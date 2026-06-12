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
import Defaults
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
