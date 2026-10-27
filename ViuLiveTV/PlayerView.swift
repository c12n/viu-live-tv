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
import OSLog

/// Playback lifecycle log — visible in Console and in the CI simulator
/// test's captured logs (used to prove real playback end to end).
let viuPlaybackLog = Logger(subsystem: "com.c12n.viulivetv", category: "playback")

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
            viuPlaybackLog.info("VIU_PLAYBACK link ok stream=\(self.channel.streamId, privacy: .public) host=\(url.host ?? "?", privacy: .public)")
            // Fire-and-forget history ping.
            await APIClient.shared.reportHistory(streamID: channel.streamId,
                                                 streamName: displayName,
                                                 device: deviceName)
        } catch {
            isLoading = false
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
            viuPlaybackLog.error("VIU_PLAYBACK link failed stream=\(self.channel.streamId, privacy: .public): \(self.errorMessage ?? "?", privacy: .public)")
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
        // The options key is AVURLAssetHTTPHeaderFieldsKey (literal string —
        // the constant isn't visible to the Swift compiler in this SDK).
        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": "viutvapp/1.12 LH"]
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
        // Heartbeat for the playback log: proves time actually advances.
        let token = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 2, preferredTimescale: 600),
            queue: .main
        ) { time in
            viuPlaybackLog.info("VIU_PLAYBACK t=\(time.seconds, privacy: .public) rate=\(player.rate, privacy: .public) timeControl=\(player.timeControlStatus.rawValue, privacy: .public)")
        }
        context.coordinator.timeObserverToken = token
        context.coordinator.observedPlayer = player
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
        if let token = coordinator.timeObserverToken, let player = coordinator.observedPlayer {
            player.removeTimeObserver(token)
        }
        coordinator.timeObserverToken = nil
        uiViewController.player?.pause()
        uiViewController.player = nil
        coordinator.invalidate()
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        private var statusObservation: NSKeyValueObservation?
        private let onPlaybackError: ((String) -> Void)?
        private var reported = false
        var lastGeneration = 0
        var timeObserverToken: Any?
        weak var observedPlayer: AVPlayer?

        init(onPlaybackError: ((String) -> Void)?) {
            self.onPlaybackError = onPlaybackError
        }

        func observe(item: AVPlayerItem) {
            statusObservation?.invalidate()
            reported = false
            statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    viuPlaybackLog.info("VIU_PLAYBACK item readyToPlay")
                case .failed:
                    viuPlaybackLog.error("VIU_PLAYBACK item failed: \(Self.describe(item.error), privacy: .public)")
                    if !self.reported {
                        self.reported = true
                        self.onPlaybackError?(Self.describe(item.error))
                    }
                default:
                    break
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

// MARK: - CI playback test (env-gated)
//
// Shown instead of the normal UI when the app is launched with
// VIU_PLAYBACK_TEST=1 (the simulator CI does this with a session token in
// VIU_TEST_TOKEN). Signs in with the token, loads the real channel guide,
// then opens VIU_TEST_STREAM (default 4626) in the native player, logging
// VIU_PLAYBACK lines the whole way so the test can verify real playback.
// Inert in normal use: the env vars can only be set by the developer /
// simctl, never by another app on a real device.

struct PlaybackTestView: View {
    @Environment(AuthViewModel.self) private var auth
    @Environment(EPGStore.self) private var epg
    @State private var channel: EPGChannel?
    @State private var phase = "Starting playback test…"

    private var env: [String: String] { ProcessInfo.processInfo.environment }

    var body: some View {
        NavigationStack {
            if let channel {
                PlayerView(channel: channel)
            } else {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text(phase)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
        }
        .task {
            viuPlaybackLog.info("VIU_PLAYBACK test view start")
            if let token = env["VIU_TEST_TOKEN"], !token.isEmpty {
                await auth.useToken(token)
                viuPlaybackLog.info("VIU_PLAYBACK auth state=\(String(describing: auth.state), privacy: .public)")
            }
            phase = "Loading channels…"
            await epg.refresh()
            viuPlaybackLog.info("VIU_PLAYBACK channels=\(epg.channels.count, privacy: .public) state=\(String(describing: epg.state), privacy: .public)")
            let sid = Int(env["VIU_TEST_STREAM"] ?? "") ?? 4626
            channel = epg.channel(for: sid)
                ?? EPGChannel(num: nil, name: "Playback Test", streamType: "live",
                              streamId: sid, streamIcon: nil, epgChannelId: nil,
                              categoryId: nil)
            viuPlaybackLog.info("VIU_PLAYBACK opening player stream=\(sid, privacy: .public)")
        }
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
