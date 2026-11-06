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
    /// 2.0.0 player extras.
    @State private var audioOnly = false
    @State private var showTracks = false
    @State private var sleepTimer = SleepTimer.shared
    @State private var failureCount = 0
    @State private var reconnectAttempt = 0

    init(channel: EPGChannel, contextList: [EPGChannel]) {
        self.contextList = contextList
        _channel = State(initialValue: channel)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                MacAVPlayerView(player: player)
                if audioOnly {
                    ZStack {
                        Color.black
                        VStack(spacing: 10) {
                            Image(systemName: "headphones")
                                .font(.system(size: 44))
                                .foregroundStyle(.white.opacity(0.7))
                            Text(channel.name)
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.white)
                            Text(nowNextLine)
                                .font(.callout)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
                if reconnectAttempt > 0 {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.large)
                        Text("Reconnecting… attempt \(reconnectAttempt) of 3")
                            .foregroundStyle(.white)
                            .font(.callout.weight(.semibold))
                    }
                }
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
                    .keyboardShortcut("l", modifiers: [])
                }
                Button {
                    showGuide = true
                } label: {
                    Label("Guide", systemImage: "list.bullet")
                }
                .keyboardShortcut("g", modifiers: [])
                .popover(isPresented: $showGuide, arrowEdge: .bottom) {
                    guideList
                }
                Button {
                    showMultiview = true
                } label: {
                    Label("Multiview", systemImage: "square.grid.2x2")
                }
                .keyboardShortcut("m", modifiers: [])
                Button {
                    favorites.toggle(channel)
                } label: {
                    Label(favorites.isFavorite(channel.streamId) ? "Favorited" : "Favorite",
                          systemImage: favorites.isFavorite(channel.streamId)
                            ? "heart.fill" : "heart")
                }
                .keyboardShortcut("f", modifiers: [])

                Menu {
                    Section("Sleep Timer") {
                        Button("Off") { sleepTimer.cancel() }
                        ForEach([15, 30, 60, 90], id: \.self) { minutes in
                            Button("\(minutes) minutes") { sleepTimer.start(minutes: minutes) }
                        }
                    }
                    Button("Audio & Subtitles…") { showTracks = true }
                    Button(audioOnly ? "Show Video" : "Audio Only") { audioOnly.toggle() }
                    Section("Stream Health") {
                        Text(healthText)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(healthColor).frame(width: 9, height: 9)
                        Image(systemName: "ellipsis.circle")
                        if sleepTimer.isActive {
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                Text(sleepTimer.remainingText ?? "")
                                    .monospacedDigit()
                            }
                        }
                    }
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
                .keyboardShortcut(.upArrow, modifiers: [])
                Button {
                    hop(1)
                } label: {
                    Label("Next Channel", systemImage: "chevron.down")
                }
                .keyboardShortcut(.downArrow, modifiers: [])
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
        .sheet(isPresented: $showTracks) {
            MacTrackPickerView(player: player)
                .frame(minWidth: 420, minHeight: 380)
        }
        .onReceive(NotificationCenter.default.publisher(for: SleepTimer.firedNotification)) { _ in
            player.pause()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: AVPlayerItem.failedToPlayToEndTimeNotification)) { note in
            guard (note.object as? AVPlayerItem) === player.currentItem else { return }
            handleFailure()
        }
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
            failureCount = 0
            reconnectAttempt = 0
        } catch {
            errorText = "Couldn't load this channel. Check your connection and try again."
            loading = false
        }
    }

    private var healthText: String {
        if errorText != nil || failureCount >= 3 { return "Stream health: Poor" }
        if reconnectAttempt > 0 { return "Stream health: Fair (reconnecting)" }
        return "Stream health: Good"
    }

    private var healthColor: Color {
        if errorText != nil || failureCount >= 3 { return .red }
        if reconnectAttempt > 0 { return .yellow }
        return .green
    }

    /// Auto-reconnect (2.0.0): retry the load up to 3 times with
    /// growing delays before leaving the error on screen.
    private func handleFailure() {
        failureCount += 1
        guard failureCount <= 3 else {
            errorText = "This stream stopped and couldn't be reconnected."
            reconnectAttempt = 0
            return
        }
        reconnectAttempt = failureCount
        let delay = [2, 5, 10][failureCount - 1]
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            if reconnectAttempt == failureCount { await load() }
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


// MARK: - Audio & subtitles (2.0.0, macOS)

struct MacTrackPickerView: View {
    let player: AVPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var refreshTick = 0

    private func group(for characteristic: AVMediaCharacteristic) -> AVMediaSelectionGroup? {
        player.currentItem?.asset.mediaSelectionGroup(forMediaCharacteristic: characteristic)
    }
    private func selected(for characteristic: AVMediaCharacteristic) -> AVMediaSelectionOption? {
        guard let item = player.currentItem, let g = group(for: characteristic) else { return nil }
        return item.currentMediaSelection.selectedMediaOption(in: g)
    }
    private func select(_ option: AVMediaSelectionOption?, for characteristic: AVMediaCharacteristic) {
        guard let item = player.currentItem, let g = group(for: characteristic) else { return }
        item.select(option, in: g)
        refreshTick += 1
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Audio & Subtitles")
                    .font(.title3.weight(.bold))
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(12)
            Divider()
            List {
                Section("Audio") {
                    let options = group(for: .audible)?.options ?? []
                    if options.isEmpty {
                        Text("No alternate audio tracks for this stream.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                        Button {
                            select(option, for: .audible)
                        } label: {
                            HStack {
                                Text(option.displayName)
                                Spacer()
                                if selected(for: .audible) == option {
                                    Image(systemName: "checkmark").foregroundStyle(.green)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section("Subtitles") {
                    Button {
                        select(nil, for: .legible)
                    } label: {
                        HStack {
                            Text("Off")
                            Spacer()
                            if selected(for: .legible) == nil {
                                Image(systemName: "checkmark").foregroundStyle(.green)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    let options = (group(for: .legible)?.options ?? [])
                        .filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
                    ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                        Button {
                            select(option, for: .legible)
                        } label: {
                            HStack {
                                Text(option.displayName)
                                Spacer()
                                if selected(for: .legible) == option {
                                    Image(systemName: "checkmark").foregroundStyle(.green)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if options.isEmpty {
                        Text("No subtitle tracks for this stream.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .id(refreshTick)
        }
    }
}
