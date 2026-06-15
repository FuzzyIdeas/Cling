import Defaults
import SwiftUI

// MARK: - ShortcutCoachmark

struct ShortcutCoachmark: View {
    @Default(.shortcutsCoachmarkShown) var shown
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "keyboard")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Shortcuts moved off the buttons")
                    .font(.callout).bold()
                Text("Hold ⌘ to peek at any action's shortcut, or change them in Settings → Shortcuts.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Got it") { withAnimation { shown = true } }
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
        .shadow(radius: 8, y: 2)
        .frame(maxWidth: 420)
        .padding(.horizontal, 12).padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - ShortcutBadge

struct ShortcutBadge: ViewModifier {
    let text: String
    let visible: Bool
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
        let label = Text(text)
            .font(.system(size: 8, weight: .semibold))
            .padding(.horizontal, 3).padding(.vertical, 1)
        if AM.useGlass, #available(macOS 26, *) {
            label
                .glassEffect(.regular, in: .capsule)
                .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
        } else {
            label
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
        }
    }
}

extension View {
    func shortcutBadge(_ text: String, visible: Bool) -> some View {
        modifier(ShortcutBadge(text: text, visible: visible))
    }
}
