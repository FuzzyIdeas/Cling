import AppKit
import Defaults
import SwiftUI

// MARK: - PillIcon

/// Icon source for an action pill: an SF Symbol, a text glyph (emoji), or a rendered app icon.
enum PillIcon {
    case symbol(String)
    case glyph(String)
    case image(NSImage)

    /// Interprets a configured icon string: a valid SF Symbol name renders as a symbol, anything
    /// else (an emoji, or an unknown token) renders as a text glyph.
    static func from(glyph: String) -> PillIcon {
        if glyph.allSatisfy(\.isASCII), NSImage(systemSymbolName: glyph, accessibilityDescription: nil) != nil {
            return .symbol(glyph)
        }
        return .glyph(glyph)
    }
}

// MARK: - ActionRowLayout

/// Shared metrics so the Open With and Scripts rows line up with each other and give their
/// shortcut hint badges room to breathe.
enum ActionRowLayout {
    /// Vertical room reserved above and below the pills so the hint badges, which poke ~6pt above
    /// each pill, aren't clipped by the horizontal ScrollView that wraps them. Applied symmetrically
    /// (and to the main action row) so every row clears its badges by the same amount; the rows then
    /// overlap slightly (negative VStack spacing) to keep the visible gap tight.
    static let badgeClearance: CGFloat = 6

    /// Fixed width for each row's leading button (Open With / Execute script) so their trailing
    /// dividers, and therefore the app and script pills, line up. Sized to hug the wider label
    /// ("Execute script") with ~4pt of slack before the divider.
    static func leadingWidth(for style: ToolbarLabelStyle, density: ToolbarDensity) -> CGFloat {
        let compact = density == .compact
        switch style {
        case .iconOnly: return 26
        case .textOnly: return compact ? 90 : 98
        case .iconAndText: return compact ? 108 : 116
        }
    }

}

// MARK: - ModifierComboHint

/// Compact "⌘⌥ +" / "⌘⌃ +" hint shown after a row's leading divider while ⌘ is held, reading as
/// "hold these modifiers + a button", so the user learns they can add ⌥ (apps) or ⌃ (scripts) to
/// reveal the per-item shortcuts without the row flooding with every badge at once. ⌘ reads as
/// pressed (accent); the second key stays muted until it is actually held.
struct ModifierComboHint: View {
    /// The secondary modifier glyph for this row: "⌥" for apps, "⌃" for scripts.
    let secondary: String
    /// Whether that secondary modifier is currently held (then it reads as pressed too).
    let secondaryHeld: Bool
    /// Row tint, matching that row's shortcut hint color.
    var tint: Color = ShortcutTint.action

    var body: some View {
        HStack(spacing: 2) {
            keycap("⌘", pressed: true)
            keycap(secondary, pressed: secondaryHeld)
            Text("+")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
        }
        // 2pt of air between the hint and the first app/script pill.
        .padding(.trailing, 2)
    }

    @Environment(\.colorScheme) private var scheme

    private var accent: Color {
        tint
    }

    private func keycap(_ glyph: String, pressed: Bool) -> some View {
        Text(glyph)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(pressed ? .white : .secondary)
            .frame(minWidth: 13)
            .padding(.horizontal, 3).padding(.vertical, 1.5)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(pressed ? accent : Color.primary.opacity(scheme == .dark ? 0.16 : 0.08))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(pressed ? accent.opacity(0.9) : Color.primary.opacity(0.18), lineWidth: 0.5)
            }
    }
}

// MARK: - ActionPillButton

/// A toolbar-style action button that follows the icon/text style from settings and shows a
/// shortcut hint badge. Shared by the Option-held alternates, the Open With row, and the Scripts
/// row so they look and behave like the main action buttons.
struct ActionPillButton: View {
    let title: String
    let icon: PillIcon
    var shortcut = ""
    var badgesVisible = false
    var labelStyle: ToolbarLabelStyle
    var role: ButtonRole?
    var help: String?
    var hintColor: Color = ShortcutTint.action
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Group {
                switch labelStyle {
                case .iconAndText: HStack(spacing: 4) { iconView; Text(title) }
                case .textOnly: Text(title)
                case .iconOnly: iconView
                }
            }
            .shortcutPrefix(shortcut, visible: badgesVisible, color: hintColor, monospaced: true)
        }
        .help(help ?? title)
    }

    @ViewBuilder private var iconView: some View {
        switch icon {
        case let .symbol(name): Image(systemName: name)
        case let .glyph(g): Text(g)
        case let .image(img): Image(nsImage: img).resizable().interpolation(.high).frame(width: 14, height: 14)
        }
    }

}

// MARK: - ShortcutHintReveal

/// Drives a `visible` flag for shortcut hint badges from a "modifier held" predicate, reusing the
/// same timing everywhere: the first reveal after the coachmark is instant, afterwards the badges
/// only appear if the modifier is held past a short threshold so quick hotkeys don't flash them.
struct ShortcutHintReveal: ViewModifier {
    let held: Bool
    @Binding var visible: Bool

    /// Skip the 500ms wait and reveal immediately. Used when a sibling hint is already on screen
    /// (e.g. the ⌘ combo hint is showing and the user adds ⌥/⌃), so there's no need to re-earn the
    /// reveal — they're clearly already peeking at shortcuts.
    var instant = false

    func body(content: Content) -> some View {
        content.onChange(of: held) { _, isHeld in
            task?.cancel()
            guard isHeld else {
                withAnimation(.easeOut(duration: 0.12)) { visible = false }
                return
            }
            if !revealedOnce || instant {
                revealedOnce = true
                withAnimation(.easeOut(duration: 0.12)) { visible = true }
            } else {
                task = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, held else { return }
                    withAnimation(.easeOut(duration: 0.12)) { visible = true }
                }
            }
        }
    }

    @State private var task: Task<Void, Never>?

    @Default(.shortcutBadgesRevealedOnce) private var revealedOnce

}

extension View {
    func revealShortcutHints(held: Bool, visible: Binding<Bool>, instant: Bool = false) -> some View {
        modifier(ShortcutHintReveal(held: held, visible: visible, instant: instant))
    }
}
