import CoreServices
import Foundation
import Lowtech
import System

// MARK: - LauncherApps

/// The apps installed on this Mac, in an index of their own, so the search bar can work as a launcher with nothing to
/// set up. An app's name loses among a home folder's files to folders and documents of the same name, and its
/// initials or a misspelling of it rarely bring it up at all. Searched alone, the few hundred apps answer to the same
/// matching as everything else, and the ones whose names match go to the top of the bar.
final class LauncherApps: @unchecked Sendable {
    /// An app matched by name, for the top of the search bar.
    struct Match: Sendable {
        let path: String
        /// Higher first: how the name matched, then how well.
        let rank: Int
    }

    /// An installed app, with when it was last opened.
    struct App: Sendable {
        let path: String
        let lastUsed: Date
    }

    static let shared = LauncherApps()

    /// Most apps the bar puts first.
    static let mostShown = 3

    /// The app's name, without the folder or `.app`.
    static func name(_ path: String) -> String {
        let file = path.split(separator: "/").last.map(String.init) ?? path
        return file.lowercased().hasSuffix(".app") ? String(file.dropLast(4)) : file
    }

    /// Letters and digits only, so `google chrome`, `google-chrome` and `googlechrome` read the same.
    static func compact(_ text: String) -> String {
        String(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// The first letter of each word, a word starting at a capital inside a name too: `btt` for BetterTouchTool,
    /// `vsc` for Visual Studio Code.
    static func initials(_ name: String) -> String {
        var initials = ""
        for word in name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            var previous: Character?
            for character in word {
                let starts = previous == nil || character.isUppercase && previous!.isLowercase
                    || character.isNumber != previous!.isNumber
                if starts {
                    initials.append(character)
                }
                previous = character
            }
        }
        return initials.lowercased()
    }

    /// One letter wrong, missing, extra or swapped with the next, or two in a longer name, against the name or its
    /// start: `binidff` for BinDiff, `firefx` for Firefox Developer Edition.
    static func misspells(_ query: String, _ name: String) -> Bool {
        let length = query.count
        guard length >= 5 else { return false }
        let allowed = length >= 9 ? 2 : 1
        let q = Array(query), n = Array(name)
        return [length - 1, length, length + 1, n.count].contains { end in
            end > 0 && end <= n.count && editDistance(q, Array(n[..<end]), within: allowed) <= allowed
        }
    }

    /// Lists the app folders again, off the main thread, once a minute at most: an app installed or deleted shows up
    /// the next time the bar is used.
    func refreshIfStale() {
        let now = CFAbsoluteTimeGetCurrent()
        let stale = lock.withLock {
            guard !scanning, now - scannedAt > 60 else { return false }
            scanning = true
            return true
        }
        guard stale else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            _ = scan()
        }
    }

    /// The installed apps whose names match `query` the way someone launching one types it, best first: the whole name,
    /// its start, its initials or the start of one of its words, then Cling's own fuzzy reading, and misspellings
    /// only when nothing matched as typed. Where an app is installed doesn't count, and between two equal matches the
    /// one opened last goes first, then the shorter name: `code` finds the editor used every day ahead of a helper
    /// app that only handles links, and `musi` finds Music ahead of Music Decoy. The first search lists the app folders.
    /// `results`: the paths the search found first. One whose name starts with what was typed was found as typed
    /// (`pdf` finds a folder of PDFs, `contract` a folder of Contracts), and only an app matched by its whole name,
    /// its start, its initials or a word goes above it, never one spelt differently or with its letters scattered.
    func matches(_ query: String, literalDefault: Bool, results: [String] = []) -> [Match] {
        let (engine, apps) = lock.withLock { self.engine.map { ($0, self.apps) } } ?? scan()
        let typed = query.trimmingCharacters(in: .whitespaces)
        let literal = literalDefault || typed.hasPrefix("'")
        let text = (typed.hasPrefix("'") ? String(typed.dropFirst()) : typed).lowercased()
        let compactQuery = Self.compact(text)
        guard compactQuery.count >= 2 else { return [] }

        // The index holds the names without `.app`, so its letters can't help a match along.
        let fuzzy = literal ? [:] : Dictionary(
            engine.search(query: typed, maxResults: 30, literalDefault: literalDefault).filter(\.hasBase).map { ($0.path + ".app", $0) },
            uniquingKeysWith: { a, _ in a }
        )
        let bestFuzzy = fuzzy.values.filter { $0.typos == 0 }.map(\.quality).max() ?? 0

        var found: [(match: Match, lastUsed: Date, length: Int)] = []
        for app in apps {
            let path = app.path
            let name = Self.name(path)
            let lower = name.lowercased()
            let compactName = Self.compact(lower)
            // Abbreviations start where a word does: `sfr` reads as Safari, `sss` doesn't as Messages.
            let startsAWord = compactQuery.first.map { Self.initials(name).contains($0) } ?? false
            let tier: Int
            var quality = 0
            if compactName == compactQuery {
                tier = 6
            } else if lower.hasPrefix(text) || compactName.hasPrefix(compactQuery) {
                tier = 5
            } else if !literal, Self.initials(name).hasPrefix(compactQuery) || Self.words(lower).map { $0.prefix(1) }.joined().hasPrefix(compactQuery)
                || Self.words(lower).contains(where: { $0.hasPrefix(text) })
            {
                tier = 4
            } else if text.count >= 3 && lower.contains(text)
                || !literal && startsAWord && fuzzy[path].map({ $0.typos == 0 && $0.quality >= bestFuzzy / 3 }) == true
            {
                tier = 3
                quality = fuzzy[path]?.quality ?? 0
            } else if !literal, startsAWord && fuzzy[path].map({ $0.typos > 0 }) == true || Self.misspells(compactQuery, compactName) {
                tier = 1
                quality = fuzzy[path]?.quality ?? 0
            } else {
                continue
            }
            found.append((Match(path: path, rank: tier * 100_000 + min(quality, 99999)), app.lastUsed, lower.count))
        }
        // Misspellings only stand in for nothing better.
        if found.contains(where: { $0.match.rank >= 300_000 }) {
            found.removeAll { $0.match.rank < 300_000 }
        }
        let foundAsTyped = results.prefix(FuzzyClient.launcherReach).contains { result in
            let file = result.split(separator: "/").last.map(String.init) ?? result
            return file.lowercased().hasPrefix(text) && !FuzzyClient.isApp(result)
        }
        if foundAsTyped {
            found.removeAll { $0.match.rank < 400_000 }
        }
        return found.sorted {
            $0.match.rank != $1.match.rank
                ? $0.match.rank > $1.match.rank
                : $0.lastUsed != $1.lastUsed ? $0.lastUsed > $1.lastUsed : $0.length < $1.length
        }
        .prefix(Self.mostShown)
        .filter { FileManager.default.fileExists(atPath: $0.match.path) }
        .map(\.match)
    }

    /// Where apps are installed, one level of folders deep (Utilities, a vendor's folder) and never inside a bundle.
    private static let folders = [
        "/Applications", "/System/Applications", "/System/Library/CoreServices/Applications", HOME.string + "/Applications",
    ]

    private let lock = NSLock()
    private var engine: SearchEngine?
    private var apps: [App] = []

    private var scannedAt: CFAbsoluteTime = 0
    private var scanning = false

    /// Optimal string alignment distance, given up past `within`.
    private static func editDistance(_ a: [Character], _ b: [Character], within: Int) -> Int {
        guard abs(a.count - b.count) <= within else { return within + 1 }
        var previous2 = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0 ... b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1 ... a.count {
            current[0] = i
            for j in 1 ... max(1, b.count) where b.count > 0 {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    current[j] = min(current[j], previous2[j - 2] + 1)
                }
            }
            if b.isEmpty {
                current[0] = i
            }
            (previous2, previous, current) = (previous, current, previous2)
        }
        return previous[b.count]
    }

    /// When the app was last opened, as Spotlight keeps it.
    private static func lastUsed(_ path: String) -> Date {
        guard let item = MDItemCreate(nil, path as CFString) else { return .distantPast }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date ?? .distantPast
    }
    private static func installedApps() -> [String] {
        var apps = ["/System/Library/CoreServices/Finder.app"]
        let fm = FileManager.default
        for folder in folders {
            for name in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] where !name.hasPrefix(".") {
                let path = folder + "/" + name
                if FuzzyClient.isApp(path) {
                    apps.append(path)
                    continue
                }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
                for inner in (try? fm.contentsOfDirectory(atPath: path)) ?? [] where FuzzyClient.isApp(inner) {
                    apps.append(path + "/" + inner)
                }
            }
        }
        var seen = Set<String>()
        return apps.filter { seen.insert($0).inserted }
    }

    @discardableResult
    private func scan() -> (SearchEngine, [App]) {
        let apps = Self.installedApps().map { App(path: $0, lastUsed: Self.lastUsed($0)) }
        let engine = SearchEngine()
        for app in apps {
            _ = engine.addPathIfMissing(String(app.path.dropLast(4)), isDir: true)
        }
        lock.withLock {
            self.engine = engine
            self.apps = apps
            scannedAt = CFAbsoluteTimeGetCurrent()
            scanning = false
        }
        return (engine, apps)
    }

}
