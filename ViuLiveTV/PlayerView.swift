//
//  PlayerView.swift
//  Viu Live TV
//
//  Native Apple playback via AVPlayerViewController wrapped for SwiftUI,
//  with Picture-in-Picture, AirPlay (external playback), a live badge
//  overlay, and landscape fullscreen behaviour.
//

import SwiftUI
import UIKit
import AVKit
import AVFoundation

// MARK: - Player model

@Observable
@MainActor
final class PlayerModel {
    let channel: EPGChannel
    var streamURL: URL?
    var isLoading = true
    var errorMessage: String?
    /// Set when the AVPlayerItem itself fails (bad stream, stall, decode) —
    /// previously this was swallowed and the user just saw a black screen.
    var playbackError: String?
    /// Bumped on every successful link fetch so the player container swaps
    /// in a fresh item even when the stream URL string is identical.
    private(set) var linkGeneration = 0
    private var autoRetried = false
    var displayName: String

    private let deviceName: String

    init(channel: EPGChannel) {
        self.channel = channel
        self.displayName = channel.name
        self.deviceName = UIDevice.current.name
        configureAudioSession()
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Non-fatal; playback can still proceed in most cases.
        }
    }

    func loadLink() async {
        isLoading = true
        errorMessage = nil
        do {
            let links = try await APIClient.shared.liveLinks(streamID: channel.streamId)
            if let name = links.streamDisplayName, !name.isEmpty { displayName = name }
            guard let link = links.liveLink, let url = URL(string: link) else {
                throw APIError.api(code: -1, message: "This channel returned no playable link.")
            }
            streamURL = url
            playbackError = nil
            linkGeneration += 1
            isLoading = false
            // Fire-and-forget history ping.
            await APIClient.shared.reportHistory(streamID: channel.streamId,
                                                 streamName: displayName,
                                                 device: deviceName)
        } catch {
            isLoading = false
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    func reportError() {
        Task {
            await APIClient.shared.reportStreamError(streamID: channel.streamId,
                                                     streamName: displayName,
                                                     device: deviceName)
        }
    }

    /// The player item failed. Retry once automatically with a freshly
    /// fetched live link (links can go stale); if it fails again, show the
    /// player the actual error instead of a silent black screen.
    func handlePlaybackFailure(_ message: String) {
        reportError()
        if !autoRetried {
            autoRetried = true
            streamURL = nil   // back to the loading UI while we refetch
            Task { await loadLink() }
        } else {
            isLoading = false
            playbackError = message
        }
    }

    /// Manual retry from the error panel.
    func retryPlayback() {
        autoRetried = false
        playbackError = nil
        Task { await loadLink() }
    }
}

// MARK: - SwiftUI player screen

struct PlayerView: View {
    @State private var model: PlayerModel
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    init(channel: EPGChannel) {
        _model = State(initialValue: PlayerModel(channel: channel))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let err = model.playbackError {
                playbackErrorPanel(err)
            } else if let url = model.streamURL {
                AVPlayerContainer(url: url, generation: model.linkGeneration,
                                  onPlaybackError: { model.handlePlaybackFailure($0) })
                    .ignoresSafeArea()
                    .overlay(alignment: .topLeading) {
                        LiveBadge()
                            .padding(.top, 14)
                            .padding(.leading, 16)
                    }
                    .overlay(alignment: .topTrailing) {
                        // Explicit AirPlay route picker (the player controls
                        // also offer one); external playback is enabled on
                        // the AVPlayer itself.
                        AirPlayButton()
                            .frame(width: 44, height: 44)
                            .glassControl(cornerRadius: 22, tint: .black)
                            .padding(.top, 8)
                            .padding(.trailing, 12)
                    }
            } else if model.isLoading {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text("Loading \(model.displayName)…")
                        .foregroundStyle(.white.opacity(0.85))
                        .font(.callout)
                }
            } else if let err = model.errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.yellow)
                    Text("Playback problem")
                        .font(.headline).foregroundStyle(.white)
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button {
                        Task { await model.loadLink() }
                    } label: {
                        Label("Try Again", systemImage: "arrow.clockwise")
                            .padding(.horizontal, 18).padding(.vertical, 10)
                    }
                    .glassControl(cornerRadius: 12, tint: .accentColor)
                    .foregroundStyle(.white)
                }
            }
        }
        .navigationTitle(model.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        openExternal()
                    } label: {
                        Label("Open in External Player", systemImage: "arrow.up.forward.app")
                    }
                    .disabled(model.streamURL == nil)
                    Button {
                        if let url = model.streamURL {
                            ExternalPlayerLauncher.presentShareSheet(urlString: url.absoluteString)
                        }
                    } label: {
                        Label("Share Stream Link", systemImage: "square.and.arrow.up")
                    }
                    .disabled(model.streamURL == nil)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.white)
                }
            }
        }
        .task { await model.loadLink() }
    }

    private func openExternal() {
        guard let url = model.streamURL else { return }
        let choice = settings.externalPlayer == .native ? ExternalPlayerChoice.vlc : settings.externalPlayer
        ExternalPlayerLauncher.open(streamURL: url.absoluteString, choice: choice) { _ in }
    }

    /// Shown when the stream itself fails inside AVPlayer: the real error
    /// text, a retry, and a one-tap jump to the external player.
    private func playbackErrorPanel(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.yellow)
            Text("This stream didn't start")
                .font(.headline).foregroundStyle(.white)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            HStack(spacing: 12) {
                Button {
                    model.retryPlayback()
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .padding(.horizontal, 16).padding(.vertical, 10)
                }
                .glassControl(cornerRadius: 12, tint: .accentColor)
                Button {
                    openExternal()
                } label: {
                    Label("Open in External Player", systemImage: "arrow.up.forward.app")
                        .padding(.horizontal, 16).padding(.vertical, 10)
                }
                .glassControl(cornerRadius: 12, tint: .white)
            }
            .foregroundStyle(.white)
        }
    }
}

// MARK: - AVPlayerViewController bridge

struct AVPlayerContainer: UIViewControllerRepresentable {
    let url: URL
    /// Changes whenever a fresh live link was fetched; forces an item swap
    /// even when the URL string itself is unchanged.
    var generation: Int = 0
    var onPlaybackError: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(onPlaybackError: onPlaybackError) }

    /// IPTV panels/CDNs expect the client app's user agent (this is the UA
    /// the Android app sends); AVPlayer otherwise uses a generic media UA.
    static func makeItem(url: URL) -> AVPlayerItem {
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetHTTPHeaderFieldsKey: ["User-Agent": "viutvapp/1.12 LH"]
        ])
        return AVPlayerItem(asset: asset)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let item = Self.makeItem(url: url)
        context.coordinator.lastGeneration = generation
        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = true            // AirPlay video
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        player.automaticallyWaitsToMinimizeStalling = true

        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.showsPlaybackControls = true
        vc.videoGravity = .resizeAspect
        vc.delegate = context.coordinator
        if #available(iOS 16.0, *) {
            vc.allowsVideoFrameAnalysis = false
        }

        context.coordinator.observe(item: item)
        player.play()
        return vc
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        // Swap the item when a fresh link was fetched (generation changed) —
        // a URL comparison is not enough, retries often return the same URL.
        if generation != context.coordinator.lastGeneration {
            context.coordinator.lastGeneration = generation
            let item = Self.makeItem(url: url)
            uiViewController.player?.replaceCurrentItem(with: item)
            context.coordinator.observe(item: item)
            uiViewController.player?.play()
        }
    }

    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: Coordinator) {
        uiViewController.player?.pause()
        uiViewController.player = nil
        coordinator.invalidate()
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        private var statusObservation: NSKeyValueObservation?
        private let onPlaybackError: ((String) -> Void)?
        private var reported = false
        var lastGeneration = 0

        init(onPlaybackError: ((String) -> Void)?) {
            self.onPlaybackError = onPlaybackError
        }

        func observe(item: AVPlayerItem) {
            statusObservation?.invalidate()
            reported = false
            statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard let self else { return }
                if item.status == .failed, !self.reported {
                    self.reported = true
                    self.onPlaybackError?(Self.describe(item.error))
                }
            }
        }

        /// "Domain code: description" for the item's error, so a failure is
        /// never just a black screen — the message can be read and reported.
        static func describe(_ error: Error?) -> String {
            guard let error else { return "The player reported an unknown error." }
            let ns = error as NSError
            var text = "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                text += " (\(underlying.domain) \(underlying.code))"
            }
            return text
        }

        func invalidate() {
            statusObservation?.invalidate()
            statusObservation = nil
        }

        // Keep playback going when PiP starts from inline.
        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {}
    }
}

// MARK: - AirPlay route picker (SwiftUI wrapper)

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = true
        v.tintColor = UIColor.white
        v.activeTintColor = UIColor.systemRed
        v.backgroundColor = .clear
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
