//
//  ChannelListView.swift
//  Viu Live TV
//
//  The first screen after login: channel list with search, category chips
//  (the server's live TV categories / tags), pull-to-refresh, and per-row
//  play / favorite / open-external actions. The All Channels | Favorites
//  switch lives in the floating bottom tab bar (iPhone). On iPad the tab
//  and category selection live in the split view's navigation sidebar
//  (see ContentView), so this list runs there with its own navigation
//  controls hidden.
//
//  On iPhone this is pushed in a NavigationStack. On iPad it is the
//  middle (content) column of a three-column NavigationSplitView, and
//  selecting a channel sets the detail column to the player.
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
    @Environment(ParentalControls.self) private var parental

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
    /// Hide the built-in segmented tab picker + category chips. On iPad
    /// the split view's sidebar owns navigation (tab + category), so the
    /// content column runs with this off.
    var showsNavigationControls: Bool = true

    @State private var search = ""
    /// Selected live TV category (tag parameter_name); nil = All.
    /// A binding owned by the caller (MainView, or the player's guide
    /// sheet) so the iPad sidebar and this list share one selection.
    @Binding var selectedCategory: String?

    // External-player alert state.
    @State private var externalAlert: ExternalAlert?

    // Timeline guide (2.0.0).
    @State private var showGuide = false

    // Parental-controls PIN gate state.
    @State private var showPIN = false
    @State private var pendingUnlock: (() -> Void)?

    struct ExternalAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    /// Recently watched channels (from Settings' history), passed
    /// through the same Kids / language visibility rules as the list.
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

    private func recentChip(_ channel: EPGChannel) -> some View {
        Button {
            play(channel)
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                    if let url = channel.logoURL {
                        AsyncImage(url: url) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFit().padding(5)
                            } else {
                                Image(systemName: "tv").foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Image(systemName: "tv").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(channel.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 84)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Recent: \(channel.name)")
    }

    private var visibleChannels: [EPGChannel] {
        var result: [EPGChannel]
        // Kids Mode wins over everything: only the Kids category,
        // in the Favorites tab too (favorites are intersected with it).
        if parental.kidsModeEnabled {
            let kids = epg.filtered(search: search, category: "KIDS")
            switch tab {
            case .all:       result = kids
            case .favorites: result = kids.filter { favorites.isFavorite($0.streamId) }
            }
        } else {
            var base = epg.filtered(search: search, category: selectedCategory)
            // Sports Mode with no category picked shows every sports channel.
            if settings.sportsModeEnabled && selectedCategory == nil {
                base = base.filter { epg.isSports($0) }
            }
            switch tab {
            case .all:       result = base
            case .favorites: result = base.filter { favorites.isFavorite($0.streamId) }
            }
        }
        // Settings language filter composes with every mode above.
        if !settings.languageFilter.isEmpty {
            result = result.filter { $0.language.code == settings.languageFilter }
        }
        // Favorites show in the user's order, pinned first (2.0.0).
        if tab == .favorites {
            result = favorites.orderedChannels(from: result)
        }
        return result
    }

    // MARK: 2.0.0 home sections (jump back in / sports / groups)

    /// The most recent channel, if it was watched within 3 hours and
    /// its current programme still has time left.
    private var jumpBackChannel: EPGChannel? {
        guard tab == .all, search.isEmpty, !parental.kidsModeEnabled,
              let id = settings.recentChannelIDs.first,
              let at = settings.recentWatchedAt[id],
              Date().timeIntervalSince(at) < 3 * 3600,
              let channel = epg.channel(for: id),
              let now = channel.nowProgramme(),
              let left = now.minutesLeft(), left > 5
        else { return nil }
        return channel
    }

    @ViewBuilder
    private var jumpBackSection: some View {
        if let channel = jumpBackChannel, let now = channel.nowProgramme() {
            Section {
                Button {
                    play(channel)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "play.circle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(settings.accent.color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Jump back in")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(settings.accent.color)
                            Text(channel.name)
                                .font(.headline)
                                .lineLimit(1)
                            Text("\(now.name) · \(now.minutesLeft() ?? 0) min left")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var sportsRailSection: some View {
        if tab == .all && search.isEmpty && !parental.kidsModeEnabled {
            let live = epg.liveSportsChannels().filter {
                settings.languageFilter.isEmpty || $0.language.code == settings.languageFilter
            }
            if !live.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(live) { channel in
                                recentChip(channel)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowInsets(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 14))
                } header: {
                    Text("Live Sports Now")
                }
            }
        }
    }

    @ViewBuilder
    private var customGroupSections: some View {
        if tab == .all && search.isEmpty && selectedCategory == nil && !parental.kidsModeEnabled {
            ForEach(settings.activeGroups) { group in
                let channels = group.channelIDs
                    .compactMap { epg.channel(for: $0) }
                    .filter { settings.languageFilter.isEmpty || $0.language.code == settings.languageFilter }
                if !channels.isEmpty {
                    Section {
                        ForEach(channels) { channel in
                            row(for: channel)
                                .listRowInsets(EdgeInsets(top: 1, leading: 14, bottom: 1, trailing: 14))
                        }
                    } header: {
                        Text(group.name)
                    }
                }
            }
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

            jumpBackSection

            if tab == .all && search.isEmpty && !recentChannels.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(recentChannels) { channel in
                                recentChip(channel)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowInsets(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 14))
                } header: {
                    Text("Recently Watched")
                }
            }

            sportsRailSection

            customGroupSections

            Section {
                if visibleChannels.isEmpty {
                    emptyStateView
                } else {
                    ForEach(visibleChannels) { channel in
                        row(for: channel)
                            .tag(channel)        // for sidebar selection
                            .listRowInsets(EdgeInsets(top: 1, leading: 14, bottom: 1, trailing: 14))
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                let isFav = favorites.isFavorite(channel.streamId)
                                Button {
                                    Haptics.medium()
                                    favorites.toggle(channel)
                                } label: {
                                    Label(isFav ? "Unfavorite" : "Favorite",
                                          systemImage: isFav ? "heart.slash" : "heart.fill")
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showGuide = true
                } label: {
                    Image(systemName: "calendar")
                }
                .accessibilityLabel("Programme Guide")
            }
        }
        .sheet(isPresented: $showGuide) {
            GuideGridView { channel in
                showGuide = false
                play(channel)
            }
        }
        .sheet(isPresented: $showPIN) {
            PINEntryView(mode: .verify) { unlocked in
                if unlocked { pendingUnlock?() }
                pendingUnlock = nil
            }
        }
        .task {
            settings.pruneReminders()
            if epg.usingFallback { await epg.refresh() }
            await favorites.reconcileWithServer()
        }
        .onChange(of: settings.sportsModeEnabled) { _, on in
            // A selected non-sports category disappears in Sports Mode.
            if on, let selectedCategory, !EPGStore.isSportsCategory(selectedCategory) {
                self.selectedCategory = nil
            }
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

    // MARK: Empty state (2.0.0 — extracted so the List body type-checks fast)

    private var emptyStateView: some View {
        let isFavorites = (tab == .favorites)
        let title = isFavorites ? "No Favorites Yet" : "No Channels"
        let icon = isFavorites ? "heart" : "tv"
        let message = isFavorites
            ? "Tap the heart on any channel to add it here."
            : "Try refreshing or adjusting your search."
        return ContentUnavailableView(title, systemImage: icon, description: Text(message))
    }

    // MARK: Top inset (iPad picker + category chips)

    private var topInset: some View {
        VStack(spacing: 0) {
            if showsNavigationControls {
                if isSidebar {
                    Picker("View", selection: $tab) {
                        ForEach(ChannelTab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                if tab == .all && !displayTags.isEmpty && !epg.usingFallback && !parental.kidsModeEnabled {
                    categoryChips
                }
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
            && !epg.isCategoryHidden(tag.parameterName)
            && (!settings.sportsModeEnabled || EPGStore.isSportsCategory(tag.parameterName)) {
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
        ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(title: "All", isSelected: selectedCategory == nil) {
                    selectedCategory = nil
                }
                .id("chip-all")
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
                    .id("chip-\(tag.parameterName)")
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
        .onChange(of: selectedCategory) { _, newValue in
            // Keep the selected chip visible after swiping categories.
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(newValue.map { "chip-\($0)" } ?? "chip-all", anchor: .center)
            }
        }
        }
    }

    private func chip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .glassControl(cornerRadius: 999, tint: isSelected ? settings.accent.color : nil)
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
            tapToPlay: isSidebar,
            isLocked: parental.isEnabled && parental.isLocked(channel.streamId),
            isPinned: favorites.isPinned(channel.streamId),
            onTogglePin: favorites.isFavorite(channel.streamId)
                ? { favorites.setPinned(channel.streamId, !favorites.isPinned(channel.streamId)) } : nil,
            onMoveUp: tab == .favorites && favorites.isFavorite(channel.streamId)
                ? { favorites.moveUp(channel.streamId) } : nil,
            onMoveDown: tab == .favorites && favorites.isFavorite(channel.streamId)
                ? { favorites.moveDown(channel.streamId) } : nil,
            groupItems: settings.activeGroups.map {
                (group: $0, isMember: settings.groupContains($0.id, streamID: channel.streamId))
            },
            onToggleGroup: { group in
                settings.setInGroup(group.id, streamID: channel.streamId,
                                    member: !settings.groupContains(group.id, streamID: channel.streamId))
            }
        )

        if let onChannelPicked {
            // Channel guide over the player: tap picks, no navigation.
            rowContent
                .contentShape(Rectangle())
                .onTapGesture {
                    gate(channel) { onChannelPicked(channel) }
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
                        favoriteButtonInteractive: false,
                        isLocked: parental.isEnabled && parental.isLocked(channel.streamId),
                        isPinned: favorites.isPinned(channel.streamId)
                    )
                }
                .buttonStyle(.plain)

                Button {
                    Haptics.medium()
                    favorites.toggle(channel)
                } label: {
                    Image(systemName: favorites.isFavorite(channel.streamId) ? "heart.fill" : "heart")
                        .foregroundStyle(favorites.isFavorite(channel.streamId) ? Color.yellow : Color.secondary)
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(favorites.isFavorite(channel.streamId) ? "Remove from favorites" : "Add to favorites")
            }
        }
    }

    private func play(_ channel: EPGChannel) {
        gate(channel) { playImmediately(channel) }
    }

    private func playImmediately(_ channel: EPGChannel) {
        Haptics.light()
        if isSidebar {
            selection = channel
        } else if let onPlayRequest {
            onPlayRequest(channel)
        } else {
            selection = channel
        }
    }

    /// Parental gate: a locked channel asks for the PIN first; the
    /// action runs only after a correct entry.
    private func gate(_ channel: EPGChannel, action: @escaping () -> Void) {
        if parental.isEnabled && parental.isLocked(channel.streamId) {
            pendingUnlock = action
            showPIN = true
        } else {
            action()
        }
    }

    // NOTE: there is deliberately no swipe-to-switch-category gesture
    // on the list anymore (removed in v1.3.1 at the user's report): the
    // simultaneous drag kept hijacking ordinary channel scrolling —
    // diagonal scrolls and flicks jumped categories mid-browse.
    // Categories switch by tapping the chips, which are larger now.

    private func openExternal(_ channel: EPGChannel) {
        gate(channel) { openExternalImmediately(channel) }
    }

    private func openExternalImmediately(_ channel: EPGChannel) {
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

// MARK: - Timeline guide grid (2.0.0)

/// A classic timeline guide: channels as rows, the next 6 hours as a
/// horizontal timeline, programme blocks sized by duration. Tapping a
/// block opens its detail (Play / Remind Me / Favorite).
struct GuideGridView: View {
    @Environment(EPGStore.self) private var epg
    @Environment(AppSettings.self) private var settings
    @Environment(FavoritesStore.self) private var favorites
    @Environment(ParentalControls.self) private var parental
    @Environment(\.dismiss) private var dismiss

    var onPlay: (EPGChannel) -> Void

    @State private var detail: GuideDetail?

    struct GuideDetail: Identifiable {
        let id = UUID()
        let channel: EPGChannel
        let programme: EPGProgramme
    }

    private let hoursShown = 6
    private let pxPerSecond: CGFloat = 0.052
    private var totalWidth: CGFloat { CGFloat(hoursShown * 3600) * pxPerSecond }
    private let labelWidth: CGFloat = 128

    private var windowStart: Date {
        let now = Date()
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: now)
        return cal.date(from: comps) ?? now
    }
    private var windowEnd: Date { windowStart.addingTimeInterval(TimeInterval(hoursShown * 3600)) }

    private var guideChannels: [EPGChannel] {
        var result = epg.channels
        if parental.kidsModeEnabled {
            result = result.filter { epg.channelCategories[$0.streamId]?.contains("KIDS") == true }
        }
        if settings.sportsModeEnabled {
            result = result.filter { epg.isSports($0) }
        }
        if !settings.languageFilter.isEmpty {
            result = result.filter { $0.language.code == settings.languageFilter }
        }
        return Array(result.prefix(120))
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical) {
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        headerRow
                        ForEach(guideChannels) { channel in
                            channelRow(channel)
                            Divider().padding(.leading, labelWidth)
                        }
                        if guideChannels.count >= 120 {
                            Text("Showing the first 120 channels")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(10)
                        }
                    }
                }
            }
            .navigationTitle("Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $detail) { d in
                detailView(d)
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: labelWidth, height: 22)
            ZStack(alignment: .leading) {
                ForEach(0..<hoursShown, id: \.self) { h in
                    Text(windowStart.addingTimeInterval(TimeInterval(h * 3600))
                        .formatted(date: .omitted, time: .shortened))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .offset(x: CGFloat(h * 3600) * pxPerSecond + 4)
                }
            }
            .frame(width: totalWidth, height: 22, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    private func channelRow(_ channel: EPGChannel) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                if let url = channel.logoURL {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFit()
                        } else {
                            Image(systemName: "tv").foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 30, height: 30)
                }
                Text(channel.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
            }
            .frame(width: labelWidth - 8, alignment: .leading)
            .padding(.trailing, 8)

            ZStack(alignment: .leading) {
                // "Now" line.
                Rectangle()
                    .fill(Color.red)
                    .frame(width: 2)
                    .offset(x: CGFloat(Date().timeIntervalSince(windowStart)) * pxPerSecond)
                ForEach(blocks(for: channel), id: \.programme.id) { block in
                    Button {
                        detail = GuideDetail(channel: channel, programme: block.programme)
                    } label: {
                        Text(block.programme.name)
                            .font(.caption2)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 5)
                            .frame(width: max(30, block.width), height: 44, alignment: .leading)
                            .background(
                                settings.accent.color.opacity(block.programme.isLive() ? 0.4 : 0.16),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .offset(x: block.offset)
                }
            }
            .frame(width: totalWidth, height: 48, alignment: .leading)
        }
        .padding(.vertical, 3)
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
            let clampedStart = max(s, start), clampedEnd = min(e, end)
            return Block(
                programme: prog,
                offset: CGFloat(clampedStart.timeIntervalSince(start)) * pxPerSecond + 1,
                width: CGFloat(clampedEnd.timeIntervalSince(clampedStart)) * pxPerSecond - 2
            )
        }
    }

    private func detailView(_ d: GuideDetail) -> some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(d.programme.name)
                            .font(.title3.weight(.bold))
                        Text(d.channel.name)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let s = d.programme.timeStart, let e = d.programme.timeEnd {
                            Text("\(s.formatted(date: .omitted, time: .shortened)) – \(e.formatted(date: .omitted, time: .shortened))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if !d.programme.description.isEmpty {
                            Text(d.programme.description)
                                .font(.body)
                                .padding(.top, 2)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    Button {
                        detail = nil
                        onPlay(d.channel)
                    } label: {
                        Label("Play \(d.channel.name)", systemImage: "play.fill")
                    }
                    Button {
                        favorites.toggle(d.channel)
                    } label: {
                        Label(favorites.isFavorite(d.channel.streamId) ? "Remove Favorite" : "Favorite",
                              systemImage: favorites.isFavorite(d.channel.streamId) ? "heart.fill" : "heart")
                    }
                    if let start = d.programme.timeStart, start > Date() {
                        let reminded = settings.hasReminder(streamID: d.channel.streamId, start: start)
                        Button {
                            Task {
                                await settings.setReminder(channel: d.channel,
                                                           programme: d.programme,
                                                           enabled: !reminded)
                            }
                        } label: {
                            Label(reminded ? "Cancel Reminder" : "Remind Me",
                                  systemImage: reminded ? "bell.slash" : "bell")
                        }
                    }
                }
            }
            .navigationTitle("Programme")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { detail = nil }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
