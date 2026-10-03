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
/// The clients and the editing live in `MCPClients.swift`, shared as is with Clop, rcmd, Lunar and Crank.
/// This half is what is Cling's own.
enum MCPInstaller {
    // MARK: - State

    enum InstallError: LocalizedError {
        case missingServer

        var errorDescription: String? {
            switch self {
            case .missingServer: "Cling's CLI is missing from the app bundle, so the MCP server cannot run."
            }
        }
    }

    static let serverName = "cling"

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

    /// The name the shared `MCPClients.swift` checks.
    static var scriptExists: Bool {
        serverExists
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
}
