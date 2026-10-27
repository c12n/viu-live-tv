//
//  EPGStore.swift
//  Viu Live TV
//
//  Loads the channel list (EPG) and exposes now/next lookups. Channels are
//  derived primarily from epgjsonV2.php; a bundled fallback list guarantees
//  the UI is never empty even if the network fails on first launch.
//

import Foundation
import Observation

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

    init() {
        // Start with fallback so the first frame is populated.
        channels = Self.fallbackChannels
        usingFallback = true
    }

    /// Fetch the live channel list. On failure, keep whatever we have (fallback
    /// or previously loaded) and record the error.
    ///
    /// Strategy (the Android app's main flow is tags -> per-tag EPG, and the
    /// token-less V2 feed now answers "Error 2", verified live):
    ///  1. Fetch tags, then merge the per-tag EPG (`epgjson.php?token=&tag=`).
    ///  2. `epgjsonV2.php?token=`
    ///  3. Plain `epgjsonV2.php` (original, token-less)
    @MainActor
    func refresh() async {
        state = .loading
        do {
            let fetched = try await fetchAllChannels()
            if fetched.isEmpty {
                // Keep fallback rather than showing an empty screen.
                if channels.isEmpty { channels = Self.fallbackChannels; usingFallback = true }
                state = .loaded(count: channels.count)
            } else {
                channels = dedupeAndSort(fetched)
                usingFallback = false
                lastUpdated = Date()
                state = .loaded(count: channels.count)
            }
        } catch {
            if channels.isEmpty {
                channels = Self.fallbackChannels
                usingFallback = true
            }
            state = .failed((error as? APIError)?.errorDescription ?? error.localizedDescription)
        }

        // Tags are optional and require a token; ignore failures.
        if let _ = await APIClient.shared.currentToken() {
            if let fetchedTags = try? await APIClient.shared.fetchTags() {
                tags = fetchedTags.filter { !$0.parameterName.isEmpty }
            }
        }
    }

    /// Multi-strategy channel fetch described in `refresh()`.
    private func fetchAllChannels() async throws -> [EPGChannel] {
        var lastError: Error?

        // 1. Per-tag EPG (requires token) — the Android app's primary flow.
        if let _ = await APIClient.shared.currentToken() {
            if let fetchedTags = try? await APIClient.shared.fetchTags() {
                let usable = fetchedTags.filter { !$0.parameterName.isEmpty }
                if !usable.isEmpty {
                    tags = usable
                    var merged: [EPGChannel] = []
                    for tag in usable {
                        if let channelsForTag = try? await APIClient.shared.fetchChannels(tag: tag.parameterName) {
                            merged.append(contentsOf: channelsForTag)
                        }
                    }
                    if !merged.isEmpty { return merged }
                }
            }

            // 2. Tokenised V2 feed.
            do {
                let fetched = try await APIClient.shared.fetchChannelsV2WithToken()
                if !fetched.isEmpty { return fetched }
            } catch { lastError = error }
        }

        // 3. Plain V2 feed.
        do {
            return try await APIClient.shared.fetchChannels()
        } catch {
            if let lastError { throw lastError }
            throw error
        }
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

    /// Filter + search helper used by the list view.
    func filtered(search: String, categoryID: String? = nil) -> [EPGChannel] {
        var result = channels
        if let categoryID, !categoryID.isEmpty {
            result = result.filter { $0.categoryId == categoryID }
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
