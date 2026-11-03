//
//  MacPlayerView.swift
//  Viu Live TV — macOS
//
//  Detail-column player: AVKit's native Mac player view (floating
//  controls, PiP), a channel header, and actions for Last Channel,
//  the guide, Multiview and Favorite.
//

import SwiftUI
import AVKit
import AVFoundation

struct MacPlayerView: View {
    @Environment(EPGStore.self) private var epg
    @Environment(FavoritesStore.self) private var favorites
    @Environment(AppSettings.self) private var settings
    @Environment(ParentalControls.self) private var parental

    let contextList: [EPGChannel]
    @State private var channel: EPGChannel
    @State private var previous: EPGChannel?
    @State private var player = AVPlayer()
    @State private var loading = true
    @State private var errorText: String?
    @State private var showGuide = false
    @State private var showMultiview = false
    @State private var pinFor: EPGChannel?

    init(channel: EPGChannel, contextList: [EPGChannel]) {
        self.contextList = contextList
        _channel = State(initialValue: channel)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                MacAVPlayerView(player: player)
                if loading {
                    ProgressView().controlSize(.large)
                }
                if let errorText {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle).foregroundStyle(.yellow)
                        Text(errorText).foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                        Button("Retry") { Task { await load() } }
                    }
                    .padding(40)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)

            HStack(spacing: 14) {
                LiveBadge()
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name).font(.title3.weight(.semibold))
                    Text(nowNextLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let previous {
                    Button {
                        requestSwitch(previous)
                    } label: {
                        Label("Last: \(previous.name)",
                              systemImage: "arrow.uturn.backward")
                    }
                }
                Button {
                    showGuide = true
                } label: {
                    Label("Guide", systemImage: "list.bullet")
                }
                .popover(isPresented: $showGuide, arrowEdge: .bottom) {
                    guideList
                }
                Button {
                    showMultiview = true
                } label: {
                    Label("Multiview", systemImage: "square.grid.2x2")
                }
                Button {
                    favorites.toggle(channel)
                } label: {
                    Label(favorites.isFavorite(channel.streamId) ? "Favorited" : "Favorite",
                          systemImage: favorites.isFavorite(channel.streamId)
                            ? "heart.fill" : "heart")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            HStack(spacing: 10) {
                Button {
                    hop(-1)
                } label: {
                    Label("Previous Channel", systemImage: "chevron.up")
                }
                Button {
                    hop(1)
                } label: {
                    Label("Next Channel", systemImage: "chevron.down")
                }
                Spacer()
                Text(channel.language.label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            Spacer(minLength: 0)
        }
        .task(id: channel.streamId) { await load() }
        .onDisappear { player.pause() }
        .sheet(isPresented: $showMultiview) {
            MacMultiviewView(initial: channel) { picked in
                if let picked, picked.streamId != channel.streamId {
                    requestSwitch(picked)
                }
            }
            .frame(minWidth: 1060, minHeight: 640)
        }
        .sheet(item: $pinFor) { target in
            MacPINEntryView(title: "Enter PIN to watch \(target.name)") { pin in
                pinFor = nil
                if let pin, parental.verify(pin) {
                    switchChannel(target)
                }
            }
            .frame(width: 340)
        }
    }

    private var nowNextLine: String {
        var parts: [String] = []
        if let now = channel.nowProgramme() { parts.append("Now: \(now.name)") }
        if let next = channel.nextProgramme() { parts.append("Next: \(next.name)") }
        return parts.isEmpty ? channel.nowText() : parts.joined(separator: "   ·   ")
    }

    private var guideList: some View {
        List(contextList) { item in
            Button {
                showGuide = false
                if item.streamId != channel.streamId {
                    requestSwitch(item)
                }
            } label: {
                HStack {
                    if item.streamId == channel.streamId {
                        Image(systemName: "play.fill").foregroundStyle(.tint)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name)
                        Text(item.nowText())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if favorites.isFavorite(item.streamId) {
                        Image(systemName: "heart.fill").foregroundStyle(.yellow)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .frame(width: 380, height: 460)
    }

    // MARK: Playback

    private func load() async {
        loading = true
        errorText = nil
        settings.recordRecent(streamID: channel.streamId)
        do {
            let links = try await APIClient.shared.liveLinks(streamID: channel.streamId)
            if links.isFavorite {
                favorites.mergeServerFavorite(streamID: channel.streamId, isFavorite: true)
            }
            guard let link = links.liveLink, let url = URL(string: link) else {
                errorText = "This channel returned no playable link."
                loading = false
                return
            }
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            player.play()
            loading = false
        } catch {
            errorText = "Couldn't load this channel. Check your connection and try again."
            loading = false
        }
    }

    private func switchChannel(_ target: EPGChannel) {
        if target.streamId != channel.streamId {
            previous = channel
        }
        channel = target
    }

    private func requestSwitch(_ target: EPGChannel) {
        if parental.isEnabled && parental.isLocked(target.streamId) {
            pinFor = target
        } else {
            switchChannel(target)
        }
    }

    private func hop(_ delta: Int) {
        guard let idx = contextList.firstIndex(where: { $0.streamId == channel.streamId })
        else { return }
        let next = idx + delta
        guard contextList.indices.contains(next) else { return }
        requestSwitch(contextList[next])
    }
}

// MARK: - AVKit bridge

struct MacAVPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.allowsPictureInPicturePlayback = true
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }
}

/// Layer-only player view for Multiview cells (no chrome).
struct MacPlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> MacPlayerLayerNSView {
        let view = MacPlayerLayerNSView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: MacPlayerLayerNSView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }
}

final class MacPlayerLayerNSView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = AVPlayerLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer = AVPlayerLayer()
    }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
