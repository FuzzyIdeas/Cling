import ClopSDK
import Defaults
import Lowtech
import SwiftUI
import System
import UniformTypeIdentifiers

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
            log.error("Failed to create script: \(error.localizedDescription)")
        }

        scriptName = ""
        selectedRunner = nil
        scriptManager.fetchScripts() // Update scripts and shortcuts
    }
}

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
                        if output.utf8.count >= 8_192, let outputFile {
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
                        if error.utf8.count >= 8_192, let errorFile {
                            Button("Open in editor") { errorFile.edit() }
                                .font(.system(size: 10))
                        }
                    }.padding(.horizontal, 4)
                    ScriptOutputText(text: error)
                }
                .roundbg(radius: 12, color: .bg.primary.opacity(0.1))
                .padding(.bottom).padding(.horizontal, 25)
            }

            if (output == nil || output?.isEmpty == true) && (error == nil || error?.isEmpty == true) {
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

    var template: String {
        let c = commentPrefix
        return """

        \(argsHelp)

        \(c) All settings below are optional. Remove the brackets around [:] to enable a setting.

        \(c) A short description shown in the script picker
        \(c) description[:]  My script description

        \(c) Only show this script for specific file types
        \(c) extensions[:]  jpg png pdf

        \(c) Require a specific number of selected files (e.g. for a diff script that needs exactly 2 files)
        \(c) minFiles[:]  2
        \(c) maxFiles[:]  2

        \(c) Only show this script when all selected items are files (not folders)
        \(c) filesOnly[:]  true
        \(c) Only show this script when all selected items are folders
        \(c) dirsOnly[:]  true

        \(c) Ask for confirmation before running (useful for scripts that delete or move files)
        \(c) confirm[:]  true

        \(c) Run the script once for each file instead of passing all files at once
        \(c) sequential[:]  true

        \(c) Show the output of the script after it finishes executing
        \(c) showOutput[:]  true

        """
    }
}

/// Uses `Text` for small output, `NSTextView` wrapper for large output to stay responsive.
struct ScriptOutputText: View {
    let text: String

    var body: some View {
        if text.utf8.count < 8_192 {
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
