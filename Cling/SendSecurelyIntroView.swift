import SwiftUI

/// One-time explainer shown the first time someone uses Send securely, so the privacy model
/// (peer-to-peer, nothing uploaded) and the "keep the Mac running" requirement aren't a surprise.
struct SendSecurelyIntroView: View {
    var onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send securely").font(.title3).bold()
                    Text("Share files over a private link that expires on its own")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                point(
                    "lock.shield",
                    "Nothing leaves your Mac",
                    "Files travel straight from your Mac to whoever opens the link. They're never uploaded to a server or stored anywhere else."
                )
                point(
                    "bolt.horizontal.circle",
                    "Keep Cling running",
                    "The link only works while Cling and your Mac stay awake. The app can be hidden, but if you quit it or the Mac sleeps, the transfer stops."
                )
                point(
                    "clock",
                    "Links expire on their own",
                    "Each link stops working when its timer runs out, or the moment you stop the transfer."
                )
            }

            HStack {
                Spacer()
                Button("Continue") { onContinue() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 430)
    }

    private func point(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(body)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
