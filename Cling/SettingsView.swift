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

extension Set<SauceKey> {
    /// Keys offered in the show/hide hotkey recorder: everything in `ALL_KEYS` plus a few non-symbol
    /// keys (Space, Tab, Return, Delete, arrows) so combos like ⌘Space / ⌥Space can be set. All of
    /// these register through Carbon (`RegisterEventHotKey`), so no extra permissions are needed.
    static var showAppKeyChoices: Set<SauceKey> {
        SauceKey.ALL_KEYS.set.union([.space, .tab, .return, .delete, .upArrow, .downArrow, .leftArrow, .rightArrow])
    }
}

let envState = EnvState()

// MARK: - SettingsCategory

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, interface, shortcuts, apps, search, volumes, filters, scripts, exclusions, licenseAndUpdates, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .interface: "Style"
        case .shortcuts: "Keyboard Shortcuts"
        case .apps: "Open With"
        case .search: "Search"
        case .volumes: "Drives & Volumes"
        case .filters: "Filters"
        case .scripts: "Scripts"
        case .exclusions: "Excluded Paths"
        case .licenseAndUpdates: "License & updates"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .interface: "slider.horizontal.3"
        case .shortcuts: "keyboard"
        case .apps: "app.badge"
        case .search: "magnifyingglass"
        case .volumes: "externaldrive"
        case .filters: "line.3.horizontal.decrease.circle"
        case .scripts: "terminal"
        case .exclusions: "eye.slash"
        case .licenseAndUpdates: "key"
        case .about: "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .interface: .orange
        case .shortcuts: .mint
        case .apps: .blue
        case .search: .green
        case .volumes: .cyan
        case .filters: .teal
        case .scripts: .indigo
        case .exclusions: .red
        case .licenseAndUpdates: .yellow
        case .about: .pink
        }
    }
}

// MARK: - SettingsNavigation

/// Drives the Settings sidebar selection so it can be set programmatically — e.g. focusing the
/// About item before presenting the Paddle licence sheet.
@MainActor final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()

    @Published var selection: SettingsCategory = .general
}

// MARK: - SettingsView

struct SettingsView: View {
    @ObservedObject private var nav = SettingsNavigation.shared
    @EnvironmentObject var env: EnvState

    var body: some View {
        NavigationSplitView {
            List(selection: $nav.selection) {
                Section {
                    sidebarRow(.general)
                    sidebarRow(.interface)
                }
                Section("Search") {
                    sidebarRow(.search)
                    sidebarRow(.filters)
                    sidebarRow(.volumes)
                    sidebarRow(.exclusions)
                }
                Section("Actions") {
                    sidebarRow(.shortcuts)
                    sidebarRow(.apps)
                    sidebarRow(.scripts)
                }
                Section("Support") {
                    sidebarRow(.licenseAndUpdates)
                    sidebarRow(.about)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detailView
                .navigationTitle(nav.selection.title)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 820, maxWidth: .infinity, minHeight: 640, maxHeight: .infinity)
    }

    @ViewBuilder
    private func sidebarRow(_ category: SettingsCategory) -> some View {
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

    @ViewBuilder
    private var detailView: some View {
        switch nav.selection {
        case .general: GeneralSettingsPane().environmentObject(env)
        case .interface: InterfaceSettingsPane()
        case .shortcuts: ShortcutsSettingsPane()
        case .apps: AppsSettingsPane()
        case .search: SearchSettingsPane()
        case .volumes: VolumesSettingsPane()
        case .filters: FiltersSettingsPane()
        case .scripts: ScriptsSettingsPane()
        case .exclusions: ExclusionsSettingsPane()
        case .licenseAndUpdates: LicenseAndUpdatesSettingsPane()
        case .about: AboutSettingsPane()
        }
    }
}

// MARK: - SettingRow

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

// MARK: - DescriptiveToggle

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

// MARK: - InterfaceSettingsPane

private struct InterfaceSettingsPane: View {
    // MARK: Body

    var body: some View {
        Form {
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
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            Section("Rows") {
                DescriptiveToggle(
                    title: "Action Bar row",
                    detail: "The bar of buttons under the results: Open, Copy, Trash, Rename, etc.",
                    isOn: $showActionRow
                )
                DescriptiveToggle(
                    title: "Open With row",
                    detail: "Quick app shortcuts for opening the selected files.",
                    isOn: $showOpenWithRow
                )
                DescriptiveToggle(
                    title: "Scripts row",
                    detail: "Run scripts on the selected files.",
                    isOn: $showScriptRow
                )
            }

            // MARK: Part A — toolbar knobs

            Section("Action Bar styling") {
                SettingRow(title: "Labels") {
                    Picker("", selection: $toolbarLabelStyle) {
                        Text("Icon + Text").tag(ToolbarLabelStyle.iconAndText)
                        Text("Text only").tag(ToolbarLabelStyle.textOnly)
                        Text("Icon only").tag(ToolbarLabelStyle.iconOnly)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }

                SettingRow(title: "Density") {
                    Picker("", selection: $toolbarDensity) {
                        Text("Regular").tag(ToolbarDensity.regular)
                        Text("Compact").tag(ToolbarDensity.compact)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .disabled(!showActionRow)

            Section {
                DescriptiveToggle(
                    title: "Show Action Menu",
                    detail: "The \u{22EF} menu holds actions you keep out of the bar. Shows only when there are overflow actions.",
                    isOn: $showActionMenu
                )

                DescriptiveToggle(
                    title: "Show segment dividers",
                    detail: "Thin separators between action groups",
                    isOn: $toolbarShowDividers
                )

                DescriptiveToggle(
                    title: "Show row background",
                    detail: "Show the material behind the action row",
                    isOn: $toolbarRowBackground
                )
            }
            .disabled(!showActionRow)

            // MARK: Sharing

            Section {
                SettingRow(title: "Default link expiration") {
                    Picker("", selection: $defaultLinkExpiration) {
                        ForEach(LINK_EXPIRATION_PRESETS, id: \.self) { e in
                            Text(expirationDurationLabel(e)).tag(e)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            } header: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Send Securely")
                    Text("Share the selected files over a private link that's copied to your clipboard. Files transfer straight from your Mac, so a link works only while you're sharing it and stops when it expires.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // MARK: Part B — per-action visibility editor

            ForEach(Array(ToolbarAction.segmentOrder.enumerated()), id: \.element) { index, segment in
                let actions = ToolbarAction.all.filter { $0.segment == segment }
                if !actions.isEmpty {
                    if index == 0 {
                        Section {
                            ForEach(actions) { action in
                                placementRow(action)
                            }
                        } header: {
                            Text(segment.title)
                        } footer: {
                            Text("Choose where each action lives: the Action Bar, the ⋯ Action Menu, or hidden entirely.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .disabled(!showActionRow)
                    } else {
                        Section(segment.title) {
                            ForEach(actions) { action in
                                placementRow(action)
                            }
                        }
                        .disabled(!showActionRow)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: Part A — knob state

    @Default(.showActionRow) private var showActionRow
    @Default(.showOpenWithRow) private var showOpenWithRow
    @Default(.showScriptRow) private var showScriptRow

    @Default(.windowAppearance) private var windowAppearance
    @Default(.toolbarLabelStyle) private var toolbarLabelStyle
    @Default(.toolbarDensity) private var toolbarDensity
    @Default(.showActionMenu) private var showActionMenu
    @Default(.toolbarShowDividers) private var toolbarShowDividers
    @Default(.toolbarRowBackground) private var toolbarRowBackground
    @Default(.defaultLinkExpiration) private var defaultLinkExpiration

    // MARK: Part B — placement state

    @Default(.barActions) private var barActions
    @Default(.hiddenActions) private var hiddenActions

    // MARK: Helpers

    private func placementRow(_ action: ToolbarAction) -> some View {
        LabeledContent {
            Picker("", selection: toolbarPlacement(for: action.id)) {
                Label("Action Bar", systemImage: "dock.rectangle").tag(ToolbarPlacement.bar)
                Label("Action Menu", systemImage: "ellipsis").tag(ToolbarPlacement.more)
                Label("Hidden", systemImage: "eye.slash").tag(ToolbarPlacement.hidden)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        } label: {
            Label(action.title, systemImage: action.systemImage)
        }
    }

    private func toolbarPlacement(for id: ActionID) -> Binding<ToolbarPlacement> {
        Binding(
            get: {
                if hiddenActions.contains(id) { return .hidden }
                return barActions.contains(id) ? .bar : .more
            },
            set: { newValue in
                var bar = barActions
                var hidden = hiddenActions
                bar.removeAll { $0 == id }
                hidden.remove(id)
                switch newValue {
                case .bar: bar.append(id)
                case .more: break
                case .hidden: hidden.insert(id)
                }
                barActions = bar
                hiddenActions = hidden
            }
        )
    }
}

// MARK: - ToolbarPlacement

private enum ToolbarPlacement: String, CaseIterable {
    case bar, more, hidden
}

// MARK: - GeneralSettingsPane

private struct GeneralSettingsPane: View {
    @Default(.showWindowAtLaunch) private var showWindowAtLaunch
    @Default(.showDockIcon) private var showDockIcon
    @Default(.keepWindowOpenWhenDefocused) private var keepWindowOpenWhenDefocused
    @Default(.instantMode) private var instantMode
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

            Section {
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
            }

            Section("Window") {
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
                    title: "Hotkey"
                ) {
                    HStack(spacing: 6) {
                        DirectionalModifierView(triggerKeys: $triggerKeys, showFnCaps: false)
                            .disabled(!enableGlobalHotkey)
                        Text("+").heavy(12)
                        DynamicKey(key: $showAppKey, recording: $env.recording, allowedKeys: .showAppKeyChoices)
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

// MARK: - AppsSettingsPane

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

                DescriptiveToggle(
                    title: "Enter key pastes paths to frontmost terminal",
                    detail: "When a terminal app is frontmost, Enter pastes the selected file paths into it instead of opening them. Turn off if you always prefer to open files on Enter.",
                    isOn: $enterPastesToFrontmostTerminal
                )

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
    @Default(.enterPastesToFrontmostTerminal) private var enterPastesToFrontmostTerminal

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

// MARK: - SearchSettingsPane

private struct SearchSettingsPane: View {
    @Default(.maxResultsCount) private var maxResultsCount
    @Default(.defaultResultsMode) private var defaultResultsMode
    @Default(.searchScopes) private var searchScopes
    @Default(.showSearchHints) private var showSearchHints
    @Default(.searchHintsManuallyEnabled) private var searchHintsManuallyEnabled
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

                DescriptiveToggle(
                    title: "Show search hints",
                    detail: "Cycle example queries in the search field placeholder.",
                    isOn: $showSearchHints
                )
                .onChange(of: showSearchHints) {
                    searchHintsManuallyEnabled = true
                }
            }

            Section("Command Line Tool") {
                SettingRow(
                    title: "Command Line Tool",
                    detail: "Installs `cling` to `~/.local/bin/` for searching from the terminal."
                ) {
                    Button(ShellIntegration.isInstalled ? "Reinstall" : "Install") {
                        cliInstallMessage = ShellIntegration.installCLI()
                        cliInstallSuccess = ShellIntegration.isInstalled
                        if cliInstallSuccess, ShellIntegration.needsPathSetup {
                            showCLIPathAlert = true
                        } else {
                            showCLIAlert = true
                        }
                    }
                    .truncationMode(.middle)
                }

                if ShellIntegration.isInstalled {
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

// MARK: - VolumesSettingsPane

private struct VolumesSettingsPane: View {
    var body: some View {
        Form {
            Section {
                DescriptiveToggle(
                    title: "Don't index new volumes automatically",
                    detail: "When on, a volume connected for the first time is not indexed until you enable it below. Volumes you've already indexed keep refreshing on their own.",
                    isOn: $disableAutomaticVolumeIndexing
                )
                .disabled(!proactive)
            }

            Section {
                VolumeListView().disabled(!proactive)
            } header: {
                Text("External Volumes")
            } footer: {
                Text("Index external or network drives so their files show up in search. Each volume can have its own `.fsignore`, editable under Exclusions.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    @Default(.disableAutomaticVolumeIndexing) private var disableAutomaticVolumeIndexing

}

// MARK: - FiltersSettingsPane

private struct FiltersSettingsPane: View {
    var body: some View {
        FilterEditorSheet(embedded: true)
    }
}

// MARK: - ScriptsSettingsPane

private struct ScriptsSettingsPane: View {
    var body: some View {
        ScriptEditorSheet(embedded: true)
    }
}

// MARK: - ExclusionsSettingsPane

private struct ExclusionsSettingsPane: View {
    @Default(.blockedPrefixes) private var blockedPrefixes
    @Default(.blockedContains) private var blockedContains
    @Default(.honorGitignore) private var honorGitignore
    @Default(.editorApp) private var editorApp
    @State private var fuzzy = FUZZY
    @State private var fsignoreContent: String = (try? String(contentsOf: fsignore.url, encoding: .utf8)) ?? ""
    @State private var fsignoreSaveTask: DispatchWorkItem?
    @State private var scopeContents: [String: String] = Dictionary(
        uniqueKeysWithValues: ScopeIgnore.rootedScopes.map { ($0.rawValue, ScopeIgnore.content(for: $0)) }
    )
    @State private var scopeSaveTasks: [String: DispatchWorkItem] = [:]
    @State private var showResetAllConfirm = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                resetAllHeader
                homeEditor
                gitignoreSection
                scopeEditors
                blocklistEditors
                volumeIgnoreSection
            }
            .padding()
        }
    }

    private var resetAllHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Index Exclusions").font(.system(size: 13, weight: .bold))
                Text("Toggle whole groups on or off. Open Edit as text under any list for full gitignore control.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) { showResetAllConfirm = true } label: {
                Label("Reset All to Default", systemImage: "arrow.counterclockwise")
            }
            .controlSize(.small)
            .confirmationDialog(
                "Reset all exclusion rules to Cling's defaults?",
                isPresented: $showResetAllConfirm,
                titleVisibility: .visible
            ) {
                Button("Reset All", role: .destructive) { resetAllToDefault() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Replaces the Home ignore file, the global blocklist, and every per-scope ignore file with Cling's built-in rules. Your custom rules in these lists are removed. Volume ignore files are left untouched.")
            }
        }
    }

    private var homeBinding: Binding<String> {
        Binding(
            get: { fsignoreContent },
            set: { newVal in
                fsignoreContent = newVal
                fsignoreSaveTask?.cancel()
                let task = DispatchWorkItem {
                    FUZZY.fsignoreWatchSuppressedUntil = CFAbsoluteTimeGetCurrent() + 5
                    try? newVal.write(to: fsignore.url, atomically: true, encoding: .utf8)
                }
                fsignoreSaveTask = task
                DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: task)
            }
        )
    }

    private func scopeBinding(_ scope: SearchScope) -> Binding<String> {
        Binding(
            get: { scopeContents[scope.rawValue] ?? "" },
            set: { newVal in
                scopeContents[scope.rawValue] = newVal
                scopeSaveTasks[scope.rawValue]?.cancel()
                let task = DispatchWorkItem { ScopeIgnore.write(newVal, for: scope) }
                scopeSaveTasks[scope.rawValue] = task
                DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: task)
            }
        )
    }

    private func resetAllToDefault() {
        let homeDefault = (try? String(contentsOf: FS_IGNORE.url, encoding: .utf8)) ?? ""
        fsignoreContent = homeDefault
        fsignoreSaveTask?.cancel()
        FUZZY.fsignoreWatchSuppressedUntil = CFAbsoluteTimeGetCurrent() + 5
        try? homeDefault.write(to: fsignore.url, atomically: true, encoding: .utf8)

        Defaults.reset(.blockedPrefixes)
        Defaults.reset(.blockedContains)
        PathBlocklist.shared.rebuild()

        for scope in ScopeIgnore.rootedScopes {
            let def = ScopeIgnore.bundledTemplate(for: scope) ?? ""
            scopeContents[scope.rawValue] = def
            ScopeIgnore.write(def, for: scope)
        }

        FUZZY.refresh(pauseSearch: false)
    }

    private var gitignoreSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $honorGitignore) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Respect each project's .gitignore").font(.system(size: 12, weight: .semibold))
                        Text(
                            "While indexing your Home folder, apply every project's own `.gitignore` and `.ignore` files, so build output (like `node_modules`, `target`, `dist`) is skipped per project. Some ignored files (`.env`, built sites) will stop appearing in search."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .onChange(of: honorGitignore) {
                    FUZZY.refresh(pauseSearch: false, scopes: [.home])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .groupBoxStyle(SettingsCardGroupBoxStyle())
    }

    private var scopeEditors: some View {
        VStack(spacing: 16) {
            ForEach(ScopeIgnore.rootedScopes, id: \.self) { scope in
                GroupedIgnoreEditor(
                    title: "\(scope.label) Ignore File",
                    subtitle: "Rules for the \(scope.label) scope (stored in Cling's cache, since this root can't hold a `.fsignore`). Patterns are relative to the scope root.",
                    rawText: scopeBinding(scope),
                    rawEditorHeight: 120,
                    applyDisabled: fuzzy.backgroundIndexing,
                    onApply: {
                        scopeSaveTasks[scope.rawValue]?.cancel()
                        ScopeIgnore.write(scopeContents[scope.rawValue] ?? "", for: scope)
                        FUZZY.refresh(pauseSearch: false, scopes: [scope])
                    },
                    defaultText: { ScopeIgnore.bundledTemplate(for: scope) ?? "" }
                )
            }
        }
    }

    private var homeEditor: some View {
        GroupedIgnoreEditor(
            title: "Home Ignore File",
            subtitle: "gitignore rules applied while indexing your Home and Library folders.",
            rawText: homeBinding,
            rawEditorHeight: 200,
            applyDisabled: fuzzy.backgroundIndexing,
            showHelpButton: true,
            onApply: {
                fsignoreSaveTask?.cancel()
                FUZZY.fsignoreWatchSuppressedUntil = CFAbsoluteTimeGetCurrent() + 5
                try? fsignoreContent.write(to: fsignore.url, atomically: true, encoding: .utf8)
                FUZZY.refresh(pauseSearch: false, scopes: [.home, .library])
            },
            defaultText: { (try? String(contentsOf: FS_IGNORE.url, encoding: .utf8)) ?? "" },
            openExternal: {
                NSWorkspace.shared.open(
                    [fsignore.url],
                    withApplicationAt: editorApp.fileURL ?? "/Applications/TextEdit.app".fileURL!,
                    configuration: .init(),
                    completionHandler: { _, _ in }
                )
            }
        )
    }

    private var blocklistEditors: some View {
        VStack(spacing: 16) {
            GroupedIgnoreEditor(
                title: "Global Blocklist · Prefix matching",
                subtitle: "Fast matching applied on every scope before the ignore files. Blocks paths that start with any of these strings.",
                rawText: $blockedPrefixes,
                rawEditorHeight: 110,
                applyDisabled: fuzzy.backgroundIndexing,
                onApply: {
                    PathBlocklist.shared.rebuild()
                    FUZZY.refresh(pauseSearch: false)
                },
                defaultText: { Defaults.Keys.blockedPrefixes.defaultValue }
            )
            GroupedIgnoreEditor(
                title: "Global Blocklist · Contains matching",
                subtitle: "Blocks paths containing any of these strings anywhere. Prefix a rule with `!` for an exception (e.g. block `.app/Contents/` but keep `!.app/Contents/MacOS/`).",
                rawText: $blockedContains,
                rawEditorHeight: 130,
                applyDisabled: fuzzy.backgroundIndexing,
                onApply: {
                    PathBlocklist.shared.rebuild()
                    FUZZY.refresh(pauseSearch: false)
                },
                defaultText: { Defaults.Keys.blockedContains.defaultValue }
            )
        }
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

// MARK: - LicenseAndUpdatesSettingsPane

private struct LicenseAndUpdatesSettingsPane: View {
    @ObservedObject var updateManager = UM

    var body: some View {
        VStack(spacing: 0) {
            if let pro = PM.pro, let updater = updateManager.updater {
                Form {
                    LicenseAndUpdatesView(pro: pro, updater: updater, appName: "Cling", changelogURL: URL(string: "https://files.lowtechguys.com/cling/changelog.html"))
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }

            #if DEBUG
                HStack {
                    Button("Reset Trial") { AppDelegate.shared?.resetTrial() }
                    Button("Expire Trial") { AppDelegate.shared?.expireTrial() }
                    Spacer()
                }
                .padding()
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - AboutSettingsPane

private struct AboutSettingsPane: View {
    var body: some View {
        VStack(spacing: 0) {
            AboutView(
                appName: "Cling",
                pro: PM.pro,
                updater: UM.updater,
                websiteURL: URL(string: "https://lowtechguys.com/cling"),
                contactURL: URL(string: "https://lowtechguys.com/contact?app=Cling"),
                discordURL: URL(string: "https://discord.gg/ERxsH9Ek3q"),
                changelogURL: URL(string: "https://files.lowtechguys.com/cling/changelog.html")
            )

            #if DEBUG
                Form {
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
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @State private var scoringJSON: String = ScoringConfig.load().toJSON()

}

// MARK: - VolumeIgnoreEditor

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
                Button("Reset to Default") { content = "" }
                    .controlSize(.small)
                    .help("Clear this volume's ignore rules (no rules is the default)")
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    @State private var content = ""
    @State private var saveTask: DispatchWorkItem?

    private var fsignorePath: FilePath { volume / ".fsignore" }

}

// MARK: - IgnoreHelpText

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

// MARK: - FilePath + @retroactive Comparable

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

// MARK: - VolumeListView

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

// MARK: - ReindexTimeIntervalSlider

struct ReindexTimeIntervalSlider: View {
    var volume: FilePath

    /// Clean values the slider is magnetically pulled toward.
    private static let anchors: [TimeInterval] = [
        3600, // 1 hour
        10800, // 3 hours
        21600, // 6 hours
        43200, // 12 hours
        86400, // 1 day
        172_800, // 2 days
        259_200, // 3 days
        604_800, // 1 week
        1_209_600, // 2 weeks
        1_814_400, // 3 weeks
        2_419_200, // 4 weeks
    ]

    /// Fraction of the gap to the neighbouring anchor within which the handle snaps to that anchor.
    /// The remaining middle of each gap stays free, rounded to the hour.
    private static let magneticFraction: TimeInterval = 0.2

    var body: some View {
        HStack {
            Text("Reindex Interval: ")
                .round(12)
            Slider(value: snapped, in: 3600 ... 2_419_200) {
                Text(interval.humanizedInterval).mono(11)
                    .frame(width: 150, alignment: .trailing)
            }
        }
    }

    /// Binding that applies magnetic snapping as the handle moves, then persists the result.
    private var snapped: Binding<TimeInterval> {
        Binding(
            get: { interval },
            set: { raw in
                let value = Self.magneticValue(for: raw)
                interval = value
                Defaults[.reindexTimeIntervalPerVolume][volume] = value
            }
        )
    }

    /// Snaps `raw` to the nearest anchor when it falls inside that anchor's magnetic zone,
    /// otherwise rounds to the whole hour.
    private static func magneticValue(for raw: TimeInterval) -> TimeInterval {
        guard let idx = anchors.indices.min(by: { abs(anchors[$0] - raw) < abs(anchors[$1] - raw) }) else {
            return (raw / 3600).rounded() * 3600
        }
        let nearest = anchors[idx]
        let radius: TimeInterval = if raw < nearest {
            (nearest - anchors[max(idx - 1, 0)]) * magneticFraction
        } else {
            (anchors[min(idx + 1, anchors.count - 1)] - nearest) * magneticFraction
        }
        if abs(raw - nearest) <= radius { return nearest }
        return (raw / 3600).rounded() * 3600
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

// MARK: - ProBadge

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

// MARK: - SettingsCardGroupBoxStyle

struct SettingsCardGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.content
            .padding(10)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))
    }
}
