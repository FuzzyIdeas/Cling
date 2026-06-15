import SwiftUI

struct TransfersPanel: View {
    @ObservedObject var manager = SendManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if manager.recentSessions.isEmpty {
                Text("No transfers yet")
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ForEach(manager.recentSessions) { session in
                    TransferRow(session: session)
                    if session.id != manager.recentSessions.last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(8)
        .frame(width: 340)
    }
}

private struct TransferRow: View {
    @ObservedObject var session: SendSession
    @ObservedObject var manager = SendManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.fileNames)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 8) {
                if session.stopped {
                    Text("Stopped").foregroundStyle(.secondary)
                } else if let label = session.expiresInLabel {
                    Text(label).foregroundStyle(.secondary)
                }
                Text("Downloaded \(session.downloadCount)×").foregroundStyle(.secondary)
            }
            .font(.caption)

            HStack(spacing: 6) {
                Button("Copy link") { session.copyLink() }
                if !session.stopped {
                    Menu("Reschedule") {
                        ForEach(LINK_EXPIRATION_PRESETS, id: \.self) { e in
                            Button(expirationDurationLabel(e)) {
                                manager.reschedule(session, to: e)
                            }
                        }
                    }
                    .fixedSize()
                    Button("Stop", role: .destructive) { manager.stop(session) }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(8)
    }
}
