import Defaults
import Foundation
import Lowtech
import OSLog
import System

private let log = Logger(subsystem: clingSubsystem, category: "Migration")

// MARK: - Migration

enum Migration {
    static let CURRENT_VERSION = 5

    static let OLD_DEFAULT_SCRIPTS = [
        "Copy to temporary folder.zsh",
        "List archive contents.zsh",
        "Archive.zsh",
    ]

    static func run() {
        let version = Defaults[.migrationVersion]
        guard version < CURRENT_VERSION else { return }
        // A fresh install runs every migration from 0 too. One that ran Cling before has a migration on record, or
        // finished onboarding in a version from before migrations were.
        let existingInstall = version > 0 || Defaults[.onboardingCompleted]

        if version < 1 {
            migrateV1()
        }
        if version < 2 {
            migrateV2()
        }
        if version < 3 {
            migrateV3()
        }
        if version < 4 {
            migrateV4(existingInstall: existingInstall)
        }
        if version < 5 {
            migrateV5()
        }

        Defaults[.migrationVersion] = CURRENT_VERSION
    }

    /// New default blocklist groups added in this version. Existing users get these appended (deduped); they
    /// were never shipped before, so appending won't override a deliberate choice. Group header comments ride
    /// along so a future toggle UI sees the grouping too.
    private static let NEW_BLOCKED_CONTAINS = """
    #:group id=vcs name=Version control
    /.svn/
    /.hg/

    #:group id=apple-metadata name=System metadata
    /.Spotlight-V100/
    /.fseventsd/
    /.DocumentRevisions-V100/
    /.TemporaryItems/

    #:group id=dependencies name=Dependencies & package caches
    /.venv/
    /.tox/
    /Pods/
    /Carthage/
    /.gradle/
    /.terraform/
    """

    private static let NEW_BLOCKED_PREFIXES = """
    #:group id=ephemeral name=Temporary & ephemeral
    /private/var/vm/
    """

    /// The granular app-bundle sections that replace the blunt `.app/Contents/` block (keeps `Contents/MacOS`
    /// binaries and embedded framework dylibs searchable).
    private static let APP_CONTENTS_GRANULAR = [
        ".app/Contents/Resources/",
        ".app/Contents/PlugIns/",
        ".app/Contents/_CodeSignature/",
        ".app/Contents/SharedSupport/",
        ".lproj/",
    ]

    /// Default rules first shipped in v5, for files that change all the time and that nobody goes looking for:
    /// SQLite side files, Claude Code's sessions and history, apps' own logs, cookie stores and crash reporter state,
    /// web view and browser storage, Xcode build folders outside DerivedData, system daemons' containers and the
    /// system's logs. Grouped like the shipped defaults, so each lands in the group it belongs to.
    private static let V5_HOME_RULES = """
    #:group id=build name=Build & index artifacts
    **/SDKExplicitPrecompiledModules/
    **/SourcePackages/

    #:group id=claude-code name=Claude Code
    .claude*/backups/
    .claude*/cache/
    .claude*/debug/
    .claude*/file-history/
    .claude*/ide/
    .claude*/paste-cache/
    .claude*/plugins/**/.in_use/
    .claude*/plugins/.in_use-links/
    .claude*/session-env/
    .claude*/sessions/
    .claude*/shell-snapshots/
    .claude*/telemetry/
    .claude/context-mode/

    #:group id=browser name=Browser caches & state
    Library/**/IndexedDB/
    Library/Application Support/Firefox/Profiles/*/weave/

    #:group id=appstate name=App caches & telemetry
    *-shm
    *-wal
    **/.gnupg/*.lock
    **/.gnupg/*.tmp
    **/.gnupg/.#lk*
    **/.gnupg/S.*
    .local/state/
    Library/Application Support/*/logs/
    Library/Application Support/*/sentry/

    #:group id=library name=User Library caches & data
    Library/**/WebKit/
    Library/Daemon Containers/
    Library/HTTPStorages/
    Library/IdentityServices/
    """

    private static let V5_BLOCKED_PREFIXES = """
    #:group id=ephemeral name=Temporary & ephemeral
    /tmp/cc-socks/
    /tmp/claude-
    /tmp/context-mode-

    #:group id=system-state name=System logs & state
    /Library/Tailscale/
    /var/db/com.apple.backgroundtaskmanagement/
    /var/db/diagnostics/
    /var/db/uuidtext/
    /var/protected/
    """

    /// v1: Update fsignore, delete old scripts, reinstall defaults
    private static func migrateV1() {
        if fsignore.exists {
            let backup = HOME / ".fsignore.bak"
            do {
                try fsignore.copy(to: backup, force: true)
                try FS_IGNORE.copy(to: fsignore, force: true)
                log.info("Migration v1: updated fsignore")
            } catch {
                log.error("Migration v1: failed to update fsignore: \(error.localizedDescription)")
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
            log.error("Migration v2: failed to patch fsignore: \(error.localizedDescription)")
        }
    }

    /// v3: Regroup + tighten the global blocklist and refresh the home ignore file, without clobbering any of
    /// the user's own customizations (surgical: replace a shipped default line only if it's still present
    /// verbatim, otherwise append-only).
    private static func migrateV3() {
        // Blocklist (contains): granularize `.app/Contents/`, then append the new default groups.
        var contains = Defaults[.blockedContains]
        if let replaced = replaceKnownDefaultLine(".app/Contents/", with: APP_CONTENTS_GRANULAR, in: contains) {
            contains = replaced
            log.info("Migration v3: granularized .app/Contents/ blocklist rule")
        }
        contains = appendingMissingLines(from: NEW_BLOCKED_CONTAINS, to: contains)
        Defaults[.blockedContains] = contains

        // Blocklist (prefixes): append the new ephemeral entries.
        Defaults[.blockedPrefixes] = appendingMissingLines(from: NEW_BLOCKED_PREFIXES, to: Defaults[.blockedPrefixes])
        PathBlocklist.shared.rebuild()

        // Home fsignore: append every functional rule from the refreshed bundled template the user is missing
        // (cross-domain caches + the DEVONthink carve-out), never touching existing or custom lines.
        guard fsignore.exists, let template = try? String(contentsOf: FS_IGNORE.url, encoding: .utf8) else { return }
        let templateRules = functionalLines(in: template)
        if let current = try? String(contentsOfFile: fsignore.string, encoding: .utf8) {
            let updated = appendingMissingLines(templateRules, to: current)
            if updated != current {
                do {
                    try updated.write(toFile: fsignore.string, atomically: true, encoding: .utf8)
                    log.info("Migration v3: appended new default ignore rules to fsignore")
                } catch {
                    log.error("Migration v3: failed to update fsignore: \(error.localizedDescription)")
                }
            }
        }
    }

    /// v4: The search bar became what the hotkey brings up on a new install. One from before keeps the search window
    /// it was getting, unless the user had already picked one.
    private static func migrateV4(existingInstall: Bool) {
        // The stored settings only: Defaults registers every key's default, so `object(forKey:)` is never nil.
        let stored = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
        guard existingInstall, stored?[Defaults.Keys.hotkeyTarget.name] == nil else { return }
        Defaults[.hotkeyTarget] = .window
        log.info("Migration v4: kept the search window as the hotkey target")
    }

    /// v5: Add the new default rules to the blocklist and the home ignore file, into their groups. They were never
    /// shipped before, so none of them can be one the user removed on purpose.
    private static func migrateV5() {
        var prefixes = IgnoreDocument.parse(Defaults[.blockedPrefixes])
        prefixes.add(IgnoreDocument.parse(V5_BLOCKED_PREFIXES), placedLike: IgnoreDocument.parse(Defaults.Keys.blockedPrefixes.defaultValue))
        // Unchanged on a new install, whose defaults have them already: left unstored, it keeps following the defaults.
        if prefixes.serialize() != Defaults[.blockedPrefixes] {
            Defaults[.blockedPrefixes] = prefixes.serialize()
            PathBlocklist.shared.rebuild()
        }

        guard fsignore.exists, let current = try? String(contentsOfFile: fsignore.string, encoding: .utf8) else { return }
        var home = IgnoreDocument.parse(current)
        let template = (try? String(contentsOf: FS_IGNORE.url, encoding: .utf8)).map(IgnoreDocument.parse)
        home.add(IgnoreDocument.parse(V5_HOME_RULES), placedLike: template)
        let updated = home.serialize()
        guard updated != current else { return }
        do {
            try updated.write(toFile: fsignore.string, atomically: true, encoding: .utf8)
            log.info("Migration v5: added the new default ignore rules to fsignore")
        } catch {
            log.error("Migration v5: failed to update fsignore: \(error.localizedDescription)")
        }
    }

    // MARK: - Surgical helpers

    /// Non-comment, non-blank lines (trimmed), in order.
    private static func functionalLines(in content: String) -> [String] {
        content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Append the lines from `block` that aren't already present (trimmed compare). Comment/group-header lines
    /// in `block` are kept so the grouping carries over, but deduped too.
    private static func appendingMissingLines(from block: String, to content: String) -> String {
        appendingMissingLines(block.components(separatedBy: .newlines), to: content)
    }

    private static func appendingMissingLines(_ add: [String], to content: String) -> String {
        let existing = Set(content.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) })
        let newLines = add.filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !existing.contains(t)
        }
        guard !newLines.isEmpty else { return content }
        var updated = content
        if !updated.isEmpty, !updated.hasSuffix("\n") {
            updated += "\n"
        }
        updated += newLines.joined(separator: "\n")
        return updated
    }

    /// Replace a known shipped-default line with replacement lines, but only if it's present verbatim and the
    /// user hasn't built customizations around it (no `!` exception line references it). Returns nil = leave
    /// the content untouched.
    private static func replaceKnownDefaultLine(_ old: String, with replacement: [String], in content: String) -> String? {
        var lines = content.components(separatedBy: .newlines)
        guard let idx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == old }) else { return nil }
        // If the user added an exception referencing this rule, they've customized it; don't disturb it.
        if lines.contains(where: { let t = $0.trimmingCharacters(in: .whitespaces); return t.hasPrefix("!") && t.contains(old) }) {
            return nil
        }
        lines.replaceSubrange(idx ... idx, with: replacement)
        return lines.joined(separator: "\n")
    }
}
