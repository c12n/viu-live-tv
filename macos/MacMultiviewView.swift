//
//  MacMultiviewView.swift
//  Viu Live TV — macOS
//
//  Up to four channels at once. Click a pane to give it the sound;
//  double-click (or the expand button) opens it in the main
//  player. Empty panes take any channel from the picker.
//

import SwiftUI
import AVFoundation

extension Int: Identifiable {
    public var id: Int { self }
}

struct MacMultiviewView: View {
    @Environment(EPGStore.self) private var epg
    @Environment(ParentalControls.self) private var parental
    @Environment(\.dismiss) private var dismiss

    let onDone: (EPGChannel?) -> Void
    @State private var slots: [EPGChannel?]
    @State private var audioSlot = 0
    @State private var pickerSlot: Int?
    @State private var pinFor: (slot: Int, channel: EPGChannel)?

    init(initial: EPGChannel, onDone: @escaping (EPGChannel?) -> Void) {
        _slots = State(initialValue: [initial, nil, nil, nil])
        self.onDone = onDone
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Multiview").font(.title2.weight(.bold))
                Spacer()
                Text("Click a pane for sound · Double-click to expand")
                    .foregroundStyle(.secondary)
                Button("Done") {
                    onDone(nil)
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16),
                                GridItem(.flexible(), spacing: 16)], spacing: 16) {
                ForEach(0..<4, id: \.self) { i in
                    if let channel = slots[i] {
                        MacMultiviewCell(channel: channel,
                                         isAudio: audioSlot == i)
                            .onTapGesture(count: 2) {
                                onDone(channel)
                                dismiss()
                            }
                            .onTapGesture(count: 1) {
                                audioSlot = i
                            }
                    } else {
                        Button {
                            pickerSlot = i
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: "plus").font(.largeTitle)
                                Text("Add Channel")
                            }
                            .frame(maxWidth: .infinity)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .background(Color.primary.opacity(0.05),
                                        in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .sheet(item: $pickerSlot) { slot in
            pickerView(slot: slot)
        }
        .sheet(item: Binding(get: { pinFor?.channel },
                             set: { if $0 == nil { pinFor = nil } })) { target in
            MacPINEntryView(title: "Enter PIN to watch \(target.name)") { pin in
                let pending = pinFor
                pinFor = nil
                if let pin, let pending, parental.verify(pin) {
                    slots[pending.slot] = pending.channel
                    audioSlot = pending.slot
                }
            }
            .frame(width: 340)
        }
    }

    private func pickerView(slot: Int) -> some View {
        NavigationStack {
            List(epg.channels) { channel in
                Button {
                    pickerSlot = nil
                    if parental.isEnabled && parental.isLocked(channel.streamId) {
                        pinFor = (slot, channel)
                    } else {
                        slots[slot] = channel
                        audioSlot = slot
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(channel.name)
                            Text(channel.nowText())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(channel.language.code.uppercased())
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Add Channel")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { pickerSlot = nil }
                }
            }
        }
        .frame(width: 460, height: 520)
    }
}

/// One Multiview pane with its own player; sound follows selection.
struct MacMultiviewCell: View {
    let channel: EPGChannel
    let isAudio: Bool
    @State private var player: AVPlayer?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black
            if let player {
                MacPlayerLayerView(player: player)
            } else if failed {
                VStack(spacing: 6) {
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
                HStack(spacing: 7) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text(channel.name)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()
                    if isAudio {
                        Image(systemName: "speaker.wave.2.fill")
                            .foregroundStyle(.white)
                    }
                }
                .padding(10)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.55)],
                                           startPoint: .top, endPoint: .bottom))
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isAudio ? Color.accentColor : Color.primary.opacity(0.15),
                        lineWidth: isAudio ? 3 : 1)
        )
        .task(id: channel.streamId) { await load() }
        .onChange(of: isAudio) { _, audio in
            player?.isMuted = !audio
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
            newPlayer.isMuted = !isAudio
            player = newPlayer
            newPlayer.play()
        } catch {
            failed = true
        }
    }
}
