//
//  SettingsView.swift
//  Viu Live TV
//
//  Account info + logout, player choice, appearance override, stream quality,
//  and About.
//

import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AuthViewModel.self) private var auth
    @Environment(AppSettings.self) private var settingsStore
    @Environment(EPGStore.self) private var epg
    @Environment(FavoritesStore.self) private var favorites
    @Environment(ParentalControls.self) private var parental
    @Environment(\.dismiss) private var dismiss

    @State private var showLogoutConfirm = false
    @State private var showClearCacheConfirm = false
    @State private var showRestoreDefaultsConfirm = false
    @State private var showClearFavoritesConfirm = false
    @State private var cacheSizeText = "…"
    @State private var pinFlow: PINFlow?

    var body: some View {
        @Bindable var settings = settingsStore

        NavigationStack {
            Form {
                accountSection

                Section("Appearance") {
                    Picker("Theme", selection: $settings.appearance) {
                        ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Haptic Feedback", isOn: Binding(
                        get: { settingsStore.hapticsEnabled },
                        set: { settingsStore.hapticsEnabled = $0 }
                    ))
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Accent Color")
                        HStack(spacing: 12) {
                            ForEach(AccentChoice.allCases) { choice in
                                Button {
                                    settingsStore.accent = choice
                                    UIApplication.shared.setAlternateIconName(choice.iconName) { _ in }
                                    Haptics.light()
                                } label: {
                                    Circle()
                                        .fill(choice.color)
                                        .frame(width: 30, height: 30)
                                        .overlay {
                                            if settingsStore.accent == choice {
                                                Image(systemName: "checkmark")
                                                    .font(.caption.bold())
                                                    .foregroundStyle(.white)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(choice.label)
                            }
                        }
                        Text("Also changes the VIU letters on the app icon.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }

                parentalSection

                sportsSection

                Section {
                    Picker("External Player", selection: $settings.externalPlayer) {
                        ForEach(ExternalPlayerChoice.allCases) { choice in
                            HStack {
                                Text(choice.label)
                                if choice != .native, choice != .shareSheet,
                                   ExternalPlayerLauncher.isInstalled(choice) {
                                    Spacer()
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                }
                            }.tag(choice)
                        }
                    }
                    Toggle("Background Play", isOn: Binding(
                        get: { settingsStore.backgroundPlayEnabled },
                        set: { settingsStore.backgroundPlayEnabled = $0 }
                    ))
                    Toggle("Picture in Picture", isOn: Binding(
                        get: { settingsStore.pictureInPictureEnabled },
                        set: { settingsStore.pictureInPictureEnabled = $0 }
                    ))
                } header: {
                    Text("Playback")
                } footer: {
                    Text("'Open in external player' on a channel uses this app. A green check means the app looks installed. Background Play keeps the audio playing when you leave the app or lock the screen; Picture in Picture lets the video float over other apps.")
                }

                categoriesSection

                dataSection

                Section("Stream Quality") {
                    Picker("Preferred Quality", selection: $settings.streamQuality) {
                        ForEach(StreamQuality.allCases) { Text($0.label).tag($0) }
                    }
                    if settings.streamQuality != .auto {
                        Text("Applied when the stream exposes multiple variants (HLS). Otherwise the source quality is used.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Help") {
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("Channel Loading Diagnostics", systemImage: "stethoscope")
                    }
                }

                aboutSection
                logoutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                if auth.accountInfo == nil { await auth.loadAccountInfo() }
                refreshCacheSize()
            }
            .sheet(item: $pinFlow) { flow in
                PINEntryView(mode: flow.mode) { ok in
                    if ok { flow.onSuccess() }
                }
            }
            .confirmationDialog("Sign out of Viu Live TV?",
                                isPresented: $showLogoutConfirm,
                                titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) {
                    epg.clearCacheAndReset()
                    Task { await auth.logout() }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Clear the channel cache?",
                                isPresented: $showClearCacheConfirm,
                                titleVisibility: .visible) {
                Button("Clear Cache", role: .destructive) {
                    Task {
                        await epg.clearGuideCache()
                        refreshCacheSize()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes \(cacheSizeText) of cached data (the saved channel guide and channel logos) and downloads the guide fresh from Viu. Favorites and settings are not affected.")
            }
            .confirmationDialog("Clear all favorites?",
                                isPresented: $showClearFavoritesConfirm,
                                titleVisibility: .visible) {
                Button("Clear Favorites", role: .destructive) {
                    Task { await favorites.clearAll() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every favorite is removed from this device and from your Viu account on the website. This can't be undone.")
            }
            .confirmationDialog("Restore category defaults?",
                                isPresented: $showRestoreDefaultsConfirm,
                                titleVisibility: .visible) {
                Button("Restore Defaults") {
                    epg.resetCategoryPreferences()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All channel categories will be shown again, and their order reset to the default. Favorites and other settings are not affected.")
            }
        }
    }

    // MARK: Parental controls & modes

    private var parentalSection: some View {
        Section {
            Toggle("Parental Controls", isOn: Binding(
                get: { parental.isEnabled },
                set: { newValue in
                    if newValue {
                        if parental.hasPIN { parental.isEnabled = true }
                        else { pinFlow = PINFlow(mode: .setup) { parental.isEnabled = true } }
                    } else {
                        pinFlow = PINFlow(mode: .verify) { parental.isEnabled = false }
                    }
                }
            ))
            if parental.isEnabled {
                NavigationLink {
                    LockedChannelsView()
                } label: {
                    HStack {
                        Label("Locked Channels", systemImage: "lock.fill")
                        Spacer()
                        Text("\(parental.lockedIDs.count)")
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Change PIN") {
                    pinFlow = PINFlow(mode: .change) {}
                }
            }
            Toggle("Kids Mode", isOn: Binding(
                get: { parental.kidsModeEnabled },
                set: { newValue in
                    if newValue {
                        if parental.hasPIN { parental.kidsModeEnabled = true }
                        else { pinFlow = PINFlow(mode: .setup) { parental.kidsModeEnabled = true } }
                    } else {
                        pinFlow = PINFlow(mode: .verify) { parental.kidsModeEnabled = false }
                    }
                }
            ))
        } header: {
            Text("Parental Controls")
        } footer: {
            Text("Locked channels ask for a 4-digit PIN before they play, and a lock icon shows next to locked channels in the lists and search. Kids Mode limits the app to the Kids category — the PIN is only needed to turn Kids Mode off (if no PIN exists yet, you create one when you turn it on). Forgot your PIN? Sign out and sign back in to reset parental controls.")
        }
    }

    private var sportsSection: some View {
        Section {
            Toggle("Sports Mode", isOn: Binding(
                get: { settingsStore.sportsModeEnabled },
                set: { settingsStore.sportsModeEnabled = $0 }
            ))
        } header: {
            Text("Sports Mode")
        } footer: {
            Text("Shows only sports categories (Sports, Hockey, ESPN+, TSN+ and similar). No PIN needed. While Kids Mode is on, Kids Mode takes over.")
        }
    }

    // MARK: Categories & data

    /// Every real category (the built-in All / Favorites tabs excluded)
    /// with a visibility toggle.
    private var categoryTags: [EPGTag] {
        var result: [EPGTag] = []
        for tag in epg.tags where tag.parameterName != "ALL" && tag.parameterName != "FAVORITES" {
            result.append(tag)
        }
        return result
    }

    private var categoriesSection: some View {
        Section {
            if categoryTags.isEmpty {
                Text("Categories load together with your channel list.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(categoryTags) { tag in
                    Toggle(isOn: Binding(
                        get: { !epg.isCategoryHidden(tag.parameterName) },
                        set: { epg.setCategoryHidden(tag.parameterName, hidden: !$0) }
                    )) {
                        Text(tag.displayName)
                    }
                }
            }
        } header: {
            Text("Channel Categories")
        } footer: {
            Text("Hidden categories are removed from the category bar in the channel list. You can also long-press a category in that bar and drag it into your preferred order.")
        }
    }

    private var dataSection: some View {
        Section("Data") {
            Button {
                showClearCacheConfirm = true
            } label: {
                HStack {
                    Label("Clear Cache", systemImage: "trash")
                    Spacer()
                    Text(cacheSizeText)
                        .foregroundStyle(.secondary)
                }
            }
            Button(role: .destructive) {
                showClearFavoritesConfirm = true
            } label: {
                Label("Clear Favorites", systemImage: "heart.slash")
            }
            Button {
                showRestoreDefaultsConfirm = true
            } label: {
                Label("Restore Defaults", systemImage: "arrow.counterclockwise")
            }
        }
    }

    private func refreshCacheSize() {
        cacheSizeText = ByteCountFormatter.string(fromByteCount: epg.cacheSizeBytes, countStyle: .file)
    }

    // MARK: Sections without bindings

    private var accountSection: some View {
        Section("Account") {
            if let info = auth.accountInfo {
                LabeledContent("Name", value: info.displayName)
                if let u = info.username { LabeledContent("Username", value: u) }
                if let status = info.premiumStatus, !status.isEmpty {
                    LabeledContent("Status", value: status)
                }
                if let exp = info.premiumExpiresOn, !exp.isEmpty {
                    LabeledContent("Premium Expires", value: exp)
                }
                if let created = info.createdOn, !created.isEmpty {
                    LabeledContent("Member Since", value: created)
                }
            } else {
                LabeledContent("Username", value: auth.username.isEmpty ? "—" : auth.username)
                Button {
                    Task { await auth.loadAccountInfo() }
                } label: {
                    Label("Refresh Account Info", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("App", value: "Viu Live TV")
            LabeledContent("Version", value: appVersion)
            LabeledContent("Service", value: "api.viu.rs")
        }
    }

    private var logoutSection: some View {
        Section {
            Button(role: .destructive) {
                showLogoutConfirm = true
            } label: {
                HStack {
                    if auth.isWorking { ProgressView() }
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
            .disabled(auth.isWorking)
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}

// MARK: - Diagnostics

/// Runs the exact requests the app uses to load channels and shows what
/// the server actually answered — the fastest way to pin down why a live
/// list isn't loading. The report contains no token or password.
struct DiagnosticsView: View {
    @Environment(EPGStore.self) private var epg
    @State private var lines: [String] = []
    @State private var running = false

    private var reportText: String {
        var parts = ["Viu Live TV — channel loading diagnostics"]
        if !epg.strategyLog.isEmpty {
            parts.append("Last channel refresh:")
            parts.append(contentsOf: epg.strategyLog.map { "• \($0)" })
        }
        if !lines.isEmpty {
            parts.append("Live endpoint tests:")
            parts.append(contentsOf: lines.map { "• \($0)" })
        }
        return parts.joined(separator: "\n")
    }

    var body: some View {
        List {
            Section {
                Button {
                    Task { await run() }
                } label: {
                    HStack {
                        if running { ProgressView() }
                        Text(running ? "Testing…" : "Run Endpoint Tests")
                    }
                }
                .disabled(running)

                if !epg.strategyLog.isEmpty || !lines.isEmpty {
                    ShareLink(item: reportText) {
                        Label("Share Report", systemImage: "square.and.arrow.up")
                    }
                }
            } footer: {
                Text("Makes the same requests the app uses and shows exactly what the Viu server answers. The report never includes your sign-in token or password.")
            }

            if !epg.strategyLog.isEmpty {
                Section("Last Channel Refresh") {
                    ForEach(Array(epg.strategyLog.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.footnote).textSelection(.enabled)
                    }
                }
            }

            if !lines.isEmpty {
                Section("Endpoint Tests") {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.footnote).textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func run() async {
        running = true
        defer { running = false }
        lines = await APIClient.shared.runDiagnostics()
    }
}

// MARK: - Parental PIN

enum PINEntryMode { case verify, setup, change }

/// A PIN sheet request from Settings: which flow to run, and what to do
/// after it succeeds.
struct PINFlow: Identifiable {
    let id = UUID()
    let mode: PINEntryMode
    let onSuccess: () -> Void
}

/// 4-digit PIN pad for parental controls: verifying (locked channel,
/// turning a mode or the controls off), setting a first PIN, or
/// changing an existing PIN (verify current, then enter + confirm).
struct PINEntryView: View {
    @Environment(ParentalControls.self) private var parental
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    let mode: PINEntryMode
    var onFinished: (Bool) -> Void

    @State private var entry = ""
    @State private var firstEntry: String?
    @State private var stepIndex = 0
    @State private var errorText: String?
    @State private var completed = false

    private enum Step { case verify, new, confirm }

    private var steps: [Step] {
        switch mode {
        case .verify: return [.verify]
        case .setup:  return [.new, .confirm]
        case .change: return [.verify, .new, .confirm]
        }
    }

    private var currentStep: Step { steps[min(stepIndex, steps.count - 1)] }

    private var title: String {
        switch currentStep {
        case .verify:  return "Enter PIN"
        case .new:     return mode == .change ? "Enter New PIN" : "Create a PIN"
        case .confirm: return "Confirm PIN"
        }
    }

    private var subtitle: String {
        switch currentStep {
        case .verify:  return "This is protected by parental controls."
        case .new:     return "Choose a 4-digit PIN for parental controls."
        case .confirm: return "Enter the PIN once more to confirm it."
        }
    }

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "lock.fill")
                .font(.largeTitle)
                .foregroundStyle(settings.accent.color)
            Text(title)
                .font(.title3.bold())
            Text(errorText ?? subtitle)
                .font(.subheadline)
                .foregroundStyle(errorText == nil ? Color.secondary : Color.red)
                .multilineTextAlignment(.center)
            HStack(spacing: 16) {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(i < entry.count ? settings.accent.color : Color.secondary.opacity(0.3))
                        .frame(width: 14, height: 14)
                }
            }
            keypad
            Button("Cancel") { finish(false) }
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
        .onDisappear { if !completed { onFinished(false) } }
    }

    private var keypad: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
            ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "del"], id: \.self) { key in
                Button { tap(key) } label: {
                    Group {
                        if key == "del" {
                            Image(systemName: "delete.left")
                        } else {
                            Text(key).font(.title2.weight(.medium))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .glassControl(cornerRadius: 28)
                }
                .buttonStyle(.plain)
                .disabled(key.isEmpty)
                .opacity(key.isEmpty ? 0 : 1)
            }
        }
        .frame(maxWidth: 300)
    }

    private func tap(_ key: String) {
        if key == "del" {
            if !entry.isEmpty { entry.removeLast() }
            return
        }
        guard entry.count < 4 else { return }
        entry.append(key)
        errorText = nil
        Haptics.light()
        if entry.count == 4 {
            Task {
                try? await Task.sleep(for: .milliseconds(160))
                completeEntry()
            }
        }
    }

    private func completeEntry() {
        let pin = entry
        switch currentStep {
        case .verify:
            if parental.verify(pin) { finish(true) } else { fail("Incorrect PIN") }
        case .new:
            firstEntry = pin
            entry = ""
            stepIndex += 1
        case .confirm:
            if pin == firstEntry {
                parental.setPIN(pin)
                finish(true)
            } else {
                fail("PINs didn't match — start again")
                firstEntry = nil
                stepIndex = steps.firstIndex(of: .new) ?? 0
            }
        }
    }

    private func fail(_ message: String) {
        errorText = message
        entry = ""
        Haptics.medium()
    }

    private func finish(_ ok: Bool) {
        completed = true
        onFinished(ok)
        dismiss()
    }
}

// MARK: - Locked channels picker

/// Every channel with a lock toggle — the parental lock list.
struct LockedChannelsView: View {
    @Environment(EPGStore.self) private var epg
    @Environment(ParentalControls.self) private var parental
    @Environment(AppSettings.self) private var settings
    @State private var search = ""

    private var channels: [EPGChannel] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return epg.channels }
        return epg.channels.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        List {
            Section {
                ForEach(channels) { channel in
                    let locked = parental.isLocked(channel.streamId)
                    Button {
                        parental.setLocked(channel.streamId, locked: !locked)
                        Haptics.light()
                    } label: {
                        HStack {
                            Text(channel.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: locked ? "lock.fill" : "lock.open")
                                .foregroundStyle(locked ? settings.accent.color : .secondary)
                        }
                    }
                }
            } footer: {
                Text("Locked channels ask for the parental PIN before they play. \(parental.lockedIDs.count) locked.")
            }
        }
        .searchable(text: $search, prompt: "Search channels")
        .navigationTitle("Locked Channels")
        .navigationBarTitleDisplayMode(.inline)
    }
}
