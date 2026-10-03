import AppKit
import Defaults
import Lowtech
import SwiftUI

// MARK: - MCPSettingsPane

/// Cling's MCP server, and which agents it is installed into. The server is bundled; installing writes one
/// entry into an agent's own config file.
///
/// Same job and copy as Clop's `MCPSettingsView`, built out of Cling's own Form rows. Keep the behaviour in
/// step, not the markup.
struct MCPSettingsPane: View {
    var body: some View {
        Form {
            Section("MCP") {
                Toggle(isOn: $mcpEnabled) {
                    Text("Enable MCP")
                    Text("Allow agents to control Cling, search files, manage indexes, change settings, write filters")
                }
                // A two-line label in a grouped Form reaches AX unnamed.
                .accessibilityLabel("Enable MCP")
                .onChange(of: mcpEnabled) { MCPInstaller.writeServerCard() }

                Toggle(isOn: $mcpAllowScripts) {
                    Text("Allow agents to write arbitrary scripts")
                    Text("Using scripts allows for flexible operations but can be dangerous if not properly verified")
                }
                .accessibilityLabel("Allow agents to write arbitrary scripts")
                .disabled(!mcpEnabled)
                .onChange(of: mcpAllowScripts) {
                    MCPInstaller.writeServerCard()
                    guard mcpAllowScripts else { return }
                    if !askAboutScripts() {
                        mcpAllowScripts = false
                    }
                }
            }

            Section("Install in") {
                ForEach(MCPInstaller.featuredClients) { client in
                    clientRow(client)
                }
                DisclosureGroup("See more", isExpanded: $showMoreClients) {
                    ForEach(MCPInstaller.moreClients) { client in
                        clientRow(client)
                    }
                }
            }

            Section("Install by hand") {
                CopyableValueRow(title: "Command line", value: MCPInstaller.cliCommand)
                CopyableValueRow(title: "Server", value: MCPInstaller.cliPath + " " + MCPInstaller.serveArgs.joined(separator: " "))
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear(perform: refresh)
    }

    @State private var states: [String: MCPInstaller.ConfigState] = [:]
    @State private var failures: [String: String] = [:]
    @State private var showMoreClients = false

    @Default(.mcpEnabled) private var mcpEnabled
    @Default(.mcpAllowScripts) private var mcpAllowScripts

    private func clientRow(_ client: MCPInstaller.Client) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(client.name)
                // A client with nothing to say shows nothing, rather than an empty line that makes its row
                // taller than the rest.
                let detail = rowDetail(client)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            switch states[client.id] ?? .notInstalled {
            case .installed:
                Button("Remove") { apply(MCPInstaller.remove(client), to: client) }
                    .tint(.red)
            case .unusable:
                // Not a disabled Install: there is no members list to write into, so the only move left is
                // to open the file.
                Button("Show file") { MCPInstaller.revealConfig(client) }
            case .notInstalled:
                Button("Install") { apply(MCPInstaller.install(client), to: client) }
            }
        }
    }

    private func apply(_ result: Result<Void, Error>, to client: MCPInstaller.Client) {
        if case let .failure(error) = result {
            failures[client.id] = error.localizedDescription
        } else {
            // A later success has to clear the earlier failure, or the row keeps showing an error it no
            // longer has.
            failures[client.id] = nil
        }
        refresh()
    }

    private func rowDetail(_ client: MCPInstaller.Client) -> String {
        if let failure = failures[client.id] {
            return failure
        }
        switch states[client.id] ?? .notInstalled {
        case .unusable:
            return "\(client.path) is not a JSON object."
        case .installed, .notInstalled:
            // Once it is added, the useful detail is where it landed.
            return client.isPresent || states[client.id] == .installed
                ? client.path
                : "Not installed on this Mac."
        }
    }

    private func refresh() {
        states = Dictionary(uniqueKeysWithValues: MCPInstaller.clients.map { ($0.id, MCPInstaller.state($0)) })
    }

    private func askAboutScripts() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Allow agents to write scripts?"
        alert.informativeText = """
        A script runs arbitrary code on the files you select.

        Without human verification, it can result in irretrievable file losses as scripts are not sandboxed in any way.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - CopyableValueRow

/// A row whose value is the copy control: click the pill to copy it.
private struct CopyableValueRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            CopyablePill(value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - CopyablePill

private struct CopyablePill: View {
    let value: String

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copied = true
            mainAsyncAfter(ms: 1200) { copied = false }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.system(size: 9, weight: .semibold))
                    // Fixed footprint so the glyph swap can't reflow the pill.
                    .frame(width: 12, height: 12)
                Text(copied ? "Copied!" : value)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Copies the line")
    }

    @State private var copied = false
}
