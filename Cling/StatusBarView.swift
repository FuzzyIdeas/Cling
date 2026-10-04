//
//  StatusBarView.swift
//  Cling
//
//  Created by Alin Panaitiu on 08.02.2025.
//

import Defaults
import SwiftUI

struct StatusBarView: View {
    var body: some View {
        let bar = HStack {
            if !fuzzy.backgroundIndexing {
                Button(action: {
                    if fuzzy.volumeFilter == .allDrives {
                        fuzzy.indexVolumes(fuzzy.connectedDrives)
                    } else if let volume = fuzzy.volumeFilter, fuzzy.enabledVolumes.contains(volume) {
                        fuzzy.indexVolume(volume)
                    } else {
                        fuzzy.refresh()
                    }
                }) {
                    Image(systemName: "arrow.clockwise").bold()
                }
                .help(fuzzy.volumeFilter == .allDrives ? "Reindex connected drives" : fuzzy.volumeFilter != nil ? "Reindex \(fuzzy.volumeFilter!.name.string)" : "Reindex files")
                .buttonStyle(.text(borderColor: .clear))
            }

            // Text only while something runs; the activity log behind it says what ran.
            Button(action: { toggle(\.showActivityLog) }) {
                HStack(spacing: 4) {
                    if let runningAction {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .controlSize(.mini)
                        Text(runningAction)
                            .truncationMode(.middle)
                            .lineLimit(1)
                    } else {
                        Image(systemName: "list.bullet.rectangle")
                    }
                }
            }
            .buttonStyle(.text(borderColor: .clear, active: fuzzy.showActivityLog, activeTint: .blue))
            .accessibilityLabel("Activity log")
            .accessibilityToggle(isOn: fuzzy.showActivityLog)
            .help("Toggle activity log")

            // The count is what people click to find out where all those files come from.
            if let countText {
                Button(action: { toggle(\.showIndexBrowser) }) {
                    Text(countText)
                }
                .buttonStyle(.text(borderColor: .clear, active: fuzzy.showIndexBrowser, activeTint: .purple))
                .accessibilityToggle(isOn: fuzzy.showIndexBrowser)
                .help("Toggle index size view")
            }

            if !fuzzy.liveIndexChanges.isEmpty {
                Button(action: { toggle(\.showLiveIndex) }) {
                    HStack(spacing: 2) {
                        Circle()
                            .fill(fuzzy.showLiveIndex ? .green : .secondary)
                            .frame(width: 5, height: 5)
                        Text("\(fuzzy.liveIndexChanges.count) changes")
                    }
                }
                .buttonStyle(.text(borderColor: .clear, active: fuzzy.showLiveIndex, activeTint: .green))
                .accessibilityToggle(isOn: fuzzy.showLiveIndex)
                .help("Toggle live index view")
            }

            if !RH.entries.isEmpty {
                Button(action: { toggle(\.showRunHistory) }) {
                    HStack(spacing: 2) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text("\(RH.entries.count) runs")
                    }
                }
                .buttonStyle(.text(borderColor: .clear, active: fuzzy.showRunHistory, activeTint: .orange))
                .accessibilityToggle(isOn: fuzzy.showRunHistory)
                .help("Toggle run history")
            }

            Spacer()

            if let rowsToggleSymbol {
                Text("double tap **`\(rowsToggleSymbol)`** to \(toolbarRowsHidden ? "show" : "hide") actions")
                Divider().frame(height: 10)
            }
            Button {
                SB.switchFromWindow()
            } label: {
                Text("**`⌃ Tab`** to switch to the search bar")
            }
            .buttonStyle(.text(borderColor: .clear))
            Divider().frame(height: 10)
            Text("**`\(showHideShortcut)`** to show/hide Cling").padding(.trailing, 2)

            Button {
                WM.open("settings")
            } label: {
                Image(systemName: "gearshape").bold()
            }
            .buttonStyle(.text(borderColor: .clear))
            .accessibilityLabel("Settings")
        }
        .font(.scaled(10, .chrome))
        .foregroundStyle(.secondary)
        .padding(1)
        // Faded while you're reading results, back to full the moment you go looking for it.
        .opacity(dimStatusBar && !hoveringStatusBar ? 0.45 : 1)
        .onHover { hoveringStatusBar = $0 }
        .task {
            for await _ in Defaults.updates([.triggerKeys, .showAppKey, .rowsToggleModifier]) {
                let modifier = Defaults[.rowsToggleModifier]
                rowsToggleSymbol = modifier == .disabled ? nil : modifier.symbol
                showHideShortcut = "\(Defaults[.triggerKeys].shortReadableStr) + \(Defaults[.showAppKey].character)"
            }
        }
        .animation(.easeOut(duration: 0.12), value: hoveringStatusBar)

        if AM.useGlass, #available(macOS 26, *) {
            GlassEffectContainer { bar }
        } else {
            bar
        }
    }

    @State private var fuzzy: FuzzyClient = FUZZY
    @State private var everything = EVERYTHING

    @State private var appearance = AM
    @State private var hoveringStatusBar = false

    /// Rendered from triggerKeys/showAppKey/rowsToggleModifier and refreshed when those change.
    /// Reading them through @Default instead would decode their JSON on every body evaluation,
    /// which the status bar does a lot of: it also shows indexedCount and the live change count.
    @State private var showHideShortcut = ""
    @State private var rowsToggleSymbol: String?

    /// Observed so the view redraws when the text size changes; the sizes themselves come
    /// from FontScale.
    @Default(.fontScale) private var fontScale

    @Default(.toolbarRowsHidden) private var toolbarRowsHidden
    @Default(.dimStatusBar) private var dimStatusBar

    /// What is running right now, shown on the activity log button.
    private var runningAction: String? {
        if everything.enabled, everything.loading || everything.building {
            return everything.loading ? "Loading Everything…" : "Indexing everything: \(everything.count.formatted()) files"
        }
        return fuzzy.operation.isEmpty ? nil : fuzzy.operation
    }

    /// The count on the index size button, left out while Everything is still loading or being built.
    private var countText: String? {
        if everything.enabled {
            return everything.loading || everything.building ? nil : "\(everything.count.formatted()) files in Everything"
        }
        if let subset = fuzzy.filteredSubsetCount {
            return "Searching \(subset.formatted()) files"
        }
        return "\(fuzzy.indexedCount.formatted()) files indexed"
    }

    /// Opens one of the panels in place of the results, closing the others, and puts the query back when it closes.
    private func toggle(_ panel: ReferenceWritableKeyPath<FuzzyClient, Bool>) {
        fuzzy[keyPath: panel].toggle()
        if fuzzy[keyPath: panel] {
            for other in [\FuzzyClient.showActivityLog, \.showLiveIndex, \.showRunHistory, \.showIndexBrowser] where other != panel {
                fuzzy[keyPath: other] = false
            }
            fuzzy.savedQuery = fuzzy.query
            fuzzy.query = ""
        } else if let saved = fuzzy.savedQuery {
            fuzzy.query = saved
            fuzzy.savedQuery = nil
        }
    }

}
