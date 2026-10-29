//
//  ChannelRowView.swift
//  Viu Live TV
//
//  A single channel row: logo, name, now/next programme, and a progress bar
//  for the current programme. Includes a favorite star and a context menu.
//

import SwiftUI
import Combine

struct ChannelRowView: View {
    @Environment(AppSettings.self) private var settings

    let channel: EPGChannel
    var isFavorite: Bool
    var now: EPGProgramme?
    var next: EPGProgramme?

    var onPlay: () -> Void
    var onToggleFavorite: () -> Void
    var onOpenExternal: () -> Void
    /// Only tap-to-play in the iPad sidebar (selection-driven). On iPhone the
    /// row sits inside a NavigationLink, and a tap gesture on the label would
    /// swallow the link's navigation.
    var tapToPlay: Bool = true
    /// When false the star is drawn as a plain (non-interactive) indicator.
    /// The iPhone list overlays its own star Button: an interactive button
    /// inside the row's play Button would swallow the row's taps.
    var favoriteButtonInteractive: Bool = true
    /// Parental controls: locked channels show a small lock by the name.
    var isLocked: Bool = false

    // A ticking clock for live progress updates.
    @State private var clock = Date()
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 12) {
            logo

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let num = channel.num {
                        Text("\(num)")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 22, alignment: .leading)
                    }
                    Text(channel.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    LanguageBadge(code: channel.language.code)
                    if isLocked {
                        Image(systemName: "lock.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if (now?.isLive(at: clock) ?? false) {
                        LiveBadge().scaleEffect(0.85)
                    }
                }

                Text(nowLine)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let progress = now?.progress(at: clock) {
                    ProgressView(value: progress)
                        .tint(settings.accent.color)
                        .frame(height: 4)
                        .padding(.top, 1)
                }

                if let next {
                    Text("Next: \(next.name)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 2)

            if favoriteButtonInteractive {
                Button(action: onToggleFavorite) {
                    starImage
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
            }
            // Non-interactive mode: no star here at all — the list overlays
            // its own star button (an indicator + overlay rendered as a
            // doubled star). Trailing padding below reserves its space.
        }
        .padding(.vertical, 7)
        .padding(.trailing, favoriteButtonInteractive ? 0 : 30)
        .contentShape(Rectangle())
        .modifier(TapToPlayModifier(enabled: tapToPlay, action: onPlay))
        .onReceive(timer) { clock = $0 }
        .contextMenu {
            Button { onPlay() } label: { Label("Play", systemImage: "play.fill") }
            Button { onToggleFavorite() } label: {
                Label(isFavorite ? "Remove Favorite" : "Favorite",
                      systemImage: isFavorite ? "heart.slash" : "heart")
            }
            Button { onOpenExternal() } label: {
                Label("Open in External Player", systemImage: "arrow.up.forward.app")
            }
        }
    }

    private var starImage: some View {
        Image(systemName: isFavorite ? "heart.fill" : "heart")
            .foregroundStyle(isFavorite ? .yellow : .secondary)
            .font(.title3)
            .contentShape(Rectangle())
    }

    private var nowLine: String {
        if let now, now.name != "—" { return now.name }
        return channel.nowText(at: clock)
    }

    @ViewBuilder
    private var logo: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.secondarySystemBackground))
            if let url = channel.logoURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit().padding(4)
                    case .failure:
                        placeholderGlyph
                    case .empty:
                        ProgressView().controlSize(.small)
                    @unknown default:
                        placeholderGlyph
                    }
                }
            } else {
                placeholderGlyph
            }
        }
        .frame(width: 54, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var placeholderGlyph: some View {
        Image(systemName: "tv")
            .font(.title3)
            .foregroundStyle(.secondary)
    }
}

/// Small capsule with the channel's language code (EN, FR, AR, …),
/// sitting right after the channel name.
private struct LanguageBadge: View {
    @Environment(AppSettings.self) private var settings
    let code: String

    var body: some View {
        Text(code.uppercased())
            .font(.caption.weight(.bold))
            .foregroundStyle(settings.accent.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(settings.accent.color.opacity(0.18), in: Capsule())
            .accessibilityLabel("Language: \(code.uppercased())")
    }
}

/// Applies a tap gesture only when enabled (see `tapToPlay`).
private struct TapToPlayModifier: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.onTapGesture(perform: action)
        } else {
            content
        }
    }
}
