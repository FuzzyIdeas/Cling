import Defaults
import Foundation
import Lowtech
import System

let DEFAULT_SCRIPTS = [
    Bundle.main.url(forResource: "Copy to tmp", withExtension: "zsh")!.filePath!,
    Bundle.main.url(forResource: "List contents", withExtension: "zsh")!.filePath!,
    Bundle.main.url(forResource: "ZIP", withExtension: "zsh")!.filePath!,
    Bundle.main.url(forResource: "Print", withExtension: "zsh")!.filePath!,
    Bundle.main.url(forResource: "Diff", withExtension: "zsh")!.filePath!,
    Bundle.main.url(forResource: "Compare", withExtension: "zsh")!.filePath!,
    Bundle.main.url(forResource: "Disk usage", withExtension: "zsh")!.filePath!,
]
let scriptsFolder: FilePath =
    FileManager.default.urls(for: .applicationScriptsDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Cling", isDirectory: true).filePath ?? "~/.local/cling-scripts".filePath!
let defaultScriptsMarker = scriptsFolder / ".default-scripts-installed"
let SEVEN_ZIP = Bundle.main.url(forResource: "7zz", withExtension: nil)!.filePath!
let DUST = Bundle.main.url(forResource: "dust", withExtension: nil)!.filePath!
let TREE = Bundle.main.url(forResource: "tree", withExtension: nil)!.filePath!
let TREEDIFF = Bundle.main.url(forResource: "treediff", withExtension: nil)!.filePath!

@Observable
class ScriptManager {
    init() {
        asyncNow {
            self.loadShellEnv()
        }

        if !scriptsFolder.exists {
            scriptsFolder.mkdir(withIntermediateDirectories: true)
        }
        installDefaultScriptsIfNeeded()
        fetchScripts()
        startScriptsWatcher()
    }

    func installDefaultScriptsIfNeeded() {
        guard !defaultScriptsMarker.exists else { return }
        for script in DEFAULT_SCRIPTS {
            _ = try? script.copy(to: scriptsFolder)
        }
        FileManager.default.createFile(atPath: defaultScriptsMarker.string, contents: nil, attributes: nil)
        fetchScripts()
    }

    // reads the script
    // finds the line that starts with symbols, whitespace and then extensions: and returns the extensions
    // the line can start with any symbol like #, //, --, etc
    // the extensions can be separated by commas or spaces

    static let EXTENSIONS_REGEX: Regex<(Substring, Substring)> = try! Regex(#"^[^a-z0-9\n]+extensions:\s*([a-z0-9\-\., \t]*)"#).anchorsMatchLineEndings().ignoresCase()
    static let SHOW_OUTPUT_REGEX: Regex<(Substring, Substring)> = try! Regex(#"^[^a-z0-9\n]+showOutput:\s*(true|yes|1|on|enable)"#).anchorsMatchLineEndings().ignoresCase()
    static let MIN_FILES_REGEX: Regex<(Substring, Substring)> = try! Regex(#"^[^a-z0-9\n]+minFiles:\s*(\d+)"#).anchorsMatchLineEndings().ignoresCase()
    static let MAX_FILES_REGEX: Regex<(Substring, Substring)> = try! Regex(#"^[^a-z0-9\n]+maxFiles:\s*(\d+)"#).anchorsMatchLineEndings().ignoresCase()
    static let FILES_ONLY_REGEX: Regex<(Substring, Substring)> = try! Regex(#"^[^a-z0-9\n]+filesOnly:\s*(true|yes|1|on|enable)"#).anchorsMatchLineEndings().ignoresCase()
    static let DIRS_ONLY_REGEX: Regex<(Substring, Substring)> = try! Regex(#"^[^a-z0-9\n]+dirsOnly:\s*(true|yes|1|on|enable)"#).anchorsMatchLineEndings().ignoresCase()
    static let CONFIRM_REGEX: Regex<(Substring, Substring)> = try! Regex(#"^[^a-z0-9\n]+confirm:\s*(true|yes|1|on|enable)"#).anchorsMatchLineEndings().ignoresCase()
    static let SEQUENTIAL_REGEX: Regex<(Substring, Substring)> = try! Regex(#"^[^a-z0-9\n]+sequential:\s*(true|yes|1|on|enable)"#).anchorsMatchLineEndings().ignoresCase()
    static let DESCRIPTION_REGEX: Regex<(Substring, Substring)> = try! Regex(#"^[^a-z0-9\n]+description:\s*(.+)"#).anchorsMatchLineEndings().ignoresCase()

    var reservedShortcuts: Set<Character> = []
    var scriptShortcuts: [URL: Character] = [:]
    var scriptURLs: [URL] = []
    var scriptsByExtension: [String: [URL]] = [:]
    var scriptsWithOutput: Set<URL> = []
    var scriptMinFiles: [URL: Int] = [:]
    var scriptMaxFiles: [URL: Int] = [:]
    var scriptsFilesOnly: Set<URL> = []
    var scriptsDirsOnly: Set<URL> = []
    var scriptsWithConfirm: Set<URL> = []
    var scriptsSequential: Set<URL> = []
    var scriptDescriptions: [URL: String] = [:]
    var lastScript: URL?
    var lastOutputFile: FilePath?
    var lastErrorFile: FilePath?
    @ObservationIgnored var shellEnv: [String: String]? = nil

    var combinedOutputFile: FilePath? { createCombinedOutputFile() }

    var process: Process? {
        didSet {
            guard let process else {
                return
            }
            lastOutputFile = process.stdoutFilePath?.existingFilePath
            lastErrorFile = process.stderrFilePath?.existingFilePath
            process.terminationHandler = { [self] process in
                mainActor {
                    log.verbose("Script \(self.lastScript?.lastPathComponent ?? "unknown") terminated with status \(process.terminationStatus)")
                    self.process = nil
                    self.clearLastProcessTask = mainAsyncAfter(30) {
                        self.clearLastProcess()
                    }
                }
            }
        }
    }

    func clearLastProcess() {
        process = nil
        lastScript = nil
        lastOutputFile = nil
        lastErrorFile = nil
    }

    func createCombinedOutputFile() -> FilePath? {
        guard let output = lastOutputFile, let error = lastErrorFile else {
            return nil
        }
        let combined = output.withExtension("combined")
        _ = try? output.copy(to: combined)
        if let handle = try? FileHandle(forUpdating: combined.url) {
            handle.seekToEndOfFile()
            handle.write("\n\n--------\n\nSTDERR:\n\n".data(using: .utf8)!)
            try? handle.write(Data(contentsOf: error.url))
            handle.closeFile()
        }
        return combined
    }

    func getScriptExtensions(_ script: URL, contents: String) {
        guard let match = try? Self.EXTENSIONS_REGEX.firstMatch(in: contents) else {
            scriptsByExtension["ALL"] = (scriptsByExtension["ALL"] ?? []) + [script]
            return
        }
        let extensions = match.1
            .split(separator: ",").flatMap { $0.split(separator: " ") }
            .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)) }

        for ext in extensions {
            scriptsByExtension[String(ext)] = (scriptsByExtension[String(ext)] ?? []) + [script]
        }
    }

    func isEligible(_ script: URL, forPaths paths: [FilePath]) -> Bool {
        let count = paths.count
        if let min = scriptMinFiles[script], count < min { return false }
        if let max = scriptMaxFiles[script], count > max { return false }
        if scriptsFilesOnly.contains(script), paths.contains(where: \.isDir) { return false }
        if scriptsDirsOnly.contains(script), paths.contains(where: { !$0.isDir }) { return false }
        return true
    }

    func run(script: URL, args: [String]) {
        guard script.fileExists else {
            log.error("Script not found: \(script)")
            return
        }
        lastScript = script
        var env = shellEnv ?? [:]
        env["CLING_SEVEN_ZIP"] = SEVEN_ZIP.string
        env["CLING_DUST"] = DUST.string
        env["CLING_TREE"] = TREE.string
        env["CLING_TREEDIFF"] = TREEDIFF.string

        if scriptsSequential.contains(script) {
            runSequential(script: script, args: args, env: env)
        } else {
            process = shellProc(script.path, args: args, env: env)
        }
    }

    func commonScripts(for exts: [String]) -> [URL] {
        let scriptSets = exts.compactMap { scriptsByExtension[$0]?.set }
        guard let first = scriptSets.first else {
            return scriptsByExtension["ALL"] ?? []
        }

        return scriptSets.dropFirst().reduce(first) { $0.intersection($1) }.union(scriptsByExtension["ALL"] ?? []).arr
    }

    func fetchScripts() {
        do {
            // Fetch only executable files
            let files = try FileManager.default.contentsOfDirectory(at: scriptsFolder.url, includingPropertiesForKeys: [.isExecutableKey], options: .skipsHiddenFiles)
            scriptURLs = files.filter {
                (try? $0.resourceValues(forKeys: [.isExecutableKey]).isExecutable) ?? false
            }

            scriptsByExtension = [:]
            scriptsWithOutput = []
            scriptMinFiles = [:]
            scriptMaxFiles = [:]
            scriptsFilesOnly = []
            scriptsDirsOnly = []
            scriptsWithConfirm = []
            scriptsSequential = []
            scriptDescriptions = [:]
            for script in scriptURLs {
                guard let scriptContents = try? String(contentsOf: script) else {
                    continue
                }
                getScriptExtensions(script, contents: scriptContents)
                if scriptContents.contains(Self.SHOW_OUTPUT_REGEX) {
                    scriptsWithOutput.insert(script)
                }
                if let match = try? Self.MIN_FILES_REGEX.firstMatch(in: scriptContents), let n = Int(match.1) {
                    scriptMinFiles[script] = n
                }
                if let match = try? Self.MAX_FILES_REGEX.firstMatch(in: scriptContents), let n = Int(match.1) {
                    scriptMaxFiles[script] = n
                }
                if scriptContents.contains(Self.FILES_ONLY_REGEX) {
                    scriptsFilesOnly.insert(script)
                }
                if scriptContents.contains(Self.DIRS_ONLY_REGEX) {
                    scriptsDirsOnly.insert(script)
                }
                if scriptContents.contains(Self.CONFIRM_REGEX) {
                    scriptsWithConfirm.insert(script)
                }
                if scriptContents.contains(Self.SEQUENTIAL_REGEX) {
                    scriptsSequential.insert(script)
                }
                if let match = try? Self.DESCRIPTION_REGEX.firstMatch(in: scriptContents) {
                    scriptDescriptions[script] = match.1.trimmingCharacters(in: .whitespaces)
                }
            }

            scriptShortcuts = computeShortcuts(for: scriptURLs, reserved: reservedShortcuts)
        } catch {
            scriptURLs = []
            scriptShortcuts = [:]
            log.error("Failed to fetch scripts: \(error)")
        }
    }

    func startScriptsWatcher() {
        do {
            try LowtechFSEvents.startWatching(paths: [scriptsFolder.string], for: ObjectIdentifier(self), latency: 3) { event in
                mainActor { [self] in
                    guard let flags = event.flag,
                          flags.hasElements(from: [
                              .itemCreated, .itemRemoved, .itemRenamed, .itemModified, .itemChangeOwner,
                          ])
                    else {
                        log.verbose("Ignoring script event \(event)")
                        return
                    }
                    log.verbose("Handling script event \(event)")
                    fetchScripts()
                }
            }
        } catch {
            log.error("Failed to watch scripts folder \(scriptsFolder.shellString): \(error)")
        }
    }

    @ObservationIgnored private var clearLastProcessTask: DispatchWorkItem? {
        didSet {
            oldValue?.cancel()
        }
    }

    private func runSequential(script: URL, args: [String], env: [String: String]) {
        var remaining = args
        func runNext() {
            guard !remaining.isEmpty else {
                return
            }
            let arg = remaining.removeFirst()
            process = shellProc(script.path, args: [arg], env: env)
            if remaining.isNotEmpty {
                // Override the terminationHandler set by didSet to chain the next file
                process?.terminationHandler = { _ in
                    mainActor {
                        runNext()
                    }
                }
            }
        }
        runNext()
    }

    private func loadShellEnv() {
        guard let userShell = ProcessInfo.processInfo.environment["SHELL"] else {
            log.error("SHELL environment variable not found")
            return
        }
        guard let envOutput = shell(userShell, args: ["-l", "-c", "/usr/bin/printenv"]).o, envOutput.isNotEmpty else {
            log.error("Failed to get environment variables from shell")
            return
        }
        let env = envOutput.split(separator: "\n").reduce(into: [String: String]()) { dict, line in
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                dict[String(parts[0])] = String(parts[1])
            }
        }

        mainAsync {
            self.shellEnv = env
        }
    }
}

let SM = ScriptManager()
