//
//  ViuMacApp.swift
//  Viu Live TV — macOS
//
//  Mac entry point. Shares the iOS app's data layer (APIClient,
//  Models, EPGStore, FavoritesStore, AppSettings, ParentalControls,
//  AuthViewModel, Keychain, LoginView) with a native Mac interface:
//  sidebar + channel grid + player detail, plus a Settings scene.
//

import SwiftUI

@main
struct ViuMacApp: App {
    @State private var auth = AuthViewModel()
    @State private var epg = EPGStore()
    @State private var favorites = FavoritesStore()
    @State private var settings = AppSettings()
    @State private var parental = ParentalControls()

    var body: some Scene {
        WindowGroup {
            MacRootView()
                .environment(auth)
                .environment(epg)
                .environment(favorites)
                .environment(settings)
                .environment(parental)
                .frame(minWidth: 1080, minHeight: 680)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(
                        name: Notification.Name("ViuOpenSettings"), object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        Settings {
            MacSettingsView()
                .environment(auth)
                .environment(epg)
                .environment(favorites)
                .environment(settings)
                .environment(parental)
        }
    }
}

/// Extra-large mode (2.0.0) for macOS.
struct MacExtraLargeModifier: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        content.environment(\.dynamicTypeSize, enabled ? .accessibility3 : .large)
    }
}

/// Kids bedtime lock (2.0.0) for macOS.
struct MacBedtimeView: View {
    @Environment(ParentalControls.self) private var parental
    @State private var showPIN = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 54))
                .foregroundStyle(.indigo)
            Text("Bedtime")
                .font(.largeTitle.weight(.bold))
            Text("Kids Mode is asleep for the night. It will be back in the morning.")
                .foregroundStyle(.secondary)
            Button("Exit Kids Mode with PIN") { showPIN = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showPIN) {
            MacPINEntryView(title: "Enter PIN to exit Kids Mode") { pin in
                showPIN = false
                if let pin, parental.verify(pin) {
                    parental.kidsModeEnabled = false
                }
            }
            .frame(width: 340)
        }
    }
}

/// Root gate — mirrors the iOS ContentView: boot → login →
/// subscription check → home.
struct MacRootView: View {
    @Environment(AuthViewModel.self) private var auth
    @Environment(AppSettings.self) private var settings
    @Environment(FavoritesStore.self) private var favoritesStore
    @Environment(ParentalControls.self) private var parentalControls

    var body: some View {
        Group {
            switch auth.state {
            case .unknown:
                ProgressView().controlSize(.large)
            case .signedOut:
                LoginView()
            case .signedIn:
                switch auth.subscriptionState {
                case .active:
                    if parentalControls.isBedtimeActive() {
                        MacBedtimeView()
                    } else {
                        MacHomeView()
                    }
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
        .modifier(MacExtraLargeModifier(enabled: settings.extraLargeMode))
        .task {
            if auth.state == .signedIn { await auth.validateSession() }
        }
        .onAppear {
            favoritesStore.switchProfile(to: settings.activeProfileID)
        }
    }
}
