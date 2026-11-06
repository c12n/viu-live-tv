//
//  FavoritesStore.swift
//  Viu Live TV
//
//  Local favorites persistence (UserDefaults) with best-effort sync to the
//  server favorites endpoints. Local is the source of truth for the UI so the
//  star toggles instantly; server calls happen in the background.
//

import Foundation
import Observation

@Observable
final class FavoritesStore {
    /// Set of favorited stream IDs (active profile).
    private(set) var ids: Set<Int> = []
    /// Display order for favorites (2.0.0): stream IDs in user order.
    private(set) var order: [Int] = []
    /// Pinned favorites (2.0.0), shown first.
    private(set) var pinned: Set<Int> = []
    /// The profile these favorites belong to (2.0.0).
    private(set) var profileID: UUID = AppSettings.mainProfileID
    /// Server sync only happens for the main profile (2.0.0).
    private var serverSyncEnabled = true

    private var defaultsKey: String {
        profileID == AppSettings.mainProfileID
            ? "viu_favorite_stream_ids"
            : "viu_favorite_stream_ids_\(profileID.uuidString)"
    }
    private var orderKey: String {
        profileID == AppSettings.mainProfileID
            ? "viu_favorite_order"
            : "viu_favorite_order_\(profileID.uuidString)"
    }
    private var pinnedKey: String {
        profileID == AppSettings.mainProfileID
            ? "viu_favorite_pinned"
            : "viu_favorite_pinned_\(profileID.uuidString)"
    }

    init() { load() }

    /// Switch to another profile's favorites (2.0.0). The main profile
    /// syncs with the server; other profiles are local-only.
    func switchProfile(to id: UUID) {
        guard id != profileID else { return }
        profileID = id
        serverSyncEnabled = (id == AppSettings.mainProfileID)
        didReconcile = false
        load()
    }

    // MARK: Order + pins (2.0.0)

    func isPinned(_ streamID: Int) -> Bool { pinned.contains(streamID) }

    func setPinned(_ streamID: Int, _ isPinned: Bool) {
        if isPinned { pinned.insert(streamID) } else { pinned.remove(streamID) }
        save()
    }

    /// Favorites in display order: pinned first (by manual order),
    /// then the manual order, then any unordered favorites by name.
    func orderedChannels(from channels: [EPGChannel]) -> [EPGChannel] {
        let byID = Dictionary(channels.map { ($0.streamId, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [EPGChannel] = []
        var used = Set<Int>()
        let orderedIDs = order.filter { ids.contains($0) }
        for id in orderedIDs where pinned.contains(id) {
            if let ch = byID[id] { result.append(ch); used.insert(id) }
        }
        for id in orderedIDs where !pinned.contains(id) {
            if let ch = byID[id] { result.append(ch); used.insert(id) }
        }
        let rest = ids.subtracting(used)
            .compactMap { byID[$0] }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return result + rest
    }

    /// Move a favorite within the display order (materializes the
    /// full order on first use).
    func move(streamID: Int, before targetID: Int?) {
        var current = orderedStreamIDs()
        current.removeAll { $0 == streamID }
        if let targetID, let idx = current.firstIndex(of: targetID) {
            current.insert(streamID, at: idx)
        } else {
            current.append(streamID)
        }
        order = current
        save()
    }

    private func orderedStreamIDs() -> [Int] {
        var result = order.filter { ids.contains($0) }
        let missing = ids.subtracting(Set(result)).sorted()
        result.append(contentsOf: missing)
        return result
    }

    func isFavorite(_ streamID: Int) -> Bool { ids.contains(streamID) }

    /// Toggle locally and attempt to sync to the server. Returns the new state.
    @discardableResult
    func toggle(_ channel: EPGChannel) -> Bool {
        let newState: Bool
        if ids.contains(channel.streamId) {
            ids.remove(channel.streamId)
            order.removeAll { $0 == channel.streamId }
            pinned.remove(channel.streamId)
            newState = false
        } else {
            ids.insert(channel.streamId)
            if !order.contains(channel.streamId) { order.append(channel.streamId) }
            newState = true
        }
        save()
        if serverSyncEnabled { syncToServer(streamID: channel.streamId, favorite: newState) }
        return newState
    }

    func set(_ streamID: Int, favorite: Bool, syncServer: Bool = true) {
        if favorite {
            ids.insert(streamID)
            if !order.contains(streamID) { order.append(streamID) }
        } else {
            ids.remove(streamID)
            order.removeAll { $0 == streamID }
            pinned.remove(streamID)
        }
        save()
        if syncServer && serverSyncEnabled { syncToServer(streamID: streamID, favorite: favorite) }
    }

    /// Merge server-reported favorites (e.g. from LiveLinks.is_favorite) without
    /// re-posting them back to the server.
    func mergeServerFavorite(streamID: Int, isFavorite: Bool) {
        let changed = isFavorite ? ids.insert(streamID).inserted : (ids.remove(streamID) != nil)
        if changed {
            if isFavorite && !order.contains(streamID) { order.append(streamID) }
            if !isFavorite {
                order.removeAll { $0 == streamID }
                pinned.remove(streamID)
            }
            save()
        }
    }

    /// Clear Favorites (Settings): remove every favorite locally AND on
    /// the server, so the website's list is cleared too and the launch
    /// sync doesn't bring them back.
    func clearAll() async {
        let current = ids
        ids = []
        order = []
        pinned = []
        save()
        for id in current {
            try? await APIClient.shared.removeFavorite(streamID: id)
        }
    }

    private var didReconcile = false

    /// Two-way sync with the account's favorites on the server — the same
    /// list the website shows. Pulls the server's FAVORITES feed into the
    /// local set and pushes any local-only favorites up. Add-only in both
    /// directions, so syncing can never lose a favorite. This is also what
    /// makes favorites survive an app update or reinstall: sign in, and
    /// the website's favorites come straight back. Runs once per launch.
    func reconcileWithServer() async {
        guard serverSyncEnabled, !didReconcile else { return }
        didReconcile = true
        do {
            let serverChannels = try await APIClient.shared.fetchChannels(tag: "FAVORITES")
            let serverIDs = Set(serverChannels.map { $0.streamId })
            if !serverIDs.isSubset(of: ids) {
                ids.formUnion(serverIDs)
                for id in serverIDs where !order.contains(id) { order.append(id) }
                save()
            }
            for id in ids.subtracting(serverIDs) {
                try? await APIClient.shared.saveFavorite(streamID: id)
            }
        } catch {
            didReconcile = false   // retry on a later appearance
        }
    }

    private func syncToServer(streamID: Int, favorite: Bool) {
        Task {
            do {
                if favorite {
                    _ = try await APIClient.shared.saveFavorite(streamID: streamID)
                } else {
                    _ = try await APIClient.shared.removeFavorite(streamID: streamID)
                }
            } catch {
                // Non-fatal: local state already reflects the user's intent.
                // The next launch/refresh can reconcile.
            }
        }
    }

    // MARK: Persistence

    private func load() {
        let d = UserDefaults.standard
        ids = Set(d.array(forKey: defaultsKey) as? [Int] ?? [])
        order = d.array(forKey: orderKey) as? [Int] ?? []
        pinned = Set(d.array(forKey: pinnedKey) as? [Int] ?? [])
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(Array(ids), forKey: defaultsKey)
        d.set(order, forKey: orderKey)
        d.set(Array(pinned), forKey: pinnedKey)
    }
}
