//
//  Styles.swift
//  Cling
//
//  Created by Alin Panaitiu on 06.02.2025.
//

import Foundation
import Lowtech
import SwiftUI

/// One radius shared by the results table, the file preview panel and the action-row background so
/// their rounded corners read as nested inside the window. macOS doesn't expose the window's own
/// radius, and these panels sit only ~16pt in from the edge, so a true concentric inset (via
/// `ContainerRelativeShape`) would round to almost square; a single tuned value tracks the window
/// far better here. Tune this one number to taste.
let windowCornerRadius: CGFloat = 16

// MARK: - TextButtonContent

/// The rendered body shared by the text button styles. This is a real `View` (not the ButtonStyle
/// struct), so its `@State hovering` is actually installed and tracked by SwiftUI. The styles used
/// to call each other's `makeBody` by hand, which left that `@State` dead — the hover and press
/// feedback never updated. Hover/press now drive both the background fill and a subtle scale.
private struct TextButtonContent<Label: View>: View {
    enum Variant { case glass, vibrant, opaque }

    let label: Label
    let isPressed: Bool
    let variant: Variant
    var color = Color.primary.opacity(0.8)
    var borderColor: Color?
    var active = false
    var activeTint: Color = .accentColor
    var isEnabledOverride: Bool?

    var body: some View {
        label
            .foregroundStyle(color)
            .padding(.vertical, 2.0)
            .padding(.horizontal, 8.0)
            .contentShape(isSquare ? AnyShape(squareShape) : AnyShape(Capsule(style: .continuous)))
            .opacity(enabled ? (hovering ? 1 : 0.82) : 0.5)
            .background { fillBackground }
            .overlay { border }
            .scaleEffect(enabled && hovering ? 1.06 : 1)
            .onHover { hover in
                guard enabled else { return }
                withAnimation(.easeOut(duration: 0.14)) { hovering = hover }
            }
            .animation(.easeOut(duration: 0.12), value: isPressed)
    }

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    private var enabled: Bool { isEnabledOverride ?? isEnabled }

    // Opaque pills are squarish (small radius); glass/vibrant are capsules.
    private var isSquare: Bool { variant == .opaque }
    private var squareShape: RoundedRectangle { RoundedRectangle(cornerRadius: 2, style: .continuous) }

    private var fillColor: Color {
        if active { return activeTint.opacity(0.22) }

        if variant == .glass {
            // A contrasting fill against the translucent window: whiter in light, blacker in dark,
            // getting more opaque on hover/press.
            let base = scheme == .dark ? Color.black : Color.white
            guard enabled else { return base.opacity(scheme == .dark ? 0.12 : 0.22) }
            if isPressed { return base.opacity(scheme == .dark ? 0.5 : 0.72) }
            if hovering { return base.opacity(scheme == .dark ? 0.4 : 0.6) }
            return base.opacity(scheme == .dark ? 0.28 : 0.45)
        }

        // Bordered variants rely on their stroke at rest, filling in only on hover/press.
        guard enabled else { return .clear }
        if isPressed { return .primary.opacity(0.18) }
        if hovering { return .primary.opacity(0.12) }
        return .clear
    }

    @ViewBuilder
    private var fillBackground: some View {
        if isSquare {
            squareShape.fill(fillColor)
        } else {
            Capsule(style: .continuous).fill(fillColor)
        }
    }

    @ViewBuilder
    private var border: some View {
        switch variant {
        case .glass:
            // A caller that opts out (e.g. the status bar passes `.clear`) wins; otherwise the glass
            // pills get a modern top-lit bevel edge that reads as a thin glass rim.
            if let borderColor {
                Capsule(style: .continuous).strokeBorder(borderColor, lineWidth: 0.5)
            } else {
                Capsule(style: .continuous).strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(scheme == .dark ? 0.30 : 0.65),
                            .black.opacity(scheme == .dark ? 0.04 : 0.06),
                        ],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
            }
        case .vibrant:
            Capsule(style: .continuous).strokeBorder(borderColor ?? color, lineWidth: 0.5)
        case .opaque:
            squareShape.strokeBorder((borderColor ?? color).opacity(0.4), lineWidth: 1)
        }
    }

}

// MARK: - GlassTextButton

struct GlassTextButton: ButtonStyle {
    public func makeBody(configuration: Configuration) -> some View {
        TextButtonContent(label: configuration.label, isPressed: configuration.isPressed, variant: .glass, color: color, active: active, activeTint: activeTint, isEnabledOverride: isEnabledOverride)
    }

    var color = Color.primary.opacity(0.8)
    var active = false
    var activeTint: Color = .accentColor
    var isEnabledOverride: Bool?
}

// MARK: - VibrantTextButton

struct VibrantTextButton: ButtonStyle {
    public func makeBody(configuration: Configuration) -> some View {
        TextButtonContent(label: configuration.label, isPressed: configuration.isPressed, variant: .vibrant, color: color, borderColor: borderColor, active: active, activeTint: activeTint, isEnabledOverride: isEnabledOverride)
    }

    var color = Color.primary.opacity(0.8)
    var borderColor: Color?
    var active = false
    var activeTint: Color = .accentColor
    var isEnabledOverride: Bool?
}

// MARK: - OpaqueTextButton

struct OpaqueTextButton: ButtonStyle {
    public func makeBody(configuration: Configuration) -> some View {
        TextButtonContent(label: configuration.label, isPressed: configuration.isPressed, variant: .opaque, color: color, borderColor: borderColor, active: active, activeTint: activeTint, isEnabledOverride: isEnabledOverride)
    }

    var color = Color.primary.opacity(0.8)
    var borderColor: Color?
    var active = false
    var activeTint: Color = .accentColor
    var isEnabledOverride: Bool?
}

// MARK: - TextButton

struct TextButton: ButtonStyle {
    public func makeBody(configuration: Configuration) -> some View {
        let variant: TextButtonContent<Configuration.Label>.Variant = AM.useGlass ? .glass : (AM.useVibrant ? .vibrant : .opaque)
        TextButtonContent(label: configuration.label, isPressed: configuration.isPressed, variant: variant, color: color, borderColor: borderColor, active: active, activeTint: activeTint)
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

// MARK: - BorderlessTextButton

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

// MARK: - ButtonFlash

/// Transient confirmation message ("Copied", "Link copied", …) that overlays a button.
/// Fills the button's footprint so it shares the button's width and capsule radius; longer
/// text scales down to fit rather than spilling past the button.
struct ButtonFlash: ViewModifier {
    let text: String
    let visible: Bool
    var fontSize: CGFloat = 10
    var tint: Color = .accentColor

    func body(content: Content) -> some View {
        content.overlay {
            if visible {
                Text(text)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(tint, in: Capsule())
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
    }
}

extension View {
    func buttonFlash(_ text: String, visible: Bool, fontSize: CGFloat = 10, tint: Color = .accentColor) -> some View {
        modifier(ButtonFlash(text: text, visible: visible, fontSize: fontSize, tint: tint))
    }
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
    func raisedPanel(cornerRadius: CGFloat = windowCornerRadius) -> some View {
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

    /// Full-width translucent bar for floating over preview content: Liquid
    /// Glass on macOS 26 (when enabled), ultra-thin material otherwise. The
    /// image or text underneath shows through it. Outer corners are left square
    /// and clipped to shape by the enclosing panel.
    @ViewBuilder
    func glassBar() -> some View {
        if AM.useGlass, #available(macOS 26, *) {
            self.glassEffect(.regular, in: Rectangle())
        } else {
            background(.ultraThinMaterial)
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

// MARK: - DoubleClickHandler

struct DoubleClickHandler: ViewModifier {
    let handler: () -> Void

    func body(content: Content) -> some View {
        content.overlay {
            DoubleClickListeningViewRepresentable(handler: handler)
        }
    }
}

// MARK: - DoubleClickListeningViewRepresentable

struct DoubleClickListeningViewRepresentable: NSViewRepresentable {
    let handler: () -> Void

    func makeNSView(context: Context) -> DoubleClickListeningView {
        DoubleClickListeningView(handler: handler)
    }
    func updateNSView(_ nsView: DoubleClickListeningView, context: Context) {}
}

// MARK: - DoubleClickListeningView

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
