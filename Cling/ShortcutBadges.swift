import Defaults
import SwiftUI

// MARK: - ShortcutCoachmark

struct ShortcutCoachmark: View {
    @Default(.shortcutsCoachmarkShown) var shown

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

    @Environment(\.colorScheme) private var scheme

    private var accent: Color {
        .accentColor
    }

}

// MARK: - ShortcutPrefix

/// Reveals a shortcut hint *inside* the button rather than overlapping its corner: the hint slides
/// in on the left, same text size as the label, separated by a hairline divider, so the button's
/// own border ends up wrapping both. This sidesteps the overlap/clipping/truncation that a
/// corner-anchored badge hits on narrow (icon-only) buttons.
struct ShortcutPrefix: ViewModifier {
    let text: String
    let visible: Bool
    var color: Color = ShortcutTint.action
    /// The app/script pills only show the bare key (the row's `⌘⌥ +` / `⌘⌃ +` prefix already
    /// carries the modifiers), so they render it monospaced to read as a key.
    var monospaced = false

    func body(content: Content) -> some View {
        HStack(spacing: 6) {
            if visible, !text.isEmpty {
                Text(text)
                    .fontWeight(.semibold)
                    .monospaced(monospaced)
                    .foregroundStyle(color)
                    .fixedSize()
                Divider()
                    .frame(height: 12)
            }
            content
        }
    }
}

extension View {
    func shortcutPrefix(_ text: String, visible: Bool, color: Color = ShortcutTint.action, monospaced: Bool = false) -> some View {
        modifier(ShortcutPrefix(text: text, visible: visible, color: color, monospaced: monospaced))
    }
}

// MARK: - ShortcutTint

/// Distinct hint colors per row so each shortcut family is recognisable at a glance.
enum ShortcutTint {
    static let action = Color.blue
    static let alternate = Color.orange
    static let apps = Color.red
    /// A darker, less saturated red so it stays distinct from Apps and legible on light backgrounds.
    static let scripts = Color(red: 0.62, green: 0.26, blue: 0.26)
}
