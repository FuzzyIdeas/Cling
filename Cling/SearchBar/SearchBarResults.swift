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
    private(set) var nameAttrs: [NSAttributedString.Key: Any] = [:]
    private(set) var nameSelectedAttrs: [NSAttributedString.Key: Any] = [:]
    private(set) var detailAttrs: [NSAttributedString.Key: Any] = [:]
    private(set) var detailSelectedAttrs: [NSAttributedString.Key: Any] = [:]
    private(set) var metaAttrs: [NSAttributedString.Key: Any] = [:]
    private(set) var metaSelectedAttrs: [NSAttributedString.Key: Any] = [:]
    private(set) var tagAttrs: [NSAttributedString.Key: Any] = [:]
    private(set) var nameLineHeight: CGFloat = 16
    private(set) var detailLineHeight: CGFloat = 14
    private(set) var metaWidth: CGFloat = 150
    private(set) var scale: Double = 1

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

    private var kinds: [String: String] = [:]
    private let folderKind = UTType.folder.localizedDescription ?? "Folder"

    private func rebuild() {
        scale = FontScale.current
        rowHeight = FontScale.length(44)
        iconSide = FontScale.length(32)
        metaWidth = FontScale.length(150)

        let nameFont = NSFont.systemFont(ofSize: FontScale.size(13), weight: .medium)
        let detailFont = NSFont.systemFont(ofSize: FontScale.size(11))
        let metaFont = NSFont.monospacedDigitSystemFont(ofSize: FontScale.size(10.5), weight: .regular)
        let tagFont = NSFont.systemFont(ofSize: FontScale.size(9.5), weight: .semibold)

        func para(_ mode: NSLineBreakMode, _ alignment: NSTextAlignment = .left) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = mode
            style.alignment = alignment
            return style
        }

        nameAttrs = [.font: nameFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: para(.byTruncatingMiddle)]
        nameSelectedAttrs = [.font: nameFont, .foregroundColor: NSColor.white, .paragraphStyle: para(.byTruncatingMiddle)]
        detailAttrs = [.font: detailFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para(.byTruncatingMiddle)]
        detailSelectedAttrs = [.font: detailFont, .foregroundColor: NSColor.white.withAlphaComponent(0.8), .paragraphStyle: para(.byTruncatingMiddle)]
        metaAttrs = [.font: metaFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para(.byTruncatingTail, .right)]
        metaSelectedAttrs = [.font: metaFont, .foregroundColor: NSColor.white.withAlphaComponent(0.8), .paragraphStyle: para(.byTruncatingTail, .right)]
        tagAttrs = [.font: tagFont, .foregroundColor: NSColor.systemOrange]

        nameLineHeight = ceil(nameFont.ascender - nameFont.descender + nameFont.leading)
        detailLineHeight = ceil(detailFont.ascender - detailFont.descender + detailFont.leading)
    }
}

// MARK: - SearchBarRowView

/// Draws a whole result row (selection, icon, name, folder, kind, size and date) in one `draw`.
final class SearchBarRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("SearchBarRow")

    override var isOpaque: Bool {
        false
    }
    override var allowsVibrancy: Bool {
        false
    }
    override var wantsDefaultClipping: Bool {
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

    /// Strong accent while the keyboard is in the list, a lighter one while it's typing in the field.
    var strongSelection = true {
        didSet {
            guard strongSelection != oldValue, isSelected else { return }
            needsDisplay = true
        }
    }

    override func drawBackground(in _: NSRect) {}
    override func drawSelection(in _: NSRect) {}
    override func drawSeparator(in _: NSRect) {}

    override func draw(_: NSRect) {
        guard let path else { return }
        #if DEBUG || SEARCHBAR_BENCH
            SearchBarBenchmark.count("rowDraw")
        #endif
        let style = SearchBarRowStyle.shared
        let selected = isSelected
        let bounds = bounds

        if selected {
            let rect = bounds.insetBy(dx: 6, dy: 1)
            let color = strongSelection ? NSColor.controlAccentColor : NSColor.controlAccentColor.withAlphaComponent(0.55)
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        }

        let iconSide = style.iconSide
        let iconRect = NSRect(x: 14, y: (bounds.height - iconSide) / 2, width: iconSide, height: iconSide)
        FilePathBackgroundTasks.shared.icon(for: path)
            .draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)

        let textX = iconRect.maxX + 10
        let showMeta = bounds.width > 420
        let metaWidth = showMeta ? style.metaWidth : 0
        let textWidth = max(bounds.width - textX - metaWidth - 20, 40)
        let gap: CGFloat = 1
        let block = style.nameLineHeight + gap + style.detailLineHeight
        let top = (bounds.height - block) / 2

        let name = path.name.string
        (name as NSString).draw(
            in: NSRect(x: textX, y: top, width: textWidth, height: style.nameLineHeight),
            withAttributes: selected ? style.nameSelectedAttrs : style.nameAttrs
        )
        (path.dir.shellString as NSString).draw(
            in: NSRect(x: textX, y: top + style.nameLineHeight + gap, width: textWidth, height: style.detailLineHeight),
            withAttributes: selected ? style.detailSelectedAttrs : style.detailAttrs
        )

        guard showMeta else { return }
        let metaX = bounds.width - metaWidth - 16
        let metaAttrs = selected ? style.metaSelectedAttrs : style.metaAttrs
        let isDir = FilePathBackgroundTasks.shared.knownIsDir(path)
        let kind = style.kind(of: path, isDir: isDir)
        let topLine: NSString = if isStashed {
            kind.isEmpty ? "Stash" : "Stash · \(kind)" as NSString
        } else {
            kind as NSString
        }
        topLine.draw(in: NSRect(x: metaX, y: top + 1, width: metaWidth, height: style.nameLineHeight), withAttributes: metaAttrs)

        let size = isDir == true ? "" : path.memoz.humanizedFileSize
        let date = path.memoz.formattedModificationDate
        let bottomLine = (size.isEmpty || size == "—" ? date : "\(size)  ·  \(date)") as NSString
        bottomLine.draw(
            in: NSRect(x: metaX, y: top + style.nameLineHeight + gap, width: metaWidth, height: style.detailLineHeight),
            withAttributes: metaAttrs
        )
    }

    override func accessibilityLabel() -> String? {
        guard let path else { return nil }
        return "\(path.name.string), \(path.dir.shellString)"
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

    /// Same paths, fresher icons, sizes or dates: redraw what's on screen and nothing else.
    func refreshVisibleRows() {
        forEachVisibleRow { row, view in
            view.isStashed = stashed.contains(items[row])
            view.needsDisplay = true
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
