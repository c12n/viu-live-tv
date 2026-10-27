//
//  SettingsView.swift
//  Viu Live TV
//
//  Account info + logout, player choice, appearance override, stream quality,
//  and About.
//

import SwiftUI

struct SettingsView: View {
    @Environment(AuthViewModel.self) private var auth
    @Environment(AppSettings.self) private var settingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var showLogoutConfirm = false

    var body: some View {
        @Bindable var settings = settingsStore

        NavigationStack {
            Form {
                accountSection

                Section("Appearance") {
                    Picker("Theme", selection: $settings.appearance) {
                        ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                    }
                }

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
                } header: {
                    Text("Playback")
                } footer: {
                    Text("'Open in external player' on a channel uses this app. A green check means the app looks installed.")
                }

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
            .task { if auth.accountInfo == nil { await auth.loadAccountInfo() } }
            .confirmationDialog("Sign out of Viu Live TV?",
                                isPresented: $showLogoutConfirm,
                                titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) {
                    Task { await auth.logout() }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
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
