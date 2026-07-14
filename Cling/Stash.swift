import Defaults
import Foundation
import Observation
import System

/// Sentinel for `Defaults[.shelfApp]` meaning Cling's built-in stash instead of an external shelf app.
let CLING_STASH_APP = "cling://stash"

// MARK: - StashEntry

struct StashEntry: Codable, Hashable, Defaults.Serializable {
    let path: String
    let stashedAt: Date
}

extension Defaults.Keys {
    static let stashedFiles = Key<[StashEntry]>("stashedFiles", default: [])
    /// Files are removed from the stash after being stashed for this long. 0 = never.
    static let stashAutoClearAfter = Key<TimeInterval>("stashAutoClearAfter", default: 0)
}

/// Slider snap points for the auto-clear period: Never, hourly up to 1 day,
/// daily up to 1 week, then weekly up to 1 month.
let STASH_AUTO_CLEAR_PRESETS: [TimeInterval] = {
    var presets: [TimeInterval] = [0]
    for hour in 1 ... 23 {
        presets.append(TimeInterval(hour) * 3600)
    }
    for day in 1 ... 7 {
        presets.append(TimeInterval(day) * 86400)
    }
    for day in [14, 21, 30] {
        presets.append(TimeInterval(day) * 86400)
    }
    return presets
}()

func nearestStashAutoClearPresetIndex(_ value: TimeInterval) -> Int {
    guard value > 0 else { return 0 }
    return STASH_AUTO_CLEAR_PRESETS.enumerated().min { abs($0.element - value) < abs($1.element - value) }?.offset ?? 0
}

func stashAutoClearLabel(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded())
    switch s {
    case ..<1: return "Never"
    case ..<86400: let h = s / 3600; return "\(h) hour\(h == 1 ? "" : "s")"
    case ..<(8 * 86400): let d = s / 86400; return "\(d) day\(d == 1 ? "" : "s")"
    case ..<(30 * 86400): let w = s / (7 * 86400); return "\(w) week\(w == 1 ? "" : "s")"
    default: return "1 month"
    }
}

// MARK: - StashManager

/// The built-in stash: a user-curated list of files pinned above search results in the main window.
/// Fully editable (the Stash action toggles the selection in and out, right-click adds/removes)
/// and persisted across restarts. Rows keep every file action since they render as table rows.
@MainActor @Observable
final class StashManager {
    init() {
        let now = Date()
        var seen = Set<String>()
        for entry in Defaults[.stashedFiles] where !seen.contains(entry.path) {
            guard let path = entry.path.existingFilePath else { continue }
            seen.insert(entry.path)
            files.append(path)
            stashedAt[path] = min(entry.stashedAt, now)
        }
        fileSet = Set(files)
        persist()
        pruneExpired()
        // Re-arm the expiry timer whenever the auto-clear period setting changes.
        Task { @MainActor in
            for await _ in Defaults.updates(.stashAutoClearAfter) {
                pruneExpired()
            }
        }
    }

    static let shared = StashManager()

    private(set) var files: [FilePath] = []
    private(set) var fileSet: Set<FilePath> = []

    func contains(_ path: FilePath) -> Bool {
        fileSet.contains(path)
    }

    func add(_ paths: [FilePath]) {
        let new = paths.filter { !fileSet.contains($0) }
        guard !new.isEmpty else { return }
        files.append(contentsOf: new)
        fileSet.formUnion(new)
        let now = Date()
        new.forEach { stashedAt[$0] = now }
        persist()
        scheduleExpiry()
    }

    func remove(_ paths: some Collection<FilePath>) {
        let gone = Set(paths)
        guard !gone.isDisjoint(with: fileSet) else { return }
        files.removeAll { gone.contains($0) }
        fileSet.subtract(gone)
        gone.forEach { stashedAt.removeValue(forKey: $0) }
        persist()
        scheduleExpiry()
    }

    /// One-hotkey editing: if everything in `paths` is already stashed, unstash it;
    /// otherwise stash whatever is missing.
    func toggle(_ paths: [FilePath]) {
        guard !paths.isEmpty else { return }
        if paths.allSatisfy({ fileSet.contains($0) }) {
            remove(paths)
        } else {
            add(paths)
        }
    }

    func clear() {
        files = []
        fileSet = []
        stashedAt = [:]
        persist()
        scheduleExpiry()
    }

    /// Drop entries older than the auto-clear period, then re-arm the timer for the next expiry.
    func pruneExpired() {
        let period = Defaults[.stashAutoClearAfter]
        guard period > 0 else {
            expiryTask?.cancel()
            expiryTask = nil
            return
        }
        let cutoff = Date().addingTimeInterval(-period)
        let expired = files.filter { (stashedAt[$0] ?? .distantPast) < cutoff }
        if expired.isEmpty {
            scheduleExpiry()
        } else {
            remove(expired) // remove() persists and reschedules
        }
    }

    @ObservationIgnored private var stashedAt: [FilePath: Date] = [:]
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        let period = Defaults[.stashAutoClearAfter]
        guard period > 0, let oldest = stashedAt.values.min() else { return }
        let delay = max(0, oldest.addingTimeInterval(period).timeIntervalSinceNow)
        expiryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            pruneExpired()
        }
    }

    private func persist() {
        Defaults[.stashedFiles] = files.map {
            StashEntry(path: $0.string, stashedAt: stashedAt[$0] ?? Date())
        }
    }
}

@MainActor let STASH = StashManager.shared
