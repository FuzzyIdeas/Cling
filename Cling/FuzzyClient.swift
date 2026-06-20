import ClopSDK
import Cocoa
import Combine
import Foundation
import Ignore
import Lowtech
import OSLog
import System

private let log = Logger(subsystem: clingSubsystem, category: "FuzzyClient")

let FS_IGNORE = Bundle.main.url(forResource: "fsignore", withExtension: nil)!.existingFilePath!

let fsignore: FilePath = HOME / ".fsignore"
let fsignoreString: String = (HOME / ".fsignore").string

// MARK: - PathBlocklist

/// Fast in-memory blocklist for paths that should never be indexed, regardless of scope.
/// Rebuilt from user settings. Checked with simple prefix/contains matching on UTF-8 bytes for speed.
final class PathBlocklist: @unchecked Sendable {
    init() { rebuild() }

    static let shared = PathBlocklist()

    private(set) var prefixes: [[UInt8]] = []
    private(set) var components: [[UInt8]] = []

    // Exceptions: lines starting with `!`. A path matching one of these is indexed even if a block rule
    // also matches it (e.g. block `.app/Contents/`, allow `!.app/Contents/MacOS/`). Kept as both UTF-8
    // bytes (for fast matching) and strings (for the ancestor-descent test during directory walks).
    private(set) var allowPrefixes: [[UInt8]] = []
    private(set) var allowComponents: [[UInt8]] = []
    private(set) var allowPrefixesStr: [String] = []
    private(set) var allowComponentsStr: [String] = []

    var hasAllows: Bool { !allowPrefixes.isEmpty || !allowComponents.isEmpty }

    func rebuild() {
        let (blockPrefixes, allowPfx) = Self.split(Defaults[.blockedPrefixes])
        let (blockContains, allowContains) = Self.split(Defaults[.blockedContains])

        prefixes = Self.expandPrivate(blockPrefixes).map { Array($0.utf8) }
        let expandedAllow = Self.expandPrivate(allowPfx)
        allowPrefixesStr = expandedAllow
        allowPrefixes = expandedAllow.map { Array($0.utf8) }
        components = blockContains.map { Array($0.utf8) }
        allowComponentsStr = allowContains
        allowComponents = allowContains.map { Array($0.utf8) }
    }

    /// Split non-comment lines into (block, allow). Allow lines start with `!`.
    private static func split(_ s: String) -> (block: [String], allow: [String]) {
        var block = [String]()
        var allow = [String]()
        for raw in s.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("!") {
                let value = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { allow.append(value) }
            } else {
                block.append(line)
            }
        }
        return (block, allow)
    }

    /// Auto-generate /private counterparts for paths under symlinked dirs.
    private static func expandPrivate(_ prefixes: [String]) -> [String] {
        var out = [String]()
        for p in prefixes {
            out.append(p)
            if p.hasPrefix("/tmp/") || p.hasPrefix("/var/") || p.hasPrefix("/etc/") {
                out.append("/private" + p)
            } else if p.hasPrefix("/private/tmp/") || p.hasPrefix("/private/var/") || p.hasPrefix("/private/etc/") {
                out.append(String(p.dropFirst("/private".count)))
            }
        }
        return out
    }
}

/// Length of the longest pattern that matches `path` (0 if none). Used as a specificity score so a more
/// specific rule can override a broader one (e.g. an exact prefix beats a shallow `contains` exception).
private func blocklistMatchLength(_ path: String, prefixes: [[UInt8]], components: [[UInt8]]) -> Int {
    var best = 0
    path.utf8.withContiguousStorageIfAvailable { buf in
        let len = buf.count
        for prefix in prefixes {
            let pLen = prefix.count
            guard pLen > best else { continue } // can't beat the current best
            if len >= pLen, memcmp(buf.baseAddress!, prefix, pLen) == 0 { best = pLen; continue }
            // A prefix ending in "/" also matches the bare directory itself ("X/" matches path "X").
            if prefix[pLen - 1] == 0x2F, len == pLen - 1, memcmp(buf.baseAddress!, prefix, pLen - 1) == 0 {
                best = pLen
            }
        }
        for component in components {
            let cLen = component.count
            guard cLen > best, len >= cLen else { continue }
            // memmem is a SIMD-optimized substring search; far cheaper than a hand-rolled sliding memcmp
            // once the blocklist has many `contains` patterns (this runs per path during default-result scans).
            var matched = memmem(buf.baseAddress!, len, component, cLen) != nil
            // Also match when the path ends with the component minus its trailing slash
            // e.g. path "/foo/build" matches component "/build/" because fts_read omits the trailing /
            if !matched, cLen >= 2, component[cLen - 1] == 0x2F, len >= cLen - 1 {
                matched = memcmp(buf.baseAddress! + len - (cLen - 1), component, cLen - 1) == 0
            }
            if matched { best = cLen }
        }
    }
    return best
}

/// Specificity of the strongest block rule matching `path` (0 if none).
func pathBlockLength(_ path: String) -> Int {
    let bl = PathBlocklist.shared
    return blocklistMatchLength(path, prefixes: bl.prefixes, components: bl.components)
}

/// Specificity of the strongest allow exception matching `path` (0 if none).
func pathAllowLength(_ path: String) -> Int {
    let bl = PathBlocklist.shared
    guard bl.hasAllows else { return 0 }
    return blocklistMatchLength(path, prefixes: bl.allowPrefixes, components: bl.allowComponents)
}

/// Whether a path matches a block rule (ignoring exceptions).
func pathBlockMatch(_ path: String) -> Bool { pathBlockLength(path) > 0 }

/// Whether a path matches an allow exception (`!` rule).
func pathAllowMatch(_ path: String) -> Bool { pathAllowLength(path) > 0 }

/// Blocked when a block rule matches and no allow exception is at least as specific. The most specific
/// (longest) matching rule wins, so a deep block can re-exclude inside a shallower allowed area.
func isPathBlocked(_ path: String) -> Bool {
    let block = pathBlockLength(path)
    guard block > 0 else { return false }
    return block > pathAllowLength(path)
}

/// For a blocked directory, whether an allow-exception could match something beneath it, meaning the
/// walker should descend into it (without indexing the directory itself) instead of pruning it.
func blocklistDirHasAllowedDescendant(_ path: String) -> Bool {
    let bl = PathBlocklist.shared
    guard bl.hasAllows else { return false }
    let withSlash = path + "/"
    for rule in bl.allowComponentsStr {
        // The allow pattern already appears in the path, or continuing down could complete it.
        if withSlash.contains(rule) { return true }
        if suffixIsPrefix(of: rule, in: withSlash) { return true }
    }
    for rule in bl.allowPrefixesStr where rule.hasPrefix(withSlash) {
        return true
    }
    return false
}

/// True if any non-empty suffix of `s` equals a prefix of `r` (a partial match in progress).
private func suffixIsPrefix(of r: String, in s: String) -> Bool {
    let sb = Array(s.utf8)
    let rb = Array(r.utf8)
    let maxLen = min(sb.count, rb.count)
    guard maxLen > 0 else { return false }
    for len in stride(from: maxLen, through: 1, by: -1) {
        let off = sb.count - len
        var ok = true
        var k = 0
        while k < len {
            if sb[off + k] != rb[k] { ok = false; break }
            k += 1
        }
        if ok { return true }
    }
    return false
}

/// Bounds on the in-memory live-change history. To stay searchable over a long window (find a change from a
/// day ago) without growing without limit, the history is deduplicated by (path, kind) keeping only the
/// latest event per key, with a generous hard cap on distinct entries as the final backstop. Compaction is
/// lazy: it runs only when the raw array (which may hold superseded duplicates) passes the threshold, so
/// appends stay amortized O(1).
private let liveChangesMax = 15000 // distinct (path, kind) entries kept after compaction
private let liveChangesCompactThreshold = 20000 // compact once the raw array passes this
/// Max number of newest live changes computeDefaultResults scans looking for 20 fresh results.
private let liveScanBudget = 4000

let indexFolder: FilePath =
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("com.lowtechguys.Cling", isDirectory: true).filePath ?? "/tmp/cling-\(NSUserName())".filePath!

let PIDFILE = "/tmp/cling-\(NSUserName().safeFilename).pid".filePath!
let HARD_IGNORED: Set<String> = [PIDFILE.string]
func scopeIndexFile(_ scope: SearchScope) -> FilePath {
    indexFolder / "\(scope.rawValue).idx"
}

var scopeIndexesExist: Bool {
    SearchScope.allCases.contains { scopeIndexFile($0).exists }
}

// MARK: - SortField

enum SortField: String, CaseIterable, Identifiable {
    case score
    case name
    case path
    case size
    case date
    case kind

    var id: String { rawValue }
}

private func computeEnabledVolumes(mounted: [FilePath], disabled: [FilePath]) -> [FilePath] {
    let disabledSet = Set(disabled)
    let mountedSet = Set(mounted)
    let mountedEnabled = mounted.filter { !disabledSet.contains($0) }
    let disconnected = Defaults[.indexedVolumePaths].filter { !mountedSet.contains($0) && !disabledSet.contains($0) }
    return mountedEnabled + disconnected
}

// MARK: - FuzzyClient

@Observable @MainActor
class FuzzyClient {
    init() {}

    // MARK: - Observable State (read by UI)

    struct IndexChange: Identifiable {
        enum Kind: String, Comparable {
            case added = "+"
            case removed = "-"
            case modified = "~"

            static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
        }

        let id = UUID()
        let path: String
        let kind: Kind
        let date = Date()

        var name: String { (path as NSString).lastPathComponent }
        var dir: String { (path as NSString).deletingLastPathComponent }
    }

    struct ActivityEntry: Identifiable {
        let id = UUID()
        let message: String
        let date = Date()
        let durationMs: Double?
    }

    static let initialVolumes = getVolumes()

    /// Score biases per scope (higher = results ranked higher in merged output)
    static let scopeBiases: [SearchScope: Int] = [
        .home: 2, .applications: 1, .library: 0, .system: -1, .root: -1,
    ]

    static let freeScopes: Set<SearchScope> = [.home, .applications, .library]

    @ObservationIgnored var searchTask: Task<Void, Never>?
    /// Thread-safe coordinator for CLI and multi-engine search
    @ObservationIgnored let searchCoordinator = SearchCoordinator()

    var liveIndexChanges: [IndexChange] = []
    var showLiveIndex = false
    var showActivityLog = false
    var showRunHistory = false
    @ObservationIgnored var savedQuery: String?
    var activityLog: [ActivityEntry] = []
    var loadingIndex = false
    var indexedCount = 0
    var clopIsAvailable = false
    var removedFiles: Set<String> = []
    var excludedPaths: Set<String> = []
    var results: [FilePath] = []
    var seenPaths: Set<String> = []
    var operation = ""
    var scoredResults: [FilePath] = []
    var recents: [FilePath] = [] // Merged default results (live index + MDQuery)
    var sortedRecents: [FilePath] = [] // Same, sorted by current sort field
    @ObservationIgnored var mdQueryRecents: [FilePath] = [] // Raw MDQuery results (filtered)
    var commonOpenWithApps: [URL] = []
    var openWithAppShortcuts: [URL: Character] = [:]
    /// Set when ⌘⌥<letter> (or a collapsed apps pill) matches several apps, to present the Open With
    /// picker scoped to that group for quick numbered selection.
    var openWithGroupRequest: OpenWithGroupRequest?
    var installedApps: [URL] = []
    @ObservationIgnored nonisolated(unsafe) var appIconCache: [String: NSImage] = [:]
    @ObservationIgnored var appDirWatchers: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored var appRefreshTask: DispatchWorkItem?
    var noQuery = true
    var searching = false
    var hasFullDiskAccess: Bool = FullDiskAccess.isGranted
    var disabledVolumes: [FilePath] = Defaults[.disabledVolumes]
    var enabledVolumes: [FilePath] = computeEnabledVolumes(mounted: initialVolumes, disabled: Defaults[.disabledVolumes])
    var externalIndexes: [FilePath] = computeEnabledVolumes(mounted: initialVolumes, disabled: Defaults[.disabledVolumes])
        .map { volumeIndexFile($0) }
    var disconnectedVolumes: Set<FilePath> = {
        let mounted = Set(initialVolumes)
        return Set(Defaults[.indexedVolumePaths].filter { !mounted.contains($0) && !Defaults[.disabledVolumes].contains($0) })
    }()
    var readOnlyVolumes: [FilePath] = initialVolumes.filter(\.url.volumeIsReadOnly)
    @ObservationIgnored var quickFilterPool: [Int]? // Legacy, for CLI
    @ObservationIgnored var quickFilterPools: [String: [Int]] = [:] // Per-engine pools
    var filteredSubsetCount: Int?

    @ObservationIgnored var scopeIndexTask: Task<Void, Never>?
    @ObservationIgnored var volumeIndexTasks: [FilePath: Task<Void, Never>] = [:]
    var volumesIndexing: Set<FilePath> = []
    /// Scopes currently part of the active `indexFiles` batch (either running or queued inside it).
    var scopesIndexing: Set<SearchScope> = []
    @ObservationIgnored var cliMachPortThread: Thread?

    // MARK: - Search Engines (per-scope + recents)

    /// Per-scope engines: each scope has its own SearchEngine for independent search/load/unload
    @ObservationIgnored var scopeEngines: [SearchScope: SearchEngine] = [:]
    @ObservationIgnored var volumeEngines: [FilePath: SearchEngine] = [:]
    @ObservationIgnored var smbMetadataCaches: [FilePath: SMBMetadataCache] = [:]
    @ObservationIgnored var recentsEngine = SearchEngine()

    @ObservationIgnored var suppressNextSearch = false
    @ObservationIgnored let fsEventsQueue = DispatchQueue(label: "com.lowtechguys.Cling.fsevents")

    @ObservationIgnored var updatingFilters = false
    @ObservationIgnored var defaultResultsDirty = true

    @ObservationIgnored var fsignoreWatchSuppressedUntil: CFAbsoluteTime = 0

    /// Log an activity with optional duration tracking.
    /// Call with a key to start timing, call again with the same key to log with duration.
    /// Log an activity. Set `ongoing: true` for operations in progress (shows spinner).
    /// Set `ongoing: false` (default) for completed operations (clears spinner after logging).
    @ObservationIgnored var ongoingOperations: [String: String] = [:]
    @ObservationIgnored var ongoingOperationCounts: [String: Int] = [:]
    var ongoingOperationsList: [(key: String, message: String)] = []

    @ObservationIgnored var appDiscoveryQuery: MetaQuery? { didSet { _ = oldValue } }

    var backgroundIndexing = false {
        didSet {
            if !backgroundIndexing, !indexing {
                ongoingOperations.removeAll()
                ongoingOperationCounts.removeAll()
                setOperation("")
            }
            searchCoordinator.setIndexing(indexing || backgroundIndexing)
        }
    }

    var quickFilter: QuickFilter? {
        didSet {
            guard quickFilter != oldValue, !updatingFilters else { return }
            updatingFilters = true
            defer { updatingFilters = false }

            if let quickFilter {
                logActivity("QuickFilter: \(quickFilter.id)")
                // Deselect folder filter unless quick filter has its own folders
                if quickFilter.folders == nil || quickFilter.folders?.isEmpty == true {
                    if folderFilter != nil { folderFilter = nil }
                }
            } else {
                logActivity("QuickFilter cleared")
            }
            // Auto-apply/clear folder filter from quick filter
            if let folders = quickFilter?.folders, !folders.isEmpty {
                let name = folders.count == 1 ? Self.friendlyName(for: folders[0]) : folders.map { Self.friendlyName(for: $0) }.joined(separator: ", ")
                folderFilter = FolderFilter(id: name, folders: folders, key: nil)
            } else if oldValue?.folders != nil {
                folderFilter = nil
            }
            recomputeQuickFilterPool()
        }
    }

    /// All engines to search (enabled scopes + volumes + recents)
    var activeEngines: [(engine: SearchEngine, label: String, scoreBias: Int)] {
        let scopes = Defaults[.searchScopes]
        var result = [(SearchEngine, String, Int)]()
        for scope in scopes {
            if !proactive, !Self.freeScopes.contains(scope) { continue }
            if let eng = scopeEngines[scope] {
                result.append((eng, scope.label, Self.scopeBiases[scope] ?? 0))
            }
        }
        if proactive {
            for (volume, eng) in volumeEngines {
                if enabledVolumes.contains(volume) {
                    result.append((eng, volume.name.string, -2))
                }
            }
        }
        if recentsEngine.count > 0 {
            result.append((recentsEngine, "Recents", 3))
        }
        return result
    }

    var externalVolumes: [FilePath] = initialVolumes { didSet {
        registerNewVolumes()
        let mounted = Set(externalVolumes)
        disconnectedVolumes = Set(Defaults[.indexedVolumePaths].filter { !mounted.contains($0) && !disabledVolumes.contains($0) })
        enabledVolumes = computeEnabledVolumes(mounted: externalVolumes, disabled: disabledVolumes)
        readOnlyVolumes = externalVolumes.filter(\.url.volumeIsReadOnly)
        externalIndexes = getExternalIndexes()
        indexStaleExternalVolumes()
    }}

    /// Records freshly-seen volumes. In opt-in mode (`disableAutomaticVolumeIndexing`), a volume seen for
    /// the first time that has never been indexed starts out disabled, so it shows up toggled-off in
    /// Settings until the user enables it. Guarded by `knownVolumes` so it runs exactly once per volume:
    /// it never re-disables a volume the user has already enabled, and never touches already-known or
    /// previously-indexed volumes (those keep auto-reindexing).
    func registerNewVolumes() {
        let known = Set(Defaults[.knownVolumes])
        let unseen = externalVolumes.filter { !known.contains($0) }
        guard !unseen.isEmpty else { return }
        Defaults[.knownVolumes].append(contentsOf: unseen)

        guard Defaults[.disableAutomaticVolumeIndexing] else { return }
        let indexed = Set(Defaults[.indexedVolumePaths])
        let toDisable = unseen.filter { !indexed.contains($0) && !disabledVolumes.contains($0) }
        guard !toDisable.isEmpty else { return }

        Defaults[.disabledVolumes].append(contentsOf: toDisable)
        disabledVolumes.append(contentsOf: toDisable)
        let mounted = Set(externalVolumes)
        disconnectedVolumes = Set(Defaults[.indexedVolumePaths].filter { !mounted.contains($0) && !disabledVolumes.contains($0) })
        enabledVolumes = computeEnabledVolumes(mounted: externalVolumes, disabled: disabledVolumes)
        externalIndexes = getExternalIndexes()
    }

    var volumeFilter: FilePath? {
        didSet {
            guard volumeFilter != oldValue, !updatingFilters else { return }
            updatingFilters = true
            defer { updatingFilters = false }

            if let volumeFilter {
                // Auto-start indexing if not yet indexed
                if volumeFilter != .root, volumeEngines[volumeFilter] == nil, !volumesIndexing.contains(volumeFilter) {
                    indexVolume(volumeFilter)
                }
                logActivity("Volume filter: \(volumeFilter.name.string)")
                if folderFilter != nil { folderFilter = nil }
            } else {
                logActivity("Volume filter cleared")
            }
            // Skip search if volume is not yet indexed
            guard volumeFilter == nil || volumeFilter == .root || volumeEngines[volumeFilter!] != nil else { return }
            performSearch()
        }
    }
    var folderFilter: FolderFilter? {
        didSet {
            guard folderFilter != oldValue, !updatingFilters else { return }
            updatingFilters = true
            defer { updatingFilters = false }

            if let folderFilter {
                logActivity("Folder filter: \(folderFilter.id)")
                // Deselect volume filter
                if volumeFilter != nil { volumeFilter = nil }
                // Merge folders into active quick filter, keeping non-folder properties
                if let currentQuick = quickFilter {
                    quickFilter = QuickFilter(
                        id: currentQuick.id, extensions: currentQuick.extensions,
                        preQuery: currentQuick.preQuery, postQuery: currentQuick.postQuery,
                        dirsOnly: currentQuick.dirsOnly, folders: folderFilter.folders, key: currentQuick.key,
                        maxDepth: currentQuick.maxDepth
                    )
                    recomputeQuickFilterPool()
                }
            } else if quickFilter == nil {
                logActivity("Folder filter cleared")
            }
            if folderFilter == nil, quickFilter == nil {
                filteredSubsetCount = nil
            }
            searching = true
            performSearch()
        }
    }

    var sortField: SortField = .score {
        didSet {
            guard sortField != oldValue else { return }
            results = sortedResults()
            sortedRecents = sortedResults(results: recents)
        }
    }
    var reverseSort = true {
        didSet {
            guard reverseSort != oldValue else { return }
            results = sortedResults()
            sortedRecents = sortedResults(results: recents)
        }
    }

    var query = "" {
        didSet {
            guard !showLiveIndex else { return }
            if suppressNextSearch { suppressNextSearch = false; return }
            querySendTask = mainAsyncAfter(ms: 150) { [self] in
                performSearch()
            }
        }
    }
    var indexing = false {
        didSet {
            if !indexing, !backgroundIndexing {
                ongoingOperations.removeAll()
                ongoingOperationCounts.removeAll()
                setOperation("")
            } else if indexing {
                setOperation("Indexing files")
            }
            searchCoordinator.setIndexing(indexing || backgroundIndexing)
        }
    }

    @ObservationIgnored var querySendTask: DispatchWorkItem? { didSet { oldValue?.cancel() } }
    @ObservationIgnored var indexConsolidationTask: DispatchWorkItem? { didSet { oldValue?.cancel() } }

    var indexExists: Bool { scopeIndexesExist }
    var indexIsStale: Bool {
        let scopes = Defaults[.searchScopes]
        return scopes.contains { scope in
            let f = scopeIndexFile(scope)
            return !f.exists || (f.timestamp ?? 0) < Date().addingTimeInterval(-3600 * 72).timeIntervalSince1970
        }
    }

    @ObservationIgnored var computeOpenWithTask: DispatchWorkItem? { didSet { oldValue?.cancel() } }
    @ObservationIgnored var updateDefaultResultsTask: DispatchWorkItem? { didSet { oldValue?.cancel() } }

    @ObservationIgnored var emptyQuery: Bool {
        query.isEmpty && folderFilter == nil && quickFilter == nil
    }

    // MARK: - Query Construction

    /// Human-friendly name for a folder path
    nonisolated static func friendlyName(for path: FilePath) -> String {
        let home = NSHomeDirectory()
        let s = path.string
        let icloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"

        if s == "/" { return "Root" }
        if s == home { return "Home" }
        if s == icloud { return "iCloud" }
        if s.hasPrefix(icloud + "/") { return "iCloud/\(path.name.string)" }
        if s == "/System/Applications" { return "System Apps" }
        if s == "\(home)/Applications" { return "~/Applications" }
        return path.name.string
    }

    /// Pick the best first engine to search based on query hints.
    /// Returns the index into the engines array.
    nonisolated static func bestFirstEngine(
        for query: String,
        engines: [(engine: SearchEngine, label: String, scoreBias: Int)]
    ) -> Int {
        let q = query.lowercased()

        // Map query patterns to preferred scope labels
        let hints: [(pattern: (String) -> Bool, label: String)] = [
            ({ $0.contains(".framework") || $0.contains(".dylib") }, "System"),
            ({ $0.contains(".app") || $0.contains("/applications") }, "Applications"),
            ({ $0.contains("/usr") || $0.contains("/bin") || $0.contains("/opt") }, "Root"),
            ({ $0.contains("/library") || $0.contains("~/library") }, "Library"),
            ({ $0.contains(".xcodeproj") || $0.contains(".swift") || $0.contains(".xcworkspace") }, "Home"),
            ({ $0.contains("/documents") || $0.contains("/desktop") || $0.contains("/downloads") }, "Home"),
        ]

        for hint in hints {
            if hint.pattern(q), let idx = engines.firstIndex(where: { $0.label == hint.label }) {
                return idx
            }
        }

        // Default: prefer Home (most likely user intent), then Applications
        if let idx = engines.firstIndex(where: { $0.label == "Home" }) { return idx }
        if let idx = engines.firstIndex(where: { $0.label == "Applications" }) { return idx }
        return 0
    }

    /// Merge results from multiple engines: quality gate + sort + dedup
    nonisolated static func mergeResults(_ results: [SearchResult], maxResults: Int) -> [SearchResult] {
        guard !results.isEmpty else { return [] }
        var bestQ = 0
        var i = 0
        while i < results.count {
            if results[i].quality > bestQ { bestQ = results[i].quality }
            i &+= 1
        }
        let minQ = bestQ / 3
        var filtered = results.filter { $0.quality >= minQ || $0.hasBase }
        filtered.sort(by: >)
        var seen = Set<String>()
        return filtered.prefix(maxResults * 2).filter { seen.insert($0.path).inserted }.prefix(maxResults).map { $0 }
    }

    func setOperation(_ value: String) {
        if value.isEmpty {
            _operationThrottle?.cancel()
            _operationThrottle = nil
            operation = value
            ongoingOperationsList = []
            _lastOperationUpdate = CFAbsoluteTimeGetCurrent()
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - _lastOperationUpdate
        if elapsed >= 0.5 {
            _operationThrottle?.cancel()
            _operationThrottle = nil
            operation = value
            ongoingOperationsList = ongoingOperations.map { (key: $0.key, message: $0.value) }
            _lastOperationUpdate = now
        } else {
            _operationThrottle?.cancel()
            _operationThrottle = Task {
                try? await Task.sleep(for: .milliseconds(Int(500 - elapsed * 1000)))
                guard !Task.isCancelled else { return }
                self.operation = value
                self.ongoingOperationsList = self.ongoingOperations.map { (key: $0.key, message: $0.value) }
                self._lastOperationUpdate = CFAbsoluteTimeGetCurrent()
                self._operationThrottle = nil
            }
        }
    }
    func logActivity(_ message: String, ongoing: Bool = false, operationKey: String? = nil, timerKey: String? = nil, count: Int? = nil) {
        var duration: Double?
        if let key = timerKey {
            if let start = activityTimers[key] {
                duration = (CFAbsoluteTimeGetCurrent() - start) * 1000
                activityTimers[key] = nil
            } else {
                activityTimers[key] = CFAbsoluteTimeGetCurrent()
            }
        }
        activityLog.append(ActivityEntry(message: message, durationMs: duration))
        if activityLog.count > 100 {
            activityLog.removeFirst(activityLog.count - 100)
        }
        if ongoing, let key = operationKey {
            ongoingOperations[key] = message
            if let count { ongoingOperationCounts[key] = count }
            setOperation(compactOperationSummary())
        } else {
            if let key = operationKey {
                ongoingOperations.removeValue(forKey: key)
                ongoingOperationCounts.removeValue(forKey: key)
            }
            if !ongoingOperations.isEmpty {
                setOperation(compactOperationSummary())
            } else if backgroundIndexing || indexing {
                setOperation(message)
            } else {
                setOperation("")
            }
        }
    }
    /// Sync active engines to the SearchCoordinator (for CLI thread access)
    func syncCoordinator() {
        searchCoordinator.setEngines(activeEngines.map {
            SearchCoordinator.EngineEntry(engine: $0.engine, label: $0.label, scoreBias: $0.scoreBias)
        })
    }

    func recomputeQuickFilterPool() {
        guard let qf = quickFilter, qf.poolExtensions != nil || qf.searchDirsOnly else {
            quickFilterPool = nil
            quickFilterPools.removeAll()
            filteredSubsetCount = nil
            invalidateSearch()
            performSearch()
            return
        }
        searching = true
        let engines = activeEngines
        Task.detached(priority: .userInitiated) {
            var pools: [String: [Int]] = [:]
            var totalCount = 0
            for (eng, label, _) in engines {
                let pool = eng.prefilter(extensions: qf.poolExtensions, dirsOnly: qf.searchDirsOnly)
                pools[label] = pool
                totalCount += pool.count
            }
            await MainActor.run {
                self.quickFilterPools = pools
                self.quickFilterPool = nil
                self.filteredSubsetCount = totalCount
                self.invalidateSearch()
                self.performSearch()
            }
        }
    }

    /// Recalculate total indexed count from all engines
    func updateIndexedCount() {
        indexedCount = scopeEngines.values.reduce(0) { $0 + $1.count }
            + volumeEngines.values.reduce(0) { $0 + $1.count }
            + recentsEngine.count
        syncCoordinator()
    }

    func start() {
        startCLIListeners()
        discoverInstalledApps()
        watchAppDirectories()

        asyncNow {
            let clopIsAvailable = ClopSDK.shared.getClopAppURL() != nil
            mainActor {
                self.clopIsAvailable = clopIsAvailable
                if clopIsAvailable {
                    SM.reservedShortcuts.insert("o")
                    SM.fetchScripts()
                }
            }
        }

        // FDA prompt moved after setup so it doesn't block listeners and indexing
        pub(.maxResultsCount)
            .debounce(for: 0.5, scheduler: RunLoop.main)
            .sink { [self] _ in
                performSearch()
                if let recentsQuery {
                    stopRecentsQuery(recentsQuery)
                    self.recentsQuery = queryRecents()
                }
            }.store(in: &observers)
        pub(.searchScopes)
            .debounce(for: 2.0, scheduler: RunLoop.main)
            .sink { [self] _ in
                performSearch()
            }.store(in: &observers)

        pub(.disabledVolumes)
            .debounce(for: 2.0, scheduler: RunLoop.main)
            .sink { [self] volumes in
                let previouslyDisabled = Set(disabledVolumes)
                disabledVolumes = volumes.newValue
                let nowDisabled = Set(volumes.newValue)
                let reEnabled = previouslyDisabled.subtracting(nowDisabled)
                let mounted = Set(externalVolumes)
                disconnectedVolumes = Set(Defaults[.indexedVolumePaths].filter { !mounted.contains($0) && !disabledVolumes.contains($0) })
                enabledVolumes = computeEnabledVolumes(mounted: externalVolumes, disabled: disabledVolumes)
                externalIndexes = getExternalIndexes()
                performSearch()

                // Index volumes that just became enabled and have no loaded engine yet (covers opt-in's
                // "flip the toggle on -> index"; a volume toggled off then on with its engine still loaded
                // is left alone). indexVolumes already skips volumes that are mid-index.
                let toIndex = reEnabled.filter { $0.exists && volumeEngines[$0] == nil }
                if !toIndex.isEmpty { indexVolumes(Array(toIndex)) }
            }.store(in: &observers)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didMountNotification)
            .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification))
            .sink { _ in
                self.externalVolumes = Self.getVolumes()
            }
            .store(in: &observers)

        indexFolder.mkdir(withIntermediateDirectories: true, permissions: 0o700)
        externalIndexes = getExternalIndexes()

        hasFullDiskAccess = FullDiskAccess.isGranted
        startIndex()

        if !hasFullDiskAccess {
            // Skip the modal FDA prompt if onboarding will handle it
            if Defaults[.onboardingCompleted] {
                FullDiskAccess.promptIfNotGranted(
                    title: "Enable Full Disk Access for Cling",
                    message: "Cling requires Full Disk Access to index the files on the whole disk.",
                    settingsButtonTitle: "Open Settings",
                    skipButtonTitle: "Skip",
                    canBeSuppressed: false,
                    icon: nil
                )
            }
            fullDiskAccessChecker = Repeater(every: 2) {
                guard FullDiskAccess.isGranted else { return }
                self.hasFullDiskAccess = true
                self.fullDiskAccessChecker = nil
                self.refresh(pauseSearch: false)
            }
        }
    }

    func cleanup() {
        LowtechFSEvents.stopWatching(for: ObjectIdentifier(self))
        searchTask?.cancel()
        for source in fsignoreWatchSources {
            source.cancel()
        }
        fsignoreWatchSources.removeAll()
        fsignoreReindexTask?.cancel()
    }

    // MARK: - Indexing

    func startIndex() {
        // Record volumes present at launch (and, in opt-in mode, leave never-indexed ones disabled)
        // before any indexStaleExternalVolumes() runs.
        registerNewVolumes()

        if !fsignore.exists {
            do { try FS_IGNORE.copy(to: fsignore) }
            catch { log.error("Failed to copy \(FS_IGNORE.string) to \(fsignoreString): \(error.localizedDescription)") }
        }
        ScopeIgnore.ensureSeeded()

        if !indexExists {
            indexFiles(pauseSearch: true) { [self] in
                watchFiles()
                indexStaleExternalVolumes()
            }
        } else if indexIsStale, batteryLevel() > 0.3 {
            loadPersistedIndex { [self] in
                indexFiles(pauseSearch: false) { [self] in
                    watchFiles()
                }
            }
        } else {
            loadPersistedIndex { [self] in
                watchFiles()
                indexStaleExternalVolumes()
            }
        }

        indexChecker = Repeater(every: 60 * 60, name: "Index Checker", tolerance: 60 * 60) { [self] in
            guard batteryLevel() > 0.3 else { return }
            refresh(pauseSearch: false)
        }

        watchIgnoreFiles()
    }

    func watchIgnoreFiles() {
        for source in fsignoreWatchSources {
            source.cancel()
        }
        fsignoreWatchSources.removeAll()

        let paths = [fsignoreString]
        for path in paths {
            fsignoreContentHashes[path] = contentHash(of: path)

            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: fsEventsQueue
            )
            source.setEventHandler { [self] in
                let event = source.data
                if event.contains(.delete) || event.contains(.rename) {
                    // File was replaced, re-watch after a short delay
                    source.cancel()
                    close(fd)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                        watchIgnoreFiles()
                    }
                    return
                }

                guard CFAbsoluteTimeGetCurrent() > fsignoreWatchSuppressedUntil else { return }
                guard let newHash = contentHash(of: path), newHash != fsignoreContentHashes[path] else { return }
                fsignoreContentHashes[path] = newHash

                bust_gitignore_cache()

                log.info("Ignore file changed: \(path), scheduling reindex in 60s")
                fsignoreReindexTask?.cancel()
                fsignoreReindexTask = DispatchWorkItem { [self] in
                    mainActor {
                        log.info("Reindexing after ignore file change")
                        self.refresh(pauseSearch: false)
                    }
                }
                fsEventsQueue.asyncAfter(deadline: .now() + 60, execute: fsignoreReindexTask!)
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            fsignoreWatchSources.append(source)
        }
    }

    func loadPersistedIndex(onComplete: (@MainActor () -> Void)? = nil) {
        guard indexedCount == 0 else {
            onComplete?()
            return
        }

        guard scopeIndexesExist else {
            onComplete?()
            return
        }

        setOperation("Loading index...")
        loadingIndex = true

        Task.detached(priority: .userInitiated) {
            // Load priority scopes first (home, applications) so search works during cold start
            let priorityScopes: [SearchScope] = [.home, .applications, .library]
            let remainingScopes: [SearchScope] = SearchScope.allCases.filter { !priorityScopes.contains($0) }

            // Phase 1: Load priority scopes, make searchable immediately
            for scope in priorityScopes {
                let file = scopeIndexFile(scope)
                guard file.exists else { continue }
                let eng = SearchEngine()
                let opKey = "load:\(scope.rawValue)"
                if eng.loadBinaryIndex(from: file.url, progress: { count in
                    Task { @MainActor in
                        self.logActivity("Loading \(scope.label): \(count.formatted()) entries", ongoing: true, operationKey: opKey, count: count)
                    }
                }) {
                    await MainActor.run {
                        self.scopeEngines[scope] = eng
                        self.updateIndexedCount()
                        self.logActivity("Loaded \(scope.label): \(eng.count.formatted()) entries", operationKey: opKey)
                    }
                }
            }

            // Phase 2: Load remaining scopes in background
            for scope in remainingScopes {
                let file = scopeIndexFile(scope)
                guard file.exists else { continue }
                let eng = SearchEngine()
                let opKey = "load:\(scope.rawValue)"
                if eng.loadBinaryIndex(from: file.url, progress: { count in
                    Task { @MainActor in
                        self.logActivity("Loading \(scope.label): \(count.formatted()) entries", ongoing: true, operationKey: opKey, count: count)
                    }
                }) {
                    await MainActor.run {
                        self.scopeEngines[scope] = eng
                        self.updateIndexedCount()
                        self.logActivity("Loaded \(scope.label): \(eng.count.formatted()) entries", operationKey: opKey)
                    }
                }
            }

            // Backfill indexedVolumePaths from existing index files on disk
            let scopeNames = Set(SearchScope.allCases.map(\.rawValue))
            let indexFiles = (try? FileManager.default.contentsOfDirectory(atPath: indexFolder.string)) ?? []
            let discoveredVolumePaths: [FilePath] = indexFiles.compactMap { filename in
                guard filename.hasSuffix(".idx") else { return nil }
                let name = String(filename.dropLast(4))
                guard !scopeNames.contains(name) else { return nil }
                let volumeName = name.replacingOccurrences(of: "-", with: " ")
                let volume = FilePath("/Volumes/\(volumeName)")
                // Also try the original dashed name
                let volumeDashed = FilePath("/Volumes/\(name)")
                if Defaults[.disabledVolumes].contains(volume) || Defaults[.disabledVolumes].contains(volumeDashed) { return nil }
                // Prefer the path that exists, fall back to the spaced version
                if volumeDashed.exists { return volumeDashed }
                return volume
            }
            if !discoveredVolumePaths.isEmpty {
                let existing = Set(Defaults[.indexedVolumePaths])
                let newPaths = discoveredVolumePaths.filter { !existing.contains($0) }
                if !newPaths.isEmpty {
                    await MainActor.run {
                        Defaults[.indexedVolumePaths].append(contentsOf: newPaths)
                        let mounted = Set(self.externalVolumes)
                        self.disconnectedVolumes = Set(Defaults[.indexedVolumePaths].filter { !mounted.contains($0) && !self.disabledVolumes.contains($0) })
                        self.enabledVolumes = computeEnabledVolumes(mounted: self.externalVolumes, disabled: self.disabledVolumes)
                    }
                }
            }

            // Phase 3: Load volume indexes (including disconnected but previously indexed volumes)
            var missingIndexVolumes: [FilePath] = []
            for volume in await MainActor.run(body: { self.enabledVolumes }) {
                let file = volumeIndexFile(volume)
                guard file.exists else {
                    if Defaults[.indexedVolumePaths].contains(volume) { missingIndexVolumes.append(volume) }
                    continue
                }
                let eng = SearchEngine()
                if eng.loadBinaryIndex(from: file.url) {
                    let metaCacheFile = smbMetadataCacheFile(volume)
                    var metaCache: SMBMetadataCache?
                    if metaCacheFile.exists {
                        let cache = SMBMetadataCache()
                        cache.load(from: metaCacheFile)
                        if cache.count > 0 { metaCache = cache }
                    }
                    await MainActor.run {
                        self.volumeEngines[volume] = eng
                        if let metaCache { self.smbMetadataCaches[volume] = metaCache }
                        self.updateIndexedCount()
                    }
                }
            }

            // Clean up indexed volume paths whose index files no longer exist
            if !missingIndexVolumes.isEmpty {
                await MainActor.run {
                    Defaults[.indexedVolumePaths].removeAll { missingIndexVolumes.contains($0) }
                    for vol in missingIndexVolumes {
                        self.disconnectedVolumes.remove(vol)
                    }
                    self.enabledVolumes = computeEnabledVolumes(mounted: self.externalVolumes, disabled: self.disabledVolumes)
                }
            }

            await MainActor.run {
                self.loadingIndex = false
                if self.indexedCount > 0 {
                    self.logActivity("Loaded \(self.indexedCount.formatted()) entries")
                    let indexedCount = self.indexedCount
                    let scopeCount = self.scopeEngines.count
                    let volumeCount = self.volumeEngines.count
                    log.debug("Loaded \(indexedCount) entries (\(scopeCount) scopes, \(volumeCount) volumes)")
                } else {
                    self.setOperation("")
                }
                onComplete?()
            }
        }
    }

    func reindexSource(_ label: String) {
        // Check if it's a scope
        if let scope = SearchScope.allCases.first(where: { $0.label == label }) {
            refresh(pauseSearch: false, scopes: [scope])
            return
        }
        // Check if it's a volume
        if let volume = enabledVolumes.first(where: { $0.name.string == label }) {
            indexVolume(volume)
            return
        }
        // "Recents" or unknown: full refresh
        refresh(pauseSearch: false)
    }

    func refresh(pauseSearch: Bool = true, scopes: [SearchScope]? = nil) {
        guard !indexing, FullDiskAccess.isGranted else { return }

        if pauseSearch {
            indexing = true
            setOperation("Reindexing filesystem")
            searchTask?.cancel()
        }

        stopWatchingFiles()
        indexFiles(pauseSearch: pauseSearch, scopes: scopes) { [self] in
            watchFiles()
            if scopes == nil { indexStaleExternalVolumes() }
        }
    }

    func indexFiles(wait: Bool = false, changedWithin: Date? = nil, pauseSearch: Bool = true, scopes scopeOverride: [SearchScope]? = nil, onFinish: (@MainActor () -> Void)? = nil) {
        _ = invalidReq3(PRODUCTS, nil)
        backgroundIndexing = true
        if pauseSearch { indexing = true }

        let scopes = scopeOverride ?? Defaults[.searchScopes]
        guard !scopes.isEmpty else {
            log.debug("No scopes to index")
            onFinish?()
            indexing = false
            return
        }

        scopesIndexing.formUnion(scopes)
        bust_gitignore_cache()
        let ignoreChecker: String? = fsignore.exists ? fsignoreString : nil
        let volumePaths = Set(enabledVolumes.map(\.string))

        scopeIndexTask?.cancel()
        scopeIndexTask = Task.detached(priority: .userInitiated) {
            await withTaskGroup(of: (SearchScope, SearchEngine).self) { group in
                for scope in scopes {
                    let dirs = await self.walkDirs(for: scope)
                    // Scopes rooted in read-only/SIP locations (Applications, System, Root) get their own
                    // gitignore stored in our cache dir, matched against the real scope dir via a rooted check.
                    let scopeIgnoreFile = ScopeIgnore.rootedScopes.contains(scope) ? ScopeIgnore.activeFile(for: scope) : nil
                    // Per-project .gitignore discovery is opt-in and limited to the Home scope.
                    let honorGitignore = scope == .home && Defaults[.honorGitignore]
                    group.addTask {
                        let scopeEngine = SearchEngine()
                        scopeEngine.reserveCapacity(100_000)
                        for dir in dirs {
                            let excludeSkip: ((String) -> Bool)? = dir.excludePrefix.map { excl in
                                { path in path.hasPrefix(excl) }
                            }
                            // Blocklist (incl. `!` exceptions) is handled inside walkDirectory via
                            // applyBlocklist, so it can descend into a blocked dir that has an allowed
                            // descendant instead of pruning it. skipDir only covers scope/volume excludes.
                            let skipDir: ((String) -> Bool)? = { path in
                                if excludeSkip?(path) ?? false { return true }
                                if volumePaths.contains(path) { return true }
                                return false
                            }
                            let ignore = scopeIgnoreFile ?? (dir.applyIgnore ? ignoreChecker : nil)
                            let ignoreRoot = scopeIgnoreFile != nil ? dir.dir : nil
                            let opKey = "scope:\(scope.rawValue)"
                            scopeEngine.walkDirectory(dir.dir, ignoreFile: ignore, ignoreRoot: ignoreRoot, skipDir: skipDir, applyBlocklist: true, discoverGitignore: honorGitignore, progress: { count, _ in
                                Task { @MainActor in
                                    self.logActivity("Indexing \(scope.label): \(count.formatted()) files", ongoing: true, operationKey: opKey, count: count)
                                }
                            })
                        }
                        return (scope, scopeEngine)
                    }
                }

                // Store each scope engine as it completes, trigger search as soon as first is ready
                nonisolated(unsafe) var searchTriggered = false

                for await (scope, scopeEngine) in group {
                    let file = scopeIndexFile(scope)
                    try? FileManager.default.removeItem(at: file.url)
                    scopeEngine.saveBinaryIndex(to: file.url)
                    let added = scopeEngine.count
                    log.debug("Indexed \(scope.label): \(added) entries -> \(file.string)")

                    let reloadedEngine = SearchEngine()
                    _ = reloadedEngine.loadBinaryIndex(from: file.url)

                    await MainActor.run {
                        self.scopeEngines[scope] = reloadedEngine
                        self.scopesIndexing.remove(scope)
                        self.updateIndexedCount()
                        self.logActivity("Indexed \(scope.label): \(added.formatted()) files (\(self.indexedCount.formatted()) total)", operationKey: "scope:\(scope.rawValue)")

                        if !searchTriggered {
                            searchTriggered = true
                            if !self.emptyQuery || self.volumeFilter != nil {
                                self.performSearch()
                            }
                        }
                    }
                }
            }

            await MainActor.run {
                self.scopeIndexTask = nil
                self.scopesIndexing.removeAll()
                self.cleanRecentsEngine()
                self.excludedPaths.removeAll()
                onFinish?()
                self.indexing = false
                self.backgroundIndexing = !self.volumesIndexing.isEmpty
                self.invalidateSearch()
                if !self.emptyQuery || self.volumeFilter != nil {
                    self.performSearch()
                }
            }
        }
    }

    func cleanRecentsEngine() {
        let entries = recentsEngine.entries
        let homePrefix = HOME.string + "/"
        let ignoreFile: String? = fsignore.exists ? fsignoreString : nil
        let volumeFsignores: [(prefix: String, fsignore: String)] = enabledVolumes.compactMap { volume in
            let vfsignore = volume / ".fsignore"
            guard vfsignore.exists else { return nil }
            return (volume.string + "/", vfsignore.string)
        }

        log.debug("cleanRecentsEngine: \(entries.count) entries, ignoreFile=\(ignoreFile ?? "nil")")

        var toRemove: [String] = []
        var i = 0
        while i < entries.count {
            let entry = entries[i]
            let path = entry.path
            if !path.isEmpty {
                if isPathBlocked(path) {
                    toRemove.append(path)
                } else if let ignoreFile, path.hasPrefix(homePrefix), path.isIgnored(in: ignoreFile) {
                    toRemove.append(path)
                } else if volumeFsignores.contains(where: { path.hasPrefix($0.prefix) && path.isIgnored(in: $0.fsignore) }) {
                    toRemove.append(path)
                }
            }
            i += 1
        }
        for path in toRemove {
            recentsEngine.removePath(path)
        }
        liveIndexChanges.removeAll { change in
            isPathBlocked(change.path) || (ignoreFile != nil && change.path.hasPrefix(homePrefix) && change.path.isIgnored(in: ignoreFile!)) ||
                volumeFsignores.contains(where: { change.path.hasPrefix($0.prefix) && change.path.isIgnored(in: $0.fsignore) })
        }
        if !toRemove.isEmpty {
            logActivity("Cleaned \(toRemove.count) ignored path\(toRemove.count == 1 ? "" : "s") from recents")
            updateIndexedCount()
            if noQuery { updateDefaultResults(debounce: true) }
        }
        log.debug("cleanRecentsEngine: removed \(toRemove.count) paths")
    }

    // MARK: - File Watching (FSEvents)

    func stopWatchingFiles() {
        LowtechFSEvents.stopWatching(for: ObjectIdentifier(self))
    }

    func watchFiles() {
        removedFiles.removeAll()
        seenPaths.removeAll()
        LowtechFSEvents.stopWatching(for: ObjectIdentifier(self))

        do {
            try LowtechFSEvents.startWatching(
                paths: ["/Users", "/usr/local", "/opt", "/Applications", "/tmp"],
                for: ObjectIdentifier(self), latency: 1
            ) { event in
                self.fsEventsQueue.async { [self] in
                    guard let flags = event.flag,
                          flags.hasElements(from: [.itemCreated, .itemRemoved, .itemRenamed, .itemModified]),
                          let path = event.path.filePath
                    else { return }

                    let pathStr = path.string
                    if isPathBlocked(pathStr) { return }
                    if path.exists {
                        let isDir = path.isDir
                        if path.starts(with: HOME), pathStr.isIgnored(in: fsignoreString) { return }
                        for volume in self.enabledVolumes where pathStr.hasPrefix(volume.string + "/") {
                            let vfsignore = volume / ".fsignore"
                            if vfsignore.exists, pathStr.isIgnored(in: vfsignore.string) { return }
                            break
                        }
                        // Add to recents engine (never blocks main thread)
                        recentsEngine.addPath(pathStr, isDir: isDir)
                        mainActor {
                            let isNew = !self.seenPaths.contains(pathStr)
                            self.seenPaths.insert(pathStr)
                            if isNew { self.indexedCount &+= 1 }
                            let kind: IndexChange.Kind = isNew ? .added : .modified
                            self.appendLiveChange(IndexChange(path: pathStr, kind: kind))
                            if self.noQuery { self.updateDefaultResults(debounce: true) }
                        }
                    } else {
                        recentsEngine.removePath(pathStr)
                        mainActor {
                            self.removedFiles.insert(pathStr)
                            self.indexedCount = max(0, self.indexedCount &- 1)
                            self.appendLiveChange(IndexChange(path: pathStr, kind: .removed))
                            if self.noQuery { self.updateDefaultResults(debounce: true) }
                            if let index = self.scoredResults.firstIndex(of: path) {
                                self.scoredResults.remove(at: index)
                                self.results = self.sortedResults()
                            }
                        }
                    }
                }
            }
        } catch {
            log.error("Failed to watch files: \(error.localizedDescription)")
        }
    }

    /// Force the next performSearch to run even if params haven't changed
    func invalidateSearch() {
        lastSearchQuery = "\0"
    }
    /// Cancel the 150ms query-typing debounce so a search doesn't fire after
    /// the window has been closed.
    func cancelPendingSearch() {
        querySendTask = nil
        searchTask?.cancel()
    }
    func performSearch() {
        searchTask?.cancel()
        // Skip stray fires after the window dismisses — only the UI consumes
        // scoredResults/results, and the TextField binding can commit a final
        // update post-close that re-arms the 150ms typing debounce.
        guard WM.mainWindowActive else {
            querySendTask = nil
            return
        }

        if emptyQuery, volumeFilter == nil {
            scoredResults = []
            results = []
            noQuery = true
            lastSearchQuery = ""
            return
        }

        guard validReq(), !indexing || indexedCount > 0 else { return }

        // Combine user query with QuickFilter's queryString
        var query = constructQuery(self.query)
        if let qf = quickFilter {
            let contribution = qf.queryString
            if !contribution.isEmpty { query = query.isEmpty ? contribution : "\(contribution) \(query)" }
        }

        // Skip if nothing changed since last search
        if query == lastSearchQuery,
           folderFilter == lastSearchFolderFilter,
           quickFilter == lastSearchQuickFilter,
           volumeFilter == lastSearchVolumeFilter,
           !scoredResults.isEmpty
        {
            return
        }
        lastSearchQuery = query
        lastSearchFolderFilter = folderFilter
        lastSearchQuickFilter = quickFilter
        lastSearchVolumeFilter = volumeFilter

        let filterDesc = [
            folderFilter.map { "folder=\($0.id)" },
            quickFilter.map { "quick=\($0.id)(\($0.subtitle))" },
            volumeFilter.map { "volume=\($0.name.string)" },
        ].compactMap { $0 }.joined(separator: " ")
        let engineCount = activeEngines.count
        log.debug("performSearch: q=\"\(query)\" engines=\(engineCount) \(filterDesc)")
        let maxResults = proactive ? Defaults[.maxResultsCount] : min(Defaults[.maxResultsCount], 500)
        let folderPrefixes = folderFilter?.folders.map(\.string)
        let volumePrefix = volumeFilter?.string
        let removedPaths = removedFiles.union(excludedPaths)
        let activeMaxDepth: Int? = {
            let q = quickFilter?.maxDepth
            let f = folderFilter?.maxDepth
            switch (q, f) {
            case let (.some(a), .some(b)): return min(a, b)
            case let (.some(a), nil): return a
            case let (nil, .some(b)): return b
            default: return nil
            }
        }()
        let wantVolumeFilter = volumeFilter != nil

        // Combine folder prefixes with volume prefix
        var allPrefixes = folderPrefixes
        if let vp = volumePrefix, allPrefixes == nil {
            allPrefixes = [vp]
        }

        // Snapshot active engines, pre-filtered by volume/folder constraints
        let engines: [(engine: SearchEngine, label: String, scoreBias: Int)]
        if let vp = volumePrefix {
            let volumeMounted = volumeFilter?.exists ?? true
            // Only search engines whose paths could match the volume/folder prefix
            engines = activeEngines.filter { eng in
                // Recents only participates for mounted volumes (it won't have entries for unmounted ones)
                if eng.label == "Recents" { return volumeMounted }
                // Volume engines match if the prefix starts with the volume path
                if let vol = volumeEngines.first(where: { $0.value === eng.engine })?.key {
                    return vp.hasPrefix(vol.string)
                }
                // Scope engines: check if any of their walk dirs could contain the prefix
                if let scope = SearchScope.allCases.first(where: { $0.label == eng.label }) {
                    return scopeCouldContain(scope, prefix: vp)
                }
                return true
            }
        } else if let fps = folderPrefixes {
            engines = activeEngines.filter { eng in
                if eng.label == "Recents" { return true }
                if let scope = SearchScope.allCases.first(where: { $0.label == eng.label }) {
                    return fps.contains { scopeCouldContain(scope, prefix: $0) }
                }
                // Volume engines: check if any folder prefix is on that volume
                if let vol = volumeEngines.first(where: { $0.value === eng.engine })?.key {
                    return fps.contains { $0.hasPrefix(vol.string) }
                }
                return true
            }
        } else {
            engines = activeEngines
        }
        let pools = quickFilterPools

        searching = true
        searchTask = Task.detached(priority: .userInitiated) {
            let engineCount = engines.count
            guard engineCount > 0 else {
                await MainActor.run { self.searching = false }
                return
            }

            nonisolated(unsafe) var cancelFlag = false
            var accumulated = [SearchResult]()

            // Pick the best first engine based on query hints
            let bestFirstIdx = Self.bestFirstEngine(for: query, engines: engines)

            await withTaskCancellationHandler {
                // Phase 1: Search the best engine first for instant results
                let firstEng = engines[bestFirstIdx]
                let firstPool = pools[firstEng.label]
                var firstResults = firstEng.engine.search(
                    query: query, maxResults: maxResults, folderPrefixes: allPrefixes,
                    excludedPaths: removedPaths.isEmpty ? nil : removedPaths,
                    maxDepth: activeMaxDepth,
                    candidatePool: firstPool, cancelled: { cancelFlag }
                )
                for i in firstResults.indices {
                    firstResults[i].sourceLabel = firstEng.label
                }
                accumulated = firstResults

                guard !cancelFlag else { return }

                // Show first engine results immediately
                let interim = Self.mergeResults(firstResults, maxResults: maxResults)
                await MainActor.run {
                    self.scoredResults = interim.compactMap { r in
                        guard let fp = r.path.filePath else { return nil }
                        fp.cache(r.isDir, forKey: \.isDir)
                        fp.cache(r.sourceLabel, forKey: \.sourceIndex)
                        return fp
                    }.filter { $0.memoz.isOnExternalVolume ? true : $0.exists }
                    self.results = self.sortedResults()
                }

                guard !cancelFlag, engineCount > 1 else { return }

                // Phase 2: Search remaining engines in parallel, single final update
                await withTaskGroup(of: [SearchResult].self) { group in
                    var idx = 0
                    while idx < engineCount {
                        if idx != bestFirstIdx {
                            let eng = engines[idx]
                            let pool = pools[eng.label]
                            group.addTask {
                                guard !cancelFlag else { return [] }
                                var results = eng.engine.search(
                                    query: query, maxResults: maxResults, folderPrefixes: allPrefixes,
                                    excludedPaths: removedPaths.isEmpty ? nil : removedPaths,
                                    maxDepth: activeMaxDepth,
                                    candidatePool: pool, cancelled: { cancelFlag }
                                )
                                for i in results.indices {
                                    results[i].sourceLabel = eng.label
                                }
                                return results
                            }
                        }
                        idx += 1
                    }
                    for await results in group {
                        guard !cancelFlag else { break }
                        accumulated.append(contentsOf: results)
                    }
                }
            } onCancel: {
                cancelFlag = true
            }

            guard !cancelFlag else {
                await MainActor.run { self.searching = false }
                return
            }

            let searchResults = Self.mergeResults(accumulated, maxResults: maxResults)

            await MainActor.run {
                self.scoredResults = searchResults.compactMap { result in
                    guard let fp = result.path.filePath else { return nil }
                    fp.cache(result.isDir, forKey: \.isDir)
                    fp.cache(result.sourceLabel, forKey: \.sourceIndex)
                    return fp
                }.filter {
                    $0.memoz.isOnExternalVolume ? true : $0.exists
                }
                self.results = self.sortedResults()
                self.searching = false
                if !self.emptyQuery || wantVolumeFilter {
                    self.noQuery = false
                }
            }
        }
    }

    func reloadResults() {
        scoredResults = scoredResults
        results = sortedResults()
    }

    // MARK: - Rename

    func renamePaths(_ renamed: [FilePath: FilePath]) {
        guard !renamed.isEmpty else { return }
        logActivity("Renamed \(renamed.count) file\(renamed.count == 1 ? "" : "s")")
        for (oldPath, newPath) in renamed {
            let isDir = newPath.isDir
            for eng in scopeEngines.values {
                if eng.removePath(oldPath.string) {
                    eng.addPath(newPath.string, isDir: isDir)
                }
            }
            for eng in volumeEngines.values {
                if eng.removePath(oldPath.string) {
                    eng.addPath(newPath.string, isDir: isDir)
                }
            }
            if recentsEngine.removePath(oldPath.string) {
                recentsEngine.addPath(newPath.string, isDir: isDir)
            }
        }
        scheduleSaveIndexes()
    }

    // MARK: - Index Persistence

    /// Schedule a debounced save of all scope and volume indexes (5s delay).
    func scheduleSaveIndexes() {
        saveIndexTask?.cancel()
        saveIndexTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self.setOperation("Saving index\u{2026}")
            self.logActivity("Saving index to disk")
            let scopes = self.scopeEngines
            let volumes = self.volumeEngines
            await Task.detached {
                for (scope, eng) in scopes {
                    let file = scopeIndexFile(scope)
                    eng.saveBinaryIndex(to: file.url)
                }
                for (volume, eng) in volumes {
                    let file = volumeIndexFile(volume)
                    eng.saveBinaryIndex(to: file.url)
                }
            }.value
            self.logActivity("Index saved (\(scopes.count) scopes, \(volumes.count) volumes)")
            self.setOperation("")
        }
    }

    // MARK: - Exclude

    func excludeFromIndex(paths: Set<FilePath>) {
        logActivity("Excluded \(paths.count) path\(paths.count == 1 ? "" : "s") from index")
        let homeStr = HOME.string + "/"
        let homePaths = paths.filter { $0.string.hasPrefix(homeStr) }
        let nonHomePaths = paths.subtracting(homePaths)

        // Keep excluded paths in memory so they never reappear during reindex
        excludedPaths.formUnion(paths.map(\.string))

        if !homePaths.isEmpty {
            // Write HOME-relative paths to fsignore (skip already-present lines)
            let relativePaths = homePaths.map { path -> String in
                var rel = String(path.string.dropFirst(homeStr.count))
                if path.isDir { rel += "/" }
                return rel
            }
            let existingLines = Set((try? String(contentsOfFile: fsignoreString, encoding: .utf8))?.components(separatedBy: .newlines) ?? [])
            let newPaths = relativePaths.filter { !existingLines.contains($0) }

            if !newPaths.isEmpty {
                let fileList = newPaths.joined(separator: "\n")

                // Suppress fsignore watcher before writing (we'll do our own targeted reindex)
                fsignoreWatchSuppressedUntil = CFAbsoluteTimeGetCurrent() + 10
                fsignoreReindexTask?.cancel()

                do {
                    let fileHandle = try FileHandle(forUpdating: fsignore.url)
                    fileHandle.seekToEndOfFile()
                    if let data = "\n\(fileList)".data(using: .utf8) {
                        fileHandle.write(data)
                    }
                    fileHandle.closeFile()
                } catch {
                    log.error("Failed to write to fsignore: \(error.localizedDescription)")
                }

                bust_gitignore_cache()

                // Update content hash so watcher doesn't trigger after suppression expires
                fsignoreContentHashes[fsignoreString] = contentHash(of: fsignoreString)
            }
        }

        if !nonHomePaths.isEmpty {
            // Group paths by volume
            var volumePaths: [FilePath: [FilePath]] = [:]
            var otherPaths: [FilePath] = []
            for path in nonHomePaths {
                if let volume = enabledVolumes.first(where: { path.starts(with: $0) }) {
                    volumePaths[volume, default: []].append(path)
                } else {
                    otherPaths.append(path)
                }
            }

            // Write volume paths to each volume's .fsignore
            for (volume, paths) in volumePaths {
                let volumeFsignore = volume / ".fsignore"
                let volumeStr = volume.string + "/"
                let relativePaths = paths.map { path -> String in
                    var rel = String(path.string.dropFirst(volumeStr.count))
                    if path.isDir { rel += "/" }
                    return rel
                }
                let existingLines = Set((try? String(contentsOfFile: volumeFsignore.string, encoding: .utf8))?.components(separatedBy: .newlines) ?? [])
                let newPaths = relativePaths.filter { !existingLines.contains($0) }
                if !newPaths.isEmpty {
                    let fileList = newPaths.joined(separator: "\n")
                    do {
                        if !volumeFsignore.exists {
                            FileManager.default.createFile(atPath: volumeFsignore.string, contents: nil)
                        }
                        let fileHandle = try FileHandle(forUpdating: volumeFsignore.url)
                        fileHandle.seekToEndOfFile()
                        if let data = "\n\(fileList)".data(using: .utf8) {
                            fileHandle.write(data)
                        }
                        fileHandle.closeFile()
                    } catch {
                        log.error("Failed to write to \(volumeFsignore.string): \(error.localizedDescription)")
                    }
                }
            }

            // Non-volume, non-home paths go to blockedContains
            if !otherPaths.isEmpty {
                let current = Defaults[.blockedContains]
                let existingLines = Set(current.components(separatedBy: .newlines))
                let newPaths = otherPaths.map(\.string).filter { !existingLines.contains($0) }
                if !newPaths.isEmpty {
                    let additions = newPaths.joined(separator: "\n")
                    var updated = current
                    if !updated.hasSuffix("\n") { updated += "\n" }
                    updated += additions
                    Defaults[.blockedContains] = updated
                    PathBlocklist.shared.rebuild()
                }
            }
        }

        // Remove from all live engines
        for path in paths {
            for eng in scopeEngines.values {
                eng.removePath(path.string)
            }
            for eng in volumeEngines.values {
                eng.removePath(path.string)
            }
            recentsEngine.removePath(path.string)
        }
        removedFiles.formUnion(paths.map(\.string))
        results = results.without(paths)
        scoredResults = scoredResults.without(paths)
        recents = recents.without(paths)
        sortedRecents = sortedRecents.without(paths)
        scheduleSaveIndexes()
    }

    /// Force a previously-excluded path back into the index by removing blocklist rules and/or appending
    /// `!` re-include rules to the relevant ignore file, then reindexing the affected scopes/volumes.
    /// Inverse of `excludeFromIndex`. See `IndexInclusionAnalyzer` for how plans are produced.
    func includeInIndex(_ plan: IndexInclusionPlan) {
        guard !plan.isEmpty || plan.fullReindex || !plan.reindexScopes.isEmpty || !plan.reindexVolumes.isEmpty else { return }
        logActivity("Reindexing a path that was excluded")

        // 1. Update the global blocklist: add `!` exceptions and/or remove matched rules.
        var blocklistChanged = false
        if !plan.addBlockedPrefixes.isEmpty {
            Defaults[.blockedPrefixes] = Self.appendingLines(plan.addBlockedPrefixes, to: Defaults[.blockedPrefixes])
            blocklistChanged = true
        }
        if !plan.removeBlockedPrefixes.isEmpty {
            Defaults[.blockedPrefixes] = Self.removingLines(plan.removeBlockedPrefixes, from: Defaults[.blockedPrefixes])
            blocklistChanged = true
        }
        if !plan.addBlockedContains.isEmpty {
            Defaults[.blockedContains] = Self.appendingLines(plan.addBlockedContains, to: Defaults[.blockedContains])
            blocklistChanged = true
        }
        if !plan.removeBlockedContains.isEmpty {
            Defaults[.blockedContains] = Self.removingLines(plan.removeBlockedContains, from: Defaults[.blockedContains])
            blocklistChanged = true
        }
        if blocklistChanged {
            PathBlocklist.shared.rebuild()
        }

        // 2. Append ignore-file lines (re-exclusions first, then `!` re-includes, already ordered by the plan).
        if !plan.addHomeFsignoreLines.isEmpty {
            appendIgnoreLines(plan.addHomeFsignoreLines, to: fsignore, suppressWatcher: true)
        }
        for (volume, lines) in plan.volumeFsignoreLines where !lines.isEmpty {
            appendIgnoreLines(lines, to: volume / ".fsignore", suppressWatcher: false)
        }
        if !plan.scopeFsignoreLines.isEmpty {
            ScopeIgnore.ensureDir()
            for (scope, lines) in plan.scopeFsignoreLines where !lines.isEmpty {
                appendIgnoreLines(lines, to: ScopeIgnore.file(for: scope), suppressWatcher: false)
            }
        }

        // 3. Reindex what's affected.
        if plan.fullReindex {
            refresh(pauseSearch: false)
        } else {
            if !plan.reindexScopes.isEmpty {
                refresh(pauseSearch: false, scopes: Array(plan.reindexScopes))
            }
            for volume in plan.reindexVolumes {
                indexVolume(volume)
            }
        }
    }

    /// Apply a set of exclusion rules chosen in the Exclude-from-index sheet: append ignore-file lines and/or
    /// blocklist lines, drop the selected paths from the live index immediately, then reindex if the rules are
    /// broad enough to also match other indexed paths.
    func excludeFromIndex(rules: [ExcludeRule], paths: Set<FilePath>, reindex: Bool) {
        guard !rules.isEmpty else { return }
        logActivity("Excluded \(paths.count) path\(paths.count == 1 ? "" : "s") from index")

        var homeLines: [String] = []
        var volumeLines: [FilePath: [String]] = [:]
        var scopeLines: [SearchScope: [String]] = [:]
        var blockedPrefixLines: [String] = []
        var blockedContainsLines: [String] = []
        for rule in rules {
            switch rule.mechanism {
            case .homeIgnore: homeLines.append(rule.line)
            case let .volumeIgnore(v): volumeLines[v, default: []].append(rule.line)
            case let .scopeIgnore(scope): scopeLines[scope, default: []].append(rule.line)
            case .blocklist: rule.blocklistPrefix ? blockedPrefixLines.append(rule.line) : blockedContainsLines.append(rule.line)
            }
        }

        if !homeLines.isEmpty {
            appendIgnoreLines(homeLines, to: fsignore, suppressWatcher: true)
        }
        for (volume, lines) in volumeLines where !lines.isEmpty {
            appendIgnoreLines(lines, to: volume / ".fsignore", suppressWatcher: false)
        }
        if !scopeLines.isEmpty {
            ScopeIgnore.ensureDir()
            for (scope, lines) in scopeLines where !lines.isEmpty {
                appendIgnoreLines(lines, to: ScopeIgnore.file(for: scope), suppressWatcher: false)
            }
        }
        var blocklistChanged = false
        if !blockedPrefixLines.isEmpty {
            Defaults[.blockedPrefixes] = Self.appendingLines(blockedPrefixLines, to: Defaults[.blockedPrefixes])
            blocklistChanged = true
        }
        if !blockedContainsLines.isEmpty {
            Defaults[.blockedContains] = Self.appendingLines(blockedContainsLines, to: Defaults[.blockedContains])
            blocklistChanged = true
        }
        if blocklistChanged { PathBlocklist.shared.rebuild() }

        // Drop the selected paths from the live index immediately for instant feedback.
        excludedPaths.formUnion(paths.map(\.string))
        for path in paths {
            for eng in scopeEngines.values {
                eng.removePath(path.string)
            }
            for eng in volumeEngines.values {
                eng.removePath(path.string)
            }
            recentsEngine.removePath(path.string)
        }
        removedFiles.formUnion(paths.map(\.string))
        results = results.without(paths)
        scoredResults = scoredResults.without(paths)
        recents = recents.without(paths)
        sortedRecents = sortedRecents.without(paths)

        if reindex {
            let scopes = Set(paths.flatMap { IndexInclusionAnalyzer.scopesForPath($0.string, home: HOME.string) })
            let volumes = Set(paths.compactMap { p in enabledVolumes.first { p.starts(with: $0) } })
            for volume in volumes {
                indexVolume(volume)
            }
            if !scopes.isEmpty {
                refresh(pauseSearch: false, scopes: Array(scopes))
            } else if volumes.isEmpty {
                refresh(pauseSearch: false)
            }
        } else {
            scheduleSaveIndexes()
        }
    }

    // MARK: - Sorting

    func sortedResults(results: [FilePath]? = nil) -> [FilePath] {
        guard sortField != .score else {
            return results ?? scoredResults
        }
        return (results ?? scoredResults).sorted { a, b in
            switch sortField {
            case .name:
                return reverseSort ? (a.name.string.lowercased() > b.name.string.lowercased()) : (a.name.string.lowercased() < b.name.string.lowercased())
            case .path:
                return reverseSort ? (a.dir.string.lowercased() > b.dir.string.lowercased()) : (a.dir.string.lowercased() < b.dir.string.lowercased())
            case .size:
                let aSize = a.memoz.size
                let bSize = b.memoz.size
                return reverseSort ? (aSize > bSize) : (aSize < bSize)
            case .date:
                let aDate = a.memoz.date
                let bDate = b.memoz.date
                return reverseSort ? (aDate > bDate) : (aDate < bDate)
            case .kind:
                let aKind = ((a.memoz.isDir ? "\0" : "") + (a.extension ?? "") + (a.stem ?? "")).lowercased()
                let bKind = ((b.memoz.isDir ? "\0" : "") + (b.extension ?? "") + (b.stem ?? "")).lowercased()
                return reverseSort ? (aKind > bKind) : (aKind < bKind)
            default:
                return true
            }
        }
    }

    // MARK: - Default Results (empty query)

    /// Merge live index changes + MDQuery recents into smart default results
    func computeDefaultResults() -> [FilePath] {
        var seen = Set<String>()
        var results = [FilePath]()
        let maxResults = proactive ? Defaults[.maxResultsCount] : min(Defaults[.maxResultsCount], 500)

        // 1. Live index changes (newest first, added/modified only). Cap the backward scan: normally the 20
        //    freshest live results are found right away, but when a burst of transient files keeps failing the
        //    `exists` check we must not walk an unbounded history calling isPathBlocked on the main thread.
        //    MDQuery recents backfill anything we stop short of.
        var ci = liveIndexChanges.count - 1
        let scanFloor = max(0, ci - liveScanBudget)
        while ci >= scanFloor, results.count < 20 {
            let change = liveIndexChanges[ci]
            if change.kind != .removed, !seen.contains(change.path),
               isRelevantDefaultPath(change.path),
               let fp = change.path.filePath, fp.exists
            {
                seen.insert(change.path)
                results.append(fp)
            }
            ci -= 1
        }

        // 2. MDQuery recents (already filtered by isRelevantDefaultPath in getPaths)
        for fp in mdQueryRecents where !seen.contains(fp.string) {
            seen.insert(fp.string)
            results.append(fp)
            if results.count >= maxResults { break }
        }

        return results
    }

    /// Mark default results as needing recomputation (cheap, no work done)
    func invalidateDefaultResults() {
        defaultResultsDirty = true
    }

    /// Recompute default results if dirty and window is active
    func refreshDefaultResultsIfNeeded() {
        guard defaultResultsDirty else { return }
        performUpdateDefaultResults()
    }

    /// Recompute default results and update the UI + coordinator
    func updateDefaultResults(debounce: Bool = false) {
        guard debounce else {
            performUpdateDefaultResults()
            return
        }
        invalidateDefaultResults()
        guard WM.mainWindowActive else { return }
        updateDefaultResultsTask = mainAsyncAfter(ms: 500) { [self] in
            performUpdateDefaultResults()
        }
    }

    func constructQuery(_ query: String) -> String {
        var query = query
        if query.contains("~/") {
            query = query.replacingOccurrences(of: "~/", with: "\(HOME.string)/")
        }
        return query
    }

    // MARK: - Open With

    func computeOpenWithApps(for urls: [URL]) {
        computeOpenWithTask = mainAsyncAfter(ms: 100) { [self] in
            commonOpenWithApps = commonApplications(for: urls).sorted(by: \.lastPathComponent)
            // Keep open-with app hotkeys from stealing letters already bound to
            // ⌘⌥ actions (see ActionButtons), e.g. ⌘⌥C for Copy to...
            openWithAppShortcuts = computeShortcuts(for: commonOpenWithApps, reserved: reservedOptionCommandLetters)
            for app in commonOpenWithApps where appIconCache[app.path] == nil {
                appIconCache[app.path] = appIconThumbnail(forFile: app.path)
            }
        }
    }

    func discoverInstalledApps() {
        appDiscoveryQuery = queryInstalledApps { [self] apps in
            let filtered = apps.filter { isAppPathRelevant($0.path.string) }
            let grouped = Dictionary(grouping: filtered, by: \.bundleIdentifier)
            let unique = grouped.values.compactMap { $0.max(by: { $0.useCount < $1.useCount }) }
            let urls = unique.map(\.url).sorted(by: \.lastPathComponent)

            var icons: [String: NSImage] = [:]
            for url in urls {
                icons[url.path] = appIconThumbnail(forFile: url.path)
            }

            mainActor {
                self.appIconCache = icons
                self.installedApps = urls
            }
        }
    }

    func watchAppDirectories() {
        for dir in APP_DIRS where !dir.hasPrefix("/System") {
            let fd = open(dir, O_EVTONLY)
            guard fd >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
            source.setEventHandler { [self] in
                appRefreshTask?.cancel()
                appRefreshTask = mainAsyncAfter(ms: 5000) {
                    self.discoverInstalledApps()
                }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            appDirWatchers.append(source)
        }
    }

    // MARK: - Helpers

    func appendToIndex(_ paths: [String]) {
        for path in paths {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            recentsEngine.addPath(path, isDir: isDirectory.boolValue)
        }
    }

    /// Append a live change. The history stays searchable for a long window (find a change from a day ago)
    /// while memory stays bounded by the number of *distinct* changes, not the number of FS events: a
    /// frequently-touched file keeps only its latest event per kind. Compaction is lazy, so appends are O(1)
    /// and duplicates are collapsed only when the raw array passes the threshold.
    func appendLiveChange(_ change: IndexChange) {
        liveIndexChanges.append(change)
        if liveIndexChanges.count > liveChangesCompactThreshold {
            compactLiveChanges()
        }
    }

    /// User-triggered compaction (the live-changes "Compact" button). Same dedup as the automatic pass, but
    /// on demand regardless of the threshold, and it reports how many duplicate events were collapsed.
    func compactLiveChangesManually() {
        let before = liveIndexChanges.count
        compactLiveChanges()
        let removed = before - liveIndexChanges.count
        logActivity("Compacted live changes: collapsed \(removed) duplicate event\(removed == 1 ? "" : "s")")
    }

    @ObservationIgnored private var _lastOperationUpdate: CFAbsoluteTime = 0
    @ObservationIgnored private var _operationThrottle: Task<Void, Never>?

    @ObservationIgnored private var saveIndexTask: Task<Void, Never>?

    @ObservationIgnored private var activityTimers: [String: CFAbsoluteTime] = [:]

    // MARK: - Search

    @ObservationIgnored private var lastSearchQuery = ""

    @ObservationIgnored private var lastSearchFolderFilter: FolderFilter?
    @ObservationIgnored private var lastSearchQuickFilter: QuickFilter?
    @ObservationIgnored private var lastSearchVolumeFilter: FilePath?

    @ObservationIgnored private var observers: Set<AnyCancellable> = []
    @ObservationIgnored private var recentsQuery: MDQuery? = queryRecents()
    @ObservationIgnored private var fullDiskAccessChecker: Repeater?
    @ObservationIgnored private var indexChecker: Repeater?
    @ObservationIgnored private var fsignoreWatchSources: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var fsignoreContentHashes: [String: Int] = [:]
    @ObservationIgnored private var fsignoreReindexTask: DispatchWorkItem?

    private static func removingLines(_ remove: [String], from content: String) -> String {
        let toRemove = Set(remove.map { $0.trimmingCharacters(in: .whitespaces) })
        return content
            .components(separatedBy: .newlines)
            .filter { !toRemove.contains($0.trimmingCharacters(in: .whitespaces)) }
            .joined(separator: "\n")
    }

    private static func appendingLines(_ add: [String], to content: String) -> String {
        let existing = Set(content.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) })
        let newLines = add.filter { !existing.contains($0.trimmingCharacters(in: .whitespaces)) }
        guard !newLines.isEmpty else { return content }
        var updated = content
        if !updated.isEmpty, !updated.hasSuffix("\n") { updated += "\n" }
        updated += newLines.joined(separator: "\n")
        return updated
    }

    private func appendIgnoreLines(_ lines: [String], to file: FilePath, suppressWatcher: Bool) {
        let existing = Set((try? String(contentsOfFile: file.string, encoding: .utf8))?.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) } ?? [])
        let newLines = lines.filter { !existing.contains($0.trimmingCharacters(in: .whitespaces)) }
        guard !newLines.isEmpty else { return }

        if suppressWatcher {
            fsignoreWatchSuppressedUntil = CFAbsoluteTimeGetCurrent() + 10
            fsignoreReindexTask?.cancel()
        }

        do {
            if !file.exists {
                FileManager.default.createFile(atPath: file.string, contents: nil)
            }
            let handle = try FileHandle(forUpdating: file.url)
            handle.seekToEndOfFile()
            if let data = "\n\(newLines.joined(separator: "\n"))".data(using: .utf8) {
                handle.write(data)
            }
            handle.closeFile()
        } catch {
            log.error("Failed to append to \(file.string): \(error.localizedDescription)")
        }

        bust_gitignore_cache()
        if suppressWatcher {
            fsignoreContentHashes[file.string] = contentHash(of: file.string)
        }
    }

    /// Collapse the live-change history to the latest event per (path, kind), preserving oldest→newest order,
    /// and keep at most liveChangesMax distinct entries (dropping the oldest). Walking newest→oldest and
    /// keeping the first occurrence of each key retains the most recent event, and its date, for that key.
    private func compactLiveChanges() {
        struct Key: Hashable {
            let path: String
            let kind: IndexChange.Kind
        }
        var seen = Set<Key>()
        var deduped: [IndexChange] = []
        deduped.reserveCapacity(min(liveIndexChanges.count, liveChangesMax))
        for change in liveIndexChanges.reversed() {
            guard seen.insert(Key(path: change.path, kind: change.kind)).inserted else { continue }
            deduped.append(change)
            if deduped.count >= liveChangesMax { break } // newest-first, so this drops only the oldest
        }
        deduped.reverse() // restore oldest→newest
        liveIndexChanges = deduped
    }

    private func compactOperationSummary() -> String {
        let ops = Array(ongoingOperations.values)
        guard let first = ops.last else { return "" }
        if ops.count == 1 { return first }
        return "\(first) (+\(ops.count - 1) more)"
    }

    // MARK: - Ignore File Watching

    private func contentHash(of path: String) -> Int? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return data.hashValue
    }

    private func performUpdateDefaultResults() {
        defaultResultsDirty = false
        let defaults: [FilePath] = switch Defaults[.defaultResultsMode] {
        case .recentFiles: computeDefaultResults()
        case .runHistory: RH.topResults(limit: Defaults[.maxResultsCount])
        case .empty: []
        }
        recents = defaults
        sortedRecents = sortedResults(results: defaults)
        searchCoordinator.setRecents(defaults.map {
            SearchCoordinator.RecentEntry(path: $0.string, isDir: $0.isDir)
        })
        let mdCount = mdQueryRecents.count
        let liveCount = liveIndexChanges.count
        log.debug("updateDefaultResults: mdQuery=\(mdCount) live=\(liveCount) merged=\(defaults.count)")
    }

    /// Returns the walk directories for a given scope.
    private func scopeCouldContain(_ scope: SearchScope, prefix: String) -> Bool {
        for dir in walkDirs(for: scope) {
            // prefix is inside this scope dir, or scope dir is inside the prefix
            if prefix.hasPrefix(dir.dir) || dir.dir.hasPrefix(prefix) { return true }
        }
        return false
    }

    private func walkDirs(for scope: SearchScope) -> [(dir: String, excludePrefix: String?, applyIgnore: Bool)] {
        switch scope {
        case .home:
            var dirs: [(dir: String, excludePrefix: String?, applyIgnore: Bool)] = [(HOME.string, "\(HOME.string)/Library", true)]
            if FileManager.default.fileExists(atPath: "/Users/Shared") {
                // /Users/Shared is not under HOME, so ~/.fsignore (rooted at HOME) cannot be applied.
                dirs.append(("/Users/Shared", nil, false))
            }
            return dirs
        case .library: return [("\(HOME.string)/Library", nil, true)]
        case .applications: return [("/Applications", nil, false), ("/System/Applications", nil, false)]
        case .system: return [("/System", "/System/Volumes", false)]
        case .root:
            return ["/usr", "/bin", "/sbin", "/opt", "/etc", "/Library", "/var", "/private"]
                .filter { FileManager.default.fileExists(atPath: $0) }
                .map { ($0, nil, false) }
        }
    }

}

// MARK: - Helpers

/// Letters bound to ⌘⌥<letter> actions (see ActionButtons), so open-with app
/// hotkeys never override them. Only plain-letter combos collide; ⌘⌥⏎/⌘⌥⌫ and
/// ⌘⌥⇧-prefixed combos use other keys and are safe.
let reservedOptionCommandLetters: Set<Character> = ["c"] // ⌘⌥C Copy to...

/// Each app is keyed by the first letter of its name, which is what a user expects (Notes → N).
/// Several apps can share a letter; that collision is resolved at press time by opening the picker
/// scoped to them. Apps whose first letter is reserved (e.g. "c" = ⌘⌥C Copy to…) get no shortcut.
func computeShortcuts(for urls: [URL], reserved: Set<Character> = []) -> [URL: Character] {
    var shortcuts = [URL: Character]()
    for url in urls {
        let name = url.lastPathComponent.ns.deletingPathExtension
        guard let first = name.lowercased().first(where: { $0.isLetter || $0.isNumber }) else { continue }
        if reserved.contains(first) { continue }
        shortcuts[url] = first
    }
    return shortcuts
}

import Defaults

func commonApplications(for urls: [URL]) -> [URL] {
    let appSets = urls.map { Set(NSWorkspace.shared.urlsForApplications(toOpen: $0)) }
    guard let first = appSets.first else { return [] }
    var commonApps = appSets.dropFirst().reduce(first) { $0.intersection($1) }
    if let terminal = Defaults[.terminalApp].fileURL, let editor = Defaults[.editorApp].fileURL {
        commonApps = commonApps.filter { $0 != terminal && $0 != editor }
    }
    commonApps = commonApps.filter { $0.lastPathComponent != "Google Chrome for Testing.app" }
    let commonAppsDict: [String: [URL]] = commonApps.group(by: \.bundleIdentifier)
    let uniqueAppsByShortestPath = commonAppsDict.values.compactMap { $0.min(by: \.path.count) }
    return uniqueAppsByShortestPath
}

@MainActor let FUZZY = FuzzyClient()
