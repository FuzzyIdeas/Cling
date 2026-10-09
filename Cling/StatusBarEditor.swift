import Defaults
import KeyboardShortcuts
import SwiftUI

// MARK: - StatusBarItem

/// What the window's status bar can show, left to right. The activity log, index sizes, live changes and run history
/// open only from their items here, so hiding one of those leaves its panel out of reach until it's shown again.
enum StatusBarItem: String, CaseIterable, Codable, Defaults.Serializable {
    case reindex, activityLog, fileCount, liveChanges, runHistory, searchTime
    case actionsHint, searchBarHint, showHideHint, settings

    /// Its panel opens from nowhere else.
    var opensPanel: Bool {
        [.activityLog, .fileCount, .liveChanges, .runHistory].contains(self)
    }

    var title: String {
        switch self {
        case .reindex: "Reindex"
        case .activityLog: "Activity log"
        case .fileCount: "File count"
        case .liveChanges: "Live changes"
        case .runHistory: "Run history"
        case .searchTime: "Search time"
        case .actionsHint: "Actions hint"
        case .searchBarHint: "Search bar hint"
        case .showHideHint: "Show/hide shortcut"
        case .settings: "Settings"
        }
    }
}

// MARK: - SearchBarFooterItem

/// What the search bar's footer can show. The key hints still come and go with the selection; a hidden one stays out
/// whatever is selected.
enum SearchBarFooterItem: String, CaseIterable, Codable, Defaults.Serializable {
    case open, showInFinder, quickLook, searchInFolder, copy, actions, syntax, table
    case resultCount, searchTime, settings

    /// The item a key hint belongs to. Paste stands in for Open while a terminal is in front, so it goes with it.
    init?(hint: SearchBarHint.ID) {
        switch hint {
        case .open, .paste: self = .open
        case .showInFinder: self = .showInFinder
        case .quickLook: self = .quickLook
        case .drill: self = .searchInFolder
        case .copy: self = .copy
        case .actions: self = .actions
        case .syntax: self = .syntax
        case .window: self = .table
        case .settings, .reindexDrives, .skipDriveReindex: return nil
        }
    }

    static let keyHints: [Self] = [.open, .showInFinder, .quickLook, .searchInFolder, .copy, .actions, .syntax, .table]

    var title: String {
        switch self {
        case .open: "Open"
        case .showInFinder: "Show in Finder"
        case .quickLook: "QuickLook"
        case .searchInFolder: "Search in folder"
        case .copy: "Copy"
        case .actions: "Actions"
        case .syntax: "Syntax"
        case .table: "Table"
        case .resultCount: "Result count"
        case .searchTime: "Search time"
        case .settings: "Settings"
        }
    }

}

// MARK: - StatusBarEditor

/// Both bars as they look, with every item there to click: a hidden one stays in place, faded, until it's clicked back.
struct StatusBarEditor: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Window")
            FitToWidth { windowBar }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Search bar")
            FitToWidth { searchBarFooter }
                .padding(.vertical, 6)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    @Default(.hiddenStatusBarItems) private var hiddenWindowItems
    @Default(.hiddenSearchBarFooterItems) private var hiddenFooterItems
    @Default(.rowsToggleModifier) private var rowsToggleModifier
    @Default(.triggerKeys) private var triggerKeys
    @Default(.showAppKey) private var showAppKey

    /// Laid out like `StatusBarView`: pills where the bar has buttons, plain secondary text where it has text.
    private var windowBar: some View {
        HStack {
            windowItem(.reindex, pill: true) { Text(Image(systemName: "arrow.clockwise")).bold() }
            windowItem(.activityLog, pill: true) { Text(Image(systemName: "list.bullet.rectangle")) }
            windowItem(.fileCount, pill: true) { Text("\(FUZZY.indexedCount.spaced) files indexed") }
            windowItem(.liveChanges, pill: true) {
                HStack(spacing: 2) {
                    Circle().fill(.secondary).frame(width: 5, height: 5)
                    Text("3 changes")
                }
            }
            windowItem(.runHistory, pill: true) {
                HStack(spacing: 2) {
                    Text(Image(systemName: "clock.arrow.circlepath"))
                    Text("5 runs")
                }
            }
            windowItem(.searchTime) { Text("~90ms").monospacedDigit() }

            // The real bar's empty middle shrinks to nothing here, so a divider keeps the two ends apart.
            gap(dividerHeight: 10)

            windowItem(.actionsHint) {
                Text("double tap **`\(rowsToggleModifier == .disabled ? RowToggleModifier.option.symbol : rowsToggleModifier.symbol)`** to hide actions")
            }
            Divider().frame(height: 10)
            windowItem(.searchBarHint, pill: true) { Text("**`⌃ Tab`** to switch to the floating bar") }
            Divider().frame(height: 10)
            windowItem(.showHideHint) {
                Text("**`\(triggerKeys.shortReadableStr) + \(showAppKey.character)`** to show/hide Cling").padding(.trailing, 2)
            }
            windowItem(.settings, pill: true) { Text(Image(systemName: "gearshape")).bold() }
        }
        .font(.scaled(10, .chrome))
        .foregroundStyle(.secondary)
        .padding(1)
    }

    /// Drawn like `SearchBarHintBar`, which draws in AppKit: keycaps and titles, the status, then the gear.
    private var searchBarFooter: some View {
        let height = FontScale.length(SearchBarMetrics.modern ? 34 : 30, .chrome)
        return HStack(spacing: 0) {
            HStack(spacing: 16) {
                footerItem(.open, key: "⏎", capHeight: (height * 0.6).rounded())
                footerItem(.showInFinder, key: shortcut(.clShowInFinder) ?? "⌘⏎", capHeight: (height * 0.6).rounded())
                footerItem(.quickLook, key: shortcut(.clQuickLook) ?? "⌘Y", capHeight: (height * 0.6).rounded())
                footerItem(.searchInFolder, key: "→", capHeight: (height * 0.6).rounded())
                footerItem(.copy, key: shortcut(.clCopy) ?? "⌘C", capHeight: (height * 0.6).rounded())
                footerItem(.actions, key: "⌘K", capHeight: (height * 0.6).rounded())
                footerItem(.syntax, key: "⌘/", capHeight: (height * 0.6).rounded())
                footerItem(.table, key: "⌃ Tab", capHeight: (height * 0.6).rounded())
            }

            gap(dividerHeight: 12)

            Group {
                footerToggle(.resultCount) { Text("6 results") }
                footerToggle(.searchTime) { Text(hiddenFooterItems.contains(.resultCount) ? "~90ms" : " · ~90ms") }
            }
            .font(.system(size: FontScale.size(11, .chrome)).monospacedDigit())
            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))

            footerToggle(.settings) {
                Image(systemName: "gearshape")
                    .font(.system(size: FontScale.size(11, .chrome), weight: .semibold))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }
            .padding(.leading, 12)
        }
        .padding(.horizontal, 14)
        .frame(height: height)
    }

    /// Where the real bar has room to spare: a divider between whatever space is left. Three views of the row it's in,
    /// not a stack of its own, so the spacers still give way before the text does.
    @ViewBuilder
    private func gap(dividerHeight: CGFloat) -> some View {
        Spacer(minLength: 6)
        Divider().frame(height: dividerHeight)
        Spacer(minLength: 6)
    }

    private func windowItem(_ item: StatusBarItem, pill: Bool = false, @ViewBuilder label: () -> some View) -> some View {
        EditorItem(title: item.title, hidden: hiddenWindowItems.contains(item), pill: pill, opensPanel: item.opensPanel, action: {
            hiddenWindowItems.formSymmetricDifference([item])
        }, label: label())
    }

    private func footerToggle(_ item: SearchBarFooterItem, @ViewBuilder label: () -> some View) -> some View {
        EditorItem(title: item.title, hidden: hiddenFooterItems.contains(item), pill: false, opensPanel: false, action: {
            hiddenFooterItems.formSymmetricDifference([item])
        }, label: label())
    }

    private func footerItem(_ item: SearchBarFooterItem, key: String, capHeight: CGFloat) -> some View {
        footerToggle(item) {
            HStack(spacing: 5) {
                Text(key)
                    .font(.system(size: FontScale.size(10, .chrome), weight: .semibold))
                    .padding(.horizontal, 4)
                    .frame(minWidth: capHeight, minHeight: capHeight, maxHeight: capHeight)
                    .background(
                        Color(nsColor: .labelColor).opacity(0.08),
                        in: RoundedRectangle(cornerRadius: SearchBarMetrics.modern ? 5 : 4, style: .continuous)
                    )
                Text(item.title)
                    .font(.system(size: FontScale.size(11, .chrome)))
            }
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        }
    }

    private func shortcut(_ name: KeyboardShortcuts.Name) -> String? {
        KeyboardShortcuts.getShortcut(for: name)?.description
    }

}

// MARK: - EditorItem

/// One item of a replica. The replica is scaled down to fit the pane, so the item under the pointer grows back to the
/// size it has in the real bar, over its neighbours.
private struct EditorItem<Label: View>: View {
    let title: String
    let hidden: Bool
    /// Drawn as a pill, the way the real bar draws its buttons; the rest is plain text, as it is there.
    let pill: Bool
    let opensPanel: Bool
    let action: () -> Void
    let label: Label

    var body: some View {
        // The whole item fades, a pill's fill with it, so a hidden pill doesn't read as a button.
        styled(Button(action: action) { label })
            .opacity(hidden ? 0.3 : 1)
            .background {
                if hovering {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(.background)
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        .padding(pill ? 0 : -3)
                }
            }
            .scaleEffect(hovering ? max(1 / scale, 1.06) : 1)
            .zIndex(hovering ? 1 : 0)
            .onHover { hover in
                withAnimation(.easeOut(duration: 0.12)) { hovering = hover }
            }
        #if SEARCHBAR_BENCH
            // `-statusBarEditorHover <title>` shows that item as if the pointer were on it, for screenshots.
            .onAppear {
                if let i = CommandLine.arguments.firstIndex(of: "-statusBarEditorHover"), CommandLine.arguments.dropFirst(i + 1).first == title {
                    hovering = true
                }
            }
        #endif
            .help(hidden ? "Show \(title)" : opensPanel ? "Hide \(title): its panel opens only from here" : "Hide \(title)")
            .accessibilityLabel(title)
            .accessibilityValue(hidden ? "Hidden" : "Shown")
    }

    @Environment(\.statusBarEditorScale) private var scale
    @State private var hovering = false

    @ViewBuilder
    private func styled(_ button: Button<some View>) -> some View {
        if pill {
            button.buttonStyle(.text(borderColor: .clear))
        } else {
            button.buttonStyle(.plain)
        }
    }
}

extension EnvironmentValues {
    /// How much `FitToWidth` shrank the replica around a view.
    @Entry var statusBarEditorScale: CGFloat = 1
}

// MARK: - FitToWidth

/// Lays its content out across the width it's given, and scales it down to fit when the content needs more.
private struct FitToWidth<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        let width = max(available, natural)
        let scale = width > 0 ? available / width : 1
        content
            .environment(\.statusBarEditorScale, scale)
            .frame(width: width, alignment: .leading)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: available, height: height * scale, alignment: .topLeading)
            .background(alignment: .topLeading) {
                content
                    .fixedSize()
                    .hidden()
                    .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { natural = $0.width; height = $0.height })
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { available = $0 })
    }

    @State private var available: CGFloat = 0
    @State private var natural: CGFloat = 0
    @State private var height: CGFloat = 0
}
