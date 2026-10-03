//
//  SearchBarViews.swift
//  Cling
//
//  AppKit pieces of the expanded search bar: the field row, the hint bar and the root view that
//  lays them out by hand. Manual frames instead of constraints, so a label changing its text never
//  sets off a layout pass over the rest of the window.
//

import AppKit
import Lowtech
import SwiftUI

// MARK: - SearchBarField

final class SearchBarField: NSTextField {
    var onMouseDown: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        // The field editor draws the caret; keep its background clear like the field.
        (currentEditor() as? NSTextView)?.drawsBackground = false
        return ok
    }
}

// MARK: - SearchBarIconButton

/// A borderless SF Symbol button that tints itself and never takes focus away from the field.
final class SearchBarIconButton: NSButton {
    var symbol = "" {
        didSet {
            guard symbol != oldValue else { return }
            updateImage()
        }
    }

    var pointSize: CGFloat = 14 {
        didSet {
            guard pointSize != oldValue else { return }
            updateImage()
        }
    }

    var tint: NSColor? {
        didSet {
            guard tint != oldValue else { return }
            contentTintColor = tint ?? .secondaryLabelColor
        }
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    func configure(symbol: String, accessibility: String, target: AnyObject?, action: Selector) {
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        refusesFirstResponder = true
        focusRingType = .none
        setAccessibilityLabel(accessibility)
        self.symbol = symbol
        updateImage()
    }

    private func updateImage() {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityLabel())?.withSymbolConfiguration(config)
        contentTintColor = tint ?? .secondaryLabelColor
    }
}

// MARK: - SearchBarHint

struct SearchBarHint: Equatable {
    enum ID: Equatable {
        case open, paste, showInFinder, quickLook, copy, drill, actions
    }

    let id: ID
    let key: String
    let title: String
}

// MARK: - SearchBarHintBar

/// The row of key hints along the bottom and the result count on the right, drawn as one layer.
/// Each hint is clickable; their rects are kept from the last draw.
final class SearchBarHintBar: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.contentsFormat = .RGBA8Uint
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override var isFlipped: Bool {
        true
    }
    override var allowsVibrancy: Bool {
        false
    }

    var onHint: ((SearchBarHint.ID) -> Void)?

    var hints: [SearchBarHint] = [] {
        didSet {
            guard hints != oldValue else { return }
            needsDisplay = true
        }
    }

    var status = "" {
        didSet {
            guard status != oldValue else { return }
            needsDisplay = true
        }
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func draw(_: NSRect) {
        let text = SearchBarTextCache.shared
        var rects: [(SearchBarHint.ID, NSRect)] = []

        let statusText = flashText ?? status
        let statusStyle: SearchBarTextCache.Style = flashText == nil ? .status : .flash
        let statusSize = text.size(statusText, style: statusStyle)
        let statusX = bounds.width - statusSize.width - 14
        text.draw(
            statusText, style: statusStyle, at: NSPoint(x: statusX, y: (bounds.height - statusSize.height) / 2),
            color: flashText == nil ? .tertiaryLabelColor : .controlAccentColor
        )

        var x: CGFloat = 12
        let limit = statusX - 12
        let capHeight = round(bounds.height * 0.6)
        let capFill = NSColor.labelColor.withAlphaComponent(0.08)
        for hint in hints {
            let keySize = text.size(hint.key, style: .hintKey)
            let titleSize = text.size(hint.title, style: .hintTitle)
            let capWidth = max(keySize.width + 8, capHeight)
            let width = capWidth + 5 + titleSize.width
            guard x + width <= limit else { break }

            let capRect = NSRect(x: x, y: (bounds.height - capHeight) / 2, width: capWidth, height: capHeight)
            capFill.setFill()
            NSBezierPath(roundedRect: capRect, xRadius: 4, yRadius: 4).fill()
            text.draw(
                hint.key, style: .hintKey,
                at: NSPoint(x: capRect.midX - keySize.width / 2, y: capRect.midY - keySize.height / 2), color: .secondaryLabelColor
            )
            text.draw(
                hint.title, style: .hintTitle,
                at: NSPoint(x: capRect.maxX + 5, y: (bounds.height - titleSize.height) / 2), color: .secondaryLabelColor
            )

            rects.append((hint.id, NSRect(x: x - 4, y: 0, width: width + 8, height: bounds.height)))
            x += width + 16
        }
        // Cursor rects are part of the window's structural regions, which AppKit recomputes in
        // full when they're invalidated, so only when the hints actually moved.
        if !rects.elementsEqual(hintRects, by: { $0.0 == $1.0 && $0.1 == $1.1 }) {
            hintRects = rects
            window?.invalidateCursorRects(for: self)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = hintRects.first(where: { $0.1.contains(point) }) {
            onHint?(hit.0)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func resetCursorRects() {
        for (_, rect) in hintRects {
            addCursorRect(rect, cursor: .pointingHand)
        }
    }

    /// A short confirmation ("Copied") that replaces the status for a moment.
    func flash(_ text: String) {
        flashText = text
        needsDisplay = true
        flashTask?.cancel()
        flashTask = mainAsyncAfter(ms: 1200) { [weak self] in
            self?.flashText = nil
            self?.needsDisplay = true
        }
    }

    private var hintRects: [(SearchBarHint.ID, NSRect)] = []
    private var flashText: String?
    private var flashTask: DispatchWorkItem?
}

// MARK: - SearchBarSeparator

final class SearchBarSeparator: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
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

    override func updateLayer() {
        layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
    }
}

// MARK: - SearchBarChip

/// A small capsule label: the active filter, or the orange Everything badge.
final class SearchBarChip: NSView {
    init(color: NSColor? = nil) {
        fill = color
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override var isFlipped: Bool {
        true
    }
    override var allowsVibrancy: Bool {
        false
    }

    var onClick: (() -> Void)?

    var text = "" {
        didSet {
            guard text != oldValue else { return }
            needsDisplay = true
        }
    }

    var color: NSColor = .secondaryLabelColor {
        didSet { needsDisplay = true }
    }

    var fill: NSColor? {
        didSet { needsDisplay = true }
    }

    var fittingWidth: CGFloat {
        guard !text.isEmpty else { return 0 }
        return ceil((text as NSString).size(withAttributes: attrs).width) + 16
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func draw(_: NSRect) {
        guard !text.isEmpty else { return }
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        if let fill {
            fill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        } else {
            color.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        }
        var attrs = attrs
        attrs[.foregroundColor] = fill == nil ? color : NSColor.white
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }

    override func mouseDown(with _: NSEvent) {
        onClick?()
    }

    private var attrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: FontScale.size(10.5, .chrome), weight: .semibold)]
    }
}

// MARK: - SearchBarRootView

/// Everything inside the expanded bar. Owns no state: the controller pushes values in.
final class SearchBarRootView: NSView {
    init(results: SearchBarResultsController) {
        self.results = results
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        wantsLayer = true

        addSubview(background)
        addSubview(field)
        addSubview(filterButton)
        addSubview(filterChip)
        addSubview(everythingChip)
        addSubview(spinner)
        addSubview(everythingButton)
        addSubview(sortButton)
        addSubview(previewButton)
        addSubview(topSeparator)
        addSubview(results.scrollView)
        addSubview(emptyLabel)
        addSubview(previewDivider)
        addSubview(previewContainer)
        addSubview(bottomSeparator)
        addSubview(hintBar)
        addSubview(sheetHost)

        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setAccessibilityLabel("Search")
        sheetHost.sizingOptions = []

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isIndeterminate = true

        emptyLabel.isEditable = false
        emptyLabel.isSelectable = false
        emptyLabel.isBordered = false
        emptyLabel.drawsBackground = false
        emptyLabel.alignment = .center
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.isHidden = true

        everythingChip.isHidden = true
        filterChip.isHidden = true
        previewContainer.isHidden = true
        previewDivider.isHidden = true
        applyFonts()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override var isFlipped: Bool {
        true
    }

    let results: SearchBarResultsController
    let background = SearchBarBackgroundView()
    let field = SearchBarField()
    let filterButton = SearchBarIconButton()
    let filterChip = SearchBarChip()
    let everythingChip = SearchBarChip(color: .systemOrange)
    let spinner = NSProgressIndicator()
    let everythingButton = SearchBarIconButton()
    let sortButton = SearchBarIconButton()
    let previewButton = SearchBarIconButton()
    let topSeparator = SearchBarSeparator()
    let bottomSeparator = SearchBarSeparator()
    let previewDivider = SearchBarSeparator()
    let emptyLabel = NSTextField(labelWithString: "")
    let hintBar = SearchBarHintBar()
    /// Holds the preview's hosting view, created the first time the preview is shown.
    let previewContainer = NSView()
    /// A zero-size SwiftUI host that presents the bar's sheets (rename, copy and move).
    let sheetHost = NSHostingView(rootView: SearchBarSheetHost())

    var showsPreview = false {
        didSet {
            guard showsPreview != oldValue else { return }
            previewContainer.isHidden = !showsPreview
            previewDivider.isHidden = !showsPreview
            needsLayout = true
        }
    }

    /// Clicks that reach the background drag the window. The panel isn't movable by AppKit (see
    /// SearchBarController.ensurePanel), so this follows the cursor itself until the button is up.
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let startMouse = NSEvent.mouseLocation
        let startOrigin = window.frame.origin
        var moved = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - startMouse.x
            let dy = mouse.y - startMouse.y
            guard moved || abs(dx) > 2 || abs(dy) > 2 else { continue }
            moved = true
            window.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
        }
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height
        let rowHeight = FontScale.length(52, .secondary)
        let hintHeight = FontScale.length(30, .chrome)

        background.frame = bounds
        sheetHost.frame = NSRect(x: 0, y: 0, width: 1, height: 1)

        // Search row, laid out from both ends towards the field.
        let iconBox = FontScale.length(28, .control)
        let iconY = (rowHeight - iconBox) / 2
        filterButton.frame = NSRect(x: 12, y: iconY, width: iconBox + 4, height: iconBox)

        var right = w - 12
        for button in [previewButton, sortButton, everythingButton] {
            right -= iconBox
            button.frame = NSRect(x: right, y: iconY, width: iconBox, height: iconBox)
            right -= 2
        }
        let spinnerSide: CGFloat = 16
        right -= 6
        spinner.frame = NSRect(x: right - spinnerSide, y: (rowHeight - spinnerSide) / 2, width: spinnerSide, height: spinnerSide)
        right -= spinnerSide + 6

        let chipHeight = FontScale.length(20, .chrome)
        for chip in [everythingChip, filterChip] where !chip.isHidden {
            let width = min(chip.fittingWidth, 220)
            right -= width
            chip.frame = NSRect(x: right, y: (rowHeight - chipHeight) / 2, width: width, height: chipHeight)
            right -= 6
        }

        let fieldX = filterButton.frame.maxX + 6
        let fieldHeight = ceil((field.font?.boundingRectForFont.height ?? 24) + 2)
        field.frame = NSRect(x: fieldX, y: (rowHeight - fieldHeight) / 2, width: max(right - fieldX - 4, 40), height: fieldHeight)

        topSeparator.frame = NSRect(x: 0, y: rowHeight, width: w, height: 1)
        hintBar.frame = NSRect(x: 0, y: h - hintHeight, width: w, height: hintHeight)
        bottomSeparator.frame = NSRect(x: 0, y: h - hintHeight - 1, width: w, height: 1)

        let middleY = rowHeight + 1
        let middleHeight = max(h - hintHeight - 1 - middleY, 0)
        var listWidth = w
        if showsPreview {
            let previewWidth = min(max(round(w * 0.42), 260), w - 280)
            listWidth = w - previewWidth - 1
            previewDivider.frame = NSRect(x: listWidth, y: middleY, width: 1, height: middleHeight)
            previewContainer.frame = NSRect(x: listWidth + 1, y: middleY, width: previewWidth, height: middleHeight)
            previewContainer.subviews.first?.frame = previewContainer.bounds
        }
        results.scrollView.frame = NSRect(x: 0, y: middleY, width: listWidth, height: middleHeight)
        let labelHeight: CGFloat = 22
        emptyLabel.frame = NSRect(x: 16, y: middleY + middleHeight / 2 - labelHeight / 2, width: max(listWidth - 32, 10), height: labelHeight)
    }

    func applyFonts() {
        guard fontScale != FontScale.current || field.font == nil else { return }
        fontScale = FontScale.current
        field.font = .systemFont(ofSize: FontScale.size(20, .secondary), weight: .regular)
        field.placeholderAttributedString = NSAttributedString(
            string: "Search files…",
            attributes: [
                .font: NSFont.systemFont(ofSize: FontScale.size(20, .secondary), weight: .regular),
                .foregroundColor: NSColor.placeholderTextColor,
            ]
        )
        emptyLabel.font = .systemFont(ofSize: FontScale.size(13, .secondary))
        let iconSize = FontScale.size(15, .control)
        for button in [filterButton, everythingButton, sortButton, previewButton] {
            button.pointSize = iconSize
        }
        filterButton.pointSize = FontScale.size(18, .secondary)
        needsLayout = true
    }

    private var fontScale: Double = 0
}
