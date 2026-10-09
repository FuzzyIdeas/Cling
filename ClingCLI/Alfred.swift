import ArgumentParser
import Foundation

// MARK: - Alfred

/// The Script Filter output for Cling's Alfred workflow. Building it here instead of in the workflow's scripts keeps
/// the workflow to one line per object with nothing to install (Alfred cannot count on Python, and macOS 14 has no
/// jq), and it changes with Cling's updates without the workflow being installed again.
struct Alfred: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Script Filter output for Cling's Alfred workflow",
        shouldDisplay: false,
        subcommands: [Search.self, Reindex.self]
    )
}

extension Alfred {
    struct Search: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Search results, or recent files for an empty query")

        @Argument(help: "What the user typed after the keyword")
        var query = ""

        @Option(name: .shortAndLong, help: "Max results")
        var count = 40

        mutating func run() throws {
            let query = query.trimmingCharacters(in: .whitespaces)
            let request = query.isEmpty
                ? ClingRequest(command: .recents, maxResults: count)
                : ClingRequest(command: .search, query: query, maxResults: count)
            guard let response = AlfredOutput.ask(request) else { return }

            let results = response.results ?? []
            guard !results.isEmpty else {
                AlfredOutput.print([AlfredOutput.message(query.isEmpty ? "No recent files" : "No files match \"\(query)\"")])
                return
            }
            let apps = AlfredApps()
            AlfredOutput.print(results.map { apps.item(for: $0) }, extra: ["skipknowledge": true])
        }
    }

    struct Reindex: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "The scopes and drives to reindex, and the walk in progress")

        mutating func run() throws {
            guard let status = AlfredOutput.ask(ClingRequest(command: .status)) else { return }

            let scopes = (status.scopes ?? []).filter(\.enabled)
            let volumes = (status.volumes ?? []).filter { $0.enabled && FileManager.default.fileExists(atPath: $0.path) }
            var items = [[String: Any]]()

            let walking = scopes.filter(\.indexing).map(\.name) + volumes.filter(\.indexing).map(\.name)
            if !walking.isEmpty {
                let walked = scopes.reduce(0) { $0 + ($1.indexing ? $1.operationCount ?? 0 : 0) }
                    + volumes.reduce(0) { $0 + ($1.indexing ? $1.operationCount ?? 0 : 0) }
                items.append([
                    "title": "Reindexing \(walking.joined(separator: ", "))",
                    "subtitle": "\(walked.formatted()) files so far, ↩ to stop",
                    "arg": "", "variables": ["reindex": "cancel"],
                ])
            }

            let total = scopes.reduce(0) { $0 + $1.count }
            items.append([
                "title": "Reindex everything",
                "subtitle": "\(total.formatted()) files in \(scopes.count) scopes",
                "arg": "", "variables": ["reindex": "all"],
            ])
            for scope in scopes {
                var item: [String: Any] = [
                    "title": "Reindex \(scope.name)",
                    "subtitle": AlfredOutput.scopeDetail(scope.count, scope.lastIndexedAt),
                    "arg": "", "variables": ["reindex": scope.rawValue],
                ]
                if let folder = AlfredOutput.scopeFolder[scope.rawValue] {
                    item["icon"] = ["type": "fileicon", "path": folder]
                }
                items.append(item)
            }
            for volume in volumes {
                items.append([
                    "title": "Reindex \(volume.name)",
                    "subtitle": "\(volume.path), \(volume.count.formatted()) files",
                    "arg": "", "variables": ["reindex": volume.path],
                    "icon": ["type": "fileicon", "path": volume.path],
                ])
            }
            // While a walk runs, the list asks again every half second so its count moves.
            AlfredOutput.print(items, extra: walking.isEmpty ? ["skipknowledge": true] : ["skipknowledge": true, "rerun": 0.5])
        }
    }
}

// MARK: - AlfredOutput

enum AlfredOutput {
    /// The folder whose icon stands for each scope. Expanded here because Alfred reads a bare `~` as a missing file.
    static let scopeFolder = [
        "home": "~", "library": "~/Library", "applications": "/Applications", "system": "/System", "root": "/",
        "cloud": "~/Library/CloudStorage",
    ].mapValues { NSString(string: $0).expandingTildeInPath }

    /// The app's answer, or nil after printing an item that says why there is none.
    static func ask(_ request: ClingRequest) -> ClingResponse? {
        let data: Data?
        do {
            data = try sendMachPort(data: request.encoded(), recvTimeout: 10)
        } catch let error as NSError where error.code == 1 {
            // No port to send to: the app is not running.
            print([message("Cling isn't running", subtitle: "↩ to open it", variables: ["action": "launch"])])
            return nil
        } catch {
            print([message("Cling did not answer", subtitle: "Try again in a moment")])
            return nil
        }
        guard let data, let response = try? JSONDecoder().decode(ClingResponse.self, from: data) else {
            print([message("Cling did not answer", subtitle: "Try again in a moment")])
            return nil
        }
        if let error = response.error {
            print([message(error)])
            return nil
        }
        return response
    }

    static func message(_ title: String, subtitle: String = "", variables: [String: String]? = nil) -> [String: Any] {
        var item: [String: Any] = ["title": title, "subtitle": subtitle, "valid": variables != nil]
        if let variables {
            item["arg"] = ""
            item["variables"] = variables
        }
        return item
    }

    static func scopeDetail(_ count: Int, _ lastIndexedAt: Double?) -> String {
        guard let lastIndexedAt else { return "\(count.formatted()) files" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let when = formatter.localizedString(for: Date(timeIntervalSince1970: lastIndexedAt), relativeTo: Date())
        return "\(count.formatted()) files, indexed \(when)"
    }

    static func print(_ items: [[String: Any]], extra: [String: Any] = [:]) {
        var root = extra
        root["items"] = items
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data)
    }
}

// MARK: - AlfredApps

/// The apps the modifier keys open results in, read from Cling's settings so they match its toolbar.
struct AlfredApps {
    init() {
        let defaults = UserDefaults(suiteName: "com.lowtechguys.Cling")
        tilde = defaults?.object(forKey: "copyPathsWithTilde") as? Bool ?? true
        terminal = Self.name(defaults?.string(forKey: "terminalApp") ?? "/System/Applications/Utilities/Terminal.app")
        editor = Self.name(defaults?.string(forKey: "editorApp") ?? "/System/Applications/TextEdit.app")

        let shelfApp = defaults?.string(forKey: "shelfApp") ?? "cling://stash"
        shelf = shelfApp == "cling://stash" ? "Add to Cling's stash" : Self.name(shelfApp).map { "Send to \($0)" }
    }

    static let home = NSHomeDirectory()

    let tilde: Bool
    let terminal: String?
    let editor: String?
    /// The shelf modifier's subtitle.
    let shelf: String?

    static func tildify(_ path: String) -> String {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    func item(for result: ClingSearchResult) -> [String: Any] {
        let path = result.path
        let copied = tilde ? Self.tildify(path) : path
        var item: [String: Any] = [
            "uid": path,
            "type": "file:skipcheck",
            "title": (path as NSString).lastPathComponent,
            "subtitle": Self.tildify((path as NSString).deletingLastPathComponent),
            "arg": path,
            "icon": ["type": "fileicon", "path": path],
            "quicklookurl": path,
            "text": ["copy": copied, "largetype": copied],
            "variables": ["action": "open"],
            "mods": [
                "cmd": mod("Show in Finder", "reveal", path),
                "alt": editor.map { mod("Open in \($0)", "editor", path) } ?? unset("an editor"),
                "ctrl": terminal.map { mod(result.isDir ? "Open in \($0)" : "Open its folder in \($0)", "terminal", path) }
                    ?? unset("a terminal"),
                "shift": shelf.map { mod($0, "shelve", path) } ?? unset("a shelf app"),
                "fn": mod("Paste path", "paste", copied),
            ],
        ]
        // Tab on a folder narrows the search to it. Cling reads `in:` up to the next space, so only for paths without one.
        let folder = Self.tildify(path)
        if result.isDir, !folder.contains(" ") {
            item["autocomplete"] = "in:\(folder) "
        }
        return item
    }

    private static func name(_ appPath: String) -> String? {
        guard FileManager.default.fileExists(atPath: appPath) else { return nil }
        return ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    private func mod(_ subtitle: String, _ action: String, _ arg: String) -> [String: Any] {
        ["subtitle": subtitle, "arg": arg, "valid": true, "variables": ["action": action]]
    }

    private func unset(_ what: String) -> [String: Any] {
        ["subtitle": "Set \(what) in Cling Settings > Open With", "valid": false]
    }
}
