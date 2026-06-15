import Defaults
import SwiftUI

// MARK: - ShortcutCoachmark

struct ShortcutCoachmark: View {
    @Default(.shortcutsCoachmarkShown) var shown
    @Environment(\.colorScheme) private var scheme

    private var accent: Color { .accentColor }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "keyboard.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .shadow(color: accent.opacity(0.5), radius: 4, y: 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("Shortcuts moved off the buttons")
                    .font(.callout).bold()
                    .foregroundStyle(.primary)
                Text("Hold ⌘ to peek at any action's shortcut, or change them in Settings → Shortcuts.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Got it") { withAnimation { shown = true } }
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.background)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(accent.opacity(scheme == .dark ? 0.22 : 0.12))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(accent.opacity(scheme == .dark ? 0.85 : 0.6), lineWidth: 1.5)
        }
        .shadow(color: accent.opacity(0.25), radius: 10, y: 3)
        .frame(maxWidth: 440)
        .padding(.horizontal, 12).padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - ShortcutBadge

struct ShortcutBadge: ViewModifier {
    let text: String
    let visible: Bool
    @Environment(\.colorScheme) private var scheme

    private var accent: Color { .accentColor }

    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            if visible, !text.isEmpty {
                pill
                    .offset(x: 4, y: -6)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var pill: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 4).padding(.vertical, 1.5)
            .background {
                Capsule(style: .continuous)
                    .fill(.background)
                    .overlay {
                        Capsule(style: .continuous)
                            .fill(accent.opacity(scheme == .dark ? 0.30 : 0.16))
                    }
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(accent.opacity(scheme == .dark ? 0.85 : 0.6), lineWidth: 1)
            }
    }
}

extension View {
    func shortcutBadge(_ text: String, visible: Bool) -> some View {
        modifier(ShortcutBadge(text: text, visible: visible))
    }
}
