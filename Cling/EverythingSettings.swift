import Defaults
import SwiftUI

// MARK: - EverythingSettingsSection

/// Settings > Search: Everything's switch, and its saved index with a way to delete it.
///
/// Turning it off asks about the saved index, since reclaiming that space is a common reason to turn it off. Keeping
/// it lets Everything load and replay what changed when it is turned back on, instead of walking the disks again.
/// Turning it on starts nothing: as on a fresh install, the first Everything search loads or walks it.
struct EverythingSettingsSection: View {
    var body: some View {
        Section("Everything") {
            Toggle("Enable Everything", isOn: Binding(
                get: { everythingEnabled },
                set: { on in
                    if !on, everything.savedBytes > 0 {
                        confirmingOff = true
                    } else {
                        setEnabled(on)
                    }
                }
            ))
            .onAppear { everything.refreshSavedBytes() }
            .alert("Delete the Everything index?", isPresented: $confirmingDelete) {
                Button("Delete", role: .destructive) { everything.deleteIndex() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Frees \(size). The next Everything search walks the local disks again to rebuild it.")
            }
            .alert("Delete the Everything index too? (\(size))", isPresented: $confirmingOff) {
                Button("Delete", role: .destructive) {
                    everything.deleteIndex()
                    setEnabled(false)
                }
                Button("Keep", role: .cancel) { setEnabled(false) }
            }

            if everything.savedBytes > 0 {
                LabeledContent("Saved index") {
                    HStack(spacing: 8) {
                        Text(size)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Button("Delete…") { confirmingDelete = true }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    @State private var everything = EVERYTHING
    @State private var confirmingDelete = false
    @State private var confirmingOff = false

    @Default(.everythingEnabled) private var everythingEnabled

    private var size: String {
        EverythingIndex.sizeText(everything.savedBytes)
    }

    /// Applied right away rather than when the setting's publisher gets to it, so the window and the bar follow at once.
    private func setEnabled(_ on: Bool) {
        everythingEnabled = on
        everything.applySetting()
    }
}
