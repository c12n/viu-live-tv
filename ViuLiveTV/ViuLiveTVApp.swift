//
//  ViuLiveTVApp.swift
//  Viu Live TV
//
//  App entry point. Creates the shared observable stores and injects them
//  into the environment. Sets the AVAudioSession category early so audio
//  keeps playing in PiP / background.
//

import SwiftUI
import AVFoundation

@main
struct ViuLiveTVApp: App {
    @State private var auth = AuthViewModel()
    @State private var epg = EPGStore()
    @State private var favorites = FavoritesStore()
    @State private var settings = AppSettings()
    @State private var parental = ParentalControls()

    init() {
        // Configure audio session up-front so PiP / AirPlay behave.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    /// CI harness: VIU_PLAYBACK_TEST=1 swaps in the playback test screen
    /// (see PlaybackTestView). Never set in normal use.
    private var playbackTestMode: Bool {
        ProcessInfo.processInfo.environment["VIU_PLAYBACK_TEST"] == "1"
    }

    var body: some Scene {
        WindowGroup {
            if playbackTestMode {
                PlaybackTestView()
                    .environment(auth)
                    .environment(epg)
                    .environment(favorites)
                    .environment(settings)
                    .environment(parental)
            } else {
                ContentView()
                    .environment(auth)
                    .environment(epg)
                    .environment(favorites)
                    .environment(settings)
                    .environment(parental)
            }
        }
    }
}
