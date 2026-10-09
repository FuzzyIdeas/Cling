import Cocoa
import Combine
import Defaults
import Foundation
import Lowtech
import OSLog
import System

private let log = Logger(subsystem: clingSubsystem, category: "VolumeIndex")

let DEFAULT_VOLUME_REINDEX_INTERVAL: TimeInterval = 60 * 60 * 24 * 7 // 1 week

func volumeIndexFile(_ volume: FilePath) -> FilePath {
    indexFolder / "\(volume.name.string.replacingOccurrences(of: " ", with: "-")).idx"
}

/// What macOS and Windows keep at the top of a drive for themselves: file system events, the Spotlight index, the trash,
/// version history, installer scratch space. A drive's walk skips them, along with the `._` files macOS writes beside
/// each file on an exFAT or FAT drive, and a saved index that still holds either from before loses them once, on its
/// first load.
let DRIVE_METADATA_FOLDERS = [
    ".fseventsd", ".Spotlight-V100", ".Trashes", ".TemporaryItems", ".DocumentRevisions-V100", ".MobileBackups",
    ".PKInstallSandboxManager", ".PKInstallSandboxManager-SystemSoftware", ".HFS+ Private Directory Data\r",
    "System Volume Information", "$RECYCLE.BIN",
]

func driveMetadataFolders(_ volume: FilePath) -> Set<String> {
    Set(DRIVE_METADATA_FOLDERS.map { "\(volume.string)/\($0)" })
}

private func volumeCheckpointFile(_ volume: FilePath) -> URL {
    volumeIndexFile(volume).url.deletingPathExtension().appendingPathExtension("checkpoint")
}

extension FilePath {
    /// The volume filter that searches every external drive's saved index at once, connected or not, so a file can
    /// be traced to the drive holding it while the drives sit in a drawer. It is the folder they all mount under,
    /// so as a path it is true of every result, but it is never walked or indexed itself.
    static let allDrives = FilePath("/Volumes")
}

/// ⌥E picks External drives. Not a digit: those count the volumes from 0, the internal disk, so one after them would
/// move as drives come and go. A quick or folder filter the user put on E keeps it, and new ones are never given it.
let ALL_DRIVES_KEY: Character = "e"

// MARK: - VolumeIndexBatchTracker

private final class VolumeIndexBatchTracker: @unchecked Sendable {
    init(count: Int, onFinish: (@MainActor () -> Void)?) {
        remaining = count
        self.onFinish = onFinish
    }

    func finishOne() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        remaining -= 1
        return remaining == 0
    }

    @MainActor
    func runCompletionIfNeeded(_ shouldRun: Bool) {
        guard shouldRun else { return }
        onFinish?()
    }

    private var remaining: Int
    private let onFinish: (@MainActor () -> Void)?
    private let lock = NSLock()

}

/// Index a single volume into the given engine, picking the fastest traversal method:
/// - Local external drives (USB, SSD, SD): fts with FTS_NOSTAT (getattrlistbulk)
/// - SMB shares: native SMBClient.framework walk, falling back to FileManager
/// - Other network volumes: FileManager with checkpointing
private func indexVolumeEngine(
    volume: FilePath,
    engine: SearchEngine,
    ignoreChecker: String?,
    progress: @escaping (Int, String) -> Void,
    cancelled: @escaping () -> Bool
) async -> (added: Int, metadataCache: SMBMetadataCache?) {
    let volumePath = volume.string
    let metadata = driveMetadataFolders(volume)
    let skipDir: (String) -> Bool = { path in
        metadata.contains(path) || (ignoreChecker.map { path.isIgnored(in: $0) } ?? false)
    }
    let isLocal = volume.url.isLocalVolume

    // Local external drives: use fts (fastest, uses getattrlistbulk internally)
    if isLocal {
        log.info("Using fts walk for local volume \(volumePath)")
        let added = engine.walkDirectory(
            volumePath,
            ignoreFile: ignoreChecker,
            skipDir: skipDir,
            skipAppleDouble: true,
            progress: progress,
            cancelled: cancelled
        )
        return (added, nil)
    }

    // SMB shares: try native SMB walk first
    if isSMBVolume(volumePath) {
        let metadataCache = SMBMetadataCache()
        do {
            let added = try await walkSMBShare(
                engine: engine,
                mountPoint: volumePath,
                ignoreFile: ignoreChecker,
                skipDir: skipDir,
                metadataCache: metadataCache,
                maxConcurrent: 8,
                progress: progress,
                cancelled: cancelled
            )
            log.info("SMB walk succeeded for \(volumePath): \(added) entries")
            return (added, metadataCache)
        } catch {
            log.warning("SMB walk failed for \(volumePath), falling back to FileManager: \(error.localizedDescription)")
            engine.clear()
        }
    }

    // Network fallback: FileManager with checkpointing for reliability
    let cpFile = volumeIndexFile(volume).url.deletingPathExtension().appendingPathExtension("checkpoint")
    let added = engine.walkDirectoryURL(
        volumePath,
        ignoreFile: ignoreChecker,
        skipDir: skipDir,
        checkpointFile: cpFile,
        progress: progress,
        cancelled: cancelled
    )
    return (added, nil)
}

extension FuzzyClient {
    /// Staleness checks for volumes the caller has already confirmed mounted.
    /// `volume.exists` is deliberately not consulted here: stat on a stalled or
    /// mid-unmount volume can block for tens of seconds, so callers stat off-main
    /// first (CLING-14).
    func staleExternalVolumes(amongMounted volumes: [FilePath]) -> [FilePath] {
        let walks = IndexWalks.read().walks
        return volumes.filter { volume in
            let index = volumeIndexFile(volume)
            let cpFile = index.url.deletingPathExtension().appendingPathExtension("checkpoint")
            if FileManager.default.fileExists(atPath: cpFile.path) {
                return true
            } // interrupted indexing
            guard index.exists else { return true }
            let size = (try? FileManager.default.attributesOfItem(atPath: index.string)[.size] as? Int) ?? 0
            if size <= 64 {
                return true
            } // empty or header-only index
            if let engine = volumeEngines[volume], engine.count == 0 {
                return true
            } // loaded but empty
            let interval = Defaults[.reindexTimeIntervalPerVolume][volume] ?? DEFAULT_VOLUME_REINDEX_INTERVAL
            // From the last walk: a followed drive's index is written whenever it changes, and the walk is what finds
            // the changes made while the drive was on another computer.
            let walked = walks[IndexWalks.Key.volume(volume).string]?.finished.timeIntervalSince1970 ?? index.timestamp ?? 0
            return walked < Date().addingTimeInterval(-interval).timeIntervalSince1970
        }
    }

    static func getVolumes() -> [FilePath] {
        let mountedVolumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.isVolumeKey, .volumeIsRootFileSystemKey],
            options: [.skipHiddenVolumes]
        ) ?? []
        return mountedVolumes
            .filter(\.isVolume)
            .compactMap(\.filePath)
            .filter { !isDMGVolume($0) && !isTimeMachineVolume($0) }
            .uniqued.sorted()
    }

    /// DMG installer volumes typically contain a symlink to /Applications,
    /// or a .app bundle with very few other files
    private static func isDMGVolume(_ volume: FilePath) -> Bool {
        let appLink = (volume / "Applications").string
        let attrs = try? FileManager.default.attributesOfItem(atPath: appLink)
        if attrs?[.type] as? FileAttributeType == .typeSymbolicLink {
            return true
        }

        let contents = (try? FileManager.default.contentsOfDirectory(atPath: volume.string)) ?? []
        return contents.count <= 10 && contents.contains { $0.hasSuffix(".app") }
    }

    private static func isTimeMachineVolume(_ volume: FilePath) -> Bool {
        if isTimeMachineBackup(volume.string) {
            return true
        }
        // Only APFS volumes can carry a volume role, and `diskutil info` on a cold
        // external disk can block for many seconds (7s+ on camera SD cards), so ask
        // the mount table for the filesystem type and skip the probe for
        // exFAT/NTFS/SMB/... volumes entirely.
        var fs = statfs()
        guard statfs(volume.string, &fs) == 0 else { return false }
        let fsType = withUnsafeBytes(of: &fs.f_fstypename) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        guard fsType == "apfs" else { return false }
        // APFS Time Machine: check for Backup volume role
        if let output = shell("/usr/sbin/diskutil", args: ["info", volume.string], timeout: 3).o {
            for line in output.components(separatedBy: "\n") where line.contains("APFS Volume Role:") {
                let role = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? ""
                // T=Backup (Time Machine), C=Sidecar (Time Machine)
                if role.contains("T") || role.contains("C") {
                    return true
                }
            }
        }
        return false
    }

    func indexStaleExternalVolumes() {
        guard Defaults[.onboardingCompleted] else { return }
        let candidates = enabledVolumes
        asyncNow {
            // `exists` on a stalled or mid-unmount volume can block the caller for
            // tens of seconds. This runs off `externalVolumes.didSet` on the main
            // thread, so probe mounts off-main and hop back to check staleness and
            // start indexing (CLING-14).
            let mounted = candidates.filter(\.exists)
            mainActor {
                let stale = self.staleExternalVolumes(amongMounted: mounted)
                guard !stale.isEmpty else { return }
                // Nobody asked for these: they wait for each drive to go quiet, and the reads give way to everything
                // else on it.
                self.walkWhenQuiet(stale)
            }
        }
    }

    func getExternalIndexes() -> [FilePath] {
        enabledVolumes.map { volumeIndexFile($0) }
    }

    /// The engines the External drives filter searches: every enabled drive's index, which stays loaded from launch
    /// whether or not the drive is mounted. Taken from the volume engines and not `activeEngines`, because
    /// Everything replaces those while it is on and holds only the disks that are mounted.
    var driveEngines: [(engine: SearchEngine, label: String, scoreBias: Int)] {
        guard proactive else { return [] }
        return enabledVolumes.compactMap { volume in
            volumeEngines[volume].map { ($0, volume.name.string, -2) }
        }
    }

    /// What a volume filter searches: the drive's own saved index, or every drive's for External drives, even while
    /// Everything is on. Everything stands in for `activeEngines` then, and it holds only the disks that are mounted,
    /// so a disconnected drive searched through it found nothing. Nil for the internal disk, which Everything or the
    /// scopes cover.
    var volumeFilterEngines: [(engine: SearchEngine, label: String, scoreBias: Int)]? {
        guard let volumeFilter, volumeFilter != .root else { return nil }
        if volumeFilter == .allDrives {
            return driveEngines
        }
        guard proactive, enabledVolumes.contains(volumeFilter), let engine = volumeEngines[volumeFilter] else { return [] }
        return [(engine, volumeFilter.name.string, -2)]
    }

    /// With a single drive the External drives filter would only repeat that drive's own entry.
    var offersAllDrivesFilter: Bool {
        enabledVolumes.count >= 2
    }

    /// Whether ⌥E picks External drives: while it is offered, and none of the user's own filters has E.
    func allDrivesKeyApplies(quickFilters: [QuickFilter] = Defaults[.quickFilters], folderFilters: [FolderFilter] = Defaults[.folderFilters]) -> Bool {
        offersAllDrivesFilter
            && !quickFilters.contains { $0.key == ALL_DRIVES_KEY }
            && !folderFilters.contains { $0.key == ALL_DRIVES_KEY }
    }

    /// The search is limited to external drives, one or all of them. Everything has no index of a drive of its own,
    /// only of the disks mounted right now with nothing excluded, so it stays off while this holds.
    var searchLimitedToDrives: Bool {
        volumeFilter.map { $0 != .root } ?? false
    }

    /// Results can come from more than one drive, so each says which external drive it is on. Never while the search
    /// is limited to a single drive, internal or external, where every result is on that one.
    var resultsSpanDrives: Bool {
        volumeFilter == nil || volumeFilter == .allDrives
    }

    /// The external drive a path is on and whether it is plugged in right now; nil for the Mac's own disk.
    func externalDrive(of path: FilePath) -> (name: String, connected: Bool)? {
        let string = path.string
        guard string.hasPrefix("/Volumes/") else { return nil }
        let name = string.dropFirst("/Volumes/".count).prefix { $0 != "/" }
        guard !name.isEmpty else { return nil }
        return (String(name), !disconnectedVolumes.contains(FilePath("/Volumes/\(name)")))
    }

    /// What the volume filter is called after "on" in the window's filter line and the bar's.
    var volumeFilterName: String? {
        volumeFilter.map { $0 == .allDrives ? "external drives" : $0.name.string }
    }

    /// The enabled drives that are mounted, the only ones a walk can reach.
    var connectedDrives: [FilePath] {
        enabledVolumes.filter { !disconnectedVolumes.contains($0) }
    }

    private func startVolumeIndexTask(_ volume: FilePath, priority: TaskPriority = .utility, batchTracker: VolumeIndexBatchTracker? = nil) {
        guard !volumesIndexing.contains(volume) else { return }

        backgroundIndexing = true
        volumesIndexing.insert(volume)
        stopWaitingForQuiet(volume)
        // The walk replaces the engine being followed, which is followed again from where the walk started.
        stopFollowing(volume)
        let checkpointFile = volumeCheckpointFile(volume)

        let task = Task.detached(priority: priority) {
            let started = Date()
            let volumeName = volume.name.string
            let opKey = "volume:\(volume.string)"
            // Read here, off the main thread: a stalled or half-unmounted drive can take tens of seconds to answer
            // (CLING-14).
            guard volume.exists else {
                let shouldRunCompletion = batchTracker?.finishOne() ?? false
                await MainActor.run {
                    self.finishVolumeIndexTask(volume)
                    batchTracker?.runCompletionIfNeeded(shouldRunCompletion)
                }
                return
            }
            let volumeFsignore = volume / ".fsignore"
            if let content = try? String(contentsOf: volumeFsignore.url, encoding: .utf8),
               content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                try? FileManager.default.removeItem(at: volumeFsignore.url)
            }
            let ignoreChecker: String? = volumeFsignore.exists ? volumeFsignore.string : nil
            try? FileManager.default.removeItem(at: checkpointFile)
            // Changes made from here on are replayed onto the walked index once it is followed.
            let walkStart = FSEventsGetCurrentEventId()
            let mounted = MountedVolume.read(volume)
            // A drive whose history lives only in memory notes what changes during the walk as it changes.
            let walkWatch = mounted.flatMap { $0.isLocal && !$0.keepsHistory ? WalkWatch(volume: volume, device: $0.device, since: walkStart) : nil }

            await MainActor.run { self.logActivity("Indexing volume: \(volumeName)", ongoing: true, operationKey: opKey) }

            let volumeEngine = SearchEngine()
            DriveRelease.shared.startReading(volume.string)
            let result = await indexVolumeEngine(
                volume: volume, engine: volumeEngine, ignoreChecker: ignoreChecker,
                progress: { count, _ in
                    Task { @MainActor in
                        self.logActivity("Indexing \(volumeName): \(count.formatted()) files", ongoing: true, operationKey: opKey, count: count)
                    }
                },
                cancelled: { Task.isCancelled || DriveRelease.shared.isReleasing(volume.string) }
            )
            DriveRelease.shared.stopReading(volume.string)
            // Nil when too much changed during the walk to say where.
            let walkAgain: [String]? = walkWatch == nil ? [] : walkWatch!.finish()

            let wasCancelled = Task.isCancelled || DriveRelease.shared.isReleasing(volume.string)
            let file = volumeIndexFile(volume)
            if wasCancelled {
                try? FileManager.default.removeItem(at: checkpointFile)
                log.info("Cancelled volume indexing for \(volume.string)")
            } else {
                volumeSaveQueue.sync {
                    try? FileManager.default.removeItem(at: file.url)
                    VolumeLiveState.forget(volume)
                    if result.added > 0 {
                        volumeEngine.saveBinaryIndex(to: file.url)
                        result.metadataCache?.save(to: smbMetadataCacheFile(volume))
                        // A drive that isn't followed after the walk, and whose history ends with the mount, can give
                        // what changes from here on only until it is unmounted.
                        let unwatched = !(mounted?.keepsHistory ?? true) && Defaults[.unfollowedVolumes].contains(volume)
                        mounted.map { $0.state(FollowedPosition(mounted: $0, eventID: walkStart, dirty: unwatched ? "live updates were off" : nil, missed: nil)).save(volume) }
                        log.debug("Indexed volume \(volumeName): \(result.added) entries -> \(file.string)")
                    }
                }
            }

            let reloadedEngine = SearchEngine()
            if !wasCancelled, result.added > 0 {
                _ = reloadedEngine.loadBinaryIndex(from: file.url)
            }

            let shouldRunCompletion = batchTracker?.finishOne() ?? false
            await MainActor.run {
                if !wasCancelled {
                    releaseInBackground(self.volumeEngines.updateValue(reloadedEngine, forKey: volume))
                    if let metaCache = result.metadataCache {
                        releaseInBackground(self.smbMetadataCaches.updateValue(metaCache, forKey: volume))
                    }
                    self.updateIndexedCount()
                    IndexWalks.record(.volume(volume), started: started)
                    self.forgetWalkNeeded(volume)
                    if walkAgain == nil {
                        self.noteWalkNeeded(volume, "too much changed during its last reindex")
                    }
                    self.logActivity("Indexed volume: \(volumeName) (\(result.added.formatted()) files)", operationKey: opKey)
                    if !Defaults[.metadataPrunedVolumes].contains(volume) {
                        Defaults[.metadataPrunedVolumes].append(volume)
                    }
                    if result.added > 0, !Defaults[.indexedVolumePaths].contains(volume) {
                        Defaults[.indexedVolumePaths].append(volume)
                    }
                } else {
                    self.logActivity("Cancelled indexing: \(volumeName)", operationKey: opKey)
                }

                self.finishVolumeIndexTask(volume)
                self.invalidateSearch()
                // The volume engine was replaced; rebuild stale QuickFilter pools first.
                if !self.refreshPoolsAfterReindex(), !self.emptyQuery || self.volumeFilter != nil {
                    self.performSearch()
                }
                // A cancelled walk left the engine as it was, which picks up from its saved position.
                self.followVolume(volume, walkedFrom: wasCancelled ? nil : walkStart, walkAgain: wasCancelled ? [] : walkAgain ?? [])
                batchTracker?.runCompletionIfNeeded(shouldRunCompletion)
            }
        }

        volumeIndexTasks[volume] = task
    }

    private func finishVolumeIndexTask(_ volume: FilePath) {
        volumesIndexing.remove(volume)
        volumeIndexTasks.removeValue(forKey: volume)
        if volumesIndexing.isEmpty {
            backgroundIndexing = indexing
        }
    }

    /// Each walk checks its drive is there before going in, off the main thread.
    func indexVolumes(_ volumes: [FilePath], priority: TaskPriority = .utility, onFinish: (@MainActor () -> Void)? = nil) {
        let volumes = volumes.filter { !volumesIndexing.contains($0) }
        guard !volumes.isEmpty else { return }

        let batchTracker = VolumeIndexBatchTracker(count: volumes.count, onFinish: onFinish)
        for volume in volumes {
            startVolumeIndexTask(volume, priority: priority, batchTracker: batchTracker)
        }
    }

    func cancelVolumeIndexing(volume: FilePath? = nil) {
        if let volume {
            volumeIndexTasks[volume]?.cancel()
            logActivity("Cancelling indexing: \(volume.name.string)")
        } else {
            for task in volumeIndexTasks.values {
                task.cancel()
            }
            logActivity("Cancelling volume indexing")
        }
    }

    func cancelScopeIndexing() {
        scopeIndexTask?.cancel()
        scopeIndexTask = nil
        indexing = false
        backgroundIndexing = !volumesIndexing.isEmpty
        logActivity("Scope indexing cancelled")
    }

    func cancelAllIndexing() {
        cancelScopeIndexing()
        cancelVolumeIndexing()
        logActivity("All indexing cancelled")
    }

    func indexVolume(_ volume: FilePath, priority: TaskPriority = .utility) {
        startVolumeIndexTask(volume, priority: priority)
    }

    func removeVolume(_ volume: FilePath) {
        stopFollowing(volume, save: false)
        stopWaitingForQuiet(volume)
        forgetWalkNeeded(volume)
        cancelVolumeIndexing(volume: volume)
        volumeIndexTasks[volume] = nil
        releaseInBackground(volumeEngines.removeValue(forKey: volume))
        volumesIndexing.remove(volume)
        disconnectedVolumes.remove(volume)

        Defaults[.indexedVolumePaths].removeAll { $0 == volume }
        Defaults[.knownVolumes].removeAll { $0 == volume }
        Defaults[.reindexTimeIntervalPerVolume][volume] = nil
        if !Defaults[.disabledVolumes].contains(volume) {
            Defaults[.disabledVolumes].append(volume)
        }
        if !disabledVolumes.contains(volume) {
            disabledVolumes.append(volume)
        }

        try? FileManager.default.removeItem(at: volumeIndexFile(volume).url)
        try? FileManager.default.removeItem(at: volumeCheckpointFile(volume))
        VolumeLiveState.forget(volume)

        enabledVolumes.removeAll { $0 == volume }
        externalIndexes = getExternalIndexes()

        if volumeFilter == volume || (volumeFilter == .allDrives && !offersAllDrivesFilter) {
            volumeFilter = nil
        }

        logActivity("Removed volume: \(volume.name.string)")
    }
}

/// A Time Machine disk, told by what Time Machine keeps at its root: Backups.backupdb on HFS+, backup_manifest.plist
/// on APFS. That reads the disk, seconds on a sleeping one, so keep it off the main thread. The APFS volume role says
/// the same more formally, but `diskutil info` doesn't print it on macOS 27.
nonisolated func isTimeMachineBackup(_ volume: String) -> Bool {
    let fm = FileManager.default
    return fm.fileExists(atPath: volume + "/Backups.backupdb") || fm.fileExists(atPath: volume + "/backup_manifest.plist")
}
