//
//  ContentView.swift
//  Viu Live TV
//
//  Root view. Decides login vs. main UI, and adapts layout:
//   - iPhone (compact):  NavigationStack, player pushed on top.
//   - iPad (regular):    NavigationSplitView — sidebar channel list + detail/player.
//

import SwiftUI

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
                MainView()
            }
        }
        .animation(.default, value: auth.state)
        .preferredColorScheme(settings.appearance.colorScheme)
    }
}

// MARK: - Main (post-login) UI

struct MainView: View {
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var selection: EPGChannel?
    @State private var showSettings = false

    var body: some View {
        if hSize == .regular {
            splitLayout
        } else {
            stackLayout
        }
    }

    // iPad / large: two-column split view.
    private var splitLayout: some View {
        NavigationSplitView {
            ChannelListView(selection: $selection, isSidebar: true)
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

    // iPhone / compact: navigation stack, player pushed.
    private var stackLayout: some View {
        NavigationStack {
            ChannelListView(selection: $selection)
                .toolbar { settingsToolbar }
                .navigationDestination(for: EPGChannel.self) { channel in
                    PlayerView(channel: channel)
                }
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
