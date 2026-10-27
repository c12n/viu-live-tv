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
        // Start with fallback so the first frame is populated.
        channels = Self.fallbackChannels
        usingFallback = true
    }

    /// Fetch the live channel list. On failure, keep whatever we have
    /// (fallback or previously loaded) and record what the server said.
    ///
    /// Strategy (mirrors the Android app, whose main flow is tags -> per-tag
    /// EPG; the token-less V2 feed now answers "Error 2", verified live):
    ///  1. Tags, then every tag's EPG fetched IN PARALLEL and merged.
    ///  2. `epgjson.php?token=` with no tag.
    ///  3. `epgjsonV2.php?token=`
    ///  4. Plain `epgjsonV2.php` (original, token-less)
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
            // 1. Per-tag EPG in parallel (the Android app's primary flow).
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
                channelCategories[ch.streamId]?.contains(category) == true
                    || ch.categoryId == category
                    || (ch.tags?.localizedCaseInsensitiveContains(category) ?? false)
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
