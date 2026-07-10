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
            return "\(num < 10 ? num.str(decimals: 1) : num.intround.s) MB"
        default:
            let num = d / 1_000_000_000
            return "\(num < 10 ? num.str(decimals: 1) : num.intround.s) GB"
        }
    }
}

let dateFormat = Date.FormatStyle
    .dateTime.year(.padded(4)).month().day(.twoDigits)
    .hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits)

// MARK: - FocusedField

enum FocusedField {
    case search, list, openWith, executeScript
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
        .font(.round(10))
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
        .font(.round(10))
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
                }
                .onDisappear {
                    if let cmdDownMonitor {
                        NSEvent.removeMonitor(cmdDownMonitor)
                    }
                    cmdDownMonitor = nil
                    removeContentShortcutMonitor()
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
                .disabled(!wm.mainWindowActive)
                .quickLookPreview(
                    Binding(get: { quickLook.selection }, set: { quickLook.selection = $0 }),
                    in: quickLook.items
                )
        }
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
                                [.escape]
                        ),
                        phases: [.down], action: handleFilterKeyPress
                    )

                middleRow

                if showingResults {
                    actionButtonRows
                        .padding(.top, 6)
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
        .alert("File not found", isPresented: Binding(get: { pathNotFoundMessage != nil }, set: { if !$0 { pathNotFoundMessage = nil } })) {
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

    private static let placeholderExamples = [
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
        "Example: **`'cat`** *(exact text: finds Cats or vacation, not contact)*",
        "Example: **`brew python`** *(shows installed Python versions)*",
    ]

    @State private var pinHovering = false

    @State private var quitHovering = false

    @State private var quickLook = QLP

    @FocusState private var focused: FocusedField?

    @State private var appManager = APP_MANAGER
    @State private var renamedPaths: [FilePath]? = nil
    @State private var fuzzy: FuzzyClient = FUZZY
    @State private var appearance = AM
    @State private var scriptManager: ScriptManager = SM
    @State private var selectedResults = Set<FilePath>()
    @State private var selectedResultIDs = Set<String>()

    @State private var isAddingQuickFilter = false
    @State private var filterDraft = QuickFilterDraft()

    @State private var cmdDownMonitor: Any?
    @State private var contentShortcutMonitor: Any?

    @State private var showFullHistory = false
    @State private var showSyntaxHelp = false
    // Right-arrow drills into a folder (query becomes `in:<folder>`); left-arrow walks back out.
    @State private var queryDrillStack: [String] = []
    @State private var lastDrillSetQuery: String?
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
    @State private var liveChangesIndexedOnly = true

    @State private var runHistorySelection = Set<String>()
    @State private var liveIndexSelection = Set<UUID>()
    @State private var pathNotFoundMessage: String?
    @State private var runHistorySortOrder = [KeyPathComparator(\RunHistoryRow.count, order: .reverse)]

    /// Keep the user's selection when the results list mutates for reasons other
    /// than a new query (file watching, reindexing). Only drop ids that vanished,
    /// and fall back to the first row if the whole selection is gone.
    @State private var lastSelectionQuery: String? = nil

    @Default(.showFilePreview) private var showFilePreview

    @Default(.showOpenWithRow) private var showOpenWithRow
    @Default(.showScriptRow) private var showScriptRow
    @Default(.toolbarRowBackground) private var toolbarRowBackground
    @Default(.showActionRow) private var showActionRow
    @Default(.shortcutsCoachmarkShown) private var coachmarkShown
    @Default(.onboardingCompleted) private var onboardingCompleted

    @Default(.triggerKeys) private var triggerKeys
    @Default(.showAppKey) private var showAppKey
    @Default(.folderFilters) private var folderFilters
    @Default(.quickFilters) private var quickFilters

    @Default(.showSearchHints) private var showSearchHints
    @Default(.searchHintsManuallyEnabled) private var searchHintsManuallyEnabled
    @Default(.searchHintsFirstShownAt) private var searchHintsFirstShownAt

    /// Whether the normal results table (not a log/history/live view) is showing,
    /// the only context where the file preview panel makes sense.
    private var isShowingResultsTable: Bool {
        !fuzzy.showLiveIndex && !fuzzy.showActivityLog && !fuzzy.showRunHistory && !showFullHistory
    }

    /// Files whose previews are shown: the selected results in table order, falling
    /// back to the first row so the panel is never blank when results exist.
    private var previewPaths: [FilePath] {
        let selected = results.filter { selectedResults.contains($0) }
        if !selected.isEmpty { return selected }
        if let first = results.first { return [first] }
        return []
    }

    /// Roughly a third of the table's width, clamped so it stays usable.
    private var previewWidth: CGFloat {
        let available = wm.size.width - 32
        return min(max(available * 0.26, 300), 520)
    }

    private var filterSubtitle: String? {
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
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var showingResults: Bool {
        !fuzzy.showLiveIndex && !fuzzy.showActivityLog
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

    private var results: [FilePath] {
        (fuzzy.noQuery && fuzzy.volumeFilter == nil)
            ? (fuzzy.sortField == .score ? fuzzy.recents : fuzzy.sortedRecents)
            : fuzzy.results
    }

    private var sortedLiveChanges: [FuzzyClient.IndexChange] {
        let q = fuzzy.query.trimmingCharacters(in: .whitespaces).lowercased()
        // No query: show the most recent slice. With a query: search the whole deduplicated history (bounded,
        // so a change from a day ago is still findable), then cap the rendered rows.
        let filtered: [FuzzyClient.IndexChange] = q.isEmpty
            ? Array(fuzzy.liveIndexChanges.suffix(2000))
            : fuzzy.liveIndexChanges.filter { $0.path.lowercased().contains(q) }
        let afterBlock: [FuzzyClient.IndexChange] = if liveChangesIndexedOnly {
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
            Image(nsImage: path.memoz.icon).resizable().frame(width: 16, height: 16)
        }.width(20)
    }

    private var nameColumn: some TableColumnContent<FilePath, KeyPathComparator<FilePath>> {
        TableColumn("Name", value: \.name.string) { path in
            // .help sets the cell's NSView tooltip (cheap, no layout pass), so the truncated middle is
            // revealed on hover without the per-row measuring that would slow scrolling.
            let name = path.name.string
            Text(name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle).help(name)
        }.width(min: 100, ideal: 200)
    }

    private var pathColumn: some TableColumnContent<FilePath, KeyPathComparator<FilePath>> {
        TableColumn("Path", value: \.dir.string) { path in
            let dir = path.dir.shellString
            Text(dir).font(.system(size: 12, design: .rounded)).tracking(-0.2).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).help(dir)
        }.width(min: 100, ideal: 300)
    }

    private var sizeColumn: some TableColumnContent<FilePath, KeyPathComparator<FilePath>> {
        TableColumn("Size", value: \.memoz.size) { path in
            Text(path.memoz.humanizedFileSize).font(.system(size: 11, design: .monospaced)).lineLimit(1)
        }.width(min: 60, ideal: 80)
    }

    private var dateColumn: some TableColumnContent<FilePath, KeyPathComparator<FilePath>> {
        TableColumn("Date Modified", value: \.memoz.date) { path in
            let date = path.memoz.formattedModificationDate
            Text(date).font(.system(size: 11, design: .monospaced)).lineLimit(1).help(date)
        }.width(min: 100, ideal: 160)
    }

    /// The results/index table next to the optional file preview panel. The
    /// preview steals width from the table instead of growing the window.
    private var middleRow: some View {
        HStack(spacing: 10) {
            middleSection
                .frame(maxWidth: .infinity, maxHeight: .infinity)

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
                    Spacer()
                    Button("Run live index compaction") { fuzzy.compactLiveChangesManually() }
                        .controlSize(.mini)
                        .font(.system(size: 10))
                        .disabled(fuzzy.liveIndexChanges.isEmpty)
                        .help("Collapse duplicate events, keeping the latest change per file")
                        .padding(.vertical, 4)
                    Toggle("Indexed only", isOn: $liveChangesIndexedOnly)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 8).padding(.vertical, 4)
                }
                liveIndexTable
            }
            .raisedPanel()
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
                            .font(.system(size: 11, design: .monospaced))
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
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                    Spacer()
                    if let ms = entry.durationMs {
                        Text(ms >= 1000 ? String(format: "%.1fs", ms / 1000) : String(format: "%.0fms", ms))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 4)
                    }
                    Text(entry.date.formatted(.dateTime.hour().minute().second()))
                        .font(.system(size: 9, design: .monospaced))
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
                            .font(.system(size: 12))
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
                guard keyPress.modifiers.isEmpty else { return .ignored }
                focused = .search
                return .handled
            }
            .onKeyPress(.space) {
                guard focused == .list else {
                    return .ignored
                }
                if !fuzzy.query.isEmpty { SearchHistory.shared.commit(fuzzy.query) }
                QLP.present(
                    urls: selectedResults.count > 1 ? selectedResults.map(\.url) : results.map(\.url),
                    selectedItemIndex: selectedResults.count == 1 ? (results.firstIndex(of: selectedResults.first!) ?? 0) : 0
                )
                return .handled
            }
            .onKeyPress(
                keys: Set(
                    folderFilters.compactMap(\.keyEquivalent) +
                        quickFilters.compactMap(\.keyEquivalent) +
                        (fuzzy.enabledVolumes.isEmpty ? [] : (0 ... fuzzy.enabledVolumes.count).compactMap(\.s.keyEquivalent)) +
                        [.escape]
                ),
                phases: [.down], action: handleFilterKeyPress
            )
            .raisedPanel()
            .contextMenu(forSelectionType: String.self) { ids in
                RightClickMenu(
                    selectedResults: $selectedResults,
                    orderedResults: results,
                    contextPaths: results.filter { ids.contains($0.string) }
                )
                .onAppear {
                    if !ids.isEmpty, !ids.isSubset(of: selectedResultIDs) {
                        selectedResultIDs = ids
                    }
                }
            } primaryAction: { ids in
                let paths = results.filter { ids.contains($0.string) }
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
        // Each row clears its shortcut badges by `badgeClearance` on top and bottom (the Open With /
        // Scripts rows do it inside their pill ScrollViews; the action row gets it here). The bottom
        // clearance is otherwise empty, so a small negative spacing overlaps it to keep the visible
        // gap between rows tight and even.
        let rows = VStack(spacing: -3) {
            ActionButtons(selectedResults: $selectedResults, selectedResultIDs: $selectedResultIDs, focused: $focused)
                .hfill(.leading)
                .padding(.vertical, ActionRowLayout.badgeClearance)

            if showOpenWithRow {
                OpenWithActionButtons(selectedResults: selectedResults)
                    .hfill(.leading)
            }
            if proactive, showScriptRow {
                ScriptActionButtons(selectedResults: selectedResults, focused: $focused)
                    .hfill(.leading)
            }
        }

        return Group {
            if toolbarRowBackground {
                rows
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background {
                        RoundedRectangle(cornerRadius: windowCornerRadius, style: .continuous)
                            .fill(.black.opacity(0.06).shadow(.inner(color: .black.opacity(0.22), radius: 4, y: 1)))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: windowCornerRadius, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.black.opacity(0.25), .white.opacity(0.12)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                    }
            } else {
                rows
            }
        }
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
                    .font(.system(size: 10))
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
                if fuzzy.searching {
                    ProgressView()
                        .controlSize(.small)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: fuzzy.searching)
            xButton
            historyButton
            saveFilterButton
            syntaxHelpButton
        }
        .offset(x: -10)
    }

    private var syntaxHelpButton: some View {
        Button(action: { showSyntaxHelp.toggle() }) {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(.plain)
        .foregroundColor(showSyntaxHelp ? .accentColor : .secondary)
        .focusable(false)
        .help("Search syntax reference (⌘/)")
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
        }
    }

    private var searchBar: some View {
        ZStack(alignment: .leading) {
            if fuzzy.query.isEmpty, !imeComposing {
                Text(LocalizedStringKey(placeholderHint))
                    .foregroundStyle(Color(nsColor: .placeholderTextColor))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .id(placeholderHint)
                    .transition(.opacity)
                    .allowsHitTesting(false)
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
            }
            TextField("", text: $fuzzy.query)
                .textFieldStyle(.plain)
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
                    historySuggestions: historySuggestions
                ))
        }
        .animation(.easeInOut(duration: 0.45), value: placeholderHint)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.quaternary, lineWidth: 0.5))
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
            if imeComposing { imeComposing = false }
            if showFullHistory { showFullHistory = false }
        }
        .onChange(of: focused) {
            showHistorySuggestions = focused == .search && !fuzzy.query.isEmpty
            if focused != .search {
                showSuggestionsList = false
                suggestionIndex = -1
                if imeComposing { imeComposing = false }
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
                placeholderHint = ContentView.placeholderExamples[placeholderIndex]
                placeholderIndex = (placeholderIndex + 1) % ContentView.placeholderExamples.count
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
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Table(of: FilePath.self, selection: $selectedResultIDs, sortOrder: $sortOrder) {
                    iconColumn
                    nameColumn
                    pathColumn
                    sizeColumn
                    dateColumn
                } rows: {
                    ForEach(results, id: \.string) { path in
                        TableRow(path)
                            .draggable(path.url)
                    }
                }
                .scrollContentBackground(.hidden)
                .alternatingRowBackgrounds(.disabled)
                // Fixed row height keeps NSTableView from measuring every inserted row
                // (which would force synchronous per-row stat/icon fetches on a bulk
                // result update and freeze the app — CLING-B). Rows are uniform single
                // line cells, so a constant height is exact, not just an approximation.
                .fixedTableRowHeight(24)
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
                    if lastSelectionQuery != fuzzy.query {
                        lastSelectionQuery = fuzzy.query
                        selectFirstResult()
                    } else {
                        preserveSelectionAcrossResultsUpdate()
                    }
                }
                .onChange(of: selectedResultIDs) {
                    selectedResults = Set(results.filter { selectedResultIDs.contains($0.string) })
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
                .onKeyPress(.rightArrow) {
                    // Drill into the selected folder: replace the query with `in:<folder>`.
                    guard focused == .list, selectedResults.count == 1,
                          let folder = selectedResults.first, folder.memoz.isDir
                    else { return .ignored }
                    let drilled = drillIntoFolderQuery(folder)
                    // A fresh drill (query isn't one we set) starts a new back-stack.
                    if fuzzy.query != lastDrillSetQuery { queryDrillStack.removeAll() }
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
                .focused($focused, equals: .list)
                .transparentTableBackground()
                .padding(6)

                Button(action: {
                    fuzzy.sortField = .score
                    fuzzy.reverseSort = true
                }) {
                    Image(systemName: "flag.pattern.checkered.circle" + (fuzzy.sortField == .score ? ".fill" : ""))
                        .font(.system(size: 14))
                        .opacity(fuzzy.sortField == .score ? 1 : 0.5)
                }
                .buttonStyle(BorderlessButtonStyle())
                .help("Sort by score (Control-0)")
                .padding(.trailing, 12)
                .padding(.top, 9)
            }
            .background(.background.opacity(0.3))

            if !fuzzy.noQuery {
                MissingPathResultsBar(query: fuzzy.query)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clingRequestExcludeSheet)) { notif in
            guard let paths = notif.object as? [FilePath], !paths.isEmpty else { return }
            excludeRequest = ExcludeSheetRequest(paths: paths)
        }
        .sheet(item: $excludeRequest) { request in
            ExcludeFromIndexSheet(paths: request.paths)
                .frame(width: 600, height: 540)
        }
    }

    private var runHistoryTable: some View {
        Table(sortedRunHistory, selection: $runHistorySelection, sortOrder: $runHistorySortOrder) {
            TableColumn("Runs", value: \.count) { row in
                Text("\(row.count)")
                    .font(.system(size: 12, design: .monospaced))
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
                    .font(.system(size: 11, design: .monospaced))
                    .help(row.lastRun.formatted(date: .abbreviated, time: .standard))
            }.width(min: 100, ideal: 120)
        }
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
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(liveChangeColor(change.kind))
            }.width(16)

            TableColumn("Name", value: \.name) { change in
                Text(change.name)
                    .lineLimit(1).truncationMode(.middle)
                    .help(change.name)
            }.width(min: 100, ideal: 200)

            TableColumn("Path", value: \.dir) { change in
                Text(change.dir)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .help(change.dir)
            }.width(min: 100, ideal: 300)

            TableColumn("Time", value: \.date) { change in
                Text(change.date.formatted(.dateTime.hour().minute().second()))
                    .font(.system(size: 11, design: .monospaced))
                    .help(change.date.formatted(date: .abbreviated, time: .standard))
            }.width(min: 70, ideal: 80)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            let paths = ids.compactMap { id in sortedLiveChanges.first { $0.id == id }.map { FilePath($0.path) } }
            filePathContextMenu(paths: paths)
        } primaryAction: { ids in
            let paths = ids.compactMap { id in sortedLiveChanges.first { $0.id == id }.map { FilePath($0.path) } }
            openPathsIfExist(paths)
        }
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
            .font(.system(size: 10, design: .monospaced))
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
            if let path = paths.first { openFinderGetInfo(path) }
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

    private func handleFilterKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        guard keyPress.modifiers == [.option] else { return .ignored }
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
        if let index = keyPress.key.character.wholeNumberValue, let filter = ([FilePath.root] + fuzzy.enabledVolumes)[safe: index] {
            fuzzy.volumeFilter = filter
            result = .handled
        }

        if result == .handled {
            focused = .search
        }
        return result
    }

    private func handleFolderFilterDismiss() {
        guard !folderFilterID.isEmpty, !folderFilterFolders.isEmpty else {
            folderFilterID = ""; folderFilterFolders = []
            return
        }
        fuzzy.suppressNextSearch = true
        fuzzy.query = ""
        saveFolderFilter(id: folderFilterID, folders: folderFilterFolders, key: folderFilterKey)
        folderFilterID = ""; folderFilterFolders = []; folderFilterKey = .escape
    }

    private func handleQuickFilterDismiss() {
        let f = filterDraft.asFilter
        let hasContent = f.extensions != nil || f.exclude != nil || f.match != .both || f.folders?.isEmpty == false || f.rawQuery != nil
        guard !filterDraft.name.trimmed.isEmpty, hasContent else {
            filterDraft = QuickFilterDraft()
            return
        }
        fuzzy.suppressNextSearch = true
        fuzzy.query = ""
        saveQuickFilter(draft: filterDraft, originalID: "")
        filterDraft = QuickFilterDraft()
    }

    private func prefillQuickFilter() {
        let q = fuzzy.query.trimmingCharacters(in: .whitespaces)
        let tokens = q.split(separator: " ")
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path

        // Parse extension tokens (.swift, *.pdf, etc.)
        let extTokens = tokens.filter { $0.hasPrefix(".") || $0.hasPrefix("*.") }
        // Parse in: folder tokens
        let inTokens: [FilePath] = tokens.compactMap { token in
            guard token.hasPrefix("in:"), token.count > 3 else { return nil }
            var path = String(token.dropFirst(3))
            if path.hasPrefix("~") { path = homePath + path.dropFirst() }
            return path.filePath
        }
        let fuzzyTokens = tokens.filter { !$0.hasPrefix(".") && !$0.hasPrefix("*.") && !$0.hasPrefix("in:") }

        // If ONLY in: tokens, show FolderFilter sheet (unchanged).
        if !inTokens.isEmpty, extTokens.isEmpty, fuzzyTokens.isEmpty {
            folderFilterID = inTokens.count == 1 ? inTokens[0].name.string.prefix(1).uppercased() + inTokens[0].name.string.dropFirst() : ""
            folderFilterFolders = inTokens
            folderFilterKey = getFilterKey(id: folderFilterID)
            isAddingFolderFilter = true
            return
        }

        // Always open in structured mode: extensions/folders/match map to fields, and any
        // free-text or operator tokens go into Prepend so nothing is lost.
        filterDraft = QuickFilterDraft()
        filterDraft.extensions = extTokens.map { $0.hasPrefix("*.") ? "." + $0.dropFirst(2) : String($0) }.joined(separator: " ")
        filterDraft.match = q.hasSuffix("/") ? .folders : .both
        filterDraft.folders = inTokens
        filterDraft.prepend = fuzzyTokens.joined(separator: " ")

        let nameSource = fuzzyTokens.isEmpty ? extTokens : fuzzyTokens
        let name = nameSource.map(String.init).joined(separator: " ")
        filterDraft.name = name.prefix(1).uppercased() + name.dropFirst()
        filterDraft.hotkey = getFilterKey(id: filterDraft.name)

        isAddingQuickFilter = true
    }

    private func installContentShortcutMonitor() {
        guard contentShortcutMonitor == nil else { return }
        contentShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Sample IME marked-text state AFTER the field editor handles this
            // keystroke, so the search placeholder hides during composition.
            // Only matters while the query is empty (otherwise the placeholder
            // is already hidden) and when no ⌘/⌃ shortcut is in flight.
            if focused == .search, fuzzy.query.isEmpty {
                let evMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if !evMods.contains(.command), !evMods.contains(.control) {
                    DispatchQueue.main.async {
                        let composing = (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false
                        if composing != imeComposing { imeComposing = composing }
                    }
                }
            } else if imeComposing {
                imeComposing = false
            }
            if NSApp.keyWindow?.attachedSheet != nil { return event }
            if DropZoneOverlay.shared.isPresenting { return event }
            if event.window !== AppDelegate.shared.mainWindow { return event }
            // Let IME handle keys (Esc/arrows/Return/etc.) during active composition.
            if let responder = event.window?.firstResponder as? NSTextInputClient,
               responder.hasMarkedText()
            {
                return event
            }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let kc = event.keyCode
            let chars = (event.charactersIgnoringModifiers ?? "").lowercased()

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
            // ⌘S → save current query as Quick Filter (when applicable)
            if mods == .command, chars == "s",
               !fuzzy.query.isEmpty, showingResults, proactive
            {
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
        case .score, .kind: break
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
        if let firstResult = results.first {
            selectedResultIDs = [firstResult.string]
        } else {
            selectedResultIDs.removeAll()
        }
    }

    private func preserveSelectionAcrossResultsUpdate() {
        let resultIDs = Set(results.map(\.string))
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

        // Check SMB metadata cache for instant size/date without network round trip
        if let volume = path.volume,
           let smbCache = FUZZY.smbMetadataCaches[volume],
           let meta = smbCache.get(path.string)
        {
            attrCache[path] = [:]

            let date = meta.modificationDate
            path.cache(date.formatted(dateFormat), forKey: \FilePath.formattedModificationDate)
            path.cache(date.iso8601String, forKey: \FilePath.isoFormattedModificationDate)
            path.cache(date, forKey: \FilePath.date)

            let size = Int(meta.size)
            path.cache(size.humanSize, forKey: \FilePath.humanizedFileSize)
            path.cache(size, forKey: \FilePath.size)

            FUZZY.reloadResults()
            return
        }

        let fetcher = DispatchWorkItem {
            let attrs: [FileAttributeKey: Any]
            let icon: NSImage
            do {
                attrs = try FileManager.default.attributesOfItem(atPath: path.string)
                icon = NSWorkspace.shared.icon(forFile: path.string)
            } catch {
                log.error("Error fetching file metadata for \(path.string): \(error.localizedDescription)")
                mainActor { self.attrFetchers[path] = nil }
                return
            }

            mainActor {
                self.attrCache[path] = attrs
                self.attrFetchers[path] = nil

                let date = (attrs[.modificationDate] as? Date) ?? Date()
                path.cache(date.formatted(dateFormat), forKey: \FilePath.formattedModificationDate)
                path.cache(date.iso8601String, forKey: \FilePath.isoFormattedModificationDate)
                path.cache(date, forKey: \FilePath.date)

                let size = (attrs[.size] as? UInt64)?.i ?? 0
                path.cache(size.humanSize, forKey: \FilePath.humanizedFileSize)
                path.cache(size, forKey: \FilePath.size)

                path.cache(icon, forKey: \FilePath.icon)
                FUZZY.reloadResults()
            }

        }
        attrFetchers[path] = fetcher
        DispatchQueue.global(qos: .background).async(execute: fetcher)
    }

    private var attrFetchers: [FilePath: DispatchWorkItem] = [:]
    private var attrCache: [FilePath: [FileAttributeKey: Any]] = [:]

}

@MainActor
extension FilePath {
    private var smbMeta: SMBFileMetadata? {
        guard let volume else { return nil }
        return FUZZY.smbMetadataCaches[volume]?.get(string)
    }

    var date: Date {
        if let meta = smbMeta { return meta.modificationDate }
        guard !memoz.isOnExternalVolume else {
            FilePathBackgroundTasks.shared.fetchAttributes(of: self)
            return Date()
        }
        return modificationDate ?? Date()
    }
    var formattedModificationDate: String {
        if let meta = smbMeta { return meta.modificationDate.formatted(dateFormat) }
        guard !memoz.isOnExternalVolume else {
            FilePathBackgroundTasks.shared.fetchAttributes(of: self)
            return "Fetching..."
        }
        return (modificationDate ?? Date()).formatted(dateFormat)
    }
    var isoFormattedModificationDate: String {
        if let meta = smbMeta { return meta.modificationDate.iso8601String }
        guard !memoz.isOnExternalVolume else {
            FilePathBackgroundTasks.shared.fetchAttributes(of: self)
            return "Fetching..."
        }
        return (modificationDate ?? Date()).iso8601String
    }

    var size: Int {
        if let meta = smbMeta { return Int(meta.size) }
        guard !memoz.isOnExternalVolume else {
            FilePathBackgroundTasks.shared.fetchAttributes(of: self)
            return 0
        }
        return fileSize() ?? 0
    }

    var humanizedFileSize: String {
        if let meta = smbMeta { return Int(meta.size).humanSize }
        guard !memoz.isOnExternalVolume else {
            FilePathBackgroundTasks.shared.fetchAttributes(of: self)
            return "—"
        }
        return (fileSize() ?? 0).humanSize
    }
    var icon: NSImage {
        if memoz.isOnExternalVolume {
            if memoz.isDir {
                return NSWorkspace.shared.icon(for: .folder)
            }
            let ext = url.pathExtension
            if !ext.isEmpty, let utType = UTType(filenameExtension: ext) {
                return NSWorkspace.shared.icon(for: utType)
            }
            return NSWorkspace.shared.icon(for: .plainText)
        }
        return NSWorkspace.shared.icon(forFile: string)
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

    func body(content: Content) -> some View {
        content
            .onKeyPress(.upArrow) {
                guard focused.wrappedValue == .search else { return .ignored }
                if isIMEComposing() { return .ignored }
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
                if historyIndex == -1 { querySaved = query }
                let newIndex = min(historyIndex + 1, history.count - 1)
                if newIndex != historyIndex {
                    historyIndex = newIndex
                    navigatingHistory = true
                    query = history[newIndex]
                }
                return .handled
            }
            .onKeyPress(.downArrow) {
                guard focused.wrappedValue == .search else { return .ignored }
                if isIMEComposing() { return .ignored }
                if historyIndex > 0 {
                    historyIndex -= 1
                    navigatingHistory = true
                    query = SearchHistory.shared.entries[historyIndex]
                    return .handled
                } else if historyIndex == 0 {
                    historyIndex = -1
                    navigatingHistory = true
                    query = querySaved
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
                focused.wrappedValue = .list
                return .handled
            }
            .onKeyPress(.rightArrow) {
                guard focused.wrappedValue == .search else { return .ignored }
                if isIMEComposing() { return .ignored }
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
                if isIMEComposing() { return .ignored }
                // Tab accepts the ghost completion in full.
                if let suggestion = inlineSuggestion {
                    query = suggestion
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.return, phases: [.down]) { _ in
                guard focused.wrappedValue == .search else { return .ignored }
                if isIMEComposing() { return .ignored }
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
