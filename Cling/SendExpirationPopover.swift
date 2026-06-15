import Defaults
import SwiftUI

struct SendExpirationPopover: View {
    let files: [URL]
    @Binding var expiration: TimeInterval
    var onSent: () -> Void

    private var index: Binding<Double> {
        Binding(
            get: { Double(nearestExpirationPresetIndex(expiration)) },
            set: { expiration = LINK_EXPIRATION_PRESETS[max(0, min(LINK_EXPIRATION_PRESETS.count - 1, Int($0.rounded())))] }
        )
    }

    private var fileSummary: String {
        files.count == 1 ? files[0].lastPathComponent : "\(files.count) items"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Send securely").font(.headline)
                    Text(fileSummary)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Link expires", systemImage: "clock")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Text(expirationDurationLabel(expiration))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .contentTransition(.numericText())
                }
                Slider(value: index, in: 0 ... Double(LINK_EXPIRATION_PRESETS.count - 1), step: 1)
                    .animation(.snappy(duration: 0.2), value: expiration)
                HStack {
                    Text(expirationShortLabel(LINK_EXPIRATION_PRESETS[0]))
                    Spacer()
                    Text(expirationShortLabel(LINK_EXPIRATION_PRESETS[LINK_EXPIRATION_PRESETS.count - 1]))
                }
                .font(.caption2).foregroundStyle(.tertiary)
            }

            Button {
                SendManager.shared.requestSend(files: files, expiration: expiration)
                onSent()
            } label: {
                Label("Copy link & share", systemImage: "link")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(files.isEmpty)
        }
        .padding(16)
        .frame(width: 300)
    }
}
