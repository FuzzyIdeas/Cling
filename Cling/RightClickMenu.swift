import AppKit
import Defaults
import Lowtech
import OSLog
import SwiftUI
import System

private let log = Logger(subsystem: clingSubsystem, category: "RightClickMenu")

extension Notification.Name {
    static let clingRequestRename = Notification.Name("cling.requestRename")
    static let clingDidCreateFiles = Notification.Name("cling.didCreateFiles")
    static let clingRequestExcludeSheet = Notification.Name("cling.requestExcludeSheet")
    static let clingSortByScore = Notification.Name("cling.sortByScore")
}

// MARK: - RightClickMenu

struct RightClickMenu: View {
    @Binding var selectedResults: Set<FilePath>

    var orderedResults: [FilePath]

    /// Paths resolved from the context menu's own selection set. Authoritative for the right-clicked rows,
    /// since `selectedResults` is synced a beat later and can briefly lag (or be empty) when the menu opens.
    var contextPaths: [FilePath] = []

    var body: some View {
        Button("Open") { openSelection() }
        Button("Show in Finder") { showInFinder() }
        Button("QuickLook") { quicklookSelection() }
        Button("Get Info") {
            let paths = contextPaths.isEmpty ? Array(selectedResults) : contextPaths
            // One panel only, even when many files are right-clicked.
            if let path = paths.first {
                openFinderGetInfo(path)
            }
        }
        // Display hint only: the actual ⌘I keystroke is handled by the
        // content shortcut monitor in ContentView, which swallows the event.
        .keyboardShortcut("i", modifiers: .command)

        Divider()

        if let terminal = terminalApp.existingFilePath?.url {
            Button("Open in \(terminalApp.filePath?.stem ?? "Terminal")") {
                openInTerminal(at: terminal)
            }
        }
        if let editor = editorApp.existingFilePath?.url {
            Button("Edit in \(editorApp.filePath?.stem ?? "Editor")") {
                openWith(app: editor, activates: true)
            }
        }
        if let app = APP_MANAGER.lastFrontmostApp,
           let appURL = app.bundleURL,
           !isConfiguredHelperApp(appURL)
        {
            Button("Open with \(app.name ?? "frontmost app")") {
                openWith(app: appURL, activates: true)
            }
        }

        Divider()

        Button("Rename\(orderedSelection.count > 1 ? " (batch)..." : "...")") {
            NotificationCenter.default.post(name: .clingRequestRename, object: nil)
        }
        Button("Duplicate") { SelectionCommands.duplicate(orderedSelection) }
        Button("Compress") { SelectionCommands.compress(orderedSelection) }

        Divider()

        Button("Copy") { copyFiles() }
        Menu("Copy Paths") {
            ForEach(SelectionCommands.ListStyle.allCases, id: \.self) { style in
                Button(style.title) { SelectionCommands.copyPaths(orderedSelection, style) }
            }
        }
        Menu("Copy Filenames") {
            ForEach(SelectionCommands.ListStyle.allCases, id: \.self) { style in
                if style == .lines {
                    Button(style.title) { SelectionCommands.copyFilenames(orderedSelection, style) }
                        .keyboardShortcut("c", modifiers: [.command, .option, .control])
                } else {
                    Button(style.title) { SelectionCommands.copyFilenames(orderedSelection, style) }
                }
            }
        }
        Menu("Export Results List") {
            ForEach(SelectionCommands.ExportFormat.allCases, id: \.self) { format in
                Button(format.title) { SelectionCommands.export(orderedSelection, as: format) }
            }
        }

        Divider()

        Button("Copy Files To...") { performFileOperation(.copy) }
        Button("Move Files To...") { performFileOperation(.move) }

        Divider()

        Button {
            STASH.toggle(orderedSelection)
        } label: {
            Label(
                allSelectedStashed ? "Remove from Stash" : "Add to Stash",
                systemImage: allSelectedStashed ? "tray.and.arrow.up" : "tray.and.arrow.down"
            )
        }
        .disabled(orderedSelection.isEmpty)

        Divider()

        Button {
            SendManager.shared.requestSend(files: orderedSelection.map(\.url), expiration: Defaults[.defaultLinkExpiration])
        } label: {
            Label("Send securely", systemImage: "paperplane")
        }
        .disabled(orderedSelection.isEmpty)

        Divider()

        Button("Move to Trash", role: .destructive) { moveToTrash() }

        Divider()

        Button("Exclude from Index...") {
            let paths = contextPaths.isEmpty ? Array(selectedResults) : contextPaths
            guard !paths.isEmpty else { return }
            NotificationCenter.default.post(name: .clingRequestExcludeSheet, object: paths)
        }

        if let source = SelectionCommands.sourceIndex(of: selectedResults) {
            Divider()
            Text("Source: \(source)").foregroundStyle(.secondary)
            Button("Reindex \(source)") {
                FUZZY.reindexSource(source)
            }
        }
    }

    private enum FileOperation {
        case copy, move
    }

    @Default(.terminalApp) private var terminalApp
    @Default(.editorApp) private var editorApp
    @Default(.shelfApp) private var shelfApp

    /// Selected results in the same order they appear in the UI
    private var orderedSelection: [FilePath] {
        orderedResults.filter { selectedResults.contains($0) }
    }

    private var allSelectedStashed: Bool {
        !orderedSelection.isEmpty && orderedSelection.allSatisfy { STASH.contains($0) }
    }

    private func isConfiguredHelperApp(_ url: URL) -> Bool {
        let target = url.resolvingSymlinksInPath().path
        let helpers = [terminalApp, editorApp, shelfApp].compactMap {
            $0.existingFilePath?.url.resolvingSymlinksInPath().path
        }
        return helpers.contains(target)
    }

    private func openSelection() {
        let paths = orderedSelection
        RH.trackRun(Set(paths))
        for path in paths {
            NSWorkspace.shared.open(path.url)
        }
    }

    private func showInFinder() {
        let urls = orderedSelection.filter(\.exists).map(\.url)
        guard !urls.isEmpty else { return }
        revealInFinder(urls)
    }

    private func quicklookSelection() {
        let urls = orderedSelection.map(\.url)
        QLP.present(urls: urls, selectedItemIndex: 0)
    }

    private func openInTerminal(at terminal: URL) {
        let paths = orderedSelection
        RH.trackRun(Set(paths))
        let dirs = paths.map { $0.isDir ? $0.url : $0.dir.url }.uniqued
        NSWorkspace.shared.open(
            dirs, withApplicationAt: terminal, configuration: .init(),
            completionHandler: { _, _ in }
        )
    }

    private func openWith(app: URL, activates: Bool) {
        let paths = orderedSelection
        RH.trackRun(Set(paths))
        let config = NSWorkspace.OpenConfiguration()
        config.activates = activates
        NSWorkspace.shared.open(
            paths.map(\.url), withApplicationAt: app, configuration: config,
            completionHandler: { _, _ in }
        )
    }

    private func copyFiles() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(orderedSelection.map(\.url) as [NSPasteboardWriting])
    }

    private func moveToTrash() {
        var removed = Set<FilePath>()
        for path in orderedSelection {
            log.info("Trashing \(path.shellString)")
            do {
                try FileManager.default.trashItem(at: path.url, resultingItemURL: nil)
                removed.insert(path)
            } catch {
                log.error("Error trashing \(path.shellString): \(error.localizedDescription)")
            }
        }
        selectedResults.subtract(removed)
        STASH.remove(removed)
        FUZZY.results = FUZZY.results.filter { !removed.contains($0) && $0.exists }
    }

    private func performFileOperation(_ operation: FileOperation) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let dir = panel.url?.existingFilePath else { return }
            for file in orderedSelection {
                do {
                    switch operation {
                    case .copy:
                        try file.copy(to: dir)
                    case .move:
                        try file.move(to: dir)
                    }
                } catch {
                    let operationName = operation == .copy ? "copy" : "move"
                    log.error("Failed to \(operationName) \(file.shellString) to \(dir.shellString): \(error.localizedDescription)")
                }
            }
        }
    }
}

extension Date {
    var iso8601String: String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: self)
    }
}
