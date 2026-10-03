//
//  SearchBarResults.swift
//  Cling
//
//  The results list of the search bar: a plain view-based NSTableView whose rows draw themselves.
//  One layer per visible row, no cell subviews, no Auto Layout and no per-row material, so a
//  fresh result set costs one `reloadData` that touches only the dozen rows on screen.
//

import AppKit
import Lowtech
import System
import UniformTypeIdentifiers

// MARK: - SearchBarTableView

final class SearchBarTableView: NSTableView {
    /// The search field keeps first responder the whole time, Spotlight style: clicks select rows
    /// without pulling the caret out of the field.
    override var acceptsFirstResponder: Bool {
        false
    }

    /// Answers right clicks and ⌘K with the actions menu for the clicked or selected rows.
    var actionsMenuProvider: ((IndexSet) -> NSMenu?)?
    var onDoubleClick: ((Int) -> Void)?
    /// Called on any mouse down in the list, so the bar can move keyboard ownership to the rows.
    var onMouseDown: (() -> Void)?

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            let row = row(at: convert(event.locationInWindow, from: nil))
            if row >= 0 {
                onDoubleClick?(row)
            }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return actionsMenuProvider?(selectedRowIndexes)
    }
}

// MARK: - SearchBarRowStyle

/// Fonts, colours and metrics shared by every row, rebuilt only when the text size changes.
@MainActor
final class SearchBarRowStyle {
    init() {
        rebuild()
    }

    static let shared = SearchBarRowStyle()

    /// Where a row's icon and name start; the search row lines its filter button and query up with them.
    static let iconX: CGFloat = 14

    private(set) var rowHeight: CGFloat = 44
    private(set) var iconSide: CGFloat = 32
    private(set) var nameLineHeight: CGFloat = 16
    private(set) var detailLineHeight: CGFloat = 14
    private(set) var metaWidth: CGFloat = 150
    private(set) var stashTagWidth: CGFloat = 30
    private(set) var scale: Double = 1

    /// Bumped whenever sizes or fonts change, so rows drawn with the old ones know to redraw.
    private(set) var generation = 0

    /// Called once a burst of background renders has landed, so the visible rows redraw once.
    var onRastersReady: (() -> Void)?

    var textX: CGFloat {
        Self.iconX + iconSide + 10
    }

    func rebuildIfNeeded() {
        guard FontScale.current != scale else { return }
        rebuild()
    }

    /// Kind of file by extension alone: a lookup in the type database that never reaches the disk,
    /// cached per extension because a result list is a handful of repeated types.
    func kind(of path: FilePath, isDir: Bool?) -> String {
        let ext = path.extension?.lowercased() ?? ""
        if ext.isEmpty {
            return isDir == true ? folderKind : ""
        }
        let key = isDir == true ? ext + "/" : ext
        if let cached = kinds[key] {
            return cached
        }
        // A bundle like .xcodeproj is only described when looked up as a directory, and a file type only as data.
        let conforming: [UTType] = switch isDir {
        case true: [.directory]
        case false: [.data]
        case nil: [.data, .directory]
        }
        let description = conforming.lazy.compactMap { UTType(filenameExtension: ext, conformingTo: $0)?.localizedDescription }.first
        let kind = description.map(Self.capitalizedFirst) ?? (isDir == true ? folderKind : ext.uppercased())
        kinds[key] = kind
        return kind
    }

    /// The icon pre-rendered at the row's exact pixel size, for a row's icon layer. Workspace
    /// icons are IconServices images that render their representation again on every draw, which
    /// was the single most expensive part of a row; a bitmap of the right size is only composited.
    ///
    /// A file's own icon is never rendered on the main thread: until its bitmap is ready (made on a
    /// background queue) the row shows the icon for its type, which every file with that extension
    /// shares and so is rendered once.
    func iconImage(for path: FilePath, side: CGFloat, scale: CGFloat) -> CGImage? {
        let icon = FilePathBackgroundTasks.shared.icon(for: path)
        if let ready = cachedRaster(icon, side: side, scale: scale) {
            return ready
        }
        requestRaster(icon, side: side, scale: scale)
        let stand = FilePathBackgroundTasks.shared.typeIcon(for: path)
        if let ready = cachedRaster(stand, side: side, scale: scale) {
            return ready
        }
        guard let image = Self.render(stand, side: side, scale: scale) else { return nil }
        rasters.setObject(Raster(image: image, side: side, scale: scale), forKey: stand)
        return image
    }

    private final class Raster {
        init(image: CGImage, side: CGFloat, scale: CGFloat) {
            self.image = image
            self.side = side
            self.scale = scale
        }

        let image: CGImage
        let side: CGFloat
        let scale: CGFloat
    }

    private var pendingRasters: Set<ObjectIdentifier> = []
    private var readyNotificationScheduled = false

    /// Weak keys: a stand-in icon replaced by the real one drops its raster with it.
    private let rasters = NSMapTable<NSImage, Raster>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    private var kinds: [String: String] = [:]
    private let folderKind = UTType.folder.localizedDescription.map(capitalizedFirst) ?? "Folder"

    /// The type database has some kinds in lower case ("application", "folder"); Finder starts each
    /// with a capital.
    private static func capitalizedFirst(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    private nonisolated static func render(_ icon: NSImage, side: CGFloat, scale: CGFloat) -> CGImage? {
        let pixels = Int((side * scale).rounded())
        guard pixels > 0, let space = CGColorSpace(name: CGColorSpace.sRGB), let cg = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        cg.interpolationQuality = .high
        let context = NSGraphicsContext(cgContext: cg, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return cg.makeImage()
    }

    private func cachedRaster(_ icon: NSImage, side: CGFloat, scale: CGFloat) -> CGImage? {
        guard let cached = rasters.object(forKey: icon), cached.side == side, cached.scale == scale else { return nil }
        return cached.image
    }

    private func requestRaster(_ icon: NSImage, side: CGFloat, scale: CGFloat) {
        let id = ObjectIdentifier(icon)
        guard !pendingRasters.contains(id) else { return }
        pendingRasters.insert(id)
        DispatchQueue.global(qos: .userInitiated).async {
            let image = Self.render(icon, side: side, scale: scale)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.pendingRasters.remove(id)
                    guard let image else { return }
                    self.rasters.setObject(Raster(image: image, side: side, scale: scale), forKey: icon)
                    self.scheduleReadyNotification()
                }
            }
        }
    }

    private func scheduleReadyNotification() {
        guard !readyNotificationScheduled else { return }
        readyNotificationScheduled = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.readyNotificationScheduled = false
                self.onRastersReady?()
            }
        }
    }

    private func rebuild() {
        scale = FontScale.current
        rowHeight = FontScale.length(44)
        iconSide = FontScale.length(32)
        // Fits "999 MB · 30 Sep 2026 at 23:59" untruncated.
        metaWidth = FontScale.length(168)

        let nameFont = NSFont.systemFont(ofSize: FontScale.size(13), weight: .medium)
        let detailFont = NSFont.systemFont(ofSize: FontScale.size(11))
        let tagFont = NSFont.systemFont(ofSize: FontScale.size(9.5), weight: .semibold)
        nameLineHeight = ceil(nameFont.ascender - nameFont.descender + nameFont.leading)
        detailLineHeight = ceil(detailFont.ascender - detailFont.descender + detailFont.leading)
        stashTagWidth = ceil(("Stash" as NSString).size(withAttributes: [.font: tagFont]).width)
        SearchBarTextCache.shared.reset()
        generation += 1
    }
}

// MARK: - SearchBarTextCache

/// Typeset, truncated lines kept by text and width, so a row drawn again (the same file after a
/// list update, a fresher icon, a scroll back) only draws glyphs. Colour isn't part of a line: it
/// comes from the context when drawn, so cached lines follow light and dark mode.
@MainActor
final class SearchBarTextCache {
    enum Style: Int {
        case name, detail, meta, tag
        case hintKey, hintTitle, status, flash
    }

    static let shared = SearchBarTextCache()

    /// Draws `text` on one line inside `rect` of a flipped context, truncated in the middle (or at
    /// the end for meta), right-aligned when asked.
    func draw(_ text: String, style: Style, in rect: NSRect, color: NSColor, alignRight: Bool = false) {
        guard !text.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let entry = line(text, style: style, width: rect.width)
        context.saveGState()
        color.setFill()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let x = alignRight ? rect.maxX - entry.width : rect.minX
        context.textPosition = CGPoint(x: x, y: rect.minY + entry.ascent)
        CTLineDraw(entry.line, context)
        context.restoreGState()
    }

    /// Draws `text` untruncated with the top of its line box at `point`, in a flipped context.
    func draw(_ text: String, style: Style, at point: NSPoint, color: NSColor) {
        guard !text.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let entry = line(text, style: style, width: nil)
        context.saveGState()
        color.setFill()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: point.x, y: point.y + entry.ascent)
        CTLineDraw(entry.line, context)
        context.restoreGState()
    }

    /// Width and line height of `text` set on one line, untruncated.
    func size(_ text: String, style: Style) -> NSSize {
        let entry = line(text, style: style, width: nil)
        return NSSize(width: entry.width, height: entry.ascent + entry.descent)
    }

    func reset() {
        lines.removeAll(keepingCapacity: true)
        fonts.removeAll()
    }

    private struct Key: Hashable {
        let text: String
        let style: Int
        let width: Int
    }

    private struct Entry {
        let line: CTLine
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
    }

    private var lines: [Key: Entry] = [:]
    private var fonts: [Int: NSFont] = [:]

    private func font(_ style: Style) -> NSFont {
        if let font = fonts[style.rawValue] {
            return font
        }
        let font: NSFont = switch style {
        case .name: .systemFont(ofSize: FontScale.size(13), weight: .medium)
        case .detail: .systemFont(ofSize: FontScale.size(11))
        case .meta: .monospacedDigitSystemFont(ofSize: FontScale.size(10.5), weight: .regular)
        case .tag: .systemFont(ofSize: FontScale.size(9.5), weight: .semibold)
        case .hintKey: .systemFont(ofSize: FontScale.size(10, .chrome), weight: .semibold)
        case .hintTitle: .systemFont(ofSize: FontScale.size(11, .chrome))
        case .status: .monospacedDigitSystemFont(ofSize: FontScale.size(11, .chrome), weight: .regular)
        case .flash: .systemFont(ofSize: FontScale.size(11, .chrome), weight: .semibold)
        }
        fonts[style.rawValue] = font
        return font
    }

    private func line(_ text: String, style: Style, width: CGFloat?) -> Entry {
        let key = Key(text: text, style: style.rawValue, width: width.map { Int($0) } ?? -1)
        if let cached = lines[key] {
            return cached
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font(style),
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let full = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        var line = full
        if let width, CTLineGetTypographicBounds(full, nil, nil, nil) > width {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attrs))
            line = CTLineCreateTruncatedLine(full, width, style == .meta ? .end : .middle, ellipsis) ?? full
        }
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let lineWidth = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        let entry = Entry(line: line, width: lineWidth, ascent: ascent, descent: descent)
        if lines.count > 1500 {
            lines.removeAll(keepingCapacity: true)
        }
        lines[key] = entry
        return entry
    }
}

// MARK: - SearchBarRowView

/// A result row as three layers: a selection highlight that is only shown or hidden, an icon whose
/// bitmap is swapped in without drawing, and text that redraws only when the row's file, its size
/// and date, or the text size change. Moving the selection or an icon arriving draws nothing.
final class SearchBarRowView: NSTableRowView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(selectionView)
        addSubview(iconView)
        addSubview(content)
        selectionView.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override var isOpaque: Bool {
        false
    }
    override var allowsVibrancy: Bool {
        false
    }
    override var wantsUpdateLayer: Bool {
        true
    }

    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            selectionView.isHidden = !isSelected
        }
    }

    let content = SearchBarRowContent()
    let iconView = SearchBarIconView()
    let selectionView = SearchBarSelectionView()

    var path: FilePath? {
        get { content.path }
        set {
            content.path = newValue
            refreshIcon()
        }
    }

    var isStashed: Bool {
        get { content.isStashed }
        set { content.isStashed = newValue }
    }

    /// Stronger while the keyboard is in the list, lighter while it's typing in the field.
    var strongSelection: Bool {
        get { selectionView.strong }
        set { selectionView.strong = newValue }
    }

    override func updateLayer() {}
    override func drawBackground(in _: NSRect) {}
    override func drawSelection(in _: NSRect) {}
    override func drawSeparator(in _: NSRect) {}

    override func layout() {
        super.layout()
        let side = SearchBarRowStyle.shared.iconSide
        selectionView.frame = bounds.insetBy(dx: 6, dy: 1)
        iconView.frame = NSRect(x: SearchBarRowStyle.iconX, y: ((bounds.height - side) / 2).rounded(), width: side, height: side)
        content.frame = bounds
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        iconView.layer?.contentsScale = backingScale
        refreshIcon()
    }

    override func accessibilityLabel() -> String? {
        guard let path else { return nil }
        return "\(path.name.string), \(path.dir.shellString)"
    }

    func refreshIcon() {
        guard let path = content.path else {
            iconView.image = nil
            return
        }
        let style = SearchBarRowStyle.shared
        iconView.image = style.iconImage(for: path, side: style.iconSide, scale: backingScale)
    }

    /// Same file, possibly fresher icon, size or date.
    func refresh() {
        refreshIcon()
        content.refreshIfStale()
    }

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }
}

// MARK: - SearchBarIconView

/// Shows a ready bitmap as its layer's contents: changing it composites, nothing is drawn.
final class SearchBarIconView: NSView {
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

    var image: CGImage? {
        didSet {
            guard image !== oldValue else { return }
            needsDisplay = true
        }
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func updateLayer() {
        layer?.contents = image
        layer?.contentsGravity = .resizeAspect
    }
}

// MARK: - SearchBarSelectionView

final class SearchBarSelectionView: NSView {
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

    var strong = true {
        didSet {
            guard strong != oldValue else { return }
            needsDisplay = true
        }
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(strong ? 0.32 : 0.2).cgColor
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
    }
}

// MARK: - SearchBarRowContent

/// Name, folder, kind, size and date, drawn in one pass.
final class SearchBarRowContent: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // On an XDR display the default backing is 16 bits per channel; text doesn't need it and
        // drawing into half the bytes is twice as cheap.
        layer?.contentsFormat = .RGBA8Uint
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override var isFlipped: Bool {
        true
    }
    override var isOpaque: Bool {
        false
    }
    override var allowsVibrancy: Bool {
        false
    }

    var path: FilePath? {
        didSet {
            guard path != oldValue else { return }
            needsDisplay = true
        }
    }

    var isStashed = false {
        didSet {
            guard isStashed != oldValue else { return }
            needsDisplay = true
        }
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    /// The layer only redraws on request, so a new width (the bar resized) has to ask for it.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed {
            needsDisplay = true
        }
    }

    override func draw(_: NSRect) {
        guard let path else { return }
        #if DEBUG || SEARCHBAR_BENCH
            SearchBarBenchmark.count("rowDraw")
        #endif
        let style = SearchBarRowStyle.shared
        let text = SearchBarTextCache.shared
        let bounds = bounds
        drawnGeneration = style.generation

        let textX = style.textX
        let showMeta = bounds.width > 420
        let metaWidth = showMeta ? style.metaWidth : 0
        let textWidth = max(bounds.width - textX - metaWidth - 20, 40)
        let gap: CGFloat = 1
        let block = style.nameLineHeight + gap + style.detailLineHeight
        let top = (bounds.height - block) / 2

        text.draw(path.name.string, style: .name, in: NSRect(x: textX, y: top, width: textWidth, height: style.nameLineHeight), color: .labelColor)
        text.draw(
            path.dir.shellString, style: .detail,
            in: NSRect(x: textX, y: top + style.nameLineHeight + gap, width: textWidth, height: style.detailLineHeight),
            color: .secondaryLabelColor
        )

        guard showMeta else {
            drawnMeta = nil
            return
        }
        let metaX = bounds.width - metaWidth - 16
        let kind = style.kind(of: path, isDir: FilePathBackgroundTasks.shared.knownIsDir(path))
        if isStashed {
            let tagWidth = style.stashTagWidth
            text.draw("Stash", style: .tag, in: NSRect(x: metaX, y: top + 2, width: metaWidth, height: style.nameLineHeight), color: .systemOrange)
            text.draw(
                kind, style: .meta,
                in: NSRect(x: metaX + tagWidth + 6, y: top + 1, width: max(metaWidth - tagWidth - 6, 10), height: style.nameLineHeight),
                color: .secondaryLabelColor, alignRight: true
            )
        } else {
            text.draw(kind, style: .meta, in: NSRect(x: metaX, y: top + 1, width: metaWidth, height: style.nameLineHeight), color: .secondaryLabelColor, alignRight: true)
        }
        let meta = metaLine(path)
        drawnMeta = meta
        text.draw(
            meta, style: .meta,
            in: NSRect(x: metaX, y: top + style.nameLineHeight + gap, width: metaWidth, height: style.detailLineHeight),
            color: .secondaryLabelColor, alignRight: true
        )
    }

    /// Redraws only when the size and date line or the row style changed since the last draw.
    func refreshIfStale() {
        guard let path else { return }
        if SearchBarRowStyle.shared.generation != drawnGeneration || (drawnMeta != nil && metaLine(path) != drawnMeta) {
            needsDisplay = true
        }
    }

    private var drawnMeta: String?
    private var drawnGeneration = -1

    private func metaLine(_ path: FilePath) -> String {
        let isDir = FilePathBackgroundTasks.shared.knownIsDir(path) == true
        // The window pads sizes for its aligned column ("38  B"); a run of text doesn't need it.
        let size = isDir ? "" : path.memoz.humanizedFileSize.replacingOccurrences(of: "  ", with: " ")
        let date = path.memoz.formattedModificationDate
        return size.isEmpty || size == "—" ? date : "\(size) · \(date)"
    }
}

// MARK: - SearchBarResultsController

/// Owns the list's data and its table. Holds the displayed paths as a plain array: the bar's
/// controller pushes a new one only when the results actually changed.
@MainActor
final class SearchBarResultsController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    override init() {
        tableView = SearchBarTableView()
        scrollView = NSScrollView()
        super.init()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.usesAutomaticRowHeights = false
        tableView.rowHeight = SearchBarRowStyle.shared.rowHeight
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        // Rows draw their own highlight; the regular style would also build AppKit's selection
        // background view in every selected row.
        tableView.selectionHighlightStyle = .none
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.focusRingType = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.setAccessibilityLabel("Results")

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        scrollView.borderType = .noBorder

        // The highlight is the accent colour baked into a layer, which doesn't follow a change in
        // System Settings on its own.
        NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for view in self.freeRows.values {
                    view.selectionView.needsDisplay = true
                }
                self.forEachVisibleRow { _, view in
                    view.selectionView.needsDisplay = true
                }
            }
        }

        SearchBarRowStyle.shared.onRastersReady = { [weak self] in
            self?.refreshVisibleRows()
        }
    }

    let tableView: SearchBarTableView
    let scrollView: NSScrollView

    private(set) var items: [FilePath] = []
    var stashed: Set<FilePath> = []
    var onSelectionChange: (() -> Void)?

    var strongSelection = false {
        didSet {
            guard strongSelection != oldValue else { return }
            forEachVisibleRow { $1.strongSelection = strongSelection }
        }
    }

    var selectedPaths: [FilePath] {
        tableView.selectedRowIndexes.compactMap { items[safe: $0] }
    }

    var visibleRowCount: Int {
        max(Int(scrollView.contentView.bounds.height / max(tableView.rowHeight, 1)) - 1, 1)
    }

    /// Replaces the list. With `select` nil the selection follows the same paths when they are
    /// still there, otherwise it lands on the given row (or nothing for -1).
    func setItems(_ newItems: [FilePath], select row: Int?, scrollToTop: Bool) {
        let previouslySelected = Set(selectedPaths)
        let oldItems = items
        items = newItems
        suppressSelectionCallback = true
        if SearchBarRowStyle.shared.rowHeight != tableView.rowHeight {
            tableView.rowHeight = SearchBarRowStyle.shared.rowHeight
            tableView.reloadData()
        } else if !applyInsertionsAndRemovals(from: oldItems, to: newItems) {
            let shown = scrollToTop ? 0 : max(tableView.rows(in: tableView.visibleRect).location, 0)
            reservedPaths = Set(newItems[min(shown, newItems.count) ..< min(shown + visibleRowCount + 4, newItems.count)])
            tableView.reloadData()
        }

        var selection = IndexSet()
        if let row {
            if row >= 0, row < items.count {
                selection.insert(row)
            }
        } else if !previouslySelected.isEmpty {
            for (i, path) in items.enumerated() where previouslySelected.contains(path) {
                selection.insert(i)
            }
        }
        tableView.selectRowIndexes(selection, byExtendingSelection: false)
        suppressSelectionCallback = false
        if scrollToTop {
            tableView.scroll(NSPoint(x: 0, y: -scrollView.contentInsets.top))
        } else if let first = selection.first {
            tableView.scrollRowToVisible(first)
        }
        onSelectionChange?()
    }

    /// Same paths, fresher icons, sizes or dates: redraw the rows on screen whose look changed.
    func refreshVisibleRows() {
        forEachVisibleRow { row, view in
            view.isStashed = stashed.contains(items[row])
            view.refresh()
        }
    }

    func select(row: Int, extend: Bool = false) {
        guard !items.isEmpty else { return }
        let row = min(max(row, 0), items.count - 1)
        if extend {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: true)
        } else {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        tableView.scrollRowToVisible(row)
    }

    func moveSelection(by delta: Int, extend: Bool = false) {
        guard !items.isEmpty else { return }
        let current = delta > 0 ? (tableView.selectedRowIndexes.last ?? -1) : (tableView.selectedRowIndexes.first ?? items.count)
        select(row: current + delta, extend: extend)
    }

    // MARK: Data source and delegate

    func numberOfRows(in _: NSTableView) -> Int {
        items.count
    }

    /// Row views go back to a pool keyed by the file they show. A list that comes back reordered
    /// (live index changes, a refined search keeping most results) gets each file's already drawn
    /// row back, so only rows for files new to the screen draw anything.
    func tableView(_: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let path = items[row]
        let view: SearchBarRowView
        if let pooled = freeRows.removeValue(forKey: path) {
            #if DEBUG || SEARCHBAR_BENCH
                SearchBarBenchmark.count("rowReused")
            #endif
            freeOrder.removeAll { $0 == path }
            view = pooled
            view.refresh()
        } else if let index = freeOrder.firstIndex(where: { !reservedPaths.contains($0) }) {
            view = freeRows.removeValue(forKey: freeOrder.remove(at: index))!
        } else {
            view = SearchBarRowView()
        }
        view.path = path
        view.isStashed = stashed.contains(path)
        view.strongSelection = strongSelection
        return view
    }

    /// Called for every row leaving the table, whether scrolled away or dropped by a reload.
    func tableView(_: NSTableView, didRemove rowView: NSTableRowView, forRow _: Int) {
        guard let view = rowView as? SearchBarRowView, let path = view.path else { return }
        if freeRows.updateValue(view, forKey: path) == nil {
            freeOrder.append(path)
        }
        if freeOrder.count > Self.maxPooledRows {
            freeRows.removeValue(forKey: freeOrder.removeFirst())
        }
    }

    func tableView(_: NSTableView, viewFor _: NSTableColumn?, row _: Int) -> NSView? {
        nil
    }

    func tableView(_: NSTableView, heightOfRow _: Int) -> CGFloat {
        SearchBarRowStyle.shared.rowHeight
    }

    func tableViewSelectionDidChange(_: Notification) {
        guard !suppressSelectionCallback else { return }
        onSelectionChange?()
    }

    func tableView(_: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        items[safe: row]?.url as NSURL?
    }

    private static let maxPooledRows = 64

    private var suppressSelectionCallback = false
    private var freeRows: [FilePath: SearchBarRowView] = [:]
    private var freeOrder: [FilePath] = []
    /// Files about to be shown, whose pooled rows shouldn't be handed to another file.
    private var reservedPaths: Set<FilePath> = []

    /// A list that only gained or lost a few files, the rest in the same order (a file created or
    /// deleted while the bar is open), is applied as row inserts and removals: rows already on
    /// screen keep their drawing and only slide. A reload would remove and redraw every row.
    private func applyInsertionsAndRemovals(from old: [FilePath], to new: [FilePath]) -> Bool {
        let limit = 32
        guard !old.isEmpty, !new.isEmpty, old != new else { return old == new }
        guard abs(old.count - new.count) <= limit, max(old.count, new.count) <= 5000 else { return false }

        let newSet = Set(new)
        var removed = IndexSet()
        for (i, path) in old.enumerated() where !newSet.contains(path) {
            removed.insert(i)
            if removed.count > limit {
                return false
            }
        }
        let oldSet = Set(old)
        var inserted = IndexSet()
        for (i, path) in new.enumerated() where !oldSet.contains(path) {
            inserted.insert(i)
            if inserted.count > limit {
                return false
            }
        }
        // Everything else has to keep its relative order, otherwise rows moved and a reload is simpler.
        let keptOld = old.indices.lazy.filter { !removed.contains($0) }.map { old[$0] }
        let keptNew = new.indices.lazy.filter { !inserted.contains($0) }.map { new[$0] }
        guard keptOld.elementsEqual(keptNew) else { return false }

        tableView.beginUpdates()
        tableView.removeRows(at: removed, withAnimation: [])
        tableView.insertRows(at: inserted, withAnimation: [])
        tableView.endUpdates()
        return true
    }

    private func forEachVisibleRow(_ body: (Int, SearchBarRowView) -> Void) {
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.length > 0 else { return }
        for row in range.location ..< range.location + range.length {
            if let view = tableView.rowView(atRow: row, makeIfNecessary: false) as? SearchBarRowView {
                body(row, view)
            }
        }
    }
}
