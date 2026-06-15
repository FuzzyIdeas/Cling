import Defaults
import SwiftUI

struct SendExpirationPopover: View {
    let files: [URL]
    var onSent: () -> Void
    @State private var expiration: TimeInterval = Defaults[.defaultLinkExpiration]

    private var index: Binding<Double> {
        Binding(
            get: { Double(nearestExpirationPresetIndex(expiration)) },
            set: { expiration = LINK_EXPIRATION_PRESETS[max(0, min(LINK_EXPIRATION_PRESETS.count - 1, Int($0.rounded())))] }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Link expires in \(expirationDurationLabel(expiration))").font(.headline)
            Slider(value: index, in: 0 ... Double(LINK_EXPIRATION_PRESETS.count - 1), step: 1)
            Button("Copy link, expires in \(expirationShortLabel(expiration))") {
                SendManager.shared.requestSend(files: files, expiration: expiration)
                onSent()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(files.isEmpty)
        }
        .padding(14)
        .frame(width: 280)
    }
}
