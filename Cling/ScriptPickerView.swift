import ClopSDK
import Defaults
import Lowtech
import OSLog
import SwiftUI
import System
import UniformTypeIdentifiers

private let log = Logger(subsystem: clingSubsystem, category: "ScriptPickerView")

// MARK: - ScriptPickerView

struct ScriptPickerView: View {
    let fileURLs: [URL]
    @Environment(\.dismiss) var dismiss
    @State private var isShowingAddScript = false
    @State private var scriptName = ""
    @State private var selectedRunner: ScriptRunner? = .zsh
    @State private var scriptManager = SM
    @State private var confirmScript: URL? = nil
    @State private var deleteScript: URL? = nil

    func scriptButton(_ script: URL) -> some View {
        ScriptRowButton(
            script: script,
            scriptManager: scriptManager,
            onRun: {
                if scriptManager.scriptsWithConfirm.contains(script) {
                    confirmScript = script
                } else {
                    scriptManager.run(script: script, args: fileURLs.map(\.path))
                    dismiss()
                }
            },
            onDelete: { deleteScript = script }
        )
        .ifLet(scriptManager.scriptShortcuts[script]) {
            $0.keyboardShortcut(KeyEquivalent($1), modifiers: [])
        }
    }

    @ViewBuilder
    var scriptList: some View {
        let paths = fileURLs.compactMap(\.filePath)
        ForEach(scriptManager.scriptURLs.sorted(by: \.lastPathComponent).filter { scriptManager.isEligible($0, forPaths: paths) }, id: \.path) { script in
            scriptButton(script)
        }.focusable(false)
    }

    var body: some View {
        VStack {
            if !scriptManager.scriptURLs.isEmpty {
                scriptList
            } else {
                Text("No scripts found in")
                Button("\(scriptsFolder.shellString)") {
                    NSWorkspace.shared.open(scriptsFolder.url)
                }
                .buttonStyle(.text)
                .font(.mono(10))
                .padding(.top, 2)
                .focusable(false)
            }

            HStack {
                Button("⌘N Create Script") { isShowingAddScript = true }
                    .keyboardShortcut("n", modifiers: [.command])
                Button("⌘O Open script folder") {
                    NSWorkspace.shared.open(scriptsFolder.url)
                    NSApp.deactivate()
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
            .padding(.top)
        }
        .padding()
        .sheet(isPresented: $isShowingAddScript, onDismiss: createNewScript) {
            AddScriptView(name: $scriptName, selectedRunner: $selectedRunner)
        }
        .alert(
            "Run \(confirmScript?.lastPathComponent.ns.deletingPathExtension ?? "script")?",
            isPresented: Binding(get: { confirmScript != nil }, set: { if !$0 { confirmScript = nil } })
        ) {
            Button("Run") {
                if let script = confirmScript {
                    scriptManager.run(script: script, args: fileURLs.map(\.path))
                    confirmScript = nil
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {
                confirmScript = nil
            }
        } message: {
            Text("This will run on \(fileURLs.count) file\(fileURLs.count == 1 ? "" : "s")")
        }
        .alert(
            "Delete \(deleteScript?.lastPathComponent.ns.deletingPathExtension ?? "script")?",
            isPresented: Binding(get: { deleteScript != nil }, set: { if !$0 { deleteScript = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let script = deleteScript {
                    try? FileManager.default.removeItem(at: script)
                    deleteScript = nil
                    scriptManager.fetchScripts()
                }
            }
            Button("Cancel", role: .cancel) {
                deleteScript = nil
            }
        } message: {
            Text("This will permanently delete the script file")
        }
    }

    func createNewScript() {
        guard !scriptName.isEmpty else { return }
        let ext = selectedRunner?.fileExtension ?? "sh"
        let newScript = scriptsFolder / "\(scriptName.safeFilename).\(ext)"

        do {
            let runner = selectedRunner ?? .zsh
            try "\(runner.shebang)\n\(runner.template)".write(to: newScript.url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: newScript.string)
            newScript.edit()
        } catch {
            log.error("Failed to create script: \(error.localizedDescription, privacy: .public)")
        }

        scriptName = ""
        selectedRunner = nil
        scriptManager.fetchScripts() // Update scripts and shortcuts
    }
}

// MARK: - ScriptActionButtons

struct ScriptActionButtons: View {
    let selectedResults: Set<FilePath>
    var focused: FocusState<FocusedField?>.Binding

    var body: some View {
        HStack {
            runThroughScriptButton
                .frame(width: 110, alignment: .leading)
                .disabled(selectedResults.isEmpty || scriptManager.process != nil)

            Divider().frame(height: 16)

            if commonScripts.isEmpty {
                Text("Script hotkeys will appear here")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 10))
                Spacer()
            } else {
                HStack(spacing: 1) {
                    Text("⌘").roundbg(color: .bg.primary.opacity(0.2))
                    Text("⌃").roundbg(color: .bg.primary.opacity(0.2))
                    Text(" +")
                }.foregroundColor(.fg.warm)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        scriptList
                    }.buttonStyle(.borderlessText(color: .fg.warm.opacity(0.8)))
                }.disabled(selectedResults.isEmpty || scriptManager.process != nil)
            }

            runningProcessButton
            clopButton
        }
        .font(.system(size: 10))
        .buttonStyle(.text(color: .fg.warm.opacity(0.9)))
        .lineLimit(1)
        .onAppear {
            let extensions = selectedResults.compactMap(\.extension).uniqued
            commonScripts = scriptManager.commonScripts(for: extensions).sorted(by: \.lastPathComponent)
        }
        .onChange(of: selectedResults) {
            let extensions = selectedResults.compactMap(\.extension).uniqued
            commonScripts = scriptManager.commonScripts(for: extensions).sorted(by: \.lastPathComponent)
        }
        .alert(
            "Run \(confirmScript?.lastPathComponent.ns.deletingPathExtension ?? "script")?",
            isPresented: Binding(get: { confirmScript != nil }, set: { if !$0 { confirmScript = nil } })
        ) {
            Button("Run") {
                if let script = confirmScript {
                    scriptManager.run(script: script, args: selectedResults.map(\.string))
                    confirmScript = nil
                }
            }
            Button("Cancel", role: .cancel) {
                confirmScript = nil
            }
        } message: {
            Text("This will run on \(selectedResults.count) file\(selectedResults.count == 1 ? "" : "s")")
        }
    }

    @ViewBuilder
    var scriptList: some View {
        ForEach(commonScripts.filter { scriptManager.isEligible($0, forPaths: selectedResults.arr) }, id: \.path) { script in
            if let key = scriptManager.scriptShortcuts[script] {
                scriptButton(script, key: key)
            }
        }
    }

    func outputView(output: String?, error: String?, outputFile: FilePath?, errorFile: FilePath?) -> some View {
        VStack(spacing: 5) {
            HStack {
                Button(action: { showOutput = false }) {
                    Image(systemName: "xmark")
                        .font(.heavy(7))
                        .foregroundColor(.bg.warm)
                }
                .buttonStyle(FlatButton(color: .fg.warm.opacity(0.6), circle: true, horizontalPadding: 5, verticalPadding: 5))
                .padding(.top, 8).padding(.leading, 8)
                Spacer()
            }

            if let output, output.isNotEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("OUTPUT").font(.bold(10)).foregroundColor(.secondary)
                        Spacer()
                        if output.utf8.count >= 8192, let outputFile {
                            Button("Open in editor") { outputFile.edit() }
                                .font(.system(size: 10))
                        }
                    }.padding(.horizontal, 4)
                    ScriptOutputText(text: output)
                }
                .roundbg(radius: 12, color: .bg.primary.opacity(0.1))
                .padding(.bottom).padding(.horizontal, 25)
            }

            if let error, error.isNotEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("ERRORS").font(.bold(10)).foregroundColor(.secondary)
                        Spacer()
                        if error.utf8.count >= 8192, let errorFile {
                            Button("Open in editor") { errorFile.edit() }
                                .font(.system(size: 10))
                        }
                    }.padding(.horizontal, 4)
                    ScriptOutputText(text: error)
                }
                .roundbg(radius: 12, color: .bg.primary.opacity(0.1))
                .padding(.bottom).padding(.horizontal, 25)
            }

            if output == nil || output?.isEmpty == true, error == nil || error?.isEmpty == true {
                Text("No output").foregroundColor(.secondary).padding()
            }
        }.frame(width: 800, height: 500, alignment: .topLeading)
    }

    @State private var commonScripts: [URL] = []

    @State private var showOutput = false
    @State private var confirmScript: URL? = nil

    @State private var scriptManager = SM
    @State private var fuzzy = FUZZY
    @State private var isPresentingScriptPicker = false

    @ViewBuilder
    private var runningProcessButton: some View {
        HStack(spacing: 0) {
            if let script = scriptManager.lastScript {
                Button(action: {
                    if let process = scriptManager.process {
                        process.terminate()
                    } else {
                        scriptManager.clearLastProcess()
                    }
                }) {
                    Image(systemName: "xmark").font(.heavy(10))
                }
                .buttonStyle(.borderlessText(color: .fg.warm.opacity(0.8)))
                .help(scriptManager.process != nil ? "Terminate script" : "Clear process output")

                Button(action: showProcessOutput) {
                    HStack(spacing: 1) {
                        if scriptManager.process != nil {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.mini)
                                .padding(.trailing, 5)
                            Text(script.lastPathComponent.ns.deletingPathExtension)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        } else {
                            Image(systemName: "doc.text")
                                .font(.heavy(10))
                                .padding(.trailing, 5)
                            Text("Script output").fixedSize()
                        }
                    }
                }
                .buttonStyle(.text(color: .fg.warm.opacity(0.8)))
                .sheet(isPresented: $showOutput) {
                    if let outFile = scriptManager.lastOutputFile, let errFile = scriptManager.lastErrorFile {
                        let output = try? String(contentsOf: outFile.url).trimmed
                        let error = try? String(contentsOf: errFile.url).trimmed
                        outputView(output: output, error: error, outputFile: outFile, errorFile: errFile)
                    } else {
                        outputView(output: nil, error: "Script failed to start. No output was captured.", outputFile: nil, errorFile: nil)
                    }
                }
                .help("View script output and errors")
                .onChange(of: scriptManager.process) { old, new in
                    if new == nil, old != nil, scriptManager.scriptsWithOutput.contains(script) {
                        showProcessOutput()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var clopButton: some View {
        if fuzzy.clopIsAvailable {
            let clopCandidates = selectedResults.filter(\.exists).map(\.url).filter(\.memoz.canBeOptimisedByClop)
            if clopCandidates.isNotEmpty {
                let oKeyAvailable = !scriptManager.scriptShortcuts.values.contains("o")
                Button(action: {
                    guard ClopSDK.shared.waitForClopToBeAvailable(for: 5) else {
                        return
                    }
                    _ = try? ClopSDK.shared.optimise(
                        paths: clopCandidates.map(\.path),
                        aggressive: NSEvent.modifierFlags.contains(.option),
                        inTheBackground: true
                    )
                }) {
                    if oKeyAvailable {
                        Text("⌘⌃O").mono(10, weight: .bold).foregroundColor(.fg.warm.opacity(0.8)) + Text(" Optimise with Clop")
                    } else {
                        Text("Optimise with Clop")
                    }
                }
                .buttonStyle(.text(color: .fg.warm.opacity(0.8)))
                .if(oKeyAvailable) {
                    $0.keyboardShortcut("o", modifiers: [.command, .control])
                }
            }
        }

    }

    private var runThroughScriptButton: some View {
        Button("⌘X Execute script") {
            focused.wrappedValue = .executeScript
            isPresentingScriptPicker = true
        }
        .keyboardShortcut("x", modifiers: [.command])
        .disabled(focused.wrappedValue == .search)
        .help("Run the selected files through a script")
        .sheet(isPresented: $isPresentingScriptPicker) {
            ScriptPickerView(fileURLs: selectedResults.map(\.url))
                .font(.medium(13))
                .focused(focused, equals: .executeScript)
        }
    }

    private func scriptButton(_ script: URL, key: Character) -> some View {
        Button(action: {
            if scriptManager.scriptsWithConfirm.contains(script) {
                confirmScript = script
            } else {
                scriptManager.run(script: script, args: selectedResults.map(\.string))
            }
        }) {
            HStack(spacing: 0) {
                Text("\(key.uppercased())").mono(10, weight: .bold).foregroundColor(.fg.warm).roundbg(color: .bg.primary.opacity(0.2))
                Text(" \(script.lastPathComponent.ns.deletingPathExtension)")
            }
        }
    }

    private func showProcessOutput() {
        showOutput = true
    }

}

// MARK: - ScriptRowButton

private struct ScriptRowButton: View {
    let script: URL
    let scriptManager: ScriptManager
    let onRun: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onRun) {
            HStack {
                Image(nsImage: icon(for: script))
                VStack(alignment: .leading, spacing: 1) {
                    Text(script.lastPathComponent.ns.deletingPathExtension)
                    if let desc = scriptManager.scriptDescriptions[script] {
                        Text(desc).font(.system(size: 10)).foregroundColor(.secondary)
                    }
                }

                Spacer()

                if let shortcut = scriptManager.scriptShortcuts[script] {
                    Text(String(shortcut).uppercased()).monospaced().bold().foregroundColor(.secondary)
                }

                Button(action: { openInEditor(script) }) {
                    Image(systemName: "pencil")
                        .padding(4)
                        .background(editHovered ? Color.primary.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .foregroundStyle(editHovered ? .primary : .secondary)
                .onHover { editHovered = $0 }
                .ifLet(scriptManager.scriptShortcuts[script]) {
                    $0.keyboardShortcut(KeyEquivalent($1), modifiers: [.command, .shift])
                        .help("Edit script in \(Defaults[.editorApp].filePath?.stem ?? "TextEdit") (⌘⇧\(String($1))")
                }

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .padding(4)
                        .background(deleteHovered ? Color.red.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .foregroundStyle(deleteHovered ? .red : .red.opacity(0.5))
                .onHover { deleteHovered = $0 }
            }
            .hfill(.leading)
        }
        .buttonStyle(FlatButton(color: .bg.primary.opacity(0.4), textColor: .primary))
        .onHover { rowHovered = $0 }
    }

    @State private var rowHovered = false
    @State private var editHovered = false
    @State private var deleteHovered = false

}

func openInEditor(_ file: URL) {
    NSWorkspace.shared.open(
        [file],
        withApplicationAt: Defaults[.editorApp].fileURL ?? URL(fileURLWithPath: "/Applications/TextEdit.app"),
        configuration: NSWorkspace.OpenConfiguration()
    )

}

extension FilePath {
    func edit() {
        openInEditor(url)
    }
}

extension URL {
    var fileExists: Bool {
        filePath?.exists ?? false
    }
}

// MARK: - AddScriptView

struct AddScriptView: View {
    @Binding var name: String
    @Binding var selectedRunner: ScriptRunner?

    var body: some View {
        VStack {
            VStack {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        dismiss()
                        NSApp.deactivate()
                    }
                Picker("Script runner", selection: $selectedRunner) {
                    ForEach(ScriptRunner.allCases, id: \.self) { runner in
                        Text("\(runner.name) (\(runner.path))").tag(runner as ScriptRunner?)
                    }
                    Divider()
                    Text("Custom").tag(nil as ScriptRunner?)
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            .padding()
            HStack {
                Button {
                    cancel()
                } label: {
                    Label("Cancel", systemImage: "escape")
                }
                Button {
                    dismiss()
                    NSApp.deactivate()
                } label: {
                    Text("⌘S Save")
                }
                .keyboardShortcut("s")
            }
        }
        .onExitCommand {
            cancel()
        }
        .padding()
    }

    func cancel() {
        name = ""
        selectedRunner = nil
        dismiss()
    }

    @Environment(\.dismiss) private var dismiss
}

// MARK: - ScriptEditorSheet

/// Sidebar list of scripts + inline source editor. Mirrors `FilterEditorSheet`.
/// Presented standalone as a sheet, or embedded inside the Settings window's Scripts pane.
struct ScriptEditorSheet: View {
    @State private var scriptManager = SM
    @State private var selection: URL? = nil
    @State private var isShowingAddScript = false
    @State private var scriptName = ""
    @State private var selectedRunner: ScriptRunner? = .zsh
    @State private var deleteScript: URL? = nil
    @Environment(\.dismiss) var dismiss

    /// When true, renders without the sheet header/Done button and fills its container.
    var embedded = false

    var body: some View {
        if embedded {
            editorContent
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("Script Editor").font(.headline)
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

    private var scripts: [URL] {
        scriptManager.scriptURLs.sorted(by: \.lastPathComponent)
    }

    private var editorContent: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .sheet(isPresented: $isShowingAddScript, onDismiss: createNewScript) {
            AddScriptView(name: $scriptName, selectedRunner: $selectedRunner)
        }
        .alert(
            "Delete \(deleteScript?.lastPathComponent.ns.deletingPathExtension ?? "script")?",
            isPresented: Binding(get: { deleteScript != nil }, set: { if !$0 { deleteScript = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let script = deleteScript {
                    try? FileManager.default.removeItem(at: script)
                    if selection == script { selection = nil }
                    deleteScript = nil
                    scriptManager.fetchScripts()
                }
            }
            Button("Cancel", role: .cancel) { deleteScript = nil }
        } message: {
            Text("This will permanently delete the script file")
        }
        .onAppear {
            if selection == nil || !scripts.contains(selection!) { selection = scripts.first }
        }
        .onChange(of: scriptManager.scriptURLs) {
            if let sel = selection, !scriptManager.scriptURLs.contains(sel) { selection = scripts.first }
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        List(selection: $selection) {
            Section("Scripts") {
                ForEach(scripts, id: \.self) { script in
                    NavigationLink(value: script) {
                        Label {
                            Text(script.lastPathComponent.ns.deletingPathExtension)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        } icon: {
                            Image(nsImage: icon(for: script))
                        }
                    }
                }
                Button(action: { isShowingAddScript = true }) {
                    Label("New Script", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
        }
        .listStyle(.sidebar)
        .frame(width: 240)
        .foregroundStyle(.primary)
    }

    @ViewBuilder
    private var detail: some View {
        if let script = selection, scripts.contains(script) {
            ScriptSourceEditor(
                script: script,
                scriptManager: scriptManager,
                onDelete: { deleteScript = script },
                onRename: { selection = $0 }
            )
            .id(script)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "applescript")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text(scripts.isEmpty ? "No scripts yet" : "Select a script to edit")
                    .foregroundStyle(.secondary)
                if scripts.isEmpty {
                    Button("New Script") { isShowingAddScript = true }
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func createNewScript() {
        guard !scriptName.isEmpty else { return }
        let ext = selectedRunner?.fileExtension ?? "sh"
        let newScript = scriptsFolder / "\(scriptName.safeFilename).\(ext)"

        do {
            let runner = selectedRunner ?? .zsh
            try "\(runner.shebang)\n\(runner.template)".write(to: newScript.url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: newScript.string)
        } catch {
            log.error("Failed to create script: \(error.localizedDescription, privacy: .public)")
        }

        scriptName = ""
        selectedRunner = .zsh
        scriptManager.fetchScripts()
        selection = newScript.url
    }
}

// MARK: - ScriptSourceEditor

/// Editor for a single script. Owns the parsed params + code and the save logic, and hands each
/// off to a dedicated child view so typing in the code editor doesn't re-render the settings form
/// (and vice versa) — only the child whose binding actually changed re-evaluates.
private struct ScriptSourceEditor: View {
    let script: URL
    let scriptManager: ScriptManager
    let onDelete: () -> Void
    let onRename: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScriptCodeEditor(source: $source, language: SyntaxHighlighter.language(forExtension: script.pathExtension) ?? "bash")
                .id("code")
            Divider()
            ScriptParamsForm(params: $params)
                .id("params")
            Divider()
            actionBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: load)
        .onDisappear(perform: saveNow)
        // Params are discrete toggles/steppers, so persist them promptly; the code
        // editor keeps the long debounce so typing never writes on every keystroke.
        .onChange(of: params) { scheduleSave(after: Self.paramsSaveDebounce) }
        .onChange(of: source) { scheduleSave(after: Self.saveDebounce) }
    }

    // Generous debounce so typing in the code editor never writes on every keystroke; the rebuild
    // is deferred to fire time so each change just cancels and reschedules.
    private static let saveDebounce: TimeInterval = 2
    private static let paramsSaveDebounce: TimeInterval = 0.35

    @State private var params = ScriptParams()
    @State private var source = ""
    @State private var name = ""
    @State private var shebang: String? = nil
    @State private var runner: ScriptRunner = .zsh
    @State private var savedSnapshot = ""
    @State private var saveTask: DispatchWorkItem?

    @Default(.editorApp) private var editorApp

    // Description lives with the params but is edited in the header; empty clears it (so it isn't written).
    private var descriptionBinding: Binding<String> {
        Binding(get: { params.description ?? "" }, set: { params.description = $0.isEmpty ? nil : $0 })
    }

    private var currentName: String { script.lastPathComponent.ns.deletingPathExtension }

    private var renameTarget: URL {
        let stem = name.trimmingCharacters(in: .whitespaces).safeFilename
        let ext = script.pathExtension
        return (scriptsFolder / (ext.isEmpty ? stem : "\(stem).\(ext)")).url
    }

    // Enabled only for a non-empty, changed name that wouldn't clobber another script.
    private var canRename: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != currentName else { return false }
        return !FileManager.default.fileExists(atPath: renameTarget.path)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: icon(for: script))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: 240)
                        .onSubmit { if canRename { rename() } }
                    if canRename {
                        Button("Rename", action: rename)
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .help("Rename the script file on disk")
                    }
                }
                TextField("Description…", text: descriptionBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 320, alignment: .leading)
            }
            Spacer()
            if let shortcut = scriptManager.scriptShortcuts[script] {
                Text("⌘⌃\(String(shortcut).uppercased())")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button { openInEditor(script) } label: { Label("Open Externally", systemImage: "arrow.up.forward.app") }
                .help("Open in \(editorApp.filePath?.stem ?? "TextEdit")")
            Button { NSWorkspace.shared.activateFileViewerSelecting([script]) } label: { Label("Reveal", systemImage: "folder") }
                .help("Reveal in Finder")
            Spacer()
            Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
                .foregroundStyle(.red)
        }
        .controlSize(.small)
        .padding(12)
    }

    /// Writes only if the file still exists, so a delete-while-open isn't undone by a pending or
    /// on-disappear save, and re-applies the executable bit that the atomic (rename) write drops.
    /// Scripts must stay executable or `ScriptManager.fetchScripts` filters them out of the list.
    private static func write(_ text: String, to url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            log.error("Failed to save script \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // Renaming has to recreate the file (write current content to the new path, drop the old one)
    // and repoint the selection, so it's an explicit button rather than part of the debounced save.
    private func rename() {
        guard canRename else { return }
        let newURL = renameTarget
        saveTask?.cancel()
        let content = ScriptHeaderParser.rebuild(shebang: shebang, params: params, body: source, runner: runner)
        do {
            try content.write(to: newURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: newURL.path)
            try? FileManager.default.removeItem(at: script)
        } catch {
            log.error("Failed to rename script \(script.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        onRename(newURL)
        scriptManager.fetchScripts()
    }

    private func load() {
        let content = (try? String(contentsOf: script, encoding: .utf8)) ?? ""
        name = currentName
        shebang = ScriptHeaderParser.shebang(content)
        runner = ScriptRunner(fromShebang: shebang ?? "") ?? ScriptRunner(fromExtension: script.pathExtension) ?? .zsh
        params = ScriptHeaderParser.parse(content)
        source = ScriptHeaderParser.body(content)
        // Snapshot the normalized form so the load itself isn't treated as an edit and re-saved.
        savedSnapshot = ScriptHeaderParser.rebuild(shebang: shebang, params: params, body: source, runner: runner)
    }

    private func scheduleSave(after debounce: TimeInterval = saveDebounce) {
        saveTask?.cancel()
        saveTask = mainAsyncAfter(debounce) { saveNow() }
    }

    private func saveNow() {
        saveTask?.cancel()
        let content = ScriptHeaderParser.rebuild(shebang: shebang, params: params, body: source, runner: runner)
        guard content != savedSnapshot else { return }
        Self.write(content, to: script)
        // Track what's now on disk; otherwise reverting an edit (e.g. toggling a
        // param back off) matches the stale load-time snapshot and skips the write.
        savedSnapshot = content
    }

}

// MARK: - ScriptCodeEditor

/// Fixed-height syntax-highlighted editor. Isolated so each keystroke only re-renders this view,
/// not the settings form below it; the fixed height also keeps the text view managing its own scrolling.
private struct ScriptCodeEditor: View {
    @Binding var source: String

    var language: String?

    var body: some View {
        CodeEditorView(source: $source, language: language, fontSize: 12)
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - ScriptParamsForm

/// Grouped form of the behaviour params. Takes a binding so it only re-renders when `params`
/// changes — not on every keystroke in the code editor.
private struct ScriptParamsForm: View {
    @Binding var params: ScriptParams

    var body: some View {
        Form {
            detailsSection
            eligibilitySection
            behaviourSection
        }
        .formStyle(.grouped)
    }

    @State private var recording = false

    // Bridges the stored single-letter `key` to the SauceKey that DynamicKey records; Escape clears it.
    private var hotkeyBinding: Binding<SauceKey> {
        Binding(
            get: { params.key.flatMap { SauceKey(rawValue: $0.lowercased()) } ?? .escape },
            set: { params.key = $0 == .escape ? nil : $0.lowercasedChar }
        )
    }

    @ViewBuilder
    private var detailsSection: some View {
        Section {
            LabeledContent("Hotkey") {
                HStack(spacing: 4) {
                    Text("⌘⌃ +").font(.system(size: 11)).foregroundStyle(.secondary)
                    DynamicKey(key: hotkeyBinding, recording: $recording, allowedKeys: .ALPHANUMERIC_KEYS)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .frame(width: 28)
                }
            }
        } header: {
            Text("Hotkey")
        } footer: {
            Text("Press a key to override Cling's automatic ⌘⌃ shortcut, or Escape to clear the override.")
        }
    }

    @ViewBuilder
    private var eligibilitySection: some View {
        Section {
            Toggle("Show only on specific file types", isOn: enabled(\.extensions, fallback: ""))
            if params.extensions != nil {
                TextField("", text: text(\.extensions), prompt: Text("Space-separated dot-less extensions. e.g. jpg png pdf tar.gz"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }

            Toggle("Minimum selected files", isOn: enabled(\.minFiles, fallback: 1))
            if let n = params.minFiles {
                Stepper(value: int(\.minFiles), in: 1 ... 999) {
                    Text("At least \(n) file\(n == 1 ? "" : "s")")
                }
            }

            Toggle("Maximum selected files", isOn: enabled(\.maxFiles, fallback: 1))
            if let n = params.maxFiles {
                Stepper(value: int(\.maxFiles), in: 1 ... 999) {
                    Text("At most \(n) file\(n == 1 ? "" : "s")")
                }
            }
            Toggle("Files only (hide when folders are selected)", isOn: $params.filesOnly)
            Toggle("Folders only (hide when files are selected)", isOn: $params.dirsOnly)
        } header: {
            Text("Eligibility")
        } footer: {
            Text("Controls when this script shows up in the picker for the selected files.")
        }
    }

    @ViewBuilder
    private var behaviourSection: some View {
        Section("Behaviour") {
            Toggle("Show confirmation before running", isOn: $params.confirm)
            Toggle("Run once per file (sequential)", isOn: $params.sequential)
            Toggle("Show output when finished", isOn: $params.showOutput)
        }
    }

    // A toggle flips the optional param between nil (disabled) and a value; the field edits the value.
    private func enabled<V>(_ key: WritableKeyPath<ScriptParams, V?>, fallback: V) -> Binding<Bool> {
        Binding(
            get: { params[keyPath: key] != nil },
            set: { params[keyPath: key] = $0 ? (params[keyPath: key] ?? fallback) : nil }
        )
    }

    private func text(_ key: WritableKeyPath<ScriptParams, String?>) -> Binding<String> {
        Binding(get: { params[keyPath: key] ?? "" }, set: { params[keyPath: key] = $0 })
    }

    private func int(_ key: WritableKeyPath<ScriptParams, Int?>) -> Binding<Int> {
        Binding(get: { params[keyPath: key] ?? 1 }, set: { params[keyPath: key] = $0 })
    }

}

// MARK: - ScriptParams

/// Optional behaviour settings parsed from (and written back into) a script's comment header.
/// A `nil` String/Int or a `false` Bool means the setting is absent from the script.
struct ScriptParams: Equatable {
    var description: String? = nil
    var key: String? = nil
    var extensions: String? = nil
    var minFiles: Int? = nil
    var maxFiles: Int? = nil
    var filesOnly = false
    var dirsOnly = false
    var confirm = false
    var sequential = false
    var showOutput = false

    func commentLines(prefix c: String) -> [String] {
        var lines: [String] = []
        if let description, !description.isEmpty { lines.append("\(c) description: \(description)") }
        if let key, !key.isEmpty { lines.append("\(c) key: \(key)") }
        if let extensions, !extensions.isEmpty { lines.append("\(c) extensions: \(extensions)") }
        if let minFiles { lines.append("\(c) minFiles: \(minFiles)") }
        if let maxFiles { lines.append("\(c) maxFiles: \(maxFiles)") }
        if filesOnly { lines.append("\(c) filesOnly: true") }
        if dirsOnly { lines.append("\(c) dirsOnly: true") }
        if confirm { lines.append("\(c) confirm: true") }
        if sequential { lines.append("\(c) sequential: true") }
        if showOutput { lines.append("\(c) showOutput: true") }
        return lines
    }
}

// MARK: - ScriptHeaderParser

/// Splits a script into its managed behaviour header and the user's code, and rebuilds it on save.
/// Reuses `ScriptManager`'s regexes for parsing so the form and the runtime agree on what's set.
enum ScriptHeaderParser {
    static func shebang(_ content: String) -> String? {
        let first = String(content.prefix(while: { $0 != "\n" }))
        return first.hasPrefix("#!") ? first : nil
    }

    static func parse(_ content: String) -> ScriptParams {
        var p = ScriptParams()
        if let m = try? ScriptManager.DESCRIPTION_REGEX.firstMatch(in: content) {
            p.description = m.1.trimmingCharacters(in: .whitespaces)
        }
        if let m = try? ScriptManager.KEY_REGEX.firstMatch(in: content) {
            p.key = String(m.1).lowercased()
        }
        if let m = try? ScriptManager.EXTENSIONS_REGEX.firstMatch(in: content) {
            p.extensions = m.1.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let m = try? ScriptManager.MIN_FILES_REGEX.firstMatch(in: content), let n = Int(m.1) { p.minFiles = n }
        if let m = try? ScriptManager.MAX_FILES_REGEX.firstMatch(in: content), let n = Int(m.1) { p.maxFiles = n }
        p.filesOnly = content.contains(ScriptManager.FILES_ONLY_REGEX)
        p.dirsOnly = content.contains(ScriptManager.DIRS_ONLY_REGEX)
        p.confirm = content.contains(ScriptManager.CONFIRM_REGEX)
        p.sequential = content.contains(ScriptManager.SEQUENTIAL_REGEX)
        p.showOutput = content.contains(ScriptManager.SHOW_OUTPUT_REGEX)
        return p
    }

    /// The script with its shebang and managed header lines removed, blank runs collapsed.
    static func body(_ content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        if let first = lines.first, first.hasPrefix("#!") { lines.removeFirst() }
        var result: [String] = []
        var lastBlank = false
        for line in lines where !isManagedLine(line) {
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if blank, lastBlank { continue }
            result.append(line)
            lastBlank = blank
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func rebuild(shebang: String?, params: ScriptParams, body: String, runner: ScriptRunner) -> String {
        var out: [String] = [shebang ?? runner.shebang]
        let paramLines = params.commentLines(prefix: runner.commentPrefix)
        if !paramLines.isEmpty {
            out.append("")
            out.append(contentsOf: paramLines)
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            out.append("")
            out.append(trimmed)
        }
        return out.joined(separator: "\n") + "\n"
    }

    private static let paramLineRegex = try! Regex(
        #"^[^A-Za-z0-9\n]+(description|key|extensions|minFiles|maxFiles|filesOnly|dirsOnly|confirm|sequential|showOutput)\s*\[?\s*:"#
    ).ignoresCase()

    // Descriptive comments emitted by older templates, stripped so the code editor stays clean.
    private static let managedHelpPhrases: Set<String> = [
        "All settings below are optional. Remove the brackets around [:] to enable a setting.",
        "A short description shown in the script picker",
        "Only show this script for specific file types",
        "Require a specific number of selected files (e.g. for a diff script that needs exactly 2 files)",
        "Only show this script when all selected items are files (not folders)",
        "Only show this script when all selected items are folders",
        "Ask for confirmation before running (useful for scripts that delete or move files)",
        "Run the script once for each file instead of passing all files at once",
        "Show the output of the script after it finishes executing",
    ]

    private static func isManagedLine(_ line: String) -> Bool {
        if (try? paramLineRegex.firstMatch(in: line)) != nil { return true }
        let stripped = line.trimmingCharacters(in: CharacterSet(charactersIn: "#/-").union(.whitespaces))
        return managedHelpPhrases.contains(stripped)
    }
}

// MARK: - ScriptRunner

enum ScriptRunner: String, CaseIterable {
    case sh
    case zsh
    case fish
    case python3
    case ruby
    case perl
    case swift
    case osascript
    case node

    init?(fromShebang shebang: String) {
        let path = shebang.replacingOccurrences(of: "#!", with: "").replacingOccurrences(of: "/usr/bin/env ", with: "").trimmingCharacters(in: .whitespaces)
        guard let runner = ScriptRunner.allCases.first(where: { $0.path == path }) ?? ScriptRunner.allCases.first(where: { $0.path.contains(path) }) else {
            return nil
        }
        self = runner
    }

    init?(fromExtension ext: String) {
        guard let runner = ScriptRunner.allCases.first(where: { $0.fileExtension == ext }) else {
            return nil
        }
        self = runner
    }

    var fileExtension: String {
        switch self {
        case .sh: "sh"
        case .zsh: "zsh"
        case .fish: "fish"
        case .python3: "py"
        case .ruby: "rb"
        case .perl: "pl"
        case .swift: "swift"
        case .osascript: "scpt"
        case .node: "js"
        }
    }

    var shebang: String {
        "#!\(path)"
    }

    var utType: UTType? {
        if let utType = UTType(filenameExtension: fileExtension) {
            return utType
        }

        switch self {
        case .sh: return .shellScript
        case .zsh: return .shellScript
        case .fish: return .shellScript
        case .python3: return .pythonScript
        case .ruby: return .rubyScript
        case .perl: return .perlScript
        case .swift: return .swiftSource
        case .osascript: return .appleScript
        case .node: return .javaScript
        }
    }

    var name: String {
        switch self {
        case .sh: "Shell"
        case .zsh: "Zsh"
        case .fish: "Fish"
        case .python3: "Python 3"
        case .ruby: "Ruby"
        case .perl: "Perl"
        case .swift: "Swift"
        case .osascript: "AppleScript"
        case .node: "Node.js"
        }
    }

    var path: String {
        switch self {
        case .sh: "/bin/zsh"
        case .zsh: "/bin/zsh"
        case .fish: "/usr/local/bin/fish"
        case .python3: "/usr/bin/python3"
        case .ruby: "/usr/bin/ruby"
        case .perl: "/usr/bin/perl"
        case .swift: "/usr/bin/swift"
        case .osascript: "/usr/bin/osascript"
        case .node: "/usr/local/bin/node"
        }
    }

    var commentPrefix: String {
        switch self {
        case .swift, .node: "//"
        case .osascript: "--"
        default: "#"
        }
    }

    var argsHelp: String {
        let c = commentPrefix
        switch self {
        case .sh, .zsh:
            return """
            \(c) File paths are passed as arguments to the script
            \(c) The first file path is $1, the second is $2, and so on
            \(c) The number of arguments is stored in $#
            \(c) The arguments are stored in $@ as an array
            """
        case .fish:
            return """
            \(c) File paths are passed as arguments via $argv
            \(c) $argv[1] is the first file, $argv[2] is the second, and so on
            \(c) The number of arguments is (count $argv)
            """
        case .python3:
            return """
            \(c) File paths are passed as arguments via sys.argv
            \(c) sys.argv[1] is the first file, sys.argv[2] is the second, and so on
            """
        case .ruby:
            return """
            \(c) File paths are passed as arguments via ARGV
            \(c) ARGV[0] is the first file, ARGV[1] is the second, and so on
            """
        case .perl:
            return """
            \(c) File paths are passed as arguments via @ARGV
            \(c) $ARGV[0] is the first file, $ARGV[1] is the second, and so on
            """
        case .swift:
            return """
            \(c) File paths are passed as arguments via CommandLine.arguments
            \(c) CommandLine.arguments[1] is the first file (index 0 is the script path)
            """
        case .osascript:
            return """
            \(c) File paths are passed via "on run argv"
            \(c) Item 1 of argv is the first file, item 2 is the second, and so on
            """
        case .node:
            return """
            \(c) File paths are passed as arguments via process.argv
            \(c) process.argv[2] is the first file (index 0 is node, index 1 is the script path)
            """
        }
    }

    // Behaviour settings (description, extensions, confirm, …) are managed through the
    // Scripts editor form, which writes them into the comment header on save.
    var template: String {
        """

        \(argsHelp)

        """
    }
}

// MARK: - ScriptOutputText

/// Uses `Text` for small output, `NSTextView` wrapper for large output to stay responsive.
struct ScriptOutputText: View {
    let text: String

    var body: some View {
        if text.utf8.count < 8192 {
            ScrollView {
                Text(text)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .monospaced()
                    .textSelection(.enabled)
                    .fill(.topLeading)
            }
        } else {
            LargeTextView(text: text)
        }
    }
}

// MARK: - LargeTextView

struct LargeTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = NSTextView()

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        if let textView = scrollView.documentView as? NSTextView, textView.string != text {
            textView.string = text
        }
    }
}
