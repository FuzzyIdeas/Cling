//
//  Styles.swift
//  Cling
//
//  Created by Alin Panaitiu on 06.02.2025.
//

import Foundation
import Lowtech
import SwiftUI

// MARK: - Glass Button Style (macOS 26+)

struct GlassTextButton: ButtonStyle {
    @Environment(\.isEnabled) public var isEnabled

    public func makeBody(configuration: Configuration) -> some View {
        let enabled = isEnabledOverride ?? isEnabled
        let label = configuration.label
            .foregroundStyle(color)
            .padding(.vertical, 2.0)
            .padding(.horizontal, 8.0)
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.6)

        if #available(macOS 26, *) {
            if active {
                label.glassEffect(.regular.tint(activeTint).interactive(), in: .capsule)
            } else {
                label.glassEffect(.regular.interactive(), in: .capsule)
            }
        } else {
            label
        }
    }

    var color = Color.primary.opacity(0.8)
    var active = false
    var activeTint: Color = .accentColor
    var isEnabledOverride: Bool?

}

// MARK: - Vibrant Button Style

struct VibrantTextButton: ButtonStyle {
    @Environment(\.isEnabled) public var isEnabled

    public func makeBody(configuration: Configuration) -> some View {
        let enabled = isEnabledOverride ?? isEnabled
        configuration.label
            .foregroundStyle(color)
            .padding(.vertical, 2.0)
            .padding(.horizontal, 8.0)
            .contentShape(Rectangle())
            .onHover { hover in
                guard enabled else { return }
                withAnimation(.easeOut(duration: 0.2)) { hovering = hover }
            }
            .opacity(enabled ? (hovering ? 1 : 0.8) : 0.6)
            .background(active ? activeTint.opacity(0.2) : Color.clear, in: .capsule)
            .overlay(Capsule().strokeBorder(borderColor ?? color, lineWidth: 0.5))
    }

    var color = Color.primary.opacity(0.8)
    var borderColor: Color?
    var active = false
    var activeTint: Color = .accentColor
    var isEnabledOverride: Bool?

    @State private var hovering = false

}

// MARK: - Opaque Button Style

struct OpaqueTextButton: ButtonStyle {
    @Environment(\.isEnabled) public var isEnabled

    public func makeBody(configuration: Configuration) -> some View {
        let enabled = isEnabledOverride ?? isEnabled
        configuration.label
            .foregroundStyle(color)
            .padding(.vertical, 2.0)
            .padding(.horizontal, 8.0)
            .contentShape(Rectangle())
            .onHover { hover in
                guard enabled else { return }
                withAnimation(.easeOut(duration: 0.2)) { hovering = hover }
            }
            .opacity(enabled ? (hovering ? 1 : 0.8) : 0.6)
            .background(active ? activeTint.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .background(roundRect(2, stroke: borderColor ?? color, lineWidth: 1))
    }

    var color = Color.primary.opacity(0.8)
    var borderColor: Color?
    var active = false
    var activeTint: Color = .accentColor
    var isEnabledOverride: Bool?

    @State private var hovering = false

}

// MARK: - Adaptive TextButton (picks style based on appearance)

struct TextButton: ButtonStyle {
    @Environment(\.isEnabled) public var isEnabled

    public func makeBody(configuration: Configuration) -> some View {
        if AM.useGlass {
            GlassTextButton(color: color, active: active, activeTint: activeTint, isEnabledOverride: isEnabled)
                .makeBody(configuration: configuration)
        } else if AM.useVibrant {
            VibrantTextButton(color: color, borderColor: borderColor, active: active, activeTint: activeTint, isEnabledOverride: isEnabled)
                .makeBody(configuration: configuration)
        } else {
            OpaqueTextButton(color: color, borderColor: borderColor, active: active, activeTint: activeTint, isEnabledOverride: isEnabled)
                .makeBody(configuration: configuration)
        }
    }

    var color = Color.primary.opacity(0.8)
    var borderColor: Color?
    var active = false
    var activeTint: Color = .accentColor

}

extension ButtonStyle where Self == TextButton {
    static var text: TextButton { TextButton() }
    static func text(color: Color = .primary.opacity(0.8), borderColor: Color? = nil, active: Bool = false, activeTint: Color = .accentColor) -> TextButton {
        TextButton(color: color, borderColor: borderColor, active: active, activeTint: activeTint)
    }
}

extension ButtonStyle where Self == GlassTextButton {
    static var glassText: GlassTextButton { GlassTextButton() }
}

extension ButtonStyle where Self == VibrantTextButton {
    static var vibrantText: VibrantTextButton { VibrantTextButton() }
}

extension ButtonStyle where Self == OpaqueTextButton {
    static var opaqueText: OpaqueTextButton { OpaqueTextButton() }
}

extension ButtonStyle where Self == BorderlessTextButton {
    static var borderlessText: BorderlessTextButton { BorderlessTextButton() }
    static func borderlessText(color: Color) -> BorderlessTextButton {
        BorderlessTextButton(color: color)
    }
}

// MARK: - Borderless Button Style

struct BorderlessTextButton: ButtonStyle {
    @Environment(\.isEnabled) public var isEnabled

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(color)
            .padding(.vertical, 2.0)
            .padding(.horizontal, 4.0)
            .contentShape(Rectangle())
            .onHover { hover in
                guard isEnabled else { return }
                withAnimation(.easeOut(duration: 0.2)) { hovering = hover }
            }
            .opacity(isEnabled ? (hovering ? 1 : 0.8) : 0.6)
    }

    var color = Color.primary.opacity(0.8)

    @State private var hovering = false

}

extension View {
    func transparentTableBackground() -> some View {
        onAppear {
            // Remove opaque backgrounds from NSTableView header and enclosing scroll view
            DispatchQueue.main.async {
                for window in NSApp.windows {
                    for tableView in window.contentView?.findViews(ofType: NSTableView.self) ?? [] {
                        tableView.backgroundColor = .clear
                        tableView.enclosingScrollView?.backgroundColor = .clear
                        tableView.enclosingScrollView?.drawsBackground = false
                        tableView.headerView?.wantsLayer = true
                        tableView.headerView?.layer?.backgroundColor = .clear
                        if let headerClip = tableView.headerView?.superview {
                            headerClip.wantsLayer = true
                            headerClip.layer?.backgroundColor = .clear
                        }
                        // Clear the corner view (top-right square)
                        tableView.enclosingScrollView?.wantsLayer = true
                        if let cornerView = tableView.cornerView {
                            cornerView.wantsLayer = true
                            cornerView.layer?.backgroundColor = .clear
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    func raisedPanel(cornerRadius: CGFloat = 18) -> some View {
        clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.background.opacity(0.4))
                    .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
            )
    }

    @ViewBuilder
    func glassOrMaterial(cornerRadius: CGFloat = 18) -> some View {
        if AM.useGlass, #available(macOS 26, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    /// Adds a double click handler this view (macOS only)
    ///
    /// Example
    /// ```
    /// Text("Hello")
    ///     .onDoubleClick { print("Double click detected") }
    /// ```
    /// - Parameters:
    ///   - handler: Block invoked when a double click is detected
    func onDoubleClick(handler: @escaping () -> Void) -> some View {
        modifier(DoubleClickHandler(handler: handler))
    }
}

extension NSView {
    func findViews<T: NSView>(ofType type: T.Type) -> [T] {
        var found = [T]()
        for sub in subviews {
            if let match = sub as? T { found.append(match) }
            found.append(contentsOf: sub.findViews(ofType: type))
        }
        return found
    }
}

struct DoubleClickHandler: ViewModifier {
    let handler: () -> Void

    func body(content: Content) -> some View {
        content.overlay {
            DoubleClickListeningViewRepresentable(handler: handler)
        }
    }
}

struct DoubleClickListeningViewRepresentable: NSViewRepresentable {
    let handler: () -> Void

    func makeNSView(context: Context) -> DoubleClickListeningView {
        DoubleClickListeningView(handler: handler)
    }
    func updateNSView(_ nsView: DoubleClickListeningView, context: Context) {}
}

class DoubleClickListeningView: NSView {
    init(handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    let handler: () -> Void

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            handler()
        }
    }
}
