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
    /// Set of favorited stream IDs.
    private(set) var ids: Set<Int> = []

    private let defaultsKey = "viu_favorite_stream_ids"

    init() { load() }

    func isFavorite(_ streamID: Int) -> Bool { ids.contains(streamID) }

    /// Toggle locally and attempt to sync to the server. Returns the new state.
    @discardableResult
    func toggle(_ channel: EPGChannel) -> Bool {
        let newState: Bool
        if ids.contains(channel.streamId) {
            ids.remove(channel.streamId)
            newState = false
        } else {
            ids.insert(channel.streamId)
            newState = true
        }
        save()
        syncToServer(streamID: channel.streamId, favorite: newState)
        return newState
    }

    func set(_ streamID: Int, favorite: Bool, syncServer: Bool = true) {
        if favorite { ids.insert(streamID) } else { ids.remove(streamID) }
        save()
        if syncServer { syncToServer(streamID: streamID, favorite: favorite) }
    }

    /// Merge server-reported favorites (e.g. from LiveLinks.is_favorite) without
    /// re-posting them back to the server.
    func mergeServerFavorite(streamID: Int, isFavorite: Bool) {
        let changed = isFavorite ? ids.insert(streamID).inserted : (ids.remove(streamID) != nil)
        if changed { save() }
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
        let arr = UserDefaults.standard.array(forKey: defaultsKey) as? [Int] ?? []
        ids = Set(arr)
    }

    private func save() {
        UserDefaults.standard.set(Array(ids), forKey: defaultsKey)
    }
}
