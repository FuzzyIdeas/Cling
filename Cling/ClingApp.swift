//
//  Created by Alin Panaitiu on 03.02.2025.
//

import AppKit
import Combine
import Defaults
import Lowtech
import LowtechIndie
import LowtechPro
import os.signpost
import Paddle
import Sparkle
import SwiftUI
import System

let summonSignposter = OSSignposter(subsystem: "com.lowtechguys.Cling", category: "Summon")

extension [String] {
    func removing(_ element: String) -> [String] {
        filter { $0 != element }
    }
}

/// Arguments minus --hidden for custom processing
var appArguments: [String] {
    CommandLine.arguments.removing("--hidden")
}

@MainActor
func cleanup() {
    FUZZY.cleanup()
}

let HOUR_FACTOR: TimeInterval = 60 * 60
let MINUTE_FACTOR: TimeInterval = 60

@MainActor @Observable
final class AppearanceManager {
    init() {
        let appearance = Defaults[.windowAppearance]
        if #available(macOS 26, *) {
            useGlass = appearance.isGlassy
        } else {
            useGlass = false
        }
        useVibrant = !appearance.isOpaque
    }

    static let shared = AppearanceManager()

    var useGlass: Bool
    var useVibrant: Bool

    func update() {
        let appearance = Defaults[.windowAppearance]
        if #available(macOS 26, *) {
            useGlass = appearance.isGlassy
        } else {
            useGlass = false
        }
        useVibrant = !appearance.isOpaque
    }
}

let AM = AppearanceManager.shared

var PRODUCTS: [Any] {
    if let product {
        [product]
    } else {
        []
    }
}

@MainActor
class AppDelegate: LowtechProAppDelegate {
    @MainActor
    override public func willShowPaddle(_: PADUIType, product _: PADProduct) -> PADDisplayConfiguration? {
        PADDisplayConfiguration(.window, hideNavigationButtons: false, parentWindow: nil)
    }

    static var shared: AppDelegate!

    var keepSettingsFrontUntil: Date?

    var mainWindow: NSWindow? {
        NSApp.windows.first { $0.title == "Cling" }
    }
    var settingsWindow: NSWindow? {
        NSApp.windows.first { $0.title.contains("Settings") }
    }

    override func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        swizzleDraggableToRealPath()
        NSApp.disableRelaunchOnLogin()
        if !SWIFTUI_PREVIEW,
           let app = NSWorkspace.shared.runningApplications.first(where: {
               $0.bundleIdentifier == Bundle.main.bundleIdentifier
                   && $0.processIdentifier != NSRunningApplication.current.processIdentifier
           })
        {
            app.forceTerminate()
        }
        Migration.run()
        FUZZY.start()
        setupCleanup()

        if !SWIFTUI_PREVIEW {
            paddleVendorID = "122873"
            paddleAPIKey = "e1e517a68c1ed1bea2ac968a593ac147"
            paddleProductID = "923424"
            trialDays = 14
            trialText = "This is a trial for the Pro features. After the trial, the app will automatically revert to the free version."
            price = 12
            productName = "Cling Pro"
            vendorName = "THE LOW TECH GUYS SRL"
            hasFreeFeatures = true
        }

        super.applicationDidFinishLaunching(notification)

        KM.specialKey = Defaults[.enableGlobalHotkey] ? Defaults[.showAppKey] : nil
        KM.specialKeyModifiers = Defaults[.triggerKeys]
        KM.onSpecialHotkey = { [self] in
            let t0 = DispatchTime.now().uptimeNanoseconds
            let wallNS = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
            log.debug("RECV_NS=\(wallNS) (KM handler entry)")
            log.debug("Hotkey fired: isKey=\(mainWindow?.isKeyWindow ?? false) isVisible=\(mainWindow?.isVisible ?? false) alpha=\(mainWindow?.alphaValue ?? -1) NSApp.isActive=\(NSApp.isActive)")
            if let mainWindow, mainWindow.isKeyWindow {
                let state = summonSignposter.beginInterval("HotkeyHide")
                log.debug("Hotkey: hiding (instant=\(Defaults[.instantMode]))")
                WM.pinned = false
                mainWindow.resignKey()
                mainWindow.resignMain()
                hideOrCloseMainWindow(mainWindow)
                APP_MANAGER.lastFrontmostApp?.activate()
                summonSignposter.endInterval("HotkeyHide", state)
                log.debug("Hotkey hide took \((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)ms")
            } else {
                let state = summonSignposter.beginInterval("HotkeyShow")
                let instantFastPath = Defaults[.instantMode] && mainWindow != nil
                log.debug("Hotkey: showing (instant=\(Defaults[.instantMode]), fastPath=\(instantFastPath), visible=\(mainWindow?.isVisible ?? false))")

                let t1 = DispatchTime.now().uptimeNanoseconds
                if instantFastPath {
                    focusWindow()
                } else {
                    WM.open("main")
                    focusWindow()
                    focus()
                }
                let t2 = DispatchTime.now().uptimeNanoseconds

                summonSignposter.endInterval("HotkeyShow", state)
                log.debug("Hotkey show: path=\((t2-t1)/1_000_000)ms total=\((t2-t0)/1_000_000)ms")

                CATransaction.begin()
                let tCA = DispatchTime.now().uptimeNanoseconds
                CATransaction.setCompletionBlock {
                    let wallNow = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
                    log.debug("SHOW_NS=\(wallNow) (CA commit at \((DispatchTime.now().uptimeNanoseconds - tCA)/1_000_000)ms)")
                }
                CATransaction.commit()

                DispatchQueue.main.async {
                    log.debug("Hotkey show: next runloop tick at \((DispatchTime.now().uptimeNanoseconds - t0)/1_000_000)ms")
                }
            }
        }
        pub(.enableGlobalHotkey)
            .sink { change in
                KM.specialKey = change.newValue ? Defaults[.showAppKey] : nil
                KM.reinitHotkeys()
            }.store(in: &observers)
        pub(.showAppKey)
            .sink { change in
                KM.specialKey = Defaults[.enableGlobalHotkey] ? change.newValue : nil
                KM.reinitHotkeys()
            }.store(in: &observers)
        pub(.triggerKeys)
            .sink { change in
                KM.specialKeyModifiers = change.newValue
                KM.reinitHotkeys()
            }.store(in: &observers)
        pub(.windowAppearance)
            .sink { _ in
                AM.update()
            }.store(in: &observers)
        pub(.instantMode)
            .sink { [self] change in
                mainWindow?.animationBehavior = change.newValue ? .none : .default
            }.store(in: &observers)

        UM.updater = updateController.updater
        PM.pro = pro
        if !SWIFTUI_PREVIEW {
            pro.checkProLicense()
            let _ = invalidReq(PRODUCTS, nil)
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeMain(_:)),
            name: NSWindow.didBecomeMainNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil
        )

        resizeCancellable = NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)
            .compactMap { $0.object as? NSWindow }
            .filter { $0.title == "Cling" }
            .map(\.frame.size)
            .filter { $0 != WM.size }
            .throttle(for: .milliseconds(80), scheduler: RunLoop.main, latest: true)
            .sink { newSize in
                WM.size = newSize
            }

        let skipWindow = CommandLine.arguments.contains("--hidden")
        if !Defaults[.onboardingCompleted] {
            // Keep dock icon visible during onboarding
            mainWindow?.close()
            WM.open("onboarding")
        } else {
            NSApp.setActivationPolicy(Defaults[.showDockIcon] ? .regular : .accessory)
            if Defaults[.showWindowAtLaunch], !skipWindow {
                WM.open("main")
                mainWindow?.becomeMain()
                mainWindow?.becomeKey()
                focus()
            } else if !skipWindow {
                mainWindow?.close()
            }
        }
    }

    override func applicationDidBecomeActive(_ notification: Notification) {
        guard didBecomeActiveAtLeastOnce else {
            didBecomeActiveAtLeastOnce = true
            return
        }
//        log.debug("Became active")
        focusWindow()
    }

    override func applicationDidResignActive(_ notification: Notification) {
        log.debug("Resigned active: pinned=\(WM.pinned) keepOpen=\(Defaults[.keepWindowOpenWhenDefocused]) settingsVisible=\(settingsWindow?.isVisible ?? false)")
        let settingsVisible = settingsWindow?.isVisible ?? false
        if !Defaults[.keepWindowOpenWhenDefocused], !settingsVisible {
            settingsWindow?.close()
        }
        guard !WM.pinned else {
            mainWindow?.alphaValue = 0.75
            return
        }
        guard !Defaults[.keepWindowOpenWhenDefocused], !settingsVisible else {
            return
        }

        if NSApp.isActive {
            log.debug("Skipping window close: app became active again")
            return
        }
        log.debug("Closing main window after resign delay")
        WM.mainWindowActive = false
        if let mainWindow {
            hideOrCloseMainWindow(mainWindow)
        }
    }

    func hideOrCloseMainWindow(_ window: NSWindow) {
        if Defaults[.instantMode] {
            window.animationBehavior = .none
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            WM.mainWindowActive = false
            log.debug("hideOrCloseMainWindow: instant hide, alpha=0")
        } else {
            window.close()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        log.debug("Open URLs: \(urls)")
        handleURLs(application, urls)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        log.debug("Open files: \(filenames)")
        handleURLs(sender, filenames.compactMap(\.url))
    }

    func handleURLs(_ application: NSApplication, _ urls: [URL]) {
        let filePaths = urls.compactMap(\.existingFilePath)
        guard !filePaths.isEmpty else {
            application.reply(toOpenOrPrint: .failure)
            return
        }
        let id = filePaths.count == 1 ? filePaths[0].name.string : "Custom"
        FUZZY.folderFilter = FolderFilter(id: id, folders: filePaths, key: nil)
        application.reply(toOpenOrPrint: .success)
    }

    func focusWindow() {
        guard let window = mainWindow else { return }
        let tC = DispatchTime.now().uptimeNanoseconds
        window.collectionBehavior.insert(.moveToActiveSpace)
        let tAfterC = DispatchTime.now().uptimeNanoseconds
        if Defaults[.instantMode] {
            window.animationBehavior = .none
            window.ignoresMouseEvents = false
            window.alphaValue = 1
            let tAfterAlpha = DispatchTime.now().uptimeNanoseconds
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            let tAfterMake = DispatchTime.now().uptimeNanoseconds
            NSApp.activate(ignoringOtherApps: true)
            let tAfterActivate = DispatchTime.now().uptimeNanoseconds
            log.debug("focusWindow: alpha=\((tAfterAlpha-tAfterC)/1_000_000)ms order+makeKey=\((tAfterMake-tAfterAlpha)/1_000_000)ms activate=\((tAfterActivate-tAfterMake)/1_000_000)ms")
        } else {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let oldpid = FileManager.default.contents(atPath: PIDFILE.string)?.s?.i32 else {
            return
        }
        log.debug("Killing old process: \(oldpid)")
        kill(oldpid, SIGKILL)
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !SWIFTUI_PREVIEW else {
            return true
        }

//        log.debug("Reopened")

        if let mainWindow {
            mainWindow.orderFrontRegardless()
            mainWindow.becomeMain()
            mainWindow.becomeKey()
            focus()
        } else {
            WM.open("main")
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleanup()
    }

    func setupCleanup() {
        signal(SIGINT) { _ in
            cleanup()
            exit(0)
        }
        signal(SIGTERM) { _ in
            cleanup()
            exit(0)
        }
        signal(SIGKILL) { _ in
            cleanup()
            exit(0)
        }
    }

    @objc func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window.title == "Cling" {
            WM.mainWindowActive = false
            APP_MANAGER.lastFrontmostApp?.activate()

        }
    }
    @objc func windowDidBecomeMain(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }

        if let paddleController = window.windowController as? PADActivateWindowController,
           let email = paddleController.emailTxt, let licenseCode = paddleController.licenseTxt
        {
            email.isBordered = true
            licenseCode.isBordered = true

            email.drawsBackground = true
            licenseCode.drawsBackground = true

            email.backgroundColor = .black.withAlphaComponent(0.05)
            licenseCode.backgroundColor = .black.withAlphaComponent(0.05)
        }

        if window.title.contains("Settings"), !settingsWindowConfigured {
            settingsWindowConfigured = true
            window.titlebarAppearsTransparent = true
            window.backgroundColor = .clear
            window.toolbar?.showsBaselineSeparator = false
        }

        if window.title == "Cling" {
            let tBM = DispatchTime.now().uptimeNanoseconds
            let bmState = summonSignposter.beginInterval("windowDidBecomeMain")
            WM.mainWindowActive = true
            let tRF = DispatchTime.now().uptimeNanoseconds
            FUZZY.refreshDefaultResultsIfNeeded()
            log.debug("windowDidBecomeMain: FUZZY.refresh took \((DispatchTime.now().uptimeNanoseconds - tRF)/1_000_000)ms")

            window.alphaValue = 1
            if !WM.pinned {
                window.level = .normal
            }

            if !windowConfigured {
                windowConfigured = true
                window.titlebarAppearsTransparent = true
                window.styleMask = [
                    .fullSizeContentView, .closable, .resizable, .miniaturizable, .titled,
                    .nonactivatingPanel,
                ]
                window.isMovableByWindowBackground = true
                window.backgroundColor = .clear

                if mainWindowDelegateProxy == nil {
                    let proxy = MainWindowDelegateProxy()
                    proxy.original = window.delegate
                    window.delegate = proxy
                    mainWindowDelegateProxy = proxy
                }
            }
            window.animationBehavior = Defaults[.instantMode] ? .none : .default
            WM.size = window.frame.size

            if let until = keepSettingsFrontUntil, Date.now < until {
                settingsWindow?.makeKeyAndOrderFront(nil)
            } else {
                keepSettingsFrontUntil = nil
            }
            summonSignposter.endInterval("windowDidBecomeMain", bmState)
            log.debug("windowDidBecomeMain total: \((DispatchTime.now().uptimeNanoseconds - tBM)/1_000_000)ms")
        }
    }
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        cleanup()
    }

    private var windowConfigured = false
    private var settingsWindowConfigured = false
    private var mainWindowDelegateProxy: MainWindowDelegateProxy?

    private var resizeCancellable: AnyCancellable?

}

final class MainWindowDelegateProxy: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated {
            guard Defaults[.instantMode] else {
                return original?.windowShouldClose?(sender) ?? true
            }
            WM.pinned = false
            AppDelegate.shared?.hideOrCloseMainWindow(sender)
            APP_MANAGER.lastFrontmostApp?.activate()
            return false
        }
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return original?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original
    }
}

@MainActor @Observable
class WindowManager {
    static let DEFAULT_SIZE = CGSize(width: 1150, height: 850)

    var windowToOpen: String?
    var size = DEFAULT_SIZE
    var pinned = false

    var mainWindowActive = false {
        didSet {
            guard !pinned, !Defaults[.keepWindowOpenWhenDefocused] else {
                return
            }
            FUZZY.suspended = !mainWindowActive
        }
    }

    func open(_ window: String) {
        if window == "main", NSApp.windows.first(where: { $0.title == "Cling" }) != nil {
            focus()
            AppDelegate.shared?.focusWindow()
            if windowToOpen != nil {
                windowToOpen = nil
            }
            return
        }
        windowToOpen = window
    }
}
@MainActor let WM = WindowManager()

import IOKit.ps

func batteryLevel() -> Double {
    guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources: NSArray = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue()
    else { return 1 }

    for ps in sources {
        guard let info: NSDictionary = IOPSGetPowerSourceDescription(snapshot, ps as CFTypeRef)?.takeUnretainedValue(),
              let capacity = info[kIOPSCurrentCapacityKey] as? Int,
              let max = info[kIOPSMaxCapacityKey] as? Int
        else { continue }

        return (max > 0) ? (Double(capacity) / Double(max)) : Double(capacity)
    }

    return 1
}

struct WindowBackground: View {
    var tintColor: Color {
        colorScheme == .light ? .white : .black
    }

    var body: some View {
        switch appearance {
        case .glassy:
            if #available(macOS 26, *) {
                let lightOpacity: Double = colorScheme == .light ? 0.7 : 0.5
                tintColor.opacity(lightOpacity)
                    .background(Color.clear.glassEffect(.regular, in: .rect))
            } else {
                let lightOpacity: Double = colorScheme == .light ? 0.4 : 0.5
                tintColor.opacity(lightOpacity)
                    .background(.regularMaterial)
            }
        case .vibrant:
            let lightOpacity: Double = colorScheme == .light ? 0.4 : 0.5
            tintColor.opacity(lightOpacity)
                .background(.regularMaterial)
        case .opaque:
            Color(.windowBackgroundColor)
        }
    }

    @Environment(\.colorScheme) private var colorScheme

    @Default(.windowAppearance) private var appearance

}

@main
struct ClingApp: App {
    @Environment(\.openWindow) var openWindow

    var body: some Scene {
        Window("Cling", id: "main") {
            ContentView()
                .frame(minWidth: WindowManager.DEFAULT_SIZE.width, minHeight: 300)
                .background {
                    WindowBackground()
                }
                .ignoresSafeArea()
                .environmentObject(envState)
        }
        .defaultSize(width: WindowManager.DEFAULT_SIZE.width, height: WindowManager.DEFAULT_SIZE.height)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .help) {
                Button("Check for updates (current version: v\(Bundle.main.version))") {
                    UM.updater?.checkForUpdates()
                }
                .keyboardShortcut("U", modifiers: [.command])
            }
        }
        .onChange(of: wm.windowToOpen) {
            guard let window = wm.windowToOpen, !SWIFTUI_PREVIEW else {
                return
            }
            if window == "main", NSApp.windows.first(where: { $0.title == "Cling" }) != nil {
                return
            }

            openWindow(id: window)
            focus()
            NSApp.keyWindow?.orderFrontRegardless()
            wm.windowToOpen = nil
        }

        Window("Welcome to Cling", id: "onboarding") {
            OnboardingView()
                .background { WindowBackground() }
                .ignoresSafeArea()
                .environmentObject(envState)
        }
        .defaultSize(width: 560, height: 580)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
                .frame(minWidth: 600, minHeight: 600)
                .environmentObject(envState)
                .glassOrMaterial(cornerRadius: 0)
        }
        .defaultSize(width: 600, height: 600)
    }

    @State private var wm = WM

    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

}
