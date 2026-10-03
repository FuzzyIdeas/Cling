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
/// background, acting on a file from the current results. As wide as the pane, like the window, so Trash and the ⋯
/// menu sit at its edge; an Action Bar with more buttons than fit is drawn smaller instead of cutting them short.
/// Only to look at: clicks and shortcuts never reach it.
struct ActionBarPreview: View {
    var body: some View {
        let background = toolbarRowBackground && anyRowVisible
        // The Action Bar at its own width, plus what the row background adds around it. The other two rows scroll
        // their buttons within themselves, as in the window.
        let needed = barWidth + (background ? 20 : 0)
        let width = max(available, needed)
        let scale = width > 0 ? available / width : 1

        ActionRowsStack(selectedResults: $selection, selectedResultIDs: $selectionIDs, focused: $focused, preview: true)
            .modifier(ActionRowsBackground(visible: background))
            .allowsHitTesting(false)
            .frame(width: width, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { height = $0 })
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: available, height: height * scale, alignment: .topLeading)
            .background(alignment: .topLeading) {
                ActionButtons(selectedResults: $selection, selectedResultIDs: $selectionIDs, focused: $focused, preview: true)
                    .fixedSize()
                    .hidden()
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { barWidth = $0 })
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { available = $0 })
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(WindowBackground())
            .overlay(alignment: .top) { Divider() }
            .onAppear { selection = Self.sampleSelection() }
    }

    @State private var selection: Set<FilePath> = []
    @State private var selectionIDs: Set<String> = []
    @FocusState private var focused: FocusedField?
    @State private var available: CGFloat = 0
    @State private var barWidth: CGFloat = 0
    @State private var height: CGFloat = 0

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
