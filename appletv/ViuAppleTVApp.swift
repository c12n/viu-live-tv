//
//  ViuAppleTVApp.swift
//  Viu Live TV — Apple TV
//
//  tvOS entry point. Shares the iOS app's data layer (APIClient,
//  Models, EPGStore, FavoritesStore, AppSettings, ParentalControls,
//  AuthViewModel, Keychain, LoginView) and swaps the touch UI for a
//  focus-first TV interface.
//

import SwiftUI
import AVFoundation

@main
struct ViuAppleTVApp: App {
    @State private var auth = AuthViewModel()
    @State private var epg = EPGStore()
    @State private var favorites = FavoritesStore()
    @State private var settings = AppSettings()
    @State private var parental = ParentalControls()

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environment(auth)
                .environment(epg)
                .environment(favorites)
                .environment(settings)
                .environment(parental)
        }
    }
}

/// Root gate — mirrors the iOS ContentView: boot → login →
/// subscription check → home.
/// Kids bedtime lock (2.0.0) for tvOS.
struct TVBedtimeView: View {
    @Environment(ParentalControls.self) private var parental
    @State private var showPIN = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 72))
                .foregroundStyle(.indigo)
            Text("Bedtime")
                .font(.largeTitle.weight(.bold))
            Text("Kids Mode is asleep for the night. It will be back in the morning.")
                .font(.title3)
                .foregroundStyle(.secondary)
            Button("Exit Kids Mode with PIN") { showPIN = true }
        }
        .sheet(isPresented: $showPIN) {
            TVPINEntryView(title: "Enter PIN to exit Kids Mode") { pin in
                guard let pin else { return true }
                if parental.verify(pin) {
                    parental.kidsModeEnabled = false
                    return true
                }
                return false
            }
        }
    }
}

struct TVRootView: View {
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
                        TVBedtimeView()
                    } else {
                        TVHomeView()
                    }
                case .inactive:
                    SubscriptionRequiredView()
                case .unknown:
                    SubscriptionCheckingView()
                }
            }
        }
        .onAppear {
            favoritesStore.switchProfile(to: settings.activeProfileID)
        }
        .animation(.default, value: auth.state)
        .preferredColorScheme(settings.appearance.colorScheme)
        .tint(settings.accent.color)
        .task {
            if auth.state == .signedIn { await auth.validateSession() }
        }
    }
}
