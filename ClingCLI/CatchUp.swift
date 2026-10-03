import ArgumentParser
import CoreServices
import Foundation
import IOKit
import OSLog

private let log = Logger(subsystem: "com.lowtechguys.Cling", category: "CatchUp")

// MARK: - CatchUp

/// Run by launchd every half hour (Contents/Library/LaunchAgents/com.lowtechguys.Cling.catch-up.plist). While Cling is
/// closed it gathers the file changes since the saved indexes into the change journal, once every three hours: it
/// waits for a few minutes nobody touches the Mac when it can, and runs anyway past six. With Cling open it does
/// nothing, Cling follows the changes itself.
struct CatchUp: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "catch-up",
        abstract: "Gather the file changes made while Cling is closed",
        shouldDisplay: false
    )

    static let interval: TimeInterval = 3 * 60 * 60
    static let deadline: TimeInterval = 6 * 60 * 60
    static let idleEnough: TimeInterval = 5 * 60
    /// Further back, there is too much to read for a background job, and Cling walks its scopes instead.
    static let maxBacklog: UInt64 = 100_000_000
    /// A replay that hasn't finished by then is kept as far as it got.
    static let timeLimit: TimeInterval = 10 * 60

    /// Whether the Cling app is running: it answers on its CLI port.
    static var clingIsRunning: Bool {
        CFMessagePortCreateRemote(nil, CLING_PORT_ID) != nil
    }

    /// Seconds since the last keyboard, mouse or trackpad input.
    static var userIdle: TimeInterval {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber
        else { return 0 }
        return value.doubleValue / 1_000_000_000
    }

    @Flag(help: "Run now, without waiting for its time or for the Mac to be idle")
    var now = false

    func run() throws {
        guard !Self.clingIsRunning else { return }

        let lockFile = open(ChangeJournal.folder.appendingPathComponent("catch-up.lock").path, O_CREAT | O_RDWR, 0o644)
        guard lockFile >= 0, flock(lockFile, LOCK_EX | LOCK_NB) == 0 else { return }
        defer { close(lockFile) }

        let lastRun = ChangeJournal.readHeader()?.lastRun ?? SavedIndexes.savedAt ?? .distantPast
        let waited = Date().timeIntervalSince(lastRun)
        if !now {
            guard waited >= Self.interval, waited >= Self.deadline || Self.userIdle >= Self.idleEnough else { return }
        }
        guard let oldest = SavedIndexes.oldestPosition() else {
            log.info("Catch-up: no saved indexes to catch up")
            return
        }

        // Carry on from the journal while the saved indexes still start within it, or start over from them.
        var journal = ChangeJournal.read().flatMap { j -> ChangeJournal? in
            j.usable && j.header.start <= oldest && oldest <= j.header.end ? j : nil
        } ?? ChangeJournal(header: ChangeJournal.Header(start: oldest, end: oldest))
        let current = FSEventsGetCurrentEventId()
        guard current - journal.header.end <= Self.maxBacklog else {
            log.info("Catch-up: \(current - journal.header.end) events behind, left for Cling to walk")
            return
        }

        let t0 = CFAbsoluteTimeGetCurrent()
        let replay = Replay(since: journal.header.end, excluding: SavedIndexes.unwatchedFolders(), changes: journal.changes)
        let done = replay.run(timeLimit: Self.timeLimit)
        journal.changes = replay.changes
        journal.header.end = replay.lastID
        journal.header.lost = journal.header.lost || replay.lost || journal.changes.count > ChangeJournal.maxPaths
        journal.header.lastRun = Date()
        if journal.header.lost {
            journal.changes = [:]
        }
        try journal.write()
        log.info(
            "Catch-up: \(replay.events) events, \(journal.changes.count) paths kept, \(done ? "done" : "stopped early") in \(CFAbsoluteTimeGetCurrent() - t0, format: .fixed(precision: 1))s\(journal.header.lost ? ", history lost" : "")"
        )
    }
}

// MARK: - SavedIndexes

/// What the agent needs to know about Cling's saved indexes, read from the files Cling keeps next to them.
private enum SavedIndexes {
    static let stateFile = ChangeJournal.folder.appendingPathComponent("index-state.json")

    static var savedAt: Date? {
        (try? FileManager.default.attributesOfItem(atPath: stateFile.path))?[.modificationDate] as? Date
    }

    /// The position of the scope saved longest ago, when the saved positions are from this disk's FSEvents history.
    static func oldestPosition() -> UInt64? {
        guard let data = try? Data(contentsOf: stateFile), let state = try? JSONDecoder().decode(State.self, from: data),
              state.system == FSEventsHistory.systemBuild, state.fseventsUUID == FSEventsHistory.fseventsUUID
        else { return nil }
        let current = FSEventsGetCurrentEventId()
        return state.eventIDs.values.filter { $0 > 0 && $0 <= current }.min()
    }

    /// The busy folders Cling leaves out of its own stream, which nothing indexed is inside.
    static func unwatchedFolders() -> [String] {
        guard let data = try? Data(contentsOf: ChangeJournal.folder.appendingPathComponent("unwatched-folders.json")),
              let unwatched = try? JSONDecoder().decode(Unwatched.self, from: data)
        else { return [] }
        return unwatched.folders.map(\.path)
    }

    private struct State: Decodable {
        var eventIDs: [String: UInt64]
        var system: String
        var fseventsUUID: String
    }

    private struct Unwatched: Decodable {
        struct Folder: Decodable {
            var path: String
        }

        var folders: [Folder]
    }

}

// MARK: - Replay

/// Reads the FSEvents history from a position up to now, merging what happened to each path.
private final class Replay {
    init(since: UInt64, excluding: [String], changes: [String: UInt32]) {
        self.since = since
        self.excluding = excluding
        self.changes = changes
        lastID = since
    }

    private(set) var changes: [String: UInt32]
    private(set) var lastID: UInt64
    private(set) var events = 0
    private(set) var lost = false

    /// Whether it reached the end of the history in time.
    func run(timeLimit: TimeInterval) -> Bool {
        let queue = DispatchQueue(label: "com.lowtechguys.Cling.catch-up", qos: .background)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            let replay = Unmanaged<Replay>.fromOpaque(info).takeUnretainedValue()
            let cPaths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            for i in 0 ..< count {
                replay.take(path: String(cString: cPaths[i]), flags: flags[i], id: ids[i])
            }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, ["/"] as CFArray, since, 0.5, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        ) else { return false }
        if !excluding.isEmpty {
            FSEventStreamSetExclusionPaths(stream, excluding as CFArray)
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        let finished = finishedSignal.wait(timeout: .now() + timeLimit) == .success
        queue.sync {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        return finished
    }

    private let since: UInt64
    private let excluding: [String]
    private let finishedSignal = DispatchSemaphore(value: 0)
    private var finished = false

    private func take(path raw: String, flags: FSEventStreamEventFlags, id: UInt64) {
        guard !finished else { return }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 {
            lastID = max(lastID, id)
            finish()
            return
        }
        let droppedOrWrapped = FSEventStreamEventFlags(
            kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped
        )
        if flags & droppedOrWrapped != 0
            || (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 && FSEventsHistory.isRoot(raw))
        {
            lost = true
            finish()
            return
        }
        events += 1
        lastID = max(lastID, id)
        guard let path = FSEventsHistory.normalized(raw) else { return }
        changes[path, default: 0] |= UInt32(flags)
        if changes.count > ChangeJournal.maxPaths {
            lost = true
            finish()
        }
    }

    private func finish() {
        finished = true
        finishedSignal.signal()
    }
}
