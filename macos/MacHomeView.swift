//
//  MacHomeView.swift
//  Viu Live TV — macOS
//
//  Three-column home: sidebar (All / Favorites / Recently Watched /
//  categories with counts), a channel grid for the selection, and
//  the player as the detail column. Search covers channel names
//  and programmes. Locked channels ask for the PIN first.
//

import SwiftUI

struct MacHomeView: View {
    @Environment(EPGStore.self) private var epg
    @Environment(FavoritesStore.self) private var favorites
    @Environment(AppSettings.self) private var settings
    @Environment(ParentalControls.self) private var parental

    enum SidebarSelection: Hashable {
        case all, favorites, recent
        case category(String)
    }

    @State private var selection: SidebarSelection? = .all
    @State private var playing: EPGChannel?
    @State private var search = ""
    @State private var pinFor: EPGChannel?
    @State private var showSettingsSheet = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } content: {
            channelGrid
                .navigationSplitViewColumnWidth(min: 380, ideal: 460, max: 560)
        } detail: {
            if let playing {
                MacPlayerView(channel: playing, contextList: gridChannels)
                    .id(playing.streamId)
            } else {
                ContentUnavailableView("Select a Channel",
                                       systemImage: "play.tv",
                                       description: Text("Pick a channel from the list to start watching."))
            }
        }
        .searchable(text: $search, prompt: "Channels and programmes")
        .sheet(item: $pinFor) { target in
            MacPINEntryView(title: "Enter PIN to watch \(target.name)") { pin in
                pinFor = nil
                if let pin, parental.verify(pin) {
                    playing = target
                }
            }
            .frame(width: 340)
        }
        .sheet(isPresented: $showSettingsSheet) {
            MacSettingsView()
                .frame(minWidth: 560, minHeight: 520)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name("ViuOpenSettings"))) { _ in
            showSettingsSheet = true
        }
        .task {
            if epg.usingFallback || epg.channels.isEmpty {
                await epg.refresh()
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                Label("All Channels", systemImage: "tv")
                    .badge(epg.channels.count)
                    .tag(SidebarSelection.all)
                Label("Favorites", systemImage: "heart")
                    .badge(favorites.ids.count)
                    .tag(SidebarSelection.favorites)
                Label("Recently Watched", systemImage: "clock.arrow.circlepath")
                    .badge(settings.recentChannelIDs.count)
                    .tag(SidebarSelection.recent)
            }
            Section("Categories") {
                ForEach(visibleTags) { tag in
                    Label(tag.displayName, systemImage: "list.bullet")
                        .badge(channels(for: tag).count)
                        .tag(SidebarSelection.category(tag.parameterName))
                }
            }
            Section {
                Button {
                    showSettingsSheet = true
                } label: {
                    Label("Settings…", systemImage: "gearshape")
                }
            }
        }
        .navigationTitle("Viu Live TV")
    }

    private var visibleTags: [EPGTag] {
        let order = epg.effectiveCategoryOrder()
        var tags = epg.tags.filter { !epg.isCategoryHidden($0.parameterName) }
        if parental.kidsModeEnabled {
            tags = tags.filter { $0.parameterName == "KIDS" }
        } else if settings.sportsModeEnabled {
            tags = tags.filter { EPGStore.isSportsCategory($0.parameterName) }
        }
        return tags.sorted {
            (order.firstIndex(of: $0.parameterName) ?? 999) <
                (order.firstIndex(of: $1.parameterName) ?? 999)
        }
    }

    // MARK: Grid

    private var gridChannels: [EPGChannel] {
        var list: [EPGChannel]
        switch selection ?? .all {
        case .all:
            list = epg.filtered(search: "")
            if parental.kidsModeEnabled {
                list = list.filter {
                    epg.channelCategories[$0.streamId]?.contains("KIDS") == true
                }
            } else if settings.sportsModeEnabled {
                list = list.filter { epg.isSports($0) }
            }
        case .favorites:
            list = epg.channels.filter { favorites.isFavorite($0.streamId) }
            if parental.kidsModeEnabled {
                list = list.filter {
                    epg.channelCategories[$0.streamId]?.contains("KIDS") == true
                }
            }
        case .recent:
            list = settings.recentChannelIDs.compactMap { epg.channel(for: $0) }
        case .category(let param):
            list = epg.filtered(search: "", category: param)
        }
        if !settings.languageFilter.isEmpty {
            list = list.filter { $0.language.code == settings.languageFilter }
        }
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            let inSearch = Set(epg.filtered(search: q).map(\.streamId))
            list = list.filter { inSearch.contains($0.streamId) }
        }
        return list
    }

    private var gridTitle: String {
        switch selection ?? .all {
        case .all: return "All Channels"
        case .favorites: return "Favorites"
        case .recent: return "Recently Watched"
        case .category(let param):
            return epg.tags.first { $0.parameterName == param }?.displayName
                ?? "Channels"
        }
    }

    private var channelGrid: some View {
        Group {
            if epg.channels.isEmpty {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text("Loading channels…").foregroundStyle(.secondary)
                }
            } else if gridChannels.isEmpty {
                ContentUnavailableView("No Channels",
                                       systemImage: "tv.slash",
                                       description: Text("Nothing matches here right now."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 14)],
                              spacing: 14) {
                        ForEach(gridChannels) { channel in
                            MacChannelCard(channel: channel,
                                           isPlaying: playing?.streamId == channel.streamId) {
                                requestPlay(channel)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle(gridTitle)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await epg.refresh() }
                } label: {
                    Label("Refresh Guide", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private func channels(for tag: EPGTag) -> [EPGChannel] {
        epg.filtered(search: "", category: tag.parameterName)
    }

    private func requestPlay(_ channel: EPGChannel) {
        if parental.isEnabled && parental.isLocked(channel.streamId) {
            pinFor = channel
        } else {
            playing = channel
        }
    }
}

// MARK: - Channel card

struct MacChannelCard: View {
    @Environment(FavoritesStore.self) private var favorites
    @Environment(ParentalControls.self) private var parental
    let channel: EPGChannel
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                    if let url = channel.logoURL {
                        AsyncImage(url: url) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFit().padding(8)
                            } else {
                                Image(systemName: "tv").foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Image(systemName: "tv").foregroundStyle(.secondary)
                    }
                }
                .frame(height: 84)
                HStack(spacing: 6) {
                    if isPlaying {
                        Image(systemName: "play.fill")
                            .font(.caption2).foregroundStyle(.tint)
                    }
                    Text(channel.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(channel.language.code.uppercased())
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.tint.opacity(0.85), in: Capsule())
                        .foregroundStyle(.white)
                    if parental.isLocked(channel.streamId) {
                        Image(systemName: "lock.fill")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if favorites.isFavorite(channel.streamId) {
                        Image(systemName: "heart.fill")
                            .font(.caption2).foregroundStyle(.yellow)
                    }
                }
                Text(channel.nowText())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(10)
            .background(.background.secondary,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isPlaying ? Color.accentColor : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                favorites.toggle(channel)
            } label: {
                Label(favorites.isFavorite(channel.streamId)
                        ? "Remove from Favorites" : "Add to Favorites",
                      systemImage: favorites.isFavorite(channel.streamId)
                        ? "heart.slash" : "heart")
            }
            if parental.isEnabled {
                Button {
                    parental.setLocked(channel.streamId,
                                       locked: !parental.isLocked(channel.streamId))
                } label: {
                    Label(parental.isLocked(channel.streamId)
                            ? "Unlock Channel" : "Lock Channel",
                          systemImage: parental.isLocked(channel.streamId)
                            ? "lock.open" : "lock")
                }
            }
        }
    }
}
