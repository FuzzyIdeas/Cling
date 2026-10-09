//
//  WebPage.swift
//  Cling
//
//  The HTML for Web Access: one page, and the fragments htmx swaps into it.
//

import Defaults
import Foundation

enum WebPage {
    enum Header {
        case recent
        case folder(String)
    }

    struct SelectionSummary {
        let count: Int
        let bytes: UInt64
        /// False when a folder was too big to measure in time, so the size is a floor.
        let complete: Bool
        let downloads: [String]
        let zipURL: String
        /// The one item's name, or how many there are, for the send dialog.
        let name: String
        /// The one item is a folder, which the send dialog names as one.
        let folder: Bool
        /// Something in it may be online only, for the page to get onto the Mac first.
        let fetchFirst: Bool
    }

    /// What the options sheet narrows a search to. It rides in the page's URL, so a reload keeps it.
    struct Options {
        init() {}

        init(_ request: HTTPRequest) {
            place = request.param("where") ?? ""
            // From a bookmark or a tab left open since before Everything was turned off.
            if place == "everything", !Defaults[.everythingEnabled] {
                place = ""
            }
            quickFilter = request.param("filter") ?? ""
            folderFilter = request.param("folders") ?? ""
        }

        /// Empty for the window's own indexes, or "everything", "drives" (every external drive), "scope:<raw value>",
        /// "drive:<name>".
        var place = ""
        var quickFilter = ""
        var folderFilter = ""

        var params: [String] {
            var params = [String]()
            if !place.isEmpty {
                params.append("where=" + encodeQuery(place))
            }
            if !quickFilter.isEmpty {
                params.append("filter=" + encodeQuery(quickFilter))
            }
            if !folderFilter.isEmpty {
                params.append("folders=" + encodeQuery(folderFilter))
            }
            return params
        }
    }

    /// What the options sheet offers, as the Mac's search window has it.
    struct Choices {
        /// A quick or folder filter as the window shows it: its SF Symbol and the hue of its colour.
        struct Filter {
            let name: String
            let icon: String
            let hue: Double
        }

        var scopes: [(value: String, label: String)] = []
        var drives: [(name: String, connected: Bool)] = []
        /// Every external drive at once, offered from two of them up.
        var allDrives = false
        /// Settings > Search can turn Everything off, and then it isn't offered.
        var everything = Defaults[.everythingEnabled]
        var quickFilters: [Filter] = []
        var folderFilters: [Filter] = []
    }

    /// How an icon in the options sheet is coloured: a filter's hue, Everything's orange, or plain grey.
    enum SymbolColor {
        case hue(Double)
        case orange
        case gray

        var param: String {
            switch self {
            case let .hue(hue): String(format: "%.4f", hue)
            case .orange: "orange"
            case .gray: "gray"
            }
        }
    }

    /// An SF Symbol, drawn by the Mac in the colour each appearance gets (see `/sym/` in WebAccessServer), since a
    /// browser has no SF Symbols and the page's CSP allows no inline styles to tint one.
    static func symbol(_ name: String, _ color: SymbolColor) -> String {
        let base = "/sym/\(encodeQuery(name)).png?c=\(color.param)"
        return #"<picture class="sym"><source srcset="\#(escape(base))&amp;d=1" media="(prefers-color-scheme: dark)"><img src="\#(escape(base))&amp;d=0" alt=""></picture>"#
    }

    /// The icon each place to search in gets in the options sheet.
    static func placeSymbol(_ place: String, choices: Choices) -> String {
        switch place {
        case "": symbol("magnifyingglass", .gray)
        case "everything": symbol("asterisk", .orange)
        case "drives": symbol("externaldrive.fill", .gray)
        case "scope:home": symbol("house", .gray)
        case "scope:library": symbol("building.columns", .gray)
        case "scope:applications": symbol("square.grid.2x2", .gray)
        case "scope:system": symbol("gearshape", .gray)
        case "scope:root": symbol("terminal", .gray)
        case let p where p.hasPrefix("drive:"):
            symbol(choices.drives.contains { p == "drive:\($0.name)" && !$0.connected } ? "externaldrive.badge.xmark" : "externaldrive.fill", .gray)
        default: symbol("magnifyingglass", .gray)
        }
    }

    // MARK: URLs

    static func pageURL(query: String, folder: String?, options: Options = Options()) -> String {
        var params = [String]()
        if !query.isEmpty {
            params.append("q=" + encodeQuery(query))
        }
        if let folder {
            params.append("in=" + encodeQuery(folder))
        }
        params += options.params
        return params.isEmpty ? "/" : "/?" + params.joined(separator: "&")
    }

    static func resultsURL(query: String, folder: String?, from: Int, options: Options) -> String {
        var params = ["q=" + encodeQuery(query)]
        if let folder {
            params.append("in=" + encodeQuery(folder))
        }
        params += options.params
        if from > 0 {
            params.append("from=\(from)")
        }
        return "/results?" + params.joined(separator: "&")
    }

    static func viewURL(_ path: String) -> String {
        "/f" + encodePath(path)
    }
    static func downloadURL(_ path: String) -> String {
        "/d" + encodePath(path)
    }

    /// Every byte outside the unreserved set and "/" percent-encoded, so any file name survives the trip.
    static func encodePath(_ path: String) -> String {
        var out = ""
        for byte in path.utf8 {
            switch byte {
            case UInt8(ascii: "a") ... UInt8(ascii: "z"), UInt8(ascii: "A") ... UInt8(ascii: "Z"), UInt8(ascii: "0") ... UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"), UInt8(ascii: "/"):
                out.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    static func encodeQuery(_ value: String) -> String {
        encodePath(value).replacingOccurrences(of: "/", with: "%2F")
    }

    /// Scalar by scalar: a Character holding `"` and a combining mark after it is not equal to `"`, and would slip
    /// through to end the attribute it sits in.
    static func escape(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out.append(contentsOf: "&amp;".unicodeScalars)
            case "<": out.append(contentsOf: "&lt;".unicodeScalars)
            case ">": out.append(contentsOf: "&gt;".unicodeScalars)
            case "\"": out.append(contentsOf: "&quot;".unicodeScalars)
            case "'": out.append(contentsOf: "&#39;".unicodeScalars)
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    /// `s` as a JSON string literal, for an htmx value.
    static func json(_ s: String) -> String {
        (try? String(decoding: JSONEncoder().encode(s), as: UTF8.self)) ?? "\"\""
    }

    // MARK: Page

    static func page(
        macName: String, appHead: String, options: Options, choices: Choices, query: String, folder: String?, results: String,
        selectionBar: String, confirmOver: UInt64, linkExpiration: TimeInterval, assetVersion: String
    ) -> String {
        // The send dialog's slider steps through the same expiries as the Mac's, starting at its default.
        let expiries = LINK_EXPIRATION_PRESETS.map { String(Int($0)) }.joined(separator: ",")
        let expiry = Int(LINK_EXPIRATION_PRESETS[nearestExpirationPresetIndex(linkExpiration)])
        let summary = optionsSummary(options, choices: choices)
        let scope = folder.map { folder in
            """
            <a class="scope" href="\(escape(pageURL(query: query, folder: nil)))" aria-label="Search everywhere">\
            \(icon("folder"))<span>\(escape(folderName(folder)))</span>\(icon("x"))</a>
            <input type="hidden" name="in" value="\(escape(folder))">
            """
        } ?? ""
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover, interactive-widget=resizes-content">
        <meta name="color-scheme" content="light dark">
        <meta name="htmx-config" content='{"defaultTimeout": 30000, "includeIndicatorCSS": false}'>
        <title>Cling · \(escape(macName))</title>
        <link rel="icon" type="image/png" href="/icon.png">
        \(appHead)
        <link rel="stylesheet" href="/assets/cling-web.css?v=\(assetVersion)">
        <script src="/assets/htmx.min.js?v=\(assetVersion)" defer></script>
        <script src="/assets/cling-web.js?v=\(assetVersion)" defer></script>
        </head>
        <body data-mac="\(escape(macName))" data-confirm-over="\(confirmOver)" data-expiries="\(expiries)" data-expiry="\(expiry)">
        \(sprite)
        <main id="results" class="results">\(results)</main>
        <aside id="preview" class="preview" aria-label="Preview"></aside>
        <footer class="dock">
        <div class="selecthead"><button class="link" type="button" data-select-all>Select All</button></div>
        \(selectionBar)
        <div class="searchrow">
        <form id="search" class="search" action="/" method="get" role="search">
        \(icon("search", class: "glass"))
        \(scope)
        <input id="q" type="search" name="q" value="\(escape(query))" placeholder="Search files" aria-label="Search files"
         autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" enterkeyhint="search" autofocus
         hx-get="/results" hx-trigger="input changed delay:90ms, search" hx-target="#results" hx-swap="innerHTML scroll:top"
         hx-sync="this:replace" hx-include="closest form">
        <button class="opts\(summary.isEmpty ? "" : " on")" type="button" data-opens="options" aria-label="Search options">\
        \(icon("filter"))<span class="opts-label">\(summary)</span></button>
        \(optionsSheet(options, choices: choices))
        </form>
        <button class="select" type="button" aria-pressed="false">Select</button>
        <button class="clear showpreview" type="button" aria-label="Show preview">\(icon("sidebar"))</button>
        </div>
        </footer>
        <dialog id="sheet" class="sheet"></dialog>
        </body>
        </html>
        """
    }

    /// `signIn` adds a field for the link from Settings, the only way an installed iPhone app gets signed in again: a
    /// scanned QR code opens Safari, whose cookies the app doesn't share. `home` adds a way back to the search, for an
    /// error page an installed app would otherwise be stuck on.
    static func message(title: String, body: String, assetVersion: String, signIn: Bool = false, home: Bool = false) -> String {
        let form = signIn
            ? """
            <form class="relink" action="/pair" method="get">
            <input type="text" inputmode="url" name="link" placeholder="Paste the link" aria-label="Sign-in link" required
             autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false">
            <button class="btn primary" type="submit">Sign in</button>
            </form>
            """
            : ""
        let back = home ? #"<p><a class="btn" href="/">Back to search</a></p>"# : ""
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta name="color-scheme" content="light dark">
        <title>Cling</title>
        <link rel="stylesheet" href="/assets/cling-web.css?v=\(assetVersion)">
        </head>
        <body class="message">
        <main>
        <h1>\(escape(title))</h1>
        \(body.isEmpty ? "" : "<p>\(escape(body))</p>")
        \(form)\(back)
        </main>
        </body>
        </html>
        """
    }

    /// What the service worker shows in place of the page when the Mac doesn't answer. Kept in its cache, so it names
    /// the Mac as it was called when the app last reached it.
    static func offline(macName: String, assetVersion: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta name="color-scheme" content="light dark">
        <title>Cling</title>
        <link rel="stylesheet" href="/assets/cling-web.css?v=\(assetVersion)">
        <script src="/assets/cling-web.js?v=\(assetVersion)" defer></script>
        </head>
        <body class="message">
        <main>
        <h1>Can't reach \(escape(macName))</h1>
        <p>It may be asleep, or this device isn't on its network or VPN.</p>
        <p><a class="btn primary" href="/">Try again</a></p>
        </main>
        </body>
        </html>
        """
    }

    // MARK: Listing

    /// `problem` stands in for "No results" when the search couldn't run as asked (Everything without Pro, say).
    /// `narrowed` names the search options when they're the reason nothing was found, with the URL that drops them.
    static func listing(
        header: Header?, items: [WebItem], selected: Set<String>, webkit: Bool, next: String?, searching: Bool, problem: String? = nil,
        narrowed: (names: String, clearURL: String)? = nil
    ) -> String {
        var html = ""
        switch header {
        case .recent:
            // The installed app adds its Downloads button here (cling-web.js), once it has kept some.
            html += #"<header class="crumb recent"><h1>Recent</h1></header>"#
        case let .folder(folder):
            let parent = (folder as NSString).deletingLastPathComponent
            let back = folder == "/" ? "" : """
            <a class="up" href="\(escape(pageURL(query: "", folder: parent)))">\(icon("back"))<span>\(escape(folderName(parent)))</span></a>
            """
            html += """
            <header class="crumb">\(back)<h1>\(escape(folderName(folder)))</h1>\
            <a class="pill" href="\(escape(downloadURL(folder)))" download data-size="?"\(WebCloudFetch.inCloud(folder) ? " data-cloud" : "")>\(icon("download"))<span>Download folder</span></a></header>
            """
        case nil:
            break
        }
        if items.isEmpty {
            if problem == nil, searching, let narrowed {
                return html + """
                <p class="empty">No results in \(escape(narrowed.names))</p>\
                <p class="empty-action"><a class="btn" href="\(escape(narrowed.clearURL))" data-plain>Clear options</a></p>
                """
            }
            let empty = switch header {
            case .folder where !searching: "Empty folder"
            case .recent: "No recent files"
            default: "No results"
            }
            return html + #"<p class="empty">\#(escape(problem ?? empty))</p>"#
        }
        let browsing = if case .folder = header, !searching {
            true
        } else {
            false
        }
        return html + #"<ul class="list">"# + rows(items, selected: selected, webkit: webkit, browsing: browsing) + moreSentinel(next) + "</ul>"
    }

    /// `browsing` a folder's own files, which all sit in it: the rows leave out where they are.
    static func rows(_ items: [WebItem], selected: Set<String>, webkit: Bool, browsing: Bool = false) -> String {
        items.map { row($0, selected: selected.contains($0.path), webkit: webkit, browsing: browsing) }.joined()
    }

    /// The last row asks for the next page once it scrolls into view.
    static func moreSentinel(_ next: String?) -> String {
        guard let next else { return "" }
        return #"<li class="more" hx-get="\#(escape(next))" hx-trigger="revealed" hx-swap="outerHTML" aria-hidden="true"></li>"#
    }

    static func row(_ item: WebItem, selected: Bool, webkit: Bool, browsing: Bool = false) -> String {
        let name = escape(item.name)
        let kind = item.isDir ? WebViewKind.none : WebViewKind.of(item.path, size: item.size, webkit: webkit, readable: item.readable)

        var meta = browsing ? [] : [#"<span class="where">\#(escape(displayFolder(item.path)))</span>"#]
        if item.offline {
            meta.append("<span>Drive not connected</span>")
        } else {
            let cloud = item.onlineOnly ? #"<span class="cloud" role="img" aria-label="Online only">\#(icon("cloud"))</span>"# : ""
            if item.browsable {
                meta.append("<span>Folder</span>")
            } else if let size = item.size ?? (item.isPackage ? nil : 0) {
                meta.append("<span>\(cloud)\(formatBytes(size))</span>")
            } else if !cloud.isEmpty {
                meta.append("<span>\(cloud)</span>")
            }
            if let modified = item.modified {
                meta.append("<span>\(escape(relativeDate(modified)))</span>")
            }
        }

        let open = if item.offline {
            #"<span class="main">"#
        } else if item.browsable {
            #"<a class="main" href="\#(escape(pageURL(query: "", folder: item.path)))">"#
        } else if kind != .none {
            #"<a class="main" href="\#(escape(viewURL(item.path)))" data-kind="\#(kind.rawValue)"\#(item.fetchFirst ? " data-cloud" : "")>"#
        } else {
            #"<a class="main" href="\#(escape(downloadURL(item.path)))" download\#(sizeAttributes(item))>"#
        }
        let close = item.offline ? "</span>" : "</a>"

        let thumb = item.offline
            ? ""
            : #"<img class="thumb" src="/t\#(escape(encodePath(item.path)))?v=\#(item.version)" alt="" loading="lazy" decoding="async">"#
        let glyph = item.browsable ? "folder" : (item.isPackage ? "package" : "file")
        let download = item.offline
            ? ""
            : """
            <a class="dl" href="\(escape(downloadURL(item.path)))" download\(sizeAttributes(item)) aria-label="Download \(name)">\(icon("download"))</a>\
            <button class="dl send" type="button" data-link="\(escape(item.path))" data-name="\(name)"\(sizeAttributes(item))\
            \(item.browsable ? " data-folder" : "") aria-label="Send \(name) securely">\(icon("send"))</button>
            """

        // The checkbox sits in a column of its own that only selection mode opens (see cling-web.js), and the icon is
        // part of the row's link, so tapping it opens the file like the rest of the row.
        return """
        <li class="row\(selected ? " on" : "")\(item.offline ? " offline" : "")">\
        <label class="pick" aria-label="Select \(name)">\
        <input type="checkbox" name="on" value="true"\(selected ? " checked" : "")\(item.offline ? " disabled" : "") \
        hx-post="/select" hx-vals="\(escape("{\"p\": \(json(item.path))}"))" hx-target="#selbar" hx-swap="outerHTML">\
        <span class="check">\(icon("check"))</span></label>\
        \(open)<span class="icon"><span class="glyph">\(icon(glyph))</span>\(thumb)</span>\
        <span class="text"><span class="name">\(name)</span><span class="meta">\(meta.joined())</span></span>\(close)\
        \(download)</li>
        """
    }

    // MARK: Search options

    /// The options sheet: where to search and which filters to search with, one choice in each, laid out like the
    /// window's filter menu. It sits inside the search form, so every search sends its radios along (htmx collects a
    /// form's own descendants), and a change searches again (cling-web.js). A modal dialog rather than a popover, so a
    /// tap beside it only closes it, instead of also landing on the file underneath.
    static func optionsSheet(_ options: Options, choices: Choices) -> String {
        func choice(_ name: String, _ value: String, _ label: String, _ symbol: String, current: String, note: String? = nil) -> String {
            """
            <li><label class="choice"><input type="radio" name="\(name)" value="\(escape(value))" data-label="\(escape(label))"\
            \(value == current ? " checked" : "")>\(symbol)<span class="choice-label">\(escape(label))</span>\
            \(note.map { #"<span class="choice-note">\#(escape($0))</span>"# } ?? "")\(icon("check"))</label></li>
            """
        }
        func section(_ title: String, _ rows: [String]) -> String {
            #"<section><h2>\#(title)</h2><ul class="choices">"# + rows.joined() + "</ul></section>"
        }
        func place(_ value: String, _ label: String, note: String? = nil) -> String {
            choice("where", value, label, placeSymbol(value, choices: choices), current: options.place, note: note)
        }
        let none = #"<picture class="sym"></picture>"#

        var places = [place("", "All")]
        if choices.everything {
            places.append(place("everything", "Everything"))
        }
        places += choices.scopes.map { place("scope:\($0.value)", $0.label) }
        if choices.allDrives {
            places.append(place("drives", "External drives"))
        }
        places += choices.drives.map { place("drive:\($0.name)", $0.name, note: $0.connected ? nil : "Not connected") }

        var html = section("Search in", places)
        if !choices.quickFilters.isEmpty {
            html += section(
                "Quick filter",
                [choice("filter", "", "None", none, current: options.quickFilter)]
                    + choices.quickFilters.map { choice("filter", $0.name, $0.name, symbol($0.icon, .hue($0.hue)), current: options.quickFilter) }
            )
        }
        if !choices.folderFilters.isEmpty {
            html += section(
                "Folder filter",
                [choice("folders", "", "None", none, current: options.folderFilter)]
                    + choices.folderFilters.map { choice("folders", $0.name, $0.name, symbol($0.icon, .hue($0.hue)), current: options.folderFilter) }
            )
        }
        return #"<dialog id="options" class="sheet options">"# + html + "</dialog>"
    }

    /// What the options button shows while a search is narrowed: each choice's icon and name, as cling-web.js builds
    /// it when a choice changes.
    /// The chosen options by name, "Everything · Images", for saying what a search was narrowed to.
    static func optionsNames(_ options: Options, choices: Choices) -> String {
        var names = [String]()
        switch options.place {
        case "": break
        case "everything": names.append("Everything")
        case "drives": names.append("External drives")
        case let p where p.hasPrefix("scope:"): names.append(choices.scopes.first { p == "scope:\($0.value)" }?.label ?? String(p.dropFirst("scope:".count)))
        case let p: names.append(String(p.dropFirst("drive:".count)))
        }
        names += [options.quickFilter, options.folderFilter].filter { !$0.isEmpty }
        return names.joined(separator: " · ")
    }

    static func optionsSummary(_ options: Options, choices: Choices) -> String {
        func part(_ symbol: String, _ label: String, everything: Bool = false) -> String {
            #"<span class="part\#(everything ? " everything" : "")">\#(symbol)<span>\#(escape(label))</span></span>"#
        }
        var parts = [String]()
        switch options.place {
        case "":
            break
        case "everything":
            parts.append(part(placeSymbol("everything", choices: choices), "Everything", everything: true))
        case "drives":
            parts.append(part(placeSymbol("drives", choices: choices), "External drives"))
        case let p where p.hasPrefix("scope:"):
            let label = choices.scopes.first { p == "scope:\($0.value)" }?.label ?? String(p.dropFirst("scope:".count))
            parts.append(part(placeSymbol(p, choices: choices), label))
        case let p:
            parts.append(part(placeSymbol(p, choices: choices), String(p.dropFirst("drive:".count))))
        }
        for (name, filters) in [(options.quickFilter, choices.quickFilters), (options.folderFilter, choices.folderFilters)] where !name.isEmpty {
            let filter = filters.first { $0.name == name }
            parts.append(part(filter.map { symbol($0.icon, .hue($0.hue)) } ?? "", name))
        }
        return parts.joined()
    }

    // MARK: Selection

    static func selectionBar(_ summary: SelectionSummary?) -> String {
        guard let summary else { return #"<div id="selbar" class="selbar" hidden></div>"# }
        let size = formatBytes(summary.bytes) + (summary.complete ? "" : "+")
        let urls = "[" + summary.downloads.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        let sized = #" data-size="\#(summary.bytes)" data-size-label="\#(escape(formatBytes(summary.bytes)))""#
            + (summary.complete ? "" : #" data-size-floor="1""#)
        let cloud = summary.fetchFirst ? #" data-cloud="sel""# : ""
        let download = summary.count == 1
            ? #"<a class="btn" href="\#(escape(summary.downloads[0]))" download\#(sized)\#(cloud) aria-label="Download">\#(icon("download"))<span>Download</span></a>"#
            : #"<button class="btn" type="button" data-urls="\#(escape(urls))"\#(sized)\#(cloud) aria-label="Download">\#(icon("download"))<span>Download</span></button>"#
        let zip = summary.count == 1 ? "" : """
        <a class="btn primary" href="\(escape(summary.zipURL))" download\(sized)\(cloud) aria-label="ZIP">\(icon("zip"))<span>ZIP</span></a>
        """
        let kind = summary.count > 1 ? #" data-count="\#(summary.count)""# : summary.folder ? " data-folder" : ""
        let link = #"<button class="btn icon" type="button" data-link="selection" data-name="\#(escape(summary.name))"\#(sized)\#(kind) aria-label="Send securely">\#(icon("send"))</button>"#
        return """
        <div id="selbar" class="selbar">\
        <button class="count" type="button" data-opens="sheet" hx-get="/selection" hx-target="#sheet"><span>\(summary.count) selected · \(size)</span>\(icon("up"))</button>\
        \(link)\(download)\(zip)\
        <button class="clear" type="button" hx-post="/select/clear" hx-target="#selbar" hx-swap="outerHTML" aria-label="Clear selection">\(icon("x"))</button>\
        </div>
        """
    }

    static func sheet(_ items: [WebItem], webkit: Bool) -> String {
        guard !items.isEmpty else { return #"<p class="empty">No results</p>"# }
        let rows = items.map { item in
            let name = escape(item.name)
            return """
            <li class="row">\
            <span class="main"><span class="icon"><span class="glyph">\(icon(item.browsable ? "folder" : "file"))</span>\
            <img class="thumb" src="/t\(escape(encodePath(item.path)))?v=\(item.version)" alt="" decoding="async"></span>\
            <span class="text"><span class="name">\(name)</span><span class="meta"><span class="where">\(escape(displayFolder(item.path)))</span></span></span></span>\
            <a class="dl" href="\(escape(downloadURL(item.path)))" download\(sizeAttributes(item)) aria-label="Download \(name)">\(icon("download"))</a>\
            <button class="clear" type="button" data-unselect="\(escape(item.path))" aria-label="Remove \(name)">\(icon("x"))</button></li>
            """
        }.joined()
        return #"<header class="crumb"><h1>Selected</h1></header><ul class="list">"# + rows + "</ul>"
    }

    // MARK: Formatting

    static func folderName(_ path: String) -> String {
        if path == NSHomeDirectory() {
            return "~"
        }
        if path == "/" {
            return "/"
        }
        return (path as NSString).lastPathComponent
    }

    /// Where a row's file lives: ~ for the home folder, a drive by its name instead of /Volumes.
    static func displayFolder(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        let home = NSHomeDirectory()
        if parent == home {
            return "~"
        }
        if parent.hasPrefix(home + "/") {
            return "~" + parent.dropFirst(home.count)
        }
        if parent.hasPrefix("/Volumes/") {
            return String(parent.dropFirst("/Volumes/".count))
        }
        return parent
    }

    /// What a download's confirmation weighs (cling-web.js): a file's size, or "?" for a folder or package, whose ZIP
    /// is measured only when it's tapped.
    /// What a download link carries for the page: the size its confirmation weighs, and whether the Mac has to get it
    /// from the cloud first.
    static func sizeAttributes(_ item: WebItem) -> String {
        (item.isDir ? #" data-size="?""# : #" data-size="\#(item.size ?? 0)" data-size-label="\#(escape(formatBytes(item.size ?? 0)))""#)
            + (item.fetchFirst ? " data-cloud" : "")
    }

    /// With a decimal point whatever the region writes, like the sizes in the app; `ByteCountFormatter` follows the region.
    static func formatBytes(_ bytes: UInt64) -> String {
        bytes < 1000 ? "\(bytes) bytes" : IndexStats.diskSize(Int(clamping: bytes))
    }

    static func relativeDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return timeFormatter.string(from: date)
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7, days > 0 {
            return weekdayFormatter.string(from: date)
        }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return dayFormatter.string(from: date)
        }
        return yearFormatter.string(from: date)
    }

    // MARK: Icons

    static func icon(_ name: String, class extra: String = "") -> String {
        ##"<svg class="i\##(extra.isEmpty ? "" : " " + extra)" aria-hidden="true"><use href="#i-\##(name)"/></svg>"##
    }

    private static let timeFormatter = formatter("jmm")
    private static let weekdayFormatter = formatter("EEEE")
    private static let dayFormatter = formatter("MMMd")
    private static let yearFormatter = formatter("MMMdyyyy")

    private static let sprite = """
    <svg xmlns="http://www.w3.org/2000/svg" class="sprite">
    <symbol id="i-cloud" viewBox="0 0 24 24"><path d="M7.5 18.5H17a3.75 3.75 0 0 0 .4-7.48 5.5 5.5 0 0 0-10.6 1.24A3.25 3.25 0 0 0 7.5 18.5z"/></symbol>
    <symbol id="i-download" viewBox="0 0 24 24"><path d="M12 4v11m0 0-4.5-4.5M12 15l4.5-4.5M5 19.5h14"/></symbol>
    <symbol id="i-send" viewBox="0 0 24 24"><path d="M20.5 3.5 3.9 10.2a.6.6 0 0 0 0 1.1l6.4 2.4 2.4 6.4a.6.6 0 0 0 1.1 0zM10.3 13.7 20.5 3.5"/></symbol>
    <symbol id="i-zip" viewBox="0 0 24 24"><path d="M4.5 8h15v10.5a2 2 0 0 1-2 2h-11a2 2 0 0 1-2-2zM3.5 4h17v4h-17zM10 12h4"/></symbol>
    <symbol id="i-x" viewBox="0 0 24 24"><path d="M7 7l10 10M17 7 7 17"/></symbol>
    <symbol id="i-sidebar" viewBox="0 0 24 24"><rect x="3.5" y="5" width="17" height="14" rx="2.5"/><path d="M14.5 5v14"/></symbol>
    <symbol id="i-check" viewBox="0 0 24 24"><path d="M6 12.5l4 4L18 8"/></symbol>
    <symbol id="i-filter" viewBox="0 0 24 24"><path d="M4.5 7h15M7.5 12h9M10.5 17h3"/></symbol>
    <symbol id="i-search" viewBox="0 0 24 24"><circle cx="10.5" cy="10.5" r="6.5"/><path d="m15.5 15.5 4.5 4.5"/></symbol>
    <symbol id="i-back" viewBox="0 0 24 24"><path d="M14.5 18 8.5 12l6-6"/></symbol>
    <symbol id="i-up" viewBox="0 0 24 24"><path d="M7 14.5 12 9.5l5 5"/></symbol>
    <symbol id="i-folder" viewBox="0 0 24 24"><path d="M3.5 7A1.5 1.5 0 0 1 5 5.5h4l2 2h8A1.5 1.5 0 0 1 20.5 9v8.5A1.5 1.5 0 0 1 19 19H5a1.5 1.5 0 0 1-1.5-1.5z"/></symbol>
    <symbol id="i-file" viewBox="0 0 24 24"><path d="M7 3.5h6.5l4.5 4.5v11a1.5 1.5 0 0 1-1.5 1.5h-9.5A1.5 1.5 0 0 1 5.5 19V5A1.5 1.5 0 0 1 7 3.5zM13.5 3.5V8H18"/></symbol>
    <symbol id="i-package" viewBox="0 0 24 24"><path d="M12 3.5 19.5 7.5v9L12 20.5l-7.5-4v-9zM4.5 7.5 12 11.5l7.5-4M12 11.5v9"/></symbol>
    </svg>
    """

    private static func formatter(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

}
