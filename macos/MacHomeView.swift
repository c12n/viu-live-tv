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
        case group(UUID)
    }

    @State private var selection: SidebarSelection? = .all
    @State private var playing: EPGChannel?
    @State private var search = ""
    @State private var pinFor: EPGChannel?
    @State private var showSettingsSheet = false
    @State private var showGuide = false

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
        .sheet(isPresented: $showGuide) {
            MacGuideView { channel in
                showGuide = false
                requestPlay(channel)
            }
            .frame(minWidth: 900, minHeight: 560)
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
            if let jump = jumpBackChannel {
                Section {
                    Button {
                        requestPlay(jump)
                    } label: {
                        Label("Jump back in: \(jump.name)", systemImage: "play.circle.fill")
                            .lineLimit(1)
                    }
                }
            }
            if !liveSports.isEmpty {
                Section("Live Sports Now") {
                    ForEach(liveSports.prefix(10)) { channel in
                        Button {
                            requestPlay(channel)
                        } label: {
                            Label(channel.name, systemImage: "sportscourt")
                                .lineLimit(1)
                        }
                    }
                }
            }
            if !settings.activeGroups.isEmpty {
                Section("My Groups") {
                    ForEach(settings.activeGroups) { group in
                        Label(group.name, systemImage: "folder")
                            .badge(group.channelIDs.count)
                            .tag(SidebarSelection.group(group.id))
                    }
                }
            }
            Section {
                Button {
                    showGuide = true
                } label: {
                    Label("Programme Guide", systemImage: "calendar")
                }
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

    private var jumpBackChannel: EPGChannel? {
        guard let id = settings.recentChannelIDs.first,
              let at = settings.recentWatchedAt[id],
              Date().timeIntervalSince(at) < 3 * 3600,
              let channel = epg.channel(for: id),
              let now = channel.nowProgramme(),
              let left = now.minutesLeft(), left > 5
        else { return nil }
        return channel
    }

    private var liveSports: [EPGChannel] {
        epg.liveSportsChannels()
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
            list = favorites.orderedChannels(from: epg.channels.filter { favorites.isFavorite($0.streamId) })
            if parental.kidsModeEnabled {
                list = list.filter {
                    epg.channelCategories[$0.streamId]?.contains("KIDS") == true
                }
            }
        case .group(let groupID):
            let ids = settings.customGroups.first { $0.id == groupID }?.channelIDs ?? []
            list = ids.compactMap { epg.channel(for: $0) }
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
        case .group(let groupID):
            return settings.customGroups.first { $0.id == groupID }?.name ?? "Group"
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
    @Environment(AppSettings.self) private var settings
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
                    if favorites.isPinned(channel.streamId) {
                        Image(systemName: "pin.fill")
                            .font(.caption2).foregroundStyle(.tint)
                    }
                }
                Text(channel.nowText())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let now = channel.nowProgramme(), let progress = now.progress() {
                    HStack(spacing: 6) {
                        ProgressView(value: progress)
                            .controlSize(.small)
                        if let end = now.timeEnd {
                            Text("Ends \(end.formatted(date: .omitted, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
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
            if favorites.isFavorite(channel.streamId) {
                Button {
                    favorites.setPinned(channel.streamId,
                                        !favorites.isPinned(channel.streamId))
                } label: {
                    Label(favorites.isPinned(channel.streamId) ? "Unpin" : "Pin to Top",
                          systemImage: "pin")
                }
                Button { favorites.moveUp(channel.streamId) } label: {
                    Label("Move Up", systemImage: "arrow.up")
                }
                Button { favorites.moveDown(channel.streamId) } label: {
                    Label("Move Down", systemImage: "arrow.down")
                }
            }
            if !settings.activeGroups.isEmpty {
                Menu("Groups") {
                    ForEach(settings.activeGroups) { group in
                        Button {
                            settings.setInGroup(group.id, streamID: channel.streamId,
                                                member: !settings.groupContains(group.id, streamID: channel.streamId))
                        } label: {
                            Label(group.name,
                                  systemImage: settings.groupContains(group.id, streamID: channel.streamId)
                                    ? "checkmark.circle.fill" : "circle")
                        }
                    }
                }
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


// MARK: - Timeline guide (2.0.0, macOS)

/// Timeline guide sheet: channels as rows, next 6 hours as blocks.
struct MacGuideView: View {
    @Environment(EPGStore.self) private var epg
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    var onPlay: (EPGChannel) -> Void

    private let hoursShown = 6
    private let pxPerSecond: CGFloat = 0.075
    private var totalWidth: CGFloat { CGFloat(hoursShown * 3600) * pxPerSecond }
    private let labelWidth: CGFloat = 170

    private var windowStart: Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: Date())
        return cal.date(from: comps) ?? Date()
    }
    private var windowEnd: Date { windowStart.addingTimeInterval(TimeInterval(hoursShown * 3600)) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Programme Guide")
                    .font(.title3.weight(.bold))
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(12)
            Divider()
            ScrollView(.vertical) {
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            Color.clear.frame(width: labelWidth, height: 20)
                            ZStack(alignment: .leading) {
                                ForEach(0..<hoursShown, id: \.self) { h in
                                    Text(windowStart.addingTimeInterval(TimeInterval(h * 3600))
                                        .formatted(date: .omitted, time: .shortened))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .offset(x: CGFloat(h * 3600) * pxPerSecond + 4)
                                }
                            }
                            .frame(width: totalWidth, height: 20, alignment: .leading)
                        }
                        ForEach(Array(epg.channels.prefix(120))) { channel in
                            HStack(spacing: 0) {
                                Text(channel.name)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                    .frame(width: labelWidth - 10, alignment: .leading)
                                    .padding(.trailing, 10)
                                ZStack(alignment: .leading) {
                                    Rectangle()
                                        .fill(Color.red)
                                        .frame(width: 2)
                                        .offset(x: CGFloat(Date().timeIntervalSince(windowStart)) * pxPerSecond)
                                    ForEach(blocks(for: channel), id: \.programme.id) { block in
                                        Button {
                                            onPlay(channel)
                                        } label: {
                                            Text(block.programme.name)
                                                .font(.caption)
                                                .lineLimit(2)
                                                .multilineTextAlignment(.leading)
                                                .padding(.horizontal, 5)
                                                .frame(width: max(36, block.width), height: 40, alignment: .leading)
                                                .background(Color.accentColor.opacity(block.programme.isLive() ? 0.4 : 0.15),
                                                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                        }
                                        .buttonStyle(.plain)
                                        .offset(x: block.offset)
                                    }
                                }
                                .frame(width: totalWidth, height: 44, alignment: .leading)
                            }
                            .padding(.vertical, 2)
                            Divider().padding(.leading, labelWidth)
                        }
                    }
                    .padding(10)
                }
            }
        }
    }

    private struct Block {
        let programme: EPGProgramme
        let offset: CGFloat
        let width: CGFloat
    }

    private func blocks(for channel: EPGChannel) -> [Block] {
        let start = windowStart, end = windowEnd
        return channel.schedule.compactMap { prog in
            guard let s = prog.timeStart, let e = prog.timeEnd, e > start, s < end else { return nil }
            let cs = max(s, start), ce = min(e, end)
            return Block(programme: prog,
                         offset: CGFloat(cs.timeIntervalSince(start)) * pxPerSecond + 1,
                         width: CGFloat(ce.timeIntervalSince(cs)) * pxPerSecond - 2)
        }
    }
}
