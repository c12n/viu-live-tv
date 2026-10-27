//
//  GlassHelpers.swift
//  Viu Live TV
//
//  Liquid Glass UI helpers. On iOS 26+ we use the SwiftUI glass effect APIs;
//  on iOS 17–25 we fall back to Material. Everything that touches the iOS 26
//  APIs is gated behind `if #available(iOS 26.0, *)` so the project still
//  compiles for an iOS 17 deployment target with the Xcode 26 SDK.
//

import SwiftUI

// MARK: - Card background

/// A rounded card surface that uses Liquid Glass on iOS 26+ and a Material
/// blur on earlier systems.
struct GlassCardBackground: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

/// An interactive / highlighted glass surface (e.g. for buttons and overlays).
struct GlassControlBackground: ViewModifier {
    var cornerRadius: CGFloat = 12
    var tint: Color?

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            if let tint {
                content.glassEffect(.regular.tint(tint).interactive(), in: shape)
            } else {
                content.glassEffect(.regular.interactive(), in: shape)
            }
        } else {
            content
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(tint?.opacity(0.18) ?? .clear)
                )
        }
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassCardBackground(cornerRadius: cornerRadius))
    }

    func glassControl(cornerRadius: CGFloat = 12, tint: Color? = nil) -> some View {
        modifier(GlassControlBackground(cornerRadius: cornerRadius, tint: tint))
    }
}

// MARK: - Glass container

/// Wraps content in a `GlassEffectContainer` on iOS 26+ (which lets nearby
/// glass elements blend), and is a plain passthrough otherwise.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: () -> Content

    init(spacing: CGFloat = 12, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

// MARK: - Live badge

struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(.red)
                .frame(width: 7, height: 7)
            Text("LIVE")
                .font(.caption2.weight(.bold))
                .kerning(0.5)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassControl(cornerRadius: 8, tint: .red)
        .foregroundStyle(.primary)
        .accessibilityLabel("Live now")
    }
}
