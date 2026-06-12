//
//  FileInfo.swift
//  Cling
//
//  Quick file metadata for the preview panel footer (dimensions, page counts,
//  item counts, durations, line counts) plus the Finder Get Info bridge.
//  Every fact comes from header-only or stat-level reads. Network and offline
//  volumes are classified before any filesystem call so a dead mount can never
//  hang the UI or pile up blocked threads.
//

import AppKit
import AVFoundation
import ImageIO
import Lowtech
import os
import OSLog
import SwiftUI
import System
import UniformTypeIdentifiers

private let log = Logger(subsystem: clingSubsystem, category: "FileInfo")

// MARK: - FileFacts

struct FileFacts: Equatable {
    var primary: [String] = [] // line 1: size and kind-specific facts
    var secondary: [String] = [] // line 2: created/modified dates
}

// MARK: - PreviewPanelState

/// The file currently shown in the preview panel, published so the ⌘I key
/// handler can target the single previewed file even with many selected.
@MainActor
final class PreviewPanelState {
    static let shared = PreviewPanelState()

    var currentPath: FilePath?
}

// MARK: - VolumeFetchGate

/// At most one in-flight kind-specific fetch per non-internal volume. When the
/// slot is busy (a previous fetch is stuck on a dead share), new fetches skip
/// their kind-specific facts instead of queueing behind it.
@MainActor
enum VolumeFetchGate {
    static func tryAcquire(_ key: String) -> Bool { busy.insert(key).inserted }
    static func release(_ key: String) { busy.remove(key) }

    private static var busy: Set<String> = []
}

/// Runs blocking file I/O on a GCD queue so a stall parks a dispatch thread,
/// never a Swift-concurrency cooperative thread.
func runBlocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async {
            cont.resume(returning: work())
        }
    }
}

/// Races `operation` against a timeout and ABANDONS it on expiry: the caller
/// resumes with nil while the operation keeps running detached and its late
/// result is dropped. (A task group would await the stuck child on exit, which
/// is exactly the hang this exists to avoid.)
func race<T: Sendable>(timeout: TimeInterval, _ operation: @escaping @Sendable () async -> T?) async -> T? {
    await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
        let resumed = OSAllocatedUnfairLock(initialState: false)
        @Sendable func resumeOnce(_ value: T?) -> Bool {
            let first = resumed.withLock { done in
                if done { return false }
                done = true
                return true
            }
            if first { cont.resume(returning: value) }
            return first
        }
        let timer = Task {
            try? await Task.sleep(for: .seconds(timeout))
            _ = resumeOnce(nil)
        }
        Task {
            let value = await operation()
            // Stop the timer when the operation wins, so a fast fetch does not
            // leave a sleeping task behind for the full timeout.
            if resumeOnce(value) { timer.cancel() }
        }
    }
}

// MARK: - FileInfo

enum FileInfo {
    /// Where a path lives, decided from in-memory state (mounted volume list
    /// and memoized volume attributes), never from a fresh stat.
    enum VolumeClass {
        case internalDisk
        case externalLocal(FilePath)
        case network(FilePath)
        case offline
    }

    @MainActor
    static func classify(_ path: FilePath) -> VolumeClass {
        if let volume = path.memoz.volume {
            // isOnExternalVolume is true only for network (non-local) volumes;
            // USB disks count as local. See SettingsView.swift FilePath.volume.
            return path.memoz.isOnExternalVolume ? .network(volume) : .externalLocal(volume)
        }
        // Under /Volumes/ but matching no mounted volume: a disconnected disk
        // still present in stale results. Touching it could hang in stat.
        if path.string.hasPrefix("/Volumes/") {
            return .offline
        }
        return .internalDisk
    }

    /// SMB metadata cached at index time, available even when the share is gone.
    @MainActor
    static func cachedSMBMeta(_ path: FilePath) -> SMBFileMetadata? {
        if let volume = path.memoz.volume {
            return FUZZY.smbMetadataCaches[volume]?.get(path.string)
        }
        // Offline volume: prefix-match the cache keys directly since the
        // volume is no longer in the mounted list.
        return FUZZY.smbMetadataCaches.first { path.starts(with: $0.key) }?.value.get(path.string)
    }

    // MARK: Kind-specific fetchers (all called off the main thread)

    private static func imageFacts(_ url: URL) -> [String] {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, opts) as? [CFString: Any]
        else { return [] }
        var facts: [String] = []
        if let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int
        {
            facts.append("\(w)×\(h)")
        }
        if let model = props[kCGImagePropertyColorModel] as? String {
            if let depth = props[kCGImagePropertyDepth] as? Int {
                facts.append("\(model) \(depth)-bit")
            } else {
                facts.append(model)
            }
        }
        if let dpi = props[kCGImagePropertyDPIWidth] as? Double, dpi > 0, Int(dpi) != 72 {
            facts.append("\(Int(dpi)) dpi")
        }
        return facts
    }

    private static func pdfFacts(_ url: URL) -> [String] {
        guard let doc = CGPDFDocument(url as CFURL) else { return [] }
        let pages = doc.numberOfPages
        var facts = ["\(pages.formatted()) page\(pages == 1 ? "" : "s")"]
        if doc.isEncrypted { facts.append("encrypted") }
        return facts
    }

    private static func mediaFacts(_ url: URL, video: Bool) async -> [String] {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.isNumeric else { return [] }
        var facts = [formatDuration(duration.seconds)]
        if video,
           let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize),
           size.width > 0, size.height > 0
        {
            facts.append("\(Int(size.width))×\(Int(size.height))")
        }
        return facts
    }

    private static func folderFacts(_ url: URL) -> [String] {
        // Lazy shallow enumeration, hidden files included, hard cap so a
        // directory with millions of entries stays bounded.
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [],
            options: [.skipsSubdirectoryDescendants]
        ) else { return [] }
        var count = 0
        for case _ as URL in enumerator {
            count += 1
            if count >= 2000 { return ["\(2000.formatted())+ items"] }
        }
        return ["\(count.formatted()) item\(count == 1 ? "" : "s")"]
    }

    /// Counts newlines with memchr over 256 KB chunks. No String decoding,
    /// constant memory. Caller enforces the size cap and volume policy.
    private static func lineCountFacts(_ url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        var count = 0
        var lastByte: UInt8 = 0x0A
        while let data = try? handle.read(upToCount: 256 * 1024), !data.isEmpty {
            data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                guard var base = buf.baseAddress else { return }
                var remaining = buf.count
                while remaining > 0 {
                    guard let hit = memchr(base, 0x0A, remaining) else { break }
                    count += 1
                    let consumed = Int(bitPattern: hit) - Int(bitPattern: base) + 1
                    base = base.advanced(by: consumed)
                    remaining -= consumed
                }
                lastByte = buf[buf.count - 1]
            }
        }
        if lastByte != 0x0A { count += 1 } // final line without trailing newline
        return ["\(count.formatted()) line\(count == 1 ? "" : "s")"]
    }

    // MARK: Fetch pipeline

    private static let lineCountSizeCap = 8 * 1024 * 1024
    private static let cacheLimit = 64

    // LRU keyed by path string, validated by mtime, so paging back and forth
    // through a selection never refetches.
    @MainActor private static var cache: [String: (mtime: Date?, facts: FileFacts)] = [:]
    @MainActor private static var cacheOrder: [String] = []

    @MainActor
    private static func cached(_ path: FilePath, mtime: Date?) -> FileFacts? {
        guard let entry = cache[path.string], entry.mtime == mtime else { return nil }
        return entry.facts
    }

    @MainActor
    private static func store(_ facts: FileFacts, for path: FilePath, mtime: Date?) {
        if cache[path.string] == nil {
            cacheOrder.append(path.string)
            if cacheOrder.count > cacheLimit {
                cache.removeValue(forKey: cacheOrder.removeFirst())
            }
        }
        cache[path.string] = (mtime, facts)
    }

    private struct CommonAttrs: Sendable {
        var size: Int?
        var created: Date?
        var modified: Date?
        var isSymlink = false
        var symlinkTarget: String?
        var kindName: String?
    }

    private static func commonAttrs(_ url: URL) -> CommonAttrs {
        var common = CommonAttrs()
        guard let vals = try? url.resourceValues(forKeys: [
            .fileSizeKey, .creationDateKey, .contentModificationDateKey,
            .isSymbolicLinkKey, .contentTypeKey,
        ]) else { return common }
        common.size = vals.fileSize
        common.created = vals.creationDate
        common.modified = vals.contentModificationDate
        common.isSymlink = vals.isSymbolicLink == true
        if common.isSymlink {
            common.symlinkTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        }
        common.kindName = vals.contentType?.localizedDescription
        return common
    }

    @MainActor
    static func fetch(for path: FilePath, kind: PreviewKind) async -> FileFacts {
        let volumeClass = classify(path)
        let url = path.url

        // 1. Common facts: size + dates. Never stat offline volumes; prefer
        //    the SMB index cache on network volumes.
        var common = CommonAttrs()
        switch volumeClass {
        case .offline, .network:
            if let meta = cachedSMBMeta(path) {
                common.size = Int(meta.size)
                common.created = meta.creationDate
                common.modified = meta.modificationDate
            }
        case .internalDisk, .externalLocal:
            common = await runBlocking { commonAttrs(url) }
        }

        if case .offline = volumeClass {
            var facts = FileFacts()
            if let size = common.size { facts.primary.append(size.humanSize) }
            facts.primary.append("offline")
            facts.secondary = datesLine(common)
            return facts
        }

        if let hit = cached(path, mtime: common.modified) { return hit }

        if kind == .archive {
            var facts = FileFacts()
            if let size = common.size { facts.primary.append(size.humanSize) }
            // cachedList shares the 7z subprocess with ArchivePreview; the
            // subprocess has its own 6s watchdog, and offline volumes never
            // reach this point.
            if let listing = await SevenZip.cachedList(url).value {
                let n = listing.entries.count
                facts.primary.append("\(n.formatted())\(listing.truncated ? "+" : "") file\(n == 1 ? "" : "s")")
                if listing.totalUncompressedSize > 0 {
                    // Truncated listings carry a partial sum, marked with "+"
                    // just like the file count.
                    facts.primary.append("\(Int(listing.totalUncompressedSize).humanSize)\(listing.truncated ? "+" : "") uncompressed")
                }
            }
            if common.isSymlink, let target = common.symlinkTarget { facts.primary.append("→ \(target)") }
            facts.secondary = datesLine(common)
            store(facts, for: path, mtime: common.modified)
            return facts
        }

        // 2. Kind-specific facts, gated per volume so a dead share costs at
        //    most one parked thread.
        var kindFacts: [String] = []
        switch volumeClass {
        case .internalDisk:
            kindFacts = await kindSpecificFacts(url, kind: kind, size: common.size, allowContentReads: true)
        case let .externalLocal(volume), let .network(volume):
            var allowContentReads = true
            if case .network = volumeClass { allowContentReads = false }
            if VolumeFetchGate.tryAcquire(volume.string) {
                let volumeKey = volume.string
                kindFacts = await race(timeout: 2) { [size = common.size] in
                    // The release lives INSIDE the raced operation, in a defer,
                    // so the slot frees exactly when the (possibly stuck) work
                    // finishes, never while it is still parked on a dead mount.
                    defer { Task { @MainActor in VolumeFetchGate.release(volumeKey) } }
                    return await kindSpecificFacts(url, kind: kind, size: size, allowContentReads: allowContentReads)
                } ?? []
            }
        case .offline:
            break // handled above
        }

        var facts = FileFacts()
        if let size = common.size, kind != .folder { facts.primary.append(size.humanSize) }
        facts.primary += kindFacts
        if kind == .quicklook, let kindName = common.kindName { facts.primary.append(kindName) }
        if common.isSymlink, let target = common.symlinkTarget { facts.primary.append("→ \(target)") }
        facts.secondary = datesLine(common)

        store(facts, for: path, mtime: common.modified)
        return facts
    }

    /// `allowContentReads` is false on network volumes: line counting reads
    /// full file contents, which is a header-only budget violation over SMB.
    private static func kindSpecificFacts(_ url: URL, kind: PreviewKind, size: Int?, allowContentReads: Bool) async -> [String] {
        switch kind {
        case .image:
            return await runBlocking { imageFacts(url) }
        case .pdf:
            return await runBlocking { pdfFacts(url) }
        case .video:
            return await mediaFacts(url, video: true)
        case .audio:
            return await mediaFacts(url, video: false)
        case .folder:
            return await runBlocking { folderFacts(url) }
        case .text:
            guard allowContentReads, let size, size <= lineCountSizeCap else { return [] }
            return await runBlocking { lineCountFacts(url) }
        case .archive:
            return [] // archives are handled earlier in fetch(), before this switch
        case .quicklook:
            return []
        }
    }

    private static func datesLine(_ common: CommonAttrs) -> [String] {
        var line: [String] = []
        if let created = common.created {
            line.append("Created \(created.formatted(date: .abbreviated, time: .omitted))")
        }
        if let modified = common.modified {
            line.append("Modified \(modified.formatted(date: .abbreviated, time: .omitted))")
        }
        return line
    }
}

// MARK: - FileInfoBar

/// Two-line metadata footer under the preview content. Reserves its height
/// while facts load so the layout never jumps; facts that fail or time out
/// are simply absent.
struct FileInfoBar: View {
    let path: FilePath
    let kind: PreviewKind

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(facts.primary.isEmpty ? " " : facts.primary.joined(separator: " · "))
            Text(facts.secondary.isEmpty ? " " : facts.secondary.joined(separator: " · "))
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .task(id: "\(path.string)|\(kind)") {
            // .task(id:) cancels when the path (or its detected kind, which
            // can flip once QuickLook support detection finishes) changes;
            // that is the generation token dropping late results from an
            // abandoned fetch.
            facts = FileFacts()
            let result = await FileInfo.fetch(for: path, kind: kind)
            if !Task.isCancelled { facts = result }
        }
    }

    @State private var facts = FileFacts()
}

// MARK: - Formatting

func formatDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "" }
    let total = Int(seconds.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

// MARK: - Finder Get Info

/// Opens Finder's Get Info panel for one file. First use triggers the
/// one-time "Cling wants to control Finder" Automation prompt.
func openFinderGetInfo(_ path: FilePath) {
    // Spawn off-main so the key handler never waits on posix_spawn.
    Task.detached(priority: .userInitiated) {
        let script = """
        on run argv
            tell application "Finder"
                open information window of (POSIX file (item 1 of argv) as alias)
                activate
            end tell
        end run
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, path.string]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { proc in
            if proc.terminationStatus != 0 {
                log.error("Finder Get Info failed for \(path.string, privacy: .public) (exit \(proc.terminationStatus))")
            }
        }
        do {
            try process.run()
        } catch {
            log.error("Failed to launch osascript for Get Info: \(error.localizedDescription, privacy: .public)")
        }
    }
}
