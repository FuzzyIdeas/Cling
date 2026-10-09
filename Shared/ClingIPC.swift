import Foundation

// MARK: - Shared IPC Message Types

//
// These types are used by both the Cling app (server) and the ClingCLI tool (client)
// to exchange requests and responses over a Mach port. Any change here must be
// source-compatible across both targets.

public let CLING_PORT_ID = "com.lowtechguys.Cling.cli" as CFString

// MARK: - ClingCommand

public enum ClingCommand: String, Codable {
    case search
    case index // backwards compat
    case reindex
    case cancelIndex
    case status
    case recents
    case indexAdd
    case indexRemove
    case indexHas
    case explain
    /// Ranks one query the way the engines do and says where a path landed and why.
    case why
    case settings
    case filters
    case scripts
    case volumes
    /// iCloud Drive and the folders in ~/Library/CloudStorage.
    case cloud
    case scopes
    case ignore
    case shortcuts
    /// The Everything index's switch and its saved files.
    case everything
    /// Opens paths the way the toolbar does: in their app, in Finder, the terminal, the editor or on the shelf
    /// (`action`), and counts them as runs.
    case open
    /// What the live index recorded lately, as the window's live changes pane lists it.
    case changes
}

// MARK: - ClingRequest

public struct ClingRequest: Codable {
    public init(
        command: ClingCommand,
        query: String? = nil,
        maxResults: Int? = nil,
        verbose: Bool? = nil,
        rebuild: Bool? = nil,
        dir: String? = nil,
        suffixPattern: String? = nil,
        folderPrefixes: [String]? = nil,
        dirsOnly: Bool? = nil,
        scopes: [String]? = nil,
        paths: [String]? = nil,
        everything: Bool? = nil,
        action: String? = nil,
        key: String? = nil,
        value: String? = nil,
        payload: String? = nil,
        quickFilter: String? = nil,
        folderFilter: String? = nil,
        allDrives: Bool? = nil,
        searchBar: Bool? = nil,
        since: Double? = nil
    ) {
        self.command = command
        self.query = query
        self.maxResults = maxResults
        self.verbose = verbose
        self.rebuild = rebuild
        self.dir = dir
        self.suffixPattern = suffixPattern
        self.folderPrefixes = folderPrefixes
        self.dirsOnly = dirsOnly
        self.scopes = scopes
        self.paths = paths
        self.everything = everything
        self.action = action
        self.key = key
        self.value = value
        self.payload = payload
        self.quickFilter = quickFilter
        self.folderFilter = folderFilter
        self.allDrives = allDrives
        self.searchBar = searchBar
        self.since = since
    }

    public let command: ClingCommand
    public var query: String?
    public var maxResults: Int?
    public var verbose: Bool?
    public var rebuild: Bool?
    public var dir: String?
    public var suffixPattern: String?
    public var folderPrefixes: [String]?
    public var dirsOnly: Bool?
    public var scopes: [String]?
    public var paths: [String]?
    /// Search the Everything index (every file on the local disks) instead of the normal one.
    public var everything: Bool?
    /// What a configuration command should do: list, show, write, delete, set and so on.
    public var action: String?
    public var key: String?
    public var value: String?
    /// A JSON-encoded spec for the writes that carry more than a key and a value (filters, scripts).
    public var payload: String?
    /// Saved filters to apply the way the search window does, so a search complaint can be reproduced.
    public var quickFilter: String?
    public var folderFilter: String?
    /// Search only the saved index of every external drive, connected or not, the way the window's External drives
    /// filter does.
    public var allDrives: Bool?
    /// Order the results as the search bar does, with apps among the first ones moved to the top.
    public var searchBar: Bool?
    /// Epoch seconds: only what happened after this.
    public var since: Double?
    /// `mcp` when the call came through the bundled MCP server. The app refuses changes carrying it until
    /// the user allows them; a person running the CLI needs no permission from anyone.
    public var origin: String?

}

// MARK: - ClingSearchResult

public struct ClingSearchResult: Codable {
    public init(path: String, isDir: Bool, score: Int, quality: Int) {
        self.path = path
        self.isDir = isDir
        self.score = score
        self.quality = quality
    }

    public let path: String
    public let isDir: Bool
    public let score: Int
    public let quality: Int

}

// MARK: - ClingScopeStatus

public struct ClingScopeStatus: Codable {
    public init(
        name: String,
        rawValue: String,
        enabled: Bool,
        indexed: Bool,
        indexing: Bool,
        count: Int,
        operation: String? = nil,
        operationCount: Int? = nil,
        lastIndexedAt: Double? = nil
    ) {
        self.name = name
        self.rawValue = rawValue
        self.enabled = enabled
        self.indexed = indexed
        self.indexing = indexing
        self.count = count
        self.operation = operation
        self.operationCount = operationCount
        self.lastIndexedAt = lastIndexedAt
    }

    public let name: String
    public let rawValue: String
    public let enabled: Bool
    public let indexed: Bool
    public let indexing: Bool
    public let count: Int
    public var operation: String?
    public var operationCount: Int?
    /// Epoch seconds of the last successful reindex for this scope. Lets callers detect
    /// a fast reindex that completed between the request and the first status poll.
    public var lastIndexedAt: Double?

}

// MARK: - ClingVolumeStatus

public struct ClingVolumeStatus: Codable {
    public init(
        name: String,
        path: String,
        enabled: Bool,
        indexed: Bool,
        indexing: Bool,
        count: Int,
        operation: String? = nil,
        operationCount: Int? = nil,
        lastIndexedAt: Double? = nil,
        following: String? = nil,
        health: String? = nil
    ) {
        self.name = name
        self.path = path
        self.enabled = enabled
        self.indexed = indexed
        self.indexing = indexing
        self.count = count
        self.operation = operation
        self.operationCount = operationCount
        self.lastIndexedAt = lastIndexedAt
        self.following = following
        self.health = health
    }

    public let name: String
    public let path: String
    public let enabled: Bool
    public let indexed: Bool
    public let indexing: Bool
    public let count: Int
    public var operation: String?
    public var operationCount: Int?
    public var lastIndexedAt: Double?
    /// "following" while the drive's changes are followed into its index, "catching up" while it replays what changed
    /// since its index was saved; nil when it isn't followed.
    public var following: String?
    /// "healthy", "slow" or "struggling": how following the drive has gone over the last 10 minutes, while it is.
    public var health: String?

}

// MARK: - ClingResponse

public struct ClingResponse: Codable {
    public init(
        results: [ClingSearchResult]? = nil,
        status: String? = nil,
        error: String? = nil,
        indexCount: Int? = nil,
        searchMs: Double? = nil,
        state: String? = nil,
        operation: String? = nil,
        scopes: [ClingScopeStatus]? = nil,
        volumes: [ClingVolumeStatus]? = nil,
        everything: String? = nil,
        everythingCount: Int? = nil,
        everythingWalked: Int? = nil,
        payload: String? = nil
    ) {
        self.results = results
        self.status = status
        self.error = error
        self.indexCount = indexCount
        self.searchMs = searchMs
        self.state = state
        self.operation = operation
        self.scopes = scopes
        self.volumes = volumes
        self.everything = everything
        self.everythingCount = everythingCount
        self.everythingWalked = everythingWalked
        self.payload = payload
    }

    public var results: [ClingSearchResult]?
    public var status: String?
    public var error: String?
    public var indexCount: Int?
    public var searchMs: Double?
    public var state: String?
    public var operation: String?
    public var scopes: [ClingScopeStatus]?
    public var volumes: [ClingVolumeStatus]?
    /// State of the Everything index: off, unloaded, loading, indexing or ready.
    public var everything: String?
    public var everythingCount: Int?
    /// Entries a walk of the Everything index has reached so far. A walk that replaces a loaded index fills a new
    /// one, and `everythingCount` stays the size of the one still searched until it does.
    public var everythingWalked: Int?
    /// The configuration commands' answer as JSON, for `--json` and the MCP server. `status` carries the
    /// same answer worded for a terminal.
    public var payload: String?

}
