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

/// Accent colors for the UI (and the matching app icon). A curated set:
/// every option is a mid-tone chosen to stay clearly visible in both
/// Light and Dark mode — each has a slightly deeper Light-mode variant
/// and a brighter Dark-mode variant for contrast.
enum AccentChoice: String, CaseIterable, Identifiable {
    case red, blue, purple, pink, orange, green, teal
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    /// Alternate app icon name for this accent (nil = the primary icon).
    var iconName: String? {
        self == .red ? nil : "AppIcon\(rawValue.capitalized)"
    }

    var color: Color {
        switch self {
        case .red:    return Self.dynamic(light: 0xD70015, dark: 0xFF424D)
        case .blue:   return Self.dynamic(light: 0x0057D9, dark: 0x409CFF)
        case .purple: return Self.dynamic(light: 0x6C2BD9, dark: 0xBF5AF2)
        case .pink:   return Self.dynamic(light: 0xD81B60, dark: 0xFF6482)
        case .orange: return Self.dynamic(light: 0xE8590C, dark: 0xFF9F0A)
        case .green:  return Self.dynamic(light: 0x178A43, dark: 0x30D158)
        case .teal:   return Self.dynamic(light: 0x087F8C, dark: 0x38B2C6)
        }
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: 1)
        })
    }
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
    /// Keep audio playing when the app is backgrounded / the screen locks.
    var backgroundPlayEnabled: Bool {
        didSet { UserDefaults.standard.set(backgroundPlayEnabled, forKey: Keys.backgroundPlay) }
    }
    /// Allow Picture in Picture (including auto-PiP when leaving the app).
    var pictureInPictureEnabled: Bool {
        didSet { UserDefaults.standard.set(pictureInPictureEnabled, forKey: Keys.pictureInPicture) }
    }
    /// Tactile feedback on taps and gestures (Settings toggle).
    var hapticsEnabled: Bool {
        didSet { UserDefaults.standard.set(hapticsEnabled, forKey: Keys.haptics) }
    }
    /// UI accent color (Settings picker). Also switches the app icon.
    var accent: AccentChoice {
        didSet { UserDefaults.standard.set(accent.rawValue, forKey: Keys.accent) }
    }
    /// Sports Mode: only sports categories are shown (Settings toggle,
    /// default OFF, no PIN). Kids Mode takes precedence while it's on.
    var sportsModeEnabled: Bool {
        didSet { UserDefaults.standard.set(sportsModeEnabled, forKey: Keys.sportsMode) }
    }

    private enum Keys {
        static let appearance = "viu_appearance_mode"
        static let externalPlayer = "viu_external_player"
        static let streamQuality = "viu_stream_quality"
        static let backgroundPlay = "viu_background_play"
        static let pictureInPicture = "viu_pip_enabled"
        static let haptics = "viu_haptics_enabled"
        static let accent = "viu_accent_choice"
        static let sportsMode = "viu_sports_mode"
    }

    init() {
        let d = UserDefaults.standard
        appearance     = AppearanceMode(rawValue: d.string(forKey: Keys.appearance) ?? "") ?? .system
        externalPlayer = ExternalPlayerChoice(rawValue: d.string(forKey: Keys.externalPlayer) ?? "") ?? .native
        streamQuality  = StreamQuality(rawValue: d.string(forKey: Keys.streamQuality) ?? "") ?? .auto
        backgroundPlayEnabled   = d.object(forKey: Keys.backgroundPlay) as? Bool ?? true
        pictureInPictureEnabled = d.object(forKey: Keys.pictureInPicture) as? Bool ?? true
        hapticsEnabled          = d.object(forKey: Keys.haptics) as? Bool ?? true
        accent                  = AccentChoice(rawValue: d.string(forKey: Keys.accent) ?? "") ?? .red
        sportsModeEnabled       = d.bool(forKey: Keys.sportsMode)
    }
}

// MARK: - Parental controls

/// Parental controls: an on/off toggle (default OFF), a 4-digit PIN in
/// the Keychain, and a set of locked channel IDs. Locked channels ask
/// for the PIN before they play. Signing out resets everything (the
/// documented PIN recovery).
@Observable
final class ParentalControls {
    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.enabled) }
    }
    /// Kids Mode: the app shows only the Kids category. Default OFF.
    /// Turning it off requires the parental PIN.
    var kidsModeEnabled: Bool {
        didSet { UserDefaults.standard.set(kidsModeEnabled, forKey: Keys.kidsMode) }
    }
    private(set) var lockedIDs: Set<Int>
    private var resetObserver: NSObjectProtocol?

    private enum Keys {
        static let enabled = "viu_parental_enabled"
        static let locked = "viu_locked_channel_ids"
        static let kidsMode = "viu_kids_mode"
        static let pinAccount = "parental_pin"
        static let resetCode = "viu_pin_reset_code"
        static let resetCodeAt = "viu_pin_reset_code_at"
    }

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Keys.enabled)
        kidsModeEnabled = UserDefaults.standard.bool(forKey: Keys.kidsMode)
        lockedIDs = Set(UserDefaults.standard.array(forKey: Keys.locked) as? [Int] ?? [])
        resetObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("ViuParentalReset"), object: nil, queue: .main
        ) { [weak self] _ in self?.reloadFromStorage() }
    }

    private func reloadFromStorage() {
        isEnabled = UserDefaults.standard.bool(forKey: Keys.enabled)
        kidsModeEnabled = UserDefaults.standard.bool(forKey: Keys.kidsMode)
        lockedIDs = Set(UserDefaults.standard.array(forKey: Keys.locked) as? [Int] ?? [])
    }

    /// The PIN every install starts with. It is also the PIN after an
    /// uninstall (a fresh install has nothing stored) and after a reset.
    static let defaultPIN = "0000"

    var hasCustomPIN: Bool { Keychain.shared.get(account: Keys.pinAccount) != nil }
    var isDefaultPIN: Bool { !hasCustomPIN }

    func setPIN(_ pin: String) { Keychain.shared.set(pin, account: Keys.pinAccount) }

    /// The PIN that currently works: the stored one, or the default
    /// 0000 when none was ever set on this install.
    private var effectivePIN: String {
        Keychain.shared.get(account: Keys.pinAccount) ?? Self.defaultPIN
    }

    func verify(_ pin: String) -> Bool { effectivePIN == pin }

    // MARK: Forgot-PIN reset codes

    /// Generates a 6-digit reset code (valid 10 minutes). The PIN screen
    /// emails it to the Viu account email; entering it resets the PIN
    /// back to the default 0000.
    func requestResetCode() -> String {
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        UserDefaults.standard.set(code, forKey: Keys.resetCode)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Keys.resetCodeAt)
        return code
    }

    func verifyResetCode(_ code: String) -> Bool {
        guard let stored = UserDefaults.standard.string(forKey: Keys.resetCode) else { return false }
        let age = Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: Keys.resetCodeAt)
        return stored == code && age < 600
    }

    func clearResetCode() {
        UserDefaults.standard.removeObject(forKey: Keys.resetCode)
        UserDefaults.standard.removeObject(forKey: Keys.resetCodeAt)
    }

    /// Back to the factory default (deleting the stored PIN makes the
    /// effective PIN 0000 again).
    func resetPINToDefault() {
        Keychain.shared.delete(account: Keys.pinAccount)
        clearResetCode()
    }

    func isLocked(_ streamID: Int) -> Bool { lockedIDs.contains(streamID) }

    func setLocked(_ streamID: Int, locked: Bool) {
        if locked { lockedIDs.insert(streamID) } else { lockedIDs.remove(streamID) }
        UserDefaults.standard.set(Array(lockedIDs), forKey: Keys.locked)
    }

    /// Full reset (used on sign-out): controls off, locks cleared, PIN gone.
    static func clearStorage() {
        UserDefaults.standard.set(false, forKey: Keys.enabled)
        UserDefaults.standard.set(false, forKey: Keys.kidsMode)
        UserDefaults.standard.removeObject(forKey: Keys.locked)
        Keychain.shared.delete(account: Keys.pinAccount)
        NotificationCenter.default.post(name: Notification.Name("ViuParentalReset"), object: nil)
    }
}
