//
//  EPGStore.swift
//  Viu Live TV
//
//  Loads the channel list (EPG) and exposes now/next lookups. A bundled
//  fallback list guarantees the UI is never empty on first launch, and is
//  always labelled as sample data when shown.
//

import Foundation
import Observation

/// Reference-type log so the nested strategy helpers can append to it.
private final class StrategyLogBox {
    var lines: [String] = []
}

@Observable
final class EPGStore {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded(count: Int)
        case failed(String)
    }

    private(set) var channels: [EPGChannel] = []
    private(set) var tags: [EPGTag] = []
    private(set) var state: LoadState = .idle
    /// True when the current list is the bundled fallback, not live data.
    private(set) var usingFallback = false
    private(set) var lastUpdated: Date?
    /// True when the server answered "expired" / auth-error for our token.
    private(set) var sessionExpired = false
    /// Per-strategy outcome of the last refresh — shown by Diagnostics.
    private(set) var strategyLog: [String] = []
    /// Which categories (tag parameter_names) each channel belongs to,
    /// learned from the per-tag EPG merge. Powers the category filter.
    private(set) var channelCategories: [Int: Set<String>] = [:]

    init() {
        // Start from the disk cache when we have one (instant channel list
        // from the last session, refreshed in the background); otherwise
        // start with the bundled fallback so the first frame is populated.
        if let cache = Self.loadCache() {
            channels = cache.channels
            tags = cache.tags
            channelCategories = cache.categories
            lastUpdated = cache.savedAt
            usingFallback = false
            state = .loaded(count: cache.channels.count)
        } else {
            channels = Self.fallbackChannels
            usingFallback = true
        }
    }

    // MARK: Disk cache

    private struct CachePayload: Codable {
        var channels: [EPGChannel]
        var tags: [EPGTag]
        var categories: [Int: Set<String>]
        var savedAt: Date
    }

    private static var cacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("viu-epg-cache.json")
    }

    private static func loadCache() -> CachePayload? {
        guard let url = cacheURL,
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(CachePayload.self, from: data),
              !payload.channels.isEmpty else { return nil }
        return payload
    }

    private func saveCache() {
        guard let url = Self.cacheURL else { return }
        let payload = CachePayload(channels: channels, tags: tags,
                                   categories: channelCategories, savedAt: Date())
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Sign-out: forget the cached guide and return to the bundled samples.
    func clearCacheAndReset() {
        if let url = Self.cacheURL { try? FileManager.default.removeItem(at: url) }
        channels = Self.fallbackChannels
        tags = []
        channelCategories = [:]
        usingFallback = true
        lastUpdated = nil
        sessionExpired = false
        state = .idle
    }

    /// Fetch the live channel list. On failure, keep whatever we have
    /// (fallback or previously loaded) and record what the server said.
    ///
    /// Strategy:
    ///  1. FAST: tags + the single ALL feed (one request); categories come
    ///     from each channel's own `tags` field.
    ///  2. Tags, then every tag's EPG fetched IN PARALLEL and merged.
    ///  3. `epgjson.php?token=` with no tag.
    ///  4. `epgjsonV2.php?token=`
    ///  5. Plain `epgjsonV2.php` (original, token-less)
    /// A successful load is cached to disk so the next launch is instant.
    @MainActor
    func refresh() async {
        state = .loading
        sessionExpired = false
        channelCategories = [:]
        let log = StrategyLogBox()
        do {
            let fetched = try await fetchAllChannels(log: log)
            strategyLog = log.lines
            if fetched.isEmpty {
                if channels.isEmpty { channels = Self.fallbackChannels; usingFallback = true }
                state = .failed("The server returned an empty channel list.")
            } else {
                channels = dedupeAndSort(fetched)
                usingFallback = false
                lastUpdated = Date()
                state = .loaded(count: channels.count)
                saveCache()
            }
        } catch {
            strategyLog = log.lines
            if let apiError = error as? APIError, case .sessionExpired = apiError {
                sessionExpired = true
            }
            if channels.isEmpty {
                channels = Self.fallbackChannels
                usingFallback = true
            }
            state = .failed((error as? APIError)?.errorDescription ?? error.localizedDescription)
        }

        // Tags are optional; refresh them quietly when a token exists.
        if await APIClient.shared.currentToken() != nil,
           let fetchedTags = try? await APIClient.shared.fetchTags() {
            tags = fetchedTags.filter { !$0.parameterName.isEmpty }
        }
    }

    /// Multi-strategy channel fetch described in `refresh()`. Every strategy
    /// appends its outcome to `log` so failures are visible, not silent.
    private func fetchAllChannels(log: StrategyLogBox) async throws -> [EPGChannel] {
        var lastError: Error?
        var sawExpired = false

        func note(_ error: Error, _ label: String) {
            if let apiError = error as? APIError, case .sessionExpired = apiError { sawExpired = true }
            log.lines.append("\(label): \((error as? APIError)?.errorDescription ?? error.localizedDescription)")
            lastError = error
        }

        if await APIClient.shared.currentToken() != nil {
            // 1. FAST PATH: the single ALL feed. It already contains every
            //    channel (1,145 channels / ~2.3 MB / ~3 s on the wire,
            //    measured) and each channel's own `tags` field names its
            //    categories, so one request replaces the 72-request merge
            //    that made loading take ~25 s.
            do {
                let fetchedTags = try await APIClient.shared.fetchTags()
                let usable = fetchedTags.filter { !$0.parameterName.isEmpty }
                if !usable.isEmpty { tags = usable }
                let all = try await APIClient.shared.fetchChannels(tag: "ALL")
                log.lines.append("ALL feed: \(all.count) channels (single request)")
                if !all.isEmpty {
                    channelCategories = Self.categoryMapping(from: all)
                    return all
                }
            } catch { note(error, "ALL feed") }

            // 2. Per-tag EPG in parallel (the Android app's primary flow).
            do {
                let fetchedTags = try await APIClient.shared.fetchTags()
                let usable = fetchedTags.filter { !$0.parameterName.isEmpty }
                if usable.isEmpty {
                    log.lines.append("Tags: server returned no tags")
                } else {
                    tags = usable
                    let merged = await fetchChannelsForTagsInParallel(usable)
                    log.lines.append("Per-tag EPG: \(merged.count) channels from \(usable.count) tags")
                    if !merged.isEmpty { return merged }
                    // All tags came back empty — probe the first one directly
                    // so the log (and any expiry) shows the real reason.
                    do {
                        let probe = try await APIClient.shared.fetchChannels(tag: usable[0].parameterName)
                        if !probe.isEmpty { return probe }
                        log.lines.append("Per-tag probe: empty list")
                    } catch { note(error, "Per-tag probe") }
                }
            } catch { note(error, "Tags") }

            // 2. EPG with token, no tag.
            do {
                let fetched = try await APIClient.shared.fetchChannelsNoTag()
                log.lines.append("EPG (no tag): \(fetched.count) channels")
                if !fetched.isEmpty { return fetched }
            } catch { note(error, "EPG (no tag)") }

            // 3. Tokenised V2 feed.
            do {
                let fetched = try await APIClient.shared.fetchChannelsV2WithToken()
                log.lines.append("V2 (token): \(fetched.count) channels")
                if !fetched.isEmpty { return fetched }
            } catch { note(error, "V2 (token)") }
        }

        // 4. Plain V2 feed.
        do {
            let fetched = try await APIClient.shared.fetchChannels()
            log.lines.append("V2 (no token): \(fetched.count) channels")
            if !fetched.isEmpty { return fetched }
        } catch { note(error, "V2 (no token)") }

        if sawExpired { throw APIError.sessionExpired }
        if let lastError { throw lastError }
        return []
    }

    /// Fetches every tag's channel list concurrently instead of one-by-one
    /// (a sequential pass over dozens of tags took minutes). Also records
    /// which categories each channel came from.
    private func fetchChannelsForTagsInParallel(_ tagsToFetch: [EPGTag]) async -> [EPGChannel] {
        let results: [(String, [EPGChannel])] = await withTaskGroup(of: (String, [EPGChannel]).self) { group in
            for tag in tagsToFetch {
                group.addTask {
                    (tag.parameterName, (try? await APIClient.shared.fetchChannels(tag: tag.parameterName)) ?? [])
                }
            }
            var out: [(String, [EPGChannel])] = []
            for await part in group { out.append(part) }
            return out
        }
        var mapping: [Int: Set<String>] = [:]
        var merged: [EPGChannel] = []
        for (param, chans) in results {
            merged.append(contentsOf: chans)
            for ch in chans { mapping[ch.streamId, default: []].insert(param) }
        }
        channelCategories = mapping
        return merged
    }

    /// Category membership from each channel's own `tags` string
    /// (e.g. "uk, cinema" -> {UK, CINEMA}), normalised to the parameter_name
    /// shape used by epg_tags.php (uppercased, spaces -> underscores).
    static func categoryMapping(from channels: [EPGChannel]) -> [Int: Set<String>] {
        var mapping: [Int: Set<String>] = [:]
        for ch in channels {
            guard let tags = ch.tags else { continue }
            var set = Set<String>()
            for raw in tags.split(separator: ",") {
                let token = raw.trimmingCharacters(in: .whitespaces)
                    .uppercased()
                    .replacingOccurrences(of: " ", with: "_")
                if !token.isEmpty { set.insert(token) }
            }
            if !set.isEmpty { mapping[ch.streamId] = set }
        }
        return mapping
    }

    private func dedupeAndSort(_ input: [EPGChannel]) -> [EPGChannel] {
        var seen = Set<Int>()
        var out: [EPGChannel] = []
        for ch in input where !seen.contains(ch.streamId) {
            seen.insert(ch.streamId)
            out.append(ch)
        }
        // Sort by channel number when available, else by name.
        return out.sorted {
            switch ($0.num, $1.num) {
            case let (a?, b?): return a < b
            case (_?, nil):    return true
            case (nil, _?):    return false
            default:           return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    // MARK: Lookups

    func channel(for streamID: Int) -> EPGChannel? {
        channels.first { $0.streamId == streamID }
    }

    func now(for channel: EPGChannel, at date: Date = Date()) -> EPGProgramme? {
        channel.nowProgramme(at: date)
    }

    func next(for channel: EPGChannel, at date: Date = Date()) -> EPGProgramme? {
        channel.nextProgramme(at: date)
    }

    /// Filter + search helper used by the list view. `category` is a tag
    /// parameter_name (a live TV category from epg_tags.php).
    func filtered(search: String, category: String? = nil) -> [EPGChannel] {
        var result = channels
        if let category, !category.isEmpty {
            result = result.filter { ch in
                if channelCategories[ch.streamId]?.contains(category) == true { return true }
                if ch.categoryId == category { return true }
                // Fallback: normalised token match against the raw tags
                // string ("HOT_RIGHT_NOW" vs "hot right now, sports").
                guard let tags = ch.tags else { return false }
                return tags.split(separator: ",").contains {
                    $0.trimmingCharacters(in: .whitespaces)
                        .uppercased()
                        .replacingOccurrences(of: " ", with: "_") == category
                }
            }
        }
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return result }
        return result.filter {
            $0.name.lowercased().contains(q) ||
            $0.nowText().lowercased().contains(q) ||
            ($0.tags?.lowercased().contains(q) ?? false)
        }
    }

    // MARK: Bundled fallback channel list

    static let fallbackChannels: [EPGChannel] = [
        EPGChannel(num: 1, name: "Viu News 24", streamType: "live", streamId: 90001,
                   streamIcon: nil, epgChannelId: "viu.news", categoryId: "news",
                   currentShow: "Live Coverage"),
        EPGChannel(num: 2, name: "Viu Sports", streamType: "live", streamId: 90002,
                   streamIcon: nil, epgChannelId: "viu.sports", categoryId: "sports",
                   currentShow: "Match of the Day"),
        EPGChannel(num: 3, name: "Viu Movies", streamType: "live", streamId: 90003,
                   streamIcon: nil, epgChannelId: "viu.movies", categoryId: "entertainment",
                   currentShow: "Feature Presentation"),
        EPGChannel(num: 4, name: "Viu Kids", streamType: "live", streamId: 90004,
                   streamIcon: nil, epgChannelId: "viu.kids", categoryId: "kids",
                   currentShow: "Morning Cartoons"),
        EPGChannel(num: 5, name: "Viu Music", streamType: "live", streamId: 90005,
                   streamIcon: nil, epgChannelId: "viu.music", categoryId: "music",
                   currentShow: "Top 40 Countdown"),
        EPGChannel(num: 6, name: "Viu Documentary", streamType: "live", streamId: 90006,
                   streamIcon: nil, epgChannelId: "viu.docs", categoryId: "documentary",
                   currentShow: "Planet Explorers")
    ]
}
