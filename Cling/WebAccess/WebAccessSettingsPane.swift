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
                Toggle("Enable file server", isOn: $enabled)
                TextField("Port", value: portBinding, format: .number.grouping(.never))
                    .monospacedDigit()
                ForEach(failureLines, id: \.self) { line in
                    Text(line).font(.callout).foregroundStyle(.red)
                }
            }

            if enabled {
                Section("Devices") {
                    if let current {
                        Picker("Network", selection: hostBinding) {
                            ForEach(web.links) { link in
                                Text(link.title).tag(link.id)
                            }
                        }
                        let link = current.pairingURL(port: port, key: key)
                        HStack(spacing: 18) {
                            QRCodeView(text: link)
                                .frame(width: 136, height: 136)
                            CopyablePill(value: link)
                        }
                        .padding(.vertical, 4)
                    } else {
                        Text("Not connected to a network").foregroundStyle(.secondary)
                    }
                    HStack {
                        // Always through 127.0.0.1: this Mac can't reach its own address on a VPN tunnel through
                        // Network.framework's listener, and loopback works whatever network it is on.
                        Button("Open") {
                            if let url = URL(string: "http://127.0.0.1:\(port)/pair/\(key)") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        Button("Sign out all devices") {
                            if confirmSignOut() {
                                web.signOutEverywhere()
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        // A VPN's DNS can come up after its address does.
        .onAppear {
            if enabled {
                web.lookUpHostnames()
            }
        }
    }

    @Default(.webAccessEnabled) private var enabled
    @Default(.webAccessPort) private var port
    @Default(.webAccessKey) private var key
    @Default(.webAccessLinkHost) private var linkHost

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
