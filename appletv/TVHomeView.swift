//
//  TVHomeView.swift
//  Viu Live TV — Apple TV
//
//  Focus-first home: a top tab bar (Channels / Favorites / Search /
//  Settings), category rows of channel cards on Channels, a favorites
//  grid, and system search. Playback and the parental PIN gate are
//  coordinated here so every tab plays the same way.
//

import SwiftUI

struct TVHomeView: View {
    @Environment(EPGStore.self) private var epg
    @Environment(FavoritesStore.self) private var favorites
    @Environment(AppSettings.self) private var settings
    @Environment(ParentalControls.self) private var parental

    @State private var playing: EPGChannel?
    @State private var pinFor: EPGChannel?
    @State private var pinSucceeded = false

    var body: some View {
        TabView {
            TVChannelsView(onPlay: requestPlay)
                .tabItem { Label("Channels", systemImage: "tv") }
            TVFavoritesView(onPlay: requestPlay)
                .tabItem { Label("Favorites", systemImage: "heart") }
            TVSearchView(onPlay: requestPlay)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            TVSettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .fullScreenCover(item: $playing) { channel in
            TVPlayerView(channel: channel, contextList: epg.channels)
        }
        .sheet(item: $pinFor, onDismiss: {
            if pinSucceeded, let channel = pinForAfterDismiss {
                playing = channel
            }
            pinSucceeded = false
            pinForAfterDismiss = nil
        }) { channel in
            TVPINEntryView(title: "Enter PIN to watch \(channel.name)") { pin in
                guard let pin else { return true }
                if parental.verify(pin) {
                    pinSucceeded = true
                    pinForAfterDismiss = channel
                    return true
                }
                return false
            }
        }
    }

    @State private var pinForAfterDismiss: EPGChannel?

    private func requestPlay(_ channel: EPGChannel) {
        if parental.isEnabled && parental.isLocked(channel.streamId) {
            pinFor = channel
        } else {
            playing = channel
        }
    }
}

// MARK: - Channels (category rows)

struct TVChannelsView: View {
    @Environment(EPGStore.self) private var epg
    @Environment(AppSettings.self) private var settings
    @Environment(ParentalControls.self) private var parental
    let onPlay: (EPGChannel) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if epg.channels.isEmpty {
                    VStack(spacing: 20) {
                        ProgressView().controlSize(.large)
                        Text("Loading channels…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 44) {
                            if !recentChannels.isEmpty {
                                channelRow(title: "Recently Watched",
                                           channels: recentChannels)
                            }
                            ForEach(visibleTags) { tag in
                                let list = channels(for: tag)
                                if !list.isEmpty {
                                    channelRow(title: tag.displayName,
                                               channels: list)
                                }
                            }
                        }
                        .padding(.horizontal, 48)
                        .padding(.vertical, 28)
                    }
                }
            }
            .navigationTitle("Channels")
        }
        .task {
            if epg.usingFallback || epg.channels.isEmpty {
                await epg.refresh()
            }
        }
    }

    private func channelRow(title: String, channels: [EPGChannel]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title3.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    ForEach(channels) { channel in
                        TVChannelCard(channel: channel) { onPlay(channel) }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 10)
            }
        }
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

    private func channels(for tag: EPGTag) -> [EPGChannel] {
        var list = epg.filtered(search: "", category: tag.parameterName)
        if !settings.languageFilter.isEmpty {
            list = list.filter { $0.language.code == settings.languageFilter }
        }
        return list
    }

    private var recentChannels: [EPGChannel] {
        var out: [EPGChannel] = []
        for id in settings.recentChannelIDs {
            guard let channel = epg.channel(for: id) else { continue }
            if parental.kidsModeEnabled,
               epg.channelCategories[id]?.contains("KIDS") != true { continue }
            if !settings.languageFilter.isEmpty,
               channel.language.code != settings.languageFilter { continue }
            out.append(channel)
        }
        return out
    }
}

// MARK: - Favorites

struct TVFavoritesView: View {
    @Environment(EPGStore.self) private var epg
    @Environment(FavoritesStore.self) private var favorites
    @Environment(AppSettings.self) private var settings
    @Environment(ParentalControls.self) private var parental
    let onPlay: (EPGChannel) -> Void

    private var favoriteChannels: [EPGChannel] {
        var list = epg.channels.filter { favorites.isFavorite($0.streamId) }
        if parental.kidsModeEnabled {
            list = list.filter {
                epg.channelCategories[$0.streamId]?.contains("KIDS") == true
            }
        } else if settings.sportsModeEnabled {
            list = list.filter { epg.isSports($0) }
        }
        if !settings.languageFilter.isEmpty {
            list = list.filter { $0.language.code == settings.languageFilter }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            Group {
                if favoriteChannels.isEmpty {
                    ContentUnavailableView(
                        "No Favorites",
                        systemImage: "heart.slash",
                        description: Text("Favorite a channel and it will show up here."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 28)],
                                  spacing: 28) {
                            ForEach(favoriteChannels) { channel in
                                TVChannelCard(channel: channel) { onPlay(channel) }
                            }
                        }
                        .padding(48)
                    }
                }
            }
            .navigationTitle("Favorites")
        }
    }
}

// MARK: - Search

struct TVSearchView: View {
    @Environment(EPGStore.self) private var epg
    @Environment(AppSettings.self) private var settings
    let onPlay: (EPGChannel) -> Void
    @State private var query = ""

    private var results: [EPGChannel] {
        var list = epg.filtered(search: query)
        if !settings.languageFilter.isEmpty {
            list = list.filter { $0.language.code == settings.languageFilter }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            Group {
                if query.isEmpty {
                    ContentUnavailableView(
                        "Search Channels",
                        systemImage: "magnifyingglass",
                        description: Text("Search by channel name — or by what's on, like a team or a show."))
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 28)],
                                  spacing: 28) {
                            ForEach(results) { channel in
                                TVChannelCard(channel: channel) { onPlay(channel) }
                            }
                        }
                        .padding(48)
                    }
                }
            }
            .navigationTitle("Search")
        }
        .searchable(text: $query, prompt: "Channels and programmes")
    }
}

// MARK: - Channel card

struct TVChannelCard: View {
    @Environment(FavoritesStore.self) private var favorites
    @Environment(ParentalControls.self) private var parental
    let channel: EPGChannel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                    if let url = channel.logoURL {
                        AsyncImage(url: url) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFit().padding(14)
                            } else {
                                Image(systemName: "tv")
                                    .font(.largeTitle)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Image(systemName: "tv")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 300, height: 150)
                HStack(spacing: 8) {
                    Text(channel.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(channel.language.code.uppercased())
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.tint, in: Capsule())
                        .foregroundStyle(.white)
                    if parental.isLocked(channel.streamId) {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if favorites.isFavorite(channel.streamId) {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                    Spacer(minLength: 0)
                }
                Text(channel.nowText())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 300)
        }
        .buttonStyle(.card)
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
