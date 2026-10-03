import AppKit
import Defaults
import Foundation
import os

private let mcpLog = Logger(subsystem: clingSubsystem, category: "MCP")

// MARK: - MCPInstaller

/// Registers Cling's MCP server with the agents people actually use, by merging one entry into each
/// client's own config file. Everything else in those files is preserved: they are read, one key is
/// added, and they are written back.
///
/// Same shape as Clop's, rcmd's and Crank's `MCPInstaller`; keep them in step.
enum MCPInstaller {
    /// The config layouts in the wild. They differ only in which top-level key holds the servers and
    /// how the command is shaped.
    enum Style {
        case mcpServers // Claude Code, Claude Desktop, Cursor, Windsurf
        case vsCode // "servers", command + args
        case zed // "context_servers", nested command object
    }

    struct Client: Identifiable {
        let id: String
        let name: String
        let path: String
        let style: Style
        /// A file or app that shows the client is on this Mac.
        let evidence: [String]

        var url: URL {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }

        /// Where the bytes actually live. These are exactly the files people keep in a dotfiles repo and
        /// symlink into place, and an atomic write against a symlink replaces the link with a regular file.
        /// See `resolvedConfigURL`.
        var writeURL: URL {
            resolvedConfigURL(url)
        }

        var isPresent: Bool {
            FileManager.default.fileExists(atPath: url.path)
                || evidence.contains { FileManager.default.fileExists(atPath: ($0 as NSString).expandingTildeInPath) }
        }
    }

    // MARK: - State

    enum InstallError: LocalizedError {
        case missingServer

        var errorDescription: String? {
            switch self {
            case .missingServer: "Cling's CLI is missing from the app bundle, so the MCP server cannot run."
            }
        }
    }

    /// What the client's config file says.
    enum ConfigState {
        case installed
        case notInstalled
        /// The file is there and is not an object even with its comments taken out, so there is no
        /// members list to add Cling to.
        case unusable
    }

    static let serverName = "cling"

    static let clients: [Client] = [
        Client(
            id: "claude-code", name: "Claude Code",
            path: "~/.claude.json", style: .mcpServers,
            evidence: ["/opt/homebrew/bin/claude", "~/.claude"]
        ),
        Client(
            id: "claude-desktop", name: "Claude Desktop",
            path: "~/Library/Application Support/Claude/claude_desktop_config.json", style: .mcpServers,
            evidence: ["/Applications/Claude.app"]
        ),
        Client(
            id: "cursor", name: "Cursor",
            path: "~/.cursor/mcp.json", style: .mcpServers,
            evidence: ["/Applications/Cursor.app", "~/.cursor"]
        ),
        Client(
            id: "vscode", name: "VS Code",
            path: "~/Library/Application Support/Code/User/mcp.json", style: .vsCode,
            evidence: ["/Applications/Visual Studio Code.app", "~/Library/Application Support/Code"]
        ),
        Client(
            id: "windsurf", name: "Windsurf",
            path: "~/.codeium/windsurf/mcp_config.json", style: .mcpServers,
            evidence: ["/Applications/Windsurf.app", "~/.codeium"]
        ),
        Client(
            id: "zed", name: "Zed",
            path: "~/.config/zed/settings.json", style: .zed,
            evidence: ["/Applications/Zed.app", "~/.config/zed"]
        ),
    ]

    /// The arguments that turn the CLI into the server.
    static let serveArgs = ["mcp", "serve"]

    // MARK: - Paths

    /// The CLI, which IS the MCP server. Bundled beside the app, so an agent drives the same binary the
    /// user's own `cling` command does.
    static var cliPath: String {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/SharedSupport/ClingCLI").path
        if FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        return CLING_CLI_LINK.string
    }

    /// Whether the server can actually run. Installing without it writes a config entry that looks fine
    /// and starts nothing, so every caller checks this first.
    static var serverExists: Bool {
        FileManager.default.isExecutableFile(atPath: cliPath)
    }

    /// The one-liner for a client that is driven from a terminal.
    static var cliCommand: String {
        "claude mcp add --scope user cling -- \(cliPath) \(serveArgs.joined(separator: " "))"
    }

    static var cardURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".well-known/mcp/cling.json")
    }

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cling", isDirectory: true)
    }

    // MARK: - The switch

    /// Unlike Clop's, this is not a Pro wall: nothing else in Cling gates driving it from the CLI, and the
    /// features that need Pro still refuse on their own.
    @MainActor static func setEnabled(_ enabled: Bool) {
        Defaults[.mcpEnabled] = enabled
        writeServerCard()
        mcpLog.info("MCP \(enabled ? "enabled" : "disabled", privacy: .public)")
    }

    /// Handles `cling://mcp/start` and `cling://mcp/stop`. Returns false for a URL that is not ours, so the
    /// caller can keep handling it.
    ///
    /// Start ASKS. The URL is what an agent opens when a tool of its own was refused, so nothing but this
    /// alert stands between "an agent decided to" and the switch being on. Stop needs no alert: it only
    /// ever takes permission away.
    @MainActor static func handle(url: URL) -> Bool {
        guard url.scheme == "cling", url.host == "mcp" else { return false }
        switch url.lastPathComponent {
        case "start":
            guard !Defaults[.mcpEnabled] else { return true }
            if askToEnable() {
                setEnabled(true)
            }
        case "stop": setEnabled(false)
        default: return false
        }
        return true
    }

    // MARK: - Server card

    /// A card an agent can read to find Cling, written on every launch whether or not the switch is on.
    ///
    /// There is no shipped standard for discovering a local MCP server, so this follows the shape of the
    /// proposed `.well-known/mcp` card and drops it in two places an agent is likely to look. It carries no
    /// credentials: Cling's transport is a Mach port that any process of this user can already open.
    @MainActor static func writeServerCard() {
        let card: [String: Any] = [
            "name": serverName,
            "displayName": "Cling",
            "description": "File search. Search the index, explain why a file is missing or ranks where it does, manage scopes, volumes and ignore rules, and read or change settings, filters, shortcuts and scripts.",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            "app": ["bundleID": Bundle.main.bundleIdentifier ?? "com.lowtechguys.Cling", "path": Bundle.main.bundlePath],
            "enabled": Defaults[.mcpEnabled],
            "allowScripts": Defaults[.mcpAllowScripts],
            "requiresPro": false,
            "pro": proactive,
            "transport": [
                "type": "stdio",
                "command": cliPath,
                "args": serveArgs,
            ],
            "control": [
                "start": "open cling://mcp/start",
                "stop": "open cling://mcp/stop",
                "note": "Reading works whether or not it is started; changes are refused until it is. Starting sticks across launches until it is stopped.",
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: card, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }

        // Both cards go through the symlink resolver for the same reason the client configs do:
        // `~/.well-known` is a folder people keep in a dotfiles repo.
        for url in [supportDirectory.appendingPathComponent("mcp.json"), cardURL].map(resolvedConfigURL) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }

    static func state(_ client: Client) -> ConfigState {
        do {
            guard let root = try JSONCEditor.read(client.url) else { return .notInstalled }
            let installed = (root[serversKey(client.style)] as? [String: Any])?[serverName] != nil
            return installed ? .installed : .notInstalled
        } catch {
            return .unusable
        }
    }

    static func isInstalled(_ client: Client) -> Bool {
        state(client) == .installed
    }

    /// The command and arguments a client's config currently points at, or nil when Cling is not in it.
    static func installedCommand(_ client: Client) -> (command: String, args: [String])? {
        guard let root = try? JSONCEditor.read(client.url),
              let member = (root[serversKey(client.style)] as? [String: Any])?[serverName] as? [String: Any]
        else { return nil }

        // Zed nests the pair under `command`; the others keep them side by side.
        let source = client.style == .zed ? (member["command"] as? [String: Any] ?? [:]) : member
        let key = client.style == .zed ? "path" : "command"
        guard let command = source[key] as? String else { return nil }
        return (command, source["args"] as? [String] ?? [])
    }

    /// Whether an entry names something that is no longer on disk.
    ///
    /// The test is "does this still work", not "does this match what Cling would write now". An entry
    /// pointing at another copy of Cling is somebody's deliberate choice, and repointing it because this
    /// copy launched from somewhere else would hijack a working config.
    static func entryIsBroken(_ command: String, _ args: [String]) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: command) else { return true }
        // Only arguments that are absolute paths, so `mcp` and `serve` are never mistaken for files.
        return args.contains { $0.hasPrefix("/") && !FileManager.default.fileExists(atPath: $0) }
    }

    /// Repairs entries that no longer start anything, like one written by a copy of Cling that was since
    /// moved or deleted. Only entries that already exist and are already broken are touched: this never
    /// installs Cling into a client the user did not choose, and never moves one that still works.
    static func migrateInstalledClients() {
        guard serverExists else { return }

        for client in clients {
            guard let current = installedCommand(client), entryIsBroken(current.command, current.args) else { continue }
            mcpLog.info("Repairing dead MCP entry in \(client.name, privacy: .public): \(current.command, privacy: .public)")
            _ = install(client)
        }
    }

    // MARK: - Install and remove

    @discardableResult
    static func install(_ client: Client) -> Result<Void, Error> {
        guard serverExists else {
            return .failure(InstallError.missingServer)
        }
        return edit(client) { text in
            try JSONCEditor.setMember(in: text, container: serversKey(client.style), name: serverName, member: entry(for: client.style))
        }
    }

    @discardableResult
    static func remove(_ client: Client) -> Result<Void, Error> {
        edit(client) { text in
            // nil means ours was not in there, and nothing is written: a file that was never ours must not
            // be touched on the way out.
            JSONCEditor.removeMember(in: text, container: serversKey(client.style), name: serverName)
        }
    }

    static func revealConfig(_ client: Client) {
        NSWorkspace.shared.activateFileViewerSelecting([client.url])
    }

    @MainActor private static func askToEnable() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Let agents control Cling through MCP?"
        alert.informativeText = """
        An AI agent asked for MCP access which allows it to search your files, change indexes and ignore rules, change any setting, and write filters and scripts.

        You can also toggle this in Cling's Settings -> MCP.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Not now")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func serversKey(_ style: Style) -> String {
        switch style {
        case .mcpServers: "mcpServers"
        case .vsCode: "servers"
        case .zed: "context_servers"
        }
    }

    /// The member, already formatted. The file is edited as text, so this is what lands in it verbatim.
    private static func entry(for style: Style) -> String {
        let command = json(cliPath)
        let args = serveArgs.map(json).joined(separator: ", ")
        return switch style {
        case .zed:
            """
            {
              "source": "custom",
              "command": {
                "path": \(command),
                "args": [\(args)]
              }
            }
            """
        case .vsCode:
            """
            {
              "type": "stdio",
              "command": \(command),
              "args": [\(args)]
            }
            """
        case .mcpServers:
            """
            {
              "command": \(command),
              "args": [\(args)]
            }
            """
        }
    }

    /// A path can hold a quote or a backslash, so it goes through the encoder rather than into a string
    /// literal.
    private static func json(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes]),
              let array = String(data: data, encoding: .utf8)
        else { return "\"\(value)\"" }
        return String(array.dropFirst().dropLast())
    }

    /// Read the file as text, splice it, write it back. `change` returns nil when there is nothing to do,
    /// and then nothing is written at all.
    ///
    /// The read happens as late as possible: Claude Code keeps writing `~/.claude.json` while it runs, and
    /// anything it puts there between this read and this write is lost. The window is microseconds and it
    /// is not zero; a client that rewrites its config on a timer is a client to install into while it is
    /// closed.
    private static func edit(_ client: Client, _ change: (String) throws -> String?) -> Result<Void, Error> {
        do {
            let target = client.writeURL
            let existing = FileManager.default.fileExists(atPath: target.path)
                ? try String(contentsOf: target, encoding: .utf8)
                : ""
            guard let updated = try change(existing), updated != existing else { return .success(()) }

            let dir = target.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try updated.write(to: target, atomically: true, encoding: .utf8)
            mcpLog.info("Wrote MCP entry to \(client.path, privacy: .public)")
            return .success(())
        } catch {
            mcpLog.error("MCP install failed for \(client.name, privacy: .public): \(String(describing: error), privacy: .public)")
            return .failure(error)
        }
    }
}
