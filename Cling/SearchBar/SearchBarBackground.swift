//
//  SearchBarBackground.swift
//  Cling
//
//  The surface under the search bar and the compact field, in the user's window style. One
//  background for the whole window: rows, the field and the hint bar draw on top of it without any
//  material of their own, so the blur is composited once per window rather than once per row.
//

import AppKit
import Defaults

// MARK: - SearchBarTintView

/// A flat colour that follows light and dark mode through `updateLayer`, where AppKit has already
/// set the view's appearance as current, so the dynamic colour resolves to the right variant.
final class SearchBarTintView: NSView {
    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override var wantsUpdateLayer: Bool {
        true
    }
    override var allowsVibrancy: Bool {
        false
    }

    var color: NSColor {
        didSet { needsDisplay = true }
    }

    var cornerRadius: CGFloat = 0 {
        didSet { layer?.cornerRadius = cornerRadius }
    }

    override func updateLayer() {
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }
}

// MARK: - SearchBarBackgroundView

/// Glass, vibrant blur or the plain window colour, matching `WindowBackground` in the main window:
/// the same materials under the same tint, so the bar reads as the same app.
final class SearchBarBackgroundView: NSView {
    init(cornerRadius: CGFloat = 0) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    var cornerRadius: CGFloat {
        didSet {
            guard cornerRadius != oldValue else { return }
            applyCornerRadius()
        }
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    /// Re-reads the window style. Cheap enough to call on every summon, and a no-op when the style
    /// didn't change.
    func rebuild() {
        let appearance = Defaults[.windowAppearance]
        let glass: Bool = if #available(macOS 26, *) {
            appearance.isGlassy
        } else {
            false
        }
        let style: Style = glass ? .glass : appearance.isOpaque ? .opaque : .vibrant
        guard style != currentStyle else { return }
        currentStyle = style

        material?.removeFromSuperview()
        tint?.removeFromSuperview()
        material = nil
        tint = nil

        switch style {
        case .glass:
            if #available(macOS 26, *) {
                let glassView = NSGlassEffectView(frame: bounds)
                glassView.style = .regular
                glassView.autoresizingMask = [.width, .height]
                addSubview(glassView)
                material = glassView
            }
            addTint(light: 0.7, dark: 0.5)
        case .vibrant:
            let effect = NSVisualEffectView(frame: bounds)
            effect.material = .menu
            effect.blendingMode = .behindWindow
            // Always active: the bar never activates Cling, so following the window's active state
            // would leave the blur flat grey.
            effect.state = .active
            effect.autoresizingMask = [.width, .height]
            addSubview(effect)
            material = effect
            addTint(light: 0.4, dark: 0.5)
        case .opaque:
            let plain = SearchBarTintView(color: .windowBackgroundColor)
            plain.frame = bounds
            plain.autoresizingMask = [.width, .height]
            addSubview(plain)
            material = plain
        }
        applyCornerRadius()
    }

    private enum Style { case glass, vibrant, opaque }

    private var currentStyle: Style?
    private var material: NSView?
    private var tint: SearchBarTintView?

    /// A stretchable rounded-rect mask: only the corners are drawn, `capInsets` repeat the middle.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    private func addTint(light: CGFloat, dark: CGFloat) {
        let color = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor.black.withAlphaComponent(dark)
                : NSColor.white.withAlphaComponent(light)
        }
        let view = SearchBarTintView(color: color)
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        tint = view
    }

    private func applyCornerRadius() {
        tint?.cornerRadius = cornerRadius
        if #available(macOS 26, *), let glassView = material as? NSGlassEffectView {
            glassView.cornerRadius = cornerRadius
        } else if let effect = material as? NSVisualEffectView {
            effect.maskImage = cornerRadius > 0 ? Self.roundedMask(radius: cornerRadius) : nil
        } else if let plain = material as? SearchBarTintView {
            plain.cornerRadius = cornerRadius
        }
    }

}
