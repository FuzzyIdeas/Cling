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
import SwiftUI

// MARK: - SearchBarMetrics

/// Shapes shared by the bar's pieces. From macOS 26 windows and controls are much rounder, and the bar follows.
enum SearchBarMetrics {
    static let modern = if #available(macOS 26, *) {
        true
    } else {
        false
    }

    static let windowRadius: CGFloat = modern ? 26 : 14
    /// How far rows, the preview card and the hint bar sit in from the window's edge.
    static let inset: CGFloat = 8
    static let rowRadius: CGFloat = modern ? 12 : 7
    static let buttonRadius: CGFloat = modern ? 9 : 6
    static let cardRadius: CGFloat = modern ? 18 : 9
    static let buttonSide: CGFloat = 30
}

extension NSColor {
    /// The orange of Everything and the stash. The system orange is too light to read on its own tint over a light
    /// background, so light mode gets a deeper one.
    static let searchBarOrange = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .systemOrange
            : NSColor(srgbRed: 0.7, green: 0.32, blue: 0, alpha: 1)
    }

    /// A quick filter's colour for its pill, following light and dark mode.
    static func searchBarFilter(hue: Double) -> NSColor {
        NSColor(name: nil) { appearance in
            NSColor(FilterColor(hue: hue).accent(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua))
        }
    }
}

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
    /// `clear` is for the pinned field: glass at its most transparent and the blur without a tint, as the field holds
    /// a single line of text and should show the desktop under it.
    init(cornerRadius: CGFloat = 0, clear: Bool = false) {
        self.cornerRadius = cornerRadius
        self.clear = clear
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
        edge?.removeFromSuperview()
        material = nil
        tint = nil
        edge = nil

        switch style {
        case .glass:
            if #available(macOS 26, *) {
                let glassView = NSGlassEffectView(frame: bounds)
                glassView.style = clear ? .clear : .regular
                glassView.autoresizingMask = [.width, .height]
                addSubview(glassView)
                material = glassView
            }
            // Only enough to keep text legible over a busy desktop: more turns the glass into grey paint. Clear glass
            // still needs dimming in dark mode, or over a light window it's a grey capsule with grey text.
            if clear {
                addTint(light: 0, dark: 0.5)
            } else {
                addTint(light: 0.12, dark: 0.18)
            }
        case .vibrant:
            let effect = NSVisualEffectView(frame: bounds)
            effect.material = .popover
            effect.blendingMode = .behindWindow
            // Always active: the bar never activates Cling, so following the window's active state
            // would leave the blur flat grey.
            effect.state = .active
            effect.autoresizingMask = [.width, .height]
            addSubview(effect)
            material = effect
            if clear {
                addTint(light: 0, dark: 0.4)
            } else {
                addTint(light: 0.1, dark: 0.15)
            }
            addEdge()
        case .opaque:
            let plain = SearchBarTintView(color: .windowBackgroundColor)
            plain.frame = bounds
            plain.autoresizingMask = [.width, .height]
            addSubview(plain)
            material = plain
            addEdge()
        }
        applyCornerRadius()
    }

    private enum Style { case glass, vibrant, opaque }

    private let clear: Bool

    private var currentStyle: Style?
    private var material: NSView?
    private var tint: SearchBarTintView?
    private var edge: SearchBarEdgeView?

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

    /// The hairline a window has along its edge, which glass draws for itself.
    private func addEdge() {
        let view = SearchBarEdgeView()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        edge = view
    }

    private func applyCornerRadius() {
        tint?.cornerRadius = cornerRadius
        edge?.cornerRadius = cornerRadius
        if #available(macOS 26, *), let glassView = material as? NSGlassEffectView {
            glassView.cornerRadius = cornerRadius
            // The glass rounds what it shows, but still covers its whole rectangle at a sliver of alpha, which is
            // enough for the window to cast a square shadow under the rounded corners. Clipping it here stops that.
            layer?.cornerRadius = cornerRadius
            layer?.cornerCurve = .continuous
            layer?.masksToBounds = cornerRadius > 0
        } else if let effect = material as? NSVisualEffectView {
            effect.maskImage = cornerRadius > 0 ? Self.roundedMask(radius: cornerRadius) : nil
        } else if let plain = material as? SearchBarTintView {
            plain.cornerRadius = cornerRadius
        }
    }

}

// MARK: - SearchBarEdgeView

final class SearchBarEdgeView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
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

    var cornerRadius: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.1)).cgColor
        layer?.borderWidth = 1 / (window?.backingScaleFactor ?? 2)
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }
}
