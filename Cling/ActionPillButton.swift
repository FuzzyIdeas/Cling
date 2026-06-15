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

// MARK: - ActionPillButton

/// A toolbar-style action button that follows the icon/text style from settings and shows a
/// shortcut hint badge. Shared by the Option-held alternates, the Open With row, and the Scripts
/// row so they look and behave like the main action buttons.
struct ActionPillButton: View {
    let title: String
    let icon: PillIcon
    var shortcut: String = ""
    var badgesVisible = false
    var labelStyle: ToolbarLabelStyle
    var role: ButtonRole? = nil
    var help: String? = nil
    let action: () -> Void

    @ViewBuilder private var iconView: some View {
        switch icon {
        case let .symbol(name): Image(systemName: name)
        case let .glyph(g):     Text(g)
        case let .image(img):   Image(nsImage: img).resizable().interpolation(.high).frame(width: 14, height: 14)
        }
    }

    var body: some View {
        Button(role: role, action: action) {
            switch labelStyle {
            case .iconAndText: HStack(spacing: 4) { iconView; Text(title) }
            case .textOnly:    Text(title)
            case .iconOnly:    iconView
            }
        }
        .help(help ?? title)
        .shortcutBadge(shortcut, visible: badgesVisible)
    }
}

// MARK: - ShortcutHintReveal

/// Drives a `visible` flag for shortcut hint badges from a "modifier held" predicate, reusing the
/// same timing everywhere: the first reveal after the coachmark is instant, afterwards the badges
/// only appear if the modifier is held past a short threshold so quick hotkeys don't flash them.
struct ShortcutHintReveal: ViewModifier {
    let held: Bool
    @Binding var visible: Bool
    @Default(.shortcutBadgesRevealedOnce) private var revealedOnce
    @State private var task: Task<Void, Never>?

    func body(content: Content) -> some View {
        content.onChange(of: held) { _, isHeld in
            task?.cancel()
            guard isHeld else {
                withAnimation(.easeOut(duration: 0.12)) { visible = false }
                return
            }
            if !revealedOnce {
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
}

extension View {
    func revealShortcutHints(held: Bool, visible: Binding<Bool>) -> some View {
        modifier(ShortcutHintReveal(held: held, visible: visible))
    }
}
