//
//  WebAccessSettingsPane.swift
//  Cling
//
//  Settings > File server: the switch, the port, and the link (with its QR code) that signs a browser in. Copy is
//  drafted in docs/web-access-copy.md.
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
        // A VPN's DNS can come up after its address does.
        .onAppear {
            if serving {
                web.lookUpHostnames()
            }
        }
    }

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

    /// The picked host, or the first one while it's away (a DNS name before its lookup lands, a VPN that's off).
    private var current: WebLink? {
        web.links.first { $0.id == linkHost } ?? web.links.first
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
