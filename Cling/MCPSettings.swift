import AppKit
import Defaults
import Foundation
import LaunchAtLogin
import Lowtech

extension Defaults.Keys {
    /// Whether agents may change things through the MCP server. Reading works either way; this is the
    /// switch for everything that writes. Sticks across launches, see `MCPInstaller`.
    static let mcpEnabled = Key<Bool>("mcpEnabled", default: false)
    /// Whether an agent may write a script's code. Separate from `mcpEnabled` because a script is arbitrary
    /// code that runs on the user's files, which is a sharper edge than changing a setting.
    static let mcpAllowScripts = Key<Bool>("mcpAllowScripts", default: false)
}

// MARK: - MCPSettingRow

/// Where a setting lives on screen and what it is called there.
///
/// Clop takes this from the index behind its Settings search field. Cling's Settings window has no such
/// index, so the titles and subtitles are copied from the panes and have to follow them when they change.
struct MCPSettingRow {
    /// nil for a setting with no row in Settings, which only a shortcut or the window itself changes.
    var pane: SettingsCategory?
    var section = ""
    var title: String
    /// The row's own detail text, verbatim. Empty when the row has none.
    var subtitle = ""
    /// For the agent only: what the row cannot say on screen. A consequence, a constraint, or where the
    /// control actually is.
    var note = ""
    var keywords: [String] = []
    /// Shows or hides part of the interface. `cling_ui_settings` lists exactly these.
    var ui = false
}

// MARK: - MCPSettingKey

/// One setting, typed. The closures capture the real `Defaults.Key`, so the type, the accepted values and
/// the write all come from the declaration the app itself reads.
struct MCPSettingKey {
    let name: String
    let type: String
    let allowed: [String]?
    let row: MCPSettingRow
    let read: @MainActor () -> String
    /// Returns nil on success, an explanation on a rejected value.
    let write: @MainActor (String) -> String?
}

// MARK: - MCPSettingInfo

/// One setting as an agent sees it: what it is called on screen, what it holds, and what it accepts.
struct MCPSettingInfo: Codable {
    let key: String
    let type: String
    let value: String
    let allowed: [String]?
    let title: String
    let subtitle: String
    let note: String
    let pane: String
    let section: String
    let ui: Bool
}

// MARK: - MCPSettingsBridge

/// Settings discovery for agents, and the reads and writes behind it.
///
/// Same job as Clop's `MCPSettingsBridge`; keep the two in step. Settings that need more than one value
/// (scopes, volumes, ignore rules, filters, scripts, shortcuts) have their own commands instead, and
/// `Scripts/settings-index-audit.py` holds the list of which keys went where.
enum MCPSettingsBridge {
    // MARK: - Key registry

    @MainActor static let keys: [MCPSettingKey] = [
        // General
        launchAtLogin(row(.general, "", "Launch at login")),
        bool("showDockIcon", .showDockIcon, row(
            .general, "", "Show Dock icon",
            subtitle: "Show Cling in the Dock as a regular app.",
            note: "Window mode in Settings sets this together with keepWindowOpenWhenDefocused: Utility is both off, Desktop App is both on.",
            keywords: ["window mode", "utility", "desktop app", "dock"], ui: true
        )) { on in
            NSApp.setActivationPolicy(on ? .regular : .accessory)
        },
        bool("showMenuBarIcon", .showMenuBarIcon, row(
            .general, "", "Show menu bar icon",
            subtitle: "Click it to summon Cling, click again to hide it.",
            keywords: ["status item", "menubar"], ui: true
        )),
        bool("keepWindowOpenWhenDefocused", .keepWindowOpenWhenDefocused, row(
            .general, "", "Keep window open when app is in background",
            subtitle: "Don't close the window when clicking outside the app.",
            keywords: ["window mode", "hide", "defocus", "click outside"]
        )),
        rawValue("windowDisplay", .windowDisplay, row(.general, "Window", "Show window on", keywords: ["display", "screen", "monitor"])),
        rawValue("windowPosition", .windowPosition, row(
            .general, "Window", "Window position",
            note: "cursor only applies while windowDisplay is cursor; on any other display it acts as centered.",
            keywords: ["center", "position"]
        )),
        bool("showWindowAtLaunch", .showWindowAtLaunch, row(
            .general, "Window", "Show window at launch",
            subtitle: "Show the main window when Cling is first launched.", ui: true
        )),
        presets("resetSelectionAfter", .resetSelectionAfter, SELECTION_RESET_PRESETS, row(
            .general, "Window", "Reset selection after",
            note: "Seconds Cling spends in the background before the selection jumps back to the first row. 0 keeps it forever.",
            keywords: ["selection", "first row"]
        )),
        bool("enableGlobalHotkey", .enableGlobalHotkey, row(
            .general, "Global Hotkey", "Enable global hotkey",
            subtitle: "Summon Cling from anywhere with a keyboard shortcut.",
            keywords: ["shortcut", "summon", "show", "hotkey"]
        )),
        showAppKey(row(
            .general, "Global Hotkey", "Hotkey",
            note: "The key half of the global hotkey. triggerKeys holds the modifiers.",
            keywords: ["shortcut", "summon", "key"]
        )),
        triggerKeys(row(
            .general, "Global Hotkey", "Hotkey",
            note: "The modifier half of the global hotkey, as a list. rcmd alone means pressing right Command and the key. Left and right sides are told apart, except by cmd, alt, ctrl and shift, which match either side and turn on Side-independent modifiers in Settings.",
            keywords: ["shortcut", "summon", "modifier", "command", "option"]
        )),

        // Style
        rawValue("hotkeyTarget", .hotkeyTarget, row(
            .interface, "Interface", "Interface",
            note: "What the global hotkey, the Dock icon and the menu bar icon bring up: the search window, or the floating search bar.",
            keywords: ["search bar", "window", "spotlight", "floating"], ui: true
        )),
        rawValue("searchBarDefaultResults", .searchBarDefaultResults, row(
            .interface, "Interface", "Default results",
            note: "The search bar's own default results. The window's are defaultResultsMode. Empty opens the bar as a lone field.",
            keywords: ["search bar", "recent", "empty"], ui: true
        )),
        bool("searchBarPinned", .searchBarPinned, row(
            .interface, "Interface", "Pin to desktop",
            note: "Only shown while hotkeyTarget is searchBar. Keeps the compact field on screen while the bar is collapsed.",
            keywords: ["search bar", "pin", "desktop"], ui: true
        )),
        bool("searchBarAboveWindows", .searchBarAboveWindows, row(
            .interface, "Interface", "Keep above windows",
            note: "Only shown while searchBarPinned is on. Off puts the pinned field on the desktop, under every window.",
            keywords: ["search bar", "floating", "level"], ui: true
        )),
        rawValue("windowAppearance", .windowAppearance, row(
            .interface, "Window", "Window style",
            subtitle: "Choose the window background appearance.",
            note: "Glassy needs macOS 26.",
            keywords: ["glass", "vibrancy", "opaque", "background", "transparency"], ui: true
        )) { (value: WindowAppearance) in
            value.available ? nil : "Glassy needs macOS 26"
        },
        double("fontScale", .fontScale, FontScale.range, row(
            .interface, "Window", "Text size",
            subtitle: "\u{2318}+ / \u{2318}- to change, \u{2318}0 to reset",
            note: "1 is the system size.",
            keywords: ["font", "bigger", "smaller", "zoom"], ui: true
        )),
        bool("dimStatusBar", .dimStatusBar, row(
            .interface, "Window", "Dim status bar",
            note: "Fades the window's status bar and the search bar's hint bar until the pointer reaches them.",
            keywords: ["status bar", "hints", "fade"], ui: true
        )),
        double("filterWindowTintStrength", .filterWindowTintStrength, 0 ... 1, row(
            .interface, "Window", "Tint strength when a filter is active",
            note: "Applies to the window and the search bar. 0 turns the tint off and leaves only the filter's coloured icon.",
            keywords: ["filter", "colour", "color", "wash"], ui: true
        )),
        bool("showFilePreview", .showFilePreview, row(
            title: "File preview",
            note: "The preview panel beside the window's results. Not in Settings: toggled with the Toggle Preview shortcut (⌘⇧P by default).",
            keywords: ["preview", "quicklook", "panel", "sidebar"], ui: true
        )),
        bool("searchBarShowPreview", .searchBarShowPreview, row(
            title: "Search bar preview",
            note: "The search bar's own preview panel. Not in Settings: toggled from the search bar.",
            keywords: ["preview", "search bar", "panel"], ui: true
        )),

        // Action Bar
        bool("showActionRow", .showActionRow, row(
            .actionBar, "Rows", "Action Bar row",
            subtitle: "The bar of buttons under the results: Open, Copy, Trash, Rename, etc.",
            keywords: ["toolbar", "buttons", "actions"], ui: true
        )),
        bool("showOpenWithRow", .showOpenWithRow, row(
            .actionBar, "Rows", "Open With row",
            subtitle: "Quick app shortcuts for opening the selected files.",
            keywords: ["apps", "open with"], ui: true
        )),
        bool("showScriptRow", .showScriptRow, row(
            .actionBar, "Rows", "Scripts row",
            subtitle: "Run scripts on the selected files.",
            note: "The row only appears with Cling Pro, whatever this says.",
            keywords: ["scripts"], ui: true
        )),
        rawValue("rowsToggleModifier", .rowsToggleModifier, row(
            .actionBar, "Rows", "Toggle all rows by double-tapping",
            subtitle: "Double-tap this modifier key to instantly hide or show all three rows at once.",
            keywords: ["double tap", "hide rows", "modifier"], ui: true
        )),
        bool("toolbarRowsHidden", .toolbarRowsHidden, row(
            title: "All rows hidden",
            note: "What the double-tap in rowsToggleModifier flips. On hides the Action Bar, Open With and Scripts rows together without touching their own settings, so it is the first thing to check when the rows are missing but their settings say on.",
            keywords: ["missing", "toolbar", "rows", "hidden", "action bar"], ui: true
        )),
        rawValue("toolbarLabelStyle", .toolbarLabelStyle, row(.actionBar, "Action Bar styling", "Labels", keywords: ["icons", "text"], ui: true)),
        rawValue("toolbarDensity", .toolbarDensity, row(.actionBar, "Action Bar styling", "Density", keywords: ["compact"], ui: true)),
        bool("showActionMenu", .showActionMenu, row(
            .actionBar, "", "Show Action Menu",
            subtitle: "The \u{22EF} menu holds actions you keep out of the bar. Shows only when there are overflow actions.",
            keywords: ["overflow", "more", "ellipsis"], ui: true
        )),
        bool("toolbarShowDividers", .toolbarShowDividers, row(
            .actionBar, "", "Show segment dividers",
            subtitle: "Thin separators between action groups", ui: true
        )),
        bool("toolbarRowBackground", .toolbarRowBackground, row(
            .actionBar, "", "Show row background",
            subtitle: "Show the material behind the action row", ui: true
        )),
        presets("defaultLinkExpiration", .defaultLinkExpiration, LINK_EXPIRATION_PRESETS, row(
            .actionBar, "Send Securely", "Default link expiration",
            note: "Seconds.", keywords: ["send", "share", "link", "expire"]
        )),
        actionList(row(
            .actionBar, "Open", "Action Bar",
            note: "The actions shown as buttons in the Action Bar, in order. An action in neither barActions nor hiddenActions sits in the ⋯ Action Menu.",
            keywords: ["toolbar", "buttons", "placement", "action menu"], ui: true
        )),
        hiddenActionSet(row(
            .actionBar, "Open", "Hidden",
            note: "Actions hidden from both the Action Bar and the ⋯ Action Menu. Their keyboard shortcuts still work.",
            keywords: ["toolbar", "buttons", "placement", "hide"], ui: true
        )),

        // Open With
        app("editorApp", .editorApp, row(.apps, "Default Apps", "Text editor", subtitle: "Used for editing text files.", keywords: ["editor", "code", "open in editor"])),
        app("terminalApp", .terminalApp, row(
            .apps, "Default Apps", "Terminal",
            subtitle: "Used for running shell commands and opening folders.",
            keywords: ["shell", "iterm", "ghostty", "open in terminal"]
        )),
        bool("enterPastesToFrontmostTerminal", .enterPastesToFrontmostTerminal, row(
            .apps, "Default Apps", "Enter key pastes paths to frontmost terminal",
            subtitle: "When a terminal app is frontmost, Enter pastes the selected file paths into it instead of opening them. Turn off if you always prefer to open files on Enter.",
            keywords: ["enter", "return", "paste", "terminal"]
        )),
        app("shelfApp", .shelfApp, row(
            .apps, "Default Apps", "Stash / shelf app",
            subtitle: "The Stash action (⌘S) pins files to a Stash section above the results, or hands them to a shelf app like Yoink or Dropover.",
            note: "stash means Cling's own Stash.",
            keywords: ["stash", "shelf", "yoink", "dropover"]
        ), builtin: ["stash": CLING_STASH_APP]),
        presets("stashAutoClearAfter", .stashAutoClearAfter, STASH_AUTO_CLEAR_PRESETS, row(
            .apps, "Default Apps", "Auto-clear stash",
            subtitle: "Remove files from the stash after they've been stashed for this long.",
            note: "Seconds, 0 never clears. Only used with Cling's own Stash.",
            keywords: ["stash", "clear"]
        )),
        bool("copyPathsWithTilde", .copyPathsWithTilde, row(
            .apps, "Paths", "Use `~/` (tilde) in copied paths",
            keywords: ["copy path", "tilde", "home"]
        )),

        // Search
        bool("updateWhileClosed", .updateWhileClosed, row(
            .search, "", "Watch file events while the app is quit",
            note: "A launch agent gathers file changes while Cling is closed, so the indexes are nearly current when it opens.",
            keywords: ["closed", "catch up", "launch agent", "fsevents"]
        )) { _ in
            CatchUpAgent.sync()
        },
        bool("everythingEnabled", .everythingEnabled, row(
            .search, "Everything", "Enable Everything index",
            note: "Off unloads the Everything index, stops its walk and its following of file changes, and hides its asterisk "
                + "in the search window, the search bar and the file server; the Toggle Everything shortcut does nothing. "
                + "Searches asking for Everything are refused. The saved index stays on disk: cling_everything delete "
                + "removes it. Back on, nothing runs until the next Everything search loads the saved index, or walks the "
                + "local disks when it was deleted. Free to change; searching Everything still needs Cling Pro.",
            keywords: ["everything", "whole disk", "asterisk", "disk space", "delete index", "turn off"], ui: true
        )) { _ in
            EVERYTHING.applySetting()
        },
        bool("literalSearch", .literalSearch, row(
            .search, "Matching", "Literal search",
            subtitle: "Words match as typed, not fuzzily. Prefix a word with ' to fuzzy match it.",
            note: "Flips what a ' prefix means in every query.",
            keywords: ["exact", "fuzzy", "fzf", "substring"]
        )),
        int("minQueryLength", .minQueryLength, 1 ... 5, row(
            .search, "Matching", "Minimum query length",
            note: "Shorter queries show the default results instead of searching, unless a filter is active.",
            keywords: ["short query", "characters", "letters"]
        )),
        int("maxResultsCount", .maxResultsCount, 1 ... 10000, row(
            .search, "Results", "Max results",
            subtitle: "Maximum number of results to show in the search results.",
            note: "Settings offers 100, 500, and with Cling Pro 1000, 2000, 5000 and 10000. Without Pro the window shows at most 500 whatever this says.",
            keywords: ["limit", "count", "more results", "truncated"]
        )) { value in
            value > 500 && !proactive ? "more than 500 results needs Cling Pro" : nil
        },
        rawValue("defaultResultsMode", .defaultResultsMode, row(
            .search, "Results", "Default results",
            subtitle: "What to show when no query or filter is active.",
            note: "The search window's. The search bar has its own in searchBarDefaultResults.",
            keywords: ["recent", "history", "empty"], ui: true
        )),
        bool("showSearchHints", .showSearchHints, row(
            .search, "Results", "Show search hints",
            subtitle: "Cycle example queries in the search field placeholder.",
            keywords: ["placeholder", "examples", "hints"], ui: true
        )) { _ in
            Defaults[.searchHintsManuallyEnabled] = true
        },

        // Filters
        bool("filterAutoOff", .filterAutoOff, row(
            .filters, "", "Auto-disable filters",
            note: "The checkbox in the bar at the bottom of the Filters pane. When on, an active quick, folder or drive filter turns off "
                + "after filterAutoOffAfter seconds with Cling in the background and the search bar closed. A filter's own "
                + "autoOff (cling_filter_write) wins over both.",
            keywords: ["filter", "reset", "clear", "timeout", "auto off", "background"]
        )),
        duration("filterAutoOffAfter", .filterAutoOffAfter, row(
            .filters, "", "Auto-disable filters",
            note: "The time in that bar. Counted from when Cling went to the background, or from when the filter was turned "
                + "on if later. Only applies while filterAutoOff is true.",
            keywords: ["filter", "reset", "clear", "timeout", "auto off", "background"]
        )),

        // Drives & Volumes
        bool("disableAutomaticVolumeIndexing", .disableAutomaticVolumeIndexing, row(
            .volumes, "", "Index new volumes automatically",
            subtitle: "When off, a volume connected for the first time is not indexed until you enable it below. Volumes you've already indexed keep refreshing on their own.",
            note: "The reverse of its Settings toggle: true means a volume connected for the first time is not indexed until it is enabled. Needs Cling Pro.",
            keywords: ["external", "usb", "drive", "volume"]
        ), pro: true),

        // Excluded Paths
        bool("honorGitignore", .honorGitignore, row(
            .exclusions, "", "Respect each project's .gitignore",
            note: "Turning it either way reindexes the Home scope.",
            keywords: ["gitignore", "node_modules", "build", "ignore"]
        )) { _ in
            FUZZY.refresh(pauseSearch: false, scopes: [.home])
        },

        // MCP. Readable so an agent can see why a script was refused, and never writable here: the switch
        // would otherwise be one the thing it gates could turn on for itself.
        readOnly("mcpAllowScripts", .mcpAllowScripts, row(.mcp, "MCP", "Allow agents to write arbitrary scripts")),

        // Web Access serves this Mac's files to browsers on the network, so only the user turns it on.
        readOnly("webAccessEnabled", .webAccessEnabled, row(
            .webAccess, "", "Enable file server",
            note: "Search and download this Mac's files from a browser on the local network or a VPN, signed in through the link or QR code in Settings. Needs Cling Pro: without it the server stays off whatever this says.",
            keywords: ["web access", "web", "browser", "phone", "lan", "tailscale", "server", "download"]
        )),
        int("webAccessConfirmDownloadsOver", .webAccessConfirmDownloadsOver, 0 ... 1_000_000, row(
            .webAccess, "", "Confirm downloads over",
            note: "Megabytes. A download from the file server page bigger than this asks first, in the browser, before it starts: one file, a folder's ZIP, or the selection. 0 never asks. Viewing a file or streaming a video doesn't count.",
            keywords: ["download", "confirm", "size", "large", "limit", "mb"]
        )),
        // Getting the certificate publishes the Mac's Tailscale name, so only the user turns it on.
        readOnly("webAccessHTTPS", .webAccessHTTPS, row(
            .webAccess, "", "HTTPS on Tailscale",
            note: "Serves the file server over HTTPS on this Mac's Tailscale name, with a certificate Tailscale gets from Let's Encrypt, which puts that name in public certificate logs. Needed for installing the page as an app on Android and in Chrome, and for its offline page.",
            keywords: ["https", "tls", "certificate", "tailscale", "pwa", "app"]
        )),
    ]

    @MainActor static var keysByName: [String: MCPSettingKey] {
        Dictionary(keys.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Schema

    /// Every setting with its live value, narrowed by `filter` when one is given.
    @MainActor static func schema(filter: String? = nil) -> [MCPSettingInfo] {
        guard let filter, !filter.trimmingCharacters(in: .whitespaces).isEmpty else {
            return keys.map(info)
        }
        return matches(filter).map(info)
    }

    @MainActor static func get(_ name: String) -> MCPSettingInfo? {
        keysByName[name].map(info)
    }

    /// Returns nil on success, an explanation otherwise.
    @MainActor static func set(_ name: String, to value: String) -> String? {
        guard let key = keysByName[name] else {
            return "no setting named '\(name)'. Ask for the schema to see every key."
        }
        return key.write(value)
    }

    /// What an agent's whole question should land on.
    ///
    /// Rows where every word hits come first, then the ones that only share some of them: "why are the
    /// buttons under the results gone" has words no row carries, and the rarer ones should still decide it.
    @MainActor static func matches(_ filter: String) -> [MCPSettingKey] {
        let wanted = words(filter).filter { !stopWords.contains($0) }
        guard !wanted.isEmpty else { return keys }

        let scored = keys.map { key -> (key: MCPSettingKey, score: Double, all: Bool) in
            let fields: [(Double, [String])] = [
                (3.0, words(key.row.title)),
                (2.5, key.row.keywords.flatMap(words)),
                (2.0, words(splitCamelCase(key.name))),
                (1.0, words(key.row.subtitle) + words(key.row.note)),
                (0.6, words(key.row.section) + words(key.row.pane?.title ?? "")),
            ]
            var score = 0.0
            var hits = 0
            for word in wanted {
                let best = fields.map { weight, haystack in
                    haystack.contains { $0 == word || ($0.count > 3 && word.count > 3 && ($0.hasPrefix(word) || word.hasPrefix($0))) } ? weight : 0
                }.max() ?? 0
                if best > 0 {
                    hits += 1
                }
                score += best
            }
            return (key, score, hits == wanted.count)
        }
        let strict = scored.filter(\.all).sorted { $0.score > $1.score }.map(\.key)
        let relaxed = scored.filter { !$0.all && $0.score > 0 }.sorted { $0.score > $1.score }.prefix(20).map(\.key)
        return strict + relaxed
    }

    /// The settings for a terminal.
    static func text(_ settings: [MCPSettingInfo]) -> String {
        guard !settings.isEmpty else { return "Nothing matched." }
        return settings.map { s in
            let where_ = [s.pane, s.section].filter { !$0.isEmpty }.joined(separator: " > ")
            var lines = ["\(s.title)\(where_.isEmpty ? "" : "  [\(where_)]")"]
            if !s.subtitle.isEmpty {
                lines.append("  \(s.subtitle)")
            }
            if !s.note.isEmpty {
                lines.append("  \(s.note)")
            }
            lines.append("  \(s.key) = \(s.value)\(s.allowed.map { "   one of: " + $0.joined(separator: ", ") } ?? "")")
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private static let stopWords: Set = [
        "the", "a", "an", "is", "are", "why", "how", "do", "does", "i", "my", "to", "of", "in", "on", "it",
        "not", "can", "cant", "dont", "doesnt", "and", "or", "when", "what", "where", "show", "hide", "make",
    ]

    @MainActor private static func info(_ key: MCPSettingKey) -> MCPSettingInfo {
        MCPSettingInfo(
            key: key.name,
            type: key.type,
            value: key.read(),
            allowed: key.allowed,
            title: key.row.title,
            subtitle: key.row.subtitle,
            note: key.row.note,
            pane: key.row.pane?.title ?? "",
            section: key.row.section,
            ui: key.row.ui
        )
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func splitCamelCase(_ name: String) -> String {
        name.reduce(into: "") { out, ch in
            if ch.isUppercase {
                out.append(" ")
            }
            out.append(ch)
        }
    }

    private static func row(
        _ pane: SettingsCategory? = nil, _ section: String = "", _ title: String,
        subtitle: String = "", note: String = "", keywords: [String] = [], ui: Bool = false
    ) -> MCPSettingRow {
        MCPSettingRow(pane: pane, section: section, title: title, subtitle: subtitle, note: note, keywords: keywords, ui: ui)
    }

    private static func row(title: String, note: String, keywords: [String], ui: Bool) -> MCPSettingRow {
        MCPSettingRow(pane: nil, title: title, note: note, keywords: keywords, ui: ui)
    }
}

// MARK: - Typed builders

extension MCPSettingsBridge {
    private static func parseBool(_ raw: String) -> Bool? {
        switch raw.lowercased().trimmingCharacters(in: .whitespaces) {
        case "true", "yes", "on", "1": true
        case "false", "no", "off", "0": false
        default: nil
        }
    }

    /// `apply` runs after the write for the settings whose Settings row does more than store the value.
    private static func bool(
        _ name: String, _ key: Defaults.Key<Bool>, _ row: MCPSettingRow, pro: Bool = false,
        apply: (@MainActor (Bool) -> Void)? = nil
    ) -> MCPSettingKey {
        MCPSettingKey(name: name, type: "bool", allowed: ["true", "false"], row: row) {
            Defaults[key] ? "true" : "false"
        } write: { raw in
            guard let value = parseBool(raw) else {
                return "\(name) takes true or false, not '\(raw)'"
            }
            if pro, !proactive {
                return "\(name) needs Cling Pro"
            }
            Defaults[key] = value
            apply?(value)
            return nil
        }
    }

    private static func readOnly(_ name: String, _ key: Defaults.Key<Bool>, _ row: MCPSettingRow) -> MCPSettingKey {
        MCPSettingKey(name: name, type: "bool", allowed: nil, row: row) {
            Defaults[key] ? "true" : "false"
        } write: { _ in
            "\(name) can only be changed by the user, in Cling Settings, \(row.pane?.title ?? "MCP")."
        }
    }

    private static func int(
        _ name: String, _ key: Defaults.Key<Int>, _ range: ClosedRange<Int>, _ row: MCPSettingRow,
        check: (@MainActor (Int) -> String?)? = nil
    ) -> MCPSettingKey {
        MCPSettingKey(name: name, type: "int", allowed: ["\(range.lowerBound) to \(range.upperBound)"], row: row) {
            String(Defaults[key])
        } write: { raw in
            guard let value = Int(raw.trimmingCharacters(in: .whitespaces)), range.contains(value) else {
                return "\(name) takes a whole number from \(range.lowerBound) to \(range.upperBound), not '\(raw)'"
            }
            if let problem = check?(value) {
                return problem
            }
            Defaults[key] = value
            return nil
        }
    }

    private static func double(_ name: String, _ key: Defaults.Key<Double>, _ range: ClosedRange<Double>, _ row: MCPSettingRow) -> MCPSettingKey {
        MCPSettingKey(name: name, type: "number", allowed: ["\(range.lowerBound) to \(range.upperBound)"], row: row) {
            String(Defaults[key])
        } write: { raw in
            guard let value = Double(raw.trimmingCharacters(in: .whitespaces)), range.contains(value) else {
                return "\(name) takes a number from \(range.lowerBound) to \(range.upperBound), not '\(raw)'"
            }
            Defaults[key] = value
            return nil
        }
    }

    /// A duration the Settings control only offers at fixed points, so a write lands on one of them rather
    /// than on a value the picker cannot show.
    private static func presets(_ name: String, _ key: Defaults.Key<TimeInterval>, _ values: [TimeInterval], _ row: MCPSettingRow) -> MCPSettingKey {
        let allowed = values.map { String(Int($0)) }
        return MCPSettingKey(name: name, type: "seconds", allowed: allowed, row: row) {
            String(Int(Defaults[key]))
        } write: { raw in
            guard let value = Double(raw.trimmingCharacters(in: .whitespaces)), values.contains(value) else {
                return "\(name) takes one of these numbers of seconds: \(allowed.joined(separator: ", ")). Got '\(raw)'"
            }
            Defaults[key] = value
            return nil
        }
    }

    /// A duration the way the Settings field takes it: `300`, `90s`, `5m`, `1h 30m`. A bare number is seconds, the unit
    /// the value reads back in.
    private static func duration(_ name: String, _ key: Defaults.Key<TimeInterval>, _ row: MCPSettingRow) -> MCPSettingKey {
        MCPSettingKey(name: name, type: "seconds", allowed: ["10 to 86400, or a duration like 90s, 10m, 2h"], row: row) {
            String(Int(Defaults[key]))
        } write: { raw in
            guard let value = AutoOffDuration.parse(raw, current: 1) else {
                return "\(name) takes seconds or a duration like 90s, 10m or 2h, not '\(raw)'"
            }
            if let problem = AutoOffDuration.problem(value) {
                return "\(problem), not '\(raw)'"
            }
            Defaults[key] = value
            return nil
        }
    }

    /// Any `String`-backed enum. The allowed list comes from `CaseIterable`, so it cannot drift from the
    /// cases the app accepts.
    private static func rawValue<T>(
        _ name: String, _ key: Defaults.Key<T>, _ row: MCPSettingRow,
        check: (@MainActor (T) -> String?)? = nil
    ) -> MCPSettingKey where T: RawRepresentable & CaseIterable & Defaults.Serializable, T.RawValue == String {
        MCPSettingKey(name: name, type: "enum", allowed: T.allCases.map(\.rawValue), row: row) {
            Defaults[key].rawValue
        } write: { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard let value = T.allCases.first(where: { $0.rawValue.lowercased() == trimmed }) else {
                return "\(name) takes one of: \(T.allCases.map(\.rawValue).joined(separator: ", ")). Got '\(raw)'"
            }
            if let problem = check?(value) {
                return problem
            }
            Defaults[key] = value
            return nil
        }
    }

    /// An app, given as a path, a name or a bundle identifier, stored as the path Settings would store.
    /// `builtin` maps a word to a value that is not an app, like Cling's own Stash.
    private static func app(_ name: String, _ key: Defaults.Key<String>, _ row: MCPSettingRow, builtin: [String: String] = [:]) -> MCPSettingKey {
        MCPSettingKey(name: name, type: "app", allowed: builtin.isEmpty ? nil : Array(builtin.keys) + ["<app path, name or bundle id>"], row: row) {
            let value = Defaults[key]
            return builtin.first { $0.value == value }?.key ?? value
        } write: { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if let value = builtin[trimmed.lowercased()] {
                Defaults[key] = value
                return nil
            }
            guard let url = resolveApp(trimmed) else {
                return "no app found for '\(raw)'. Pass the path to a .app, its name as it shows in /Applications, or its bundle identifier."
            }
            Defaults[key] = url.path
            return nil
        }
    }

    static func resolveApp(_ text: String) -> URL? {
        let expanded = (text as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return expanded.hasSuffix(".app") && FileManager.default.fileExists(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: text) {
            return url
        }
        let name = text.hasSuffix(".app") ? text : text + ".app"
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities", HOME.string + "/Applications"]
        for folder in folders {
            let path = folder + "/" + name
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        // Names differ in case more often than in spelling ("iterm" for iTerm).
        for folder in folders {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            if let match = items.first(where: { $0.lowercased() == name.lowercased() }) {
                return URL(fileURLWithPath: folder + "/" + match)
            }
        }
        return nil
    }

    private static func launchAtLogin(_ row: MCPSettingRow) -> MCPSettingKey {
        MCPSettingKey(name: "launchAtLogin", type: "bool", allowed: ["true", "false"], row: row) {
            LaunchAtLogin.isEnabled ? "true" : "false"
        } write: { raw in
            guard let value = parseBool(raw) else {
                return "launchAtLogin takes true or false, not '\(raw)'"
            }
            LaunchAtLogin.isEnabled = value
            return nil
        }
    }

    private static func showAppKey(_ row: MCPSettingRow) -> MCPSettingKey {
        let allowed = Set<SauceKey>.showAppKeyChoices.map(\.rawValue).sorted()
        return MCPSettingKey(name: "showAppKey", type: "enum", allowed: allowed, row: row) {
            Defaults[.showAppKey].rawValue
        } write: { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard let key = Set<SauceKey>.showAppKeyChoices.first(where: { $0.rawValue.lowercased() == trimmed }) else {
                return "showAppKey takes one of: \(allowed.joined(separator: ", ")). Got '\(raw)'"
            }
            Defaults[.showAppKey] = key
            return nil
        }
    }

    /// The modifier keys, by name. `TriggerKey` is an `Int` enum, and those numbers mean nothing to an agent.
    private static let triggerKeyNames: [(String, TriggerKey)] = [
        ("rcmd", .rcmd), ("lcmd", .lcmd), ("cmd", .cmd),
        ("ralt", .ralt), ("lalt", .lalt), ("alt", .alt),
        ("rctrl", .rctrl), ("lctrl", .lctrl), ("ctrl", .ctrl),
        ("rshift", .rshift), ("lshift", .lshift), ("shift", .shift),
        ("fn", .fn), ("capsLock", .capsLock),
    ]

    private static func triggerKeys(_ row: MCPSettingRow) -> MCPSettingKey {
        MCPSettingKey(name: "triggerKeys", type: "list", allowed: triggerKeyNames.map(\.0), row: row) {
            Defaults[.triggerKeys].compactMap { key in triggerKeyNames.first { $0.1 == key }?.0 }.joined(separator: ", ")
        } write: { raw in
            let wanted = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
            var chosen: [TriggerKey] = []
            var unknown: [String] = []
            for want in wanted {
                if let match = triggerKeyNames.first(where: { $0.0.lowercased() == want })?.1 {
                    chosen.append(match)
                } else {
                    unknown.append(want)
                }
            }
            guard unknown.isEmpty, !chosen.isEmpty else {
                return "triggerKeys takes a comma separated list of: \(triggerKeyNames.map(\.0).joined(separator: ", ")). Got '\(raw)'"
            }
            Defaults[.triggerKeys] = chosen
            return nil
        }
    }

    private static func actionIDs(_ raw: String) -> (ids: [ActionID], unknown: [String]) {
        var ids: [ActionID] = []
        var unknown: [String] = []
        for want in raw.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }) {
            if let id = ActionID.allCases.first(where: { $0.rawValue.lowercased() == want.lowercased() }) {
                ids.append(id)
            } else {
                unknown.append(want)
            }
        }
        return (ids, unknown)
    }

    /// Order is what the bar shows left to right, so this keeps what it is given rather than sorting it.
    /// An action moved onto the bar comes off the hidden list, as the placement picker does.
    private static func actionList(_ row: MCPSettingRow) -> MCPSettingKey {
        let allowed = ActionID.allCases.map(\.rawValue)
        return MCPSettingKey(name: "barActions", type: "list", allowed: allowed, row: row) {
            Defaults[.barActions].map(\.rawValue).joined(separator: ", ")
        } write: { raw in
            let (ids, unknown) = actionIDs(raw)
            guard unknown.isEmpty else {
                return "barActions does not know \(unknown.joined(separator: ", ")). It takes any of: \(allowed.joined(separator: ", "))"
            }
            var seen = Set<ActionID>()
            let bar = ids.filter { seen.insert($0).inserted }
            Defaults[.barActions] = bar
            Defaults[.hiddenActions].subtract(bar)
            return nil
        }
    }

    private static func hiddenActionSet(_ row: MCPSettingRow) -> MCPSettingKey {
        let allowed = ActionID.allCases.map(\.rawValue)
        return MCPSettingKey(name: "hiddenActions", type: "list", allowed: allowed, row: row) {
            Defaults[.hiddenActions].map(\.rawValue).sorted().joined(separator: ", ")
        } write: { raw in
            let (ids, unknown) = actionIDs(raw)
            guard unknown.isEmpty else {
                return "hiddenActions does not know \(unknown.joined(separator: ", ")). It takes any of: \(allowed.joined(separator: ", "))"
            }
            let hidden = Set(ids)
            Defaults[.hiddenActions] = hidden
            Defaults[.barActions].removeAll { hidden.contains($0) }
            return nil
        }
    }
}

// MARK: - Request handling

extension MCPSettingsBridge {
    @MainActor static func handle(_ req: ClingRequest) -> ClingResponse {
        switch req.action ?? "schema" {
        case "schema":
            let settings = schema(filter: req.query)
            return ClingResponse(status: text(settings), payload: payloadJSON(["settings": settings]))
        case "ui":
            let settings = keys.filter(\.row.ui).map(info)
            return ClingResponse(status: text(settings), payload: payloadJSON(["settings": settings]))
        case "get":
            guard let name = req.key else {
                return ClingResponse(error: "get needs a key")
            }
            guard let found = get(name) else {
                return ClingResponse(error: "no setting named '\(name)'. Ask for the schema to see every key.")
            }
            return ClingResponse(status: text([found]), payload: payloadJSON(["settings": [found]]))
        case "set":
            guard let name = req.key, let value = req.value else {
                return ClingResponse(error: "set needs a key and a value")
            }
            if let problem = set(name, to: value) {
                return ClingResponse(error: problem)
            }
            let settings = get(name).map { [$0] } ?? []
            return ClingResponse(status: text(settings), payload: payloadJSON(["settings": settings]))
        default:
            return ClingResponse(error: "unknown settings action '\(req.action ?? "")'")
        }
    }
}

// MARK: - The gate

extension ClingRequest {
    /// Whether this request changes anything. Reading is open to agents whether or not the user has allowed
    /// changes, so they can find out why something is the way it is before asking for anything.
    var changesSomething: Bool {
        switch command {
        case .search, .status, .recents, .indexHas, .explain, .why:
            false
        case .index, .reindex, .cancelIndex, .indexAdd, .indexRemove, .open:
            true
        case .settings:
            action == "set"
        case .filters, .scripts, .volumes, .cloud, .scopes, .ignore, .shortcuts:
            !["list", "show", nil].contains(action)
        case .everything:
            !["status", nil].contains(action)
        }
    }

    /// Whether this request writes code that Cling will run on the user's files.
    var writesScriptCode: Bool {
        command == .scripts && action == "write"
    }
}

/// Whether a request arriving from the MCP server may run, and why not when it may not. nil when it may.
///
/// The gate lives in the app because the CLI is a binary the caller controls. A request that does not claim
/// MCP origin is somebody using their own CLI, which needs no permission from anyone.
nonisolated func mcpRefusal(_ req: ClingRequest) -> String? {
    guard req.origin == "mcp", req.changesSomething else { return nil }
    guard Defaults[.mcpEnabled] else {
        return "Cling is not accepting changes from agents. Ask the user to allow it in Cling Settings, MCP."
    }
    guard req.writesScriptCode, !Defaults[.mcpAllowScripts] else { return nil }
    return "Cling is not accepting scripts from agents. Ask the user to allow scripts in Cling Settings, MCP."
}

/// A configuration answer as the JSON the CLI prints for `--json`.
func payloadJSON(_ value: some Encodable) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}

/// Runs `body` on the main actor and waits for it. Gives up after `timeout` so a busy main thread cannot
/// hold a CLI call forever, and then returns nil.
nonisolated func waitOnMain<T>(timeout: TimeInterval = 10, _ body: @escaping @MainActor () -> T) -> T? {
    if Thread.isMainThread {
        return MainActor.assumeIsolated { body() }
    }
    var result: T?
    let sem = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
        result = MainActor.assumeIsolated { body() }
        sem.signal()
    }
    guard sem.wait(timeout: .now() + timeout) == .success else { return nil }
    return result
}
