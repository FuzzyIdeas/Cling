import AppKit
import CoreServices
import Foundation
import Lowtech
import OSLog
import System

private let log = Logger(subsystem: clingSubsystem, category: "Everything")

/// Its own folder: the normal index takes any other `.idx` file next to its scope files for a volume's index.
private let everythingFolder = indexFolder / "Everything"
private let everythingIndexFile = everythingFolder / "everything.idx"
private let everythingStateFile = everythingFolder / "everything.json"

// MARK: - EverythingSnapshot

/// What the saved index was built against. FSEvents replays changes since `eventID` on top of it; a different
/// macOS build or a reset FSEvents database means the replay can't be trusted and the index is walked again.
struct EverythingSnapshot: Codable {
    static var current: Self {
        Self(eventID: FSEventsGetCurrentEventId(), system: FSEventsHistory.systemBuild, fseventsUUID: FSEventsHistory.fseventsUUID, volumes: EverythingIndex.localVolumes())
    }

    var eventID: UInt64
    var system: String
    var fseventsUUID: String
    var volumes: [String]

    /// Whether the changes since `eventID` can still be replayed onto the saved index.
    var replayable: Bool {
        FSEventsHistory.replayable(eventID: eventID, system: system, fseventsUUID: fseventsUUID)
    }

    static func read() -> Self? {
        guard let data = try? Data(contentsOf: everythingStateFile.url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func write() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: everythingStateFile.url, options: .atomic)
    }
}

// MARK: - EverythingIndex

/// A second index of every file on the local disks, with no ignore file, blocklist or `.gitignore` applied. It
/// lives on disk and is only in memory while Everything is on (and for `unloadDelay` after), searched instead
/// of the normal engines, which it never touches. Nothing runs for it while it is unloaded: loading replays
/// what changed since it was saved, and it is only walked again when that history is lost.
@MainActor @Observable
final class EverythingIndex {
    enum CLIAccess {
        case ready(SearchEngine, building: Bool)
        case loading
        case needsPro
    }

    static let shared = EverythingIndex()

    /// How long it stays in memory after it is switched off, or after the window goes away while it is on.
    static let unloadDelay: TimeInterval = 10 * 60

    /// Searches go to this index instead of the normal one.
    private(set) var enabled = false
    private(set) var loading = false
    /// The first build, filling the engine that is already being searched.
    private(set) var building = false
    /// Any walk, including one that replaces the loaded engine when it is done.
    private(set) var walking = false
    private(set) var count = 0
    /// Set when the toggle is used without a Pro licence; the search bar button shows the Pro prompt for it.
    var showProPrompt = false

    /// Present while loaded, and from the start of the first build so results show up as it fills.
    @ObservationIgnored private(set) var engine: SearchEngine?

    var active: Bool {
        enabled && engine != nil
    }

    var state: String {
        loading ? "loading" : walking ? "indexing" : engine != nil ? "ready" : "unloaded"
    }

    /// Local disks other than the startup disk, walked as their own roots.
    nonisolated static func localVolumes() -> [String] {
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsRootFileSystemKey]
        return (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [])
            .filter { url in
                guard url.path.hasPrefix("/Volumes/"), let values = try? url.resourceValues(forKeys: Set(keys)) else { return false }
                return values.volumeIsLocal == true && values.volumeIsRootFileSystem != true
            }
            .map(\.path)
            .sorted()
    }

    func toggle() {
        guard proactive else {
            showProPrompt = true
            return
        }
        enabled ? disable() : enable()
    }

    func windowHidden() {
        guard enabled || engine != nil else { return }
        scheduleUnload()
    }

    func windowShown() {
        guard enabled else { return }
        unloadTask?.cancel()
        unloadTask = nil
    }

    /// For a CLI search: loads the index when needed and keeps it warm for `unloadDelay` after the last call.
    func cliAccess() -> CLIAccess {
        guard proactive else { return .needsPro }
        keepWarm()
        if !loading, engine == nil {
            load()
        }
        guard let engine, !loading else { return .loading }
        return .ready(engine, building: building)
    }

    /// Walks everything again, replacing the loaded engine when done, or filling a new one that is searched as it fills.
    func rebuild() -> Bool {
        guard proactive else { return false }
        keepWarm()
        walk(priority: .userInitiated)
        return true
    }

    /// Called after a batch of file changes lands, and on walk progress.
    func applied(to engine: SearchEngine, eventID: UInt64 = 0, changes: Int = 0) {
        guard self.engine === engine else { return }
        count = engine.count
        if eventID > 0 {
            lastEventID = max(lastEventID, eventID)
        }
        unsavedChanges += changes
        // While the first build fills the engine, search again every couple of seconds so results catch up.
        if building, enabled, CFAbsoluteTimeGetCurrent() - lastBuildSearch > 2 {
            lastBuildSearch = CFAbsoluteTimeGetCurrent()
            FUZZY.everythingChanged()
        } else if changes > 0, enabled {
            FUZZY.everythingChanged()
        }
    }

    /// FSEvents dropped events or lost its history, so the loaded engine may have missed changes.
    func historyLost(in engine: SearchEngine) {
        guard self.engine === engine, !walking else { return }
        log.info("Everything: change history lost, walking again")
        walk(priority: .utility)
    }

    @ObservationIgnored private var unloadTask: Task<Void, Never>?
    @ObservationIgnored private var updater: EverythingUpdater?
    @ObservationIgnored private var stream: FSChangeStream?
    @ObservationIgnored private let streamQueue = DispatchQueue(label: "com.lowtechguys.Cling.everythingStream", qos: .utility)
    @ObservationIgnored private var lastBuildSearch: CFAbsoluteTime = 0
    @ObservationIgnored private var volumeObservers: [NSObjectProtocol] = []
    /// What the loaded engine reflects, and how many paths changed since it was last written to disk.
    @ObservationIgnored private var snapshot: EverythingSnapshot?
    @ObservationIgnored private var lastEventID: UInt64 = 0
    @ObservationIgnored private var unsavedChanges = 0

    // MARK: Walking

    /// Each top-level folder of the startup disk walks on its own task, and so does each local disk under
    /// /Volumes. No ignore rules, `.git` folders and `.DS_Store` files stay in, and entries are appended without a
    /// duplicate check.
    private nonisolated static func walkEverything(into engine: SearchEngine, volumes: [String], progress: @escaping @Sendable () -> Void) async {
        let (roots, topLevel) = startupDiskRoots()
        for (path, isDir) in topLevel {
            engine.appendPath(path, isDir: isDir)
        }
        for volume in volumes {
            engine.appendPath(volume, isDir: true)
        }
        await withTaskGroup(of: Void.self) { group in
            for root in roots + volumes {
                group.addTask {
                    engine.walkDirectory(
                        root,
                        // The data volume shows up a second time in here; its folders are already at /.
                        skipDir: { $0 == "/System/Volumes" },
                        skipGitDirs: false,
                        skipJunkFiles: false,
                        dedupe: false,
                        progress: { _, _ in progress() }
                    )
                }
            }
        }
    }

    /// The startup disk's top-level entries, with every folder a walk root. A walk never leaves the disk it starts
    /// on, which keeps /dev and other mounts out; /Volumes is left unwalked since stat on a stalled network share
    /// there can hang, and its local disks are walked as their own roots.
    private nonisolated static func startupDiskRoots() -> (roots: [String], topLevel: [(String, Bool)]) {
        var rootStat = stat()
        lstat("/", &rootStat)

        var roots: [String] = []
        var topLevel: [(String, Bool)] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: "/")) ?? [] {
            let path = "/" + name
            var st = stat()
            guard lstat(path, &st) == 0 else { continue }
            let isDir = (st.st_mode & S_IFMT) == S_IFDIR
            // Another file system mounted at the top level (/dev).
            if isDir, st.st_dev != rootStat.st_dev {
                continue
            }
            topLevel.append((path, isDir))
            if isDir, path != "/Volumes" {
                roots.append(path)
            }
        }
        return (roots, topLevel)
    }

    private func enable() {
        enabled = true
        unloadTask?.cancel()
        unloadTask = nil
        if engine != nil {
            FUZZY.everythingChanged()
        } else {
            load()
        }
    }

    private func disable() {
        enabled = false
        FUZZY.everythingChanged()
        // Kept warm for a while, so switching straight back costs nothing.
        scheduleUnload()
    }

    private func keepWarm() {
        // While it is on with the window up, it stays loaded regardless.
        if !enabled || unloadTask != nil {
            scheduleUnload()
        }
    }

    private func scheduleUnload() {
        unloadTask?.cancel()
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.unloadDelay))
            guard !Task.isCancelled else { return }
            self?.unload()
        }
    }

    private func unload() {
        guard !walking else {
            // A walk holds the engine until it is done; try again after.
            scheduleUnload()
            return
        }
        let wasEnabled = enabled
        enabled = false
        stopWatching()
        if let engine {
            saveIfWorthIt(engine)
        }
        engine = nil
        count = 0
        if wasEnabled {
            FUZZY.everythingChanged()
        }
        FUZZY.logActivity("Everything unloaded")
    }

    /// Writing the index costs about as much as replaying a lot of changes, so it is only rewritten once enough
    /// have piled up, or once the replay would reach back more than a few days.
    private func saveIfWorthIt(_ engine: SearchEngine) {
        let age = everythingIndexFile.timestamp.map { Date().timeIntervalSince1970 - $0 } ?? .infinity
        guard var snapshot, unsavedChanges > 0, lastEventID > snapshot.eventID,
              unsavedChanges >= 20000 || age > 3 * 24 * 60 * 60
        else {
            releaseInBackground(engine)
            return
        }
        snapshot.eventID = lastEventID
        snapshot.volumes = Self.localVolumes()
        let saved = snapshot
        let url = everythingIndexFile.url
        Task.detached(priority: .background) {
            engine.saveBinaryIndex(to: url)
            saved.write()
        }
    }

    private func load() {
        guard !loading, !walking else { return }
        // Days behind, a replay would read millions of changes back out of FSEvents, which costs more than walking.
        guard everythingIndexFile.exists, let saved = EverythingSnapshot.read(), saved.replayable,
              FSEventsGetCurrentEventId() - saved.eventID <= FuzzyClient.maxReplayGap
        else {
            walk(priority: .userInitiated)
            return
        }
        loading = true
        let url = everythingIndexFile.url
        Task.detached(priority: .userInitiated) {
            let t0 = CFAbsoluteTimeGetCurrent()
            let engine = SearchEngine()
            let loaded = engine.loadBinaryIndex(from: url)
            log.info("Everything load: \(engine.count) entries in \(CFAbsoluteTimeGetCurrent() - t0, format: .fixed(precision: 2))s")
            if loaded {
                // Disks plugged in or out since it was saved.
                let now = Self.localVolumes()
                let gone = saved.volumes.filter { !now.contains($0) }
                if !gone.isEmpty {
                    engine.removeSubtrees(gone)
                }
                for volume in now where !saved.volumes.contains(volume) {
                    engine.appendPath(volume, isDir: true)
                    engine.walkDirectory(volume, skipGitDirs: false, skipJunkFiles: false, dedupe: false)
                }
            }
            await MainActor.run {
                self.loading = false
                guard loaded else {
                    self.walk(priority: .userInitiated)
                    return
                }
                self.snapshot = saved
                self.lastEventID = saved.eventID
                self.unsavedChanges = 0
                self.install(engine)
                self.startWatching(since: saved.eventID)
            }
        }
    }

    private func install(_ engine: SearchEngine) {
        if self.engine !== engine {
            releaseInBackground(self.engine)
        }
        self.engine = engine
        count = engine.count
        if enabled {
            FUZZY.everythingChanged()
        }
    }

    /// Walk everything into a fresh engine and save it. The first build is searched while it fills; a later one
    /// replaces the loaded engine when it is done.
    private func walk(priority: TaskPriority) {
        guard !walking else { return }
        walking = true
        // Changes made from here on are replayed on top of this walk once it is watched.
        let started = EverythingSnapshot.current
        let fresh = SearchEngine()
        if engine == nil {
            building = true
            install(fresh)
        }
        let url = everythingIndexFile.url
        Task.detached(priority: priority) {
            let t0 = CFAbsoluteTimeGetCurrent()
            await Self.walkEverything(into: fresh, volumes: started.volumes) {
                Task { @MainActor in self.applied(to: fresh) }
            }
            let walked = CFAbsoluteTimeGetCurrent()
            try? FileManager.default.createDirectory(at: everythingFolder.url, withIntermediateDirectories: true)
            fresh.saveBinaryIndex(to: url)
            started.write()
            let n = fresh.count
            log.info("Everything walk: \(n) entries in \(walked - t0, format: .fixed(precision: 1))s, saved in \(CFAbsoluteTimeGetCurrent() - walked, format: .fixed(precision: 1))s")

            // Reloading the saved file sheds the walk's growth slack, over half its memory at this size, like the
            // scope walks do. That includes the first build, which swaps the engine on show for its reloaded copy.
            let wanted = await MainActor.run { self.engine != nil }
            var finished = fresh
            if wanted {
                let reloaded = SearchEngine()
                if reloaded.loadBinaryIndex(from: url) {
                    finished = reloaded
                }
            }
            let engine = finished
            await MainActor.run {
                self.walking = false
                self.building = false
                FUZZY.logActivity("Everything indexed: \(n.formatted()) files")
                guard self.engine != nil else { return }
                self.stopWatching()
                self.snapshot = started
                self.lastEventID = started.eventID
                self.unsavedChanges = 0
                self.install(engine)
                self.startWatching(since: started.eventID)
            }
        }
    }

    // MARK: Live updates

    /// Replays every change since `since` (FSEvents keeps the history), then follows along until unloaded.
    private func startWatching(since: UInt64) {
        guard let engine else { return }
        let updater = EverythingUpdater(engine: engine)
        self.updater = updater
        // Changes arrive a few seconds late, in fewer and larger batches.
        stream = FSChangeStream(paths: ["/"], since: since, latency: 3, queue: streamQueue) { events in
            updater.enqueue(events)
        }
        if stream == nil {
            log.error("Everything watcher failed to start")
        }
        watchVolumes(updater)
    }

    private func stopWatching() {
        stream?.stop()
        stream = nil
        updater = nil
        for observer in volumeObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        volumeObservers = []
    }

    /// A disk plugged in while loaded is walked into the engine; one ejected leaves it. The saved index learns about
    /// either when it is next loaded.
    private func watchVolumes(_ updater: EverythingUpdater) {
        let center = NSWorkspace.shared.notificationCenter
        volumeObservers = [
            center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: nil) { note in
                guard let path = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path,
                      Self.localVolumes().contains(path)
                else { return }
                updater.addVolume(path)
            },
            center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: nil) { note in
                guard let path = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path, path.hasPrefix("/Volumes/") else { return }
                updater.removeVolume(path)
            },
        ]
    }

}

@MainActor let EVERYTHING = EverythingIndex.shared

// MARK: - EverythingUpdater

/// Applies file system events to a loaded Everything engine in batches, on its own background queue, so the
/// normal index's watcher and the main thread never wait on it.
final class EverythingUpdater: @unchecked Sendable {
    init(engine: SearchEngine) {
        self.engine = engine
        volumes = Set(EverythingIndex.localVolumes())
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

    func addVolume(_ path: String) {
        queue.async { [self] in
            guard !volumes.contains(path) else { return }
            volumes.insert(path)
            engine.appendPath(path, isDir: true)
            engine.walkDirectory(path, skipGitDirs: false, skipJunkFiles: false, dedupe: false)
            notify(eventID: 0, changes: 1)
        }
    }

    func removeVolume(_ path: String) {
        queue.async { [self] in
            guard volumes.remove(path) != nil else { return }
            engine.removeSubtrees([path])
            notify(eventID: 0, changes: 1)
        }
    }

    private let engine: SearchEngine
    private let queue = DispatchQueue(label: "com.lowtechguys.Cling.everything", qos: .utility)
    private var pending: [FSChange] = []
    private var flushScheduled = false
    /// The local disks under /Volumes being followed; events from anything else mounted there are ignored.
    private var volumes: Set<String>

    private func notify(eventID: UInt64, changes: Int) {
        let engine = engine
        Task { @MainActor in EVERYTHING.applied(to: engine, eventID: eventID, changes: changes) }
    }

    /// One pass over the engine per batch whatever its size: every path that went away or came back is removed
    /// in a single sweep, then whatever exists now is added. A file only modified is already in the index.
    private func apply(_ events: [FSChange]) {
        let t0 = CFAbsoluteTimeGetCurrent()
        var flagsByPath: [String: EonilFSEventsEventFlags] = [:]
        var maxEventID: UInt64 = 0
        for event in events {
            maxEventID = max(maxEventID, event.id)
            let flags = event.flags
            if FSEventsHistory.lost(flags, path: event.path) {
                let engine = engine
                Task { @MainActor in EVERYTHING.historyLost(in: engine) }
                return
            }
            guard let path = normalized(event.path) else { continue }
            flagsByPath[path, default: []].formUnion(flags)
        }
        guard !flagsByPath.isEmpty else {
            notify(eventID: maxEventID, changes: 0)
            return
        }

        var gone: [String] = []
        var added: [(String, Bool)] = []
        var rescan: [String] = []
        let structural: EonilFSEventsEventFlags = [.itemCreated, .itemRenamed, .itemRemoved, .mustScanSubDirs]
        for (path, flags) in flagsByPath {
            var st = stat()
            guard lstat(path, &st) == 0 else {
                if FSEventsHistory.isGone(errno) {
                    gone.append(path)
                }
                continue
            }
            guard !flags.isDisjoint(with: structural) else { continue }
            if flags.contains(.itemRenamed), FSEventsHistory.isStaleCase(path, mode: st.st_mode) {
                gone.append(path)
                continue
            }
            let isDir = (st.st_mode & S_IFMT) == S_IFDIR
            gone.append(path)
            added.append((path, isDir))
            if isDir {
                // A folder moved in arrives as one event, with none for what is inside it.
                rescan.append(path)
            }
        }

        // Walk only the outermost folders, and leave out what those walks add anyway.
        rescan = FSEventsHistory.outermost(rescan)
        if !rescan.isEmpty {
            let prefixes = rescan.map { $0 + "/" }
            added.removeAll { path, _ in prefixes.contains { path.hasPrefix($0) } }
        }

        engine.removeSubtrees(gone)
        for (path, isDir) in added {
            engine.appendPath(path, isDir: isDir)
        }
        for dir in rescan {
            engine.walkDirectory(dir, skipGitDirs: false, skipJunkFiles: false, dedupe: false)
        }
        log.debug("Everything: \(flagsByPath.count) changed paths applied in \(CFAbsoluteTimeGetCurrent() - t0, format: .fixed(precision: 3))s")
        notify(eventID: maxEventID, changes: flagsByPath.count)
    }

    /// Anything mounted under /Volumes that isn't a local disk being followed is left out too.
    private func normalized(_ raw: String) -> String? {
        guard let path = FSEventsHistory.normalized(raw) else { return nil }
        if path.hasPrefix("/Volumes/") {
            let volume = "/Volumes/" + (path.dropFirst("/Volumes/".count).split(separator: "/", maxSplits: 1).first ?? "")
            guard volumes.contains(volume) else { return nil }
        }
        return path
    }
}
