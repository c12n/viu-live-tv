//
//  AuthViewModel.swift
//  Viu Live TV
//
//  Observable auth state. Owns the token lifecycle, username persistence,
//  and account info. Username is stored in UserDefaults; token in Keychain.
//

import Foundation
import Observation

@Observable
@MainActor
final class AuthViewModel {
    enum AuthState: Equatable {
        case unknown        // haven't checked yet
        case signedOut
        case signedIn
    }

    var state: AuthState = .unknown
    var isWorking = false
    var errorMessage: String?
    var accountInfo: AccountInfo?

    /// Subscription gate: the app is only usable with an active
    /// subscription. Resolved whenever account info is (re)fetched.
    enum SubscriptionState: Equatable {
        case unknown        // not checked yet
        case active
        case inactive
    }

    var subscriptionState: SubscriptionState = .unknown

    private func applyAccountInfo(_ info: AccountInfo) {
        accountInfo = info
        subscriptionState = info.hasActiveSubscription ? .active : .inactive
    }

    /// Persisted username (not the password).
    var username: String {
        get { UserDefaults.standard.string(forKey: usernameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: usernameKey) }
    }

    private let usernameKey = "viu_username"

    init() {
        // If we already hold a token, go straight in — then validate it in
        // the background. Viu tokens get revoked (e.g. by signing in on the
        // website or another device); without this check the app would sit
        // on a dead session forever, showing only the sample channels.
        if let token = Keychain.shared.token, !token.isEmpty {
            Task { await APIClient.shared.setToken(token) }
            state = .signedIn
            // ContentView calls validateSession() on appear.
        } else {
            state = .signedOut
        }
    }

    /// Confirms the stored token is still accepted. Only an explicit auth
    /// rejection signs the user out; a network failure leaves them in.
    func validateSession() async {
        await APIClient.shared.setToken(Keychain.shared.token)
        do {
            _ = try await APIClient.shared.checkService()
            // Resolve the subscription gate for this launch too.
            await loadAccountInfo()
        } catch let error as APIError {
            if case .sessionExpired = error {
                await APIClient.shared.setToken(nil)
                accountInfo = nil
                subscriptionState = .unknown
                errorMessage = "Your Viu session expired (it may have been signed in elsewhere). Please sign in again."
                state = .signedOut
            }
        } catch {
            // Offline or server hiccup — stay signed in.
        }
    }

    // MARK: Login with credentials

    func login(user: String, password: String) async {
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }

        let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUser.isEmpty, !password.isEmpty else {
            errorMessage = "Please enter both username and password."
            return
        }

        do {
            let result = try await APIClient.shared.authenticate(user: trimmedUser, password: password)
            if result.isSuccess {
                username = trimmedUser
                state = .signedIn
                await loadAccountInfo()
            } else {
                errorMessage = result.humanError
            }
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Use a token directly

    func useToken(_ raw: String) async {
        errorMessage = nil
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            errorMessage = "Please paste a token."
            return
        }
        isWorking = true
        defer { isWorking = false }

        await APIClient.shared.setToken(token)
        // Validate by pulling account info; if it fails, roll back.
        do {
            let info = try await APIClient.shared.accountInfo()
            applyAccountInfo(info)
            state = .signedIn
        } catch {
            await APIClient.shared.setToken(nil)
            errorMessage = "That token didn't work: " +
                ((error as? APIError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: Account info

    func loadAccountInfo() async {
        do {
            applyAccountInfo(try await APIClient.shared.accountInfo())
        } catch {
            // Non-fatal — keep whatever we already had (a network hiccup
            // must not flap the subscription gate or blank Settings).
        }
    }

    // MARK: Logout

    func logout() async {
        isWorking = true
        defer { isWorking = false }
        await APIClient.shared.logout()
        accountInfo = nil
        subscriptionState = .unknown
        state = .signedOut
    }

    var hasToken: Bool {
        Keychain.shared.token?.isEmpty == false
    }
}
