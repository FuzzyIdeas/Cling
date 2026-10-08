import AppKit
import Carbon.HIToolbox
import Defaults
import Foundation
import KeyboardShortcuts
import Lowtech
import System

// MARK: - CLIConfig

/// The configuration commands the CLI sends over the Mach port: filters, scripts, volumes, scopes, ignore
/// rules and shortcuts, plus the two diagnostics that need the live engines.
///
/// Each one changes what the matching Settings pane changes, the same way, so a change from the terminal or
/// an agent shows up in Settings and in the window as if the user had made it. The MCP gate has already run
/// by the time a request lands here, see `mcpRefusal`.
enum CLIConfig {
    nonisolated static func handle(_ request: ClingRequest, coordinator coord: SearchCoordinator) -> ClingResponse {
        // The diagnostics search the engines, which is thread-safe and slow enough to keep off the main thread.
        switch request.command {
        case .why:
            return why(request, coordinator: coord)
        case .explain:
            return diagnose(request, coordinator: coord)
        default:
            break
        }
        let answer = waitOnMain { () -> ClingResponse in
            switch request.command {
            case .settings: MCPSettingsBridge.handle(request)
            case .filters: filters(request)
            case .scripts: scripts(request)
            case .volumes: volumes(request)
            case .cloud: cloud(request)
            case .scopes: scopes(request)
            case .ignore: ignore(request)
            case .shortcuts: shortcuts(request)
            default: ClingResponse(error: "not a configuration command")
            }
        }
        return answer ?? ClingResponse(error: "Cling is busy and did not answer in time. Try again in a moment.")
    }
}

// MARK: - Filters

extension CLIConfig {
    private struct QuickFilterInfo: Encodable {
        let name: String
        let key: String?
        let extensions: String?
        let exclude: String?
        let match: String
        let prepend: String?
        let append: String?
        let rawQuery: String?
        let folders: [String]
        let maxDepth: Int?
        let icon: String?
        let hue: Double?
        /// What the filter adds around the typed query, as the editor's "Runs as" shows it.
        let runsAs: String
        let active: Bool
        let autoOff: AutoOffInfo
    }

    private struct FolderFilterInfo: Encodable {
        let name: String
        let key: String?
        let folders: [String]
        let maxDepth: Int?
        let icon: String?
        let hue: Double?
        let active: Bool
        let autoOff: AutoOffInfo
    }

    /// When the filter turns off, and whether that is its own time or the setting's.
    private struct AutoOffInfo: Encodable {
        @MainActor init(_ own: FilterAutoOff?) {
            setting = own.map { $0.enabled ? AutoOffDuration.text($0.after) : "off" } ?? "default"
            seconds = (own ?? .current).period.map { Int($0) }
        }

        /// `default`, `off` or the filter's own time, e.g. `10 minutes`.
        let setting: String
        /// Seconds in the background before it turns off, nil when it stays on.
        let seconds: Int?

        var text: String {
            let when = seconds.map { "turns off after \(AutoOffDuration.text(TimeInterval($0))) in the background" } ?? "stays on"
            return setting == "default" ? "\(when) (default)" : when
        }
    }

    private struct FilterList: Encodable {
        var quick: [QuickFilterInfo]?
        var folder: [FolderFilterInfo]?
        var warnings: [String]?
    }

    @MainActor private static func info(_ f: QuickFilter) -> QuickFilterInfo {
        QuickFilterInfo(
            name: f.id, key: f.key.map { String($0) }, extensions: f.extensions, exclude: f.exclude,
            match: f.match.rawValue, prepend: f.preQuery, append: f.postQuery, rawQuery: f.rawQuery,
            folders: f.folders?.map(\.string) ?? [], maxDepth: f.maxDepth, icon: f.icon, hue: f.color?.hue,
            runsAs: f.queryString, active: FUZZY.quickFilter?.uuid == f.uuid, autoOff: AutoOffInfo(f.autoOff)
        )
    }

    @MainActor private static func info(_ f: FolderFilter) -> FolderFilterInfo {
        FolderFilterInfo(
            name: f.id, key: f.key.map { String($0) }, folders: f.folders.map(\.string), maxDepth: f.maxDepth,
            icon: f.icon, hue: f.color?.hue, active: FUZZY.folderFilter?.uuid == f.uuid, autoOff: AutoOffInfo(f.autoOff)
        )
    }

    private static func filterText(_ list: FilterList) -> String {
        var lines: [String] = []
        if let quick = list.quick {
            lines.append("Quick filters:")
            lines += quick.isEmpty
                ? ["  none"]
                : quick.map { f in
                    "  \(f.name)\(f.key.map { "  ⌥\($0.uppercased())" } ?? "")\(f.active ? "  (active)" : "")\n    runs as: \(f.runsAs.isEmpty ? "(nothing)" : f.runsAs)\n    \(f.autoOff.text)"
                }
        }
        if let folder = list.folder {
            if !lines.isEmpty {
                lines.append("")
            }
            lines.append("Folder filters:")
            lines += folder.isEmpty
                ? ["  none"]
                : folder.map { f in
                    "  \(f.name)\(f.key.map { "  ⌥\($0.uppercased())" } ?? "")\(f.active ? "  (active)" : "")\n    \(f.folders.joined(separator: ", "))\(f.maxDepth.map { "  depth ≤ \($0)" } ?? "")\n    \(f.autoOff.text)"
                }
        }
        for warning in list.warnings ?? [] {
            lines.append("warning: \(warning)")
        }
        return lines.joined(separator: "\n")
    }

    @MainActor private static func filterResponse(kind: String?, warnings: [String] = []) -> ClingResponse {
        var list = FilterList()
        if kind != "folder" {
            list.quick = Defaults[.quickFilters].map(info)
        }
        if kind != "quick" {
            list.folder = Defaults[.folderFilters].map(info)
        }
        list.warnings = warnings.isEmpty ? nil : warnings
        return ClingResponse(status: filterText(list), payload: payloadJSON(list))
    }

    /// One letter or digit, or nil to clear. Returns an error message for anything else.
    private static func filterKey(_ raw: String?) -> Result<Character?, ClingError> {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty, raw != "none" else {
            return .success(nil)
        }
        guard raw.count == 1, let ch = raw.first, ch.isLetter || ch.isNumber else {
            return .failure(ClingError("a filter key is one letter or digit, or none. Got '\(raw)'"))
        }
        return .success(ch)
    }

    /// nil keeps the filter's current auto-off. `default` drops its own time, `off` keeps it on, and a duration sets
    /// its own time. A bare number is seconds, as for the `filterAutoOffAfter` setting.
    @MainActor private static func filterAutoOff(_ raw: String?, current: FilterAutoOff?) -> Result<FilterAutoOff?, ClingError> {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else {
            return .success(current)
        }
        let base = current ?? .current
        switch raw {
        case "default": return .success(nil)
        case "off", "never", "none": return .success(FilterAutoOff(enabled: false, after: base.after))
        default:
            guard let seconds = AutoOffDuration.parse(raw, current: 1) else {
                return .failure(ClingError("autoOff is a duration like 90s, 10m or 2h, off, or default. Got '\(raw)'"))
            }
            if let problem = AutoOffDuration.problem(seconds) {
                return .failure(ClingError("\(problem). Got '\(raw)'"))
            }
            return .success(FilterAutoOff(enabled: true, after: seconds))
        }
    }

    private static func folderPaths(_ raw: [String]) -> Result<[FilePath], ClingError> {
        var paths: [FilePath] = []
        var missing: [String] = []
        for item in raw.map({ ($0 as NSString).expandingTildeInPath }) where !item.isEmpty {
            if let path = item.existingFilePath, path.isDir {
                paths.append(path)
            } else {
                missing.append(item)
            }
        }
        guard missing.isEmpty else {
            return .failure(ClingError("not a folder: \(missing.joined(separator: ", "))"))
        }
        return .success(paths)
    }

    @MainActor static func filters(_ req: ClingRequest) -> ClingResponse {
        switch req.action ?? "list" {
        case "list":
            return filterResponse(kind: req.key)
        case "write":
            guard let payload = req.payload, let spec = try? JSONDecoder().decode(ClingFilterSpec.self, from: Data(payload.utf8)) else {
                return ClingResponse(error: "write needs a filter spec")
            }
            switch spec.kind {
            case "quick": return writeQuickFilter(spec)
            case "folder": return writeFolderFilter(spec)
            default: return ClingResponse(error: "kind is quick or folder, not '\(spec.kind)'")
            }
        case "delete":
            guard let name = req.value?.lowercased() else {
                return ClingResponse(error: "delete needs a filter name")
            }
            switch req.key {
            case "quick":
                guard let filter = Defaults[.quickFilters].first(where: { $0.id.lowercased() == name }) else {
                    return ClingResponse(error: "no quick filter named '\(req.value ?? "")'")
                }
                Defaults[.quickFilters].removeAll { $0.uuid == filter.uuid }
                if FUZZY.quickFilter?.uuid == filter.uuid {
                    FUZZY.quickFilter = nil
                }
            case "folder":
                guard let filter = Defaults[.folderFilters].first(where: { $0.id.lowercased() == name }) else {
                    return ClingResponse(error: "no folder filter named '\(req.value ?? "")'")
                }
                Defaults[.folderFilters].removeAll { $0.uuid == filter.uuid }
                if FUZZY.folderFilter?.uuid == filter.uuid {
                    FUZZY.folderFilter = nil
                }
            default:
                return ClingResponse(error: "delete needs the kind: quick or folder")
            }
            return filterResponse(kind: req.key)
        default:
            return ClingResponse(error: "unknown filter action '\(req.action ?? "")'")
        }
    }

    /// Creates the filter, or edits the one with that name. A field left out keeps its current value, the
    /// same as editing one field in the Filters pane.
    @MainActor private static func writeQuickFilter(_ spec: ClingFilterSpec) -> ClingResponse {
        var all = Defaults[.quickFilters]
        let lookup = (spec.rename ?? spec.name).lowercased()
        let index = all.firstIndex { $0.id.lowercased() == lookup }
        let current = index.map { all[$0] }
        let name = spec.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            return ClingResponse(error: "a filter needs a name")
        }
        if all.contains(where: { $0.id.lowercased() == name.lowercased() && $0.uuid != current?.uuid }) {
            return ClingResponse(error: "there is already a quick filter named '\(name)'")
        }

        let key: Character?
        switch filterKey(spec.key) {
        case let .success(k): key = spec.key == nil ? current?.key : k
        case let .failure(error): return ClingResponse(error: error.message)
        }
        var folders = current?.folders
        if let raw = spec.folders {
            switch folderPaths(raw) {
            case let .success(paths): folders = paths.isEmpty ? nil : paths
            case let .failure(error): return ClingResponse(error: error.message)
            }
        }
        let match: FilterMatch
        if let raw = spec.match {
            guard let m = FilterMatch(rawValue: raw.lowercased()) else {
                return ClingResponse(error: "match is both, files or folders, not '\(raw)'")
            }
            match = m
        } else {
            match = current?.match ?? .both
        }
        /// An empty string clears a text field; nil keeps it.
        func text(_ new: String?, _ old: String?) -> String? {
            guard let new else { return old }
            let trimmed = new.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        let maxDepth = spec.maxDepth.map { $0 < 0 ? nil : $0 } ?? current?.maxDepth
        let autoOff: FilterAutoOff?
        switch filterAutoOff(spec.autoOff, current: current?.autoOff) {
        case let .success(value): autoOff = value
        case let .failure(error): return ClingResponse(error: error.message)
        }

        let filter = QuickFilter(
            id: name,
            extensions: text(spec.extensions, current?.extensions),
            preQuery: text(spec.prepend, current?.preQuery),
            postQuery: text(spec.append, current?.postQuery),
            dirsOnly: match == .folders,
            folders: folders,
            key: key,
            maxDepth: maxDepth,
            exclude: text(spec.exclude, current?.exclude),
            rawQuery: text(spec.rawQuery, current?.rawQuery),
            match: match,
            icon: spec.icon ?? current?.icon,
            color: spec.hue.map { FilterColor(hue: $0) } ?? current?.color,
            autoOff: autoOff,
            uuid: current?.uuid ?? UUID().uuidString
        )
        // The Filters pane saves nothing that would match every file, so neither does this.
        guard filter.extensions != nil || filter.exclude != nil || filter.match != .both || filter.folders?.isEmpty == false
            || filter.rawQuery != nil || filter.preQuery != nil || filter.postQuery != nil
        else {
            return ClingResponse(error: "a quick filter needs at least one of: extensions, exclude, match, folders, prepend, append or rawQuery")
        }

        // Two filters on one key would leave one unreachable, so the other one gives its key up, as in the
        // Filters pane.
        var warnings: [String] = []
        if let key, let other = all.firstIndex(where: { $0.key == key && $0.uuid != filter.uuid }) {
            warnings.append("⌥\(String(key).uppercased()) moved here from the quick filter '\(all[other].id)', which has no key now")
            all[other] = all[other].withKey(nil)
        }
        if let key, let folder = Defaults[.folderFilters].first(where: { $0.key == key }) {
            warnings.append("the folder filter '\(folder.id)' also uses ⌥\(String(key).uppercased()); pressing it applies both")
        }
        if let index {
            all[index] = filter
        } else {
            all.insert(filter, at: 0)
        }
        Defaults[.quickFilters] = all
        if FUZZY.quickFilter?.uuid == filter.uuid {
            FUZZY.quickFilter = filter
        }
        return filterResponse(kind: "quick", warnings: warnings)
    }

    @MainActor private static func writeFolderFilter(_ spec: ClingFilterSpec) -> ClingResponse {
        var all = Defaults[.folderFilters]
        let lookup = (spec.rename ?? spec.name).lowercased()
        let index = all.firstIndex { $0.id.lowercased() == lookup }
        let current = index.map { all[$0] }
        let name = spec.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            return ClingResponse(error: "a filter needs a name")
        }
        if all.contains(where: { $0.id.lowercased() == name.lowercased() && $0.uuid != current?.uuid }) {
            return ClingResponse(error: "there is already a folder filter named '\(name)'")
        }
        for (field, value) in [("extensions", spec.extensions), ("exclude", spec.exclude), ("match", spec.match), ("prepend", spec.prepend), ("append", spec.append), ("rawQuery", spec.rawQuery)] where value != nil {
            return ClingResponse(error: "\(field) belongs to quick filters. A folder filter has folders, maxDepth, key, icon, hue and autoOff.")
        }

        let key: Character?
        switch filterKey(spec.key) {
        case let .success(k): key = spec.key == nil ? current?.key : k
        case let .failure(error): return ClingResponse(error: error.message)
        }
        var folders = current?.folders ?? []
        if let raw = spec.folders {
            switch folderPaths(raw) {
            case let .success(paths): folders = paths
            case let .failure(error): return ClingResponse(error: error.message)
            }
        }
        guard !folders.isEmpty else {
            return ClingResponse(error: "a folder filter needs at least one folder")
        }
        let autoOff: FilterAutoOff?
        switch filterAutoOff(spec.autoOff, current: current?.autoOff) {
        case let .success(value): autoOff = value
        case let .failure(error): return ClingResponse(error: error.message)
        }
        let filter = FolderFilter(
            id: name, folders: folders, key: key,
            maxDepth: spec.maxDepth.map { $0 < 0 ? nil : $0 } ?? current?.maxDepth,
            icon: spec.icon ?? current?.icon,
            color: spec.hue.map { FilterColor(hue: $0) } ?? current?.color,
            autoOff: autoOff,
            uuid: current?.uuid ?? UUID().uuidString
        )

        var warnings: [String] = []
        if let key, let other = all.firstIndex(where: { $0.key == key && $0.uuid != filter.uuid }) {
            warnings.append("⌥\(String(key).uppercased()) moved here from the folder filter '\(all[other].id)', which has no key now")
            all[other] = all[other].withKey(nil)
        }
        if let key, let quick = Defaults[.quickFilters].first(where: { $0.key == key }) {
            warnings.append("the quick filter '\(quick.id)' also uses ⌥\(String(key).uppercased()); pressing it applies both")
        }
        if let index {
            all[index] = filter
        } else {
            all.insert(filter, at: 0)
        }
        Defaults[.folderFilters] = all
        if FUZZY.folderFilter?.uuid == filter.uuid {
            FUZZY.folderFilter = filter
        }
        return filterResponse(kind: "folder", warnings: warnings)
    }
}

// MARK: - Scripts

extension CLIConfig {
    private struct ScriptInfo: Encodable {
        let name: String
        let path: String
        let runner: String
        let description: String?
        /// The ⌘⌃ key in the search window, whether it was set or assigned automatically.
        let key: String?
        let extensions: String?
        let minFiles: Int?
        let maxFiles: Int?
        let filesOnly: Bool
        let dirsOnly: Bool
        let confirm: Bool
        let sequential: Bool
        let showOutput: Bool
        var code: String?
    }

    private struct ScriptList: Encodable {
        let folder: String
        let scripts: [ScriptInfo]
        var warnings: [String]?
    }

    private static func runner(of url: URL, content: String) -> ScriptRunner {
        let byExtension = ScriptRunner(fromExtension: url.pathExtension)
        guard let byShebang = ScriptRunner(fromShebang: ScriptHeaderParser.shebang(content) ?? "") else {
            return byExtension ?? .zsh
        }
        // `sh` and `zsh` both run /bin/zsh, so the shebang can't tell them apart and a `.zsh` script would be
        // rewritten as `.sh`. The extension can.
        if let byExtension, byExtension.path == byShebang.path {
            return byExtension
        }
        return byShebang
    }

    @MainActor private static func info(_ url: URL, withCode: Bool = false) -> ScriptInfo {
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let params = ScriptHeaderParser.parse(content)
        return ScriptInfo(
            name: url.deletingPathExtension().lastPathComponent,
            path: url.path,
            runner: runner(of: url, content: content).rawValue,
            description: params.description,
            key: SM.scriptShortcuts[url].map { String($0) },
            extensions: params.extensions,
            minFiles: params.minFiles,
            maxFiles: params.maxFiles,
            filesOnly: params.filesOnly,
            dirsOnly: params.dirsOnly,
            confirm: params.confirm,
            sequential: params.sequential,
            showOutput: params.showOutput,
            code: withCode ? content : nil
        )
    }

    private static func scriptText(_ list: ScriptList) -> String {
        var lines = ["Scripts in \(list.folder):"]
        lines += list.scripts.isEmpty
            ? ["  none"]
            : list.scripts.map { s in
                var line = "  \(s.name) (\(s.runner))\(s.key.map { "  ⌘⌃\($0.uppercased())" } ?? "")"
                if let description = s.description {
                    line += "\n    \(description)"
                }
                if let code = s.code {
                    line += "\n\n" + code
                }
                return line
            }
        for warning in list.warnings ?? [] {
            lines.append("warning: \(warning)")
        }
        return lines.joined(separator: "\n")
    }

    @MainActor private static func scriptResponse(_ urls: [URL], withCode: Bool = false, warnings: [String] = []) -> ClingResponse {
        let list = ScriptList(
            folder: scriptsFolder.string,
            scripts: urls.sorted(by: \.lastPathComponent).map { info($0, withCode: withCode) },
            warnings: warnings.isEmpty ? nil : warnings
        )
        return ClingResponse(status: scriptText(list), payload: payloadJSON(list))
    }

    /// Every file in the scripts folder with this name, executable or not: a script that lost its executable
    /// bit is still there, and writing a second one beside it would leave two files for one name.
    private static func scriptFiles(named name: String) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: scriptsFolder.url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return files.filter { $0.deletingPathExtension().lastPathComponent.lowercased() == name.lowercased() }
    }

    @MainActor static func scripts(_ req: ClingRequest) -> ClingResponse {
        switch req.action ?? "list" {
        case "list":
            return scriptResponse(SM.scriptURLs)
        case "show":
            guard let name = req.value, let url = scriptFiles(named: name).first else {
                return ClingResponse(error: "no script named '\(req.value ?? "")'")
            }
            return scriptResponse([url], withCode: true)
        case "delete":
            guard let name = req.value else {
                return ClingResponse(error: "delete needs a script name")
            }
            let files = scriptFiles(named: name)
            guard !files.isEmpty else {
                return ClingResponse(error: "no script named '\(name)'")
            }
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
            SM.fetchScripts()
            return scriptResponse(SM.scriptURLs)
        case "write", "key":
            guard let payload = req.payload, let spec = try? JSONDecoder().decode(ClingScriptSpec.self, from: Data(payload.utf8)) else {
                return ClingResponse(error: "\(req.action ?? "write") needs a script spec")
            }
            // A key change goes through the same rebuild, with nothing else in the spec, so it can never
            // carry new code past the scripts switch.
            if req.action == "key" {
                var keyOnly = ClingScriptSpec(name: spec.name)
                keyOnly.key = spec.key ?? "none"
                return writeScript(keyOnly)
            }
            return writeScript(spec)
        default:
            return ClingResponse(error: "unknown script action '\(req.action ?? "")'")
        }
    }

    /// Writes the script the way the Scripts pane saves one: the shebang, the managed header comments, then
    /// the code, executable. Settings left out of the spec keep their current values.
    @MainActor private static func writeScript(_ spec: ClingScriptSpec) -> ClingResponse {
        let name = spec.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            return ClingResponse(error: "a script needs a name")
        }
        let existing = scriptFiles(named: name).first
        let content = existing.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        if existing != nil, spec.code != nil, spec.replace != true {
            return ClingResponse(error: "a script named '\(name)' already exists. Pass replace to overwrite its code, or leave code out to change only its settings.")
        }
        guard existing != nil || spec.code != nil else {
            return ClingResponse(error: "no script named '\(name)'. A new script needs code.")
        }

        let currentRunner = existing.map { runner(of: $0, content: content) }
        var newRunner = currentRunner ?? .zsh
        if let raw = spec.runner {
            guard let r = ScriptRunner(rawValue: raw.lowercased()) else {
                return ClingResponse(error: "runner is one of \(ScriptRunner.allCases.map(\.rawValue).joined(separator: ", ")), not '\(raw)'")
            }
            newRunner = r
        }

        var params = existing == nil ? ScriptParams() : ScriptHeaderParser.parse(content)
        if let description = spec.description {
            params.description = description.isEmpty ? nil : description
        }
        if let raw = spec.key?.trimmingCharacters(in: .whitespaces).lowercased() {
            if raw.isEmpty || raw == "none" {
                params.key = nil
            } else {
                guard raw.count == 1, let ch = raw.first, ch.isLetter || ch.isNumber else {
                    return ClingResponse(error: "a script key is one letter or digit, or none. Got '\(raw)'")
                }
                params.key = raw
            }
        }
        if let extensions = spec.extensions {
            let cleaned = extensions.replacingOccurrences(of: ".", with: "").trimmingCharacters(in: .whitespaces)
            params.extensions = cleaned.isEmpty || cleaned.lowercased() == "none" ? nil : cleaned
        }
        if let n = spec.minFiles {
            params.minFiles = n > 0 ? n : nil
        }
        if let n = spec.maxFiles {
            params.maxFiles = n > 0 ? n : nil
        }
        if let v = spec.filesOnly {
            params.filesOnly = v
        }
        if let v = spec.dirsOnly {
            params.dirsOnly = v
        }
        if let v = spec.confirm {
            params.confirm = v
        }
        if let v = spec.sequential {
            params.sequential = v
        }
        if let v = spec.showOutput {
            params.showOutput = v
        }
        if params.filesOnly, params.dirsOnly {
            return ClingResponse(error: "filesOnly and dirsOnly together would hide the script for every selection")
        }

        // A shebang written by hand stays, unless the runner changed under it.
        let shebang = currentRunner == newRunner ? ScriptHeaderParser.shebang(content) : nil
        let body = spec.code.map { stripShebang($0) } ?? ScriptHeaderParser.body(content)
        let text = ScriptHeaderParser.rebuild(shebang: shebang, params: params, body: body, runner: newRunner)

        let target = (scriptsFolder / "\(name.safeFilename).\(newRunner.fileExtension)").url
        do {
            if !scriptsFolder.exists {
                scriptsFolder.mkdir(withIntermediateDirectories: true)
            }
            try text.write(to: target, atomically: true, encoding: .utf8)
            // Scripts must stay executable or `ScriptManager.fetchScripts` leaves them out of the list.
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            if let existing, existing.path != target.path {
                try? FileManager.default.removeItem(at: existing)
            }
        } catch {
            return ClingResponse(error: "could not write \(target.path): \(error.localizedDescription)")
        }
        SM.fetchScripts()

        var warnings: [String] = []
        if let key = params.key?.first,
           let other = SM.scriptShortcuts.first(where: { $0.value == key && $0.key.path != target.path })?.key
        {
            warnings.append("⌘⌃\(String(key).uppercased()) is also the key of '\(other.deletingPathExtension().lastPathComponent)'; only one of them runs")
        }
        if params.key == "o", SM.reservedShortcuts.contains("o") {
            warnings.append("⌘⌃O is Optimise with Clop while Clop is installed; this script takes it over")
        }
        if !proactive {
            warnings.append("the Scripts row and ⌘⌃ keys need Cling Pro, so this script will not run until then")
        }
        return scriptResponse([target], withCode: true, warnings: warnings)
    }

    /// An agent tends to send the whole file, shebang included; the runner writes its own.
    private static func stripShebang(_ code: String) -> String {
        guard code.hasPrefix("#!") else { return code }
        return code.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().joined()
    }
}

// MARK: - Volumes

extension CLIConfig {
    private struct VolumeInfo: Encodable {
        let name: String
        let path: String
        let mounted: Bool
        let enabled: Bool
        let indexed: Bool
        let indexing: Bool
        let count: Int
        let reindexIntervalSeconds: Int
        let reindexInterval: String
        let lastIndexedAt: Double?
        let local: Bool?
        let readOnly: Bool
    }

    private struct VolumeList: Encodable {
        let pro: Bool
        let automaticIndexing: Bool
        let volumes: [VolumeInfo]
    }

    /// The Reindex Interval slider's range.
    static let volumeIntervalRange: ClosedRange<TimeInterval> = 3600 ... 2_419_200

    @MainActor private static func volumeResponse() -> ClingResponse {
        let mounted = FUZZY.externalVolumes
        let all = mounted + FUZZY.disconnectedVolumes.sorted().filter { !mounted.contains($0) }
        let volumes = all.map { v in
            let interval = Defaults[.reindexTimeIntervalPerVolume][v] ?? DEFAULT_VOLUME_REINDEX_INTERVAL
            let file = volumeIndexFile(v)
            return VolumeInfo(
                name: v.name.string, path: v.string, mounted: mounted.contains(v),
                enabled: FUZZY.enabledVolumes.contains(v), indexed: FUZZY.volumeEngines[v] != nil,
                indexing: FUZZY.volumesIndexing.contains(v), count: FUZZY.volumeEngines[v]?.count ?? 0,
                reindexIntervalSeconds: Int(interval), reindexInterval: interval.humanizedInterval,
                lastIndexedAt: file.exists ? file.timestamp : nil,
                local: mounted.contains(v) ? v.url.isLocalVolume : nil,
                readOnly: FUZZY.readOnlyVolumes.contains(v)
            )
        }
        let list = VolumeList(pro: proactive, automaticIndexing: !Defaults[.disableAutomaticVolumeIndexing], volumes: volumes)
        var lines = volumes.isEmpty
            ? ["No external volumes."]
            : volumes.map { v in
                let state = !v.enabled ? "disabled" : v.indexing ? "indexing" : v.indexed ? "\(v.count.formatted()) entries" : "not indexed"
                return "\(v.name) (\(v.path))\(v.mounted ? "" : " [disconnected]"): \(state), reindexed every \(v.reindexInterval)"
            }
        if !proactive {
            lines.append("Indexing external volumes needs Cling Pro.")
        }
        return ClingResponse(status: lines.joined(separator: "\n"), payload: payloadJSON(list))
    }

    @MainActor private static func findVolume(_ raw: String?) -> FilePath? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let all = FUZZY.externalVolumes + Array(FUZZY.disconnectedVolumes) + Defaults[.disabledVolumes]
        let path = (raw as NSString).expandingTildeInPath
        return all.first { $0.string == path || $0.string == "/Volumes/" + raw }
            ?? all.first { $0.name.string.lowercased() == raw.lowercased() }
    }

    @MainActor static func volumes(_ req: ClingRequest) -> ClingResponse {
        let action = req.action ?? "list"
        guard action != "list" else {
            return volumeResponse()
        }
        // The whole Drives & Volumes list is disabled in Settings without Pro.
        guard proactive else {
            return ClingResponse(error: "indexing external volumes needs Cling Pro")
        }
        guard let volume = findVolume(req.value) else {
            return ClingResponse(error: "no volume named '\(req.value ?? "")'. List the volumes to see their names and paths.")
        }
        switch action {
        case "enable", "disable":
            // What the volume's toggle in Settings writes. Cling picks the change up on its own, and indexes a
            // volume that was just enabled and has no index yet.
            if action == "enable" {
                Defaults[.disabledVolumes].removeAll { $0 == volume }
            } else if !Defaults[.disabledVolumes].contains(volume) {
                Defaults[.disabledVolumes].append(volume)
            }
        case "interval":
            guard let seconds = req.key.flatMap(TimeInterval.init), volumeIntervalRange.contains(seconds) else {
                return ClingResponse(error: "interval takes seconds from \(Int(volumeIntervalRange.lowerBound)) (1 hour) to \(Int(volumeIntervalRange.upperBound)) (4 weeks). Got '\(req.key ?? "")'")
            }
            Defaults[.reindexTimeIntervalPerVolume][volume] = seconds
        case "remove":
            guard FUZZY.disconnectedVolumes.contains(volume) else {
                return ClingResponse(error: "\(volume.name.string) is connected. Settings only removes a disconnected volume; disable this one instead.")
            }
            FUZZY.removeVolume(volume)
        default:
            return ClingResponse(error: "unknown volume action '\(action)'")
        }
        return volumeResponse()
    }
}

// MARK: - Cloud storage

extension CLIConfig {
    private struct CloudInfo: Encodable {
        let name: String
        let account: String?
        let path: String
        let enabled: Bool
        /// Its online-only folders are being listed right now.
        let listing: Bool
        let count: Int
    }

    @MainActor private static func cloudResponse() -> ClingResponse {
        let disabled = FUZZY.disabledCloudRoots
        let engine = FUZZY.scopeEngines[.cloud]
        let locations = FUZZY.cloudLocations.map { location in
            let root = location.root.string
            return CloudInfo(
                name: location.name, account: location.account, path: root, enabled: !disabled.contains(root),
                listing: FUZZY.cloudListing[root] != nil, count: engine?.countBelow(root) ?? 0
            )
        }
        let lines = locations.isEmpty
            ? ["No cloud storage on this Mac."]
            : locations.map { l in
                let state = !l.enabled ? "disabled" : l.listing ? "listing, \(l.count.formatted()) entries so far" : "indexed, \(l.count.formatted()) entries"
                return "\(l.account.map { "\(l.name) \($0)" } ?? l.name) (\(l.path)): \(state)"
            }
        return ClingResponse(status: lines.joined(separator: "\n"), payload: payloadJSON(["locations": locations]))
    }

    @MainActor private static func findCloudLocation(_ raw: String?) -> CloudLocation? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let path = (raw as NSString).expandingTildeInPath
        let all = FUZZY.cloudLocations
        let lower = raw.lowercased()
        return all.first { $0.root.string == path }
            ?? all.first { $0.label.lowercased() == lower }
            ?? all.first { $0.account?.lowercased() == lower }
            ?? all.first { $0.name.lowercased() == lower }
    }

    @MainActor static func cloud(_ req: ClingRequest) -> ClingResponse {
        // Settings looks again each time it opens; so does the CLI, for an account added a moment ago.
        FUZZY.cloudLocations = CloudStorage.locations()
        let action = req.action ?? "list"
        guard action != "list" else {
            return cloudResponse()
        }
        if action == "refresh", req.value == nil {
            FUZZY.listCloudFolders()
            return cloudResponse()
        }
        guard let location = findCloudLocation(req.value) else {
            return ClingResponse(error: "no cloud storage named '\(req.value ?? "")'. List them to see their names and paths.")
        }
        switch action {
        case "enable":
            // What the location's toggle in Settings writes: Cling walks and lists it once the change lands.
            Defaults[.disabledCloudLocations].removeAll { $0 == location.root }
        case "disable":
            if !Defaults[.disabledCloudLocations].contains(location.root) {
                Defaults[.disabledCloudLocations].append(location.root)
            }
        case "refresh":
            FUZZY.listCloudFolders([location])
        default:
            return ClingResponse(error: "unknown cloud action '\(action)'")
        }
        return cloudResponse()
    }
}

// MARK: - Scopes

extension CLIConfig {
    private struct ScopeInfo: Encodable {
        let name: String
        let label: String
        let enabled: Bool
        let needsPro: Bool
        /// Enabled and allowed by the licence, so its engine is loaded and searched.
        let searched: Bool
        let indexed: Bool
        let count: Int
        let roots: [String]
    }

    @MainActor private static func scopeResponse() -> ClingResponse {
        let enabled = Defaults[.searchScopes]
        let home = HOME.string
        let scopes = SearchScope.allCases.map { s in
            let roots: [String] = switch s {
            case .home: [home]
            case .library: [home + "/Library"]
            case .cloud: FUZZY.cloudRoots
            default: ScopeIgnore.roots(for: s)
            }
            // The cloud scope follows its folders' toggles (cling cloud), not the scope list.
            let on = s == .cloud ? !FUZZY.cloudRoots.isEmpty : enabled.contains(s)
            return ScopeInfo(
                name: s.rawValue, label: s.label, enabled: on,
                needsPro: !FuzzyClient.freeScopes.contains(s),
                searched: on && (proactive || FuzzyClient.freeScopes.contains(s)),
                indexed: FUZZY.scopeEngines[s] != nil, count: FUZZY.scopeEngines[s]?.count ?? 0, roots: roots
            )
        }
        let text = scopes.map { s in
            "\(s.name): \(s.enabled ? "enabled" : "disabled")\(s.needsPro ? " (Pro)" : "")\(s.enabled && !s.searched ? ", not searched without Pro" : ""), \(s.indexed ? "\(s.count.formatted()) entries" : "not indexed")  \(s.roots.joined(separator: ", "))"
        }.joined(separator: "\n")
        return ClingResponse(status: text, payload: payloadJSON(["scopes": scopes]))
    }

    @MainActor static func scopes(_ req: ClingRequest) -> ClingResponse {
        let action = req.action ?? "list"
        guard action != "list" else {
            return scopeResponse()
        }
        let names = req.scopes ?? []
        var chosen: [SearchScope] = []
        for name in names {
            guard let scope = SearchScope(rawValue: name.lowercased()) else {
                return ClingResponse(error: "no scope named '\(name)'. Scopes are \(SearchScope.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            chosen.append(scope)
        }
        guard !chosen.isEmpty else {
            return ClingResponse(error: "\(action) needs one or more scopes")
        }
        if chosen.contains(.cloud) {
            return ClingResponse(error: "the cloud scope is on while any cloud folder is. Turn those on and off with cling cloud enable|disable <name>")
        }
        switch action {
        case "enable":
            // System and Root are disabled toggles in Settings without Pro.
            if !proactive, let locked = chosen.first(where: { !FuzzyClient.freeScopes.contains($0) }) {
                return ClingResponse(error: "the \(locked.rawValue) scope needs Cling Pro")
            }
            for scope in chosen where !Defaults[.searchScopes].contains(scope) {
                Defaults[.searchScopes].append(scope)
            }
        case "disable":
            Defaults[.searchScopes].removeAll { chosen.contains($0) }
        default:
            return ClingResponse(error: "unknown scope action '\(action)'")
        }
        return scopeResponse()
    }
}

// MARK: - Ignore rules

extension CLIConfig {
    private struct IgnoreStore: Encodable {
        /// The name to pass as a target: home, blocklist-prefix, blocklist-contains, a rooted scope, or a volume path.
        let target: String
        let label: String
        let file: String?
        let matching: String
        let rules: [String]
        var text: String?
    }

    private static let rootedTargets = Dictionary(uniqueKeysWithValues: ScopeIgnore.rootedScopes.map { ($0.rawValue, $0) })

    @MainActor private static func stores() -> [IgnoreStore] {
        var stores: [IgnoreStore] = [
            IgnoreStore(
                target: "home", label: "Home Ignore File", file: fsignore.string,
                matching: "gitignore patterns, relative to your home folder, for the Home and Library scopes",
                rules: IndexSnapshot.nonCommentLines((try? String(contentsOf: fsignore.url, encoding: .utf8)) ?? "")
            ),
            IgnoreStore(
                target: "blocklist-prefix", label: "Global Blocklist · Prefix matching", file: nil,
                matching: "absolute path prefixes, checked on every scope and volume before any ignore file",
                rules: IndexSnapshot.nonCommentLines(Defaults[.blockedPrefixes])
            ),
            IgnoreStore(
                target: "blocklist-contains", label: "Global Blocklist · Contains matching", file: nil,
                matching: "text anywhere in a path; a rule starting with ! is an exception",
                rules: IndexSnapshot.nonCommentLines(Defaults[.blockedContains])
            ),
        ]
        for scope in ScopeIgnore.rootedScopes {
            stores.append(IgnoreStore(
                target: scope.rawValue, label: "\(scope.label) Ignore File", file: ScopeIgnore.file(for: scope).string,
                matching: "gitignore patterns, relative to the scope root (\(ScopeIgnore.roots(for: scope).joined(separator: ", ")))",
                rules: IndexSnapshot.nonCommentLines(ScopeIgnore.content(for: scope))
            ))
        }
        for volume in FUZZY.externalVolumes {
            let file = volume / ".fsignore"
            stores.append(IgnoreStore(
                target: volume.string, label: "\(volume.name.string) Ignore File", file: file.string,
                matching: "gitignore patterns, relative to the volume root",
                rules: IndexSnapshot.nonCommentLines((try? String(contentsOf: file.url, encoding: .utf8)) ?? "")
            ))
        }
        return stores
    }

    @MainActor private static func mechanism(_ target: String) -> (ExcludeMechanism, prefix: Bool)? {
        switch target.lowercased() {
        case "home": return (.homeIgnore, false)
        case "blocklist-prefix": return (.blocklist, true)
        case "blocklist-contains": return (.blocklist, false)
        default:
            if let scope = rootedTargets[target.lowercased()] {
                return (.scopeIgnore(scope), false)
            }
            if let volume = findVolume(target), FUZZY.externalVolumes.contains(volume) {
                return (.volumeIgnore(volume), false)
            }
            return nil
        }
    }

    @MainActor private static func ignoreResponse(_ stores: [IgnoreStore], note: String? = nil) -> ClingResponse {
        let text = stores.map { s in
            var lines = ["\(s.label)  [target: \(s.target)]\(s.file.map { "  \($0)" } ?? "")", "  \(s.matching)"]
            lines += s.rules.isEmpty ? ["  (no rules)"] : s.rules.map { "  \($0)" }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
        var payload: [String: AnyEncodable] = ["stores": AnyEncodable(stores)]
        if let note {
            payload["note"] = AnyEncodable(note)
        }
        return ClingResponse(status: [text, note].compactMap { $0 }.joined(separator: "\n\n"), payload: payloadJSON(payload))
    }

    /// Reindexes what a rule in `mechanism` can reach, the way the Apply button under each list does.
    @MainActor private static func reindex(after mechanism: ExcludeMechanism) -> String {
        switch mechanism {
        case .homeIgnore:
            FUZZY.refresh(pauseSearch: false, scopes: [.home, .library])
            return "Reindexing Home and Library."
        case let .scopeIgnore(scope):
            FUZZY.refresh(pauseSearch: false, scopes: [scope])
            return "Reindexing \(scope.label)."
        case let .volumeIgnore(volume):
            FUZZY.indexVolume(volume)
            return "Reindexing \(volume.name.string)."
        case .blocklist:
            FUZZY.refresh(pauseSearch: false)
            return "Reindexing every scope."
        }
    }

    @MainActor static func ignore(_ req: ClingRequest) -> ClingResponse {
        let action = req.action ?? "show"
        let reindexAfter = req.rebuild != false
        switch action {
        case "show", "list":
            var all = stores()
            if let target = req.key {
                all = all.filter { $0.target.lowercased() == target.lowercased() }
                guard !all.isEmpty else {
                    return ClingResponse(error: "no ignore list named '\(target)'. Targets are home, blocklist-prefix, blocklist-contains, \(ScopeIgnore.rootedScopes.map(\.rawValue).joined(separator: ", ")), or a connected volume's path.")
                }
            }
            return ignoreResponse(all)

        case "add", "remove":
            guard let target = req.key, let found = mechanism(target) else {
                return ClingResponse(error: "\(action) needs a target: home, blocklist-prefix, blocklist-contains, \(ScopeIgnore.rootedScopes.map(\.rawValue).joined(separator: ", ")), or a connected volume's path")
            }
            let (mech, prefix) = found
            let lines = (req.paths ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !lines.isEmpty else {
                return ClingResponse(error: "\(action) needs one or more rule lines")
            }
            let rules = lines.map { ExcludeRule(mechanism: mech, line: $0, blocklistPrefix: prefix) }
            if action == "add" {
                FUZZY.writeExcludeRules(rules)
            } else {
                let present = Set(stores().first { $0.target.lowercased() == target.lowercased() }?.rules ?? [])
                let absent = lines.filter { !present.contains($0) }
                guard absent.count < lines.count else {
                    return ClingResponse(error: "none of those lines are in \(target): \(absent.joined(separator: ", "))")
                }
                FUZZY.removeExcludeRules(rules)
            }
            let note = reindexAfter ? reindex(after: mech) : "Not reindexed: the change applies from the next reindex of what this list covers."
            return ignoreResponse(stores().filter { $0.target.lowercased() == target.lowercased() }, note: note)

        case "exclude":
            let paths = (req.paths ?? []).map { ($0 as NSString).expandingTildeInPath }
            guard !paths.isEmpty else {
                return ClingResponse(error: "exclude needs one or more paths")
            }
            // The rule the Exclude sheet recommends: exactly this path, nothing else, so nothing needs a reindex.
            let infos = paths.map { ExcludePathInfo(path: FilePath($0), home: HOME.string, volumes: FUZZY.enabledVolumes) }
            let rules = infos.map { ExcludeAnalyzer.exactRule($0) }
            FUZZY.excludeFromIndex(rules: rules, paths: Set(infos.map(\.path)), reindex: false)
            let note = rules.map { "\($0.storeLabel): \($0.line)" }.joined(separator: "\n")
            return ClingResponse(status: "Excluded and dropped from the index:\n\(note)", payload: payloadJSON(["rules": rules.map { ["store": $0.storeLabel, "line": $0.line] }]))

        case "include":
            guard let path = req.paths?.first.map({ ($0 as NSString).expandingTildeInPath }) else {
                return ClingResponse(error: "include needs a path")
            }
            let diagnosis = IndexInclusionAnalyzer.diagnose(rawPath: path, snapshot: IndexSnapshot.capture())
            switch diagnosis.status {
            case .notFound:
                return ClingResponse(error: "\(path) does not exist")
            case .notInAnyScope:
                return ClingResponse(error: "\(path) is not under any scope or connected volume, so no rule can bring it in. Enable the scope it belongs to, or index its volume.")
            case .alreadyIndexable:
                // Nothing keeps it out, so only the path itself is walked again, in case the last walk missed it.
                FUZZY.indexPathFirst(diagnosis.path, isDir: diagnosis.isDir) {}
                return ClingResponse(status: "No rule excludes \(path). Indexing it again now.")
            case .excluded:
                let choice = Int(req.value ?? "0") ?? 0
                guard diagnosis.options.indices.contains(choice) else {
                    return ClingResponse(error: "option \(choice) does not exist; explain the path to see its options")
                }
                let option = diagnosis.options[choice]
                FUZZY.includeInIndex(diagnosis.plan(for: option))
                return ClingResponse(
                    status: "\(option.title): \(option.summary)\n\(changes(option).joined(separator: "\n"))",
                    payload: payloadJSON(["applied": optionInfo(option, index: choice)])
                )
            }

        default:
            return ClingResponse(error: "unknown ignore action '\(action)'")
        }
    }

    // MARK: Diagnose

    private struct OptionInfo: Encodable {
        let index: Int
        let title: String
        let summary: String
        let breadth: String
        let changes: [String]
    }

    private struct Diagnosis: Encodable {
        let path: String
        let report: String
        let status: String
        let excludedBy: [[String: String]]
        let options: [OptionInfo]
    }

    private static func changes(_ option: InclusionOption) -> [String] {
        let dest = switch option.ignoreDest {
        case .home: "~/.fsignore"
        case let .volume(v): v.string + "/.fsignore"
        case let .scope(s): "the \(s.rawValue) ignore file"
        }
        return option.addBlocklistPrefixes.map { "add to the prefix blocklist: \($0)" }
            + option.addBlocklistContains.map { "add to the contains blocklist: \($0)" }
            + option.removeBlocklist.map { "remove from the \($0.source == .blocklistPrefix ? "prefix" : "contains") blocklist: \($0.rule)" }
            + option.fsignoreLines.map { "add to \(dest): \($0)" }
    }

    private static func optionInfo(_ option: InclusionOption, index: Int) -> OptionInfo {
        let breadth = switch option.breadth {
        case .exact: "exact"
        case .pattern: "pattern"
        case .folder: "folder"
        case .broad: "broad"
        }
        return OptionInfo(index: index, title: option.title, summary: option.summary, breadth: breadth, changes: changes(option))
    }

    /// `explain`, plus the rule lines that exclude each path and the ways the Missing Path sheet offers to
    /// bring it back. The options are what `ignore include` applies.
    nonisolated static func diagnose(_ req: ClingRequest, coordinator coord: SearchCoordinator) -> ClingResponse {
        let paths = req.paths ?? []
        guard !paths.isEmpty else {
            return ClingResponse(error: "no paths specified")
        }
        guard let snapshot = waitOnMain(timeout: 5, { IndexSnapshot.capture() }) else {
            return ClingResponse(error: "Cling is busy and did not answer in time. Try again in a moment.")
        }
        let results = paths.map { path -> Diagnosis in
            let d = IndexInclusionAnalyzer.diagnose(rawPath: path, snapshot: snapshot)
            let status = switch d.status {
            case .notFound: "notFound"
            case .excluded: "excluded"
            case .notInAnyScope: "notInAnyScope"
            case .alreadyIndexable: "notExcluded"
            }
            return Diagnosis(
                path: path,
                report: explainPathExclusion(path, coord: coord),
                status: status,
                excludedBy: d.hits.map { ["source": $0.source.label, "rule": $0.rule] },
                options: d.options.enumerated().map { optionInfo($1, index: $0) }
            )
        }
        let text = results.map { d in
            var lines = [d.report]
            if !d.options.isEmpty {
                lines.append("  ways to include it (cling ignore include --option N):")
                lines += d.options.map { "    \($0.index). \($0.title): \($0.changes.joined(separator: "; "))" }
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
        return ClingResponse(status: text, indexCount: coord.count, payload: payloadJSON(["paths": results]))
    }
}

// MARK: - Shortcuts

extension CLIConfig {
    private struct ShortcutInfo: Encodable {
        let name: String
        let id: String
        let title: String
        let group: String
        let shortcut: String?
        let defaultShortcut: String?
    }

    private struct ShortcutList: Encodable {
        let shortcuts: [ShortcutInfo]
        /// The other keys Cling listens for, which this command does not set, so a conflict can be spotted.
        let elsewhere: [String]
    }

    private static var shortcutEntries: [(name: KeyboardShortcuts.Name, id: String, title: String, group: String)] {
        let actions = ToolbarAction.all.compactMap { action -> (KeyboardShortcuts.Name, String, String, String)? in
            guard let name = ClingShortcuts.nameByAction[action.id] else { return nil }
            return (name, action.id.rawValue, action.title, action.segment.title)
        }
        let sorts = ClingShortcuts.sortShortcuts.map { ($0.name, "sortBy\($0.field.rawValue.capitalized)", $0.title, "Sorting") }
        let utilities = ClingShortcuts.utilityShortcuts.map { ($0.name, $0.name.rawValue.replacingOccurrences(of: "cl_", with: ""), $0.title, "Stash") }
        return actions + sorts + utilities
    }

    @MainActor private static func shortcutResponse(note: String? = nil) -> ClingResponse {
        let shortcuts = shortcutEntries.map { e in
            ShortcutInfo(
                name: e.name.rawValue, id: e.id, title: e.title, group: e.group,
                shortcut: KeyboardShortcuts.getShortcut(for: e.name)?.description,
                defaultShortcut: e.name.initialShortcut?.description
            )
        }
        var elsewhere: [String] = []
        let global = Defaults[.triggerKeys].map { "\($0)" }.joined(separator: "+")
        elsewhere.append("Global hotkey: \(Defaults[.enableGlobalHotkey] ? "\(global)+\(Defaults[.showAppKey].rawValue)" : "off") (settings: enableGlobalHotkey, triggerKeys, showAppKey)")
        elsewhere += SM.scriptShortcuts.sorted { $0.value < $1.value }.map { "⌘⌃\(String($0.value).uppercased()): script '\($0.key.deletingPathExtension().lastPathComponent)'" }
        elsewhere += Defaults[.quickFilters].compactMap { f in f.key.map { "⌥\(String($0).uppercased()): quick filter '\(f.id)'" } }
        elsewhere += Defaults[.folderFilters].compactMap { f in f.key.map { "⌥\(String($0).uppercased()): folder filter '\(f.id)'" } }
        let list = ShortcutList(shortcuts: shortcuts, elsewhere: elsewhere)

        var lines = shortcuts.map { "\($0.title) [\($0.id)]: \($0.shortcut ?? "none")\($0.shortcut == $0.defaultShortcut ? "" : "  (default \($0.defaultShortcut ?? "none"))")" }
        lines.append("")
        lines += elsewhere
        if let note {
            lines.append("")
            lines.append(note)
        }
        return ClingResponse(status: lines.joined(separator: "\n"), payload: payloadJSON(list))
    }

    private static func shortcutName(_ raw: String) -> KeyboardShortcuts.Name? {
        let wanted = raw.lowercased()
        return shortcutEntries.first {
            $0.name.rawValue.lowercased() == wanted || $0.id.lowercased() == wanted || $0.title.lowercased() == wanted
        }?.name
    }

    @MainActor static func shortcuts(_ req: ClingRequest) -> ClingResponse {
        switch req.action ?? "list" {
        case "list":
            return shortcutResponse()
        case "reset":
            if let raw = req.key {
                guard let name = shortcutName(raw) else {
                    return ClingResponse(error: "no shortcut named '\(raw)'")
                }
                KeyboardShortcuts.reset(name)
            } else {
                KeyboardShortcuts.reset(ClingShortcuts.allNames)
            }
            return shortcutResponse()
        case "set":
            guard let raw = req.key, let name = shortcutName(raw) else {
                return ClingResponse(error: "no shortcut named '\(req.key ?? "")'. List them to see the names.")
            }
            let value = (req.value ?? "").trimmingCharacters(in: .whitespaces)
            switch value.lowercased() {
            case "", "none", "off":
                KeyboardShortcuts.setShortcut(nil, for: name)
                return shortcutResponse()
            case "default":
                KeyboardShortcuts.reset(name)
                return shortcutResponse()
            default:
                break
            }
            guard let shortcut = parseShortcut(value) else {
                return ClingResponse(error: "could not read '\(value)' as a shortcut. Write it like cmd+shift+e, ctrl+0 or opt+return, with at least one of cmd, ctrl or opt.")
            }
            // Ours are dispatched by the window, not registered globally, so the package's own conflict check
            // never sees them. The Shortcuts pane clears a duplicate; this refuses it before it lands.
            if let other = ClingShortcuts.conflictingTitle(with: shortcut, excluding: name) {
                return ClingResponse(error: "\(shortcut.description) is already \(other). Free it first or pick another.")
            }
            KeyboardShortcuts.setShortcut(shortcut, for: name)
            return shortcutResponse()
        default:
            return ClingResponse(error: "unknown shortcut action '\(req.action ?? "")'")
        }
    }

    private static let keyCodes: [String: Int] = {
        var codes: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
            "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
            "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
            ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
            "/": kVK_ANSI_Slash, "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave,
            "return": kVK_Return, "enter": kVK_Return, "⏎": kVK_Return, "↩": kVK_Return,
            "tab": kVK_Tab, "space": kVK_Space, "delete": kVK_Delete, "backspace": kVK_Delete, "⌫": kVK_Delete,
            "forwarddelete": kVK_ForwardDelete, "escape": kVK_Escape, "esc": kVK_Escape,
            "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
            "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
        ]
        let functionKeys = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ]
        for (i, code) in functionKeys.enumerated() {
            codes["f\(i + 1)"] = code
        }
        return codes
    }()

    /// `cmd+shift+e`, `⌘⇧E`, `ctrl 0`. A bare key is refused: these are window shortcuts, and a bare letter
    /// would eat typing in the search field.
    static func parseShortcut(_ text: String) -> KeyboardShortcuts.Shortcut? {
        var rest = text.lowercased()
        var mods: NSEvent.ModifierFlags = []
        let glyphs: [(Character, NSEvent.ModifierFlags)] = [("⌘", .command), ("⇧", .shift), ("⌥", .option), ("⌃", .control)]
        while let first = rest.first, let glyph = glyphs.first(where: { $0.0 == first }) {
            mods.insert(glyph.1)
            rest.removeFirst()
        }
        var parts = rest.split(whereSeparator: { $0 == "+" || $0 == " " || $0 == "-" && rest.count > 1 }).map(String.init)
        // A lone "-" is the minus key, which the split above would swallow.
        if rest.hasSuffix("+-") || rest == "-" {
            parts.append("-")
        }
        guard let keyName = parts.popLast() else { return nil }
        for part in parts {
            switch part {
            case "cmd", "command", "⌘": mods.insert(.command)
            case "shift", "⇧": mods.insert(.shift)
            case "opt", "option", "alt", "⌥": mods.insert(.option)
            case "ctrl", "control", "⌃": mods.insert(.control)
            default: return nil
            }
        }
        guard !mods.intersection([.command, .control, .option]).isEmpty, let code = keyCodes[keyName] else { return nil }
        return KeyboardShortcuts.Shortcut(carbonKeyCode: code, carbonModifiers: carbonModifiers(from: mods))
    }
}

// MARK: - Why

extension CLIConfig {
    private struct TokenInfo: Encodable {
        let token: String
        let meaning: String
    }

    private struct ResultInfo: Encodable {
        let rank: Int
        let path: String
        let engine: String
        let score: Int
        let quality: Int
        let rankScore: Int
        let basenameMatch: Bool
        let segmentMatches: Int
        let prefixMatch: Bool
        let importance: Int
    }

    private struct EngineMatch: Encodable {
        let engine: String
        let matched: Bool
        let position: Int?
        let results: Int
        let best: ResultInfo?
    }

    private struct WhyReport: Encodable {
        let query: String
        let effectiveQuery: String
        let tokens: [TokenInfo]
        let settings: [String: String]
        let qualityGate: Int
        let target: String?
        let targetRank: Int?
        let targetMatches: [EngineMatch]?
        let targetIndex: String?
        let results: [ResultInfo]
        let notes: [String]
    }

    /// What each token of a query asks for. Mirrors the classification in `SearchEngine.searchCore` and has
    /// to follow it when that changes; the tokenizer and the escape decoding are the engine's own.
    private nonisolated static func explainTokens(_ query: String, literalDefault: Bool) -> [TokenInfo] {
        tokenizeQuery(query.trimmingCharacters(in: .whitespaces).lowercased()).map { raw in
            var t = raw
            var negate = false
            if t.hasPrefix("!") {
                if t.count == 1 {
                    return TokenInfo(token: raw, meaning: "the character ! as fuzzy text")
                }
                negate = true
                t.removeFirst()
            }
            if negate, t == "/" {
                return TokenInfo(token: raw, meaning: "files only: folders are left out")
            }
            if !negate, t.hasPrefix("in:"), t.count > 3 {
                return TokenInfo(token: raw, meaning: "only results inside \(decodeQueryEscapes(String(t.dropFirst(3))))")
            }
            if !negate, t.hasPrefix("depth:"), t.count > 6 {
                return TokenInfo(token: raw, meaning: Int(t.dropFirst(6)).map { "at most \($0) folders below the search folder" } ?? "an unreadable depth, ignored")
            }
            var anchorEnd = false
            if t.hasSuffix("$"), t.count > 1, !lastIsEscaped(t) {
                anchorEnd = true
                t.removeLast()
            }
            var anchorStart = false
            var quoted = false
            if t.hasPrefix("'"), t.count > 1 {
                quoted = true
                t.removeFirst()
            } else if t.hasPrefix("^"), t.count > 1 {
                anchorStart = true
                t.removeFirst()
            } else if t.hasPrefix("/") {
                let rest = String(t.dropFirst())
                if !rest.isEmpty, !rest.contains("/") {
                    anchorStart = true
                    t = rest
                } else {
                    while t.hasPrefix("/") {
                        t.removeFirst()
                    }
                }
            }
            guard !t.isEmpty else {
                return TokenInfo(token: raw, meaning: "nothing, ignored")
            }
            let text = decodeQueryEscapes(t)
            let not = negate ? "must NOT " : "must "
            if anchorStart || anchorEnd {
                let parts = [anchorStart ? "have a path component starting with \(text)" : nil, anchorEnd ? "have a name ending in \(text) (extension optional)" : nil]
                return TokenInfo(token: raw, meaning: not + parts.compactMap { $0 }.joined(separator: " and "))
            }
            if !quoted, t.hasPrefix("."), t.count > 1 {
                return TokenInfo(token: raw, meaning: negate ? "leaves out the \(text) extension" : "extension \(text) (several extensions match any of them)")
            }
            if !quoted, t.hasPrefix("*."), t.count > 2 {
                return TokenInfo(token: raw, meaning: negate ? "leaves out the .\(text.dropFirst(2)) extension" : "extension .\(text.dropFirst(2))")
            }
            if !quoted, t.hasSuffix("/"), t.count > 1 {
                return TokenInfo(token: raw, meaning: negate ? "must NOT contain \(text) anywhere in the path" : "a folder named like \(text.dropLast()) somewhere in the path; alone it shows only folders")
            }
            if negate {
                return TokenInfo(token: raw, meaning: "must NOT contain \(text) anywhere in the path")
            }
            if literalDefault != quoted {
                return TokenInfo(token: raw, meaning: "must contain \(text) as typed (literal)\(literalDefault ? ", and ranks by it" : "")")
            }
            return TokenInfo(token: raw, meaning: "fuzzy: the letters \(text) in order, anywhere in the path, joined with the other fuzzy words")
        }
    }

    /// Searches the way the window would for `query`, with the same filters, and says where `path` lands in
    /// each engine and in the merged list, and what ranked above it.
    nonisolated static func why(_ req: ClingRequest, coordinator coord: SearchCoordinator) -> ClingResponse {
        let typed = req.query ?? ""
        let resolved: SearchCoordinator.Resolved
        switch coord.resolve(req) {
        case let .success(r): resolved = r
        case let .failure(error): return ClingResponse(error: error.message)
        }
        let query = SearchCoordinator.folding(suffix: req.suffixPattern, into: resolved.query)
        let literal = Defaults[.literalSearch]
        let maxResults = Defaults[.maxResultsCount]
        let shown = req.maxResults ?? 15
        let target = req.paths?.first.map { (($0 as NSString).expandingTildeInPath as NSString).standardizingPath }

        var engines: [SearchCoordinator.EngineEntry]
        var drives: String?
        if req.allDrives == true {
            switch FuzzyClient.cliDrives() {
            case let .success(found): (engines, drives) = (found.engines, found.names)
            case let .failure(error): return ClingResponse(error: error.message)
            }
            // Scopes named as well are ranked alongside the drives, the way `cling search` takes them.
            if let scopes = req.scopes, !scopes.isEmpty {
                engines += coord.engines(scopeLabels: scopes).filter { e in !engines.contains { $0.engine === e.engine } }
            }
        } else {
            engines = coord.engines(scopeLabels: req.scopes)
        }
        // Deep enough that a target well below the window's cut-off still shows its real position.
        let depth = max(maxResults, 2000)
        var perEngine: [(entry: SearchCoordinator.EngineEntry, results: [SearchResult])] = []
        CLICalls.searchLock.withLock {
            for entry in engines {
                let results = entry.engine.search(
                    query: query, maxResults: depth, folderPrefixes: resolved.folderPrefixes,
                    dirsOnly: resolved.dirsOnly, literalDefault: literal
                )
                perEngine.append((entry, results))
            }
        }

        let best = perEngine.compactMap(\.results.first?.quality).max() ?? 0
        let gate = best / 3
        var merged: [(SearchResult, String)] = perEngine.flatMap { e in
            e.results.filter { $0.quality >= gate || $0.hasBase }.map { ($0, e.entry.label) }
        }
        merged.sort { $0.0 > $1.0 }
        var seen = Set<String>()
        merged = merged.filter { seen.insert($0.0.path).inserted }

        func info(_ r: SearchResult, _ engine: String, _ rank: Int) -> ResultInfo {
            ResultInfo(
                rank: rank, path: r.path, engine: engine, score: r.score, quality: r.quality, rankScore: r.rank,
                basenameMatch: r.hasBase, segmentMatches: r.segmentMatches, prefixMatch: r.prefixMatch, importance: r.pathImportance
            )
        }

        var notes: [String] = []
        var targetMatches: [EngineMatch]?
        var targetRank: Int?
        var targetIndex: String?
        if let target {
            targetMatches = perEngine.map { e in
                let position = e.results.firstIndex { $0.path == target }
                return EngineMatch(
                    engine: e.entry.label, matched: position != nil, position: position.map { $0 + 1 }, results: e.results.count,
                    best: position.map { info(e.results[$0], e.entry.label, $0 + 1) }
                )
            }
            targetRank = merged.firstIndex { $0.0.path == target }.map { $0 + 1 }
            if let rank = targetRank {
                if rank > maxResults {
                    notes.append("It ranks \(rank), below the window's limit of \(maxResults) results (maxResultsCount).")
                } else if !proactive, rank > 500 {
                    notes.append("It ranks \(rank); without Cling Pro the window shows at most 500 results.")
                }
            } else if let match = targetMatches?.first(where: \.matched), let r = match.best {
                notes
                    .append(
                        "The \(match.engine) engine matched it with quality \(r.quality), under the merge's quality gate of \(gate) (a third of the best match, \(best)), and it does not match on its name, so the merge drops it. A more specific query, or one that hits its name, lifts it over the gate."
                    )
            } else {
                targetIndex = explainPathExclusion(target, coord: coord)
                notes.append("No engine matched it for this query. Check the index report: if it is indexed, the query does not match its path.")
            }
        }
        let typedCount = typed.trimmingCharacters(in: .whitespaces).count
        let minLength = Defaults[.minQueryLength]
        if typedCount < minLength, req.quickFilter == nil, req.folderFilter == nil {
            notes.append("The query is shorter than minQueryLength (\(minLength)), so the window shows the default results instead of searching.")
        }
        if query != typed {
            notes.append("The window wraps the query with the filters' own tokens, which is the effective query above.")
        }
        if let drives {
            notes.append("Searched the saved index of every external drive, as the window's External drives filter does, Everything on or not: \(drives).")
            notes.append("The window also hides results that were deleted or excluded since the last walk.")
        } else {
            notes.append("The window also hides results that were deleted or excluded since the last walk, and while Everything is on it searches only the Everything index.")
        }

        let report = WhyReport(
            query: typed,
            effectiveQuery: query,
            tokens: explainTokens(query, literalDefault: literal),
            settings: [
                "literalSearch": literal ? "true" : "false",
                "minQueryLength": String(minLength),
                "maxResultsCount": String(maxResults),
                "pro": proactive ? "true" : "false",
                "engines": engines.map(\.label).joined(separator: ", "),
            ],
            qualityGate: gate,
            target: target,
            targetRank: targetRank,
            targetMatches: targetMatches,
            targetIndex: targetIndex,
            results: merged.prefix(shown).enumerated().map { info($1.0, $1.1, $0 + 1) },
            notes: notes
        )
        return ClingResponse(status: whyText(report), payload: payloadJSON(report))
    }

    private static func whyText(_ r: WhyReport) -> String {
        var lines = ["query: \(r.query)"]
        if r.effectiveQuery != r.query {
            lines.append("effective query: \(r.effectiveQuery)")
        }
        lines += r.tokens.map { "  \($0.token)  →  \($0.meaning)" }
        lines.append("engines: \(r.settings["engines"] ?? "")   quality gate: \(r.qualityGate)")
        if let target = r.target {
            lines.append("")
            lines.append("\(target): \(r.targetRank.map { "rank \($0)" } ?? "not in the merged results")")
            for m in r.targetMatches ?? [] {
                lines.append("  \(m.engine): \(m.best.map { "position \($0.rank) of \(m.results), score \($0.score), quality \($0.quality), rank score \($0.rankScore)" } ?? "no match")")
            }
            if let index = r.targetIndex {
                lines.append(index)
            }
        }
        lines.append("")
        lines += r.results.map { "\($0.rank). \($0.path)  [\($0.engine)] rank score \($0.rankScore), score \($0.score), quality \($0.quality)\($0.basenameMatch ? ", name match" : "")" }
        if !r.notes.isEmpty {
            lines.append("")
            lines += r.notes
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - ClingError

struct ClingError: Error {
    init(_ message: String) {
        self.message = message
    }

    let message: String
}

// MARK: - AnyEncodable

/// Lets a payload mix value types without a struct for every shape.
struct AnyEncodable: Encodable {
    init(_ value: some Encodable) {
        encodeValue = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }

    private let encodeValue: (Encoder) throws -> Void
}
