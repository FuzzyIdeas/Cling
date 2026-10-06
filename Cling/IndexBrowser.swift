import Defaults
import Lowtech
import SwiftUI
import System

// MARK: - IndexNode

/// One row of the index browser: a scope, a volume, one of a scope's walk roots, or a folder or file inside one.
struct IndexNode: Identifiable, Hashable {
    enum Kind: Hashable {
        case scope(SearchScope)
        case volume(FilePath)
        case root
        case folder
        case file
    }

    let id: String
    let name: String
    let kind: Kind
    /// Absolute path; nil only for scope rows.
    let path: String?
    var count: Int

    var canOpen: Bool {
        kind != .file
    }

    /// Scopes, volumes and walk roots are turned off in Settings, not pruned.
    var canPrune: Bool {
        kind == .folder || kind == .file
    }

    static func largestFirst(_ a: IndexNode, _ b: IndexNode) -> Bool {
        a.count != b.count ? a.count > b.count : a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

// MARK: - IndexLevel

struct IndexLevel {
    /// Which live engine the rows are counted from; nil for the top level.
    enum Source: Hashable {
        case scope(SearchScope)
        case volume(FilePath)
    }

    let title: String
    let source: Source?
    /// The folder listed; nil for the top level and for a scope's list of walk roots.
    let path: String?
    var rows: [IndexNode]
    var selection: String?
}

// MARK: - PrunedPath

struct PrunedPath: Identifiable {
    let id = UUID()
    let path: String
    let isDir: Bool
    let count: Int
    let rule: ExcludeRule
    var restoring = false
}

// MARK: - IndexBrowser

/// Breadcrumb trail through the live index, counted from the engines in memory (no disk access), plus the
/// paths pruned this session so they can be put back.
@MainActor @Observable
final class IndexBrowser {
    static let shared = IndexBrowser()

    var levels: [IndexLevel] = []
    var loading = false
    var pruned: [PrunedPath] = []

    var current: IndexLevel? {
        levels.last
    }

    var selectedNode: IndexNode? {
        guard let level = current, let id = level.selection else { return nil }
        return level.rows.first { $0.id == id }
    }

    func open() {
        loadToken = UUID()
        loading = false
        levels = [topLevel()]
    }

    func select(_ id: String?) {
        guard !levels.isEmpty else { return }
        levels[levels.count - 1].selection = id
    }

    func enter(_ node: IndexNode) {
        guard node.canOpen, !loading, let level = current else { return }
        select(node.id)
        switch node.kind {
        case let .scope(scope):
            let roots = FUZZY.walkDirs(for: scope).map(\.dir)
            if roots.count == 1 {
                loadFolder(roots[0], title: node.name, source: .scope(scope))
            } else {
                loadRoots(roots, title: node.name, source: .scope(scope))
            }
        case let .volume(volume):
            loadFolder(volume.string, title: node.name, source: .volume(volume))
        case .root, .folder:
            guard let path = node.path, let source = level.source else { return }
            loadFolder(path, title: node.name, source: source)
        case .file:
            break
        }
    }

    func back() {
        jump(to: levels.count - 2)
    }

    func jump(to index: Int) {
        guard index >= 0, index < levels.count - 1 else { return }
        // Drop a count still running for a deeper level.
        loadToken = UUID()
        loading = false
        levels.removeLast(levels.count - 1 - index)
        // Prunes below may have shrunk rows here, so settle the order again.
        levels[index].rows.sort(by: IndexNode.largestFirst)
    }

    func prune(_ node: IndexNode) {
        guard node.canPrune, let path = node.path, !levels.isEmpty else { return }
        let rule = FUZZY.pruneFromIndex(path)
        pruned.insert(PrunedPath(path: path, isDir: node.kind == .folder, count: node.count, rule: rule), at: 0)

        let last = levels.count - 1
        if let i = levels[last].rows.firstIndex(where: { $0.id == node.id }) {
            levels[last].rows.remove(at: i)
            let rows = levels[last].rows
            levels[last].selection = rows.isEmpty ? nil : rows[min(i, rows.count - 1)].id
        }
        // Each level up the trail has the row that was opened to get here selected; it held this path too.
        for li in levels.indices.dropLast() {
            if let ri = levels[li].rows.firstIndex(where: { $0.id == levels[li].selection }) {
                levels[li].rows[ri].count -= node.count
            }
        }
    }

    func restore(_ item: PrunedPath) {
        guard let i = pruned.firstIndex(where: { $0.id == item.id }), !pruned[i].restoring else { return }
        pruned[i].restoring = true
        FUZZY.restorePruned(item.path, isDir: item.isDir, rule: item.rule) { [self] in
            pruned.removeAll { $0.id == item.id }
            recount()
        }
    }

    @ObservationIgnored private var loadToken = UUID()

    private nonisolated static func folderRows(_ counts: [SearchEngine.ChildCount]) -> [IndexNode] {
        counts.map { c in
            IndexNode(id: c.path, name: (c.path as NSString).lastPathComponent, kind: c.isDir ? .folder : .file, path: c.path, count: c.count)
        }.sorted(by: IndexNode.largestFirst)
    }

    private nonisolated static func rootRows(_ roots: [String], engine: SearchEngine) -> [IndexNode] {
        roots.map { root in
            IndexNode(id: root, name: root.shellString, kind: .root, path: root, count: engine.countBelow(root))
        }.sorted(by: IndexNode.largestFirst)
    }

    private func engine(for source: IndexLevel.Source) -> SearchEngine? {
        switch source {
        case let .scope(scope): FUZZY.scopeEngines[scope]
        case let .volume(volume): FUZZY.volumeEngines[volume]
        }
    }

    private func topLevel() -> IndexLevel {
        var rows: [IndexNode] = []
        for scope in Defaults[.searchScopes] {
            if let engine = FUZZY.scopeEngines[scope] {
                rows.append(IndexNode(id: "scope:\(scope.rawValue)", name: scope.label, kind: .scope(scope), path: nil, count: engine.count))
            }
        }
        for volume in FUZZY.enabledVolumes {
            if let engine = FUZZY.volumeEngines[volume] {
                rows.append(IndexNode(id: volume.string, name: volume.name.string, kind: .volume(volume), path: volume.string, count: engine.count))
            }
        }
        rows.sort(by: IndexNode.largestFirst)
        return IndexLevel(title: "Index", source: nil, path: nil, rows: rows, selection: rows.first?.id)
    }

    private func loadFolder(_ path: String, title: String, source: IndexLevel.Source) {
        guard let engine = engine(for: source) else { return }
        load(title: title, source: source, path: path) {
            Self.folderRows(engine.childCounts(of: path))
        }
    }

    private func loadRoots(_ roots: [String], title: String, source: IndexLevel.Source) {
        guard let engine = engine(for: source) else { return }
        load(title: title, source: source, path: nil) {
            Self.rootRows(roots, engine: engine)
        }
    }

    /// Counts off the main thread: a pass over a large engine takes tens of milliseconds.
    private func load(title: String, source: IndexLevel.Source, path: String?, rows: @escaping @Sendable () -> [IndexNode]) {
        let token = UUID()
        loadToken = token
        loading = true
        Task.detached(priority: .userInitiated) {
            let rows = rows()
            await MainActor.run {
                guard self.loadToken == token else { return }
                self.loading = false
                self.levels.append(IndexLevel(title: title, source: source, path: path, rows: rows, selection: rows.first?.id))
            }
        }
    }

    /// Count every level of the trail again, keeping each one's selection where the row still exists.
    private func recount() {
        guard !levels.isEmpty else { return }
        let token = UUID()
        loadToken = token
        let top = topLevel()
        let deeper = levels.dropFirst().map { level in (level, level.source.flatMap { engine(for: $0) }) }
        Task.detached(priority: .userInitiated) {
            let fresh = deeper.map { level, engine -> [IndexNode] in
                guard let engine else { return level.rows }
                if let path = level.path {
                    return Self.folderRows(engine.childCounts(of: path))
                }
                return Self.rootRows(level.rows.compactMap(\.path), engine: engine)
            }
            await MainActor.run {
                guard self.loadToken == token, self.levels.count == fresh.count + 1 else { return }
                var levels = self.levels
                levels[0].rows = top.rows
                for (i, rows) in fresh.enumerated() {
                    levels[i + 1].rows = rows
                }
                for i in levels.indices where !levels[i].rows.contains(where: { $0.id == levels[i].selection }) {
                    levels[i].selection = levels[i].rows.first?.id
                }
                self.levels = levels
            }
        }
    }

}

// MARK: - IndexBrowserView

/// Index size by folder, largest first, in the spirit of `dua i`: → opens a folder, ← goes back up, ⌫ prunes
/// the selected row with an exact ignore rule. Pruned paths gather in the right-hand panel until re-added.
struct IndexBrowserView: View {
    var focused: FocusState<FocusedField?>.Binding

    var body: some View {
        HStack(spacing: 10) {
            browserPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .raisedPanel()
            if !browser.pruned.isEmpty {
                prunedPanel
                    .frame(width: WindowManager.previewWidth(forWindowWidth: WM.size.width))
                    .raisedPanel()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: browser.pruned.isEmpty)
        .onAppear {
            browser.open()
            installDeleteMonitor()
            focused.wrappedValue = .indexBrowser
            // Again once the table is in the window; the first assignment can land before it is.
            mainAsyncAfter(ms: 100) { focused.wrappedValue = .indexBrowser }
        }
        .onDisappear { removeDeleteMonitor() }
    }

    @State private var browser = IndexBrowser.shared
    @State private var deleteMonitor: Any?
    @State private var stats: IndexStats?
    /// Set by clicking the stats header; cleared whenever the automatic choice changes, so entering a scope or making
    /// the window shorter closes the stats again.
    @State private var statsOpen: Bool?
    /// Height shared by the list and the stats.
    @State private var listHeight: CGFloat = 0

    private var rows: [IndexNode] {
        browser.current?.rows ?? []
    }

    private var total: Int {
        max(rows.reduce(0) { $0 + $1.count }, 1)
    }

    private var selection: Binding<String?> {
        Binding(
            get: { browser.current?.selection },
            set: { browser.select($0) }
        )
    }

    /// Open at the top level when the window has room for the list of scopes and the stats both, and closed inside a
    /// scope or drive, whose list is what's being looked at then.
    private var statsAuto: Bool {
        guard browser.levels.count <= 1, let stats else { return false }
        let topRows = browser.levels.first?.rows.count ?? 0
        let table = FontScale.length(28) + CGFloat(topRows) * FontScale.length(24)
        let header = FontScale.length(26)
        return listHeight >= table + header + IndexStatsView.gridHeight(stats)
    }

    private var statsExpanded: Bool {
        statsOpen ?? statsAuto
    }

    private var browserPanel: some View {
        VStack(spacing: 0) {
            breadcrumb
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            Divider()
            VStack(spacing: 0) {
                ZStack {
                    table
                    if rows.isEmpty, !browser.loading {
                        Text("Nothing indexed here")
                            .font(.scaled(12))
                            .foregroundStyle(.secondary)
                    }
                }
                Divider()
                IndexStatsView(stats: stats, expanded: statsExpanded) { statsOpen = !statsExpanded }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            .animation(.easeOut(duration: 0.18), value: statsExpanded)
            Divider()
            keyHints
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        }
        .onChange(of: statsAuto) { statsOpen = nil }
        // Memory moves as searches read pages in and the system drops them, so keep measuring while this is open.
        .task {
            while !Task.isCancelled {
                stats = await IndexStats.gather()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            ForEach(Array(browser.levels.enumerated()), id: \.offset) { i, level in
                if i > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                Button(level.title) { browser.jump(to: i) }
                    .buttonStyle(.plain)
                    .foregroundStyle(i == browser.levels.count - 1 ? .primary : .secondary)
                    .lineLimit(1)
            }
            Spacer()
            if browser.loading {
                ProgressView().controlSize(.mini)
                Text("Counting…").foregroundStyle(.secondary)
            }
        }
        .font(.scaled(11, .chrome, weight: .medium))
    }

    private var table: some View {
        Table(rows, selection: selection) {
            TableColumn("Name") { node in
                HStack(spacing: 6) {
                    Image(systemName: icon(for: node))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text(node.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.scaled(12))
            }
            TableColumn("Files") { node in
                Text(node.count.formatted())
                    .font(.scaled(12).monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 80, max: 120)
            TableColumn("") { node in
                shareBar(node)
            }
            .width(min: 60, ideal: 140, max: 240)
        }
        .scrollContentBackground(.hidden)
        .alternatingRowBackgrounds(.disabled)
        .accessibilityLabel("Index size")
        .onKeyPress(.rightArrow) {
            guard let node = browser.selectedNode, node.canOpen else { return .ignored }
            browser.enter(node)
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard browser.levels.count > 1 else { return .ignored }
            browser.back()
            return .handled
        }
        .onKeyPress(.tab) {
            focused.wrappedValue = .search
            return .handled
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let node = rows.first(where: { ids.contains($0.id) }) {
                Button("Open") { browser.enter(node) }
                    .disabled(!node.canOpen)
                Button("Prune") { browser.prune(node) }
                    .disabled(!node.canPrune)
            }
        } primaryAction: { ids in
            if let node = rows.first(where: { ids.contains($0.id) }) {
                browser.enter(node)
            }
        }
        .homeEndSelectsRow(in: { rows.map(\.id) }, select: { browser.select($0) })
        .focused(focused, equals: .indexBrowser)
        .transparentTableBackground()
        // Lets the window's click monitor move @FocusState here when a row is clicked.
        .tableRegistration(.indexBrowser)
    }

    private var keyHints: some View {
        HStack(spacing: 8) {
            keyHint("→ open")
            keyHint("← back")
            keyHint("⌫ prune")
            Spacer()
        }
    }

    private var prunedPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Pruned")
                .font(.scaled(11, .chrome, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            Divider()
            List(browser.pruned) { item in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.path.shellString)
                            .font(.scaled(11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(item.count.formatted()) files · \(item.rule.storeLabel)")
                            .font(.scaled(10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if item.restoring {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Re-add") { browser.restore(item) }
                            .controlSize(.small)
                            .help("Removes the rule and indexes this path again")
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollContentBackground(.hidden)
        }
    }

    private func shareBar(_ node: IndexNode) -> some View {
        GeometryReader { geo in
            Capsule()
                .fill(Color.accentColor.opacity(0.45))
                .frame(width: max(2, geo.size.width * CGFloat(node.count) / CGFloat(total)))
                .frame(maxHeight: .infinity)
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    private func keyHint(_ text: String) -> some View {
        Text(text)
            .font(.scaled(10, .chrome, design: .monospaced))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.quaternary, lineWidth: 0.5))
    }

    /// ⌫ and ⌦ prune the selected row. Caught with a key-code monitor, like the app's other Delete
    /// shortcuts, so nothing in the table's own key handling sees it first. Left alone while a text field is
    /// being edited, and a held key prunes once instead of everything that slides into the selection.
    private func installDeleteMonitor() {
        guard deleteMonitor == nil else { return }
        deleteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 51 || event.keyCode == 117,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  let window = event.window, window === AppDelegate.shared.mainWindow, window.attachedSheet == nil,
                  !(window.firstResponder is NSText),
                  let node = IndexBrowser.shared.selectedNode, node.canPrune
            else { return event }
            if !event.isARepeat {
                IndexBrowser.shared.prune(node)
            }
            return nil
        }
    }

    private func removeDeleteMonitor() {
        if let deleteMonitor {
            NSEvent.removeMonitor(deleteMonitor)
        }
        deleteMonitor = nil
    }

    private func icon(for node: IndexNode) -> String {
        switch node.kind {
        case .scope: "square.stack.3d.up"
        case .volume: "externaldrive"
        case .root, .folder: "folder"
        case .file: "doc"
        }
    }

}
