//
//  WebAccessServer.swift
//  Cling
//
//  What the Web Access pages ask for: search, folder listings, files to view or download, thumbnails, and the
//  per-browser selection that turns into one ZIP or a row of downloads.
//
//  Every route but the pairing link and the static assets needs the access key, which a browser gets as a cookie by
//  opening the link (or scanning the QR code) from Settings. Turning the key over signs every browser out.
//

import AppKit
import CryptoKit
import Defaults
import Foundation
import os.log
@preconcurrency import QuickLookThumbnailing
import UniformTypeIdentifiers

// MARK: - WebItem

/// One row on the page: a search result, a recent file, or a folder's child.
struct WebItem {
    let path: String
    let isDir: Bool
    /// A folder the system shows as one file (an app, a Photos library). It downloads as a ZIP and isn't browsed.
    let isPackage: Bool
    let size: UInt64?
    let modified: Date?
    /// On a drive that isn't connected, so there is nothing to send.
    let offline: Bool
    /// Flagged hidden, the way Finder hides $RECYCLE.BIN on a drive that has been in a PC.
    var hidden = false
    /// Safe to read a little of, to see whether it's text: see `WebViewKind.of`.
    var readable = false

    var name: String {
        (path as NSString).lastPathComponent
    }
    var browsable: Bool {
        isDir && !isPackage
    }
    var version: String {
        "\(Int(modified?.timeIntervalSince1970 ?? 0))-\(size ?? 0)"
    }
}

// MARK: - WebViewKind

/// How a browser shows a file it is sent inline, or `.none` for one it can only download.
enum WebViewKind: String {
    case image, video, audio, pdf, text, html, none

    /// `webkit` is Safari or any iOS browser, which also show HEIC, TIFF and AIFF. `readable` lets a file whose name
    /// doesn't settle whether it's text be read to find out: a regular file that is on the Mac, not one iCloud has
    /// evicted (reading it would download it).
    static func of(_ path: String, size: UInt64?, webkit: Bool, readable: Bool) -> WebViewKind {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp", "avif", "svg", "bmp", "ico": return .image
        case "heic", "heif", "tif", "tiff": return webkit ? .image : .none
        case "mp4", "m4v", "mov", "webm", "ogv": return .video
        case "mp3", "m4a", "aac", "wav", "flac", "ogg", "oga", "opus": return .audio
        case "aif", "aiff", "caf": return webkit ? .audio : .none
        case "pdf": return .pdf
        case "html", "htm", "xhtml": return .html
        default:
            // A browser shows any text as text when told it is text/plain. Past a few MB a log is better downloaded.
            guard (size ?? 0) <= 8 << 20 else { return .none }
            return isText(path, ext: ext, readable: readable) ? .text : .none
        }
    }

    static func readable(_ st: stat) -> Bool {
        st.st_mode & S_IFMT == S_IFREG && st.st_flags & UInt32(SF_DATALESS) == 0
    }

    /// By its type where macOS knows the extension as text. By its first bytes where macOS doesn't know the extension
    /// (most code: .vue, .styl, .slim), where there is none (Makefile, LICENSE), and where an app has claimed one that
    /// is also code (.ts as a video, .plist as a binary list).
    private static func isText(_ path: String, ext: String, readable: Bool) -> Bool {
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), !type.isDynamic {
            guard !type.conforms(to: .rtf) else { return false }
            let texty = type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json)
                || type.conforms(to: .xml) || type.conforms(to: .yaml) || type.conforms(to: .commaSeparatedText)
            if texty {
                return true
            }
            guard codeExtensions.contains(ext) else { return false }
        }
        return readable && looksLikeText(path)
    }

    /// Git's test: no NUL byte near the start. UTF-16 text is full of them, so it counts by its byte order mark.
    private static func looksLikeText(_ path: String) -> Bool {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &bytes, bytes.count)
        guard count >= 0 else { return false }
        let start = bytes[..<count]
        return start.starts(with: [0xFF, 0xFE]) || start.starts(with: [0xFE, 0xFF]) || !start.contains(0)
    }
}

// MARK: - WebAccessServer

final class WebAccessServer: @unchecked Sendable {
    init(coordinator: SearchCoordinator, key: String, macName: String, icon: Data?, appIcon: CGImage?) {
        self.coordinator = coordinator
        _key = key
        self.macName = macName
        self.icon = icon
        art = WebAppArt(icon: appIcon)
        assets = Self.loadAssets()
        assetVersion = Self.assetVersion(assets)
        appHead = WebApp.head(version: assetVersion)
    }

    /// Locations that never leave the Mac this way, even for a browser that has the key: the files that would let
    /// whoever holds the phone into everything else.
    static let privatePrefixes: [String] = {
        let home = NSHomeDirectory()
        let support = home + "/Library/Application Support"
        return [
            home + "/.ssh", home + "/.gnupg", home + "/.aws", home + "/.kube", home + "/.docker", home + "/.netrc",
            home + "/.password-store", home + "/.config/gh", home + "/Library/Keychains", home + "/Library/Cookies",
            support + "/Google/Chrome", support + "/BraveSoftware", support + "/Microsoft Edge", support + "/Arc",
            support + "/Firefox/Profiles", "/Library/Keychains", "/System/Library/Keychains", "/private/var/db",
        ].flatMap { path -> [String] in
            // Where a symlinked one (a dotfiles repo's .ssh) really is, too.
            guard let real = realpath(path, nil) else { return [path.lowercased()] }
            defer { free(real) }
            return [path.lowercased(), String(cString: real).lowercased()]
        }
    }()

    let macName: String

    var key: String {
        get { lock.withLock { _key } }
        set { lock.withLock { _key = newValue } }
    }

    /// Compared without case, as APFS compares names.
    static func isPrivate(_ path: String) -> Bool {
        var path = path.lowercased()
        if path.hasPrefix("/system/volumes/data/") {
            path = String(path.dropFirst("/system/volumes/data".count))
        }
        return privatePrefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    static func randomToken(bytes: Int = 20) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var random = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &random)
        // Base32, 5 bits a character.
        var out = ""
        var buffer = 0
        var bits = 0
        for byte in random {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 {
            out.append(alphabet[(buffer << (5 - bits)) & 31])
        }
        return out
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let response = await route(request)
        response.headers.append(("Referrer-Policy", "no-referrer"))
        response.headers.append(("X-Content-Type-Options", "nosniff"))
        let html = response.headers.contains { $0.0 == "Content-Type" && $0.1.hasPrefix("text/html") }
        if html, !response.headers.contains(where: { $0.0 == "Content-Security-Policy" }) {
            // The pages run only their own scripts, with no inline handlers and nothing evaluated, so markup that
            // slipped into one through a file name still couldn't run.
            response.headers.append(("Content-Security-Policy", Self.pagePolicy))
        }
        return response
    }

    private struct Session {
        var selection: [String] = []
        /// What Clear took away, for its Undo.
        var cleared: [String] = []
        var lastSeen = Date()
    }

    private struct Asset {
        let data: Data
        let gzipped: Data?
        let type: String
    }

    private enum ByteRange {
        case full
        case partial(ClosedRange<UInt64>)
        case unsatisfiable
    }

    private enum LinkAnswer {
        case ready(String, expires: Date?)
        case stillZipping
        case failed
    }

    private static let pagePolicy = "default-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"
    private static let keyCookie = "cling_key"
    private static let sessionCookie = "cling_sid"
    /// A cookie lives as long as Chrome lets one: 400 days.
    private static let cookieAge = 400 * 24 * 3600
    private static let pageSize = 60
    private static let maxResults = 1000

    private static let httpDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }()

    private static let work = DispatchQueue(label: "com.lowtechguys.Cling.WebAccess.work", qos: .userInitiated, attributes: .concurrent)

    // MARK: Links

    /// How long a link request waits before answering that it isn't ready yet. Zipping a big folder takes minutes,
    /// longer than a browser holds a request open; the page asks again, and the new request waits on the same send.
    private static let linkWait: TimeInterval = 20

    private let coordinator: SearchCoordinator
    private let icon: Data?
    private let art: WebAppArt
    /// The page's app tags, the same for every page until the assets change.
    private let appHead: String
    private let assets: [String: Asset]
    private let assetVersion: String
    private let lock = NSLock()
    private var _key: String
    private var sessions: [String: Session] = [:]
    /// What each ZIP link stands for. The link's id is a hash of its paths, so the same selection keeps the same link
    /// and a dropped download of it can resume.
    private var bundles: [String: [String]] = [:]
    private var bundleOrder: [String] = []
    private var plans: [String: (archive: ZipArchive, made: Date)] = [:]
    private var folderSizes: [String: (bytes: UInt64, complete: Bool, made: Date)] = [:]
    private let thumbnails: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 64 << 20
        return cache
    }()

    private static func loadAssets() -> [String: Asset] {
        var assets = [String: Asset]()
        for (file, type) in [
            ("htmx.min.js", "text/javascript; charset=utf-8"),
            // highlight.js 11.11.1 (BSD-3-Clause), its common languages, loaded when a text file is first shown.
            ("highlight.min.js", "text/javascript; charset=utf-8"),
            ("cling-web.js", "text/javascript; charset=utf-8"),
            ("cling-web.css", "text/css; charset=utf-8"),
        ] {
            let name = file as NSString
            guard let url = Bundle.main.url(forResource: name.deletingPathExtension, withExtension: name.pathExtension),
                  let data = try? Data(contentsOf: url)
            else {
                webLog.error("Missing web asset \(file, privacy: .public)")
                continue
            }
            assets[file] = Asset(data: data, gzipped: Gzip.compress(data, level: 9), type: type)
        }
        return assets
    }

    private static func assetVersion(_ assets: [String: Asset]) -> String {
        var hash = SHA256()
        for name in assets.keys.sorted() {
            hash.update(data: assets[name]!.data)
        }
        return hash.finalize().prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// A folder Finder shows as one file: an app, a Photos library, a bundle. Asked of the file system, since the
    /// extension alone can't tell (and a type looked up by extension defaults to a plain file's).
    private static func isPackage(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
    }

    private static func isWebKit(_ request: HTTPRequest) -> Bool {
        let agent = request.headers["user-agent"] ?? ""
        return agent.contains("AppleWebKit") && !agent.contains("Chrome/")
    }

    /// The real path `raw` names, with its symlinks resolved and the case on disk, when it exists and is outside the
    /// private locations. What is served or walked is always this spelling, so `/users/alin` can't reach
    /// `/Users/alin/.ssh` through a ZIP of the folder that the blocklist, which compares strings, wouldn't catch.
    private static func cleanPath(_ raw: String) -> String? {
        guard raw.hasPrefix("/"), !raw.contains("//") else { return nil }
        guard !raw.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        guard let real = realpath(raw, nil) else { return nil }
        defer { free(real) }
        let path = String(cString: real)
        return isPrivate(raw) || isPrivate(path) ? nil : path
    }

    /// The name the request used for its last component, which a symlink keeps even though its target is served.
    private static func requestedName(_ raw: String) -> String {
        var raw = raw
        while raw.count > 1, raw.hasSuffix("/") {
            raw.removeLast()
        }
        return (raw as NSString).lastPathComponent
    }

    private static func range(_ request: HTTPRequest, length: UInt64, etag: String, lastModified: String) -> ByteRange {
        guard let header = request.headers["range"], header.hasPrefix("bytes=") else { return .full }
        if let ifRange = request.headers["if-range"], ifRange != etag, ifRange != lastModified {
            return .full
        }
        let spec = header.dropFirst("bytes=".count)
        // Browsers ask for one range; a list of them gets the whole body, which is also correct.
        guard !spec.contains(","), length > 0 else { return .full }
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return .full }
        if parts[0].isEmpty {
            guard let suffix = UInt64(parts[1].trimmingCharacters(in: .whitespaces)), suffix > 0 else { return .unsatisfiable }
            return .partial((length - min(suffix, length)) ... (length - 1))
        }
        guard let start = UInt64(parts[0].trimmingCharacters(in: .whitespaces)) else { return .full }
        guard start < length else { return .unsatisfiable }
        let end = parts[1].isEmpty ? length - 1 : min(UInt64(parts[1].trimmingCharacters(in: .whitespaces)) ?? (length - 1), length - 1)
        guard end >= start else { return .unsatisfiable }
        return .partial(start ... end)
    }

    private static func disposition(_ kind: String, _ name: String) -> String {
        let ascii = String(name.unicodeScalars.map { $0.isASCII && $0.value >= 0x20 && $0 != "\"" && $0 != "\\" ? Character($0) : "_" })
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0) ..< Unicode.Scalar(128)))
        allowed.insert(charactersIn: "!#$&+-.^_`|~")
        let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? ascii
        return "\(kind); filename=\"\(ascii)\"; filename*=UTF-8''\(encoded)"
    }

    private static func mimeType(_ path: String, inline kind: WebViewKind?) -> String {
        if kind == .text {
            return "text/plain; charset=utf-8"
        }
        if kind == .html {
            return "text/html; charset=utf-8"
        }
        let ext = (path as NSString).pathExtension
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }

    private static func encodeThumbnail(_ image: CGImage, png: Bool) -> Data? {
        let data = NSMutableData()
        let type = (png ? UTType.png : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        let options = png ? nil : [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func json(_ object: [String: Any], status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: [("Content-Type", "application/json"), ("Cache-Control", "no-store")], body: .data(data))
    }

    private func route(_ request: HTTPRequest) async -> HTTPResponse {
        let path = request.path
        guard ["GET", "HEAD", "POST"].contains(request.method) else {
            return .text("Method not allowed", status: 405).header("Allow", "GET, HEAD, POST")
        }
        if path.hasPrefix("/assets/") {
            return asset(request, String(path.dropFirst("/assets/".count)))
        }
        if path.hasPrefix("/pair/") {
            return pair(request, String(path.dropFirst("/pair/".count)))
        }
        // The link pasted on the signed-out page: the whole URL, or only its key.
        if path == "/pair", let link = request.param("link")?.trimmingCharacters(in: .whitespacesAndNewlines) {
            let candidate = link.components(separatedBy: "/pair/").last?.components(separatedBy: CharacterSet(charactersIn: "/?#")).first ?? link
            return pair(request, candidate)
        }
        if let response = await appRoute(request, path: path) {
            return response
        }
        guard authorized(request) else {
            // A page the htmx request can't show: reload into the signed-out page instead.
            if request.isHTMX {
                return HTTPResponse(status: 401).header("HX-Refresh", "true")
            }
            return .html(WebPage.message(title: "Not signed in", body: "Open the link from Settings > File server in Cling on your Mac, or scan its QR code.", assetVersion: assetVersion, signIn: true), status: 401)
        }

        let (sid, isNew) = session(for: request)
        let response = await authorizedRoute(request, path: path, sid: sid)
        if isNew {
            response.headers.append(("Set-Cookie", "\(Self.sessionCookie)=\(sid); Path=/; Max-Age=\(Self.cookieAge); HttpOnly; SameSite=Lax"))
        }
        return response
    }

    private func authorizedRoute(_ request: HTTPRequest, path: String, sid: String) async -> HTTPResponse {
        if request.method == "GET" || request.method == "HEAD", path.hasPrefix("/t/") {
            return await thumbnail(request, String(path.dropFirst(2)))
        }
        if request.method == "POST", path == "/link" {
            // Same guard as the other posts (blockingRoute): a cross-site form can't send this header.
            guard request.isHTMX else { return .text("Forbidden", status: 403) }
            return await shareLink(request, sid: sid)
        }
        return await offload { self.blockingRoute(request, path: path, sid: sid) }
    }

    /// Everything but thumbnails blocks: a search waits its turn on the search lock, a ZIP walks its folders, a stat
    /// can hang on a sleeping network drive. It runs on a queue of its own so none of it holds a thread of Swift's
    /// cooperative pool, which the rest of Cling shares.
    private func offload(_ work: @escaping @Sendable () -> HTTPResponse) async -> HTTPResponse {
        await withCheckedContinuation { continuation in
            Self.work.async { continuation.resume(returning: work()) }
        }
    }

    private func blockingRoute(_ request: HTTPRequest, path: String, sid: String) -> HTTPResponse {
        if request.method == "POST" {
            // htmx sends this header, and a cross-site form can't, so another site can't post here in the user's
            // name even with the cookie along.
            guard request.isHTMX else { return .text("Forbidden", status: 403) }
            switch path {
            case "/select": return select(request, sid: sid)
            case "/select/clear": return clearSelection(sid: sid)
            case "/select/undo": return undoClear(sid: sid)
            default: return .text("Not found", status: 404)
            }
        }
        switch path {
        case "/": return page(request, sid: sid)
        case "/results": return results(request, sid: sid)
        case "/selection": return selectionSheet(request, sid: sid)
        case "/offline": return .html(WebPage.offline(macName: macName, assetVersion: assetVersion))
        default: break
        }
        if path.hasPrefix("/f/") {
            return file(request, String(path.dropFirst(2)), download: false)
        }
        if path.hasPrefix("/d/") {
            return file(request, String(path.dropFirst(2)), download: true)
        }
        if path.hasPrefix("/z/") {
            return bundleZip(request, String(path.dropFirst(3)))
        }
        if path == "/favicon.ico" || path == "/icon.png" {
            return iconResponse()
        }
        if path.hasPrefix("/size/") {
            return sizeResponse(String(path.dropFirst("/size".count)))
        }
        if path.hasPrefix("/sym/"), path.hasSuffix(".png") {
            return symbol(request, String(path.dropFirst("/sym/".count).dropLast(".png".count)))
        }
        return notFound()
    }

    private func notFound() -> HTTPResponse {
        .html(WebPage.message(title: "Not found", body: "", assetVersion: assetVersion, home: true), status: 404)
    }

    // MARK: Auth and sessions

    private func authorized(_ request: HTTPRequest) -> Bool {
        let key = key
        guard !key.isEmpty else { return false }
        if let cookie = request.cookies[Self.keyCookie], constantTimeEqual(cookie, key) {
            return true
        }
        if let auth = request.headers["authorization"], auth.hasPrefix("Bearer ") {
            return constantTimeEqual(String(auth.dropFirst("Bearer ".count)), key)
        }
        return false
    }

    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let a = Array(a.utf8)
        let b = Array(b.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in a.indices {
            diff |= a[i] ^ b[i]
        }
        return diff == 0
    }

    private func pair(_ request: HTTPRequest, _ candidate: String) -> HTTPResponse {
        guard constantTimeEqual(candidate, key) else {
            // An installed app opens the link it was added with, so after signing in again with a new one it keeps
            // asking for the old one: already signed in, that goes straight to the search.
            if authorized(request) {
                return HTTPResponse.redirect("/")
            }
            return .html(WebPage.message(title: "This link has expired", body: "Get the new one from Settings > File server in Cling on your Mac.", assetVersion: assetVersion, signIn: true), status: 401)
        }
        return HTTPResponse.redirect("/")
            .header("Set-Cookie", "\(Self.keyCookie)=\(candidate); Path=/; Max-Age=\(Self.cookieAge); HttpOnly; SameSite=Lax")
    }

    private func session(for request: HTTPRequest) -> (String, Bool) {
        lock.withLock {
            if let sid = request.cookies[Self.sessionCookie], sessions[sid] != nil {
                sessions[sid]!.lastSeen = Date()
                return (sid, false)
            }
            if sessions.count >= 64, let oldest = sessions.min(by: { $0.value.lastSeen < $1.value.lastSeen })?.key {
                sessions[oldest] = nil
            }
            let sid = Self.randomToken()
            sessions[sid] = Session()
            return (sid, true)
        }
    }

    private func selection(_ sid: String) -> [String] {
        lock.withLock { sessions[sid]?.selection ?? [] }
    }

    // MARK: Pages

    private func page(_ request: HTTPRequest, sid: String) -> HTTPResponse {
        let q = request.param("q") ?? ""
        let folder = request.param("in").flatMap(Self.cleanPath).flatMap { isDirectory($0) ? $0 : nil }
        let listing = listingHTML(request, q: q, folder: folder, from: 0, sid: sid)
        let options = WebPage.Options(request)
        let html = WebPage.page(
            macName: macName,
            appHead: appHead,
            options: options,
            choices: searchChoices(),
            query: q,
            folder: folder,
            results: listing,
            selectionBar: selectionBar(sid: sid),
            confirmOver: UInt64(max(0, Defaults[.webAccessConfirmDownloadsOver])) * 1_000_000,
            linkExpiration: Defaults[.defaultLinkExpiration],
            assetVersion: assetVersion
        )
        return .html(html)
    }

    private func results(_ request: HTTPRequest, sid: String) -> HTTPResponse {
        let q = request.param("q") ?? ""
        let folder = request.param("in").flatMap(Self.cleanPath).flatMap { isDirectory($0) ? $0 : nil }
        let from = min(max(0, Int(request.param("from") ?? "0") ?? 0), Self.maxResults)
        let response = HTTPResponse.html(listingHTML(request, q: q, folder: folder, from: from, sid: sid))
        if from == 0 {
            // The address bar follows the search, so a reload or a trip back from a file lands on the same results.
            response.headers.append(("HX-Replace-Url", WebPage.pageURL(query: q, folder: folder, options: WebPage.Options(request))))
        }
        return response
    }

    private func listingHTML(_ request: HTTPRequest, q: String, folder: String?, from: Int, sid: String) -> String {
        let query = q.trimmingCharacters(in: .whitespaces)
        let webkit = Self.isWebKit(request)
        let selected = Set(selection(sid))
        let wanted = from + Self.pageSize

        let options = WebPage.Options(request)
        // A quick or folder filter searches with its own tokens even before anything is typed, as the window does.
        let filtering = !options.quickFilter.isEmpty || (folder == nil && !options.folderFilter.isEmpty)

        let items: [WebItem]
        var more = false
        var header: WebPage.Header?
        var problem: String?
        if !filtering, query.isEmpty || (folder == nil && query.count < Defaults[.minQueryLength]) {
            if let folder {
                let all = folderChildren(folder)
                items = Array(all.dropFirst(from).prefix(Self.pageSize))
                more = all.count > wanted
                header = .folder(folder)
            } else {
                let recents = coordinator.getRecents(maxResults: Self.maxResults)
                let slice = recents.dropFirst(from).prefix(Self.pageSize)
                items = slice.compactMap { item($0.path, isDir: $0.isDir) }
                more = recents.count > wanted
                header = .recent
            }
        } else {
            let expanded = query.replacingOccurrences(of: "~/", with: NSHomeDirectory() + "/")
            // The search `cling search` runs, so the options mean here what its flags mean, Pro checks included.
            // Inside a folder the folder is the scope, and a folder filter would only widen it.
            var search = ClingRequest(
                command: .search,
                query: expanded,
                maxResults: min(wanted + 1, Self.maxResults),
                folderPrefixes: folder.map { [$0] },
                quickFilter: options.quickFilter.isEmpty ? nil : options.quickFilter,
                folderFilter: folder == nil && !options.folderFilter.isEmpty ? options.folderFilter : nil
            )
            switch options.place {
            case "everything": search.everything = true
            case "drives": search.allDrives = true
            case let place where place.hasPrefix("scope:"): search.scopes = [String(place.dropFirst("scope:".count))]
            case let place where place.hasPrefix("drive:"): search.scopes = [String(place.dropFirst("drive:".count))]
            default: break
            }
            // The CLI waits up to two minutes for Everything to load. A page waits a few seconds, which a saved index
            // takes to load, and otherwise says so: a first build walks every disk.
            if search.everything == true {
                let deadline = Date().addingTimeInterval(6)
                repeat {
                    problem = waitOnMain(timeout: 2) { () -> String? in
                        switch EVERYTHING.cliAccess() {
                        case .ready: nil
                        case .needsPro: "Everything needs Cling Pro"
                        case .loading: "The Everything index is still loading"
                        }
                    } ?? "The Everything index is still loading"
                    guard problem == "The Everything index is still loading", Date() < deadline else { break }
                    Thread.sleep(forTimeInterval: 0.25)
                } while true
            }
            var found = [ClingSearchResult]()
            if problem == nil {
                let response = FuzzyClient.handleCLIRequest(search, coordinator: coordinator)
                found = response.results ?? []
                problem = response.error.map { $0.prefix(1).uppercased() + $0.dropFirst() }
            }
            items = found.dropFirst(from).prefix(Self.pageSize).compactMap { item($0.path, isDir: $0.isDir) }
            more = found.count > wanted && wanted < Self.maxResults
            if let folder {
                header = .folder(folder)
            }
        }

        let nextURL = more ? WebPage.resultsURL(query: q, folder: folder, from: wanted, options: options) : nil
        let searching = !query.isEmpty || filtering
        if from > 0 {
            let browsing = folder != nil && !searching
            return WebPage.rows(items, selected: selected, webkit: webkit, browsing: browsing) + WebPage.moreSentinel(nextURL)
        }
        // Nothing found with options on: say which, with a way to search without them.
        var narrowed: (names: String, clearURL: String)?
        if items.isEmpty, searching, !options.params.isEmpty {
            let names = WebPage.optionsNames(options, choices: searchChoices())
            if !names.isEmpty {
                narrowed = (names, WebPage.pageURL(query: q, folder: folder))
            }
        }
        return WebPage.listing(header: header, items: items, selected: selected, webkit: webkit, next: nextURL, searching: searching, problem: problem, narrowed: narrowed)
    }

    /// What the options sheet offers, read from the search window's own state: the scopes it searches (the free ones
    /// without Pro), its drives (none without Pro), and the user's filters.
    private func searchChoices() -> WebPage.Choices {
        waitOnMain(timeout: 2) {
            let offline = Set(FUZZY.disconnectedVolumes.map(\.name.string))
            return WebPage.Choices(
                scopes: FUZZY.searchableScopes.map { ($0.rawValue, $0.label) },
                drives: FUZZY.driveEngines.map { ($0.label, !offline.contains($0.label)) },
                allDrives: FUZZY.offersAllDrivesFilter && !FUZZY.driveEngines.isEmpty,
                // The fallbacks are the window's, for a filter never given an icon or a colour.
                quickFilters: Defaults[.quickFilters].map {
                    .init(name: $0.id, icon: $0.icon ?? "line.3.horizontal.decrease.circle.fill", hue: ($0.color ?? .forName($0.id)).hue)
                },
                folderFilters: Defaults[.folderFilters].map {
                    .init(name: $0.id, icon: $0.icon ?? "folder.fill", hue: ($0.color ?? .forName($0.id)).hue)
                }
            )
        } ?? WebPage.Choices()
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// A folder's visible contents, folders first, in Finder's name order.
    private func folderChildren(_ folder: String) -> [WebItem] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        let items = names.lazy
            .filter { !$0.hasPrefix(".") && $0 != "Icon\r" }
            .prefix(5000)
            .compactMap { self.item(folder == "/" ? "/" + $0 : folder + "/" + $0, isDir: nil) }
            .filter { !$0.hidden }
        return items.sorted { a, b in
            a.browsable != b.browsable ? a.browsable : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// The row for `path`, or nil when it is gone. A path on a drive that isn't connected keeps its row, marked as
    /// such, the way the window shows it.
    private func item(_ path: String, isDir: Bool?) -> WebItem? {
        guard !Self.isPrivate(path) else { return nil }
        var st = Darwin.stat()
        guard stat(path, &st) == 0 else {
            let parts = path.split(separator: "/", maxSplits: 2)
            if parts.count >= 2, parts[0] == "Volumes", !FileManager.default.fileExists(atPath: "/Volumes/" + parts[1]) {
                return WebItem(path: path, isDir: isDir ?? false, isPackage: false, size: nil, modified: nil, offline: true)
            }
            return nil
        }
        let dir = st.st_mode & S_IFMT == S_IFDIR
        let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        return WebItem(
            path: path, isDir: dir, isPackage: dir && Self.isPackage(path), size: dir ? nil : UInt64(st.st_size),
            modified: modified, offline: false, hidden: st.st_flags & UInt32(UF_HIDDEN) != 0, readable: WebViewKind.readable(st)
        )
    }

    // MARK: Selection

    /// One `p` from a checkbox, or every row a two-finger glide crossed, sent once when the fingers lift.
    private func select(_ request: HTTPRequest, sid: String) -> HTTPResponse {
        let paths = request.form.filter { $0.name == "p" }.compactMap { Self.cleanPath($0.value) }
        guard !paths.isEmpty else { return .text("Bad request", status: 400) }
        let on = request.formValue("on") == "true"
        lock.withLock {
            var selection = sessions[sid]?.selection ?? []
            selection.removeAll { paths.contains($0) }
            if on {
                selection.append(contentsOf: paths)
            }
            sessions[sid]?.selection = selection
        }
        return .html(selectionBar(sid: sid))
    }

    /// A drop link (Send Securely) to the selection, or to the one file in `p`, opened by Cling on the Mac. Waits for
    /// the room without holding a thread: a folder is zipped first, which can take a while.
    private func shareLink(_ request: HTTPRequest, sid: String) async -> HTTPResponse {
        let raw = request.formValue("sel") == "1" ? selection(sid) : request.form.filter { $0.name == "p" }.map(\.value)
        let paths = raw.compactMap(Self.cleanPath).filter { path in item(path, isDir: nil).map { !$0.offline } ?? false }
        guard !paths.isEmpty else { return Self.json(["error": "Nothing to share"], status: 400) }
        // From the page's send dialog, one of the steps the Mac's own Send Securely offers.
        let expiration = request.formValue("exp").flatMap(TimeInterval.init).flatMap { LINK_EXPIRATION_PRESETS.contains($0) ? $0 : nil }
            ?? Defaults[.defaultLinkExpiration]

        let answer: LinkAnswer = await withCheckedContinuation { continuation in
            let once = OnceFlag()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    SendManager.shared.link(files: paths.map { URL(fileURLWithPath: $0) }, expiration: expiration) { link in
                        if once.take() {
                            let expires = link.flatMap { link in SendManager.shared.sessions.first { $0.shareURL == link }?.expiresAt }
                            continuation.resume(returning: link.map { .ready($0, expires: expires) } ?? .failed)
                        }
                    }
                }
            }
            Self.work.asyncAfter(deadline: .now() + Self.linkWait) {
                if once.take() {
                    continuation.resume(returning: .stillZipping)
                }
            }
        }
        switch answer {
        case let .ready(link, expires):
            var answer: [String: Any] = ["url": link]
            if let expires {
                answer["expires"] = Int(expires.timeIntervalSince1970)
            }
            return Self.json(answer)
        case .stillZipping: return Self.json(["pending": true], status: 202)
        case .failed: return Self.json(["error": "Couldn't create a link"], status: 502)
        }
    }

    /// What a folder's or a package's ZIP will weigh, measured for up to a second, for the page to decide whether to
    /// ask first. `floor` says the measuring ran out of time, so the size is a lower bound.
    private func sizeResponse(_ raw: String) -> HTTPResponse {
        guard let path = Self.cleanPath(raw), let item = item(path, isDir: nil), !item.offline else { return notFound() }
        let size = item.isDir ? folderSize(path, within: 1) : (bytes: item.size ?? 0, complete: true)
        return Self.json(["bytes": size.bytes, "label": WebPage.formatBytes(size.bytes), "floor": !size.complete])
    }

    private func clearSelection(sid: String) -> HTTPResponse {
        lock.withLock {
            if let selection = sessions[sid]?.selection, !selection.isEmpty {
                sessions[sid]?.cleared = selection
            }
            sessions[sid]?.selection = []
        }
        // On the body: the button that asked is gone by the time the event fires, swapped out with the bar.
        return HTTPResponse.html(selectionBar(sid: sid)).header("HX-Trigger", #"{"cling:cleared": {"target": "body"}}"#)
    }

    /// Puts back what Clear took away, after anything selected since. The page gets the bar and the paths to check.
    private func undoClear(sid: String) -> HTTPResponse {
        let restored: [String] = lock.withLock {
            guard var session = sessions[sid] else { return [] }
            let back = session.cleared.filter { !session.selection.contains($0) }
            session.selection = back + session.selection
            session.cleared = []
            sessions[sid] = session
            return back
        }
        return Self.json(["bar": selectionBar(sid: sid), "paths": restored])
    }

    private func selectionSheet(_ request: HTTPRequest, sid: String) -> HTTPResponse {
        let items = selection(sid).compactMap { item($0, isDir: nil) }
        return .html(WebPage.sheet(items, webkit: Self.isWebKit(request)))
    }

    private func selectionBar(sid: String) -> String {
        let items = selection(sid).compactMap { item($0, isDir: nil) }.filter { !$0.offline }
        guard !items.isEmpty else { return WebPage.selectionBar(nil) }

        var bytes: UInt64 = 0
        var complete = true
        for item in items {
            if item.isDir {
                let size = folderSize(item.path)
                bytes += size.bytes
                complete = complete && size.complete
            } else {
                bytes += item.size ?? 0
            }
        }
        let paths = items.map(\.path)
        let id = bundleID(for: paths)
        let summary = WebPage.SelectionSummary(
            count: items.count,
            bytes: bytes,
            complete: complete,
            downloads: items.map { WebPage.downloadURL($0.path) },
            zipURL: "/z/\(id)/" + WebPage.encodePath(zipName(for: paths)),
            name: items.count == 1 ? items[0].name : "\(items.count) files",
            folder: items.count == 1 && items[0].browsable
        )
        return WebPage.selectionBar(summary)
    }

    private func bundleID(for paths: [String]) -> String {
        let digest = SHA256.hash(data: Data(paths.joined(separator: "\n").utf8))
        let id = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        lock.withLock {
            if bundles[id] == nil {
                bundles[id] = paths
                bundleOrder.append(id)
                if bundleOrder.count > 256 {
                    bundles[bundleOrder.removeFirst()] = nil
                }
            }
        }
        return id
    }

    /// The parent folder's name when everything picked shares one, otherwise the Mac's.
    private func zipName(for paths: [String]) -> String {
        if paths.count == 1 {
            return (paths[0] as NSString).lastPathComponent + ".zip"
        }
        let parents = Set(paths.map { ($0 as NSString).deletingLastPathComponent })
        let base = parents.count == 1 ? (parents.first! as NSString).lastPathComponent : macName
        return "\(base.isEmpty || base == "/" ? macName : base) (\(paths.count) items).zip"
    }

    /// Bytes under `path`, counted for at most `within` seconds so a huge folder can't hold up the bar. A count that
    /// ran out of time is counted again when asked to take longer.
    private func folderSize(_ path: String, within: TimeInterval = 0.25) -> (bytes: UInt64, complete: Bool) {
        if let known = lock.withLock({ folderSizes[path] }), Date().timeIntervalSince(known.made) < 60, known.complete || within <= 0.25 {
            return (known.bytes, known.complete)
        }
        let deadline = Date().addingTimeInterval(within)
        var bytes: UInt64 = 0
        var complete = true
        let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.fileSizeKey], options: [], errorHandler: { _, _ in true })
        var n = 0
        while let url = enumerator?.nextObject() as? URL {
            bytes += UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            n += 1
            if n % 256 == 0, Date() > deadline {
                complete = false
                break
            }
        }
        lock.withLock { folderSizes[path] = (bytes, complete, Date()) }
        return (bytes, complete)
    }

    // MARK: Files

    private func file(_ request: HTTPRequest, _ raw: String, download: Bool) -> HTTPResponse {
        guard let path = Self.cleanPath(raw) else { return notFound() }
        var st = Darwin.stat()
        guard stat(path, &st) == 0 else { return notFound() }
        let name = Self.requestedName(raw)

        if st.st_mode & S_IFMT == S_IFDIR {
            if !download, !Self.isPackage(path) {
                return .redirect(WebPage.pageURL(query: "", folder: path), status: 302)
            }
            return zip(request, items: [(path, name)], name: name + ".zip")
        }
        guard st.st_mode & S_IFMT == S_IFREG else { return notFound() }

        let size = UInt64(st.st_size)
        let kind = download ? nil : WebViewKind.of(path, size: size, webkit: Self.isWebKit(request), readable: WebViewKind.readable(st))
        let viewable = kind != nil && kind != WebViewKind.none
        let etag = "\"\(st.st_ino)-\(st.st_size)-\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)\""
        var headers: [(String, String)] = [
            ("Content-Type", viewable ? Self.mimeType(path, inline: kind) : (download ? Self.mimeType(path, inline: nil) : "application/octet-stream")),
            ("Content-Disposition", Self.disposition(viewable ? "inline" : "attachment", name)),
            ("Cache-Control", "private, no-cache"),
        ]
        if kind == .html || (path as NSString).pathExtension.lowercased() == "svg" {
            // A page or an SVG from disk runs as an origin of its own: no scripts, no cookies, no reach into the
            // search or the other files.
            headers.append(("Content-Security-Policy", "sandbox"))
        }
        return serve(request, length: size, etag: etag, modified: TimeInterval(st.st_mtimespec.tv_sec), headers: headers) { range in
            FileStream(path: path, offset: range.lowerBound, length: range.upperBound - range.lowerBound + 1)
        }
    }

    private func serve(
        _ request: HTTPRequest, length: UInt64, etag: String, modified: TimeInterval, headers: [(String, String)],
        open: (ClosedRange<UInt64>) -> HTTPBodyStream?
    ) -> HTTPResponse {
        let lastModified = Self.httpDate.string(from: Date(timeIntervalSince1970: modified))
        let common = headers + [("ETag", etag), ("Last-Modified", lastModified), ("Accept-Ranges", "bytes")]
        if request.headers["range"] == nil, request.headers["if-none-match"] == etag {
            return HTTPResponse(status: 304, headers: common)
        }
        switch Self.range(request, length: length, etag: etag, lastModified: lastModified) {
        case .unsatisfiable:
            return HTTPResponse(status: 416, headers: common + [("Content-Range", "bytes */\(length)")])
        case .full:
            guard length > 0 else { return HTTPResponse(status: 200, headers: common, body: .data(Data())) }
            guard let stream = open(0 ... length - 1) else { return unreadable() }
            return HTTPResponse(status: 200, headers: common, body: .stream(stream))
        case let .partial(range):
            guard let stream = open(range) else { return unreadable() }
            return HTTPResponse(status: 206, headers: common + [("Content-Range", "bytes \(range.lowerBound)-\(range.upperBound)/\(length)")], body: .stream(stream))
        }
    }

    private func unreadable() -> HTTPResponse {
        .html(WebPage.message(title: "Cling can't read this file", body: "", assetVersion: assetVersion, home: true), status: 403)
    }

    // MARK: ZIP

    private func bundleZip(_ request: HTTPRequest, _ rest: String) -> HTTPResponse {
        let parts = rest.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let paths = lock.withLock({ bundles[String(parts[0])] }) else { return notFound() }
        let items = paths.compactMap { path in Self.cleanPath(path).map { ($0, Self.requestedName(path)) } }
        return zip(request, items: items, name: String(parts[1]))
    }

    /// `items` are real paths from `cleanPath`, each with the name its entry gets.
    private func zip(_ request: HTTPRequest, items: [(path: String, name: String)], name: String) -> HTTPResponse {
        guard !items.isEmpty else { return notFound() }
        let key = items.map { "\($0.path)\t\($0.name)" }.joined(separator: "\n")

        var archive = lock.withLock { () -> ZipArchive? in
            guard let plan = plans[key], Date().timeIntervalSince(plan.made) < 600 else { return nil }
            return plan.archive
        }
        // A plan is reused while a dropped download resumes; a new download looks at the files again.
        if archive == nil || request.headers["range"] == nil {
            do {
                archive = try ZipArchive(items: items)
            } catch {
                return .html(WebPage.message(title: "Too many files to zip (more than \(ZipArchive.maxEntries.formatted()))", body: "", assetVersion: assetVersion, home: true), status: 413)
            }
            lock.withLock {
                plans = plans.filter { Date().timeIntervalSince($0.value.made) < 600 }
                plans[key] = (archive!, Date())
            }
        }
        guard let archive else { return notFound() }
        let headers: [(String, String)] = [
            ("Content-Type", "application/zip"),
            ("Content-Disposition", Self.disposition("attachment", name)),
            ("Cache-Control", "private, no-cache"),
        ]
        return serve(request, length: archive.length, etag: archive.etag, modified: TimeInterval(archive.lastModified), headers: headers) { range in
            ZipStream(archive: archive, range: range)
        }
    }

    // MARK: Thumbnails

    private func thumbnail(_ request: HTTPRequest, _ raw: String) async -> HTTPResponse {
        let path = await withCheckedContinuation { continuation in
            Self.work.async { continuation.resume(returning: Self.cleanPath(raw)) }
        }
        guard let path else { return notFound() }
        // Points: a row's 48 by default, larger for the preview beside the list.
        let points = min(max(Int(request.param("s") ?? "") ?? 48, 48), 512)
        let cacheKey = "\(path)|\(request.param("v") ?? "")|\(points)" as NSString
        let png: Bool
        var data = thumbnails.object(forKey: cacheKey) as Data?
        if data == nil, let made = await makeThumbnail(path, points: points) {
            data = made
            thumbnails.setObject(made as NSData, forKey: cacheKey, cost: made.count)
        }
        guard let data else { return notFound() }
        png = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        return HTTPResponse(status: 200, headers: [
            ("Content-Type", png ? "image/png" : "image/jpeg"),
            // The URL carries the file's date and size, so a changed file gets a new URL.
            ("Cache-Control", "private, max-age=604800, immutable"),
        ], body: .data(data))
    }

    private func makeThumbnail(_ path: String, points: Int) async -> Data? {
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: points, height: points),
            scale: 3,
            representationTypes: .all
        )
        let ext = (path as NSString).pathExtension.lowercased()
        let mayHaveAlpha = ["png", "gif", "webp", "heic", "heif", "tif", "tiff", "svg", "ico", "icns", "pdf", "avif"].contains(ext)
        return await withCheckedContinuation { continuation in
            let once = OnceFlag()
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                guard once.take() else { return }
                guard let representation else {
                    continuation.resume(returning: nil)
                    return
                }
                let png = representation.type == .icon || mayHaveAlpha
                continuation.resume(returning: Self.encodeThumbnail(representation.cgImage, png: png))
            }
            // Quick Look can stall on a sleeping drive; the row keeps its plain icon instead.
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
                guard once.take() else { return }
                QLThumbnailGenerator.shared.cancel(request)
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: App

    /// What installing the page as an app reads: open to any browser, since the icons and launch screens are only
    /// Cling's, and a browser fetches some of them without its cookies. The manifest names the Mac and carries the key
    /// only for one signed in.
    private func appRoute(_ request: HTTPRequest, path: String) async -> HTTPResponse? {
        guard request.method == "GET" || request.method == "HEAD" else { return nil }
        let immutable = ("Cache-Control", "public, max-age=31536000, immutable")
        switch path {
        case "/manifest.webmanifest":
            let signedIn = authorized(request)
            let data = WebApp.manifest(
                name: signedIn ? "Cling · \(macName)" : "Cling",
                startURL: signedIn ? "/pair/\(key)" : "/",
                version: assetVersion
            )
            return HTTPResponse(status: 200, headers: [("Content-Type", "application/manifest+json"), ("Cache-Control", "no-store")], body: .data(data))
        case "/sw.js":
            // Checked on every visit, so a new version of the page replaces the old one's cache.
            let script = Data(WebApp.serviceWorker(version: assetVersion).utf8)
            return HTTPResponse(status: 200, headers: [("Content-Type", "text/javascript; charset=utf-8"), ("Cache-Control", "no-cache")], body: .data(script))
        default:
            break
        }
        let art = art
        let image: (@Sendable () -> Data?)? = switch path {
        case "/apple-touch-icon.png": { art.fullBleedIcon(size: 180) }
        case "/icon-maskable-512.png": { art.fullBleedIcon(size: 512) }
        case "/icon-192.png": { art.icon(size: 192) }
        case "/icon-512.png": { art.icon(size: 512) }
        default:
            if path.hasPrefix("/splash/"), path.hasSuffix(".png"),
               let spec = WebApp.splashSpec(String(path.dropFirst("/splash/".count).dropLast(".png".count)))
            {
                { art.splash(width: spec.width, height: spec.height, dark: spec.dark) }
            } else {
                nil
            }
        }
        guard let image else { return nil }
        return await offload {
            guard let data = image() else { return .text("Not found", status: 404) }
            return HTTPResponse(status: 200, headers: [("Content-Type", "image/png"), immutable], body: .data(data))
        }
    }

    // MARK: Assets

    private func asset(_ request: HTTPRequest, _ name: String) -> HTTPResponse {
        guard let asset = assets[name] else { return .text("Not found", status: 404) }
        var headers: [(String, String)] = [
            ("Content-Type", asset.type),
            // Asset URLs carry a hash of their contents.
            ("Cache-Control", "public, max-age=31536000, immutable"),
            ("Vary", "Accept-Encoding"),
        ]
        if request.acceptsGzip, let gzipped = asset.gzipped {
            headers.append(("Content-Encoding", "gzip"))
            return HTTPResponse(status: 200, headers: headers, body: .data(gzipped))
        }
        return HTTPResponse(status: 200, headers: headers, body: .data(asset.data))
    }

    /// An SF Symbol in one of the options sheet's colours (`WebPage.SymbolColor`), for light or dark.
    private func symbol(_ request: HTTPRequest, _ name: String) -> HTTPResponse {
        let color: CGColor? = switch request.param("c") ?? "" {
        case "orange": WebAppArt.orange(dark: request.param("d") == "1")
        case "gray": WebAppArt.gray(dark: request.param("d") == "1")
        case let hue: Double(hue).flatMap { (0 ... 1).contains($0) ? WebAppArt.filterColor(hue: $0, dark: request.param("d") == "1") : nil }
        }
        guard let color, name.count <= 80, name.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == ".") }),
              let data = art.symbol(name, color: color)
        else { return .text("Not found", status: 404) }
        return HTTPResponse(status: 200, headers: [("Content-Type", "image/png"), ("Cache-Control", "public, max-age=604800")], body: .data(data))
    }

    private func iconResponse() -> HTTPResponse {
        guard let icon else { return .text("Not found", status: 404) }
        return HTTPResponse(status: 200, headers: [("Content-Type", "image/png"), ("Cache-Control", "public, max-age=86400")], body: .data(icon))
    }
}

// MARK: - OnceFlag

/// True for the first `take`, false after: whichever of a result and its timeout arrives first wins.
final class OnceFlag: @unchecked Sendable {
    func take() -> Bool {
        lock.withLock {
            guard !taken else { return false }
            taken = true
            return true
        }
    }

    private let lock = NSLock()
    private var taken = false
}
