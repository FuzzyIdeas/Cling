import Defaults
import Foundation
import Lowtech
import System

enum Migration {
    static let CURRENT_VERSION = 2

    static let OLD_DEFAULT_SCRIPTS = [
        "Copy to temporary folder.zsh",
        "List archive contents.zsh",
        "Archive.zsh",
    ]

    static func run() {
        let version = Defaults[.migrationVersion]
        guard version < CURRENT_VERSION else { return }

        if version < 1 { migrateV1() }
        if version < 2 { migrateV2() }

        Defaults[.migrationVersion] = CURRENT_VERSION
    }

    /// v1: Update fsignore, delete old scripts, reinstall defaults
    private static func migrateV1() {
        if fsignore.exists {
            let backup = HOME / ".fsignore.bak"
            do {
                try fsignore.copy(to: backup, force: true)
                try FS_IGNORE.copy(to: fsignore, force: true)
                log.info("Migration v1: updated fsignore")
            } catch {
                log.error("Migration v1: failed to update fsignore: \(error)")
            }
        }

        for name in OLD_DEFAULT_SCRIPTS {
            let path = scriptsFolder / name
            if path.exists {
                try? FileManager.default.removeItem(atPath: path.string)
                log.info("Migration v1: deleted old script \(name)")
            }
        }

        if defaultScriptsMarker.exists {
            try? FileManager.default.removeItem(atPath: defaultScriptsMarker.string)
            log.info("Migration v1: removed default scripts marker for reinstall")
        }
        SM.installDefaultScriptsIfNeeded()
    }

    /// v2: Patch hardcoded username in Spotify ignore pattern
    private static func migrateV2() {
        guard fsignore.exists else { return }
        do {
            var content = try String(contentsOfFile: fsignore.string, encoding: .utf8)
            let old = "Library/Application Support/Spotify/PersistentCache/Users/alin.p32-user/*.tmp"
            if content.contains(old) {
                content = content.replacingOccurrences(of: old, with: "Library/Application Support/Spotify/PersistentCache/Users/*-user/*.tmp")
                try content.write(toFile: fsignore.string, atomically: true, encoding: .utf8)
                log.info("Migration v2: patched Spotify ignore pattern in fsignore")
            }
        } catch {
            log.error("Migration v2: failed to patch fsignore: \(error)")
        }
    }
}
