//
//  WebPage.swift
//  Cling
//
//  The HTML for Web Access: one page, and the fragments htmx swaps into it. Copy is drafted in
//  docs/web-access-copy.md.
//

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
    }

    // MARK: URLs

    static func pageURL(query: String, folder: String?) -> String {
        var params = [String]()
        if !query.isEmpty {
            params.append("q=" + encodeQuery(query))
        }
        if let folder {
            params.append("in=" + encodeQuery(folder))
        }
        return params.isEmpty ? "/" : "/?" + params.joined(separator: "&")
    }

    static func resultsURL(query: String, folder: String?, from: Int) -> String {
        var params = ["q=" + encodeQuery(query)]
        if let folder {
            params.append("in=" + encodeQuery(folder))
        }
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

    static func page(macName: String, appHead: String, query: String, folder: String?, results: String, selectionBar: String, assetVersion: String) -> String {
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
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover, interactive-widget=resizes-content">
        <meta name="color-scheme" content="light dark">
        <meta name="htmx-config" content='{"defaultTimeout": 30000, "includeIndicatorCSS": false}'>
        <title>Cling · \(escape(macName))</title>
        <link rel="icon" type="image/png" href="/icon.png">
        \(appHead)
        <link rel="stylesheet" href="/assets/cling-web.css?v=\(assetVersion)">
        <script src="/assets/htmx.min.js?v=\(assetVersion)" defer></script>
        <script src="/assets/cling-web.js?v=\(assetVersion)" defer></script>
        </head>
        <body data-mac="\(escape(macName))">
        \(sprite)
        <main id="results" class="results">\(results)</main>
        <footer class="dock">
        \(selectionBar)
        <form class="search" action="/" method="get" role="search">
        \(icon("search", class: "glass"))
        \(scope)
        <input id="q" type="search" name="q" value="\(escape(query))" placeholder="Search files" aria-label="Search files"
         autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" enterkeyhint="search" autofocus
         hx-get="/results" hx-trigger="input changed delay:90ms, search" hx-target="#results" hx-swap="innerHTML scroll:top"
         hx-sync="this:replace" hx-include="closest form">
        </form>
        </footer>
        <div id="sheet" class="sheet" popover></div>
        </body>
        </html>
        """
    }

    static func message(title: String, body: String, assetVersion: String) -> String {
        """
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

    static func listing(header: Header?, items: [WebItem], selected: Set<String>, webkit: Bool, next: String?, searching: Bool) -> String {
        var html = ""
        switch header {
        case .recent:
            html += #"<header class="crumb"><h1>Recent</h1></header>"#
        case let .folder(folder):
            let parent = (folder as NSString).deletingLastPathComponent
            let back = folder == "/" ? "" : """
            <a class="up" href="\(escape(pageURL(query: "", folder: parent)))">\(icon("back"))<span>\(escape(folderName(parent)))</span></a>
            """
            html += """
            <header class="crumb">\(back)<h1>\(escape(folderName(folder)))</h1>\
            <a class="pill" href="\(escape(downloadURL(folder)))" download>\(icon("download"))<span>Download folder</span></a></header>
            """
        case nil:
            break
        }
        if items.isEmpty {
            let empty = if case .folder = header, !searching {
                "Empty folder"
            } else {
                "No results"
            }
            return html + #"<p class="empty">\#(empty)</p>"#
        }
        return html + #"<ul class="list">"# + rows(items, selected: selected, webkit: webkit) + moreSentinel(next) + "</ul>"
    }

    static func rows(_ items: [WebItem], selected: Set<String>, webkit: Bool) -> String {
        items.map { row($0, selected: selected.contains($0.path), webkit: webkit) }.joined()
    }

    /// The last row asks for the next page once it scrolls into view.
    static func moreSentinel(_ next: String?) -> String {
        guard let next else { return "" }
        return #"<li class="more" hx-get="\#(escape(next))" hx-trigger="revealed" hx-swap="outerHTML" aria-hidden="true"></li>"#
    }

    static func row(_ item: WebItem, selected: Bool, webkit: Bool) -> String {
        let name = escape(item.name)
        let kind = item.isDir ? WebViewKind.none : WebViewKind.of(item.path, size: item.size, webkit: webkit)

        var meta = [#"<span class="where">\#(escape(displayFolder(item.path)))</span>"#]
        if item.offline {
            meta.append("<span>Drive not connected</span>")
        } else {
            if item.browsable {
                meta.append("<span>Folder</span>")
            } else if let size = item.size ?? (item.isPackage ? nil : 0) {
                meta.append("<span>\(formatBytes(size))</span>")
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
            #"<a class="main" href="\#(escape(viewURL(item.path)))" data-kind="\#(kind.rawValue)">"#
        } else {
            #"<a class="main" href="\#(escape(downloadURL(item.path)))" download>"#
        }
        let close = item.offline ? "</span>" : "</a>"

        let thumb = item.offline
            ? ""
            : #"<img class="thumb" src="/t\#(escape(encodePath(item.path)))?v=\#(item.version)" alt="" loading="lazy" decoding="async">"#
        let glyph = item.browsable ? "folder" : (item.isPackage ? "package" : "file")
        let download = item.offline ? "" : """
        <a class="dl" href="\(escape(downloadURL(item.path)))" download aria-label="Download \(name)">\(icon("download"))</a>
        """

        return """
        <li class="row\(selected ? " on" : "")\(item.offline ? " offline" : "")">\
        <label class="pick" aria-label="Select \(name)">\
        <input type="checkbox" name="on" value="true"\(selected ? " checked" : "")\(item.offline ? " disabled" : "") \
        hx-post="/select" hx-vals="\(escape("{\"p\": \(json(item.path))}"))" hx-target="#selbar" hx-swap="outerHTML">\
        <span class="glyph">\(icon(glyph))</span>\(thumb)<span class="check">\(icon("check"))</span></label>\
        \(open)<span class="name">\(name)</span><span class="meta">\(meta.joined())</span>\(close)\
        \(download)</li>
        """
    }

    // MARK: Selection

    static func selectionBar(_ summary: SelectionSummary?) -> String {
        guard let summary else { return #"<div id="selbar" class="selbar" hidden></div>"# }
        let size = formatBytes(summary.bytes) + (summary.complete ? "" : "+")
        let urls = "[" + summary.downloads.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        let download = summary.count == 1
            ? #"<a class="btn" href="\#(escape(summary.downloads[0]))" download>\#(icon("download"))<span>Download</span></a>"#
            : #"<button class="btn" type="button" data-urls="\#(escape(urls))">\#(icon("download"))<span>Download</span></button>"#
        let zip = summary.count == 1 ? "" : """
        <a class="btn primary" href="\(escape(summary.zipURL))" download>\(icon("zip"))<span>ZIP</span></a>
        """
        return """
        <div id="selbar" class="selbar">\
        <button class="count" type="button" popovertarget="sheet" hx-get="/selection" hx-target="#sheet">\(summary.count) selected · \(size)</button>\
        \(download)\(zip)\
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
            <span class="pick"><span class="glyph">\(icon(item.browsable ? "folder" : "file"))</span>\
            <img class="thumb" src="/t\(escape(encodePath(item.path)))?v=\(item.version)" alt="" decoding="async"></span>\
            <span class="main"><span class="name">\(name)</span><span class="meta"><span class="where">\(escape(displayFolder(item.path)))</span></span></span>\
            <a class="dl" href="\(escape(downloadURL(item.path)))" download aria-label="Download \(name)">\(icon("download"))</a></li>
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

    static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
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
    <symbol id="i-download" viewBox="0 0 24 24"><path d="M12 4v11m0 0-4.5-4.5M12 15l4.5-4.5M5 19.5h14"/></symbol>
    <symbol id="i-zip" viewBox="0 0 24 24"><path d="M4.5 8h15v10.5a2 2 0 0 1-2 2h-11a2 2 0 0 1-2-2zM3.5 4h17v4h-17zM10 12h4"/></symbol>
    <symbol id="i-x" viewBox="0 0 24 24"><path d="M7 7l10 10M17 7 7 17"/></symbol>
    <symbol id="i-check" viewBox="0 0 24 24"><path d="M6 12.5l4 4L18 8"/></symbol>
    <symbol id="i-search" viewBox="0 0 24 24"><circle cx="10.5" cy="10.5" r="6.5"/><path d="m15.5 15.5 4.5 4.5"/></symbol>
    <symbol id="i-back" viewBox="0 0 24 24"><path d="M14.5 18 8.5 12l6-6"/></symbol>
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
