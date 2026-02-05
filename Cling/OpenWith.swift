import Lowtech
import SwiftUI
import System

struct OpenWithMenuView: View {
    let fileURLs: [URL]

    var body: some View {
        Menu("⌘O Open with...   ") {
            let apps = commonApplications(for: fileURLs).sorted(by: \.lastPathComponent)
            ForEach(apps, id: \.path) { app in
                Button(action: {
                    NSWorkspace.shared.open(
                        fileURLs, withApplicationAt: app, configuration: .init(),
                        completionHandler: { _, _ in }
                    )
                }) {
                    SwiftUI.Image(nsImage: icon(for: app))
                    Text(app.lastPathComponent.ns.deletingPathExtension)
                }
            }
        }
    }

}

struct OpenWithPickerView: View {
    let fileURLs: [URL]
    @Environment(\.dismiss) var dismiss
    @State private var fuzzy: FuzzyClient = FUZZY

    func openWithApp(_ app: URL) {
        RH.trackRun(fileURLs.compactMap(\.existingFilePath))
        NSWorkspace.shared.open(
            fileURLs, withApplicationAt: app, configuration: .init(),
            completionHandler: { _, _ in }
        )
        dismiss()
    }

    func appButton(_ app: URL) -> some View {
        Button(action: { openWithApp(app) }) {
            HStack {
                SwiftUI.Image(nsImage: icon(for: app))
                Text(app.lastPathComponent.ns.deletingPathExtension)

                if let shortcut = fuzzy.openWithAppShortcuts[app] {
                    Spacer()
                    Text(String(shortcut).uppercased()).monospaced().bold().foregroundColor(.secondary)
                }
            }.hfill()
        }
    }

    var appList: some View {
        ForEach(fuzzy.commonOpenWithApps, id: \.path) { app in
            appButton(app)
                .buttonStyle(FlatButton(color: .bg.primary.opacity(0.4), textColor: .primary))
                .ifLet(fuzzy.openWithAppShortcuts[app]) {
                    $0.keyboardShortcut(KeyEquivalent($1), modifiers: [])
                }
        }.focusable(false)
    }

    var body: some View {
        VStack {
            appList
        }
        .padding()
    }
}

struct OpenWithActionButtons: View {
    let selectedResults: Set<FilePath>

    var buttons: some View {
        ForEach(fuzzy.openWithAppShortcuts.sorted(by: \.key.lastPathComponent), id: \.0.path) { app, key in
            Button(action: {
                RH.trackRun(selectedResults)
                NSWorkspace.shared.open(selectedResults.map(\.url), withApplicationAt: app, configuration: .init(), completionHandler: { _, _ in })
            }) {
                HStack(spacing: 0) {
                    Text("\(key.uppercased())").mono(10, weight: .bold).foregroundColor(.fg.warm).roundbg(color: .bg.primary.opacity(0.2))
                    Text(" \(app.lastPathComponent.ns.deletingPathExtension)")
                }
            }
        }
        .buttonStyle(.borderlessText(color: .fg.warm.opacity(0.8)))
    }

    var body: some View {
        HStack {
            OpenWithMenuView(fileURLs: selectedResults.map(\.url))
                .help("Open the selected files with a specific app")
                .frame(width: 110, alignment: .leading)
                .disabled(selectedResults.isEmpty || fuzzy.openWithAppShortcuts.isEmpty)

            Divider().frame(height: 16)

            if fuzzy.openWithAppShortcuts.isEmpty {
                Text("Open with app hotkeys will appear here")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 10))
            } else {
                HStack(spacing: 1) {
                    Text("⌘").roundbg(color: .bg.primary.opacity(0.2))
                    Text("⌥").roundbg(color: .bg.primary.opacity(0.2))
                    Text(" +")
                }.foregroundColor(.fg.warm)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) { buttons }
                }
                Divider().frame(height: 16)
                ShareButton(urls: selectedResults.map(\.url))
                    .bold()
                    .buttonStyle(.borderlessText)
            }
        }
        .font(.system(size: 10))
        .buttonStyle(.text(color: .fg.warm.opacity(0.9)))
        .lineLimit(1)
    }

    @State private var fuzzy: FuzzyClient = FUZZY

}

func icon(for app: URL) -> NSImage {
    let i = NSWorkspace.shared.icon(forFile: app.path)
    i.size = NSSize(width: 14, height: 14)
    return i
}

extension URL {
    var bundleIdentifier: String? {
        guard let bundle = Bundle(url: self) else {
            return nil
        }
        return bundle.bundleIdentifier
    }
}
