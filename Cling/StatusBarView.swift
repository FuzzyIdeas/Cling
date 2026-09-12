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
                    if let volume = fuzzy.volumeFilter, fuzzy.enabledVolumes.contains(volume) {
                        fuzzy.indexVolume(volume)
                    } else {
                        fuzzy.refresh()
                    }
                }) {
                    Image(systemName: "arrow.clockwise").bold()
                }
                .help(fuzzy.volumeFilter != nil ? "Reindex \(fuzzy.volumeFilter!.name.string)" : "Reindex files")
                .buttonStyle(.text(borderColor: .clear))
            }

            Button(action: {
                fuzzy.showActivityLog.toggle()
                if fuzzy.showActivityLog {
                    fuzzy.showLiveIndex = false
                    fuzzy.showRunHistory = false
                    fuzzy.savedQuery = fuzzy.query
                    fuzzy.query = ""
                } else if let saved = fuzzy.savedQuery {
                    fuzzy.query = saved
                    fuzzy.savedQuery = nil
                }
            }) {
                if !fuzzy.operation.isEmpty {
                    HStack(spacing: 4) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .controlSize(.mini)
                        Text(fuzzy.operation)
                            .truncationMode(.middle)
                            .lineLimit(1)
                    }
                } else if let subset = fuzzy.filteredSubsetCount {
                    Text("Searching \(subset.formatted()) files")
                } else {
                    Text("\(fuzzy.indexedCount.formatted()) files indexed")
                }
            }
            .buttonStyle(.text(borderColor: .clear, active: fuzzy.showActivityLog, activeTint: .blue))
            .help("Toggle activity log")

            if !fuzzy.liveIndexChanges.isEmpty {
                Button(action: {
                    fuzzy.showLiveIndex.toggle()
                    if fuzzy.showLiveIndex {
                        fuzzy.showActivityLog = false
                        fuzzy.showRunHistory = false
                        fuzzy.savedQuery = fuzzy.query
                        fuzzy.query = ""
                    } else if let saved = fuzzy.savedQuery {
                        fuzzy.query = saved
                        fuzzy.savedQuery = nil
                    }
                }) {
                    HStack(spacing: 2) {
                        Circle()
                            .fill(fuzzy.showLiveIndex ? .green : .secondary)
                            .frame(width: 5, height: 5)
                        Text("\(fuzzy.liveIndexChanges.count) changes")
                    }
                }
                .buttonStyle(.text(borderColor: .clear, active: fuzzy.showLiveIndex, activeTint: .green))
                .help("Toggle live index view")
            }

            if !RH.entries.isEmpty {
                Button(action: {
                    fuzzy.showRunHistory.toggle()
                    if fuzzy.showRunHistory {
                        fuzzy.showActivityLog = false
                        fuzzy.showLiveIndex = false
                        fuzzy.savedQuery = fuzzy.query
                        fuzzy.query = ""
                    } else if let saved = fuzzy.savedQuery {
                        fuzzy.query = saved
                        fuzzy.savedQuery = nil
                    }
                }) {
                    HStack(spacing: 2) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text("\(RH.entries.count) runs")
                    }
                }
                .buttonStyle(.text(borderColor: .clear, active: fuzzy.showRunHistory, activeTint: .orange))
                .help("Toggle run history")
            }

            Spacer()

            if let rowsToggleSymbol {
                Text("double tap **`\(rowsToggleSymbol)`** to \(toolbarRowsHidden ? "show" : "hide") actions")
                Divider().frame(height: 10)
            }
            Text("**`\(showHideShortcut)`** to show/hide Cling").padding(.trailing, 2)

            Button {
                WM.open("settings")
            } label: {
                Image(systemName: "gearshape").bold()
            }
            .buttonStyle(.text(borderColor: .clear))
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

}
