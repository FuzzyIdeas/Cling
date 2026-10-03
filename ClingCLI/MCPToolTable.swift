//
//  MCPToolTable.swift
//  ClingCLI
//
//  The tools `cling mcp serve` offers, their schemas and their handlers. Descriptions are what the agent
//  reads before it picks one, so they carry the caveats: which surface a value belongs to, what a tool is
//  for, what it does not do, and what needs Cling Pro.
//
//  Every tool runs a `cling` command. A new command or option lands here in the same change.
//

import Foundation

// MARK: - Server instructions

extension MCPServer {
    /// Sent once at `initialize`, for the agent's context.
    static let instructions = """
    Cling is a file search app. It keeps its own index of file paths, so a file shows up only if it is in \
    that index and the query matches its path.

    - The index is split into scopes: home (~ without ~/Library), library (~/Library), applications, system \
    and root (/usr, /bin, /etc, /Library, /var, /private and the like). System and root need Cling Pro. \
    External volumes are indexed separately and need Pro. Everything is a separate Pro index of every file on \
    the local disks, with no ignore rules, searched alone when it is on.
    - What the index leaves out is decided by, in order: the global blocklist (prefix and contains rules, \
    checked first and on every scope), then gitignore-style ignore files: ~/.fsignore for home and library, one \
    per rooted scope, and a .fsignore at the root of each volume.
    - "Why is X not showing up?" has two halves. cling_explain_path says whether X is indexed and which rule \
    keeps it out. cling_explain_search says how the query is read and where X ranks for it. Reproduce with the \
    user's own query and the quick or folder filter they had on.
    - "How do I hide or show this part of the window?" is cling_ui_settings.
    - The search window and the floating search bar are two interfaces; hotkeyTarget picks which one the \
    global hotkey brings up, and some settings exist once for each.
    - Quick filters narrow by kind (extensions, files or folders, words); folder filters narrow by location. \
    Both are picked with ⌥ and a letter in the search window.

    Reading works whenever Cling is running. Every change is refused until the user allows agent changes, and \
    writing a script's code also needs scripts allowed; cling_status says which, and cling_start_server asks the \
    user on screen. Cling's own refusals come back verbatim.
    """
}

// MARK: - Elicitation copy

extension MCPServer {
    /// Bringing a path back can mean one exact rule or deleting a blocklist rule that lets in thousands of
    /// files, so when there is more than one way the user picks it.
    static func includeSchema(_ options: [[String: Any]]) -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "option": [
                    "type": "string",
                    "title": "Index it by",
                    "oneOf": options.map { o in
                        ["const": "\(o["index"] as? Int ?? 0)", "title": o["title"] as? String ?? ""]
                    },
                    "default": "0",
                ],
            ],
            "required": ["option"],
        ]
    }

    static func includeOptionsText(_ path: String, _ options: [[String: Any]]) -> String {
        let lines = options.map { o -> String in
            let changes = (o["changes"] as? [String] ?? []).joined(separator: "; ")
            return "  \(o["index"] as? Int ?? 0). \(o["title"] as? String ?? ""): \(o["summary"] as? String ?? "") (\(changes))"
        }
        return """
        \(path) can be brought back into the index in more than one way, and they reach very different \
        numbers of files:
        \(lines.joined(separator: "\n"))
        Ask the user which they want, then call cling_ignore again with action include and that option.
        """
    }

    static let cancelledPrefix = """
    The question was not answered. Some clients cannot show one at all, a non-interactive session for \
    instance, so ask the user directly instead.

    """

    static let declinedPrefix = "The user declined to answer, so ask them directly instead.\n"
}

// MARK: - Handlers

extension MCPServer {
    static func search(_ a: [String: Any]) throws -> ToolOutput {
        let folders = list(a, "folders")
        let scopes = list(a, "scopes")
        return try run(
            ["search"]
                + opt(a, "--count", "count")
                + opt(a, "--suffix", "suffix")
                + (folders.isEmpty ? [] : ["--folders=\(folders.joined(separator: ","))"])
                + flag(a, "dirsOnly", "--dirs-only")
                + flag(a, "everything", "--everything")
                + opt(a, "--quick-filter", "quickFilter")
                + opt(a, "--folder-filter", "folderFilter")
                + (scopes.isEmpty ? [] : ["--scope"] + scopes),
            tail: [argument(a["query"] ?? "")],
            // Loading the Everything index can take a while the first time.
            timeout: a["everything"] as? Bool == true ? 160 : 30
        )
    }

    static func why(_ a: [String: Any]) throws -> ToolOutput {
        let folders = list(a, "folders")
        let scopes = list(a, "scopes")
        return try run(
            ["why"]
                + opt(a, "--path", "path")
                + opt(a, "--count", "count")
                + opt(a, "--suffix", "suffix")
                + (folders.isEmpty ? [] : ["--folders=\(folders.joined(separator: ","))"])
                + flag(a, "dirsOnly", "--dirs-only")
                + opt(a, "--quick-filter", "quickFilter")
                + opt(a, "--folder-filter", "folderFilter")
                + (scopes.isEmpty ? [] : ["--scope"] + scopes),
            tail: [argument(a["query"] ?? "")],
            timeout: 60
        )
    }

    static func reindex(_ a: [String: Any]) throws -> ToolOutput {
        let scopes = list(a, "scopes")
        let wait = a["wait"] as? Bool == true
        return try text(
            ["reindex"]
                + (scopes.isEmpty ? [] : ["--scope"] + scopes)
                + flag(a, "rebuild", "--rebuild")
                + flag(a, "cancel", "--cancel")
                + flag(a, "everything", "--everything")
                + (wait ? ["--wait"] : []),
            timeout: wait ? reindexTimeout : 30
        )
    }

    static func indexPaths(_ a: [String: Any]) throws -> ToolOutput {
        let action = argument(a["action"] ?? "")
        guard ["add", "remove", "has"].contains(action) else {
            throw ClingMCPError("action must be add, remove or has")
        }
        // `index` takes its paths with `.remaining`, so they go in raw, after the action.
        return try text(["index", action], tail: paths(a), terminator: false)
    }

    static func ignore(_ a: [String: Any]) throws -> ToolOutput {
        let action = argument(a["action"] ?? "show")
        switch action {
        case "show":
            let target = a["target"].map { argument($0) } ?? ""
            return try run(["ignore", "show"], tail: target.isEmpty ? [] : [target])
        case "add", "remove":
            let target = argument(a["target"] ?? "")
            let lines = list(a, "lines")
            guard !target.isEmpty, !lines.isEmpty else {
                throw ClingMCPError("\(action) needs a target and one or more lines")
            }
            let noReindex = a["reindex"] as? Bool == false
            return try run(["ignore", action] + (noReindex ? ["--no-reindex"] : []), tail: [target] + lines, timeout: 60)
        case "exclude":
            return try run(["ignore", "exclude"], tail: paths(a), timeout: 60)
        case "include":
            let path = try paths(a)[0]
            var option = a["option"].flatMap { Int(argument($0)) }
            if option == nil {
                switch try chooseInclusion(path) {
                case let .chosen(index): option = index
                case let .askInChat(output): return output
                }
            }
            return try run(["ignore", "include", "--option=\(option ?? 0)"], tail: [path], timeout: 60)
        default:
            throw ClingMCPError("action must be show, add, remove, exclude or include")
        }
    }

    enum Inclusion {
        case chosen(Int)
        case askInChat(ToolOutput)
    }

    /// Picks how to bring `path` back when the call did not say. One way is no choice; more than one asks
    /// the user, since "the exact path" and "delete the rule" reach very different numbers of files.
    static func chooseInclusion(_ path: String) throws -> Inclusion {
        guard case let .json(payload) = try run(["explain"], tail: [path], terminator: false),
              let entry = ((payload as? [String: Any])?["paths"] as? [[String: Any]])?.first
        else { return .chosen(0) }
        let options = entry["options"] as? [[String: Any]] ?? []
        guard options.count > 1 else { return .chosen(0) }

        try refuseBeforeAsking()
        let name = (path as NSString).lastPathComponent
        switch try ask("include_option", "How should Cling bring “\(name)” back into the index?", includeSchema(options)) {
        case let .answered(content):
            return .chosen(asInt(content, "option", 0) ?? 0)
        case .declined:
            return .askInChat(.text(declinedPrefix + includeOptionsText(path, options)))
        case .unanswered:
            return .askInChat(.text(cancelledPrefix + includeOptionsText(path, options)))
        case .unsupported:
            return .askInChat(.text(includeOptionsText(path, options)))
        }
    }

    static func filterWrite(_ a: [String: Any]) throws -> ToolOutput {
        let kind = argument(a["kind"] ?? "")
        guard ["quick", "folder"].contains(kind) else {
            throw ClingMCPError("kind must be quick or folder")
        }
        var folders: [String] = []
        if a["folders"] != nil {
            folders = ["--folders=\(list(a, "folders").map { ($0 as NSString).expandingTildeInPath }.joined(separator: ","))"]
        }
        return try run(
            ["filter", "write", "--kind=\(kind)"]
                + opt(a, "--rename", "rename")
                + folders
                + opt(a, "--extensions", "extensions")
                + opt(a, "--exclude", "exclude")
                + opt(a, "--match", "match")
                + opt(a, "--prepend", "prepend")
                + opt(a, "--append", "append")
                + opt(a, "--raw-query", "rawQuery")
                + opt(a, "--max-depth", "maxDepth")
                + opt(a, "--key", "key")
                + opt(a, "--icon", "icon")
                + opt(a, "--hue", "hue"),
            tail: [argument(a["name"] ?? "")]
        )
    }

    static func scriptWrite(_ a: [String: Any]) throws -> ToolOutput {
        try run(
            ["script", "write"]
                + opt(a, "--runner", "runner")
                + opt(a, "--code", "code")
                + opt(a, "--description", "description")
                + opt(a, "--key", "key")
                + opt(a, "--extensions", "extensions")
                + opt(a, "--min-files", "minFiles")
                + opt(a, "--max-files", "maxFiles")
                + opt(a, "--files-only", "filesOnly")
                + opt(a, "--dirs-only", "dirsOnly")
                + opt(a, "--confirm", "confirm")
                + opt(a, "--sequential", "sequential")
                + opt(a, "--show-output", "showOutput")
                + flag(a, "replace", "--replace"),
            tail: [argument(a["name"] ?? "")]
        )
    }

    static func volumes(_ a: [String: Any]) throws -> ToolOutput {
        let action = argument(a["action"] ?? "list")
        guard ["list", "enable", "disable", "interval", "remove"].contains(action) else {
            throw ClingMCPError("action must be list, enable, disable, interval or remove")
        }
        let volume = a["volume"].map { argument($0) } ?? ""
        let seconds = a["seconds"].map { argument($0) } ?? ""
        return try run(["volume", action], tail: [volume, seconds].filter { !$0.isEmpty })
    }

    static func scopes(_ a: [String: Any]) throws -> ToolOutput {
        let action = argument(a["action"] ?? "list")
        guard ["list", "enable", "disable"].contains(action) else {
            throw ClingMCPError("action must be list, enable or disable")
        }
        return try run(["scope", action], tail: list(a, "scopes"))
    }

    static func shortcuts(_ a: [String: Any]) throws -> ToolOutput {
        switch argument(a["action"] ?? "list") {
        case "list":
            return try run(["shortcut", "list"])
        case "set":
            let name = argument(a["name"] ?? "")
            let shortcut = argument(a["shortcut"] ?? "")
            guard !name.isEmpty, !shortcut.isEmpty else {
                throw ClingMCPError("set needs a name and a shortcut")
            }
            return try run(["shortcut", "set"], tail: [name, shortcut])
        case "reset":
            let name = a["name"].map { argument($0) } ?? ""
            return try run(["shortcut", "reset"], tail: name.isEmpty ? [] : [name])
        default:
            throw ClingMCPError("action must be list, set or reset")
        }
    }
}

// MARK: - Debug logs

extension MCPServer {
    /// `cling logs persist` gets root from sudo, which needs a terminal, and this process has none: its stdin
    /// and stdout are the JSON-RPC stream. An administrator dialog is the way left, and osascript gets its own
    /// pipes so nothing it prints can land in that stream.
    ///
    /// Never routed through the app or its MCP switch. macOS asks for the password itself, and that dialog
    /// is a stronger gate than either.
    static func debugLogs(_ a: [String: Any]) throws -> ToolOutput {
        guard let action = (a["action"] as? String).flatMap(Logs.Persist.Action.init(rawValue:)) else {
            throw ClingMCPError("action must be on, off or status")
        }
        let command = Logs.Persist.subsystems
            .map { (["/usr/bin/log"] + action.logConfigArguments(subsystem: $0)).map(shellQuoted).joined(separator: " ") }
            // && so a failure on any subsystem is the one reported, rather than only the last one's.
            .joined(separator: " && ")
        let prompt = action == .on ? "Cling wants to keep its debug logs on disk." : "Cling wants to change how its debug logs are kept."

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(appleScriptEscaped(command))\" with prompt \"\(appleScriptEscaped(prompt))\" with administrator privileges"]
        let out = Pipe()
        let err = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            throw ClingMCPError("Could not change the log settings: \(error.localizedDescription)")
        }
        let output = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let complaint = (String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            // -128 is AppleScript's userCanceledErr, which is what the dialog's Cancel button raises.
            if complaint.contains("-128") {
                throw ClingMCPError("The user cancelled the administrator password dialog. Nothing changed.")
            }
            throw ClingMCPError("Could not change the log settings: "
                + (complaint.isEmpty ? "osascript exited with status \(process.terminationStatus)" : complaint))
        }
        if let message = action.doneMessage {
            return .text(message)
        }
        // `do shell script` hands back the command's output with carriage returns for line breaks.
        return .text(output.replacingOccurrences(of: "\r", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The words are fixed today, but this string runs as root, so a subsystem or mode that ever carries a
    /// space or a quote has to stay one argument instead of becoming more shell.
    static func shellQuoted(_ word: String) -> String {
        guard word.unicodeScalars.contains(where: { !shellSafe.contains($0) }) else { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static let shellSafe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:,=@%+"))

    /// For the inside of an AppleScript string literal, where only backslash and double quote are special.
    static func appleScriptEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - The table

extension MCPServer {
    static let gate = "Refused until the user allows agent changes in Cling Settings, MCP (cling_start_server asks "
        + "them). Cling's own words come back verbatim when it refuses."

    static let scopeNames = "home, library, applications, system, root"
    static let ignoreTargets = "home (~/.fsignore, for the home and library scopes), blocklist-prefix, blocklist-contains, "
        + "applications, system, root (each rooted scope's own ignore file), or a connected volume's path"

    static let tools: [MCPTool] = [
        // --- the switch
        MCPTool(
            name: "cling_start_server",
            description: "Ask the user to allow changes through MCP, launching Cling if it is not running. "
                + "Cling puts an alert on screen and this waits for the answer, so call it once, in response to "
                + "something the user asked for, and tell them to expect it. Every tool that changes something "
                + "is refused until they allow it; reading works either way, and the choice sticks across "
                + "launches until it is stopped. It does not allow scripts: that switch is only in Settings.",
            inputSchema: ["type": "object", "properties": [String: Any]()],
            handler: { _ in try startServer() }
        ),
        MCPTool(
            name: "cling_stop_server",
            description: "Stop allowing changes through MCP. Reading stays available.",
            inputSchema: ["type": "object", "properties": [String: Any]()],
            handler: { _ in try stopServer() }
        ),
        MCPTool(
            name: "cling_status",
            description: "Whether agent changes and scripts are allowed, whether Cling is running, whether the user "
                + "has Cling Pro, and where the app lives. Read this first when a tool has been refused. For the "
                + "index itself, see cling_index_status.",
            inputSchema: ["type": "object", "properties": [String: Any]()],
            handler: { _ in try status() }
        ),

        // --- searching and the index
        MCPTool(
            name: "cling_search",
            description: "Search Cling's index the way the search window does, with each result's score and "
                + "quality. To reproduce a complaint, pass the user's exact query and the quickFilter or "
                + "folderFilter they had on (cling_filter_list names them); the window wraps the query in the "
                + "filter's own tokens and this does the same. It does not apply the window's live tidying "
                + "(results deleted or excluded since the last walk are hidden there), minQueryLength, or the "
                + "500 result cap without Pro. Use cling_explain_search to see why a file ranks where it does. "
                + "everything searches the Everything index alone (Pro), loading it first and building it on first use.",
            inputSchema: ["type": "object", "properties": [
                "query": ["type": "string", "description": "the query as typed, operators included (.pdf, in:~/Documents, !foo, 'exact, ^start, end$)"],
                "count": ["type": "integer", "description": "how many results, default 30"],
                "quickFilter": ["type": "string", "description": "a saved quick filter's name"],
                "folderFilter": ["type": "string", "description": "a saved folder filter's name"],
                "folders": ["type": "array", "items": ["type": "string"], "description": "only inside these folders"],
                "suffix": ["type": "string", "description": "extensions, e.g. '.png .jpg'"],
                "dirsOnly": ["type": "boolean", "description": "only folders"],
                "scopes": ["type": "array", "items": ["type": "string"], "description": "only these scopes: \(scopeNames)"],
                "everything": ["type": "boolean", "description": "search the Everything index instead (Pro)"],
            ], "required": ["query"]],
            handler: search
        ),
        MCPTool(
            name: "cling_index_status",
            description: "The index: every scope (enabled, indexed, entry count, whether it is being indexed now), "
                + "every external volume, the Everything index, and what Cling is doing. A scope that is enabled "
                + "but not indexed has not been walked yet, and its files cannot show up.",
            inputSchema: ["type": "object", "properties": [String: Any]()],
            handler: { _ in try run(["status"]) }
        ),
        MCPTool(
            name: "cling_reindex",
            description: "Walk scopes or volumes again. With no scopes it walks everything, which takes minutes on "
                + "a large home folder; name the scope or volume that changed instead. rebuild throws away the "
                + "saved index first, for a corrupted one, and is slower. cancel stops indexing. everything walks "
                + "the Everything index again (Pro), which normally follows file changes on its own. wait returns "
                + "when it is done, or after 10 minutes saying it is still going. Changing an ignore list through "
                + "cling_ignore already reindexes what it covers. " + gate,
            inputSchema: ["type": "object", "properties": [
                "scopes": ["type": "array", "items": ["type": "string"], "description": "\(scopeNames), or a volume path like /Volumes/Backup"],
                "rebuild": ["type": "boolean"],
                "cancel": ["type": "boolean"],
                "everything": ["type": "boolean"],
                "wait": ["type": "boolean"],
            ]],
            handler: reindex
        ),
        MCPTool(
            name: "cling_index_paths",
            description: "Add paths to the live index, remove them from it, or check whether they are in it, right "
                + "now and without a walk. The scope is picked from the path. It does NOT change any rule, so a "
                + "removed path comes back on the next reindex and an added one that a rule excludes goes again: "
                + "to keep a path out or let it in for good, use cling_ignore exclude or include. has is the quick "
                + "check; cling_explain_path says why. add and remove: " + gate,
            inputSchema: ["type": "object", "properties": [
                "action": ["type": "string", "enum": ["add", "remove", "has"]],
                "paths": ["type": "array", "items": ["type": "string"]],
            ], "required": ["action", "paths"]],
            handler: indexPaths
        ),

        // --- troubleshooting
        MCPTool(
            name: "cling_explain_path",
            description: "Why a path is or is not in the index: whether it exists, which engine holds it, the scope "
                + "it belongs to and whether that scope is on, then the exact blocklist or ignore-file rule lines "
                + "that exclude it, with a verdict. When it is excluded, also the ways to bring it back, numbered; "
                + "cling_ignore include applies one. Start here for 'X never shows up'. It does not look at any "
                + "query: when the path is indexed and still missing, use cling_explain_search.",
            inputSchema: ["type": "object", "properties": [
                "paths": ["type": "array", "items": ["type": "string"]],
            ], "required": ["paths"]],
            handler: { a in try run(["explain"], tail: paths(a), terminator: false) }
        ),
        MCPTool(
            name: "cling_explain_search",
            description: "How Cling reads a query and where a file ranks for it. Lists what every token means "
                + "(fuzzy text, literal text, extension, folder, in:, depth:, exclusions), the effective query "
                + "after the quick or folder filter wraps it, and the top results with their rank score, score and "
                + "quality. With path, also where that file lands in each engine and in the merged list, and why "
                + "it was dropped when it was: no match, under the merge's quality gate, or past the result limit; "
                + "when no engine matches it, the index report from cling_explain_path. This is the tool for "
                + "reproducing 'searching for X does not find Y' or 'Y ranks below junk'. It reads the "
                + "literalSearch, minQueryLength and maxResultsCount settings but changes nothing.",
            inputSchema: ["type": "object", "properties": [
                "query": ["type": "string", "description": "the query exactly as the user typed it"],
                "path": ["type": "string", "description": "the file the user expected to see"],
                "quickFilter": ["type": "string", "description": "the quick filter the user had on"],
                "folderFilter": ["type": "string", "description": "the folder filter the user had on"],
                "folders": ["type": "array", "items": ["type": "string"]],
                "suffix": ["type": "string"],
                "dirsOnly": ["type": "boolean"],
                "scopes": ["type": "array", "items": ["type": "string"], "description": scopeNames],
                "count": ["type": "integer", "description": "how many top results to list, default 15"],
            ], "required": ["query"]],
            handler: why
        ),
        MCPTool(
            name: "cling_ui_settings",
            description: "Every setting that shows or hides part of Cling's interface, with its current value and the "
                + "label it has in Settings: the Action Bar, Open With and Scripts rows and the double-tap that "
                + "hides all three, which actions sit in the bar or the ⋯ menu or nowhere, the preview panels, the "
                + "status bar, search hints, the Dock and menu bar icons, the search bar versus the window. "
                + "Answer 'where did X go' or 'how do I hide X' from here, then change it with cling_settings_set.",
            inputSchema: ["type": "object", "properties": [String: Any]()],
            handler: { _ in try run(["settings", "ui"]) }
        ),
        MCPTool(
            name: "cling_debug_logs",
            description: "Turns keeping Cling's debug and info log messages on disk on or off, or reports it, so "
                + "`log show --debug` can read what happened before anyone started streaming. Use it when "
                + "reproducing a problem needs logs from earlier. macOS requires root for this: the call shows an "
                + "administrator password dialog on the user's screen and waits, and nothing changes if they "
                + "cancel. Debug builds already keep debug logs.",
            inputSchema: ["type": "object", "properties": [
                "action": ["type": "string", "enum": Logs.Persist.Action.allCases.map(\.rawValue), "description": "on, off or status"],
            ], "required": ["action"]],
            handler: debugLogs
        ),

        // --- settings
        MCPTool(
            name: "cling_settings_schema",
            description: "Cling's settings: each one's key, current value, type, allowed values, and the pane, "
                + "section, title and subtitle it has in Settings, plus a note for what the row cannot say. Pass "
                + "a plain-language query to narrow it, like 'buttons under the results' or 'open folders in "
                + "iTerm'. Call this before cling_settings_set: the value a set takes is the form shown here. "
                + "Scopes, volumes, ignore rules, filters, scripts and shortcuts have their own tools and are not here.",
            inputSchema: ["type": "object", "properties": [
                "query": ["type": "string", "description": "plain-language filter"],
            ]],
            handler: { a in
                let query = (a["query"] as? String) ?? ""
                return try run(["settings", "schema"], tail: query.isEmpty ? [] : [query])
            }
        ),
        MCPTool(
            name: "cling_settings_get",
            description: "Read one setting by its key. Keys come from cling_settings_schema.",
            inputSchema: ["type": "object", "properties": ["key": ["type": "string"]], "required": ["key"]],
            handler: { a in try run(["settings", "get"], tail: [argument(a["key"] ?? "")]) }
        ),
        MCPTool(
            name: "cling_settings_set",
            description: "Change one setting. The value is the form cling_settings_schema shows: true or false, a "
                + "number, one of the allowed names, or a comma separated list. The default apps (editorApp, "
                + "terminalApp, shelfApp) take an app's path, its name or its bundle identifier, and shelfApp "
                + "also takes stash for Cling's own Stash. The global hotkey is enableGlobalHotkey, triggerKeys "
                + "and showAppKey. Applies immediately and comes back with the new value. Some values need Cling "
                + "Pro and are refused without it. " + gate,
            inputSchema: ["type": "object", "properties": [
                "key": ["type": "string"], "value": ["type": "string"],
            ], "required": ["key", "value"]],
            handler: { a in try run(["settings", "set"], tail: [argument(a["key"] ?? ""), argument(a["value"] ?? "")]) }
        ),

        // --- what gets indexed
        MCPTool(
            name: "cling_scopes",
            description: "List the search scopes, or enable or disable them. Disabling one unloads its index and "
                + "deletes the saved copy, so its files stop showing up at once; enabling one walks it again. "
                + "system and root need Cling Pro: enabling them without it is refused, and an enabled one is not "
                + "searched while the licence is missing. list: open; enable and disable: " + gate,
            inputSchema: ["type": "object", "properties": [
                "action": ["type": "string", "enum": ["list", "enable", "disable"]],
                "scopes": ["type": "array", "items": ["type": "string"], "description": scopeNames],
            ]],
            handler: scopes
        ),
        MCPTool(
            name: "cling_volumes",
            description: "External and network volumes (Cling Pro). list shows each one with whether it is mounted, "
                + "enabled and indexed, its entry count and how often it is reindexed. enable and disable turn its "
                + "indexing on or off, as its toggle in Settings does; enabling one with no index walks it. "
                + "interval sets how often it is walked again, in seconds from 3600 (1 hour) to 2419200 (4 "
                + "weeks). remove deletes a disconnected volume's saved index; a connected one can only be "
                + "disabled. To walk one now, use cling_reindex with its path. Whether new volumes are indexed on "
                + "their own is the disableAutomaticVolumeIndexing setting. list: open; the rest need Pro and: " + gate,
            inputSchema: ["type": "object", "properties": [
                "action": ["type": "string", "enum": ["list", "enable", "disable", "interval", "remove"]],
                "volume": ["type": "string", "description": "its name or its path under /Volumes"],
                "seconds": ["type": "integer", "description": "for interval"],
            ]],
            handler: volumes
        ),
        MCPTool(
            name: "cling_ignore",
            description: "What the index leaves out. show lists the rule lines in every ignore list, or in target. "
                + "add and remove change lines in one list, then reindex what it covers unless reindex is false: "
                + "ignore files take gitignore patterns relative to their root, blocklist-prefix takes absolute "
                + "path prefixes, and blocklist-contains takes text matched anywhere in a path, where a line "
                + "starting with ! is an exception. exclude keeps exactly the given paths out with the narrowest "
                + "rule and drops them from the index now, no reindex. include brings an excluded path back with "
                + "one of the ways cling_explain_path lists, by option; without option and with more than one "
                + "way, the user is asked which, since removing a blocklist rule can let in thousands of files. "
                + "Settings > Excluded Paths shows the same lists. show: open; the rest: " + gate,
            inputSchema: ["type": "object", "properties": [
                "action": ["type": "string", "enum": ["show", "add", "remove", "exclude", "include"]],
                "target": ["type": "string", "description": ignoreTargets],
                "lines": ["type": "array", "items": ["type": "string"], "description": "rule lines for add and remove"],
                "paths": ["type": "array", "items": ["type": "string"], "description": "for exclude, or one path for include"],
                "option": ["type": "integer", "description": "for include: which way, from cling_explain_path"],
                "reindex": ["type": "boolean", "description": "add and remove reindex by default"],
            ], "required": ["action"]],
            handler: ignore
        ),

        // --- filters
        MCPTool(
            name: "cling_filter_list",
            description: "Saved quick filters (narrow by kind: extensions, files or folders, words, and optionally "
                + "folders) and folder filters (narrow by location), with their ⌥ keys and which one is active. A "
                + "quick filter's runsAs is what it adds around the typed query.",
            inputSchema: ["type": "object", "properties": [
                "kind": ["type": "string", "enum": ["quick", "folder"], "description": "omit for both"],
            ]],
            handler: { a in try run(["filter", "list"] + opt(a, "--kind", "kind")) }
        ),
        MCPTool(
            name: "cling_filter_write",
            description: "Create a quick or folder filter, or change the one with that name (rename to rename it). "
                + "Fields left out keep their current values; an empty string clears a text field and maxDepth -1 "
                + "clears the depth. A quick filter needs at least one of extensions, exclude, match, folders, "
                + "prepend, append or rawQuery; rawQuery replaces the structured fields with a whole query in "
                + "Cling's query syntax. A folder filter takes only folders, maxDepth, key, icon and hue, and the "
                + "folders must exist. key is the letter pressed with ⌥ in the search window, which needs Cling "
                + "Pro; a key taken by another filter of the same kind moves here. Picking a filter from the "
                + "menus works without Pro. " + gate,
            inputSchema: ["type": "object", "properties": [
                "kind": ["type": "string", "enum": ["quick", "folder"]],
                "name": ["type": "string"],
                "rename": ["type": "string", "description": "the filter's current name, to rename it"],
                "folders": ["type": "array", "items": ["type": "string"]],
                "extensions": ["type": "string", "description": "quick: e.g. '.png .jpg .heic'"],
                "exclude": ["type": "string", "description": "quick: words or extensions to leave out, space separated"],
                "match": ["type": "string", "enum": ["both", "files", "folders"], "description": "quick"],
                "prepend": ["type": "string", "description": "quick: text put before the typed query"],
                "append": ["type": "string", "description": "quick: text put after the typed query"],
                "rawQuery": ["type": "string", "description": "quick: a whole query instead of the fields above"],
                "maxDepth": ["type": "integer", "description": "how deep below each folder, -1 for no limit"],
                "key": ["type": "string", "description": "one letter or digit, or none"],
                "icon": ["type": "string", "description": "an SF Symbol name"],
                "hue": ["type": "number", "description": "0 to 1 around the colour wheel"],
            ], "required": ["kind", "name"]],
            handler: filterWrite
        ),
        MCPTool(
            name: "cling_filter_delete",
            description: "Delete a saved quick or folder filter by name. Built-in filters deleted here are gone "
                + "until recreated. " + gate,
            inputSchema: ["type": "object", "properties": [
                "kind": ["type": "string", "enum": ["quick", "folder"]],
                "name": ["type": "string"],
            ], "required": ["kind", "name"]],
            handler: { a in try run(["filter", "delete", "--kind=\(argument(a["kind"] ?? ""))"], tail: [argument(a["name"] ?? "")]) }
        ),

        // --- scripts
        MCPTool(
            name: "cling_script_list",
            description: "The scripts Cling runs on selected files, from the Scripts row or with ⌘⌃ and a key in "
                + "the search window: each one's runner, key, description, and when it shows up (extensions, "
                + "file counts, files or folders only). Running them needs Cling Pro; listing and writing them do not.",
            inputSchema: ["type": "object", "properties": [String: Any]()],
            handler: { _ in try run(["script", "list"]) }
        ),
        MCPTool(
            name: "cling_script_show",
            description: "One script with its full code.",
            inputSchema: ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]],
            handler: { a in try run(["script", "show"], tail: [argument(a["name"] ?? "")]) }
        ),
        MCPTool(
            name: "cling_script_write",
            description: "Create a script, or change one. The selected files' paths arrive as arguments ($1, $2 and "
                + "\"$@\" in a shell, sys.argv in Python, process.argv from index 2 in node, argv in osascript's "
                + "on run). Cling writes the shebang for the runner and the header comments for the options; code "
                + "is everything after them. Cling also sets CLING_SEVEN_ZIP, CLING_DUST, CLING_TREE and "
                + "CLING_TREEDIFF to bundled tools, and runs the script with the user's login shell environment. "
                + "A simple script is one line of zsh; a complex one restricts itself with extensions, minFiles, "
                + "maxFiles, filesOnly or dirsOnly, and confirm asks before a destructive run. Without key, Cling "
                + "picks one. Options left out keep their current values. An existing script's code is only "
                + "replaced with replace. It does NOT run the script. A script is arbitrary code that runs on the "
                + "user's files, so it is refused until the user allows scripts in Cling Settings, MCP, separately "
                + "from agent changes. Prefer a filter or a setting when one can do the job. " + gate,
            inputSchema: ["type": "object", "properties": [
                "name": ["type": "string", "description": "the file name without its extension; also its title in the picker"],
                "runner": ["type": "string", "enum": ["zsh", "sh", "fish", "python3", "ruby", "perl", "swift", "osascript", "node"], "description": "default zsh for a new script"],
                "code": ["type": "string", "description": "the body, without the shebang"],
                "description": ["type": "string", "description": "shown in the picker"],
                "key": ["type": "string", "description": "one letter or digit for ⌘⌃, or none"],
                "extensions": ["type": "string", "description": "only for these, space separated, no dots, or none"],
                "minFiles": ["type": "integer", "description": "0 for no minimum"],
                "maxFiles": ["type": "integer", "description": "0 for no maximum"],
                "filesOnly": ["type": "boolean", "description": "hide when folders are selected"],
                "dirsOnly": ["type": "boolean", "description": "hide when files are selected"],
                "confirm": ["type": "boolean", "description": "ask before running"],
                "sequential": ["type": "boolean", "description": "run once per file instead of once with all of them"],
                "showOutput": ["type": "boolean", "description": "show the output when it finishes"],
                "replace": ["type": "boolean", "description": "overwrite an existing script's code"],
            ], "required": ["name"]],
            handler: scriptWrite
        ),
        MCPTool(
            name: "cling_script_key",
            description: "Set the key that runs a script with ⌘⌃ in the search window, or none to let Cling pick "
                + "one. Changes only that line, so it does not need scripts allowed. Says so when another script "
                + "has the same key. " + gate,
            inputSchema: ["type": "object", "properties": [
                "name": ["type": "string"],
                "key": ["type": "string", "description": "one letter or digit, or none"],
            ], "required": ["name", "key"]],
            handler: { a in try run(["script", "key"], tail: [argument(a["name"] ?? ""), argument(a["key"] ?? "")]) }
        ),
        MCPTool(
            name: "cling_script_delete",
            description: "Delete a script file. It is not moved to the Trash. " + gate,
            inputSchema: ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]],
            handler: { a in try run(["script", "delete"], tail: [argument(a["name"] ?? "")]) }
        ),

        // --- shortcuts
        MCPTool(
            name: "cling_shortcuts",
            description: "The search window's keyboard shortcuts: one per action (open, show in Finder, copy paths, "
                + "trash and so on), the sort orders and the stash. list shows each one's current and default "
                + "shortcut, plus the other keys Cling listens for (the global hotkey, ⌘⌃ script keys, ⌥ filter "
                + "keys), so a clash is visible. set takes a shortcut like cmd+shift+e, ctrl+0 or opt+return, "
                + "with at least one of cmd, ctrl or opt, or none to clear it, or default; one already used by "
                + "another action is refused. These work only inside the window; the global hotkey that "
                + "summons Cling is a setting (enableGlobalHotkey, triggerKeys, showAppKey). list: open; set "
                + "and reset: " + gate,
            inputSchema: ["type": "object", "properties": [
                "action": ["type": "string", "enum": ["list", "set", "reset"]],
                "name": ["type": "string", "description": "the action id from list, e.g. showInFinder or sortByName"],
                "shortcut": ["type": "string"],
            ]],
            handler: shortcuts
        ),
    ]

    static let toolsByName: [String: MCPTool] = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
}
