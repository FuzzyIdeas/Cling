//
//  HTTPServer.swift
//  Cling
//
//  The HTTP/1.1 server behind Web Access, on Network.framework. It listens on the addresses it is given and never
//  on 0.0.0.0, so nothing outside the local networks and VPNs the Mac is on can reach it. Bodies go out a chunk at a
//  time with backpressure, so a video or a ZIP of a whole folder never sits in memory.
//
//  Caddy was the other candidate. It would add about 40 MB per architecture for what is a few hundred lines here,
//  and it could still not do the parts that matter: the search, the ZIP stream and the thumbnails all live in Cling.
//

import Foundation
import Network
import os.log
import zlib

let webLog = Logger(subsystem: "com.lowtechguys.Cling", category: "WebAccess")

// MARK: - HTTPRequest

struct HTTPRequest {
    let method: String
    /// Percent-decoded, without the query.
    let path: String
    let query: [(name: String, value: String)]
    /// Names lowercased. A repeated header keeps its values joined with ", ".
    let headers: [String: String]
    let body: Data

    var isHTMX: Bool {
        headers["hx-request"] == "true"
    }
    var acceptsGzip: Bool {
        headers["accept-encoding"]?.contains("gzip") ?? false
    }

    var cookies: [String: String] {
        guard let raw = headers["cookie"] else { return [:] }
        var cookies = [String: String]()
        for pair in raw.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            cookies[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return cookies
    }

    var form: [(name: String, value: String)] {
        HTTPRequest.parseURLEncoded(String(decoding: body, as: UTF8.self))
    }

    static func parseURLEncoded(_ string: String) -> [(name: String, value: String)] {
        string.split(separator: "&").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first.flatMap({ decodeComponent($0) }), !name.isEmpty else { return nil }
            return (name, parts.count > 1 ? decodeComponent(parts[1]) ?? "" : "")
        }
    }

    static func decodeComponent(_ s: Substring) -> String? {
        s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }

    func param(_ name: String) -> String? {
        query.first { $0.name == name }?.value
    }

    func formValue(_ name: String) -> String? {
        form.first { $0.name == name }?.value
    }
}

// MARK: - HTTPBodyStream

/// A body produced as it is sent. `read` is called on the connection's queue, one call at a time.
protocol HTTPBodyStream: AnyObject {
    /// The exact number of bytes all the reads add up to.
    var length: UInt64 { get }
    /// Up to `max` bytes. Empty data is the end; a throw drops the connection, which the browser shows as a failed
    /// download it can retry.
    func read(max: Int) throws -> Data
    func close()
}

// MARK: - HTTPResponse

final class HTTPResponse: @unchecked Sendable {
    init(status: Int = 200, headers: [(String, String)] = [], body: Body = .none) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    enum Body {
        case none
        case data(Data)
        case stream(HTTPBodyStream)
    }

    var status: Int
    var headers: [(String, String)]
    var body: Body
    /// Gzipped when the browser takes it: pages, fragments and assets. Files go out as they are.
    var compressible = false

    static func html(_ html: String, status: Int = 200) -> HTTPResponse {
        let response = HTTPResponse(status: status, headers: [
            ("Content-Type", "text/html; charset=utf-8"),
            ("Cache-Control", "no-store"),
        ], body: .data(Data(html.utf8)))
        response.compressible = true
        return response
    }

    static func redirect(_ location: String, status: Int = 303) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Location", location), ("Cache-Control", "no-store")])
    }

    static func text(_ text: String, status: Int) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")], body: .data(Data(text.utf8)))
    }

    @discardableResult
    func header(_ name: String, _ value: String) -> HTTPResponse {
        headers.append((name, value))
        return self
    }
}

// MARK: - FileStream

/// A byte range of one file, read with `pread` so nothing but the current chunk is in memory.
final class FileStream: HTTPBodyStream {
    init?(path: String, offset: UInt64, length: UInt64) {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        self.fd = fd
        self.offset = offset
        self.length = length
        remaining = length
    }

    deinit { close() }

    let length: UInt64

    func read(max: Int) throws -> Data {
        guard remaining > 0, fd >= 0 else { return Data() }
        let want = Int(min(UInt64(max), remaining))
        var data = Data(count: want)
        let got = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, want, off_t(offset)) }
        guard got > 0 else {
            // The file got shorter since its size went out in Content-Length.
            throw POSIXError(got < 0 ? POSIXErrorCode(rawValue: errno) ?? .EIO : .EIO)
        }
        if got < want {
            data.count = got
        }
        offset += UInt64(got)
        remaining -= UInt64(got)
        return data
    }

    func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }

    private var fd: Int32
    private var offset: UInt64
    private var remaining: UInt64
}

// MARK: - Gzip

enum Gzip {
    static func compress(_ data: Data, level: Int32 = 6) -> Data? {
        var stream = z_stream()
        // 15 window bits, plus 16 for the gzip wrapper instead of zlib's.
        guard deflateInit2_(&stream, level, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return nil
        }
        defer { deflateEnd(&stream) }
        var out = Data(count: Int(deflateBound(&stream, uLong(data.count))) + 32)
        let result: Int32 = data.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(src.count)
                stream.next_out = dst.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(dst.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard result == Z_STREAM_END else { return nil }
        out.count = Int(stream.total_out)
        return out
    }
}

// MARK: - HTTPConnection

typealias HTTPHandler = @Sendable (HTTPRequest) async -> HTTPResponse

// MARK: - HTTPConnection

/// One client connection: reads requests one after another (keep-alive) and answers each in turn.
final class HTTPConnection: @unchecked Sendable {
    init(_ connection: NWConnection, handler: @escaping HTTPHandler, onClose: @escaping (HTTPConnection) -> Void) {
        self.connection = connection
        self.handler = handler
        self.onClose = onClose
        queue = DispatchQueue(label: "com.lowtechguys.Cling.WebAccess.connection", qos: .userInitiated)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
        queue.async { [self] in
            armIdleTimer()
            readNext()
        }
    }

    func cancel() {
        queue.async { [self] in close() }
    }

    private enum Parsed {
        case incomplete
        case request(HTTPRequest, keepAlive: Bool)
        case bad(Int)
    }

    /// A body this big or bigger is refused: the forms the page posts are a path and a flag.
    private static let maxBody = 1 << 20
    private static let maxHead = 32 << 10
    /// How long a connection with no request in progress stays open.
    private static let idleTimeout: DispatchTimeInterval = .seconds(75)
    private static let chunkSize = 1 << 20

    private let connection: NWConnection
    private let handler: HTTPHandler
    private let onClose: (HTTPConnection) -> Void
    private let queue: DispatchQueue
    private var buffer = Data()
    private var closed = false
    private var idleTimer: DispatchSourceTimer?

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 206: "Partial Content"
        case 301: "Moved Permanently"
        case 302: "Found"
        case 303: "See Other"
        case 304: "Not Modified"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Content Too Large"
        case 416: "Range Not Satisfiable"
        case 431: "Request Header Fields Too Large"
        case 501: "Not Implemented"
        case 503: "Service Unavailable"
        default: status < 400 ? "OK" : "Error"
        }
    }

    private func armIdleTimer() {
        idleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.idleTimeout)
        timer.setEventHandler { [weak self] in self?.close() }
        timer.resume()
        idleTimer = timer
    }

    private func disarmIdleTimer() {
        idleTimer?.cancel()
        idleTimer = nil
    }

    private func close() {
        guard !closed else { return }
        closed = true
        disarmIdleTimer()
        connection.cancel()
        onClose(self)
    }

    private func readNext() {
        guard !closed else { return }
        switch parse() {
        case let .request(request, keepAlive):
            disarmIdleTimer()
            let handler = handler
            Task {
                let response = await handler(request)
                self.queue.async { self.send(response, for: request, keepAlive: keepAlive) }
            }
        case let .bad(status):
            disarmIdleTimer()
            let request = HTTPRequest(method: "GET", path: "/", query: [], headers: [:], body: Data())
            send(.text("Bad request", status: status), for: request, keepAlive: false)
        case .incomplete:
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    buffer.append(data)
                } else if isComplete || error != nil {
                    close()
                    return
                }
                readNext()
            }
        }
    }

    private func parse() -> Parsed {
        guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > Self.maxHead ? .bad(431) : .incomplete
        }
        let head = String(decoding: buffer[buffer.startIndex ..< headEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3 else { return .bad(400) }

        var headers = [String: String]()
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        guard headers["transfer-encoding"] == nil else { return .bad(501) }
        let bodyLength = Int(headers["content-length"] ?? "0") ?? -1
        guard bodyLength >= 0, bodyLength <= Self.maxBody else { return .bad(413) }
        let bodyStart = headEnd.upperBound
        guard buffer.count - (bodyStart - buffer.startIndex) >= bodyLength else { return .incomplete }

        let body = Data(buffer[bodyStart ..< bodyStart + bodyLength])
        buffer = Data(buffer[(bodyStart + bodyLength)...])

        let target = String(requestLine[1])
        let rawPath = String(target.prefix { $0 != "?" })
        let rawQuery = target.dropFirst(rawPath.count + 1)
        guard rawPath.hasPrefix("/"), let path = rawPath.removingPercentEncoding, !path.contains("\0") else {
            return .bad(400)
        }
        let version = requestLine[2]
        let connectionHeader = headers["connection"]?.lowercased() ?? ""
        let keepAlive = version == "HTTP/1.1" ? !connectionHeader.contains("close") : connectionHeader.contains("keep-alive")
        let request = HTTPRequest(
            method: String(requestLine[0]).uppercased(),
            path: path,
            query: HTTPRequest.parseURLEncoded(String(rawQuery)),
            headers: headers,
            body: body
        )
        return .request(request, keepAlive: keepAlive)
    }

    private func send(_ response: HTTPResponse, for request: HTTPRequest, keepAlive: Bool) {
        guard !closed else {
            if case let .stream(stream) = response.body {
                stream.close()
            }
            return
        }
        var payload: Data?
        var stream: HTTPBodyStream?
        var length: UInt64 = 0
        switch response.body {
        case .none:
            break
        case var .data(data):
            if response.compressible, request.acceptsGzip, data.count > 860, let gzipped = Gzip.compress(data) {
                data = gzipped
                response.headers.append(("Content-Encoding", "gzip"))
                response.headers.append(("Vary", "Accept-Encoding"))
            }
            payload = data
            length = UInt64(data.count)
        case let .stream(s):
            stream = s
            length = s.length
        }
        let head = request.method == "HEAD"
        if head {
            stream?.close()
            stream = nil
            payload = nil
        }

        var text = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        for (name, value) in response.headers {
            text += "\(name): \(value)\r\n"
        }
        if response.status != 304, response.status >= 200 {
            text += "Content-Length: \(length)\r\n"
        }
        text += keepAlive ? "Connection: keep-alive\r\n" : "Connection: close\r\n"
        text += "\r\n"
        var first = Data(text.utf8)
        if let payload {
            first.append(payload)
        }

        connection.send(content: first, completion: .contentProcessed { [weak self] error in
            guard let self else {
                stream?.close()
                return
            }
            guard error == nil else {
                stream?.close()
                close()
                return
            }
            if let stream {
                pump(stream, keepAlive: keepAlive)
            } else {
                finish(keepAlive: keepAlive)
            }
        })
    }

    private func pump(_ stream: HTTPBodyStream, keepAlive: Bool) {
        guard !closed else {
            stream.close()
            return
        }
        let chunk: Data
        do {
            chunk = try stream.read(max: Self.chunkSize)
        } catch {
            webLog.error("Stopped sending a body: \(error.localizedDescription)")
            stream.close()
            close()
            return
        }
        guard !chunk.isEmpty else {
            stream.close()
            finish(keepAlive: keepAlive)
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                stream.close()
                self?.close()
                return
            }
            pump(stream, keepAlive: keepAlive)
        })
    }

    private func finish(keepAlive: Bool) {
        guard keepAlive else {
            close()
            return
        }
        armIdleTimer()
        readNext()
    }

}

// MARK: - HTTPServer

/// Listeners on a set of addresses, all on one port, and the connections they accept.
final class HTTPServer: @unchecked Sendable {
    init(handler: @escaping HTTPHandler) {
        self.handler = handler
    }

    enum ListenerState: Equatable {
        case starting
        case ready
        case failed(String)
        case stopped
    }

    /// Called on the main queue whenever one address's listener changes state.
    var onStateChange: ((String, ListenerState) -> Void)?

    /// Listens on exactly `addresses`, with TLS on those `tls` has an identity for: new ones start, missing ones stop,
    /// one whose identity changed restarts, and a new port restarts them all.
    func listen(on addresses: [String], port: UInt16, tls: [String: sec_identity_t] = [:]) {
        queue.async { [self] in
            if port != self.port {
                for (address, current) in listeners {
                    current.listener.cancel()
                    report(address, .stopped)
                }
                listeners.removeAll()
                self.port = port
            }
            wanted = Dictionary(uniqueKeysWithValues: addresses.map { ($0, Want(tls: tls[$0])) })
            for (address, current) in listeners where !(wanted[address].map { Self.same($0.tls, current.tls) } ?? false) {
                current.listener.cancel()
                listeners[address] = nil
                report(address, .stopped)
            }
            for (address, want) in wanted where listeners[address] == nil {
                start(address, tls: want.tls)
            }
        }
    }

    func stop() {
        queue.async { [self] in
            wanted.removeAll()
            for (address, current) in listeners {
                current.listener.cancel()
                report(address, .stopped)
            }
            listeners.removeAll()
            for connection in connections.values {
                connection.cancel()
            }
            connections.removeAll()
        }
    }

    private struct Want {
        let tls: sec_identity_t?
    }

    /// Past this many open connections, new ones are turned away. A browser opens six per address at most, so this is
    /// a handful of devices with room to spare.
    private static let maxConnections = 128

    private let handler: HTTPHandler
    private let queue = DispatchQueue(label: "com.lowtechguys.Cling.WebAccess.server")
    private var wanted: [String: Want] = [:]
    private var listeners: [String: (listener: NWListener, tls: sec_identity_t?)] = [:]
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]
    private var port: UInt16 = 0

    private static func describe(_ error: NWError) -> String {
        if case let .posix(code) = error, code == .EADDRINUSE {
            return "in use"
        }
        if case let .posix(code) = error, code == .EADDRNOTAVAIL {
            return "address gone"
        }
        return error.localizedDescription
    }

    private static func same(_ a: sec_identity_t?, _ b: sec_identity_t?) -> Bool {
        (a as AnyObject?) === (b as AnyObject?)
    }

    private static func isInUse(_ error: NWError) -> Bool {
        if case let .posix(code) = error {
            return code == .EADDRINUSE
        }
        return false
    }

    private func report(_ address: String, _ state: ListenerState) {
        guard let onStateChange else { return }
        DispatchQueue.main.async {
            onStateChange(address, state)
        }
    }

    /// `attempt` counts tries after "in use": a listener restarting with a new certificate can find the one it
    /// replaces still letting go of the port.
    private func start(_ address: String, tls: sec_identity_t?, attempt: Int = 0) {
        guard let port = NWEndpoint.Port(rawValue: port) else { return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        // A phone that walks out of range mid-download, or leaves a paused video open, frees its connection within a
        // couple of minutes instead of holding it until TCP gives up.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        tcp.keepaliveInterval = 10
        tcp.keepaliveCount = 6
        var tlsOptions: NWProtocolTLS.Options?
        if let tls {
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(options.securityProtocolOptions, tls)
            sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
            sec_protocol_options_add_tls_application_protocol(options.securityProtocolOptions, "http/1.1")
            tlsOptions = options
        }
        let params = NWParameters(tls: tlsOptions, tcp: tcp)
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: port)
        params.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            report(address, .failed(error.localizedDescription))
            return
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                webLog.info("Listening on \(address, privacy: .public):\(port.rawValue)\(tls == nil ? "" : " with TLS", privacy: .public)")
                report(address, .ready)
            case let .failed(error):
                listener?.cancel()
                queue.async {
                    if self.listeners[address]?.listener === listener {
                        self.listeners[address] = nil
                    }
                    if Self.isInUse(error), attempt < 4 {
                        self.queue.asyncAfter(deadline: .now() + 0.5) {
                            guard self.listeners[address] == nil, let want = self.wanted[address], Self.same(want.tls, tls) else { return }
                            self.start(address, tls: tls, attempt: attempt + 1)
                        }
                        return
                    }
                    webLog.error("Listener on \(address, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    self.report(address, .failed(Self.describe(error)))
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            guard connections.count < Self.maxConnections else {
                connection.cancel()
                return
            }
            let client = HTTPConnection(connection, handler: handler) { [weak self] closed in
                self?.queue.async { self?.connections[ObjectIdentifier(closed)] = nil }
            }
            connections[ObjectIdentifier(client)] = client
            client.start()
        }
        listeners[address] = (listener, tls)
        report(address, .starting)
        listener.start(queue: queue)
    }

}
