//
//  ActionRows.swift
//  Cling
//
//  The rows of buttons under the results (the Action Bar, the Open With row and the Scripts row) and the sunken
//  background they can sit in. The window and the preview in Settings > Action Bar draw the same ones.
//

import Defaults
import Lowtech
import SwiftUI
import System

// MARK: - ActionRowsStack

struct ActionRowsStack: View {
    @Binding var selectedResults: Set<FilePath>
    @Binding var selectedResultIDs: Set<String>

    var focused: FocusState<FocusedField?>.Binding
    var preview = false

    var body: some View {
        // Each row clears its shortcut badges by `badgeClearance` on top and bottom (the Open With /
        // Scripts rows do it inside their pill ScrollViews; the action row gets it here). The bottom
        // clearance is otherwise empty, so a small negative spacing overlaps it to keep the visible
        // gap between rows tight and even.
        VStack(spacing: -3) {
            ActionButtons(selectedResults: $selectedResults, selectedResultIDs: $selectedResultIDs, focused: focused, preview: preview)
                .hfill(.leading)
                .padding(.vertical, showActionRow && !toolbarRowsHidden ? ActionRowLayout.badgeClearance : 0)
                .contentShape(Rectangle())
                .contextMenu {
                    Button("Hide action buttons row") { showActionRow = false }
                }

            if showOpenWithRow, !toolbarRowsHidden {
                OpenWithActionButtons(selectedResults: selectedResults)
                    .hfill(.leading)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button("Hide \"Open with\" row") { showOpenWithRow = false }
                    }
            }
            if proactive, showScriptRow, !toolbarRowsHidden {
                ScriptActionButtons(selectedResults: selectedResults, focused: focused, preview: preview)
                    .hfill(.leading)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button("Hide script row") { showScriptRow = false }
                    }
            }
        }
    }

    @Default(.showActionRow) private var showActionRow
    @Default(.showOpenWithRow) private var showOpenWithRow
    @Default(.showScriptRow) private var showScriptRow
    @Default(.toolbarRowsHidden) private var toolbarRowsHidden
}

// MARK: - ActionRowsBackground

/// The sunken panel behind the rows, when the row background is on.
struct ActionRowsBackground: ViewModifier {
    var visible: Bool

    func body(content: Content) -> some View {
        if visible {
            content
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background {
                    RoundedRectangle(cornerRadius: windowCornerRadius, style: .continuous)
                        .fill(.black.opacity(0.06).shadow(.inner(color: .black.opacity(0.22), radius: 4, y: 1)))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: windowCornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.black.opacity(0.25), .white.opacity(0.12)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                }
        } else {
            content
        }
    }
}

// MARK: - ActionBarPreview

/// The rows at the bottom of Settings > Action Bar, redrawn as its settings change: the window's own rows over its
/// background, acting on a file from the current results. As wide as the pane, so Trash and the ⋯ menu stay at its
/// edge, and scrolling sideways only when the buttons need more. Only to look at: clicks and shortcuts never reach it.
struct ActionBarPreview: View {
    var body: some View {
        ScrollView(.horizontal) {
            ActionRowsStack(selectedResults: $selection, selectedResultIDs: $selectionIDs, focused: $focused, preview: true)
                .modifier(ActionRowsBackground(visible: toolbarRowBackground && anyRowVisible))
                .allowsHitTesting(false)
                .frame(minWidth: max(available - 32, 0), alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { available = $0 })
        .background(WindowBackground())
        .overlay(alignment: .top) { Divider() }
        .onAppear { selection = Self.sampleSelection() }
    }

    @State private var selection: Set<FilePath> = []
    @State private var selectionIDs: Set<String> = []
    @FocusState private var focused: FocusedField?
    @State private var available: CGFloat = 0

    @Default(.toolbarRowBackground) private var toolbarRowBackground
    @Default(.showActionRow) private var showActionRow
    @Default(.showOpenWithRow) private var showOpenWithRow
    @Default(.showScriptRow) private var showScriptRow
    @Default(.toolbarRowsHidden) private var toolbarRowsHidden

    private var anyRowVisible: Bool {
        !toolbarRowsHidden && (showActionRow || showOpenWithRow || (proactive && showScriptRow))
    }

    private static func sampleSelection() -> Set<FilePath> {
        if let file = FUZZY.results.first ?? FUZZY.recents.first {
            return [file]
        }
        return [HOME]
    }
}
