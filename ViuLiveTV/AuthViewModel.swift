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

    /// Persisted username (not the password).
    var username: String {
        get { UserDefaults.standard.string(forKey: usernameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: usernameKey) }
    }

    private let usernameKey = "viu_username"

    init() {
        // If we already hold a token, go straight in.
        if let token = Keychain.shared.token, !token.isEmpty {
            Task { await APIClient.shared.setToken(token) }
            state = .signedIn
        } else {
            state = .signedOut
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
            accountInfo = info
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
            accountInfo = try await APIClient.shared.accountInfo()
        } catch {
            // Non-fatal — settings screen will show what it can.
            accountInfo = nil
        }
    }

    // MARK: Logout

    func logout() async {
        isWorking = true
        defer { isWorking = false }
        await APIClient.shared.logout()
        accountInfo = nil
        state = .signedOut
    }

    var hasToken: Bool {
        Keychain.shared.token?.isEmpty == false
    }
}
