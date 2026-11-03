//
//  MacSettingsView.swift
//  Viu Live TV — macOS
//
//  Settings form (used in the Settings scene and as a sheet from
//  the home view): account, appearance + accent, language filter,
//  modes, parental controls with PIN flows, categories, sign out.
//

import SwiftUI

struct MacSettingsView: View {
    @Environment(AuthViewModel.self) private var auth
    @Environment(EPGStore.self) private var epg
    @Environment(AppSettings.self) private var settings
    @Environment(ParentalControls.self) private var parental
    @Environment(\.dismiss) private var dismiss

    private enum PINFlow: Identifiable {
        case disableParental, setupForParental, disableKids
        case changeVerify, changeSetup
        var id: String { String(describing: self) }
    }
    @State private var pinFlow: PINFlow?
    @State private var pinError: String?

    var body: some View {
        Form {
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
                Picker("Accent", selection: accentBinding) {
                    ForEach(AccentChoice.allCases) { accent in
                        Text(accent.label).tag(accent)
                    }
                }
            }

            Section("Language") {
                Picker("Channel Language", selection: languageBinding) {
                    Text("All Languages").tag("")
                    ForEach(epg.availableLanguages()) { option in
                        Text("\(option.label) (\(option.count))").tag(option.code)
                    }
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
                        MacLockedChannelsView()
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

            Section("Data") {
                Button("Clear Guide Cache") {
                    Task { await epg.clearGuideCache() }
                }
                LabeledContent("Version", value: "1.5.0")
                Text("Viu Live TV for macOS · Copyright (c) 2026 c12n Apps")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .frame(minWidth: 520, minHeight: 480)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(item: $pinFlow) { flow in
            MacPINEntryView(title: title(for: flow), error: pinError) { pin in
                handlePIN(pin, for: flow)
            }
            .frame(width: 340)
        }
        .onChange(of: pinFlow) { _, _ in pinError = nil }
    }

    // MARK: Bindings + flows

    private var appearanceBinding: Binding<AppearanceMode> {
        Binding(get: { settings.appearance }, set: { settings.appearance = $0 })
    }

    private var accentBinding: Binding<AccentChoice> {
        Binding(get: { settings.accent }, set: { settings.accent = $0 })
    }

    private var languageBinding: Binding<String> {
        Binding(get: { settings.languageFilter },
                set: { settings.languageFilter = $0 })
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

    private var orderedTags: [EPGTag] {
        let order = epg.effectiveCategoryOrder()
        return epg.tags.sorted {
            (order.firstIndex(of: $0.parameterName) ?? 999) <
                (order.firstIndex(of: $1.parameterName) ?? 999)
        }
    }

    private func title(for flow: PINFlow) -> String {
        switch flow {
        case .disableParental: return "Enter PIN"
        case .setupForParental: return "Create a PIN"
        case .disableKids: return "Enter PIN to turn off Kids Mode"
        case .changeVerify: return "Enter your current PIN"
        case .changeSetup: return "Create a new PIN"
        }
    }

    private func handlePIN(_ pin: String?, for flow: PINFlow) {
        guard let pin else {
            pinFlow = nil
            return
        }
        switch flow {
        case .disableParental:
            if parental.verify(pin) {
                parental.isEnabled = false
                pinFlow = nil
            } else {
                pinError = "Incorrect PIN — try again."
            }
        case .setupForParental:
            parental.setPIN(pin)
            parental.isEnabled = true
            pinFlow = nil
        case .disableKids:
            if parental.verify(pin) {
                parental.kidsModeEnabled = false
                pinFlow = nil
            } else {
                pinError = "Incorrect PIN — try again."
            }
        case .changeVerify:
            if parental.verify(pin) {
                pinFlow = .changeSetup
            } else {
                pinError = "Incorrect PIN — try again."
            }
        case .changeSetup:
            parental.setPIN(pin)
            pinFlow = nil
        }
    }
}

// MARK: - Locked channels

struct MacLockedChannelsView: View {
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

// MARK: - PIN entry (keyboard)

struct MacPINEntryView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    var error: String? = nil
    /// Called with the 4-digit PIN, or nil when cancelled.
    let onDone: (String?) -> Void
    @State private var entry = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.fill").font(.largeTitle)
            Text(title).font(.headline)
                .multilineTextAlignment(.center)
            if let error {
                Text(error).foregroundStyle(.red)
            }
            SecureField("PIN", text: $entry)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .font(.title2)
                .frame(width: 160)
                .focused($fieldFocused)
                .onChange(of: entry) { _, value in
                    let digits = value.filter(\.isNumber)
                    entry = String(digits.prefix(4))
                }
                .onSubmit(confirm)
            HStack(spacing: 12) {
                Button("Cancel") {
                    onDone(nil)
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("OK") { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(entry.count != 4)
            }
        }
        .padding(28)
        .onAppear { fieldFocused = true }
    }

    private func confirm() {
        guard entry.count == 4 else { return }
        onDone(entry)
        dismiss()
    }
}
