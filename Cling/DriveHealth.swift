import Darwin
import Foundation

// MARK: - DriveHealth

/// What following one drive costs, kept for as long as Cling runs: how many changes arrive, how long the drive takes to
/// answer for each file, how far behind its index runs and how much processor time goes to it. A drive that keeps
/// Cling busy or answers slowly stands out in Settings, beside the toggle that stops following it.
///
/// A drive's changes are read at background priority, and while something else writes to the drive macOS holds those
/// reads back so they stay out of its way. Timings taken then say more about the copy than about the drive, so they
/// are kept apart from the ones taken while the drive was quiet, and only the quiet ones are judged. What is judged
/// either way is Cling falling behind: a drive written to without end that it can't keep up with leaves search further
/// out of date the longer it goes on, where a copy holds it back for a few minutes at most.
final class DriveHealth: @unchecked Sendable {
    enum Level: Int, Comparable, Sendable {
        case good
        case slow
        case bad

        /// `slow` from the first threshold on, `bad` from the second.
        init(_ value: Double, slow: Double, bad: Double) {
            self = value >= bad ? .bad : value >= slow ? .slow : .good
        }

        var verdict: String {
            switch self {
            case .good: "healthy"
            case .slow: "slow"
            case .bad: "struggling"
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

    }

    /// The values over the last `window`, and the totals since the drive was first followed.
    struct Snapshot: Sendable {
        var changesPerMinute: Double
        /// Milliseconds the drive took to answer for each file checked, nil when none was.
        var msPerFile: Double?
        /// The longest a batch of changes waited before it was in the index, nil when none came.
        var lag: Double?
        /// `msPerFile` was only measured while the drive was being written to, and isn't judged.
        var fileWhileWritten: Bool
        /// `lag` was only measured while the drive was being written to, and isn't judged.
        var lagWhileWritten: Bool
        /// The share of one core's time spent applying the drive's changes.
        var busy: Double
        /// The share of the time a change on the drive had waited longer than `behindAfter` and wasn't in the index.
        var behind: Double
        var changes: Int
        /// Bursts FSEvents dropped changes from, whose folders were walked again.
        var drops: Int
        var since: Date
        /// How long the drive's last unmount waited for Cling to let go of it.
        var lastEject: Double?

        /// A slow hard drive answers in around 10 ms, a failing one or a stalled connection in hundreds.
        var fileLevel: Level {
            fileWhileWritten ? .good : msPerFile.map { Level($0, slow: 30, bad: 200) } ?? .good
        }
        var behindLevel: Level {
            Level(behind, slow: 0.3, bad: 0.7)
        }
        var lagLevel: Level {
            max(lagWhileWritten ? .good : lag.map { Level($0, slow: 10, bad: 60) } ?? .good, behindLevel)
        }
        var busyLevel: Level {
            Level(busy, slow: 0.05, bad: 0.2)
        }
        /// Red once the eject waited as long as it ever does: something reading the drive didn't stop in time.
        var ejectLevel: Level {
            lastEject.map { Level($0, slow: 2, bad: DriveRelease.longestWait - 0.05) } ?? .good
        }
        var level: Level {
            max(fileLevel, lagLevel, busyLevel, ejectLevel)
        }
    }

    /// The values shown cover this long.
    static let window: CFTimeInterval = 10 * 60

    /// A change waiting longer than this to reach the index leaves Cling behind the drive.
    static let behindAfter: CFTimeInterval = 30

    /// The drive mounted at `volume`, kept by its mount point until Cling quits.
    static func of(_ volume: String) -> DriveHealth {
        registryLock.withLock {
            if let health = registry[volume] {
                return health
            }
            let health = DriveHealth()
            registry[volume] = health
            return health
        }
    }

    static func existing(_ volume: String) -> DriveHealth? {
        registryLock.withLock { registry[volume] }
    }

    /// The last 10 minutes as they stand at `date`.
    func snapshot(at date: Date = Date()) -> Snapshot {
        let now = date.timeIntervalSinceReferenceDate
        return lock.withLock {
            settle(now)
            prune(now)
            // Over the whole window even when following started later: a catch-up after launch, or one burst, is
            // a moment's work and shouldn't read as a drive that keeps Cling busy.
            let span = Self.window
            let applyingCPU = applying.map { max(0, Self.processorTime($0.thread) - $0.cpu) } ?? 0
            let quiet = minutes.reduce(into: Timings()) { $0.add($1.quiet) }
            let written = minutes.reduce(into: Timings()) { $0.add($1.written) }
            // The drive's own speed when it was quiet at all, what a copy left it at otherwise.
            let files = quiet.files > 0 ? quiet : written
            return Snapshot(
                changesPerMinute: Double(minutes.reduce(0) { $0 + $1.changes }) / (span / 60),
                msPerFile: files.files > 0 ? files.fileSeconds / Double(files.files) * 1000 : nil,
                lag: quiet.lag ?? written.lag,
                fileWhileWritten: quiet.files == 0 && written.files > 0,
                lagWhileWritten: quiet.lag == nil && written.lag != nil,
                busy: min(1, (minutes.reduce(0) { $0 + $1.cpu } + applyingCPU) / span),
                behind: behindSeconds(now) / span,
                changes: changes, drops: drops, since: Date(timeIntervalSinceReferenceDate: started), lastEject: lastEject
            )
        }
    }

    /// A batch of changes is being applied on the calling thread, `arrived` when its first change came as it was made.
    /// Until it is done, the time it keeps Cling behind and the processor time it takes count already: a drive Cling
    /// can't keep up with is applied in ever longer batches, one walk of its busiest folders taking minutes.
    func startedApplying(arrived: CFAbsoluteTime?) {
        let thread = mach_thread_self()
        let cpu = Self.processorTime(thread)
        lock.withLock {
            releaseApplyingThread()
            applyingSince = arrived
            applying = (thread, cpu)
        }
    }

    /// The batch being applied was dropped.
    func stoppedApplying() {
        lock.withLock {
            applyingSince = nil
            releaseApplyingThread()
        }
    }

    /// FSEvents delivered changes as they were made, `count` of them could reach the index.
    func noteChanges(_ count: Int) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.withLock {
            settle(now)
            // The drive was still being written to after these batches were taken.
            for batch in held {
                commit(batch.timings, quiet: false, at: now)
            }
            held.removeAll()
            if deliveries.count >= Self.deliveriesKept {
                deliveries.removeFirst(deliveries.count / 2)
            }
            deliveries.append(now)
            guard count > 0 else { return }
            updateMinute(now) { $0.changes += count }
            changes += count
        }
    }

    /// A batch was applied: taken from the pending changes at `taken`, the first of which arrived at `arrived`, using
    /// `cpu` seconds of processor time. `files` were checked on the drive in `fileSeconds`, and `lag` passed between
    /// the first change arriving and the batch being in the index.
    func noteBatch(taken: CFAbsoluteTime, arrived: CFAbsoluteTime?, cpu: Double, files: Int, fileSeconds: Double, lag: Double?) {
        let now = CFAbsoluteTimeGetCurrent()
        let timings = Timings(files: files, fileSeconds: fileSeconds, lag: lag)
        lock.withLock {
            settle(now)
            applyingSince = nil
            releaseApplyingThread()
            updateMinute(now) { $0.cpu += cpu }
            if let lag, lag > Self.behindAfter {
                noteBehind(from: now - lag + Self.behindAfter, to: now)
            }
            guard timings.files > 0 || timings.lag != nil else { return }
            let first = arrived ?? taken
            // Changes arriving shortly before the batch's first one, while it waited or while it was applied come from
            // writes still going on. Its first change arrived with one of them.
            let writtenAround = deliveries.reversed().lazy.prefix { $0 >= first - Self.quietGap }.count > 1
            if writtenAround {
                commit(timings, quiet: false, at: now)
            } else {
                // Judged once it is known whether more changes followed.
                held.append((until: taken + Self.quietGap, timings: timings))
            }
        }
    }

    func noteDrop() {
        lock.withLock { drops += 1 }
    }

    func noteEject(_ seconds: Double) {
        lock.withLock { lastEject = seconds }
    }

    private struct Timings {
        var files = 0
        var fileSeconds = 0.0
        var lag: Double?

        mutating func add(_ other: Self) {
            files += other.files
            fileSeconds += other.fileSeconds
            if let lag = other.lag {
                self.lag = max(self.lag ?? 0, lag)
            }
        }
    }

    private struct Minute {
        let index: Int
        var changes = 0
        var cpu = 0.0
        var quiet = Timings()
        var written = Timings()
    }

    /// FSEvents delivers a drive's changes every 2 seconds while they keep coming: changes that close together come from
    /// the same writes.
    private static let quietGap: CFTimeInterval = 3

    private static let registryLock = NSLock()
    private nonisolated(unsafe) static var registry: [String: DriveHealth] = [:]

    private static let deliveriesKept = 4096

    private let lock = NSLock()
    private let started = CFAbsoluteTimeGetCurrent()
    /// One per minute that had something, the oldest first.
    private var minutes: [Minute] = []
    /// When FSEvents delivered changes lately, the oldest first. A batch can wait minutes behind others on a slow
    /// drive, so more are kept than one `quietGap`.
    private var deliveries: [CFAbsoluteTime] = []
    /// Batches applied while the drive seemed quiet, until it is known whether more changes followed them.
    private var held: [(until: CFAbsoluteTime, timings: Timings)] = []
    private var changes = 0
    private var drops = 0
    private var lastEject: Double?
    /// When Cling was behind the drive, the oldest first, none overlapping.
    private var behindSpans: [(start: CFAbsoluteTime, end: CFAbsoluteTime)] = []
    /// When the first change of the batch being applied arrived.
    private var applyingSince: CFAbsoluteTime?
    /// The thread applying a batch, and its processor time when it started.
    private var applying: (thread: thread_act_t, cpu: Double)?

    /// Seconds of processor time `thread` has used.
    private static func processorTime(_ thread: thread_act_t) -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds + info.system_time.seconds)
            + Double(info.user_time.microseconds + info.system_time.microseconds) / 1_000_000
    }

    /// Under `lock`.
    private func releaseApplyingThread() {
        if let thread = applying?.thread {
            mach_port_deallocate(mach_task_self_, thread)
        }
        applying = nil
    }

    private func noteBehind(from start: CFAbsoluteTime, to end: CFAbsoluteTime) {
        if let last = behindSpans.last, start <= last.end {
            behindSpans[behindSpans.count - 1] = (min(last.start, start), max(last.end, end))
        } else {
            behindSpans.append((start, end))
        }
    }

    /// Under `lock`.
    private func behindSeconds(_ now: CFAbsoluteTime) -> Double {
        let from = now - Self.window
        behindSpans.removeAll { $0.end < from }
        var spans = behindSpans
        if let since = applyingSince, now - since > Self.behindAfter {
            let start = since + Self.behindAfter
            if let last = spans.last, start <= last.end {
                spans[spans.count - 1] = (min(last.start, start), now)
            } else {
                spans.append((start, now))
            }
        }
        return spans.reduce(0) { $0 + max(0, $1.end - max($1.start, from)) }
    }

    /// Changes the current minute's counts, under `lock`.
    private func updateMinute(_ now: CFAbsoluteTime, _ change: (inout Minute) -> Void) {
        prune(now)
        let index = Int(now / 60)
        if minutes.last?.index != index {
            minutes.append(Minute(index: index))
        }
        change(&minutes[minutes.count - 1])
    }

    /// Batches held long enough with nothing after them were applied on a quiet drive. Under `lock`.
    private func settle(_ now: CFAbsoluteTime) {
        guard held.contains(where: { $0.until <= now }) else { return }
        for batch in held where batch.until <= now {
            commit(batch.timings, quiet: true, at: now)
        }
        held.removeAll { $0.until <= now }
    }

    private func commit(_ timings: Timings, quiet: Bool, at now: CFAbsoluteTime) {
        updateMinute(now) { minute in
            if quiet {
                minute.quiet.add(timings)
            } else {
                minute.written.add(timings)
            }
        }
    }

    private func prune(_ now: CFAbsoluteTime) {
        let oldest = Int((now - Self.window) / 60)
        minutes.removeAll { $0.index <= oldest }
    }
}
