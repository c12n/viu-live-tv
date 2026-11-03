//
//  TVPlayerView.swift
//  Viu Live TV — Apple TV
//
//  Full-screen player built on AVPlayerLayer with a focusable
//  control banner: Play/Pause toggles, Up/Down hops channels, and
//  the banner carries Last Channel, the guide, Multiview and
//  Favorite. Multiview is a 2×2 grid where the focused pane has
//  the sound and Select expands it to the full player.
//

import SwiftUI
import AVKit
import AVFoundation

struct TVPlayerView: View {
    @Environment(EPGStore.self) private var epg
    @Environment(FavoritesStore.self) private var favorites
    @Environment(AppSettings.self) private var settings
    @Environment(ParentalControls.self) private var parental
    @Environment(\.dismiss) private var dismiss

    let contextList: [EPGChannel]
    @State private var channel: EPGChannel
    @State private var previous: EPGChannel?
    @State private var player = AVPlayer()
    @State private var isPlaying = false
    @State private var loading = true
    @State private var errorText: String?
    @State private var showBanner = true
    @State private var showGuide = false
    @State private var showMultiview = false
    @State private var pinFor: EPGChannel?
    @State private var hideTask: Task<Void, Never>?

    private enum FocusField: Hashable { case video, last, guide, multi, fav }
    @FocusState private var focus: FocusField?

    init(channel: EPGChannel, contextList: [EPGChannel]) {
        self.contextList = contextList
        _channel = State(initialValue: channel)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TVPlayerLayerView(player: player)
                .ignoresSafeArea()

            if loading {
                ProgressView().controlSize(.large)
            }
            if let errorText {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle).foregroundStyle(.yellow)
                    Text(errorText)
                        .font(.title3)
                        .multilineTextAlignment(.center)
                    Button("Retry") { Task { await load() } }
                }
                .padding(60)
            }

            if showBanner && errorText == nil {
                banner
            }
        }
        .focusable()
        .focused($focus, equals: .video)
        .onPlayPauseCommand {
            wakeBanner()
            if isPlaying { player.pause() } else { player.play() }
            isPlaying.toggle()
        }
        .onMoveCommand { direction in
            guard focus == .video else { return }
            wakeBanner()
            switch direction {
            case .up: hop(-1)
            case .down: hop(1)
            default: break
            }
        }
        .onExitCommand {
            if showGuide {
                showGuide = false
            } else if showBanner {
                showBanner = false
                focus = .video
            } else {
                dismiss()
            }
        }
        .task(id: channel.streamId) { await load() }
        .onChange(of: focus) { _, newFocus in
            // Navigating the banner buttons keeps the banner awake.
            if newFocus != nil && newFocus != .video { wakeBanner() }
        }
        .onAppear {
            focus = .video
            scheduleHide()
        }
        .onDisappear {
            hideTask?.cancel()
            player.pause()
        }
        .sheet(isPresented: $showGuide) {
            guideList
        }
        .fullScreenCover(isPresented: $showMultiview) {
            TVMultiviewView(initial: channel) { picked in
                if let picked, picked.streamId != channel.streamId {
                    requestSwitch(picked)
                }
            }
        }
        .sheet(item: $pinFor) { target in
            TVPINEntryView(title: "Enter PIN to watch \(target.name)") { pin in
                guard let pin else { return true }
                if parental.verify(pin) {
                    switchChannel(target)
                    return true
                }
                return false
            }
        }
    }

    // MARK: Banner

    private var banner: some View {
        VStack {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        LiveBadge()
                        Text(channel.name).font(.title2.weight(.bold))
                        Text(channel.language.code.uppercased())
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.tint, in: Capsule())
                    }
                    Text(nowNextLine)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Spacer()
            HStack(spacing: 20) {
                if let previous {
                    Button {
                        requestSwitch(previous)
                    } label: {
                        Label("Last: \(previous.name)",
                              systemImage: "arrow.uturn.backward")
                    }
                    .focused($focus, equals: .last)
                }
                Button {
                    showGuide = true
                } label: {
                    Label("Guide", systemImage: "list.bullet")
                }
                .focused($focus, equals: .guide)
                Button {
                    showMultiview = true
                } label: {
                    Label("Multiview", systemImage: "square.grid.2x2")
                }
                .focused($focus, equals: .multi)
                Button {
                    favorites.toggle(channel)
                } label: {
                    Label(favorites.isFavorite(channel.streamId) ? "Favorited" : "Favorite",
                          systemImage: favorites.isFavorite(channel.streamId)
                            ? "heart.fill" : "heart")
                }
                .focused($focus, equals: .fav)
                Spacer()
                Text("↑↓ channel · OK play/pause")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(48)
        .background(
            LinearGradient(colors: [.black.opacity(0.55), .clear, .black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    private var nowNextLine: String {
        var parts: [String] = []
        if let now = channel.nowProgramme() { parts.append("Now: \(now.name)") }
        if let next = channel.nextProgramme() { parts.append("Next: \(next.name)") }
        return parts.isEmpty ? channel.nowText() : parts.joined(separator: "   ·   ")
    }

    // MARK: Guide

    private var guideList: some View {
        NavigationStack {
            List(contextList) { item in
                Button {
                    showGuide = false
                    if item.streamId != channel.streamId {
                        requestSwitch(item)
                    }
                } label: {
                    HStack(spacing: 16) {
                        if item.streamId == channel.streamId {
                            Image(systemName: "play.fill").foregroundStyle(.tint)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.headline)
                            Text(item.nowText())
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if favorites.isFavorite(item.streamId) {
                            Image(systemName: "heart.fill").foregroundStyle(.yellow)
                        }
                    }
                }
            }
            .navigationTitle("Guide")
        }
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
            isPlaying = true
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
        wakeBanner()
    }

    private func requestSwitch(_ target: EPGChannel) {
        if parental.isEnabled && parental.isLocked(target.streamId) {
            pinFor = target
        } else {
            switchChannel(target)
        }
    }

    private func hop(_ delta: Int) {
        guard !contextList.isEmpty else { return }
        guard let idx = contextList.firstIndex(where: { $0.streamId == channel.streamId })
        else { return }
        let next = idx + delta
        guard contextList.indices.contains(next) else { return }
        requestSwitch(contextList[next])
    }

    private func wakeBanner() {
        showBanner = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if !Task.isCancelled {
                showBanner = false
                focus = .video
            }
        }
    }
}

// MARK: - Player layer

struct TVPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> TVPlayerLayerUIView {
        let view = TVPlayerLayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: TVPlayerLayerUIView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }
}

final class TVPlayerLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

// MARK: - Multiview

struct TVMultiviewView: View {
    @Environment(ParentalControls.self) private var parental
    @Environment(\.dismiss) private var dismiss

    let onDone: (EPGChannel?) -> Void
    @State private var slots: [EPGChannel?]
    @State private var pickerSlot: Int?
    @State private var pinFor: (slot: Int, channel: EPGChannel)?
    @FocusState private var focusedSlot: Int?

    init(initial: EPGChannel, onDone: @escaping (EPGChannel?) -> Void) {
        _slots = State(initialValue: [initial, nil, nil, nil])
        self.onDone = onDone
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                HStack {
                    Text("Multiview").font(.title2.weight(.bold))
                    Spacer()
                    Text("Select a pane to expand it · Menu goes back")
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 20),
                                    GridItem(.flexible(), spacing: 20)], spacing: 20) {
                    ForEach(0..<4, id: \.self) { i in
                        if let channel = slots[i] {
                            TVMultiviewCell(channel: channel,
                                            isAudioFocused: focusedSlot == i)
                                .focused($focusedSlot, equals: i)
                                .onTapGesture {
                                    onDone(channel)
                                    dismiss()
                                }
                        } else {
                            Button {
                                pickerSlot = i
                            } label: {
                                VStack(spacing: 10) {
                                    Image(systemName: "plus").font(.largeTitle)
                                    Text("Add Channel").font(.headline)
                                }
                                .frame(maxWidth: .infinity)
                                .aspectRatio(16 / 9, contentMode: .fit)
                            }
                            .buttonStyle(.card)
                            .focused($focusedSlot, equals: i)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(48)
        }
        .onExitCommand {
            onDone(nil)
            dismiss()
        }
        .sheet(item: $pickerSlot) { slot in
            TVMultiviewPicker { picked in
                pickerSlot = nil
                if let picked {
                    if parental.isEnabled && parental.isLocked(picked.streamId) {
                        pinFor = (slot, picked)
                    } else {
                        slots[slot] = picked
                        focusedSlot = slot
                    }
                }
            }
        }
        .sheet(item: Binding(get: { pinFor?.channel },
                             set: { if $0 == nil { pinFor = nil } })) { target in
            TVPINEntryView(title: "Enter PIN to watch \(target.name)") { pin in
                guard let pin else { return true }
                if let pending = pinFor, parental.verify(pin) {
                    slots[pending.slot] = pending.channel
                    focusedSlot = pending.slot
                    return true
                }
                return false
            }
        }
    }
}

/// One Multiview pane with its own player; sound follows focus.
struct TVMultiviewCell: View {
    let channel: EPGChannel
    let isAudioFocused: Bool
    @State private var player: AVPlayer?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black
            if let player {
                TVPlayerLayerView(player: player)
            } else if failed {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.yellow)
                    Text("Couldn't load").font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
            }
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Circle().fill(.red).frame(width: 9, height: 9)
                    Text(channel.name).font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    if isAudioFocused {
                        Image(systemName: "speaker.wave.2.fill")
                    }
                }
                .padding(14)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.6)],
                                           startPoint: .top, endPoint: .bottom))
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isAudioFocused ? Color.accentColor : Color.white.opacity(0.15),
                        lineWidth: isAudioFocused ? 3 : 1)
        )
        .focusable()
        .task(id: channel.streamId) { await load() }
        .onChange(of: isAudioFocused) { _, focused in
            player?.isMuted = !focused
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private func load() async {
        failed = false
        do {
            let links = try await APIClient.shared.liveLinks(streamID: channel.streamId)
            guard let link = links.liveLink, let url = URL(string: link) else {
                failed = true
                return
            }
            let newPlayer = AVPlayer(playerItem: AVPlayerItem(url: url))
            newPlayer.isMuted = !isAudioFocused
            player = newPlayer
            newPlayer.play()
        } catch {
            failed = true
        }
    }
}

/// Channel picker for an empty Multiview pane.
struct TVMultiviewPicker: View {
    @Environment(EPGStore.self) private var epg
    @Environment(\.dismiss) private var dismiss
    let onPick: (EPGChannel?) -> Void

    var body: some View {
        NavigationStack {
            List(epg.channels) { channel in
                Button {
                    onPick(channel)
                    dismiss()
                } label: {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(channel.name).font(.headline)
                            Text(channel.nowText())
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(channel.language.code.uppercased())
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Add Channel")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onPick(nil)
                        dismiss()
                    }
                }
            }
        }
    }
}

extension Int: @retroactive Identifiable {
    public var id: Int { self }
}
