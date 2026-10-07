//
//  WebAccessSettingsPane.swift
//  Cling
//
//  Settings > File server: the switch, the port, the link (with its QR code) that signs a browser in, and the
//  Tailscale steps for reaching it away from home.
//

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Defaults
import SwiftUI

// MARK: - WebAccessSettingsPane

struct WebAccessSettingsPane: View {
    var body: some View {
        Form {
            Section {
                // Shown off without Pro, though a lapsed licence leaves the setting on so the server comes back with it.
                Toggle(isOn: Binding(get: { serving }, set: { enabled = $0 })) {
                    HStack(spacing: 6) { Text("Enable file server"); ProBadge() }
                }
                .accessibilityLabel("Enable file server")
                TextField("Port", value: portBinding, format: .number.grouping(.never))
                    .monospacedDigit()
                LabeledContent("Confirm downloads over") {
                    HStack(spacing: 6) {
                        TextField("", value: $confirmOver, format: .number.grouping(.never))
                            .labelsHidden()
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                        Text("MB").foregroundStyle(.secondary)
                    }
                }
                ForEach(failureLines, id: \.self) { line in
                    Text(line).font(.callout).foregroundStyle(.red)
                }
                // Only where Tailscale would issue the certificate: anywhere else the switch could do nothing.
                if serving, let domain = web.certificateDomain {
                    Toggle("HTTPS on Tailscale", isOn: Binding(
                        get: { https },
                        set: { on in
                            if !on || confirmHTTPS(domain) {
                                https = on
                            }
                        }
                    ))
                }
            }
            .disabled(!proactive)

            if serving {
                Section("Devices") {
                    if let current {
                        Picker("Network", selection: hostBinding) {
                            ForEach(web.links) { link in
                                Text(link.title).tag(link.id)
                            }
                        }
                        let link = current.pairingURL(port: port, key: key)
                        VStack(spacing: 12) {
                            QRCodeView(text: link)
                                .frame(width: 200, height: 200)
                            CopyablePill(value: link)
                            actions.padding(.top, 6)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    } else {
                        Text("Not connected to a network").foregroundStyle(.secondary)
                        actions.frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $showRemoteAccess) {
            RemoteAccessSheet()
        }
        // A VPN's DNS can come up after its address does.
        .onAppear {
            if serving {
                web.lookUpHostnames()
            }
        }
    }

    @State private var showRemoteAccess = false

    @Default(.webAccessEnabled) private var enabled
    @Default(.webAccessPort) private var port
    @Default(.webAccessKey) private var key
    @Default(.webAccessLinkHost) private var linkHost
    @Default(.webAccessHTTPS) private var https
    @Default(.webAccessConfirmDownloadsOver) private var confirmOver

    private var serving: Bool {
        enabled && proactive
    }

    private var web: WebAccess {
        WebAccess.shared
    }

    /// The picked host, or while it's away (a DNS name before its lookup lands, a VPN that's off) Tailscale's, which
    /// works away from home too, or the first one.
    private var current: WebLink? {
        web.links.first { $0.id == linkHost } ?? web.links.first(where: \.tailscale) ?? web.links.first
    }

    private var hostBinding: Binding<String> {
        Binding(get: { current?.id ?? "" }, set: { linkHost = $0 })
    }

    private var portBinding: Binding<Int> {
        Binding(
            get: { port },
            set: { port = min(max($0, WebAccess.portRange.lowerBound), WebAccess.portRange.upperBound) }
        )
    }

    private var failureLines: [String] {
        web.failures.sorted { $0.key < $1.key }.map { address, reason in
            reason == "in use" ? "Port \(port) is in use on \(address)" : "\(address): \(reason)"
        }
    }

    /// Under the link they act on, rather than in a row of their own at the section's edge.
    private var actions: some View {
        HStack(spacing: 8) {
            // Always through 127.0.0.1: this Mac can't reach its own address on a VPN tunnel through
            // Network.framework's listener, and loopback works whatever network it is on.
            Button {
                if let url = URL(string: "http://127.0.0.1:\(port)/pair/\(key)") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Open", systemImage: "arrow.up.forward.app")
            }
            Button {
                if confirmSignOut() {
                    web.signOutEverywhere()
                }
            } label: {
                Label("Sign out all devices", systemImage: "rectangle.portrait.and.arrow.right")
            }
            Button {
                showRemoteAccess = true
            } label: {
                Label("Remote access", systemImage: "globe")
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
    }

    /// Asked before the first certificate, since getting one publishes the Mac's name on the tailnet.
    private func confirmHTTPS(_ domain: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Get an HTTPS certificate for this Mac?"
        alert.informativeText = "Tailscale gets it from Let's Encrypt, which lists every certificate in public logs, with this Mac's Tailscale name: \(domain)"
        alert.addButton(withTitle: "Get Certificate")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmSignOut() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Sign out all devices?"
        alert.informativeText = "Browsers using Cling need the new link or QR code to get back in."
        alert.addButton(withTitle: "Sign Out")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - RemoteAccessSheet

/// Tailscale, for reaching the file server away from home: its app on this Mac and on the phone, signed in to the
/// same account. Its address turns up by itself once it connects (`WebAccess.networkChanged`), and the pairing link
/// moves to it, since a Tailscale link works at home too.
struct RemoteAccessSheet: View {
    enum Phone: String, CaseIterable, Identifiable {
        case iPhone
        case android = "Android"

        var id: Self {
            self
        }

        var store: String {
            switch self {
            case .iPhone: "https://apps.apple.com/app/tailscale/id1470499037"
            case .android: "https://play.google.com/store/apps/details?id=com.tailscale.ipn"
            }
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                TailscaleIcon(app: app)
                    .frame(width: 72, height: 72)
                Text("Tailscale").font(.title2.weight(.semibold))
                Text("An easy way to create a private link between your devices")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button(app == nil ? "Get Tailscale for Mac" : "Open Tailscale") {
                if let app {
                    NSWorkspace.shared.open(app)
                } else if let store = URL(string: "macappstore://apps.apple.com/app/tailscale/id1475387142") {
                    NSWorkspace.shared.open(store)
                }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)

            VStack(spacing: 10) {
                QRCodeView(text: phone.store)
                    .frame(width: 150, height: 150)
                Picker("Phone", selection: $phone) {
                    ForEach(Phone.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            Text("Sign in with the same account on all devices")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                status
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400)
        // Set up for using it away from home: the link people pair with is Tailscale's from here on.
        .onChange(of: tailscaleLink?.id) { _, id in
            if let id {
                linkHost = id
            }
        }
        .onDisappear {
            if let tailscaleLink {
                linkHost = tailscaleLink.id
            }
        }
    }

    #if SEARCHBAR_BENCH
        /// Screenshots show an invented Tailscale name instead of the Mac's: `-searchBarShowcaseTailscaleHost mac.example.ts.net`.
        private static let shownHost = UserDefaults.standard.string(forKey: "searchBarShowcaseTailscaleHost")
    #else
        private static let shownHost: String? = nil
    #endif

    @Environment(\.dismiss) private var dismiss
    @State private var phone: Phone = .iPhone

    @Default(.webAccessLinkHost) private var linkHost

    /// Tailscale's app on this Mac: the App Store's, or the one from Tailscale's site.
    private var app: URL? {
        ["io.tailscale.ipn.macos", "io.tailscale.ipn.macsys"].lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    /// Its name for this Mac where it has one, otherwise its address.
    private var tailscaleLink: WebLink? {
        WebAccess.shared.links.first(where: \.tailscale)
    }

    @ViewBuilder private var status: some View {
        if let host = Self.shownHost ?? tailscaleLink?.host {
            Label {
                Text("Connected · \(host)")
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for Tailscale on this Mac")
            }
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - TailscaleIcon

/// The installed app's icon, or Tailscale's mark (nine dots, a T lit in them) drawn the way that icon shows it.
struct TailscaleIcon: View {
    let app: URL?

    var body: some View {
        if let app {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .aspectRatio(1, contentMode: .fit)
        } else {
            GeometryReader { geometry in
                let side = geometry.size.width
                let dot = side * 0.14
                ZStack {
                    RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                        .fill(Color(white: 0.12))
                    VStack(spacing: dot * 0.55) {
                        ForEach(Self.lit.indices, id: \.self) { row in
                            HStack(spacing: dot * 0.55) {
                                ForEach(Self.lit[row].indices, id: \.self) { column in
                                    Circle()
                                        .fill(Self.lit[row][column] ? Color.white : Color(white: 0.4))
                                        .frame(width: dot, height: dot)
                                }
                            }
                        }
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            // The size an app icon's artwork takes inside its frame.
            .padding(.all, 7)
        }
    }

    private static let lit: [[Bool]] = [[false, false, false], [true, true, true], [false, true, false]]
}

// MARK: - QRCodeView

/// The link as a QR code for a phone's camera, dark on white whatever the appearance, since that is what scanners
/// read best.
struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.image(text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .aspectRatio(1, contentMode: .fit)
                .padding(8)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private static let context = CIContext()

    private static func image(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return context.createCGImage(output, from: output.extent)
    }
}
