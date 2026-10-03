//
//  SearchBarController.swift
//  Cling
//
//  A Spotlight-like floating search bar over the same search state as the main window: it reads
//  FUZZY's query, results and filters and runs the same actions, it only draws them differently.
//
//  What keeps it cheap:
//  - It observes FUZZY only while expanded, through one `withObservationTracking` read that is
//    re-armed after each change and dropped on collapse. Collapsed, nothing in it runs when the
//    index changes.
//  - The compact pinned field observes nothing at all.
//  - Rows are drawn by an NSTableView with a fixed height, so a new result set reloads only the rows
//    on screen, and a list that didn't change only redraws them.
//  - The window style's material sits under the whole window once; nothing per row.
//

import AppKit
import Combine
import Defaults
import KeyboardShortcuts
import Lowtech
import OSLog
import QuickLookUI
import SwiftUI
import System

private let log = Logger(subsystem: clingSubsystem, category: "SearchBar")

@MainActor let SB = SearchBarController.shared

// MARK: - SearchBarPanel

final class SearchBarPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }
    override var canBecomeMain: Bool {
        false
    }

    weak var controller: SearchBarController?

    /// No double-click-to-zoom on the transparent titlebar strip above the field.
    override func zoom(_: Any?) {}

    override func cancelOperation(_: Any?) {
        controller?.escape()
    }

    override func acceptsPreviewPanelControl(_: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        controller?.beginQuickLook(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        controller?.endQuickLook(panel)
    }
}

// MARK: - SearchBarController

@MainActor
final class SearchBarController: NSObject, NSWindowDelegate, NSTextFieldDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    enum State { case hidden, compact, expanded }

    /// Everything the bar shows that comes from the shared search state.
    struct Inputs: Equatable {
        var list: [FilePath]
        var defaultList: Bool
        var searching: Bool
        var stash: [FilePath]
        var query: String
        var filterText: String
        var scopeIcon: String?
        var scopeHue: Double?
        var everything: Bool
    }

    /// Shortcut labels and the paste target for the hint bar, read once per summon: both come from
    /// settings and the app in front, neither of which changes while the bar has the keyboard.
    struct HintKeys {
        var showInFinder = "⌘⏎"
        var quickLook = "⌘Y"
        var copy = "⌘C"
        var pasteTarget: String?
    }

    static let shared = SearchBarController()

    static let minSize = NSSize(width: 560, height: 320)
    static let defaultSize = NSSize(width: 860, height: 500)

    private(set) var state = State.hidden

    /// The show/hide hotkey, the Dock icon and the menu bar icon bring up the bar instead of the window.
    private(set) var ownsHotkey = false

    // MARK: Internals shared with the actions extension

    let results = SearchBarResultsController()
    var root: SearchBarRootView?
    var panel: SearchBarPanel?
    var activatedApp = false
    var quickLookItems: [URL] = []
    var quickLookIndex = 0
    var listFocused = false
    var minQueryLength = 3

    var isExpanded: Bool {
        state == .expanded
    }

    var panelWindow: NSWindow? {
        panel
    }

    var selection: [FilePath] {
        results.selectedPaths
    }

    var lastAppliedInputs: Inputs? {
        lastInputs
    }

    var quickLookVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    #if DEBUG || SEARCHBAR_BENCH
        var benchmarkPillWindow: NSWindow? {
            pillPanel
        }
    #endif

    // MARK: Setup

    func setup() {
        ownsHotkey = Defaults[.hotkeyTarget] == .searchBar
        minQueryLength = Defaults[.minQueryLength]
        pinned = Defaults[.searchBarPinned]

        KeyboardShortcuts.onKeyDown(for: .clSearchBar) { [weak self] in
            self?.toggle()
        }

        pub(.hotkeyTarget).sink { [weak self] change in
            mainAsync { self?.ownsHotkey = change.newValue == .searchBar }
        }.store(in: &observers)
        pub(.minQueryLength).sink { [weak self] change in
            mainAsync { self?.minQueryLength = change.newValue }
        }.store(in: &observers)
        pub(.searchBarPinned).sink { [weak self] change in
            mainAsync { self?.pinnedChanged(change.newValue) }
        }.store(in: &observers)
        pub(.searchBarAboveWindows).sink { [weak self] _ in
            mainAsync { self?.applyPillLevel() }
        }.store(in: &observers)
        pub(.windowAppearance).sink { [weak self] _ in
            mainAsync { self?.restyle() }
        }.store(in: &observers)
        pub(.fontScale).sink { [weak self] _ in
            mainAsync { self?.fontScaleChanged() }
        }.store(in: &observers)
        pub(.searchBarShowPreview).sink { [weak self] _ in
            mainAsync { self?.updatePreviewVisibility() }
        }.store(in: &observers)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                mainAsync { self?.screensChanged() }
            }.store(in: &observers)

        if pinned {
            state = .compact
            showPill()
        }
        #if DEBUG || SEARCHBAR_BENCH
            SearchBarBenchmark.startIfRequested()
        #endif
    }

    // MARK: Summon and dismiss

    /// The hotkey: brings the bar up, or puts it away when it is already the window in front.
    func toggle() {
        if isExpanded, panel?.isKeyWindow == true {
            collapse()
            return
        }
        // A menu bar click first takes key focus away, which already collapsed the bar: that
        // click meant "put it away", not "bring it back".
        if let at = lastFocusLossCollapse, Date().timeIntervalSince(at) < 0.35 {
            lastFocusLossCollapse = nil
            return
        }
        expand()
    }

    func expand() {
        let panel = ensurePanel()
        guard let root else { return }
        suspendHiddenMainWindow()

        root.background.rebuild()
        root.applyFonts()
        SearchBarRowStyle.shared.rebuildIfNeeded()
        if results.tableView.rowHeight != SearchBarRowStyle.shared.rowHeight {
            results.tableView.rowHeight = SearchBarRowStyle.shared.rowHeight
        }

        let wasExpanded = isExpanded
        if !wasExpanded {
            placingPanel = true
            panel.setFrame(frameForExpanded(), display: false)
            placingPanel = false
        }

        state = .expanded
        WM.searchBarActive = true
        EVERYTHING.windowShown()
        FUZZY.refreshDefaultResultsIfNeeded()
        if root.field.stringValue != FUZZY.query {
            root.field.stringValue = FUZZY.query
        }
        if !FUZZY.emptyQuery || FUZZY.volumeFilter != nil {
            // Runs only when the index changed since the last search, otherwise returns at once.
            FUZZY.performSearch()
        }

        if !wasExpanded {
            refreshHintKeys()
            observationGeneration += 1
            observe()
            updatePreviewVisibility()
            installKeyMonitor()
        }

        // First responder before ordering in, so showing the panel doesn't pick a key view first
        // only for it to be replaced.
        if root.field.currentEditor() == nil {
            panel.makeFirstResponder(root.field)
        }
        panel.makeKeyAndOrderFront(nil)
        root.field.currentEditor()?.selectAll(nil)
        pillPanel?.orderOut(nil)
        signpost("expand")
    }

    func collapse(focusLost: Bool = false) {
        guard isExpanded else { return }
        observationGeneration += 1
        removeKeyMonitor()
        searchWork?.cancel()
        previewWork?.cancel()
        historyIndex = -1
        closeQuickLook()
        clearPreview()

        state = pinned ? .compact : .hidden
        WM.searchBarActive = false
        FUZZY.cancelPendingSearch()
        EVERYTHING.windowHidden()
        panel?.orderOut(nil)
        if focusLost {
            lastFocusLossCollapse = Date()
        }
        if pinned {
            showPill()
        }
        if activatedApp {
            activatedApp = false
            if !focusLost {
                APP_MANAGER.lastFrontmostApp?.activate()
            }
        }
    }

    /// Esc: closes QuickLook, then clears the query, then puts the bar away.
    func escape() {
        if quickLookVisible {
            closeQuickLook()
            return
        }
        guard let root else { return }
        if !root.field.stringValue.isEmpty {
            root.field.stringValue = ""
            queryEdited("")
            return
        }
        collapse()
    }

    // MARK: Window delegate

    func windowDidResignKey(_: Notification) {
        guard isExpanded else { return }
        // Let the new key window settle: QuickLook, a sheet or an alert of our own keep the bar up.
        mainAsyncAfter(ms: 80) { [weak self] in
            self?.checkFocusLoss()
        }
    }

    func windowDidMove(_: Notification) {
        guard isExpanded, !placingPanel, !pinned, let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        guard area.width > 0, area.height > 0 else { return }
        let cx = (panel.frame.midX - area.minX) / area.width
        let top = (area.maxY - panel.frame.maxY) / area.height
        Defaults[.searchBarPosition] = [cx, top]
    }

    func windowDidEndLiveResize(_: Notification) {
        guard let panel else { return }
        Defaults[.searchBarSize] = [panel.frame.width, panel.frame.height]
    }

    // MARK: Field

    func controlTextDidChange(_: Notification) {
        guard let root else { return }
        queryEdited(root.field.stringValue)
    }

    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.moveDownAndModifySelection(_:)):
            moveSelection(by: 1, extend: true)
        case #selector(NSResponder.moveUpAndModifySelection(_:)):
            moveSelection(by: -1, extend: true)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)):
            moveSelection(by: results.visibleRowCount)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)):
            moveSelection(by: -results.visibleRowCount)
        case #selector(NSResponder.insertNewline(_:)):
            _ = performReturn(modifiers: [])
        case #selector(NSResponder.insertTab(_:)):
            drillIn()
        case #selector(NSResponder.insertBacktab(_:)):
            drillOut()
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)):
            escape()
        default:
            return false
        }
        return true
    }

    /// The query as typed. Searches right away on the first key after a pause and coalesces a fast
    /// burst, instead of the window's fixed 150 ms wait, so a single word shows results instantly.
    func queryEdited(_ text: String) {
        setListFocused(false)
        historyIndex = -1
        if !FUZZY.showLiveIndex {
            FUZZY.suppressNextSearch = true
        }
        FUZZY.query = text
        if text != lastDrillQuery {
            drillStack.removeAll()
            lastDrillQuery = nil
        }

        searchWork?.cancel()
        let now = CACurrentMediaTime()
        let burst = now - lastKeystroke < 0.12
        lastKeystroke = now
        if burst {
            searchWork = mainAsyncAfter(ms: 45) {
                FUZZY.performSearch()
            }
        } else {
            FUZZY.performSearch()
        }
    }

    /// Sheets and alerts need Cling active to take the keyboard; the bar alone never activates it.
    func activateForModal() {
        guard !NSApp.isActive else { return }
        activatedApp = true
        NSApp.activate(ignoringOtherApps: true)
    }

    func setListFocused(_ focused: Bool) {
        guard listFocused != focused else { return }
        listFocused = focused
        results.strongSelection = focused
        updateHints()
    }

    func moveSelection(by delta: Int, extend: Bool = false) {
        if delta < 0, historyIndex >= 0 || (FUZZY.query.isEmpty && (results.tableView.selectedRow <= 0)) {
            if stepHistory(back: true) {
                return
            }
        }
        if delta > 0, historyIndex >= 0 {
            _ = stepHistory(back: false)
            return
        }
        setListFocused(true)
        userNavigated = true
        if results.tableView.selectedRowIndexes.isEmpty {
            results.select(row: delta > 0 ? 0 : results.items.count - 1)
        } else {
            results.moveSelection(by: delta, extend: extend)
        }
    }

    /// Puts the field and the shared query to `text` without the history and drill bookkeeping.
    func setQuery(_ text: String) {
        guard let root else { return }
        root.field.stringValue = text
        if let editor = root.field.currentEditor() {
            editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
        searchWork?.cancel()
        if !FUZZY.showLiveIndex {
            FUZZY.suppressNextSearch = true
        }
        FUZZY.query = text
        FUZZY.performSearch()
    }

    /// Tab: search inside the selected folder, the way → does in the window's table.
    func drillIn() {
        guard selection.count == 1, let folder = selection.first, isDirectory(folder) else { return }
        if FUZZY.query != lastDrillQuery {
            drillStack.removeAll()
        }
        drillStack.append(FUZZY.query)
        let drilled = Self.drillQuery(folder) + " "
        lastDrillQuery = drilled
        setQuery(drilled)
        setListFocused(false)
    }

    /// Shift-Tab: back out to the query from before the last Tab.
    func drillOut() {
        guard !drillStack.isEmpty, FUZZY.query == lastDrillQuery else { return }
        let previous = drillStack.removeLast()
        lastDrillQuery = drillStack.isEmpty ? nil : previous
        setQuery(previous)
    }

    func isDirectory(_ path: FilePath) -> Bool {
        if let known = FilePathBackgroundTasks.shared.knownIsDir(path) {
            return known
        }
        guard path.memoz.volume == nil else { return false }
        return path.isDir
    }

    func updateHints() {
        guard let root else { return }
        let sel = selection
        var hints: [SearchBarHint] = []
        let keys = hintKeys
        if !sel.isEmpty {
            if let pasteTarget = keys.pasteTarget {
                hints.append(.init(id: .paste, key: "⏎", title: "Paste to \(pasteTarget)"))
            } else {
                hints.append(.init(id: .open, key: "⏎", title: "Open"))
            }
            hints.append(.init(id: .showInFinder, key: keys.showInFinder, title: "Show in Finder"))
            hints.append(.init(id: .quickLook, key: listFocused ? "␣" : keys.quickLook, title: "QuickLook"))
            if sel.count == 1, let path = sel.first, FilePathBackgroundTasks.shared.knownIsDir(path) == true {
                hints.append(.init(id: .drill, key: "⇥", title: "Search in folder"))
            }
            hints.append(.init(id: .copy, key: keys.copy, title: "Copy"))
        }
        hints.append(.init(id: .actions, key: "⌘K", title: "Actions"))
        root.hintBar.hints = hints
    }

    func refreshHintKeys() {
        let pastes = APP_MANAGER.frontmostAppIsTerminal && Defaults[.enterPastesToFrontmostTerminal]
        hintKeys = HintKeys(
            showInFinder: shortcutString(.clShowInFinder) ?? "⌘⏎",
            quickLook: shortcutString(.clQuickLook) ?? "⌘Y",
            copy: shortcutString(.clCopy) ?? "⌘C",
            pasteTarget: pastes ? (APP_MANAGER.lastFrontmostApp?.name ?? "frontmost app") : nil
        )
    }

    func shortcutString(_ name: KeyboardShortcuts.Name) -> String? {
        KeyboardShortcuts.getShortcut(for: name)?.description
    }

    func signpost(_ name: StaticString) {
        #if DEBUG || SEARCHBAR_BENCH
            SearchBarBenchmark.mark(name)
        #endif
    }

    func toggleQuickLook() {
        guard let ql = QLPreviewPanel.shared() else { return }
        if quickLookVisible {
            ql.orderOut(nil)
            return
        }
        let sel = selection
        let items = sel.count > 1 ? sel : results.items
        guard !items.isEmpty else { return }
        quickLookItems = items.map(\.url)
        quickLookIndex = sel.count == 1 ? (results.items.firstIndex(of: sel[0]) ?? 0) : 0
        if !FUZZY.query.isEmpty {
            SearchHistory.shared.commit(FUZZY.query)
        }
        ql.makeKeyAndOrderFront(nil)
    }

    func closeQuickLook() {
        guard quickLookVisible else { return }
        QLPreviewPanel.shared().orderOut(nil)
    }

    func beginQuickLook(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = quickLookIndex
    }

    func endQuickLook(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
        if isExpanded {
            self.panel?.makeKey()
        }
    }

    nonisolated func numberOfPreviewItems(in _: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { quickLookItems.count }
    }

    nonisolated func previewPanel(_: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { quickLookItems[safe: index] as NSURL? }
    }

    private var hintKeys = HintKeys()
    private var pillPanel: SearchBarPillPanel?
    private var pillView: SearchBarPillView?
    private var previewHost: NSHostingView<AnyView>?
    private var previewPaths: [FilePath] = []
    private var lastPreviewRequest: CFTimeInterval = 0

    private var observationGeneration = 0
    private var lastInputs: Inputs?
    private var appliedQueryKey: String?
    private var userNavigated = false

    private var drillStack: [String] = []
    private var lastDrillQuery: String?
    private var historyIndex = -1
    private var querySaved = ""

    private var lastKeystroke: CFTimeInterval = 0
    private var searchWork: DispatchWorkItem?
    private var previewWork: DispatchWorkItem?
    private var keyMonitor: Any?
    private var observers: Set<AnyCancellable> = []
    private var placingPanel = false
    private var pinned = false
    private var lastFocusLossCollapse: Date?

    private var showsPreview: Bool {
        Defaults[.searchBarShowPreview]
    }

    private var storedSize: NSSize {
        let stored = Defaults[.searchBarSize]
        guard stored.count == 2 else { return Self.defaultSize }
        return NSSize(width: max(stored[0], Self.minSize.width), height: max(stored[1], Self.minSize.height))
    }

    /// The `in:` query the window's → builds: home shortened to `~`, quoted when it has spaces.
    private static func drillQuery(_ folder: FilePath) -> String {
        let p = folder.string
        let home = NSHomeDirectory()
        var shown = p
        if p == home {
            shown = "~"
        } else if p.hasPrefix(home + "/") {
            shown = "~" + p.dropFirst(home.count)
        }
        return shown.contains(" ") ? "in:\"\(shown)\"" : "in:\(shown)"
    }

    private func ensurePanel() -> SearchBarPanel {
        if let panel {
            return panel
        }
        let size = storedSize
        let panel = SearchBarPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.identifier = NSUserInterfaceItemIdentifier("searchbar")
        panel.controller = self
        panel.delegate = self
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.title = "Cling"
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        // Moved by SearchBarRootView's own drag. A movable titled window has AppKit work out which
        // parts of its titlebar strip can drag it, from scratch whenever a view moves under it, and
        // here that was every row scrolling in or out.
        panel.isMovable = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.minSize = Self.minSize
        panel.depthLimit = .twentyfourBitRGB

        let root = SearchBarRootView(results: results)
        root.frame = NSRect(origin: .zero, size: size)
        root.autoresizingMask = [.width, .height]
        panel.contentView = root

        root.field.delegate = self
        root.field.onMouseDown = { [weak self] in self?.setListFocused(false) }
        root.filterButton.configure(symbol: "line.3.horizontal.decrease.circle", accessibility: "Filters", target: self, action: #selector(showFilterMenu(_:)))
        root.filterButton.toolTip = "Quick Filters: narrow down results without typing often used queries"
        root.everythingButton.configure(symbol: "asterisk", accessibility: "Everything", target: self, action: #selector(toggleEverything(_:)))
        root.everythingButton.toolTip = "Everything: every file on the local disks, nothing excluded (⌘⇧E)"
        root.sortButton.configure(symbol: "arrow.up.arrow.down", accessibility: "Sort", target: self, action: #selector(showSortMenu(_:)))
        root.sortButton.toolTip = "Sort"
        root.previewButton.configure(symbol: "sidebar.right", accessibility: "Toggle Preview", target: self, action: #selector(togglePreview(_:)))
        root.filterChip.onClick = { [weak self] in
            guard let self else { return }
            showFilterMenu(root.filterButton)
        }
        root.everythingChip.text = "Everything"
        root.everythingChip.onClick = { EVERYTHING.toggle() }
        root.hintBar.onHint = { [weak self] id in self?.performHint(id) }

        results.onSelectionChange = { [weak self] in self?.selectionChanged() }
        results.tableView.onDoubleClick = { [weak self] _ in
            guard let self else { return }
            perform(.open)
        }
        results.tableView.onMouseDown = { [weak self] in
            self?.setListFocused(true)
            self?.userNavigated = true
        }
        results.tableView.actionsMenuProvider = { [weak self] _ in
            self?.actionsMenu()
        }

        self.panel = panel
        self.root = root
        return panel
    }

    /// Unpinned: where it was left on the display Settings > General picks, Spotlight's spot at
    /// first. Pinned: grown out of the compact field, downwards when there's room, else upwards.
    private func frameForExpanded() -> NSRect {
        let size = storedSize
        if pinned, let pillPanel {
            let pillFrame = pillPanel.frame
            let screen = NSScreen.screens.first { $0.frame.intersects(pillFrame) } ?? NSScreen.main
            let area = screen?.visibleFrame ?? pillFrame
            var origin = NSPoint(x: pillFrame.minX - 10, y: pillFrame.maxY - size.height)
            if origin.y < area.minY {
                origin.y = pillFrame.minY
            }
            return clamp(NSRect(origin: origin, size: size), in: area)
        }

        let screen = AppDelegate.shared?.displayForMainWindow() ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let stored = Defaults[.searchBarPosition]
        let cx = stored.count == 2 ? stored[0] : 0.5
        let top = stored.count == 2 ? stored[1] : 0.18
        let origin = NSPoint(
            x: area.minX + cx * area.width - size.width / 2,
            y: area.maxY - top * area.height - size.height
        )
        return clamp(NSRect(origin: origin, size: size), in: area)
    }

    private func clamp(_ rect: NSRect, in area: NSRect) -> NSRect {
        var r = rect
        r.size.width = min(r.width, area.width)
        r.size.height = min(r.height, area.height)
        r.origin.x = min(max(r.minX, area.minX), area.maxX - r.width)
        r.origin.y = min(max(r.minY, area.minY), area.maxY - r.height)
        return r
    }

    /// A hidden main window keeps its view graph, and that graph observes the same results the bar
    /// shows, so it would redraw its table for every keystroke here. Its content is dropped until
    /// the window is summoned again.
    private func suspendHiddenMainWindow() {
        let main = AppDelegate.shared?.mainWindow
        guard main == nil || main?.isVisible == false || main?.alphaValue == 0, !WM.mainContentSuspended else { return }
        WM.mainContentSuspended = true
    }

    private func checkFocusLoss() {
        guard isExpanded, let panel, !panel.isKeyWindow else { return }
        if panel.attachedSheet != nil || quickLookVisible {
            return
        }
        if let key = NSApp.keyWindow, key.sheetParent === panel {
            return
        }
        collapse(focusLost: true)
    }

    // MARK: Observation

    private func readInputs() -> Inputs {
        let fuzzy = FUZZY
        let defaultList = fuzzy.noQuery && fuzzy.volumeFilter == nil
        let list = defaultList ? (fuzzy.sortField == .score ? fuzzy.recents : fuzzy.sortedRecents) : fuzzy.results

        var parts = [String]()
        if let q = fuzzy.quickFilter {
            parts.append(q.id)
        }
        if let f = fuzzy.folderFilter {
            parts.append("in \(f.id)")
        }
        if let v = fuzzy.volumeFilter {
            parts.append("on \(v.name.string)")
        }
        let scope = fuzzy.scopeAppearance

        return Inputs(
            list: list,
            defaultList: defaultList,
            searching: fuzzy.searching,
            stash: STASH.files,
            query: fuzzy.query,
            filterText: parts.joined(separator: " "),
            scopeIcon: scope?.icon,
            scopeHue: scope?.color.hue,
            everything: EVERYTHING.enabled
        )
    }

    /// Reads the inputs under observation and applies them. The change callback only schedules the
    /// next read, so a burst of changes in one run loop turn costs one update.
    private func observe() {
        let generation = observationGeneration
        let inputs = withObservationTracking {
            readInputs()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.observationGeneration, self.isExpanded else { return }
                    self.observe()
                }
            }
        }
        apply(inputs)
    }

    private func apply(_ inputs: Inputs) {
        guard let root else { return }
        let previous = lastInputs
        lastInputs = inputs
        signpost("apply")

        // The list.
        let stashSet = Set(inputs.stash)
        let displayed = inputs.stash.isEmpty ? inputs.list : inputs.stash + inputs.list.filter { !stashSet.contains($0) }
        results.stashed = stashSet
        let queryKey = "\(inputs.query)\u{1}\(inputs.filterText)\u{1}\(inputs.everything)"
        let newQuery = queryKey != appliedQueryKey
        if newQuery {
            appliedQueryKey = queryKey
            userNavigated = false
        }
        // Nothing preselected over recents, as in the window: a row picked on open is one the
        // person never chose. Otherwise the first result, until the person moves the selection.
        let firstRow = inputs.defaultList ? -1 : (displayed.count > inputs.stash.count ? inputs.stash.count : 0)

        if displayed != results.items {
            results.setItems(displayed, select: userNavigated ? nil : firstRow, scrollToTop: !userNavigated)
        } else if newQuery, !userNavigated {
            if firstRow < 0 {
                results.tableView.deselectAll(nil)
            } else {
                results.select(row: firstRow)
            }
        } else if previous?.query == inputs.query, previous == inputs {
            // The same paths handed back again: icons, sizes or dates arrived for them.
            results.refreshVisibleRows()
        }

        // Spinner.
        if inputs.searching != previous?.searching {
            inputs.searching ? root.spinner.startAnimation(nil) : root.spinner.stopAnimation(nil)
        }

        // Filter button, filter chip and Everything.
        if inputs.scopeIcon != previous?.scopeIcon || inputs.scopeHue != previous?.scopeHue || previous == nil {
            if let icon = inputs.scopeIcon, let hue = inputs.scopeHue {
                root.filterButton.symbol = icon
                let dark = root.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                root.filterButton.tint = NSColor(FilterColor(hue: hue).accent(dark: dark))
            } else {
                root.filterButton.symbol = "line.3.horizontal.decrease.circle"
                root.filterButton.tint = nil
            }
        }
        if inputs.filterText != previous?.filterText || inputs.everything != previous?.everything || previous == nil {
            root.filterChip.text = inputs.filterText
            root.filterChip.isHidden = inputs.filterText.isEmpty
            if let hue = inputs.scopeHue {
                let dark = root.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                root.filterChip.color = NSColor(FilterColor(hue: hue).accent(dark: dark))
            }
            root.everythingChip.isHidden = !inputs.everything
            root.everythingButton.tint = inputs.everything ? .systemOrange : nil
            root.everythingButton.isEnabled = proactive
            root.needsLayout = true
        }

        // Empty state and count.
        let tooShort = !inputs.query.isEmpty && inputs.query.count < minQueryLength && inputs.filterText.isEmpty
        if displayed.isEmpty {
            root.emptyLabel.stringValue = tooShort
                ? "Type \(minQueryLength) or more characters to search"
                : (inputs.defaultList || inputs.searching ? "" : "No results")
            root.emptyLabel.isHidden = root.emptyLabel.stringValue.isEmpty
        } else if !root.emptyLabel.isHidden {
            root.emptyLabel.isHidden = true
        }
        let count = inputs.list.count
        root.hintBar.status = inputs.defaultList ? "" : (count == 1 ? "1 result" : "\(count.formatted()) results")
    }

    // MARK: Selection, preview and QuickLook

    private func selectionChanged() {
        updateHints()
        let sel = selection
        if !sel.isEmpty {
            FUZZY.computeOpenWithApps(for: sel.map(\.url))
        }
        schedulePreview()
        if quickLookVisible {
            syncQuickLook()
        }
    }

    private func updatePreviewVisibility() {
        guard let root else { return }
        let show = showsPreview && isExpanded
        root.showsPreview = show
        root.previewButton.tint = showsPreview ? .controlAccentColor : nil
        let shortcut = shortcutString(.clTogglePreview).map { " (\($0))" } ?? ""
        root.previewButton.toolTip = "Toggle Preview\(shortcut)"
        if show {
            schedulePreview(immediately: true)
        } else {
            clearPreview()
        }
    }

    /// The preview follows the selection, but holding an arrow key would rebuild it for every row
    /// passed, so quick successive moves wait until the selection rests.
    private func schedulePreview(immediately: Bool = false) {
        guard showsPreview, isExpanded else { return }
        previewWork?.cancel()
        let now = CACurrentMediaTime()
        let rapid = now - lastPreviewRequest < 0.2
        lastPreviewRequest = now
        if immediately || !rapid {
            showPreview()
        } else {
            previewWork = mainAsyncAfter(ms: 110) { [weak self] in
                self?.showPreview()
            }
        }
    }

    private func showPreview() {
        guard let root, isExpanded, showsPreview else { return }
        let sel = selection
        let paths = sel.isEmpty ? Array(results.items.prefix(1)) : sel
        guard paths != previewPaths else { return }
        previewPaths = paths
        signpost("preview")
        let view = AnyView(FilePreviewPanel(paths: paths))
        if let previewHost {
            previewHost.rootView = view
        } else {
            let host = NSHostingView(rootView: view)
            // Laid out by the bar; the preview must not push its own size onto the window.
            host.sizingOptions = []
            host.frame = root.previewContainer.bounds
            host.autoresizingMask = [.width, .height]
            root.previewContainer.addSubview(host)
            previewHost = host
        }
    }

    /// Drops the preview's SwiftUI content, which stops any playing media and releases images.
    /// The host stays in the window and applies the change right away: QuickLook's view asserts if
    /// it is closed after it already left its window.
    private func clearPreview() {
        previewWork?.cancel()
        previewPaths = []
        guard let previewHost else { return }
        previewHost.rootView = AnyView(EmptyView())
        previewHost.layoutSubtreeIfNeeded()
    }

    /// Arrowing through the bar's list while QuickLook is up moves QuickLook along with it.
    private func syncQuickLook() {
        guard let ql = QLPreviewPanel.shared(), ql.dataSource === self else { return }
        let sel = selection
        if sel.count == 1, quickLookItems.count == results.items.count, let index = results.items.firstIndex(of: sel[0]) {
            quickLookIndex = index
            ql.currentPreviewItemIndex = index
        } else if sel.count > 1 {
            quickLookItems = sel.map(\.url)
            quickLookIndex = 0
            ql.reloadData()
        }
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            nonisolated(unsafe) let unsafeEvent = event
            let passThrough = MainActor.assumeIsolated { self.handle(unsafeEvent) != nil }
            return passThrough ? event : nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let panel, event.window === panel, panel.attachedSheet == nil, let root else { return event }
        guard event.type == .keyDown else { return event }
        if let editor = root.field.currentEditor() as? NSTextView, editor.hasMarkedText() {
            return event
        }

        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let kc = event.keyCode
        let chars = (event.charactersIgnoringModifiers ?? "").lowercased()

        switch kc {
        case 125 where mods == .command: // ⌘↓
            setListFocused(true)
            userNavigated = true
            results.select(row: results.items.count - 1)
            return nil
        case 126 where mods == .command: // ⌘↑
            setListFocused(true)
            userNavigated = true
            results.select(row: 0)
            return nil
        case 36, 76: // Return
            if mods.isEmpty || mods == [.command, .shift], performReturn(modifiers: mods) {
                return nil
            }
        case 49 where mods.isEmpty && listFocused: // Space
            toggleQuickLook()
            return nil
        case 53 where mods == .option: // ⌥⎋
            clearFilters()
            return nil
        case 53 where mods.isEmpty: // ⎋
            escape()
            return nil
        case 51 where mods == .command && !listFocused, 117 where mods == .command && !listFocused:
            // ⌘⌫ edits the query until the list has the keyboard.
            return event
        default:
            break
        }

        if mods == .command {
            switch chars {
            case "k":
                showActionsMenu()
                return nil
            case "i":
                if let path = selection.first {
                    openFinderGetInfo(path)
                }
                return nil
            case "=", "+":
                FontScale.adjust(by: FontScale.step)
                return nil
            case "-":
                FontScale.adjust(by: -FontScale.step)
                return nil
            case "0":
                FontScale.reset()
                return nil
            case "w":
                collapse()
                return nil
            default:
                break
            }
        }

        if let pressed = KeyboardShortcuts.Shortcut(event: event) {
            if pressed == KeyboardShortcuts.getShortcut(for: .clTogglePreview) {
                Defaults[.searchBarShowPreview].toggle()
                return nil
            }
            if pressed == KeyboardShortcuts.getShortcut(for: .clToggleEverything) {
                EVERYTHING.toggle()
                return nil
            }
            if pressed == KeyboardShortcuts.getShortcut(for: .clStashClear), !STASH.files.isEmpty {
                STASH.clear()
                return nil
            }
            if let field = ClingShortcuts.sortField(for: pressed) {
                applySort(field)
                return nil
            }
            if !selection.isEmpty, let id = rebindableAction(for: pressed) {
                perform(id)
                return nil
            }
        }

        if mods == .option, let ch = chars.first, applyFilterKey(ch) {
            return nil
        }
        if mods == [.command, .option], let ch = chars.first, openWithShortcut(ch) {
            return nil
        }
        if mods == [.command, .control], let ch = chars.first, runScriptShortcut(ch) {
            return nil
        }
        return event
    }

    /// The action bound to `pressed`, skipping the ones that would steal text editing keys from the
    /// field: ⌘C copies the query's selected text when there is some, ⌘⌫ trashes only from the list.
    private func rebindableAction(for pressed: KeyboardShortcuts.Shortcut) -> ActionID? {
        for action in ToolbarAction.rebindable where action.id != .togglePreview {
            guard KeyboardShortcuts.getShortcut(for: ClingShortcuts.name(for: action.id)) == pressed else { continue }
            if action.id == .copy, let editor = root?.field.currentEditor(), editor.selectedRange.length > 0 {
                return nil
            }
            if action.id == .trash, !listFocused {
                return nil
            }
            return action.id
        }
        return nil
    }

    // MARK: Pill

    private func showPill() {
        let panel = ensurePill()
        applyPillLevel()
        panel.orderFrontRegardless()
        // The shadow follows the capsule's alpha, which only exists once it has drawn.
        DispatchQueue.main.async { panel.invalidateShadow() }
    }

    @discardableResult
    private func ensurePill() -> SearchBarPillPanel {
        if let pillPanel {
            return pillPanel
        }
        let size = SearchBarPillView.fittingSize
        let panel = SearchBarPillPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.identifier = NSUserInterfaceItemIdentifier("searchbar-pinned")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let view = SearchBarPillView(frame: NSRect(origin: .zero, size: size))
        view.autoresizingMask = [.width, .height]
        view.onClick = { [weak self] in self?.expand() }
        view.onMoved = { [weak self] origin in
            Defaults[.searchBarPillOrigin] = [origin.x, origin.y]
            self?.screensChanged()
        }
        panel.contentView = view
        panel.setFrameOrigin(storedPillOrigin(size: size))
        pillPanel = panel
        pillView = view
        return panel
    }

    private func storedPillOrigin(size: NSSize) -> NSPoint {
        let stored = Defaults[.searchBarPillOrigin]
        if stored.count == 2 {
            let origin = NSPoint(x: stored[0], y: stored[1])
            let frame = NSRect(origin: origin, size: size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                return origin
            }
        }
        // Top right of the main display, under the menu bar.
        let area = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: area.maxX - size.width - 20, y: area.maxY - size.height - 12)
    }

    private func applyPillLevel() {
        guard let pillPanel else { return }
        pillPanel.level = Defaults[.searchBarAboveWindows]
            ? .floating
            : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }

    private func pinnedChanged(_ value: Bool) {
        pinned = value
        if value {
            if state == .hidden {
                state = .compact
                showPill()
            }
        } else {
            pillPanel?.orderOut(nil)
            if state == .compact {
                state = .hidden
            }
        }
    }

    /// Keeps the compact field on a display: one that was unplugged takes it back to the default spot.
    private func screensChanged() {
        guard let pillPanel else { return }
        let frame = pillPanel.frame
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            pillPanel.setFrameOrigin(storedPillOrigin(size: frame.size))
        }
    }

    private func restyle() {
        pillView?.restyle()
        root?.background.rebuild()
    }

    private func fontScaleChanged() {
        SearchBarRowStyle.shared.rebuildIfNeeded()
        guard let root else { return }
        root.applyFonts()
        results.tableView.rowHeight = SearchBarRowStyle.shared.rowHeight
        results.tableView.reloadData()
        root.hintBar.needsDisplay = true
    }

    private func stepHistory(back: Bool) -> Bool {
        let history = SearchHistory.shared.entries
        guard !history.isEmpty else { return false }
        if back {
            if historyIndex == -1 {
                querySaved = FUZZY.query
            }
            let next = min(historyIndex + 1, history.count - 1)
            guard next != historyIndex else { return true }
            historyIndex = next
            setQuery(history[next])
        } else {
            if historyIndex > 0 {
                historyIndex -= 1
                setQuery(history[historyIndex])
            } else {
                historyIndex = -1
                setQuery(querySaved)
            }
        }
        return true
    }
}
