import Defaults
import KeyboardShortcuts
import Lowtech
import OSLog
import SwiftUI
import System

private let log = Logger(subsystem: clingSubsystem, category: "ActionButtons")

// MARK: - ActionButtons

struct ActionButtons: View {
    @Binding var selectedResults: Set<FilePath>
    @Binding var selectedResultIDs: Set<String>
    var focused: FocusState<FocusedField?>.Binding

    @State private var appManager: AppManager = APP_MANAGER
    @State private var fuzzy: FuzzyClient = FUZZY
    @State private var scriptManager: ScriptManager = SM
    @Default(.suppressTrashConfirm) var suppressTrashConfirm: Bool
    @Default(.enterPastesToFrontmostTerminal) var enterPastesToFrontmostTerminal: Bool
    @Default(.terminalApp) var terminalApp
    @Default(.editorApp) var editorApp
    @Default(.shelfApp) var shelfApp
    @Default(.copyPathsWithTilde) var copyPathsWithTilde
    @Default(.showActionRow) var showActionRow
    @Default(.barActions) var barActions
    @Default(.hiddenActions) var hiddenActions
    @Default(.toolbarShowDividers) var showDividers
    @Default(.showActionMenu) var showActionMenu
    @Default(.toolbarLabelStyle) var labelStyle
    @Default(.toolbarDensity) var density
    @ObservedObject var km = KM
    @ObservedObject private var sendManager = SendManager.shared
    @Default(.shortcutBadgesRevealedOnce) private var badgesRevealedOnce
    @State private var badgesVisible = false
    @State private var badgeRevealTask: Task<Void, Never>?

    var body: some View {
        let inTerminal = appManager.frontmostAppIsTerminal
        let showingAlternates = (km.ralt || km.lalt) && !isAnySheetOpen
        let hidden = hiddenActions

        HStack {
            if showActionRow {
                if showingAlternates {
                    dropToFocusedElementButton
                    dropToZoneButton
                    openWithFrontmostAppButton
                    Spacer()
                    if !hidden.contains(.copy) {
                        copyFilesButton.disabled(focused.wrappedValue != .list)
                    }
                    if !hidden.contains(.copyPaths) {
                        copyPathsButton
                    }
                    if !hidden.contains(.trash) {
                        trashButton.disabled(focused.wrappedValue != .list)
                    }
                } else {
                    HStack(spacing: density.spacing) {
                        ForEach(ToolbarAction.segmentOrder, id: \.self) { segment in
                            let items = visibleBarActions.filter { $0.segment == segment }
                            if !items.isEmpty {
                                if segment == .destructive {
                                    Spacer(minLength: 8)
                                } else if showDividers, segment != ToolbarAction.segmentOrder.first {
                                    Divider().frame(height: 16)
                                }
                                ForEach(items) { action in actionButton(action) }
                            }
                        }
                        overflowButton
                    }
                    .font(.system(size: density.fontSize))
                    .buttonStyle(.text(color: .fg.warm.opacity(0.9)))
                }
            }
        }
        .font(.system(size: 10))
        .buttonStyle(.text(color: .fg.warm.opacity(0.9)))
        .lineLimit(1)
        .background(openWithPickerButton)
        .sheet(isPresented: $isPresentingCopyToSheet) {
            FileOperationSheet(operation: .copy, files: selectedResults.arr)
        }
        .sheet(isPresented: $isPresentingMoveToSheet) {
            FileOperationSheet(operation: .move, files: selectedResults.arr) { movedPaths in
                selectedResults.subtract(movedPaths)
                fuzzy.results = fuzzy.results.filter { !movedPaths.contains($0) }
            }
        }
        .onAppear { installShortcutMonitor() }
        .onDisappear { removeShortcutMonitor() }
        .onReceive(NotificationCenter.default.publisher(for: .clingRequestRename)) { _ in
            guard !selectedResults.isEmpty else { return }
            isPresentingRenameView = true
        }
        .onChange(of: sendManager.linkCopiedTick) { _, _ in
            flashCopied(.sendSecurely, text: "Link copied")
        }
        .onChange(of: cmdHeld) { _, held in
            badgeRevealTask?.cancel()
            guard held else {
                withAnimation(.easeOut(duration: 0.12)) { badgesVisible = false }
                return
            }
            // First reveal after the coachmark is instant, to reward the discovery.
            // Afterwards the badges only show if ⌘ is held a beat, so plain ⌘ hotkeys don't flash them.
            if !badgesRevealedOnce {
                badgesRevealedOnce = true
                withAnimation(.easeOut(duration: 0.12)) { badgesVisible = true }
            } else {
                badgeRevealTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, cmdHeld else { return }
                    withAnimation(.easeOut(duration: 0.12)) { badgesVisible = true }
                }
            }
        }
        .confirmationDialog(
            "Archive folders before sending?",
            isPresented: Binding(
                get: { sendManager.pendingFolderConfirm != nil },
                set: { if !$0 { sendManager.cancelPendingSend() } }
            ),
            presenting: sendManager.pendingFolderConfirm
        ) { _ in
            Button("Create archive & send") { sendManager.confirmPendingSend() }
            Button("Cancel", role: .cancel) { sendManager.cancelPendingSend() }
        } message: { pending in
            let n = sendManager.folderCount(in: pending.files)
            Text("\(n) folder\(n == 1 ? "" : "s") will be archived into a .zip before sending.")
        }
    }

    @State private var shortcutMonitor: Any?

    private func installShortcutMonitor() {
        guard shortcutMonitor == nil else { return }
        let selB = $selectedResults
        let copyToB = $isPresentingCopyToSheet
        let moveToB = $isPresentingMoveToSheet
        let renameB = $isPresentingRenameView
        let confirmB = $isPresentingConfirm
        let openWithB = $isPresentingOpenWithPicker
        let copiedFilesB = $copiedFiles
        let copiedPathsB = $copiedPaths
        let focusBinding = focused
        let enterPastesB = $enterPastesToFrontmostTerminal

        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Only act on key events delivered to the main Cling window — never to Settings,
            // Onboarding, the borderless DropZoneOverlay panel, or any sheet on top of those.
            if NSApp.keyWindow?.attachedSheet != nil { return event }
            if DropZoneOverlay.shared.isPresenting { return event }
            if event.window !== AppDelegate.shared.mainWindow { return event }
            // Let an active IME (Pinyin etc.) commit/navigate during composition.
            if let responder = event.window?.firstResponder as? NSTextInputClient,
               responder.hasMarkedText()
            {
                return event
            }

            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
            let kc = event.keyCode
            let sel = selB.wrappedValue
            let focus = focusBinding.wrappedValue
            let inTerminal = APP_MANAGER.frontmostAppIsTerminal

            let isReturn = kc == 36 || kc == 76
            let isDelete = kc == 51 || kc == 117
            // When disabled, plain ⏎ always opens even if a terminal is frontmost.
            // Only affects the plain-⏎ branches below; the ⌘⇧⏎ variants keep using raw `inTerminal`.
            let enterPastesToTerminal = inTerminal && enterPastesB.wrappedValue

            if sel.isEmpty { return event }

            // ⏎ Open (default app, non-terminal context) — context-dependent, not rebindable
            if isReturn, mods.isEmpty, !enterPastesToTerminal {
                RH.trackRun(sel)
                for url in sel.map(\.url) {
                    NSWorkspace.shared.open(url)
                }
                return nil
            }
            // ⌘⇧⏎ Open (default app, terminal context) — context-dependent, not rebindable
            if isReturn, mods == [.command, .shift], inTerminal {
                RH.trackRun(sel)
                for url in sel.map(\.url) {
                    NSWorkspace.shared.open(url)
                }
                return nil
            }
            // ⏎ Paste to terminal — context-dependent, not rebindable
            if isReturn, mods.isEmpty, enterPastesToTerminal {
                RH.trackRun(sel)
                APP_MANAGER.pasteToFrontmostApp(paths: sel.arr, separator: " ", quoted: true)
                return nil
            }
            // ⌘⇧⏎ Paste to non-terminal — context-dependent, not rebindable
            if isReturn, mods == [.command, .shift], !inTerminal {
                RH.trackRun(sel)
                APP_MANAGER.pasteToFrontmostApp(paths: sel.arr, separator: "\n", quoted: false)
                return nil
            }

            // Window-local dispatch from user-rebindable shortcuts. NOT global hotkeys.
            // copy and trash originally required focus == .list in the per-branch keyDown handler;
            // all other rebindable actions had no focus guard. Reproduce that exactly here.
            // Note: .open and .pasteToFrontmost are handled above with context-dependent Return-key logic.
            //
            // Skip actions that have a native .keyboardShortcut on an Action Menu item — those fire
            // via macOS menu key equivalents even when the menu is closed, so dispatching them here
            // too would execute the action twice. An action is "owned by the menu" when:
            //   showActionMenu == true  AND  action is not hidden  AND  action is not in barActions
            //   AND  action.segment != .alternate
            if let pressed = KeyboardShortcuts.Shortcut(event: event) {
                let currentHidden = Defaults[.hiddenActions]
                let currentBarActions = Defaults[.barActions]
                let menuEnabled = Defaults[.showActionMenu]
                let handled = MainActor.assumeIsolated {
                    for action in ToolbarAction.rebindable where !currentHidden.contains(action.id) {
                        if (action.id == .copy || action.id == .trash), focusBinding.wrappedValue != .list { continue }
                        // If this action is rendered as an Action Menu item with a native shortcut,
                        // the menu key equivalent handles dispatch — skip to avoid double-fire.
                        if menuEnabled,
                           !currentHidden.contains(action.id),
                           !currentBarActions.contains(action.id),
                           action.segment != .alternate
                        { continue }
                        guard let bound = KeyboardShortcuts.getShortcut(for: ClingShortcuts.name(for: action.id)),
                              bound == pressed, isAvailable(action.id) else { continue }
                        execute(action.id)
                        return true
                    }
                    return false
                }
                if handled { return nil }
            }

            // ⌘⌥C Copy to... (non-rebindable ⌥ variant; ⌘C is handled above by the registry)
            if chars == "c", mods == [.command, .option], focus == .list {
                copyToB.wrappedValue = true
                return nil
            }
            // ⌘⌥⇧C Copy filenames (non-rebindable ⌥ variant; ⌘⇧C is handled above by the registry)
            if chars == "c", mods == [.command, .shift, .option] {
                withAnimation(.fastSpring) { copiedPathsB.wrappedValue = true }
                mainAsyncAfter(ms: 150) {
                    withAnimation(.easeOut(duration: 0.1)) { copiedPathsB.wrappedValue = false }
                }
                let filenames = sel.map(\.name.string)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    APP_MANAGER.frontmostAppIsTerminal
                        ? filenames.map { $0.replacingOccurrences(of: " ", with: "\\ ") }.joined(separator: " ")
                        : filenames.joined(separator: "\n"), forType: .string
                )
                return nil
            }
            // ⌘⌥⌫ Permanent delete (non-rebindable ⌥ variant; ⌘⌫ trash is handled above by the registry)
            if isDelete, focus == .list, mods == [.command, .option],
               !sel.contains(where: \.isOnReadOnlyVolume)
            {
                Self.performDelete(selection: selB)
                return nil
            }

            return event
        }
    }

    private func removeShortcutMonitor() {
        if let m = shortcutMonitor {
            NSEvent.removeMonitor(m)
            shortcutMonitor = nil
        }
    }

    private static func performTrash(selection: Binding<Set<FilePath>>) {
        var removed = Set<FilePath>()
        for path in selection.wrappedValue {
            log.info("Trashing \(path.shellString)")
            do {
                try FileManager.default.trashItem(at: path.url, resultingItemURL: nil)
                removed.insert(path)
            } catch {
                log.error("Error trashing \(path.shellString): \(error.localizedDescription)")
            }
        }
        selection.wrappedValue.subtract(removed)
        FUZZY.results = FUZZY.results.filter { !removed.contains($0) && $0.exists }
    }

    private static func performDelete(selection: Binding<Set<FilePath>>) {
        var removed = Set<FilePath>()
        for path in selection.wrappedValue {
            log.info("Permanently deleting \(path.shellString)")
            do {
                try FileManager.default.removeItem(at: path.url)
                removed.insert(path)
            } catch {
                log.error("Error deleting \(path.shellString): \(error.localizedDescription)")
            }
        }
        selection.wrappedValue.subtract(removed)
        FUZZY.results = FUZZY.results.filter { !removed.contains($0) && $0.exists }
    }

    private func pasteToFrontmostApp(inTerminal: Bool) {
        RH.trackRun(selectedResults)
        if inTerminal {
            appManager.pasteToFrontmostApp(paths: selectedResults.arr, separator: " ", quoted: true)
        } else {
            appManager.pasteToFrontmostApp(
                paths: selectedResults.arr, separator: "\n", quoted: false
            )
        }
    }

    private var showInFinderButton: some View {
        Button("⌘⏎ Show in Finder") {
            showInFinder()
        }
        .help("Show the selected files in Finder")
    }

    @ViewBuilder
    private var openInTerminalButton: some View {
        if terminalApp.existingFilePath != nil {
            Button("⌘T Open in \(terminalApp.filePath?.stem ?? "Terminal")") {
                openInTerminal()
            }
            .help("Open the selected files in Terminal")
        }
    }
    @ViewBuilder
    private var openInEditorButton: some View {
        if editorApp.existingFilePath != nil {
            Button("⌘E Edit") {
                openInEditor()
            }
            .help("Open the selected files in the configured editor (\(editorApp.filePath?.stem ?? "TextEdit"))")
        }
    }
    @ViewBuilder
    private var shelveButton: some View {
        if shelfApp.existingFilePath != nil {
            Button("⌘S Shelve in \(shelfApp.filePath?.stem ?? "shelf app")") {
                shelve()
            }
            .help("Shelve the selected files in \(shelfApp.filePath?.stem ?? "shelf app")")
        }
    }

    @ViewBuilder
    private var copyFilesButton: some View {
        if km.ralt || km.lalt {
            Button("⌘⌥C Copy to...") {
                isPresentingCopyToSheet = true
            }
            .help("Copy the selected files to a folder")
        } else {
            Button(action: copyFiles) {
                Text("⌘C Copy")
            }
            .help("Copy the selected files")
            .background(Color.inverted.opacity(copiedFiles ? 1.0 : 0.0))
            .shadow(color: Color.black.opacity(copiedFiles ? 0.1 : 0.0), radius: 3)
            .scaleEffect(copiedFiles ? 1.1 : 1)
        }
    }

    @ViewBuilder
    private var copyPathsButton: some View {
        if km.ralt || km.lalt {
            Button(action: copyFilenames) {
                Text("⌘⌥⇧C Copy filenames")
            }
            .help("Copy the filenames of the selected files")
            .background(Color.inverted.opacity(copiedPaths ? 1.0 : 0.0))
            .shadow(color: Color.black.opacity(copiedPaths ? 0.1 : 0.0), radius: 3)
            .scaleEffect(copiedPaths ? 1.1 : 1)
        } else {
            Button(action: copyPaths) {
                Text("⌘⇧C Copy paths")
            }
            .help("Copy the paths of the selected files")
            .background(Color.inverted.opacity(copiedPaths ? 1.0 : 0.0))
            .shadow(color: Color.black.opacity(copiedPaths ? 0.1 : 0.0), radius: 3)
            .scaleEffect(copiedPaths ? 1.1 : 1)
        }
    }

    @State private var copiedPaths = false
    @State private var copiedFiles = false

    private var openWithPickerButton: some View {
        Button("") {
            openWithPicker()
        }
        .buttonStyle(.plain)
        .opacity(0)
        .frame(width: 0, height: 0)
        .sheet(isPresented: $isPresentingOpenWithPicker) {
            OpenWithPickerView(fileURLs: selectedResults.map(\.url))
                .font(.medium(13))
                .focused(focused, equals: .openWith)
        }
        .disabled(selectedResults.isEmpty || fuzzy.openWithAppShortcuts.isEmpty)
    }

    @ViewBuilder
    private var trashButton: some View {
        if km.ralt || km.lalt {
            Button("⌘⌥⌫ Delete", role: .destructive) {
                permanentlyDelete()
            }
            .help("Permanently delete the selected files")
            .disabled(selectedResults.contains(where: \.isOnReadOnlyVolume))
        } else {
            Button("⌘⌫ Trash", role: .destructive) {
                trashSelected()
            }
            .help("Move the selected files to the trash")
            .disabled(selectedResults.contains(where: \.isOnReadOnlyVolume))
            .confirmationDialog(
                "Are you sure?",
                isPresented: $isPresentingConfirm
            ) {
                Button("Move to trash") {
                    moveToTrash()
                }.keyboardShortcut(.defaultAction)
            }
            .dialogIcon(Image(systemName: "trash.circle.fill"))
            .dialogSuppressionToggle(isSuppressed: $suppressTrashConfirm)
        }
    }

    private func permanentlyDelete() {
        var removed = Set<FilePath>()
        for path in selectedResults {
            log.info("Permanently deleting \(path.shellString)")
            do {
                try FileManager.default.removeItem(at: path.url)
                removed.insert(path)
            } catch {
                log.error("Error deleting \(path.shellString): \(error.localizedDescription)")
            }
        }

        selectedResults.subtract(removed)
        fuzzy.results = fuzzy.results.filter { !removed.contains($0) && $0.exists }
    }

    private var results: [FilePath] {
        (fuzzy.noQuery && fuzzy.volumeFilter == nil)
            ? (fuzzy.sortField == .score ? fuzzy.recents : fuzzy.sortedRecents)
            : fuzzy.results
    }

    private var quicklookButton: some View {
        Button(action: quicklook) {
            Text("\(focused.wrappedValue == .search ? "⌘Y" : "⎵") Quicklook")
        }
        .help("Preview the selected files")
    }

    private var renameButton: some View {
        Button("⌘R Rename") {
            renameSelected()
        }
        .sheet(isPresented: $isPresentingRenameView) {
            RenameView(originalPaths: selectedResults.arr, submission: $renameSubmission)
        }
        .onChange(of: renameSubmission) {
            renameFiles()
        }
        .help("Rename the selected files")
    }

    private func openButton(inTerminal: Bool) -> some View {
        Button(action: openSelectedResults) {
            Text(inTerminal ? "⌘⇧⏎" : "⏎") + Text(" Open")
        }
        .help("Open the selected files with their default app")
    }

    @ViewBuilder
    private var dropToFocusedElementButton: some View {
        if let app = appManager.lastFrontmostApp,
           let target = appManager.axDropTarget(for: app)
        {
            Button("⌥⏎ Drop into \(target.name)") {
                dropToFocusedElement()
            }
            .help("Drop into \(target.name) using a real drag-drop event")
            .disabled(selectedResults.isEmpty)
        }
    }

    @ViewBuilder
    private var dropToZoneButton: some View {
        Button("⌥⇧⏎ Drag and drop to zone") {
            dropToZone()
        }
        .help("Pick a screen zone with the keyboard, then drop the files there")
        .disabled(selectedResults.isEmpty)
    }

    @ViewBuilder
    private var openWithFrontmostAppButton: some View {
        if let app = appManager.lastFrontmostApp,
           let appURL = app.bundleURL,
           !isConfiguredHelperApp(appURL)
        {
            Button("⌘⌥⏎ Open with \(app.name ?? "frontmost app")") {
                openWithFrontmostApp()
            }
            .help("Open the selected files with \(app.name ?? "the frontmost app")")
            .disabled(selectedResults.isEmpty)
        }
    }

    private func isConfiguredHelperApp(_ url: URL) -> Bool {
        let target = url.resolvingSymlinksInPath().path
        let helpers = [terminalApp, editorApp, shelfApp].compactMap {
            $0.existingFilePath?.url.resolvingSymlinksInPath().path
        }
        return helpers.contains(target)
    }

    // MARK: - Registry-driven toolbar

    /// Returns false only when a required external resource (terminal, editor) is not configured.
    /// Selection-dependent actions (copy, trash) return true here so they remain visible but disabled.
    private func isConfigured(_ id: ActionID) -> Bool {
        switch id {
        case .openInTerminal: return terminalApp.existingFilePath != nil
        case .openInEditor:   return editorApp.existingFilePath != nil
        case .shelve:         return shelfApp.existingFilePath != nil
        default:              return true
        }
    }

    var cmdHeld: Bool { (km.rcmd || km.lcmd) && !isAnySheetOpen }

    var visibleBarActions: [ToolbarAction] {
        barActions.compactMap { ToolbarAction.byID[$0] }
            .filter { !hiddenActions.contains($0.id) && isConfigured($0.id) && $0.segment != .alternate }
    }

    var overflowActions: [ToolbarAction] {
        ToolbarAction.all.filter {
            $0.segment != .alternate && !hiddenActions.contains($0.id) && !barActions.contains($0.id)
                && isConfigured($0.id)
        }
    }

    @ViewBuilder func actionButton(_ action: ToolbarAction) -> some View {
        let color: Color = action.isDestructive ? .red.opacity(0.9) : .fg.warm.opacity(0.9)
        let isSend = action.id == .sendSecurely
        let sendActive = isSend && !sendManager.sessions.isEmpty
        let activeCount = sendManager.sessions.count
        Button { execute(action.id) } label: {
            if sendActive {
                switch labelStyle {
                case .iconAndText:
                    Label {
                        Text(action.title)
                    } icon: {
                        Image(systemName: "paperplane.fill")
                            .overlay(alignment: .topTrailing) {
                                if activeCount > 1 {
                                    Text("\(activeCount)")
                                        .font(.system(size: 7, weight: .bold))
                                        .padding(1.5)
                                        .background(Color.accentColor, in: Circle())
                                        .foregroundStyle(.white)
                                        .offset(x: 5, y: -5)
                                }
                            }
                    }
                case .textOnly:
                    Text(action.title)
                case .iconOnly:
                    Image(systemName: "paperplane.fill")
                        .overlay(alignment: .topTrailing) {
                            if activeCount > 1 {
                                Text("\(activeCount)")
                                    .font(.system(size: 7, weight: .bold))
                                    .padding(1.5)
                                    .background(Color.accentColor, in: Circle())
                                    .foregroundStyle(.white)
                                    .offset(x: 5, y: -5)
                            }
                        }
                }
            } else {
                switch labelStyle {
                case .iconAndText: Label(action.title, systemImage: action.systemImage)
                case .textOnly:    Text(action.title)
                case .iconOnly:    Image(systemName: action.systemImage)
                }
            }
        }
        .buttonStyle(.text(color: sendActive ? Color.accentColor : color))
        .disabled(!isAvailable(action.id))
        .shortcutBadge(shortcutString(action.id), visible: badgesVisible)
        .overlay {
            if copiedFeedbackAction == action.id {
                Text(copiedFeedbackText)
                    .font(.system(size: density.fontSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor, in: Capsule())
                    .fixedSize()
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .popover(isPresented: isSend ? $showingSendPopover : .constant(false), arrowEdge: .bottom) {
            if isSend {
                SendExpirationPopover(files: selectedResults.map(\.url)) { showingSendPopover = false }
            }
        }
        .popover(isPresented: isSend ? $showingTransfers : .constant(false), arrowEdge: .bottom) {
            if isSend { TransfersPanel() }
        }
    }

    @MainActor func shortcutString(_ id: ActionID) -> String {
        guard ToolbarAction.rebindable.contains(where: { $0.id == id }),
              let sc = KeyboardShortcuts.getShortcut(for: ClingShortcuts.name(for: id)) else { return "" }
        return sc.description
    }

    @MainActor func menuShortcut(for id: ActionID) -> (KeyEquivalent, SwiftUI.EventModifiers)? {
        guard ToolbarAction.rebindable.contains(where: { $0.id == id }),
              let sc = KeyboardShortcuts.getShortcut(for: ClingShortcuts.name(for: id)),
              let keyStr = sc.nsMenuItemKeyEquivalent, let ch = keyStr.first else { return nil }
        var mods: SwiftUI.EventModifiers = []
        if sc.modifiers.contains(.command) { mods.insert(.command) }
        if sc.modifiers.contains(.option)  { mods.insert(.option) }
        if sc.modifiers.contains(.control) { mods.insert(.control) }
        if sc.modifiers.contains(.shift)   { mods.insert(.shift) }
        return (KeyEquivalent(ch), mods)
    }

    @ViewBuilder var overflowButton: some View {
        let show = showActionMenu && !overflowActions.isEmpty
        if show {
            Menu {
                ForEach(ActionSegment.segmentSections, id: \.self) { segment in
                    let items = overflowActions.filter { $0.segment == segment }
                    if !items.isEmpty {
                        Section(segment.title) {
                            ForEach(items) { a in
                                let button = Button { execute(a.id) } label: { Label(a.title, systemImage: a.systemImage) }
                                    .disabled(!isAvailable(a.id))
                                if let (k, m) = menuShortcut(for: a.id) {
                                    button.keyboardShortcut(k, modifiers: m)
                                } else {
                                    button
                                }
                            }
                        }
                    }
                }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // MARK: - Action dispatch

    func execute(_ id: ActionID) {
        switch id {
        case .open:                 openSelectedResults()
        case .showInFinder:         showInFinder()
        case .quickLook:            quicklook()
        case .openWith:             openWithPicker()
        case .openInTerminal:       openInTerminal()
        case .openInEditor:         openInEditor()
        case .copy:                 copyFiles(); flashCopied(.copy)
        case .copyPaths:            copyPaths()
        case .moveTo:               moveTo()
        case .rename:               renameSelected()
        case .shelve:               shelve()
        case .sendSecurely:         startSecureSend()
        case .pasteToFrontmost:     pasteToFrontmostApp(inTerminal: appManager.frontmostAppIsTerminal)
        case .trash:                trashSelected()
        case .dropToFocusedElement: dropToFocusedElement()
        case .dropToZone:           dropToZone()
        case .openWithFrontmost:    openWithFrontmostApp()
        }
    }

    // isAvailable gates executability (used by the shortcut monitor and toolbar button disabling).
    // isConfigured gates toolbar VISIBILITY (external tool configured vs not); do not conflate them —
    // e.g. openInTerminal belongs in isAvailable so ⌘T does nothing when no terminal is set.
    // NOTE: focus guards for copy/trash belong in the shortcut dispatch loop, NOT here — the toolbar
    // buttons must stay enabled regardless of which field is focused.
    func isAvailable(_ id: ActionID) -> Bool {
        switch id {
        case .openInTerminal:  return terminalApp.existingFilePath != nil
        case .openInEditor:    return editorApp.existingFilePath != nil
        case .copy:            return !selectedResults.isEmpty
        case .trash:           return !selectedResults.isEmpty && !selectedResults.contains(where: \.isOnReadOnlyVolume)
        case .openWith:        return !selectedResults.isEmpty && !fuzzy.openWithAppShortcuts.isEmpty
        case .sendSecurely:    return !selectedResults.isEmpty
        default:               return true
        }
    }

    // Extractions of button-inline action bodies into callable private methods

    private func showInFinder() {
        RH.trackRun(selectedResults)
        revealInFinder(selectedResults.map(\.url))
    }

    private func openWithPicker() {
        focused.wrappedValue = .openWith
        isPresentingOpenWithPicker = true
    }

    private func openInTerminal() {
        guard let terminal = terminalApp.existingFilePath?.url else { return }
        RH.trackRun(selectedResults)
        let dirs = selectedResults.map { $0.isDir ? $0.url : $0.dir.url }.uniqued
        NSWorkspace.shared.open(
            dirs, withApplicationAt: terminal, configuration: .init(),
            completionHandler: { _, _ in }
        )
    }

    private func openInEditor() {
        guard let editor = editorApp.existingFilePath?.url else { return }
        RH.trackRun(selectedResults)
        NSWorkspace.shared.open(
            selectedResults.map(\.url), withApplicationAt: editor, configuration: .init(),
            completionHandler: { _, _ in }
        )
    }

    private func shelve() {
        guard let shelf = shelfApp.existingFilePath?.url else { return }
        RH.trackRun(selectedResults)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.open(
            selectedResults.map(\.url), withApplicationAt: shelf, configuration: config,
            completionHandler: { _, _ in }
        )
    }

    private func moveTo() {
        isPresentingMoveToSheet = true
    }

    private func renameSelected() {
        isPresentingRenameView = true
    }

    private func trashSelected() {
        if suppressTrashConfirm {
            moveToTrash()
        } else {
            isPresentingConfirm = true
        }
    }

    private func dropToFocusedElement() {
        RH.trackRun(selectedResults)
        appManager.dropToFocusedElement(paths: selectedResults.arr)
    }

    private func dropToZone() {
        RH.trackRun(selectedResults)
        appManager.dropToZone(paths: selectedResults.arr)
    }

    private func openWithFrontmostApp() {
        guard let app = appManager.lastFrontmostApp, let appURL = app.bundleURL else { return }
        RH.trackRun(selectedResults)
        NSWorkspace.shared.open(
            selectedResults.map(\.url), withApplicationAt: appURL, configuration: .init(),
            completionHandler: { _, _ in }
        )
    }

    private func startSecureSend() {
        if sendManager.sessions.isEmpty { showingSendPopover = true } else { showingTransfers = true }
    }

    private func pasteToFrontmostAppButton(inTerminal: Bool) -> some View {
        Button(action: { pasteToFrontmostApp(inTerminal: inTerminal) }) {
            Text(inTerminal ? "⏎" : "⌘⇧⏎")
                + Text(" Paste to \(appManager.lastFrontmostApp?.name ?? "frontmost app")")
        }
        .help("Paste the paths of the selected files to the frontmost app")
    }

    private func copyFiles() {
        RH.trackRun(selectedResults)
        withAnimation(.fastSpring) { copiedFiles = true }
        mainAsyncAfter(ms: 150) { withAnimation(.easeOut(duration: 0.1)) { copiedFiles = false }}

        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(selectedResults.map(\.url) as [NSPasteboardWriting])
    }

    private func copyPaths() {
        withAnimation(.fastSpring) { copiedPaths = true }
        mainAsyncAfter(ms: 150) { withAnimation(.easeOut(duration: 0.1)) { copiedPaths = false }}

        let pathStr: (FilePath) -> String = copyPathsWithTilde ? { $0.shellString } : { $0.string }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            appManager.frontmostAppIsTerminal
                ? selectedResults.map { pathStr($0).replacingOccurrences(of: " ", with: "\\ ") }.joined(separator: " ")
                : selectedResults.map { pathStr($0) }.joined(separator: "\n"), forType: .string
        )
    }

    private func copyFilenames() {
        withAnimation(.fastSpring) { copiedPaths = true }
        mainAsyncAfter(ms: 150) { withAnimation(.easeOut(duration: 0.1)) { copiedPaths = false }}

        let filenames = selectedResults.map(\.name.string)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            appManager.frontmostAppIsTerminal
                ? filenames.map { $0.replacingOccurrences(of: " ", with: "\\ ") }.joined(separator: " ")
                : filenames.joined(separator: "\n"), forType: .string
        )
    }

    private func moveToTrash() {
        var removed = Set<FilePath>()
        for path in selectedResults {
            log.info("Trashing \(path.shellString)")
            do {
                try FileManager.default.trashItem(at: path.url, resultingItemURL: nil)
                removed.insert(path)
            } catch {
                log.error("Error trashing \(path.shellString): \(error.localizedDescription)")
            }
        }

        selectedResults.subtract(removed)
        fuzzy.results = fuzzy.results.filter { !removed.contains($0) && $0.exists }
    }

    private func quicklook() {
        QLP.present(
            urls: selectedResults.count > 1 ? selectedResults.map(\.url) : results.map(\.url),
            selectedItemIndex: selectedResults.count == 1 ? (results.firstIndex(of: selectedResults.first!) ?? 0) : 0
        )
    }

    private func openSelectedResults() {
        RH.trackRun(selectedResults)
        for url in selectedResults.map(\.url) {
            NSWorkspace.shared.open(url)
        }
    }

    private func renameFiles() {
        NSApp.mainWindow?.becomeKey()
        focus()

        guard let renameSubmission else { return }
        do {
            let renamed = try performRenameOperation(
                originalPaths: renameSubmission.originals, renamedPaths: renameSubmission.renamed
            )
            fuzzy.renamePaths(renamed)
            fuzzy.scoredResults = fuzzy.scoredResults.map { renamed[$0] ?? $0 }
            fuzzy.results = fuzzy.results.map { renamed[$0] ?? $0 }
            selectedResults = selectedResults.map { renamed[$0] ?? $0 }.set
            selectedResultIDs = Set(selectedResults.map(\.string))
        } catch {
            log.error("Error renaming files: \(error.localizedDescription)")
        }
        self.renameSubmission = nil
    }

    private var moveToButton: some View {
        Button("⌘M Move to...") {
            moveTo()
        }
        .help("Move the selected files to a folder")
    }

    @State private var isPresentingRenameView = false
    @State private var renameSubmission: RenameSubmission? = nil
    @State private var isPresentingOpenWithPicker = false
    @State private var isPresentingConfirm = false
    @State private var isPresentingCopyToSheet = false
    @State private var isPresentingMoveToSheet = false
    @State private var showingSendPopover = false
    @State private var showingTransfers = false

    @State private var copiedFeedbackAction: ActionID?
    @State private var copiedFeedbackText: String = "Copied"
    @State private var copiedClearTask: Task<Void, Never>?

    func flashCopied(_ id: ActionID, text: String = "Copied") {
        copiedClearTask?.cancel()
        copiedFeedbackText = text
        withAnimation(.easeOut(duration: 0.18)) { copiedFeedbackAction = id }
        copiedClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            withAnimation(.easeIn(duration: 0.25)) {
                if copiedFeedbackAction == id { copiedFeedbackAction = nil }
            }
        }
    }

    private var isAnySheetOpen: Bool {
        isPresentingRenameView || isPresentingOpenWithPicker || isPresentingConfirm
            || isPresentingCopyToSheet || isPresentingMoveToSheet || showingSendPopover || showingTransfers
            || sendManager.pendingFolderConfirm != nil
    }
}

// MARK: - FileOperationSheet

struct FileOperationSheet: View {
    init(operation: Operation, files: [FilePath], onComplete: @escaping (Set<FilePath>) -> Void = { _ in }) {
        self.operation = operation
        self.files = files
        self.onComplete = onComplete

        let ext = files.compactMap(\.extension).first ?? ""
        let saved = Defaults[.fileOpDestinations][ext]
        _destinationPath = State(initialValue: saved ?? "~/")
    }

    enum Operation: String {
        case copy = "Copy"
        case move = "Move"
    }

    let operation: Operation
    let files: [FilePath]
    var onComplete: (Set<FilePath>) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(operation.rawValue) \(files.count) file\(files.count == 1 ? "" : "s") to")
                .font(.headline)

            HStack {
                TextField("Destination folder", text: $destinationPath)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { perform() }

                Button("Browse...") { browse() }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(operation.rawValue) { perform() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(destinationPath.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }

    @State private var destinationPath: String
    @Environment(\.dismiss) private var dismiss

    private func expandedURL() -> URL {
        var path = destinationPath.trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("~") {
            path = FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst())
        }
        return URL(fileURLWithPath: path)
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = expandedURL()
        if panel.runModal() == .OK, let url = panel.url {
            destinationPath = url.path.shellString
        }
    }

    private func perform() {
        let destURL = expandedURL()
        let destPath = destURL.path
        let isSingleFile = files.count == 1
        let hasTrailingSlash = destinationPath.trimmingCharacters(in: .whitespaces).hasSuffix("/")

        // Single file to a path without trailing slash: treat as a file destination
        if isSingleFile, !hasTrailingSlash {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: destPath, isDirectory: &isDir)

            if exists, isDir.boolValue {
                // Destination is an existing directory, copy/move into it
                guard let dest = destURL.existingFilePath else { return }
                do {
                    switch operation {
                    case .copy: try files[0].copy(to: dest)
                    case .move: try files[0].move(to: dest)
                    }
                    onComplete(Set(files))
                } catch {
                    log.error("Failed to \(operation.rawValue.lowercased()) \(files[0].shellString) to \(dest.shellString): \(error.localizedDescription)")
                }
            } else {
                // Destination is a file path, ensure parent directory exists
                let parentPath = destURL.deletingLastPathComponent().path
                var parentIsDir: ObjCBool = false
                if !FileManager.default.fileExists(atPath: parentPath, isDirectory: &parentIsDir) || !parentIsDir.boolValue {
                    do {
                        try FileManager.default.createDirectory(atPath: parentPath, withIntermediateDirectories: true)
                    } catch {
                        log.error("Failed to create directory \(parentPath): \(error.localizedDescription)")
                        return
                    }
                }

                let dest = FilePath(destPath)
                do {
                    switch operation {
                    case .copy: try FileManager.default.copyItem(atPath: files[0].string, toPath: dest.string)
                    case .move: try FileManager.default.moveItem(atPath: files[0].string, toPath: dest.string)
                    }
                    onComplete(Set(files))
                } catch {
                    log.error("Failed to \(operation.rawValue.lowercased()) \(files[0].shellString) to \(dest.shellString): \(error.localizedDescription)")
                }
            }
        } else {
            // Multiple files or trailing slash: treat as directory destination
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: destPath, isDirectory: &isDir) || !isDir.boolValue {
                do {
                    try FileManager.default.createDirectory(atPath: destPath, withIntermediateDirectories: true)
                } catch {
                    log.error("Failed to create directory \(destPath): \(error.localizedDescription)")
                    return
                }
            }

            guard let dest = destURL.existingFilePath else { return }
            var processed = Set<FilePath>()
            for file in files {
                do {
                    switch operation {
                    case .copy: try file.copy(to: dest)
                    case .move: try file.move(to: dest)
                    }
                    processed.insert(file)
                } catch {
                    log.error("Failed to \(operation.rawValue.lowercased()) \(file.shellString) to \(dest.shellString): \(error.localizedDescription)")
                }
            }
            onComplete(processed)
        }
        let extensions = Set(files.compactMap(\.extension))
        for ext in extensions {
            Defaults[.fileOpDestinations][ext] = destinationPath
        }

        dismiss()
    }
}
