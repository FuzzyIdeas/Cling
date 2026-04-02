import ArgumentParser
import Foundation

// MARK: - IPC Message Types (must match Cling app side)

let CLING_PORT_ID = "com.lowtechguys.Cling.cli" as CFString

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

// MARK: - CLI

@main
struct ClingCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cling",
        abstract: "Cling: fast fuzzy file search from the command line",
        subcommands: [Search.self, Reindex.self, Status.self, Recents.self, Index.self],
        defaultSubcommand: Search.self
    )
}

// MARK: - Search Command

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

// MARK: - Reindex Command

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
        """
    )

    @Flag(name: .shortAndLong, help: "Force full rebuild: delete persisted indexes and re-walk from scratch")
    var rebuild = false

    @Flag(name: .shortAndLong, help: "Wait for indexing to finish")
    var wait = false

    @Option(name: .shortAndLong, parsing: .upToNextOption, help: "Scopes to reindex (home, library, applications, system, root) or volume paths (/Volumes/...). Omit for all.")
    var scope: [String] = []

    mutating func run() throws {
        let volumes = scope.filter { $0.hasPrefix("/Volumes/") || $0.hasPrefix("/Volumes") }
        let scopes = scope.filter { !$0.hasPrefix("/Volumes") }
        let request = ClingRequest(command: .reindex, rebuild: rebuild, scopes: scopes.isEmpty && volumes.isEmpty ? nil : scopes, paths: volumes.isEmpty ? nil : volumes)
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

        fputs("indexing...", stderr)
        while true {
            Thread.sleep(forTimeInterval: 1)
            let statusReq = ClingRequest(command: .status)
            guard let statusData = try sendMachPort(data: JSONEncoder().encode(statusReq), recvTimeout: 5),
                  let statusResp = try? JSONDecoder().decode(ClingResponse.self, from: statusData)
            else { continue }

            fputs("\r\u{1B}[Kindexing... \(statusResp.indexCount ?? 0) entries", stderr)
            if statusResp.status != "indexing..." {
                fputs("\n", stderr)
                print("indexed: \(statusResp.indexCount ?? 0) entries")
                break
            }
        }
    }
}

// MARK: - Status Command

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show index status")

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
        if let error = response.error { fputs("error: \(error)\n", stderr) }
        else {
            print("indexed: \(response.indexCount ?? 0) entries")
            print("status: \(response.status ?? "unknown")")
        }
    }
}

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

// MARK: - Index Management Command

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
