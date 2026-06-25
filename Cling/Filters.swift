import Defaults
import Foundation
import Lowtech
import LowtechPro
import SwiftUI
import System

// MARK: - FilterPicker

struct FilterPicker: View {
    static let iconWidth: CGFloat = 20

    var body: some View {
        menu
            .onAppear { installFilterShortcutMonitor() }
            .onDisappear { removeFilterShortcutMonitor() }
            .sheet(isPresented: $isAddingQuickFilter, onDismiss: {
                saveQuickFilter(draft: filterDraft, originalID: originalFilterID)
                filterDraft = QuickFilterDraft()
                originalFilterID = ""
                isEditingFilter = false
            }) {
                QuickFilterAddSheet(draft: $filterDraft)
            }
            .sheet(isPresented: $isAddingFolderFilter, onDismiss: {
                saveFolderFilter(id: filterID, folders: filterFolders, key: filterKey, originalID: originalFilterID)
                filterID = ""
                originalFilterID = ""
                filterFolders = []
                isEditingFilter = false
            }) {
                FolderFilterAddSheet(id: $filterID, folders: $filterFolders, key: $filterKey)
            }
    }

    var menu: some View {
        Group {
            if proManager.pro?.active != true {
                Button(action: { showNeedsProPopover = true }) {
                    filterLabel
                }
                .buttonStyle(.borderlessText)
                .popover(isPresented: $showNeedsProPopover) {
                    if let pro = PM.pro {
                        PaddedPopoverView(background: Color.red.brightness(0.1).any) {
                            NeedsProView(size: 16, color: .black.opacity(0.8), pro: pro)
                        }
                    }
                }
            } else if km.lalt || km.ralt || showFilterEditor {
                Button(action: { showFilterEditor = true }) {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: FilterPicker.iconWidth)
                }
                .buttonStyle(.borderlessText)
                .sheet(isPresented: $showFilterEditor) {
                    FilterEditorSheet()
                }
            } else {
                Menu {
                    folderFilterPicker
                    quickFilterPicker
                    volumePicker

                    Button("All files (clear filters)") {
                        fuzzy.folderFilter = nil
                        fuzzy.quickFilter = nil
                        fuzzy.volumeFilter = nil
                    }
                    .help("Searches all indexed files without any filters")
                    // Hint only; the NSEvent monitor does the actual handling.
                    .keyboardShortcut(.escape, modifiers: [.option])
                } label: {
                    filterLabel
                }
                .menuStyle(.button)
                .buttonStyle(.borderlessText)
            }
        }
        .fixedSize()
    }

    private enum IndexStatus {
        case indexed, indexing, notIndexed, disconnected
    }

    @State private var defaults = DEFAULTS_CACHE
    @State private var fuzzy: FuzzyClient = FUZZY
    @ObservedObject private var km = KM
    @ObservedObject private var proManager = PM

    @State private var lastQuery = ""

    @State private var isAddingQuickFilter = false
    @State private var isAddingFolderFilter = false
    @State private var isEditingFilter = false
    @State private var originalFilterID = ""
    @State private var filterDraft = QuickFilterDraft()
    // Folder-filter flow keeps its own vars (shared with FolderFilterAddSheet).
    @State private var filterID = ""
    @State private var filterFolders: [FilePath] = []
    @State private var filterKey: SauceKey = .escape

    @State private var showFilterEditor = false

    @State private var showNeedsProPopover = false

    @State private var filterShortcutMonitor: Any?

    private var folderFilters: [FolderFilter] { defaults.folderFilters }
    private var quickFilters: [QuickFilter] { defaults.quickFilters }

    private var enabledVolumes: [FilePath]? {
        fuzzy.enabledVolumes.isEmpty ? nil : fuzzy.enabledVolumes
    }

    @ViewBuilder
    private var volumePicker: some View {
        if let enabledVolumes {
            let volumes = ([FilePath.root] + enabledVolumes).enumerated().map { $0 }
            Picker(selection: $fuzzy.volumeFilter) {
                Text("Volumes").round(11).foregroundColor(.secondary).selectionDisabled()
                ForEach(volumes, id: \.1) { i, volume in
                    filterItem(volume, key: i > 9 ? nil : i.s.first)
                }
            } label: { Text("Volume filter") }
                .labelsHidden()
                .pickerStyle(.inline)
        }
    }

    @ViewBuilder
    private var folderFilterPicker: some View {
        if !folderFilters.isEmpty || fuzzy.folderFilter != nil {
            Picker(selection: $fuzzy.folderFilter) {
                Text("Folder filters").round(11).foregroundColor(.secondary).selectionDisabled()
                ForEach(folderFilters, id: \.self) { filter in
                    filterItem(filter)
                }

                if let filter = fuzzy.folderFilter, !folderFilters.contains(filter) {
                    Divider()
                    filterItem(filter, applyShortcut: false)
                }
            } label: { Text("Folder filter") }
                .labelsHidden()
                .pickerStyle(.inline)
        }
    }

    @ViewBuilder
    private var quickFilterPicker: some View {
        if !quickFilters.isEmpty || fuzzy.quickFilter != nil {
            Picker(selection: $fuzzy.quickFilter) {
                Text("Quick filters").round(11).foregroundColor(.secondary).selectionDisabled()
                ForEach(quickFilters, id: \.self) { filter in
                    filterItem(filter)
                }

                if let filter = fuzzy.quickFilter, !quickFilters.contains(filter) {
                    Divider()
                    filterItem(filter, applyShortcut: false)
                }
            } label: { Text("Quick filter") }
                .labelsHidden()
                .pickerStyle(.inline)
        }
    }

    private var filterLabel: some View {
        Image(systemName: "line.3.horizontal.decrease.circle" + (fuzzy.quickFilter != nil || fuzzy.folderFilter != nil ? ".fill" : ""))
            .frame(width: FilterPicker.iconWidth)
    }

    private func filterItem(_ filter: FilePath, key: Character?) -> some View {
        let status = volumeStatus(filter)
        let subtitle: String = switch status {
        case .notIndexed: "Click to start indexing"
        case .indexing: "Indexing in progress..."
        case .indexed: filter == .root ? "/" : filter.shellString
        case .disconnected: "Volume not connected, searching cached index"
        }
        return (
            Text((filter == .root ? (filter.url.volumeName ?? "Root") : filter.name.string) + statusSuffix(status) + "\n") +
                Text(subtitle)
                .foregroundStyle(.secondary)
                .font(.caption)
        )
        .tag(filter as FilePath?)
        .help(status == .notIndexed ? "Click to start indexing \(filter.shellString)" : status == .disconnected ? "Volume not connected, searches cached index" : "Searches inside: \(filter.shellString)")
        // Hint only; the NSEvent monitor does the actual handling.
        .ifLet(key) { view, key in
            view.keyboardShortcut(KeyEquivalent(key), modifiers: [.option])
        }
        .truncationMode(.tail)
        .disabled(status == .indexing)
    }

    private func filterItem(_ filter: QuickFilter, applyShortcut: Bool = true) -> some View {
        (
            Text("\(filter.id)\n") +
                Text(filter.menuSubtitle)
                .foregroundStyle(.secondary)
                .font(.caption)
        )
        .tag(filter as QuickFilter?)
        .help(filter.subtitle)
        // Hint only; the NSEvent monitor does the actual handling.
        .ifLet(applyShortcut ? filter.key : nil) { view, key in
            view.keyboardShortcut(KeyEquivalent(key), modifiers: [.option])
        }
        .truncationMode(.tail)
    }

    private func filterItem(_ filter: FolderFilter, applyShortcut: Bool = true) -> some View {
        let status = folderFilterStatus(filter)
        return (
            Text("\(filter.id)\(statusSuffix(status))\n") +
                Text(filter.menuSubtitle)
                .foregroundStyle(.secondary)
                .font(.caption)
        )
        .tag(filter as FolderFilter?)
        .help("Searches in \(filter.folders.map(\.shellString).joined(separator: ", "))")
        // Hint only; the NSEvent monitor does the actual handling.
        .ifLet(applyShortcut ? filter.key : nil) { view, key in
            view.keyboardShortcut(KeyEquivalent(key), modifiers: [.option])
        }
        .truncationMode(.tail)
        .disabled(status == .indexing)
    }

    @ViewBuilder private func filterButtons(_ filter: QuickFilter, action: String = "Edit") -> some View {
        Button(action) {
            isEditingFilter = action == "Edit"
            originalFilterID = filter.id
            filterDraft = QuickFilterDraft(from: filter)
            isAddingQuickFilter = true
        }
        Button("Delete") {
            Defaults[.quickFilters] = Defaults[.quickFilters].without(filter)
            if fuzzy.quickFilter == filter {
                fuzzy.quickFilter = nil
            }
        }
    }

    @ViewBuilder private func filterButtons(_ filter: FolderFilter, action: String = "Edit") -> some View {
        Button(action) {
            isEditingFilter = action == "Edit"
            originalFilterID = filter.id
            filterID = filter.id
            filterFolders = filter.folders
            filterKey = filter.key.flatMap { SauceKey(rawValue: $0.lowercased()) } ?? .escape
            isAddingFolderFilter = true
        }
        Button("Delete") {
            Defaults[.folderFilters] = Defaults[.folderFilters].without(filter)
            if fuzzy.folderFilter == filter {
                fuzzy.folderFilter = nil
            }
        }
    }

    private func installFilterShortcutMonitor() {
        guard filterShortcutMonitor == nil else { return }
        filterShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if NSApp.keyWindow?.attachedSheet != nil { return event }
            if DropZoneOverlay.shared.isPresenting { return event }
            if event.window !== AppDelegate.shared.mainWindow { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods == .option else { return event }

            // ⌥⎋ → clear all filters
            if event.keyCode == 53 {
                FUZZY.folderFilter = nil
                FUZZY.quickFilter = nil
                FUZZY.volumeFilter = nil
                return nil
            }

            guard let ch = (event.charactersIgnoringModifiers ?? "").lowercased().first else {
                return event
            }

            // Quick filters
            if let qf = Defaults[.quickFilters].first(where: { $0.key == ch }) {
                FUZZY.quickFilter = qf
                return nil
            }
            // Folder filters
            if let ff = Defaults[.folderFilters].first(where: { $0.key == ch }) {
                FUZZY.folderFilter = ff
                return nil
            }
            // Volumes (digit keys; index 0 = root, 1...n = enabled volumes)
            if let digit = ch.wholeNumberValue {
                let enabled = FUZZY.enabledVolumes
                if !enabled.isEmpty {
                    let volumes = [FilePath.root] + enabled
                    if digit < volumes.count {
                        FUZZY.volumeFilter = volumes[digit]
                        return nil
                    }
                }
            }
            return event
        }
    }

    private func removeFilterShortcutMonitor() {
        if let m = filterShortcutMonitor {
            NSEvent.removeMonitor(m)
            filterShortcutMonitor = nil
        }
    }

    private func volumeStatus(_ volume: FilePath) -> IndexStatus {
        if volume == .root { return .indexed }
        if fuzzy.disconnectedVolumes.contains(volume) {
            if fuzzy.volumeEngines[volume] != nil { return .disconnected }
            return .disconnected
        }
        if fuzzy.volumesIndexing.contains(volume) { return .indexing }
        if fuzzy.volumeEngines[volume] != nil { return .indexed }
        return .notIndexed
    }

    private func scopeForFolder(_ folder: FilePath) -> SearchScope? {
        let s = folder.string
        let home = HOME.string
        if s.hasPrefix(home + "/Library") { return .library }
        if s.hasPrefix(home) { return .home }
        if s.hasPrefix("/Applications") || s.hasPrefix("/System/Applications") { return .applications }
        if s.hasPrefix("/System") { return .system }
        if ["/usr", "/bin", "/sbin", "/opt", "/etc", "/Library", "/var", "/private"].contains(where: { s.hasPrefix($0) }) { return .root }
        return nil
    }

    private func folderFilterStatus(_ filter: FolderFilter) -> IndexStatus {
        let scopes = defaults.searchScopes
        for folder in filter.folders {
            if let volume = fuzzy.enabledVolumes.first(where: { folder.starts(with: $0) }) {
                if fuzzy.volumesIndexing.contains(volume) { return .indexing }
                if fuzzy.volumeEngines[volume] == nil { return .notIndexed }
                continue
            }
            if let scope = scopeForFolder(folder) {
                if !scopes.contains(scope) { return .notIndexed }
                if fuzzy.scopeEngines[scope] == nil {
                    return fuzzy.indexing ? .indexing : .notIndexed
                }
            }
        }
        return .indexed
    }

    private func statusSuffix(_ status: IndexStatus) -> String {
        switch status {
        case .indexed: ""
        case .indexing: " [Indexing...]"
        case .notIndexed: " [Not indexed]"
        case .disconnected: " [Disconnected]"
        }
    }

}

@MainActor
func saveQuickFilter(draft: QuickFilterDraft, originalID: String = "") {
    let filter = draft.asFilter
    guard !filter.id.isEmpty,
          filter.extensions != nil || filter.exclude != nil || filter.match != .both || filter.folders?.isEmpty == false || filter.rawQuery != nil
    else { return }

    let originalFilter = Defaults[.quickFilters].first { $0.id == originalID }

    if let keyChar = filter.key,
       let existingFilter = Defaults[.quickFilters].first(where: { $0.key == keyChar }),
       existingFilter != originalFilter
    {
        Defaults[.quickFilters] = Defaults[.quickFilters].without([existingFilter, originalFilter ?? filter]) + [existingFilter.withKey(nil), filter]
    } else {
        Defaults[.quickFilters] = Defaults[.quickFilters].without(originalFilter ?? filter) + [filter]
    }
    FUZZY.quickFilter = filter
}

@MainActor
func saveFolderFilter(id: String, folders: [FilePath], key: SauceKey, originalID: String = "") {
    guard !folders.isEmpty, !id.isEmpty else {
        return
    }

    guard key != .escape else {
        let filter = FolderFilter(id: id, folders: folders, key: nil)
        let originalFilter = Defaults[.folderFilters].first { $0.id == originalID }

        Defaults[.folderFilters] = Defaults[.folderFilters].without(originalFilter ?? filter) + [filter]
        FUZZY.folderFilter = filter

        return
    }

    // Check for existing filter with the same key and set its key to nil
    let key = key.lowercasedChar.first
    let filter = FolderFilter(id: id, folders: folders, key: key)
    let originalFilter = Defaults[.folderFilters].first { $0.id == originalID }
    // if let key, let existingFilter = Defaults[.quickFilters].first(where: { $0.key == key }) {
    //     Defaults[.quickFilters] = Defaults[.quickFilters].without(existingFilter) + [existingFilter.withKey(nil)]
    // }
    if let key, let existingFilter = Defaults[.folderFilters].first(where: { $0.key == key }), existingFilter != originalFilter {
        Defaults[.folderFilters] = Defaults[.folderFilters].without([existingFilter, originalFilter ?? filter]) + [existingFilter.withKey(nil), filter]
        FUZZY.folderFilter = filter
        return
    }

    Defaults[.folderFilters] = Defaults[.folderFilters].without(originalFilter ?? filter) + [filter]
    FUZZY.folderFilter = filter
}

// MARK: - FlowLayout

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (idx, pos) in result.positions.enumerated() {
            subviews[idx].place(at: CGPoint(x: bounds.minX + pos.x, y: bounds.minY + pos.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions = [CGPoint]()
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return (CGSize(width: maxWidth, height: y + rowHeight), positions)
    }
}

// MARK: - FilterEditorSelection

enum FilterEditorSelection: Hashable {
    case quickFilters
    case quickFilter(String)
    case folderFilters
    case folderFilter(String)
    case disconnectedVolumes
}

// MARK: - FilterEditorSheet

struct FilterEditorSheet: View {
    @Default(.quickFilters) private var quickFilters
    @Default(.folderFilters) private var folderFilters
    @State private var fuzzy = FUZZY
    @State private var selection: FilterEditorSelection? = .quickFilters
    @Environment(\.dismiss) var dismiss

    /// When true, the editor renders without the sheet header/Done button and fills its container.
    /// Used when embedded inside the Settings window's Filters pane.
    var embedded = false

    var body: some View {
        if embedded {
            editorContent
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("Filter Editor").font(.headline)
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
                .padding()

                Divider()

                editorContent
            }
            .frame(width: 820, height: 580)
        }
    }

    private var editorContent: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .onChange(of: quickFilters) { old, new in
            if case let .quickFilter(id) = selection, !new.contains(where: { $0.id == id }) {
                // Same length + same position → it's a rename. Follow the renamed filter.
                if old.count == new.count, let oldIdx = old.firstIndex(where: { $0.id == id }), oldIdx < new.count {
                    selection = .quickFilter(new[oldIdx].id)
                } else {
                    selection = .quickFilters
                }
            }
        }
        .onChange(of: folderFilters) { old, new in
            if case let .folderFilter(id) = selection, !new.contains(where: { $0.id == id }) {
                if old.count == new.count, let oldIdx = old.firstIndex(where: { $0.id == id }), oldIdx < new.count {
                    selection = .folderFilter(new[oldIdx].id)
                } else {
                    selection = .folderFilters
                }
            }
        }
    }

    private var disconnectedVolumes: [FilePath] {
        fuzzy.disconnectedVolumes.sorted(by: { $0.string < $1.string })
    }

    @ViewBuilder
    private var sidebar: some View {
        List(selection: $selection) {
            Section("Quick Filters") {
                NavigationLink(value: FilterEditorSelection.quickFilters) {
                    Label("All Quick Filters", systemImage: "slider.horizontal.3")
                }
                ForEach(quickFilters, id: \.id) { filter in
                    NavigationLink(value: FilterEditorSelection.quickFilter(filter.id)) {
                        Label(filter.id, systemImage: "line.3.horizontal.decrease.circle")
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Button(action: addQuickFilter) {
                    Label("New Quick Filter", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }

            Section("Folder Filters") {
                NavigationLink(value: FilterEditorSelection.folderFilters) {
                    Label("All Folder Filters", systemImage: "folder")
                }
                ForEach(folderFilters, id: \.id) { filter in
                    NavigationLink(value: FilterEditorSelection.folderFilter(filter.id)) {
                        Label(filter.id, systemImage: "folder.fill")
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Button(action: addFolderFilter) {
                    Label("New Folder Filter", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }

            if !disconnectedVolumes.isEmpty {
                Section("Other") {
                    NavigationLink(value: FilterEditorSelection.disconnectedVolumes) {
                        Label("Disconnected Volumes", systemImage: "externaldrive.badge.xmark")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(width: 240)
        .foregroundStyle(.primary)
    }

    @ViewBuilder
    private var detail: some View {
        Form {
            switch selection ?? .quickFilters {
            case .quickFilters:
                if quickFilters.isEmpty {
                    emptySection("No quick filters yet")
                } else {
                    ForEach(quickFilters, id: \.id) { filter in
                        QuickFilterRow(filter: filter).id(filter.id)
                    }
                }
            case let .quickFilter(id):
                if let filter = quickFilters.first(where: { $0.id == id }) {
                    QuickFilterRow(filter: filter).id(filter.id)
                } else {
                    emptySection("Filter not found")
                }
            case .folderFilters:
                if folderFilters.isEmpty {
                    emptySection("No folder filters yet")
                } else {
                    ForEach(folderFilters, id: \.id) { filter in
                        FolderFilterRow(filter: filter).id(filter.id)
                    }
                }
            case let .folderFilter(id):
                if let filter = folderFilters.first(where: { $0.id == id }) {
                    FolderFilterRow(filter: filter).id(filter.id)
                } else {
                    emptySection("Filter not found")
                }
            case .disconnectedVolumes:
                if disconnectedVolumes.isEmpty {
                    emptySection("No disconnected volumes")
                } else {
                    Section("Disconnected Volumes") {
                        ForEach(disconnectedVolumes, id: \.string) { volume in
                            DisconnectedVolumeRow(volume: volume)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func emptySection(_ text: String) -> some View {
        Section {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
        }
    }

    private func addQuickFilter() {
        let baseID = "New Filter"
        var id = baseID
        var i = 2
        while Defaults[.quickFilters].contains(where: { $0.id == id }) {
            id = "\(baseID) \(i)"
            i += 1
        }
        let filter = QuickFilter(id: id, extensions: nil, preQuery: nil, dirsOnly: false, key: nil)
        Defaults[.quickFilters].insert(filter, at: 0)
        selection = .quickFilter(id)
    }

    private func addFolderFilter() {
        let baseID = "New Folder"
        var id = baseID
        var i = 2
        while Defaults[.folderFilters].contains(where: { $0.id == id }) {
            id = "\(baseID) \(i)"
            i += 1
        }
        let filter = FolderFilter(id: id, folders: [], key: nil)
        Defaults[.folderFilters].insert(filter, at: 0)
        selection = .folderFilter(id)
    }
}

// MARK: - Folder Editor

@ViewBuilder
private func folderEditor(folders: Binding<[FilePath]>, emptyText: String, onChange: @escaping () -> Void, onAdd: @escaping () -> Void) -> some View {
    HStack(alignment: .top, spacing: 6) {
        VStack(alignment: .leading, spacing: 4) {
            if folders.wrappedValue.isEmpty {
                Text(emptyText).font(.system(size: 12)).foregroundStyle(.tertiary).hfill(.trailing)
            } else {
                FlowLayout(spacing: 4) {
                    ForEach(folders.wrappedValue) { folder in
                        HStack(spacing: 3) {
                            Text(FuzzyClient.friendlyName(for: folder))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Button(action: {
                                folders.wrappedValue.removeAll { $0 == folder }
                                onChange()
                            }) {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 9))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06))
                        .cornerRadius(4)
                    }
                }
            }
        }
        Spacer(minLength: 0)
        Button(action: onAdd) {
            Image(systemName: "plus.circle")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Add folder")
    }
}

// MARK: - QuickFilterDraft

/// Mutable working copy of a `QuickFilter`'s fields, edited by `QuickFilterEditor`.
struct QuickFilterDraft {
    init() {}
    init(from f: QuickFilter) {
        name = f.id
        extensions = f.extensions ?? ""
        exclude = f.exclude ?? ""
        match = f.match
        prepend = f.preQuery ?? ""
        append = f.postQuery ?? ""
        rawQuery = f.rawQuery
        folders = f.folders ?? []
        hotkey = f.key.flatMap { SauceKey(rawValue: $0.lowercased()) } ?? .escape
        maxDepth = f.maxDepth ?? -1
    }

    var name = ""
    var extensions = ""
    var exclude = ""
    var match: FilterMatch = .both
    var prepend = "" // added before the user's typed search (preQuery)
    var append = "" // added after the user's typed search (postQuery)
    var rawQuery: String? // nil = structured mode
    var folders: [FilePath] = []
    var hotkey: SauceKey = .escape
    var maxDepth: Int = -1

    var asFilter: QuickFilter {
        QuickFilter(
            id: name,
            extensions: extensions.trimmed.isEmpty ? nil : extensions.trimmed,
            preQuery: prepend.trimmed.isEmpty ? nil : prepend.trimmed,
            postQuery: append.trimmed.isEmpty ? nil : append.trimmed,
            dirsOnly: false,
            folders: folders.isEmpty ? nil : folders,
            key: hotkey == .escape ? nil : hotkey.lowercasedChar.first,
            maxDepth: maxDepth < 0 ? nil : maxDepth,
            exclude: exclude.trimmed.isEmpty ? nil : exclude.trimmed,
            rawQuery: rawQuery?.trimmed.isEmpty == true ? nil : rawQuery?.trimmed,
            match: match
        )
    }
}

// MARK: - QuickFilterEditor

/// Shared Quick Filter editor (used by the Settings list row and the add sheet). Renders three
/// Form sections: a pinned edit-mode section, the name + structured fields, and hotkey + scope.
struct QuickFilterEditor: View {
    @Binding var draft: QuickFilterDraft

    var matchCountText = ""
    var onEdit: () -> Void = {}
    var onAddFolder: () -> Void = {}
    var onDelete: (() -> Void)? = nil

    var body: some View {
        // Pinned at top so switching modes only changes the sections below it.
        Section {
            Picker("Edit mode", selection: modeBinding) {
                Text("Structured fields").tag(Mode.fields)
                Text("Raw query").tag(Mode.raw)
            }
            .pickerStyle(.segmented)
            Text("Construct the query using the controls below or edit the raw query directly. They are equivalent as the fields translate into a raw query themselves.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            rawQueryRow
        } header: {
            HStack {
                Text(draft.name.isEmpty ? "Quick Filter" : draft.name).font(.headline)
                Spacer()
                if let onDelete {
                    Button(action: onDelete) { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        .help("Delete filter")
                }
            }
        }

        Section {
            TextField("Name", text: $draft.name, prompt: Text("Filter name"))
                .textFieldStyle(.roundedBorder)
                .onChange(of: draft.name) { onEdit() }
            if fieldsMode {
                TextField("Extensions", text: $draft.extensions, prompt: Text("e.g.: .png .jpg .pdf"))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: draft.extensions) { onEdit() }
                TextField("Exclude", text: $draft.exclude, prompt: Text("e.g.: draft .zip node_modules/"))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: draft.exclude) { onEdit() }
                Picker("Match", selection: $draft.match) {
                    Text("Both").tag(FilterMatch.both)
                    Text("Files").tag(FilterMatch.files)
                    Text("Folders").tag(FilterMatch.folders)
                }
                .pickerStyle(.segmented)
                .onChange(of: draft.match) { onEdit() }
                TextField("Prepend", text: $draft.prepend, prompt: Text("Added before your search"))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: draft.prepend) { onEdit() }
                TextField("Append", text: $draft.append, prompt: Text("Added after your search"))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: draft.append) { onEdit() }
            }
        }

        Section {
            LabeledContent("Hotkey") {
                HStack(spacing: 4) {
                    Text("\u{2325} +").font(.system(size: 11)).foregroundStyle(.secondary)
                    DynamicKey(key: $draft.hotkey, recording: $recording, allowedKeys: .ALL_KEYS)
                        .font(.mono(11, weight: .bold))
                        .onChange(of: draft.hotkey) { onEdit() }
                        .frame(width: 28)
                }
            }
            if fieldsMode {
                Stepper(value: $draft.maxDepth, in: -1 ... 100) {
                    HStack {
                        Text("Max depth")
                        Spacer()
                        Text(draft.maxDepth < 0 ? "∞" : "\(draft.maxDepth)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: draft.maxDepth) { onEdit() }
                .help("Limit results to entries at most N folders below the search root. -1 = unlimited.")
                LabeledContent("Search in") {
                    folderEditor(folders: $draft.folders, emptyText: "All locations", onChange: onEdit, onAdd: onAddFolder)
                }
            }
        }
    }

    private enum Mode: Hashable { case fields, raw }

    @State private var recording = false

    private var modeBinding: Binding<Mode> {
        Binding(
            get: { draft.rawQuery == nil ? .fields : .raw },
            set: { newMode in
                if newMode == .raw {
                    draft.rawQuery = draft.asFilter.queryString
                } else {
                    draft.rawQuery = nil
                }
                onEdit()
            }
        )
    }

    private var fieldsMode: Bool { draft.rawQuery == nil }
    private var preview: String { draft.asFilter.queryString }

    @ViewBuilder private var rawQueryRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Raw query").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if !matchCountText.isEmpty {
                    Text(matchCountText).font(.mono(11)).foregroundStyle(.tertiary)
                }
            }
            if fieldsMode {
                // Read-only preview of the compiled query; wraps at spaces (token boundaries).
                Text(preview.isEmpty ? "everything" : preview)
                    .font(.mono(11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            } else {
                // Single-line editable field, like the search bar (multiline is for reading only).
                TextField(
                    "",
                    text: Binding(get: { draft.rawQuery ?? "" }, set: { draft.rawQuery = $0 }),
                    prompt: Text("Full query, e.g.: .png in:~/Desktop !draft")
                )
                .font(.mono(12))
                .textFieldStyle(.roundedBorder)
                .onChange(of: draft.rawQuery) { onEdit() }
            }
        }
    }
}

// MARK: - QuickFilterRow

struct QuickFilterRow: View {
    init(filter: QuickFilter) {
        self.filter = filter
        _draft = State(initialValue: QuickFilterDraft(from: filter))
    }

    @EnvironmentObject var env: EnvState

    let filter: QuickFilter

    var body: some View {
        QuickFilterEditor(
            draft: $draft,
            matchCountText: matchCountText,
            onEdit: { save(); refreshCount() },
            onAddFolder: addFolder,
            onDelete: delete
        )
        .task { refreshCount() }
    }

    @State private var draft: QuickFilterDraft
    @State private var matchCountText = ""
    @State private var countTask: Task<Void, Never>?

    @Default(.quickFilters) private var quickFilters

    private func refreshCount() {
        countTask?.cancel()
        let f = draft.asFilter
        countTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return }
            let n = await FUZZY.matchCount(
                query: f.queryString,
                dirsOnly: f.searchDirsOnly,
                folders: f.folders ?? [],
                maxDepth: f.maxDepth
            )
            if Task.isCancelled { return }
            await MainActor.run { matchCountText = n >= 5000 ? "~5000+ results" : "~\(n) results" }
        }
    }

    private func save() {
        guard let idx = quickFilters.firstIndex(where: { $0.id == filter.id }) else { return }
        let updated = draft.asFilter
        quickFilters[idx] = updated
        if FUZZY.quickFilter == filter { FUZZY.quickFilter = updated }
    }

    private func delete() {
        quickFilters.removeAll { $0 == filter }
        if FUZZY.quickFilter == filter { FUZZY.quickFilter = nil }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.begin { response in
            if response == .OK {
                for url in panel.urls {
                    if let path = url.existingFilePath, !draft.folders.contains(path) { draft.folders.append(path) }
                }
                save()
                refreshCount()
            }
        }
    }
}

// MARK: - FolderFilterRow

struct FolderFilterRow: View {
    init(filter: FolderFilter) {
        self.filter = filter
        _name = State(initialValue: filter.id)
        _folders = State(initialValue: filter.folders)
        _hotkey = State(initialValue: filter.key.flatMap { SauceKey(rawValue: $0.lowercased()) } ?? .escape)
        _maxDepth = State(initialValue: filter.maxDepth ?? -1)
    }

    @EnvironmentObject var env: EnvState

    let filter: FolderFilter

    var body: some View {
        Section {
            TextField("Name", text: $name, prompt: Text("Filter name"))
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit { save() }
                .onChange(of: nameFocused) { _, focused in
                    if !focused { save() }
                }
            LabeledContent("Folders") {
                folderEditor(folders: $folders, emptyText: "No folders", onChange: { save(); refreshCount() }, onAdd: addFolder)
            }
        } header: {
            HStack {
                Text(filter.id).font(.headline)
                Text(folders.map { FuzzyClient.friendlyName(for: $0) }.joined(separator: ", "))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if !matchCountText.isEmpty {
                    Text(matchCountText)
                        .font(.caption).foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Button(action: delete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help("Delete filter")
            }
        }
        .task { refreshCount() }

        Section {
            Stepper(value: $maxDepth, in: -1 ... 100) {
                HStack {
                    Text("Max depth")
                    Spacer()
                    Text(maxDepth < 0 ? "∞" : "\(maxDepth)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: maxDepth) { save(); refreshCount() }
            .help("Limit results to entries at most N folders below the search root. -1 = unlimited.")
            LabeledContent("Hotkey") {
                HStack(spacing: 4) {
                    Text("\u{2325} +").font(.system(size: 11)).foregroundStyle(.secondary)
                    DynamicKey(key: $hotkey, recording: $recording, allowedKeys: .ALL_KEYS)
                        .font(.mono(11, weight: .bold))
                        .onChange(of: hotkey) { save() }
                        .frame(width: 28)
                }
            }
        }
    }

    @State private var name: String
    @State private var folders: [FilePath]
    @State private var hotkey: SauceKey
    @State private var recording = false
    @State private var maxDepth: Int
    @FocusState private var nameFocused: Bool
    @State private var matchCountText = ""
    @State private var countTask: Task<Void, Never>?

    @Default(.folderFilters) private var folderFilters

    private func refreshCount() {
        countTask?.cancel()
        let currentFolders = folders
        let currentMaxDepth = maxDepth
        countTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return }
            let n = await FUZZY.matchCount(
                query: "",
                dirsOnly: false,
                folders: currentFolders,
                maxDepth: currentMaxDepth < 0 ? nil : currentMaxDepth
            )
            if Task.isCancelled { return }
            await MainActor.run { matchCountText = n >= 5000 ? "~5000+ results" : "~\(n) results" }
        }
    }

    private func save() {
        guard let idx = folderFilters.firstIndex(where: { $0.id == filter.id }) else { return }
        let updated = FolderFilter(id: name, folders: folders, key: hotkey == .escape ? nil : hotkey.lowercasedChar.first, maxDepth: maxDepth < 0 ? nil : maxDepth)
        folderFilters[idx] = updated
        if FUZZY.folderFilter == filter { FUZZY.folderFilter = updated }
    }

    private func delete() {
        folderFilters.removeAll { $0 == filter }
        if FUZZY.folderFilter == filter { FUZZY.folderFilter = nil }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.begin { response in
            if response == .OK {
                for url in panel.urls {
                    if let path = url.existingFilePath, !folders.contains(path) { folders.append(path) }
                }
                save()
            }
        }
    }
}

// MARK: - DisconnectedVolumeRow

struct DisconnectedVolumeRow: View {
    let volume: FilePath

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.xmark")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(volume.name.string).font(.system(size: 12, weight: .bold))
                    Text("Disconnected")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                    if let count = fuzzy.volumeEngines[volume]?.count {
                        Text("\(count.formatted()) cached entries")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(volume.shellString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Remove", role: .destructive) {
                confirmRemoval = true
            }
            .buttonStyle(.bordered)
            .help("Delete cached index for \(volume.name.string)")
        }
        .padding(10)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
        .confirmationDialog(
            "Remove \(volume.name.string)?",
            isPresented: $confirmRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { fuzzy.removeVolume(volume) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The cached index for this volume will be deleted. Reconnect the drive to index it again.")
        }
    }

    @State private var fuzzy = FUZZY
    @State private var confirmRemoval = false

}
