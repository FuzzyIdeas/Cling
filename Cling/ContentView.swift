//
//  ContentView.swift
//  Cling
//
//  Created by Alin Panaitiu on 03.02.2025.
//

import AppKit
import Defaults
import Lowtech
import LowtechPro
import SwiftUI
import System
import UniformTypeIdentifiers

// Returns true if an IME (CJK input method, etc.) is currently composing text
// in the focused responder. Key handlers should defer to the IME in that case.
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
            NSApp.windows.first { $0.title == "Cling" }?.level = wm.pinned ? .floating : .normal
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
    @State private var pinHovering = false

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
    @State private var quitHovering = false

    var body: some View {
        let _ = appearance.useGlass
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

                if fuzzy.showLiveIndex {
                    VStack(spacing: 0) {
                        HStack {
                            Spacer()
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

                if showingResults {
                    actionButtonRows
                        .padding(.top, 6)
                }
                StatusBarView().hfill(.leading).padding(.top, 10)
            }

            historySuggestionsOverlay
        }
        .padding(.top, 24)
        .padding([.leading, .trailing])
        .padding(.bottom, 4)
        .alert("File not found", isPresented: Binding(get: { pathNotFoundMessage != nil }, set: { if !$0 { pathNotFoundMessage = nil } })) {
            Button("OK") { pathNotFoundMessage = nil }
        } message: {
            Text(pathNotFoundMessage ?? "")
        }
        .if(!fuzzy.hasFullDiskAccess) { view in
            view.overlay(fullDiskAccessOverlay)
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
                QuickLooker.quicklook(
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
                RightClickMenu(selectedResults: $selectedResults, orderedResults: results)
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

    @Default(.showOpenWithRow) private var showOpenWithRow
    @Default(.showScriptRow) private var showScriptRow

    private var actionButtonRows: some View {
        let rows = VStack {
            ActionButtons(selectedResults: $selectedResults, selectedResultIDs: $selectedResultIDs, focused: $focused)
                .hfill(.leading)
                .padding(.bottom, 4)

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
            if AM.useGlass, #available(macOS 26, *) {
                GlassEffectContainer {
                    rows
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
    @Default(.triggerKeys) private var triggerKeys
    @Default(.showAppKey) private var showAppKey

    @FocusState private var focused: FocusedField?

    @State private var appManager = APP_MANAGER
    @State private var renamedPaths: [FilePath]? = nil
    @State private var fuzzy: FuzzyClient = FUZZY
    @State private var appearance = AM
    @State private var scriptManager: ScriptManager = SM
    @State private var selectedResults = Set<FilePath>()
    @State private var selectedResultIDs = Set<String>()

    @Default(.folderFilters) private var folderFilters
    @Default(.quickFilters) private var quickFilters

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

    @State private var isAddingQuickFilter = false
    @State private var filterID = ""
    @State private var filterSuffix = ""
    @State private var filterQuery = ""
    @State private var filterPostQuery = ""
    @State private var filterDirsOnly = false
    @State private var filterFolders: [FilePath] = []
    @State private var filterKey: SauceKey = .escape

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

    @ViewBuilder
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
            QuickFilterAddSheet(id: $filterID, extensions: $filterSuffix, preQuery: $filterQuery, postQuery: $filterPostQuery, dirsOnly: $filterDirsOnly, folders: $filterFolders, key: $filterKey)
        }
        .sheet(isPresented: $isAddingFolderFilter, onDismiss: handleFolderFilterDismiss) {
            FolderFilterAddSheet(id: $folderFilterID, folders: $folderFilterFolders, key: $folderFilterKey)
        }
    }

    @ViewBuilder
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
        }
        .offset(x: -10)
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
        let ext = filterSuffix.trimmed.isEmpty ? nil : filterSuffix.trimmed
        let pre = filterQuery.trimmed.isEmpty ? nil : filterQuery.trimmed
        let post = filterPostQuery.trimmed.isEmpty ? nil : filterPostQuery.trimmed
        guard !filterID.isEmpty, ext != nil || pre != nil || post != nil || filterDirsOnly else {
            filterID = ""; filterSuffix = ""; filterQuery = ""; filterPostQuery = ""; filterDirsOnly = false
            return
        }
        fuzzy.suppressNextSearch = true
        fuzzy.query = ""
        saveQuickFilter(id: filterID, extensions: ext, preQuery: pre, postQuery: post, dirsOnly: filterDirsOnly, folders: filterFolders.isEmpty ? nil : filterFolders, key: filterKey)
        filterID = ""; filterSuffix = ""; filterQuery = ""; filterPostQuery = ""; filterDirsOnly = false; filterFolders = []
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

        // If ONLY in: tokens, show FolderFilter sheet
        if !inTokens.isEmpty, extTokens.isEmpty, fuzzyTokens.isEmpty {
            folderFilterID = inTokens.count == 1 ? inTokens[0].name.string.prefix(1).uppercased() + inTokens[0].name.string.dropFirst() : ""
            folderFilterFolders = inTokens
            folderFilterKey = getFilterKey(id: folderFilterID)
            isAddingFolderFilter = true
            return
        }

        // Join ALL extension tokens, normalizing *.ext to .ext
        filterSuffix = extTokens.map { $0.hasPrefix("*.") ? "." + $0.dropFirst(2) : String($0) }.joined(separator: " ")
        filterDirsOnly = q.hasSuffix("/")
        filterQuery = fuzzyTokens.joined(separator: " ")
        filterFolders = inTokens

        let name = fuzzyTokens.isEmpty ? extTokens.map(String.init).joined(separator: " ") : fuzzyTokens.joined(separator: " ")
        filterID = name.prefix(1).uppercased() + name.dropFirst()

        // Auto-assign hotkey: first alphanumeric char not already used
        filterKey = getFilterKey(id: filterID)

        isAddingQuickFilter = true
    }

    @State private var cmdDownMonitor: Any?
    @State private var contentShortcutMonitor: Any?

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
                NSApp.windows.first { $0.title == "Cling" }?.level = wm.pinned ? .floating : .normal
                return nil
            }
            // ⌘S → save current query as Quick Filter (when applicable)
            if mods == .command, chars == "s",
               !fuzzy.query.isEmpty, showingResults, proactive
            {
                prefillQuickFilter()
                return nil
            }
            // ⌃0 → sort by score
            if mods == .control, chars == "0" {
                fuzzy.sortField = .score
                fuzzy.reverseSort = true
                return nil
            }
            // Esc → quicklook close / dismiss / clear query (xButton behavior)
            if kc == 53, mods.isEmpty, !showHistorySuggestions, !DropZoneOverlay.shared.isPresenting {
                if QuickLooker.visible {
                    QuickLooker.close()
                    return nil
                }
                if fuzzy.query.isEmpty {
                    if let win = NSApp.windows.first(where: { $0.title == "Cling" }) {
                        AppDelegate.shared.hideOrCloseMainWindow(win)
                    }
                    appManager.lastFrontmostApp?.activate()
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
            // ⌘⌥<letter> → open with app
            if mods == [.command, .option],
               let ch = chars.first,
               let app = fuzzy.openWithAppShortcuts.first(where: { $0.value == ch })?.key
            {
                RH.trackRun(selectedResults)
                NSWorkspace.shared.open(
                    selectedResults.map(\.url), withApplicationAt: app, configuration: .init(),
                    completionHandler: { _, _ in }
                )
                return nil
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

    @State private var showFullHistory = false
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

    private func completionHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.quaternary, lineWidth: 0.5))
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

    @State private var placeholderHint = "Search"
    @State private var placeholderIndex = 0
    @Default(.showSearchHints) private var showSearchHints
    @Default(.searchHintsManuallyEnabled) private var searchHintsManuallyEnabled
    @Default(.searchHintsFirstShownAt) private var searchHintsFirstShownAt

    private var shouldCyclePlaceholder: Bool {
        showSearchHints && fuzzy.query.isEmpty && wm.mainWindowActive
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
        "Example: **`brew python`** *(shows installed Python versions)*",
    ]

    private var xButton: some View {
        Button(action: {
            if QuickLooker.visible {
                QuickLooker.close()
            } else if fuzzy.query.isEmpty {
                dismiss()
                appManager.lastFrontmostApp?.activate()
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

    @State private var windowManager = WM
    @State private var sortOrder = [KeyPathComparator(\FilePath.string)]

    private var results: [FilePath] {
        let base = (fuzzy.noQuery && fuzzy.volumeFilter == nil)
            ? (fuzzy.sortField == .score ? fuzzy.recents : fuzzy.sortedRecents)
            : fuzzy.results
        return base
    }

    @ViewBuilder
    private var resultsList: some View {
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
            .onChange(of: sortOrder) { _, newOrder in
                applySortOrder(newOrder)
            }
            .onChange(of: results) {
                selectFirstResult()
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
    }

    @State private var liveChangeSortOrder = [KeyPathComparator(\FuzzyClient.IndexChange.date, order: .reverse)]
    @State private var liveChangesIndexedOnly = true

    private var sortedLiveChanges: [FuzzyClient.IndexChange] {
        let changes = fuzzy.liveIndexChanges.suffix(2000)
        let filtered: [FuzzyClient.IndexChange]
        if fuzzy.query.trimmingCharacters(in: .whitespaces).isEmpty {
            filtered = Array(changes)
        } else {
            let q = fuzzy.query.lowercased()
            filtered = changes.filter { $0.path.lowercased().contains(q) }
        }
        let afterBlock: [FuzzyClient.IndexChange] = if liveChangesIndexedOnly {
            filtered.filter { change in
                !isPathBlocked(change.path) && !(change.path.hasPrefix(HOME.string) && change.path.isIgnored(in: fsignoreString))
            }
        } else {
            filtered
        }
        return afterBlock.sorted(using: liveChangeSortOrder)
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

    @State private var runHistorySelection = Set<String>()
    @State private var liveIndexSelection = Set<UUID>()
    @State private var pathNotFoundMessage: String?
    @State private var runHistorySortOrder = [KeyPathComparator(\RunHistoryRow.count, order: .reverse)]

    private var sortedRunHistory: [RunHistoryRow] {
        runHistoryRows.sorted(using: runHistorySortOrder)
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
            }.width(min: 100, ideal: 200)

            TableColumn("Path", value: \.dir) { row in
                Text(row.dir)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }.width(min: 100, ideal: 300)

            TableColumn("Last Run", value: \.lastRun) { row in
                Text(row.lastRun.formatted(.dateTime.month().day().hour().minute()))
                    .font(.system(size: 11, design: .monospaced))
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
            }.width(min: 100, ideal: 200)

            TableColumn("Path", value: \.dir) { change in
                Text(change.dir)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }.width(min: 100, ideal: 300)

            TableColumn("Time", value: \.date) { change in
                Text(change.date.formatted(.dateTime.hour().minute().second()))
                    .font(.system(size: 11, design: .monospaced))
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

    private func liveChangeColor(_ kind: FuzzyClient.IndexChange.Kind) -> Color {
        switch kind {
        case .added: .green
        case .removed: .red
        case .modified: .orange
        }
    }

    private var iconColumn: some TableColumnContent<FilePath, KeyPathComparator<FilePath>> {
        TableColumn("", value: \.string) { path in
            Image(nsImage: path.memoz.icon).resizable().frame(width: 16, height: 16)
        }.width(20)
    }

    private var nameColumn: some TableColumnContent<FilePath, KeyPathComparator<FilePath>> {
        TableColumn("Name", value: \.name.string) { path in
            Text(path.name.string).lineLimit(1).truncationMode(.middle)
        }.width(min: 100, ideal: 200)
    }

    private var pathColumn: some TableColumnContent<FilePath, KeyPathComparator<FilePath>> {
        TableColumn("Path", value: \.dir.string) { path in
            Text(path.dir.shellString).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
        }.width(min: 100, ideal: 300)
    }

    private var sizeColumn: some TableColumnContent<FilePath, KeyPathComparator<FilePath>> {
        TableColumn("Size", value: \.memoz.size) { path in
            Text(path.memoz.humanizedFileSize).monospaced().lineLimit(1)
        }.width(min: 60, ideal: 80)
    }

    private var dateColumn: some TableColumnContent<FilePath, KeyPathComparator<FilePath>> {
        TableColumn("Date Modified", value: \.memoz.date) { path in
            Text(path.memoz.formattedModificationDate).monospaced().lineLimit(1)
        }.width(min: 100, ideal: 160)
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

    private func selectFirstResult() {
        if let firstResult = results.first {
            selectedResultIDs = [firstResult.string]
        } else {
            selectedResultIDs.removeAll()
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
                log.error("Error fetching file metadata for \(path): \(error)")
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
    var sourceIndex: String { "" }
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
                while end < suffix.endIndex, suffix[end] == " " { end = suffix.index(after: end) }
                while end < suffix.endIndex, suffix[end] != " " { end = suffix.index(after: end) }
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

    var id: String { path.string }
}
