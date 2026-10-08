import AppKit
import Defaults
import Foundation
import Lowtech
import OSLog

// MARK: - FilterAutoOff

/// How long a filter stays on once Cling is in the background with the search bar closed. Settings holds the
/// default for every filter, and a quick or folder filter can carry its own.
struct FilterAutoOff: Codable, Hashable, Defaults.Serializable {
    static let defaultAfter: TimeInterval = 300
    static let range: ClosedRange<TimeInterval> = 10 ... 86400

    /// The default from Settings.
    @MainActor static var current: FilterAutoOff {
        FilterAutoOff(enabled: Defaults[.filterAutoOff], after: Defaults[.filterAutoOffAfter])
    }

    var enabled = true
    var after: TimeInterval = defaultAfter

    /// Seconds in the background before the filter turns off, nil when it stays on.
    var period: TimeInterval? {
        enabled ? after.clamped(to: Self.range) : nil
    }
}

extension QuickFilter {
    @MainActor var autoOffPeriod: TimeInterval? {
        (autoOff ?? .current).period
    }
}

extension FolderFilter {
    @MainActor var autoOffPeriod: TimeInterval? {
        (autoOff ?? .current).period
    }
}

// MARK: - AutoOffDuration

/// The duration the auto-off slider and field work with: a slider with even steps between clean values from
/// seconds to a day, and text a person can type in any unit.
enum AutoOffDuration {
    /// Spaced evenly along the slider, so seconds, minutes and hours each get room.
    static let anchors: [TimeInterval] = [10, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 14400, 28800, 43200, 86400]

    /// Where `seconds` sits along the slider, from 0 to `anchors.count - 1`.
    static func position(for seconds: TimeInterval) -> Double {
        let s = seconds.clamped(to: FilterAutoOff.range)
        guard let upper = anchors.firstIndex(where: { $0 >= s }), upper > 0 else { return 0 }
        let low = anchors[upper - 1], high = anchors[upper]
        return Double(upper - 1) + (s - low) / (high - low)
    }

    /// The value at a slider position, pulled onto an anchor near one and rounded to a readable step between them.
    static func seconds(at position: Double) -> TimeInterval {
        let p = position.clamped(to: 0 ... Double(anchors.count - 1))
        let lower = min(Int(p), anchors.count - 2)
        let t = p - Double(lower)
        if t < magneticFraction {
            return anchors[lower]
        }
        if t > 1 - magneticFraction {
            return anchors[lower + 1]
        }
        let raw = anchors[lower] + (anchors[lower + 1] - anchors[lower]) * t
        let step: TimeInterval = raw < 60 ? 5 : raw < 3600 ? 60 : 900
        return ((raw / step).rounded() * step).clamped(to: FilterAutoOff.range)
    }

    /// Reads `90s`, `5 min`, `1h 30m`, `2 hours` and the like. A bare number takes the unit `current` shows in, so
    /// replacing the 5 of `5 minutes` with 10 gives ten minutes. nil for text that is not a duration. Not clamped to
    /// `FilterAutoOff.range`: the field clamps, the CLI and agents get told.
    static func parse(_ text: String, current: TimeInterval) -> TimeInterval? {
        let scanner = Scanner(string: text.lowercased())
        scanner.charactersToBeSkipped = .whitespaces.union(CharacterSet(charactersIn: ","))
        var total: TimeInterval = 0
        var parsedAny = false
        while !scanner.isAtEnd {
            guard let number = scanner.scanDouble(), number >= 0 else { return nil }
            let unit = scanner.scanCharacters(from: .letters) ?? ""
            guard let multiplier = unit.isEmpty ? displayUnit(for: current) : units[unit] else { return nil }
            total += number * multiplier
            parsedAny = true
        }
        guard parsedAny else { return nil }
        // Past an hour the field shows hours and minutes, so seconds there would be kept but never shown.
        return total < 3600 ? total.rounded() : (total / 60).rounded() * 60
    }

    static func clamped(_ seconds: TimeInterval) -> TimeInterval {
        seconds.clamped(to: FilterAutoOff.range)
    }

    /// Why `seconds` can't be an auto-off time, nil when it can.
    static func problem(_ seconds: TimeInterval) -> String? {
        FilterAutoOff.range.contains(seconds) ? nil : "an auto-off time is from 10 seconds to 24 hours"
    }

    /// How a duration reads in the field: `45 seconds`, `5 minutes`, `1 hour 30 minutes`.
    static func text(_ seconds: TimeInterval) -> String {
        seconds.clamped(to: FilterAutoOff.range).humanizedInterval
    }

    /// Fraction of each gap next to an anchor that snaps onto it.
    private static let magneticFraction = 0.12

    private static let units: [String: TimeInterval] = [
        "s": 1, "sec": 1, "secs": 1, "second": 1, "seconds": 1,
        "m": 60, "min": 60, "mins": 60, "minute": 60, "minutes": 60,
        "h": 3600, "hr": 3600, "hrs": 3600, "hour": 3600, "hours": 3600,
        "d": 86400, "day": 86400, "days": 86400,
    ]

    /// The largest unit `humanizedInterval` writes `seconds` in.
    private static func displayUnit(for seconds: TimeInterval) -> TimeInterval {
        seconds < 60 ? 1 : seconds < 3600 ? 60 : seconds < 86400 ? 3600 : 86400
    }
}

// MARK: - FilterAutoOffMonitor

/// Turns the quick, folder and drive filters off once Cling has spent their auto-off time in the background with the
/// search bar closed, so a filter picked for one search doesn't quietly narrow the next one.
///
/// The time counts from when Cling went to the background, or from when the filter was turned on if that came later
/// (the CLI can turn one on while Cling is away).
@MainActor
final class FilterAutoOffMonitor {
    private init() {
        // Settings, the CLI and agents can change a period while Cling is away.
        settingsObserver = Task { @MainActor [weak self] in
            for await _ in Defaults.updates([.filterAutoOff, .filterAutoOffAfter, .quickFilters, .folderFilters], initial: false) {
                guard let self, awaySince != nil else { continue }
                schedule()
            }
        }
    }

    enum Kind: CaseIterable {
        case quick, folder, volume
    }

    static let shared = FilterAutoOffMonitor()

    /// Cling may have come into use or left it: the app activated or resigned, a window showed, hid or closed, or the
    /// search bar expanded or collapsed.
    func update() {
        evaluate()
        // Windows close and focus moves on a moment after the calls that announce it.
        DispatchQueue.main.async { [self] in
            evaluate()
        }
    }

    /// A filter was turned on, off or swapped. Its time starts over.
    func noteChange(_ kind: Kind) {
        changedAt[kind] = .now
        if awaySince != nil, !turningOff {
            schedule()
        }
    }

    private var awaySince: Date?
    private var changedAt: [Kind: Date] = [:]

    private var timer: Task<Void, Never>?
    private var turnedOffWhileAway = false
    /// Turning one filter off can take another with it, which reschedules once at the end instead of in between.
    private var turningOff = false
    private var settingsObserver: Task<Void, Never>?

    /// The search bar is open, or one of Cling's windows has the keyboard: the main window or Settings. Cling active
    /// with nothing on screen is not use, which happens when the bar closes and the app before it can't be brought back.
    private var inUse: Bool {
        SB.isExpanded || NSApp.isActive && NSApp.windows.contains { $0.isVisible && $0.isKeyWindow }
    }

    private func evaluate() {
        if inUse {
            // A Mac that slept through the deadline comes back before the timer catches up, so check here too.
            turnOffExpired(now: .now)
            awaySince = nil
            timer?.cancel()
            timer = nil
            // Turned off while nothing showed results, the search that drops the filter could not run then.
            if turnedOffWhileAway, WM.searchUIActive {
                turnedOffWhileAway = false
                FUZZY.performSearch()
            }
        } else if awaySince == nil {
            awaySince = .now
            schedule()
        }
    }

    /// Seconds the active filter of this kind stays on, nil when none is on or it never turns off.
    private func period(_ kind: Kind) -> TimeInterval? {
        switch kind {
        case .quick:
            guard let filter = FUZZY.quickFilter else { return nil }
            // The active copy can be a rebuilt one (folders merged in), the saved filter has the user's setting.
            return (Defaults[.quickFilters].first { $0.uuid == filter.uuid } ?? filter).autoOffPeriod
        case .folder:
            guard let filter = FUZZY.folderFilter else { return nil }
            if let saved = Defaults[.folderFilters].first(where: { $0.uuid == filter.uuid }) {
                return saved.autoOffPeriod
            }
            // A quick filter with folders turns them on as a folder filter of its own, which goes off with it.
            return FUZZY.folderFilterIsQuickFilters ? nil : FilterAutoOff.current.period
        case .volume:
            return FUZZY.volumeFilter == nil ? nil : FilterAutoOff.current.period
        }
    }

    private func deadline(_ kind: Kind) -> Date? {
        guard let awaySince, let period = period(kind) else { return nil }
        return max(awaySince, changedAt[kind] ?? awaySince).addingTimeInterval(period)
    }

    private func schedule() {
        timer?.cancel()
        guard let next = Kind.allCases.compactMap(deadline).min() else {
            timer = nil
            return
        }
        // The continuous clock keeps counting while the Mac sleeps, so a deadline passed in sleep fires on wake.
        let delay = max(next.timeIntervalSinceNow, 0)
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(1), clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            turnOffExpired(now: .now)
            schedule()
        }
    }

    private func turnOffExpired(now: Date) {
        let expired = Set(Kind.allCases.filter { deadline($0).map { $0 <= now } ?? false })
        guard !expired.isEmpty else { return }
        log.debug("Turning off filters after their auto-off time: \(String(describing: expired), privacy: .public)")
        turningOff = true
        defer { turningOff = false }
        // Quick first: one with folders takes its own folder filter off with it.
        if expired.contains(.quick) {
            FUZZY.quickFilter = nil
        }
        if expired.contains(.folder), FUZZY.folderFilter != nil {
            FUZZY.folderFilter = nil
        }
        if expired.contains(.volume) {
            FUZZY.volumeFilter = nil
        }
        if !WM.searchUIActive {
            turnedOffWhileAway = true
        }
    }
}

private let log = Logger(subsystem: clingSubsystem, category: "FilterAutoOff")

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
