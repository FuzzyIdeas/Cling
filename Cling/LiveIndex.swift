import CoreServices
import Foundation
import Lowtech
import OSLog

private let log = Logger(subsystem: clingSubsystem, category: "LiveIndex")

// MARK: - FSEventsHistory

extension FSEventsHistory {
    static func replayable(eventID: UInt64, system: String, fseventsUUID uuid: String) -> Bool {
        eventID > 0 && eventID <= FSEventsGetCurrentEventId() && system == systemBuild && uuid == fseventsUUID
    }

    /// Dropped events or wrapped ids, or the whole disk flagged for rescanning: the replay can't be trusted.
    static func lost(_ flags: EonilFSEventsEventFlags, path: String) -> Bool {
        !flags.isDisjoint(with: [.userDropped, .kernelDropped, .idsWrapped]) || (flags.contains(.mustScanSubDirs) && isRoot(path))
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
        // Every saved scope now holds what the background agent gathered while Cling was closed.
        if let oldest = state.eventIDs.values.min() {
            ChangeJournal.discard(ifSavedPast: oldest)
        }
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

// MARK: - UnwatchedFolders

/// The busiest folders the walks skip, whose changes FSEvents leaves out of the stream (it takes at most 8). Temporary
/// files, build output and caches were nearly half the changes reaching Cling, each one checked only to be dropped.
/// It saves nothing in fseventsd, which reads and filters every change either way, only in Cling.
struct UnwatchedFolders: Codable {
    struct Folder: Codable {
        let path: String
        /// Changes an hour when it was chosen.
        let rate: Double
        let chosen: Date

        /// Halves each day: nothing is counted in a folder left out, so one that went quiet gives its place up to a
        /// busier one in time, and comes back if it is still the busier.
        var weight: Double {
            rate * pow(0.5, Date().timeIntervalSince(chosen) / 86400)
        }
    }

    static let file = indexFolder / "unwatched-folders.json"
    static let max = 8
    /// Fewer changes an hour aren't worth a place.
    static let minRate = 100.0

    var folders: [Folder] = []

    var paths: [String] {
        folders.map(\.path)
    }

    static func read() -> Self {
        guard let data = try? Data(contentsOf: file.url), let state = try? JSONDecoder().decode(Self.self, from: data) else {
            return Self()
        }
        return state
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.file.url, options: .atomic)
    }

    /// The busiest of these and of the folders counted over the last `hours`.
    func choosing(from counts: [String: Int], hours: Double) -> Self {
        var pool = folders
        for (path, count) in counts where Double(count) / hours >= Self.minRate && !pool.contains(where: { $0.path == path }) {
            pool.append(Folder(path: path, rate: Double(count) / hours, chosen: Date()))
        }
        var chosen: [Folder] = []
        for folder in pool.sorted(by: { $0.weight > $1.weight }) where chosen.count < Self.max {
            // One inside another leaves nothing more out.
            guard !chosen.contains(where: { folder.path.hasPrefix($0.path + "/") || $0.path.hasPrefix(folder.path + "/") }) else {
                continue
            }
            chosen.append(folder)
        }
        return Self(folders: chosen)
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

// MARK: - FSChange

/// One file change as FSEvents reports it.
struct FSChange {
    let path: String
    let flags: EonilFSEventsEventFlags
    let id: UInt64
}

// MARK: - FSChangeStream

/// A file-level FSEvents stream that hands each delivery over as one batch, on a serial queue of the caller's choosing.
/// Lowtech's stream calls back on the main thread once per event: a launch replay of a million changes kept the main
/// thread busy, and every change cost its own dispatch to each queue that wanted it.
///
/// No `noDefer`: a change waits up to `latency` and arrives with whatever else happened meanwhile, rather than waking
/// the process on its own after every quiet spell. `flush()` asks for what is waiting when someone is looking.
///
/// Everything after `init` happens on the stream's queue, where its deliveries arrive too.
final class FSChangeStream: @unchecked Sendable {
    init?(
        paths: [String], since: UInt64?, latency: CFTimeInterval, excluding: [String] = [], queue: DispatchQueue,
        handler: @escaping ([FSChange]) -> Void
    ) {
        self.paths = paths
        self.latency = latency
        self.queue = queue
        self.handler = Handler(handler, lastID: since ?? FSEventsGetCurrentEventId())
        guard let created = Self.create(paths: paths, since: since, latency: latency, excluding: excluding, queue: queue, handler: self.handler) else {
            return nil
        }
        stream = created
    }

    deinit {
        // Anything still queued holds the stream object, so nothing else can reach `stream` now.
        if let stream {
            queue.async { Self.tearDown(stream) }
        }
    }

    /// Delivers what is waiting out its latency now.
    func flush() {
        queue.async { [self] in
            guard let stream else { return }
            FSEventStreamFlushAsync(stream)
        }
    }

    func stop() {
        queue.async { [self] in
            guard let stream else { return }
            self.stream = nil
            Self.tearDown(stream)
        }
    }

    /// Starts again with changes inside `excluding` left out, from the last change delivered, so nothing is missed or
    /// delivered twice. FSEvents only takes the folders to leave out before a stream starts.
    func restart(excluding: [String]) {
        queue.async { [self] in
            guard let old = stream else { return }
            Self.tearDown(old)
            stream = Self.create(paths: paths, since: handler.lastID, latency: latency, excluding: excluding, queue: queue, handler: handler)
                ?? Self.create(paths: paths, since: handler.lastID, latency: latency, excluding: [], queue: queue, handler: handler)
        }
    }

    private final class Handler {
        init(_ call: @escaping ([FSChange]) -> Void, lastID: UInt64) {
            self.call = call
            self.lastID = lastID
        }

        let call: ([FSChange]) -> Void
        /// The newest change delivered, where a restart carries on from.
        var lastID: UInt64
    }

    private let paths: [String]
    private let latency: CFTimeInterval
    private let queue: DispatchQueue
    private let handler: Handler
    private var stream: FSEventStreamRef?

    private static func create(
        paths: [String], since: UInt64?, latency: CFTimeInterval, excluding: [String], queue: DispatchQueue, handler: Handler
    ) -> FSEventStreamRef? {
        let box = Unmanaged.passRetained(handler)
        var context = FSEventStreamContext(
            version: 0, info: box.toOpaque(),
            // The stream holds the handler for as long as it exists, so a delivery already queued when it stops
            // still finds it.
            retain: { info in
                guard let info else { return nil }
                return UnsafeRawPointer(Unmanaged<Handler>.fromOpaque(info).retain().toOpaque())
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Handler>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
            let cPaths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            var batch: [FSChange] = []
            batch.reserveCapacity(count)
            for i in 0 ..< count {
                batch.append(FSChange(path: String(cString: cPaths[i]), flags: EonilFSEventsEventFlags(rawValue: flags[i]), id: ids[i]))
                handler.lastID = max(handler.lastID, ids[i])
            }
            handler.call(batch)
        }
        let created = FSEventStreamCreate(
            nil, callback, &context, paths as CFArray,
            since ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        )
        // The stream took its own reference through `retain`.
        box.release()
        guard let created else { return nil }
        if !excluding.isEmpty, !FSEventStreamSetExclusionPaths(created, excluding as CFArray) {
            log.error("Could not leave \(excluding.count) folders out of the file change stream")
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return nil
        }
        return created
    }

    private static func tearDown(_ stream: FSEventStreamRef) {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

// MARK: - SharedFlag

/// A flag set on the main thread and read from background queues.
final class SharedFlag: @unchecked Sendable {
    init(_ value: Bool) {
        _value = value
    }

    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }

    /// Clears the flag and says whether it was set.
    func take() -> Bool {
        lock.withLock {
            defer { _value = false }
            return _value
        }
    }

    private let lock = NSLock()
    private var _value: Bool
}

// MARK: - LiveIndexBatch

/// What a batch of file changes did to the scope indexes.
struct LiveIndexBatch: Sendable {
    enum Kind: Sendable {
        case added
        case modified
        case removed
    }

    /// Indexed paths that came, changed or went, once the launch replay is done. What a folder brought or took with
    /// it isn't listed path by path.
    var paths: [(path: String, kind: Kind)] = []
    /// Entries the indexes gained, or lost when negative.
    var countDelta = 0
    /// Paths changed in the indexes.
    var changed = 0
}

// MARK: - LiveIndexUpdater

/// Applies file changes to the scope indexes as a walk would have found them, in batches on its own queue, so they
/// stay current without walking again. Nothing here touches the main thread; it is told when a batch lands.
final class LiveIndexUpdater: @unchecked Sendable {
    init(
        routes: [LiveRoute],
        replaying: Bool,
        applied: @escaping @Sendable (LiveIndexBatch) -> Void,
        caughtUp: @escaping @Sendable () -> Void = {},
        historyLost: @escaping @Sendable () -> Void
    ) {
        _routes = routes
        _caughtUp = !replaying
        self.applied = applied
        self.caughtUp = caughtUp
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

    /// Changes counted in each folder a walk skips, since they were last taken.
    func takeSkipped() -> [String: Int] {
        lock.withLock {
            defer { _skipped = [:] }
            return _skipped
        }
    }

    /// Whether no change inside `dir` could reach an index: the scope it belongs to skips it by rules that only
    /// change with a walk or a route refresh. `.gitignore` files are left out of that, as they change on their own.
    func isUnwatchable(_ dir: String) -> Bool {
        let routes = lock.withLock { _routes }
        guard let route = route(for: dir), !routes.contains(where: { $0.root.hasPrefix(dir + "/") }) else {
            return false
        }
        var folders: [String: WalkRules.Folder] = [:]
        let folder = (route.rules.discoverGitignore ? route.rules.withoutGitignore : route.rules).folder(dir, cache: &folders)
        return !folder.descended && !folder.added
    }

    /// Brings these folders up to date as their rules have them now, after a time their changes weren't followed.
    func rescan(_ dirs: [String]) {
        guard !dirs.isEmpty else { return }
        enqueue(dirs.map { FSChange(path: $0, flags: [.itemIsDir, .mustScanSubDirs], id: 0) })
    }

    /// The scope route a path belongs to, the deepest root first.
    func route(for path: String) -> LiveRoute? {
        let routes = lock.withLock { _routes }
        var best: LiveRoute?
        for route in routes where route.contains(path) && route.root.utf8.count > best?.root.utf8.count ?? -1 {
            best = route
        }
        return best
    }

    /// Takes a delivery from the stream; changes are applied half a second after the first of a batch arrives.
    func enqueue(_ events: [FSChange]) {
        queue.async { [self] in
            pending.append(contentsOf: events)
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

    /// Skipped folders counted at most, every `.git` and build folder that changed being one.
    private static let skippedMax = 10000

    private let lock = NSLock()
    private var _routes: [LiveRoute]

    private var _lastAppliedEventID: UInt64 = 0
    private var _changes = 0
    private var _skipped: [String: Int] = [:]
    private let applied: @Sendable (LiveIndexBatch) -> Void
    private let caughtUp: @Sendable () -> Void
    private let historyLost: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.lowtechguys.Cling.liveIndex", qos: .utility)
    private var pending: [FSChange] = []
    private var flushScheduled = false
    /// Changes were dropped since this updater started. Only touched on `queue`.
    private var lost = false
    private let started = CFAbsoluteTimeGetCurrent()
    private var _replayed = 0
    private var _caughtUp = false
    private var _caughtUpAt: CFAbsoluteTime?

    private static func isIgnoreFile(_ path: String) -> Bool {
        let name = path.lastPathComponentNative
        return name == ".gitignore" || name == ".ignore"
    }

    /// The outermost folder holding `path` that a walk skips by its rules. Nil when the walk goes into the folder
    /// holding it (the path was left out on its own), or only skips it because it can't list it.
    private static func skippedFolder(_ path: String, isDir: Bool, rules: WalkRules, folders: inout [String: WalkRules.Folder]) -> String? {
        let rootLength = rules.walkRoot.utf8.count
        var dir = isDir ? path : path.parentPath
        guard dir.utf8.count > rootLength, !rules.folder(dir, cache: &folders).descended else { return nil }
        while true {
            let parent = dir.parentPath
            guard parent.utf8.count > rootLength, !rules.folder(parent, cache: &folders).descended else { break }
            dir = parent
        }
        return rules.folder(dir, cache: &folders).added ? nil : dir
    }

    /// Asks for a walk once, and keeps applying what comes after: the walk is held to one an hour, and stopping here
    /// left the indexes following nothing at all until Cling was relaunched.
    private func reportLoss() {
        guard !lost else { return }
        lost = true
        historyLost()
    }

    /// What went away is removed through each engine's path index, so only an indexed folder costs a pass over the
    /// entries, then whatever a walk would index is added, skipping what is already there. A file only modified is
    /// already in the index.
    private func apply(_ events: [FSChange]) {
        let t0 = CFAbsoluteTimeGetCurrent()
        var flagsByPath: [String: EonilFSEventsEventFlags] = [:]
        var maxEventID: UInt64 = 0
        var replayDone = false
        // A replay is applied without being listed: it would fill the live changes list with a day of changes.
        let listing = lock.withLock { _caughtUp }
        for event in events {
            maxEventID = max(maxEventID, event.id)
            let flags = event.flags
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
                    replayDone = true
                    log.info("Live index: caught up after \(replayed) events in \(CFAbsoluteTimeGetCurrent() - self.started, format: .fixed(precision: 1))s")
                }
            }
            if FSEventsHistory.lost(flags, path: event.path) {
                reportLoss()
                continue
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
        var skipped: [String: Int] = [:]
        var modified: [String] = []
        var batch = LiveIndexBatch()
        var changed = 0

        for (path, flags) in flagsByPath {
            guard let route = routes.filter({ $0.contains(path) }).max(by: { $0.root.utf8.count < $1.root.utf8.count }) else {
                if flags.contains(.mustScanSubDirs), routes.contains(where: { $0.root == path }) {
                    // A whole scope folder needs rescanning.
                    reportLoss()
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
                if let dir = Self.skippedFolder(path, isDir: reportedDir, rules: route.rules, folders: &folders[route.root, default: [:]]) {
                    skipped[dir, default: 0] += 1
                }
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
            guard !flags.isDisjoint(with: structural) else {
                if kindKnown, listing {
                    modified.append(path)
                }
                continue
            }
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
                if let dir = Self.skippedFolder(path, isDir: isDir, rules: route.rules, folders: &folders[route.root, default: [:]]) {
                    skipped[dir, default: 0] += 1
                }
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

            let before = engine.count
            var removed = Set<String>()
            engine.removeIndexed(gone[key] ?? []) { removed.insert($0) }
            // Usually never indexed; counted only when they were (the rules changed since the last walk).
            changed += engine.removeIndexed(excluded[key] ?? []) { removed.insert($0) }
            for (path, isDir) in engineAdded {
                // A folder moved over one of the same name was taken out above and goes back in.
                let new = engine.addPathIfMissing(path, isDir: isDir) && removed.remove(path) == nil
                if listing {
                    batch.paths.append((path, new ? .added : .modified))
                }
            }
            for (route, dir) in engineRescans {
                let folder = route.rules.folder(dir, cache: &folders[route.root, default: [:]])
                engine.walkDirectory(
                    dir, ignoreFile: route.rules.ignoreFile, ignoreRoot: route.rules.ignoreRoot, skipDir: route.rules.skipDir,
                    applyBlocklist: route.rules.applyBlocklist, discoverGitignore: route.rules.discoverGitignore,
                    inheritedGitignores: folder.gitignores
                )
            }
            if listing {
                batch.paths += removed.map { ($0, .removed) }
            }
            batch.countDelta += engine.count - before
        }
        if listing {
            batch.paths += modified.map { ($0, .modified) }
        }
        batch.changed = changed

        lock.withLock {
            // Past a loss the engines no longer hold every change up to here, so their saved positions stay before it
            // and a relaunch replays what was dropped.
            if !lost {
                _lastAppliedEventID = max(_lastAppliedEventID, maxEventID)
            }
            _changes += changed
            for (dir, count) in skipped where _skipped.count < Self.skippedMax || _skipped[dir] != nil {
                _skipped[dir, default: 0] += count
            }
        }
        if changed > 0 {
            log.debug("Live index: \(changed) changed paths applied in \(CFAbsoluteTimeGetCurrent() - t0, format: .fixed(precision: 3))s")
        }
        if changed > 0 || batch.countDelta != 0 || !batch.paths.isEmpty {
            applied(batch)
        }
        if replayDone {
            caughtUp()
        }
    }
}
