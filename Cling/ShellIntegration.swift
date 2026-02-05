import Foundation
import Lowtech
import System

let CLING_CLI_BIN = Bundle.main.sharedSupportPath.map { ($0 + "/ClingCLI").filePath! }
let CLING_CLI_LINK = (HOME / ".local/bin/cling")

class ShellIntegration {
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
            log.info("Created symlink \(linkPath) -> \(cliBin)")

            // Ensure ~/.local/bin is in PATH for common shells
            let pathExport = "export PATH=\"$PATH:$HOME/.local/bin\""
            for rcFile in [HOME / ".zshrc", HOME / ".bashrc"] {
                guard rcFile.exists else { continue }
                let contents = (try? String(contentsOf: rcFile.url)) ?? ""
                if !contents.contains(".local/bin") {
                    try (contents + "\n\(pathExport)\n").write(to: rcFile.url, atomically: true, encoding: .utf8)
                }
            }

            // Fish uses fish_user_paths
            let fishConfig = HOME / ".config/fish/config.fish"
            if fishConfig.exists {
                let contents = (try? String(contentsOf: fishConfig.url)) ?? ""
                if !contents.contains(".local/bin") {
                    try (contents + "\nfish_add_path $HOME/.local/bin\n").write(to: fishConfig.url, atomically: true, encoding: .utf8)
                }
            }

            return "Installed `cling` CLI to \(linkPath.shellString)\n\nRestart your shell or run: export PATH=\"$PATH:$HOME/.local/bin\""
        } catch {
            log.error("Failed to install CLI: \(error)")
            return "Failed to install CLI: \(error.localizedDescription)"
        }
    }

}
