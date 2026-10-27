//
//  ChannelListView.swift
//  Viu Live TV
//
//  The first screen after login: All Channels | Favorites, with search,
//  pull-to-refresh, and per-row play / favorite / open-external actions.
//
//  On iPhone this is pushed in a NavigationStack. On iPad it is the sidebar
//  of a NavigationSplitView (see ContentView), and selecting a channel sets
//  the detail column.
//

import SwiftUI

enum ChannelTab: String, CaseIterable, Identifiable {
    case all = "All Channels"
    case favorites = "Favorites"
    var id: String { rawValue }
}

struct ChannelListView: View {
    @Environment(EPGStore.self) private var epg
    @Environment(FavoritesStore.self) private var favorites
    @Environment(AppSettings.self) private var settings
    @Environment(AuthViewModel.self) private var auth

    /// On iPad, selecting a channel drives the detail column. On iPhone we push.
    @Binding var selection: EPGChannel?
    /// Whether this list is acting as an iPad sidebar (affects row selection UI).
    var isSidebar: Bool = false

    @State private var tab: ChannelTab = .all
    @State private var search = ""

    // External-player alert state.
    @State private var externalAlert: ExternalAlert?

    struct ExternalAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private var visibleChannels: [EPGChannel] {
        let base = epg.filtered(search: search)
        switch tab {
        case .all:       return base
        case .favorites: return base.filter { favorites.isFavorite($0.streamId) }
        }
    }

    var body: some View {
        List(selection: isSidebar ? $selection : .constant(nil)) {
            if epg.sessionExpired {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Your Viu session has expired.", systemImage: "key.slash")
                            .font(.subheadline.bold())
                            .foregroundStyle(.red)
                        Text("The server no longer accepts this sign-in (signing in on the Viu website or another device can revoke it). Sign out and sign in again to load your channels.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Sign Out & Sign In Again", role: .destructive) {
                            Task { await auth.logout() }
                        }
                        .font(.subheadline.bold())
                    }
                    .padding(.vertical, 4)
                }
            }

            if epg.usingFallback {
                Section {
                    Label("Showing sample channels — pull to refresh for the live list.",
                          systemImage: "wifi.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if case .failed(let msg) = epg.state {
                Section {
                    Label(msg, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                if visibleChannels.isEmpty {
                    ContentUnavailableView(
                        tab == .favorites ? "No Favorites Yet" : "No Channels",
                        systemImage: tab == .favorites ? "star" : "tv",
                        description: Text(tab == .favorites
                            ? "Tap the star on any channel to add it here."
                            : "Try refreshing or adjusting your search.")
                    )
                } else {
                    ForEach(visibleChannels) { channel in
                        row(for: channel)
                            .tag(channel)        // for sidebar selection
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Viu Live TV")
        .searchable(text: $search, prompt: "Search channels or shows")
        .refreshable { await epg.refresh() }
        .safeAreaInset(edge: .top) {
            Picker("View", selection: $tab) {
                ForEach(ChannelTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .alert(item: $externalAlert) { alert in
            Alert(title: Text(alert.title),
                  message: Text(alert.message),
                  dismissButton: .default(Text("OK")))
        }
        .task {
            if epg.usingFallback { await epg.refresh() }
        }
    }

    @ViewBuilder
    private func row(for channel: EPGChannel) -> some View {
        let rowContent = ChannelRowView(
            channel: channel,
            isFavorite: favorites.isFavorite(channel.streamId),
            now: epg.now(for: channel),
            next: epg.next(for: channel),
            onPlay: { play(channel) },
            onToggleFavorite: { favorites.toggle(channel) },
            onOpenExternal: { openExternal(channel) },
            tapToPlay: isSidebar
        )

        if isSidebar {
            // In split view, selection drives the detail column.
            rowContent
        } else {
            // In a NavigationStack, push the player.
            NavigationLink(value: channel) { rowContent }
        }
    }

    private func play(_ channel: EPGChannel) {
        selection = channel
    }

    private func openExternal(_ channel: EPGChannel) {
        Task {
            do {
                let links = try await APIClient.shared.liveLinks(streamID: channel.streamId)
                guard let link = links.liveLink, !link.isEmpty else {
                    await MainActor.run {
                        externalAlert = ExternalAlert(title: "No Stream",
                                                      message: "This channel returned no playable link.")
                    }
                    return
                }
                await MainActor.run {
                    ExternalPlayerLauncher.open(streamURL: link, choice: settings.externalPlayer) { result in
                        switch result {
                        case .opened:
                            break
                        case .notInstalled(let appName):
                            externalAlert = ExternalAlert(
                                title: "\(appName) Not Found",
                                message: "\(appName) doesn't appear to be installed. Install it, or choose a different player in Settings.")
                        case .failed:
                            externalAlert = ExternalAlert(
                                title: "Couldn't Open",
                                message: "The external player could not be opened.")
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    externalAlert = ExternalAlert(
                        title: "Error",
                        message: (error as? APIError)?.errorDescription ?? error.localizedDescription)
                }
            }
        }
    }
}
