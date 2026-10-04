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

    struct Inputs: Equatable {
        var list: [FilePath]
        var defaultList: Bool
        var searching: Bool
        var stash: [FilePath]
        var query: String
        var filterText: String
        var scopeIcon: String?
        var scopeHue: Double?
        var wash: SearchBarWashView.Wash?
        var everything: Bool
        /// Why the Everything button is off limits, while the search is limited to external drives.
        var everythingBlocked: String?
        /// Only the search row shows: nothing typed, nothing chosen for the bar to show before typing and nothing stashed.
        var fieldOnly: Bool
        /// The stash is all there is to show, and the bar is only as tall as it needs.
        var stashOnly: Bool
    }

    /// Shortcut labels and the paste target for the hint bar, read once per summon: both come from
    /// settings and the app in front, neither of which changes while the bar has the keyboard.
    struct HintKeys {
        var showInFinder = "⌘⏎"
        var quickLook = "⌘Y"
        var copy = "⌘C"
        var pasteTarget: String?
    }

    /// Everything the bar shows that comes from the shared search state.
    static let everythingTip = "Everything: every file on the local disks, nothing excluded (⌘⇧E)"

    static let shared = SearchBarController()

    static let minSize = NSSize(width: 560, height: 320)
    static let defaultSize = NSSize(width: 750, height: 500)

    private(set) var state = State.hidden

    /// The show/hide hotkey, the Dock icon and the menu bar icon bring up the bar instead of the window.
    private(set) var ownsHotkey = false

    // MARK: Internals shared with the actions extension

    let results = SearchBarResultsController()
    var root: SearchBarRootView?
    var panel: SearchBarPanel?
    var activatedApp = false
    var syntaxPopover: NSPopover?
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

    /// Cling's hotkey, shown on the compact field while it's the bar that the hotkey brings up, in
    /// the usual ⌃⌥⇧⌘ order.
    var pillHotkey: String? {
        guard Defaults[.hotkeyTarget] == .searchBar, Defaults[.enableGlobalHotkey] else { return nil }
        let triggers = Defaults[.triggerKeys]
        let flags = triggers.map(\.sideIndependentModifier).reduce(NSEvent.ModifierFlags()) { $0.union($1) }
        var keys = triggers.contains(.fn) ? "fn" : ""
        for (flag, symbol) in [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")] where flags.contains(flag) {
            keys += symbol
        }
        return keys + Defaults[.showAppKey].character
    }

    /// Top centre of a display's usable area, a little under the menu bar.
    static func defaultPillOrigin(size: NSSize, in area: NSRect) -> NSPoint {
        NSPoint(x: (area.midX - size.width / 2).rounded(), y: area.maxY - size.height - 14)
    }

    // MARK: Setup

    func setup() {
        ownsHotkey = Defaults[.hotkeyTarget] == .searchBar
        minQueryLength = Defaults[.minQueryLength]
        pinned = Defaults[.searchBarPinned]

        pub(.hotkeyTarget).sink { [weak self] change in
            mainAsync {
                self?.ownsHotkey = change.newValue == .searchBar
                self?.updatePillHotkey()
                if change.oldValue != change.newValue {
                    self?.interfaceChanged(to: change.newValue)
                }
            }
        }.store(in: &observers)
        for key: Defaults._AnyKey in [.enableGlobalHotkey, .triggerKeys, .showAppKey] {
            Defaults.publisher(keys: key).sink { [weak self] _ in
                mainAsync { self?.updatePillHotkey() }
            }.store(in: &observers)
        }
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
        // Style's Window section, which the bar follows too.
        pub(.dimStatusBar).sink { [weak self] change in
            mainAsync { self?.root?.hintBar.dims = change.newValue }
        }.store(in: &observers)
        pub(.filterWindowTintStrength).sink { [weak self] change in
            mainAsync { self?.root?.wash.strength = change.newValue }
        }.store(in: &observers)
        pub(.searchBarShowPreview).sink { [weak self] _ in
            mainAsync { self?.updatePreviewVisibility() }
        }.store(in: &observers)
        pub(.searchBarDefaultResults).sink { [weak self] change in
            mainAsync {
                if change.newValue == .recentFiles {
                    FUZZY.updateDefaultResults()
                }
                guard let self, self.isExpanded else { return }
                self.observationGeneration += 1
                self.observe()
            }
        }.store(in: &observers)
        NotificationCenter.default.publisher(for: .clingDidCreateFiles)
            .sink { [weak self] notification in
                guard let paths = notification.object as? [FilePath], !paths.isEmpty else { return }
                mainAsync { self?.showCreatedFiles(paths) }
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
        restoreMainContentWork?.cancel()

        root.background.rebuild()
        root.applyFonts()
        SearchBarRowStyle.shared.rebuildIfNeeded()
        if results.tableView.rowHeight != SearchBarRowStyle.shared.rowHeight {
            results.tableView.rowHeight = SearchBarRowStyle.shared.rowHeight
        }

        let wasExpanded = isExpanded
        let pill = !wasExpanded && pinned ? pillPanel.flatMap { $0.isVisible ? $0 : nil } : nil
        let target = frameForExpanded()
        if !wasExpanded {
            placingPanel = true
            panel.setFrame(pill?.frame ?? target, display: false)
            placingPanel = false
        }

        state = .expanded
        updateCursorFollowing()
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
        if let pill {
            panel.alphaValue = 0
        }
        panel.makeKeyAndOrderFront(nil)
        root.field.currentEditor()?.selectAll(nil)
        updateCompletion()
        if let pill {
            grow(panel, outOf: pill, to: target)
        } else {
            if !morphing {
                pillPanel?.orderOut(nil)
            }
            refreshShadow()
        }
        // After this turn's commit, so tearing the hidden window's content down doesn't hold up the
        // bar's first frame.
        DispatchQueue.main.async { [weak self] in
            guard let self, isExpanded else { return }
            suspendHiddenMainWindow()
        }
        signpost("expand")
    }

    func collapse(focusLost: Bool = false) {
        guard isExpanded else { return }
        observationGeneration += 1
        removeKeyMonitor()
        searchWork?.cancel()
        previewWork?.cancel()
        historyIndex = -1
        ghostDismissed = false
        hideSuggestions()
        root?.completion = nil
        closeQuickLook()
        syntaxPopover?.close()
        clearPreview()

        state = pinned ? .compact : .hidden
        WM.searchBarActive = false
        FUZZY.cancelPendingSearch()
        EVERYTHING.windowHidden()
        if pinned, let panel {
            shrink(panel)
        } else {
            panel?.orderOut(nil)
        }
        if focusLost {
            lastFocusLossCollapse = Date()
        }
        restoreMainContentWhenIdle()
        updateCursorFollowing()
        if activatedApp {
            activatedApp = false
            if !focusLost {
                APP_MANAGER.lastFrontmostApp?.activate()
            }
        }
    }

    /// ⌃⇥ in the bar: the same search in the window, for what the bar doesn't do. The switch sticks: the hotkey, the
    /// Dock and menu bar icons and launch bring up the window from now on, as if it was picked in Settings > Style.
    func switchToWindow() {
        guard isExpanded else { return }
        // Focus stays with Cling, which the window takes next.
        collapse(focusLost: true)
        ownsHotkey = false
        Defaults[.hotkeyTarget] = .window
        if let app = AppDelegate.shared, app.mainWindow == nil {
            app.pendingDisplay = app.displayForMainWindow()
        }
        WM.open("main")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// ⌃⇥ in the window: the same search in the bar, which then stays the one Cling brings up.
    func switchFromWindow() {
        if let app = AppDelegate.shared, let main = app.mainWindow {
            app.hideOrCloseMainWindow(main)
        }
        ownsHotkey = true
        Defaults[.hotkeyTarget] = .searchBar
        expand()
    }

    /// Esc: closes QuickLook, then clears the query, then puts the bar away.
    func escape() {
        if quickLookVisible {
            closeQuickLook()
            return
        }
        if let popover = syntaxPopover, popover.isShown {
            popover.performClose(nil)
            return
        }
        if suggestionsShown {
            let visible = suggestionsVisible
            hideSuggestions()
            if visible {
                return
            }
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

    /// Quick Look takes the keyboard when it opens or is clicked. The bar keeps it, so Space closes Quick Look and the
    /// arrows move through the list as before.
    func windowDidBecomeKey(_ notification: Notification) {
        guard notification.object is QLPreviewPanel, isExpanded, let panel else { return }
        panel.makeKey()
    }

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
        storeSize()
    }

    func windowDidResize(_: Notification) {
        if suggestionsVisible {
            positionSuggestions()
        }
    }

    // MARK: Field

    func controlTextDidChange(_: Notification) {
        guard let root else { return }
        queryEdited(root.field.stringValue)
    }

    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            if suggestionsVisible {
                if suggestionIndex < suggestionCount - 1 {
                    highlightSuggestion(suggestionIndex + 1)
                    return true
                }
                // Past the last one, on into the results as in the window.
                hideSuggestions()
            }
            moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            if suggestionsVisible {
                if suggestionIndex > 0 {
                    highlightSuggestion(suggestionIndex - 1)
                } else {
                    hideSuggestions()
                }
                return true
            }
            moveSelection(by: -1)
        case #selector(NSResponder.moveRight(_:)):
            // In the list, into the selected folder; in the query, the caret, or the ghost's next word at the end.
            return listFocused ? drillIn(keepingListFocus: true) : completeNextWord()
        case #selector(NSResponder.moveLeft(_:)):
            return listFocused && drillOut()
        case #selector(NSResponder.moveDownAndModifySelection(_:)):
            moveSelection(by: 1, extend: true)
        case #selector(NSResponder.moveUpAndModifySelection(_:)):
            moveSelection(by: -1, extend: true)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)):
            moveSelection(by: results.visibleRowCount)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)):
            moveSelection(by: -results.visibleRowCount)
        case #selector(NSResponder.scrollToBeginningOfDocument(_:)):
            selectEdge(last: false)
        case #selector(NSResponder.scrollToEndOfDocument(_:)):
            selectEdge(last: true)
        case #selector(NSResponder.insertNewline(_:)):
            _ = performReturn(modifiers: [])
        case #selector(NSResponder.insertTab(_:)):
            if let suggestion = inlineSuggestion {
                complete(to: suggestion)
            } else {
                drillIn()
            }
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
        suggestionIndex = -1
        ghostDismissed = false
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
        updateCompletion()
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
        if focused {
            suggestionsShown = false
        }
        updateCompletion()
        updateHints()
    }

    func moveSelection(by delta: Int, extend: Bool = false) {
        // As in the window, ↑ from the field goes back through past searches, whatever is typed, and ↓ comes forward
        // again. The results only take the keyboard on ↓, so ⌘⌫ keeps editing the query.
        if delta == -1, !extend, !listFocused, stepHistory(back: true) {
            return
        }
        if delta > 0, !listFocused, historyIndex >= 0 {
            _ = stepHistory(back: false)
            return
        }
        if delta == -1, !extend, listFocused, results.tableView.selectedRow <= 0 {
            // Up from the first result hands the keyboard back to the field.
            setListFocused(false)
            return
        }
        let wasFocused = listFocused
        setListFocused(true)
        userNavigated = true
        if results.tableView.selectedRowIndexes.isEmpty {
            results.select(row: 0)
        } else if wasFocused || extend || abs(delta) > 1 {
            results.moveSelection(by: delta, extend: extend)
        }
        // Otherwise the first arrow from the field only moves the keyboard to the list, so the highlighted result is
        // the one Space and the other keys act on.
    }

    /// ⌘↑ and Home select the first result, ⌘↓ and End the last.
    func selectEdge(last: Bool) {
        setListFocused(true)
        userNavigated = true
        results.select(row: last ? results.items.count - 1 : 0)
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
        updateCompletion()
    }

    /// Tab, or → in the list as in the window's table: search inside the selected folder. Tab leaves the keyboard in
    /// the field to type more, → keeps it in the list to go on into a subfolder.
    @discardableResult
    func drillIn(keepingListFocus: Bool = false) -> Bool {
        guard selection.count == 1, let folder = selection.first, isDirectory(folder) else { return false }
        if FUZZY.query != lastDrillQuery {
            drillStack.removeAll()
        }
        drillStack.append(FUZZY.query)
        let drilled = Self.drillQuery(folder) + " "
        lastDrillQuery = drilled
        setQuery(drilled)
        if !keepingListFocus {
            setListFocused(false)
        }
        return true
    }

    /// Shift-Tab, or ← in the list: back out to the query from before the last drill, while it's still untouched.
    @discardableResult
    func drillOut() -> Bool {
        guard !drillStack.isEmpty, FUZZY.query == lastDrillQuery else { return false }
        let previous = drillStack.removeLast()
        lastDrillQuery = drillStack.isEmpty ? nil : previous
        setQuery(previous)
        return true
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
            // Return settles the query first while ↑ is going through past searches or a ghost completion shows.
            let returnSettlesQuery = !listFocused && (historyIndex >= 0 || root.completion != nil)
            if !returnSettlesQuery {
                if let pasteTarget = keys.pasteTarget {
                    hints.append(.init(id: .paste, key: "⏎", title: "Paste to \(pasteTarget)"))
                } else {
                    hints.append(.init(id: .open, key: "⏎", title: "Open"))
                }
            }
            hints.append(.init(id: .showInFinder, key: keys.showInFinder, title: "Show in Finder"))
            hints.append(.init(id: .quickLook, key: listFocused ? "␣" : keys.quickLook, title: "QuickLook"))
            // ⇥ takes the ghost completion while there is one.
            if sel.count == 1, root.completion == nil, let path = sel.first, FilePathBackgroundTasks.shared.knownIsDir(path) == true {
                hints.append(.init(id: .drill, key: listFocused ? "→" : "⇥", title: "Search in folder"))
            }
            hints.append(.init(id: .copy, key: keys.copy, title: "Copy"))
        }
        hints.append(.init(id: .actions, key: "⌘K", title: "Actions"))
        if sel.isEmpty {
            hints.append(.init(id: .syntax, key: "⌘/", title: "Syntax"))
        }
        hints.append(.init(id: .window, key: "⌃ Tab", title: "Window"))
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
        // Like the bar, Quick Look has to take the keyboard without making Cling the active app. Otherwise Cling loses
        // it altogether and Space and the arrows go to the app in front.
        ql.styleMask.insert(.nonactivatingPanel)
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

    private static let shrinkTiming = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)

    /// Response 0.22 s, damping 0.86: a step response that is within a tenth of a percent after `springDuration`.
    private static let springDuration: CFTimeInterval = 0.28

    private var hintKeys = HintKeys()
    private var restoreMainContentWork: DispatchWorkItem?
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

    // MARK: Pill

    /// While the bar grows out of the compact field or shrinks back into it.
    private var morphing = false
    /// Tells a morph's completion whether a newer one took over.
    private var morphGeneration = 0

    private var springLink: CADisplayLink?
    private var springFrom = NSRect.zero
    private var springTo = NSRect.zero
    private var springStart: CFTimeInterval = 0
    private var springCompletion: (() -> Void)?

    // MARK: Following the cursor's display

    private var cursorMonitors: [Any] = []
    private var screenFrames: [NSRect] = []
    /// The display the cursor was last seen on, so a move within it costs one rectangle test.
    private var cursorScreenFrame: NSRect?
    private var followWork: DispatchWorkItem?

    // MARK: Past searches

    /// Return dropped the ghost completion; typing brings it back.
    private var ghostDismissed = false
    /// The ⌘↓ list is open, even while nothing matches the query.
    private var suggestionsShown = false
    private var suggestionIndex = -1
    private var suggestionsPanel: SearchBarSuggestionsPanel?

    private var showsPreview: Bool {
        Defaults[.searchBarShowPreview]
    }

    private var storedSize: NSSize {
        let stored = Defaults[.searchBarSize]
        guard stored.count == 2 else { return Self.defaultSize }
        return NSSize(width: max(stored[0], Self.minSize.width), height: max(stored[1], Self.minSize.height))
    }

    /// The expanded height before typing when the bar shows only its field.
    private var fieldOnlyBeforeTyping: Bool {
        emptyBeforeTyping && STASH.files.isEmpty
    }

    private var emptyBeforeTyping: Bool {
        FUZZY.noQuery && FUZZY.volumeFilter == nil && Defaults[.searchBarDefaultResults] == .empty
    }

    /// Search row, stashed files and hint bar, when the stash is all the bar shows; nil otherwise.
    private var stashOnlyHeight: CGFloat? {
        guard emptyBeforeTyping, !STASH.files.isEmpty, let root else { return nil }
        let height = root.searchRowHeight + results.stashListHeight(rows: min(STASH.files.count, 8)) + root.hintBarHeight
        return min(height.rounded(.up), storedSize.height)
    }

    private var suggestionsVisible: Bool {
        suggestionsPanel?.isVisible == true
    }

    private var suggestionCount: Int {
        suggestionsPanel?.list.items.count ?? 0
    }

    /// The latest past search the query starts, drawn after it: ⇥ takes it all, → a word at a time.
    private var inlineSuggestion: String? {
        guard let root, !listFocused, historyIndex < 0, !ghostDismissed else { return nil }
        if let editor = root.field.currentEditor() as? NSTextView, editor.hasMarkedText() {
            return nil
        }
        let query = root.field.stringValue
        guard !query.isEmpty else { return nil }
        let lower = query.lowercased()
        return SearchHistory.shared.entries.first { $0.count > query.count && $0.lowercased().hasPrefix(lower) }
    }

    /// Past searches matching the query for the ⌘↓ list, most recent first.
    private var historySuggestions: [String] {
        let query = root?.field.stringValue ?? ""
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return SearchHistory.shared.suggestions(for: query)
            .filter { $0.trimmingCharacters(in: .whitespaces) != trimmed }
            .prefix(8).map(\.self)
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

    private static func springProgress(_ t: Double) -> Double {
        let omega = 2 * Double.pi / 0.22
        let zeta = 0.86
        let damped = omega * (1 - zeta * zeta).squareRoot()
        return 1 - exp(-zeta * omega * t) * (cos(damped * t) + zeta * omega / damped * sin(damped * t))
    }

    // MARK: Bar and window

    /// Settings > Style switched between the bar and the window: the one no longer picked goes away.
    private func interfaceChanged(to target: HotkeyTarget) {
        switch target {
        case .searchBar:
            if let app = AppDelegate.shared, let main = app.mainWindow, main.isVisible, main.alphaValue > 0 {
                app.hideOrCloseMainWindow(main)
            }
        case .window:
            collapse(focusLost: true)
        }
    }

    /// Shrinks the bar to its search row, or grows it back to the stored size, keeping its top edge where it is.
    private func fitPanelHeight() {
        guard let panel, let root, !morphing else { return }
        let height = root.fieldOnly ? root.searchRowHeight : stashOnlyHeight ?? storedSize.height
        guard panel.frame.height != height else { return }
        var frame = panel.frame
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        if let area = (panel.screen ?? NSScreen.main)?.visibleFrame {
            frame = clamp(frame, in: area)
        }
        placingPanel = true
        panel.setFrame(frame, display: true)
        placingPanel = false
        refreshShadow()
    }

    /// Only sizes set by hand: animations and the bar's own placement go through `placingPanel`, and the field-only
    /// height isn't one to keep.
    private func storeSize() {
        guard let panel, root?.fieldOnly != true, stashOnlyHeight == nil, !placingPanel, !morphing else { return }
        Defaults[.searchBarSize] = [panel.frame.width, panel.frame.height]
        refreshShadow()
    }

    /// A borderless window's shadow is worked out from what it has drawn and then kept. One taken before the rounded
    /// background drew, or before a resize, stays a rectangle and shows under the rounded corners, so it's redone
    /// after the next draw.
    private func refreshShadow() {
        DispatchQueue.main.async { [weak self] in
            guard let panel = self?.panel, panel.isVisible else { return }
            panel.displayIfNeeded()
            panel.invalidateShadow()
        }
    }

    private func ensurePanel() -> SearchBarPanel {
        if let panel {
            return panel
        }
        let size = storedSize
        // Borderless, so the bar has its own rounder corners and no window rim. It is moved by SearchBarRootView's
        // own drag and resized by its SearchBarResizeOverlay.
        let panel = SearchBarPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.identifier = NSUserInterfaceItemIdentifier("searchbar")
        panel.controller = self
        panel.delegate = self
        panel.title = "Cling"
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
        // Down to the compact field, which the bar grows out of and shrinks back into. Resizing by hand keeps to the
        // resize overlay's minSize.
        panel.minSize = NSSize(width: 40, height: 20)
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
        root.everythingButton.toolTip = Self.everythingTip
        root.sortButton.configure(symbol: "arrow.up.arrow.down", accessibility: "Sort", target: self, action: #selector(showSortMenu(_:)))
        root.sortButton.toolTip = "Sort"
        root.previewButton.configure(symbol: "sidebar.right", accessibility: "Toggle Preview", target: self, action: #selector(togglePreview(_:)))
        root.resizeOverlay.minSize = Self.minSize
        root.resizeOverlay.onResizeEnd = { [weak self] in self?.storeSize() }
        root.hintBar.onHint = { [weak self] id in self?.performHint(id) }
        root.hintBar.dims = Defaults[.dimStatusBar]
        root.wash.strength = Defaults[.filterWindowTintStrength]

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
    /// first. Pinned: grown out of the compact field, with its search row on the field's midline,
    /// downwards when there's room, else upwards. Sideways it grows away from the closer screen edge:
    /// rightwards from a field in the left third, leftwards from one in the right third, and evenly
    /// from one in the middle.
    private func frameForExpanded() -> NSRect {
        var size = storedSize
        let rowHeight = root?.searchRowHeight ?? 54
        if fieldOnlyBeforeTyping, let root {
            root.fieldOnly = true
            size.height = rowHeight
        } else if let height = stashOnlyHeight {
            size.height = height
        }
        if pinned, let pillPanel {
            let pillFrame = pillPanel.frame
            let screen = NSScreen.screens.first { $0.frame.intersects(pillFrame) } ?? NSScreen.main
            let area = screen?.visibleFrame ?? pillFrame
            let across = area.width > 0 ? (pillFrame.midX - area.minX) / area.width : 0.5
            let x = switch across {
            case ..<(1 / 3): pillFrame.minX - 10
            case (2 / 3)...: pillFrame.maxX + 10 - size.width
            default: pillFrame.midX - size.width / 2
            }
            var origin = NSPoint(x: x, y: pillFrame.midY + rowHeight / 2 - size.height)
            if origin.y < area.minY {
                origin.y = pillFrame.midY - rowHeight / 2
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

    /// When the hotkey still shows the window, the bar is the occasional tool, so the window's
    /// content is built again a moment after the bar closes. That cost lands while nobody waits,
    /// instead of on the next summon of the window. When the hotkey shows the bar, the window
    /// stays empty until something opens it.
    private func restoreMainContentWhenIdle() {
        guard !ownsHotkey, WM.mainContentSuspended else { return }
        restoreMainContentWork?.cancel()
        restoreMainContentWork = mainAsyncAfter(ms: 800) { [weak self] in
            guard let self, !isExpanded else { return }
            WM.mainContentSuspended = false
        }
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
        let defaultResults = Defaults[.searchBarDefaultResults]
        let list: [FilePath] = if !defaultList {
            fuzzy.results
        } else {
            switch defaultResults {
            case .empty: []
            case .recentFiles: fuzzy.sortField == .score ? fuzzy.recentFiles : fuzzy.sortedResults(results: fuzzy.recentFiles)
            case .runHistory: RH.topResults(limit: Defaults[.maxResultsCount])
            }
        }

        var parts = [String]()
        if let q = fuzzy.quickFilter {
            parts.append(q.id)
        }
        if let f = fuzzy.folderFilter {
            parts.append("in \(f.id)")
        }
        if let v = fuzzy.volumeFilterName {
            parts.append("on \(v)")
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
            wash: fuzzy.scopeWash.map { SearchBarWashView.Wash(top: $0.top, bottom: $0.bottom) },
            everything: EVERYTHING.applies,
            everythingBlocked: EVERYTHING.blockedReason,
            fieldOnly: defaultList && defaultResults == .empty && STASH.files.isEmpty,
            stashOnly: defaultList && defaultResults == .empty && !STASH.files.isEmpty
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
        // Before any row is drawn for these results, and the rows already on screen redraw: a narrower filter often
        // hands back the same files, which would otherwise keep the drive labels of the previous one.
        let showsDrives = FUZZY.resultsSpanDrives
        if SearchBarRowStyle.shared.showsDrives != showsDrives {
            SearchBarRowStyle.shared.showsDrives = showsDrives
            results.refreshVisibleRows()
        }

        if inputs.fieldOnly != root.fieldOnly {
            root.fieldOnly = inputs.fieldOnly
            fitPanelHeight()
        } else if inputs.stashOnly != previous?.stashOnly || inputs.stashOnly && inputs.stash.count != previous?.stash.count {
            fitPanelHeight()
        }

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

        if inputs.wash != previous?.wash || previous == nil {
            root.wash.wash = inputs.wash
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
        if inputs.filterText != previous?.filterText || inputs.everything != previous?.everything
            || inputs.everythingBlocked != previous?.everythingBlocked || previous == nil
        {
            root.filterButton.label = inputs.filterText.isEmpty ? nil : inputs.filterText
            root.filterButton.tint = inputs.filterText.isEmpty ? nil : inputs.scopeHue.map { NSColor.searchBarFilter(hue: $0) }
            root.everythingButton.tint = inputs.everything ? .searchBarOrange : nil
            root.everythingButton.label = inputs.everything ? "Everything" : nil
            root.everythingButton.isEnabled = proactive && inputs.everythingBlocked == nil
            root.everythingButton.toolTip = inputs.everythingBlocked ?? Self.everythingTip
            root.needsLayout = true
        }

        // Empty state and count.
        let tooShort = !inputs.query.isEmpty && inputs.query.count < minQueryLength && inputs.filterText.isEmpty
        if displayed.isEmpty {
            root.emptyLabel.stringValue = tooShort
                ? "Type \(minQueryLength) or more characters to search"
                : (inputs.defaultList || inputs.searching ? "" : "No results")
            root.emptyLabel.isHidden = root.emptyLabel.stringValue.isEmpty || inputs.fieldOnly
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
        let view = AnyView(FilePreviewPanel(paths: paths, plain: true))
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
            // From the field, past searches like the window's; from the list, the last result.
            if !listFocused, !SearchHistory.shared.entries.isEmpty {
                toggleSuggestions()
            } else {
                selectEdge(last: true)
            }
            return nil
        case 126 where mods == .command: // ⌘↑
            selectEdge(last: false)
            return nil
        case 36, 76: // Return
            if mods.isEmpty, suggestionsVisible {
                pickSuggestion(at: max(suggestionIndex, 0))
                return nil
            }
            // From the field, Return first settles the query, as in the window: it keeps the past search ↑ brought
            // back, or drops the ghost completion. Only then does it open the result.
            if mods.isEmpty, !listFocused, historyIndex >= 0 || root.completion != nil {
                historyIndex = -1
                ghostDismissed = true
                updateCompletion()
                return nil
            }
            if mods.isEmpty || mods == [.command, .shift], performReturn(modifiers: mods) {
                return nil
            }
        case 48 where mods == .control: // ⌃⇥
            switchToWindow()
            return nil
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
            case "s" where commandSSaves:
                saveQueryAsFilter()
                return nil
            case "/":
                toggleSyntaxReference()
                return nil
            case "x" where listFocused:
                // As in the window, where ⌘X runs a script unless the search field has the keyboard.
                showActionsMenu(.scripts)
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

    /// The bar starts over the compact field and springs to its size, fading in while the field fades out under it.
    private func grow(_ panel: NSPanel, outOf pill: NSPanel, to target: NSRect) {
        morphGeneration += 1
        let generation = morphGeneration
        morphing = true
        placingPanel = true
        // The bar covers the field within the first few frames, while it's still about the field's size.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.07
            panel.animator().alphaValue = 1
            pill.animator().alphaValue = 0
        }
        spring(panel, to: target) { [weak self] in
            guard let self, generation == morphGeneration else { return }
            morphing = false
            placingPanel = false
            pill.orderOut(nil)
            pill.alphaValue = 1
            refreshShadow()
            // Typing during the animation may have changed what the bar shows.
            fitPanelHeight()
        }
    }

    /// Moves the bar's frame along a spring, driven by the display, as NSAnimationContext only has curves: a start
    /// with no lag, a settle in about a quarter of a second and a half-percent overshoot.
    private func spring(_ panel: NSPanel, to target: NSRect, completion: @escaping () -> Void) {
        springLink?.invalidate()
        springFrom = panel.frame
        springTo = target
        springStart = CACurrentMediaTime()
        springCompletion = completion
        let link = panel.displayLink(target: self, selector: #selector(springStep(_:)))
        link.add(to: .main, forMode: .common)
        springLink = link
    }

    @objc private func springStep(_ link: CADisplayLink) {
        guard let panel else {
            link.invalidate()
            return
        }
        let t = CACurrentMediaTime() - springStart
        let done = t >= Self.springDuration
        let p = done ? 1 : Self.springProgress(t)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            (a + (b - a) * p).rounded()
        }
        let frame = done
            ? springTo
            : NSRect(
                x: mix(springFrom.minX, springTo.minX), y: mix(springFrom.minY, springTo.minY),
                width: mix(springFrom.width, springTo.width), height: mix(springFrom.height, springTo.height)
            )
        panel.setFrame(frame, display: true)
        guard done else { return }
        link.invalidate()
        springLink = nil
        let completion = springCompletion
        springCompletion = nil
        completion?()
    }

    /// The reverse of `grow`: the bar shrinks into the compact field's frame and fades out over it.
    private func shrink(_ panel: NSPanel) {
        let pill = ensurePill()
        applyPillLevel()
        pill.alphaValue = 0
        pill.orderFrontRegardless()
        morphGeneration += 1
        let generation = morphGeneration
        morphing = true
        placingPanel = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = Self.shrinkTiming
            panel.animator().setFrame(pill.frame, display: true)
            panel.animator().alphaValue = 0
            pill.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            mainAsync {
                guard let self, generation == self.morphGeneration else { return }
                self.morphing = false
                self.placingPanel = false
                panel.orderOut(nil)
                panel.alphaValue = 1
                pill.invalidateShadow()
            }
        }
    }

    private func showPill() {
        let panel = ensurePill()
        applyPillLevel()
        panel.orderFrontRegardless()
        followCursorDisplay()
        updateCursorFollowing()
        // The shadow follows the capsule's alpha, which only exists once it has drawn.
        DispatchQueue.main.async { panel.invalidateShadow() }
    }

    /// The compact field stays on the display with the cursor. It listens to the mouse only while the field is up and
    /// there's more than one display, so it costs nothing at rest, and moves half a second after the cursor reaches
    /// another display, so crossing one on the way doesn't drag it along.
    private func updateCursorFollowing() {
        let wanted = state == .compact && pinned && NSScreen.screens.count > 1
        guard wanted != !cursorMonitors.isEmpty else { return }
        if wanted {
            screenFrames = NSScreen.screens.map(\.frame)
            cursorScreenFrame = nil
            let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
                MainActor.assumeIsolated { self?.cursorMoved() }
            }
            let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
                MainActor.assumeIsolated { self?.cursorMoved() }
                return event
            }
            cursorMonitors = [global, local].compactMap(\.self)
        } else {
            cursorMonitors.forEach(NSEvent.removeMonitor)
            cursorMonitors = []
            followWork?.cancel()
            followWork = nil
        }
    }

    private func cursorMoved() {
        let mouse = NSEvent.mouseLocation
        if let frame = cursorScreenFrame, NSMouseInRect(mouse, frame, false) {
            return
        }
        cursorScreenFrame = screenFrames.first { NSMouseInRect(mouse, $0, false) }
        followWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.followCursorDisplay() }
        }
        followWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func followCursorDisplay() {
        let mouse = NSEvent.mouseLocation
        guard let pillPanel, let target = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) else { return }
        let pillFrame = pillPanel.frame
        let current = NSScreen.screens.first { $0.frame.contains(NSPoint(x: pillFrame.midX, y: pillFrame.midY)) }
        guard current?.frame != target.frame else { return }
        // The same spot in the other display's usable area, in one step: it leaves one display and shows on the other
        // in the same frame.
        let from = current?.visibleFrame ?? target.visibleFrame
        let to = target.visibleFrame
        let fx = from.width > pillFrame.width ? (pillFrame.minX - from.minX) / (from.width - pillFrame.width) : 0.5
        let fy = from.height > pillFrame.height ? (pillFrame.minY - from.minY) / (from.height - pillFrame.height) : 1
        let origin = NSPoint(
            x: (to.minX + min(max(fx, 0), 1) * (to.width - pillFrame.width)).rounded(),
            y: (to.minY + min(max(fy, 0), 1) * (to.height - pillFrame.height)).rounded()
        )
        pillPanel.setFrameOrigin(origin)
        Defaults[.searchBarPillOrigin] = [origin.x, origin.y]
    }

    @discardableResult
    private func ensurePill() -> SearchBarPillPanel {
        if let pillPanel {
            return pillPanel
        }
        let hotkey = pillHotkey
        let size = SearchBarPillView.fittingSize(hotkey: hotkey)
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
        view.hotkey = hotkey
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

    private func updatePillHotkey() {
        guard let pillPanel, let pillView else { return }
        let hotkey = pillHotkey
        guard pillView.hotkey != hotkey else { return }
        pillView.hotkey = hotkey
        // Grown or shrunk from its left edge, then kept on its display.
        var frame = NSRect(origin: pillPanel.frame.origin, size: SearchBarPillView.fittingSize(hotkey: hotkey))
        if let area = (pillPanel.screen ?? NSScreen.main)?.visibleFrame {
            frame = clamp(frame, in: area)
        }
        pillPanel.setFrame(frame, display: true)
        pillPanel.invalidateShadow()
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
        let area = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return Self.defaultPillOrigin(size: size, in: area)
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
            updateCursorFollowing()
        }
    }

    /// Keeps the compact field on a display: one that was unplugged takes it back to the default spot.
    private func screensChanged() {
        screenFrames = NSScreen.screens.map(\.frame)
        cursorScreenFrame = nil
        updateCursorFollowing()
        guard let pillPanel else { return }
        let frame = pillPanel.frame
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            pillPanel.setFrameOrigin(storedPillOrigin(size: frame.size))
        }
    }

    private func restyle() {
        pillView?.restyle()
        root?.background.rebuild()
        suggestionsPanel?.background.rebuild()
    }

    private func fontScaleChanged() {
        SearchBarRowStyle.shared.rebuildIfNeeded()
        guard let root else { return }
        root.applyFonts()
        results.tableView.rowHeight = SearchBarRowStyle.shared.rowHeight
        results.tableView.reloadData()
        root.hintBar.needsDisplay = true
    }

    private func updateCompletion() {
        guard let root else { return }
        let query = root.field.stringValue
        let completion = inlineSuggestion.map { suggestion in
            let suffix = String(suggestion.dropFirst(query.count))
            var hints = ["tab to complete"]
            if suffix.contains(" ") {
                hints.append("→ word by word")
            }
            hints.append("⌘↓ suggestions")
            return SearchBarCompletion(typed: query, suffix: suffix, hints: hints)
        }
        root.completion = completion
        // Return and ⇥ follow the ghost and the history, and so do their hints.
        updateHints()
        updateSuggestions()
    }

    private func toggleSuggestions() {
        suggestionsShown.toggle()
        suggestionIndex = -1
        updateSuggestions()
    }

    private func hideSuggestions() {
        suggestionsShown = false
        suggestionIndex = -1
        updateSuggestions()
    }

    private func highlightSuggestion(_ index: Int) {
        suggestionIndex = index
        suggestionsPanel?.list.highlighted = index
    }

    private func pickSuggestion(at index: Int) {
        guard let items = suggestionsPanel?.list.items, items.indices.contains(index) else { return }
        hideSuggestions()
        complete(to: items[index])
    }

    /// Puts `text` in the field as if typed, with the caret at its end.
    private func complete(to text: String) {
        guard let root else { return }
        root.field.stringValue = text
        if root.field.currentEditor() == nil {
            panel?.makeFirstResponder(root.field)
        }
        root.field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        queryEdited(text)
    }

    /// → at the end of the query takes the ghost completion's next word; anywhere else it moves the caret.
    private func completeNextWord() -> Bool {
        guard let root, let suggestion = inlineSuggestion, let editor = root.field.currentEditor() as? NSTextView else { return false }
        let selected = editor.selectedRange()
        guard selected.length == 0, selected.location == (editor.string as NSString).length else { return false }
        let query = root.field.stringValue
        let suffix = suggestion.dropFirst(query.count)
        var end = suffix.startIndex
        while end < suffix.endIndex, suffix[end] == " " {
            end = suffix.index(after: end)
        }
        while end < suffix.endIndex, suffix[end] != " " {
            end = suffix.index(after: end)
        }
        complete(to: query + suffix[suffix.startIndex ..< end])
        return true
    }

    private func updateSuggestions() {
        let items = suggestionsShown && isExpanded && historyIndex < 0 && !listFocused ? historySuggestions : []
        guard let panel, !items.isEmpty else {
            if let list = suggestionsPanel, list.isVisible {
                list.parent?.removeChildWindow(list)
                list.orderOut(nil)
            }
            return
        }
        let list = suggestionsPanel ?? makeSuggestionsPanel()
        if suggestionIndex >= items.count {
            suggestionIndex = -1
        }
        list.list.items = items
        list.list.highlighted = suggestionIndex
        positionSuggestions()
        if !list.isVisible {
            list.background.rebuild()
            list.level = panel.level
            list.collectionBehavior = panel.collectionBehavior
            panel.addChildWindow(list, ordered: .above)
            list.orderFront(nil)
            // Its shadow follows the rounded background, which only exists once it has drawn.
            DispatchQueue.main.async { list.invalidateShadow() }
        }
    }

    private func makeSuggestionsPanel() -> SearchBarSuggestionsPanel {
        let list = SearchBarSuggestionsPanel()
        list.list.onPick = { [weak self] index in
            self?.pickSuggestion(at: index)
        }
        list.list.onHover = { [weak self] index in
            self?.highlightSuggestion(index)
        }
        suggestionsPanel = list
        return list
    }

    /// Under the search row, with its text lined up with the query's.
    private func positionSuggestions() {
        guard let panel, let root, let list = suggestionsPanel else { return }
        let field = panel.convertToScreen(root.convert(root.field.frame, to: nil))
        let rowBottom = panel.convertPoint(toScreen: root.convert(NSPoint(x: 0, y: min(root.searchRowHeight, root.bounds.height)), to: nil)).y
        let x = field.minX + 2 - SearchBarSuggestionsView.textInset
        let size = list.list.fittingSize(maxWidth: max(panel.frame.maxX - 12 - x, 220))
        let frame = NSRect(x: x, y: rowBottom - size.height + 2, width: size.width, height: size.height)
        guard frame != list.frame else { return }
        list.setFrame(frame, display: true)
        if list.isVisible {
            DispatchQueue.main.async { list.invalidateShadow() }
        }
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
