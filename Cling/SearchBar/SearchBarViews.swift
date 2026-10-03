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

/// A borderless SF Symbol button that tints itself and never takes focus away from the field. With `squircle` it sits
/// on a rounded square like a toolbar button, tinted along with the symbol while it's on.
final class SearchBarIconButton: NSButton {
    override var isHighlighted: Bool {
        didSet { updateBackground() }
    }

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
            updateImage()
        }
    }

    var squircle = false {
        didSet { updateBackground() }
    }

    /// Text after the symbol, in the tint colour: the Everything toggle while it's on.
    var label: String? {
        didSet {
            guard label != oldValue else { return }
            updateImage()
        }
    }

    /// The width the button needs: square with only a symbol, wider with a label.
    var fittingWidth: CGFloat {
        let side = FontScale.length(SearchBarMetrics.buttonSide, .control)
        guard let content = labelContent() else { return side }
        return max(side, ceil(content.glyph.size.width + Self.labelGap + content.text.size().width) + 2 * Self.labelPadding)
    }

    /// With a label the symbol is drawn here at the text's size, beside it, rather than by the cell at the icon size.
    override func draw(_ dirtyRect: NSRect) {
        guard let content = labelContent() else {
            super.draw(dirtyRect)
            return
        }
        let textSize = content.text.size()
        let glyphSize = content.glyph.size
        var x = ((bounds.width - glyphSize.width - Self.labelGap - textSize.width) / 2).rounded()
        // Both centred on the same midline; for the system font the capitals' centre is the line box's centre.
        content.glyph.draw(in: NSRect(x: x, y: ((bounds.height - glyphSize.height) / 2).rounded(), width: glyphSize.width, height: glyphSize.height))
        x += glyphSize.width + Self.labelGap
        content.text.draw(at: NSPoint(x: x, y: ((bounds.height - textSize.height) / 2).rounded()))
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        guard squircle else { return }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with _: NSEvent) {
        hovering = true
    }

    override func mouseExited(with _: NSEvent) {
        hovering = false
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
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
        wantsLayer = true
        setAccessibilityLabel(accessibility)
        self.symbol = symbol
        updateImage()
    }

    private static let labelGap: CGFloat = 6
    private static let labelPadding: CGFloat = 10

    private var hoverArea: NSTrackingArea?

    private var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            updateBackground()
        }
    }

    private func updateImage() {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityLabel())?.withSymbolConfiguration(config)
        contentTintColor = tint ?? .secondaryLabelColor
        needsDisplay = true
        updateBackground()
    }

    private func labelContent() -> (glyph: NSImage, text: NSAttributedString)? {
        guard let label else { return nil }
        let color = tint ?? .secondaryLabelColor
        let font = NSFont.systemFont(ofSize: FontScale.size(12, .control), weight: .semibold)
        let config = NSImage.SymbolConfiguration(pointSize: font.pointSize - 1, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return nil }
        return (glyph, NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: color]))
    }

    private func updateBackground() {
        guard let layer else { return }
        guard squircle else {
            layer.backgroundColor = nil
            return
        }
        let base = tint ?? .labelColor
        let alpha = (tint == nil ? 0.06 : 0.16) + (hovering ? 0.05 : 0) + (isHighlighted ? 0.06 : 0)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = base.withAlphaComponent(alpha).cgColor
        }
        layer.cornerRadius = SearchBarMetrics.buttonRadius
        layer.cornerCurve = .continuous
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

        var x = SearchBarRowStyle.iconX
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
            let capRadius: CGFloat = SearchBarMetrics.modern ? 5 : 4
            NSBezierPath(roundedRect: capRect, xRadius: capRadius, yRadius: capRadius).fill()
            text.draw(
                hint.key, style: .hintKey,
                at: NSPoint(x: capRect.midX - keySize.width / 2, y: capRect.midY - keySize.height / 2), color: .secondaryLabelColor
            )
            text.draw(
                hint.title, style: .hintTitle,
                at: NSPoint(x: capRect.maxX + 5, y: (bounds.height - titleSize.height) / 2), color: .tertiaryLabelColor
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

// MARK: - SearchBarCardView

/// The rounded, faintly filled card the preview sits in, so it floats on the bar's background like the rows do.
final class SearchBarCardView: NSView {
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

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.05) : NSColor.black.withAlphaComponent(0.035)).cgColor
        layer?.cornerRadius = SearchBarMetrics.cardRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }
}

// MARK: - SearchBarResizeOverlay

/// Resizes the borderless bar from its edges and corners, as a titled window would. It only answers clicks near the
/// edge, so everything under it keeps its own.
final class SearchBarResizeOverlay: NSView {
    var minSize = NSSize(width: 560, height: 320)
    var onResizeEnd: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        edges(at: convert(point, from: superview)) == nil ? nil : self
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        let b = bounds
        let g = Self.grip
        let c = Self.corner
        let rects: [(NSRect, Edges)] = [
            (NSRect(x: c, y: 0, width: b.width - 2 * c, height: g), .bottom),
            (NSRect(x: c, y: b.height - g, width: b.width - 2 * c, height: g), .top),
            (NSRect(x: 0, y: c, width: g, height: b.height - 2 * c), .left),
            (NSRect(x: b.width - g, y: c, width: g, height: b.height - 2 * c), .right),
            (NSRect(x: 0, y: 0, width: c, height: c), [.left, .bottom]),
            (NSRect(x: b.width - c, y: 0, width: c, height: c), [.right, .bottom]),
            (NSRect(x: 0, y: b.height - c, width: c, height: c), [.left, .top]),
            (NSRect(x: b.width - c, y: b.height - c, width: c, height: c), [.right, .top]),
        ]
        for (rect, edges) in rects {
            addCursorRect(rect, cursor: Self.cursor(for: edges))
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window, let edges = edges(at: convert(event.locationInWindow, from: nil)) else { return }
        let start = NSEvent.mouseLocation
        let startFrame = window.frame
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - start.x
            let dy = mouse.y - start.y
            var frame = startFrame
            if edges.contains(.right) {
                frame.size.width = max(startFrame.width + dx, minSize.width)
            }
            if edges.contains(.left) {
                frame.size.width = max(startFrame.width - dx, minSize.width)
                frame.origin.x = startFrame.maxX - frame.width
            }
            if edges.contains(.top) {
                frame.size.height = max(startFrame.height + dy, minSize.height)
            }
            if edges.contains(.bottom) {
                frame.size.height = max(startFrame.height - dy, minSize.height)
                frame.origin.y = startFrame.maxY - frame.height
            }
            window.setFrame(frame, display: true)
        }
        onResizeEnd?()
    }

    private struct Edges: OptionSet {
        static let left = Edges(rawValue: 1)
        static let right = Edges(rawValue: 2)
        static let top = Edges(rawValue: 4)
        static let bottom = Edges(rawValue: 8)

        let rawValue: Int

    }

    private static let grip: CGFloat = 5
    private static let corner: CGFloat = 14

    private static func cursor(for edges: Edges) -> NSCursor {
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition = switch edges {
            case [.left, .top]: .topLeft
            case [.right, .top]: .topRight
            case [.left, .bottom]: .bottomLeft
            case [.right, .bottom]: .bottomRight
            case .left: .left
            case .right: .right
            case .top: .top
            default: .bottom
            }
            return .frameResize(position: position, directions: .all)
        }
        return edges.contains(.left) || edges.contains(.right) ? .resizeLeftRight : .resizeUpDown
    }

    /// Which edges a point is close enough to grab, in the overlay's own coordinates.
    private func edges(at p: NSPoint) -> Edges? {
        let b = bounds
        guard b.contains(p) else { return nil }
        let near = { (d: CGFloat, limit: CGFloat) in d < limit }
        let left = p.x, right = b.width - p.x, bottom = isFlipped ? b.height - p.y : p.y, top = isFlipped ? p.y : b.height - p.y
        // Corners grab from further in, as the rounded corner leaves little edge to aim at.
        if near(min(left, right), Self.corner), near(min(top, bottom), Self.corner) {
            return [left < right ? .left : .right, top < bottom ? .top : .bottom]
        }
        var edges: Edges = []
        if near(left, Self.grip) {
            edges.insert(.left)
        }
        if near(right, Self.grip) {
            edges.insert(.right)
        }
        if near(top, Self.grip) {
            edges.insert(.top)
        }
        if near(bottom, Self.grip) {
            edges.insert(.bottom)
        }
        return edges.isEmpty ? nil : edges
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
        addSubview(spinner)
        addSubview(everythingButton)
        addSubview(sortButton)
        addSubview(previewButton)
        addSubview(results.scrollView)
        addSubview(emptyLabel)
        addSubview(previewContainer)
        addSubview(hintBar)
        addSubview(sheetHost)
        addSubview(resizeOverlay)

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
        background.cornerRadius = SearchBarMetrics.windowRadius
        for button in [everythingButton, sortButton, previewButton] {
            button.squircle = true
        }

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

        filterChip.isHidden = true
        previewContainer.isHidden = true
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
    let spinner = NSProgressIndicator()
    let everythingButton = SearchBarIconButton()
    let sortButton = SearchBarIconButton()
    let previewButton = SearchBarIconButton()
    let emptyLabel = NSTextField(labelWithString: "")
    let hintBar = SearchBarHintBar()
    /// Holds the preview's hosting view, created the first time the preview is shown.
    let previewContainer = SearchBarCardView()
    /// A zero-size SwiftUI host that presents the bar's sheets (rename, copy and move).
    let sheetHost = NSHostingView(rootView: SearchBarSheetHost())
    let resizeOverlay = SearchBarResizeOverlay()

    var showsPreview = false {
        didSet {
            guard showsPreview != oldValue else { return }
            previewContainer.isHidden = !showsPreview
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
        let rowHeight = FontScale.length(54, .secondary)
        let hintHeight = FontScale.length(SearchBarMetrics.modern ? 34 : 30, .chrome)
        let inset = SearchBarMetrics.inset

        background.frame = bounds
        resizeOverlay.frame = bounds
        sheetHost.frame = NSRect(x: 0, y: 0, width: 1, height: 1)

        // Search row, laid out from both ends towards the field. Everything is centred on the row's midline.
        let mid = rowHeight / 2
        let iconBox = FontScale.length(28, .control)
        // The filter button is centred over the rows' icons and the query starts where their names do.
        let rowStyle = SearchBarRowStyle.shared
        let filterWidth = iconBox + 4
        let filterX = (SearchBarRowStyle.iconX + rowStyle.iconSide / 2 - filterWidth / 2).rounded()
        filterButton.frame = NSRect(x: filterX, y: (mid - iconBox / 2).rounded(), width: filterWidth, height: iconBox)

        let side = FontScale.length(SearchBarMetrics.buttonSide, .control)
        var right = w - 12
        for button in [previewButton, sortButton, everythingButton] {
            let width = button.fittingWidth
            right -= width
            button.frame = NSRect(x: right, y: (mid - side / 2).rounded(), width: width, height: side)
            right -= 6
        }
        let spinnerSide: CGFloat = 16
        right -= 4
        spinner.frame = NSRect(x: right - spinnerSide, y: (mid - spinnerSide / 2).rounded(), width: spinnerSide, height: spinnerSide)
        right -= spinnerSide + 6

        if !filterChip.isHidden {
            let chipHeight = FontScale.length(20, .chrome)
            let width = min(filterChip.fittingWidth, 220)
            right -= width
            filterChip.frame = NSRect(x: right, y: (mid - chipHeight / 2).rounded(), width: width, height: chipHeight)
            right -= 6
        }

        // The text sits with its capitals centred on the midline, like the symbols around it. The field draws its text
        // 2 pt in from its frame, with its baseline a point short of one ascender down from the top.
        let font = field.font ?? .systemFont(ofSize: 20)
        let fieldX = rowStyle.textX - 2
        let fieldHeight = ceil(font.ascender - font.descender) + 2
        let fieldY = (mid + font.capHeight / 2 - font.ascender + 1).rounded()
        field.frame = NSRect(x: fieldX, y: fieldY, width: max(right - fieldX - 4, 40), height: fieldHeight)

        hintBar.frame = NSRect(x: 0, y: h - hintHeight, width: w, height: hintHeight)

        let middleY = rowHeight
        let middleHeight = max(h - hintHeight - middleY, 0)
        var listWidth = w
        if showsPreview {
            let previewWidth = min(max(round(w * 0.42), 260), w - 280)
            listWidth = w - previewWidth
            previewContainer.frame = NSRect(x: listWidth, y: middleY + 2, width: previewWidth - inset, height: max(middleHeight - 4, 0))
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
        let iconSize = FontScale.size(14, .control)
        for button in [filterButton, everythingButton, sortButton, previewButton] {
            button.pointSize = iconSize
        }
        filterButton.pointSize = FontScale.size(18, .secondary)
        needsLayout = true
    }

    private var fontScale: Double = 0
}
