import SwiftUI

struct ShortcutBadge: ViewModifier {
    let text: String
    let visible: Bool
    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            if visible, !text.isEmpty {
                Text(text)
                    .font(.system(size: 8, weight: .semibold))
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(.thinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
                    .offset(x: 4, y: -6)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
    }
}

extension View {
    func shortcutBadge(_ text: String, visible: Bool) -> some View {
        modifier(ShortcutBadge(text: text, visible: visible))
    }
}
