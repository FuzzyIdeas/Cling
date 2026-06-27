import SwiftUI

// MARK: - TransfersPanel

struct TransfersPanel: View {
    @ObservedObject var manager = SendManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Transfers").font(.headline)
                Spacer()
                if activeCount > 0 {
                    Text("\(activeCount) active")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                if manager.recentSessions.contains(where: \.stopped) {
                    Button("Clear") { withAnimation { manager.clearFinished() } }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Remove finished transfers from the list")
                }
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)

            if manager.recentSessions.isEmpty {
                Text("No transfers yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                Divider()
                ForEach(manager.recentSessions) { session in
                    TransferRow(session: session, now: now)
                    if session.id != manager.recentSessions.last?.id {
                        Divider().padding(.leading, 12)
                    }
                }
            }
        }
        .frame(width: 340)
        .onAppear { startTicking() }
        .onDisappear { ticker?.cancel(); ticker = nil }
    }

    @State private var now = Date()
    @State private var ticker: Task<Void, Never>?

    private var activeCount: Int {
        manager.sessions.count
    }

    /// Tick `now` only while the popover is on screen, and only as often as needed: every second
    /// when the soonest expiry is under an hour out, every minute otherwise. Cancelled on disappear
    /// so no clock work happens while the popover is hidden.
    private func startTicking() {
        ticker?.cancel()
        now = Date()
        ticker = Task { @MainActor in
            while !Task.isCancelled {
                let soonest = manager.recentSessions
                    .filter { !$0.stopped }
                    .compactMap { $0.expiresAt?.timeIntervalSince(now) }
                    .filter { $0 > 0 }
                    .min()
                let delay: Double = soonest.map { $0 > 3600 ? 60 : 1 } ?? 60
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { break }
                now = Date()
            }
        }
    }

}

// MARK: - TransferRow

private struct TransferRow: View {
    @ObservedObject var session: SendSession
    @ObservedObject var manager = SendManager.shared

    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: session.files.count > 1 ? "doc.on.doc.fill" : "doc.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 28, height: 28)
                    .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.fileSummary)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1).truncationMode(.middle)
                        .help(session.fileNames)
                    HStack(spacing: 6) {
                        statusPill
                        if session.downloadCount > 0 {
                            Label("\(session.downloadCount)", systemImage: "arrow.down.circle.fill")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            if !session.stopped {
                HStack(spacing: 6) {
                    Button { session.copyLink() } label: {
                        Label("Copy link", systemImage: "link")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)

                    Menu {
                        ForEach(LINK_EXPIRATION_PRESETS, id: \.self) { e in
                            Button(expirationDurationLabel(e)) { manager.reschedule(session, to: e) }
                        }
                    } label: {
                        Label("Reschedule", systemImage: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .fixedSize()

                    Spacer(minLength: 0)

                    Button(role: .destructive) { manager.stop(session) } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .opacity(session.stopped ? 0.65 : 1)
    }

    private var accent: Color {
        session.stopped ? .secondary : .accentColor
    }

    @ViewBuilder private var statusPill: some View {
        if session.stopped {
            pill("Stopped", color: .secondary)
        } else if let label = session.expiresLabel(asOf: now) {
            pill(label, color: .accentColor)
        }
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.12), in: Capsule())
    }
}
