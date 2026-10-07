//
//  WebCloudFetch.swift
//  Cling
//
//  Online-only files, brought to the Mac before Web Access sends them. Reading one downloads all of it from its cloud
//  service first: a browser that already has the headers would sit on a download stuck at nothing for as long as that
//  takes. So the page asks for this first and shows how far it got, and a file asked for without that waits for it
//  before its headers go out.
//

import Foundation
import System

final class WebCloudFetch: @unchecked Sendable {
    /// The online-only files and packages in `paths`, walking folders. Listing a folder that is online only fetches its
    /// names, never its files.
    init(paths: [String]) {
        var found: [(path: String, size: UInt64)] = []
        var seen = 0
        for path in paths {
            Self.collect(path, into: &found, seen: &seen)
        }
        items = found.sorted { $0.size > $1.size }
        service = paths.lazy.compactMap(Self.service).first ?? "the cloud"
        // Nothing to get: done already, and never reused for a file evicted after.
        done = items.isEmpty
    }

    struct Status {
        var done: Bool
        var fraction: Double
        var error: String?
    }

    let items: [(path: String, size: UInt64)]
    /// Where they come from, as its app calls itself: `Dropbox`, `iCloud Drive`.
    let service: String

    var isEmpty: Bool {
        items.isEmpty
    }

    /// Everything came down once. Not asked again: evicted since, a file would wait on downloads nobody started.
    var isDone: Bool {
        lock.withLock { done }
    }

    /// A folder whose files may be online only, so the page asks for it before downloading it.
    static func inCloud(_ path: String) -> Bool {
        CloudStorage.root(containing: path) != nil
    }

    /// Asks each service for its files. The largest are followed closely enough to show their progress; the rest only
    /// count once they are on the Mac.
    func start() {
        let followed = items.prefix(Self.followed).map(\.path)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let downloads = followed.map { CloudDownload.of(FilePath($0)) }
                for download in downloads {
                    download.start()
                }
                self.downloads = downloads
            }
        }
        for item in items.dropFirst(Self.followed) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: URL(fileURLWithPath: item.path))
        }
    }

    /// Done once nothing is online only any more, whatever the progress said.
    func status() async -> Status {
        let pending = items.map { FilePath($0.path).isOnlineOnly }
        guard pending.contains(true) else {
            lock.withLock { done = true }
            return Status(done: true, fraction: 1, error: nil)
        }
        let followed = await MainActor.run { downloads?.map { ($0.fraction, $0.phase) } ?? [] }
        var got = 0.0
        var total = 0.0
        var error: String?
        for (i, item) in items.enumerated() {
            let weight = Double(max(item.size, 1))
            total += weight
            guard pending[i] else {
                got += weight
                continue
            }
            if i < followed.count {
                got += weight * followed[i].0
                if case let .failed(message) = followed[i].1 {
                    error = message
                }
            }
        }
        return Status(done: false, fraction: total > 0 ? got / total : 0, error: error ?? unfollowedError(pending))
    }

    /// Blocks until they are all on the Mac, for a file asked for without the page asking first. False when one
    /// couldn't be downloaded, or it took longer than `timeout`.
    func waitUntilLocal(timeout: TimeInterval = 60 * 60) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let pending = items.map { FilePath($0.path).isOnlineOnly }
            guard pending.contains(true) else {
                lock.withLock { done = true }
                return true
            }
            if pending.indices.contains(where: { pending[$0] && downloadError(items[$0].path) != nil }) {
                return false
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }

    /// How many are followed with their progress: each one is a subscription to its download's progress.
    private static let followed = 64
    /// A folder this big is left to download as it is read rather than walked here first.
    private static let walkLimit = 200_000

    @MainActor private var downloads: [CloudDownload]?
    private let lock = NSLock()
    private var done = false

    private static func collect(_ path: String, into found: inout [(path: String, size: UInt64)], seen: inout Int) {
        seen += 1
        guard seen < walkLimit else { return }
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        let online = st.st_flags & UInt32(SF_DATALESS) != 0
        switch st.st_mode & S_IFMT {
        case S_IFREG:
            if online {
                found.append((path, UInt64(st.st_size)))
            }
        case S_IFDIR:
            if online, CloudDownloads.isOnlinePackage(path) {
                found.append((path, 0))
                return
            }
            for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
                collect(path + "/" + name, into: &found, seen: &seen)
            }
        default:
            break
        }
    }

    private static func service(_ path: String) -> String? {
        guard let root = CloudStorage.root(containing: path) else { return nil }
        return CloudStorage.locations().first { $0.root.string == root }?.name
    }

    private func downloadError(_ path: String) -> String? {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.ubiquitousItemDownloadingErrorKey])
        return values?.ubiquitousItemDownloadingError?.localizedDescription
    }

    /// The first few still online only that aren't followed, asked whether their download failed.
    private func unfollowedError(_ pending: [Bool]) -> String? {
        pending.indices.lazy.filter { $0 >= Self.followed && pending[$0] }.prefix(8).compactMap { self.downloadError(self.items[$0].path) }.first
    }
}
