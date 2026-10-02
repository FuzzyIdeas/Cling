import CoreServices
import Foundation
import Lowtech
import OSLog

private let log = Logger(subsystem: clingSubsystem, category: "LiveIndex")

// MARK: - FSEventsHistory

/// FSEvents keeps a log of file changes on each disk whether or not anything is watching, so an index saved with
/// its position in that log can catch up on launch by replaying from there instead of walking again.
enum FSEventsHistory {
    /// The sealed system volume only changes in a macOS update, and FSEvents doesn't report those.
    static var systemBuild: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    /// Identifies the data volume's FSEvents history; it changes when that history is thrown away.
    static var fseventsUUID: String {
        var st = stat()
        guard lstat("/Users", &st) == 0, let uuid = FSEventsCopyUUIDForDevice(st.st_dev) else { return "" }
        return CFUUIDCreateString(nil, uuid) as String? ?? ""
    }

    static func replayable(eventID: UInt64, system: String, fseventsUUID uuid: String) -> Bool {
        eventID > 0 && eventID <= FSEventsGetCurrentEventId() && system == systemBuild && uuid == fseventsUUID
    }

    /// Dropped events or wrapped ids, or the whole disk flagged for rescanning: the replay can't be trusted.
    static func lost(_ flags: EonilFSEventsEventFlags, path: String) -> Bool {
        !flags.isDisjoint(with: [.userDropped, .kernelDropped, .idsWrapped]) || (flags.contains(.mustScanSubDirs) && isRoot(path))
    }

    static func isRoot(_ path: String) -> Bool {
        path == "/" || path == "/System/Volumes/Data" || path == "/System/Volumes/Data/"
    }

    /// The data volume's own mount path maps back onto /, and the system's helper volumes and /dev are left out.
    static func normalized(_ raw: String) -> String? {
        var path = raw
        // FSEvents hands paths over bridged from NSString; native storage keeps the hashing, comparing and prefix
        // checks that follow off the slow path.
        path.makeContiguousUTF8()
        if path.utf8.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        if path.hasPrefix("/System/Volumes/Data/") {
            return String(path.utf8.dropFirst("/System/Volumes/Data".utf8.count))!
        }
        guard !path.isEmpty, path != "/", !path.hasPrefix("/System/Volumes/"), !path.hasPrefix("/dev/") else { return nil }
        return path
    }

    /// Whether a failed lstat means the path is gone. A path that exists but can't be read (Full Disk Access taken
    /// away, say) is left as it was rather than dropped from the index.
    static func isGone(_ errorNumber: Int32) -> Bool {
        errorNumber == ENOENT || errorNumber == ENOTDIR
    }

    /// A renamed path that still resolves under a different case is the old spelling of a case-only rename (the disk
    /// ignores case, so lstat finds it either way), and only the new spelling stays in the index.
    static func isStaleCase(_ path: String, mode: mode_t) -> Bool {
        guard (mode & S_IFMT) != S_IFLNK else { return false }
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buf) != nil else { return false }
        let onDisk = String(cString: buf).lastPathComponentNative
        let reported = path.lastPathComponentNative
        return onDisk != reported && onDisk.lowercased() == reported.lowercased()
    }

    /// Folders not inside another folder of the list.
    static func outermost(_ dirs: [String]) -> [String] {
        var result: [String] = []
        for dir in dirs.sorted() {
            if let last = result.last, dir.hasPrefix(last + "/") {
                continue
            }
            result.append(dir)
        }
        return result
    }
}

// MARK: - ScopeIndexState

/// The FSEvents position each saved scope index reflects, kept next to the index files (not as an `.idx`, which
/// would be taken for a volume's index). A scope without a position, or a position from another macOS build or
/// FSEvents history, is walked again instead of replayed.
struct ScopeIndexState: Codable {
    static let file = indexFolder / "index-state.json"

    var eventIDs: [String: UInt64] = [:]
    /// What each scope's rules looked like when it was last walked; rules changed while Cling was closed mean the
    /// saved index no longer matches them, and that scope is walked again.
    var rules: [String: String] = [:]
    var system = FSEventsHistory.systemBuild
    var fseventsUUID = FSEventsHistory.fseventsUUID

    /// Positions that can still be replayed, by scope.
    var replayable: [SearchScope: UInt64] {
        guard system == FSEventsHistory.systemBuild, fseventsUUID == FSEventsHistory.fseventsUUID else { return [:] }
        let now = FSEventsGetCurrentEventId()
        return eventIDs.reduce(into: [:]) { result, item in
            if let scope = SearchScope(rawValue: item.key), item.value > 0, item.value <= now {
                result[scope] = item.value
            }
        }
    }

    static func read() -> Self? {
        guard let data = try? Data(contentsOf: file.url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    /// Records where the given scopes' saved files are and the rules they were walked by, keeping the others as
    /// they were.
    static func save(_ ids: [SearchScope: UInt64], rules: [SearchScope: String]) {
        var state = read() ?? Self()
        if state.system != FSEventsHistory.systemBuild || state.fseventsUUID != FSEventsHistory.fseventsUUID {
            state = Self()
        }
        for (scope, id) in ids {
            guard let fingerprint = rules[scope] else { continue }
            state.eventIDs[scope.rawValue] = id
            state.rules[scope.rawValue] = fingerprint
        }
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: file.url, options: .atomic)
    }

    static func forget(_ scopes: [SearchScope]) {
        guard var state = read() else { return }
        for scope in scopes {
            state.eventIDs[scope.rawValue] = nil
            state.rules[scope.rawValue] = nil
        }
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: file.url, options: .atomic)
    }
}

// MARK: - LiveRoute

/// A folder a scope walks, with the engine it fills and the rules it walks by.
struct LiveRoute: @unchecked Sendable {
    let scope: SearchScope
    let root: String
    let excludePrefix: String?
    let engine: SearchEngine
    let rules: WalkRules

    func contains(_ path: String) -> Bool {
        guard path.hasPrefix(root + "/") else { return false }
        if let excludePrefix, path == excludePrefix || path.hasPrefix(excludePrefix + "/") {
            return false
        }
        return true
    }
}

// MARK: - LiveIndexUpdater

/// Applies file changes to the scope indexes as a walk would have found them, in batches on its own queue, so they
/// stay current without walking again. Nothing here touches the main thread; it is told when a batch lands.
final class LiveIndexUpdater: @unchecked Sendable {
    init(
        routes: [LiveRoute],
        replaying: Bool,
        applied: @escaping @Sendable (_ changes: Int) -> Void,
        historyLost: @escaping @Sendable () -> Void
    ) {
        _routes = routes
        _caughtUp = !replaying
        self.applied = applied
        self.historyLost = historyLost
    }

    /// Every event up to this one has been applied.
    var lastAppliedEventID: UInt64 {
        lock.withLock { _lastAppliedEventID }
    }

    var changes: Int {
        lock.withLock { _changes }
    }

    /// How far the replay of changes made while Cling was closed has got.
    var replay: (caughtUp: Bool, events: Int, seconds: Double) {
        lock.withLock { (_caughtUp, _replayed, (_caughtUpAt ?? CFAbsoluteTimeGetCurrent()) - started) }
    }

    /// Paths changed in the indexes since the counter was last taken.
    func takeChanges() -> Int {
        lock.withLock {
            defer { _changes = 0 }
            return _changes
        }
    }

    func setRoutes(_ routes: [LiveRoute]) {
        lock.withLock { _routes = routes }
    }

    /// The scope route a path belongs to, the deepest root first.
    func route(for path: String) -> LiveRoute? {
        lock.withLock { _routes }.filter { $0.contains(path) }.max { $0.root.utf8.count < $1.root.utf8.count }
    }

    /// Delivered by the stream one event at a time, so it only hands the event over.
    func enqueue(_ event: EonilFSEventsEvent) {
        queue.async { [self] in
            pending.append(event)
            guard !flushScheduled else { return }
            flushScheduled = true
            queue.asyncAfter(deadline: .now() + 0.5) { [self] in
                flushScheduled = false
                let batch = pending
                pending.removeAll(keepingCapacity: true)
                apply(batch)
            }
        }
    }

    private let lock = NSLock()
    private var _routes: [LiveRoute]

    private var _lastAppliedEventID: UInt64 = 0
    private var _changes = 0
    private let applied: @Sendable (Int) -> Void
    private let historyLost: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.lowtechguys.Cling.liveIndex", qos: .utility)
    private var pending: [EonilFSEventsEvent] = []
    private var flushScheduled = false
    private var lost = false
    private let started = CFAbsoluteTimeGetCurrent()
    private var _replayed = 0
    private var _caughtUp = false
    private var _caughtUpAt: CFAbsoluteTime?

    private static func isIgnoreFile(_ path: String) -> Bool {
        let name = path.lastPathComponentNative
        return name == ".gitignore" || name == ".ignore"
    }

    /// What went away is removed through each engine's path index, so only an indexed folder costs a pass over the
    /// entries, then whatever a walk would index is added, skipping what is already there. A file only modified is
    /// already in the index.
    private func apply(_ events: [EonilFSEventsEvent]) {
        guard !lost else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        var flagsByPath: [String: EonilFSEventsEventFlags] = [:]
        var maxEventID: UInt64 = 0
        for event in events {
            maxEventID = max(maxEventID, event.ID?.rawValue ?? 0)
            let flags = event.flag ?? []
            if !lock.withLock({ _caughtUp }) {
                let replayed = lock.withLock {
                    _replayed += 1
                    if flags.contains(.historyDone) {
                        _caughtUp = true
                        _caughtUpAt = CFAbsoluteTimeGetCurrent()
                    }
                    return _replayed
                }
                if flags.contains(.historyDone) {
                    log.info("Live index: caught up after \(replayed) events in \(CFAbsoluteTimeGetCurrent() - self.started, format: .fixed(precision: 1))s")
                }
            }
            if FSEventsHistory.lost(flags, path: event.path) {
                lost = true
                historyLost()
                return
            }
            guard let path = FSEventsHistory.normalized(event.path) else { continue }
            flagsByPath[path, default: []].formUnion(flags)
        }

        let routes = lock.withLock { _routes }
        let structural: EonilFSEventsEventFlags = [.itemCreated, .itemRenamed, .itemRemoved, .mustScanSubDirs]
        // Kept apart and appended to in place: a struct of arrays copied out of a dictionary and written back
        // copies the arrays on every append, which made a replay of a million changes quadratic.
        var engines: [ObjectIdentifier: SearchEngine] = [:]
        var gone: [ObjectIdentifier: [String]] = [:]
        var excluded: [ObjectIdentifier: [String]] = [:]
        var added: [ObjectIdentifier: [(String, Bool)]] = [:]
        var rescans: [ObjectIdentifier: [(route: LiveRoute, dir: String)]] = [:]
        var folders: [String: [String: WalkRules.Folder]] = [:]
        var changed = 0

        for (path, flags) in flagsByPath {
            guard let route = routes.filter({ $0.contains(path) }).max(by: { $0.root.utf8.count < $1.root.utf8.count }) else {
                if flags.contains(.mustScanSubDirs), routes.contains(where: { $0.root == path }) {
                    // A whole scope folder needs rescanning.
                    lost = true
                    historyLost()
                    return
                }
                continue
            }
            let key = ObjectIdentifier(route.engine)
            engines[key] = route.engine

            if route.rules.discoverGitignore, Self.isIgnoreFile(path) {
                // A changed .gitignore changes what its folder should hold: walk that folder again under the new
                // rules. The scope folder's own one is never read by a walk.
                let dir = path.parentPath
                folders[route.root] = nil
                if dir != route.root, SearchEngine.walkAdmits(dir, isDir: true, rules: route.rules, folders: &folders[route.root, default: [:]]) {
                    gone[key, default: []].append(dir)
                    added[key, default: []].append((dir, true))
                    rescans[key, default: []].append((route, dir))
                    changed += 1
                }
            }

            // The rules first, with the kind FSEvents reports: most changes land in what they leave out (caches, .git,
            // build output), and those need no lstat, only dropping from the index in case they were there (a
            // lookup). A folder left out answers for everything inside it for the rest of the batch.
            let reportedDir = flags.contains(.itemIsDir) && !flags.contains(.itemIsSymlink)
            let kindKnown = flags.contains(.itemIsDir) != flags.contains(.itemIsFile)
            if kindKnown, !SearchEngine.walkAdmits(path, isDir: reportedDir, rules: route.rules, folders: &folders[route.root, default: [:]]) {
                excluded[key, default: []].append(path)
                continue
            }

            var st = stat()
            guard lstat(path, &st) == 0 else {
                if FSEventsHistory.isGone(errno) {
                    gone[key, default: []].append(path)
                    changed += 1
                }
                continue
            }
            guard !flags.isDisjoint(with: structural) else { continue }
            if flags.contains(.itemRenamed), FSEventsHistory.isStaleCase(path, mode: st.st_mode) {
                gone[key, default: []].append(path)
                changed += 1
                continue
            }
            let isDir = (st.st_mode & S_IFMT) == S_IFDIR
            if !kindKnown || isDir != reportedDir,
               !SearchEngine.walkAdmits(path, isDir: isDir, rules: route.rules, folders: &folders[route.root, default: [:]])
            {
                excluded[key, default: []].append(path)
                continue
            }
            changed += 1
            added[key, default: []].append((path, isDir))
            if isDir {
                // A folder moved in arrives as one event, with none for what is inside it, and one moved over an
                // indexed folder of the same name leaves that folder's old contents behind.
                gone[key, default: []].append(path)
                rescans[key, default: []].append((route, path))
            }
        }

        for (key, engine) in engines {
            var engineAdded = added[key] ?? []
            var engineRescans = rescans[key] ?? []
            // Walk only the outermost folders, and leave out what those walks add anyway.
            let outer = Set(FSEventsHistory.outermost(engineRescans.map(\.dir)))
            engineRescans.removeAll { !outer.contains($0.dir) }
            if !outer.isEmpty {
                let prefixes = outer.map { $0 + "/" }
                engineAdded.removeAll { path, _ in prefixes.contains { path.hasPrefix($0) } }
            }

            engine.removeIndexed(gone[key] ?? [])
            // Usually never indexed; counted only when they were (the rules changed since the last walk).
            changed += engine.removeIndexed(excluded[key] ?? [])
            for (path, isDir) in engineAdded {
                _ = engine.addPath(path, isDir: isDir)
            }
            for (route, dir) in engineRescans {
                let folder = route.rules.folder(dir, cache: &folders[route.root, default: [:]])
                engine.walkDirectory(
                    dir, ignoreFile: route.rules.ignoreFile, ignoreRoot: route.rules.ignoreRoot, skipDir: route.rules.skipDir,
                    applyBlocklist: route.rules.applyBlocklist, discoverGitignore: route.rules.discoverGitignore,
                    inheritedGitignores: folder.gitignores
                )
            }
        }

        lock.withLock {
            _lastAppliedEventID = max(_lastAppliedEventID, maxEventID)
            _changes += changed
        }
        if changed > 0 {
            log.debug("Live index: \(changed) changed paths applied in \(CFAbsoluteTimeGetCurrent() - t0, format: .fixed(precision: 3))s")
            applied(changed)
        }
    }
}
