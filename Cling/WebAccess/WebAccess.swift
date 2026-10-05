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
import SystemConfiguration

extension Defaults.Keys {
    static let webAccessEnabled = Key<Bool>("webAccessEnabled", default: false)
    /// "CLING" on a phone keypad.
    static let webAccessPort = Key<Int>("webAccessPort", default: 25464)
    /// What the pairing link carries and every browser keeps as a cookie. Made on first use, replaced to sign every
    /// browser out.
    static let webAccessKey = Key<String>("webAccessKey", default: "")
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
    var host: String {
        address.contains(":") ? "[\(address)]" : address
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

    var running: Bool {
        httpServer != nil
    }

    /// Watches the settings and the network. Called once at launch.
    func start() {
        pub(.webAccessEnabled).sink { _ in mainAsync { self.apply() } }.store(in: &observers)
        pub(.webAccessPort).sink { _ in mainAsync { self.apply() } }.store(in: &observers)
        pub(.webAccessKey).sink { change in mainAsync { self.server?.key = change.newValue } }.store(in: &observers)
        apply()
    }

    func pairingURL(for address: WebAddress) -> String {
        "http://\(address.host):\(Defaults[.webAccessPort])/pair/\(Defaults[.webAccessKey])"
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
                icon: Self.iconPNG(size: 64)
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
        }
        addresses = Self.localAddresses()
        listen()
    }

    @ObservationIgnored private var observers: Set<AnyCancellable> = []
    @ObservationIgnored private var server: WebAccessServer?
    @ObservationIgnored private var httpServer: HTTPServer?
    @ObservationIgnored private var store: SCDynamicStore?
    @ObservationIgnored private var networkChange: DispatchWorkItem?

    private func listen() {
        let port = Defaults[.webAccessPort]
        guard let httpServer, Self.portRange.contains(port) else { return }
        httpServer.listen(on: addresses.map(\.address), port: UInt16(port))
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

        let names = interfaceNames()
        var found = [WebAddress]()
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
            found.append(WebAddress(address: address, interface: interface, label: label(interface, address: address, names: names)))
        }
        return found.sorted { rank($0) < rank($1) }
    }

    /// The private ranges a browser on the same network or VPN can reach: RFC 1918, link-local, CGNAT (Tailscale and
    /// other VPNs), and 127.0.0.1 for this Mac.
    nonisolated static func isPrivateIPv4(_ v: UInt32) -> Bool {
        v >> 24 == 10 || v >> 20 == 0xAC1 || v >> 16 == 0xC0A8 || v >> 22 == 0x191 || v >> 16 == 0xA9FE || v == 0x7F00_0001
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

    private nonisolated static func label(_ interface: String, address: String, names: [String: String]) -> String {
        if interface.hasPrefix("lo") {
            return "This Mac"
        }
        let tailscale = address.hasPrefix("fd7a:115c:a1e0:") || {
            let parts = address.split(separator: ".").compactMap { UInt32($0) }
            return parts.count == 4 && parts[0] == 100 && parts[1] & 0xC0 == 64
        }()
        if interface.hasPrefix("utun"), tailscale {
            return "Tailscale"
        }
        if interface.hasPrefix("utun") || interface.hasPrefix("ipsec") || interface.hasPrefix("ppp") {
            return "VPN"
        }
        return names[interface] ?? interface
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
