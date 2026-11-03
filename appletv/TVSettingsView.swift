//
//  TVSettingsView.swift
//  Viu Live TV — Apple TV
//
//  TV settings: account, accent + appearance, language filter,
//  modes, parental controls with a remote-friendly PIN pad,
//  category visibility, and sign out.
//

import SwiftUI

struct TVSettingsView: View {
    @Environment(AuthViewModel.self) private var auth
    @Environment(EPGStore.self) private var epg
    @Environment(AppSettings.self) private var settings
    @Environment(ParentalControls.self) private var parental

    private enum PINFlow: Identifiable {
        case enableParental, disableParental, setupForParental
        case disableKids, changeVerify, changeSetup
        var id: String { String(describing: self) }
    }
    @State private var pinFlow: PINFlow?
    @State private var pinError: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    LabeledContent("Signed in as",
                                   value: auth.accountInfo?.displayName ?? auth.username)
                    if let status = auth.accountInfo?.premiumStatus {
                        LabeledContent("Subscription", value: status)
                    }
                    if let expiry = auth.accountInfo?.premiumExpiresOn {
                        LabeledContent("Premium expires", value: expiry)
                    }
                    Button("Sign Out", role: .destructive) {
                        Task { await auth.logout() }
                    }
                }

                Section("Appearance") {
                    Picker("Mode", selection: appearanceBinding) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    HStack(spacing: 18) {
                        Text("Accent")
                        Spacer()
                        ForEach(AccentChoice.allCases) { accent in
                            Button {
                                settings.accent = accent
                            } label: {
                                Circle()
                                    .fill(accent.color)
                                    .frame(width: 40, height: 40)
                                    .overlay {
                                        if settings.accent == accent {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.white)
                                                .font(.headline)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("Language") {
                    NavigationLink {
                        TVLanguageView()
                    } label: {
                        LabeledContent("Channel Language",
                                       value: currentLanguageLabel)
                    }
                }

                Section("Modes") {
                    Toggle("Sports Mode", isOn: sportsBinding)
                    Toggle("Kids Mode", isOn: kidsBinding)
                }

                Section("Parental Controls") {
                    Toggle("Parental Controls", isOn: parentalBinding)
                    if parental.isEnabled {
                        NavigationLink {
                            TVLockedChannelsView()
                        } label: {
                            LabeledContent("Locked Channels",
                                           value: "\(parental.lockedIDs.count)")
                        }
                        Button("Change PIN") { pinFlow = .changeVerify }
                        if parental.isDefaultPIN {
                            Text("PIN is the default 0000 — set your own above.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Categories") {
                    NavigationLink {
                        TVCategoriesView()
                    } label: {
                        LabeledContent("Show / Hide Categories",
                                       value: "\(epg.tags.count - hiddenCount) shown")
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: "1.5.0")
                    Text("Viu Live TV for Apple TV\nCopyright (c) 2026 c12n Apps")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
        .sheet(item: $pinFlow) { flow in
            TVPINEntryView(title: title(for: flow),
                           subtitle: pinError) { pin in
                handlePIN(pin, for: flow)
            }
        }
        .onChange(of: pinFlow) { _, _ in pinError = nil }
    }

    // MARK: Bindings + flows

    private var appearanceBinding: Binding<AppearanceMode> {
        Binding(get: { settings.appearance }, set: { settings.appearance = $0 })
    }

    private var sportsBinding: Binding<Bool> {
        Binding(get: { settings.sportsModeEnabled },
                set: { settings.sportsModeEnabled = $0 })
    }

    private var kidsBinding: Binding<Bool> {
        Binding(get: { parental.kidsModeEnabled }, set: { newValue in
            if newValue {
                parental.kidsModeEnabled = true
            } else {
                pinFlow = .disableKids
            }
        })
    }

    private var parentalBinding: Binding<Bool> {
        Binding(get: { parental.isEnabled }, set: { newValue in
            if newValue {
                if parental.hasCustomPIN {
                    parental.isEnabled = true
                } else {
                    pinFlow = .setupForParental
                }
            } else {
                pinFlow = .disableParental
            }
        })
    }

    private var hiddenCount: Int {
        epg.tags.filter { epg.isCategoryHidden($0.parameterName) }.count
    }

    private var currentLanguageLabel: String {
        if settings.languageFilter.isEmpty { return "All Languages" }
        return epg.availableLanguages()
            .first { $0.code == settings.languageFilter }?.label ?? "All Languages"
    }

    private func title(for flow: PINFlow) -> String {
        switch flow {
        case .enableParental, .disableParental: return "Enter PIN"
        case .setupForParental: return "Create a PIN"
        case .disableKids: return "Enter PIN to turn off Kids Mode"
        case .changeVerify: return "Enter your current PIN"
        case .changeSetup: return "Create a new PIN"
        }
    }

    private func handlePIN(_ pin: String?, for flow: PINFlow) -> Bool {
        guard let pin else {
            pinFlow = nil
            return true
        }
        pinError = nil
        switch flow {
        case .disableParental:
            if parental.verify(pin) {
                parental.isEnabled = false
                pinFlow = nil
                return true
            }
            pinError = "Incorrect PIN — try again."
            return false
        case .setupForParental:
            parental.setPIN(pin)
            parental.isEnabled = true
            pinFlow = nil
            return true
        case .disableKids:
            if parental.verify(pin) {
                parental.kidsModeEnabled = false
                pinFlow = nil
                return true
            }
            pinError = "Incorrect PIN — try again."
            return false
        case .changeVerify:
            if parental.verify(pin) {
                pinFlow = .changeSetup
                return true
            }
            pinError = "Incorrect PIN — try again."
            return false
        case .changeSetup:
            parental.setPIN(pin)
            pinFlow = nil
            return true
        case .enableParental:
            pinFlow = nil
            return true
        }
    }
}

// MARK: - Language picker

struct TVLanguageView: View {
    @Environment(EPGStore.self) private var epg
    @Environment(AppSettings.self) private var settings

    var body: some View {
        List {
            Button {
                settings.languageFilter = ""
            } label: {
                HStack {
                    Text("All Languages")
                    Spacer()
                    Text("\(epg.channels.count)")
                        .foregroundStyle(.secondary)
                    if settings.languageFilter.isEmpty {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
            }
            ForEach(epg.availableLanguages()) { option in
                Button {
                    settings.languageFilter = option.code
                } label: {
                    HStack {
                        Text(option.label)
                        Spacer()
                        Text("\(option.count)")
                            .foregroundStyle(.secondary)
                        if settings.languageFilter == option.code {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
            }
        }
        .navigationTitle("Channel Language")
    }
}

// MARK: - Locked channels

struct TVLockedChannelsView: View {
    @Environment(EPGStore.self) private var epg
    @Environment(ParentalControls.self) private var parental

    var body: some View {
        List {
            ForEach(epg.channels.sorted { $0.name < $1.name }) { channel in
                Toggle(isOn: Binding(
                    get: { parental.isLocked(channel.streamId) },
                    set: { parental.setLocked(channel.streamId, locked: $0) }
                )) {
                    HStack {
                        Text(channel.name)
                        Spacer()
                        Text(channel.language.code.uppercased())
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Locked Channels")
    }
}

// MARK: - Categories

struct TVCategoriesView: View {
    @Environment(EPGStore.self) private var epg

    var body: some View {
        List {
            ForEach(orderedTags) { tag in
                Toggle(isOn: Binding(
                    get: { !epg.isCategoryHidden(tag.parameterName) },
                    set: { epg.setCategoryHidden(tag.parameterName, hidden: !$0) }
                )) {
                    Text(tag.displayName)
                }
            }
            Button("Restore Defaults") {
                epg.resetCategoryPreferences()
            }
        }
        .navigationTitle("Categories")
    }

    private var orderedTags: [EPGTag] {
        let order = epg.effectiveCategoryOrder()
        return epg.tags.sorted {
            (order.firstIndex(of: $0.parameterName) ?? 999) <
                (order.firstIndex(of: $1.parameterName) ?? 999)
        }
    }
}

// MARK: - PIN entry (remote-friendly digit pad)

struct TVPINEntryView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    var subtitle: String? = nil
    /// Called with the 4-digit PIN, or nil when cancelled. Return
    /// true to accept and close; false keeps the pad open (wrong
    /// PIN) and clears the entry.
    let onDone: (String?) -> Bool
    @State private var entry = ""

    private let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"],
                                    ["7", "8", "9"], ["", "0", "⌫"]]

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "lock.fill").font(.largeTitle)
            Text(title).font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle).foregroundStyle(.red)
            }
            HStack(spacing: 16) {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(i < entry.count ? Color.primary : Color.clear)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().stroke(.secondary, lineWidth: 1.5))
                }
            }
            VStack(spacing: 14) {
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: 14) {
                        ForEach(row, id: \.self) { key in
                            if key.isEmpty {
                                Color.clear.frame(width: 84, height: 84)
                            } else {
                                Button {
                                    press(key)
                                } label: {
                                    Text(key)
                                        .font(.title)
                                        .frame(width: 84, height: 84)
                                }
                                .buttonStyle(.card)
                            }
                        }
                    }
                }
            }
            Button("Cancel") {
                _ = onDone(nil)
                dismiss()
            }
        }
        .padding(48)
    }

    private func press(_ key: String) {
        if key == "⌫" {
            if !entry.isEmpty { entry.removeLast() }
            return
        }
        guard entry.count < 4 else { return }
        entry += key
        if entry.count == 4 {
            let pin = entry
            // Small delay so the fourth dot paints before closing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                if onDone(pin) {
                    dismiss()
                } else {
                    entry = ""
                }
            }
        }
    }
}
