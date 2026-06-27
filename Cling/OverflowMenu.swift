import AppKit
import SwiftUI

// MARK: - OverflowMenuButton

/// The toolbar's overflow ("…") action menu. It pops a real AppKit `NSMenu` so each item shows its
/// keyboard shortcut in the native right-aligned secondary style — SwiftUI's inline `Menu` does not
/// render `.keyboardShortcut` glyphs for its items. The trigger itself stays a SwiftUI button, so it
/// keeps the toolbar's flat-pill styling and hover.
struct OverflowMenuButton: View {
    let sections: [(title: String, items: [ToolbarAction])]
    let isEnabled: (ActionID) -> Bool
    /// The display key equivalent + modifier mask for an action, or nil if it has no shortcut.
    let shortcut: (ActionID) -> (key: String, modifiers: NSEvent.ModifierFlags)?
    let onSelect: (ActionID) -> Void

    var body: some View {
        Button(action: present) {
            // The ellipsis glyph is short, so on its own the pill collapses to a thin line. A hidden
            // space sets the label to the font's full line height (the ellipsis sets the width), so
            // the pill matches the other action buttons' vertical size.
            ZStack {
                Text(verbatim: " ").hidden()
                Image(systemName: "ellipsis")
            }
        }
        .help("More actions")
        .background(MenuAnchorView(anchor: anchor))
    }

    @State private var anchor = MenuAnchor()

    private func present() {
        let target = MenuActionTarget(onSelect)
        let menu = NSMenu()
        menu.autoenablesItems = false

        for section in sections where !section.items.isEmpty {
            menu.addItem(.sectionHeader(title: section.title))
            for action in section.items {
                let item = NSMenuItem(title: action.title, action: #selector(MenuActionTarget.fire(_:)), keyEquivalent: "")
                item.target = target
                item.representedObject = action.id.rawValue
                item.isEnabled = isEnabled(action.id)
                item.image = NSImage(systemSymbolName: action.systemImage, accessibilityDescription: nil)
                if let sc = shortcut(action.id) {
                    item.keyEquivalent = sc.key
                    item.keyEquivalentModifierMask = sc.modifiers
                }
                menu.addItem(item)
            }
        }

        guard let view = anchor.view else { return }
        // popUp tracks the menu modally and returns once it closes, so `target` (held weakly by the
        // menu items) must stay alive across the whole call.
        withExtendedLifetime(target) {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
        }
    }
}

// MARK: - MenuActionTarget

@MainActor
private final class MenuActionTarget: NSObject {
    init(_ onSelect: @escaping (ActionID) -> Void) {
        self.onSelect = onSelect
    }

    let onSelect: (ActionID) -> Void

    @objc func fire(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = ActionID(rawValue: raw) else { return }
        onSelect(id)
    }
}

// MARK: - MenuAnchor

/// Holds a reference to the button's backing view so the menu can be popped up anchored to it.
private final class MenuAnchor {
    weak var view: NSView?
}

// MARK: - MenuAnchorView

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = FlippedAnchorView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

// MARK: - FlippedAnchorView

/// Flipped so popping up at `y == bounds.height` reliably places the menu just below the button,
/// regardless of how SwiftUI hosts the representable.
private final class FlippedAnchorView: NSView {
    override var isFlipped: Bool {
        true
    }
}
