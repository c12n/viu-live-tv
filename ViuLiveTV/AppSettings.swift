//
//  AppSettings.swift
//  Viu Live TV
//
//  Persisted user preferences: appearance override, external-player choice,
//  stream quality preference. Observable so views update live.
//

import SwiftUI
import Observation

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

enum ExternalPlayerChoice: String, CaseIterable, Identifiable {
    case native, vlc, infuse, outplayer, nplayer, shareSheet

    var id: String { rawValue }

    var label: String {
        switch self {
        case .native:     return "Native (in-app)"
        case .vlc:        return "VLC"
        case .infuse:     return "Infuse"
        case .outplayer:  return "OutPlayer"
        case .nplayer:    return "nPlayer"
        case .shareSheet: return "Open In… (share sheet)"
        }
    }
}

enum StreamQuality: String, CaseIterable, Identifiable {
    case auto, high, medium, low
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

@Observable
final class AppSettings {
    var appearance: AppearanceMode {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Keys.appearance) }
    }
    var externalPlayer: ExternalPlayerChoice {
        didSet { UserDefaults.standard.set(externalPlayer.rawValue, forKey: Keys.externalPlayer) }
    }
    var streamQuality: StreamQuality {
        didSet { UserDefaults.standard.set(streamQuality.rawValue, forKey: Keys.streamQuality) }
    }

    private enum Keys {
        static let appearance = "viu_appearance_mode"
        static let externalPlayer = "viu_external_player"
        static let streamQuality = "viu_stream_quality"
    }

    init() {
        let d = UserDefaults.standard
        appearance     = AppearanceMode(rawValue: d.string(forKey: Keys.appearance) ?? "") ?? .system
        externalPlayer = ExternalPlayerChoice(rawValue: d.string(forKey: Keys.externalPlayer) ?? "") ?? .native
        streamQuality  = StreamQuality(rawValue: d.string(forKey: Keys.streamQuality) ?? "") ?? .auto
    }
}
