//
//  StatusBarView.swift
//  Cling
//
//  Created by Alin Panaitiu on 08.02.2025.
//

import Defaults
import SwiftUI

struct StatusBarView: View {
    @Default(.triggerKeys) private var triggerKeys
    @Default(.showAppKey) private var showAppKey

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

            Text("**`\(triggerKeys.shortReadableStr) + \(showAppKey.character)`** to show/hide").padding(.trailing, 2)

            SettingsLink {
                Image(systemName: "gearshape").bold()
            }
            .buttonStyle(.text(borderColor: .clear))
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(1)

        if AM.useGlass, #available(macOS 26, *) {
            GlassEffectContainer { bar }
        } else {
            bar
        }
    }

    @State private var fuzzy: FuzzyClient = FUZZY
    @State private var appearance = AM
}
