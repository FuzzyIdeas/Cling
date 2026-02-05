import Cocoa
import Combine
import Defaults
import Foundation
import Lowtech
import System

let DEFAULT_VOLUME_REINDEX_INTERVAL: TimeInterval = 60 * 60 * 24 * 7 // 1 week

func volumeIndexFile(_ volume: FilePath) -> FilePath {
    indexFolder / "\(volume.name.string.replacingOccurrences(of: " ", with: "-")).idx"
}

extension FuzzyClient {
    var staleExternalVolumes: [FilePath] {
        enabledVolumes.filter { volume in
            guard volume.exists else { return false }
            let index = volumeIndexFile(volume)
            let interval = Defaults[.reindexTimeIntervalPerVolume][volume] ?? DEFAULT_VOLUME_REINDEX_INTERVAL
            return !index.exists || (index.timestamp ?? 0) < Date().addingTimeInterval(-interval).timeIntervalSince1970
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
            .filter { !isDMGVolume($0) }
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

    func indexStaleExternalVolumes() {
        let volumes = staleExternalVolumes
        guard !volumes.isEmpty else { return }
        indexVolumes(volumes)
    }

    func getExternalIndexes() -> [FilePath] {
        enabledVolumes.map { volumeIndexFile($0) }
    }

    func indexVolumes(_ volumes: [FilePath], onFinish: (@MainActor () -> Void)? = nil) {
        let volumes = volumes.filter(\.exists)
        guard !volumes.isEmpty else { return }

        backgroundIndexing = true
        let ignoreChecker = fsignore.exists ? (try? String(contentsOf: fsignore.url)) : nil

        let indexTask = Task.detached(priority: .utility) {
            for volume in volumes {
                guard !Task.isCancelled else { break }
                let volumeName = volume.name.string
                await MainActor.run { self.logActivity("Indexing volume: \(volumeName)", ongoing: true) }

                let volumeEngine = SearchEngine()
                let skipDir: ((String) -> Bool)? = ignoreChecker.map { checker in
                    { path in path.isIgnored(in: checker) }
                }
                // Use URL-based walker with checkpoint support for crash recovery
                let cpFile = volumeIndexFile(volume).url.deletingPathExtension().appendingPathExtension("checkpoint")
                let added = volumeEngine.walkDirectoryURL(volume.string, ignoreFile: ignoreChecker, skipDir: skipDir, checkpointFile: cpFile, progress: { count, lastPath in
                    Task { @MainActor in
                        self.logActivity("Indexing \(volumeName): \(count.formatted()) files", ongoing: true)
                    }
                }, cancelled: { Task.isCancelled })

                // Save per-volume index
                let file = volumeIndexFile(volume)
                volumeEngine.saveBinaryIndex(to: file.url)
                log.debug("Indexed volume \(volumeName): \(added) entries -> \(file.string)")

                // Store as separate volume engine
                await MainActor.run {
                    self.volumeEngines[volume] = volumeEngine
                    self.updateIndexedCount()
                    self.logActivity("Indexed volume: \(volumeName) (\(added.formatted()) files)")
                }
            }

            await MainActor.run {
                self.volumeIndexTask = nil
                onFinish?()
                self.backgroundIndexing = false
                if !self.emptyQuery || self.volumeFilter != nil {
                    self.performSearch()
                }
            }
        }
        volumeIndexTask = indexTask
    }

    func cancelVolumeIndexing() {
        volumeIndexTask?.cancel()
        volumeIndexTask = nil
        backgroundIndexing = false
        logActivity("Volume indexing cancelled")
    }

    func indexVolume(_ volume: FilePath) {
        indexVolumes([volume])
    }
}
