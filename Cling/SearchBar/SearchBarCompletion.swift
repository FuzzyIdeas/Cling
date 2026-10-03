//
//  SearchBarCompletion.swift
//  Cling
//
//  Past searches in the bar, as in the window: the rest of the latest one that starts with the query, drawn after it
//  with the keys that take it, and the ⌘↓ list of the ones that match.
//

import AppKit

// MARK: - SearchBarCompletion

/// What the search row draws after the query: the rest of a past search and the keys that take it.
struct SearchBarCompletion: Equatable {
    var typed: String
    var suffix: String
    var hints: [String]
}

// MARK: - SearchBarGhostLabel

/// The rest of the past search, in the field's font so it continues the query. Clicks go through to the field.
final class SearchBarGhostLabel: NSTextField {
    convenience init() {
        self.init(labelWithString: "")
        textColor = .secondaryLabelColor
        lineBreakMode = .byClipping
        cell?.wraps = false
        setAccessibilityElement(false)
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }
}

// MARK: - SearchBarCompletionHints

/// The keys after the ghost text, boxed like the window's: what fits, in order.
final class SearchBarCompletionHints: NSView {
    override var isFlipped: Bool {
        true
    }

    var hints: [String] = [] {
        didSet {
            guard hints != oldValue else { return }
            needsDisplay = true
        }
    }

    var height: CGFloat {
        ceil(font.ascender - font.descender) + 4
    }

    var fittingWidth: CGFloat {
        hints.map(width(of:)).reduce(0, +) + CGFloat(max(hints.count - 1, 0)) * Self.gap
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func draw(_: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        let textHeight = font.ascender - font.descender
        var x: CGFloat = 0
        for hint in hints {
            let hintWidth = width(of: hint)
            let box = NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: hintWidth, height: bounds.height).insetBy(dx: 0.25, dy: 0.25), xRadius: 4, yRadius: 4)
            box.lineWidth = 0.5
            NSColor.quaternaryLabelColor.setStroke()
            box.stroke()
            (hint as NSString).draw(at: NSPoint(x: x + 4, y: (bounds.height - textHeight) / 2), withAttributes: attributes)
            x += hintWidth + Self.gap
        }
    }

    func fitting(_ hints: [String], in width: CGFloat) -> [String] {
        var shown: [String] = []
        var x: CGFloat = 0
        for hint in hints {
            let hintWidth = self.width(of: hint)
            guard x + hintWidth <= width else { break }
            shown.append(hint)
            x += hintWidth + Self.gap
        }
        return shown
    }

    private static let gap: CGFloat = 6

    private var font: NSFont {
        .monospacedSystemFont(ofSize: FontScale.size(11, .chrome), weight: .regular)
    }

    private func width(of hint: String) -> CGFloat {
        ceil((hint as NSString).size(withAttributes: [.font: font]).width) + 8
    }
}

// MARK: - SearchBarSuggestionsPanel

/// The ⌘↓ list, in a panel of its own under the field so it can hang below a bar that is only its field. It never
/// takes the keyboard: the bar keeps it and moves through the list.
final class SearchBarSuggestionsPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none

        let content = NSView()
        content.wantsLayer = true
        background.autoresizingMask = [.width, .height]
        list.autoresizingMask = [.width, .height]
        content.addSubview(background)
        content.addSubview(list)
        contentView = content
    }

    override var canBecomeKey: Bool {
        false
    }
    override var canBecomeMain: Bool {
        false
    }

    let background = SearchBarBackgroundView(cornerRadius: 10)
    let list = SearchBarSuggestionsView()
}

// MARK: - SearchBarSuggestionsView

final class SearchBarSuggestionsView: NSView {
    /// Where the text starts in from the list's edge, so it lines up with the query above it.
    static let textInset: CGFloat = 12

    override var isFlipped: Bool {
        true
    }

    var onPick: ((Int) -> Void)?
    var onHover: ((Int) -> Void)?

    var items: [String] = [] {
        didSet {
            guard items != oldValue else { return }
            needsDisplay = true
        }
    }

    var highlighted = -1 {
        didSet {
            guard highlighted != oldValue else { return }
            needsDisplay = true
        }
    }

    override func draw(_: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        let textHeight = ceil(font.ascender - font.descender)
        for (index, item) in items.enumerated() {
            let row = rowRect(index)
            if index == highlighted {
                NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
                NSBezierPath(roundedRect: row.insetBy(dx: 5, dy: 1), xRadius: 6, yRadius: 6).fill()
            }
            let text = NSRect(x: Self.textInset, y: row.midY - textHeight / 2, width: row.width - Self.textInset * 2, height: textHeight)
            (item as NSString).draw(with: text, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let index = row(at: convert(event.locationInWindow, from: nil))
        if index >= 0 {
            onHover?(index)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let index = row(at: convert(event.locationInWindow, from: nil))
        if index >= 0 {
            onPick?(index)
        }
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    func fittingSize(maxWidth: CGFloat) -> NSSize {
        let font = font
        let textWidth = items.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 0
        return NSSize(
            width: min(max(textWidth + Self.textInset * 2, 220), maxWidth),
            height: CGFloat(items.count) * rowHeight + Self.padding * 2
        )
    }

    private static let padding: CGFloat = 5

    private var font: NSFont {
        .systemFont(ofSize: FontScale.size(14, .secondary))
    }

    private var rowHeight: CGFloat {
        FontScale.length(28, .secondary)
    }

    private func rowRect(_ index: Int) -> NSRect {
        NSRect(x: 0, y: Self.padding + CGFloat(index) * rowHeight, width: bounds.width, height: rowHeight)
    }

    private func row(at point: NSPoint) -> Int {
        let index = Int(floor((point.y - Self.padding) / rowHeight))
        return items.indices.contains(index) ? index : -1
    }
}
