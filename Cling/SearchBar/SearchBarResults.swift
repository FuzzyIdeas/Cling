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

    private(set) var rowHeight: CGFloat = 44
    private(set) var iconSide: CGFloat = 32
    private(set) var nameLineHeight: CGFloat = 16
    private(set) var detailLineHeight: CGFloat = 14
    private(set) var metaWidth: CGFloat = 150
    private(set) var stashTagWidth: CGFloat = 30
    private(set) var scale: Double = 1

    /// Called once a burst of background renders has landed, so the visible rows redraw once.
    var onRastersReady: (() -> Void)?

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
        if let cached = kinds[ext] {
            return cached
        }
        let kind = UTType(filenameExtension: ext)?.localizedDescription ?? ext.uppercased()
        kinds[ext] = kind
        return kind
    }

    /// The icon pre-rendered at the row's exact pixel size. Workspace icons are IconServices
    /// images that render their representation again on every draw, which was the single most
    /// expensive part of a row; a plain bitmap of the right size draws as a blit.
    ///
    /// A row never renders a file's own icon on the main thread: until its bitmap is ready (made on
    /// a background queue) the row shows the icon for its type, which is shared by every file with
    /// that extension and so rendered once.
    func iconImage(for path: FilePath, side: CGFloat, scale: CGFloat) -> NSImage {
        let icon = FilePathBackgroundTasks.shared.icon(for: path)
        if let ready = cachedRaster(icon, side: side, scale: scale) {
            return ready
        }
        requestRaster(icon, side: side, scale: scale)
        let stand = FilePathBackgroundTasks.shared.typeIcon(for: path)
        if let ready = cachedRaster(stand, side: side, scale: scale) {
            return ready
        }
        let image = Self.render(stand, side: side, scale: scale) ?? stand
        rasters.setObject(Raster(image: image, side: side, scale: scale), forKey: stand)
        return image
    }

    private final class Raster {
        init(image: NSImage, side: CGFloat, scale: CGFloat) {
            self.image = image
            self.side = side
            self.scale = scale
        }

        let image: NSImage
        let side: CGFloat
        let scale: CGFloat
    }

    private var pendingRasters: Set<ObjectIdentifier> = []
    private var readyNotificationScheduled = false

    /// Weak keys: a stand-in icon replaced by the real one drops its raster with it.
    private let rasters = NSMapTable<NSImage, Raster>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    private var kinds: [String: String] = [:]
    private let folderKind = UTType.folder.localizedDescription ?? "Folder"

    private nonisolated static func render(_ icon: NSImage, side: CGFloat, scale: CGFloat) -> NSImage? {
        let pixels = Int((side * scale).rounded())
        guard pixels > 0, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    private func cachedRaster(_ icon: NSImage, side: CGFloat, scale: CGFloat) -> NSImage? {
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
        metaWidth = FontScale.length(150)

        let nameFont = NSFont.systemFont(ofSize: FontScale.size(13), weight: .medium)
        let detailFont = NSFont.systemFont(ofSize: FontScale.size(11))
        let tagFont = NSFont.systemFont(ofSize: FontScale.size(9.5), weight: .semibold)
        nameLineHeight = ceil(nameFont.ascender - nameFont.descender + nameFont.leading)
        detailLineHeight = ceil(detailFont.ascender - detailFont.descender + detailFont.leading)
        stashTagWidth = ceil(("Stash" as NSString).size(withAttributes: [.font: tagFont]).width)
        SearchBarTextCache.shared.reset()
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
        }
        fonts[style.rawValue] = font
        return font
    }

    private func line(_ text: String, style: Style, width: CGFloat) -> Entry {
        let key = Key(text: text, style: style.rawValue, width: Int(width))
        if let cached = lines[key] {
            return cached
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font(style),
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let full = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        var line = full
        if CTLineGetTypographicBounds(full, nil, nil, nil) > width {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attrs))
            line = CTLineCreateTruncatedLine(full, width, style == .meta ? .end : .middle, ellipsis) ?? full
        }
        var ascent: CGFloat = 0
        let lineWidth = CTLineGetTypographicBounds(line, &ascent, nil, nil)
        let entry = Entry(line: line, width: lineWidth, ascent: ascent)
        if lines.count > 1500 {
            lines.removeAll(keepingCapacity: true)
        }
        lines[key] = entry
        return entry
    }
}

// MARK: - SearchBarRowView

/// A result row: a selection highlight that is only shown or hidden, under content that redraws
/// only when the row's file or what's known about it changes. Moving the selection draws nothing.
final class SearchBarRowView: NSTableRowView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(selectionView)
        addSubview(content)
        selectionView.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    static let identifier = NSUserInterfaceItemIdentifier("SearchBarRow")

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
    let selectionView = SearchBarSelectionView()

    var path: FilePath? {
        get { content.path }
        set { content.path = newValue }
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
        selectionView.frame = bounds.insetBy(dx: 6, dy: 1)
        content.frame = bounds
    }

    override func accessibilityLabel() -> String? {
        guard let path else { return nil }
        return "\(path.name.string), \(path.dir.shellString)"
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

/// Icon, name, folder, kind, size and date, drawn in one pass.
final class SearchBarRowContent: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // On an XDR display the default backing is 16 bits per channel; text and icons don't need
        // it and drawing into half the bytes is twice as cheap.
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

    override func draw(_: NSRect) {
        guard let path else { return }
        #if DEBUG || SEARCHBAR_BENCH
            SearchBarBenchmark.count("rowDraw")
        #endif
        let style = SearchBarRowStyle.shared
        let text = SearchBarTextCache.shared
        let bounds = bounds

        let iconSide = style.iconSide
        let iconRect = NSRect(x: 14, y: (bounds.height - iconSide) / 2, width: iconSide, height: iconSide)
        let icon = style.iconImage(for: path, side: iconSide, scale: window?.backingScaleFactor ?? 2)
        icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        drawnIcon = ObjectIdentifier(icon)

        let textX = iconRect.maxX + 10
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
            let tag = "Stash"
            text.draw(tag, style: .tag, in: NSRect(x: metaX, y: top + 2, width: metaWidth, height: style.nameLineHeight), color: .systemOrange)
            let tagWidth = style.stashTagWidth
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

    /// Redraws only when the icon or the size and date line changed since the last draw.
    func refreshIfStale() {
        guard let path else { return }
        let style = SearchBarRowStyle.shared
        let icon = style.iconImage(for: path, side: style.iconSide, scale: window?.backingScaleFactor ?? 2)
        if ObjectIdentifier(icon) != drawnIcon || metaLine(path) != drawnMeta {
            needsDisplay = true
        }
    }

    private var drawnIcon: ObjectIdentifier?
    private var drawnMeta: String?

    private func metaLine(_ path: FilePath) -> String {
        let isDir = FilePathBackgroundTasks.shared.knownIsDir(path) == true
        let size = isDir ? "" : path.memoz.humanizedFileSize
        let date = path.memoz.formattedModificationDate
        return size.isEmpty || size == "—" ? date : "\(size)  ·  \(date)"
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
        tableView.selectionHighlightStyle = .regular
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
        items = newItems
        if SearchBarRowStyle.shared.rowHeight != tableView.rowHeight {
            tableView.rowHeight = SearchBarRowStyle.shared.rowHeight
        }
        suppressSelectionCallback = true
        tableView.reloadData()

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
            view.content.refreshIfStale()
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

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = (tableView.makeView(withIdentifier: SearchBarRowView.identifier, owner: nil) as? SearchBarRowView) ?? {
            let view = SearchBarRowView()
            view.identifier = SearchBarRowView.identifier
            view.wantsLayer = true
            view.layerContentsRedrawPolicy = .onSetNeedsDisplay
            return view
        }()
        let path = items[row]
        view.path = path
        view.isStashed = stashed.contains(path)
        view.strongSelection = strongSelection
        return view
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

    private var suppressSelectionCallback = false

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
