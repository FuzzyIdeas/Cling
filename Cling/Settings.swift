import Combine
import Defaults
import Foundation
import Lowtech
import SwiftUI
import System

// MARK: - DefaultResultsMode

enum DefaultResultsMode: String, CaseIterable, Defaults.Serializable {
    case recentFiles = "Recent Files"
    case runHistory = "Run History"
    case empty = "Empty"
}

// MARK: - FilePath + Defaults.Serializable, @retroactive LosslessStringConvertible

extension FilePath: Defaults.Serializable, @retroactive LosslessStringConvertible {
    public init?(from defaultsValue: String) {
        self.init(defaultsValue)
    }

    public var defaultsValue: String {
        string
    }
}

// MARK: - Character + @retroactive Codable

extension Character: @retroactive Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard string.count == 1 else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "String too long")
        }
        self = string.first!
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(self))
    }
}

// MARK: - FolderFilter

struct FolderFilter: Identifiable, Hashable, Codable, Defaults.Serializable {
    init(id: String, folders: [FilePath], key: Character?, maxDepth: Int? = nil) {
        self.id = id
        self.folders = folders
        self.key = key
        self.maxDepth = maxDepth
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        folders = try container.decode([FilePath].self, forKey: .folders)
        key = try container.decodeIfPresent(Character.self, forKey: .key)
        maxDepth = try container.decodeIfPresent(Int.self, forKey: .maxDepth)
    }

    let id: String
    let folders: [FilePath]
    let key: Character?
    let maxDepth: Int?

    var keyEquivalent: KeyEquivalent? {
        key.map { KeyEquivalent($0) }
    }

    func withKey(_ key: Character?) -> FolderFilter {
        FolderFilter(id: id, folders: folders, key: key, maxDepth: maxDepth)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(folders, forKey: .folders)
        try container.encodeIfPresent(key, forKey: .key)
        try container.encodeIfPresent(maxDepth, forKey: .maxDepth)
    }

    private enum CodingKeys: String, CodingKey {
        case id, folders, key, maxDepth
    }
}

// MARK: - QuickFilter

struct QuickFilter: Identifiable, Hashable, Codable, Defaults.Serializable {
    // Migration: supports old "suffix"/"query" keys and very old ".app/$" format
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        key = try container.decodeIfPresent(Character.self, forKey: .key)
        postQuery = try container.decodeIfPresent(String.self, forKey: .postQuery)
        folders = try container.decodeIfPresent([FilePath].self, forKey: .folders)
        maxDepth = try container.decodeIfPresent(Int.self, forKey: .maxDepth)

        if container.contains(.extensions) {
            extensions = try container.decodeIfPresent(String.self, forKey: .extensions)
            preQuery = try container.decodeIfPresent(String.self, forKey: .preQuery)
            dirsOnly = try container.decodeIfPresent(Bool.self, forKey: .dirsOnly) ?? false
        } else if container.contains(.suffix) || container.contains(.dirsOnly) {
            // Previous format: suffix -> extensions, query -> preQuery
            extensions = try container.decodeIfPresent(String.self, forKey: .suffix)
            preQuery = try container.decodeIfPresent(String.self, forKey: .query)
            dirsOnly = try container.decodeIfPresent(Bool.self, forKey: .dirsOnly) ?? false
        } else if let oldQuery = try container.decodeIfPresent(String.self, forKey: .query) {
            let stripped = oldQuery.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "$", with: "")
            if stripped.hasSuffix("/") {
                dirsOnly = true
                let withoutSlash = String(stripped.dropLast())
                extensions = withoutSlash.isEmpty ? nil : withoutSlash
                preQuery = nil
            } else if stripped.hasPrefix(".") {
                extensions = stripped
                dirsOnly = false
                preQuery = nil
            } else {
                extensions = nil
                dirsOnly = false
                preQuery = stripped.isEmpty ? nil : stripped
            }
        } else {
            extensions = nil
            preQuery = nil
            dirsOnly = false
        }
    }

    init(id: String, extensions: String?, preQuery: String?, postQuery: String? = nil, dirsOnly: Bool, folders: [FilePath]? = nil, key: Character?, maxDepth: Int? = nil) {
        self.id = id
        self.extensions = extensions
        self.preQuery = preQuery
        self.postQuery = postQuery
        self.dirsOnly = dirsOnly
        self.folders = folders
        self.key = key
        self.maxDepth = maxDepth
    }

    let id: String
    let extensions: String? // e.g. ".png .jpeg" or ".mp4 | .mov"
    let preQuery: String? // prepended before user query
    let postQuery: String? // appended after user query
    let dirsOnly: Bool
    let folders: [FilePath]? // auto-applied folder filter when this quick filter is enabled
    let key: Character?
    let maxDepth: Int?

    var keyEquivalent: KeyEquivalent? {
        key.map { KeyEquivalent($0) }
    }

    var header: String {
        var parts = [String]()
        if let folders, !folders.isEmpty {
            parts.append("in \(folders.map { FuzzyClient.friendlyName(for: $0) }.joined(separator: ", "))")
        }
        return parts.joined(separator: ", ")
    }

    var subtitle: String {
        var parts = [String]()
        if let extensions {
            let exts = extensions.replacingOccurrences(of: "|", with: " ").replacingOccurrences(of: ",", with: " ")
                .split(separator: " ").filter { $0.hasPrefix(".") }.map { "*\($0)" }
            parts.append(exts.joined(separator: " "))
        }
        if dirsOnly { parts.append("dirs only") }
        if let preQuery { parts.append(preQuery) }
        if let postQuery { parts.append("...\(postQuery)") }
        if let folders, !folders.isEmpty {
            parts.append("in \(folders.map { FuzzyClient.friendlyName(for: $0) }.joined(separator: ", "))")
        }
        if let maxDepth { parts.append("depth ≤ \(maxDepth)") }
        return parts.joined(separator: ", ")
    }

    func withKey(_ key: Character?) -> QuickFilter {
        QuickFilter(id: id, extensions: extensions, preQuery: preQuery, postQuery: postQuery, dirsOnly: dirsOnly, folders: folders, key: key, maxDepth: maxDepth)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(extensions, forKey: .extensions)
        try container.encodeIfPresent(preQuery, forKey: .preQuery)
        try container.encodeIfPresent(postQuery, forKey: .postQuery)
        try container.encode(dirsOnly, forKey: .dirsOnly)
        try container.encodeIfPresent(folders, forKey: .folders)
        try container.encodeIfPresent(key, forKey: .key)
        try container.encodeIfPresent(maxDepth, forKey: .maxDepth)
    }

    private enum CodingKeys: String, CodingKey {
        case id, extensions, preQuery, postQuery, dirsOnly, folders, key, maxDepth
        case suffix, query // legacy keys for decoding only
    }

}

extension String {
    var keyEquivalent: KeyEquivalent? {
        guard let key = first else { return nil }
        return KeyEquivalent(key)
    }
}

let ICLOUD_PATH: FilePath = HOME / "Library" / "Mobile Documents" / "com~apple~CloudDocs"

let DEFAULT_FOLDER_FILTERS = [
    FolderFilter(id: "Applications", folders: ["/Applications".filePath!, "/System/Applications".filePath!, HOME / "Applications"], key: "a"),
    FolderFilter(id: "Home", folders: [HOME], key: "h"),
    FolderFilter(id: "Documents", folders: [HOME / "Documents", HOME / "Desktop", HOME / "Downloads"], key: "d"),
    FolderFilter(id: "iCloud", folders: [ICLOUD_PATH], key: "i"),
    FolderFilter(id: "System", folders: ["/System".filePath!], key: "s"),
]

let USER_CONTENT_FOLDERS: [FilePath] = [
    HOME / "Documents", HOME / "Desktop", HOME / "Downloads",
    HOME / "Pictures", HOME / "Movies", HOME / "Music",
    ICLOUD_PATH,
]

let DEFAULT_QUICK_FILTERS = [
    QuickFilter(
        id: "Apps",
        extensions: ".app",
        preQuery: nil,
        dirsOnly: true,
        folders: ["/Applications".filePath!, "/System/Applications".filePath!, HOME / "Applications"],
        key: "a"
    ),
    QuickFilter(id: "Folders", extensions: nil, preQuery: nil, dirsOnly: true, key: "f"),
    QuickFilter(
        id: "Images",
        extensions: ".png .jpg .jpeg .gif .webp .heic .tiff .bmp .svg .ico .avif",
        preQuery: nil,
        dirsOnly: false,
        folders: [HOME, ICLOUD_PATH],
        key: "i"
    ),
    QuickFilter(
        id: "Videos",
        extensions: ".mp4 .mov .mkv .avi .webm .m4v .wmv",
        preQuery: nil,
        dirsOnly: false,
        folders: [HOME, ICLOUD_PATH],
        key: "v"
    ),
    QuickFilter(
        id: "Audio",
        extensions: ".mp3 .aac .flac .wav .m4a .ogg .aiff .wma",
        preQuery: nil,
        dirsOnly: false,
        folders: [HOME, ICLOUD_PATH],
        key: "u"
    ),
    QuickFilter(
        id: "Documents",
        extensions: ".pdf .doc .docx .xls .xlsx .ppt .pptx .pages .numbers .keynote .txt .rtf .csv .md",
        preQuery: nil,
        dirsOnly: false,
        folders: [HOME, ICLOUD_PATH],
        key: "d"
    ),
    QuickFilter(
        id: "Archives",
        extensions: ".zip .tar .gz .bz2 .7z .rar .dmg .iso .xz .tgz",
        preQuery: nil,
        dirsOnly: false,
        folders: [HOME, ICLOUD_PATH],
        key: "z"
    ),
    QuickFilter(
        id: "Code",
        extensions: ".swift .py .js .ts .go .rs .c .cpp .h .java .rb .sh .css .html .sql",
        preQuery: nil,
        dirsOnly: false,
        folders: [HOME],
        key: "c"
    ),
    QuickFilter(
        id: "Config",
        extensions: ".json .yaml .yml .xml .toml .plist .ini .cfg .conf .env .fish .zsh .bash .zshrc .bashrc",
        preQuery: nil,
        dirsOnly: false,
        folders: [HOME / ".config", "/etc".filePath!, HOME / "Library/Preferences"],
        key: "g"
    ),
    QuickFilter(
        id: "PDFs",
        extensions: ".pdf",
        preQuery: nil,
        dirsOnly: false,
        folders: [HOME, ICLOUD_PATH],
        key: "p"
    ),
    QuickFilter(id: "Xcode Projects", extensions: ".xcodeproj .xcworkspace", preQuery: nil, dirsOnly: true, folders: [HOME], key: "x"),
]

// MARK: - Toolbar knob enums

enum ToolbarLabelStyle: String, Codable, Defaults.Serializable, CaseIterable { case iconAndText, textOnly, iconOnly }
enum ToolbarDensity: String, Codable, Defaults.Serializable, CaseIterable { case regular, compact }
enum ToolbarOverflowMode: String, Codable, Defaults.Serializable, CaseIterable { case auto, always, off }
enum ToolbarShortcutHint: String, Codable, Defaults.Serializable, CaseIterable { case tooltip, menuAndTooltip, never }

extension ToolbarDensity {
    var fontSize: CGFloat { self == .compact ? 9 : 10 }
    var spacing: CGFloat { self == .compact ? 6 : 8 }
}

// MARK: - HiddenActionButton

enum HiddenActionButton: String, CaseIterable, Defaults.Serializable {
    case open
    case showInFinder
    case pasteToFrontmost
    case openInTerminal
    case openInEditor
    case shelve
    case moveTo
    case copy
    case copyPaths
    case trash
    case quicklook
    case rename

    var label: String {
        switch self {
        case .open: "Open (⏎)"
        case .showInFinder: "Show in Finder (⌘⏎)"
        case .pasteToFrontmost: "Paste to frontmost app (⌘⇧⏎)"
        case .openInTerminal: "Open in Terminal (⌘T)"
        case .openInEditor: "Open in Editor (⌘E)"
        case .shelve: "Shelve (⌘S)"
        case .moveTo: "Move to… (⌘M)"
        case .copy: "Copy (⌘C)"
        case .copyPaths: "Copy paths (⌘⇧C)"
        case .trash: "Trash (⌘⌫)"
        case .quicklook: "Quicklook (⎵)"
        case .rename: "Rename (⌘R)"
        }
    }

}

// MARK: - SearchScope

enum SearchScope: String, CaseIterable, Defaults.Serializable {
    case home
    case library
    case applications
    case system
    case root

    var label: String {
        switch self {
        case .home: "Home"
        case .library: "Library"
        case .applications: "Applications"
        case .system: "System"
        case .root: "Root (/usr, /bin, /etc, ...)"
        }
    }

    var binding: Binding<Bool> {
        Binding(
            get: { Defaults[.searchScopes].contains(self) },
            set: { enabled in
                if enabled {
                    Defaults[.searchScopes].append(self)
                } else {
                    Defaults[.searchScopes].removeAll { $0 == self }
                }
            }
        )
    }
}

// MARK: - WindowAppearance

enum WindowAppearance: String, CaseIterable, Defaults.Serializable {
    case glassy = "Glassy"
    case vibrant = "Vibrant"
    case opaque = "Opaque"

    static var defaultValue: WindowAppearance {
        if #available(macOS 26, *) { return .glassy }
        return .vibrant
    }

    var isGlassy: Bool { self == .glassy }
    var isVibrant: Bool { self == .vibrant }
    var isOpaque: Bool { self == .opaque }

    var available: Bool {
        if self == .glassy {
            if #available(macOS 26, *) { return true }
            return false
        }
        return true
    }
}

let KNOWN_SHELF_APPS = [
    "at.EternalStorms.Yoink",
    "at.EternalStorms.Yoink-setapp",
    "me.damir.dropover-mac",
    "com.hachipoo.Dockside",
]

func detectShelfApp() -> String {
    for bundleID in KNOWN_SHELF_APPS {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.path
        }
    }
    return ""
}

extension Defaults.Keys {
    static let suppressTrashConfirm = Key<Bool>("suppressTrashConfirm", default: false)
    static let editorApp = Key<String>("editorApp", default: "/System/Applications/TextEdit.app")
    static let terminalApp = Key<String>("terminalApp", default: "/System/Applications/Utilities/Terminal.app")
    static let shelfApp = Key<String>("shelfApp", default: detectShelfApp())
    static let showWindowAtLaunch = Key<Bool>("showWindowAtLaunch", default: true)
    static let showDockIcon = Key<Bool>("showDockIcon", default: false)
    static let keepWindowOpenWhenDefocused = Key<Bool>("keepWindowOpenWhenDefocused", default: false)
    static let instantMode = Key<Bool>("instantMode", default: true)
    static let defaultResultsMode = Key<DefaultResultsMode>("defaultResultsMode", default: .recentFiles)
    static let showSearchHints = Key<Bool>("showSearchHints", default: true)
    static let searchHintsManuallyEnabled = Key<Bool>("searchHintsManuallyEnabled", default: false)
    static let searchHintsFirstShownAt = Key<TimeInterval>("searchHintsFirstShownAt", default: 0)

    static let showActionRow = Key<Bool>("showActionRow", default: true)
    static let showOpenWithRow = Key<Bool>("showOpenWithRow", default: true)
    static let showScriptRow = Key<Bool>("showScriptRow", default: true)
    static let showFilePreview = Key<Bool>("showFilePreview", default: true)
    static let hiddenActionButtons = Key<[HiddenActionButton]>("hiddenActionButtons", default: [])
    static let folderFilters = Key<[FolderFilter]>("folderFilters", default: DEFAULT_FOLDER_FILTERS)
    static let maxResultsCount = Key<Int>("maxResultsCount", default: 1000)
    static let externalVolumes = Key<[FilePath]>("externalVolumes", default: [])
    static let disabledVolumes = Key<[FilePath]>("disabledVolumes", default: [])
    static let indexedVolumePaths = Key<[FilePath]>("indexedVolumePaths", default: [])
    static let copyPathsWithTilde = Key<Bool>("copyPathsWithTilde", default: true)
    static let fileOpDestinations = Key<[String: String]>("fileOpDestinations", default: [:])

    static let enableGlobalHotkey = Key<Bool>("enableGlobalHotkey", default: true)
    static let showAppKey = Key<SauceKey>("showAppKey", default: SauceKey.slash)
    static let triggerKeys = Key<[TriggerKey]>("triggerKeys", default: [.rcmd])

    static let searchScopes = Key<[SearchScope]>("searchScopes", default: [.home, .library, .applications, .system, .root])
    static let quickFilters = Key<[QuickFilter]>("quickFilters", default: DEFAULT_QUICK_FILTERS)
    static let reindexTimeIntervalPerVolume = Key<[FilePath: Double]>("reindexTimeIntervalPerVolume", default: [:])
    static let windowAppearance = Key<WindowAppearance>("windowAppearance", default: WindowAppearance.defaultValue)
    static let migrationVersion = Key<Int>("migrationVersion", default: 0)
    static let onboardingCompleted = Key<Bool>("onboardingCompleted", default: false)
    /// When on, the indexer applies each project's own `.gitignore`/`.ignore` files while walking the Home
    /// scope, so build output is excluded per project. Off by default (some gitignored files are worth finding).
    static let honorGitignore = Key<Bool>("honorGitignore", default: false)

    // Lines starting with "#" are comments. "#:group id=… name=…" headers mark a block of rules so a future
    // settings UI can toggle whole groups; rules you add yourself land under "#:custom". Both are ignored by
    // the parser (PathBlocklist.split skips "#" and blank lines). Prefixes match the start of an absolute path.
    static let blockedPrefixes = Key<String>("blockedPrefixes", default: """
    #:group id=ephemeral name=Temporary & ephemeral
    /tmp/com.apple.
    /var/folders/
    /private/var/vm/
    /cores/

    #:group id=shared name=System shared data
    /usr/share/

    #:custom name=Your rules
    """)
    // Contains rules match anywhere inside an absolute path (directory prune).
    static let blockedContains = Key<String>("blockedContains", default: """
    #:group id=cling-internal name=Cling internal
    -Users-

    #:group id=vcs name=Version control
    /.git/
    /.svn/
    /.hg/

    #:group id=app-bundles name=App bundle internals
    .app/Contents/Resources/
    .app/Contents/PlugIns/
    .app/Contents/_CodeSignature/
    .app/Contents/SharedSupport/
    .lproj/

    #:group id=apple-metadata name=System metadata
    /.Spotlight-V100/
    /.fseventsd/
    /.DocumentRevisions-V100/
    /.TemporaryItems/

    #:group id=trash name=Trash
    /.Trash/

    #:group id=caches name=Caches
    /.cache/

    #:group id=build-output name=Build output
    /build/
    /target/
    /.build/
    /DerivedData/
    /.swiftpm/
    /xcuserdata/

    #:group id=dependencies name=Dependencies & package caches
    /node_modules/
    /__pycache__/
    /.venv/
    /.tox/
    /Pods/
    /Carthage/
    /.gradle/
    /.terraform/

    #:group id=databases name=Database data
    /var/postgres/

    #:custom name=Your rules
    """)

    static let toolbarLabelStyle       = Key<ToolbarLabelStyle>("toolbarLabelStyle", default: .iconAndText)
    static let toolbarDensity          = Key<ToolbarDensity>("toolbarDensity", default: .regular)
    static let toolbarShowDividers     = Key<Bool>("toolbarShowDividers", default: true)
    static let toolbarOverflowMode     = Key<ToolbarOverflowMode>("toolbarOverflowMode", default: .auto)
    static let toolbarRowBackground    = Key<Bool>("toolbarRowBackground", default: true)
    static let toolbarShortcutHint     = Key<ToolbarShortcutHint>("toolbarShortcutHint", default: .menuAndTooltip)
    static let barActions              = Key<[ActionID]>("barActions", default: ToolbarAction.defaultBar)
    static let hiddenActions           = Key<Set<ActionID>>("hiddenActions", default: [])
    static let didMigrateHiddenActions = Key<Bool>("didMigrateHiddenActions", default: false)
    static let defaultLinkExpiration   = Key<TimeInterval>("defaultLinkExpiration", default: 3600)
    static let shortcutsCoachmarkShown = Key<Bool>("shortcutsCoachmarkShown", default: false)
}

// MARK: - hiddenActionButtons → hiddenActions migration

func migrateHiddenActionButtonsIfNeeded() {
    guard !Defaults[.didMigrateHiddenActions] else { return }
    let map: [HiddenActionButton: ActionID] = [
        .open: .open,
        .showInFinder: .showInFinder,
        .pasteToFrontmost: .pasteToFrontmost,
        .openInTerminal: .openInTerminal,
        .openInEditor: .openInEditor,
        .shelve: .shelve,
        .moveTo: .moveTo,
        .copy: .copy,
        .copyPaths: .copyPaths,
        .trash: .trash,
        .quicklook: .quickLook,
        .rename: .rename,
    ]
    Defaults[.hiddenActions] = Set(Defaults[.hiddenActionButtons].compactMap { map[$0] })
    Defaults[.didMigrateHiddenActions] = true
}

// MARK: - DefaultsCache

@MainActor
@Observable
final class DefaultsCache {
    private init() {
        folderFilters = Defaults[.folderFilters]
        quickFilters = Defaults[.quickFilters]
        searchScopes = Defaults[.searchScopes]

        pub(.folderFilters)
            .receive(on: RunLoop.main)
            .sink { [self] change in folderFilters = change.newValue }
            .store(in: &observers)

        pub(.quickFilters)
            .receive(on: RunLoop.main)
            .sink { [self] change in quickFilters = change.newValue }
            .store(in: &observers)

        pub(.searchScopes)
            .receive(on: RunLoop.main)
            .sink { [self] change in searchScopes = change.newValue }
            .store(in: &observers)
    }

    static let shared = DefaultsCache()

    var folderFilters: [FolderFilter]
    var quickFilters: [QuickFilter]
    var searchScopes: [SearchScope]

    @ObservationIgnored private var observers: Set<AnyCancellable> = []

}

let DEFAULTS_CACHE = DefaultsCache.shared
