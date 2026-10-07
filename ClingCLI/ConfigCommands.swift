import ArgumentParser
import Foundation

// MARK: - Caller

/// Who is calling. The app reads it to decide what an agent may change, and an absent origin is somebody
/// using their own CLI, which needs permission from nobody.
///
/// The environment is only the starting value: `cling mcp serve` pins this to "mcp" for the life of the
/// process, so the stamp cannot be dropped by a client that builds its own environment.
var CLI_ORIGIN: String? = ProcessInfo.processInfo.environment["CLING_ORIGIN"]

/// When a `--wait` has to give up. Set by the MCP server, which serves one client for hours and cannot let
/// one long reindex hold the session open. Nil for a person at a terminal, who can press ctrl-C.
var CLI_DEADLINE: Date?

// MARK: - CLIError

/// An error worded for whoever reads it: a person at a terminal or an agent through the MCP server.
struct CLIError: Error, CustomStringConvertible {
    init(_ description: String) {
        self.description = description
    }

    let description: String
}

extension ClingRequest {
    /// The request as it goes over the port, stamped with the caller.
    func encoded() throws -> Data {
        var request = self
        request.origin = CLI_ORIGIN
        return try JSONEncoder().encode(request)
    }
}

/// Sends one request to the running app and returns its answer, with every way that can fail turned into a
/// message.
func ask(_ request: ClingRequest, recvTimeout: TimeInterval = 15) throws -> ClingResponse {
    let data: Data?
    do {
        data = try sendMachPort(data: request.encoded(), recvTimeout: recvTimeout)
    } catch {
        throw CLIError(error.localizedDescription)
    }
    // The app answers nothing at all to a command it cannot decode, which is what an older build does with
    // every command added after it. The port hands that back as empty data.
    guard let data, !data.isEmpty else {
        throw CLIError("Cling did not answer. It may be older than this command line tool: update Cling and try again.")
    }
    guard let response = try? JSONDecoder().decode(ClingResponse.self, from: data) else {
        throw CLIError("Cling sent an answer this command line tool cannot read")
    }
    if let error = response.error {
        throw CLIError(error)
    }
    return response
}

/// Runs a configuration command and prints the app's answer: JSON with `--json`, words otherwise.
func runConfig(_ request: ClingRequest, json: Bool, recvTimeout: TimeInterval = 15) throws {
    let response = try ask(request, recvTimeout: recvTimeout)
    print(json ? (response.payload ?? "{}") : (response.status ?? "done"))
}

func encodedSpec(_ spec: some Encodable) throws -> String {
    try String(decoding: JSONEncoder().encode(spec), as: UTF8.self)
}

// MARK: - Why

struct Why: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Explain how a query is read and where a file ranks for it",
        discussion: """
        Searches each engine the way the search window does, with the same quick and folder filters, and \
        reports what every token of the query means, where --path lands in each engine and in the merged \
        results, and what ranks above it. When no engine matches the path, says whether it is indexed at all.
        """
    )

    @Argument(help: "The query, as typed in the search field")
    var query: String

    @Option(name: .shortAndLong, help: "The file that should show up")
    var path: String?

    @Option(name: .long, help: "Apply a saved quick filter by name")
    var quickFilter: String?

    @Option(name: .long, help: "Apply a saved folder filter by name")
    var folderFilter: String?

    @Option(name: .long, help: "Restrict to folder prefix(es), comma-separated")
    var folders: String?

    @Option(name: .long, help: "Filter by suffix (e.g. .pdf)")
    var suffix: String?

    @Flag(name: .long, help: "Only match directories")
    var dirsOnly = false

    @Option(name: .long, parsing: .upToNextOption, help: "Search only in specific scopes (home, library, applications, system, root)")
    var scope: [String] = []

    @Flag(name: .long, help: "Search only the external drives' saved indexes, connected or not, as the External drives filter does (Pro)")
    var allDrives = false

    @Option(name: .shortAndLong, help: "How many of the top results to show")
    var count = 15

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    func validate() throws {
        if allDrives, !scope.isEmpty {
            throw ValidationError("--all-drives cannot be combined with --scope")
        }
    }

    mutating func run() throws {
        let target = path.map { p -> String in
            let tilde = (p as NSString).expandingTildeInPath
            let cwd = FileManager.default.currentDirectoryPath
            return ((tilde.hasPrefix("/") ? tilde : (cwd as NSString).appendingPathComponent(tilde)) as NSString).standardizingPath
        }
        let request = ClingRequest(
            command: .why, query: query, maxResults: count, suffixPattern: suffix,
            folderPrefixes: folders?.components(separatedBy: ","), dirsOnly: dirsOnly ? true : nil,
            scopes: scope.isEmpty ? nil : scope, paths: target.map { [$0] },
            quickFilter: quickFilter, folderFilter: folderFilter, allDrives: allDrives ? true : nil
        )
        try runConfig(request, json: json, recvTimeout: 60)
    }
}

// MARK: - SettingsCommand

/// Read and change the settings the Settings window shows.
///
/// Everything goes through the running app rather than into the defaults suite: the app applies a change
/// live instead of on next launch, and the MCP gate can only be enforced somewhere the caller does not
/// control.
struct SettingsCommand: ParsableCommand {
    struct Schema: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Every setting, its value and what it accepts. Pass words to narrow it.")

        @Argument(help: "Plain language filter, e.g. 'buttons under the results'")
        var query: [String] = []

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        mutating func run() throws {
            let q = query.joined(separator: " ")
            try runConfig(ClingRequest(command: .settings, query: q.isEmpty ? nil : q, action: "schema"), json: json)
        }
    }

    struct UI: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "ui", abstract: "The settings that show or hide parts of the interface, with their values.")

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        mutating func run() throws {
            try runConfig(ClingRequest(command: .settings, action: "ui"), json: json)
        }
    }

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Read one setting by key.")

        @Argument(help: "The setting key")
        var key: String

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        mutating func run() throws {
            try runConfig(ClingRequest(command: .settings, action: "get", key: key), json: json)
        }
    }

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Change one setting. Applies immediately.")

        @Argument(help: "The setting key")
        var key: String

        @Argument(help: "The new value, in the form the schema shows")
        var value: String

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        mutating func run() throws {
            try runConfig(ClingRequest(command: .settings, action: "set", key: key, value: value), json: json)
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "settings",
        abstract: "Read and change Cling's settings.",
        subcommands: [Schema.self, UI.self, Get.self, Set.self],
        defaultSubcommand: Schema.self
    )
}

// MARK: - FilterCommand

struct FilterCommand: ParsableCommand {
    enum Kind: String, ExpressibleByArgument, CaseIterable {
        case quick
        case folder
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Saved quick and folder filters.")

        @Option(name: .long, help: "quick or folder. Omit for both")
        var kind: Kind?

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        mutating func run() throws {
            try runConfig(ClingRequest(command: .filters, action: "list", key: kind?.rawValue), json: json)
        }
    }

    struct Write: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a filter, or change the one with that name.",
            discussion: "Options left out keep their current value. An empty string clears a text option, -1 clears --max-depth and none clears --key."
        )

        @Argument(help: "The filter's name")
        var name: String

        @Option(name: .long, help: "quick or folder")
        var kind: Kind

        @Option(name: .long, help: "The current name, when renaming")
        var rename: String?

        @Option(name: .long, help: "Folders, comma-separated. A folder filter needs at least one")
        var folders: String?

        @Option(name: .long, help: "Quick filters: extensions, e.g. '.png .jpg'")
        var extensions: String?

        @Option(name: .long, help: "Quick filters: words or extensions to leave out")
        var exclude: String?

        @Option(name: .long, help: "Quick filters: both, files or folders")
        var match: String?

        @Option(name: .long, help: "Quick filters: text put before the typed query")
        var prepend: String?

        @Option(name: .long, help: "Quick filters: text put after the typed query")
        var append: String?

        @Option(name: .long, help: "Quick filters: a whole query that replaces the fields above")
        var rawQuery: String?

        @Option(name: .long, help: "How deep below each folder to look, -1 for no limit")
        var maxDepth: Int?

        @Option(name: .long, help: "A letter or digit pressed with ⌥ in the search window, or none")
        var key: String?

        @Option(name: .long, help: "An SF Symbol name")
        var icon: String?

        @Option(name: .long, help: "Colour, 0 to 1 around the colour wheel")
        var hue: Double?

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        mutating func run() throws {
            var spec = ClingFilterSpec(kind: kind.rawValue, name: name)
            spec.rename = rename
            spec.folders = folders.map { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
            spec.extensions = extensions
            spec.exclude = exclude
            spec.match = match
            spec.prepend = prepend
            spec.append = append
            spec.rawQuery = rawQuery
            spec.maxDepth = maxDepth
            spec.key = key
            spec.icon = icon
            spec.hue = hue
            try runConfig(ClingRequest(command: .filters, action: "write", payload: encodedSpec(spec)), json: json)
        }
    }

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a saved filter.")

        @Argument(help: "The filter's name")
        var name: String

        @Option(name: .long, help: "quick or folder")
        var kind: Kind

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        mutating func run() throws {
            try runConfig(ClingRequest(command: .filters, action: "delete", key: kind.rawValue, value: name), json: json)
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "filter",
        abstract: "Manage quick filters and folder filters.",
        subcommands: [List.self, Write.self, Delete.self],
        defaultSubcommand: List.self
    )
}

// MARK: - ScriptCommand

struct ScriptCommand: ParsableCommand {
    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Scripts, with their keys and when they show up.")

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        mutating func run() throws {
            try runConfig(ClingRequest(command: .scripts, action: "list"), json: json)
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "One script, with its code.")

        @Argument(help: "The script's name, without the extension")
        var name: String

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        mutating func run() throws {
            try runConfig(ClingRequest(command: .scripts, action: "show", value: name), json: json)
        }
    }

    struct Write: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a script, or change one.",
            discussion: """
            The selected files are passed as arguments. Cling writes the shebang and the header comments \
            for the options below; --code is everything after them. Options left out keep their current \
            value, and an existing script's code is only overwritten with --replace.
            """
        )

        @Argument(help: "The script's name, without the extension")
        var name: String

        @Option(name: .long, help: "sh, zsh, fish, python3, ruby, perl, swift, osascript or node")
        var runner: String?

        @Option(name: .long, help: "The code")
        var code: String?

        @Option(name: .long, help: "Read the code from this file")
        var codeFile: String?

        @Option(name: .long, help: "Shown in the script picker")
        var description: String?

        @Option(name: .long, help: "A letter or digit for ⌘⌃ in the search window, or none")
        var key: String?

        @Option(name: .long, help: "Only show for these extensions, space-separated without dots, or none")
        var extensions: String?

        @Option(name: .long, help: "Only show for at least this many selected files, 0 for no minimum")
        var minFiles: Int?

        @Option(name: .long, help: "Only show for at most this many selected files, 0 for no maximum")
        var maxFiles: Int?

        @Option(name: .long, help: "Hide when folders are selected")
        var filesOnly: Bool?

        @Option(name: .long, help: "Hide when files are selected")
        var dirsOnly: Bool?

        @Option(name: .long, help: "Ask before running")
        var confirm: Bool?

        @Option(name: .long, help: "Run once per file")
        var sequential: Bool?

        @Option(name: .long, help: "Show the output when it finishes")
        var showOutput: Bool?

        @Flag(name: .long, help: "Overwrite the code of an existing script")
        var replace = false

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        mutating func run() throws {
            var spec = ClingScriptSpec(name: name)
            spec.runner = runner
            if let codeFile {
                do {
                    spec.code = try String(contentsOfFile: (codeFile as NSString).expandingTildeInPath, encoding: .utf8)
                } catch {
                    throw CLIError("could not read \(codeFile): \(error.localizedDescription)")
                }
            } else {
                spec.code = code
            }
            spec.description = description
            spec.key = key
            spec.extensions = extensions
            spec.minFiles = minFiles
            spec.maxFiles = maxFiles
            spec.filesOnly = filesOnly
            spec.dirsOnly = dirsOnly
            spec.confirm = confirm
            spec.sequential = sequential
            spec.showOutput = showOutput
            spec.replace = replace ? true : nil
            try runConfig(ClingRequest(command: .scripts, action: "write", payload: encodedSpec(spec)), json: json)
        }
    }

    struct Key: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Set the ⌘⌃ key that runs a script from the search window.")

        @Argument(help: "The script's name, without the extension")
        var name: String

        @Argument(help: "A letter or digit, or none to let Cling pick one")
        var key: String

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        mutating func run() throws {
            var spec = ClingScriptSpec(name: name)
            spec.key = key
            try runConfig(ClingRequest(command: .scripts, action: "key", payload: encodedSpec(spec)), json: json)
        }
    }

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a script file.")

        @Argument(help: "The script's name, without the extension")
        var name: String

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        mutating func run() throws {
            try runConfig(ClingRequest(command: .scripts, action: "delete", value: name), json: json)
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "script",
        abstract: "Manage the scripts that run on selected files.",
        subcommands: [List.self, Show.self, Write.self, Key.self, Delete.self],
        defaultSubcommand: List.self
    )
}

// MARK: - VolumeCommand

struct VolumeCommand: ParsableCommand {
    enum Action: String, ExpressibleByArgument, CaseIterable {
        case list
        case enable
        case disable
        case interval
        case remove
    }

    static let configuration = CommandConfiguration(
        commandName: "volume",
        abstract: "List external volumes, turn their indexing on or off, and set how often they are reindexed (Pro).",
        discussion: """
        cling volume list
        cling volume enable|disable <volume>
        cling volume interval <volume> <seconds>     3600 (1 hour) to 2419200 (4 weeks)
        cling volume remove <volume>                 a disconnected volume's index
        Reindex a volume now with: cling reindex --scope /Volumes/<name>
        """
    )

    @Argument(help: "list, enable, disable, interval or remove")
    var action: Action = .list

    @Argument(help: "The volume's name or path")
    var volume: String?

    @Argument(help: "For interval: seconds between reindexes")
    var seconds: Int?

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    mutating func run() throws {
        if action != .list, volume == nil {
            throw CLIError("\(action.rawValue) needs a volume")
        }
        if action == .interval, seconds == nil {
            throw CLIError("interval needs a number of seconds")
        }
        try runConfig(ClingRequest(command: .volumes, action: action.rawValue, key: seconds.map(String.init), value: volume), json: json)
    }
}

// MARK: - CloudCommand

struct CloudCommand: ParsableCommand {
    enum Action: String, ExpressibleByArgument, CaseIterable {
        case list
        case enable
        case disable
        case refresh
    }

    static let configuration = CommandConfiguration(
        commandName: "cloud",
        abstract: "List cloud storage folders and turn their indexing on or off.",
        discussion: """
        cling cloud list
        cling cloud enable|disable <name or path>
        cling cloud refresh [<name or path>]      list online-only folders again now
        """
    )

    @Argument(help: "list, enable, disable or refresh")
    var action: Action = .list

    @Argument(help: "The cloud folder's name, account or path")
    var location: String?

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    mutating func run() throws {
        if action == .enable || action == .disable, location == nil {
            throw CLIError("\(action.rawValue) needs a name or path")
        }
        try runConfig(ClingRequest(command: .cloud, action: action.rawValue, value: location), json: json)
    }
}

// MARK: - ScopeCommand

struct ScopeCommand: ParsableCommand {
    enum Action: String, ExpressibleByArgument, CaseIterable {
        case list
        case enable
        case disable
    }

    static let configuration = CommandConfiguration(
        commandName: "scope",
        abstract: "List the search scopes, or turn them on and off. System and Root need Pro.",
        discussion: "Disabling a scope unloads its index and deletes the saved copy; enabling one indexes it again."
    )

    @Argument(help: "list, enable or disable")
    var action: Action = .list

    @Argument(help: "home, library, applications, system or root")
    var scopes: [String] = []

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    mutating func run() throws {
        try runConfig(ClingRequest(command: .scopes, scopes: scopes, action: action.rawValue), json: json)
    }
}

// MARK: - IgnoreCommand

struct IgnoreCommand: ParsableCommand {
    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "The rules in every ignore list, or in one.")

        @Argument(help: "home, blocklist-prefix, blocklist-contains, applications, system, root, or a volume path")
        var target: String?

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        mutating func run() throws {
            try runConfig(ClingRequest(command: .ignore, action: "show", key: target), json: json)
        }
    }

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add rule lines to an ignore list, then reindex what it covers.")

        @Argument(help: "home, blocklist-prefix, blocklist-contains, applications, system, root, or a volume path")
        var target: String

        @Argument(help: "Rule lines, one per argument")
        var lines: [String]

        @Flag(name: .long, help: "Leave the reindex for later")
        var noReindex = false

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        mutating func run() throws {
            try runConfig(ClingRequest(command: .ignore, rebuild: noReindex ? false : nil, paths: lines, action: "add", key: target), json: json)
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove rule lines from an ignore list, then reindex what it covers.")

        @Argument(help: "home, blocklist-prefix, blocklist-contains, applications, system, root, or a volume path")
        var target: String

        @Argument(help: "Rule lines, exactly as they appear in the list")
        var lines: [String]

        @Flag(name: .long, help: "Leave the reindex for later")
        var noReindex = false

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        mutating func run() throws {
            try runConfig(ClingRequest(command: .ignore, rebuild: noReindex ? false : nil, paths: lines, action: "remove", key: target), json: json)
        }
    }

    struct Exclude: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Keep exactly these paths out of the index, and drop them from it now.")

        @Argument(help: "Paths to exclude")
        var paths: [String]

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        mutating func run() throws {
            let resolved = paths.map { absolutePath($0) }
            try runConfig(ClingRequest(command: .ignore, paths: resolved, action: "exclude"), json: json)
        }
    }

    struct Include: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Bring an excluded path back into the index.",
            discussion: "`cling explain --json <path>` lists the ways to do it; --option picks one. 0, the narrowest, is the default."
        )

        @Argument(help: "The path to include")
        var path: String

        @Option(name: .long, help: "Which of the ways to include it, from `cling explain`")
        var option = 0

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        mutating func run() throws {
            try runConfig(ClingRequest(command: .ignore, paths: [absolutePath(path)], action: "include", value: String(option)), json: json)
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "ignore",
        abstract: "Read and change what the index leaves out: ignore files and the global blocklist.",
        subcommands: [Show.self, Add.self, Remove.self, Exclude.self, Include.self],
        defaultSubcommand: Show.self
    )
}

func absolutePath(_ p: String) -> String {
    let tilde = (p as NSString).expandingTildeInPath
    let cwd = FileManager.default.currentDirectoryPath
    return ((tilde.hasPrefix("/") ? tilde : (cwd as NSString).appendingPathComponent(tilde)) as NSString).standardizingPath
}

// MARK: - ShortcutCommand

struct ShortcutCommand: ParsableCommand {
    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Every search window shortcut, and the other keys Cling listens for.")

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        mutating func run() throws {
            try runConfig(ClingRequest(command: .shortcuts, action: "list"), json: json)
        }
    }

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Change one shortcut.")

        @Argument(help: "The action, e.g. showInFinder, sortByName or cl_copyPaths")
        var name: String

        @Argument(help: "e.g. cmd+shift+e, ctrl+0 or opt+return; none to clear it, default to restore it")
        var shortcut: String

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        mutating func run() throws {
            try runConfig(ClingRequest(command: .shortcuts, action: "set", key: name, value: shortcut), json: json)
        }
    }

    struct Reset: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Restore one shortcut, or all of them, to the default.")

        @Argument(help: "The action. Omit to reset every shortcut")
        var name: String?

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        mutating func run() throws {
            try runConfig(ClingRequest(command: .shortcuts, action: "reset", key: name), json: json)
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "shortcut",
        abstract: "Read and change the search window's keyboard shortcuts.",
        subcommands: [List.self, Set.self, Reset.self],
        defaultSubcommand: List.self
    )
}

// MARK: - MCPCommand

/// What the bundled MCP server asks before it does anything.
///
/// Reads the app's own defaults suite rather than talking to the app, so it answers whether or not Cling is
/// running. The server card fills in the paths.
struct MCPCommand: ParsableCommand {
    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Whether agents may change Cling, and where the server lives.")

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        mutating func run() throws {
            let defaults = UserDefaults(suiteName: "com.lowtechguys.Cling")
            // Live, from the suite the app writes. The card's copy can lag a crash.
            let enabled = defaults?.bool(forKey: "mcpEnabled") ?? false
            let scripts = defaults?.bool(forKey: "mcpAllowScripts") ?? false

            let cardPath = ("~/Library/Application Support/Cling/mcp.json" as NSString).expandingTildeInPath
            let card = (try? Data(contentsOf: URL(fileURLWithPath: cardPath)))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let running = CFMessagePortCreateRemote(nil, CLING_PORT_ID) != nil

            var status: [String: Any] = [
                "enabled": enabled,
                "allowScripts": scripts,
                "running": running,
                "pro": card["pro"] as? Bool ?? false,
                "requiresPro": false,
                "cardPath": cardPath,
            ]
            if let version = card["version"] as? String {
                status["version"] = version
            }
            if let app = card["app"] as? [String: Any], let path = app["path"] as? String {
                status["appPath"] = path
            }
            if let transport = card["transport"] as? [String: Any] {
                let command = transport["command"] as? String ?? ""
                let args = (transport["args"] as? [String]) ?? []
                status["serverCommand"] = ([command] + args).joined(separator: " ")
            }

            guard json else {
                print("Agent changes:   \(enabled ? "allowed" : "not allowed")")
                print("Scripts:         \(scripts ? "allowed" : "not allowed")")
                print("Cling running:   \(running ? "yes" : "no")")
                print("Cling Pro:       \(status["pro"] as? Bool == true ? "yes" : "no")")
                if let path = status["appPath"] as? String {
                    print("App:             \(path)")
                }
                if !enabled {
                    print("\nAsk the user to allow it in Cling Settings, MCP, or run: open cling://mcp/start")
                }
                return
            }
            let data = try JSONSerialization.data(withJSONObject: ["ok": true, "mcp": status], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            print(String(data: data, encoding: .utf8) ?? "{}")
        }
    }

    /// The MCP server itself. Hidden because it is for an agent's config file, not for a person: it speaks
    /// JSON-RPC on stdin and stdout and does nothing readable at a terminal.
    struct Serve: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "serve",
            abstract: "Speak MCP over stdin and stdout.",
            shouldDisplay: false
        )

        mutating func run() throws {
            MCPServer.serve()
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "The MCP server that lets agents drive Cling.",
        subcommands: [Status.self, Serve.self],
        defaultSubcommand: Status.self
    )
}
