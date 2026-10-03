//
//  Created by Alin Panaitiu on 03.02.2025.
//

import AppKit
import Combine
import Defaults
import Lowtech
import LowtechIndie
import LowtechPro
import LowtechProSentry
import OSLog
import Paddle
import Sparkle
import SwiftUI
import System

private let log = Logger(subsystem: clingSubsystem, category: "ClingApp")

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

// MARK: - AppearanceManager

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

// MARK: - AppDelegate

@MainActor
class AppDelegate: LowtechProAppDelegate {
    static var shared: AppDelegate!

    /// Room kept between the search window and the edges of the usable area, when the window is small enough
    /// to leave it.
    static let screenPadding: CGFloat = 20

    var keepSettingsFrontUntil: Date?

    /// Picked when a summon starts and the window is still to be created: by the time it exists Cling has
    /// activated, and the frontmost app's focused window would be Cling's own.
    var pendingDisplay: NSScreen?

    var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "main" }
    }
    /// The Settings window's title tracks the selected sidebar item, so match on
    /// the stable SwiftUI scene identifier instead.
    var settingsWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "settings" }
    }

    @MainActor
    override func willShowPaddle(_ uiType: PADUIType, product _: PADProduct) -> PADDisplayConfiguration? {
        // Present the licence / product-access dialogs as a sheet on the Settings window (which hosts
        // the About sidebar item) when it is open, consistent with the other Lowtech apps. Standalone
        // Paddle windows were unclickable on macOS 27. Checkout and alerts keep their own window.
        if uiType == .product || uiType == .license, let settings = settingsWindow, settings.isVisible {
            SettingsNavigation.shared.selection = .about
            focus()
            settings.makeKeyAndOrderFront(nil)
            return PADDisplayConfiguration(.sheet, hideNavigationButtons: false, parentWindow: settings)
        }
        return PADDisplayConfiguration(.window, hideNavigationButtons: false, parentWindow: nil)
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
        migrateHiddenActionButtonsIfNeeded()
        hideOpenWithFromToolbarByDefault()
        assignFilterUUIDsIfNeeded()
        ClingShortcuts.setup()
        FUZZY.start()
        if !SWIFTUI_PREVIEW {
            CatchUpAgent.sync()
        }
        setupCleanup()
        QuickLookSupport.shared.warmUp()

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

            if Defaults[.enableSentry] {
                LowtechSentry.sentryDSN = "https://cb2335583d0612b61abb5d902ac97560@o84592.ingest.us.sentry.io/4511614814060544"
                LowtechSentry.configureSentry(restartOnHang: false, getUser: LowtechSentry.getSentryUser)
            }
        }

        super.applicationDidFinishLaunching(notification)

        KM.specialKey = Defaults[.enableGlobalHotkey] ? Defaults[.showAppKey] : nil
        KM.specialKeyModifiers = Defaults[.triggerKeys]
        KM.onSpecialHotkey = { [self] in
            toggleMainWindow(isFront: mainWindow?.isKeyWindow ?? false)
        }
        applyMenuBarIconSetting()
        pub(.showMenuBarIcon)
            .sink { [self] _ in
                mainAsync { self.applyMenuBarIconSetting() }
            }.store(in: &observers)
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
        // System and Root are only walked, loaded and followed with Pro, so they come and go with it.
        pro.$productActivated.combineLatest(pro.$onTrial)
            .map { $0 || $1 }
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { _ in FUZZY.syncScopeEngines() }
            .store(in: &observers)
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
            .filter { $0.identifier?.rawValue == "main" }
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
                pendingDisplay = displayForMainWindow()
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
        WM.noteActive()
        guard didBecomeActiveAtLeastOnce else {
            didBecomeActiveAtLeastOnce = true
            return
        }
//        log.debug("Became active")
        // Defer until the key window settles. If the app was activated by clicking
        // the Settings window, don't also pop the main search window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
            if let settings = settingsWindow, settings.isKeyWindow || settings.isMainWindow {
                return
            }
            focusWindow()
        }
    }

    override func applicationDidResignActive(_ notification: Notification) {
        WM.noteInactive()
        if WM.mainWindowActive, mainWindow?.isVisible == true {
            mainWindowLeftFrontAt = .now
        }
        let settingsVisible = settingsWindow?.isVisible ?? false
        log.debug("Resigned active: pinned=\(WM.pinned) keepOpen=\(Defaults[.keepWindowOpenWhenDefocused]) settingsVisible=\(settingsVisible)")
        // Keep the window fully visible while a sheet is attached (e.g. "Reindex excluded path"), so clicking
        // outside the app or dragging a file into the sheet doesn't dismiss the window and the sheet with it.
        if mainWindow?.attachedSheet != nil {
            log.debug("Skipping window hide: a sheet is attached to the main window")
            return
        }
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
        // Measured while the table is still laid out: outside instant mode the next window starts without one.
        _ = cursorAnchor(in: window)
        EVERYTHING.windowHidden()
        WM.noteInactive()
        FUZZY.cancelPendingSearch()
        if Defaults[.instantMode] {
            window.animationBehavior = .none
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.orderOut(nil)
            WM.mainWindowActive = false
        } else {
            window.close()
        }
    }

    /// Called after the main window is dismissed. If Settings is still open, keep
    /// Cling active and focus it; otherwise hand focus back to the previous app.
    /// Activating another app while Settings is open would wrongly defocus Cling.
    func handBackFocusAfterMainDismiss() {
        if let settings = settingsWindow, settings.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            settings.makeKeyAndOrderFront(nil)
        } else {
            APP_MANAGER.lastFrontmostApp?.activate()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        log.debug("Open URLs: \(String(describing: urls))")
        handleURLs(application, urls)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        log.debug("Open files: \(String(describing: filenames))")
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

    /// Summon or dismiss the search window. `isFront` decides which way the toggle goes: the
    /// window is only hidden when the user can already see it in front, so one that is open but
    /// behind another app comes forward first instead of disappearing.
    func toggleMainWindow(isFront: Bool) {
        if isFront, let mainWindow {
            WM.pinned = false
            mainWindow.resignKey()
            mainWindow.resignMain()
            hideOrCloseMainWindow(mainWindow)
            handBackFocusAfterMainDismiss()
        } else if Defaults[.instantMode], mainWindow != nil {
            focusWindow()
        } else {
            pendingDisplay = displayForMainWindow()
            WM.open("main")
            focusWindow()
            focus()
        }
    }

    func applyMenuBarIconSetting() {
        guard Defaults[.showMenuBarIcon] else {
            if let menuBarItem {
                NSStatusBar.system.removeStatusItem(menuBarItem)
                self.menuBarItem = nil
            }
            return
        }
        guard menuBarItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "doc.text.magnifyingglass",
            accessibilityDescription: "Cling"
        )
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "Show or hide Cling"
        item.button?.target = self
        item.button?.action = #selector(menuBarIconClicked)
        menuBarItem = item
    }

    @objc func menuBarIconClicked() {
        // Clicking a status item sends the app to the background first, and in utility mode that
        // deactivation already hid the window by the time this runs. Without the grace window the
        // click meant to dismiss Cling would find an empty screen and summon it straight back.
        let leftFrontForThisClick = mainWindowLeftFrontAt
            .map { Date.now.timeIntervalSince($0) < Self.menuBarClickGrace } ?? false
        log.debug("Menu bar click: frontmost=\(self.mainWindowIsFrontmost) leftFront=\(leftFrontForThisClick) visible=\(self.mainWindow?.isVisible ?? false)")

        guard !mainWindowIsFrontmost, !leftFrontForThisClick else {
            mainWindowLeftFrontAt = nil
            // Already gone if the deactivation got there first; otherwise dismiss it now.
            if let mainWindow, mainWindow.isVisible {
                toggleMainWindow(isFront: true)
            }
            return
        }
        toggleMainWindow(isFront: false)
    }

    func focusWindow() {
        DropZoneOverlay.shared.dismissIfPresenting()
        guard let window = mainWindow else { return }
        if !window.isVisible || window.alphaValue == 0 {
            placeMainWindow(window, on: pendingDisplay ?? displayForMainWindow())
        }
        pendingDisplay = nil
        EVERYTHING.windowShown()
        window.collectionBehavior.insert(.moveToActiveSpace)
        if Defaults[.instantMode] {
            window.animationBehavior = .none
            window.ignoresMouseEvents = false
            window.alphaValue = 1
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    /// The display the search window should come up on, per Settings > General. Read before Cling activates.
    func displayForMainWindow() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        let underCursor = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        switch Defaults[.windowDisplay] {
        case .cursor: return underCursor
        case .main: return NSScreen.screens.first
        case .focusedWindow: return focusedWindowScreen() ?? underCursor
        }
    }

    /// Moves a hidden search window onto `screen`. With *Open at the cursor* it comes up with the pointer over
    /// the first row's name, every time. Otherwise it takes the spot of the usable area it had on its previous
    /// display, and a window already on that display keeps the frame it was given there. Either way it stays
    /// inside the usable area (no menu bar or Dock), with `screenPadding` to spare where it fits and the whole
    /// span where it doesn't.
    func placeMainWindow(_ window: NSWindow, on screen: NSScreen?) {
        guard let screen else { return }
        let area = screen.visibleFrame
        let size = window.frame.size
        if Defaults[.windowDisplay] == .cursor, Defaults[.windowAtCursor] {
            let mouse = NSEvent.mouseLocation
            let anchor = cursorAnchor(in: window)
            let origin = CGPoint(x: mouse.x - anchor.x, y: mouse.y - anchor.y)
            window.setFrame(Self.frame(size, origin: origin, in: area), display: false)
            return
        }

        let current = Self.screen(containing: window.frame)
        guard current?.frame != screen.frame else { return }
        // Where the window's centre sat, as a fraction of the old display's usable area.
        var center = CGPoint(x: area.midX, y: area.midY)
        if let from = current?.visibleFrame, from.width > 0, from.height > 0 {
            center.x = area.minX + (window.frame.midX - from.minX) / from.width * area.width
            center.y = area.minY + (window.frame.midY - from.minY) / from.height * area.height
        }
        let origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        window.setFrame(Self.frame(size, origin: origin, in: area), display: false)
    }

    /// A freshly created search window, moved to the display picked when the summon started.
    func placeNewMainWindow() {
        guard let display = pendingDisplay, let window = mainWindow else { return }
        pendingDisplay = nil
        placeMainWindow(window, on: display)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        if #available(macOS 26, *) {
            UserDefaults.standard.register(defaults: ["NSAutoFillHeuristicControllerEnabled": false])
        }

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

        DropZoneOverlay.shared.dismissIfPresenting()
        if let mainWindow {
            mainWindow.orderFrontRegardless()
            mainWindow.becomeMain()
            mainWindow.becomeKey()
            focus()
        } else {
            pendingDisplay = displayForMainWindow()
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
        guard let window = notification.object as? NSWindow else { return }
        if window.identifier?.rawValue == "main" {
            WM.mainWindowActive = false
            WM.noteInactive()
            handBackFocusAfterMainDismiss()
        } else if window.identifier?.rawValue == "settings" {
            // Restore the user's configured policy once Settings closes.
            NSApp.setActivationPolicy(Defaults[.showDockIcon] ? .regular : .accessory)
        }
    }
    @objc func windowDidBecomeMain(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window.identifier?.rawValue == "main" {
            placeNewMainWindow()
        }

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

        if window.identifier?.rawValue == "settings" {
            // Settings deserves a real menu bar and proper window management, so run
            // as a regular app while it's open (reverted in windowWillClose).
            NSApp.setActivationPolicy(.regular)
            if !settingsWindowConfigured {
                settingsWindowConfigured = true
                window.toolbar?.showsBaselineSeparator = false
                // The window keeps a "Settings" title (set via navigationTitle) so it reads
                // correctly in the Window menu / Mission Control, but we don't want the text
                // drawn in the titlebar.
                window.titleVisibility = .hidden
            }
        }

        if window.identifier?.rawValue == "main" {
            WM.mainWindowActive = true
            WM.noteActive()
            FUZZY.refreshDefaultResultsIfNeeded()

            window.alphaValue = 1
            // Undo the click-through state set while hidden, otherwise a window shown
            // again via dock reopen swallows nothing and clicks fall through to Settings.
            window.ignoresMouseEvents = false
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
        }
    }
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        cleanup()
    }

    func allowedChannels(for _: SPUUpdater) -> Set<String> {
        lowtechAllowedChannels()
    }

    /// How long after the app goes to the background a status item click still counts as the
    /// click that sent it there. A single click covers a few milliseconds; anything slower is
    /// the user coming back to Cling and wanting it summoned.
    private static let menuBarClickGrace: TimeInterval = 0.35

    /// Last measured spot of the first row's name, from the window's bottom-left corner. A window created a
    /// moment ago has no table laid out yet, so it borrows the previous window's.
    private var lastCursorAnchor: CGPoint?

    private var menuBarItem: NSStatusItem?
    /// When the search window last stopped being the front window because the app went to the
    /// background. Read by the menu bar click to tell "dismiss this" from "summon this".
    private var mainWindowLeftFrontAt: Date?
    private var windowConfigured = false
    private var settingsWindowConfigured = false
    private var mainWindowDelegateProxy: MainWindowDelegateProxy?

    private var resizeCancellable: AnyCancellable?

    /// Whether the search window is the one the user is looking at right now. Clicking a status
    /// item doesn't activate the app, so key-window state can already have moved by the time this
    /// runs; app activation plus visibility survives that. Settings being key means the search
    /// window is behind it, so it counts as not in front.
    private var mainWindowIsFrontmost: Bool {
        guard let mainWindow, mainWindow.isVisible, NSApp.isActive else { return false }
        if let settings = settingsWindow, settings.isVisible, settings.isKeyWindow {
            return false
        }
        return true
    }

    private static func frame(_ size: CGSize, origin: CGPoint, in area: NSRect) -> NSRect {
        let x = fit(size.width, origin: origin.x, from: area.minX, to: area.maxX)
        let y = fit(size.height, origin: origin.y, from: area.minY, to: area.maxY)
        return NSRect(x: x.origin, y: y.origin, width: x.length, height: y.length)
    }

    /// One axis of a placement: `length` starting at `origin`, pushed back inside `lo...hi` with up to
    /// `screenPadding` left at each end. Padding shrinks evenly when the window nearly fills the span, and a
    /// window that needs more than the span gets exactly the span.
    private static func fit(_ length: CGFloat, origin: CGFloat, from lo: CGFloat, to hi: CGFloat) -> (origin: CGFloat, length: CGFloat) {
        let span = hi - lo
        guard length < span else { return (lo, span) }
        let pad = min(screenPadding, (span - length) / 2)
        return (min(max(origin, lo + pad), hi - pad - length), length)
    }

    private static func screen(containing rect: NSRect) -> NSScreen? {
        func overlap(_ s: NSScreen) -> CGFloat {
            let r = s.frame.intersection(rect)
            return r.isNull ? 0 : r.width * r.height
        }
        guard let best = NSScreen.screens.max(by: { overlap($0) < overlap($1) }), overlap(best) > 0 else { return nil }
        return best
    }

    /// Where the pointer should land in the search window: a little into the name of the topmost visible row,
    /// stash or results, measured from the live table so toolbar rows, the stash and text size all count.
    private func cursorAnchor(in window: NSWindow) -> CGPoint {
        let registry = TableRegistry.shared
        if let table = registry.stashTableView ?? registry.headerTableView, table.window === window,
           table.numberOfColumns > 0
        {
            let column = table.tableColumns.firstIndex { $0.title == "Name" } ?? min(1, table.numberOfColumns - 1)
            let row = max(table.rows(in: table.visibleRect).location, 0)
            let rowRect = table.rect(ofRow: row).isEmpty
                ? NSRect(x: 0, y: table.visibleRect.minY, width: table.bounds.width, height: table.rowHeight)
                : table.rect(ofRow: row)
            let columnRect = table.rect(ofColumn: column)
            let point = NSPoint(x: columnRect.minX + min(48, columnRect.width / 3), y: rowRect.midY)
            let anchor = table.convert(point, to: nil)
            lastCursorAnchor = anchor
            return anchor
        }
        // First summon of a new window: roughly the first row's name below the search bar.
        return lastCursorAnchor ?? CGPoint(x: 150, y: window.frame.height - 150)
    }

    /// The display holding most of the frontmost app's front window. The window server gives out window
    /// bounds without any permission (only titles need Screen Recording).
    private func focusedWindowScreen() -> NSScreen? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            // Cling itself is in front, Settings for one: its key window decides, unless that is the hidden search window.
            guard let key = NSApp.keyWindow, key !== mainWindow else { return nil }
            return Self.screen(containing: key.frame)
        }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let front = windows.first(where: {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0
        }),
            let bounds = front[kCGWindowBounds as String] as? NSDictionary,
            let rect = CGRect(dictionaryRepresentation: bounds)
        else { return nil }
        // Window server rects are flipped, with the origin at the top left of the main display.
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return Self.screen(containing: NSRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height))
    }

}

// MARK: - MainWindowDelegateProxy

final class MainWindowDelegateProxy: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) {
            return true
        }
        return original?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated {
            guard Defaults[.instantMode] else {
                return original?.windowShouldClose?(sender) ?? true
            }
            WM.pinned = false
            AppDelegate.shared?.hideOrCloseMainWindow(sender)
            AppDelegate.shared?.handBackFocusAfterMainDismiss()
            return false
        }
    }

}

// MARK: - WindowManager

@MainActor @Observable
class WindowManager {
    static let DEFAULT_SIZE = CGSize(width: 1150, height: 850)

    var windowToOpen: String?
    var size = DEFAULT_SIZE
    var pinned = false

    var mainWindowActive = false

    /// Bumped when the app comes back after being away long enough for the result selection to
    /// count as stale. Observed by ContentView, which then jumps the selection back to the top.
    var selectionResetToken = 0

    /// Roughly a third of the table's width, clamped so it stays usable. Lives here rather than in
    /// ContentView because the filter discovery row lines its divider up with the same seam, so the
    /// window keeps one vertical split at any size.
    static func previewWidth(forWindowWidth width: CGFloat) -> CGFloat {
        min(max((width - 32) * 0.26, 300), 520)
    }

    /// The app went to the background or the main window was hidden/closed.
    func noteInactive() {
        guard inactiveSince == nil else { return }
        inactiveSince = .now
    }

    /// The app came back. Ask for a selection reset if we were away for longer than the setting.
    func noteActive() {
        guard let since = inactiveSince else { return }
        inactiveSince = nil
        let timeout = Defaults[.resetSelectionAfter]
        guard timeout > 0, Date.now.timeIntervalSince(since) >= timeout else { return }
        selectionResetToken &+= 1
    }

    func open(_ window: String) {
        if window == "main", NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) != nil {
            focus()
            AppDelegate.shared?.focusWindow()
            if windowToOpen != nil {
                windowToOpen = nil
            }
            return
        }
        windowToOpen = window
    }

    /// When the app last went to the background or hid its window.
    private var inactiveSince: Date?
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

// MARK: - WindowBackground

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

// MARK: - ClingApp

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
            // The Settings scene used to provide this automatically; recreate it for the Window scene.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    WM.open("settings")
                }
                .keyboardShortcut(",", modifiers: .command)
            }
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
            if window == "main", NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) != nil {
                return
            }

            openWindow(id: window)
            if window == "main" {
                AppDelegate.shared?.placeNewMainWindow()
            }
            focus()
            if window == "settings" {
                AppDelegate.shared?.settingsWindow?.makeKeyAndOrderFront(nil)
            }
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

        // A regular Window (not the Settings scene): the Settings scene's hosting view pins its size
        // to the content's intrinsic size, so it can never be resized. A Window resizes normally.
        Window("Settings", id: "settings") {
            SettingsView()
                .environmentObject(envState)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 920, height: 640)
    }

    @State private var wm = WM

    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

}
