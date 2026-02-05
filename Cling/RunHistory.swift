import Defaults
import Foundation
import System

extension Defaults.Keys {
    static let runHistory = Key<[String: RunHistory.Entry]>("runHistory", default: [:])
}

@MainActor @Observable
final class RunHistory {
    struct Entry: Codable, Defaults.Serializable {
        var count: Int
        var lastRun: Date
    }

    static let shared = RunHistory()

    private(set) var entries: [String: Entry] = Defaults[.runHistory]

    func trackRun(_ paths: [FilePath]) {
        let query = FUZZY.query
        if !query.isEmpty { SearchHistory.shared.commit(query) }

        let now = Date()
        for path in paths {
            let key = path.string
            var entry = entries[key] ?? Entry(count: 0, lastRun: now)
            entry.count += 1
            entry.lastRun = now
            entries[key] = entry
        }
        Defaults[.runHistory] = entries
    }

    func trackRun(_ paths: Set<FilePath>) {
        trackRun(Array(paths))
    }

    func clearAll() {
        entries.removeAll()
        Defaults[.runHistory] = entries
    }

    /// Returns file paths sorted by run count (descending), then by last run date (descending)
    func topResults(limit: Int = 500) -> [FilePath] {
        entries.sorted { a, b in
            if a.value.count != b.value.count { return a.value.count > b.value.count }
            return a.value.lastRun > b.value.lastRun
        }
        .prefix(limit)
        .map { FilePath($0.key) }
        .filter(\.exists)
    }
}

let RH = RunHistory.shared
