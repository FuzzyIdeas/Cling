import Foundation
import Lowtech
import os.log

private let cliLog = Logger(subsystem: "com.lowtechguys.Cling", category: "CLIService")

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

    var count: Int { lock.withLock { _count } }
    var indexing: Bool { lock.withLock { _indexing } }

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
        lock.withLock {
            _engines = engines
            _count = engines.reduce(0) { $0 + $1.engine.count }
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

// MARK: - IPC Message Types (must match ClingCLI side)

let CLING_PORT_ID = "com.lowtechguys.Cling.cli"
let CLING_SOCKET_PORT: UInt16 = 29055

enum ClingCommand: String, Codable {
    case search
    case index // backwards compat
    case reindex
    case status
    case recents
    case indexAdd
    case indexRemove
    case indexHas
}

struct ClingRequest: Codable {
    let command: ClingCommand
    var query: String?
    var maxResults: Int?
    var verbose: Bool?
    var rebuild: Bool?
    var dir: String?
    var suffixPattern: String?
    var folderPrefixes: [String]?
    var dirsOnly: Bool?
    var scopes: [String]?
    var paths: [String]?
}

struct ClingSearchResult: Codable {
    let path: String
    let isDir: Bool
    let score: Int
    let quality: Int
}

struct ClingResponse: Codable {
    var results: [ClingSearchResult]?
    var status: String?
    var error: String?
    var indexCount: Int?
    var searchMs: Double?
}

private extension Encodable {
    var jsonData: Data { try! JSONEncoder().encode(self) }
}
private extension Decodable {
    static func from(_ data: Data) -> Self? { try? JSONDecoder().decode(Self.self, from: data) }
}

// MARK: - Mach Port & Socket Listeners

@MainActor
extension FuzzyClient {
    func startCLIListeners() {
        startMachPortListener()
        startSocketListener()
    }

    private func startMachPortListener() {
        nonisolated(unsafe) let portName = CLING_PORT_ID as CFString
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

    private func startSocketListener() {
        let coord = searchCoordinator
        cliSocketThread = Thread {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { cliLog.error("socket() failed"); return }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = CLING_SOCKET_PORT.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bindOK = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bindOK == 0 else {
                cliLog.error("bind() failed on port \(CLING_SOCKET_PORT): \(String(cString: strerror(errno)))")
                return
            }
            guard listen(fd, 5) == 0 else { cliLog.error("listen() failed"); return }
            cliLog.info("Socket listener started on port \(CLING_SOCKET_PORT)")

            while true {
                var clientAddr = sockaddr_in()
                var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &clientLen) }
                }
                guard clientFD >= 0 else { continue }

                var buf = [UInt8](repeating: 0, count: 4096)
                let n = read(clientFD, &buf, buf.count)
                guard n > 0 else { close(clientFD); continue }

                let raw = String(bytes: buf[0 ..< n], encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if raw.isEmpty {
                    let msg = "echo 'query' | nc localhost \(CLING_SOCKET_PORT)\n"
                    _ = msg.withCString { write(clientFD, $0, strlen($0)) }
                } else {
                    let request = ClingRequest(command: .search, query: raw, maxResults: 30)
                    let response = FuzzyClient.handleCLIRequest(request, coordinator: coord)
                    let text: String = if let results = response.results {
                        results.map { r in r.isDir ? r.path + "/" : r.path }.joined(separator: "\n") + "\n"
                    } else {
                        response.error ?? "(no results)\n"
                    }
                    _ = text.withCString { write(clientFD, $0, strlen($0)) }
                }
                close(clientFD)
            }
        }
        cliSocketThread?.name = "ClingSocket"
        cliSocketThread?.start()
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
            let volumePaths = request.paths?.compactMap(\.filePath) ?? []
            mainActor {
                if !volumePaths.isEmpty {
                    for volume in volumePaths {
                        if FUZZY.enabledVolumes.contains(volume) {
                            FUZZY.indexVolume(volume)
                        }
                    }
                }
                if scopes != nil || volumePaths.isEmpty {
                    FUZZY.refresh(pauseSearch: request.rebuild ?? false, scopes: scopes)
                }
            }
            var labels = [String]()
            if let scopes { labels.append(contentsOf: scopes.map(\.label)) }
            if !volumePaths.isEmpty { labels.append(contentsOf: volumePaths.map(\.name.string)) }
            let scopeLabel = labels.isEmpty ? "all" : labels.joined(separator: ", ")
            return ClingResponse(status: "indexing started (\(scopeLabel))", indexCount: coord.count)

        case .status:
            let c = coord.count
            return ClingResponse(
                status: coord.indexing ? "indexing..." : (c > 0 ? "ready" : "empty"),
                indexCount: c
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
        }
    }
}
