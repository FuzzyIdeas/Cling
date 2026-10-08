import AppKit
import Combine
import CoreServices
import Defaults
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
    /// `volumes` are filled in by the caller off the main thread: finding them reads each disk (`internalVolumes`).
    static var current: Self {
        Self(eventID: FSEventsGetCurrentEventId(), system: FSEventsHistory.systemBuild, fseventsUUID: FSEventsHistory.fseventsUUID, volumes: [])
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

/// A second index of every file on the internal disk, with no ignore file, blocklist or `.gitignore` applied. It
/// lives on disk and is only in memory while Everything is on (and for `unloadDelay` after), searched instead
/// of the normal engines, which it never touches. Nothing runs for it while it is unloaded: loading replays
/// what changed since it was saved, and it is only walked again when that history is lost.
@MainActor @Observable
final class EverythingIndex {
    private init() {
        settingObserver = Defaults.publisher(.everythingEnabled, options: []).sink { [weak self] _ in
            Task { @MainActor in self?.applySetting() }
        }
    }

    enum CLIAccess {
        case ready(SearchEngine, building: Bool)
        case loading
        case needsPro
        case off
    }

    static let shared = EverythingIndex()

    /// How long it stays in memory after it is switched off, or after the window goes away while it is on.
    static let unloadDelay: TimeInterval = 10 * 60

    nonisolated static let offMessage = "Everything is off. Turn it on in Settings > Search, or with: cling everything on"

    nonisolated static var indexFile: FilePath {
        everythingIndexFile
    }

    /// The `everythingEnabled` setting as last applied. Off, nothing loads, walks or follows the index, and its
    /// toggle and shortcut are gone from the window, the search bar and the file server.
    private(set) var available = Defaults[.everythingEnabled]
    /// Searches go to this index instead of the normal one.
    private(set) var enabled = false
    private(set) var loading = false
    /// The first build, filling the engine that is already being searched.
    private(set) var building = false
    /// Any walk, including one that replaces the loaded engine when it is done.
    private(set) var walking = false
    private(set) var count = 0
    /// Entries the walk in progress has reached. A walk that replaces the loaded engine fills one of its own, so
    /// `count` stays the size of the index still being searched until the walk is done.
    private(set) var walked = 0
    /// Set when the toggle is used without a Pro licence; the search bar button shows the Pro prompt for it.
    var showProPrompt = false

    /// Present while loaded, and from the start of the first build so results show up as it fills.
    @ObservationIgnored private(set) var engine: SearchEngine?

    var active: Bool {
        enabled && engine != nil
    }

    /// On, and not set aside by a search limited to external drives, which Everything has no index of. What the
    /// toggle, the chip and the window's tint show.
    var applies: Bool {
        enabled && !FUZZY.searchLimitedToDrives
    }

    /// Why the toggle is off limits right now, for its tooltip; nil while it can be used.
    var blockedReason: String? {
        FUZZY.searchLimitedToDrives ? "External drives have no Everything index, so it stays off while searching them" : nil
    }

    var state: String {
        !available ? "off" : loading ? "loading" : walking ? "indexing" : engine != nil ? "ready" : "unloaded"
    }

    /// What the saved index takes on disk, as last measured off the main thread.
    var savedBytes: Int {
        INDEX_SIZES.everything ?? 0
    }

    /// Volumes on the internal disk other than the startup one (a second partition, say), walked as their own roots,
    /// unless turned off in Settings > Drives. Drives plugged in over USB, Thunderbolt or a card slot stay out, and
    /// so does a Time Machine disk, which holds copies of what is already indexed, millions of files deep. Telling
    /// one apart reads the disk, so this never runs on the main thread.
    nonisolated static func internalVolumes() -> [String] {
        let keys: [URLResourceKey] = [.volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsRootFileSystemKey]
        let off = Set(Defaults[.disabledVolumes].map(\.string))
        return (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [])
            .filter { url in
                guard url.path.hasPrefix("/Volumes/"), !off.contains(url.path), let values = try? url.resourceValues(forKeys: Set(keys)) else { return false }
                return values.volumeIsInternal == true && values.volumeIsRemovable != true && values.volumeIsRootFileSystem != true
            }
            .map(\.path)
            .filter { !isTimeMachineBackup($0) }
            .sorted()
    }

    /// The cloud folders on this Mac, and those of them Settings > Drives has on. Everything walks each one that is on
    /// as a root of its own, the way it does an internal volume, and leaves out the others. Finding them reads the
    /// disk, so this never runs on the main thread either.
    nonisolated static func cloudRoots() -> (on: [String], all: [String]) {
        let all = CloudStorage.locations().map(\.root.string)
        let off = Set(Defaults[.disabledCloudLocations].map(\.string))
        return (all.filter { !off.contains($0) }, all)
    }

    func toggle() {
        guard available else { return }
        guard proactive else {
            showProPrompt = true
            return
        }
        guard blockedReason == nil else {
            NSSound.beep()
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
        guard available else { return .off }
        guard proactive else { return .needsPro }
        keepWarm()
        if !loading, engine == nil {
            load()
        }
        guard let engine, !loading else { return .loading }
        return .ready(engine, building: building)
    }

    /// Walks everything again, replacing the loaded engine when done, or filling a new one that is searched as it fills.
    /// nil once started, otherwise why it can't.
    func rebuild() -> String? {
        guard available else { return Self.offMessage }
        guard proactive else { return "Everything needs Cling Pro" }
        keepWarm()
        walk(priority: .userInitiated)
        return nil
    }

    /// Follows the `everythingEnabled` setting. Called on every change to it, and right after a change made here, so
    /// whoever changed it reads the new state back at once.
    func applySetting() {
        let on = Defaults[.everythingEnabled]
        guard on != available else { return }
        available = on
        log.info("Everything turned \(on ? "on" : "off")")
        if !on {
            shutDown(saving: true)
        }
    }

    /// Unloads the index and deletes it from disk, stopping a walk that would write it again, and returns the bytes
    /// freed. Whether Everything is on stays as it was: on, its next search walks the local disks again.
    @discardableResult
    func deleteIndex() -> Int {
        let freed = savedBytes
        shutDown(saving: false)
        Self.deletions.withLock { $0 += 1 }
        Self.diskQueue.async {
            try? FileManager.default.removeItem(at: everythingFolder.url)
            Task { @MainActor in INDEX_SIZES.refresh() }
        }
        INDEX_SIZES.forget(everythingIndexFile)
        log.info("Everything index deleted, \(freed) bytes")
        FUZZY.logActivity("Everything index deleted")
        return freed
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

    /// A cloud account came or went.
    func cloudFoldersChanged() {
        updater?.syncCloud()
    }

    /// Cling listed online-only folders in this cloud folder, filling them in on disk.
    func cloudFolderListed(_ root: String) {
        updater?.syncCloud(listed: root)
    }

    /// FSEvents dropped events or lost its history, so the loaded engine may have missed changes. The updater walks
    /// the folders that changed around a drop again; this walks everything, for what a drop missed elsewhere. A walk
    /// is a minute or more of a core on a big disk, and a busy disk drops events every few minutes, so it runs at most
    /// once an hour: a loss inside the hour waits for the hour to be up.
    func historyLost(in engine: SearchEngine) {
        guard self.engine === engine, !walking else { return }
        if let last = lastLossWalk, Date().timeIntervalSince(last) < Self.lossWalkInterval {
            guard lossWalkTask == nil else { return }
            let wait = Self.lossWalkInterval - Date().timeIntervalSince(last)
            log.info("Everything: change history lost again, walking in \(Int(wait / 60)) min")
            lossWalkTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard let self, !Task.isCancelled else { return }
                lossWalkTask = nil
                guard self.engine != nil, !walking else { return }
                lastLossWalk = Date()
                log.info("Everything: walking again for change history lost within the hour")
                walk(priority: .utility)
            }
            return
        }
        lastLossWalk = Date()
        log.info("Everything: change history lost, walking again")
        walk(priority: .utility)
    }

    private static let lossWalkInterval: TimeInterval = 60 * 60

    /// Writes and deletions of the index files, one at a time and in order.
    private nonisolated static let diskQueue = DispatchQueue(label: "com.lowtechguys.Cling.everythingDisk", qos: .utility)
    /// How many times the index was deleted. A save scheduled before a deletion leaves the files alone.
    private nonisolated static let deletions = OSAllocatedUnfairLock(initialState: 0)

    @ObservationIgnored private var unloadTask: Task<Void, Never>?
    @ObservationIgnored private var updater: EverythingUpdater?
    @ObservationIgnored private var stream: FSChangeStream?
    @ObservationIgnored private let streamQueue = DispatchQueue(label: "com.lowtechguys.Cling.everythingStream", qos: .utility)
    @ObservationIgnored private var lastBuildSearch: CFAbsoluteTime = 0
    @ObservationIgnored private var volumeObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var drivesObserver: AnyCancellable?
    @ObservationIgnored private var cloudObserver: AnyCancellable?
    /// What the loaded engine reflects, and how many paths changed since it was last written to disk.
    @ObservationIgnored private var snapshot: EverythingSnapshot?
    @ObservationIgnored private var lastEventID: UInt64 = 0
    @ObservationIgnored private var unsavedChanges = 0
    /// When a lost history last walked everything, and the walk waiting for the hour to be up.
    @ObservationIgnored private var lastLossWalk: Date?
    @ObservationIgnored private var lossWalkTask: Task<Void, Never>?
    @ObservationIgnored private var settingObserver: AnyCancellable?
    /// Bumped on every shutdown, so a load or walk started before it can tell its result is no longer wanted.
    @ObservationIgnored private var generation = 0
    /// Set to stop the walk in progress.
    @ObservationIgnored private var walkStop: OSAllocatedUnfairLock<Bool>?

    // MARK: Walking

    /// Each top-level folder of the startup disk walks on its own task, and so does each other internal volume
    /// under /Volumes and each cloud folder that is on. No ignore rules, `.git` folders and `.DS_Store` files stay in,
    /// and entries are appended without a duplicate check.
    private nonisolated static func walkEverything(
        into engine: SearchEngine, volumes: [String], cloud: (on: [String], all: [String]), stop: OSAllocatedUnfairLock<Bool>,
        progress: @escaping @Sendable () -> Void
    ) async {
        let (roots, topLevel) = startupDiskRoots()
        for (path, isDir) in topLevel {
            engine.appendPath(path, isDir: isDir)
        }
        for root in volumes + cloud.on {
            engine.appendPath(root, isDir: true)
        }
        let cloudFolders = Set(cloud.all)
        await withTaskGroup(of: Void.self) { group in
            for root in roots + volumes + cloud.on {
                group.addTask {
                    engine.walkDirectory(
                        root,
                        // The data volume shows up a second time in here; its folders are already at /. Cloud folders
                        // walk on their own.
                        skipDir: { $0 == "/System/Volumes" || cloudFolders.contains($0) },
                        skipGitDirs: false,
                        skipJunkFiles: false,
                        dedupe: false,
                        progress: { _, _ in progress() },
                        cancelled: { stop.withLock { $0 } }
                    )
                }
            }
        }
    }

    /// The startup disk's top-level entries, with every folder a walk root. A walk never leaves the disk it starts
    /// on, which keeps /dev and other mounts out; /Volumes is left unwalked since stat on a stalled network share
    /// there can hang, and its internal volumes are walked as their own roots.
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

    /// Stops all of it at once: the walk in progress, a load, following changes and the timers. The engine goes too,
    /// saved first when `saving` and that is worth it. A walk stopped part way is never saved.
    private func shutDown(saving: Bool) {
        generation += 1
        walkStop?.withLock { $0 = true }
        walkStop = nil
        unloadTask?.cancel()
        unloadTask = nil
        lossWalkTask?.cancel()
        lossWalkTask = nil
        let wasEnabled = enabled
        let firstBuild = building
        enabled = false
        loading = false
        walking = false
        building = false
        showProPrompt = false
        stopWatching()
        if let engine {
            if saving, !firstBuild {
                saveIfWorthIt(engine)
            } else {
                releaseInBackground(engine)
            }
        }
        engine = nil
        count = 0
        if wasEnabled {
            FUZZY.everythingChanged()
        }
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
        let pending = snapshot
        let url = everythingIndexFile.url
        let deletions = Self.deletions.withLock { $0 }
        Task.detached(priority: .background) {
            var saved = pending
            saved.volumes = Self.internalVolumes()
            Self.diskQueue.sync {
                guard Self.deletions.withLock({ $0 }) == deletions else { return }
                engine.saveBinaryIndex(to: url)
                saved.write()
            }
            await MainActor.run { INDEX_SIZES.refresh() }
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
        let gen = generation
        Task.detached(priority: .userInitiated) {
            let t0 = CFAbsoluteTimeGetCurrent()
            let engine = SearchEngine()
            let loaded = engine.loadBinaryIndex(from: url)
            log.info("Everything load: \(engine.count) entries in \(CFAbsoluteTimeGetCurrent() - t0, format: .fixed(precision: 2))s")
            // Disks unplugged since it was saved leave now. Disks plugged in since are walked once it is searchable,
            // the way one plugged in while it is loaded is: walking a big one first kept it "loading" for as long as
            // the walk took, and searches waiting on it gave up.
            var kept = saved.volumes
            var added: [String] = []
            if loaded {
                let now = Self.internalVolumes()
                let gone = saved.volumes.filter { !now.contains($0) }
                if !gone.isEmpty {
                    engine.removeSubtrees(gone)
                }
                kept = saved.volumes.filter { now.contains($0) }
                added = now.filter { !saved.volumes.contains($0) }
            }
            await MainActor.run {
                // Turned off or deleted while it loaded.
                guard self.generation == gen else { return }
                self.loading = false
                guard loaded else {
                    self.walk(priority: .userInitiated)
                    return
                }
                self.snapshot = saved
                self.lastEventID = saved.eventID
                self.unsavedChanges = 0
                self.install(engine)
                self.startWatching(since: saved.eventID, volumes: kept, cloud: ([], []))
                for volume in added {
                    self.updater?.addVolume(volume)
                }
                // What Cling listed in a cloud folder while this was unloaded isn't sure to come back as file changes, so
                // each cloud folder is walked again, and one turned off since it was saved leaves.
                self.updater?.syncCloud(fresh: true)
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
        walked = 0
        // This walk picks up whatever a drop before it missed.
        lossWalkTask?.cancel()
        lossWalkTask = nil
        // Changes made from here on are replayed on top of this walk once it is watched.
        let start = EverythingSnapshot.current
        let fresh = SearchEngine()
        if engine == nil {
            building = true
            install(fresh)
        }
        let url = everythingIndexFile.url
        let gen = generation
        let stop = OSAllocatedUnfairLock(initialState: false)
        walkStop = stop
        Task.detached(priority: priority) {
            var snapshot = start
            snapshot.volumes = Self.internalVolumes()
            let started = snapshot
            let cloud = Self.cloudRoots()
            let t0 = CFAbsoluteTimeGetCurrent()
            let began = Date()
            await Self.walkEverything(into: fresh, volumes: started.volumes, cloud: cloud, stop: stop) {
                Task { @MainActor in
                    guard self.generation == gen else { return }
                    if self.walking {
                        self.walked = fresh.count
                    }
                    self.applied(to: fresh)
                }
            }
            let walked = CFAbsoluteTimeGetCurrent()
            // Turned off or deleted while it walked: what it has is partial, and none of it is kept.
            let saved = Self.diskQueue.sync { () -> Bool in
                guard !stop.withLock({ $0 }) else { return false }
                try? FileManager.default.createDirectory(at: everythingFolder.url, withIntermediateDirectories: true)
                fresh.saveBinaryIndex(to: url)
                started.write()
                return true
            }
            guard saved else {
                log.info("Everything walk stopped")
                return
            }
            let n = fresh.count
            log.info("Everything walk: \(n) entries in \(walked - t0, format: .fixed(precision: 1))s, saved in \(CFAbsoluteTimeGetCurrent() - walked, format: .fixed(precision: 1))s")

            // Reloading the saved file sheds the walk's growth slack, over half its memory at this size, like the
            // scope walks do. That includes the first build, which swaps the engine on show for its reloaded copy.
            let wanted = await MainActor.run { self.generation == gen && self.engine != nil }
            var finished = fresh
            if wanted {
                let reloaded = SearchEngine()
                if reloaded.loadBinaryIndex(from: url) {
                    finished = reloaded
                }
            }
            let engine = finished
            await MainActor.run {
                INDEX_SIZES.refresh()
                guard self.generation == gen else { return }
                self.walkStop = nil
                self.walking = false
                self.building = false
                self.walked = n
                IndexWalks.record(.everything, started: began)
                FUZZY.logActivity("Everything indexed: \(n.formatted()) files")
                guard self.engine != nil else { return }
                self.stopWatching()
                self.snapshot = started
                self.lastEventID = started.eventID
                self.unsavedChanges = 0
                self.install(engine)
                self.startWatching(since: started.eventID, volumes: started.volumes, cloud: cloud)
            }
        }
    }

    // MARK: Live updates

    /// Replays every change since `since` (FSEvents keeps the history), then follows along until unloaded. `volumes`
    /// are the disks the engine already holds.
    private func startWatching(since: UInt64, volumes: [String], cloud: (on: [String], all: [String])) {
        guard let engine else { return }
        let updater = EverythingUpdater(engine: engine, volumes: volumes, cloud: cloud)
        self.updater = updater
        // Changes arrive a few seconds late, in fewer and larger batches.
        stream = FSChangeStream(paths: ["/"], since: since, latency: EverythingUpdater.latency, queue: streamQueue) { events in
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
        drivesObserver = nil
        cloudObserver = nil
    }

    /// A disk plugged in or turned on in Settings > Drives while loaded is walked into the engine; one ejected or
    /// turned off leaves it. The saved index learns about either when it is next loaded.
    private func watchVolumes(_ updater: EverythingUpdater) {
        let center = NSWorkspace.shared.notificationCenter
        volumeObservers = [
            center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: nil) { note in
                guard let path = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path, path.hasPrefix("/Volumes/") else { return }
                updater.addVolume(path)
            },
            center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: nil) { note in
                guard let path = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path, path.hasPrefix("/Volumes/") else { return }
                updater.removeVolume(path)
            },
        ]
        drivesObserver = Defaults.publisher(.disabledVolumes, options: []).sink { _ in updater.syncVolumes() }
        cloudObserver = Defaults.publisher(.disabledCloudLocations, options: []).sink { _ in updater.syncCloud() }
    }

}

@MainActor let EVERYTHING = EverythingIndex.shared

// MARK: - EverythingUpdater

/// Applies file system events to a loaded Everything engine in batches, on its own background queue, so the
/// normal index's watcher and the main thread never wait on it.
final class EverythingUpdater: @unchecked Sendable {
    init(engine: SearchEngine, volumes: [String], cloud: (on: [String], all: [String])) {
        self.engine = engine
        self.volumes = Set(volumes)
        self.cloud = Set(cloud.on)
        cloudOff = cloud.all.filter { !cloud.on.contains($0) }
    }

    /// Changes arrive a few seconds late, in fewer and larger batches.
    static let latency: CFTimeInterval = 3

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

    /// Takes any disk mounted under /Volumes and keeps it only if `internalVolumes` would, checked here on the
    /// updater's queue since that reads the disk.
    func addVolume(_ path: String) {
        queue.async { [self] in
            guard !volumes.contains(path), EverythingIndex.internalVolumes().contains(path) else { return }
            volumes.insert(path)
            engine.appendPath(path, isDir: true)
            engine.walkDirectory(path, skipGitDirs: false, skipJunkFiles: false, dedupe: false)
            notify(eventID: 0, changes: 1)
        }
    }

    /// Settings > Drives changed: a volume turned off leaves the engine, one turned back on is walked into it.
    func syncVolumes() {
        queue.async { [self] in
            let now = Set(EverythingIndex.internalVolumes())
            let off = volumes.subtracting(now)
            if !off.isEmpty {
                volumes.subtract(off)
                engine.removeSubtrees(Array(off))
            }
            let on = now.subtracting(volumes).sorted()
            for path in on {
                volumes.insert(path)
                engine.appendPath(path, isDir: true)
                engine.walkDirectory(path, skipGitDirs: false, skipJunkFiles: false, dedupe: false)
            }
            if !off.isEmpty || !on.isEmpty {
                notify(eventID: 0, changes: off.count + on.count)
            }
        }
    }

    /// Brings the cloud folders in line with Settings > Drives and the accounts on this Mac: one turned off leaves the
    /// engine and one turned on is walked into it. `listed` is walked again, after Cling filled in folders there that
    /// were online only. `fresh` walks them all again, for an engine loaded from disk, which holds them as they were
    /// when it was saved.
    func syncCloud(fresh: Bool = false, listed: String? = nil) {
        queue.async { [self] in
            let (on, all) = EverythingIndex.cloudRoots()
            let now = Set(on)
            cloudOff = all.filter { !now.contains($0) }
            var walk = fresh ? now : now.subtracting(cloud)
            if let listed, now.contains(listed) {
                walk.insert(listed)
            }
            // What is walked replaces what the engine had there: an account added since the last walk was walked as
            // a plain folder.
            let remove = (fresh ? Set(all) : cloud.subtracting(now)).union(walk)
            cloud = now
            guard !remove.isEmpty else { return }
            // Walked on the side and swapped in, so searches meanwhile still find the files from before.
            let walked = SearchEngine()
            for root in walk.sorted() {
                walked.appendPath(root, isDir: true)
                walked.walkDirectory(root, skipGitDirs: false, skipJunkFiles: false, dedupe: false)
            }
            engine.removeSubtrees(Array(remove))
            engine.appendEntries(of: walked)
            notify(eventID: 0, changes: remove.count)
        }
    }

    func removeVolume(_ path: String) {
        queue.async { [self] in
            guard volumes.remove(path) != nil else { return }
            engine.removeSubtrees([path])
            notify(eventID: 0, changes: 1)
        }
    }

    /// How long before and after a drop the folders that changed are walked again: two of the stream's deliveries.
    private static let lossRescanWindow = 2 * latency
    /// How long the changes must stay quiet before the collected folders are walked, longer than a delivery takes.
    private static let lossRescanQuiet = latency + 1
    /// The longest the walk waits for quiet, through changes that keep coming.
    private static let lossRescanLongest: CFAbsoluteTime = 30
    /// The most entries a folder can hold and still be walked again whole after a drop. A file written in the home
    /// folder during a burst makes it one of the folders that changed, and walking it whole is most of the disk.
    private static let lossRescanWholeMax = 100_000

    private let engine: SearchEngine
    private let queue = DispatchQueue(label: "com.lowtechguys.Cling.everything", qos: .utility)
    private var pending: [FSChange] = []
    private var flushScheduled = false
    /// Changes were dropped since this updater started. Only touched on `queue`, like everything below.
    private var lost = false
    /// The folders each recent batch changed, kept for `lossRescanWindow`.
    private var recentBusyFolders: [(at: CFAbsoluteTime, dirs: Set<String>)] = []
    /// Until when the folders each batch changes are collected, after a drop.
    private var rescanBusyFoldersUntil: CFAbsoluteTime = 0
    /// Folders collected around drops, waiting for the changes to go quiet.
    private var lossRescanDirs = Set<String>()
    private var lossRescanSince: CFAbsoluteTime?
    private var lastLossActivity: CFAbsoluteTime = 0
    private var lossRescanScheduled = false
    /// The internal volumes under /Volumes being followed; events from anything else mounted there are ignored.
    private var volumes: Set<String>
    /// The cloud folders that are on, and the ones that are off, whose events are ignored.
    private var cloud: Set<String>
    private var cloudOff: [String]

    /// The folders these changes landed in: a folder's own path, a file's parent. The top of the disk is left out, as
    /// walking it again is the walk of everything a drop asks for already.
    private static func busyFolders(_ flagsByPath: [String: EonilFSEventsEventFlags]) -> Set<String> {
        var dirs = Set<String>()
        // A folder flagged for rescanning is walked for that already, which includes the walks asked for below.
        for (path, flags) in flagsByPath where !flags.contains(.mustScanSubDirs) {
            for dir in FSEventsHistory.changedFolders(path, flags: flags) where dir != "/" {
                dirs.insert(dir)
            }
        }
        return dirs
    }

    private func notify(eventID: UInt64, changes: Int) {
        let engine = engine
        Task { @MainActor in EVERYTHING.applied(to: engine, eventID: eventID, changes: changes) }
    }

    /// Asks for a walk of everything once, and keeps applying what comes after: stopping at the drop left the rest of
    /// the batch out of the engine until that walk was done.
    private func reportLoss() {
        guard !lost else { return }
        lost = true
        let engine = engine
        Task { @MainActor in EVERYTHING.historyLost(in: engine) }
    }

    /// A drop names no folder, only `/`, but what it dropped happened among the changes delivered around it: a burst
    /// too fast for FSEvents, like a big folder written or deleted at once, drops a third of its changes or more. The
    /// folders those changes landed in, just before the drop and for a few seconds after, are walked again once the
    /// changes go quiet, instead of the files waiting up to an hour for the next walk of everything.
    private func collectAroundLoss(_ flagsByPath: [String: EonilFSEventsEventFlags], sawLoss: Bool) {
        let now = CFAbsoluteTimeGetCurrent()
        let busy = Self.busyFolders(flagsByPath)
        recentBusyFolders.removeAll { now - $0.at > Self.lossRescanWindow }
        var dirs = Set<String>()
        if sawLoss {
            rescanBusyFoldersUntil = now + Self.lossRescanWindow
            for recent in recentBusyFolders {
                dirs.formUnion(recent.dirs)
            }
        }
        if now < rescanBusyFoldersUntil {
            dirs.formUnion(busy)
        }
        if !busy.isEmpty {
            recentBusyFolders.append((now, busy))
        }
        guard !dirs.isEmpty || sawLoss else { return }
        lossRescanDirs.formUnion(dirs)
        lossRescanSince = lossRescanSince ?? now
        lastLossActivity = now
        scheduleLossRescan()
    }

    /// Walks the folders collected around drops once nothing has changed for `lossRescanQuiet`, or after
    /// `lossRescanLongest` of changes that never stop.
    private func scheduleLossRescan() {
        guard !lossRescanScheduled else { return }
        lossRescanScheduled = true
        queue.asyncAfter(deadline: .now() + Self.lossRescanQuiet) { [self] in
            lossRescanScheduled = false
            let now = CFAbsoluteTimeGetCurrent()
            let settled = now - lastLossActivity >= Self.lossRescanQuiet && now >= rescanBusyFoldersUntil
            guard settled || now - (lossRescanSince ?? now) >= Self.lossRescanLongest else {
                scheduleLossRescan()
                return
            }
            let dirs = Array(lossRescanDirs)
            lossRescanDirs.removeAll()
            lossRescanSince = nil
            rescanAroundLoss(dirs)
        }
    }

    /// Walks these folders again whole, like a folder flagged for rescanning. One holding more than
    /// `lossRescanWholeMax` entries only has what sits directly in it brought up to date, and the folders inside it
    /// that changed are walked in its place.
    private func rescanAroundLoss(_ dirs: [String]) {
        var left = dirs
        var whole: [String] = []
        var large: [String] = []
        while !left.isEmpty {
            let outer = FSEventsHistory.outermost(left)
            var big: [String] = []
            for (dir, count) in zip(outer, engine.countsBelow(outer)) {
                if count > Self.lossRescanWholeMax {
                    big.append(dir)
                } else {
                    whole.append(dir)
                }
            }
            large += big
            let prefixes = big.map { $0 + "/" }
            left = left.filter { dir in prefixes.contains { dir.hasPrefix($0) } }
        }
        guard !whole.isEmpty || !large.isEmpty else { return }
        log.info("Everything: walking \(whole.count) folders that changed around dropped events, and the top of \(large.count) large ones")
        apply(whole.map { FSChange(path: $0, flags: [.itemIsDir, .mustScanSubDirs], id: 0) } + large.flatMap(childChanges))
    }

    /// What sits directly in `dir` that the engine has wrong: entries gone from the disk, and ones it never got, which
    /// are walked if they are folders. Flagged for rescanning, so they don't count as folders that changed.
    private func childChanges(of dir: String) -> [FSChange] {
        var st = stat()
        guard lstat(dir, &st) == 0 else {
            return FSEventsHistory.isGone(errno) ? [FSChange(path: dir, flags: [.itemRemoved, .mustScanSubDirs], id: 0)] : []
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        let onDisk = names.map { dir + "/" + $0 }
        let indexed = engine.childCounts(of: dir).map(\.path)
        let onDiskKeys = Set(onDisk.map { $0.lowercased() })
        let indexedKeys = Set(indexed.map { $0.lowercased() })
        let gone = indexed.filter { !onDiskKeys.contains($0.lowercased()) }
            .map { FSChange(path: $0, flags: [.itemRemoved, .mustScanSubDirs], id: 0) }
        let new = onDisk.filter { !indexedKeys.contains($0.lowercased()) }
            .map { FSChange(path: $0, flags: [.itemCreated, .mustScanSubDirs], id: 0) }
        return gone + new
    }

    /// One pass over the engine per batch whatever its size: every path that went away or came back is removed
    /// in a single sweep, then whatever exists now is added. A file only modified is already in the index.
    private func apply(_ events: [FSChange]) {
        let t0 = CFAbsoluteTimeGetCurrent()
        var flagsByPath: [String: EonilFSEventsEventFlags] = [:]
        var maxEventID: UInt64 = 0
        var sawLoss = false
        for event in events {
            maxEventID = max(maxEventID, event.id)
            let flags = event.flags
            if FSEventsHistory.lost(flags, path: event.path) {
                reportLoss()
                sawLoss = true
                continue
            }
            guard let path = normalized(event.path) else { continue }
            flagsByPath[path, default: []].formUnion(flags)
        }
        collectAroundLoss(flagsByPath, sawLoss: sawLoss)
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

    /// Anything mounted under /Volumes that isn't an internal volume being followed is left out too, and so is
    /// anything in a cloud folder that is off.
    private func normalized(_ raw: String) -> String? {
        guard let path = FSEventsHistory.normalized(raw) else { return nil }
        if cloudOff.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return nil
        }
        if path.hasPrefix("/Volumes/") {
            let volume = "/Volumes/" + (path.dropFirst("/Volumes/".count).split(separator: "/", maxSplits: 1).first ?? "")
            guard volumes.contains(volume) else { return nil }
        }
        return path
    }
}

// MARK: - cling everything

extension CLIConfig {
    private struct EverythingInfo: Encodable {
        let enabled: Bool
        /// off, unloaded, loading, indexing or ready.
        let state: String
        /// Entries in the loaded index, absent while it is unloaded.
        let entries: Int?
        let savedBytes: Int
        let saved: String?
        var freedBytes: Int?
    }

    /// `cling everything`: status, on, off and delete. On and off change the `everythingEnabled` setting, the one
    /// Settings > Search changes. Delete works whether Everything is on or off, and without Pro, so an index built
    /// during a trial can still be removed.
    /// The saved index's size comes from `INDEX_SIZES`, which `handle` measured off the main thread just before.
    @MainActor static func everything(_ req: ClingRequest) -> ClingResponse {
        let size = IndexStats.diskSize
        var said: String?
        var freed: Int?
        switch req.action ?? "status" {
        case "status":
            break
        case "on":
            Defaults[.everythingEnabled] = true
            EVERYTHING.applySetting()
            said = "Everything is on"
        case "off":
            Defaults[.everythingEnabled] = false
            EVERYTHING.applySetting()
            let bytes = EVERYTHING.savedBytes
            said = bytes > 0
                ? "Everything is off. Its saved index stays on disk (\(size(bytes))): cling everything delete removes it."
                : "Everything is off"
        case "delete":
            let bytes = EVERYTHING.deleteIndex()
            freed = bytes
            said = bytes > 0 ? "Deleted the Everything index, freeing \(size(bytes))" : "There is no Everything index on disk"
        default:
            return ClingResponse(error: "everything takes status, on, off or delete")
        }

        let ev = EVERYTHING
        let loaded = ev.state == "ready" || ev.state == "indexing"
        var info = EverythingInfo(
            enabled: ev.available, state: ev.state, entries: loaded ? ev.count : nil,
            savedBytes: ev.savedBytes, saved: ev.savedBytes > 0 ? size(ev.savedBytes) : nil
        )
        info.freedBytes = freed
        let text = said ?? [
            "everything: " + (ev.available ? "on, \(ev.state)" : "off") + (loaded ? ", \(ev.count.formatted()) entries" : ""),
            "saved index: " + (info.saved ?? "none"),
        ].joined(separator: "\n")
        return ClingResponse(status: text, payload: payloadJSON(info))
    }
}
