import Defaults
import Lowtech
import SwiftUI
import System

// MARK: - ActionButtons

struct ActionButtons: View {
    @Binding var selectedResults: Set<FilePath>
    @Binding var selectedResultIDs: Set<String>
    var focused: FocusState<FocusedField?>.Binding

    @State private var appManager: AppManager = APP_MANAGER
    @State private var fuzzy: FuzzyClient = FUZZY
    @State private var scriptManager: ScriptManager = SM
    @Default(.suppressTrashConfirm) var suppressTrashConfirm: Bool
    @Default(.terminalApp) var terminalApp
    @Default(.editorApp) var editorApp
    @Default(.shelfApp) var shelfApp
    @Default(.copyPathsWithTilde) var copyPathsWithTilde
    @Default(.showActionRow) var showActionRow
    @Default(.hiddenActionButtons) var hiddenActionButtons
    @ObservedObject var km = KM

    var body: some View {
        let inTerminal = appManager.frontmostAppIsTerminal
        let showingAlternates = (km.ralt || km.lalt) && !isAnySheetOpen
        let hidden = Set(hiddenActionButtons)

        HStack {
            if showActionRow {
                if !showingAlternates {
                    if !hidden.contains(.open) { openButton(inTerminal: inTerminal) }
                    if !hidden.contains(.showInFinder) { showInFinderButton }
                    if !hidden.contains(.pasteToFrontmost) { pasteToFrontmostAppButton(inTerminal: inTerminal) }
                    if !hidden.contains(.openInTerminal) { openInTerminalButton }
                    if !hidden.contains(.openInEditor) { openInEditorButton }
                    if !hidden.contains(.shelve) { shelveButton }
                    Spacer()
                    openWithPickerButton
                    Spacer()
                } else {
                    dropToFocusedElementButton
                    dropToZoneButton
                    openWithFrontmostAppButton
                    Spacer()
                }
                if !hidden.contains(.copy) {
                    copyFilesButton.disabled(focused.wrappedValue != .list)
                }
                if !hidden.contains(.copyPaths) {
                    copyPathsButton
                }
                if !showingAlternates, !hidden.contains(.moveTo) {
                    moveToButton
                }
                if !hidden.contains(.trash) {
                    trashButton.disabled(focused.wrappedValue != .list)
                }
                if !showingAlternates {
                    if !hidden.contains(.quicklook) { quicklookButton }
                    if !hidden.contains(.rename) { renameButton }
                }
            } else {
                openWithPickerButton
            }
        }
        .font(.system(size: 10))
        .buttonStyle(.text(color: .fg.warm.opacity(0.9)))
        .lineLimit(1)
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

            if sel.isEmpty { return event }

            // ⌘⏎ Show in Finder
            if isReturn, mods == .command {
                RH.trackRun(sel)
                revealInFinder(sel.map(\.url))
                return nil
            }
            // ⏎ Open (default app, non-terminal context)
            if isReturn, mods.isEmpty, !inTerminal {
                RH.trackRun(sel)
                for url in sel.map(\.url) {
                    NSWorkspace.shared.open(url)
                }
                return nil
            }
            // ⌘⇧⏎ Open (default app, terminal context)
            if isReturn, mods == [.command, .shift], inTerminal {
                RH.trackRun(sel)
                for url in sel.map(\.url) {
                    NSWorkspace.shared.open(url)
                }
                return nil
            }
            // ⏎ Paste to terminal
            if isReturn, mods.isEmpty, inTerminal {
                RH.trackRun(sel)
                APP_MANAGER.pasteToFrontmostApp(paths: sel.arr, separator: " ", quoted: true)
                return nil
            }
            // ⌘⇧⏎ Paste to non-terminal
            if isReturn, mods == [.command, .shift], !inTerminal {
                RH.trackRun(sel)
                APP_MANAGER.pasteToFrontmostApp(paths: sel.arr, separator: "\n", quoted: false)
                return nil
            }
            // ⌥⏎ Drop into focused element of last frontmost app
            if isReturn, mods == .option {
                RH.trackRun(sel)
                APP_MANAGER.dropToFocusedElement(paths: sel.arr)
                return nil
            }
            // ⌥⇧⏎ Drop to zone (escape hatch)
            if isReturn, mods == [.option, .shift] {
                RH.trackRun(sel)
                APP_MANAGER.dropToZone(paths: sel.arr)
                return nil
            }
            // ⌘⌥⏎ Open with last frontmost app
            if isReturn, mods == [.command, .option],
               let app = APP_MANAGER.lastFrontmostApp, let appURL = app.bundleURL
            {
                RH.trackRun(sel)
                NSWorkspace.shared.open(
                    sel.map(\.url), withApplicationAt: appURL, configuration: .init(),
                    completionHandler: { _, _ in }
                )
                return nil
            }
            // ⌘T Open in terminal
            if chars == "t", mods == .command,
               let terminal = Defaults[.terminalApp].existingFilePath?.url
            {
                RH.trackRun(sel)
                let dirs = sel.map { $0.isDir ? $0.url : $0.dir.url }.uniqued
                NSWorkspace.shared.open(
                    dirs, withApplicationAt: terminal, configuration: .init(),
                    completionHandler: { _, _ in }
                )
                return nil
            }
            // ⌘E Edit
            if chars == "e", mods == .command,
               let editor = Defaults[.editorApp].existingFilePath?.url
            {
                RH.trackRun(sel)
                NSWorkspace.shared.open(
                    sel.map(\.url), withApplicationAt: editor, configuration: .init(),
                    completionHandler: { _, _ in }
                )
                return nil
            }
            // ⌘S Shelve
            if chars == "s", mods == .command,
               let shelf = Defaults[.shelfApp].existingFilePath?.url
            {
                RH.trackRun(sel)
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                NSWorkspace.shared.open(
                    sel.map(\.url), withApplicationAt: shelf, configuration: config,
                    completionHandler: { _, _ in }
                )
                return nil
            }
            // ⌘O Open With picker
            if chars == "o", mods == .command, !FUZZY.openWithAppShortcuts.isEmpty {
                focusBinding.wrappedValue = .openWith
                openWithB.wrappedValue = true
                return nil
            }
            // ⌘M Move to...
            if chars == "m", mods == .command {
                moveToB.wrappedValue = true
                return nil
            }
            // ⌘R Rename
            if chars == "r", mods == .command {
                renameB.wrappedValue = true
                return nil
            }
            // ⌘Y Quicklook
            if chars == "y", mods == .command {
                let resultsList = (FUZZY.noQuery && FUZZY.volumeFilter == nil)
                    ? (FUZZY.sortField == .score ? FUZZY.recents : FUZZY.sortedRecents)
                    : FUZZY.results
                QLP.present(
                    urls: sel.count > 1 ? sel.map(\.url) : resultsList.map(\.url),
                    selectedItemIndex: sel.count == 1 ? (resultsList.firstIndex(of: sel.first!) ?? 0) : 0
                )
                return nil
            }
            // ⌘C Copy / ⌘⌥C Copy to...
            if chars == "c", mods == .command, focus == .list {
                RH.trackRun(sel)
                withAnimation(.fastSpring) { copiedFilesB.wrappedValue = true }
                mainAsyncAfter(ms: 150) {
                    withAnimation(.easeOut(duration: 0.1)) { copiedFilesB.wrappedValue = false }
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects(sel.map(\.url) as [NSPasteboardWriting])
                return nil
            }
            if chars == "c", mods == [.command, .option], focus == .list {
                copyToB.wrappedValue = true
                return nil
            }
            // ⌘⇧C Copy paths / ⌘⌥⇧C Copy filenames
            if chars == "c", mods == [.command, .shift] {
                withAnimation(.fastSpring) { copiedPathsB.wrappedValue = true }
                mainAsyncAfter(ms: 150) {
                    withAnimation(.easeOut(duration: 0.1)) { copiedPathsB.wrappedValue = false }
                }
                let useTilde = Defaults[.copyPathsWithTilde]
                let pathStr: (FilePath) -> String = useTilde ? { $0.shellString } : { $0.string }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    APP_MANAGER.frontmostAppIsTerminal
                        ? sel.map { pathStr($0).replacingOccurrences(of: " ", with: "\\ ") }.joined(separator: " ")
                        : sel.map { pathStr($0) }.joined(separator: "\n"), forType: .string
                )
                return nil
            }
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
            // ⌘⌫ Trash / ⌘⌥⌫ Delete
            if isDelete, focus == .list, !sel.contains(where: \.isOnReadOnlyVolume) {
                if mods == .command {
                    if Defaults[.suppressTrashConfirm] {
                        Self.performTrash(selection: selB)
                    } else {
                        confirmB.wrappedValue = true
                    }
                    return nil
                }
                if mods == [.command, .option] {
                    Self.performDelete(selection: selB)
                    return nil
                }
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
                log.error("Error trashing \(path.shellString): \(error)")
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
                log.error("Error deleting \(path.shellString): \(error)")
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
            RH.trackRun(selectedResults)
            revealInFinder(selectedResults.map(\.url))
        }
        .help("Show the selected files in Finder")
    }

    @ViewBuilder
    private var openInTerminalButton: some View {
        if let terminal = terminalApp.existingFilePath?.url {
            Button("⌘T Open in \(terminalApp.filePath?.stem ?? "Terminal")") {
                RH.trackRun(selectedResults)
                let dirs = selectedResults.map { $0.isDir ? $0.url : $0.dir.url }.uniqued
                NSWorkspace.shared.open(
                    dirs, withApplicationAt: terminal, configuration: .init(),
                    completionHandler: { _, _ in }
                )
            }
            .help("Open the selected files in Terminal")
        }
    }
    @ViewBuilder
    private var openInEditorButton: some View {
        if let editor = editorApp.existingFilePath?.url {
            Button("⌘E Edit") {
                RH.trackRun(selectedResults)
                NSWorkspace.shared.open(
                    selectedResults.map(\.url), withApplicationAt: editor, configuration: .init(),
                    completionHandler: { _, _ in }
                )
            }
            .help("Open the selected files in the configured editor (\(editorApp.filePath?.stem ?? "TextEdit"))")
        }
    }
    @ViewBuilder
    private var shelveButton: some View {
        if let shelf = shelfApp.existingFilePath?.url {
            Button("⌘S Shelve in \(shelfApp.filePath?.stem ?? "shelf app")") {
                RH.trackRun(selectedResults)
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                NSWorkspace.shared.open(
                    selectedResults.map(\.url), withApplicationAt: shelf, configuration: config,
                    completionHandler: { _, _ in }
                )
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
            focused.wrappedValue = .openWith
            isPresentingOpenWithPicker = true
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
                if suppressTrashConfirm {
                    moveToTrash()
                } else {
                    isPresentingConfirm = true
                }
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
                log.error("Error deleting \(path.shellString): \(error)")
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
            isPresentingRenameView = true
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
                RH.trackRun(selectedResults)
                appManager.dropToFocusedElement(paths: selectedResults.arr)
            }
            .help("Drop into \(target.name) using a real drag-drop event")
            .disabled(selectedResults.isEmpty)
        }
    }

    @ViewBuilder
    private var dropToZoneButton: some View {
        Button("⌥⇧⏎ Drag and drop to zone") {
            RH.trackRun(selectedResults)
            appManager.dropToZone(paths: selectedResults.arr)
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
                RH.trackRun(selectedResults)
                NSWorkspace.shared.open(
                    selectedResults.map(\.url), withApplicationAt: appURL, configuration: .init(),
                    completionHandler: { _, _ in }
                )
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
                log.error("Error trashing \(path.shellString): \(error)")
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
            log.error("Error renaming files: \(error)")
        }
        self.renameSubmission = nil
    }

    private var moveToButton: some View {
        Button("⌘M Move to...") {
            isPresentingMoveToSheet = true
        }
        .help("Move the selected files to a folder")
    }

    @State private var isPresentingRenameView = false
    @State private var renameSubmission: RenameSubmission? = nil
    @State private var isPresentingOpenWithPicker = false
    @State private var isPresentingConfirm = false
    @State private var isPresentingCopyToSheet = false
    @State private var isPresentingMoveToSheet = false

    private var isAnySheetOpen: Bool {
        isPresentingRenameView || isPresentingOpenWithPicker || isPresentingConfirm
            || isPresentingCopyToSheet || isPresentingMoveToSheet
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
