import ClopSDK
import Cocoa
import Combine
import Foundation
import Ignore
import Lowtech
import System

let FS_IGNORE = Bundle.main.url(forResource: "fsignore", withExtension: nil)!.existingFilePath!

let fsignore: FilePath = HOME / ".fsignore"
let fsignoreString: String = (HOME / ".fsignore").string

/// Fast in-memory blocklist for paths that should never be indexed, regardless of scope.
/// Rebuilt from user settings. Checked with simple prefix/contains matching on UTF-8 bytes for speed.
final class PathBlocklist: @unchecked Sendable {
    init() { rebuild() }

    static let shared = PathBlocklist()

    private(set) var prefixes: [[UInt8]] = []
    private(set) var components: [[UInt8]] = []

    func rebuild() {
        let rawPrefixes = Defaults[.blockedPrefixes]
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        // Auto-generate /private counterparts for paths under symlinked dirs
        var allPrefixes = [String]()
        for p in rawPrefixes {
            allPrefixes.append(p)
            if p.hasPrefix("/tmp/") || p.hasPrefix("/var/") || p.hasPrefix("/etc/") {
                allPrefixes.append("/private" + p)
            } else if p.hasPrefix("/private/tmp/") || p.hasPrefix("/private/var/") || p.hasPrefix("/private/etc/") {
                allPrefixes.append(String(p.dropFirst("/private".count)))
            }
        }
        prefixes = allPrefixes.map { Array($0.utf8) }
        components = Defaults[.blockedContains]
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { Array($0.utf8) }
    }
}

func isPathBlocked(_ path: String) -> Bool {
    let bl = PathBlocklist.shared
    var blocked = false
    path.utf8.withContiguousStorageIfAvailable { buf in
        let len = buf.count
        for prefix in bl.prefixes {
            guard len >= prefix.count else { continue }
            if memcmp(buf.baseAddress!, prefix, prefix.count) == 0 { blocked = true; return }
        }
        for component in bl.components {
            let cLen = component.count
            guard len >= cLen else { continue }
            let end = len - cLen
            for i in 0 ... end {
                if memcmp(buf.baseAddress! + i, component, cLen) == 0 { blocked = true; return }
            }
            // Also match when path ends with the component minus trailing slash
            // e.g. path "/foo/build" matches component "/build/" because fts_read omits trailing /
            if cLen >= 2, component[cLen - 1] == 0x2F, len >= cLen - 1 {
                if memcmp(buf.baseAddress! + len - (cLen - 1), component, cLen - 1) == 0 { blocked = true; return }
            }
        }
    }
    return blocked
}

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
        let mounted = Set(externalVolumes)
        disconnectedVolumes = Set(Defaults[.indexedVolumePaths].filter { !mounted.contains($0) && !disabledVolumes.contains($0) })
        enabledVolumes = computeEnabledVolumes(mounted: externalVolumes, disabled: disabledVolumes)
        readOnlyVolumes = externalVolumes.filter(\.url.volumeIsReadOnly)
        externalIndexes = getExternalIndexes()
        indexStaleExternalVolumes()
    }}

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
                        dirsOnly: currentQuick.dirsOnly, folders: folderFilter.folders, key: currentQuick.key
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
        guard let qf = quickFilter, qf.extensions != nil || qf.dirsOnly else {
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
                let pool = eng.prefilter(extensions: qf.extensions, dirsOnly: qf.dirsOnly)
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
                disabledVolumes = volumes.newValue
                let mounted = Set(externalVolumes)
                disconnectedVolumes = Set(Defaults[.indexedVolumePaths].filter { !mounted.contains($0) && !disabledVolumes.contains($0) })
                enabledVolumes = computeEnabledVolumes(mounted: externalVolumes, disabled: disabledVolumes)
                externalIndexes = getExternalIndexes()
                performSearch()
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
        if !fsignore.exists {
            do { try FS_IGNORE.copy(to: fsignore) }
            catch { log.error("Failed to copy \(FS_IGNORE.string) to \(fsignoreString): \(error)") }
        }

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
                    log.debug("Loaded \(self.indexedCount) entries (\(self.scopeEngines.count) scopes, \(self.volumeEngines.count) volumes)")
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
                    group.addTask {
                        let scopeEngine = SearchEngine()
                        scopeEngine.reserveCapacity(100_000)
                        for dir in dirs {
                            let excludeSkip: ((String) -> Bool)? = dir.excludePrefix.map { excl in
                                { path in path.hasPrefix(excl) }
                            }
                            let skipDir: ((String) -> Bool)? = { path in
                                if isPathBlocked(path) { return true }
                                if excludeSkip?(path) ?? false { return true }
                                if volumePaths.contains(path) { return true }
                                return false
                            }
                            let ignore = dir.applyIgnore ? ignoreChecker : nil
                            let opKey = "scope:\(scope.rawValue)"
                            scopeEngine.walkDirectory(dir.dir, ignoreFile: ignore, skipDir: skipDir, progress: { count, _ in
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
                            self.liveIndexChanges.append(IndexChange(path: pathStr, kind: kind))
                            if self.noQuery { self.updateDefaultResults(debounce: true) }
                        }
                    } else {
                        recentsEngine.removePath(pathStr)
                        mainActor {
                            self.removedFiles.insert(pathStr)
                            self.indexedCount = max(0, self.indexedCount &- 1)
                            self.liveIndexChanges.append(IndexChange(path: pathStr, kind: .removed))
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
            log.error("Failed to watch files: \(error)")
        }
    }

    /// Force the next performSearch to run even if params haven't changed
    func invalidateSearch() {
        lastSearchQuery = "\0"
    }
    func performSearch() {
        searchTask?.cancel()

        if emptyQuery, volumeFilter == nil {
            scoredResults = []
            results = []
            noQuery = true
            lastSearchQuery = ""
            return
        }

        guard validReq(), !indexing || indexedCount > 0 else { return }

        // Combine user query with QuickFilter's preQuery/postQuery
        var query = constructQuery(self.query)
        if let pre = quickFilter?.preQuery, !pre.isEmpty {
            query = query.isEmpty ? pre : "\(pre) \(query)"
        }
        if let post = quickFilter?.postQuery, !post.isEmpty {
            query = query.isEmpty ? post : "\(query) \(post)"
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
        log.debug("performSearch: q=\"\(query)\" engines=\(activeEngines.count) \(filterDesc)")
        let maxResults = proactive ? Defaults[.maxResultsCount] : min(Defaults[.maxResultsCount], 500)
        let folderPrefixes = folderFilter?.folders.map(\.string)
        let volumePrefix = volumeFilter?.string
        let removedPaths = removedFiles.union(excludedPaths)
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

        // 1. Live index changes (newest first, added/modified only)
        var ci = liveIndexChanges.count - 1
        while ci >= 0, results.count < 20 {
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
            openWithAppShortcuts = computeShortcuts(for: commonOpenWithApps)
            for app in commonOpenWithApps where appIconCache[app.path] == nil {
                let img = NSWorkspace.shared.icon(forFile: app.path)
                img.size = NSSize(width: 16, height: 16)
                appIconCache[app.path] = img
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
                let img = NSWorkspace.shared.icon(forFile: url.path)
                img.size = NSSize(width: 16, height: 16)
                icons[url.path] = img
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
        log.debug("updateDefaultResults: mdQuery=\(mdQueryRecents.count) live=\(liveIndexChanges.count) merged=\(defaults.count)")
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

func computeShortcuts(for urls: [URL], reserved: Set<Character> = []) -> [URL: Character] {
    var usedShortcuts = reserved
    var shortcuts = [URL: Character]()
    for url in urls {
        let name = url.lastPathComponent.ns.deletingPathExtension
        var shortcut: Character?
        for char in name.lowercased() {
            if !usedShortcuts.contains(char) { shortcut = char; break }
        }
        if shortcut == nil {
            for i in 1 ... 9 {
                let candidate = i.s.first!
                if !usedShortcuts.contains(candidate) { shortcut = candidate; break }
            }
        }
        if let shortcut {
            usedShortcuts.insert(shortcut)
            shortcuts[url] = shortcut
        }
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
    let commonAppsDict: [String: [URL]] = commonApps.group(by: \.bundleIdentifier)
    let uniqueAppsByShortestPath = commonAppsDict.values.compactMap { $0.min(by: \.path.count) }
    return uniqueAppsByShortestPath
}

@MainActor let FUZZY = FuzzyClient()
