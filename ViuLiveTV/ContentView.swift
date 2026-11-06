//
//  ContentView.swift
//  Viu Live TV
//
//  Root view. Decides login vs. main UI, and adapts layout:
//   - iPhone:  NavigationStack, player pushed on top.
//   - iPad:    three-column NavigationSplitView — a navigation sidebar
//              (Channels / Favorites + the category list), the channel
//              list as the middle column, and the player as the detail.
//

import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(AuthViewModel.self) private var auth
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Group {
            switch auth.state {
            case .unknown:
                ProgressView().controlSize(.large)
            case .signedOut:
                LoginView()
            case .signedIn:
                // Subscription gate: an active subscription is required
                // to use the app.
                switch auth.subscriptionState {
                case .active:
                    MainView()
                case .inactive:
                    SubscriptionRequiredView()
                case .unknown:
                    SubscriptionCheckingView()
                }
            }
        }
        .animation(.default, value: auth.state)
        .preferredColorScheme(settings.appearance.colorScheme)
        .tint(settings.accent.color)
        .task {
            // A stored token may have been revoked since the last launch
            // (Viu revokes it when the account signs in elsewhere). Check
            // once per launch; only an explicit rejection signs out.
            if auth.state == .signedIn { await auth.validateSession() }
        }
    }
}

// MARK: - Main (post-login) UI

/// Extra-large mode (2.0.0): bumps the whole UI to a large
/// accessibility text size when enabled in Settings.
struct ExtraLargeModifier: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.dynamicTypeSize(.accessibility3)
        } else {
            content
        }
    }
}

/// Kids bedtime lock (2.0.0): shown instead of the channel UI while
/// Kids Mode is past its bedtime. The only way out is the parental
/// PIN, which exits Kids Mode.
struct BedtimeLockView: View {
    @Environment(ParentalControls.self) private var parental
    @State private var showPIN = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 64))
                .foregroundStyle(.indigo)
            Text("Bedtime")
                .font(.largeTitle.weight(.bold))
            Text("Kids Mode is asleep for the night. It will be back in the morning.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Exit Kids Mode with PIN") { showPIN = true }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showPIN) {
            PINEntryView(mode: .verify) { unlocked in
                if unlocked { parental.kidsModeEnabled = false }
            }
        }
    }
}

struct MainView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(FavoritesStore.self) private var favoritesStore
    @Environment(ParentalControls.self) private var parentalControls
    @State private var selection: EPGChannel?
    @State private var showSettings = false
    @State private var tab: ChannelTab = .all
    /// Selected category (tag parameter_name); nil = All. Owned here so
    /// the iPad sidebar and the channel list share one selection.
    @State private var selectedCategory: String?
    /// iPhone navigation path — the context menu's Play pushes through here.
    @State private var path: [EPGChannel] = []

    /// Layout is chosen by DEVICE, not by the current size class: on larger
    /// iPhones the horizontal size class flips to .regular in landscape,
    /// which used to swap layouts mid-stream and rebuild the whole view
    /// tree — tearing down the player so the stream restarted on every
    /// rotation. iPad always gets the split view; iPhone always the stack.
    private var useSplitLayout: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    var body: some View {
        Group {
            if parentalControls.isBedtimeActive() {
                BedtimeLockView()
            } else if useSplitLayout {
                splitLayout
            } else {
                stackLayout
            }
        }
        .modifier(ExtraLargeModifier(enabled: settings.extraLargeMode))
        .onAppear {
            // Keep the favorites store on the persisted active profile.
            favoritesStore.switchProfile(to: settings.activeProfileID)
        }
    }

    // iPad: three-column split view — navigation sidebar, channel
    // column, player detail. A proper iPad layout, not the phone list
    // stretched: the sidebar is a real navigation list (Channels /
    // Favorites + every category with its channel count), the middle
    // column is just for browsing channels, and the player gets the
    // whole detail area.
    private var splitLayout: some View {
        NavigationSplitView {
            IPadSidebarView(tab: $tab, category: $selectedCategory) {
                showSettings = true
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 275, max: 340)
        } content: {
            ChannelListView(selection: $selection, tab: $tab, isSidebar: true,
                            showsNavigationControls: false,
                            selectedCategory: $selectedCategory)
                .navigationSplitViewColumnWidth(min: 330, ideal: 410, max: 540)
                .toolbar { settingsToolbar }
        } detail: {
            NavigationStack {
                if let channel = selection {
                    PlayerView(channel: channel)
                        .id(channel.streamId)   // rebuild player per channel
                } else {
                    ContentUnavailableView("Select a Channel",
                                           systemImage: "play.tv",
                                           description: Text("Pick a channel from the list to start watching."))
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    // iPhone / compact: navigation stack, player pushed, YouTube-style
    // floating pill tab bar docked at the bottom of the channel list.
    private var stackLayout: some View {
        NavigationStack(path: $path) {
            ChannelListView(selection: $selection, tab: $tab,
                            onPlayRequest: { path.append($0) },
                            selectedCategory: $selectedCategory)
                .navigationDestination(for: EPGChannel.self) { channel in
                    PlayerView(channel: channel)
                }
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Spacer(minLength: 0)
                        FloatingTabBar(tab: $tab) { showSettings = true }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 2)
                }
        }
        // Tactile tick whenever a channel is opened (path push) — only
        // when haptics are enabled in Settings.
        .sensoryFeedback(trigger: path) { _, _ in
            settings.hapticsEnabled ? .impact(weight: .light) : nil
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    @ToolbarContentBuilder
    private var settingsToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
        }
    }
}

// MARK: - Floating tab bar (YouTube-style)

/// A floating pill tab bar like YouTube's: a dark glass capsule hovering
/// above the bottom edge, with the selected item highlighted by a filled
/// capsule. Items: Channels, Favorites, Settings (opens the sheet).
struct FloatingTabBar: View {
    @Environment(AppSettings.self) private var settings
    @Binding var tab: ChannelTab
    var onSettings: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            item(.all, icon: "play.tv.fill", label: "Channels")
            item(.favorites, icon: "heart.fill", label: "Favorites")
            Button(action: onSettings) {
                VStack(spacing: 2) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 18))
                    Text("Settings")
                        .font(.caption2.weight(.medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
        .padding(5)
        .frame(maxWidth: 430)
        .modifier(FloatingBarBackground())
        .shadow(color: .black.opacity(0.28), radius: 12, x: 0, y: 4)
    }

    private func item(_ target: ChannelTab, icon: String, label: String) -> some View {
        Button {
            tab = target
        } label: {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                Text(label)
                    .font(.caption2.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(tab == target ? settings.accent.color : Color.clear, in: Capsule())
            .foregroundStyle(tab == target ? Color.white : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - iPad sidebar

/// The iPad navigation sidebar: Channels / Favorites, the live TV
/// categories as a proper list with channel counts, and Settings.
/// Category filtering mirrors ChannelListView.displayTags (the server's
/// ALL/FAVORITES tags excluded, hidden categories excluded, Sports Mode
/// narrows to sports, saved order applied).
private struct IPadSidebarView: View {
    @Environment(EPGStore.self) private var epg
    @Environment(FavoritesStore.self) private var favorites
    @Environment(AppSettings.self) private var settings
    @Environment(ParentalControls.self) private var parental

    @Binding var tab: ChannelTab
    @Binding var category: String?
    var onSettings: () -> Void

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

    /// Channels per category, counted in one pass over the store's
    /// channel→categories map.
    private var categoryCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for params in epg.channelCategories.values {
            for param in params { counts[param, default: 0] += 1 }
        }
        return counts
    }

    var body: some View {
        List {
            Section {
                navRow(target: .all, icon: "play.tv.fill", title: "Channels")
                navRow(target: .favorites, icon: "heart.fill", title: "Favorites",
                       count: favorites.ids.count)
            }
            if tab == .all && !parental.kidsModeEnabled && !displayTags.isEmpty {
                Section("Categories") {
                    categoryRow(title: "All Categories", param: nil,
                                count: epg.channels.count)
                    ForEach(displayTags) { tag in
                        categoryRow(title: tag.displayName, param: tag.parameterName,
                                    count: categoryCounts[tag.parameterName] ?? 0)
                    }
                }
            }
            Section {
                Button {
                    onSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Viu Live TV")
    }

    private func navRow(target: ChannelTab, icon: String, title: String, count: Int? = nil) -> some View {
        let isSelected = tab == target
        return Button {
            tab = target
            if target == .favorites { category = nil }
        } label: {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                if let count {
                    Text("\(count)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fontWeight(isSelected ? .semibold : .regular)
        .listRowBackground(isSelected ? settings.accent.color.opacity(0.16) : nil)
        .accessibilityLabel(title)
    }

    private func categoryRow(title: String, param: String?, count: Int) -> some View {
        let isSelected = category == param
        return Button {
            tab = .all
            category = param
        } label: {
            HStack {
                Text(title)
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fontWeight(isSelected ? .semibold : .regular)
        .listRowBackground(isSelected ? settings.accent.color.opacity(0.16) : nil)
        .accessibilityLabel(title)
    }
}

/// Liquid Glass capsule on iOS 26+, dark material capsule before that.
private struct FloatingBarBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        }
    }
}
