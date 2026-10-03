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

    /// Text plus the magnifier glyph and padding: the smallest field that still reads as a field.
    static var fittingSize: NSSize {
        let font = NSFont.systemFont(ofSize: fontSize)
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        return NSSize(width: textWidth + 12 + 6 + 24, height: 24)
    }

    var onClick: (() -> Void)?
    var onMoved: ((NSPoint) -> Void)?

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

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func draw(_: NSRect) {
        #if DEBUG || SEARCHBAR_BENCH
            SearchBarBenchmark.count("pillDraw")
        #endif
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
    }
}
