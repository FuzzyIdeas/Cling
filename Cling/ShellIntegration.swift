import AppKit
import Foundation
import Lowtech
import OSLog
import System

private let log = Logger(subsystem: clingSubsystem, category: "ShellIntegration")

let CLING_CLI_BIN = Bundle.main.sharedSupportPath.map { ($0 + "/ClingCLI").filePath! }
let CLING_CLI_LINK = (HOME / ".local/bin/cling")

// MARK: - ShellIntegration

class ShellIntegration {
    static let pathExport = "export PATH=\"$PATH:$HOME/.local/bin\""

    /// Whether the `cling` symlink exists and points at this bundle's CLI binary.
    /// Catches stale links (the app was moved or updated to a new path) and broken
    /// links that `CLING_CLI_LINK.exists` would miss, so the UI offers a repairing
    /// reinstall instead of claiming the CLI is already installed.
    static var isInstalled: Bool {
        guard let cliBin = CLING_CLI_BIN, cliBin.exists else { return false }
        let fm = FileManager.default
        let link = CLING_CLI_LINK.string
        guard let attrs = try? fm.attributesOfItem(atPath: link),
              (attrs[.type] as? FileAttributeType) == .typeSymbolicLink,
              let dest = try? fm.destinationOfSymbolicLink(atPath: link)
        else { return false }
        return dest == cliBin.string
    }

    static var needsPathSetup: Bool {
        let shellConfigs: [(file: FilePath, check: String)] = [
            (HOME / ".zshrc", ".local/bin"),
            (HOME / ".bashrc", ".local/bin"),
            (HOME / ".config/fish/config.fish", ".local/bin"),
        ]
        for config in shellConfigs {
            guard config.file.exists else { continue }
            let contents = (try? String(contentsOf: config.file.url)) ?? ""
            if !contents.contains(config.check) {
                return true
            }
        }
        return false
    }

    static func installCLI() -> String {
        guard let cliBin = CLING_CLI_BIN, cliBin.exists else {
            return "ClingCLI binary not found in app bundle"
        }

        let fm = FileManager.default
        let linkDir = HOME / ".local/bin"
        let linkPath = CLING_CLI_LINK

        do {
            // Create ~/.local/bin if needed
            if !linkDir.exists {
                linkDir.mkdir(withIntermediateDirectories: true)
            }

            // Remove existing symlink or file
            if linkPath.exists || (try? fm.attributesOfItem(atPath: linkPath.string)) != nil {
                try fm.removeItem(atPath: linkPath.string)
            }

            // Create symlink
            try fm.createSymbolicLink(atPath: linkPath.string, withDestinationPath: cliBin.string)
            log.info("Created symlink \(linkPath.string) -> \(cliBin.string)")

            return "Installed `cling` CLI to \(linkPath.shellString)"
        } catch {
            log.error("Failed to install CLI: \(error.localizedDescription)")
            return "Failed to install CLI: \(error.localizedDescription)"
        }
    }

    static func addPathToShellConfigs() {
        do {
            for rcFile in [HOME / ".zshrc", HOME / ".bashrc"] {
                guard rcFile.exists else { continue }
                let contents = (try? String(contentsOf: rcFile.url)) ?? ""
                if !contents.contains(".local/bin") {
                    let resolvedURL = rcFile.url.resolvingSymlinksInPath()
                    try (contents + "\n\(pathExport)\n").write(to: resolvedURL, atomically: true, encoding: .utf8)
                }
            }

            let fishConfig = HOME / ".config/fish/config.fish"
            if fishConfig.exists {
                let contents = (try? String(contentsOf: fishConfig.url)) ?? ""
                if !contents.contains(".local/bin") {
                    let resolvedURL = fishConfig.url.resolvingSymlinksInPath()
                    try (contents + "\nfish_add_path $HOME/.local/bin\n").write(to: resolvedURL, atomically: true, encoding: .utf8)
                }
            }
        } catch {
            log.error("Failed to update shell configs: \(error.localizedDescription)")
        }
    }

    static func copyPathExportToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(pathExport, forType: .string)
    }
}
