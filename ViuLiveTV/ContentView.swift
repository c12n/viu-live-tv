//
//  ContentView.swift
//  Viu Live TV
//
//  Root view. Decides login vs. main UI, and adapts layout:
//   - iPhone (compact):  NavigationStack, player pushed on top.
//   - iPad (regular):    NavigationSplitView — sidebar channel list + detail/player.
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

struct MainView: View {
    @Environment(AppSettings.self) private var settings
    @State private var selection: EPGChannel?
    @State private var showSettings = false
    @State private var tab: ChannelTab = .all
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
        if useSplitLayout {
            splitLayout
        } else {
            stackLayout
        }
    }

    // iPad / large: two-column split view.
    private var splitLayout: some View {
        NavigationSplitView {
            ChannelListView(selection: $selection, tab: $tab, isSidebar: true)
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
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    // iPhone / compact: navigation stack, player pushed, YouTube-style
    // floating pill tab bar docked at the bottom of the channel list.
    private var stackLayout: some View {
        NavigationStack(path: $path) {
            ChannelListView(selection: $selection, tab: $tab,
                            onPlayRequest: { path.append($0) })
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
