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
    init() {
        rebuild()
    }

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

    var hasAllows: Bool {
        !allowPrefixes.isEmpty || !allowComponents.isEmpty
    }

    func rebuild() {
        let (blockPrefixes, allowPfx) = Self.split(Defaults[.blockedPrefixes])
        let (blockContains, allowContains) = Self.split(Defaults[.blockedContains])

        prefixes = Self.expandPrivate(blockPrefixes.map(expandingHomeTilde)).map { Array($0.utf8) }
        let expandedAllow = Self.expandPrivate(allowPfx.map(expandingHomeTilde))
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
                if !value.isEmpty {
                    allow.append(value)
                }
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

/// Spells out a leading `~` or `~/` against the home folder so a typed `~/Library/Caches/` works as a
/// blocklist prefix. Hand-rolled because `expandingTildeInPath` drops the trailing slash, which would widen
/// the prefix `~/Library/` to also block `~/LibraryOld`. `~user` forms are left as typed.
func expandingHomeTilde(_ path: String) -> String {
    guard path == "~" || path.hasPrefix("~/") else { return path }
    return HOME.string + path.dropFirst()
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
            if len >= pLen, memcmp(buf.baseAddress!, prefix, pLen) == 0 {
                best = pLen; continue
            }
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
            if matched {
                best = cLen
            }
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
func pathBlockMatch(_ path: String) -> Bool {
    pathBlockLength(path) > 0
}

/// Whether a path matches an allow exception (`!` rule).
func pathAllowMatch(_ path: String) -> Bool {
    pathAllowLength(path) > 0
}

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
        if withSlash.contains(rule) {
            return true
        }
        if suffixIsPrefix(of: rule, in: withSlash) {
            return true
        }
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
            if sb[off + k] != rb[k] {
                ok = false; break
            }
            k += 1
        }
        if ok {
            return true
        }
    }
    return false
}

/// Diagnose why `rawPath` is or isn't in the index: existence on disk, current index membership, the scope
/// it maps to and whether that scope is enabled, the path blocklist, and the gitignore-style ignore files —
/// mirroring the order the indexer applies them (see `cleanRecentsEngine` and `SearchEngine.walkDirectory`).
/// Returns a human-readable multi-line report for one path. Nonisolated so the CLI handler can call it off
/// the main actor; every predicate it touches is thread-safe (Defaults reads, pure path matchers).
nonisolated func explainPathExclusion(_ rawPath: String, coord: SearchCoordinator) -> String {
    /// The index stores firmlink-resolved paths (/etc -> /private/etc, and the reverse), so probe both forms.
    func firmlinkVariants(_ p: String) -> [String] {
        var out = [p]
        for fl in ["/tmp", "/var", "/etc"] {
            if p == fl || p.hasPrefix(fl + "/") {
                out.append("/private" + p)
            }
            if p == "/private" + fl || p.hasPrefix("/private" + fl + "/") {
                out.append(String(p.dropFirst("/private".count)))
            }
        }
        return out
    }
    let variants = firmlinkVariants(rawPath)
    var lines = [rawPath]

    // 1. Existence on disk.
    var isDir: ObjCBool = false
    let exists = variants.contains { FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) }
    lines.append("  on disk:   " + (exists ? "yes (\(isDir.boolValue ? "directory" : "file"))" : "NO — does not exist"))

    // 2. Currently in the index (ground truth)?
    let engines = Set(variants.flatMap { coord.hasPath($0) })
    let indexed = !engines.isEmpty
    lines.append("  indexed:   " + (indexed ? "yes — \(engines.sorted().joined(separator: ", "))" : "no"))

    // 3. Scope membership + whether that scope is enabled.
    let enabledScopes = Set(Defaults[.searchScopes])
    let home = HOME.string
    let library = home + "/Library"
    let (scope, scopeNote): (SearchScope?, String) = {
        if let (s, root) = ScopeIgnore.scopeAndRoot(forPath: rawPath) {
            return (s, " (root \(root))")
        }
        if rawPath == library || rawPath.hasPrefix(library + "/") {
            return (.library, "")
        }
        if rawPath == home || rawPath.hasPrefix(home + "/") {
            return (.home, "")
        }
        return (nil, "")
    }()
    if let scope {
        lines.append("  scope:     \(scope.rawValue)\(scopeNote) — \(enabledScopes.contains(scope) ? "enabled" : "DISABLED")")
    } else {
        lines.append("  scope:     none — not under any search scope (only /Volumes/* is also indexed)")
    }

    // 4. Path blocklist (built-in block rules + `!` exceptions).
    let blocked = variants.contains { isPathBlocked($0) }
    let blockHit = variants.contains { pathBlockMatch($0) }
    let allowHit = variants.contains { pathAllowMatch($0) }
    if blocked {
        lines.append("  blocklist: BLOCKED by a block rule")
    } else if blockHit, allowHit {
        lines.append("  blocklist: matched a block rule, overridden by a more specific ! exception")
    } else {
        lines.append("  blocklist: no match")
    }

    // 5. Gitignore-style ignore files. The matcher anchors patterns to the ignore file's root, so only query
    // it for strict descendants (querying the root itself or a non-descendant trips a precondition).
    var ignoreReason: String?
    if let (s, root) = ScopeIgnore.scopeAndRoot(forPath: rawPath), rawPath.hasPrefix(root + "/"),
       let f = ScopeIgnore.activeFile(for: s), rawPath.isIgnored(in: f, root: root)
    {
        ignoreReason = "ignored by \((f as NSString).lastPathComponent) (scope \(s.rawValue), root \(root))"
    } else if rawPath.hasPrefix(home + "/"), fsignore.exists, rawPath.isIgnored(in: fsignoreString) {
        ignoreReason = "ignored by ~/.fsignore"
    } else if rawPath.hasPrefix("/Volumes/") {
        let parts = rawPath.dropFirst("/Volumes/".count).split(separator: "/", maxSplits: 1)
        if let volName = parts.first {
            let vIgnore = "/Volumes/\(volName)/.fsignore"
            if FileManager.default.fileExists(atPath: vIgnore), rawPath.isIgnored(in: vIgnore) {
                ignoreReason = "ignored by /Volumes/\(volName)/.fsignore"
            }
        }
    }
    lines.append("  ignore:    " + (ignoreReason ?? "not ignored"))

    // 6. Verdict (first applicable cause, following the indexer's prune order).
    let verdict = if indexed {
        "INDEXED — searchable now"
    } else if !exists {
        "NOT INDEXED — path does not exist on disk"
    } else if let scope, !enabledScopes.contains(scope) {
        "EXCLUDED — the \(scope.rawValue) scope is disabled in Settings"
    } else if scope == nil, !rawPath.hasPrefix("/Volumes/") {
        "EXCLUDED — not under any enabled search scope"
    } else if let ignoreReason {
        "EXCLUDED — \(ignoreReason)"
    } else if blocked {
        "EXCLUDED — blocked by the path blocklist"
    } else {
        "NOT INDEXED — no exclusion rule matched the path itself; the scope may still be indexing, or an ancestor directory is excluded"
    }
    lines.append("  => \(verdict)")

    return lines.joined(separator: "\n")
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

    var id: String {
        rawValue
    }
}

private func computeEnabledVolumes(mounted: [FilePath], disabled: [FilePath]) -> [FilePath] {
    let disabledSet = Set(disabled)
    let mountedSet = Set(mounted)
    let mountedEnabled = mounted.filter { !disabledSet.contains($0) }
    let disconnected = Defaults[.indexedVolumePaths].filter { !mountedSet.contains($0) && !disabledSet.contains($0) }
    return mountedEnabled + disconnected
}

/// Frees a replaced index off the main thread.
///
/// `FuzzyClient` is `@MainActor`, so overwriting one of its engine dictionaries drops the last
/// reference to the outgoing `SearchEngine` right there and runs its deinit on the main thread.
/// Tearing down a multi-million entry index takes long enough to land in Sentry as a 30 second
/// hang (CLING-59). Handing the outgoing object to a background task moves the teardown with it.
func releaseInBackground(_ object: AnyObject?) {
    guard let object else { return }
    Task.detached(priority: .background) {
        withExtendedLifetime(object) {}
    }
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

            init(_ kind: LiveIndexBatch.Kind) {
                switch kind {
                case .added: self = .added
                case .modified: self = .modified
                case .removed: self = .removed
                }
            }

            static func < (lhs: Kind, rhs: Kind) -> Bool {
                lhs.rawValue < rhs.rawValue
            }
        }

        let id = UUID()
        let path: String
        let kind: Kind
        let date = Date()

        var name: String {
            (path as NSString).lastPathComponent
        }
        var dir: String {
            (path as NSString).deletingLastPathComponent
        }
    }

    /// A file change waiting on `fsEventsQueue` to be shown: one the scope indexes took, with what it did to them, or
    /// one outside them (no kind), which is worked out from what was seen before.
    struct PendingFSChange {
        let path: FilePath
        let exists: Bool
        var kind: IndexChange.Kind?
    }

    struct ActivityEntry: Identifiable {
        let id = UUID()
        let message: String
        let date = Date()
        let durationMs: Double?
    }

    /// How long FSEvents changes accumulate before one main-actor flush.
    nonisolated static let fsFlushInterval: DispatchTimeInterval = .milliseconds(100)

    static let initialVolumes = getVolumes()

    /// Score biases per scope (higher = results ranked higher in merged output)
    static let scopeBiases: [SearchScope: Int] = [
        .home: 2, .applications: 1, .library: 0, .system: -1, .root: -1,
    ]

    static let freeScopes: Set<SearchScope> = [.home, .applications, .library]

    /// How long `indexPathFirst` may walk before handing over to the full reindex. Past this the path is about as
    /// costly as its scope, and whatever the walk reached stays searchable until the reindex lands.
    static let pathFirstWalkBudget: CFAbsoluteTime = 3

    /// Where the old watcher fed the live index before scopes were kept current; paths here outside every scope
    /// still go there.
    nonisolated static let recentsRoots = ["/Users/", "/usr/local/", "/opt/", "/Applications/", "/private/tmp/", "/tmp/"]

    /// How far behind a saved scope may be and still catch up by replaying. On a busy development Mac about one event
    /// id in twenty reaches the watcher, and replaying ~1M changes (20M ids, a day or so of use) cost ~28s of CPU, two
    /// thirds of it in fseventsd reading its history, the same as walking every scope; further back a walk is cheaper.
    static let maxReplayGap: UInt64 = 20_000_000
    /// Past this many changed paths noted while hidden, they are shown anyway rather than held without bound.
    nonisolated static let hiddenChangesMax = 20000

    @ObservationIgnored var searchTask: Task<Void, Never>?
    /// Thread-safe coordinator for CLI and multi-engine search
    @ObservationIgnored let searchCoordinator = SearchCoordinator()

    var liveIndexChanges: [IndexChange] = []
    var showLiveIndex = false
    var showActivityLog = false
    var showRunHistory = false
    var showIndexBrowser = false
    @ObservationIgnored var savedQuery: String?
    var activityLog: [ActivityEntry] = []
    var loadingIndex = false
    /// A scope or Pro change arrived while engines were loading; it is applied once they are in.
    @ObservationIgnored var scopeSyncPending = false
    var indexedCount = 0
    var clopIsAvailable = false
    var removedFiles: Set<String> = []
    var excludedPaths: Set<String> = []
    var results: [FilePath] = []
    var seenPaths: Set<String> = []
    var operation = ""
    var scoredResults: [FilePath] = []
    var recents: [FilePath] = [] // Merged default results (live index + MDQuery)
    /// The recent files whatever the window's default results are, for a search bar set to show them.
    var recentFiles: [FilePath] = []
    var sortedRecents: [FilePath] = [] // Same, sorted by current sort field
    @ObservationIgnored var mdQueryRecents: [FilePath] = [] // Raw MDQuery results (filtered)
    var commonOpenWithApps: [URL] = []
    var openWithAppShortcuts: [URL: Character] = [:]
    @ObservationIgnored var openWithGeneration = 0
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
    @ObservationIgnored var cliMachPort: CFMessagePort?

    // MARK: - Search Engines (per-scope + recents)

    /// Per-scope engines: each scope has its own SearchEngine for independent search/load/unload
    @ObservationIgnored var scopeEngines: [SearchScope: SearchEngine] = [:]
    @ObservationIgnored var volumeEngines: [FilePath: SearchEngine] = [:]
    @ObservationIgnored var smbMetadataCaches: [FilePath: SMBMetadataCache] = [:]
    @ObservationIgnored var recentsEngine = SearchEngine()

    @ObservationIgnored var suppressNextSearch = false
    @ObservationIgnored let fsEventsQueue = DispatchQueue(label: "com.lowtechguys.Cling.fsevents", qos: .utility)

    /// FSEvents changes filtered on `fsEventsQueue`, waiting for the next main-actor flush.
    /// Touched only on `fsEventsQueue`.
    @ObservationIgnored nonisolated(unsafe) var pendingFSChanges: [PendingFSChange] = []
    @ObservationIgnored nonisolated(unsafe) var fsFlushScheduled = false
    /// The watcher is replaying changes made since the indexes were saved; those reach the indexes but are not
    /// shown as live changes. Touched only on `fsEventsQueue`.
    @ObservationIgnored nonisolated(unsafe) var replayingHistory = false
    /// Changes inside the scopes that arrived while no Cling window was on screen, path to the order they last
    /// happened in, shown once a window is (see `followChanges`). Touched only on `fsEventsQueue`.
    @ObservationIgnored nonisolated(unsafe) var hiddenChanges: [String: (order: Int, kind: IndexChange.Kind)] = [:]
    /// Entries the scope indexes gained since the count on screen last moved. Only touched on `fsEventsQueue`.
    @ObservationIgnored nonisolated(unsafe) var pendingCountDelta = 0
    @ObservationIgnored nonisolated(unsafe) var hiddenChangeOrder = 0
    /// The main or Settings window is on screen. Read on the stream's and the live updater's queues.
    @ObservationIgnored let windowOnScreen = SharedFlag(false)
    /// The indexes changed while no window was on screen, so search caches and pools are refreshed once one is.
    @ObservationIgnored let indexChangedOffScreen = SharedFlag(false)
    @ObservationIgnored var liveStream: FSChangeStream?
    @ObservationIgnored var windowObservers: [NSObjectProtocol] = []

    /// The FSEvents position each scope engine in memory reflects. A scope missing here has no position to replay
    /// from and is walked again.
    @ObservationIgnored var liveBase: [SearchScope: UInt64] = [:]
    /// The rules each scope engine in memory was walked by (see `rulesFingerprint`).
    @ObservationIgnored var liveRules: [SearchScope: String] = [:]
    @ObservationIgnored var liveUpdater: LiveIndexUpdater?
    /// Folders the walks skip whose changes the stream leaves out.
    @ObservationIgnored var unwatched = UnwatchedFolders()
    /// The changes the background agent gathered while Cling was closed, applied when the stream first starts.
    @ObservationIgnored var launchJournal: ChangeJournal?
    /// Since when the updater has counted changes in the folders the walks skip.
    @ObservationIgnored var skippedCountedSince = Date()
    @ObservationIgnored var lastLiveSave = Date()
    @ObservationIgnored var lastHistoryLossWalk: Date?
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

    /// The scopes search uses: the enabled ones, and without Pro only the free ones. Nothing else is walked, loaded,
    /// followed or saved, since its results would never be shown.
    var searchableScopes: [SearchScope] {
        Defaults[.searchScopes].filter { proactive || Self.freeScopes.contains($0) }
    }

    @ObservationIgnored var livePoolRefresh: DispatchWorkItem? {
        didSet { oldValue?.cancel() }
    }

    @ObservationIgnored var appDiscoveryQuery: MetaQuery? {
        didSet { _ = oldValue }
    }

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
                    if folderFilter != nil {
                        folderFilter = nil
                    }
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
        // Everything holds what all the others do and more, so it is searched alone.
        if EVERYTHING.active, let engine = EVERYTHING.engine {
            return [(engine, "Everything", 0)]
        }
        var result = [(SearchEngine, String, Int)]()
        for scope in searchableScopes {
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

    var externalVolumes: [FilePath] = initialVolumes {
        didSet {
            registerNewVolumes()
            let mounted = Set(externalVolumes)
            disconnectedVolumes = Set(Defaults[.indexedVolumePaths].filter { !mounted.contains($0) && !disabledVolumes.contains($0) })
            enabledVolumes = computeEnabledVolumes(mounted: externalVolumes, disabled: disabledVolumes)
            readOnlyVolumes = externalVolumes.filter(\.url.volumeIsReadOnly)
            externalIndexes = getExternalIndexes()
            indexStaleExternalVolumes()
        }
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
                if folderFilter != nil {
                    folderFilter = nil
                }
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
                if volumeFilter != nil {
                    volumeFilter = nil
                }
                // Merge folders into active quick filter, keeping non-folder properties
                if let currentQuick = quickFilter {
                    quickFilter = QuickFilter(
                        id: currentQuick.id, extensions: currentQuick.extensions,
                        preQuery: currentQuick.preQuery, postQuery: currentQuick.postQuery,
                        dirsOnly: currentQuick.dirsOnly, folders: folderFilter.folders, key: currentQuick.key,
                        maxDepth: currentQuick.maxDepth, uuid: currentQuick.uuid
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
            if suppressNextSearch {
                suppressNextSearch = false; return
            }
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

    @ObservationIgnored var querySendTask: DispatchWorkItem? {
        didSet { oldValue?.cancel() }
    }
    @ObservationIgnored var indexConsolidationTask: DispatchWorkItem? {
        didSet { oldValue?.cancel() }
    }

    var indexExists: Bool {
        scopeIndexesExist
    }

    @ObservationIgnored var computeOpenWithTask: DispatchWorkItem? {
        didSet { oldValue?.cancel() }
    }
    @ObservationIgnored var updateDefaultResultsTask: DispatchWorkItem? {
        didSet { oldValue?.cancel() }
    }

    /// A query too short to search counts as no query at all, so the default results stay up rather
    /// than the list churning through a match on every second file. A folder or Quick Filter narrows
    /// the search enough on its own, so those keep working from the first character.
    @ObservationIgnored var emptyQuery: Bool {
        query.count < Defaults[.minQueryLength] && folderFilter == nil && quickFilter == nil
    }

    // MARK: - Query Construction

    /// Human-friendly name for a folder path
    nonisolated static func friendlyName(for path: FilePath) -> String {
        let home = NSHomeDirectory()
        let s = path.string
        let icloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"

        if s == "/" {
            return "Root"
        }
        if s == home {
            return "Home"
        }
        if s == icloud {
            return "iCloud"
        }
        if s.hasPrefix(icloud + "/") {
            return "iCloud/\(path.name.string)"
        }
        if s == "/System/Applications" {
            return "System Apps"
        }
        if s == "\(home)/Applications" {
            return "~/Applications"
        }
        return path.name.string
    }

    /// Merge results from multiple engines: quality gate + sort + dedup
    nonisolated static func mergeResults(_ results: [SearchResult], maxResults: Int) -> [SearchResult] {
        guard !results.isEmpty else { return [] }
        var bestQ = 0
        var i = 0
        while i < results.count {
            if results[i].quality > bestQ {
                bestQ = results[i].quality
            }
            i &+= 1
        }
        let minQ = bestQ / 3
        var filtered = results.filter { $0.quality >= minQ || $0.hasBase }
        filtered.sort(by: >)
        var seen = Set<String>()
        return filtered.prefix(maxResults * 2).filter { seen.insert($0.path).inserted }.prefix(maxResults).map { $0 }
    }

    /// True when every whitespace-separated token is a positive extension filter (".m4a", "*.png"),
    /// i.e. the query has no fuzzy term to rank by. Such queries take SearchEngine's extension-only
    /// fast path, which is a pure filter — so we widen the result cap to avoid truncating a large
    /// library (e.g. ".m4a" across a Music folder of thousands of tracks) before the wanted file.
    nonisolated static func isExtensionOnlyQuery(_ query: String) -> Bool {
        let tokens = query.split(separator: " ")
        guard !tokens.isEmpty else { return false }
        for t in tokens {
            if t.hasPrefix("."), t.count > 1 {
                continue
            }
            if t.hasPrefix("*."), t.count > 2 {
                continue
            }
            return false
        }
        return true
    }

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
            if let count {
                ongoingOperationCounts[key] = count
            }
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

    /// A reindex/reload swaps in brand-new SearchEngine instances, so any cached QuickFilter pools
    /// still hold entry indices from the now-discarded engines (which can point past the shorter
    /// new arrays). When a pool-based filter is active, rebuild the pools against the current engines;
    /// recomputeQuickFilterPool() re-runs the search itself. Returns true when it took over the
    /// post-reindex search refresh, so the caller can skip its own performSearch().
    @discardableResult
    func refreshPoolsAfterReindex() -> Bool {
        guard let qf = quickFilter, qf.poolExtensions != nil || qf.searchDirsOnly else { return false }
        recomputeQuickFilterPool()
        return true
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
                syncScopeEngines()
                performSearch()
            }.store(in: &observers)
        pub(.literalSearch)
            .sink { [self] _ in
                // The query string is unchanged, so performSearch would skip the re-run.
                invalidateSearch()
                performSearch()
            }.store(in: &observers)

        // The toolbar reads these from HelperApp's cache, so re-check whenever the user points one
        // at a different app.
        for helperApp in [
            Defaults.publisher(.terminalApp).map(\.newValue).eraseToAnyPublisher(),
            Defaults.publisher(.editorApp).map(\.newValue).eraseToAnyPublisher(),
            Defaults.publisher(.shelfApp).map(\.newValue).eraseToAnyPublisher(),
        ] {
            helperApp.sink { HelperApp.refresh([$0]) }.store(in: &observers)
        }

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
                if !toIndex.isEmpty {
                    indexVolumes(Array(toIndex))
                }
            }.store(in: &observers)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didMountNotification)
            .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification))
            .sink { _ in
                // getVolumes() does blocking file IO per volume (lstat on each volume's
                // /Applications, contentsOfDirectory, and a diskutil subprocess with a 3s
                // timeout). On a slow or stalled mount that lstat can block for tens of
                // seconds, and this notification fires on the main run loop, so running it
                // inline froze the app (CLING-V). Compute off-main, assign back on main.
                asyncNow {
                    let volumes = Self.getVolumes()
                    mainActor { self.externalVolumes = volumes }
                }
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
        liveStream?.stop()
        liveStream = nil
        searchTask?.cancel()
        for source in fsignoreWatchSources {
            source.cancel()
        }
        fsignoreWatchSources.removeAll()
        fsignoreReindexTask?.cancel()
    }

    // MARK: - Indexing

    func startIndex() {
        watchWindowVisibility()
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
        } else {
            loadPersistedIndex { [self] in
                // Each saved scope catches up by replaying what changed since it was written. One without a saved
                // position (first launch of this version, another macOS build, a reset FSEvents history) is walked.
                // It is walked too when its rules changed while Cling was closed, or when it is so far behind that
                // replaying would cost more than walking.
                let state = ScopeIndexState.read()
                let now = FSEventsGetCurrentEventId()
                // What the background agent gathered while Cling was closed stands in for that part of the history: a
                // scope it covers only replays what came after.
                let journal = ChangeJournal.read().flatMap { $0.usable ? $0 : nil }
                launchJournal = journal
                for (scope, id) in state?.replayable ?? [:] where scopeEngines[scope] != nil && liveBase[scope] == nil {
                    let fingerprint = rulesFingerprint(scope)
                    let reached = journal.map { $0.header.start <= id ? max(id, $0.header.end) : id } ?? id
                    guard state?.rules[scope.rawValue] == fingerprint, now - reached <= Self.maxReplayGap else { continue }
                    liveBase[scope] = id
                    liveRules[scope] = fingerprint
                }
                // A scope that became searchable after loading started (Pro confirmed a moment later) loads from its file
                // rather than being walked.
                let unloaded = searchableScopes.filter { scopeEngines[$0] == nil && scopeIndexFile($0).exists }
                let missing = searchableScopes.filter { liveBase[$0] == nil && !unloaded.contains($0) }
                if missing.isEmpty || batteryLevel() <= 0.3 {
                    watchFiles()
                    indexStaleExternalVolumes()
                } else {
                    indexFiles(pauseSearch: false, scopes: missing) { [self] in
                        watchFiles()
                        indexStaleExternalVolumes()
                    }
                }
                if !unloaded.isEmpty {
                    syncScopeEngines()
                }
            }
        }

        // The indexes follow file changes as they happen, so nothing is walked on a timer; this only writes them
        // to disk now and then, and walks what has no position to replay from.
        indexChecker = Repeater(every: 60 * 60, name: "Index Checker", tolerance: 60 * 60) { [self] in
            saveLiveIndexIfWorthIt()
            chooseUnwatched()
            guard batteryLevel() > 0.3 else { return }
            let missing = searchableScopes.filter { liveBase[$0] == nil }
            if !missing.isEmpty {
                refresh(pauseSearch: false, scopes: missing)
            } else {
                indexStaleExternalVolumes()
            }
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
        // A scope search doesn't use stays on disk: it is loaded if it is turned on, or when Pro starts.
        let wanted = Set(searchableScopes)

        Task.detached(priority: .userInitiated) {
            // Load priority scopes first (home, applications) so search works during cold start
            let priorityScopes: [SearchScope] = [.home, .applications, .library].filter { wanted.contains($0) }
            let remainingScopes: [SearchScope] = SearchScope.allCases.filter { !priorityScopes.contains($0) && wanted.contains($0) }

            // A file the loader rejects is truncated or corrupt, so it will never load. Delete it and
            // re-walk that scope, otherwise the scope stays silently empty until the next staleness check.
            nonisolated(unsafe) var corruptScopes: [SearchScope] = []

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
                        releaseInBackground(self.scopeEngines.updateValue(eng, forKey: scope))
                        self.updateIndexedCount()
                        self.logActivity("Loaded \(scope.label): \(eng.count.formatted()) entries", operationKey: opKey)
                    }
                } else {
                    log.error("Discarding unreadable index for \(scope.label), rebuilding it")
                    try? FileManager.default.removeItem(at: file.url)
                    corruptScopes.append(scope)
                }
            }

            // Phase 2: Load remaining scopes in background. Pro may only have been confirmed after the list above was
            // made, so its scopes are checked for again once the others are in.
            var phase2 = remainingScopes
            var checkedForLate = false
            while !phase2.isEmpty || !checkedForLate {
                if phase2.isEmpty {
                    checkedForLate = true
                    phase2 = await MainActor.run {
                        self.searchableScopes.filter { self.scopeEngines[$0] == nil && !corruptScopes.contains($0) && scopeIndexFile($0).exists }
                    }
                    continue
                }
                let scope = phase2.removeFirst()
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
                        releaseInBackground(self.scopeEngines.updateValue(eng, forKey: scope))
                        self.updateIndexedCount()
                        self.logActivity("Loaded \(scope.label): \(eng.count.formatted()) entries", operationKey: opKey)
                    }
                } else {
                    log.error("Discarding unreadable index for \(scope.label), rebuilding it")
                    try? FileManager.default.removeItem(at: file.url)
                    corruptScopes.append(scope)
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
                if Defaults[.disabledVolumes].contains(volume) || Defaults[.disabledVolumes].contains(volumeDashed) {
                    return nil
                }
                // Prefer the path that exists, fall back to the spaced version
                if volumeDashed.exists {
                    return volumeDashed
                }
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
                    if Defaults[.indexedVolumePaths].contains(volume) {
                        missingIndexVolumes.append(volume)
                    }
                    continue
                }
                let eng = SearchEngine()
                if eng.loadBinaryIndex(from: file.url) {
                    let metaCacheFile = smbMetadataCacheFile(volume)
                    var metaCache: SMBMetadataCache?
                    if metaCacheFile.exists {
                        let cache = SMBMetadataCache()
                        cache.load(from: metaCacheFile)
                        if cache.count > 0 {
                            metaCache = cache
                        }
                    }
                    await MainActor.run {
                        releaseInBackground(self.volumeEngines.updateValue(eng, forKey: volume))
                        if let metaCache {
                            releaseInBackground(self.smbMetadataCaches.updateValue(metaCache, forKey: volume))
                        }
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
                if !corruptScopes.isEmpty {
                    self.indexFiles(pauseSearch: false, scopes: corruptScopes)
                }
                if self.scopeSyncPending {
                    self.scopeSyncPending = false
                    self.syncScopeEngines()
                }
            }
        }
    }

    /// Brings the loaded engines in line with the scopes search uses, after a scope is turned on or off, or Pro starts
    /// or ends.
    ///
    /// A scope that stops being searchable has its engine, file and saved position dropped: replaying days of changes
    /// when it comes back would cost more than walking it, and a position left behind would keep the background
    /// agent's journal from ever being discarded. One that becomes searchable is loaded and caught up the same way as
    /// at launch (a file left from before this version or from a launch without Pro), and walked when it has no file,
    /// no position to replay from, or rules that changed meanwhile.
    func syncScopeEngines() {
        guard !loadingIndex else {
            scopeSyncPending = true
            return
        }
        let searchable = searchableScopes
        let dropped = scopeEngines.keys.filter { !searchable.contains($0) }
        let added = searchable.filter { scopeEngines[$0] == nil && !scopesIndexing.contains($0) }

        if !dropped.isEmpty {
            for scope in dropped {
                releaseInBackground(scopeEngines.removeValue(forKey: scope))
                liveBase[scope] = nil
                liveRules[scope] = nil
                try? FileManager.default.removeItem(at: scopeIndexFile(scope).url)
            }
            ScopeIndexState.forget(dropped)
            log.info("Scopes no longer searched, unloaded: \(dropped.map(\.rawValue))")
            updateIndexedCount()
            refreshLiveRoutes()
            invalidateSearch()
            performSearch()
        }
        guard !added.isEmpty else { return }

        loadingIndex = true
        Task.detached(priority: .userInitiated) {
            var loaded: [(SearchScope, SearchEngine)] = []
            for scope in added {
                let file = scopeIndexFile(scope)
                guard file.exists else { continue }
                let eng = SearchEngine()
                if eng.loadBinaryIndex(from: file.url) {
                    loaded.append((scope, eng))
                }
            }
            await MainActor.run { [loaded] in
                self.loadingIndex = false
                // The engines still being followed move up to where the updater got, before the stream restarts from
                // the oldest position, which the new ones may now hold.
                self.stopWatchingFiles()
                let state = ScopeIndexState.read()
                let now = FSEventsGetCurrentEventId()
                for (scope, eng) in loaded where self.searchableScopes.contains(scope) {
                    releaseInBackground(self.scopeEngines.updateValue(eng, forKey: scope))
                    let fingerprint = self.rulesFingerprint(scope)
                    if let id = state?.replayable[scope], state?.rules[scope.rawValue] == fingerprint, now - id <= Self.maxReplayGap {
                        self.liveBase[scope] = id
                        self.liveRules[scope] = fingerprint
                    }
                }
                let walk = added.filter { self.searchableScopes.contains($0) && self.liveBase[$0] == nil }
                log.info("Scopes now searched: loaded \(loaded.map(\.0.rawValue)), walking \(walk.map(\.rawValue))")
                self.updateIndexedCount()
                self.invalidateSearch()
                self.performSearch()
                if walk.isEmpty {
                    self.watchFiles()
                } else {
                    self.indexFiles(pauseSearch: false, scopes: walk) { [self] in
                        watchFiles()
                    }
                }
                if self.scopeSyncPending {
                    self.scopeSyncPending = false
                    self.syncScopeEngines()
                }
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
            if scopes == nil {
                indexStaleExternalVolumes()
            }
        }
    }

    func indexFiles(wait: Bool = false, changedWithin: Date? = nil, pauseSearch: Bool = true, scopes scopeOverride: [SearchScope]? = nil, onFinish: (@MainActor () -> Void)? = nil) {
        _ = invalidReq3(PRODUCTS, nil)
        backgroundIndexing = true
        if pauseSearch {
            indexing = true
        }

        let searchable = searchableScopes
        let scopes = (scopeOverride ?? searchable).filter { searchable.contains($0) }
        guard !scopes.isEmpty else {
            log.debug("No scopes to index")
            onFinish?()
            indexing = false
            return
        }

        scopesIndexing.formUnion(scopes)
        let ignoreChecker: String? = fsignore.exists ? fsignoreString : nil
        let volumePaths = Set(enabledVolumes.map(\.string))
        // Whatever changes from here on is replayed onto the walked engines once the watcher restarts.
        let walkStartID = FSEventsGetCurrentEventId()
        let fingerprints = Dictionary(uniqueKeysWithValues: scopes.map { ($0, rulesFingerprint($0)) })

        scopeIndexTask?.cancel()
        scopeIndexTask = Task.detached(priority: .userInitiated) {
            // Invalidate the gitignore cache off-main: it takes a lock the in-flight
            // background walk may still hold, so calling it on the main thread (the hourly
            // index-checker Repeater fires there) could freeze the app for the walk's
            // duration (CLING-32). Runs before the group so the walk re-reads fresh.
            bust_gitignore_cache()
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
                                if excludeSkip?(path) ?? false {
                                    return true
                                }
                                if volumePaths.contains(path) {
                                    return true
                                }
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

                    // Reloading from the file we just wrote drops the walk's scratch memory, but if that
                    // file is unreadable keep the engine we already have in hand rather than installing
                    // an empty one and showing the scope as having no files.
                    let reloadedEngine = SearchEngine()
                    let engineToStore = reloadedEngine.loadBinaryIndex(from: file.url) ? reloadedEngine : scopeEngine
                    ScopeIndexState.save([scope: walkStartID], rules: fingerprints)

                    await MainActor.run {
                        self.liveBase[scope] = walkStartID
                        self.liveRules[scope] = fingerprints[scope]
                        releaseInBackground(self.scopeEngines.updateValue(engineToStore, forKey: scope))
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
            }
            await self.cleanRecentsEngine()
            await MainActor.run {
                self.excludedPaths.removeAll()
                onFinish?()
                self.indexing = false
                self.backgroundIndexing = !self.volumesIndexing.isEmpty
                self.invalidateSearch()
                // Engines were replaced by the reindex; rebuild stale QuickFilter pools first.
                if !self.refreshPoolsAfterReindex(), !self.emptyQuery || self.volumeFilter != nil {
                    self.performSearch()
                }
            }
        }
    }

    /// `.exists`/`isIgnored`/`isPathBlocked` all stat() the filesystem, so every check runs OFF the
    /// main actor: with many recents entries, or a slow/unresponsive volume holding an `.fsignore`,
    /// it was hanging the UI for 30s (App Hang: CLING-7, CLING-1A). Only the snapshot of main-actor
    /// state and the final mutations touch the main actor.
    nonisolated func cleanRecentsEngine() async {
        let homePrefix = HOME.string + "/"
        // Snapshot main-actor state; the filesystem checks below all run off the main actor.
        let (entries, fsignoreFile, fsignoreStr, volumes, liveChanges) = await MainActor.run {
            (recentsEngine.allPaths(), fsignore, fsignoreString, enabledVolumes, liveIndexChanges.map(\.path))
        }

        let ignoreFile: String? = fsignoreFile.exists ? fsignoreStr : nil
        let volumeFsignores: [(prefix: String, fsignore: String)] = volumes.compactMap { volume -> (prefix: String, fsignore: String)? in
            let vfsignore = volume / ".fsignore"
            guard vfsignore.exists else { return nil }
            return (volume.string + "/", vfsignore.string)
        }

        log.debug("cleanRecentsEngine: \(entries.count) entries, ignoreFile=\(ignoreFile ?? "nil")")

        /// Filesystem-touching predicate; evaluated off the main actor.
        func shouldRemove(_ path: String) -> Bool {
            if path.isEmpty {
                return false
            }
            if isPathBlocked(path) {
                return true
            }
            if let ignoreFile, path.hasPrefix(homePrefix), path.isIgnored(in: ignoreFile) {
                return true
            }
            return volumeFsignores.contains { path.hasPrefix($0.prefix) && path.isIgnored(in: $0.fsignore) }
        }

        let toRemove = entries.filter(shouldRemove)
        let liveToRemove = Set(liveChanges.filter(shouldRemove))

        await MainActor.run {
            for path in toRemove {
                recentsEngine.removePath(path)
            }
            self.liveIndexChanges.removeAll { liveToRemove.contains($0.path) }
            if !toRemove.isEmpty {
                self.logActivity("Cleaned \(toRemove.count) ignored path\(toRemove.count == 1 ? "" : "s") from recents")
                self.updateIndexedCount()
                if self.noQuery {
                    self.updateDefaultResults(debounce: true)
                }
            }
        }
        log.debug("cleanRecentsEngine: removed \(toRemove.count) paths")
    }

    // MARK: - File Watching (FSEvents)

    func stopWatchingFiles() {
        advanceLiveBase()
        liveStream?.stop()
        liveStream = nil
        liveUpdater = nil
    }

    /// The engines hold every change the updater has applied, so their positions move up to it. A scope with no
    /// position stays without one: it was never caught up from a known point.
    func advanceLiveBase() {
        guard let applied = liveUpdater?.lastAppliedEventID, applied > 0 else { return }
        for (scope, id) in liveBase where id < applied {
            liveBase[scope] = applied
        }
    }

    /// Everything a scope's walk is decided by: its folders, its ignore file, the blocklist and the `.gitignore` setting.
    /// A stable FNV-1a hash, so it can be compared across launches.
    func rulesFingerprint(_ scope: SearchScope) -> String {
        let scopeIgnoreFile = ScopeIgnore.rootedScopes.contains(scope) ? ScopeIgnore.activeFile(for: scope) : nil
        let homeIgnore: String? = fsignore.exists ? fsignoreString : nil
        var parts = [scope.rawValue]
        for dir in walkDirs(for: scope) {
            parts.append("\(dir.dir)|\(dir.excludePrefix ?? "")")
            if let file = scopeIgnoreFile ?? (dir.applyIgnore ? homeIgnore : nil) {
                parts.append((try? String(contentsOfFile: file, encoding: .utf8)) ?? "")
            }
        }
        parts.append(Defaults[.blockedPrefixes])
        parts.append(Defaults[.blockedContains])
        parts.append(scope == .home && Defaults[.honorGitignore] ? "gitignore" : "")

        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in parts.joined(separator: "\u{0}").utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }

    /// The folders each enabled scope walks, with the same rules `indexFiles` walks them by.
    func liveRoutes() -> [LiveRoute] {
        let ignoreChecker: String? = fsignore.exists ? fsignoreString : nil
        let volumePaths = Set(enabledVolumes.map(\.string))
        var routes: [LiveRoute] = []
        for scope in searchableScopes {
            guard let engine = scopeEngines[scope] else { continue }
            let scopeIgnoreFile = ScopeIgnore.rootedScopes.contains(scope) ? ScopeIgnore.activeFile(for: scope) : nil
            let honorGitignore = scope == .home && Defaults[.honorGitignore]
            for dir in walkDirs(for: scope) {
                let excl = dir.excludePrefix
                let rules = WalkRules(
                    walkRoot: dir.dir,
                    ignoreFile: scopeIgnoreFile ?? (dir.applyIgnore ? ignoreChecker : nil),
                    ignoreRoot: scopeIgnoreFile != nil ? dir.dir : nil,
                    skipDir: { path in (excl.map { path.hasPrefix($0) } ?? false) || volumePaths.contains(path) },
                    applyBlocklist: true,
                    discoverGitignore: honorGitignore
                )
                routes.append(LiveRoute(scope: scope, root: dir.dir, excludePrefix: excl, engine: engine, rules: rules))
            }
        }
        return routes
    }

    /// Rules changed without a walk (an exclusion or a re-add): the live updates follow the new ones.
    func refreshLiveRoutes() {
        liveUpdater?.setRoutes(liveRoutes())
        chooseUnwatched(counted: false)
    }

    /// Leaves the busiest folders the walks skip out of the stream, chosen from what was counted since the last time
    /// (the launch replay, then every hour). A folder the rules no longer skip is followed again straight away and
    /// brought up to date, as its changes went unseen meanwhile.
    func chooseUnwatched(counted: Bool = true) {
        guard let updater = liveUpdater, let liveStream else { return }
        let valid = unwatched.folders.filter { updater.isUnwatchable($0.path) }
        let dropped = unwatched.paths.filter { path in !valid.contains { $0.path == path } }
        var next = UnwatchedFolders(folders: valid)
        if counted {
            let hours = max(Date().timeIntervalSince(skippedCountedSince) / 3600, 1)
            skippedCountedSince = Date()
            next = next.choosing(from: updater.takeSkipped(), hours: hours)
        }
        guard Set(next.paths) != Set(unwatched.paths) else { return }

        unwatched = next
        unwatched.save()
        liveStream.restart(excluding: next.paths)
        updater.rescan(dropped)
        log.info("Live index: leaving out changes in \(next.paths.joined(separator: ", "))")
    }

    func watchFiles() {
        removedFiles.removeAll()
        seenPaths.removeAll()
        stopWatchingFiles()

        // Replay from the oldest position among the engines; changes they already hold apply again harmlessly.
        var since = searchableScopes.compactMap { scopeEngines[$0] != nil ? liveBase[$0] : nil }.min()
        // The background agent's changes from while Cling was closed, when every engine is at or past where they start:
        // they are applied first, and the replay starts where the agent stopped.
        let journal = launchJournal.flatMap { journal in since.map { journal.header.start <= $0 } == true ? journal : nil }
        launchJournal = nil
        if let journal, let oldest = since {
            since = max(oldest, journal.header.end)
        }
        // Changes buffered before the restart describe the index we just cleared, so flushing
        // them would re-add paths into a fresh seenPaths/removedFiles.
        fsEventsQueue.async { [self] in
            pendingFSChanges.removeAll()
            hiddenChanges.removeAll()
            pendingCountDelta = 0
            replayingHistory = since != nil
        }

        let updater = LiveIndexUpdater(
            routes: liveRoutes(),
            replaying: since != nil,
            applied: { [weak self] batch in
                guard let self else { return }
                fsEventsQueue.async { self.followIndexChanges(batch) }
            },
            caughtUp: { [weak self] in
                Task { @MainActor in self?.chooseUnwatched() }
            },
            historyLost: { [weak self] in
                Task { @MainActor in self?.liveHistoryLost() }
            }
        )
        liveUpdater = updater
        if let journal {
            log.info("Live index: applying \(journal.changes.count) paths changed while Cling was closed")
            updater.enqueue(journal.changes.map { FSChange(path: $0.key, flags: EonilFSEventsEventFlags(rawValue: $0.value), id: journal.header.end) })
        }

        // Folders left out last time stay out, from the replay on, while the rules still skip them. The replay counts
        // the others since the indexes were saved, and the busiest are left out once it is done.
        let saved = UnwatchedFolders.read()
        unwatched = UnwatchedFolders(folders: saved.folders.filter { updater.isUnwatchable($0.path) })
        if unwatched.paths != saved.paths {
            unwatched.save()
            updater.rescan(saved.paths.filter { !unwatched.paths.contains($0) })
        }
        let savedAt = (try? FileManager.default.attributesOfItem(atPath: ScopeIndexState.file.string))?[.modificationDate] as? Date
        skippedCountedSince = since != nil ? savedAt ?? Date() : Date()

        liveStream = FSChangeStream(paths: ["/"], since: since, latency: 1, excluding: unwatched.paths, queue: fsEventsQueue) { [self] events in
            updater.enqueue(events)
            followChanges(events, updater: updater)
        }
        if liveStream == nil {
            log.error("Failed to watch files")
        }
    }

    /// Shows what the scope indexes took from a batch of file changes: in the live changes list, by taking deleted
    /// files out of the results, and in the count. With no Cling window on screen it is only noted and shown once one
    /// is: a hidden SwiftUI window still lays itself out again after every batch. Runs on `fsEventsQueue`.
    func followIndexChanges(_ batch: LiveIndexBatch) {
        pendingCountDelta += batch.countDelta
        guard windowOnScreen.value else {
            if batch.changed > 0 {
                indexChangedOffScreen.value = true
            }
            for (path, kind) in batch.paths {
                hiddenChangeOrder += 1
                hiddenChanges[path] = (hiddenChangeOrder, IndexChange.Kind(kind))
            }
            if hiddenChanges.count >= Self.hiddenChangesMax {
                showHiddenChanges()
            }
            return
        }
        for (path, kind) in batch.paths {
            guard let filePath = path.filePath else { continue }
            pendingFSChanges.append(PendingFSChange(path: filePath, exists: kind != .removed, kind: IndexChange.Kind(kind)))
        }
        scheduleFSFlush()
        if batch.changed > 0 {
            mainActor { self.liveIndexApplied(batch.changed) }
        }
    }

    /// Follows file changes outside the scope indexes, which keep the recents index. The scope indexes report their
    /// own (`followIndexChanges`). Runs on `fsEventsQueue`.
    func followChanges(_ events: [FSChange], updater: LiveIndexUpdater) {
        for event in events {
            if event.flags.contains(.historyDone) {
                replayingHistory = false
                continue
            }
            guard !replayingHistory,
                  event.flags.hasElements(from: [.itemCreated, .itemRemoved, .itemRenamed, .itemModified]),
                  let pathStr = FSEventsHistory.normalized(event.path),
                  Self.recentsRoots.contains(where: { pathStr.hasPrefix($0) }),
                  updater.route(for: pathStr) == nil
            else { continue }
            showRecentsChange(pathStr)
        }
    }

    /// Runs on `fsEventsQueue`.
    func showRecentsChange(_ pathStr: String) {
        guard !isPathBlocked(pathStr), let path = pathStr.filePath else { return }
        if path.exists {
            let isDir = path.isDir
            if path.starts(with: HOME), pathStr.isIgnored(in: fsignoreString, isDir: isDir) {
                return
            }
            for volume in enabledVolumes where pathStr.hasPrefix(volume.string + "/") {
                let vfsignore = volume / ".fsignore"
                if vfsignore.exists, pathStr.isIgnored(in: vfsignore.string, isDir: isDir) {
                    return
                }
                break
            }
            // Add to recents engine (never blocks main thread)
            recentsEngine.addPath(pathStr, isDir: isDir)
            enqueueFSChange(path, exists: true)
        } else {
            recentsEngine.removePath(pathStr)
            enqueueFSChange(path, exists: false)
        }
    }

    /// A window came on screen, or too many changes piled up: shows the noted changes in the order they last happened,
    /// and moves the count by what the indexes gained meanwhile. Runs on `fsEventsQueue`.
    func showHiddenChanges() {
        let changes = hiddenChanges.sorted { $0.value.order < $1.value.order }
        hiddenChanges = [:]
        for (path, change) in changes {
            guard let filePath = path.filePath else { continue }
            pendingFSChanges.append(PendingFSChange(path: filePath, exists: change.kind != .removed, kind: change.kind))
        }
        scheduleFSFlush()
    }

    /// Follows whether the main or Settings window is on screen, from the windows' own occlusion changes, which
    /// arrive however a window was shown, hidden, closed or covered.
    func watchWindowVisibility() {
        guard windowObservers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
            // A closing window is still on screen when the notification arrives, so look after it has gone.
            windowObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updateWindowOnScreen() }
            })
        }
        updateWindowOnScreen()
    }

    func updateWindowOnScreen() {
        let onScreen = NSApp.windows.contains { window in
            ["main", "settings", "searchbar"].contains(window.identifier?.rawValue ?? "") && window.isVisible && window.alphaValue > 0
                && window.occlusionState.contains(.visible)
        }
        guard onScreen != windowOnScreen.value else { return }
        windowOnScreen.value = onScreen
        log.debug("Cling window on screen: \(onScreen)")
        guard onScreen else { return }

        liveStream?.flush()
        fsEventsQueue.async { [self] in showHiddenChanges() }
        if indexChangedOffScreen.take() {
            liveIndexApplied(0)
        }
    }

    /// A batch of file changes reached the scope indexes. The count on screen moves by what the batch added and removed
    /// along with the live changes list, so it isn't recounted here: that would redraw the status bar once more.
    func liveIndexApplied(_ changes: Int) {
        invalidateSearch()
        // QuickFilter pools hold entry positions, and removals free those up for reuse by new paths.
        if let qf = quickFilter, qf.poolExtensions != nil || qf.searchDirsOnly {
            let refresh = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { _ = self?.refreshPoolsAfterReindex() }
            }
            livePoolRefresh = refresh
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: refresh)
        }
    }

    /// Writing every scope costs a few hundred MB of disk writes, while replaying changes on launch is cheap, so the
    /// indexes are only written once enough has changed or the replay would reach back several hours.
    func saveLiveIndexIfWorthIt() {
        guard let changes = liveUpdater?.changes, changes > 0,
              changes >= 20000 || Date().timeIntervalSince(lastLiveSave) > 6 * 60 * 60
        else { return }
        scheduleSaveIndexes()
    }

    /// FSEvents dropped changes or lost its history, so the indexes may have missed some: walk them again, at most
    /// once an hour in case it keeps happening.
    func liveHistoryLost() {
        // A scope without a position is walked by the next index check, so a loss inside the hour still gets its walk,
        // and the updater keeps following changes until then.
        liveBase.removeAll()
        if let last = lastHistoryLossWalk, Date().timeIntervalSince(last) < 60 * 60 {
            log.info("Live index: change history lost again, walking at the next index check")
            return
        }
        lastHistoryLossWalk = Date()
        log.info("Live index: change history lost, reindexing")
        refresh(pauseSearch: false)
    }

    /// Buffer a surviving FSEvents change and make sure a flush is pending.
    ///
    /// A build, a checkout or a package install fires thousands of events a second. Hopping to the
    /// main actor per event meant one SwiftUI transaction per event, and the status bar reads both
    /// `indexedCount` and `liveIndexChanges`, so every hop re-ran `StatusBarView.body` and a full
    /// layout pass — 48% of main-thread time in a 2.7.2 sample, but only with the window open.
    /// A window's worth of events applied in one hop lands in a single transaction, so the view
    /// updates once per window instead of once per event.
    ///
    /// Runs on `fsEventsQueue`.
    nonisolated func enqueueFSChange(_ path: FilePath, exists: Bool) {
        pendingFSChanges.append(PendingFSChange(path: path, exists: exists))
        scheduleFSFlush()
    }

    /// Runs on `fsEventsQueue`.
    nonisolated func scheduleFSFlush() {
        guard !fsFlushScheduled else { return }

        fsFlushScheduled = true
        fsEventsQueue.asyncAfter(deadline: .now() + Self.fsFlushInterval) { [self] in
            fsFlushScheduled = false
            guard !pendingFSChanges.isEmpty || pendingCountDelta != 0 else { return }

            let batch = pendingFSChanges
            let countDelta = pendingCountDelta
            pendingFSChanges.removeAll(keepingCapacity: true)
            pendingCountDelta = 0
            mainActor { self.applyFSChanges(batch, countDelta: countDelta) }
        }
    }

    /// Apply a batch of FSEvents changes in one main-actor transaction, in arrival order so a
    /// remove-then-create on the same path still ends up created.
    func applyFSChanges(_ batch: [PendingFSChange], countDelta: Int = 0) {
        var resultsChanged = false
        indexedCount = max(0, indexedCount &+ countDelta)

        for change in batch {
            let pathStr = change.path.string
            guard change.exists else {
                removedFiles.insert(pathStr)
                if change.kind == nil {
                    indexedCount = max(0, indexedCount &- 1)
                }
                appendLiveChange(IndexChange(path: pathStr, kind: .removed))
                if let index = scoredResults.firstIndex(of: change.path) {
                    scoredResults.remove(at: index)
                    resultsChanged = true
                }
                continue
            }
            // A recreate (atomic save via temp+rename, cloud sync, editor
            // delete-then-write) fires a remove event before this create.
            // removedFiles is only cleared wholesale at watcher startup, so
            // without this the reborn path stays hidden from the UI (which
            // filters results by removedFiles) even though it's back on disk
            // and in the index — the CLI, which applies no such filter, still
            // shows it. Un-remove it so the UI and index agree again.
            removedFiles.remove(pathStr)
            if let kind = change.kind {
                appendLiveChange(IndexChange(path: pathStr, kind: kind))
                continue
            }
            let isNew = !seenPaths.contains(pathStr)
            seenPaths.insert(pathStr)
            if isNew {
                indexedCount &+= 1
            }
            appendLiveChange(IndexChange(path: pathStr, kind: isNew ? .added : .modified))
        }

        if resultsChanged {
            results = sortedResults()
        }
        if noQuery {
            updateDefaultResults(debounce: true)
        }
    }

    /// Everything was switched on or off, or its engine changed: search again against what is now active.
    func everythingChanged() {
        invalidateSearch()
        if !refreshPoolsAfterReindex(), !emptyQuery || volumeFilter != nil {
            performSearch()
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
        guard WM.searchUIActive else {
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
        var query = constructQuery(query)
        if let qf = quickFilter {
            // The filter wraps the user's typed query: prefix (constraints + Prepend) before it,
            // suffix (Append) after it. Order matters for the fuzzy word ranking.
            query = [qf.queryPrefix, query, qf.querySuffix].filter { !$0.isEmpty }.joined(separator: " ")
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
        // Extension-only queries (".m4a") are a pure filter with no relevance term, so the
        // interactive 500 cap can truncate a large library before the wanted file surfaces.
        let extensionOnly = Self.isExtensionOnlyQuery(query)
        let maxResults = (proactive || extensionOnly) ? Defaults[.maxResultsCount] : min(Defaults[.maxResultsCount], 500)
        let folderPrefixes = folderFilter?.folders.map(\.string)
        let volumePrefix = volumeFilter?.string
        // Everything follows deletions itself and honours no exclusions, and looking the paths up would make
        // its engine build a path index millions of entries long.
        let removedPaths = EVERYTHING.active ? [] : removedFiles.union(excludedPaths)
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
                if eng.label == "Recents" {
                    return volumeMounted
                }
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
                if eng.label == "Recents" {
                    return true
                }
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
        let literalDefault = Defaults[.literalSearch]

        searching = true
        searchTask = Task.detached(priority: .userInitiated) {
            guard !engines.isEmpty else {
                await MainActor.run { self.searching = false }
                return
            }

            nonisolated(unsafe) var cancelFlag = false
            // Set on the main actor once the merged results are shown, so a late partial list can't cover them.
            nonisolated(unsafe) var finalShown = false
            var accumulated = [SearchResult]()
            let finished = OSAllocatedUnfairLock(initialState: [SearchResult]())

            // Every engine at once, and the results go up once, merged. Searching one engine first and showing its
            // results early flashed that engine's list before the merged one replaced it, and held the others back
            // by its own time. A search still running after 150 ms shows what the finished engines found. The
            // stale-path filter stat()s each result, so it runs off the main actor (see existingResultPaths).
            let partialTask = Task.detached(priority: .userInitiated) {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, !cancelFlag else { return }
                let sofar = finished.withLock { $0 }
                guard !sofar.isEmpty else { return }
                let partialPaths = await self.existingResultPaths(from: Self.mergeResults(sofar, maxResults: maxResults))
                guard !Task.isCancelled, !cancelFlag else { return }
                await MainActor.run {
                    guard !finalShown, !cancelFlag else { return }
                    self.scoredResults = partialPaths
                    self.results = self.sortedResults()
                }
            }

            await withTaskCancellationHandler {
                await withTaskGroup(of: [SearchResult].self) { group in
                    for eng in engines {
                        let pool = pools[eng.label]
                        group.addTask {
                            guard !cancelFlag else { return [] }
                            var results = eng.engine.search(
                                query: query, maxResults: maxResults, folderPrefixes: allPrefixes,
                                excludedPaths: removedPaths.isEmpty ? nil : removedPaths,
                                maxDepth: activeMaxDepth,
                                candidatePool: pool, literalDefault: literalDefault,
                                cancelled: { cancelFlag }
                            )
                            for i in results.indices {
                                results[i].sourceLabel = eng.label
                            }
                            return results
                        }
                    }
                    for await results in group {
                        guard !cancelFlag else { break }
                        accumulated.append(contentsOf: results)
                        finished.withLock { $0.append(contentsOf: results) }
                    }
                }
            } onCancel: {
                cancelFlag = true
            }
            partialTask.cancel()

            guard !cancelFlag else {
                await MainActor.run { self.searching = false }
                return
            }

            let searchResults = Self.mergeResults(accumulated, maxResults: maxResults)
            let finalPaths = await self.existingResultPaths(from: searchResults)

            await MainActor.run {
                finalShown = true
                self.scoredResults = finalPaths
                self.results = self.sortedResults()
                self.searching = false
                if !self.emptyQuery || wantVolumeFilter {
                    self.noQuery = false
                }
            }
        }
    }

    /// Build the display `FilePath`s for a batch of results and drop stale (deleted) local paths.
    /// `exists` calls `fileExists` (a blocking `stat()`), so the check runs OFF the main actor: a
    /// single unresponsive volume was freezing the UI for 30s (App Hang: CLING-13/-14/-10/-1A).
    /// Paths on external volumes are kept without stat'ing, and that classification needs main-actor
    /// state (`FUZZY.externalVolumes`), so only it runs on the main actor. memoz/cache are
    /// NSCache-backed and thread-safe, so building the paths across the hop is safe.
    ///
    /// Paths on a disconnected volume are kept too: the volume's index stays loaded while it is
    /// unmounted, and stat'ing them would fail for every single one, so searching an unplugged
    /// drive or an off-network share returned zero results despite a full cached index.
    nonisolated func existingResultPaths(from results: [SearchResult]) async -> [FilePath] {
        let built: [(fp: FilePath, checkExists: Bool)] = await MainActor.run {
            results.compactMap { r -> (fp: FilePath, checkExists: Bool)? in
                guard let fp = r.path.filePath else { return nil }
                fp.cache(r.isDir, forKey: \.isDir)
                fp.cache(r.sourceLabel, forKey: \.sourceIndex)
                // The index already knows this, so the row's icon never has to stat for it.
                FilePathBackgroundTasks.shared.noteIsDir(r.isDir, for: fp)
                return (fp, !fp.memoz.isOnExternalVolume && fp.disconnectedVolume == nil)
            }
        }
        return built.compactMap { $0.checkExists ? ($0.fp.exists ? $0.fp : nil) : $0.fp }
    }

    /// The same results drawn again, with the icons, sizes and dates that arrived for them since.
    func reloadResults() {
        scoredResults = scoredResults
        let sorted = sortedResults()
        if sorted == results {
            // Observation skips a write of an equal value, so nothing would draw the rows again.
            withMutation(keyPath: \.results) {}
        } else {
            results = sorted
        }
    }

    // MARK: - Rename

    func renamePaths(_ renamed: [FilePath: FilePath]) {
        guard !renamed.isEmpty else { return }
        logActivity("Renamed \(renamed.count) file\(renamed.count == 1 ? "" : "s")")
        for (oldPath, newPath) in renamed {
            let isDir = newPath.isDir
            // The extension may have changed, so the old path's cached icon no longer describes it.
            FilePathBackgroundTasks.shared.invalidateIcon(of: oldPath)
            FilePathBackgroundTasks.shared.invalidateIcon(of: newPath)
            FilePathBackgroundTasks.shared.noteIsDir(isDir, for: newPath)
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
            // Taken before writing: the engines hold at least every change applied so far.
            self.advanceLiveBase()
            let positions = self.liveBase.filter { scopes.keys.contains($0.key) }
            let rules = self.liveRules
            _ = self.liveUpdater?.takeChanges()
            self.lastLiveSave = Date()
            await Task.detached {
                // An unchanged engine already matches its file, which it may be reading straight from.
                for (scope, eng) in scopes {
                    let file = scopeIndexFile(scope)
                    guard eng.hasUnsavedChanges || !file.exists else { continue }
                    eng.saveBinaryIndex(to: file.url)
                }
                ScopeIndexState.save(positions, rules: rules)
                for (volume, eng) in volumes {
                    let file = volumeIndexFile(volume)
                    guard eng.hasUnsavedChanges || !file.exists else { continue }
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
                if path.isDir {
                    rel += "/"
                }
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
                    if path.isDir {
                        rel += "/"
                    }
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
                    if !updated.hasSuffix("\n") {
                        updated += "\n"
                    }
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

        // 3. Make the path itself searchable right away, then reindex what's affected.
        let reindex: @MainActor () -> Void = { [self] in
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
        if let path = plan.path {
            indexPathFirst(path, isDir: plan.isDir, then: reindex)
        } else {
            reindex()
        }
    }

    /// Walk just `path` into the live engine that owns it, then run `reindex`. A path brought back into the index
    /// shows up in results as soon as its own walk ends (milliseconds for a project folder) instead of after its
    /// whole scope is walked again. The reindex still follows: it replaces the engine with a clean one, and it sees
    /// what a walk started below the scope root cannot, like a `.gitignore` in a folder above the path.
    func indexPathFirst(
        _ path: String, isDir: Bool, budget: CFAbsoluteTime? = pathFirstWalkBudget,
        then reindex: @escaping @MainActor () -> Void
    ) {
        // Excluded earlier this session: results hide it by exact path until the next full walk.
        let outside = { (p: String) in p != path && !p.hasPrefix(path + "/") }
        excludedPaths = excludedPaths.filter(outside)
        removedFiles = removedFiles.filter(outside)

        guard let pathWalk = pathWalk(for: path) else {
            reindex()
            return
        }
        Task.detached(priority: .userInitiated) {
            var walk = pathWalk
            if let volume = walk.volume {
                // A network share can stall a single syscall past the budget, so leave it to the volume walk.
                guard volume.url.isLocalVolume else {
                    await MainActor.run { reindex() }
                    return
                }
                let vfsignore = volume / ".fsignore"
                if vfsignore.exists {
                    let checker = vfsignore.string
                    walk.ignoreFile = checker
                    walk.skipDir = { $0.isIgnored(in: checker) }
                }
            }
            // The ignore file may have just gained a `!` line for this path.
            bust_gitignore_cache()

            let deadline = budget.map { CFAbsoluteTimeGetCurrent() + $0 } ?? .infinity
            // walkDirectory adds what is below the path but never the path itself.
            walk.engine.addPath(path, isDir: isDir)
            let added = !isDir
                ? 0
                : walk.engine.walkDirectory(
                    path, ignoreFile: walk.ignoreFile, ignoreRoot: walk.ignoreRoot, skipDir: walk.skipDir,
                    applyBlocklist: walk.applyBlocklist, discoverGitignore: walk.discoverGitignore,
                    cancelled: { CFAbsoluteTimeGetCurrent() > deadline }
                )
            let cutOff = CFAbsoluteTimeGetCurrent() > deadline
            await MainActor.run {
                log.debug("indexPathFirst: \(path) added \(added) entries below it\(cutOff ? ", cut off at the budget" : "")")
                self.updateIndexedCount()
                self.invalidateSearch()
                if !self.refreshPoolsAfterReindex(), !self.emptyQuery || self.volumeFilter != nil {
                    self.performSearch()
                }
                reindex()
            }
        }
    }

    /// Apply a set of exclusion rules chosen in the Exclude-from-index sheet: append ignore-file lines and/or
    /// blocklist lines, drop the selected paths from the live index immediately, then reindex if the rules are
    /// broad enough to also match other indexed paths.
    func excludeFromIndex(rules: [ExcludeRule], paths: Set<FilePath>, reindex: Bool) {
        guard !rules.isEmpty else { return }
        logActivity("Excluded \(paths.count) path\(paths.count == 1 ? "" : "s") from index")

        writeExcludeRules(rules)

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
        removeContentsFromIndex(of: paths)

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

    /// Append exclusion rules to the stores they name: the home, volume or scope ignore file, or the blocklist.
    func writeExcludeRules(_ rules: [ExcludeRule]) {
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
        if blocklistChanged {
            PathBlocklist.shared.rebuild()
        }
        refreshLiveRoutes()
    }

    /// Take back rules written by `writeExcludeRules`, line for line.
    func removeExcludeRules(_ rules: [ExcludeRule]) {
        var blocklistChanged = false
        for rule in rules {
            switch rule.mechanism {
            case .homeIgnore:
                removeIgnoreLines([rule.line], from: fsignore, suppressWatcher: true)
            case let .volumeIgnore(v):
                removeIgnoreLines([rule.line], from: v / ".fsignore", suppressWatcher: false)
            case let .scopeIgnore(scope):
                removeIgnoreLines([rule.line], from: ScopeIgnore.file(for: scope), suppressWatcher: false)
            case .blocklist:
                if rule.blocklistPrefix {
                    Defaults[.blockedPrefixes] = Self.removingLines([rule.line], from: Defaults[.blockedPrefixes])
                } else {
                    Defaults[.blockedContains] = Self.removingLines([rule.line], from: Defaults[.blockedContains])
                }
                blocklistChanged = true
            }
        }
        if blocklistChanged {
            PathBlocklist.shared.rebuild()
        }
        refreshLiveRoutes()
    }

    /// Exclude `path` with the same exact rule the Exclude sheet recommends, and drop it with everything below it
    /// from the live index straight away (no reindex). Returns the rule so `restorePruned` can take it back.
    func pruneFromIndex(_ path: String) -> ExcludeRule {
        let info = ExcludePathInfo(path: FilePath(path), home: HOME.string, volumes: enabledVolumes)
        let rule = ExcludeAnalyzer.exactRule(info)
        writeExcludeRules([rule])
        logActivity("Pruned \(path.shellString) from index")

        let under = { (p: FilePath) in p.string == path || p.string.hasPrefix(path + "/") }
        results.removeAll(where: under)
        scoredResults.removeAll(where: under)
        recents.removeAll(where: under)
        sortedRecents.removeAll(where: under)

        let engines = Array(scopeEngines.values) + Array(volumeEngines.values) + [recentsEngine]
        Task.detached(priority: .userInitiated) {
            let removed = engines.reduce(0) { $0 + $1.removeSubtree(path) }
            await MainActor.run {
                log.debug("pruneFromIndex: \(path) removed \(removed) entries")
                self.updateIndexedCount()
                self.invalidateSearch()
                self.scheduleSaveIndexes()
            }
        }
        return rule
    }

    /// Undo `pruneFromIndex`: take its rule back out and walk the path into the index again, whole.
    func restorePruned(_ path: String, isDir: Bool, rule: ExcludeRule, then done: @escaping @MainActor () -> Void) {
        removeExcludeRules([rule])
        logActivity("Re-added \(path.shellString) to index")
        indexPathFirst(path, isDir: isDir, budget: nil) { [self] in
            scheduleSaveIndexes()
            done()
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

        // 2. MDQuery recents (already filtered by isRelevantDefaultPath in filterRecentPaths)
        for fp in mdQueryRecents where !seen.contains(fp.string) {
            seen.insert(fp.string)
            results.append(fp)
            if results.count >= maxResults {
                break
            }
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
        guard WM.searchUIActive else { return }
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
            // A LaunchServices query per file plus an Info.plist read per candidate app, all of it on
            // the main thread until now, so one slow app bundle froze the window (CLING-48).
            openWithGeneration &+= 1
            let generation = openWithGeneration
            asyncNow {
                let apps = commonApplications(for: urls).sorted(by: \.lastPathComponent)
                // Keep open-with app hotkeys from stealing letters already bound to
                // ⌘⌥ actions (see ActionButtons), e.g. ⌘⌥C for Copy to...
                let shortcuts = computeShortcuts(for: apps, reserved: reservedOptionCommandLetters)

                mainActor {
                    // The debounce can no longer cancel work that already left the main thread, so a
                    // slow lookup for an old selection must not overwrite a newer one.
                    guard generation == FUZZY.openWithGeneration else { return }
                    FUZZY.commonOpenWithApps = apps
                    FUZZY.openWithAppShortcuts = shortcuts

                    // Rendering an icon thumbnail reads the app bundle, so doing it here hung the main thread the
                    // same way it did in discoverInstalledApps (CLING-5). Build the missing ones off-main.
                    let missing = apps.map(\.path).filter { FUZZY.appIconCache[$0] == nil }
                    guard !missing.isEmpty else { return }
                    asyncNow {
                        var icons: [String: NSImage] = [:]
                        for path in missing {
                            icons[path] = appIconThumbnail(forFile: path)
                        }
                        mainActor {
                            for (path, icon) in icons {
                                FUZZY.appIconCache[path] = icon
                            }
                        }
                    }
                }
            }
        }
    }

    func discoverInstalledApps() {
        appDiscoveryQuery = queryInstalledApps { apps in
            // The metadata callback runs on the main thread; building an NSWorkspace icon for every
            // installed app there hung the app for 30s+ (CLING-5). Do the grouping and icon
            // rendering off-main, then assign on the main actor.
            asyncNow {
                let filtered = apps.filter { isAppPathRelevant($0.path.string) }
                let grouped = Dictionary(grouping: filtered, by: \.bundleIdentifier)
                let unique = grouped.values.compactMap { $0.max(by: { $0.useCount < $1.useCount }) }
                let urls = unique.map(\.url).sorted(by: \.lastPathComponent)

                var icons: [String: NSImage] = [:]
                for url in urls {
                    icons[url.path] = appIconThumbnail(forFile: url.path)
                }

                mainActor {
                    FUZZY.appIconCache = icons
                    FUZZY.installedApps = urls
                    // An app was installed or removed, so the memoised Open With lists and the cached
                    // helper-app existence can both be stale.
                    invalidateCommonApplicationsCache()
                    HelperApp.refresh([Defaults[.terminalApp], Defaults[.editorApp], Defaults[.shelfApp]])
                }
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

    /// Approximate count of results a query would return across all active engines.
    /// Runs on a detached utility task so it never blocks the main thread.
    func matchCount(query: String, dirsOnly: Bool, folders: [FilePath], maxDepth: Int?, cap: Int = 5000) async -> Int {
        let engines = activeEngines
        let prefixes = folders.isEmpty ? nil : folders.map(\.string)
        let literalDefault = Defaults[.literalSearch]
        return await Task.detached(priority: .utility) {
            var total = 0
            for (eng, _, _) in engines {
                total += eng.search(
                    query: query,
                    maxResults: max(0, cap - total),
                    folderPrefixes: prefixes,
                    dirsOnly: dirsOnly,
                    maxDepth: maxDepth,
                    literalDefault: literalDefault
                ).count
                if total >= cap {
                    break
                }
            }
            return min(total, cap)
        }.value
    }

    func walkDirs(for scope: SearchScope) -> [(dir: String, excludePrefix: String?, applyIgnore: Bool)] {
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

    /// The live engine a path belongs to and the rules its full walk applies there (same setup as `indexFiles`
    /// and `indexVolumeEngine`), so the single-path walk adds exactly what the full one would.
    private struct PathWalk: @unchecked Sendable {
        let engine: SearchEngine
        var volume: FilePath?
        var ignoreFile: String?
        var ignoreRoot: String?
        var skipDir: ((String) -> Bool)?
        var applyBlocklist = false
        var discoverGitignore = false
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
        if !updated.isEmpty, !updated.hasSuffix("\n") {
            updated += "\n"
        }
        updated += newLines.joined(separator: "\n")
        return updated
    }

    /// The selected paths leave the index above, but what is inside an excluded folder would stay searchable until
    /// the next reindex, which an exact rule never asks for. Drop it from every engine off the main thread (one
    /// pass per engine for any number of folders), and from the lists on screen now.
    private func removeContentsFromIndex(of paths: Set<FilePath>) {
        let excluded = Set(paths.map(\.string))
        let insideExcluded = { (p: FilePath) -> Bool in
            var dir = p.string
            while let slash = dir.lastIndex(of: "/"), slash != dir.startIndex {
                dir = String(dir[..<slash])
                if excluded.contains(dir) {
                    return true
                }
            }
            return false
        }
        results.removeAll(where: insideExcluded)
        scoredResults.removeAll(where: insideExcluded)
        recents.removeAll(where: insideExcluded)
        sortedRecents.removeAll(where: insideExcluded)

        let dirs = Array(excluded)
        let engines = Array(scopeEngines.values) + Array(volumeEngines.values) + [recentsEngine]
        Task.detached(priority: .userInitiated) {
            let removed = engines.reduce(0) { $0 + $1.removeSubtrees(dirs) }
            guard removed > 0 else { return }
            await MainActor.run {
                log.debug("excludeFromIndex: removed \(removed) entries inside \(dirs.count) excluded paths")
                self.updateIndexedCount()
                self.invalidateSearch()
                self.scheduleSaveIndexes()
            }
        }
    }

    private func pathWalk(for path: String) -> PathWalk? {
        func contains(_ root: String) -> Bool {
            path == root || path.hasPrefix(root + "/")
        }

        if let volume = enabledVolumes.first(where: { contains($0.string) }) {
            // The volume's own .fsignore is read off-main in indexPathFirst: stat on a stalled volume can block.
            return volumeEngines[volume].map { PathWalk(engine: $0, volume: volume) }
        }
        let volumePaths = Set(enabledVolumes.map(\.string))
        let homeIgnore: String? = fsignore.exists ? fsignoreString : nil
        for scope in searchableScopes {
            guard let engine = scopeEngines[scope],
                  let root = walkDirs(for: scope).first(where: { contains($0.dir) && !($0.excludePrefix.map(contains) ?? false) })
            else { continue }
            let scopeIgnoreFile = ScopeIgnore.rootedScopes.contains(scope) ? ScopeIgnore.activeFile(for: scope) : nil
            return PathWalk(
                engine: engine,
                ignoreFile: scopeIgnoreFile ?? (root.applyIgnore ? homeIgnore : nil),
                ignoreRoot: scopeIgnoreFile != nil ? root.dir : nil,
                skipDir: { dir in
                    if let excl = root.excludePrefix, dir.hasPrefix(excl) {
                        return true
                    }
                    return volumePaths.contains(dir)
                },
                applyBlocklist: true,
                discoverGitignore: scope == .home && Defaults[.honorGitignore]
            )
        }
        return nil
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

    private func removeIgnoreLines(_ lines: [String], from file: FilePath, suppressWatcher: Bool) {
        guard let content = try? String(contentsOfFile: file.string, encoding: .utf8) else { return }
        let updated = Self.removingLines(lines, from: content)
        guard updated != content else { return }

        if suppressWatcher {
            fsignoreWatchSuppressedUntil = CFAbsoluteTimeGetCurrent() + 10
            fsignoreReindexTask?.cancel()
        }
        do {
            // In place, not atomically: the ignore-file watcher holds the file's descriptor.
            try updated.write(toFile: file.string, atomically: false, encoding: .utf8)
        } catch {
            log.error("Failed to rewrite \(file.string): \(error.localizedDescription)")
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
            if deduped.count >= liveChangesMax {
                break
            } // newest-first, so this drops only the oldest
        }
        deduped.reverse() // restore oldest→newest
        liveIndexChanges = deduped
    }

    private func compactOperationSummary() -> String {
        let ops = Array(ongoingOperations.values)
        guard let first = ops.last else { return "" }
        if ops.count == 1 {
            return first
        }
        return "\(first) (+\(ops.count - 1) more)"
    }

    // MARK: - Ignore File Watching

    private func contentHash(of path: String) -> Int? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return data.hashValue
    }

    private func performUpdateDefaultResults() {
        defaultResultsDirty = false
        let mode = Defaults[.defaultResultsMode]
        let files = mode == .recentFiles || Defaults[.searchBarDefaultResults] == .recentFiles ? computeDefaultResults() : []
        let defaults: [FilePath] = switch mode {
        case .recentFiles: files
        case .runHistory: RH.topResults(limit: Defaults[.maxResultsCount])
        case .empty: []
        }
        recentFiles = files
        recents = defaults
        sortedRecents = sortedResults(results: defaults)
        // `isDir` is a stat per path and Spotlight can fire this on every recents update, so on a
        // stalled mount the whole list froze the window (CLING-4A). Only the CLI reads these and the
        // coordinator is thread-safe, so stat on the (serial, so still ordered) filter queue.
        let recentPaths = defaults.map(\.string)
        recentsFilterQueue.async { [searchCoordinator] in
            let entries = recentPaths.map { path -> SearchCoordinator.RecentEntry in
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                return SearchCoordinator.RecentEntry(path: path, isDir: isDirectory.boolValue)
            }
            searchCoordinator.setRecents(entries)
        }
        let mdCount = mdQueryRecents.count
        let liveCount = liveIndexChanges.count
        log.debug("updateDefaultResults: mdQuery=\(mdCount) live=\(liveCount) merged=\(defaults.count)")
    }

    /// Returns the walk directories for a given scope.
    private func scopeCouldContain(_ scope: SearchScope, prefix: String) -> Bool {
        for dir in walkDirs(for: scope) {
            // prefix is inside this scope dir, or scope dir is inside the prefix
            if prefix.hasPrefix(dir.dir) || dir.dir.hasPrefix(prefix) {
                return true
            }
        }
        return false
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
        if reserved.contains(first) {
            continue
        }
        shortcuts[url] = first
    }
    return shortcuts
}

import Defaults

/// `OpenWithMenuView` calls this straight from its `body`, so it ran on every re-render: a LaunchServices
/// query per file plus a `Bundle(url:)` (an Info.plist read) per candidate app, all on the main thread.
/// The answer only moves when the user installs or removes an app, so memoise it per file set.
private let openWithCacheLock = NSLock()
private var openWithCache: [String: [URL]] = [:]
private var openWithCacheOrder: [String] = []

/// Bundle IDs keyed by app path. `Bundle(url:)` reads the app's Info.plist off disk, and a cache miss
/// re-read one for every candidate app, which is what stalled the main thread while the Open With menu
/// was built (CLING-48). An app's ID only moves when the app itself does, so this is dropped with the
/// memoised lists above.
private var bundleIDCache: [String: String?] = [:]

/// Drops the memoised Open With lists. Called when the installed-app set changes.
func invalidateCommonApplicationsCache() {
    openWithCacheLock.lock()
    openWithCache.removeAll()
    openWithCacheOrder.removeAll()
    bundleIDCache.removeAll()
    openWithCacheLock.unlock()
}

func cachedBundleIdentifier(of url: URL) -> String? {
    let path = url.path
    openWithCacheLock.lock()
    if let cached = bundleIDCache[path] {
        openWithCacheLock.unlock()
        return cached
    }
    openWithCacheLock.unlock()

    let id = url.bundleIdentifier
    openWithCacheLock.lock()
    bundleIDCache[path] = id
    openWithCacheLock.unlock()
    return id
}

func commonApplications(for urls: [URL]) -> [URL] {
    // The configured terminal and editor are filtered out of the result, so they belong in the key.
    let key = (urls.map(\.path).sorted() + [Defaults[.terminalApp], Defaults[.editorApp]])
        .joined(separator: "\u{0}")
    openWithCacheLock.lock()
    if let cached = openWithCache[key] {
        openWithCacheLock.unlock()
        return cached
    }
    openWithCacheLock.unlock()

    let appSets = urls.map { Set(NSWorkspace.shared.urlsForApplications(toOpen: $0)) }
    guard let first = appSets.first else { return [] }
    var commonApps = appSets.dropFirst().reduce(first) { $0.intersection($1) }
    if let terminal = Defaults[.terminalApp].fileURL, let editor = Defaults[.editorApp].fileURL {
        commonApps = commonApps.filter { $0 != terminal && $0 != editor }
    }
    commonApps = commonApps.filter { $0.lastPathComponent != "Google Chrome for Testing.app" }
    var commonAppsDict = [String: [URL]]()
    for app in commonApps {
        guard let id = cachedBundleIdentifier(of: app) else { continue }
        commonAppsDict[id, default: []].append(app)
    }
    let result = commonAppsDict.values.compactMap { $0.min(by: \.path.count) }

    openWithCacheLock.lock()
    openWithCache[key] = result
    openWithCacheOrder.append(key)
    if openWithCacheOrder.count > 64 {
        openWithCache.removeValue(forKey: openWithCacheOrder.removeFirst())
    }
    openWithCacheLock.unlock()
    return result
}

@MainActor let FUZZY = FuzzyClient()
