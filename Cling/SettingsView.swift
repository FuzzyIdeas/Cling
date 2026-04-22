import Defaults
import LaunchAtLogin
import Lowtech
import LowtechIndie
import LowtechPro
import SwiftUI

extension Binding<Int> {
    var d: Binding<Double> {
        .init(
            get: { Double(wrappedValue) },
            set: { wrappedValue = Int($0) }
        )
    }
}

let envState = EnvState()

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, apps, search, exclusions, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .apps: "Apps"
        case .search: "Search"
        case .exclusions: "Exclusions"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .apps: "app.badge"
        case .search: "magnifyingglass"
        case .exclusions: "eye.slash"
        case .about: "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .apps: .blue
        case .search: .green
        case .exclusions: .red
        case .about: .purple
        }
    }
}

struct SettingsView: View {
    @State private var selection: SettingsCategory = .general
    @EnvironmentObject var env: EnvState

    var body: some View {
        NavigationSplitView {
            List(SettingsCategory.allCases, selection: $selection) { category in
                NavigationLink(value: category) {
                    Label {
                        Text(category.title)
                    } icon: {
                        Image(systemName: category.symbol)
                            .foregroundStyle(.white)
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 20, height: 20)
                            .background(category.tint.gradient, in: .rect(cornerRadius: 5))
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detailView
                .navigationTitle(selection.title)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 780, minHeight: 580)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .general: GeneralSettingsPane().environmentObject(env)
        case .apps: AppsSettingsPane()
        case .search: SearchSettingsPane()
        case .exclusions: ExclusionsSettingsPane()
        case .about: AboutSettingsPane()
        }
    }
}

// MARK: - Row helpers

private struct SettingRow<Label: View, Control: View>: View {
    init(
        title: String,
        detail: String? = nil,
        @ViewBuilder label: @escaping () -> Label = { EmptyView() },
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.title = title
        self.detail = detail
        self.label = label
        self.control = control
    }

    let title: String
    let detail: String?
    @ViewBuilder var label: () -> Label
    @ViewBuilder var control: () -> Control

    var body: some View {
        LabeledContent {
            control()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                if Label.self == EmptyView.self {
                    Text(title)
                } else {
                    label()
                }
                if let detail {
                    Text(LocalizedStringKey(detail))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct DescriptiveToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
            Text(detail)
        }
    }
}

// MARK: - General Pane

private struct GeneralSettingsPane: View {
    @Default(.showWindowAtLaunch) private var showWindowAtLaunch
    @Default(.showDockIcon) private var showDockIcon
    @Default(.keepWindowOpenWhenDefocused) private var keepWindowOpenWhenDefocused
    @Default(.instantMode) private var instantMode
    @Default(.windowAppearance) private var windowAppearance
    @Default(.enableGlobalHotkey) private var enableGlobalHotkey
    @Default(.showAppKey) private var showAppKey
    @Default(.triggerKeys) private var triggerKeys
    @EnvironmentObject var env: EnvState

    private var windowMode: Binding<WindowMode> {
        Binding(
            get: { showDockIcon ? .desktopApp : .utility },
            set: { mode in
                switch mode {
                case .utility:
                    showDockIcon = false
                    keepWindowOpenWhenDefocused = false
                case .desktopApp:
                    showDockIcon = true
                    keepWindowOpenWhenDefocused = true
                }
                NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
                NSApp.activate(ignoringOtherApps: true)
                AppDelegate.shared?.keepSettingsFrontUntil = .now + 2
            }
        )
    }

    var body: some View {
        Form {
            Section {
                LaunchAtLogin.Toggle()
            }

            Section("Window") {
                SettingRow(
                    title: "Window style",
                    detail: "Choose the window background appearance."
                ) {
                    Picker("", selection: $windowAppearance) {
                        ForEach(WindowAppearance.allCases.filter(\.available), id: \.self) { appearance in
                            Text(appearance.rawValue).tag(appearance)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                SettingRow(
                    title: "Window mode",
                    detail: "Utility: no Dock icon, hides on defocus. Desktop App: regular app window with dock icon."
                ) {
                    Picker("", selection: windowMode) {
                        ForEach(WindowMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                DescriptiveToggle(
                    title: "Show Dock icon",
                    detail: "Show Cling in the Dock as a regular app.",
                    isOn: $showDockIcon
                )
                .onChange(of: showDockIcon) {
                    NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
                    NSApp.activate(ignoringOtherApps: true)
                    AppDelegate.shared?.keepSettingsFrontUntil = .now + 2
                }

                DescriptiveToggle(
                    title: "Keep window open when app is in background",
                    detail: "Don't close the window when clicking outside the app.",
                    isOn: $keepWindowOpenWhenDefocused
                )

                DescriptiveToggle(
                    title: "Show window at launch",
                    detail: "Show the main window when Cling is first launched.",
                    isOn: $showWindowAtLaunch
                )

                DescriptiveToggle(
                    title: "Instant mode",
                    detail: "Hide the window instead of closing it, so the next hotkey summon is instant.",
                    isOn: $instantMode
                )
            }

            Section("Global Hotkey") {
                DescriptiveToggle(
                    title: "Enable global hotkey",
                    detail: "Summon Cling from anywhere with a keyboard shortcut.",
                    isOn: $enableGlobalHotkey
                )

                SettingRow(
                    title: "Hotkey",
                    detail: "Press the key combination to open Cling."
                ) {
                    HStack(spacing: 6) {
                        DirectionalModifierView(triggerKeys: $triggerKeys)
                            .disabled(!enableGlobalHotkey)
                        Text("+").heavy(12)
                        DynamicKey(key: $showAppKey, recording: $env.recording, allowedKeys: .ALL_KEYS)
                    }
                    .disabled(!enableGlobalHotkey)
                    .opacity(enableGlobalHotkey ? 1 : 0.5)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Apps Pane

private struct AppsSettingsPane: View {
    var body: some View {
        Form {
            Section("Default Apps") {
                SettingRow(
                    title: "Text editor",
                    detail: "Used for editing text files."
                ) {
                    Button(editorApp.filePath?.stem ?? "TextEdit") {
                        selectApp(type: "Text Editor") { editorApp = $0.path }
                    }
                    .truncationMode(.middle)
                }

                SettingRow(
                    title: "Terminal",
                    detail: "Used for running shell commands and opening folders."
                ) {
                    Button(terminalApp.filePath?.stem ?? "Terminal") {
                        selectApp(type: "Terminal") { terminalApp = $0.path }
                    }
                    .truncationMode(.middle)
                }

                SettingRow(
                    title: "Shelf app",
                    detail: "Used for shelving files with ⌘F (e.g. Yoink, Dropover)."
                ) {
                    Button(shelfApp.filePath?.stem ?? "None") {
                        selectApp(type: "Shelf") { shelfApp = $0.path }
                    }
                    .truncationMode(.middle)
                }
            }

            Section("Paths") {
                DescriptiveToggle(
                    title: "Use `~/` (tilde) in copied paths",
                    detail: "Replace `/Users/\(NSUserName())/` with `~/` when copying or exporting paths.",
                    isOn: $copyPathsWithTilde
                )
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    @Default(.editorApp) private var editorApp
    @Default(.terminalApp) private var terminalApp
    @Default(.shelfApp) private var shelfApp
    @Default(.copyPathsWithTilde) private var copyPathsWithTilde

    private func selectApp(type: String, onCompletion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Select \(type) App"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = "/Applications".fileURL

        if panel.runModal() == .OK, let url = panel.url {
            onCompletion(url)
        }
    }

}

// MARK: - Search Pane

private struct SearchSettingsPane: View {
    @Default(.maxResultsCount) private var maxResultsCount
    @Default(.defaultResultsMode) private var defaultResultsMode
    @Default(.searchScopes) private var searchScopes
    @State private var fuzzy = FUZZY
    @State private var showCLIAlert = false
    @State private var showCLIPathAlert = false
    @State private var cliInstallMessage = ""
    @State private var cliInstallSuccess = false

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Search Scopes")
                        Text("Choose which locations Cling indexes for search.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if fuzzy.backgroundIndexing || fuzzy.indexing {
                        Button("Cancel All") { fuzzy.cancelAllIndexing() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    } else {
                        Button("Reindex All") { fuzzy.refresh(pauseSearch: false) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }

                scopeRow(.home, label: "Home", detail: "User home directory (`~`) excluding `~/Library`")
                scopeRow(.applications, label: "Applications", detail: "`/Applications`, `/System/Applications`")
                scopeRow(.library, label: "Library", detail: "User library directory (`~/Library`)")
                proScopeRow(.system, label: "System", detail: "`/System`")
                proScopeRow(.root, label: "Root", detail: "`/usr`, `/bin`, `/sbin`, `/opt`, `/etc`, `/Library`, `/var`, `/private`")
            }

            Section("External Volumes") {
                VolumeListView().disabled(!proactive)
            }

            Section("Results") {
                SettingRow(
                    title: "Max results",
                    detail: "Maximum number of results to show in the search results."
                ) {
                    Picker("", selection: $maxResultsCount) {
                        Text("100").tag(100)
                        Text("500").tag(500)
                        if proactive {
                            Text("1000").tag(1000)
                            Text("2000").tag(2000)
                            Text("5000").tag(5000)
                            Text("10000").tag(10000)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                SettingRow(
                    title: "Default results",
                    detail: "What to show when no query or filter is active."
                ) {
                    HStack(spacing: 6) {
                        if defaultResultsMode == .runHistory {
                            Button("Reset") {
                                RH.clearAll()
                                FUZZY.updateDefaultResults()
                            }
                            .controlSize(.small)
                        }
                        Picker("", selection: $defaultResultsMode) {
                            ForEach(DefaultResultsMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }

            Section("Command Line Tool") {
                SettingRow(
                    title: "Command Line Tool",
                    detail: "Installs `cling` to `~/.local/bin/` for searching from the terminal."
                ) {
                    Button(CLING_CLI_LINK.exists ? "Reinstall" : "Install") {
                        cliInstallMessage = ShellIntegration.installCLI()
                        cliInstallSuccess = CLING_CLI_LINK.exists
                        if cliInstallSuccess, ShellIntegration.needsPathSetup {
                            showCLIPathAlert = true
                        } else {
                            showCLIAlert = true
                        }
                    }
                    .truncationMode(.middle)
                }

                if CLING_CLI_LINK.exists {
                    Text("Installed at \(CLING_CLI_LINK.shellString)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .alert(
            cliInstallSuccess ? "CLI Installed" : "Installation Failed",
            isPresented: $showCLIAlert,
            actions: {}
        ) {
            Text(cliInstallMessage)
        }
        .alert("Add to PATH?", isPresented: $showCLIPathAlert) {
            Button("Add Automatically") {
                ShellIntegration.addPathToShellConfigs()
                cliInstallMessage = "\(cliInstallMessage)\n\nPATH updated. Restart your shell to apply."
                showCLIAlert = true
            }
            Button("Copy to Clipboard") {
                ShellIntegration.copyPathExportToClipboard()
                cliInstallMessage = "\(cliInstallMessage)\n\nPATH export command copied to clipboard. Paste it into your shell config."
                showCLIAlert = true
            }
            Button("Skip", role: .cancel) {
                showCLIAlert = true
            }
        } message: {
            Text("\(cliInstallMessage)\n\n~/.local/bin is not in your shell PATH. Add it automatically to your shell config files?")
        }
    }

    private func scopeRow(_ scope: SearchScope, label: String, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Toggle(isOn: scope.binding) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                    Text(detail).font(.callout).foregroundColor(.secondary)
                }
            }
            Spacer()
            reindexButton(for: scope)
        }
    }

    private func proScopeRow(_ scope: SearchScope, label: String, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Toggle(isOn: scope.binding) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) { Text(label); ProBadge() }
                    Text(detail).font(.callout).foregroundColor(.secondary)
                }
            }
            .disabled(!proactive)
            Spacer()
            reindexButton(for: scope)
        }
    }

    @ViewBuilder
    private func reindexButton(for scope: SearchScope) -> some View {
        if !fuzzy.backgroundIndexing, searchScopes.contains(scope) {
            Button("Reindex") {
                fuzzy.refresh(pauseSearch: false, scopes: [scope])
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Reindex \(scope.label)")
        }
    }
}

// MARK: - Exclusions Pane

private struct ExclusionsSettingsPane: View {
    @Default(.blockedPrefixes) private var blockedPrefixes
    @Default(.blockedContains) private var blockedContains
    @State private var fuzzy = FUZZY
    @State private var showHelp = false
    @State private var fsignoreContent: String = (try? String(contentsOf: fsignore.url, encoding: .utf8)) ?? ""
    @State private var fsignoreSaveTask: DispatchWorkItem?
    @Default(.editorApp) private var editorApp

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                homeIgnoreSection
                blocklistSection
                volumeIgnoreSection
            }
            .padding()
        }
    }

    private var homeIgnoreSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Home Ignore File").font(.system(size: 12, weight: .semibold))
                        Text("Uses gitignore syntax for excluding files from the index.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: { showHelp.toggle() }) {
                        Image(systemName: "questionmark.circle").foregroundColor(.secondary)
                    }
                    .sheet(isPresented: $showHelp) {
                        VStack(spacing: 5) {
                            HStack {
                                Button(action: { showHelp = false }) {
                                    Image(systemName: "xmark")
                                        .font(.heavy(7))
                                        .foregroundColor(.bg.warm)
                                }
                                .buttonStyle(FlatButton(color: .fg.warm.opacity(0.6), circle: true, horizontalPadding: 5, verticalPadding: 5))
                                .padding(.top, 8).padding(.leading, 8)
                                Spacer()
                            }
                            IgnoreHelpText().padding()
                        }
                        .frame(width: 500)
                    }
                    .buttonStyle(.borderlessText)
                }

                TextEditor(text: $fsignoreContent)
                    .font(.system(size: 11, design: .monospaced))
                    .contentMargins(6)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 0.5))
                    .onChange(of: fsignoreContent) {
                        fsignoreSaveTask?.cancel()
                        fsignoreSaveTask = DispatchWorkItem { [fsignoreContent] in
                            FUZZY.fsignoreWatchSuppressedUntil = CFAbsoluteTimeGetCurrent() + 5
                            try? fsignoreContent.write(to: fsignore.url, atomically: true, encoding: .utf8)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: fsignoreSaveTask!)
                    }

                HStack {
                    Button("Apply & Reindex") {
                        fsignoreSaveTask?.cancel()
                        FUZZY.fsignoreWatchSuppressedUntil = CFAbsoluteTimeGetCurrent() + 5
                        try? fsignoreContent.write(to: fsignore.url, atomically: true, encoding: .utf8)
                        FUZZY.refresh(pauseSearch: false, scopes: [.home, .library])
                    }
                    .controlSize(.small)
                    .disabled(fuzzy.backgroundIndexing)
                    .help("Save the ignore file and reindex Home and Library scopes")
                    Spacer()
                    Button("Open in external editor") {
                        NSWorkspace.shared.open([fsignore.url], withApplicationAt: editorApp.fileURL ?? "/Applications/TextEdit.app".fileURL!, configuration: .init(), completionHandler: { _, _ in })
                    }
                    .controlSize(.small)
                    .truncationMode(.middle)
                }
            }
        }
        .groupBoxStyle(SettingsCardGroupBoxStyle())
    }

    private var blocklistSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Global Blocklist").font(.system(size: 12, weight: .semibold))
                    Text("Applied on all scopes (including root and live index) before the home ignore file, using fast byte matching. One pattern per line. Lines starting with `#` are ignored.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Prefix matching").font(.system(size: 11, weight: .semibold))
                    Text("Blocks paths that start with any of these strings.").font(.system(size: 10)).foregroundStyle(.secondary)
                    TextEditor(text: $blockedPrefixes)
                        .font(.system(size: 11, design: .monospaced))
                        .contentMargins(6)
                        .frame(height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Contains matching").font(.system(size: 11, weight: .semibold))
                    Text("Blocks paths containing any of these strings anywhere.").font(.system(size: 10)).foregroundStyle(.secondary)
                    TextEditor(text: $blockedContains)
                        .font(.system(size: 11, design: .monospaced))
                        .contentMargins(6)
                        .frame(height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                }

                Button("Apply & Reindex") {
                    PathBlocklist.shared.rebuild()
                    FUZZY.refresh(pauseSearch: false)
                }
                .controlSize(.small)
                .disabled(fuzzy.backgroundIndexing)
                .help("Rebuild the blocklist and trigger a full reindex")
            }
        }
        .groupBoxStyle(SettingsCardGroupBoxStyle())
    }

    private var volumeIgnoreSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Volume Ignore Files").font(.system(size: 12, weight: .semibold))
                    if fuzzy.externalVolumes.isEmpty {
                        Text("No external volumes connected.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Each volume can have its own `.fsignore` file using gitignore syntax. Paths excluded via the context menu are written here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if !fuzzy.externalVolumes.isEmpty {
                    ForEach(fuzzy.externalVolumes, id: \.string) { volume in
                        VolumeIgnoreEditor(volume: volume)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .groupBoxStyle(SettingsCardGroupBoxStyle())
    }
}

// MARK: - About Pane

private struct AboutSettingsPane: View {
    @ObservedObject var updateManager = UM
    @Default(.checkForUpdates) private var checkForUpdates
    @Default(.updateCheckInterval) private var updateCheckInterval
    @State private var scoringJSON: String = ScoringConfig.load().toJSON()

    var body: some View {
        Form {
            if let updater = updateManager.updater {
                Section("Updates") {
                    SettingRow(
                        title: "Check interval",
                        detail: "How often Cling checks for new versions."
                    ) {
                        Picker("", selection: $updateCheckInterval) {
                            Text("Daily").tag(UpdateCheckInterval.daily.rawValue)
                            Text("Every 3 days").tag(UpdateCheckInterval.everyThreeDays.rawValue)
                            Text("Weekly").tag(UpdateCheckInterval.weekly.rawValue)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                    }

                    DescriptiveToggle(
                        title: "Automatically check for updates",
                        detail: "Download and install updates in the background.",
                        isOn: $checkForUpdates
                    )

                    HStack {
                        Text("v\(Bundle.main.version)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        GentleUpdateView(updater: updater)
                    }
                }
            }

            if let pro = PM.pro {
                Section("Pro License") {
                    LicenseView(pro: pro)
                    #if DEBUG
                        HStack {
                            Button("Reset Trial") { AppDelegate.shared?.resetTrial() }
                            Button("Expire Trial") { AppDelegate.shared?.expireTrial() }
                        }
                    #endif
                }
            }

            #if DEBUG
                Section("Scoring Config (Debug)") {
                    TextEditor(text: $scoringJSON)
                        .font(.system(size: 11, design: .monospaced))
                        .contentMargins(6)
                        .frame(height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 0.5))
                    HStack {
                        Button("Apply") {
                            if let config = ScoringConfig.fromJSON(scoringJSON) {
                                config.save()
                                reloadScoringConfig()
                            }
                        }
                        Button("Reset to Defaults") {
                            ScoringConfig.default.save()
                            reloadScoringConfig()
                            scoringJSON = ScoringConfig.default.toJSON()
                        }
                        Spacer()
                        if ScoringConfig.fromJSON(scoringJSON) == nil {
                            Text("Invalid JSON").foregroundColor(.red).font(.system(size: 11))
                        }
                    }
                }
            #endif
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Helpers (unchanged)

struct VolumeIgnoreEditor: View {
    init(volume: FilePath) {
        self.volume = volume
        _content = State(initialValue: (try? String(contentsOf: (volume / ".fsignore").url, encoding: .utf8)) ?? "")
    }

    let volume: FilePath

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "externaldrive")
                Text(volume.name.string).font(.system(size: 12, weight: .semibold))
                Text(volume.shellString).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
            }

            TextEditor(text: $content)
                .font(.system(size: 11, design: .monospaced))
                .contentMargins(6)
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 0.5))
                .onChange(of: content) {
                    saveTask?.cancel()
                    saveTask = DispatchWorkItem { [content] in
                        try? content.write(to: fsignorePath.url, atomically: true, encoding: .utf8)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: saveTask!)
                }

            HStack {
                Button("Apply & Reindex") {
                    saveTask?.cancel()
                    try? content.write(to: fsignorePath.url, atomically: true, encoding: .utf8)
                    FUZZY.indexVolume(volume)
                }
                .controlSize(.small)
                .disabled(FUZZY.volumesIndexing.contains(volume))
                .help("Save the ignore file and reindex \(volume.name.string)")
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    @State private var content = ""
    @State private var saveTask: DispatchWorkItem?

    private var fsignorePath: FilePath { volume / ".fsignore" }

}

struct IgnoreHelpText: View {
    var body: some View {
        ScrollView {
            Text("""
            **Pattern syntax:**

            1. **Wildcards**: You can use asterisks (`*`) as wildcards to match multiple characters or directories at any level. For example, `*.jpg` will match all files with the .jpg extension, such as `image.jpg` or `photo.jpg`. Similarly, `*.pdf` will match any PDF files.

            2. **Directory names**: You can specify directories in patterns by ending the pattern with a slash (/). For instance, `images/` will match all files or directories named "images" or residing within an "images" directory.

            3. **Negation**: Prefixing a pattern with an exclamation mark (!) negates the pattern, instructing the app to include files that would otherwise be excluded. For example, `!important.pdf` would include a file named "important.pdf" even if it satisfies other exclusion patterns.

            4. **Comments**: You can include comments by adding a hash symbol (`#`) at the beginning of the line. These comments are ignored by the app and serve as helpful annotations for humans.

            *More complex patterns can be found in the [gitignore documentation](https://git-scm.com/docs/gitignore#_pattern_format).*

            **Examples:**

            `# Ignore all hidden files starting with a period character (dotfiles)`
            `.*`
            ` `
            `# Ignore all files and subfolders of app bundles`
            `*.app/*`
            ` `
            `# Exclude all files in a "DontSearch" directory`
            `DontSearch/`
            ` `
            `# Exclude all files with the `.temp` extension`
            `*.temp`
            ` `
            `# Exclude invoices (PDF files starting with "invoice-")`
            `invoice-*.pdf`
            ` `
            `# Exclude a specific file named "confidential.pdf"`
            `confidential.pdf`
            ` `
            `# Include a specific file named "important.pdf" even if it matches other patterns`
            `!important.pdf`
            """)
            .foregroundColor(.secondary)
        }
    }
}

import System

let VOLUMES: FilePath = "/Volumes"

extension URL {
    var volumeName: String? {
        (try? resourceValues(forKeys: [.volumeNameKey]))?.volumeName
    }
    var isLocalVolume: Bool {
        (try? resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == true
    }
    var isRootVolume: Bool {
        (try? resourceValues(forKeys: [.volumeIsRootFileSystemKey]))?.volumeIsRootFileSystem == true
    }
    var isVolume: Bool {
        guard let vals = try? resourceValues(forKeys: [.isVolumeKey, .volumeIsRootFileSystemKey]) else { return false }
        return vals.isVolume == true && vals.volumeIsRootFileSystem == false
    }
    var volumeIsReadOnly: Bool {
        guard let vals = try? resourceValues(forKeys: [.volumeIsReadOnlyKey]) else { return false }
        return vals.volumeIsReadOnly == true
    }
}

extension FilePath: @retroactive Comparable {
    public static func < (lhs: FilePath, rhs: FilePath) -> Bool {
        lhs.string < rhs.string
    }

    @MainActor
    var volume: FilePath? {
        FUZZY.externalVolumes
            .filter { self.starts(with: $0) }
            .max(by: \.components.count)
    }
    @MainActor
    var isOnExternalVolume: Bool {
        guard let volume = memoz.volume else { return false }
        return !volume.url.isLocalVolume
    }
    @MainActor
    var isOnReadOnlyVolume: Bool {
        guard let volume = memoz.volume else { return false }
        return FUZZY.readOnlyVolumes.contains(volume)
    }

    var enabledVolumeBinding: Binding<Bool> {
        Binding(
            get: { !Defaults[.disabledVolumes].contains(self) },
            set: { enabled in
                if enabled {
                    Defaults[.disabledVolumes].removeAll { $0 == self }
                } else {
                    Defaults[.disabledVolumes].append(self)
                }
            }
        )
    }
    var reindexTimeIntervalBinding: Binding<Double> {
        Binding(
            get: { Defaults[.reindexTimeIntervalPerVolume][self] ?? DEFAULT_VOLUME_REINDEX_INTERVAL },
            set: { Defaults[.reindexTimeIntervalPerVolume][self] = $0 }
        )
    }
}

struct VolumeListView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                (
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) { Text("External Volumes"); ProBadge() }
                        Text("Index external or network drives").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                ).fixedSize()
                Spacer()

                if !fuzzy.enabledVolumes.isEmpty {
                    if !fuzzy.volumesIndexing.isEmpty {
                        Button("Cancel All") {
                            fuzzy.cancelVolumeIndexing()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        Button("Reindex All") {
                            fuzzy.indexVolumes(fuzzy.enabledVolumes)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            if !fuzzy.externalVolumes.isEmpty {
                ForEach(fuzzy.externalVolumes, id: \.string) { volume in
                    volumeItem(volume)
                }
            }

            let disconnected = fuzzy.disconnectedVolumes.sorted(by: { $0.string < $1.string })
            if !disconnected.isEmpty {
                Divider().padding(.vertical, 4)
                Text("Disconnected Volumes")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(disconnected, id: \.string) { volume in
                    disconnectedVolumeItem(volume)
                }
            }
        }
    }

    private func disconnectedVolumeItem(_ volume: FilePath) -> some View {
        HStack {
            Image(systemName: "externaldrive.badge.xmark").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(volume.name.string)
                    Text("Disconnected")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                }
                Text(volume.shellString)
                    .monospaced()
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Remove") {
                fuzzy.removeVolume(volume)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Delete cached index for \(volume.name.string)")
        }
        .padding(.vertical, 2)
    }

    @Default(.reindexTimeIntervalPerVolume) private var reindexTimeIntervalPerVolume

    func volumeItem(_ volume: FilePath) -> some View {
        VStack(alignment: .leading) {
            Toggle(isOn: volume.enabledVolumeBinding) {
                HStack {
                    Image(systemName: "externaldrive")
                    Text(volume.name.string)
                    Spacer()
                    Text(volume.shellString)
                        .monospaced()
                        .foregroundColor(.secondary)
                        .truncationMode(.middle)
                    if fuzzy.enabledVolumes.contains(volume) {
                        if fuzzy.volumesIndexing.contains(volume) {
                            Button("Cancel") {
                                fuzzy.cancelVolumeIndexing(volume: volume)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Cancel indexing \(volume.name.string)")
                        } else {
                            Button("Reindex") {
                                fuzzy.indexVolume(volume)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Reindex \(volume.name.string)")
                        }
                    }
                }
            }
            ReindexTimeIntervalSlider(volume: volume, interval: Defaults[.reindexTimeIntervalPerVolume][volume] ?? DEFAULT_VOLUME_REINDEX_INTERVAL)
        }
    }

    @State private var fuzzy = FUZZY

    @Default(.disabledVolumes) private var disabledVolumes
}

struct ReindexTimeIntervalSlider: View {
    var volume: FilePath

    var body: some View {
        HStack {
            Text("Reindex Interval: ")
                .round(12)
            Slider(value: $interval, in: 3600 ... 2_419_200) {
                Text(interval.humanizedInterval).mono(11)
                    .frame(width: 150, alignment: .trailing)
            }
            .onChange(of: interval) {
                interval = (interval / 3600).rounded() * 3600
                Defaults[.reindexTimeIntervalPerVolume][volume] = interval
            }
        }
    }

    @State var interval: TimeInterval = DEFAULT_VOLUME_REINDEX_INTERVAL

}

extension TimeInterval {
    var humanizedInterval: String {
        switch self {
        case 0 ..< 60:
            return "\(Int(self)) second\(Int(self) > 1 ? "s" : "")"
        case 60 ..< 3600:
            let minutes = Int(self / 60)
            let seconds = Int(self) % 60
            return seconds == 0
                ? "\(minutes) minute\(minutes > 1 ? "s" : "")"
                : "\(minutes) minute\(minutes > 1 ? "s" : "") \(seconds) second\(seconds > 1 ? "s" : "")"
        case 3600 ..< 86400:
            let hours = Int(self / 3600)
            let minutes = Int(self / 60) % 60
            return minutes == 0
                ? "\(hours) hour\(hours > 1 ? "s" : "")"
                : "\(hours) hour\(hours > 1 ? "s" : "") \(minutes) minute\(minutes > 1 ? "s" : "")"
        case 86400 ..< 604_800:
            let days = Int(self / 86400)
            let hours = Int(self / 3600) % 24
            return hours == 0
                ? "\(days) day\(days > 1 ? "s" : "")"
                : "\(days) day\(days > 1 ? "s" : "") \(hours) hour\(hours > 1 ? "s" : "")"
        case 604_800 ..< 2_419_200:
            let weeks = Int(self / 604_800)
            let days = Int(self / 86400) % 7
            return days == 0
                ? "\(weeks) week\(weeks > 1 ? "s" : "")"
                : "\(weeks) week\(weeks > 1 ? "s" : "") \(days) day\(days > 1 ? "s" : "")"
        default:
            let months = Int(self / 2_419_200)
            let weeks = Int(self / 604_800) % 4
            return weeks == 0
                ? "\(months) month\(months > 1 ? "s" : "")"
                : "\(months) month\(months > 1 ? "s" : "") \(weeks) week\(weeks > 1 ? "s" : "")"
        }
    }
}

struct ProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.system(size: 8, weight: .heavy))
            .foregroundColor(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color.orange))
    }
}

struct SettingsCardGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.content
            .padding(10)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))
    }
}
