import Defaults
import Foundation

extension Defaults.Keys {
    static let searchHistory = Key<[String]>("searchHistory", default: [])
}

@MainActor @Observable
final class SearchHistory {
    static let shared = SearchHistory()
    static let maxEntries = 200

    /// All history entries, most recent first
    private(set) var entries: [String] = Defaults[.searchHistory]

    /// Commit a query to history (only call when user acted on results)
    func commit(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, q.count >= 2 else { return }

        // Move to front if already exists, otherwise prepend
        entries.removeAll { $0 == q }
        entries.insert(q, at: 0)

        // Cap size
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }

        Defaults[.searchHistory] = entries
    }

    /// Remove a query from history
    func remove(_ query: String) {
        entries.removeAll { $0 == query }
        Defaults[.searchHistory] = entries
    }

    /// Clear all history
    func clearAll() {
        entries.removeAll()
        Defaults[.searchHistory] = entries
    }

    /// Get suggestions matching the current input, most recent first
    func suggestions(for input: String) -> [String] {
        let q = input.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return entries }

        return entries.filter { entry in
            let lower = entry.lowercased()
            // Match if input is a prefix, or if all input words appear in the entry
            if lower.hasPrefix(q) { return true }
            let words = q.split(separator: " ")
            return words.allSatisfy { lower.contains($0) }
        }
    }

    /// Navigate history by index (0 = most recent). Returns nil if out of bounds.
    func entry(at index: Int) -> String? {
        guard index >= 0, index < entries.count else { return nil }
        return entries[index]
    }
}
