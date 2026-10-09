import AppKit
import Defaults
import Foundation
import Lowtech
import System

// MARK: - cling open

/// What the toolbar's Open, Show in Finder, Open in Terminal, Open in Editor and Shelve buttons do, for paths picked
/// somewhere other than Cling's own windows, such as the Alfred workflow. Going through the app keeps the terminal,
/// editor and shelf the ones set in Settings, and the paths count as runs, so they rank and show in recents as if
/// they had been opened from Cling.
extension FuzzyClient {
    enum OpenAction: String, CaseIterable {
        case open, reveal, terminal, editor, shelve
    }

    nonisolated static func openPaths(_ request: ClingRequest) -> ClingResponse {
        guard let action = OpenAction(rawValue: request.action ?? "open") else {
            let names = OpenAction.allCases.map(\.rawValue).joined(separator: ", ")
            return ClingResponse(error: "no such way to open: \(request.action ?? ""). Use one of \(names)")
        }
        let paths = (request.paths ?? []).compactMap { ($0 as NSString).expandingTildeInPath.existingFilePath }
        guard !paths.isEmpty else {
            return ClingResponse(error: "none of these paths exist")
        }
        let answer = waitOnMain { () -> ClingResponse in
            if let error = open(paths, action) {
                return ClingResponse(error: error)
            }
            RH.trackRun(paths, fromWindow: false)
            return ClingResponse(status: "done")
        }
        return answer ?? ClingResponse(error: "Cling is busy and did not answer in time. Try again in a moment.")
    }

    /// nil when it went through, otherwise why not.
    @MainActor
    private static func open(_ paths: [FilePath], _ action: OpenAction) -> String? {
        let urls = paths.map(\.url)
        switch action {
        case .open:
            urls.forEach { NSWorkspace.shared.open($0) }
        case .reveal:
            revealInFinder(urls)
        case .terminal:
            guard let terminal = Defaults[.terminalApp].existingFilePath?.url else {
                return "no terminal app is set in Cling Settings > Open With"
            }
            // A terminal opens folders, so a file opens its folder.
            let dirs = paths.map { $0.isDir ? $0.url : $0.dir.url }.uniqued
            NSWorkspace.shared.open(dirs, withApplicationAt: terminal, configuration: .init(), completionHandler: { _, _ in })
        case .editor:
            guard let editor = Defaults[.editorApp].existingFilePath?.url else {
                return "no editor app is set in Cling Settings > Open With"
            }
            NSWorkspace.shared.open(urls, withApplicationAt: editor, configuration: .init(), completionHandler: { _, _ in })
        case .shelve:
            let shelfApp = Defaults[.shelfApp]
            if shelfApp == CLING_STASH_APP {
                STASH.add(paths)
                return nil
            }
            guard let shelf = shelfApp.existingFilePath?.url else {
                return "no shelf app is set in Cling Settings > Open With"
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.open(urls, withApplicationAt: shelf, configuration: config, completionHandler: { _, _ in })
        }
        return nil
    }
}
