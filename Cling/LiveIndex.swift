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
        if path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        if path.hasPrefix("/System/Volumes/Data/") {
            return String(path.dropFirst("/System/Volumes/Data".count))
        }
        guard !path.isEmpty, path != "/", !path.hasPrefix("/System/Volumes/"), !path.hasPrefix("/dev/") else { return nil }
        return path
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

    /// Records where the given scopes' saved files are, keeping the others as they were.
    static func save(_ ids: [SearchScope: UInt64]) {
        var state = read() ?? Self()
        if state.system != FSEventsHistory.systemBuild || state.fseventsUUID != FSEventsHistory.fseventsUUID {
            state = Self()
        }
        for (scope, id) in ids {
            state.eventIDs[scope.rawValue] = id
        }
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: file.url, options: .atomic)
    }

    static func forget(_ scopes: [SearchScope]) {
        guard var state = read() else { return }
        for scope in scopes {
            state.eventIDs[scope.rawValue] = nil
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
        applied: @escaping @Sendable (_ changes: Int) -> Void,
        historyLost: @escaping @Sendable () -> Void
    ) {
        _routes = routes
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
        lock.withLock { _routes }.filter { $0.contains(path) }.max { $0.root.count < $1.root.count }
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

    private struct EngineChanges {
        let engine: SearchEngine
        var gone: [String] = []
        var added: [(String, Bool)] = []
        var rescans: [(route: LiveRoute, dir: String)] = []
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
        var byEngine: [ObjectIdentifier: EngineChanges] = [:]
        var folders: [String: [String: WalkRules.Folder]] = [:]
        var changed = 0

        for (path, flags) in flagsByPath {
            guard let route = routes.filter({ $0.contains(path) }).max(by: { $0.root.count < $1.root.count }) else {
                if flags.contains(.mustScanSubDirs), routes.contains(where: { $0.root == path }) {
                    // A whole scope folder needs rescanning.
                    lost = true
                    historyLost()
                    return
                }
                continue
            }
            let key = ObjectIdentifier(route.engine)
            var entry = byEngine[key] ?? EngineChanges(engine: route.engine)
            defer { byEngine[key] = entry }

            var st = stat()
            guard lstat(path, &st) == 0 else {
                entry.gone.append(path)
                changed += 1
                continue
            }
            guard !flags.isDisjoint(with: structural) else { continue }
            let isDir = (st.st_mode & S_IFMT) == S_IFDIR
            var cache = folders[route.root] ?? [:]
            let admitted = SearchEngine.walkAdmits(path, isDir: isDir, rules: route.rules, folders: &cache)
            folders[route.root] = cache
            changed += 1
            guard admitted else {
                // Renamed to something the rules leave out.
                entry.gone.append(path)
                continue
            }
            entry.added.append((path, isDir))
            if isDir {
                // A folder moved in arrives as one event, with none for what is inside it, and one moved over an
                // indexed folder of the same name leaves that folder's old contents behind.
                entry.gone.append(path)
                entry.rescans.append((route, path))
            }
        }

        for var entry in byEngine.values {
            // Walk only the outermost folders, and leave out what those walks add anyway.
            let outer = Set(FSEventsHistory.outermost(entry.rescans.map(\.dir)))
            entry.rescans.removeAll { !outer.contains($0.dir) }
            if !outer.isEmpty {
                let prefixes = outer.map { $0 + "/" }
                entry.added.removeAll { path, _ in prefixes.contains { path.hasPrefix($0) } }
            }

            entry.engine.removeIndexed(entry.gone)
            for (path, isDir) in entry.added {
                _ = entry.engine.addPath(path, isDir: isDir)
            }
            for (route, dir) in entry.rescans {
                var cache = folders[route.root] ?? [:]
                let folder = route.rules.folder(dir, cache: &cache)
                entry.engine.walkDirectory(
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
