//
//  ChannelListView.swift
//  Viu Live TV
//
//  The first screen after login: channel list with search, category chips
//  (the server's live TV categories / tags), pull-to-refresh, and per-row
//  play / favorite / open-external actions. The All Channels | Favorites
//  switch lives in the floating bottom tab bar (iPhone) or a compact
//  segmented control (iPad sidebar).
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
    /// All Channels vs Favorites — owned by MainView (floating tab bar).
    @Binding var tab: ChannelTab
    /// Whether this list is acting as an iPad sidebar (affects row selection UI).
    var isSidebar: Bool = false
    /// iPhone: ask the owner to push the player (path-driven navigation).
    /// Row taps use NavigationLink, but the context menu's Play needs this —
    /// setting `selection` alone never navigated on iPhone, which made the
    /// menu's Play button a no-op.
    var onPlayRequest: ((EPGChannel) -> Void)?
    /// Channel-guide mode (over the playing video): a row tap picks the
    /// channel instead of navigating.
    var onChannelPicked: ((EPGChannel) -> Void)?

    @State private var search = ""
    /// Selected live TV category (tag parameter_name); nil = All.
    @State private var selectedCategory: String?

    // External-player alert state.
    @State private var externalAlert: ExternalAlert?

    struct ExternalAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private var visibleChannels: [EPGChannel] {
        let base = epg.filtered(search: search, category: selectedCategory)
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
                            .listRowInsets(EdgeInsets(top: 1, leading: 14, bottom: 1, trailing: 14))
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                let isFav = favorites.isFavorite(channel.streamId)
                                Button {
                                    Haptics.medium()
                                    favorites.toggle(channel)
                                } label: {
                                    Label(isFav ? "Unfavorite" : "Favorite",
                                          systemImage: isFav ? "star.slash" : "star.fill")
                                }
                                .tint(isFav ? .orange : .yellow)
                            }
                    }
                }
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(6)
        .navigationTitle("Viu Live TV")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search channels or shows")
        .refreshable { await epg.refresh() }
        .safeAreaInset(edge: .top) { topInset }
        .alert(item: $externalAlert) { alert in
            Alert(title: Text(alert.title),
                  message: Text(alert.message),
                  dismissButton: .default(Text("OK")))
        }
        .task {
            if epg.usingFallback { await epg.refresh() }
            await favorites.reconcileWithServer()
        }
        .onChange(of: epg.tags) { _, newTags in
            // Drop a category selection that no longer exists.
            if let selectedCategory, !newTags.contains(where: { $0.parameterName == selectedCategory }) {
                self.selectedCategory = nil
            }
        }
        .onChange(of: epg.hiddenCategoryTags) { _, _ in
            // Drop a category selection that was just hidden in Settings.
            if let selectedCategory, epg.isCategoryHidden(selectedCategory) {
                self.selectedCategory = nil
            }
        }
        .onChange(of: tab) { _, newTab in
            // Categories belong to the Channels tab; Favorites shows all
            // favorites regardless of any category picked earlier.
            if newTab == .favorites {
                self.selectedCategory = nil
            }
        }
    }

    // MARK: Top inset (iPad picker + category chips)

    private var topInset: some View {
        VStack(spacing: 0) {
            if isSidebar {
                Picker("View", selection: $tab) {
                    ForEach(ChannelTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            if tab == .all && !displayTags.isEmpty && !epg.usingFallback {
                categoryChips
            }
        }
        .background(.bar)
    }

    // MARK: Category chips

    /// The server's ALL and FAVORITES tags duplicate the built-in All /
    /// Favorites tabs, so they are not repeated as chips. Categories the
    /// user hid in Settings are excluded, and the user's saved order is
    /// applied (long-press drag in the chip bar). Written as explicit
    /// loops — filter closures here pushed the type checker over its
    /// limit inside the big list body.
    private var displayTags: [EPGTag] {
        var base: [EPGTag] = []
        for tag in epg.tags where tag.parameterName != "ALL" && tag.parameterName != "FAVORITES"
            && !epg.isCategoryHidden(tag.parameterName) {
            base.append(tag)
        }
        var result: [EPGTag] = []
        var used = Set<String>()
        for param in epg.categoryOrder {
            for tag in base where tag.parameterName == param {
                result.append(tag)
                used.insert(param)
            }
        }
        for tag in base where !used.contains(tag.parameterName) {
            result.append(tag)
        }
        return result
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(title: "All", isSelected: selectedCategory == nil) {
                    selectedCategory = nil
                }
                .dropDestination(for: String.self) { items, _ in
                    // Dropping on "All" moves the category to the front.
                    guard let dragged = items.first else { return false }
                    epg.moveCategory(dragged, before: displayTags.first?.parameterName)
                    Haptics.medium()
                    return true
                }
                ForEach(displayTags) { tag in
                    chip(title: tag.displayName, isSelected: selectedCategory == tag.parameterName) {
                        selectedCategory = tag.parameterName
                    }
                    .draggable(tag.parameterName)
                    .dropDestination(for: String.self) { items, _ in
                        guard let dragged = items.first, dragged != tag.parameterName else { return false }
                        epg.moveCategory(dragged, before: tag.parameterName)
                        Haptics.medium()
                        return true
                    }
                }
                // Trailing drop zone: dropping here moves the category last.
                Color.clear
                    .frame(width: 28, height: 30)
                    .dropDestination(for: String.self) { items, _ in
                        guard let dragged = items.first else { return false }
                        epg.moveCategory(dragged, before: nil)
                        Haptics.medium()
                        return true
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    private func chip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .glassControl(cornerRadius: 999, tint: isSelected ? .accentColor : nil)
    }

    // MARK: Rows

    @ViewBuilder
    private func row(for channel: EPGChannel) -> some View {
        let rowContent = ChannelRowView(
            channel: channel,
            isFavorite: favorites.isFavorite(channel.streamId),
            now: epg.now(for: channel),
            next: epg.next(for: channel),
            onPlay: { play(channel) },
            onToggleFavorite: {
                Haptics.medium()
                favorites.toggle(channel)
            },
            onOpenExternal: { openExternal(channel) },
            tapToPlay: isSidebar
        )

        if let onChannelPicked {
            // Channel guide over the player: tap picks, no navigation.
            rowContent
                .contentShape(Rectangle())
                .onTapGesture {
                    Haptics.light()
                    onChannelPicked(channel)
                }
        } else if isSidebar {
            // In split view, selection drives the detail column.
            rowContent
        } else {
            // iPhone: the whole row is a plain Button that pushes the
            // player via play(). A NavigationLink whose label contains the
            // interactive favorite star swallowed plain row taps (only the
            // long-press menu's Play worked), so the star inside the row
            // is a non-interactive indicator and a real star Button is
            // overlaid exactly on top of it.
            ZStack(alignment: .trailing) {
                Button {
                    play(channel)
                } label: {
                    ChannelRowView(
                        channel: channel,
                        isFavorite: favorites.isFavorite(channel.streamId),
                        now: epg.now(for: channel),
                        next: epg.next(for: channel),
                        onPlay: { play(channel) },
                        onToggleFavorite: {
                            Haptics.medium()
                            favorites.toggle(channel)
                        },
                        onOpenExternal: { openExternal(channel) },
                        tapToPlay: false,
                        favoriteButtonInteractive: false
                    )
                }
                .buttonStyle(.plain)

                Button {
                    Haptics.medium()
                    favorites.toggle(channel)
                } label: {
                    Image(systemName: favorites.isFavorite(channel.streamId) ? "star.fill" : "star")
                        .foregroundStyle(favorites.isFavorite(channel.streamId) ? Color.yellow : Color.secondary)
                        .font(.body)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(favorites.isFavorite(channel.streamId) ? "Remove from favorites" : "Add to favorites")
            }
        }
    }

    private func play(_ channel: EPGChannel) {
        Haptics.light()
        if isSidebar {
            selection = channel
        } else if let onPlayRequest {
            onPlayRequest(channel)
        } else {
            selection = channel
        }
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
