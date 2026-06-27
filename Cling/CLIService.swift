import Defaults
import Foundation
import Lowtech
import os.log

private let cliLog = Logger(subsystem: "com.lowtechguys.Cling", category: "CLIService")

// MARK: - SearchCoordinator

/// Thread-safe search coordinator for multi-engine queries from any thread.
final class SearchCoordinator: @unchecked Sendable {
    struct EngineEntry {
        let engine: SearchEngine
        let label: String
        let scoreBias: Int
    }

    struct RecentEntry {
        let path: String
        let isDir: Bool
    }

    var count: Int {
        lock.withLock { _count }
    }
    var indexing: Bool {
        lock.withLock { _indexing }
    }

    func setIndexing(_ value: Bool) {
        lock.withLock { _indexing = value }
    }

    func setRecents(_ recents: [RecentEntry]) {
        lock.withLock { _recents = recents }
    }

    func getRecents(maxResults: Int) -> [RecentEntry] {
        lock.withLock { Array(_recents.prefix(maxResults)) }
    }

    func setEngines(_ engines: [EngineEntry]) {
        let retired: [EngineEntry] = lock.withLock {
            let previous = _engines
            _engines = engines
            _count = engines.reduce(0) { $0 + $1.engine.count }
            return previous
        }
        // Release the previous engines off the main thread: SearchEngine's deinit frees large index
        // buffers, and doing that on the main thread during an index swap hung the app (CLING-6).
        // Engines still present in the new set keep a positive refcount, so only truly retired
        // engines are deallocated here.
        if !retired.isEmpty {
            DispatchQueue.global(qos: .utility).async { _ = retired }
        }
    }

    func search(
        query: String,
        maxResults: Int = 30,
        folderPrefixes: [String]? = nil,
        suffixPattern: String? = nil,
        dirsOnly: Bool = false,
        scopeLabels: [String]? = nil,
        cancelled: (() -> Bool)? = nil
    ) -> [SearchResult] {
        let allEngines = lock.withLock { _engines }
        let engines: [EngineEntry]
        if let labels = scopeLabels, !labels.isEmpty {
            let lowered = Set(labels.map { $0.lowercased() })
            // Match scope labels against both raw values (e.g. "root") and display labels (e.g. "Root (/usr, ...)")
            let scopesByRawValue = Dictionary(uniqueKeysWithValues: SearchScope.allCases.map { ($0.rawValue.lowercased(), $0.label) })
            let resolvedLabels = lowered.flatMap { raw -> [String] in
                var matches = [raw]
                if let displayLabel = scopesByRawValue[raw] {
                    matches.append(displayLabel.lowercased())
                }
                return matches
            }
            let matchSet = Set(resolvedLabels)
            engines = allEngines.filter { matchSet.contains($0.label.lowercased()) }
        } else {
            engines = allEngines
        }
        guard !engines.isEmpty else { return [] }

        // Fold suffix into query as extension tokens so multi-suffix works: ".png .jpeg" -> "query .png .jpeg"
        var effectiveQuery = query
        if let sfx = suffixPattern, !sfx.isEmpty {
            let extTokens = sfx.replacingOccurrences(of: "|", with: " ").replacingOccurrences(of: ",", with: " ")
                .split(separator: " ").filter { $0.hasPrefix(".") }.map(String.init)
            if !extTokens.isEmpty {
                effectiveQuery = (effectiveQuery.isEmpty ? "" : effectiveQuery + " ") + extTokens.joined(separator: " ")
            }
        }

        let n = engines.count
        let resultStore = UnsafeMutablePointer<[SearchResult]>.allocate(capacity: n)
        resultStore.initialize(repeating: [], count: n)
        defer { resultStore.deinitialize(count: n); resultStore.deallocate() }

        DispatchQueue.concurrentPerform(iterations: n) { idx in
            resultStore[idx] = engines[idx].engine.search(
                query: effectiveQuery,
                maxResults: maxResults,
                folderPrefixes: folderPrefixes,
                dirsOnly: dirsOnly,
                cancelled: cancelled
            )
        }

        // Quality gate + Comparable merge + dedup
        var bestQuality = 0
        var i = 0
        while i < n {
            if let first = resultStore[i].first, first.quality > bestQuality { bestQuality = first.quality }
            i &+= 1
        }
        let minQuality = bestQuality / 3

        var allResults = [SearchResult]()
        i = 0
        while i < n {
            var ri = 0
            while ri < resultStore[i].count {
                let r = resultStore[i][ri]
                if r.quality >= minQuality || r.hasBase { allResults.append(r) }
                ri &+= 1
            }
            i &+= 1
        }
        allResults.sort(by: >)
        var seen = Set<String>()
        return allResults.prefix(maxResults * 2).filter { seen.insert($0.path).inserted }.prefix(maxResults).map { $0 }
    }

    /// Remove a path from engines. If scopeLabels is provided, only those engines are checked.
    func removePath(_ path: String, scopeLabels: [String]? = nil) -> [String] {
        let engines = filteredEngines(scopeLabels: scopeLabels)
        var removed = [String]()
        for eng in engines {
            if eng.engine.removePath(path) {
                removed.append(eng.label)
            }
        }
        if !removed.isEmpty {
            lock.withLock { _count = _engines.reduce(0) { $0 + $1.engine.count } }
        }
        return removed
    }

    /// Add a path to the best matching engine. If scopeLabels is provided, only those engines are considered.
    /// Otherwise, the scope is guessed from the path prefix.
    func addPath(_ path: String, isDir: Bool, scopeLabels: [String]? = nil) -> String? {
        let engines: [EngineEntry]
        if let labels = scopeLabels, !labels.isEmpty {
            engines = filteredEngines(scopeLabels: labels)
        } else {
            // Guess scope from path
            let guessed = guessScope(for: path)
            let candidates = filteredEngines(scopeLabels: guessed.map { [$0] })
            engines = candidates.isEmpty ? lock.withLock { _engines } : candidates
        }
        for eng in engines {
            if eng.engine.hasPath(path) {
                return "\(eng.label) (already exists)"
            }
        }
        guard let eng = engines.first else { return nil }
        eng.engine.addPath(path, isDir: isDir)
        lock.withLock { _count = _engines.reduce(0) { $0 + $1.engine.count } }
        return eng.label
    }

    /// Check which engines contain the path. If scopeLabels is provided, only those engines are checked.
    func hasPath(_ path: String, scopeLabels: [String]? = nil) -> [String] {
        let engines = filteredEngines(scopeLabels: scopeLabels)
        var found = [String]()
        for eng in engines {
            if eng.engine.hasPath(path) {
                found.append(eng.label)
            }
        }
        return found
    }

    private let lock = NSLock()
    private var _engines: [EngineEntry] = []
    private var _count = 0
    private var _recents: [RecentEntry] = []
    private var _indexing = false

    private func guessScope(for path: String) -> String? {
        let home = NSHomeDirectory()
        let libraryPrefix = home + "/Library"
        if path.hasPrefix(libraryPrefix + "/") || path == libraryPrefix { return "library" }
        if path.hasPrefix(home + "/") || path == home { return "home" }
        if path.hasPrefix("/Applications/") || path == "/Applications"
            || path.hasPrefix("/System/Applications/") { return "applications" }
        if path.hasPrefix("/System/") || path == "/System" { return "system" }
        if path.hasPrefix("/usr/") || path.hasPrefix("/bin/") || path.hasPrefix("/sbin/")
            || path.hasPrefix("/etc/") || path.hasPrefix("/var/") || path.hasPrefix("/opt/") { return "root" }
        return nil
    }

    private func filteredEngines(scopeLabels: [String]?) -> [EngineEntry] {
        let all = lock.withLock { _engines }
        guard let labels = scopeLabels, !labels.isEmpty else { return all }
        let lowered = Set(labels.map { $0.lowercased() })
        let scopesByRawValue = Dictionary(uniqueKeysWithValues: SearchScope.allCases.map { ($0.rawValue.lowercased(), $0.label) })
        let resolved = lowered.flatMap { raw -> [String] in
            var matches = [raw]
            if let displayLabel = scopesByRawValue[raw] { matches.append(displayLabel.lowercased()) }
            return matches
        }
        let matchSet = Set(resolved)
        return all.filter { matchSet.contains($0.label.lowercased()) }
    }

}

// IPC types (CLING_PORT_ID, ClingCommand, ClingRequest, ClingResponse,
// ClingSearchResult, ClingScopeStatus, ClingVolumeStatus) live in
// Shared/ClingIPC.swift so they can be shared between the Cling app and the
// ClingCLI tool.

private extension Encodable {
    var jsonData: Data {
        try! JSONEncoder().encode(self)
    }
}
private extension Decodable {
    static func from(_ data: Data) -> Self? {
        try? JSONDecoder().decode(Self.self, from: data)
    }
}

// MARK: - Mach Port Listener

@MainActor
extension FuzzyClient {
    func startCLIListeners() {
        startMachPortListener()
    }

    private func startMachPortListener() {
        nonisolated(unsafe) let portName = CLING_PORT_ID
        let coord = searchCoordinator

        cliMachPortThread = Thread {
            let coordPtr = Unmanaged.passUnretained(coord).toOpaque()
            var context = CFMessagePortContext(version: 0, info: coordPtr, retain: nil, release: nil, copyDescription: nil)
            guard let port = CFMessagePortCreateLocal(nil, portName, { _, _, data, info -> Unmanaged<CFData>? in
                guard let info else { return nil }
                let coord = Unmanaged<SearchCoordinator>.fromOpaque(info).takeUnretainedValue()
                guard let data = data as Data?,
                      let request = try? JSONDecoder().decode(ClingRequest.self, from: data)
                else { return nil }
                let response = FuzzyClient.handleCLIRequest(request, coordinator: coord)
                let responseData = try! JSONEncoder().encode(response)
                return Unmanaged.passRetained(responseData as CFData)
            }, &context, nil) else {
                cliLog.error("Failed to create Mach port for \(CLING_PORT_ID)")
                return
            }

            let source = CFMessagePortCreateRunLoopSource(nil, port, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
            cliLog.info("Mach port listener started on \(CLING_PORT_ID)")
            CFRunLoopRun()
        }
        cliMachPortThread?.name = "ClingMachPort"
        cliMachPortThread?.start()
    }

    // MARK: - Request Handler

    nonisolated static func handleCLIRequest(_ request: ClingRequest, coordinator coord: SearchCoordinator) -> ClingResponse {
        switch request.command {
        case .search:
            let query = request.query ?? ""
            let maxResults = request.maxResults ?? 30

            let t0 = CFAbsoluteTimeGetCurrent()
            let results = coord.search(
                query: query,
                maxResults: maxResults,
                folderPrefixes: request.folderPrefixes,
                suffixPattern: request.suffixPattern,
                dirsOnly: request.dirsOnly ?? false,
                scopeLabels: request.scopes
            )
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000

            cliLog.debug("CLI search: q=\"\(query)\" \(results.count) results in \(ms, format: .fixed(precision: 1))ms")

            return ClingResponse(
                results: results.map { ClingSearchResult(path: $0.path, isDir: $0.isDir, score: $0.score, quality: $0.quality) },
                indexCount: coord.count,
                searchMs: ms
            )

        case .index, .reindex:
            let scopes = request.scopes?.compactMap { SearchScope(rawValue: $0) }
            var volumePaths = request.paths?.compactMap(\.filePath) ?? []

            // Synchronously check for conflicts with any in-flight indexing and decide
            // whether to start a new batch, attach to the existing one, or reject.
            // 0 = started, 1 = attached, 2 = conflict
            var decisionKind = 0
            var decisionMessage = ""
            var decisionLabels: [String] = []
            let sem = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                defer { sem.signal() }

                // Resolve unrecognized scope names as volume names
                if let requestedScopes = request.scopes {
                    let recognizedScopes = Set(scopes?.map(\.rawValue) ?? [])
                    for name in requestedScopes where !recognizedScopes.contains(name) {
                        if let volume = FUZZY.enabledVolumes.first(where: { $0.name.string == name }) {
                            volumePaths.append(volume)
                        }
                    }
                }
                let activeScopeIndexing = FUZZY.scopesIndexing
                let activeVolumeIndexing = FUZZY.volumesIndexing
                let anyActive = !activeScopeIndexing.isEmpty || !activeVolumeIndexing.isEmpty || FUZZY.indexing

                let requestedScopes = scopes ?? []
                let requestedVolumes = volumePaths

                if anyActive {
                    // "Reindex all" while anything is running is a conflict.
                    if requestedScopes.isEmpty, requestedVolumes.isEmpty {
                        decisionKind = 2
                        decisionMessage = "another indexing operation is in progress; wait for it to finish or cancel it first"
                        return
                    }

                    // Any requested scope/volume not already in the active batch is a conflict,
                    // because indexFiles() would silently drop the new request.
                    let conflictingScopes = requestedScopes.filter { !activeScopeIndexing.contains($0) }
                    let conflictingVolumes = requestedVolumes.filter { !activeVolumeIndexing.contains($0) }

                    if !conflictingScopes.isEmpty || !conflictingVolumes.isEmpty {
                        var parts = [String]()
                        if !conflictingScopes.isEmpty { parts.append(conflictingScopes.map(\.label).joined(separator: ", ")) }
                        if !conflictingVolumes.isEmpty { parts.append(conflictingVolumes.map(\.name.string).joined(separator: ", ")) }
                        decisionKind = 2
                        decisionMessage = "cannot start reindex for \(parts.joined(separator: ", ")): another indexing operation is in progress; wait for it to finish or cancel it first"
                        return
                    }

                    // Everything requested is already in flight — attach.
                    decisionKind = 1
                    decisionLabels = requestedScopes.map(\.label) + requestedVolumes.map(\.name.string)
                    return
                }

                // Nothing running: start the requested work.
                if !requestedVolumes.isEmpty {
                    for volume in requestedVolumes where FUZZY.enabledVolumes.contains(volume) {
                        FUZZY.indexVolume(volume)
                    }
                }
                if scopes != nil || requestedVolumes.isEmpty {
                    FUZZY.refresh(pauseSearch: request.rebuild ?? false, scopes: scopes)
                }
                decisionKind = 0
                decisionLabels = requestedScopes.map(\.label) + requestedVolumes.map(\.name.string)
            }
            sem.wait()

            switch decisionKind {
            case 2:
                return ClingResponse(error: decisionMessage)
            case 1:
                let label = decisionLabels.isEmpty ? "all" : decisionLabels.joined(separator: ", ")
                return ClingResponse(
                    status: "already indexing (\(label)); attaching to in-progress operation",
                    indexCount: coord.count,
                    state: "indexing"
                )
            default:
                let label = decisionLabels.isEmpty ? "all" : decisionLabels.joined(separator: ", ")
                return ClingResponse(status: "indexing started (\(label))", indexCount: coord.count)
            }

        case .cancelIndex:
            let volumePaths = request.paths?.compactMap(\.filePath) ?? []
            let cancelScopes = request.scopes != nil
            mainActor {
                if !volumePaths.isEmpty {
                    for volume in volumePaths {
                        FUZZY.cancelVolumeIndexing(volume: volume)
                    }
                } else if cancelScopes {
                    FUZZY.cancelScopeIndexing()
                } else {
                    FUZZY.cancelAllIndexing()
                }
            }
            let what = !volumePaths.isEmpty ? volumePaths.map(\.name.string).joined(separator: ", ") : cancelScopes ? "scopes" : "all"
            return ClingResponse(status: "cancelled indexing (\(what))", indexCount: coord.count)

        case .status:
            let c = coord.count
            var details = ""
            var stateOut = ""
            var operationOut: String?
            var scopeStatuses: [ClingScopeStatus] = []
            var volumeStatuses: [ClingVolumeStatus] = []
            let sem = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                defer { sem.signal() }
                var lines = [String]()

                // Overall status
                let state = FUZZY.indexing ? "indexing" : FUZZY.backgroundIndexing ? "background indexing" : (c > 0 ? "ready" : "empty")
                stateOut = state
                lines.append("status: \(state)")
                lines.append("total: \(c.formatted()) entries")

                // Scope details
                let enabledScopes = Defaults[.searchScopes]
                let ops = FUZZY.ongoingOperations
                let opCounts = FUZZY.ongoingOperationCounts
                lines.append("")
                lines.append("scopes:")
                for scope in SearchScope.allCases {
                    let enabled = enabledScopes.contains(scope)
                    let count = FUZZY.scopeEngines[scope]?.count ?? 0
                    let indexed = FUZZY.scopeEngines[scope] != nil
                    let scopeKey = "scope:\(scope.rawValue)"
                    let loadKey = "load:\(scope.rawValue)"
                    let scopeOp = ops[scopeKey] ?? ops[loadKey]
                    let scopeOpCount = opCounts[scopeKey] ?? opCounts[loadKey]
                    let scopeIndexing = scopeOp != nil
                    let status = !enabled ? "disabled" : scopeIndexing ? (scopeOp ?? "indexing...") : !indexed ? "not indexed" : "\(count.formatted()) entries"
                    lines.append("  \(scope.label): \(status)")
                    let scopeFile = scopeIndexFile(scope)
                    let lastIndexedAt = scopeFile.exists ? scopeFile.timestamp : nil
                    scopeStatuses.append(ClingScopeStatus(
                        name: scope.label,
                        rawValue: scope.rawValue,
                        enabled: enabled,
                        indexed: indexed,
                        indexing: scopeIndexing,
                        count: count,
                        operation: scopeOp,
                        operationCount: scopeOpCount,
                        lastIndexedAt: lastIndexedAt
                    ))
                }

                // Volume details
                if !FUZZY.externalVolumes.isEmpty {
                    lines.append("")
                    lines.append("volumes:")
                    for volume in FUZZY.externalVolumes {
                        let enabled = FUZZY.enabledVolumes.contains(volume)
                        let volKey = "volume:\(volume.string)"
                        let volumeOp = ops[volKey]
                        let volumeOpCount = opCounts[volKey]
                        let indexing = FUZZY.volumesIndexing.contains(volume) || volumeOp != nil
                        let count = FUZZY.volumeEngines[volume]?.count ?? 0
                        let indexed = FUZZY.volumeEngines[volume] != nil
                        let status = !enabled ? "disabled" : indexing ? (volumeOp ?? "indexing...") : !indexed ? "not indexed" : "\(count.formatted()) entries"
                        lines.append("  \(volume.name.string) (\(volume.shellString)): \(status)")
                        let volFile = volumeIndexFile(volume)
                        let lastIndexedAt = volFile.exists ? volFile.timestamp : nil
                        volumeStatuses.append(ClingVolumeStatus(
                            name: volume.name.string,
                            path: volume.shellString,
                            enabled: enabled,
                            indexed: indexed,
                            indexing: indexing,
                            count: count,
                            operation: volumeOp,
                            operationCount: volumeOpCount,
                            lastIndexedAt: lastIndexedAt
                        ))
                    }
                }

                // Current operation
                if !FUZZY.operation.isEmpty {
                    lines.append("")
                    lines.append("operation: \(FUZZY.operation)")
                    operationOut = FUZZY.operation
                }

                details = lines.joined(separator: "\n")
            }
            if sem.wait(timeout: .now() + 5) == .timedOut {
                return ClingResponse(
                    status: coord.indexing ? "indexing..." : (c > 0 ? "ready" : "empty"),
                    indexCount: c,
                    state: coord.indexing ? "indexing" : (c > 0 ? "ready" : "empty")
                )
            }
            return ClingResponse(
                status: details,
                indexCount: c,
                state: stateOut,
                operation: operationOut,
                scopes: scopeStatuses,
                volumes: volumeStatuses
            )

        case .recents:
            let maxResults = request.maxResults ?? 50
            // Wait for MDQuery to populate (up to 3 seconds)
            var recents = coord.getRecents(maxResults: maxResults)
            if recents.isEmpty {
                for _ in 0 ..< 6 {
                    Thread.sleep(forTimeInterval: 0.5)
                    recents = coord.getRecents(maxResults: maxResults)
                    if !recents.isEmpty { break }
                }
            }
            return ClingResponse(
                results: recents.map { ClingSearchResult(path: $0.path, isDir: $0.isDir, score: 0, quality: 0) },
                indexCount: coord.count
            )

        case .indexRemove:
            guard let paths = request.paths, !paths.isEmpty else {
                return ClingResponse(error: "no paths specified")
            }
            var messages = [String]()
            for path in paths {
                let removed = coord.removePath(path, scopeLabels: request.scopes)
                if removed.isEmpty {
                    messages.append("\(path): not found in any engine")
                } else {
                    messages.append("\(path): removed from \(removed.joined(separator: ", "))")
                }
            }
            mainActor { FUZZY.scheduleSaveIndexes() }
            return ClingResponse(status: messages.joined(separator: "\n"), indexCount: coord.count)

        case .indexAdd:
            guard let paths = request.paths, !paths.isEmpty else {
                return ClingResponse(error: "no paths specified")
            }
            var messages = [String]()
            for path in paths {
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                if let label = coord.addPath(path, isDir: isDirectory.boolValue, scopeLabels: request.scopes) {
                    messages.append("\(path): added to \(label)")
                } else {
                    messages.append("\(path): no engines available")
                }
            }
            mainActor { FUZZY.scheduleSaveIndexes() }
            return ClingResponse(status: messages.joined(separator: "\n"), indexCount: coord.count)

        case .indexHas:
            guard let paths = request.paths, !paths.isEmpty else {
                return ClingResponse(error: "no paths specified")
            }
            var messages = [String]()
            for path in paths {
                let found = coord.hasPath(path, scopeLabels: request.scopes)
                if found.isEmpty {
                    messages.append("\(path): not found")
                } else {
                    messages.append("\(path): found in \(found.joined(separator: ", "))")
                }
            }
            return ClingResponse(status: messages.joined(separator: "\n"), indexCount: coord.count)

        case .explain:
            guard let paths = request.paths, !paths.isEmpty else {
                return ClingResponse(error: "no paths specified")
            }
            let report = paths.map { explainPathExclusion($0, coord: coord) }.joined(separator: "\n\n")
            return ClingResponse(status: report, indexCount: coord.count)
        }
    }
}
