import Defaults
import Foundation
import Lowtech
import LowtechPro
import SwiftUI
import System

struct FilterPicker: View {
    @State private var defaults = DEFAULTS_CACHE
    @State private var fuzzy: FuzzyClient = FUZZY
    @ObservedObject private var km = KM
    @ObservedObject private var proManager = PM

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
                    filterItem(filter)
                }
            } label: { Text("Folder filter") }
                .labelsHidden()
                .pickerStyle(.inline)
        }
    }

    private enum IndexStatus {
        case indexed, indexing, notIndexed, disconnected
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
        .ifLet(key) { view, key in
            view.keyboardShortcut(KeyEquivalent(key), modifiers: [.option])
        }
        .truncationMode(.tail)
        .disabled(status == .indexing)
    }

    private func filterItem(_ filter: QuickFilter) -> some View {
        (
            Text("\(filter.id)\n") +
                Text(filter.subtitle)
                .foregroundStyle(.secondary)
                .font(.caption)
        )
        .tag(filter as QuickFilter?)
        .help(filter.subtitle)
        .ifLet(filter.key) { view, key in
            view.keyboardShortcut(KeyEquivalent(key), modifiers: [.option])
        }
        .truncationMode(.tail)
    }

    private func filterItem(_ filter: FolderFilter) -> some View {
        let status = folderFilterStatus(filter)
        return (
            Text("\(filter.id)\(statusSuffix(status))\n") +
                Text(filter.folders.map(\.shellString).joined(separator: ", "))
                .foregroundStyle(.secondary)
                .font(.caption)
        )
        .tag(filter as FolderFilter?)
        .help("Searches in \(filter.folders.map(\.shellString).joined(separator: ", "))")
        .ifLet(filter.key) { view, key in
            view.keyboardShortcut(KeyEquivalent(key), modifiers: [.option])
        }
        .truncationMode(.tail)
        .disabled(status == .indexing)
    }

    @ViewBuilder private func filterButtons(_ filter: QuickFilter, action: String = "Edit") -> some View {
        Button(action) {
            isEditingFilter = action == "Edit"
            originalFilterID = filter.id
            filterID = filter.id
            filterSuffix = filter.extensions ?? ""
            filterQuery = filter.preQuery ?? ""
            filterPostQuery = filter.postQuery ?? ""
            filterDirsOnly = filter.dirsOnly
            filterFolders = filter.folders ?? []
            filterKey = filter.key.flatMap { SauceKey(rawValue: $0.lowercased()) } ?? .escape
            isAddingQuickFilter = true
        }
        Button("Delete") {
            Defaults[.quickFilters] = Defaults[.quickFilters].without(filter)
            if fuzzy.quickFilter == filter {
                fuzzy.quickFilter = nil
            }
        }
    }

    @State private var lastQuery = ""

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
                    filterItem(filter)
                }
            } label: { Text("Quick filter") }
                .labelsHidden()
                .pickerStyle(.inline)
        }
    }

    @State private var isAddingQuickFilter = false
    @State private var isAddingFolderFilter = false
    @State private var isEditingFilter = false
    @State private var originalFilterID = ""
    @State private var filterID = ""
    @State private var filterSuffix = ""
    @State private var filterQuery = ""
    @State private var filterPostQuery = ""
    @State private var filterDirsOnly = false
    @State private var filterFolders: [FilePath] = []
    @State private var filterKey: SauceKey = .escape

    var body: some View {
        menu
            .sheet(isPresented: $isAddingQuickFilter, onDismiss: {
                saveQuickFilter(
                    id: filterID,
                    extensions: filterSuffix.trimmed.isEmpty ? nil : filterSuffix.trimmed,
                    preQuery: filterQuery.trimmed.isEmpty ? nil : filterQuery.trimmed,
                    postQuery: filterPostQuery.trimmed.isEmpty ? nil : filterPostQuery.trimmed,
                    dirsOnly: filterDirsOnly,
                    folders: filterFolders.isEmpty ? nil : filterFolders,
                    key: filterKey,
                    originalID: originalFilterID
                )
                filterID = ""
                filterSuffix = ""
                filterQuery = ""
                filterPostQuery = ""
                filterDirsOnly = false
                filterFolders = []
                originalFilterID = ""
                isEditingFilter = false
            }) {
                QuickFilterAddSheet(id: $filterID, extensions: $filterSuffix, preQuery: $filterQuery, postQuery: $filterPostQuery, dirsOnly: $filterDirsOnly, folders: $filterFolders, key: $filterKey)
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

    @State private var showFilterEditor = false

    private var filterLabel: some View {
        Image(systemName: "line.3.horizontal.decrease.circle" + (fuzzy.quickFilter != nil || fuzzy.folderFilter != nil ? ".fill" : ""))
            .frame(width: FilterPicker.iconWidth)
    }

    static let iconWidth: CGFloat = 20

    @State private var showNeedsProPopover = false

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

                    Button("All files") {
                        fuzzy.folderFilter = nil
                        fuzzy.quickFilter = nil
                        fuzzy.volumeFilter = nil
                    }
                    .help("Searches all indexed files without any filters")
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
}

@MainActor
func saveQuickFilter(id: String, extensions: String?, preQuery: String?, postQuery: String? = nil, dirsOnly: Bool, folders: [FilePath]? = nil, key: SauceKey, originalID: String = "") {
    guard !id.isEmpty, (extensions != nil || preQuery != nil || postQuery != nil || dirsOnly || folders?.isEmpty == false) else { return }

    let keyChar: Character? = key == .escape ? nil : key.lowercasedChar.first
    let filter = QuickFilter(id: id, extensions: extensions, preQuery: preQuery, postQuery: postQuery, dirsOnly: dirsOnly, folders: folders?.isEmpty == true ? nil : folders, key: keyChar)
    let originalFilter = Defaults[.quickFilters].first { $0.id == originalID }

    if let keyChar, let existingFilter = Defaults[.quickFilters].first(where: { $0.key == keyChar }), existingFilter != originalFilter {
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

// MARK: - Flow Layout

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

// MARK: - Filter Editor Sheet

struct FilterEditorSheet: View {
    @Default(.quickFilters) private var quickFilters
    @Default(.folderFilters) private var folderFilters
    @State private var fuzzy = FUZZY
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Filter Editor").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Quick Filters
                    Section {
                        ForEach(Array(quickFilters.enumerated()), id: \.offset) { _, filter in
                            QuickFilterRow(filter: filter)
                        }
                        Button(action: addQuickFilter) {
                            Label("New Quick Filter", systemImage: "plus.circle")
                        }.buttonStyle(.plain).foregroundColor(.accentColor)
                    } header: {
                        HStack {
                            Text("Quick Filters").font(.subheadline).bold().foregroundStyle(.secondary)
                            Spacer()
                            Button(action: addQuickFilter) {
                                Label("New Quick Filter", systemImage: "plus.circle")
                            }.buttonStyle(.plain).foregroundColor(.accentColor).font(.system(size: 11))
                        }
                    }

                    Divider()

                    // Folder Filters
                    Section {
                        ForEach(Array(folderFilters.enumerated()), id: \.offset) { _, filter in
                            FolderFilterRow(filter: filter)
                        }
                        Button(action: addFolderFilter) {
                            Label("New Folder Filter", systemImage: "plus.circle")
                        }.buttonStyle(.plain).foregroundColor(.accentColor)
                    } header: {
                        HStack {
                            Text("Folder Filters").font(.subheadline).bold().foregroundStyle(.secondary)
                            Spacer()
                            Button(action: addFolderFilter) {
                                Label("New Folder Filter", systemImage: "plus.circle")
                            }.buttonStyle(.plain).foregroundColor(.accentColor).font(.system(size: 11))
                        }
                    }

                    let disconnected = fuzzy.disconnectedVolumes.sorted(by: { $0.string < $1.string })
                    if !disconnected.isEmpty {
                        Divider()

                        Section {
                            ForEach(disconnected, id: \.string) { volume in
                                DisconnectedVolumeRow(volume: volume)
                            }
                        } header: {
                            Text("Disconnected Volumes").font(.subheadline).bold().foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
            }
        }
        .frame(width: 700, height: 550)
    }

    private func addQuickFilter() {
        let filter = QuickFilter(id: "New Filter", extensions: nil, preQuery: nil, dirsOnly: false, key: nil)
        Defaults[.quickFilters].append(filter)
    }

    private func addFolderFilter() {
        let filter = FolderFilter(id: "New Folder", folders: [], key: nil)
        Defaults[.folderFilters].append(filter)
    }
}

struct QuickFilterRow: View {
    init(filter: QuickFilter) {
        self.filter = filter
        _name = State(initialValue: filter.id)
        _extensions = State(initialValue: filter.extensions ?? "")
        _preQuery = State(initialValue: filter.preQuery ?? "")
        _postQuery = State(initialValue: filter.postQuery ?? "")
        _dirsOnly = State(initialValue: filter.dirsOnly)
        _folders = State(initialValue: filter.folders ?? [])
        _hotkey = State(initialValue: filter.key.flatMap { SauceKey(rawValue: $0.lowercased()) } ?? .escape)
    }

    @EnvironmentObject var env: EnvState

    let filter: QuickFilter

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(filter.id).font(.system(size: 12, weight: .bold))
                Text(filter.header).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button(action: delete) {
                    Image(systemName: "trash").foregroundStyle(.red)
                }.buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .onChange(of: name) { save() }
                    TextField("Extensions (.png .jpg)", text: $extensions)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: extensions) { save() }
                }
                HStack {
                    TextField("Pre-query", text: $preQuery)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: preQuery) { save() }
                    TextField("Post-query", text: $postQuery)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: postQuery) { save() }
                }
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Toggle("Dirs only", isOn: $dirsOnly)
                            .onChange(of: dirsOnly) { save() }
                            .fixedSize()
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.primary.opacity(0.04))
                    .cornerRadius(4)

                    HStack(spacing: 4) {
                        Text("Hotkey").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text("\u{2325} +").font(.system(size: 10)).bold().foregroundStyle(.secondary)
                        DynamicKey(key: $hotkey, recording: $recording, allowedKeys: .ALL_KEYS)
                            .onChange(of: hotkey) { save() }
                            .frame(width: 28)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.primary.opacity(0.04))
                    .cornerRadius(4)

                    Spacer()
                }
                HStack(spacing: 6) {
                    Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(.secondary)
                    if folders.isEmpty {
                        Text("All locations").font(.system(size: 11)).foregroundStyle(.tertiary)
                    } else {
                        FlowLayout(spacing: 4) {
                            ForEach(folders) { folder in
                                HStack(spacing: 3) {
                                    Text(FuzzyClient.friendlyName(for: folder))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                    Button(action: { folders.removeAll { $0 == folder }; save() }) {
                                        Image(systemName: "xmark.circle.fill").font(.system(size: 9))
                                    }.buttonStyle(.plain).foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.primary.opacity(0.06))
                                .cornerRadius(4)
                            }
                        }
                    }
                    Button(action: addFolder) {
                        Image(systemName: "plus.circle").font(.system(size: 11))
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.03))
            .cornerRadius(8)
        }
    }

    @State private var name: String
    @State private var extensions: String
    @State private var preQuery: String
    @State private var postQuery: String
    @State private var dirsOnly: Bool
    @State private var folders: [FilePath]
    @State private var hotkey: SauceKey
    @State private var recording = false

    @Default(.quickFilters) private var quickFilters

    private func save() {
        guard let idx = quickFilters.firstIndex(of: filter) else { return }
        let updated = QuickFilter(
            id: name,
            extensions: extensions.trimmed.isEmpty ? nil : extensions.trimmed,
            preQuery: preQuery.trimmed.isEmpty ? nil : preQuery.trimmed,
            postQuery: postQuery.trimmed.isEmpty ? nil : postQuery.trimmed,
            dirsOnly: dirsOnly,
            folders: folders.isEmpty ? nil : folders,
            key: hotkey == .escape ? nil : hotkey.lowercasedChar.first
        )
        quickFilters[idx] = updated
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
                    if let path = url.existingFilePath, !folders.contains(path) { folders.append(path) }
                }
                save()
            }
        }
    }
}

struct FolderFilterRow: View {
    init(filter: FolderFilter) {
        self.filter = filter
        _name = State(initialValue: filter.id)
        _folders = State(initialValue: filter.folders)
        _hotkey = State(initialValue: filter.key.flatMap { SauceKey(rawValue: $0.lowercased()) } ?? .escape)
    }

    @EnvironmentObject var env: EnvState

    let filter: FolderFilter

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Searches in").font(.system(size: 12, weight: .bold))
                Text(folders.map { FuzzyClient.friendlyName(for: $0) }.joined(separator: ", "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button(action: delete) {
                    Image(systemName: "trash").foregroundStyle(.red)
                }.buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .onChange(of: name) { save() }

                    HStack(spacing: 4) {
                        Text("Hotkey").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text("\u{2325} +").font(.system(size: 10)).bold().foregroundStyle(.secondary)
                        DynamicKey(key: $hotkey, recording: $recording, allowedKeys: .ALL_KEYS)
                            .onChange(of: hotkey) { save() }
                            .frame(width: 28)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.primary.opacity(0.04))
                    .cornerRadius(4)

                    Spacer()
                }
                HStack(spacing: 6) {
                    Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(.secondary)
                    if folders.isEmpty {
                        Text("No folders").font(.system(size: 11)).foregroundStyle(.tertiary)
                    } else {
                        FlowLayout(spacing: 4) {
                            ForEach(folders) { folder in
                                HStack(spacing: 3) {
                                    Text(FuzzyClient.friendlyName(for: folder))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                    Button(action: { folders.removeAll { $0 == folder }; save() }) {
                                        Image(systemName: "xmark.circle.fill").font(.system(size: 9))
                                    }.buttonStyle(.plain).foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.primary.opacity(0.06))
                                .cornerRadius(4)
                            }
                        }
                    }
                    Button(action: addFolder) {
                        Image(systemName: "plus.circle").font(.system(size: 11))
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.03))
            .cornerRadius(8)
        }
    }

    @State private var name: String
    @State private var folders: [FilePath]
    @State private var hotkey: SauceKey
    @State private var recording = false

    @Default(.folderFilters) private var folderFilters

    private func save() {
        guard let idx = folderFilters.firstIndex(of: filter) else { return }
        let updated = FolderFilter(id: name, folders: folders, key: hotkey == .escape ? nil : hotkey.lowercasedChar.first)
        folderFilters[idx] = updated
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

struct DisconnectedVolumeRow: View {
    let volume: FilePath
    @State private var fuzzy = FUZZY
    @State private var confirmRemoval = false

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
}
