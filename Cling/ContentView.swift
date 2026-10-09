//
//  ContentView.swift
//  Cling
//
//  Created by Alin Panaitiu on 03.02.2025.
//

import AppKit
import ClopSDK
import Defaults
import KeyboardShortcuts
import Lowtech
import LowtechPro
import OSLog
import QuickLook
import SwiftUI
import System
import UniformTypeIdentifiers

private let log = Logger(subsystem: clingSubsystem, category: "ContentView")

/// Returns true if an IME (CJK input method, etc.) is currently composing text
/// in the focused responder. Key handlers should defer to the IME in that case.
@inline(__always)
func isIMEComposing() -> Bool {
    if let client = NSTextInputContext.current?.client, client.hasMarkedText() {
        return true
    }
    if let responder = NSApp.keyWindow?.firstResponder as? NSTextInputClient,
       responder.hasMarkedText()
    {
        return true
    }
    return false
}

extension Int {
    var humanSize: String {
        switch self {
        case 0 ..< 1000:
            return "\(self)  B"
        case 0 ..< 1_000_000:
            let num = self / 1000
            return "\(num) KB"
        case 0 ..< 1_000_000_000:
            let num = d / 1_000_000
            // `String(format:)` for a decimal point whatever the region writes; `str(decimals:)` follows the region.
            return "\(num < 10 ? String(format: "%.1f", num) : num.intround.s) MB"
        default:
            let num = d / 1_000_000_000
            return "\(num < 10 ? String(format: "%.1f", num) : num.intround.s) GB"
        }
    }
}

let dateFormat = Date.FormatStyle
    .dateTime.year(.padded(4)).month().day(.twoDigits)
    .hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits)

// MARK: - FocusedField

enum FocusedField {
    case search, list, stash, openWith, executeScript, indexBrowser
}

// MARK: - RowToggleTap

/// Detects a double-tap of the configured modifier key (pressed alone, released, pressed alone
/// again within the window) and flips the master toolbar-rows visibility. Any other key or
/// modifier in between cancels the gesture, so normal shortcuts never trigger it.
@MainActor
enum RowToggleTap {
    static func handle(_ event: NSEvent) {
        guard let targetFlag = Defaults[.rowsToggleModifier].flag else { return }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == targetFlag {
            pressedAlone = true
        } else if mods.isEmpty {
            guard pressedAlone else { return }
            pressedAlone = false
            if event.timestamp - lastTapAt < 0.35 {
                lastTapAt = 0
                Defaults[.toolbarRowsHidden].toggle()
            } else {
                lastTapAt = event.timestamp
            }
        } else {
            cancel()
        }
    }

    static func cancel() {
        pressedAlone = false
        lastTapAt = 0
    }

    private static var lastTapAt: TimeInterval = 0
    private static var pressedAlone = false
}

// MARK: - ContentView

struct ContentView: View {
    @Environment(\.dismiss) var dismiss
    @State var wm = WM

    var pinButton: some View {
        Button(action: {
            wm.pinned.toggle()
            NSApp.windows.first { $0.identifier?.rawValue == "main" }?.level = wm.pinned ? .floating : .normal
        }) {
            HStack(spacing: 1) {
                Image(systemName: wm.pinned ? "pin.circle.fill" : "pin.circle")
                Text(wm.pinned ? "Unpin" : "Pin")
            }
            .padding(4)
            .contentShape(Rectangle())
        }
        .font(.scaled(10, .chrome, design: .rounded))
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(pinHovering ? 1 : 0.4)
        .onHover { pinHovering = $0 }
        .focusable(false)
        .help(wm.pinned ? "Unpin window (⌘.)" : "Pin window to keep it on top of other windows (⌘.)")
    }
    var quitButton: some View {
        Button(action: {
            NSApp.terminate(nil)
        }) {
            HStack(spacing: 1) {
                Image(systemName: "xmark.circle.fill")
                Text("Quit")
            }
            .padding(4)
            .contentShape(Rectangle())
        }
        .font(.scaled(10, .chrome, design: .rounded))
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(quitHovering ? 1 : 0.4)
        .onHover { quitHovering = $0 }
        .focusable(false)
        .help("Quit Cling (⌘Q)")
    }
    var body: some View {
        let _ = appearance.useGlass
        // Track selection so the QuickLook panel re-presents even when `items`
        // is unchanged (the manual binding closures don't register observation).
        let _ = quickLook.selection
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 6) {
                pinButton
                quitButton
            }
            .padding(.top, 10)
            .padding(.trailing, 12)
            content
                .onAppear {
                    focused = .search
                    mainAsyncAfter(ms: 100) {
                        focused = .search
                    }
                    cmdDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                        // Local monitors see every window's keys, including ⌘↓ typed in a sheet's field.
                        guard event.window === AppDelegate.shared.mainWindow else { return event }
                        if event.modifierFlags.contains(.command),
                           event.keyCode == 125, // down arrow
                           focused == .search,
                           !SearchHistory.shared.entries.isEmpty
                        {
                            showSuggestionsList.toggle()
                            suggestionIndex = -1
                            return nil
                        }
                        if event.keyCode == 53, // escape
                           showSuggestionsList
                        {
                            // Let IME consume Esc to cancel composition.
                            if let responder = event.window?.firstResponder as? NSTextInputClient,
                               responder.hasMarkedText()
                            {
                                return event
                            }
                            showSuggestionsList = false
                            suggestionIndex = -1
                            return nil
                        }
                        return event
                    }
                    installContentShortcutMonitor()
                    installTableClickMonitor()
                }
                .onDisappear {
                    if let cmdDownMonitor {
                        NSEvent.removeMonitor(cmdDownMonitor)
                    }
                    cmdDownMonitor = nil
                    removeContentShortcutMonitor()
                    removeTableClickMonitor()
                }
                .onChange(of: focused) {
                    if !fuzzy.hasFullDiskAccess {
                        focused = nil
                    }
                }
                .onChange(of: wm.mainWindowActive) { _, active in
                    if active {
                        focused = .search
                    }
                }
                .onChange(of: wm.selectionResetToken) {
                    // Back after a long time away: the row selected in the previous session is
                    // stale, so ↓ from the search field should land on the first result again.
                    // Clearing lastSelectionQuery also stops the next results update from
                    // restoring the old ids.
                    lastSelectionQuery = nil
                    selectFirstResult()
                    scrollResultsTableToTop()
                }
                .disabled(!wm.mainWindowActive)
                .quickLookPreview(
                    Binding(get: { quickLook.selection }, set: { quickLook.selection = $0 }),
                    in: quickLook.items
                )
        }
        // A wash in the scope's colour, so being narrowed to something is visible before you read
        // the icon. Deliberately a plain colour and not a Material: a Material blurs the desktop
        // behind the window rather than the surface it sits on, which on the glass window style
        // would pick up whatever wallpaper happens to be back there.
        .background(scopeTint)
    }

    var content: some View {
        ZStack(alignment: .topLeading) {
            VStack {
                searchSection
                    .onKeyPress(
                        keys: Set(
                            folderFilters.compactMap(\.keyEquivalent) +
                                quickFilters.compactMap(\.keyEquivalent) +
                                (fuzzy.enabledVolumes.isEmpty ? [] : (0 ... fuzzy.enabledVolumes.count).compactMap(\.s.keyEquivalent)) +
                                (fuzzy.offersAllDrivesFilter ? [KeyEquivalent(ALL_DRIVES_KEY)] : []) +
                                [.escape]
                        ),
                        phases: [.down], action: handleFilterKeyPress
                    )

                middleRow

                if showingResults {
                    // No top padding when every row is hidden: ActionButtons stays mounted
                    // (it hosts the shortcut monitor and sheets) but occupies zero height,
                    // so the table gets the space.
                    actionButtonRows
                        .padding(.top, anyToolbarRowVisible ? 6 : 0)
                }
                StatusBarView().hfill(.leading).padding(.top, 10)
            }

            historySuggestionsOverlay
        }
        .overlay(alignment: .bottom) {
            if !coachmarkShown, onboardingCompleted, showActionRow, showingResults {
                ShortcutCoachmark()
            }
        }
        .padding(.top, 24)
        .padding([.leading, .trailing])
        .padding(.bottom, 4)
        .onChange(of: optionHeld) { _, held in
            optionDwell?.cancel()
            guard held else {
                if optionDwelled {
                    withAnimation(.easeOut(duration: 0.12)) { optionDwelled = false }
                }
                return
            }
            optionDwell = Task {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.14)) { optionDwelled = true }
            }
        }
        .alert("File not found", isPresented: Binding(get: { pathNotFoundMessage != nil }, set: {
            if !$0 {
                pathNotFoundMessage = nil
            }
        })) {
            Button("OK") { pathNotFoundMessage = nil }
        } message: {
            Text(pathNotFoundMessage ?? "")
        }
        .sheet(item: Binding(get: { fuzzy.openWithGroupRequest }, set: { fuzzy.openWithGroupRequest = $0 })) { req in
            OpenWithPickerView(fileURLs: req.files, initialApps: req.apps)
                .font(.medium(13))
        }
        .if(!fuzzy.hasFullDiskAccess) { view in
            view.overlay(fullDiskAccessOverlay)
        }
    }

    private static let placeholderExamplesBase = [
        "Search",
        "Example: **`invoice .pdf`** *(finds PDF invoices)*",
        "Example: **`.png .jpg`** *(filters common image formats)*",
        "Example: **`in:~/Downloads .dmg`** *(finds downloaded DMGs)*",
        "Example: **`contract .docx`** *(shows contracts in Word format)*",
        "Example: **`depth:1 in:~/Documents`** *(searches Documents folder non-recursively)*",
        "Example: **`config/ .toml .yaml`** *(finds configuration files)*",
        "Example: **`.mkv .mp4 in:~/Movies`** *(shows common video files)*",
        "Example: **`.md in:~/Notes`** *(finds Markdown notes)*",
        "Example: **`.js !node_modules/`** *(code, without dependencies)*",
        "Example: **`report !draft`** *(reports, skipping drafts)*",
        "Example: **`.png !screenshot`** *(PNGs that aren't screenshots)*",
        "Example: **`notes$`** *(names ending in notes)*",
        "Example: **`brew python`** *(shows installed Python versions)*",
    ]

    /// The stash, pinned above the results table so it stays visible while the results scroll.
    /// A separate table (same columns, same selection binding, same context menu) is the only way
    /// to keep rows permanently on screen: NSTableView can float group-row headers, not rows.
    /// Space the results panel keeps for itself before the stash is allowed to grow; the stash
    /// shrinks (and scrolls internally) first, so a short window never starves the results table.
    private static let resultsReservedHeight: CGFloat = 240
    /// Header chrome and the table's own vertical padding around the stash rows (28 + 5 + 10,
    /// measured). Only the rows follow the text size, this part doesn't.
    private static let stashChromeHeight: CGFloat = 43

    private static let driveColumnID = "drive"

    @State private var pinHovering = false

    @State private var quitHovering = false

    @State private var quickLook = QLP

    @FocusState private var focused: FocusedField?

    @State private var appManager = APP_MANAGER
    @State private var renamedPaths: [FilePath]? = nil
    @State private var fuzzy: FuzzyClient = FUZZY
    @State private var everything = EVERYTHING
    @State private var resultColumns = TableColumnCustomization<FilePath>()
    @State private var stash: StashManager = STASH
    @ObservedObject private var km = KM
    @State private var sortHintsVisible = false
    /// Option held past the dwell, which brings the filter cards up over the action rows. A tap
    /// means nothing, so typing an accent (⌥e) or firing an ⌥ chord doesn't flash the row.
    @State private var optionDwelled = false
    @State private var optionDwell: Task<Void, Never>?
    @State private var appearance = AM
    @State private var scriptManager: ScriptManager = SM
    @State private var selectedResults = Set<FilePath>()
    @State private var selectedResultIDs = Set<String>()

    @State private var isAddingQuickFilter = false
    @State private var filterDraft = QuickFilterDraft()

    @State private var cmdDownMonitor: Any?
    @State private var contentShortcutMonitor: Any?
    @State private var tableClickMonitor: Any?

    @State private var showFullHistory = false
    @State private var showSyntaxHelp = false
    // Right-arrow drills into a folder (query becomes `in:<folder>`); left-arrow walks back out.
    @State private var queryDrillStack: [String] = []
    @State private var lastDrillSetQuery: String?
    /// The file → was pressed on, selected again once its folder's results come in.
    @State private var drilledFile: (query: String, path: FilePath)?
    @State private var showNeedsProPopover = false
    @State private var isAddingFolderFilter = false
    @State private var folderFilterID = ""
    @State private var folderFilterFolders: [FilePath] = []
    @State private var folderFilterKey: SauceKey = .escape

    @State private var historyIndex = -1
    @State private var querySaved = "" // query before navigating history
    @State private var navigatingHistory = false
    @State private var showHistorySuggestions = false
    @State private var imeComposing = false
    @State private var showSuggestionsList = false
    @State private var suggestionIndex = -1

    @State private var placeholderHint = "Search"
    @State private var placeholderIndex = 0
    @State private var windowManager = WM
    @State private var sortOrder = [KeyPathComparator(\FilePath.string)]

    @State private var excludeRequest: ExcludeSheetRequest?

    @State private var liveChangeSortOrder = [KeyPathComparator(\FuzzyClient.IndexChange.date, order: .reverse)]
    /// The list as it was when Pause was pressed, shown instead of the live one until Resume, so rows don't move under
    /// a selection.
    @State private var pausedLiveChanges: [FuzzyClient.IndexChange]?
    @State private var liveShowHidden = false
    @State private var runHistorySelection = Set<String>()
    @State private var liveIndexSelection = Set<UUID>()
    @State private var pathNotFoundMessage: String?
    @State private var runHistorySortOrder = [KeyPathComparator(\RunHistoryRow.count, order: .reverse)]

    /// Keep the user's selection when the results list mutates for reasons other
    /// than a new query (file watching, reindexing). Only drop ids that vanished,
    /// and fall back to the first row if the whole selection is gone.
    @State private var lastSelectionQuery: String? = nil

    @Environment(\.colorScheme) private var colorScheme

    /// Decoded once per change: a `@Default` read decodes the whole JSON array, and the filter keys below are read on
    /// every evaluation of the body.
    @State private var defaults = DEFAULTS_CACHE

    @Default(.hiddenLiveEventPaths) private var hiddenLiveEventPaths

    @Default(.fontScale) private var fontScale
    @Default(.minQueryLength) private var minQueryLength
    @Default(.filterWindowTintStrength) private var filterWindowTintStrength

    @Default(.showFilePreview) private var showFilePreview

    @Default(.showOpenWithRow) private var showOpenWithRow
    @Default(.showScriptRow) private var showScriptRow
    @Default(.toolbarRowsHidden) private var toolbarRowsHidden
    @Default(.toolbarRowBackground) private var toolbarRowBackground
    @Default(.showActionRow) private var showActionRow
    @Default(.shortcutsCoachmarkShown) private var coachmarkShown
    @Default(.onboardingCompleted) private var onboardingCompleted

    @Default(.triggerKeys) private var triggerKeys
    @Default(.showAppKey) private var showAppKey
    @Default(.showSearchHints) private var showSearchHints
    @Default(.searchHintsManuallyEnabled) private var searchHintsManuallyEnabled
    @Default(.searchHintsFirstShownAt) private var searchHintsFirstShownAt

    private var folderFilters: [FolderFilter] {
        defaults.folderFilters
    }
    private var quickFilters: [QuickFilter] {
        defaults.quickFilters
    }

    /// Re-read through `fontScale` above so the whole window redraws when the size changes.
    private var rowHeight: CGFloat {
        FontScale.length(24)
    }
    private var iconSide: CGFloat {
        FontScale.length(16)
    }

    /// Whether the normal results table (not a log/history/live view) is showing,
    /// the only context where the file preview panel makes sense.
    private var isShowingResultsTable: Bool {
        !fuzzy.showLiveIndex && !fuzzy.showActivityLog && !fuzzy.showRunHistory && !fuzzy.showIndexBrowser && !showFullHistory
    }

    /// Files whose previews are shown: the selected results in table order, falling
    /// back to the first row so the panel is never blank when results exist.
    private var previewPaths: [FilePath] {
        let selected = results.filter { selectedResults.contains($0) }
        if !selected.isEmpty {
            return selected
        }
        if let first = results.first {
            return [first]
        }
        return []
    }

    private var previewWidth: CGFloat {
        WindowManager.previewWidth(forWindowWidth: wm.size.width)
    }

    private var filterSubtitle: String? {
        fuzzy.filterLine
    }

    private var showingResults: Bool {
        !fuzzy.showLiveIndex && !fuzzy.showActivityLog && !fuzzy.showIndexBrowser
    }

    /// History entries matching the query, for the ⌘↓ suggestions list.
    private var historySuggestions: [String] {
        let trimmed = fuzzy.query.trimmingCharacters(in: .whitespaces)
        return SearchHistory.shared.suggestions(for: fuzzy.query)
            .filter { $0.trimmingCharacters(in: .whitespaces) != trimmed }
            .prefix(8).map { $0 }
    }

    /// Best history entry that the current query is a prefix of, used for the inline ghost completion.
    private var inlineSuggestion: String? {
        guard focused == .search, !imeComposing, historyIndex < 0, showHistorySuggestions else { return nil }
        let q = fuzzy.query
        guard !q.isEmpty else { return nil }
        let lower = q.lowercased()
        return SearchHistory.shared.entries.first { entry in
            entry.count > q.count && entry.lowercased().hasPrefix(lower)
        }
    }

    /// The part of `inlineSuggestion` after what the user has already typed.
    private var inlineSuffix: String? {
        guard let s = inlineSuggestion else { return nil }
        return String(s.dropFirst(fuzzy.query.count))
    }

    private var shouldCyclePlaceholder: Bool {
        showSearchHints && fuzzy.query.isEmpty && wm.mainWindowActive
    }

    /// The table is showing the default list (recents or run history) rather than the answer to a
    /// search. A filter with no typed query still counts as a search: it has narrowed to something.
    private var showingDefaultResults: Bool {
        fuzzy.noQuery && fuzzy.volumeFilter == nil
    }

    private var results: [FilePath] {
        showingDefaultResults
            ? (fuzzy.sortField == .score ? fuzzy.recents : fuzzy.sortedRecents)
            : fuzzy.results
    }

    /// Results shown in the main table: stashed files live in the pinned stash table above,
    /// so they're deduplicated out of the scrolling list.
    private var visibleResults: [FilePath] {
        stash.files.isEmpty ? results : results.filter { !stash.contains($0) }
    }

    /// Everything on screen in display order: pinned stash rows first, then the results.
    private var displayedResults: [FilePath] {
        stash.files.isEmpty ? results : stash.files + visibleResults
    }

    /// Which table the keyboard should land in when leaving the search field: follow the
    /// current selection into the stash if that's where it lives.
    private var tableFocusTarget: FocusedField {
        if fuzzy.showIndexBrowser {
            return .indexBrowser
        }
        guard !stash.files.isEmpty, let id = selectedResultIDs.first,
              stash.files.contains(where: { $0.string == id })
        else { return .list }
        return .stash
    }

    private var sortedLiveChanges: [FuzzyClient.IndexChange] {
        let q = fuzzy.query.trimmingCharacters(in: .whitespaces).lowercased()
        let changes = pausedLiveChanges ?? fuzzy.liveIndexChanges
        let hidden = PathMatcher(hiddenLiveEventPaths)
        let excluded = PathMatcher(fuzzy.excludedPaths)
        func listed(_ change: FuzzyClient.IndexChange) -> Bool {
            !excluded.contains(change.path) && (liveShowHidden || !hidden.contains(change.path))
                && (q.isEmpty || change.path.lowercased().contains(q))
        }
        // No query: show the most recent slice, counted after hiding, so a log written every second can't push
        // everything else out of it. With a query: search the whole deduplicated history (bounded, so a change from
        // a day ago is still findable), then cap the rendered rows.
        var filtered: [FuzzyClient.IndexChange] = []
        if q.isEmpty {
            for change in changes.reversed() where listed(change) {
                filtered.append(change)
                if filtered.count == 2000 {
                    break
                }
            }
        } else {
            filtered = changes.filter(listed)
        }
        let afterBlock: [FuzzyClient.IndexChange] = if fuzzy.liveChangesIndexedOnly {
            filtered.filter { change in
                !isPathBlocked(change.path) && !(change.path.hasPrefix(HOME.string) && change.path.isIgnored(in: fsignoreString))
            }
        } else {
            filtered
        }
        return Array(afterBlock.sorted(using: liveChangeSortOrder).prefix(2000))
    }

    private var runHistoryRows: [RunHistoryRow] {
        RH.entries.compactMap { path, entry in
            guard entry.count > 0 else { return nil }
            let fp = FilePath(path)
            return RunHistoryRow(
                path: fp,
                name: fp.lastComponent?.string ?? path,
                dir: fp.removingLastComponent().string,
                count: entry.count,
                lastRun: entry.lastRun
            )
        }.sorted { $0.count > $1.count }
    }

    private var sortedRunHistory: [RunHistoryRow] {
        runHistoryRows.sorted(using: runHistorySortOrder)
    }

    private var iconColumn: some TableColumnContent<FilePath, KeyPathComparator<FilePath>> {
        TableColumn("", value: \.string) { path in
            Image(nsImage: path.memoz.icon).resizable().frame(width: iconSide, height: iconSide)
                .accessibilityHidden(true)
        }.width(FontScale.length(20))
    }

    private var nameColumn: some TableColumnContent<FilePath, KeyPathComparator<FilePath>> {
        TableColumn("Name", value: \.name.string) { path in
            // .help sets the cell's NSView tooltip (cheap, no layout pass), so the truncated middle is
            // revealed on hover without the per-row measuring that would slow scrolling.
            let name = path.name.string
            Text(name).font(.scaled(12)).lineLimit(1).truncationMode(.middle).help(name)
        }.width(min: FontScale.length(100), ideal: FontScale.length(200))
    }

    /// Which external drive each result is on, while results can come from more than one: hidden by default and shown
    /// through `resultColumns`, since a column can't be left out conditionally before macOS 14.4. Sorts by path, which
    /// keeps each drive's files together.
    private var driveColumn: some TableColumnContent<FilePath, KeyPathComparator<FilePath>> {
        TableColumn("Drive", value: \.dir.string) { path in
            if let drive = fuzzy.externalDrive(of: path) {
                Label(drive.name, systemImage: drive.connected ? "externaldrive.fill" : "externaldrive.badge.xmark")
                    .font(.scaled(12)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(drive.connected ? .primary : .tertiary)
                    .help(drive.connected ? drive.name : "\(drive.name), disconnected")
            }
        }
        .width(min: FontScale.length(70), ideal: FontScale.length(110))
        .customizationID(Self.driveColumnID)
        .defaultVisibility(.hidden)
    }

    /// Shown while results can come from more than one drive and some of them are on an external one.
    private var showsDriveColumn: Bool {
        fuzzy.resultsSpanDrives && visibleResults.contains { $0.string.hasPrefix("/Volumes/") }
    }

    private var pathColumn: some TableColumnContent<FilePath, KeyPathComparator<FilePath>> {
        TableColumn("Path", value: \.dir.string) { path in
            let dir = path.dir.shellString
            Text(dir).font(.scaled(12, design: .rounded)).tracking(-0.2).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).help(dir)
        }.width(min: FontScale.length(100), ideal: FontScale.length(300))
    }

    private var sizeColumn: some TableColumnContent<FilePath, KeyPathComparator<FilePath>> {
        TableColumn("Size", value: \.memoz.size) { path in
            Text(path.memoz.humanizedFileSize).font(.scaled(11, design: .monospaced)).lineLimit(1)
        }.width(min: FontScale.length(60), ideal: FontScale.length(80))
    }

    private var dateColumn: some TableColumnContent<FilePath, KeyPathComparator<FilePath>> {
        TableColumn("Date Modified", value: \.memoz.date) { path in
            let date = path.memoz.formattedModificationDate
            Text(date).font(.scaled(11, design: .monospaced)).lineLimit(1).help(date)
        }.width(min: FontScale.length(100), ideal: FontScale.length(160))
    }

    /// Whether any of the three toolbar rows is actually on screen. When none is, the rows
    /// area collapses to zero height and the results table takes the space.
    private var anyToolbarRowVisible: Bool {
        !toolbarRowsHidden && (showActionRow || showOpenWithRow || (proactive && showScriptRow))
    }

    /// Typed something, but not enough of it to search yet. Mirrors `FuzzyClient.emptyQuery`, and
    /// reads `query` rather than that property so the hint appears and clears as the user types:
    /// `emptyQuery` is `@ObservationIgnored`, so a view watching it would never be told it changed.
    private var queryTooShort: Bool {
        !fuzzy.query.isEmpty && fuzzy.query.count < minQueryLength
            && fuzzy.folderFilter == nil && fuzzy.quickFilter == nil
    }

    /// The filter cards replace the action rows on an untouched window, because something typed or a
    /// row picked means the person is past discovering and wants the actions back. Holding Option
    /// brings them back at any point: it is the key the cards are labelled with, so the same press
    /// that shows a filter's letter is the one that fires it.
    private var showFilterDiscovery: Bool {
        guard !toolbarRowsHidden else { return false }
        guard !optionDwelled else { return true }
        return fuzzy.query.isEmpty && selectedResults.isEmpty && fuzzy.folderFilter == nil
            && fuzzy.quickFilter == nil
    }

    private var optionHeld: Bool {
        km.optionOnly
    }

    /// SwiftUI routes a key typed into a sheet or popover up through the views that presented it, so an
    /// `.onKeyPress` sitting above a `.sheet` also sees every key typed into that sheet's fields (the
    /// Reindex excluded path sheet lost `/` to the focus-search handler this way). Handlers on views that
    /// present sheets must return `.ignored` unless the main window itself is key.
    private var mainWindowIsKey: Bool {
        NSApp.keyWindow === AppDelegate.shared.mainWindow
    }

    private var hiddenLiveEvents: PathMatcher {
        PathMatcher(hiddenLiveEventPaths)
    }

    /// The selected rows' paths, each once.
    private var selectedLivePaths: [String] {
        sortedLiveChanges.filter { liveIndexSelection.contains($0.id) }.map(\.path).uniqued
    }

    /// Nothing at all while searching everything, so the tint itself carries the signal. Two
    /// filters at once give a gradient instead of a flat wash, so the window says both.
    @ViewBuilder private var scopeTint: some View {
        if filterWindowTintStrength > 0, let wash = fuzzy.scopeWash {
            let dark = colorScheme == .dark
            LinearGradient(
                stops: FilterColor.washStops(top: wash.top, bottom: wash.bottom, dark: dark),
                startPoint: .top,
                endPoint: .bottom
            )
            .opacity(FilterColor.tintOpacity(dark: dark) * filterWindowTintStrength)
            .animation(.easeOut(duration: 0.18), value: wash.top)
            .animation(.easeOut(duration: 0.18), value: wash.bottom)
            .ignoresSafeArea()
        }
    }

    /// The results/index table next to the optional file preview panel. The
    /// preview steals width from the table instead of growing the window.
    private var middleRow: some View {
        HStack(spacing: 10) {
            middleSection
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Here rather than on one of the lists, so every list can ask for it: the live changes list too.
                .onReceive(NotificationCenter.default.publisher(for: .clingRequestExcludeSheet)) { notif in
                    guard let paths = notif.object as? [FilePath], !paths.isEmpty else { return }
                    excludeRequest = ExcludeSheetRequest(paths: paths)
                }
                .sheet(item: $excludeRequest) { request in
                    ExcludeFromIndexSheet(paths: request.paths)
                        .frame(width: 600, height: 540)
                }

            if showFilePreview, isShowingResultsTable {
                FilePreviewPanel(paths: previewPaths)
                    .frame(width: previewWidth)
                    .raisedPanel()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: showFilePreview)
    }

    @ViewBuilder
    private var middleSection: some View {
        if fuzzy.showLiveIndex {
            VStack(spacing: 0) {
                HStack {
                    if !liveIndexSelection.isEmpty {
                        liveSelectionActions
                            .padding(.leading, 8)
                    }
                    Spacer()
                    Button {
                        pausedLiveChanges = pausedLiveChanges == nil ? fuzzy.liveIndexChanges : nil
                    } label: {
                        Label(pausedLiveChanges == nil ? "Pause" : "Resume", systemImage: pausedLiveChanges == nil ? "pause.fill" : "play.fill")
                    }
                    .controlSize(.mini)
                    .font(.system(size: 10))
                    .help("Freezes the list, the index keeps updating")
                    if !hiddenLiveEventPaths.isEmpty {
                        Toggle("Show hidden", isOn: $liveShowHidden)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            // A mini switch reaches AX unnamed.
                            .accessibilityLabel("Show hidden")
                    }
                    Button("Run live index compaction") { fuzzy.compactLiveChangesManually() }
                        .controlSize(.mini)
                        .font(.system(size: 10))
                        .disabled(fuzzy.liveIndexChanges.isEmpty)
                        .help("Collapse duplicate events, keeping the latest change per file")
                        .padding(.vertical, 4)
                    Toggle("Indexed only", isOn: $fuzzy.liveChangesIndexedOnly)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Indexed only")
                        .padding(.trailing, 8).padding(.vertical, 4)
                }
                liveIndexTable
            }
            .raisedPanel()
        } else if fuzzy.showIndexBrowser {
            IndexBrowserView(focused: $focused)
        } else if fuzzy.showActivityLog {
            activityLogList
        } else if fuzzy.showRunHistory {
            runHistoryTable
                .raisedPanel()
        } else if showFullHistory {
            fullHistoryList
        } else {
            resultsListWithKeys
                .overlay {
                    if let volume = fuzzy.volumeFilter, fuzzy.volumesIndexing.contains(volume) {
                        volumeIndexingOverlay(volume)
                    }
                }
        }
    }

    private var activityLogList: some View {
        List {
            ForEach(fuzzy.ongoingOperationsList, id: \.key) { op in
                Button {
                    if op.key.hasPrefix("scope:") {
                        fuzzy.cancelScopeIndexing()
                    } else if op.key.hasPrefix("volume:") {
                        let path = String(op.key.dropFirst("volume:".count))
                        fuzzy.cancelVolumeIndexing(volume: FilePath(path))
                    } else {
                        fuzzy.cancelAllIndexing()
                    }
                } label: {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(op.message)
                            .font(.scaled(11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            ForEach(fuzzy.activityLog.reversed()) { entry in
                HStack {
                    Text(entry.message)
                        .font(.scaled(11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                    Spacer()
                    if let ms = entry.durationMs {
                        Text(ms >= 1000 ? String(format: "%.1fs", ms / 1000) : String(format: "%.0fms", ms))
                            .font(.scaled(9, .chrome, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 4)
                    }
                    Text(entry.date.formatted(.dateTime.hour().minute().second()))
                        .font(.scaled(9, .chrome, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .raisedPanel()
    }

    private var fullHistoryList: some View {
        VStack(spacing: 0) {
            List(SearchHistory.shared.entries, id: \.self) { entry in
                HStack {
                    Button(action: {
                        fuzzy.query = entry
                        showFullHistory = false
                        focused = .search
                    }) {
                        Text(entry)
                            .font(.scaled(12))
                            .lineLimit(1)
                            .hfill(.leading)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button(action: {
                        SearchHistory.shared.remove(entry)
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            if !SearchHistory.shared.entries.isEmpty {
                HStack {
                    Spacer()
                    Button("Clear All") {
                        SearchHistory.shared.clearAll()
                        showFullHistory = false
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
        }
        .raisedPanel()
    }

    private var resultsListWithKeys: some View {
        resultsList
            .onKeyPress("/", phases: [.down]) { keyPress in
                guard keyPress.modifiers.isEmpty, mainWindowIsKey else { return .ignored }
                focused = .search
                return .handled
            }
            .onKeyPress(.space) {
                guard mainWindowIsKey, focused == .list || focused == .stash else {
                    return .ignored
                }
                if !fuzzy.query.isEmpty {
                    SearchHistory.shared.commit(fuzzy.query)
                }
                QLP.present(
                    urls: selectedResults.count > 1 ? selectedResults.map(\.url) : displayedResults.map(\.url),
                    selectedItemIndex: selectedResults.count == 1 ? (displayedResults.firstIndex(of: selectedResults.first!) ?? 0) : 0
                )
                return .handled
            }
            .onKeyPress(
                keys: Set(
                    folderFilters.compactMap(\.keyEquivalent) +
                        quickFilters.compactMap(\.keyEquivalent) +
                        (fuzzy.enabledVolumes.isEmpty ? [] : (0 ... fuzzy.enabledVolumes.count).compactMap(\.s.keyEquivalent)) +
                        (fuzzy.offersAllDrivesFilter ? [KeyEquivalent(ALL_DRIVES_KEY)] : []) +
                        [.escape]
                ),
                phases: [.down], action: handleFilterKeyPress
            )
            .contextMenu(forSelectionType: String.self) { ids in
                RightClickMenu(
                    selectedResults: $selectedResults,
                    orderedResults: displayedResults,
                    contextPaths: displayedResults.filter { ids.contains($0.string) }
                )
                .onAppear {
                    if !ids.isEmpty, !ids.isSubset(of: selectedResultIDs) {
                        selectedResultIDs = ids
                    }
                }
            } primaryAction: { ids in
                let paths = displayedResults.filter { ids.contains($0.string) }
                RH.trackRun(Set(paths))
                if appManager.frontmostAppIsTerminal {
                    appManager.pasteToFrontmostApp(paths: paths, separator: " ", quoted: true)
                } else {
                    for path in paths {
                        NSWorkspace.shared.open(path.url)
                    }
                }
            }
    }

    private var actionButtonRows: some View {
        // Nothing typed and nothing selected means the action rows have no subject to act on, so the
        // space introduces the filters instead of showing buttons that would do nothing. The rows
        // stay mounted underneath at zero height: ActionButtons installs the action shortcut monitor
        // on appear and hosts the copy/move/send sheets, so dropping it while Option is held would
        // take every action shortcut down with it.
        ZStack(alignment: .topLeading) {
            ActionRowsStack(selectedResults: $selectedResults, selectedResultIDs: $selectedResultIDs, focused: $focused)
                .frame(height: showFilterDiscovery ? 0 : nil)
                .opacity(showFilterDiscovery ? 0 : 1)
                .allowsHitTesting(!showFilterDiscovery)
                .clipped()

            if showFilterDiscovery {
                FilterDiscoveryPanel()
                    .transition(.opacity)
            }
        }
        .modifier(ActionRowsBackground(visible: toolbarRowBackground && anyToolbarRowVisible))
    }

    @ViewBuilder
    private var historySuggestionsOverlay: some View {
        if showSuggestionsList, !historySuggestions.isEmpty, historyIndex < 0, showingResults {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(historySuggestions.enumerated()), id: \.offset) { i, suggestion in
                    Button(action: {
                        fuzzy.query = suggestion
                        showSuggestionsList = false
                    }) {
                        Text(suggestion)
                            .font(.system(size: 12))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .hfill(.leading)
                            .background(suggestionIndex >= 0 && i == suggestionIndex ? Color.accentColor.opacity(0.15) : Color.clear)
                    }
                    .buttonStyle(.plain)
                }
            }
            .hfill(.leading)
            .glassOrMaterial(cornerRadius: 6)
            .shadow(radius: 4)
            .padding(.top, 44)
            .padding(.leading, FilterPicker.iconWidth + 8)
            .allowsHitTesting(true)
        }
    }

    private var fullDiskAccessOverlay: some View {
        VStack {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle())
            Text("Waiting for Full Disk Access permissions to start indexing")
                .foregroundStyle(.secondary)
                .medium(20)
            Button("Open System Preferences") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }

            Text("Press **`\(triggerKeys.readableStr) + \(showAppKey.character)`** to show/hide Cling")
                .foregroundStyle(.secondary)
                .opacity(0.7)
                .padding(.top, 10)

        }
        .fill()
        .background(.thinMaterial)
    }

    private var searchSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if showingResults {
                    FilterPicker()
                        .help("Quick Filters: narrow down results without typing often used queries")
                }
                ZStack(alignment: .trailing) {
                    searchBar
                    searchBarTrailingButtons
                }
            }

            if showingResults, filterSubtitle != nil {
                filterRow.offset(y: -10)
            }
        }
        .sheet(isPresented: $isAddingQuickFilter, onDismiss: handleQuickFilterDismiss) {
            QuickFilterAddSheet(draft: $filterDraft)
        }
        .sheet(isPresented: $isAddingFolderFilter, onDismiss: handleFolderFilterDismiss) {
            FolderFilterAddSheet(id: $folderFilterID, folders: $folderFilterFolders, key: $folderFilterKey)
        }
    }

    private var filterRow: some View {
        HStack(spacing: 4) {
            if let subtitle = filterSubtitle {
                Text(subtitle)
                    .font(.scaled(10, .chrome))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.leading, FilterPicker.iconWidth + 8)
    }

    private var searchBarTrailingButtons: some View {
        HStack(spacing: 6) {
            Text("press / to focus")
                .round(10)
                .foregroundStyle(.secondary)
                .opacity(focused != .search ? 1 : 0)
            Group {
                if queryTooShort {
                    Text("Type \(minQueryLength) or more characters to search")
                        .round(10)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                } else if fuzzy.searching {
                    ProgressView()
                        .controlSize(.small)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: fuzzy.searching)
            .animation(.easeInOut(duration: 0.15), value: queryTooShort)
            if everything.available {
                everythingButton
            }
            xButton
            historyButton
            saveFilterButton
            syntaxHelpButton
        }
        .offset(x: -10)
    }

    private var everythingButton: some View {
        Button(action: { everything.toggle() }) {
            Image(systemName: "asterisk")
        }
        .buttonStyle(.plain)
        .foregroundColor(everything.applies ? .orange : .secondary)
        .focusable(false)
        .disabled(everything.blockedReason != nil)
        .help(everything.blockedReason ?? "Everything: every file on the local disks, nothing excluded (⌘⇧E)")
        .accessibilityLabel("Everything")
        .accessibilityToggle(isOn: everything.applies)
        .needsPro(clicked: $everything.showProPrompt)
    }

    private var syntaxHelpButton: some View {
        Button(action: { showSyntaxHelp.toggle() }) {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(.plain)
        .foregroundColor(showSyntaxHelp ? .accentColor : .secondary)
        .focusable(false)
        .help("Search syntax reference (⌘/)")
        // Without a name the button is announced by its symbol, "Question Mark In A Circle".
        .accessibilityLabel("Search syntax reference")
        .keyboardShortcut("/", modifiers: .command)
        .popover(isPresented: $showSyntaxHelp, arrowEdge: .bottom) {
            QuerySyntaxCheatsheet()
        }
    }

    @ViewBuilder
    private var historyButton: some View {
        if !SearchHistory.shared.entries.isEmpty, showingResults {
            Button(action: {
                showFullHistory.toggle()
                if showFullHistory {
                    fuzzy.showLiveIndex = false
                    fuzzy.showActivityLog = false
                }
            }) {
                Image(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(.plain)
            .foregroundColor(showFullHistory ? .accentColor : .secondary)
            .focusable(false)
            .help("Search history")
            .accessibilityLabel("Search history")
            .accessibilityToggle(isOn: showFullHistory)
        }
    }

    @ViewBuilder
    private var saveFilterButton: some View {
        if !fuzzy.query.isEmpty, showingResults, proactive {
            Button(action: { prefillQuickFilter() }) {
                Image(systemName: "plus.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .focusable(false)
            .help("Save current query as a Quick Filter (⌘S)")
            .accessibilityLabel("Save current query as a Quick Filter")
        }
    }

    /// The query field with its placeholder and ghost completion drawn in the same spot.
    private var searchField: some View {
        ZStack(alignment: .leading) {
            if fuzzy.query.isEmpty, !imeComposing {
                Text(LocalizedStringKey(placeholderHint))
                    .foregroundStyle(Color(nsColor: .placeholderTextColor))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .id(placeholderHint)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    // Drawn over the field as its placeholder; the field itself carries the name.
                    .accessibilityHidden(true)
            }
            if let suffix = inlineSuffix {
                // Ghost completion: the typed text is invisible here (the real TextField draws it), so
                // the suffix lines up right after it, with completion hints trailing in tertiary.
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(fuzzy.query).foregroundStyle(.clear)
                    Text(suffix).foregroundStyle(.secondary)
                    completionHint("tab to complete").padding(.leading, 8)
                    if suffix.contains(" ") {
                        completionHint("→ word by word").padding(.leading, 8)
                    }
                    completionHint("⌘↓ suggestions").padding(.leading, 8)
                }
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            TextField("", text: $fuzzy.query)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search")
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .focused($focused, equals: .search)
                .modifier(SearchBarKeyHandlers(
                    focused: $focused,
                    query: $fuzzy.query,
                    historyIndex: $historyIndex,
                    querySaved: $querySaved,
                    navigatingHistory: $navigatingHistory,
                    showHistorySuggestions: $showHistorySuggestions,
                    showSuggestionsList: $showSuggestionsList,
                    suggestionIndex: $suggestionIndex,
                    inlineSuggestion: inlineSuggestion,
                    historySuggestions: historySuggestions,
                    tableFocusTarget: tableFocusTarget
                ))
        }
    }

    /// Shown at the start of the search field while Everything is on; clicking it goes back to the normal index.
    private var everythingChip: some View {
        Button(action: { everything.toggle() }) {
            HStack(spacing: 3) {
                Image(systemName: "asterisk")
                    .font(.scaled(9, .chrome, weight: .bold))
                Text("Everything")
                    .font(.scaled(11, .chrome, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.orange, in: Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("Back to the normal index (⌘⇧E)")
        .padding(.leading, 6)
    }

    private var searchBar: some View {
        HStack(spacing: 0) {
            if everything.applies {
                everythingChip
            }
            searchField
        }
        // One font for the placeholder, the ghost completion and the real field: the ghost
        // suffix is positioned by drawing the query in clear text first, so any mismatch
        // between the two would slide the suggestion off the end of what was typed.
        .font(.scaled(13, .secondary))
        .animation(.easeInOut(duration: 0.45), value: placeholderHint)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(everything.enabled ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.quaternary), lineWidth: everything.enabled ? 1 : 0.5)
        )
        .padding(.vertical)
        .onChange(of: fuzzy.query) {
            if navigatingHistory {
                navigatingHistory = false
            } else {
                historyIndex = -1
                suggestionIndex = -1
                let isFocused = focused == .search
                let hasQuery = !fuzzy.query.isEmpty
                showHistorySuggestions = isFocused && hasQuery
            }
            if imeComposing {
                imeComposing = false
            }
            if showFullHistory {
                showFullHistory = false
            }
        }
        .onChange(of: focused) {
            showHistorySuggestions = focused == .search && !fuzzy.query.isEmpty
            if focused != .search {
                showSuggestionsList = false
                suggestionIndex = -1
                if imeComposing {
                    imeComposing = false
                }
            }
        }
        .task(id: shouldCyclePlaceholder) {
            guard shouldCyclePlaceholder else {
                placeholderHint = "Search"
                return
            }
            if searchHintsFirstShownAt == 0 {
                searchHintsFirstShownAt = Date().timeIntervalSince1970
            } else if !searchHintsManuallyEnabled,
                      Date().timeIntervalSince1970 - searchHintsFirstShownAt > 3 * 24 * 60 * 60
            {
                showSearchHints = false
                placeholderHint = "Search"
                return
            }
            while !Task.isCancelled, shouldCyclePlaceholder {
                let examples = ContentView.placeholderExamples(literal: Defaults[.literalSearch])
                placeholderHint = examples[placeholderIndex % examples.count]
                placeholderIndex = (placeholderIndex + 1) % examples.count
                try? await Task.sleep(nanoseconds: 3_500_000_000)
            }
        }
    }

    private var xButton: some View {
        Button(action: {
            if QLP.isVisible {
                QLP.close()
            } else if fuzzy.query.isEmpty {
                dismiss()
                AppDelegate.shared.handBackFocusAfterMainDismiss()
            } else {
                fuzzy.query = ""
                focused = .search
            }
        }) {
            Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .focusable(false)

    }

    private var resultsList: some View {
        GeometryReader { geo in
            VStack(spacing: 10) {
                if !stash.files.isEmpty {
                    stashSection(availableHeight: geo.size.height)
                }
                VStack(spacing: 0) {
                    ZStack(alignment: .topTrailing) {
                        Table(of: FilePath.self, selection: $selectedResultIDs, sortOrder: $sortOrder, columnCustomization: $resultColumns) {
                            iconColumn
                            nameColumn
                            driveColumn
                            pathColumn
                            sizeColumn
                            dateColumn
                        } rows: {
                            ForEach(visibleResults, id: \.string) { path in
                                TableRow(path)
                                    .draggable(path.url)
                            }
                        }
                        .scrollContentBackground(.hidden)
                        .alternatingRowBackgrounds(.disabled)
                        .accessibilityLabel("Results")
                        .onChange(of: showsDriveColumn, initial: true) { _, shows in
                            resultColumns[visibility: Self.driveColumnID] = shows ? .visible : .hidden
                        }
                        // Fixed row height keeps NSTableView from measuring every inserted row
                        // (which would force synchronous per-row stat/icon fetches on a bulk
                        // result update and freeze the app — CLING-B). Rows are uniform single
                        // line cells, so a constant height is exact, not just an approximation.
                        .fixedTableRowHeight(rowHeight)
                        .onChange(of: sortOrder) { oldOrder, newOrder in
                            // SwiftUI resets a newly-clicked column to ascending. Size and Date read more
                            // naturally largest/newest first, so flip those to descending the first time
                            // they become the sort column. Name and Path stay ascending, and re-clicking
                            // the same column still toggles freely.
                            if let adjusted = descendingDefaultAdjustment(from: oldOrder, to: newOrder) {
                                sortOrder = adjusted // re-fires onChange; applySortOrder runs on the settled value
                                return
                            }
                            applySortOrder(newOrder)
                        }
                        .onChange(of: results) {
                            // Auto-select the top row only when the query actually changed (a real
                            // new search). Background updates to the list (file watching, reindexing,
                            // recents refresh) keep the user's current selection put.
                            if let drilledFile, drilledFile.query == fuzzy.query,
                               let row = results.firstIndex(of: drilledFile.path)
                            {
                                lastSelectionQuery = fuzzy.query
                                selectedResultIDs = [drilledFile.path.string]
                                self.drilledFile = nil
                                scrollResultsTable(toRow: row + stash.files.count)
                            } else if lastSelectionQuery != fuzzy.query {
                                lastSelectionQuery = fuzzy.query
                                selectFirstResult()
                            } else {
                                preserveSelectionAcrossResultsUpdate()
                            }
                        }
                        .onChange(of: selectedResultIDs) {
                            selectedResults = Set((stash.files + results).filter { selectedResultIDs.contains($0.string) })
                            fuzzy.computeOpenWithApps(for: selectedResults.map(\.url))
                            // Commit to history only on user-initiated selection (not auto-select from query change)
                            if focused == .list, !selectedResults.isEmpty, !fuzzy.query.isEmpty {
                                SearchHistory.shared.commit(fuzzy.query)
                            }
                        }
                        .onReceive(NotificationCenter.default.publisher(for: .clingDidCreateFiles)) { notif in
                            guard let paths = notif.object as? [FilePath], !paths.isEmpty else { return }
                            let newSet = Set(paths)
                            fuzzy.results = paths + fuzzy.results.filter { !newSet.contains($0) }
                            fuzzy.recents = paths + fuzzy.recents.filter { !newSet.contains($0) }
                            fuzzy.sortedRecents = paths + fuzzy.sortedRecents.filter { !newSet.contains($0) }
                            DispatchQueue.main.async {
                                selectedResultIDs = Set(paths.map(\.string))
                                scrollResultsTableToTop()
                            }
                        }
                        .onKeyPress(.tab) {
                            focused = .search
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            // Walk off the top of the results into the pinned stash table.
                            guard focused == .list, let first = visibleResults.first, let last = stash.files.last,
                                  selectedResultIDs == [first.string]
                            else { return .ignored }
                            selectedResultIDs = [last.string]
                            focused = .stash
                            return .handled
                        }
                        .onKeyPress(.rightArrow) {
                            // Drill into the selected folder, or the folder holding the selected file: replace the
                            // query with `in:<folder>`. A file stays selected there.
                            guard focused == .list, selectedResults.count == 1, let selected = selectedResults.first
                            else { return .ignored }
                            let isFile = !selected.memoz.isDir
                            let drilled = drillIntoFolderQuery(isFile ? selected.removingLastComponent() : selected)
                            // Already searching in the file's folder.
                            guard drilled != fuzzy.query else { return .ignored }
                            drilledFile = isFile ? (drilled, selected) : nil
                            // A fresh drill (query isn't one we set) starts a new back-stack.
                            if fuzzy.query != lastDrillSetQuery {
                                queryDrillStack.removeAll()
                            }
                            queryDrillStack.append(fuzzy.query)
                            fuzzy.query = drilled
                            lastDrillSetQuery = drilled
                            return .handled
                        }
                        .onKeyPress(.leftArrow) {
                            // Walk back out, but only while the query is still the untouched one we drilled into.
                            guard focused == .list, !queryDrillStack.isEmpty, fuzzy.query == lastDrillSetQuery
                            else { return .ignored }
                            let previous = queryDrillStack.removeLast()
                            fuzzy.query = previous
                            lastDrillSetQuery = previous
                            return .handled
                        }
                        .homeEndSelectsRow(in: { visibleResults.map(\.string) }, select: { selectedResultIDs = [$0] })
                        .focused($focused, equals: .list)
                        .transparentTableBackground()
                        .tableRegistration(.list)
                        .padding(6)

                    }
                    .background(.background.opacity(0.3))

                    let staleDrives = fuzzy.searchedDrivesNeedingWalk
                    if !staleDrives.isEmpty {
                        DriveReindexNotice(drives: staleDrives)
                    }
                    if !fuzzy.noQuery {
                        MissingPathResultsBar(query: fuzzy.query)
                    }
                }
                .raisedPanel()
            }
        }
        .revealShortcutHints(held: km.lcmd || km.rcmd, visible: $sortHintsVisible)
        .onChange(of: sortHintsVisible) { _, visible in
            SortHintBadges.shared.setVisible(visible)
        }
        .onReceive(NotificationCenter.default.publisher(for: .clingSortByScore)) { _ in
            fuzzy.sortField = .score
            fuzzy.reverseSort = true
            sortOrder = [] // drop the sort indicator from the previously clicked column
        }
    }

    private var runHistoryTable: some View {
        Table(sortedRunHistory, selection: $runHistorySelection, sortOrder: $runHistorySortOrder) {
            TableColumn("Runs", value: \.count) { row in
                Text("\(row.count)")
                    .font(.scaled(12, design: .monospaced))
                    .foregroundStyle(.orange)
            }.width(min: 40, ideal: 50)

            TableColumn("Name", value: \.name) { row in
                Text(row.name)
                    .lineLimit(1).truncationMode(.middle)
                    .help(row.name)
            }.width(min: 100, ideal: 200)

            TableColumn("Path", value: \.dir) { row in
                Text(row.dir)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .help(row.dir)
            }.width(min: 100, ideal: 300)

            TableColumn("Last Run", value: \.lastRun) { row in
                Text(row.lastRun.formatted(.dateTime.month().day().hour().minute()))
                    .font(.scaled(11, design: .monospaced))
                    .help(row.lastRun.formatted(date: .abbreviated, time: .standard))
            }.width(min: 100, ideal: 120)
        }
        .homeEndSelectsRow(in: { sortedRunHistory.map(\.id) }, select: { runHistorySelection = [$0] })
        .contextMenu(forSelectionType: String.self) { ids in
            filePathContextMenu(paths: ids.compactMap { id in sortedRunHistory.first { $0.id == id }?.path })
        } primaryAction: { ids in
            let paths = ids.compactMap { id in sortedRunHistory.first { $0.id == id }?.path }
            openPathsIfExist(paths)
        }
    }

    private var liveIndexTable: some View {
        Table(sortedLiveChanges, selection: $liveIndexSelection, sortOrder: $liveChangeSortOrder) {
            TableColumn("", value: \.kind.rawValue) { change in
                Text(change.kind.rawValue)
                    .font(.scaled(12, design: .monospaced))
                    .foregroundStyle(liveChangeColor(change.kind))
                    .opacity(liveRowOpacity(change))
            }.width(16)

            TableColumn("Name", value: \.name) { change in
                HStack(spacing: 4) {
                    if liveShowHidden, hiddenLiveEvents.contains(change.path) {
                        Image(systemName: "eye.slash")
                            .font(.scaled(10))
                            .accessibilityLabel("Hidden")
                    }
                    Text(change.name)
                        .lineLimit(1).truncationMode(.middle)
                        .help(change.name)
                }
                .opacity(liveRowOpacity(change))
            }.width(min: 100, ideal: 200)

            TableColumn("Path", value: \.dir) { change in
                Text(change.dir)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .help(change.dir)
                    .opacity(liveRowOpacity(change))
            }.width(min: 100, ideal: 300)

            TableColumn("Time", value: \.date) { change in
                Text(change.date.formatted(.dateTime.hour().minute().second()))
                    .font(.scaled(11, design: .monospaced))
                    .help(change.date.formatted(date: .abbreviated, time: .standard))
                    .opacity(liveRowOpacity(change))
            }.width(min: 70, ideal: 80)
        }
        .homeEndSelectsRow(in: { sortedLiveChanges.map(\.id) }, select: { liveIndexSelection = [$0] })
        .contextMenu(forSelectionType: UUID.self) { ids in
            let paths = ids.compactMap { id in sortedLiveChanges.first { $0.id == id }.map { FilePath($0.path) } }
            filePathContextMenu(paths: paths)
            Divider()
            liveEventMenuItems(paths.map(\.string))
        } primaryAction: { ids in
            let paths = ids.compactMap { id in sortedLiveChanges.first { $0.id == id }.map { FilePath($0.path) } }
            openPathsIfExist(paths)
        }
    }

    @ViewBuilder
    private var liveSelectionActions: some View {
        let paths = selectedLivePaths
        let hidden = hiddenLiveEvents
        HStack(spacing: 6) {
            Button("Exclude from Index...") {
                excludeRequest = ExcludeSheetRequest(paths: paths.map { FilePath($0) })
            }
            if paths.contains(where: { !hidden.contains($0) }) {
                Menu("Hide from Events") {
                    Button(paths.parents.count == 1 ? "Hide Folder from Events" : "Hide Folders from Events") {
                        hideLiveEvents(paths.parents)
                    }
                } primaryAction: {
                    hideLiveEvents(paths)
                }
                .fixedSize()
                .help("Stays in the index")
            }
            if paths.contains(where: hidden.contains) {
                Button("Unhide") { unhideLiveEvents(paths) }
            }
        }
        .controlSize(.mini)
        .font(.system(size: 10))
    }

    @ViewBuilder
    private func liveEventMenuItems(_ rawPaths: [String]) -> some View {
        let paths = rawPaths.uniqued
        let hidden = hiddenLiveEvents
        Button("Exclude from Index...") {
            excludeRequest = ExcludeSheetRequest(paths: paths.map { FilePath($0) })
        }
        if paths.contains(where: { !hidden.contains($0) }) {
            Button("Hide from Events") { hideLiveEvents(paths) }
            Button(paths.parents.count == 1 ? "Hide Folder from Events" : "Hide Folders from Events") {
                hideLiveEvents(paths.parents)
            }
        }
        if paths.contains(where: hidden.contains) {
            Button("Unhide") { unhideLiveEvents(paths) }
        }
    }

    /// The stash panel looks exactly like the results table: column headers + rows in a floating
    /// panel. Clearing lives in the icon column's header (red trash button, ⌘⇧S).
    private func stashSection(availableHeight: CGFloat) -> some View {
        // Plain arithmetic instead of live measurement: rows are pinned to rowHeight by
        // fixedTableRowHeight, and stashChromeHeight covers the header and padding around them.
        // The stash lives in its own floating panel, so a couple of points of OS drift just
        // shift its inner breathing room.
        let ideal = CGFloat(min(stash.files.count, 6)) * rowHeight + Self.stashChromeHeight
        let minHeight = rowHeight + Self.stashChromeHeight
        let height = min(ideal, max(minHeight, availableHeight - Self.resultsReservedHeight))
        return stashTable(height: height, locked: stash.files.count <= 6 && height >= ideal)
            .background(.background.opacity(0.3))
            .raisedPanel()
    }

    private func stashTable(height: CGFloat, locked: Bool) -> some View {
        Table(of: FilePath.self, selection: $selectedResultIDs, sortOrder: $sortOrder) {
            iconColumn
            nameColumn
            pathColumn
            sizeColumn
            dateColumn
        } rows: {
            ForEach(stash.files, id: \.string) { path in
                TableRow(path)
                    .draggable(path.url)
            }
        }
        .scrollContentBackground(.hidden)
        .alternatingRowBackgrounds(.disabled)
        .accessibilityLabel("Stash")
        .fixedTableRowHeight(rowHeight)
        .onKeyPress(.downArrow) {
            // Walk off the end of the stash into the results table.
            guard focused == .stash, let last = stash.files.last,
                  selectedResultIDs == [last.string], let first = visibleResults.first
            else { return .ignored }
            selectedResultIDs = [first.string]
            focused = .list
            return .handled
        }
        .onKeyPress(.upArrow) {
            // Walk off the top of the stash back into the search field.
            guard focused == .stash, let first = stash.files.first,
                  selectedResultIDs == [first.string]
            else { return .ignored }
            focused = .search
            return .handled
        }
        .onKeyPress(.tab) {
            // Continue into the results below (Tab there wraps back to the search field).
            guard focused == .stash else { return .ignored }
            if tableFocusTarget == .stash, let first = visibleResults.first {
                selectedResultIDs = [first.string]
            }
            focused = .list
            return .handled
        }
        .homeEndSelectsRow(in: { stash.files.map(\.string) }, select: { selectedResultIDs = [$0] })
        .focused($focused, equals: .stash)
        .contextMenu(forSelectionType: String.self) { ids in
            RightClickMenu(
                selectedResults: $selectedResults,
                orderedResults: displayedResults,
                contextPaths: displayedResults.filter { ids.contains($0.string) }
            )
            .onAppear {
                if !ids.isEmpty, !ids.isSubset(of: selectedResultIDs) {
                    selectedResultIDs = ids
                }
            }
        }
        .transparentTableBackground()
        .tableRegistration(.stash, lockVertical: locked)
        .frame(height: height)
        .padding(6)
    }

    private func volumeIndexingOverlay(_ volume: FilePath) -> some View {
        VStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle())
            Text("Indexing \(volume.name.string)...")
                .medium(20)
                .foregroundStyle(.secondary)
            if !fuzzy.operation.isEmpty {
                Text(fuzzy.operation)
                    .round(12, weight: .regular)
                    .foregroundStyle(.tertiary)
            }
            Button("Cancel") {
                fuzzy.cancelVolumeIndexing(volume: volume)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .fill()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func completionHint(_ text: String) -> some View {
        Text(text)
            .font(.scaled(10, .chrome, design: .monospaced))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.quaternary, lineWidth: 0.5))
    }

    @ViewBuilder
    private func filePathContextMenu(paths: [FilePath]) -> some View {
        Button("Open") {
            openPathsIfExist(paths)
        }
        Button("Show in Finder") {
            let existing = paths.filter(\.exists)
            if existing.isEmpty {
                pathNotFoundMessage = paths.map(\.string).joined(separator: "\n")
            } else {
                revealInFinder(existing.map(\.url))
            }
        }
        Button("Get Info") {
            if let path = paths.first {
                openFinderGetInfo(path)
            }
        }
        Divider()
        Button("Copy Path\(paths.count > 1 ? "s" : "")") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(paths.map(\.string).joined(separator: "\n"), forType: .string)
        }
        Button("Copy Filename\(paths.count > 1 ? "s" : "")") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(paths.compactMap { $0.lastComponent?.string }.joined(separator: "\n"), forType: .string)
        }
    }

    /// The quote operator means the opposite of whatever matching mode is the default, so its
    /// example follows the `literalSearch` setting.
    private static func placeholderExamples(literal: Bool) -> [String] {
        placeholderExamplesBase + [
            literal
                ? "Example: **`'rprt`** *(fuzzy text: finds report.pdf)*"
                : "Example: **`'cat`** *(exact text: finds Cats or vacation, not contact)*",
        ]
    }

    private func liveRowOpacity(_ change: FuzzyClient.IndexChange) -> Double {
        liveShowHidden && hiddenLiveEvents.contains(change.path) ? 0.45 : 1
    }

    private func hideLiveEvents(_ paths: [String]) {
        hiddenLiveEventPaths = (hiddenLiveEventPaths + paths).uniqued
        liveIndexSelection = []
    }

    /// Takes away every entry hiding one of `paths`, the folders above them included.
    private func unhideLiveEvents(_ paths: [String]) {
        hiddenLiveEventPaths.removeAll { entry in paths.contains { PathMatcher([entry]).contains($0) } }
    }

    private func handleFilterKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        // ⌥-letters type characters (å, ∫, ç…) in the filter and path sheets presented under these handlers.
        guard keyPress.modifiers.subtracting(.numericPad) == [.option], mainWindowIsKey else { return .ignored }
        guard keyPress.key != .escape else {
            fuzzy.folderFilter = nil
            fuzzy.quickFilter = nil
            fuzzy.volumeFilter = nil
            focused = .search
            return .handled
        }

        var result: KeyPress.Result = .ignored

        if proactive, let filter = folderFilters.first(where: { $0.keyEquivalent == keyPress.key }) {
            fuzzy.folderFilter = filter
            result = .handled
        }
        if proactive, let filter = quickFilters.first(where: { $0.keyEquivalent == keyPress.key }) {
            fuzzy.quickFilter = filter
            result = .handled
        }
        if proactive, let index = keyPress.key.character.wholeNumberValue, let filter = ([FilePath.root] + fuzzy.enabledVolumes)[safe: index] {
            fuzzy.volumeFilter = filter
            result = .handled
        }
        if proactive, keyPress.key == KeyEquivalent(ALL_DRIVES_KEY), fuzzy.allDrivesKeyApplies(quickFilters: quickFilters, folderFilters: folderFilters) {
            fuzzy.volumeFilter = .allDrives
            result = .handled
        }

        if result == .handled {
            focused = .search
        }
        return result
    }

    private func handleFolderFilterDismiss() {
        finishFolderFilterDraft(id: folderFilterID, folders: folderFilterFolders, key: folderFilterKey)
        folderFilterID = ""; folderFilterFolders = []; folderFilterKey = .escape
    }

    private func handleQuickFilterDismiss() {
        finishQuickFilterDraft(filterDraft)
        filterDraft = QuickFilterDraft()
    }

    private func prefillQuickFilter() {
        switch FilterDraftFromQuery(query: fuzzy.query) {
        case let .folder(id, folders, key):
            folderFilterID = id
            folderFilterFolders = folders
            folderFilterKey = key
            isAddingFolderFilter = true
        case let .quick(draft):
            filterDraft = draft
            isAddingQuickFilter = true
        }
    }

    private func installContentShortcutMonitor() {
        guard contentShortcutMonitor == nil else { return }
        contentShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                RowToggleTap.handle(event)
                return event
            }
            // Any real keystroke means the modifier wasn't a lone tap (e.g. ⌘C mid-gesture).
            RowToggleTap.cancel()
            // Sample IME marked-text state AFTER the field editor handles this
            // keystroke, so the search placeholder hides during composition.
            // Only matters while the query is empty (otherwise the placeholder
            // is already hidden) and when no ⌘/⌃ shortcut is in flight.
            if focused == .search, fuzzy.query.isEmpty {
                let evMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if !evMods.contains(.command), !evMods.contains(.control) {
                    DispatchQueue.main.async {
                        let composing = (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false
                        if composing != imeComposing {
                            imeComposing = composing
                        }
                    }
                }
            } else if imeComposing {
                imeComposing = false
            }
            if NSApp.keyWindow?.attachedSheet != nil {
                return event
            }
            if DropZoneOverlay.shared.isPresenting {
                return event
            }
            if event.window !== AppDelegate.shared.mainWindow {
                return event
            }
            // Let IME handle keys (Esc/arrows/Return/etc.) during active composition.
            if let responder = event.window?.firstResponder as? NSTextInputClient,
               responder.hasMarkedText()
            {
                return event
            }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let kc = event.keyCode
            let chars = (event.charactersIgnoringModifiers ?? "").lowercased()

            // ⌃⇥ → the same search in the search bar, and back from there with the same keys.
            if kc == 48, mods == .control {
                SB.switchFromWindow()
                return nil
            }

            // ⌘+ / ⌘- / ⌘0 → text size. ⌘= carries the plus without Shift, and the keypad
            // sends its own keycodes, so all four spellings land here.
            if mods == .command || mods == [.command, .shift] {
                if chars == "=" || chars == "+" || kc == 69 {
                    FontScale.adjust(by: FontScale.step)
                    return nil
                }
                if chars == "-" || chars == "_" || kc == 78 {
                    FontScale.adjust(by: -FontScale.step)
                    return nil
                }
                if chars == "0" || kc == 82 {
                    FontScale.reset()
                    return nil
                }
            }
            // ⌘. → toggle pin
            if mods == .command, chars == "." {
                wm.pinned.toggle()
                NSApp.windows.first { $0.identifier?.rawValue == "main" }?.level = wm.pinned ? .floating : .normal
                return nil
            }
            // Toggle file preview panel (default ⌘⇧P, user-rebindable via the Toggle Preview action).
            // Handled here rather than in the ActionButtons monitor so it works with no selection.
            if let pressed = KeyboardShortcuts.Shortcut(event: event),
               pressed == KeyboardShortcuts.getShortcut(for: .clTogglePreview)
            {
                Defaults[.showFilePreview].toggle()
                return nil
            }
            // Search everything instead of the normal index (default ⌘⇧E, rebindable). Off in Settings, the key
            // goes on to whatever else takes it.
            if EVERYTHING.available, let pressed = KeyboardShortcuts.Shortcut(event: event),
               pressed == KeyboardShortcuts.getShortcut(for: .clToggleEverything)
            {
                EVERYTHING.toggle()
                return nil
            }
            // Clear the whole stash (default ⌘⇧S, rebindable). Dispatched here rather than the
            // ActionButtons monitor so it works with no selection and from the search field.
            if let pressed = KeyboardShortcuts.Shortcut(event: event),
               pressed == KeyboardShortcuts.getShortcut(for: .clStashClear)
            {
                if !STASH.files.isEmpty {
                    STASH.clear()
                    return nil
                }
                return event
            }
            // ⌘S → save current query as Quick Filter from the search field; from the results it stashes
            if mods == .command, chars == "s", showingResults, commandSSavesQuery(fromField: focused == .search) {
                prefillQuickFilter()
                return nil
            }
            // ⌘I → Finder Get Info for the previewed file (single selection
            // only when the preview panel is hidden, so 50 selected files can
            // never cascade 50 info panels)
            if mods == .command, chars == "i" {
                if showFilePreview, isShowingResultsTable, let path = PreviewPanelState.shared.currentPath {
                    openFinderGetInfo(path)
                } else if selectedResults.count == 1, let path = selectedResults.first {
                    openFinderGetInfo(path)
                } else {
                    NSSound.beep()
                }
                return nil
            }
            // Rebindable sort shortcuts (defaults ⌃N Name, ⌃P Path, ⌃S Size, ⌃D Date, ⌃0
            // Relevance). Dispatched here rather than the ActionButtons monitor so they work with
            // no selection and while the search field has focus.
            if let pressed = KeyboardShortcuts.Shortcut(event: event),
               let field = ClingShortcuts.sortField(for: pressed)
            {
                applySortShortcut(field)
                return nil
            }
            // Esc → quicklook close / dismiss / clear query (xButton behavior)
            if kc == 53, mods.isEmpty, !showHistorySuggestions, !DropZoneOverlay.shared.isPresenting {
                // A Send popover/Transfers panel is anchored on the toolbar but doesn't take key
                // focus, so close it here instead of letting Esc dismiss the whole window.
                if SendManager.shared.showingSendPopover {
                    SendManager.shared.showingSendPopover = false
                    return nil
                }
                if SendManager.shared.showingTransfers {
                    SendManager.shared.showingTransfers = false
                    return nil
                }
                if QLP.isVisible {
                    QLP.close()
                    return nil
                }
                if fuzzy.query.isEmpty {
                    if let win = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
                        AppDelegate.shared.hideOrCloseMainWindow(win)
                    }
                    AppDelegate.shared.handBackFocusAfterMainDismiss()
                    return nil
                }
                fuzzy.query = ""
                focused = .search
                return nil
            }
            // ⌘⌃<letter> → script
            if mods == [.command, .control], proactive, scriptManager.process == nil,
               let ch = chars.first,
               let script = scriptManager.scriptShortcuts.first(where: { $0.value == ch })?.key,
               scriptManager.isEligible(script, forPaths: selectedResults.arr)
            {
                RH.trackRun(selectedResults)
                scriptManager.run(script: script, args: selectedResults.map(\.string))
                return nil
            }
            // ⌃⌘O (hold ⌥ for aggressive) → Optimise with Clop. Reads the live selection here so it
            // never acts on a stale snapshot. Sits after the script branch, so a script bound to "o"
            // keeps priority (mirrors the toolbar button's o-key-available check).
            if proactive, chars == "o", mods.subtracting(.option) == [.command, .control],
               fuzzy.clopIsAvailable
            {
                let candidates = selectedResults.filter(\.exists).map(\.url).filter(\.memoz.canBeOptimisedByClop)
                if !candidates.isEmpty {
                    let paths = candidates.map(\.path)
                    let aggressive = mods.contains(.option)
                    Task.detached {
                        guard ClopSDK.shared.waitForClopToBeAvailable(for: 5) else { return }
                        _ = try? ClopSDK.shared.optimise(paths: paths, aggressive: aggressive, inTheBackground: true)
                    }
                    return nil
                }
            }
            // ⌘⌥<letter> → open with app. One match opens it directly; several apps sharing that
            // first letter open the picker scoped to them for numbered selection.
            if mods == [.command, .option], let ch = chars.first {
                let group = fuzzy.openWithAppShortcuts.filter { $0.value == ch }.map(\.key)
                if group.count == 1 {
                    RH.trackRun(selectedResults)
                    NSWorkspace.shared.open(
                        selectedResults.map(\.url), withApplicationAt: group[0], configuration: .init(),
                        completionHandler: { _, _ in }
                    )
                    return nil
                } else if group.count > 1 {
                    fuzzy.openWithGroupRequest = OpenWithGroupRequest(
                        apps: group.sorted(by: \.lastPathComponent), files: selectedResults.map(\.url)
                    )
                    return nil
                }
            }
            return event
        }
    }

    private func removeContentShortcutMonitor() {
        if let m = contentShortcutMonitor {
            NSEvent.removeMonitor(m)
            contentShortcutMonitor = nil
        }
    }

    /// Clicking a row selects it, but the focus state stays wherever it was, so the table keeps
    /// drawing an inactive (grey) selection and the arrow keys still belong to the search field.
    /// AppKit's own first-responder change is overruled by `@FocusState`, so move the focus here.
    private func installTableClickMonitor() {
        guard tableClickMonitor == nil else { return }
        tableClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            guard event.window === AppDelegate.shared.mainWindow,
                  let table = TableRegistry.shared.table(atWindowPoint: event.locationInWindow),
                  focused != table
            else { return event }
            focused = table
            return event
        }
    }

    private func removeTableClickMonitor() {
        if let m = tableClickMonitor {
            NSEvent.removeMonitor(m)
            tableClickMonitor = nil
        }
    }

    private func openPathsIfExist(_ paths: [FilePath]) {
        let missing = paths.filter { !$0.exists }
        if missing.isEmpty {
            for path in paths {
                NSWorkspace.shared.open(path.url)
            }
        } else {
            pathNotFoundMessage = missing.map(\.string).joined(separator: "\n")
        }
    }

    private func liveChangeColor(_ kind: FuzzyClient.IndexChange.Kind) -> Color {
        switch kind {
        case .added: .green
        case .removed: .red
        case .modified: .orange
        }
    }

    /// When the sort column *switches* to Size or Date and SwiftUI defaulted it to ascending,
    /// return the descending variant to apply instead (largest / most recent first). Returns nil
    /// when no change is needed: the same column was re-clicked (let it toggle), it's already
    /// descending, or it's a column that should stay ascending (Name, Path).
    private func descendingDefaultAdjustment(from old: [KeyPathComparator<FilePath>], to new: [KeyPathComparator<FilePath>]) -> [KeyPathComparator<FilePath>]? {
        guard let first = new.first, first.order == .forward,
              old.first?.keyPath != first.keyPath else { return nil }
        var adjusted = new
        switch first.keyPath {
        case \FilePath.memoz.size:
            adjusted[0] = KeyPathComparator(\FilePath.memoz.size, order: .reverse)
        case \FilePath.memoz.date:
            adjusted[0] = KeyPathComparator(\FilePath.memoz.date, order: .reverse)
        default:
            return nil
        }
        return adjusted
    }

    /// Keyboard-driven sort (rebindable ⌃N/⌃P/⌃S/⌃D/⌃0). Sets the sort field directly, then
    /// mirrors it onto the Table's `sortOrder` so the column header's sort indicator stays in sync
    /// for the four sortable columns (Relevance has no column). Pressing the field that's already
    /// active flips its direction; switching to a new field uses its natural default (Name/Path
    /// ascending, Size/Date/Relevance descending), matching a header click.
    private func applySortShortcut(_ field: SortField) {
        let ascendingDefault = field == .name || field == .path
        let reverse = fuzzy.sortField == field ? !fuzzy.reverseSort : !ascendingDefault
        fuzzy.sortField = field
        fuzzy.reverseSort = reverse
        let order: SortOrder = reverse ? .reverse : .forward
        switch field {
        case .name: sortOrder = [KeyPathComparator(\FilePath.name.string, order: order)]
        case .path: sortOrder = [KeyPathComparator(\FilePath.dir.string, order: order)]
        case .size: sortOrder = [KeyPathComparator(\FilePath.memoz.size, order: order)]
        case .date: sortOrder = [KeyPathComparator(\FilePath.memoz.date, order: order)]
        // Relevance isn't a table column: clear the sort order so the previously clicked
        // column header drops its sort indicator.
        case .score: sortOrder = []
        case .kind: break
        }
    }

    private func applySortOrder(_ order: [KeyPathComparator<FilePath>]) {
        guard let first = order.first else { return }
        let reverse = first.order == .reverse
        switch first.keyPath {
        case \FilePath.name.string:
            fuzzy.sortField = .name; fuzzy.reverseSort = reverse
        case \FilePath.dir.string:
            fuzzy.sortField = .path; fuzzy.reverseSort = reverse
        case \FilePath.memoz.size:
            fuzzy.sortField = .size; fuzzy.reverseSort = reverse
        case \FilePath.memoz.date:
            fuzzy.sortField = .date; fuzzy.reverseSort = reverse
        default:
            break
        }
    }

    /// Build an `in:` query that scopes the search into `folder`. Home is abbreviated to `~`, and a
    /// path containing spaces is wrapped in double quotes so the query tokenizer keeps it intact.
    private func drillIntoFolderQuery(_ folder: FilePath) -> String {
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

    private func selectFirstResult() {
        // Nothing preselected while the list is just recents: a row selected on open is one the
        // person never chose, and it makes every action in the toolbar look aimed at a file they
        // have not picked. Arrowing down still lands on the first row.
        guard !showingDefaultResults, let firstResult = results.first else {
            selectedResultIDs.removeAll()
            return
        }
        selectedResultIDs = [firstResult.string]
    }

    private func preserveSelectionAcrossResultsUpdate() {
        let resultIDs = Set((stash.files + results).map(\.string))
        let stillValid = selectedResultIDs.intersection(resultIDs)
        if stillValid.isEmpty {
            selectFirstResult()
        } else if stillValid != selectedResultIDs {
            selectedResultIDs = stillValid
        }
    }
}

// MARK: - FilePathBackgroundTasks

@MainActor
class FilePathBackgroundTasks {
    static let shared = FilePathBackgroundTasks()

    func fetchAttributes(of path: FilePath, force: Bool = false) {
        guard force || (attrCache[path] == nil && (attrFetchers[path]?.isCancelled ?? true)) else { return }
        attrFetchers[path]?.cancel()

        // Check SMB metadata cache for instant size/date without network round trip.
        // `knownVolume` also matches unmounted volumes, whose cache stays loaded.
        if let volume = path.knownVolume,
           let smbCache = FUZZY.smbMetadataCaches[volume],
           let meta = smbCache.get(path.string)
        {
            storeAttrs([:], for: path)

            let date = meta.modificationDate
            path.cache(date.formatted(dateFormat), forKey: \FilePath.formattedModificationDate)
            path.cache(date.iso8601String, forKey: \FilePath.isoFormattedModificationDate)
            path.cache(date, forKey: \FilePath.date)

            let size = Int(meta.size)
            path.cache(size.humanSize, forKey: \FilePath.humanizedFileSize)
            path.cache(size, forKey: \FilePath.size)

            scheduleResultsRefresh()
            return
        }

        let fetcher = DispatchWorkItem {
            let attrs: [FileAttributeKey: Any]
            let icon: NSImage
            // An online-only package's icon would download all of it; paused, it gets its type's icon.
            let downloads = CloudDownloads.pause()
            defer { downloads.resume() }
            do {
                attrs = try FileManager.default.attributesOfItem(atPath: path.string)
                icon = NSWorkspace.shared.icon(forFile: path.string)
            } catch {
                log.error("Error fetching file metadata for \(path.string): \(error.localizedDescription)")
                mainActor { self.attrFetchers[path] = nil }
                return
            }

            mainActor {
                self.storeAttrs(attrs, for: path)
                self.attrFetchers[path] = nil

                let date = (attrs[.modificationDate] as? Date) ?? Date()
                path.cache(date.formatted(dateFormat), forKey: \FilePath.formattedModificationDate)
                path.cache(date.iso8601String, forKey: \FilePath.isoFormattedModificationDate)
                path.cache(date, forKey: \FilePath.date)

                let size = (attrs[.size] as? UInt64)?.i ?? 0
                path.cache(size.humanSize, forKey: \FilePath.humanizedFileSize)
                path.cache(size, forKey: \FilePath.size)

                path.cache(icon, forKey: \FilePath.icon)
                self.scheduleResultsRefresh()
            }

        }
        attrFetchers[path] = fetcher
        // Every visible row now waits on this rather than only the ones on external volumes, so it
        // sits on the display path and `.background` would leave the columns reading "Fetching...".
        DispatchQueue.global(qos: .userInitiated).async(execute: fetcher)
    }

    /// The real icon once it has arrived, a type-derived stand-in until then. This dictionary is the
    /// authority rather than the memo: the memo is NSCache-backed, so relying on it would let an
    /// eviction send the getter back through `fetchIcon`, refresh, re-render, and round again.
    func icon(for path: FilePath) -> NSImage {
        if let real = iconCache[path] {
            return real
        }
        fetchIcon(of: path)
        return typeIcon(for: path)
    }

    /// Fetches the real icon off the main thread and overwrites the memoized stand-in with it.
    /// Also records whether the path is a directory, which `typeIcon` needs and which would
    /// otherwise cost a `stat` on the main thread.
    func fetchIcon(of path: FilePath) {
        guard iconCache[path] == nil, iconFetchers[path] == nil else { return }

        let fetcher = DispatchWorkItem {
            // An online-only package's icon would download all of it; paused, it gets its type's icon.
            let downloads = CloudDownloads.pause()
            let icon = NSWorkspace.shared.icon(forFile: path.string)
            downloads.resume()
            var isDirectory = ObjCBool(false)
            let exists = FileManager.default.fileExists(atPath: path.string, isDirectory: &isDirectory)

            mainActor {
                self.iconFetchers[path] = nil
                // A path that vanished keeps its stand-in, stored so it stops being re-fetched.
                guard exists else {
                    self.storeIcon(self.typeIcon(for: path), for: path)
                    return
                }
                self.knownDirs[path] = isDirectory.boolValue
                self.storeIcon(icon, for: path)
                path.cache(icon, forKey: \FilePath.icon)
                self.scheduleResultsRefresh()
            }
        }
        iconFetchers[path] = fetcher
        DispatchQueue.global(qos: .userInitiated).async(execute: fetcher)
    }

    /// Drops a path's icon and stat so the next render fetches them again. Used when a file is
    /// renamed or replaced. The stat cache outlives the memo behind the size and date columns, so
    /// without this a replaced file would keep reporting the size it had before.
    func invalidateIcon(of path: FilePath) {
        iconCache.removeValue(forKey: path)
        knownDirs.removeValue(forKey: path)
        iconFetchers[path]?.cancel()
        iconFetchers[path] = nil
        statCache.removeValue(forKey: path)
    }

    /// The file's icon by type alone, with no disk access: `UTType(filenameExtension:)` is a lookup in
    /// the type database and `icon(for:)` draws that type, so neither one reaches the file. Cached per
    /// extension because a result list is mostly a handful of repeated types.
    func typeIcon(for path: FilePath) -> NSImage {
        if isKnownDir(path) {
            return Self.folderIcon
        }

        let ext = path.url.pathExtension.lowercased()
        guard !ext.isEmpty else { return Self.genericIcon }
        if let cached = typeIcons[ext] {
            return cached
        }

        let icon = UTType(filenameExtension: ext).map { NSWorkspace.shared.icon(for: $0) } ?? Self.genericIcon
        typeIcons[ext] = icon
        return icon
    }

    /// Records the directory flag the search index already carries, so a row never has to `stat` to
    /// decide between a folder icon and a file icon.
    func noteIsDir(_ isDir: Bool, for path: FilePath) {
        knownDirs[path] = isDir
    }

    /// The directory flag when the index or an icon fetch has already reported it, without a `stat`.
    func knownIsDir(_ path: FilePath) -> Bool? {
        knownDirs[path]
    }

    /// Size and modification date from a single `stat`, for a path the caller has established sits
    /// on the boot volume. That syscall is a few microseconds, so a row can afford it while it
    /// draws and the columns are filled on first paint instead of a beat later.
    ///
    /// Deliberately not `fileSize()`: that one calls `exists` and then wraps `attributesOfItem` in
    /// a `withTimeout`, so it costs two syscalls, a bridged dictionary, and a dispatch round trip,
    /// and it blocks the main thread for the full 5s of that timeout on a path that stalls.
    ///
    /// The boot volume can stall too, under a FUSE mount or a disk pinned by another process, so
    /// the first call that overruns a frame gives the fast path up for the rest of the session and
    /// everything falls back to `fetchAttributes`. One slow row, once, rather than 5s per row
    /// forever (CLING-18).
    func inlineAttributes(of path: FilePath) -> (size: Int, date: Date)? {
        if let cached = statCache[path] {
            return cached
        }
        guard inlineStatAllowed else { return nil }

        // `lstat` rather than `stat`: the bare name `stat` resolves to the struct instead of the
        // syscall, and not following symlinks is what `attributesOfItem` did here before anyway.
        let start = DispatchTime.now().uptimeNanoseconds
        var info = Darwin.stat()
        let ok = lstat(path.string, &info) == 0
        let elapsed = DispatchTime.now().uptimeNanoseconds - start

        if elapsed > Self.inlineStatBudget {
            inlineStatAllowed = false
            log.error("stat(\(path.string)) took \(elapsed / 1_000_000)ms on the main thread, falling back to background attribute fetches")
        }
        guard ok else { return nil }

        let mtime = info.st_mtimespec
        let attrs = (
            size: Int(info.st_size),
            date: Date(timeIntervalSince1970: TimeInterval(mtime.tv_sec) + TimeInterval(mtime.tv_nsec) / 1_000_000_000)
        )
        storeStat(attrs, for: path)
        return attrs
    }

    private static let folderIcon = NSWorkspace.shared.icon(for: .folder)
    private static let genericIcon = NSWorkspace.shared.icon(for: .data)

    private static let inlineStatBudget: UInt64 = 16_000_000 // one 60Hz frame

    private var attrFetchers: [FilePath: DispatchWorkItem] = [:]
    private var inlineStatAllowed = true
    private var statCache: [FilePath: (size: Int, date: Date)] = [:]
    private var statOrder: [FilePath] = []
    private var attrCache: [FilePath: [FileAttributeKey: Any]] = [:]
    private var attrOrder: [FilePath] = []
    private var iconFetchers: [FilePath: DispatchWorkItem] = [:]
    private var iconCache: [FilePath: NSImage] = [:]
    private var iconOrder: [FilePath] = []
    private var typeIcons: [String: NSImage] = [:]
    private var knownDirs: [FilePath: Bool] = [:]
    private var refreshTask: DispatchWorkItem?

    private func isKnownDir(_ path: FilePath) -> Bool {
        knownDirs[path] ?? false
    }

    /// Bounded so a long session of scrolling can't accumulate every icon it has ever drawn.
    private func storeIcon(_ icon: NSImage, for path: FilePath) {
        if iconCache.updateValue(icon, forKey: path) == nil {
            iconOrder.append(path)
            if iconOrder.count > 2000 {
                iconCache.removeValue(forKey: iconOrder.removeFirst())
            }
        }
    }

    /// Icons and attributes land one at a time, and refreshing per file would rebuild the table once
    /// per row, so let a burst settle into a single refresh.
    private func scheduleResultsRefresh() {
        refreshTask?.cancel()
        refreshTask = mainAsyncAfter(ms: 50) { FUZZY.reloadResults() }
    }

    /// Bounded like `iconCache`. Five getters read the same path, so caching keeps that to one
    /// `stat` even when the memo behind an individual column has been evicted.
    private func storeStat(_ attrs: (size: Int, date: Date), for path: FilePath) {
        if statCache.updateValue(attrs, forKey: path) == nil {
            statOrder.append(path)
            if statOrder.count > 2000 {
                statCache.removeValue(forKey: statOrder.removeFirst())
            }
        }
    }

    /// Bounded for the same reason as `iconCache`: every row now goes through the attribute fetch,
    /// so a long session would otherwise keep an entry for every file it has ever drawn.
    private func storeAttrs(_ attrs: [FileAttributeKey: Any], for path: FilePath) {
        if attrCache.updateValue(attrs, forKey: path) == nil {
            attrOrder.append(path)
            if attrOrder.count > 2000 {
                attrCache.removeValue(forKey: attrOrder.removeFirst())
            }
        }
    }
}

@MainActor
extension FilePath {
    /// The cache is keyed by volume, and an unmounted volume is no longer in the mounted list,
    /// so offline paths have to look their volume up among the disconnected ones.
    private var smbMeta: SMBFileMetadata? {
        guard let volume = knownVolume else { return nil }
        return FUZZY.smbMetadataCaches[volume]?.get(string)
    }

    /// Statting a path on an unmounted volume can only fail, and on a stalled network mount it
    /// blocks. Either way the answer has to come from the index, never from the filesystem.
    private var isOffline: Bool {
        disconnectedVolume != nil
    }

    /// Read through `memoz` while SwiftUI builds a row and while the table sorts, so like `icon`
    /// these must never block while SwiftUI builds a row or sorts the table.
    ///
    /// Nothing under a mounted volume is touched from here. That is stricter than the
    /// `isOnExternalVolume` guard these used to make, which only caught volumes `isLocalVolume`
    /// reports as external and so let a USB or SMB mount that calls itself local through to a
    /// `stat` that stalls, once per row and once per result while sorting (CLING-18).
    ///
    /// Everything else is on the boot volume, where a `stat` costs microseconds, so it is read
    /// inline and the columns are right on first paint. `inlineAttributes` gives that up on its
    /// own if the syscall ever overruns a frame.
    private var inlineAttrs: (size: Int, date: Date)? {
        guard memoz.volume == nil else { return nil }
        return FilePathBackgroundTasks.shared.inlineAttributes(of: self)
    }

    var date: Date {
        if let meta = smbMeta {
            return meta.modificationDate
        }
        if isOffline {
            return Date()
        }
        if let attrs = inlineAttrs {
            return attrs.date
        }
        FilePathBackgroundTasks.shared.fetchAttributes(of: self)
        return Date()
    }
    var formattedModificationDate: String {
        if let meta = smbMeta {
            return meta.modificationDate.formatted(dateFormat)
        }
        if isOffline {
            return "—"
        }
        if let attrs = inlineAttrs {
            return attrs.date.formatted(dateFormat)
        }
        FilePathBackgroundTasks.shared.fetchAttributes(of: self)
        return "Fetching..."
    }
    var isoFormattedModificationDate: String {
        if let meta = smbMeta {
            return meta.modificationDate.iso8601String
        }
        if isOffline {
            return "—"
        }
        if let attrs = inlineAttrs {
            return attrs.date.iso8601String
        }
        FilePathBackgroundTasks.shared.fetchAttributes(of: self)
        return "Fetching..."
    }

    var size: Int {
        if let meta = smbMeta {
            return Int(meta.size)
        }
        if isOffline {
            return 0
        }
        if let attrs = inlineAttrs {
            return attrs.size
        }
        FilePathBackgroundTasks.shared.fetchAttributes(of: self)
        return 0
    }

    var humanizedFileSize: String {
        if let meta = smbMeta {
            return Int(meta.size).humanSize
        }
        if isOffline {
            return "—"
        }
        if let attrs = inlineAttrs {
            return attrs.size.humanSize
        }
        FilePathBackgroundTasks.shared.fetchAttributes(of: self)
        return "—"
    }
    /// Read through `memoz` while SwiftUI builds a row, so this must never touch the disk.
    /// `NSWorkspace.icon(forFile:)` reads the file (and a bundle's Info.plist and .icns), and the
    /// `isDir` check it used to make is a `stat`, so a path on a stalled mount froze the window
    /// (CLING-12, CLING-3F, CLING-35). Answer from the file's type alone and let the background
    /// fetch overwrite this memo with the real icon, the same way `fetchAttributes` already does.
    var icon: NSImage {
        FilePathBackgroundTasks.shared.icon(for: self)
    }
    var sourceIndex: String {
        ""
    }
}

// #Preview {
//     ContentView()
// }

// MARK: - NeedsProView

func getPro() {
    guard let paddle, let product else { return }
    if !proactive, product.licenseCode == nil {
        PRO?.showCheckout()
        return
    }

    if PRO?.onTrial == true {
        paddle.showProductAccessDialog(with: product)
        return
    }
}

// MARK: - NeedsProView

struct NeedsProView: View {
    var size: CGFloat = 12
    var color: Color = .secondary

    @ObservedObject var pro: LowtechPro

    var body: some View {
        HStack(spacing: 4) {
            Text("Needs a")
                .foregroundColor(color)
                .semibold(size)
            Button("Cling Pro") { getPro() }
                .buttonStyle(FlatButton(color: color.opacity(0.3), textColor: color.textColor()))
                .font(.semibold(size - 1))
                .fixedSize()
            Text("licence")
                .foregroundColor(color)
                .semibold(size)
        }.opacity(pro.active ? 0 : 1)
    }
}

// MARK: - NeedsProModifier

struct NeedsProModifier: ViewModifier {
    @Binding var showPopover: Bool
    @ObservedObject var pro: LowtechPro

    func body(content: Content) -> some View {
        if pro.active {
            content
        } else {
            content
                .onTapGesture {
                    showPopover = true
                }
                .popover(isPresented: $showPopover) {
                    PaddedPopoverView(background: Color.red.brightness(0.1).any) {
                        NeedsProView(size: 16, color: .black.opacity(0.8), pro: pro)
                    }
                }
        }
    }
}

extension View {
    func needsPro(clicked: Binding<Bool>) -> some View {
        guard let pro = PM.pro else { return any }
        return modifier(NeedsProModifier(showPopover: clicked, pro: pro)).any
    }

    func hideOnPro() -> some View {
        guard let pro = PM.pro else { return any }
        return Group {
            if pro.active {
                self
            }
        }.any
    }
}

// MARK: - SearchBarKeyHandlers

struct SearchBarKeyHandlers: ViewModifier {
    var focused: FocusState<FocusedField?>.Binding
    @Binding var query: String
    @Binding var historyIndex: Int
    @Binding var querySaved: String
    @Binding var navigatingHistory: Bool
    @Binding var showHistorySuggestions: Bool
    @Binding var showSuggestionsList: Bool
    @Binding var suggestionIndex: Int

    var inlineSuggestion: String?
    var historySuggestions: [String]
    /// Where ↓ lands when leaving the search field: the stash table when the selection lives there.
    var tableFocusTarget: FocusedField = .list

    func body(content: Content) -> some View {
        content
            .onKeyPress(.upArrow) {
                guard focused.wrappedValue == .search else { return .ignored }
                if isIMEComposing() {
                    return .ignored
                }
                if showSuggestionsList, !historySuggestions.isEmpty {
                    if suggestionIndex > 0 {
                        suggestionIndex -= 1
                    } else {
                        showSuggestionsList = false
                        suggestionIndex = -1
                    }
                    return .handled
                }
                let history = SearchHistory.shared.entries
                guard !history.isEmpty else { return .ignored }
                if historyIndex == -1 {
                    querySaved = query
                }
                let newIndex = min(historyIndex + 1, history.count - 1)
                if newIndex != historyIndex {
                    historyIndex = newIndex
                    navigatingHistory = true
                    query = history[newIndex]
                }
                lastHistoryStep = Date()
                return .handled
            }
            .onKeyPress(.downArrow) {
                guard focused.wrappedValue == .search else { return .ignored }
                if isIMEComposing() {
                    return .ignored
                }
                // A quick ↓ comes forward through past searches again; once one has stayed a moment, ↓ keeps it and
                // goes on into its results.
                if historyIndex >= 0, Date().timeIntervalSince(lastHistoryStep) >= SearchHistory.settleDelay {
                    historyIndex = -1
                    focused.wrappedValue = tableFocusTarget
                    return .handled
                }
                if historyIndex > 0 {
                    historyIndex -= 1
                    navigatingHistory = true
                    query = SearchHistory.shared.entries[historyIndex]
                    lastHistoryStep = Date()
                    return .handled
                } else if historyIndex == 0 {
                    historyIndex = -1
                    navigatingHistory = true
                    query = querySaved
                    lastHistoryStep = Date()
                    return .handled
                }
                if showSuggestionsList, !historySuggestions.isEmpty {
                    if suggestionIndex < historySuggestions.count - 1 {
                        suggestionIndex += 1
                        return .handled
                    }
                    showSuggestionsList = false
                    suggestionIndex = -1
                }
                focused.wrappedValue = tableFocusTarget
                return .handled
            }
            .onKeyPress(.rightArrow) {
                guard focused.wrappedValue == .search else { return .ignored }
                if isIMEComposing() {
                    return .ignored
                }
                guard let suggestion = inlineSuggestion else { return .ignored }
                // Only intercept when the caret is at the very end of the typed text; otherwise let the
                // arrow move the caret as usual.
                guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
                      editor.selectedRange().length == 0,
                      editor.selectedRange().location == (editor.string as NSString).length
                else { return .ignored }
                // Accept just the next word of the suggestion.
                let suffix = suggestion.dropFirst(query.count)
                var end = suffix.startIndex
                while end < suffix.endIndex, suffix[end] == " " {
                    end = suffix.index(after: end)
                }
                while end < suffix.endIndex, suffix[end] != " " {
                    end = suffix.index(after: end)
                }
                query += String(suffix[suffix.startIndex ..< end])
                return .handled
            }
            .onKeyPress(.tab) {
                guard focused.wrappedValue == .search else { return .ignored }
                if isIMEComposing() {
                    return .ignored
                }
                // Tab accepts the ghost completion in full.
                if let suggestion = inlineSuggestion {
                    query = suggestion
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.return, phases: [.down]) { _ in
                guard focused.wrappedValue == .search else { return .ignored }
                if isIMEComposing() {
                    return .ignored
                }
                if historyIndex >= 0 {
                    historyIndex = -1
                    return .handled
                }
                // With the ⌘↓ list open, Enter accepts the highlighted (or first) suggestion.
                if showSuggestionsList, !historySuggestions.isEmpty {
                    query = historySuggestions[max(suggestionIndex, 0)]
                    showSuggestionsList = false
                    suggestionIndex = -1
                    return .handled
                }
                // While the inline ghost is showing, Enter commits the typed query as-is and just hides
                // the suggestion, instead of moving to the results / running the Enter action. Press it
                // again (no suggestion shown) to get the normal Enter behavior.
                if showHistorySuggestions, inlineSuggestion != nil {
                    showHistorySuggestions = false
                    return .handled
                }
                focused.wrappedValue = .list
                return .handled
            }
    }

    @State private var lastHistoryStep = Date.distantPast

}

// MARK: - RunHistoryRow

struct RunHistoryRow: Identifiable {
    let path: FilePath
    let name: String
    let dir: String
    let count: Int
    let lastRun: Date

    var id: String {
        path.string
    }
}

// MARK: - PathMatcher

/// Paths matched as entries or through a folder above them: an entry stands for itself and everything in it.
struct PathMatcher {
    init(_ paths: some Sequence<String>) {
        exact = Set(paths)
        folders = exact.map { $0 + "/" }
    }

    func contains(_ path: String) -> Bool {
        exact.contains(path) || folders.contains { path.hasPrefix($0) }
    }

    private let exact: Set<String>
    private let folders: [String]
}

private extension [String] {
    /// The folders holding these paths, each once.
    var parents: [String] {
        map { ($0 as NSString).deletingLastPathComponent }.uniqued
    }
}
