import Cocoa
import Combine
import Defaults
import Foundation
import Lowtech
import os.log
import System

private let vlog = Logger(subsystem: "com.lowtechguys.Cling", category: "VolumeIndex")

let DEFAULT_VOLUME_REINDEX_INTERVAL: TimeInterval = 60 * 60 * 24 * 7 // 1 week

func volumeIndexFile(_ volume: FilePath) -> FilePath {
    indexFolder / "\(volume.name.string.replacingOccurrences(of: " ", with: "-")).idx"
}

private func volumeCheckpointFile(_ volume: FilePath) -> URL {
    volumeIndexFile(volume).url.deletingPathExtension().appendingPathExtension("checkpoint")
}

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
    let skipDir: ((String) -> Bool)? = ignoreChecker.map { checker in
        { path in path.isIgnored(in: checker) }
    }
    let isLocal = volume.url.isLocalVolume

    // Local external drives: use fts (fastest, uses getattrlistbulk internally)
    if isLocal {
        vlog.info("Using fts walk for local volume \(volumePath)")
        let added = engine.walkDirectory(
            volumePath,
            ignoreFile: ignoreChecker,
            skipDir: skipDir,
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
            vlog.info("SMB walk succeeded for \(volumePath): \(added) entries")
            return (added, metadataCache)
        } catch {
            vlog.warning("SMB walk failed for \(volumePath), falling back to FileManager: \(error)")
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
    var staleExternalVolumes: [FilePath] {
        enabledVolumes.filter { volume in
            guard volume.exists else { return false }
            let index = volumeIndexFile(volume)
            let cpFile = index.url.deletingPathExtension().appendingPathExtension("checkpoint")
            if FileManager.default.fileExists(atPath: cpFile.path) { return true } // interrupted indexing
            guard index.exists else { return true }
            let size = (try? FileManager.default.attributesOfItem(atPath: index.string)[.size] as? Int) ?? 0
            if size <= 64 { return true } // empty or header-only index
            if let engine = volumeEngines[volume], engine.count == 0 { return true } // loaded but empty
            let interval = Defaults[.reindexTimeIntervalPerVolume][volume] ?? DEFAULT_VOLUME_REINDEX_INTERVAL
            return (index.timestamp ?? 0) < Date().addingTimeInterval(-interval).timeIntervalSince1970
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
        // HFS+ Time Machine
        if FileManager.default.fileExists(atPath: (volume / "Backups.backupdb").string) {
            return true
        }
        // APFS Time Machine: check for Backup volume role
        if let output = shell("/usr/sbin/diskutil", args: ["info", volume.string], timeout: 3).o {
            for line in output.components(separatedBy: "\n") where line.contains("APFS Volume Role:") {
                let role = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? ""
                // T=Backup (Time Machine), C=Sidecar (Time Machine)
                if role.contains("T") || role.contains("C") { return true }
            }
        }
        return false
    }

    func indexStaleExternalVolumes() {
        guard Defaults[.onboardingCompleted] else { return }
        let volumes = staleExternalVolumes
        guard !volumes.isEmpty else { return }
        indexVolumes(volumes)
    }

    func getExternalIndexes() -> [FilePath] {
        enabledVolumes.map { volumeIndexFile($0) }
    }

    private func startVolumeIndexTask(_ volume: FilePath, batchTracker: VolumeIndexBatchTracker? = nil) {
        guard volume.exists, !volumesIndexing.contains(volume) else { return }

        backgroundIndexing = true
        volumesIndexing.insert(volume)

        let volumeFsignore = volume / ".fsignore"
        if let content = try? String(contentsOf: volumeFsignore.url, encoding: .utf8),
           content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            try? FileManager.default.removeItem(at: volumeFsignore.url)
        }
        let ignoreChecker: String? = volumeFsignore.exists ? volumeFsignore.string : nil
        let checkpointFile = volumeCheckpointFile(volume)
        try? FileManager.default.removeItem(at: checkpointFile)

        let task = Task.detached(priority: .utility) {
            let volumeName = volume.name.string
            let opKey = "volume:\(volume.string)"
            await MainActor.run { self.logActivity("Indexing volume: \(volumeName)", ongoing: true, operationKey: opKey) }

            let volumeEngine = SearchEngine()
            let result = await indexVolumeEngine(
                volume: volume, engine: volumeEngine, ignoreChecker: ignoreChecker,
                progress: { count, _ in
                    Task { @MainActor in
                        self.logActivity("Indexing \(volumeName): \(count.formatted()) files", ongoing: true, operationKey: opKey, count: count)
                    }
                },
                cancelled: { Task.isCancelled }
            )

            let wasCancelled = Task.isCancelled
            let file = volumeIndexFile(volume)
            if wasCancelled {
                try? FileManager.default.removeItem(at: checkpointFile)
                vlog.info("Cancelled volume indexing for \(volume.string)")
            } else {
                try? FileManager.default.removeItem(at: file.url)
                if result.added > 0 {
                    volumeEngine.saveBinaryIndex(to: file.url)
                    result.metadataCache?.save(to: smbMetadataCacheFile(volume))
                    log.debug("Indexed volume \(volumeName): \(result.added) entries -> \(file.string)")
                }
            }

            let reloadedEngine = SearchEngine()
            if !wasCancelled, result.added > 0 {
                _ = reloadedEngine.loadBinaryIndex(from: file.url)
            }

            let shouldRunCompletion = batchTracker?.finishOne() ?? false
            await MainActor.run {
                if !wasCancelled {
                    self.volumeEngines[volume] = reloadedEngine
                    if let metaCache = result.metadataCache {
                        self.smbMetadataCaches[volume] = metaCache
                    }
                    self.updateIndexedCount()
                    self.logActivity("Indexed volume: \(volumeName) (\(result.added.formatted()) files)", operationKey: opKey)
                    if result.added > 0, !Defaults[.indexedVolumePaths].contains(volume) {
                        Defaults[.indexedVolumePaths].append(volume)
                    }
                } else {
                    self.logActivity("Cancelled indexing: \(volumeName)", operationKey: opKey)
                }

                self.volumesIndexing.remove(volume)
                self.volumeIndexTasks.removeValue(forKey: volume)
                if self.volumesIndexing.isEmpty {
                    self.backgroundIndexing = self.indexing
                }
                self.invalidateSearch()
                if !self.emptyQuery || self.volumeFilter != nil {
                    self.performSearch()
                }
                batchTracker?.runCompletionIfNeeded(shouldRunCompletion)
            }
        }

        volumeIndexTasks[volume] = task
    }

    func indexVolumes(_ volumes: [FilePath], onFinish: (@MainActor () -> Void)? = nil) {
        let volumes = volumes.filter { $0.exists && !volumesIndexing.contains($0) }
        guard !volumes.isEmpty else { return }

        let batchTracker = VolumeIndexBatchTracker(count: volumes.count, onFinish: onFinish)
        for volume in volumes {
            startVolumeIndexTask(volume, batchTracker: batchTracker)
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

    func indexVolume(_ volume: FilePath) {
        startVolumeIndexTask(volume)
    }

    func removeVolume(_ volume: FilePath) {
        cancelVolumeIndexing(volume: volume)
        volumeIndexTasks[volume] = nil
        volumeEngines[volume] = nil
        volumesIndexing.remove(volume)
        disconnectedVolumes.remove(volume)

        Defaults[.indexedVolumePaths].removeAll { $0 == volume }
        Defaults[.reindexTimeIntervalPerVolume][volume] = nil
        if !Defaults[.disabledVolumes].contains(volume) {
            Defaults[.disabledVolumes].append(volume)
        }
        if !disabledVolumes.contains(volume) {
            disabledVolumes.append(volume)
        }

        try? FileManager.default.removeItem(at: volumeIndexFile(volume).url)
        try? FileManager.default.removeItem(at: volumeCheckpointFile(volume))

        enabledVolumes.removeAll { $0 == volume }
        externalIndexes = getExternalIndexes()

        if volumeFilter == volume { volumeFilter = nil }

        logActivity("Removed volume: \(volume.name.string)")
    }
}
