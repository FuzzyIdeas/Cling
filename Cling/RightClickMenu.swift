import AppKit
import Lowtech
import SwiftUI
import System

struct RightClickMenu: View {
    @Binding var selectedResults: Set<FilePath>

    var orderedResults: [FilePath]

    var body: some View {
        Menu("Export results list") {
            Button("as CSV") { exportAs(type: .csv) }
            Button("as TSV") { exportAs(type: .tsv) }
            Button("as JSON") { exportAs(type: .json) }
            Button("as plaintext") { exportAs(type: .plaintext) }
        }
        Menu("Copy paths...") {
            Button("separated by space") { copyPaths(separator: " ") }
            Button("separated by space and quoted") { copyPaths(separator: " ", quoted: true) }
            Button("separated by comma") { copyPaths(separator: ",") }
            Button("with each file on a separate line") { copyPaths(separator: "\n") }
        }
        Menu("Copy filenames...") {
            Button("separated by space") { copyFilenames(separator: " ") }
            Button("separated by space and quoted") { copyFilenames(separator: " ", quoted: true) }
            Button("separated by comma") { copyFilenames(separator: ",") }
            Button("with each file on a separate line") { copyFilenames(separator: "\n") }
                .keyboardShortcut("c", modifiers: [.command, .option, .control])
        }

        Button("Copy files to...") {
            performFileOperation(.copy)
        }

        Button("Move files to...") {
            performFileOperation(.move)
        }
        Button("Exclude from index") {
            FUZZY.excludeFromIndex(paths: selectedResults)
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

    private func copyPaths(separator: String, quoted: Bool = false) {
        let filepaths = orderedSelection.map { path in
            quoted ? "\"\(path.string)\"" : path.string
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
            return "\(path.string),\(size),\(date)"
        }.joined(separator: "\n")
        let csvContent = "\(header)\n\(fileContents)"
        try csvContent.write(to: url, atomically: true, encoding: .utf8)
    }

    private func exportTSV(to url: URL) throws {
        let header = "Path\tSize\tDate"
        let fileContents = orderedSelection.map { path in
            let size = path.memoz.size
            let date = path.memoz.isoFormattedModificationDate
            return "\(path.string)\t\(size)\t\(date)"
        }.joined(separator: "\n")
        let tsvContent = "\(header)\n\(fileContents)"
        try tsvContent.write(to: url, atomically: true, encoding: .utf8)
    }

    private func exportJSON(to url: URL) throws {
        let fileContents = orderedSelection.map { path in
            let size = path.memoz.size
            let date = path.memoz.isoFormattedModificationDate
            return [
                "path": path.string,
                "size": size,
                "date": date,
            ]
        }
        let jsonData = try JSONSerialization.data(withJSONObject: fileContents, options: .prettyPrinted)
        try jsonData.write(to: url)
    }

    private func exportPlaintext(to url: URL) throws {
        let fileContents = orderedSelection.map(\.string).joined(separator: "\n")
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
