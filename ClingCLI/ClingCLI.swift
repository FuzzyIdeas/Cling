import ArgumentParser
import Foundation

// IPC types (CLING_PORT_ID, ClingCommand, ClingRequest, ClingResponse,
// ClingSearchResult, ClingScopeStatus, ClingVolumeStatus) live in
// Shared/ClingIPC.swift and are compiled into both this tool and the Cling app.

// MARK: - Lightweight Mach Port Client (raw CFMessagePort, no Lowtech dependency)

func sendMachPort(data: Data?, sendTimeout: TimeInterval = 2, recvTimeout: TimeInterval = 10) throws -> Data? {
    guard let port = CFMessagePortCreateRemote(nil, CLING_PORT_ID) else {
        throw NSError(
            domain: "ClingCLI",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Cannot connect to Cling app (is it running?)"]
        )
    }

    var returnData: Unmanaged<CFData>?
    let status = CFMessagePortSendRequest(
        port,
        Int32.random(in: 1 ... 100_000),
        data as CFData?,
        sendTimeout,
        recvTimeout,
        CFRunLoopMode.defaultMode.rawValue,
        &returnData
    )

    guard status == kCFMessagePortSuccess else {
        throw NSError(
            domain: "ClingCLI",
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "Mach port send failed (status \(status))"]
        )
    }

    return returnData?.takeRetainedValue() as Data?
}

// MARK: - ClingCLI

@main
struct ClingCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cling",
        abstract: "Cling: fast fuzzy file search from the command line",
        subcommands: [Search.self, Reindex.self, Status.self, Recents.self, Index.self, Explain.self],
        defaultSubcommand: Search.self
    )
}

// MARK: - Explain

struct Explain: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Explain whether a path is indexed, and if not, which rule excludes it",
        discussion: """
        For each path, reports existence on disk, current index membership, the scope it maps to \
        (and whether that scope is enabled), the path blocklist, and the gitignore-style ignore \
        files — then a one-line verdict. Relative paths are resolved against the current directory.
        """
    )

    @Argument(parsing: .remaining, help: "Paths to diagnose")
    var paths: [String]

    mutating func run() throws {
        let cwd = FileManager.default.currentDirectoryPath
        let resolved = paths.map { p -> String in
            let tilde = (p as NSString).expandingTildeInPath
            let abs = tilde.hasPrefix("/") ? tilde : (cwd as NSString).appendingPathComponent(tilde)
            return (abs as NSString).standardizingPath
        }
        let request = ClingRequest(command: .explain, paths: resolved)
        guard let data = try sendMachPort(data: JSONEncoder().encode(request)) else {
            fputs("error: no response from Cling app\n", stderr)
            throw ExitCode.failure
        }
        guard let response = try? JSONDecoder().decode(ClingResponse.self, from: data) else {
            fputs("error: invalid response\n", stderr)
            throw ExitCode.failure
        }
        if let error = response.error {
            fputs("error: \(error)\n", stderr)
            throw ExitCode.failure
        }
        print(response.status ?? "(no output)")
    }
}

// MARK: - Search

struct Search: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Search for files")

    @Argument(help: "Search query (fuzzy match)")
    var query: String

    @Option(name: .shortAndLong, help: "Max results")
    var count = 30

    @Option(name: .long, help: "Filter by suffix (e.g. .pdf, .app/, /)")
    var suffix: String?

    @Option(name: .long, help: "Restrict to folder prefix(es), comma-separated")
    var folders: String?

    @Flag(name: .long, help: "Only match directories")
    var dirsOnly = false

    @Flag(name: .shortAndLong, help: "Show scores and timing")
    var verbose = false

    @Flag(name: .shortAndLong, help: "Use TCP socket instead of Mach port")
    var socket = false

    @Option(name: .long, help: "TCP port for socket mode")
    var port: UInt16 = 29055

    @Option(name: .long, parsing: .upToNextOption, help: "Search only in specific scopes (home, library, applications, system, root)")
    var scope: [String] = []

    mutating func run() throws {
        if socket {
            try runSocket()
        } else {
            try runMachPort()
        }
    }

    private func runMachPort() throws {
        let request = ClingRequest(
            command: .search, query: query, maxResults: count, verbose: verbose,
            suffixPattern: suffix, folderPrefixes: folders?.components(separatedBy: ","),
            dirsOnly: dirsOnly ? true : nil, scopes: scope.isEmpty ? nil : scope
        )

        let t0 = CFAbsoluteTimeGetCurrent()
        guard let responseData = try sendMachPort(data: JSONEncoder().encode(request)) else {
            fputs("error: no response from Cling app\n", stderr)
            throw ExitCode.failure
        }
        let roundtripMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        guard let response = try? JSONDecoder().decode(ClingResponse.self, from: responseData) else {
            fputs("error: invalid response from Cling app\n", stderr)
            throw ExitCode.failure
        }

        if let error = response.error {
            fputs("error: \(error)\n", stderr)
            throw ExitCode.failure
        }

        if verbose {
            fputs(String(
                format: "search: %.1fms (roundtrip: %.1fms), %d results, %d indexed\n",
                response.searchMs ?? 0,
                roundtripMs,
                response.results?.count ?? 0,
                response.indexCount ?? 0
            ), stderr)
        }

        guard let results = response.results, !results.isEmpty else {
            fputs("(no results)\n", stderr)
            return
        }

        for r in results {
            let display = r.isDir ? r.path + "/" : r.path
            if verbose {
                print("\(display)\tscore=\(r.score)  quality=\(r.quality)")
            } else {
                print(display)
            }
        }
    }

    private func runSocket() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { fputs("error: socket()\n", stderr); throw ExitCode.failure }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else {
            fputs("error: cannot connect to localhost:\(port)\n", stderr)
            throw ExitCode.failure
        }

        let msg = query + "\n"
        _ = msg.withCString { Darwin.write(fd, $0, strlen($0)) }

        var buf = [UInt8](repeating: 0, count: 65536)
        var response = ""
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            response += String(bytes: buf[0 ..< n], encoding: .utf8) ?? ""
        }
        print(response, terminator: "")
    }
}

// MARK: - Reindex

struct Reindex: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Trigger reindexing of the filesystem",
        discussion: """
        By default, performs an incremental reindex that re-walks enabled scopes and \
        updates the in-memory index with any changes since the last full index.

        With --rebuild, performs a full rebuild: deletes all persisted .idx files, \
        clears the in-memory index, and re-walks the entire filesystem from scratch. \
        This is useful when the index is corrupted or after significant changes to \
        the ignore file or blocklist.

        With --cancel, stops any ongoing indexing. Combine with --scope to cancel \
        specific scopes or volumes only.
        """
    )

    @Flag(name: .shortAndLong, help: "Force full rebuild: delete persisted indexes and re-walk from scratch")
    var rebuild = false

    @Flag(name: .shortAndLong, help: "Cancel ongoing indexing instead of starting a new one")
    var cancel = false

    @Flag(name: .shortAndLong, help: "Wait for indexing to finish")
    var wait = false

    @Option(name: .shortAndLong, parsing: .upToNextOption, help: "Scopes to reindex (home, library, applications, system, root) or volume paths (/Volumes/...). Omit for all.")
    var scope: [String] = []

    mutating func run() throws {
        let volumes = scope.filter { $0.hasPrefix("/Volumes/") || $0.hasPrefix("/Volumes") }
        let scopes = scope.filter { !$0.hasPrefix("/Volumes") }

        // Capture initial per-scope/volume last-indexed timestamps so the --wait loop
        // can detect fast reindexes that complete between the request and the first poll.
        var initialScopeTimestamps: [String: Double] = [:]
        var initialVolumeTimestamps: [String: Double] = [:]
        if wait, !cancel {
            let statusReq = ClingRequest(command: .status)
            if let statusData = try? sendMachPort(data: JSONEncoder().encode(statusReq), recvTimeout: 5),
               let statusResp = try? JSONDecoder().decode(ClingResponse.self, from: statusData)
            {
                for s in statusResp.scopes ?? [] {
                    if let ts = s.lastIndexedAt { initialScopeTimestamps[s.rawValue.lowercased()] = ts }
                }
                for v in statusResp.volumes ?? [] {
                    if let ts = v.lastIndexedAt { initialVolumeTimestamps[v.path] = ts }
                }
            }
        }

        let command: ClingCommand = cancel ? .cancelIndex : .reindex
        let request = ClingRequest(command: command, rebuild: rebuild, scopes: scopes.isEmpty && volumes.isEmpty ? nil : scopes, paths: volumes.isEmpty ? nil : volumes)
        guard let data = try sendMachPort(data: JSONEncoder().encode(request), recvTimeout: 300) else {
            fputs("error: no response from Cling app\n", stderr)
            throw ExitCode.failure
        }
        guard let response = try? JSONDecoder().decode(ClingResponse.self, from: data) else {
            fputs("error: invalid response\n", stderr)
            throw ExitCode.failure
        }
        if let error = response.error {
            fputs("error: \(error)\n", stderr)
            throw ExitCode.failure
        }

        guard wait else {
            print(response.status ?? "indexing started")
            return
        }

        // Filter which scopes/volumes this wait invocation cares about.
        // Empty filter = wait on whatever was indexing globally.
        let scopeFilter = Set(scopes.map { $0.lowercased() })
        let volumeFilter = Set(volumes)
        let hasFilter = !scopeFilter.isEmpty || !volumeFilter.isEmpty

        // Must observe at least one "indexing" poll before exiting, to avoid
        // returning before the app picks up the reindex request. If we never see
        // indexing within a grace period, assume nothing was actually started.
        var sawIndexing = false
        var pollsWithoutIndexing = 0
        let gracePolls = 15

        fputs("indexing...", stderr)
        while true {
            Thread.sleep(forTimeInterval: 1)
            let statusReq = ClingRequest(command: .status)
            guard let statusData = try sendMachPort(data: JSONEncoder().encode(statusReq), recvTimeout: 5),
                  let statusResp = try? JSONDecoder().decode(ClingResponse.self, from: statusData)
            else { continue }

            let matchingScopes = (statusResp.scopes ?? []).filter { s in
                guard hasFilter else { return s.indexing }
                return scopeFilter.contains(s.rawValue.lowercased()) || scopeFilter.contains(s.name.lowercased())
            }
            let matchingVolumes = (statusResp.volumes ?? []).filter { v in
                guard hasFilter else { return v.indexing }
                return volumeFilter.contains(v.path) || volumeFilter.contains("/Volumes/\(v.name)")
            }

            let scopeParts = matchingScopes.compactMap { s -> String? in
                if let opCount = s.operationCount {
                    return "[\(s.name)] \(opCount.formatted()) files"
                }
                if let op = s.operation {
                    return "[\(s.name)] \(op)"
                }
                return nil
            }
            let volumeParts = matchingVolumes.compactMap { v -> String? in
                if let opCount = v.operationCount {
                    return "[\(v.name)] \(opCount.formatted()) files"
                }
                if let op = v.operation {
                    return "[\(v.name)] \(op)"
                }
                return nil
            }
            let progressLine = (scopeParts + volumeParts).joined(separator: "  ")
            let liveCount = matchingScopes.reduce(0) { $0 + ($1.operationCount ?? 0) }
                + matchingVolumes.reduce(0) { $0 + ($1.operationCount ?? 0) }
            let finalCount = matchingScopes.reduce(0) { $0 + $1.count } + matchingVolumes.reduce(0) { $0 + $1.count }
            let display = progressLine.isEmpty ? "indexing... \(finalCount.formatted()) entries" : progressLine
            fputs("\r\u{1B}[K\(display)", stderr)

            let anyScopeIndexing = matchingScopes.contains { $0.indexing }
            let anyVolumeIndexing = matchingVolumes.contains { $0.indexing }
            let state = statusResp.state ?? ""
            let globalIndexing = state == "indexing" || state == "background indexing"
            let stillIndexing = hasFilter ? (anyScopeIndexing || anyVolumeIndexing) : globalIndexing

            // Detect fast-completion: any matching scope/volume whose lastIndexedAt
            // is newer than our initial snapshot was reindexed during this wait.
            var completedFast = false
            if hasFilter, !stillIndexing, !sawIndexing {
                let scopesTracked = matchingScopes.filter { initialScopeTimestamps[$0.rawValue.lowercased()] != nil || $0.lastIndexedAt != nil }
                let volumesTracked = matchingVolumes.filter { initialVolumeTimestamps[$0.path] != nil || $0.lastIndexedAt != nil }
                let scopesDone = !scopesTracked.isEmpty && scopesTracked.allSatisfy { s in
                    guard let now = s.lastIndexedAt else { return false }
                    let before = initialScopeTimestamps[s.rawValue.lowercased()] ?? 0
                    return now > before
                }
                let volumesDone = volumesTracked.isEmpty || volumesTracked.allSatisfy { v in
                    guard let now = v.lastIndexedAt else { return false }
                    let before = initialVolumeTimestamps[v.path] ?? 0
                    return now > before
                }
                completedFast = scopesDone && volumesDone
            }

            if stillIndexing {
                sawIndexing = true
                pollsWithoutIndexing = 0
            } else {
                pollsWithoutIndexing += 1
            }
            if !stillIndexing, sawIndexing || completedFast {
                fputs("\n", stderr)
                let reportCount = finalCount > 0 ? finalCount : liveCount
                print("indexed: \(reportCount.formatted()) entries")
                break
            }
            if !sawIndexing, pollsWithoutIndexing >= gracePolls {
                fputs("\n", stderr)
                fputs("error: no indexing activity observed within \(gracePolls)s\n", stderr)
                throw ExitCode.failure
            }
        }
    }
}

// MARK: - Status

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show index status")

    @Flag(name: .long, help: "Output status as JSON")
    var json = false

    mutating func run() throws {
        let request = ClingRequest(command: .status)
        guard let data = try sendMachPort(data: JSONEncoder().encode(request), recvTimeout: 5) else {
            fputs("error: no response from Cling app\n", stderr)
            throw ExitCode.failure
        }
        guard let response = try? JSONDecoder().decode(ClingResponse.self, from: data) else {
            fputs("error: invalid response\n", stderr)
            throw ExitCode.failure
        }
        if let error = response.error {
            fputs("error: \(error)\n", stderr)
            throw ExitCode.failure
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let payload = ClingResponse(
                indexCount: response.indexCount,
                state: response.state,
                operation: response.operation,
                scopes: response.scopes,
                volumes: response.volumes
            )
            if let out = try? encoder.encode(payload), let str = String(data: out, encoding: .utf8) {
                print(str)
            }
        } else {
            print(response.status ?? "unknown")
        }
    }
}

// MARK: - Recents

struct Recents: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show default/recent results")

    @Option(name: .shortAndLong, help: "Max results")
    var count = 50

    mutating func run() throws {
        let request = ClingRequest(command: .recents, maxResults: count)
        guard let data = try sendMachPort(data: JSONEncoder().encode(request), recvTimeout: 5) else {
            fputs("error: no response from Cling app\n", stderr)
            throw ExitCode.failure
        }
        guard let response = try? JSONDecoder().decode(ClingResponse.self, from: data) else {
            fputs("error: invalid response\n", stderr)
            throw ExitCode.failure
        }
        if let error = response.error {
            fputs("error: \(error)\n", stderr)
            throw ExitCode.failure
        }
        guard let results = response.results, !results.isEmpty else {
            fputs("(no results)\n", stderr)
            return
        }
        for r in results {
            let display = r.isDir ? r.path + "/" : r.path
            print(display)
        }
    }
}

// MARK: - Index

struct Index: ParsableCommand {
    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add paths to the index")

        @Option(name: .long, parsing: .upToNextOption, help: "Restrict to specific scopes (home, library, applications, system, root)")
        var scope: [String] = []

        @Argument(parsing: .remaining, help: "Paths to add")
        var paths: [String]

        mutating func run() throws {
            let resolved = paths.map { ($0 as NSString).expandingTildeInPath }
            let request = ClingRequest(command: .indexAdd, scopes: scope.isEmpty ? nil : scope, paths: resolved)
            guard let data = try sendMachPort(data: JSONEncoder().encode(request)) else {
                fputs("error: no response from Cling app\n", stderr)
                throw ExitCode.failure
            }
            guard let response = try? JSONDecoder().decode(ClingResponse.self, from: data) else {
                fputs("error: invalid response\n", stderr)
                throw ExitCode.failure
            }
            if let error = response.error {
                fputs("error: \(error)\n", stderr)
                throw ExitCode.failure
            }
            print(response.status ?? "done")
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove paths from the index")

        @Option(name: .long, parsing: .upToNextOption, help: "Restrict to specific scopes (home, library, applications, system, root)")
        var scope: [String] = []

        @Argument(parsing: .remaining, help: "Paths to remove")
        var paths: [String]

        mutating func run() throws {
            let resolved = paths.map { ($0 as NSString).expandingTildeInPath }
            let request = ClingRequest(command: .indexRemove, scopes: scope.isEmpty ? nil : scope, paths: resolved)
            guard let data = try sendMachPort(data: JSONEncoder().encode(request)) else {
                fputs("error: no response from Cling app\n", stderr)
                throw ExitCode.failure
            }
            guard let response = try? JSONDecoder().decode(ClingResponse.self, from: data) else {
                fputs("error: invalid response\n", stderr)
                throw ExitCode.failure
            }
            if let error = response.error {
                fputs("error: \(error)\n", stderr)
                throw ExitCode.failure
            }
            print(response.status ?? "done")
        }
    }

    struct Has: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Check if paths are in the index")

        @Option(name: .long, parsing: .upToNextOption, help: "Restrict to specific scopes (home, library, applications, system, root)")
        var scope: [String] = []

        @Argument(parsing: .remaining, help: "Paths to check")
        var paths: [String]

        mutating func run() throws {
            let resolved = paths.map { ($0 as NSString).expandingTildeInPath }
            let request = ClingRequest(command: .indexHas, scopes: scope.isEmpty ? nil : scope, paths: resolved)
            guard let data = try sendMachPort(data: JSONEncoder().encode(request)) else {
                fputs("error: no response from Cling app\n", stderr)
                throw ExitCode.failure
            }
            guard let response = try? JSONDecoder().decode(ClingResponse.self, from: data) else {
                fputs("error: invalid response\n", stderr)
                throw ExitCode.failure
            }
            if let error = response.error {
                fputs("error: \(error)\n", stderr)
                throw ExitCode.failure
            }
            print(response.status ?? "done")
        }
    }

    static let configuration = CommandConfiguration(
        abstract: "Manage the search index",
        subcommands: [Add.self, Remove.self, Has.self]
    )

}
