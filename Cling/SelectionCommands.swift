import AppKit
import Defaults
import Lowtech
import OSLog
import System

private let log = Logger(subsystem: clingSubsystem, category: "SelectionCommands")

// MARK: - SelectionCommands

/// What the window's right-click menu and the search bar's actions menu do with the selected files, kept in one
/// place so the two menus behave the same.
@MainActor
enum SelectionCommands {
    /// How a list of paths or names is joined on the clipboard.
    enum ListStyle: CaseIterable {
        case spaced, spacedQuoted, commas, lines

        var title: String {
            switch self {
            case .spaced: "separated by space"
            case .spacedQuoted: "separated by space and quoted"
            case .commas: "separated by comma"
            case .lines: "with each file on a separate line"
            }
        }

        var separator: String {
            switch self {
            case .spaced, .spacedQuoted: " "
            case .commas: ","
            case .lines: "\n"
            }
        }

        var quoted: Bool {
            self == .spacedQuoted
        }
    }

    enum ExportFormat: CaseIterable {
        case csv, tsv, json, plaintext

        var title: String {
            switch self {
            case .csv: "as CSV"
            case .tsv: "as TSV"
            case .json: "as JSON"
            case .plaintext: "as plaintext"
            }
        }
    }

    static func pathString(_ path: FilePath) -> String {
        Defaults[.copyPathsWithTilde] ? path.shellString : path.string
    }

    static func copyPaths(_ paths: [FilePath], _ style: ListStyle) {
        copyList(paths.map(pathString), style)
    }

    static func copyFilenames(_ paths: [FilePath], _ style: ListStyle) {
        copyList(paths.map(\.name.string), style)
    }

    /// The one index every path comes from, or nil when they come from several or none.
    static func sourceIndex(of paths: some Collection<FilePath>) -> String? {
        let sources = Set(paths.compactMap { path -> String? in
            let source = path.memoz.sourceIndex
            return source.isEmpty ? nil : source
        })
        return sources.count == 1 ? sources.first : nil
    }

    /// Copies each file next to itself as "name 2", "name 3" and so on, and announces the copies so the results list
    /// shows them.
    static func duplicate(_ paths: [FilePath]) {
        var created: [FilePath] = []
        for source in paths where source.exists {
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

    /// Zips the files into one archive beside them, named after the file when there is one, "Archive" otherwise.
    static func compress(_ paths: [FilePath]) {
        let paths = paths.filter(\.exists)
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

    static func export(_ paths: [FilePath], as format: ExportFormat) {
        let panel = NSSavePanel()
        panel.allowsOtherFileTypes = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = switch format {
        case .csv: [.commaSeparatedText]
        case .tsv: [.tabSeparatedText]
        case .json: [.json]
        case .plaintext: [.plainText]
        }
        panel.nameFieldStringValue = switch format {
        case .csv: "cling-files.csv"
        case .tsv: "cling-files.tsv"
        case .json: "cling-files.json"
        case .plaintext: "cling-files.txt"
        }

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try write(paths, as: format, to: url)
            } catch {
                log.error("Failed to write to \(url.path): \(error.localizedDescription)")
            }
        }
    }

    private static func copyList(_ items: [String], _ style: ListStyle) {
        let text = items.map { style.quoted ? "\"\($0)\"" : $0 }.joined(separator: style.separator)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func write(_ paths: [FilePath], as format: ExportFormat, to url: URL) throws {
        switch format {
        case .csv, .tsv:
            let separator = format == .csv ? "," : "\t"
            let header = ["Path", "Size", "Date"].joined(separator: separator)
            let rows = paths.map { path in
                [pathString(path), "\(path.memoz.size)", path.memoz.isoFormattedModificationDate].joined(separator: separator)
            }
            try ([header] + rows).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        case .json:
            let entries = paths.map { path in
                [
                    "path": pathString(path),
                    "size": path.memoz.size,
                    "date": path.memoz.isoFormattedModificationDate,
                ] as [String: Any]
            }
            try JSONSerialization.data(withJSONObject: entries, options: .prettyPrinted).write(to: url)
        case .plaintext:
            try paths.map(pathString).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
