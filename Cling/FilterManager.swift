import Defaults
import Foundation
import Lowtech
import SwiftUI
import System

// MARK: - QuickFilterAddSheet

struct QuickFilterAddSheet: View {
    @EnvironmentObject var env: EnvState

    @Binding var id: String
    @Binding var extensions: String
    @Binding var exclude: String
    @Binding var match: FilterMatch
    @Binding var folders: [FilePath]
    @Binding var key: SauceKey
    @Binding var rawQuery: String?

    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("Quick Filter").font(.headline)
            HStack {
                TextField("Name", text: $id)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveIfValid() }
                    .padding(.trailing, 8)
                Text("Hotkey: ")
                Text("\u{2325} +").bold()
                DynamicKey(key: $key, recording: $env.recording, allowedKeys: .ALL_KEYS)
            }

            if rawQuery == nil {
                TextField("Extensions (e.g. .pdf .png .jpeg)", text: $extensions)
                    .textFieldStyle(.roundedBorder)

                TextField("Exclude (e.g. .tmp .log)", text: $exclude)
                    .textFieldStyle(.roundedBorder)

                Picker("Match", selection: $match) {
                    Text("Both").tag(FilterMatch.both)
                    Text("Files").tag(FilterMatch.files)
                    Text("Folders").tag(FilterMatch.folders)
                }
                .pickerStyle(.segmented)
            } else {
                TextField("Query", text: Binding(get: { rawQuery ?? "" }, set: { rawQuery = $0 }),
                          prompt: Text("Full query, e.g.: .png in:~/Desktop !draft"))
                    .textFieldStyle(.roundedBorder)
                    .font(.mono(12))
            }

            HStack {
                Text(compiledQuery)
                    .font(.mono(11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                if rawQuery == nil {
                    Button("Edit as query") {
                        rawQuery = compiledQuery
                    }.font(.caption)
                } else {
                    Button("Use fields") {
                        rawQuery = nil
                    }.font(.caption)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Folders (optional)").font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(folders) { folder in
                    HStack {
                        Text(folder.shellString).mono(11).lineLimit(1)
                        Spacer()
                        Button(action: { folders.removeAll { $0 == folder } }) {
                            Image(systemName: "minus.circle.fill")
                        }.buttonStyle(FlatButton(color: .clear, textColor: .red.opacity(0.7)))
                    }
                }
                Button(action: addFolder) {
                    Label("Add folder", systemImage: "plus")
                }.font(.system(size: 11))
            }

            HStack {
                Button("Cancel") {
                    id = ""
                    dismiss()
                }
                Button("Save") { dismiss() }
                    .disabled(id.isEmpty || !hasValidFilter)
            }
        }
        .onExitCommand {
            id = ""
            dismiss()
        }
        .padding()
    }

    private var compiledQuery: String {
        if let rq = rawQuery {
            return rq
        }
        return compileFilterQuery(
            extensions: extensions.trimmed.isEmpty ? nil : extensions.trimmed,
            exclude: exclude.trimmed.isEmpty ? nil : exclude.trimmed,
            match: match,
            folders: folders.map(\.string),
            maxDepth: nil
        )
    }

    private var hasValidFilter: Bool {
        if let rq = rawQuery {
            return !rq.trimmed.isEmpty
        }
        return !extensions.isEmpty || !exclude.isEmpty || match != .both || !folders.isEmpty
    }

    private func saveIfValid() {
        guard !id.isEmpty, hasValidFilter else { return }
        dismiss()
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.begin { response in
            if response == .OK {
                for url in panel.urls {
                    if let path = url.existingFilePath, !folders.contains(path) {
                        folders.append(path)
                    }
                }
            }
        }
    }
}

// MARK: - QuickFilterEditorView

struct QuickFilterEditorView: View {
    var label: String? = nil

    var body: some View {
        newQuickFilterButton
            .onChange(of: filterID) {
                guard !isEditing else { return }
                filterKey = getFilterKey(id: filterID)
            }
    }

    @State private var fuzzy = FUZZY
    @Binding var isPresented: Bool
    @Binding var filterID: String
    @Binding var filterKey: SauceKey
    @Binding var isEditing: Bool

    private var newQuickFilterButton: some View {
        Button(action: { isPresented = true }) {
            if let label {
                Text(label)
            } else {
                Image(systemName: "plus.circle.fill")
            }
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .focusable(false)
    }
}

// MARK: - FolderFilterEditorView

struct FolderFilterEditorView: View {
    var label: String? = nil

    var body: some View {
        newFolderFilterButton
            .onChange(of: filterID) {
                guard !isEditing else { return }
                filterKey = getFilterKey(id: filterID)
            }
    }

    @Binding var isPresented: Bool
    @Binding var filterID: String
    @Binding var filterKey: SauceKey
    @Binding var isEditing: Bool

    private var newFolderFilterButton: some View {
        Button(action: { isPresented = true }) {
            if let label {
                Text(label)
            } else {
                Image(systemName: "plus.circle.fill")
            }
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .focusable(false)
    }
}

// MARK: - FilePath + @retroactive Identifiable

extension FilePath: @retroactive Identifiable {
    public var id: String { string }
}

// MARK: - FolderFilterAddSheet

struct FolderFilterAddSheet: View {
    @EnvironmentObject var env: EnvState

    @Binding var id: String
    @Binding var folders: [FilePath]
    @Binding var key: SauceKey

    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack {
            Text("New Folder Filter").font(.headline)
            HStack {
                TextField("Name", text: $id)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        guard !folders.isEmpty, !id.isEmpty else { return }
                        dismiss()
                    }
                    .padding(.trailing, 8)
                Text("Hotkey: ")
                Text("\u{2325} +").bold()
                DynamicKey(key: $key, recording: $env.recording, allowedKeys: .ALL_KEYS)
            }

            VStack(alignment: .leading) {
                ForEach(folders) { folder in
                    HStack {
                        Text(folder.shellString)
                            .mono(12)
                            .hfill(.leading)
                        Button(action: { folders.removeAll(where: { $0 == folder }) }) {
                            Image(systemName: "minus.circle.fill")
                        }.buttonStyle(FlatButton(color: .clear, textColor: .red.opacity(0.7)))
                    }
                }
                Button(action: addFolder) {
                    Label("Add folder", systemImage: "plus")
                }
            }
            .hfill(.leading)
            .roundbg(verticalPadding: folders.isEmpty ? 0 : 8, horizontalPadding: folders.isEmpty ? 0 : 8, color: .primary.opacity(folders.isEmpty ? 0 : 0.05))
            .padding(.bottom)

            HStack {
                Button("Cancel") {
                    id = ""
                    dismiss()
                }
                Button("Save") { dismiss() }
                    .disabled(folders.isEmpty || id.isEmpty)
            }
        }
        .onExitCommand {
            id = ""
            dismiss()
        }
        .padding()
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        panel.begin { response in
            if response == .OK, let path = panel.url?.existingFilePath, !folders.contains(path) {
                folders = folders + [path]
            }
        }
    }
}

func getFilterKey(id: String? = nil) -> SauceKey {
    guard let id else {
        return .escape
    }

    let usedKeys = Set(Defaults[.quickFilters].compactMap(\.key) + Defaults[.folderFilters].compactMap(\.key))

    for char in id.lowercased() {
        if !usedKeys.contains(char), let key = SauceKey(rawValue: String(char)) {
            return key
        }
    }
    return .escape
}
