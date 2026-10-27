//
//  ExternalPlayer.swift
//  Viu Live TV
//
//  Builds URL schemes for third-party players and opens them, with a share
//  sheet / open-URL fallback and canOpenURL checks.
//
//  NOTE on Info.plist: to let canOpenURL(_:) return true for these schemes,
//  add LSApplicationQueriesSchemes to Info.plist with: vlc, infuse,
//  outplayer, nplayer-* (see README for the exact snippet).
//

import UIKit
import SwiftUI

enum ExternalPlayerLauncher {

    /// Result of attempting to open an external player.
    enum LaunchResult {
        case opened
        case notInstalled(appName: String)
        case failed
    }

    /// Build the scheme URL for a given player + stream URL.
    static func url(for choice: ExternalPlayerChoice, streamURL: String) -> URL? {
        guard let encoded = streamURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        switch choice {
        case .native, .shareSheet:
            return URL(string: streamURL)
        case .vlc:
            // vlc://<url>  (VLC accepts the raw URL appended)
            return URL(string: "vlc://\(streamURL)")
        case .infuse:
            return URL(string: "infuse://x-callback-url/play?url=\(encoded)")
        case .outplayer:
            return URL(string: "outplayer://\(streamURL)")
        case .nplayer:
            // nPlayer uses the nplayer-<url> form.
            return URL(string: "nplayer-\(streamURL)")
        }
    }

    /// The app-store-facing name for alerts.
    static func appName(for choice: ExternalPlayerChoice) -> String {
        switch choice {
        case .vlc:        return "VLC"
        case .infuse:     return "Infuse"
        case .outplayer:  return "OutPlayer"
        case .nplayer:    return "nPlayer"
        case .native:     return "the built-in player"
        case .shareSheet: return "Open In…"
        }
    }

    /// Whether a given player appears installed (best-effort via canOpenURL).
    static func isInstalled(_ choice: ExternalPlayerChoice) -> Bool {
        let probe: String
        switch choice {
        case .vlc:        probe = "vlc://"
        case .infuse:     probe = "infuse://"
        case .outplayer:  probe = "outplayer://"
        case .nplayer:    probe = "nplayer-https://"
        case .native, .shareSheet: return true
        }
        guard let url = URL(string: probe) else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    /// Open the stream in the chosen external player. Falls back to the share
    /// sheet when the dedicated app isn't installed.
    @MainActor
    static func open(streamURL: String,
                     choice: ExternalPlayerChoice,
                     completion: @escaping (LaunchResult) -> Void) {
        if choice == .shareSheet {
            presentShareSheet(urlString: streamURL)
            completion(.opened)
            return
        }

        guard let target = url(for: choice, streamURL: streamURL) else {
            completion(.failed); return
        }

        // Native choice means "no external app" — caller should use in-app player.
        if choice == .native {
            completion(.opened); return
        }

        if UIApplication.shared.canOpenURL(target) {
            UIApplication.shared.open(target, options: [:]) { ok in
                completion(ok ? .opened : .failed)
            }
        } else {
            completion(.notInstalled(appName: appName(for: choice)))
        }
    }

    /// iOS share sheet fallback ("Open In…").
    @MainActor
    static func presentShareSheet(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)

        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            return
        }

        // Find the top-most presented controller.
        var top = root
        while let presented = top.presentedViewController { top = presented }

        // iPad popover anchoring.
        if let pop = activityVC.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        top.present(activityVC, animated: true)
    }
}
