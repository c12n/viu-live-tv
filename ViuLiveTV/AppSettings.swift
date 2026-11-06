//
//  AppSettings.swift
//  Viu Live TV
//
//  Persisted user preferences: appearance override, external-player choice,
//  stream quality preference. Observable so views update live.
//

import SwiftUI
import Observation
import UserNotifications
#if os(macOS)
import AppKit
#endif

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
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? dark : light
            return NSColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: 1)
        })
        #else
        return Color(UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: 1)
        })
        #endif
    }
}

/// A viewer profile (2.0.0). Each profile keeps its own favorites,
/// recents and custom groups. The first profile is the "main" one: its
/// favorites are the ones that sync with the Viu account on the server;
/// other profiles are local-only.
struct ViewerProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// SF Symbol name shown next to the profile.
    var symbol: String = "person.fill"
}

/// A user-built channel group (2.0.0), belonging to one profile.
struct CustomGroup: Codable, Identifiable, Equatable {
    var id: UUID
    var profileID: UUID
    var name: String
    var channelIDs: [Int] = []
}

/// App-wide sleep timer (2.0.0). Players observe the fire notification
/// and pause. Lives in AppSettings.swift so every platform target can
/// share it without project-file changes.
@Observable
final class SleepTimer {
    static let shared = SleepTimer()
    static let firedNotification = Notification.Name("ViuSleepTimerFired")

    private(set) var endDate: Date?
    private var timer: Timer?

    var isActive: Bool { endDate != nil }

    var remainingText: String? {
        guard let endDate else { return nil }
        let secs = max(0, Int(endDate.timeIntervalSinceNow))
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }

    func start(minutes: Int) {
        cancel()
        guard minutes > 0 else { return }
        let fireDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
        endDate = fireDate
        let t = Timer(fireAt: fireDate, interval: 0, repeats: false) { [weak self] _ in
            self?.endDate = nil
            NotificationCenter.default.post(name: Self.firedNotification, object: nil)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        endDate = nil
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
    /// Channel language filter: "" shows every language; otherwise a
    /// language code ("en", "fr", "ar", …) from ChannelLanguage.
    var languageFilter: String {
        didSet { UserDefaults.standard.set(languageFilter, forKey: Keys.languageFilter) }
    }
    /// Recently watched channel stream IDs, most recent first (max 12).
    var recentChannelIDs: [Int] {
        didSet { UserDefaults.standard.set(recentChannelIDs, forKey: Keys.recents) }
    }
    /// Extra-large mode (2.0.0): supersize text and rows app-wide.
    var extraLargeMode: Bool {
        didSet { UserDefaults.standard.set(extraLargeMode, forKey: Keys.extraLarge) }
    }
    /// Viewer profiles (2.0.0). The first entry is the main profile.
    var profiles: [ViewerProfile] {
        didSet { persistProfiles() }
    }
    /// The active profile's id (2.0.0).
    var activeProfileID: UUID {
        didSet { UserDefaults.standard.set(activeProfileID.uuidString, forKey: Keys.activeProfile) }
    }
    /// Custom channel groups across all profiles (2.0.0).
    var customGroups: [CustomGroup] {
        didSet { persistGroups() }
    }
    /// Recents for non-active profiles (2.0.0); the active profile's
    /// recents live in `recentChannelIDs` as before.
    private var recentsByProfile: [String: [Int]] {
        didSet {
            if let data = try? JSONEncoder().encode(recentsByProfile) {
                UserDefaults.standard.set(data, forKey: Keys.recentsByProfile)
            }
        }
    }

    /// Pending "Remind Me" notification identifiers
    /// ("viu-remind-<streamID>-<startEpoch>").
    private(set) var reminderIDs: Set<String> {
        didSet { UserDefaults.standard.set(Array(reminderIDs), forKey: Keys.reminders) }
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
        static let languageFilter = "viu_language_filter"
        static let recents = "viu_recent_channels"
        static let reminders = "viu_programme_reminders"
        static let extraLarge = "viu_extra_large_mode"
        static let profiles = "viu_profiles"
        static let activeProfile = "viu_active_profile"
        static let groups = "viu_custom_groups"
        static let recentsByProfile = "viu_recents_by_profile"
    }

    /// The main profile always uses this fixed id so its UserDefaults
    /// keys (favorites etc.) stay the legacy unsuffixed ones.
    static let mainProfileID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

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
        languageFilter          = d.string(forKey: Keys.languageFilter) ?? ""
        recentChannelIDs        = d.array(forKey: Keys.recents) as? [Int] ?? []
        reminderIDs             = Set(d.array(forKey: Keys.reminders) as? [String] ?? [])
        extraLargeMode          = d.bool(forKey: Keys.extraLarge)
        if let data = d.data(forKey: Keys.profiles),
           let decoded = try? JSONDecoder().decode([ViewerProfile].self, from: data),
           !decoded.isEmpty {
            profiles = decoded
        } else {
            profiles = [ViewerProfile(id: Self.mainProfileID, name: "Main", symbol: "person.fill")]
        }
        if let raw = d.string(forKey: Keys.activeProfile), let uuid = UUID(uuidString: raw),
           profiles.contains(where: { $0.id == uuid }) {
            activeProfileID = uuid
        } else {
            activeProfileID = profiles[0].id
        }
        if let data = d.data(forKey: Keys.groups),
           let decoded = try? JSONDecoder().decode([CustomGroup].self, from: data) {
            customGroups = decoded
        } else {
            customGroups = []
        }
        if let stored = d.dictionary(forKey: "viu_recent_watched_at") as? [String: Double] {
            recentWatchedAt = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
                Int(key).map { ($0, Date(timeIntervalSince1970: value)) }
            })
        }
        if let data = d.data(forKey: Keys.recentsByProfile),
           let decoded = try? JSONDecoder().decode([String: [Int]].self, from: data) {
            recentsByProfile = decoded
        } else {
            recentsByProfile = [:]
        }
    }

    // MARK: Profiles (2.0.0)

    var activeProfile: ViewerProfile {
        profiles.first { $0.id == activeProfileID } ?? profiles[0]
    }

    var isMainProfileActive: Bool { activeProfileID == profiles[0].id }

    /// Switch the active profile: parks the current profile's recents
    /// and loads the new profile's. Callers must also switch the
    /// FavoritesStore (the root views do both together).
    func switchProfile(to id: UUID) {
        guard id != activeProfileID, profiles.contains(where: { $0.id == id }) else { return }
        recentsByProfile[activeProfileID.uuidString] = recentChannelIDs
        activeProfileID = id
        recentChannelIDs = recentsByProfile[id.uuidString] ?? []
    }

    @discardableResult
    func addProfile(name: String, symbol: String = "person.fill") -> ViewerProfile {
        let profile = ViewerProfile(id: UUID(), name: name, symbol: symbol)
        profiles.append(profile)
        return profile
    }

    func renameProfile(_ id: UUID, to name: String) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].name = name
    }

    /// Deletes a profile and its groups/recents. The main (first)
    /// profile cannot be deleted.
    func deleteProfile(_ id: UUID) {
        guard profiles.count > 1, id != profiles[0].id else { return }
        if activeProfileID == id { switchProfile(to: profiles[0].id) }
        profiles.removeAll { $0.id == id }
        customGroups.removeAll { $0.profileID == id }
        recentsByProfile[id.uuidString] = nil
    }

    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: Keys.profiles)
        }
    }

    // MARK: Custom groups (2.0.0)

    var activeGroups: [CustomGroup] {
        customGroups.filter { $0.profileID == activeProfileID }
    }

    @discardableResult
    func addGroup(name: String) -> CustomGroup {
        let group = CustomGroup(id: UUID(), profileID: activeProfileID, name: name, channelIDs: [])
        customGroups.append(group)
        return group
    }

    func renameGroup(_ id: UUID, to name: String) {
        guard let i = customGroups.firstIndex(where: { $0.id == id }) else { return }
        customGroups[i].name = name
    }

    func deleteGroup(_ id: UUID) {
        customGroups.removeAll { $0.id == id }
    }

    func groupContains(_ groupID: UUID, streamID: Int) -> Bool {
        customGroups.first { $0.id == groupID }?.channelIDs.contains(streamID) ?? false
    }

    func setInGroup(_ groupID: UUID, streamID: Int, member: Bool) {
        guard let i = customGroups.firstIndex(where: { $0.id == groupID }) else { return }
        if member {
            if !customGroups[i].channelIDs.contains(streamID) {
                customGroups[i].channelIDs.append(streamID)
            }
        } else {
            customGroups[i].channelIDs.removeAll { $0 == streamID }
        }
    }

    private func persistGroups() {
        if let data = try? JSONEncoder().encode(customGroups) {
            UserDefaults.standard.set(data, forKey: Keys.groups)
        }
    }

    // MARK: Recently watched

    /// When each recent channel was last opened (2.0.0, powers the
    /// "Jump back in" banner). Persisted as epoch seconds by stream ID.
    private(set) var recentWatchedAt: [Int: Date] = [:]

    func recordRecent(streamID: Int) {
        var ids = recentChannelIDs
        ids.removeAll { $0 == streamID }
        ids.insert(streamID, at: 0)
        recentChannelIDs = Array(ids.prefix(12))
        recentWatchedAt[streamID] = Date()
        let stored = Dictionary(uniqueKeysWithValues: recentWatchedAt.map {
            (String($0.key), $0.value.timeIntervalSince1970)
        })
        UserDefaults.standard.set(stored, forKey: "viu_recent_watched_at")
    }

    // MARK: Programme reminders ("Remind Me")

    static func reminderID(streamID: Int, start: Date) -> String {
        "viu-remind-\(streamID)-\(Int(start.timeIntervalSince1970))"
    }

    func hasReminder(streamID: Int, start: Date?) -> Bool {
        guard let start else { return false }
        return reminderIDs.contains(Self.reminderID(streamID: streamID, start: start))
    }

    /// Schedule (or cancel) a local notification for when a programme
    /// starts. Returns the reminder's new state; scheduling asks for
    /// notification permission the first time.
    @discardableResult
    func setReminder(channel: EPGChannel, programme: EPGProgramme, enabled: Bool) async -> Bool {
        #if os(tvOS)
        // Remind Me is not offered on Apple TV (and tvOS marks the
        // notification content properties unavailable).
        return false
        #else
        guard let start = programme.timeStart else { return false }
        let id = Self.reminderID(streamID: channel.streamId, start: start)
        let center = UNUserNotificationCenter.current()
        if enabled {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted, start > Date() else { return false }
            let content = UNMutableNotificationContent()
            content.title = programme.name
            content.body = "Starting now on \(channel.name)"
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, start.timeIntervalSinceNow), repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            } catch {
                return false
            }
            reminderIDs.insert(id)
            return true
        } else {
            center.removePendingNotificationRequests(withIdentifiers: [id])
            reminderIDs.remove(id)
            return false
        }
        #endif
    }

    /// Drop reminder records whose start time has passed (the
    /// notifications themselves fire or expire on their own).
    func pruneReminders() {
        let now = Date().timeIntervalSince1970
        reminderIDs = reminderIDs.filter { id in
            guard let epoch = id.split(separator: "-").last, let t = Double(epoch) else { return false }
            return t > now - 3600
        }
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
    /// Kids bedtime (2.0.0): while Kids Mode is on, the app locks at
    /// the bedtime hour until 06:00.
    var kidsBedtimeEnabled: Bool {
        didSet { UserDefaults.standard.set(kidsBedtimeEnabled, forKey: Keys.kidsBedtime) }
    }
    /// Bedtime as minutes after midnight (default 1200 = 20:00).
    var kidsBedtimeMinutes: Int {
        didSet { UserDefaults.standard.set(kidsBedtimeMinutes, forKey: Keys.kidsBedtimeMinutes) }
    }

    /// True when Kids Mode is on, bedtime is enabled, and the current
    /// time is at/after bedtime or before 06:00.
    func isBedtimeActive(at date: Date = Date()) -> Bool {
        guard kidsModeEnabled, kidsBedtimeEnabled else { return false }
        let cal = Calendar.current
        let mins = cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
        return mins >= kidsBedtimeMinutes || mins < 360
    }
    private(set) var lockedIDs: Set<Int>
    private var resetObserver: NSObjectProtocol?

    private enum Keys {
        static let enabled = "viu_parental_enabled"
        static let locked = "viu_locked_channel_ids"
        static let kidsMode = "viu_kids_mode"
        static let kidsBedtime = "viu_kids_bedtime"
        static let kidsBedtimeMinutes = "viu_kids_bedtime_minutes"
        static let pinAccount = "parental_pin"
        static let resetCode = "viu_pin_reset_code"
        static let resetCodeAt = "viu_pin_reset_code_at"
    }

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Keys.enabled)
        kidsModeEnabled = UserDefaults.standard.bool(forKey: Keys.kidsMode)
        kidsBedtimeEnabled = UserDefaults.standard.bool(forKey: Keys.kidsBedtime)
        kidsBedtimeMinutes = UserDefaults.standard.object(forKey: Keys.kidsBedtimeMinutes) as? Int ?? 1200
        lockedIDs = Set(UserDefaults.standard.array(forKey: Keys.locked) as? [Int] ?? [])
        resetObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("ViuParentalReset"), object: nil, queue: .main
        ) { [weak self] _ in self?.reloadFromStorage() }
    }

    private func reloadFromStorage() {
        isEnabled = UserDefaults.standard.bool(forKey: Keys.enabled)
        kidsModeEnabled = UserDefaults.standard.bool(forKey: Keys.kidsMode)
        kidsBedtimeEnabled = UserDefaults.standard.bool(forKey: Keys.kidsBedtime)
        kidsBedtimeMinutes = UserDefaults.standard.object(forKey: Keys.kidsBedtimeMinutes) as? Int ?? 1200
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
        UserDefaults.standard.set(false, forKey: Keys.kidsBedtime)
        UserDefaults.standard.removeObject(forKey: Keys.locked)
        Keychain.shared.delete(account: Keys.pinAccount)
        NotificationCenter.default.post(name: Notification.Name("ViuParentalReset"), object: nil)
    }
}
