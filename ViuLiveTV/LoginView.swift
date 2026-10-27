//
//  LoginView.swift
//  Viu Live TV
//
//  First-boot login screen: username + password with show/hide, error
//  handling, and a secondary "Use a token directly" path.
//

import SwiftUI

struct LoginView: View {
    @Environment(AuthViewModel.self) private var auth

    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var showTokenEntry = false
    @State private var token = ""

    @FocusState private var focusedField: Field?
    enum Field { case username, password, token }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    header

                    GlassGroup(spacing: 14) {
                        VStack(spacing: 14) {
                            usernameField
                            passwordField
                        }
                    }
                    .padding(18)
                    .glassCard(cornerRadius: 20)

                    if let err = auth.errorMessage {
                        Label(err, systemImage: "exclamationmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.opacity)
                    }

                    signInButton

                    Button {
                        withAnimation { showTokenEntry.toggle() }
                    } label: {
                        Label("Use a token directly", systemImage: "key.horizontal")
                            .font(.subheadline)
                    }
                    .padding(.top, 4)

                    if showTokenEntry { tokenSection }
                }
                .padding(20)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "tv.inset.filled")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
                .padding(.top, 24)
            Text("Viu Live TV")
                .font(.largeTitle.weight(.bold))
            Text("Sign in to watch live channels")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var usernameField: some View {
        HStack {
            Image(systemName: "person.fill").foregroundStyle(.secondary).frame(width: 22)
            TextField("Username", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.username)
                .submitLabel(.next)
                .focused($focusedField, equals: .username)
                .onSubmit { focusedField = .password }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var passwordField: some View {
        HStack {
            Image(systemName: "lock.fill").foregroundStyle(.secondary).frame(width: 22)
            Group {
                if showPassword {
                    TextField("Password", text: $password)
                } else {
                    SecureField("Password", text: $password)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.password)
            .submitLabel(.go)
            .focused($focusedField, equals: .password)
            .onSubmit { submit() }

            Button {
                showPassword.toggle()
            } label: {
                Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showPassword ? "Hide password" : "Show password")
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var signInButton: some View {
        Button(action: submit) {
            HStack {
                if auth.isWorking { ProgressView().tint(.white) }
                Text(auth.isWorking ? "Signing in…" : "Sign In")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .glassControl(cornerRadius: 14, tint: .accentColor)
        .foregroundStyle(.white)
        .disabled(auth.isWorking)
    }

    private var tokenSection: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "key.fill").foregroundStyle(.secondary).frame(width: 22)
                TextField("Paste auth token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .token)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button {
                Task { await auth.useToken(token) }
            } label: {
                Text("Continue with Token")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .glassControl(cornerRadius: 12, tint: .accentColor)
            .disabled(auth.isWorking || token.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(16)
        .glassCard(cornerRadius: 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func submit() {
        focusedField = nil
        Task { await auth.login(user: username, password: password) }
    }
}

// MARK: - Subscription gate

/// Shown briefly at launch while the account's subscription status is
/// being checked.
struct SubscriptionCheckingView: View {
    @Environment(AuthViewModel.self) private var auth
    @Environment(EPGStore.self) private var epg

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Checking your subscription…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                Task { await auth.loadAccountInfo() }
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            .padding(.top, 8)
            Button("Sign Out", role: .destructive) {
                epg.clearCacheAndReset()
                Task { await auth.logout() }
            }
            .font(.callout)
        }
        .padding(24)
    }
}

/// Shown when the signed-in account has no active subscription: the app
/// can't be used until the subscription is renewed or purchased.
struct SubscriptionRequiredView: View {
    @Environment(AuthViewModel.self) private var auth
    @Environment(EPGStore.self) private var epg
    @Environment(\.openURL) private var openURL
    @State private var checking = false

    /// The service's official website (member portal — renewals and
    /// purchases happen there).
    private static let purchaseURL = URL(string: "https://viu.to")!

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.orange)
                        .padding(.top, 36)
                    Text("Non-VIP Found")
                        .font(.title.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text("An active VIP subscription is required to use Viu Live TV. Please renew or purchase a subscription to continue watching.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if let status = auth.accountInfo?.premiumStatus, !status.isEmpty {
                        Text("Current status: \(status)")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    if let expiry = auth.accountInfo?.premiumExpiresOn, !expiry.isEmpty {
                        Text("Subscription expiry: \(expiry)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    openURL(Self.purchaseURL)
                } label: {
                    Text("Renew or Purchase")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .glassControl(cornerRadius: 14, tint: .accentColor)
                .foregroundStyle(.white)

                Button {
                    checking = true
                    Task {
                        await auth.loadAccountInfo()
                        checking = false
                    }
                } label: {
                    HStack {
                        if checking { ProgressView() }
                        Label("I've Renewed — Check Again", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .glassControl(cornerRadius: 12, tint: .accentColor)
                .disabled(checking)

                Button("Sign Out", role: .destructive) {
                    epg.clearCacheAndReset()
                    Task { await auth.logout() }
                }
                .font(.callout)
                .padding(.top, 4)
            }
            .padding(20)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
    }
}
