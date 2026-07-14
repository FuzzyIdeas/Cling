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
            if let path = paths.first { openFinderGetInfo(path) }
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
        Button("Duplicate") { duplicateSelection() }
        Button("Compress") { compressSelection() }

        Divider()

        Button("Copy") { copyFiles() }
        Menu("Copy Paths") {
            Button("separated by space") { copyPaths(separator: " ") }
            Button("separated by space and quoted") { copyPaths(separator: " ", quoted: true) }
            Button("separated by comma") { copyPaths(separator: ",") }
            Button("with each file on a separate line") { copyPaths(separator: "\n") }
        }
        Menu("Copy Filenames") {
            Button("separated by space") { copyFilenames(separator: " ") }
            Button("separated by space and quoted") { copyFilenames(separator: " ", quoted: true) }
            Button("separated by comma") { copyFilenames(separator: ",") }
            Button("with each file on a separate line") { copyFilenames(separator: "\n") }
                .keyboardShortcut("c", modifiers: [.command, .option, .control])
        }
        Menu("Export Results List") {
            Button("as CSV") { exportAs(type: .csv) }
            Button("as TSV") { exportAs(type: .tsv) }
            Button("as JSON") { exportAs(type: .json) }
            Button("as plaintext") { exportAs(type: .plaintext) }
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

        if let source = selectedSourceIndex {
            Divider()
            Text("Source: \(source)").foregroundStyle(.secondary)
            Button("Reindex \(source)") {
                FUZZY.reindexSource(source)
            }
        }
    }

    private enum ExportType {
        case csv, tsv, json, plaintext
    }

    private enum FileOperation {
        case copy, move
    }

    @Default(.copyPathsWithTilde) private var copyPathsWithTilde
    @Default(.terminalApp) private var terminalApp
    @Default(.editorApp) private var editorApp
    @Default(.shelfApp) private var shelfApp

    private var selectedSourceIndex: String? {
        let sources = selectedResults.compactMap { path -> String? in
            let s = path.memoz.sourceIndex
            return s.isEmpty ? nil : s
        }
        let unique = Set(sources)
        return unique.count == 1 ? unique.first : nil
    }

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

    private func pathString(_ path: FilePath) -> String {
        copyPathsWithTilde ? path.shellString : path.string
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

    private func copyPaths(separator: String, quoted: Bool = false) {
        let filepaths = orderedSelection.map { path in
            let str = pathString(path)
            return quoted ? "\"\(str)\"" : str
        }.joined(separator: separator)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(filepaths, forType: .string)
    }

    private func copyFilenames(separator: String, quoted: Bool = false) {
        let filenames = orderedSelection.map { path in
            quoted ? "\"\(path.name.string)\"" : path.name.string
        }.joined(separator: separator)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(filenames, forType: .string)
    }

    private func duplicateSelection() {
        var created: [FilePath] = []
        for source in orderedSelection where source.exists {
            let dir = source.dir
            let stem = source.stem ?? source.name.string
            let ext = source.extension.map { ".\($0)" } ?? ""
            var copyIndex = 2
            var target = dir.appending("\(stem) \(copyIndex)\(ext)")
            while target.exists {
                copyIndex += 1
                target = dir.appending("\(stem) \(copyIndex)\(ext)")
            }
            do {
                try FileManager.default.copyItem(at: source.url, to: target.url)
                created.append(target)
            } catch {
                log.error("Failed to duplicate \(source.shellString): \(error.localizedDescription)")
            }
        }
        if !created.isEmpty {
            NotificationCenter.default.post(name: .clingDidCreateFiles, object: created)
        }
    }

    private func compressSelection() {
        let paths = orderedSelection.filter(\.exists)
        guard !paths.isEmpty else { return }

        let parents = Set(paths.map(\.dir))
        let workingDir = parents.count == 1 ? parents.first! : paths[0].dir

        let baseName: String = if paths.count == 1 {
            paths[0].stem ?? paths[0].name.string
        } else {
            "Archive"
        }
        var archive = workingDir.appending("\(baseName).zip")
        var idx = 2
        while archive.exists {
            archive = workingDir.appending("\(baseName) \(idx).zip")
            idx += 1
        }

        let names = paths.map { path in
            (path.dir == workingDir) ? path.name.string : path.string
        }
        let archivePath = archive
        let opKey = "compress-\(archivePath.string)"
        let progressMessage = paths.count == 1
            ? "Compressing \(paths[0].name.string)"
            : "Compressing \(paths.count) files into \(archivePath.name.string)"

        FUZZY.logActivity(progressMessage, ongoing: true, operationKey: opKey)

        let sevenZipURL = SEVEN_ZIP.url
        Task.detached(priority: .userInitiated) {
            let task = Process()
            task.executableURL = sevenZipURL
            task.currentDirectoryURL = workingDir.url
            task.arguments = ["a", "-tzip", "-bd", "-bso0", "-bsp0", archivePath.string] + names
            task.standardOutput = FileHandle.nullDevice
            task.standardError = Pipe()

            var status: Int32 = -1
            var stderr = Data()
            var runError: Error?
            do {
                try task.run()
                if let pipe = task.standardError as? Pipe {
                    stderr = pipe.fileHandleForReading.readDataToEndOfFile()
                }
                task.waitUntilExit()
                status = task.terminationStatus
            } catch {
                runError = error
            }

            await MainActor.run {
                if let runError {
                    log.error("Failed to compress: \(runError.localizedDescription)")
                    FUZZY.logActivity("Compression failed", operationKey: opKey)
                    return
                }
                if status != 0 {
                    let detail = String(data: stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    log.error("7zz exited with status \(status)\(detail.isEmpty ? "" : ": \(detail)")")
                    FUZZY.logActivity("Compression failed (exit \(status))", operationKey: opKey)
                    return
                }
                FUZZY.logActivity("Created \(archivePath.name.string)", operationKey: opKey)
                if archivePath.exists {
                    NotificationCenter.default.post(name: .clingDidCreateFiles, object: [archivePath])
                }
            }
        }
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

    private func exportAs(type: ExportType) {
        let panel = NSSavePanel()
        panel.allowsOtherFileTypes = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = switch type {
        case .csv: [.commaSeparatedText]
        case .tsv: [.tabSeparatedText]
        case .json: [.json]
        case .plaintext: [.plainText]
        }
        panel.nameFieldStringValue = switch type {
        case .csv: "cling-files.csv"
        case .tsv: "cling-files.tsv"
        case .json: "cling-files.json"
        case .plaintext: "cling-files.txt"
        }

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                switch type {
                case .csv:
                    try exportCSV(to: url)
                case .tsv:
                    try exportTSV(to: url)
                case .json:
                    try exportJSON(to: url)
                case .plaintext:
                    try exportPlaintext(to: url)
                }
            } catch {
                log.error("Failed to write to \(url.path): \(error.localizedDescription)")
            }
        }
    }

    private func exportCSV(to url: URL) throws {
        let header = "Path,Size,Date"
        let fileContents = orderedSelection.map { path in
            let size = path.memoz.size
            let date = path.memoz.isoFormattedModificationDate
            return "\(pathString(path)),\(size),\(date)"
        }.joined(separator: "\n")
        let csvContent = "\(header)\n\(fileContents)"
        try csvContent.write(to: url, atomically: true, encoding: .utf8)
    }

    private func exportTSV(to url: URL) throws {
        let header = "Path\tSize\tDate"
        let fileContents = orderedSelection.map { path in
            let size = path.memoz.size
            let date = path.memoz.isoFormattedModificationDate
            return "\(pathString(path))\t\(size)\t\(date)"
        }.joined(separator: "\n")
        let tsvContent = "\(header)\n\(fileContents)"
        try tsvContent.write(to: url, atomically: true, encoding: .utf8)
    }

    private func exportJSON(to url: URL) throws {
        let fileContents = orderedSelection.map { path in
            let size = path.memoz.size
            let date = path.memoz.isoFormattedModificationDate
            return [
                "path": pathString(path),
                "size": size,
                "date": date,
            ]
        }
        let jsonData = try JSONSerialization.data(withJSONObject: fileContents, options: .prettyPrinted)
        try jsonData.write(to: url)
    }

    private func exportPlaintext(to url: URL) throws {
        let fileContents = orderedSelection.map { pathString($0) }.joined(separator: "\n")
        try fileContents.write(to: url, atomically: true, encoding: .utf8)
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
