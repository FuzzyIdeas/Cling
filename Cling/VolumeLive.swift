import CoreServices
import DiskArbitration
import Foundation
import Lowtech
import OSLog
import System

private let log = Logger(subsystem: clingSubsystem, category: "VolumeLive")

// MARK: - VolumeLiveState

/// Where a drive's saved index stands in the drive's FSEvents history, written beside the index whenever the index is:
/// every change up to `eventID` is in it.
struct VolumeLiveState: Codable, Equatable {
    /// The file system's own UUID. A drive erased and formatted again under the same name gets a new one, and its saved
    /// index describes a drive that no longer exists.
    var volumeUUID: String
    /// FSEvents' UUID for the drive's history, nil while it had none. A different one means the history was thrown away
    /// and started again.
    var historyUUID: String?
    var eventID: UInt64
    /// Changes were made that the index may not hold and the drive's history can't give again: it went away without
    /// being ejected, changes were still arriving when it was let go of, or more were left unapplied than were kept.
    var dirty: Bool?
    /// Why it is dirty, as searching the drive gives it.
    var why: String?
    /// Paths changed that weren't applied yet, with their FSEvents flags, on a drive whose history ends with the mount.
    var missed: [String: UInt32]?

    static func file(_ volume: FilePath) -> URL {
        volumeIndexFile(volume).url.deletingPathExtension().appendingPathExtension("live")
    }

    static func read(_ volume: FilePath) -> Self? {
        guard let data = try? Data(contentsOf: file(volume)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    static func forget(_ volume: FilePath) {
        try? FileManager.default.removeItem(at: file(volume))
    }

    func save(_ volume: FilePath) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.file(volume), options: .atomic)
    }
}

/// Writes a drive's index together with its position, one drive's at a time, so a walk finishing and a save of the
/// engine it replaced can't leave the newer index beside the older position, or the other way around.
let volumeSaveQueue = DispatchQueue(label: "com.lowtechguys.Cling.volumeSave", qos: .utility)

// MARK: - MountedVolume

/// What a mounted drive is, read from the disk, so never on the main thread: a stalled drive can take tens of seconds
/// to answer.
struct MountedVolume: Sendable {
    let device: dev_t
    let fsType: String
    let isLocal: Bool
    let volumeUUID: String
    let historyUUID: String?

    /// Whether FSEvents keeps the drive's history past an unmount, so the next mount can replay what changed. exFAT and
    /// FAT drives start a new history every time they are mounted.
    var keepsHistory: Bool {
        fsType == "apfs" || fsType == "hfs"
    }

    /// Nil when nothing is mounted at the drive's own path, which a drive that just went leaves as a plain folder or
    /// nothing at all.
    static func read(_ volume: FilePath) -> Self? {
        var fs = statfs()
        guard statfs(volume.string, &fs) == 0 else { return nil }
        let mountedOn = withUnsafeBytes(of: &fs.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        guard mountedOn == volume.string else { return nil }
        let type = withUnsafeBytes(of: &fs.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        var st = stat()
        guard stat(volume.string, &st) == 0 else { return nil }
        return Self(
            device: st.st_dev,
            fsType: type,
            isLocal: fs.f_flags & UInt32(MNT_LOCAL) != 0,
            volumeUUID: (try? volume.url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString ?? "",
            historyUUID: historyUUID(of: st.st_dev)
        )
    }

    /// Asks fseventsd, not the disk.
    static func historyUUID(of device: dev_t) -> String? {
        FSEventsCopyUUIDForDevice(device).map { CFUUIDCreateString(nil, $0) as String }
    }

    /// The position to save with the index. The history's UUID is asked for again: a drive often has none until the
    /// first change after it is mounted.
    func state(_ position: FollowedPosition) -> VolumeLiveState {
        VolumeLiveState(
            volumeUUID: volumeUUID, historyUUID: Self.historyUUID(of: device) ?? historyUUID, eventID: position.eventID,
            dirty: position.dirty != nil ? true : nil, why: position.dirty, missed: position.missed?.isEmpty == false ? position.missed : nil
        )
    }
}

// MARK: - FollowedPosition

/// Where a followed drive's index stands, turned into a `VolumeLiveState` off the main thread.
struct FollowedPosition: Sendable {
    let mounted: MountedVolume
    let eventID: UInt64
    /// Why the index may hold less than the drive's history can give again, nil when it doesn't.
    let dirty: String?
    let missed: [String: UInt32]?
}

// MARK: - VolumeCatchUp

/// How a drive that was just mounted, or found mounted at launch, gets its index current before following it.
enum VolumeCatchUp: Equatable {
    /// Replays the drive's history from the saved position, and checks the paths that changed without being applied
    /// before it went: only what changed is read from the drive.
    case replay(UInt64, missed: [String: UInt32])
    /// Follows changes from now on, with no saved position to replay from, or none that means anything any more. The
    /// index is as current as its last walk, which the drive's reindex interval keeps it to.
    case live

    /// A drive taken to another Mac and written to there comes back with a history that leaves those changes out, and
    /// with nothing that says so: its UUID reads as unset until this Mac changes something on it, then as it was before
    /// it left. Those changes are found by the drive's next walk, as they were before drives were followed at all.
    static func plan(saved: VolumeLiveState?, mounted: MountedVolume) -> Self {
        guard let saved, saved.eventID > 0 else { return .live }
        if !saved.volumeUUID.isEmpty, !mounted.volumeUUID.isEmpty, saved.volumeUUID != mounted.volumeUUID {
            return .live
        }
        if mounted.keepsHistory {
            if let had = saved.historyUUID, let has = mounted.historyUUID, had != has {
                return .live
            }
            return .replay(saved.eventID, missed: [:])
        }
        // exFAT and FAT keep a history only since the mount, under a UUID of its own, and only in memory, where the
        // oldest of it goes first: a replay gives what is left with nothing to say what isn't. On the same mount that
        // is whatever changed since, which a menubar app away for a moment leaves little of.
        if let had = saved.historyUUID, had == mounted.historyUUID {
            return .replay(saved.eventID, missed: [:])
        }
        return .replay(saved.eventID, missed: saved.missed ?? [:])
    }

    /// Why the saved index may be missing changes that no replay gives back, which only a walk would find. Nothing
    /// walks the drive for it: a drive can hold millions of files behind a slow connection, and searching it offers
    /// the walk instead (`FuzzyClient.volumesNeedingWalk`).
    static func walkNeeded(saved: VolumeLiveState?, mounted: MountedVolume) -> String? {
        guard let saved, saved.eventID > 0 else { return nil }
        if !saved.volumeUUID.isEmpty, !mounted.volumeUUID.isEmpty, saved.volumeUUID != mounted.volumeUUID {
            return "formatted again"
        }
        if mounted.keepsHistory {
            if let had = saved.historyUUID, let has = mounted.historyUUID, had != has {
                return "change history started over"
            }
            // Pulled out, FSEvents may not have written its last changes to the drive.
            return saved.dirty == true ? saved.why ?? "unplugged without being ejected" : nil
        }
        // One left with more changes than its history holds would find the start of them already gone.
        return saved.dirty == true ? saved.why ?? "unmounted while changes were still arriving" : nil
    }
}

// MARK: - VolumeWatcher

/// Follows one mounted drive's changes into its index, the way the scope indexes follow the Mac's own disk. The drive's
/// stream and its updates run on queues of their own at background priority: a slow or stalled drive holds up only its
/// own updates, and the reads they take give way to everything else on that disk.
final class VolumeWatcher: @unchecked Sendable {
    /// `lostAll`: FSEvents asked for the whole drive to be read again, which it does when it has no history to give.
    init?(
        volume: FilePath, engine: SearchEngine, mounted: MountedVolume, rules: WalkRules, since: UInt64?,
        applied: @escaping @Sendable (LiveIndexBatch) -> Void, lostAll: @escaping @Sendable () -> Void
    ) {
        self.volume = volume
        self.engine = engine
        self.mounted = mounted
        startID = since ?? FSEventsGetCurrentEventId()
        let root = volume.string
        let device = mounted.device
        let name = volume.name.string
        let health = DriveHealth.of(root)
        let updater = LiveIndexUpdater(
            routes: [LiveRoute(scope: nil, root: root, excludePrefix: nil, engine: engine, rules: rules)],
            replaying: since != nil,
            label: "com.lowtechguys.Cling.volume",
            qos: .background,
            available: {
                var st = stat()
                return stat(root, &st) == 0 && st.st_dev == device
            },
            health: health,
            applied: applied,
            caughtUp: { log.info("\(name, privacy: .public): caught up with the drive's history") },
            historyLost: { log.info("\(name, privacy: .public): changes were dropped, walking the folders around them") }
        )
        self.updater = updater
        let queue = DispatchQueue(label: "com.lowtechguys.Cling.volumeStream", qos: .background)
        let released = SharedFlag(false)
        let releasedBusy = SharedFlag(false)
        let vanished = SharedFlag(false)
        let unapplied = UnappliedChanges()
        let unmounted = DispatchSemaphore(value: 0)
        let replayed = SharedFlag(since == nil)
        let keepsHistory = mounted.keepsHistory
        self.released = released
        self.releasedBusy = releasedBusy
        self.vanished = vanished
        self.unapplied = unapplied
        self.unmounted = unmounted
        let metadata = Set(DRIVE_METADATA_FOLDERS)
        guard let stream = FSChangeStream(device: device, root: root, since: since, latency: Self.latency, queue: queue, handler: { events in
            // A replay hands over changes made a while ago, none still on their way.
            let live = replayed.value
            if !live, events.contains(where: { $0.flags.contains(.historyDone) }) {
                replayed.value = true
            }
            let indexable = events.filter { Self.couldBeIndexed($0, root: root, metadata: metadata) }
            unapplied.note(indexable, applied: updater.lastAppliedEventID, live: live)
            if live {
                health.noteChanges(indexable.count)
            }
            // Nothing after this is the drive's: its files are gone, not deleted. An eject lets go of the drive first,
            // so otherwise it was pulled out, or unmounted from under everything.
            if events.contains(where: { $0.flags.contains(.unmount) }) {
                updater.cancel()
                if !released.value {
                    vanished.value = true
                }
                unmounted.signal()
                return
            }
            // Let go of: what still arrives is only noted.
            guard !updater.isCancelled else { return }
            // A drop during a burst carries the dropped flags too, and is made up for by walking the folders around it.
            if events.contains(where: { $0.path == root && $0.flags.contains(.mustScanSubDirs) && $0.flags.isDisjoint(with: [.userDropped, .kernelDropped]) }) {
                lostAll()
            }
            updater.enqueue(events)
        }) else {
            return nil
        }
        self.stream = stream
        // What changed just before an eject, a copy to the drive say, goes in while the drive is still there, so it
        // can be found while the drive is away. FSEvents can run a little behind the writes, most on exFAT and FAT,
        // where it delivers them in bursts: what arrives while a batch is applied is applied too, until a moment
        // passes with nothing new. A drive that hasn't changed for a while has nothing on its way.
        DriveRelease.shared.onRelease(root) { [updater, stream, unapplied] deadline in
            released.value = true
            let recent = CFAbsoluteTimeGetCurrent() - unapplied.lastNoted < 2
            var seen = unapplied.newest
            var quiet = false
            repeat {
                stream.flushNow()
                updater.applyPendingNow()
                updater.drain(timeout: max(0, deadline - CFAbsoluteTimeGetCurrent()))
                if unapplied.newest == seen {
                    if recent {
                        usleep(400_000)
                    }
                    quiet = unapplied.newest == seen
                    if quiet {
                        break
                    }
                }
                seen = unapplied.newest
            } while CFAbsoluteTimeGetCurrent() < deadline
            // Still being written when it had to go: an unmount forced from under a copy. FSEvents drops what it
            // hasn't delivered yet when it does, and on exFAT and FAT nothing gives it again. Changes still arriving
            // say so, and so does an app with a file open on it, since FSEvents can fall quiet for a moment there
            // while one is still writing.
            releasedBusy.value = !quiet && CFAbsoluteTimeGetCurrent() - unapplied.lastNoted < 0.5
                || !keepsHistory && recent && Self.othersHaveFilesOpen(on: root)
            unapplied.markLetGo()
            // Applying reads the drive, and stops here. The stream stays until the unmount comes through, noting what
            // is still on its way, unless it is replaying: that reads the history FSEvents keeps on the drive, which
            // holds the drive open as a walk does.
            updater.cancel()
            if !updater.replay.caughtUp {
                stream.stop(waiting: max(0.2, deadline - CFAbsoluteTimeGetCurrent()))
            }
        }
    }

    /// Changes on a drive are followed a little later than on the Mac's own disk, in fewer and larger batches.
    static let latency: CFTimeInterval = 2

    let volume: FilePath
    let engine: SearchEngine
    let mounted: MountedVolume
    let updater: LiveIndexUpdater

    /// Where the engine stands, and what arrived that isn't in it yet. `settled`: every change made on the drive has
    /// arrived, as it has once the drive's unmount comes through. Otherwise FSEvents may still have had some on their
    /// way, which only a walk finds once the drive's history is gone. `ending`: following stops here. `unwatched`: the
    /// drive stays mounted with nothing noting its changes, which a drive whose history ends with the mount can only
    /// give again until it is unmounted.
    func position(settled: Bool = false, ending: Bool = true, unwatched: Bool = false) -> FollowedPosition {
        let applied = max(startID, updater.lastAppliedEventID)
        // APFS and HFS+ keep their history, and the next mount replays it.
        guard !mounted.keepsHistory else {
            return FollowedPosition(mounted: mounted, eventID: applied, dirty: vanished.value ? "unplugged without being ejected" : nil, missed: nil)
        }
        let missed = unapplied.after(applied)
        // Changes that kept arriving after the drive was let go of were made while it was being unmounted, and a
        // forced unmount drops the ones not delivered yet.
        let unsettled = releasedBusy.value || unapplied.arrivedAfterLetGo || !settled && CFAbsoluteTimeGetCurrent() - unapplied.lastNoted < 5
        let dirty: String? = vanished.value
            ? "unplugged without being ejected"
            : missed == nil || unsettled
                ? "unmounted while changes were still arriving"
                : unwatched ? "live updates were off" : nil
        if let dirty, ending {
            log.info("\(self.volume.string, privacy: .public) may have changes not in its index: \(dirty, privacy: .public)")
        }
        return FollowedPosition(mounted: mounted, eventID: applied, dirty: dirty, missed: missed)
    }

    /// The drive was found gone without being ejected.
    func noteVanished() {
        vanished.value = true
    }

    /// Stops following and hands over where the index stands. A drive being ejected is let go of first, and its
    /// stream kept until its unmount comes through, so what was still on its way is noted for its next mount.
    func finish(unwatched: Bool = false, _ done: @escaping @Sendable (FollowedPosition) -> Void) {
        DriveRelease.shared.onRelease(volume.string, nil)
        updater.cancel()
        guard released.value else {
            stream.stop()
            done(position(unwatched: unwatched))
            return
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            let settled = unmounted.wait(timeout: .now() + 10) == .success
            if !settled {
                log.info("\(self.volume.string, privacy: .public): no unmount came through")
            }
            stream.stop()
            done(position(settled: settled))
        }
    }

    /// Stops at once, on quit.
    func stop() {
        DriveRelease.shared.onRelease(volume.string, nil)
        updater.cancel()
        stream.stop()
    }

    private let startID: UInt64
    private let stream: FSChangeStream
    private let released: SharedFlag
    private let releasedBusy: SharedFlag
    private let vanished: SharedFlag
    private let unapplied: UnappliedChanges
    private let unmounted: DispatchSemaphore

    /// Whether another process has a file open on the drive mounted at `root`. Asks the kernel about every process,
    /// which takes a few tens of milliseconds.
    private static func othersHaveFilesOpen(on root: String) -> Bool {
        var pids = [pid_t](repeating: 0, count: 256)
        let bytes = proc_listpidspath(
            UInt32(PROC_ALL_PIDS), 0, root, UInt32(PROC_LISTPIDSPATH_PATH_IS_VOLUME | PROC_LISTPIDSPATH_EXCLUDE_EVTONLY),
            &pids, Int32(pids.count * MemoryLayout<pid_t>.size)
        )
        guard bytes > 0 else { return false }
        let me = getpid()
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).contains { $0 != me && $0 > 0 }
    }

    /// Whether a change could reach the index: a notice from FSEvents can't, nor a change inside the folders macOS
    /// keeps on every drive, or to the `._` files and `.DS_Store` it writes beside others.
    private static func couldBeIndexed(_ change: FSChange, root: String, metadata: Set<String>) -> Bool {
        guard change.flags.isDisjoint(with: [.historyDone, .mount, .unmount, .rootChanged]), change.path.count > root.count + 1 else {
            return false
        }
        let inside = change.path.dropFirst(root.count + 1)
        if metadata.contains(String(inside.prefix { $0 != "/" })) {
            return false
        }
        let name = inside.split(separator: "/").last ?? inside
        return !name.hasPrefix("._") && name != ".DS_Store"
    }
}

// MARK: - UnappliedChanges

/// The changes that could reach a drive's index, by path, until they are applied. What is left when the drive is
/// ejected, or Cling quits, is applied on the next mount: exFAT and FAT drives can't replay it from their history.
private final class UnappliedChanges: @unchecked Sendable {
    /// Past this many, the drive is walked on its next mount instead.
    static let most = 10000

    var newest: UInt64 {
        lock.withLock { _newest }
    }

    /// When the last change that could reach the index arrived as it was made.
    var lastNoted: CFAbsoluteTime {
        lock.withLock { _lastNoted }
    }

    /// Whether changes arrived after the drive was let go of.
    var arrivedAfterLetGo: Bool {
        lock.withLock { letGoAt.map { _newest > $0 } ?? false }
    }

    /// Notes where the changes stood when the drive was let go of.
    func markLetGo() {
        lock.withLock { letGoAt = _newest }
    }

    /// `live`: the changes were just made, not replayed from the drive's history.
    func note(_ changes: [FSChange], applied: UInt64, live: Bool) {
        guard !changes.isEmpty else { return }
        lock.withLock {
            if live {
                _lastNoted = CFAbsoluteTimeGetCurrent()
            }
            for change in changes {
                let had = byPath[change.path]
                byPath[change.path] = (had.map { $0.flags.union(change.flags) } ?? change.flags, max(had?.id ?? 0, change.id))
                _newest = max(_newest, change.id)
            }
            guard byPath.count > Self.most / 5 else { return }
            byPath = byPath.filter { $0.value.id > applied }
            if byPath.count > Self.most {
                forgotten = max(forgotten, byPath.values.lazy.map(\.id).max() ?? 0)
                byPath.removeAll()
            }
        }
    }

    /// The changes that arrived after `applied`, nil when there were more than were kept.
    func after(_ applied: UInt64) -> [String: UInt32]? {
        lock.withLock {
            guard forgotten <= applied else { return nil }
            return byPath.filter { $0.value.id > applied }.mapValues(\.flags.rawValue)
        }
    }

    private let lock = NSLock()
    private var byPath: [String: (flags: EonilFSEventsEventFlags, id: UInt64)] = [:]
    private var _newest: UInt64 = 0
    private var _lastNoted: CFAbsoluteTime = 0
    private var letGoAt: UInt64?
    private var forgotten: UInt64 = 0
}

/// The rules a drive's walk applies, for checking a single changed path the same way. Reads the drive's `.fsignore`.
func volumeWalkRules(_ volume: FilePath) -> WalkRules {
    let fsignore = volume / ".fsignore"
    let ignoreFile: String? = fsignore.exists ? fsignore.string : nil
    let metadata = driveMetadataFolders(volume)
    return WalkRules(
        walkRoot: volume.string, ignoreFile: ignoreFile, ignoreRoot: nil, skipDir: { metadata.contains($0) },
        applyBlocklist: false, discoverGitignore: false, skipAppleDouble: true
    )
}

// MARK: - WalkWatch

/// What changes on a drive while it is walked, for a drive whose history lives only in memory (exFAT, FAT). That
/// history keeps only the latest changes, so replaying what changed during a long walk under a copy gives the end of
/// it, with nothing to say the start is gone. The folders that change are noted as they do instead, and walked again
/// once the walk is done.
final class WalkWatch: @unchecked Sendable {
    init?(volume: FilePath, device: dev_t, since: UInt64) {
        let root = volume.string
        let changed = ChangedFolders(root: root)
        let queue = DispatchQueue(label: "com.lowtechguys.Cling.walkWatch", qos: .background)
        guard let stream = FSChangeStream(device: device, root: root, since: since, latency: VolumeWatcher.latency, queue: queue, handler: { events in
            changed.note(events)
        }) else {
            return nil
        }
        self.stream = stream
        self.changed = changed
    }

    /// Stops, and gives the paths to walk again: the outermost folders that changed. Nil when changes were dropped or
    /// more folders changed than are kept, since then nothing says where, and only the whole drive walked again would.
    func finish() -> [String]? {
        stream.stop()
        return changed.toWalk()
    }

    private final class ChangedFolders: @unchecked Sendable {
        init(root: String) {
            self.root = root
        }

        /// Past this many, the drive is left needing a walk instead.
        static let most = 20000

        func note(_ events: [FSChange]) {
            lock.withLock {
                for event in events where event.flags.isDisjoint(with: [.historyDone, .mount, .unmount]) {
                    if FSEventsHistory.lost(event.flags, path: event.path) || event.path == root && event.flags.contains(.mustScanSubDirs) {
                        lostTrack = true
                        continue
                    }
                    guard !lostTrack, event.path.hasPrefix(root + "/"),
                          !metadata.contains(String(event.path.dropFirst(root.count + 1).prefix { $0 != "/" }))
                    else { continue }
                    // Something at the top of the drive is walked on its own, not the whole drive with it.
                    for dir in FSEventsHistory.changedFolders(event.path, flags: event.flags) {
                        folders.insert(dir == root ? event.path : dir)
                    }
                    if folders.count > Self.most {
                        lostTrack = true
                        folders.removeAll()
                    }
                }
            }
        }

        func toWalk() -> [String]? {
            let (lost, folders) = lock.withLock { (lostTrack, folders) }
            return lost ? nil : FSEventsHistory.outermost(Array(folders))
        }

        private let root: String
        private let metadata = Set(DRIVE_METADATA_FOLDERS)
        private let lock = NSLock()
        private var folders = Set<String>()
        private var lostTrack = false
    }

    private let stream: FSChangeStream
    private let changed: ChangedFolders
}

// MARK: - DriveQuiet

/// Tells when a drive has gone `after` seconds without a change, once, for a walk nobody asked for to start then.
final class DriveQuiet: @unchecked Sendable {
    init?(volume: FilePath, device: dev_t, then: @escaping @Sendable () -> Void) {
        let queue = DispatchQueue(label: "com.lowtechguys.Cling.driveQuiet", qos: .background)
        let changed = Changed()
        guard let stream = FSChangeStream(device: device, root: volume.string, since: nil, latency: VolumeWatcher.latency, queue: queue, handler: { _ in
            changed.now()
        }) else {
            return nil
        }
        self.stream = stream
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.after, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self, changed.quietFor >= Self.after else { return }
            cancel()
            then()
        }
        self.timer = timer
        timer.resume()
    }

    static let after: TimeInterval = 60

    func cancel() {
        let first = lock.withLock {
            defer { cancelled = true }
            return !cancelled
        }
        guard first else { return }
        timer.cancel()
        stream.stop()
    }

    private final class Changed: @unchecked Sendable {
        var quietFor: TimeInterval {
            CFAbsoluteTimeGetCurrent() - lock.withLock { last }
        }

        func now() {
            lock.withLock { last = CFAbsoluteTimeGetCurrent() }
        }

        private let lock = NSLock()
        private var last = CFAbsoluteTimeGetCurrent()
    }

    private let stream: FSChangeStream
    private var timer: DispatchSourceTimer!
    private let lock = NSLock()
    private var cancelled = false
}

// MARK: - DriveWalksNeeded

/// The drives whose indexes may be missing changes only a walk would find, with why, beside the indexes.
enum DriveWalksNeeded {
    static let file = indexFolder / "drive-walks-needed.json"

    static func read() -> [FilePath: String] {
        guard let data = try? Data(contentsOf: file.url), let drives = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: drives.compactMap { path, reason in path.filePath.map { ($0, reason) } })
    }

    static func save(_ drives: [FilePath: String]) {
        let drives = Dictionary(uniqueKeysWithValues: drives.map { ($0.key.string, $0.value) })
        guard let data = try? JSONEncoder().encode(drives) else { return }
        try? data.write(to: file.url, options: .atomic)
    }
}

// MARK: - DriveRelease

/// Lets go of a drive before it is unmounted, however the unmount was asked for (Finder, `diskutil`, another app): a walk
/// still reading the drive holds it open, and the eject fails with the drive in use.
///
/// DiskArbitration asks before every unmount and waits for the answer. The answer comes from a queue of its own, never
/// the main thread, so a busy Cling can't hold up an eject: what reads the drive stops there, and the rest of the
/// bookkeeping follows on the main thread.
final class DriveRelease: @unchecked Sendable {
    static let shared = DriveRelease()

    /// The longest an eject is held up while a walk lets go of the drive. A read stuck on a failing drive can't be
    /// interrupted, and the eject then goes ahead and reports the drive busy, as it would without Cling.
    static let longestWait: TimeInterval = 3

    /// `handler` is told, on the main thread, the mount point of each drive being let go of.
    func start(_ handler: @escaping @MainActor (FilePath) -> Void) {
        guard session == nil, let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session
        self.handler = handler
        DASessionSetDispatchQueue(session, queue)
        DARegisterDiskUnmountApprovalCallback(session, nil, { disk, _ in
            guard let description = DADiskCopyDescription(disk) as NSDictionary?,
                  let url = description[kDADiskDescriptionVolumePathKey] as? URL
            else { return nil }
            DriveRelease.shared.release(url.path)
            return nil
        }, nil)
    }

    func isReleasing(_ volume: String) -> Bool {
        lock.withLock { releasing.contains(volume) }
    }

    /// Called once the drive is gone, or found still mounted after an unmount that didn't happen.
    func forget(_ volume: String) {
        lock.withLock { _ = releasing.remove(volume) }
    }

    /// What stops the drive's live updates, and waits for the one in progress.
    /// `stop` is given the time by which the drive must be let go of.
    func onRelease(_ volume: String, _ stop: (@Sendable (CFAbsoluteTime) -> Void)?) {
        lock.withLock { stops[volume] = stop }
    }

    /// Counts a walk reading the drive, which an unmount waits for once it has been told to stop.
    func startReading(_ volume: String) {
        lock.withLock { readers[volume, default: 0] += 1 }
    }

    func stopReading(_ volume: String) {
        lock.withLock { readers[volume] = max(0, (readers[volume] ?? 1) - 1) }
    }

    private let queue = DispatchQueue(label: "com.lowtechguys.Cling.driveRelease", qos: .userInitiated)
    private let lock = NSLock()
    private var releasing: Set<String> = []
    private var readers: [String: Int] = [:]
    private var stops: [String: @Sendable (CFAbsoluteTime) -> Void] = [:]
    private var session: DASession?
    private var handler: (@MainActor (FilePath) -> Void)?

    private func release(_ volume: String) {
        let (stop, walking) = lock.withLock {
            releasing.insert(volume)
            return (stops[volume], (readers[volume] ?? 0) > 0)
        }
        // Every unmount comes through here, Time Machine's snapshots included. One nothing was reading is still held
        // a while, so nothing starts reading it as it goes.
        guard stop != nil || walking else {
            queue.asyncAfter(deadline: .now() + 60) { self.forget(volume) }
            return
        }
        let started = CFAbsoluteTimeGetCurrent()
        stop?(started + Self.longestWait)
        while lock.withLock({ (readers[volume] ?? 0) > 0 }), CFAbsoluteTimeGetCurrent() - started < Self.longestWait {
            usleep(20000)
        }
        let held = CFAbsoluteTimeGetCurrent() - started
        log.info("Let go of \(volume, privacy: .public) for its unmount in \(Int(held * 1000))ms")
        DriveHealth.of(volume).noteEject(held)
        let handler = handler
        DispatchQueue.main.async {
            MainActor.assumeIsolated { handler?(FilePath(volume)) }
        }
    }
}

// MARK: - Following drives

extension FuzzyClient {
    /// The drives followed live: enabled, mounted and indexed, with Pro, which is what searches them, unless their live
    /// updates were turned off. A drive being walked is followed again once the walk is done, from where it started.
    func syncVolumeFollowing() {
        let mounted = Set(externalVolumes)
        let wanted: Set<FilePath> = proactive
            ? Set(enabledVolumes.filter {
                mounted.contains($0) && volumeEngines[$0] != nil && !volumesIndexing.contains($0) && !unfollowedVolumes.contains($0)
                    && !networkVolumes.contains($0) && !DriveRelease.shared.isReleasing($0.string)
            })
            : []
        for volume in volumeWatchers.keys where !wanted.contains(volume) {
            let stillMounted = mounted.contains(volume)
            stopFollowing(volume, vanished: !stillMounted, unwatched: stillMounted && !DriveRelease.shared.isReleasing(volume.string))
        }
        for volume in wanted where volumeWatchers[volume] == nil {
            followVolume(volume)
        }
    }

    /// Starts following a drive. `walkedFrom`: a walk just indexed it from that event on, and the changes made while it
    /// ran are replayed onto it. `walkAgain`: what changed during that walk on a drive whose history can't give it all
    /// back, walked again. Otherwise the drive catches up as `VolumeCatchUp.plan` decides.
    func followVolume(_ volume: FilePath, walkedFrom: UInt64? = nil, walkAgain: [String] = []) {
        guard proactive, volumeWatchers[volume] == nil, !volumesStartingToFollow.contains(volume), let engine = volumeEngines[volume],
              !unfollowedVolumes.contains(volume), !DriveRelease.shared.isReleasing(volume.string)
        else { return }
        volumesStartingToFollow.insert(volume)
        Task.detached(priority: .background) {
            let mounted = MountedVolume.read(volume)
            // After the save the drive's last unmount queued, if it is still going.
            let saved = mounted?.isLocal == true && walkedFrom == nil ? volumeSaveQueue.sync { VolumeLiveState.read(volume) } : nil
            let plan: VolumeCatchUp? = mounted.flatMap { mounted in
                guard mounted.isLocal else { return nil }
                return walkedFrom.map { .replay($0, missed: [:]) } ?? VolumeCatchUp.plan(saved: saved, mounted: mounted)
            }
            let walkNeeded = mounted.flatMap { VolumeCatchUp.walkNeeded(saved: saved, mounted: $0) }
            let rules = plan != nil ? volumeWalkRules(volume) : nil
            await MainActor.run {
                self.volumesStartingToFollow.remove(volume)
                guard let mounted, let plan, let rules else {
                    if mounted?.isLocal == false {
                        log.info("\(volume.string, privacy: .public) is a network share, which FSEvents doesn't report changes on")
                    }
                    return
                }
                // Anything could have happened meanwhile: an unmount, a walk, the drive turned off.
                guard proactive, self.volumeEngines[volume] === engine, self.enabledVolumes.contains(volume),
                      self.externalVolumes.contains(volume), !self.volumesIndexing.contains(volume), self.volumeWatchers[volume] == nil,
                      !self.unfollowedVolumes.contains(volume), !DriveRelease.shared.isReleasing(volume.string)
                else { return }

                if let walkNeeded {
                    self.noteWalkNeeded(volume, walkNeeded)
                }
                let since: UInt64?
                var missed: [String: UInt32] = [:]
                switch plan {
                case let .replay(id, missedPaths):
                    since = id
                    missed = missedPaths
                case .live:
                    since = nil
                }
                guard let watcher = VolumeWatcher(volume: volume, engine: engine, mounted: mounted, rules: rules, since: since, applied: { batch in
                    self.fsEventsQueue.async { self.followIndexChanges(batch) }
                }, lostAll: {
                    Task { @MainActor in self.volumeHistoryLost(volume) }
                }) else {
                    log.error("Could not follow changes on \(volume.string, privacy: .public)")
                    return
                }
                self.volumeWatchers[volume] = watcher
                if !walkAgain.isEmpty {
                    log.info("\(volume.string, privacy: .public): walking \(walkAgain.count) folders that changed during its walk")
                    watcher.updater.rescan(walkAgain)
                }
                if !missed.isEmpty {
                    log.info("\(volume.string, privacy: .public): checking \(missed.count) paths that changed while it wasn't followed")
                    watcher.updater.enqueue(missed.map { FSChange(path: $0.key, flags: EonilFSEventsEventFlags(rawValue: $0.value), id: 0) })
                }
                log.info("Following \(volume.string, privacy: .public) (\(mounted.fsType, privacy: .public)) \(since.map { "from \($0)" } ?? "from now", privacy: .public)")
            }
        }
    }

    /// Stops following a drive and writes its index with where it stands, so the next mount picks up from there.
    /// `vanished`: the drive went away without being ejected. `unwatched`: it stays mounted and isn't followed.
    func stopFollowing(_ volume: FilePath, save: Bool = true, vanished: Bool = false, unwatched: Bool = false) {
        guard let watcher = volumeWatchers.removeValue(forKey: volume) else { return }
        if vanished {
            watcher.noteVanished()
        }
        let engine = watcher.engine
        // The position is taken before the engine is written: it holds at least every change up to there. A drive
        // that isn't being ejected hands it over at once, so the save is queued ahead of a walk that replaces it.
        watcher.finish(unwatched: unwatched) { position in
            guard save else { return }
            volumeSaveQueue.async {
                Self.saveVolume(volume, engine: engine, position: position)
            }
        }
    }

    /// The index file and the position beside it, on `volumeSaveQueue`. An empty index is written only over one that
    /// had files: a drive with nothing on it has nothing to search.
    nonisolated static func saveVolume(_ volume: FilePath, engine: SearchEngine, position: FollowedPosition?) {
        let file = volumeIndexFile(volume)
        if engine.hasUnsavedChanges || !file.exists && engine.count > 0 {
            engine.saveBinaryIndex(to: file.url)
        }
        if let position, file.exists {
            position.mounted.state(position).save(volume)
        }
    }

    /// Positions for the drives being followed, taken before their engines are written.
    func followedVolumePositions() -> [FilePath: FollowedPosition] {
        volumeWatchers.mapValues { $0.position(ending: false) }
    }

    /// Changes followed on drives since their indexes were last written.
    var followedVolumeChanges: Int {
        volumeWatchers.values.reduce(0) { $0 + $1.updater.changes }
    }

    /// FSEvents has no history to give for the drive and asks for all of it to be read again. Not within a day of a
    /// walk: one is followed from where it started, which could ask again.
    func volumeHistoryLost(_ volume: FilePath) {
        let walked = IndexWalks.read().walks[IndexWalks.Key.volume(volume).string]?.finished ?? .distantPast
        guard Date().timeIntervalSince(walked) > 24 * 60 * 60 else {
            log.info("\(volume.string, privacy: .public): FSEvents asked for a walk, the last one was \(walked.formatted())")
            return
        }
        noteWalkNeeded(volume, "FSEvents lost track of its changes")
    }

    /// Records that only a walk would find what the drive's index may be missing, for searching it to offer. Kept
    /// across launches, until the drive is walked or the offer is turned down.
    func noteWalkNeeded(_ volume: FilePath, _ reason: String) {
        log.info("\(volume.string, privacy: .public) needs a walk: \(reason, privacy: .public)")
        guard volumesNeedingWalk[volume] != reason else { return }
        volumesNeedingWalk[volume] = reason
        DriveWalksNeeded.save(volumesNeedingWalk)
    }

    /// The drive was walked, or the walk it was offered was turned down: its index stays as it is until its reindex
    /// interval comes around.
    func forgetWalkNeeded(_ volume: FilePath) {
        guard volumesNeedingWalk.removeValue(forKey: volume) != nil else { return }
        DriveWalksNeeded.save(volumesNeedingWalk)
    }

    /// The mounted drives the current search reaches through a drive filter, among the ones needing a walk.
    var searchedDrivesNeedingWalk: [FilePath] {
        guard proactive, let volumeFilter, !volumesNeedingWalk.isEmpty else { return [] }
        let searched = volumeFilter == .allDrives ? connectedDrives : [volumeFilter]
        return searched.filter { volumesNeedingWalk[$0] != nil && externalVolumes.contains($0) && !volumesIndexing.contains($0) }
    }

    /// Walks the drives nobody asked to walk once each has gone a minute without changes: a walk under a copy slows
    /// both, and what the copy changes meanwhile has to be read again. A network share's changes can't be seen, and it
    /// is walked at once.
    func walkWhenQuiet(_ volumes: [FilePath]) {
        for volume in volumes where !volumesIndexing.contains(volume) && !volumesWaitingForQuiet.contains(volume) {
            volumesWaitingForQuiet.insert(volume)
            Task.detached(priority: .background) {
                let mounted = MountedVolume.read(volume)
                await MainActor.run {
                    guard self.volumesWaitingForQuiet.contains(volume) else { return }
                    guard let mounted, mounted.isLocal, let quiet = DriveQuiet(volume: volume, device: mounted.device, then: {
                        Task { @MainActor in self.quietEnough(volume) }
                    }) else {
                        self.volumesWaitingForQuiet.remove(volume)
                        if mounted != nil {
                            self.indexVolumes([volume], priority: .background)
                        }
                        return
                    }
                    self.quietWaits[volume] = quiet
                    log.info("\(volume.string, privacy: .public): waiting for it to go quiet before walking it")
                }
            }
        }
    }

    func stopWaitingForQuiet(_ volume: FilePath) {
        volumesWaitingForQuiet.remove(volume)
        quietWaits.removeValue(forKey: volume)?.cancel()
    }

    private func quietEnough(_ volume: FilePath) {
        guard volumesWaitingForQuiet.contains(volume) else { return }
        stopWaitingForQuiet(volume)
        guard enabledVolumes.contains(volume), externalVolumes.contains(volume) else { return }
        log.info("\(volume.string, privacy: .public) went quiet, walking it")
        indexVolumes([volume], priority: .background)
    }

    /// For `cling status`: whether a drive's changes are followed, and whether it is still catching up with what
    /// changed while it wasn't.
    func followingStatus(_ volume: FilePath) -> String? {
        guard let watcher = volumeWatchers[volume] else { return nil }
        return watcher.updater.replay.caughtUp ? "following" : "catching up"
    }

    /// What following the drive has cost lately, while it is followed.
    func followedDriveHealth(_ volume: FilePath) -> DriveHealth.Snapshot? {
        guard volumeWatchers[volume] != nil else { return nil }
        return DriveHealth.existing(volume.string)?.snapshot()
    }

    /// The drives whose live updates can be turned on or off: indexed, connected and local.
    var followableVolumes: [FilePath] {
        // Read for its change when a drive's index loads or is replaced, which redraws whatever lists these: the
        // engines themselves aren't observed.
        _ = indexedCount
        return enabledVolumes.filter { externalVolumes.contains($0) && !networkVolumes.contains($0) && (volumeEngines[$0] != nil || volumesIndexing.contains($0)) }
            .sorted { $0.name.string.localizedStandardCompare($1.name.string) == .orderedAscending }
    }

    /// A drive is being unmounted, and what read it has stopped: write what was followed. An unmount another app
    /// refuses leaves the drive mounted, and it is followed again.
    func driveWillUnmount(_ volume: FilePath) {
        stopFollowing(volume)
        stopWaitingForQuiet(volume)
        if volumesIndexing.contains(volume) {
            cancelVolumeIndexing(volume: volume)
        }
        Task.detached(priority: .background) {
            // After the drive's position is written, which waits up to 10 seconds for the unmount.
            try? await Task.sleep(for: .seconds(15))
            // Forgotten already when the unmount went through.
            guard DriveRelease.shared.isReleasing(volume.string), MountedVolume.read(volume) != nil else { return }
            DriveRelease.shared.forget(volume.string)
            await MainActor.run {
                log.info("\(volume.string, privacy: .public) is still mounted, following it again")
                self.syncVolumeFollowing()
            }
        }
    }

    /// On quit: every followed drive's index and position, written before Cling goes.
    func saveFollowedVolumesNow() {
        let watchers = volumeWatchers
        volumeWatchers.removeAll()
        for watcher in watchers.values {
            watcher.stop()
        }
        volumeSaveQueue.sync {
            for (volume, watcher) in watchers {
                Self.saveVolume(volume, engine: watcher.engine, position: watcher.position())
            }
        }
    }
}
