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

            if let url = model.streamURL {
                AVPlayerContainer(url: url, onPlaybackError: { model.reportError() })
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
}

// MARK: - AVPlayerViewController bridge

struct AVPlayerContainer: UIViewControllerRepresentable {
    let url: URL
    var onPlaybackError: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(onPlaybackError: onPlaybackError) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let item = AVPlayerItem(url: url)
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
        // Swap the item if the URL changed (e.g. retry).
        if let currentAsset = (uiViewController.player?.currentItem?.asset as? AVURLAsset),
           currentAsset.url != url {
            let item = AVPlayerItem(url: url)
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
        private let onPlaybackError: (() -> Void)?
        private var reported = false

        init(onPlaybackError: (() -> Void)?) {
            self.onPlaybackError = onPlaybackError
        }

        func observe(item: AVPlayerItem) {
            statusObservation?.invalidate()
            reported = false
            statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard let self else { return }
                if item.status == .failed, !self.reported {
                    self.reported = true
                    self.onPlaybackError?()
                }
            }
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
