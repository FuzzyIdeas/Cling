//
//  SearchBarPill.swift
//  Cling
//
//  The compact field pinned to the desktop. It observes nothing: one static label on the window
//  style's background, redrawn only when the style or the system appearance changes. It never takes
//  key focus, so it can sit on screen forever without pulling focus from the app in front.
//

import AppKit
import Defaults
import Lowtech

// MARK: - SearchBarPillPanel

final class SearchBarPillPanel: NSPanel {
    override var canBecomeKey: Bool {
        false
    }
    override var canBecomeMain: Bool {
        false
    }
}

// MARK: - SearchBarPillView

final class SearchBarPillView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(background)
        addSubview(label)
        background.frame = bounds
        background.autoresizingMask = [.width, .height]
        label.frame = bounds
        label.autoresizingMask = [.width, .height]
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(Self.text)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    static let text = "Search files…"
    static let fontSize: CGFloat = 12

    static let hotkeyFontSize: CGFloat = 11

    var onClick: (() -> Void)?
    var onMoved: ((NSPoint) -> Void)?

    var hotkey: String? {
        get { label.hotkey }
        set { label.hotkey = newValue }
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func layout() {
        super.layout()
        background.cornerRadius = bounds.height / 2
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let start = dragStart else { return }
        let current = event.locationInWindow
        let dx = current.x - start.x
        let dy = current.y - start.y
        guard dragged || abs(dx) > 2 || abs(dy) > 2 else { return }
        dragged = true
        window.setFrameOrigin(NSPoint(x: window.frame.origin.x + dx, y: window.frame.origin.y + dy))
    }

    override func mouseUp(with _: NSEvent) {
        defer { dragStart = nil }
        if dragged, let window {
            onMoved?(window.frame.origin)
        } else {
            onClick?()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// Text plus the magnifier glyph and padding: the smallest field that still reads as a field. The hotkey, when
    /// it's shown, sits in a keycap after the text.
    static func fittingSize(hotkey: String?) -> NSSize {
        let font = NSFont.systemFont(ofSize: fontSize)
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        var width = textWidth + 12 + 6 + 24
        if let hotkey {
            width += hotkeyCapWidth(hotkey) + 8 - 6
        }
        return NSSize(width: width, height: 24)
    }

    static func hotkeyCapWidth(_ hotkey: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: hotkeyFontSize, weight: .medium)
        return ceil((hotkey as NSString).size(withAttributes: [.font: font]).width) + 10
    }

    func restyle() {
        background.rebuild()
        background.cornerRadius = bounds.height / 2
        label.needsDisplay = true
    }

    private let background = SearchBarBackgroundView(clear: true)
    private let label = PillLabel()
    private var dragStart: NSPoint?
    private var dragged = false
}

// MARK: - PillLabel

private final class PillLabel: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override var allowsVibrancy: Bool {
        false
    }

    var hotkey: String? {
        didSet {
            guard hotkey != oldValue else { return }
            needsDisplay = true
        }
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    /// Drawn only on request, so a new size (the hotkey's keycap coming or going) has to ask.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed {
            needsDisplay = true
        }
    }

    override func draw(_: NSRect) {
        #if DEBUG || SEARCHBAR_BENCH
            SearchBarBenchmark.count("pillDraw")
        #endif
        NSColor.clear.setFill()
        bounds.fill(using: .copy)
        let font = NSFont.systemFont(ofSize: SearchBarPillView.fontSize)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        // The colour goes in as the symbol's palette, resolved now, while this view's appearance is the current one.
        let color = NSColor(cgColor: NSColor.secondaryLabelColor.cgColor) ?? .secondaryLabelColor
        let config = NSImage.SymbolConfiguration(pointSize: SearchBarPillView.fontSize - 1, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let glyph = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        var x: CGFloat = 10
        if let glyph {
            let size = glyph.size
            glyph.draw(in: NSRect(x: x, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
            x += size.width + 5
        }
        let text = SearchBarPillView.text as NSString
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2), withAttributes: attrs)

        guard let hotkey else { return }
        let capWidth = SearchBarPillView.hotkeyCapWidth(hotkey)
        let cap = NSRect(x: bounds.maxX - 4 - capWidth, y: 4, width: capWidth, height: bounds.height - 8)
        (NSColor(cgColor: NSColor.labelColor.withAlphaComponent(0.08).cgColor) ?? .quaternaryLabelColor).setFill()
        NSBezierPath(roundedRect: cap, xRadius: cap.height / 2, yRadius: cap.height / 2).fill()
        let keyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: SearchBarPillView.hotkeyFontSize, weight: .medium),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let keySize = (hotkey as NSString).size(withAttributes: keyAttrs)
        (hotkey as NSString).draw(at: NSPoint(x: cap.midX - keySize.width / 2, y: cap.midY - keySize.height / 2), withAttributes: keyAttrs)
    }
}
