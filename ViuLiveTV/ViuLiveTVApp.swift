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

    init() {
        // Configure audio session up-front so PiP / AirPlay behave.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(auth)
                .environment(epg)
                .environment(favorites)
                .environment(settings)
        }
    }
}
