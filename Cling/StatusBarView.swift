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
            if !fuzzy.backgroundIndexing, !hidden.contains(.reindex) {
                Button(action: {
                    if fuzzy.volumeFilter == .allDrives {
                        fuzzy.indexVolumes(fuzzy.connectedDrives)
                    } else if let volume = fuzzy.volumeFilter, fuzzy.enabledVolumes.contains(volume) {
                        fuzzy.indexVolume(volume)
                    } else {
                        fuzzy.refresh()
                    }
                }) {
                    Text(Image(systemName: "arrow.clockwise")).bold()
                }
                .help(fuzzy.volumeFilter == .allDrives ? "Reindex connected drives" : fuzzy.volumeFilter != nil ? "Reindex \(fuzzy.volumeFilter!.name.string)" : "Reindex files")
                .buttonStyle(.text(borderColor: .clear))
            }

            // Text only while something runs; the activity log behind it says what ran. Hidden, it still shows while
            // something runs, as the only sign that indexing is under way.
            if !hidden.contains(.activityLog) || runningAction != nil {
                activityLogButton
            }

            // The count is what people click to find out where all those files come from.
            if let countText, !hidden.contains(.fileCount) {
                Button(action: { toggle(\.showIndexBrowser) }) {
                    Text(countText)
                }
                .buttonStyle(.text(borderColor: .clear, active: fuzzy.showIndexBrowser, activeTint: .purple))
                .accessibilityToggle(isOn: fuzzy.showIndexBrowser)
                .help("Toggle index size view")
            }

            if !fuzzy.liveIndexChanges.isEmpty, !hidden.contains(.liveChanges) {
                Button(action: { toggle(\.showLiveIndex) }) {
                    HStack(spacing: 2) {
                        Circle()
                            .fill(fuzzy.showLiveIndex ? .green : .secondary)
                            .frame(width: 5, height: 5)
                        // Only what the pane would list, so a quiet count says there's nothing worth a look.
                        let counts = fuzzy.liveChangeCounts
                        let changes = "\(counts.shown.spaced) change\(counts.shown == 1 ? "" : "s")"
                        Text(counts.hidden > 0 ? "\(changes) (\(counts.hidden.spaced) hidden)" : changes)
                    }
                }
                .buttonStyle(.text(borderColor: .clear, active: fuzzy.showLiveIndex, activeTint: .green))
                .accessibilityToggle(isOn: fuzzy.showLiveIndex)
                .help("Toggle live index view")
            }

            if !RH.entries.isEmpty, !hidden.contains(.runHistory) {
                Button(action: { toggle(\.showRunHistory) }) {
                    HStack(spacing: 2) {
                        Text(Image(systemName: "clock.arrow.circlepath"))
                        Text("\(RH.entries.count) runs")
                    }
                }
                .buttonStyle(.text(borderColor: .clear, active: fuzzy.showRunHistory, activeTint: .orange))
                .accessibilityToggle(isOn: fuzzy.showRunHistory)
                .help("Toggle run history")
            }

            if let searchTime, !hidden.contains(.searchTime) {
                Text(searchTime.text)
                    .monospacedDigit()
                    .help("How long the last search took")
                    .accessibilityLabel("Last search took about \(searchTime.spoken)")
            }

            Spacer()

            let showsSwitch = !hidden.contains(.searchBarHint)
            let showsShortcut = !hidden.contains(.showHideHint)
            if let rowsToggleSymbol, !hidden.contains(.actionsHint) {
                Text("double tap **`\(rowsToggleSymbol)`** to \(toolbarRowsHidden ? "show" : "hide") actions")
                if showsSwitch || showsShortcut {
                    Divider().frame(height: 10)
                }
            }
            if showsSwitch {
                Button {
                    SB.switchFromWindow()
                } label: {
                    Text("**`⌃ Tab`** to switch to the floating bar")
                }
                .buttonStyle(.text(borderColor: .clear))
                if showsShortcut {
                    Divider().frame(height: 10)
                }
            }
            if showsShortcut {
                Text("**`\(showHideShortcut)`** to show/hide Cling").padding(.trailing, 2)
            }

            if !hidden.contains(.settings) {
                Button {
                    WM.open("settings")
                } label: {
                    Text(Image(systemName: "gearshape")).bold()
                }
                .buttonStyle(.text(borderColor: .clear))
                .accessibilityLabel("Settings")
            }
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
        .task {
            for await items in Defaults.updates(.hiddenStatusBarItems) {
                hidden = items
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
    /// Read like the shortcut above, so the bar decodes it only when it changes.
    @State private var hidden: Set<StatusBarItem> = []

    /// Observed so the view redraws when the text size changes; the sizes themselves come
    /// from FontScale.
    @Default(.fontScale) private var fontScale

    @Default(.toolbarRowsHidden) private var toolbarRowsHidden
    @Default(.dimStatusBar) private var dimStatusBar

    /// What is running right now, shown on the activity log button.
    private var runningAction: String? {
        if everything.enabled, everything.loading || everything.building {
            return everything.loading ? "Loading Everything…" : "Indexing everything: \(everything.count.spaced) files"
        }
        return fuzzy.operation.isEmpty ? nil : fuzzy.operation
    }

    /// The count on the index size button, left out while Everything is still loading or being built.
    private var countText: String? {
        if everything.enabled {
            return everything.loading || everything.building ? nil : "\(everything.count.spaced) files in Everything"
        }
        if let subset = fuzzy.filteredSubsetCount {
            return "Searching \(subset.spaced) files"
        }
        return "\(fuzzy.indexedCount.spaced) files indexed"
    }

    /// The last search's time, shown only while a query is typed, since the recents under an empty query come from no
    /// search.
    private var searchTime: (text: String, spoken: String)? {
        fuzzy.noQuery ? nil : fuzzy.lastSearchTime
    }

    private var activityLogButton: some View {
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
                    Text(Image(systemName: "list.bullet.rectangle"))
                }
            }
        }
        .buttonStyle(.text(borderColor: .clear, active: fuzzy.showActivityLog, activeTint: .blue))
        .accessibilityLabel("Activity log")
        .accessibilityToggle(isOn: fuzzy.showActivityLog)
        .help("Toggle activity log")
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
