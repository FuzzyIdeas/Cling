//
//  WebAccess.swift
//  Cling
//
//  Web Access: search this Mac and download its files from a browser on a phone or another computer, over the local
//  network or a VPN. Off until the user turns it on in Settings.
//
//  It listens on the Mac's private addresses only, one listener each: the LAN (10/8, 172.16/12, 192.168/16),
//  link-local IPv4, Tailscale and other CGNAT VPNs (100.64/10), IPv6 unique-local, and loopback. Never on 0.0.0.0 or a
//  public address, so a Mac plugged straight into the internet doesn't serve it there, and no firewall rule is needed.
//  Addresses come and go with the network (Wi-Fi changes, a VPN connects), and the listeners follow.
//

import AppKit
import Combine
import Defaults
import Foundation
import Lowtech
import Network
import SystemConfiguration

extension Defaults.Keys {
    static let webAccessEnabled = Key<Bool>("webAccessEnabled", default: false)
    /// "CLING" on a phone keypad.
    static let webAccessPort = Key<Int>("webAccessPort", default: 25464)
    /// What the pairing link carries and every browser keeps as a cookie. Made on first use, replaced to sign every
    /// browser out.
    static let webAccessKey = Key<String>("webAccessKey", default: "")
    /// The host the pairing link carries (an address or a DNS name), as last picked. Empty for the first one listed.
    static let webAccessLinkHost = Key<String>("webAccessLinkHost", default: "")
    /// Serve the Tailscale addresses over HTTPS. Off until asked for: getting the certificate puts the Mac's Tailscale
    /// name in Let's Encrypt's public certificate logs.
    static let webAccessHTTPS = Key<Bool>("webAccessHTTPS", default: false)
}

// MARK: - WebAddress

struct WebAddress: Hashable, Identifiable {
    let address: String
    let interface: String
    /// What the network is to the user: Wi-Fi, Ethernet, Tailscale, VPN, This Mac.
    let label: String

    var id: String {
        address
    }
    var isLoopback: Bool {
        interface.hasPrefix("lo")
    }
    var isTailscale: Bool {
        label == "Tailscale"
    }
    var host: String {
        address.contains(":") ? "[\(address)]" : address
    }
}

// MARK: - WebLink

/// One way another device can reach this Mac, for the pairing link: an address, or the DNS name the network gives it.
struct WebLink: Hashable, Identifiable {
    /// As it goes in a URL: a name, an IPv4 address, or an IPv6 one in brackets.
    let host: String
    /// Served over HTTPS, with Tailscale's certificate for the name.
    var secure = false
    /// Tailscale · black.tail1c1c.ts.net
    let title: String

    var id: String {
        host
    }

    func pairingURL(port: Int, key: String) -> String {
        "\(secure ? "https" : "http")://\(host):\(port)/pair/\(key)"
    }
}

// MARK: - WebAccess

@MainActor @Observable
final class WebAccess {
    static let shared = WebAccess()

    static let portRange = 1024 ... 65535

    /// Every address the server listens on, the LAN first and this Mac last.
    private(set) var addresses: [WebAddress] = []
    /// Why a listener isn't up, by address.
    private(set) var failures: [String: String] = [:]
    /// The name the network's DNS gives an address and leads back to it, by address: Tailscale's MagicDNS name, or a
    /// VPN's or a router's.
    private(set) var hostnames: [String: String] = [:]
    /// The MagicDNS name the Tailscale addresses serve HTTPS for, while they do.
    private(set) var secureHost: String?
    /// The name Tailscale would issue this Mac a certificate for, asked without getting one. Settings offers HTTPS only
    /// while there is one.
    private(set) var certificateDomain: String?

    var running: Bool {
        httpServer != nil
    }

    /// What the pairing link can carry, each address with its DNS name first, since a name outlives the address. With
    /// HTTPS on, Tailscale's addresses offer only the name its certificate is for.
    var links: [WebLink] {
        var links = [WebLink]()
        for address in addresses where !address.isLoopback {
            if address.isTailscale, let secureHost {
                if !links.contains(where: { $0.host == secureHost }) {
                    links.append(WebLink(host: secureHost, secure: true, title: "\(address.label) · \(secureHost)"))
                }
                continue
            }
            if let name = hostnames[address.address], !links.contains(where: { $0.host == name }) {
                links.append(WebLink(host: name, title: "\(address.label) · \(name)"))
            }
            links.append(WebLink(host: address.host, title: "\(address.label) · \(address.address)"))
        }
        return links
    }

    /// Watches the settings and the network. Called once at launch.
    func start() {
        pub(.webAccessEnabled).sink { _ in mainAsync { self.apply() } }.store(in: &observers)
        pub(.webAccessPort).sink { _ in mainAsync { self.apply() } }.store(in: &observers)
        pub(.webAccessKey).sink { change in mainAsync { self.server?.key = change.newValue } }.store(in: &observers)
        pub(.webAccessHTTPS).sink { _ in mainAsync { self.httpsChanged() } }.store(in: &observers)
        apply()
    }

    /// Reverse lookups wait on the network's DNS, so they run off the main thread and land when they're done.
    func lookUpHostnames() {
        let addresses = addresses.filter { !$0.isLoopback }.map(\.address)
        hostnameLookup?.cancel()
        hostnameLookup = Task.detached(priority: .utility) {
            let names = Self.hostnames(of: addresses)
            await MainActor.run {
                if !Task.isCancelled {
                    WebAccess.shared.hostnames = names
                }
            }
        }
    }

    /// A new key: every browser has to open the new link to get back in.
    func signOutEverywhere() {
        Defaults[.webAccessKey] = WebAccessServer.randomToken()
    }

    func apply() {
        guard Defaults[.webAccessEnabled] else {
            httpServer?.stop()
            httpServer = nil
            server = nil
            failures = [:]
            hostnameLookup?.cancel()
            hostnames = [:]
            certificateTimer?.invalidate()
            certificateTimer = nil
            certificate = nil
            certificateChecked = nil
            secureHost = nil
            certificateDomain = nil
            return
        }
        if Defaults[.webAccessKey].isEmpty {
            Defaults[.webAccessKey] = WebAccessServer.randomToken()
        }
        if httpServer == nil {
            let server = WebAccessServer(
                coordinator: FUZZY.searchCoordinator,
                key: Defaults[.webAccessKey],
                macName: SCDynamicStoreCopyComputerName(nil, nil) as String? ?? Host.current().localizedName ?? "Mac",
                icon: Self.iconPNG(size: 64),
                appIcon: Self.appIcon()
            )
            let http = HTTPServer { request in await server.handle(request) }
            http.onStateChange = { [weak self] address, state in
                MainActor.assumeIsolated {
                    switch state {
                    case let .failed(reason): self?.failures[address] = reason
                    default: self?.failures[address] = nil
                    }
                }
            }
            self.server = server
            httpServer = http
            watchNetwork()
            // tailscale cert renews a certificate only when asked, so ask a few times a day.
            certificateTimer = Timer.scheduledTimer(withTimeInterval: 4 * 3600, repeats: true) { _ in
                MainActor.assumeIsolated { WebAccess.shared.refreshCertificate() }
            }
        }
        addresses = Self.localAddresses()
        listen()
        lookUpHostnames()
        checkTailscale()
        refreshCertificate()
    }

    /// Fetches Tailscale's certificate for this Mac when HTTPS is on and a Tailscale address is up, then restarts those
    /// listeners with TLS, or with the renewed certificate. Off the main thread: a first certificate can take a minute.
    func refreshCertificate() {
        guard #available(macOS 15, *), Defaults[.webAccessHTTPS], running, certificateFetch == nil,
              addresses.contains(where: \.isTailscale)
        else { return }
        if let certificateChecked, certificate != nil, Date().timeIntervalSince(certificateChecked) < 3 * 3600 {
            return
        }
        certificateFetch = Task.detached(priority: .utility) {
            var certificate: TailscaleTLS.Certificate?
            if let cli = TailscaleTLS.cli(), let domain = TailscaleTLS.domain(cli: cli) {
                certificate = TailscaleTLS.certificate(cli: cli, domain: domain)
            }
            await MainActor.run { WebAccess.shared.certificateArrived(certificate) }
        }
    }

    @ObservationIgnored private var observers: Set<AnyCancellable> = []
    @ObservationIgnored private var hostnameLookup: Task<Void, Never>?
    @ObservationIgnored private var certificate: TailscaleTLS.Certificate?
    @ObservationIgnored private var certificateFetch: Task<Void, Never>?
    @ObservationIgnored private var certificateChecked: Date?
    @ObservationIgnored private var certificateTimer: Timer?
    @ObservationIgnored private var tailscaleCheck: Task<Void, Never>?

    @ObservationIgnored private var server: WebAccessServer?
    @ObservationIgnored private var httpServer: HTTPServer?
    @ObservationIgnored private var store: SCDynamicStore?
    @ObservationIgnored private var networkChange: DispatchWorkItem?

    /// Asks Tailscale for this Mac's name and whether the tailnet issues certificates, which gets none. Needs macOS 15,
    /// the first that keeps a certificate's key in memory instead of the keychain.
    private func checkTailscale() {
        guard #available(macOS 15, *), running, tailscaleCheck == nil else { return }
        guard addresses.contains(where: \.isTailscale) else {
            certificateDomain = nil
            return
        }
        tailscaleCheck = Task.detached(priority: .utility) {
            let domain = TailscaleTLS.cli().flatMap { TailscaleTLS.domain(cli: $0) }
            await MainActor.run {
                WebAccess.shared.tailscaleCheck = nil
                WebAccess.shared.certificateDomain = domain
            }
        }
    }

    private func httpsChanged() {
        guard running else { return }
        if Defaults[.webAccessHTTPS] {
            refreshCertificate()
        } else {
            certificate = nil
            certificateChecked = nil
            secureHost = nil
            listen()
        }
    }

    /// A failed refresh keeps the certificate already served: it stays valid for weeks.
    private func certificateArrived(_ new: TailscaleTLS.Certificate?) {
        certificateFetch = nil
        certificateChecked = Date()
        guard running, Defaults[.webAccessHTTPS], let new, new.leaf != certificate?.leaf || new.domain != certificate?.domain else { return }
        webLog.info("Serving HTTPS for \(new.domain, privacy: .public)")
        certificate = new
        secureHost = new.domain
        listen()
    }
    private func listen() {
        let port = Defaults[.webAccessPort]
        guard let httpServer, Self.portRange.contains(port) else { return }
        var tls = [String: sec_identity_t]()
        if let certificate {
            for address in addresses where address.isTailscale {
                tls[address.address] = certificate.identity
            }
        }
        httpServer.listen(on: addresses.map(\.address), port: UInt16(port), tls: tls)
    }

    /// Follows address changes on every interface, a VPN's included, through the system's network store.
    private func watchNetwork() {
        guard store == nil else { return }
        guard let store = SCDynamicStoreCreate(nil, "Cling Web Access" as CFString, { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { WebAccess.shared.networkChanged() } }
        }, nil) else { return }
        let patterns = [
            "State:/Network/Interface/.*/IPv4", "State:/Network/Interface/.*/IPv6",
            "State:/Network/Service/.*/IPv4", "State:/Network/Service/.*/IPv6",
            "State:/Network/Global/IPv4", "State:/Network/Global/IPv6",
        ]
        SCDynamicStoreSetNotificationKeys(store, nil, patterns as CFArray)
        SCDynamicStoreSetDispatchQueue(store, .main)
        self.store = store
    }

    /// Settles for a second first: joining a network changes several keys in a row.
    private func networkChanged() {
        networkChange?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, running else { return }
            let current = Self.localAddresses()
            guard current != addresses else { return }
            addresses = current
            listen()
            lookUpHostnames()
            checkTailscale()
            refreshCertificate()
        }
        networkChange = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
}

// MARK: - Addresses

extension WebAccess {
    nonisolated static func localAddresses() -> [WebAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var found = [(address: String, interface: String)]()
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = pointer.pointee
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, let sa = ifa.ifa_addr else { continue }
            let interface = String(cString: ifa.ifa_name)
            // AirDrop's and the iPhone mirroring links, which no browser reaches.
            guard !["awdl", "llw", "anpi", "ap"].contains(where: { interface.hasPrefix($0) }) else { continue }

            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            switch Int32(sa.pointee.sa_family) {
            case AF_INET:
                var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                let value = UInt32(bigEndian: addr.s_addr)
                guard isPrivateIPv4(value) else { continue }
                // 100.64/10 is a VPN's on a tunnel (Tailscale's), but a carrier's shared space on Wi-Fi or Ethernet,
                // with strangers in it.
                if value >> 22 == 0x191, !interface.hasPrefix("utun") {
                    continue
                }
                inet_ntop(AF_INET, &addr, &text, socklen_t(text.count))
            case AF_INET6:
                var addr = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                // Unique-local only (fc00::/7, Tailscale's among them). Link-local needs a zone no URL can carry,
                // and a global address may be reachable from anywhere.
                guard addr.__u6_addr.__u6_addr8.0 & 0xFE == 0xFC else { continue }
                inet_ntop(AF_INET6, &addr, &text, socklen_t(text.count))
            default:
                continue
            }
            let address = String(cString: text)
            guard !found.contains(where: { $0.address == address }) else { continue }
            found.append((address, interface))
        }

        let names = interfaceNames()
        let vpns = vpnNames()
        // A tunnel carrying a Tailscale IPv6 address is Tailscale's, its 100.x address too. The 100.64/10 range alone
        // doesn't say so: NetBird and others use it.
        let tailscale = Set(found.filter { $0.address.hasPrefix("fd7a:115c:a1e0:") }.map(\.interface))
        return found.map { address, interface in
            let label = if interface.hasPrefix("lo") {
                "This Mac"
            } else if tailscale.contains(interface) {
                "Tailscale"
            } else if ["utun", "ipsec", "ppp"].contains(where: { interface.hasPrefix($0) }) {
                vpns[interface] ?? "VPN"
            } else {
                names[interface] ?? interface
            }
            return WebAddress(address: address, interface: interface, label: label)
        }
        .sorted { rank($0) < rank($1) }
    }

    /// The name the network's DNS gives each address, by address. Kept only when it leads back to one of these
    /// addresses, since DNS can still hold a name for an address that moved, and only with a dot in it, since a bare
    /// name (one from /etc/hosts, say) may resolve on this Mac alone.
    nonisolated static func hostnames(of addresses: [String]) -> [String: String] {
        let ours = Set(addresses)
        var names = [String: String]()
        for address in addresses {
            guard let name = reverseLookup(address), name.contains("."), !name.hasSuffix(".arpa"),
                  !forwardLookup(name).isDisjoint(with: ours)
            else { continue }
            names[address] = name
        }
        return names
    }

    /// The private ranges a browser on the same network or VPN can reach: RFC 1918, link-local, CGNAT (Tailscale and
    /// other VPNs), and 127.0.0.1 for this Mac.
    nonisolated static func isPrivateIPv4(_ v: UInt32) -> Bool {
        v >> 24 == 10 || v >> 20 == 0xAC1 || v >> 16 == 0xC0A8 || v >> 22 == 0x191 || v >> 16 == 0xA9FE || v == 0x7F00_0001
    }

    /// The icon at 1024 pixels as the bundle ships it, not as the system styles it for the Dock.
    nonisolated static func appIcon() -> CGImage? {
        let image = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:))
            ?? NSImage(named: NSImage.applicationIconName)
        var rect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        return image?.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    nonisolated static func iconPNG(size: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSImage(named: NSImage.applicationIconName)?.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private nonisolated static func interfaceNames() -> [String: String] {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var names = [String: String]()
        for interface in all {
            if let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
               let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
            {
                names[bsd] = name
            }
        }
        return names
    }

    /// Each connected VPN's name as System Settings > VPN shows it (a WireGuard tunnel's, say), by tunnel interface.
    /// Tailscale's is "Tailscale" whatever it was renamed to there ("Tailscale 2" after a reinstall).
    private nonisolated static func vpnNames() -> [String: String] {
        let patterns = ["State:/Network/Service/[^/]+/IPv[46]", "Setup:/Network/Service/[^/]+", "Setup:/Network/Service/[^/]+/Interface"]
        guard let store = SCDynamicStoreCreate(nil, "Cling Web Access" as CFString, nil, nil),
              let values = SCDynamicStoreCopyMultiple(store, nil, patterns as CFArray) as? [String: Any]
        else { return [:] }

        var names = [String: String]()
        for (key, value) in values where key.hasPrefix("State:") {
            let parts = key.split(separator: "/")
            guard parts.count == 5, let interface = (value as? [String: Any])?["InterfaceName"] as? String else { continue }
            let setup = "Setup:/Network/Service/\(parts[3])"
            let provider = (values[setup + "/Interface"] as? [String: Any])?["SubType"] as? String ?? ""
            if provider.hasPrefix("io.tailscale.") {
                names[interface] = "Tailscale"
            } else if let name = (values[setup] as? [String: Any])?["UserDefinedName"] as? String, !name.isEmpty {
                names[interface] = name
            }
        }
        return names
    }

    private nonisolated static func reverseLookup(_ address: String) -> String? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(address, nil, &hints, &info) == 0, let info else { return nil }
        defer { freeaddrinfo(info) }

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD) == 0
        else { return nil }
        let name = String(cString: host).lowercased()
        return name.hasSuffix(".") ? String(name.dropLast()) : name
    }

    private nonisolated static func forwardLookup(_ name: String) -> Set<String> {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &info) == 0, let first = info else { return [] }
        defer { freeaddrinfo(info) }

        var found = Set<String>()
        for entry in sequence(first: first, next: { $0.pointee.ai_next }) {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                found.insert(String(cString: host))
            }
        }
        return found
    }

    private nonisolated static func rank(_ address: WebAddress) -> Int {
        if address.isLoopback {
            return 3
        }
        if address.interface.hasPrefix("en") {
            return address.address.contains(":") ? 1 : 0
        }
        if address.interface.hasPrefix("utun") {
            return 1
        }
        return 2
    }
}
