import Defaults
import Lowtech
import SwiftUI
import System

// MARK: - WindowMode

enum WindowMode: String, CaseIterable {
    case utility = "Utility"
    case desktopApp = "Desktop App"
}

// MARK: - OnboardingView

struct OnboardingView: View {
    var body: some View {
        VStack(spacing: 0) {
            Text("Welcome to Cling")
                .heavy(28)
                .padding(.top, 30)
            Text("Fast file search for your Mac")
                .round(14, weight: .regular)
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 20) {
                // Window Mode
                VStack(alignment: .leading, spacing: 8) {
                    Text("Window Mode")
                        .heavy(14)
                    HStack(spacing: 12) {
                        windowModeButton(
                            mode: .utility,
                            icon: "rectangle.on.rectangle.angled",
                            description: [
                                "Summon on hotkey, hide on defocus",
                                "No Dock icon, stays out of the way",
                                "Best for quick find and act",
                            ]
                        )
                        windowModeButton(
                            mode: .desktopApp,
                            icon: "macwindow",
                            description: [
                                "Stays open like a regular app",
                                "Appears in the Dock and Cmd+Tab",
                                "Best for browsing and organizing",
                            ]
                        )
                    }
                }

                // UI Style
                VStack(alignment: .leading, spacing: 8) {
                    Text("Window Style")
                        .heavy(14)
                    Picker("", selection: $windowAppearance) {
                        ForEach(WindowAppearance.allCases.filter(\.available), id: \.self) { appearance in
                            Text(appearance.rawValue).tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                // Global Hotkey
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Global Hotkey")
                            .heavy(14)
                        Spacer()
                        Toggle("", isOn: $enableGlobalHotkey)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    HStack {
                        DirectionalModifierView(triggerKeys: $triggerKeys, showFnCaps: false)
                        Text("+").heavy(12)
                        DynamicKey(key: $showAppKey, recording: $env.recording, allowedKeys: .showAppKeyChoices)
                    }
                    .disabled(!enableGlobalHotkey)
                    .opacity(enableGlobalHotkey ? 1 : 0.5)
                }

                // Full Disk Access
                VStack(alignment: .leading, spacing: 8) {
                    Text("Full Disk Access")
                        .heavy(14)
                    HStack(spacing: 12) {
                        Button(action: {
                            FullDiskAccess.openSystemSettings()
                        }) {
                            Label(
                                fdaGranted ? "Granted" : "Grant in System Settings",
                                systemImage: fdaGranted ? "checkmark.circle.fill" : "lock.shield"
                            )
                        }
                        .disabled(fdaGranted)

                        Text("Required to search files across your entire disk")
                            .round(11, weight: .regular)
                            .foregroundStyle(.secondary)
                    }
                }
                // External Volumes
                if !availableVolumes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("External Volumes")
                            .heavy(14)
                        Text("Select volumes to index automatically")
                            .round(11, weight: .regular)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(availableVolumes, id: \.string) { volume in
                                Toggle(isOn: volumeBinding(volume)) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "externaldrive")
                                            .foregroundStyle(.secondary)
                                        Text(volume.name.string)
                                        Text(volume.shellString)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 28)

            Spacer()
            Spacer()

            Button(action: getStarted) {
                Text("Get Started")
                    .heavy(14)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: [])
            .padding(.horizontal, 36)
            .padding(.bottom, 24)
        }
        .frame(width: 560)
        .frame(maxHeight: .infinity)
        .onAppear {
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "onboarding" }) {
                window.level = .floating
                window.titlebarAppearsTransparent = true
                window.backgroundColor = .clear
                window.styleMask.insert(.fullSizeContentView)
                window.isMovableByWindowBackground = true
            }
            fdaGranted = FullDiskAccess.isGranted
            fdaChecker = Repeater(every: 2) {
                guard FullDiskAccess.isGranted else { return }
                mainActor {
                    fdaGranted = true
                    fdaChecker = nil
                }
            }
        }
        .onDisappear {
            fdaChecker = nil
        }
    }

    @EnvironmentObject private var env: EnvState
    @Default(.windowAppearance) private var windowAppearance
    @Default(.enableGlobalHotkey) private var enableGlobalHotkey
    @Default(.showAppKey) private var showAppKey
    @Default(.triggerKeys) private var triggerKeys
    @Default(.showDockIcon) private var showDockIcon
    @Default(.keepWindowOpenWhenDefocused) private var keepWindowOpenWhenDefocused

    @State private var selectedMode: WindowMode = .utility
    @State private var fdaGranted = false
    @State private var fdaChecker: Repeater?
    @State private var availableVolumes: [FilePath] = FuzzyClient.getVolumes()
    @State private var selectedVolumes: Set<FilePath> = Set(FuzzyClient.getVolumes())

    private func volumeBinding(_ volume: FilePath) -> Binding<Bool> {
        Binding(
            get: { selectedVolumes.contains(volume) },
            set: { enabled in
                if enabled { selectedVolumes.insert(volume) }
                else { selectedVolumes.remove(volume) }
            }
        )
    }

    @ViewBuilder
    private func windowModeButton(mode: WindowMode, icon: String, description: [String]) -> some View {
        let isSelected = selectedMode == mode

        Button(action: { selectedMode = mode }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 24))
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.accentColor)
                            .font(.system(size: 18))
                    }
                }

                Text(mode.rawValue)
                    .heavy(16)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(description, id: \.self) { point in
                        HStack(alignment: .top, spacing: 6) {
                            Text("\u{2022}")
                                .foregroundStyle(.secondary)
                            Text(point)
                                .round(11, weight: .regular)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private func getStarted() {
        switch selectedMode {
        case .utility:
            showDockIcon = false
            keepWindowOpenWhenDefocused = false
            NSApp.setActivationPolicy(.accessory)
        case .desktopApp:
            showDockIcon = true
            keepWindowOpenWhenDefocused = true
            NSApp.setActivationPolicy(.regular)
        }

        // Configure volumes: disable unselected, enable selected
        let disabledVolumes = availableVolumes.filter { !selectedVolumes.contains($0) }
        Defaults[.disabledVolumes] = disabledVolumes
        FUZZY.disabledVolumes = disabledVolumes
        FUZZY.externalVolumes = availableVolumes

        // Start indexing selected volumes
        if !selectedVolumes.isEmpty {
            FUZZY.indexVolumes(Array(selectedVolumes))
        }

        Defaults[.onboardingCompleted] = true

        if let onboardingWindow = NSApp.windows.first(where: { $0.identifier?.rawValue == "onboarding" }) {
            onboardingWindow.close()
        }
        WM.open("main")
        AppDelegate.shared?.focusWindow()
        focus()
    }
}

#Preview {
    OnboardingView()
        .environmentObject(EnvState())
}
