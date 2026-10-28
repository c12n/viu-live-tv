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
import MediaPlayer
import OSLog
import Network
import Security

/// Playback lifecycle log — visible in Console and in the CI simulator
/// test's captured logs (used to prove real playback end to end).
let viuPlaybackLog = Logger(subsystem: "com.c12n.viulivetv", category: "playback")

// MARK: - Player model

@Observable
@MainActor
final class PlayerModel {
    var channel: EPGChannel
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

    /// Switch to a different channel in place (channel guide picks).
    func switchChannel(_ newChannel: EPGChannel) {
        channel = newChannel
        displayName = newChannel.name
        autoRetried = false
        playbackError = nil
        errorMessage = nil
        streamURL = nil
        Task { await loadLink() }
    }
}

// MARK: - Player control handle

/// Lets SwiftUI gestures reach the AVPlayer owned by AVPlayerContainer
/// (double-tap to pause/resume). Not observed — just a shared handle.
final class PlayerControl {
    weak var player: AVPlayer?

    var isPlaying: Bool {
        guard let player else { return false }
        return player.timeControlStatus == .playing || player.rate > 0
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying { player.pause() } else { player.play() }
    }
}

// MARK: - SwiftUI player screen

struct PlayerView: View {
    @State private var model: PlayerModel
    @State private var control = PlayerControl()
    /// Minimal auto-hiding chrome: only the channel-guide button, shown
    /// briefly on open and on tap, then gone — otherwise the screen is
    /// purely the video.
    @State private var chromeVisible = true
    @State private var chromeHideTask: Task<Void, Never>?
    @State private var showGuide = false
    @State private var guideTab: ChannelTab = .all
    @State private var cast = CastManager()
    @State private var showCast = false
    /// Brief centre play/pause flash after a double-tap (true = resumed).
    @State private var toggleFlash: Bool?
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    init(channel: EPGChannel) {
        _model = State(initialValue: PlayerModel(channel: channel))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if cast.isCastingMedia {
                castingPanel
            } else if let err = model.playbackError {
                playbackErrorPanel(err)
            } else if let url = model.streamURL {
                AVPlayerContainer(url: url, generation: model.linkGeneration,
                                  title: model.displayName,
                                  pipEnabled: settings.pictureInPictureEnabled,
                                  backgroundEnabled: settings.backgroundPlayEnabled,
                                  control: control,
                                  onPlaybackError: { model.handlePlaybackFailure($0) })
                    .ignoresSafeArea()
                    // Single tap: light haptic + show the guide chrome.
                    .simultaneousGesture(TapGesture().onEnded {
                        Haptics.light()
                        showChrome()
                    })
                    // Double tap: pause / resume the live stream.
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        control.togglePlayPause()
                        Haptics.medium()
                        flashToggle()
                    })
                    .overlay(alignment: .topLeading) {
                        if chromeVisible {
                            HStack(spacing: 10) {
                                Button {
                                    Haptics.light()
                                    showGuide = true
                                } label: {
                                    Label("Guide", systemImage: "list.bullet")
                                        .font(.callout.weight(.semibold))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 9)
                                }
                                .glassControl(cornerRadius: 20, tint: .black)
                                .foregroundStyle(.white)

                                Button {
                                    Haptics.light()
                                    showCast = true
                                } label: {
                                    CastGlyph(active: cast.isCastingMedia)
                                        .padding(.horizontal, 13)
                                        .padding(.vertical, 10)
                                }
                                .glassControl(cornerRadius: 20, tint: .black)
                                .foregroundStyle(cast.phase == .idle ? .white : settings.accent.color)
                                .accessibilityLabel("Chromecast")
                            }
                            // Low enough to clear the native player's own top
                            // control bar (AirPlay / PiP / volume live there).
                            .padding(.top, 58)
                            .padding(.leading, 12)
                            .transition(.opacity)
                        }
                    }
                    .overlay {
                        if let toggleFlash {
                            Image(systemName: toggleFlash ? "play.fill" : "pause.fill")
                                .font(.system(size: 54, weight: .bold))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.6), radius: 12)
                                .transition(.opacity)
                        }
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
                    .glassControl(cornerRadius: 12, tint: settings.accent.color)
                    .foregroundStyle(.white)
                }
            }
        }
        // The player screen is only the video: no channel-name title, no
        // LIVE badge, no nav bar, no permanent buttons. The single Guide
        // button fades in on tap and auto-hides. Back to the channel list =
        // swipe right from the left edge of the screen.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .simultaneousGesture(edgeSwipeBackGesture)
        .sheet(isPresented: $showGuide) {
            ChannelGuideSheet(tab: $guideTab) { picked in
                showGuide = false
                if picked.streamId != model.channel.streamId {
                    model.switchChannel(picked)
                    showChrome()
                }
            }
        }
        .sheet(isPresented: $showCast) {
            castSheet
        }
        .onChange(of: cast.isReady) { _, ready in
            if ready { loadCurrentChannelToCast() }
        }
        .onChange(of: model.streamURL) { _, _ in
            loadCurrentChannelToCast()
        }
        .task {
            showChrome()
            cast.startDiscovery()
            await model.loadLink()
        }
        .onDisappear {
            cast.stopDiscovery()
            cast.disconnect()
        }
    }

    /// Send the currently loaded channel to the TV once a cast session
    /// is ready (and again whenever the channel/link changes, e.g. a
    /// guide pick while casting). The manager de-dupes repeats.
    private func loadCurrentChannelToCast() {
        guard cast.isReady, let url = model.streamURL else { return }
        cast.load(url: url, title: model.displayName,
                  image: model.channel.streamIcon.flatMap { URL(string: $0) })
    }

    // MARK: Casting UI

    /// Shown instead of the local video while the TV is playing: what's
    /// casting, its state, and the remote controls.
    private var castingPanel: some View {
        VStack(spacing: 16) {
            CastGlyph(active: true)
                .scaleEffect(2.2)
                .foregroundStyle(settings.accent.color)
                .frame(height: 44)
            Text("Casting to \(cast.connectedDeviceName ?? "TV")")
                .font(.headline)
                .foregroundStyle(.white)
            Text(model.displayName)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
            if !cast.remotePlayerState.isEmpty {
                Text(cast.remotePlayerState.capitalized)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }
            HStack(spacing: 14) {
                Button {
                    cast.togglePlayPause()
                    Haptics.light()
                } label: {
                    Label(cast.remotePlayerState == "PLAYING" ? "Pause" : "Play",
                          systemImage: cast.remotePlayerState == "PLAYING" ? "pause.fill" : "play.fill")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
                .glassControl(cornerRadius: 12, tint: settings.accent.color)
                .foregroundStyle(.white)

                Button {
                    cast.stopCasting()
                    Haptics.medium()
                } label: {
                    Label("Stop Casting", systemImage: "xmark")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
                .glassControl(cornerRadius: 12, tint: .black)
                .foregroundStyle(.white)
            }
            Button {
                Haptics.light()
                showGuide = true
            } label: {
                Label("Guide", systemImage: "list.bullet")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
            }
            .glassControl(cornerRadius: 20, tint: .black)
            .foregroundStyle(.white)
            .padding(.top, 4)
        }
        .padding(24)
    }

    /// Device picker (before connecting) and session controls (after).
    private var castSheet: some View {
        NavigationStack {
            Group {
                if cast.phase == .idle || cast.phase == .connecting {
                    List {
                        Section {
                            ForEach(cast.devices) { device in
                                Button {
                                    cast.connect(to: device)
                                    showCast = false
                                    Haptics.light()
                                } label: {
                                    HStack(spacing: 12) {
                                        CastGlyph()
                                        Text(device.name)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        if cast.phase == .connecting && cast.connectedDeviceName == device.name {
                                            ProgressView()
                                        }
                                    }
                                }
                            }
                        } header: {
                            Text("Cast to")
                        } footer: {
                            Text(cast.devices.isEmpty
                                 ? "Looking for Chromecast devices on your Wi-Fi… the TV and this device must be on the same network."
                                 : "AirPlay stays available in the player's own controls.")
                        }
                        if let error = cast.lastError {
                            Section {
                                Text(error).foregroundStyle(.red)
                            }
                        }
                    }
                } else {
                    List {
                        Section {
                            LabeledContent("Device", value: cast.connectedDeviceName ?? "—")
                            LabeledContent("Status", value: cast.isCastingMedia ? cast.remotePlayerState.capitalized : "Connected")
                        }
                        Section {
                            Button {
                                cast.togglePlayPause()
                            } label: {
                                Label(cast.remotePlayerState == "PLAYING" ? "Pause" : "Play",
                                      systemImage: cast.remotePlayerState == "PLAYING" ? "pause.fill" : "play.fill")
                            }
                            .disabled(!cast.isCastingMedia)
                            Button(role: .destructive) {
                                cast.stopCasting()
                                showCast = false
                            } label: {
                                Label("Stop Casting", systemImage: "xmark")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Chromecast")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showCast = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    /// Swipe right starting from the left screen edge → back to the list.
    private var edgeSwipeBackGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onEnded { value in
                guard value.startLocation.x < 28,
                      value.translation.width > 70,
                      abs(value.translation.height) < 45 else { return }
                Haptics.light()
                dismiss()
            }
    }

    /// Show the Guide chrome and restart its auto-hide timer.
    private func showChrome() {
        withAnimation(.easeInOut(duration: 0.2)) { chromeVisible = true }
        chromeHideTask?.cancel()
        chromeHideTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.25)) { chromeVisible = false }
            }
        }
    }

    /// Flash a big play/pause glyph briefly after a double-tap.
    private func flashToggle() {
        toggleFlash = control.isPlaying
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            await MainActor.run { toggleFlash = nil }
        }
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
                .glassControl(cornerRadius: 12, tint: settings.accent.color)
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

// MARK: - Channel guide sheet

/// The channel guide over the player: the full channel list in a sheet.
/// Picking a channel switches playback in place; Done returns to the video.
struct ChannelGuideSheet: View {
    @Binding var tab: ChannelTab
    var onPick: (EPGChannel) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ChannelListView(selection: .constant(nil), tab: $tab,
                            onChannelPicked: onPick)
                .navigationTitle("Channel Guide")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

// MARK: - AVPlayerViewController bridge

struct AVPlayerContainer: UIViewControllerRepresentable {
    let url: URL
    /// Changes whenever a fresh live link was fetched; forces an item swap
    /// even when the URL string itself is unchanged.
    var generation: Int = 0
    /// Channel name for the Now Playing info (lock screen / Control Centre).
    var title: String = ""
    /// Settings toggles: Picture in Picture and background play.
    var pipEnabled: Bool = true
    var backgroundEnabled: Bool = true
    /// Receives the AVPlayer so SwiftUI gestures can pause/resume it.
    var control: PlayerControl?
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
        vc.allowsPictureInPicturePlayback = pipEnabled
        vc.canStartPictureInPictureAutomaticallyFromInline = pipEnabled
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
        control?.player = player

        // Background play + Picture in Picture: the app declares the
        // `audio` background mode (Info.plist UIBackgroundModes) and the
        // player is PiP-enabled; here we activate the playback audio
        // session and publish Now Playing info with lock-screen /
        // Control Centre play-pause commands, which is what lets audio
        // keep playing with the screen locked and lets PiP start
        // automatically when the app is backgrounded.
        if backgroundEnabled {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            // Non-fatal; foreground playback is unaffected.
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title.isEmpty ? "Viu Live TV" : title,
            // MPNowPlayingInfoPropertyIsLiveStream (literal — the named
            // media-item constant isn't exposed to Swift in this SDK).
            "MPNowPlayingInfoPropertyIsLiveStream": true
        ]
        let commands = MPRemoteCommandCenter.shared()
        let playTarget = commands.playCommand.addTarget { _ in
            player.play()
            return .success
        }
        let pauseTarget = commands.pauseCommand.addTarget { _ in
            player.pause()
            return .success
        }
        context.coordinator.remoteTargets = [playTarget, pauseTarget]
        } else {
            // Background Play is off in Settings: pause as soon as the
            // app leaves the foreground instead of playing on.
            context.coordinator.backgroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil, queue: .main
            ) { _ in
                player.pause()
            }
        }

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
        let commands = MPRemoteCommandCenter.shared()
        for target in coordinator.remoteTargets {
            commands.playCommand.removeTarget(target)
            commands.pauseCommand.removeTarget(target)
        }
        coordinator.remoteTargets = []
        if let observer = coordinator.backgroundObserver {
            NotificationCenter.default.removeObserver(observer)
            coordinator.backgroundObserver = nil
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
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
        var remoteTargets: [Any] = []
        var backgroundObserver: NSObjectProtocol?

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

        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  failedToStartPictureInPictureWithError error: Error) {
            viuPlaybackLog.error("VIU_PLAYBACK PiP failed to start: \(error.localizedDescription, privacy: .public)")
        }

        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
            completionHandler(true)
        }
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

// MARK: - Chromecast (hand-rolled CASTV2 client)
//
// The official Cast SDK ships only as a large XCFramework download,
// which this project's text-based repo sync can't carry, so casting
// speaks the CASTV2 protocol directly: Bonjour discovery
// (_googlecast._tcp), a TLS connection to the device on port 8009,
// and length-prefixed protobuf envelopes carrying JSON payloads —
// the protocol the Default Media Receiver (CC1AD845) speaks. The
// streams are plain HLS, which the receiver plays natively. AirPlay
// remains available through the native player as before.

struct CastDevice: Identifiable {
    let name: String
    let endpoint: NWEndpoint
    var id: String { name }
}

/// The Cast glyph (SF Symbols has no cast icon): a screen outline
/// with the signal waves in its bottom-left corner.
struct CastGlyph: View {
    var active: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .stroke(lineWidth: 1.8)
                .background {
                    if active {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.white.opacity(0.22))
                    }
                }
            Canvas { context, size in
                let origin = CGPoint(x: 3.5, y: size.height - 3.5)
                for radius in [4.5, 8.0] {
                    var path = Path()
                    path.addArc(center: origin, radius: radius,
                                startAngle: .degrees(-90), endAngle: .degrees(0),
                                clockwise: true)
                    context.stroke(path, with: .foreground, lineWidth: 1.6)
                }
                let dot = Path(ellipseIn: CGRect(x: origin.x - 1.2, y: origin.y - 1.2,
                                                 width: 2.4, height: 2.4))
                context.fill(dot, with: .foreground)
            }
        }
        .frame(width: 24, height: 17)
    }
}

@Observable
final class CastManager {
    enum Phase { case idle, connecting, connected, ready }

    private(set) var phase: Phase = .idle
    private(set) var devices: [CastDevice] = []
    private(set) var connectedDeviceName: String?
    /// True once a LOAD has been sent for the current channel.
    private(set) var isCastingMedia = false
    /// Last MEDIA_STATUS playerState: PLAYING / PAUSED / BUFFERING / IDLE.
    private(set) var remotePlayerState = ""
    var lastError: String?

    var isReady: Bool { phase == .ready }

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var heartbeatTimer: Timer?
    private var requestCounter = 0
    private var mediaTransportId: String?
    private var receiverSessionId: String?
    private var mediaSessionId: Int?
    private var appTransportConnected = false
    private var pendingMedia: (url: URL, title: String, image: URL?)?
    private var lastLoadedURL: URL?

    private static let senderId = "sender-0"
    private static let receiverId = "receiver-0"
    private static let defaultReceiverAppId = "CC1AD845"
    private static let nsConnection = "urn:x-cast:com.google.cast.tp.connection"
    private static let nsHeartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
    private static let nsReceiver = "urn:x-cast:com.google.cast.receiver"
    private static let nsMedia = "urn:x-cast:com.google.cast.media"

    // MARK: Discovery

    func startDiscovery() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_googlecast._tcp", domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            var found: [CastDevice] = []
            for result in results {
                if case .service(let name, _, _, _) = result.endpoint {
                    found.append(CastDevice(name: name, endpoint: result.endpoint))
                }
            }
            self?.devices = found.sorted { $0.name < $1.name }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    func stopDiscovery() {
        browser?.cancel()
        browser = nil
        if phase == .idle { devices = [] }
    }

    // MARK: Connection

    func connect(to device: CastDevice) {
        disconnect()
        phase = .connecting
        connectedDeviceName = device.name
        lastError = nil

        // Chromecasts present self-signed certificates; the Cast
        // protocol relies on the local-network pairing instead.
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in
            complete(true)
        }, DispatchQueue.main)
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let connection = NWConnection(to: device.endpoint, using: params)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.transportReady()
            case .failed(let error):
                self?.lastError = "Couldn't connect to the TV: \(error.localizedDescription)"
                self?.disconnect()
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    private func transportReady() {
        phase = .connected
        receiveLoop()
        send(namespace: Self.nsConnection, destination: Self.receiverId,
             payload: ["type": "CONNECT"])
        send(namespace: Self.nsReceiver, destination: Self.receiverId,
             payload: ["type": "LAUNCH", "appId": Self.defaultReceiverAppId,
                       "requestId": nextRequestId()])
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.send(namespace: Self.nsHeartbeat, destination: Self.receiverId,
                       payload: ["type": "PING"])
        }
    }

    func disconnect() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        connection?.cancel()
        connection = nil
        receiveBuffer = Data()
        phase = .idle
        connectedDeviceName = nil
        mediaTransportId = nil
        receiverSessionId = nil
        mediaSessionId = nil
        appTransportConnected = false
        isCastingMedia = false
        remotePlayerState = ""
        lastLoadedURL = nil
        pendingMedia = nil
    }

    deinit {
        browser?.cancel()
        connection?.cancel()
        heartbeatTimer?.invalidate()
    }

    // MARK: Media control

    func load(url: URL, title: String, image: URL?) {
        if url == lastLoadedURL && isCastingMedia { return }
        if appTransportConnected {
            sendLoad(url: url, title: title, image: image)
        } else if phase == .connected || phase == .connecting {
            pendingMedia = (url, title, image)
        }
    }

    private func sendLoad(url: URL, title: String, image: URL?) {
        guard let transportId = mediaTransportId else { return }
        lastLoadedURL = url
        var metadata: [String: Any] = ["metadataType": 0, "title": title]
        if let image { metadata["images"] = [["url": image.absoluteString]] }
        let media: [String: Any] = [
            "contentId": url.absoluteString,
            "contentType": "application/x-mpegURL",
            "streamType": "LIVE",
            "metadata": metadata,
        ]
        send(namespace: Self.nsMedia, destination: transportId, payload: [
            "type": "LOAD",
            "requestId": nextRequestId(),
            "media": media,
            "currentTime": 0,
            "autoplay": true,
            "activeTrackIds": [],
            "customData": [:],
        ])
        isCastingMedia = true
        remotePlayerState = "BUFFERING"
    }

    func togglePlayPause() {
        guard let transportId = mediaTransportId else { return }
        var payload: [String: Any] = [
            "type": remotePlayerState == "PLAYING" ? "PAUSE" : "PLAY",
            "requestId": nextRequestId(),
        ]
        if let mediaSessionId { payload["mediaSessionId"] = mediaSessionId }
        send(namespace: Self.nsMedia, destination: transportId, payload: payload)
    }

    func stopCasting() {
        if let transportId = mediaTransportId {
            if let mediaSessionId {
                send(namespace: Self.nsMedia, destination: transportId,
                     payload: ["type": "STOP", "requestId": nextRequestId(),
                               "mediaSessionId": mediaSessionId])
            }
            send(namespace: Self.nsConnection, destination: transportId,
                 payload: ["type": "CLOSE"])
        }
        if let receiverSessionId {
            send(namespace: Self.nsReceiver, destination: Self.receiverId,
                 payload: ["type": "STOP", "sessionId": receiverSessionId,
                           "requestId": nextRequestId()])
        }
        isCastingMedia = false
        remotePlayerState = ""
        // Give the STOP messages a beat to flush before hanging up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.disconnect()
        }
    }

    // MARK: Incoming messages

    private func route(namespace: String, source: String, payload: [String: Any]) {
        let type = payload["type"] as? String ?? ""
        switch namespace {
        case Self.nsHeartbeat:
            if type == "PING" {
                send(namespace: Self.nsHeartbeat,
                     destination: source.isEmpty ? Self.receiverId : source,
                     payload: ["type": "PONG"])
            }
        case Self.nsReceiver:
            if type == "RECEIVER_STATUS" { handleReceiverStatus(payload) }
            if type == "LAUNCH_ERROR" { lastError = "The TV couldn't start its player app." }
        case Self.nsMedia:
            if type == "MEDIA_STATUS" { handleMediaStatus(payload) }
            if type == "LOAD_FAILED" || type == "LOAD_CANCELLED" {
                isCastingMedia = false
                lastError = "The TV couldn't play this channel."
            }
        case Self.nsConnection:
            if type == "CLOSE" { appTransportClosed() }
        default:
            break
        }
    }

    private func handleReceiverStatus(_ payload: [String: Any]) {
        guard let status = payload["status"] as? [String: Any],
              let apps = status["applications"] as? [[String: Any]] else { return }
        guard let app = apps.first(where: { ($0["appId"] as? String) == Self.defaultReceiverAppId }),
              let transportId = app["transportId"] as? String else {
            // The receiver app isn't running (stopped from elsewhere).
            if mediaTransportId != nil { appTransportClosed() }
            return
        }
        receiverSessionId = app["sessionId"] as? String
        if mediaTransportId != transportId {
            mediaTransportId = transportId
            appTransportConnected = false
        }
        if !appTransportConnected {
            appTransportConnected = true
            send(namespace: Self.nsConnection, destination: transportId,
                 payload: ["type": "CONNECT"])
            phase = .ready
            if let pending = pendingMedia {
                pendingMedia = nil
                sendLoad(url: pending.url, title: pending.title, image: pending.image)
            }
        }
    }

    private func handleMediaStatus(_ payload: [String: Any]) {
        guard let status = payload["status"] as? [[String: Any]],
              let first = status.first else { return }
        if let id = first["mediaSessionId"] as? Int { mediaSessionId = id }
        let state = first["playerState"] as? String ?? ""
        remotePlayerState = state
        if state == "IDLE" {
            let reason = first["idleReason"] as? String ?? ""
            if reason == "FINISHED" || reason == "CANCELLED" || reason == "ERROR" {
                isCastingMedia = false
            }
        } else if !state.isEmpty {
            isCastingMedia = true
        }
    }

    private func appTransportClosed() {
        mediaTransportId = nil
        mediaSessionId = nil
        appTransportConnected = false
        isCastingMedia = false
        remotePlayerState = ""
        if phase == .ready { phase = .connected }
    }

    // MARK: CASTV2 wire format
    //
    // Frames are a 4-byte big-endian length + a CastMessage protobuf:
    // 1 protocol_version (varint, 0), 2 source_id, 3 destination_id,
    // 4 namespace, 5 payload_type (varint, 0 = STRING), 6 payload_utf8.

    private func nextRequestId() -> Int {
        requestCounter += 1
        return requestCounter
    }

    private func send(namespace: String, destination: String, payload: [String: Any]) {
        guard let connection else { return }
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: json, encoding: .utf8) else { return }
        var message = Data()
        message.append(protoFieldVarint(1, 0))
        message.append(protoFieldString(2, Self.senderId))
        message.append(protoFieldString(3, destination))
        message.append(protoFieldString(4, namespace))
        message.append(protoFieldVarint(5, 0))
        message.append(protoFieldString(6, jsonString))
        var frame = Data()
        let length = UInt32(message.count)
        frame.append(UInt8((length >> 24) & 0xFF))
        frame.append(UInt8((length >> 16) & 0xFF))
        frame.append(UInt8((length >> 8) & 0xFF))
        frame.append(UInt8(length & 0xFF))
        frame.append(message)
        connection.send(content: frame, completion: .idempotent)
    }

    private func protoVarint(_ value: UInt64) -> Data {
        var v = value
        var out = Data()
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    private func protoFieldVarint(_ field: Int, _ value: UInt64) -> Data {
        var out = protoVarint(UInt64((field << 3) | 0))
        out.append(protoVarint(value))
        return out
    }

    private func protoFieldString(_ field: Int, _ string: String) -> Data {
        let bytes = [UInt8](string.utf8)
        var out = protoVarint(UInt64((field << 3) | 2))
        out.append(protoVarint(UInt64(bytes.count)))
        out.append(contentsOf: bytes)
        return out
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.drainFrames()
            }
            if error != nil {
                if self.phase != .idle { self.disconnect() }
                return
            }
            if !isComplete { self.receiveLoop() }
        }
    }

    private func drainFrames() {
        while receiveBuffer.count >= 4 {
            let b = [UInt8](receiveBuffer.prefix(4))
            let length = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
            guard length >= 0, receiveBuffer.count >= 4 + length else { return }
            let frame = receiveBuffer.subdata(in: 4..<(4 + length))
            receiveBuffer.removeSubrange(0..<(4 + length))
            handleMessage(frame)
        }
    }

    private func handleMessage(_ data: Data) {
        var namespace = ""
        var source = ""
        var payloadString: String?
        var index = data.startIndex

        func readVarint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while index < data.endIndex {
                let byte = data[index]
                index = data.index(after: index)
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }

        while index < data.endIndex {
            guard let tag = readVarint() else { return }
            let field = Int(tag >> 3)
            let wire = Int(tag & 7)
            switch wire {
            case 0:
                _ = readVarint()
            case 2:
                guard let len = readVarint(),
                      data.distance(from: index, to: data.endIndex) >= Int(len) else { return }
                let slice = data.subdata(in: index..<data.index(index, offsetBy: Int(len)))
                index = data.index(index, offsetBy: Int(len))
                if field == 2 { source = String(decoding: slice, as: UTF8.self) }
                if field == 4 { namespace = String(decoding: slice, as: UTF8.self) }
                if field == 6 { payloadString = String(decoding: slice, as: UTF8.self) }
            case 1:
                index = data.index(index, offsetBy: 8, limitedBy: data.endIndex) ?? data.endIndex
            case 5:
                index = data.index(index, offsetBy: 4, limitedBy: data.endIndex) ?? data.endIndex
            default:
                return
            }
        }

        guard let payloadString,
              let jsonData = payloadString.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else { return }
        route(namespace: namespace, source: source, payload: payload)
    }
}
