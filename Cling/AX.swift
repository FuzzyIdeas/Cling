import ApplicationServices
import Cocoa
import Combine
import Lowtech
import OSLog
import System

private let log = Logger(subsystem: clingSubsystem, category: "AX")

// MARK: - AppManager

@Observable
class AppManager {
    init() {
        cancellable = NSWorkspace.shared.publisher(for: \.frontmostApplication)
            .sink { [self] app in
                if app?.bundleIdentifier != Bundle.main.bundleIdentifier {
                    lastFrontmostApp = app
                }
            }
    }

    var frontmostAppIsTerminal: Bool {
        guard let name = lastFrontmostApp?.name else {
            return false
        }
        return name.contains(/tty|term/.ignoresCase())
    }

    var lastFrontmostApp: NSRunningApplication? {
        didSet {
//            log.debug("lastFrontmostApp: \(lastFrontmostApp?.localizedName ?? "nil")")
        }
    }

    func dropToZone(paths: [FilePath]) {
        guard checkAccessibilityPermissions() else {
            requestAccessibilityPermissions()
            return
        }
        let urls = paths.map(\.url)
        Task { @MainActor in
            DropZoneOverlay.shared.present(
                onSelect: { point in
                    if let win = AppDelegate.shared.mainWindow {
                        AppDelegate.shared.hideOrCloseMainWindow(win)
                    }
                    let targetApp = appAtCGPoint(point)
                    targetApp?.activate()
                    mainAsyncAfter(ms: 60) {
                        DragDropSimulator.shared.performDrop(fileURLs: urls, to: point, activating: targetApp)
                    }
                },
                onCancel: {}
            )
        }
    }

    func axDropTarget(for app: NSRunningApplication) -> AXDropTarget? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let appName = app.name ?? app.localizedName ?? "app"

        // Try the focused UI element first (text fields, editors, etc.)
        if let focused = axCopy(appElement, kAXFocusedUIElementAttribute) {
            // Some apps return the window itself as "focused element" — accept it later, not here.
            let role = axCopyString(focused, kAXRoleAttribute) ?? ""
            if role != kAXWindowRole as String, let frame = axFrame(focused) {
                let label = axCopyString(focused, kAXRoleDescriptionAttribute)
                    ?? axCopyString(focused, kAXDescriptionAttribute)
                    ?? "input"
                return AXDropTarget(point: CGPoint(x: frame.midX, y: frame.midY), name: truncated("\(appName) \(label)"), frame: frame)
            }
        }

        // Fall back to the focused window's center.
        if let window = axCopy(appElement, kAXFocusedWindowAttribute), let frame = axFrame(window) {
            let title = axCopyString(window, kAXTitleAttribute) ?? "window"
            return AXDropTarget(point: CGPoint(x: frame.midX, y: frame.midY), name: truncated("\(appName) (\(title))"), frame: frame)
        }

        return nil
    }

    func dropToFocusedElement(paths: [FilePath]) {
        guard checkAccessibilityPermissions() else {
            requestAccessibilityPermissions()
            return
        }
        guard let app = lastFrontmostApp, let target = axDropTarget(for: app) else {
            let appName = lastFrontmostApp?.name ?? "nil"
            log.warning("[DropFocused] no resolvable AX target for \(appName)")
            return
        }
        let urls = paths.map(\.url)

        // If the cursor is already inside the resolved element, respect that precise spot —
        // useful for dropping at a specific location inside an editor / canvas.
        let nsCursor = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cursorCG = CGPoint(x: nsCursor.x, y: primaryHeight - nsCursor.y)
        let point = target.frame.contains(cursorCG) ? cursorCG : target.point

        Task { @MainActor in
            if let win = AppDelegate.shared.mainWindow {
                AppDelegate.shared.hideOrCloseMainWindow(win)
            }
            app.activate()
            mainAsyncAfter(ms: 60) {
                DragDropSimulator.shared.performDrop(fileURLs: urls, to: point, activating: app)
            }
        }
    }

    func pasteToFrontmostApp(paths: [FilePath], separator: String, quoted: Bool) {
        guard checkAccessibilityPermissions() else {
            requestAccessibilityPermissions()
            return
        }

        let data = paths
            .map { quoted ? "\"\($0.string)\"" : $0.string }
            .joined(separator: separator)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(data, forType: .string)
        pasteboard.setString(data, forType: .transient)

        let source = CGEventSource(stateID: .hidSystemState)
        let keyVDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyVUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyVDown?.flags = .maskCommand

        lastFrontmostApp?.activate()
        keyVDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyVUp?.post(tap: .cgAnnotatedSessionEventTap)
    }

    private var cancellable: AnyCancellable?

    private func truncated(_ s: String, max: Int = 32) -> String {
        s.count <= max ? s : s.prefix(max - 1) + "…"
    }

}

let APP_MANAGER = AppManager()

private func checkAccessibilityPermissions() -> Bool {
    let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
    return AXIsProcessTrustedWithOptions(options)
}

private func requestAccessibilityPermissions() {
    let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
    AXIsProcessTrustedWithOptions(options)
}

extension NSPasteboard.PasteboardType {
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
}

// MARK: - AXDropTarget

struct AXDropTarget {
    let point: CGPoint
    let name: String
    let frame: CGRect
}

private func axCopy(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
          let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

private func axCopyString(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
          let value else { return nil }
    return value as? String
}

/// Lightweight, permission-free heuristic for "is the active space a fullscreen space?".
///
/// A green-button fullscreen window fills the display *below* the menu-bar line: its bounds start
/// at the menu-bar height (not y=0 — the menu-bar strip stays outside the window even though it
/// auto-hides) and run to the very bottom edge, spanning the full width with no Dock gap (the Dock
/// auto-hides too). Ordinary/zoomed windows don't reach the bottom edge when the Dock is shown.
/// So if the display under the cursor carries an on-screen, layer-0 window from another app with
/// that signature, treat the active space as fullscreen. Uses only CGWindowList (same API as
/// `appAtCGPoint`), so it needs no extra permission and no private SkyLight calls.
@MainActor
func isActiveSpaceFullscreen() -> Bool {
    let screens = NSScreen.screens
    guard let primaryHeight = screens.first?.frame.height else { return false }

    /// CGWindowList reports bounds with a top-left origin on the primary display; convert each
    /// NSScreen's (bottom-left) frame into that space so we can compare like-for-like.
    func cgFrame(_ s: NSScreen) -> CGRect {
        CGRect(x: s.frame.minX, y: primaryHeight - s.frame.maxY, width: s.frame.width, height: s.frame.height)
    }

    // The active display is the one under the cursor — that's where `.moveToActiveSpace` lands the
    // window, so it's the only display whose fullscreen state matters for this summon.
    let mouse = NSEvent.mouseLocation
    let mouseCG = CGPoint(x: mouse.x, y: primaryHeight - mouse.y)
    guard let activeScreen = screens.first(where: { cgFrame($0).contains(mouseCG) }) ?? NSScreen.main ?? screens.first else {
        return false
    }
    let target = cgFrame(activeScreen)
    // Top inset of the active display = menu-bar height. A fullscreen window's top edge sits on
    // this line; a borderless fullscreen window may instead start at y=0, so allow either.
    let menuBarH = max(0, activeScreen.frame.maxY - activeScreen.visibleFrame.maxY)

    let myPID = ProcessInfo.processInfo.processIdentifier
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let infoList = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
        return false
    }
    for info in infoList {
        // Only ordinary app windows (layer 0); skip our own and system/menu-bar layers.
        guard (info[kCGWindowLayer as String] as? Int ?? 0) == 0 else { continue }
        if (info[kCGWindowOwnerPID as String] as? pid_t ?? 0) == myPID { continue }
        guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
        let rect = CGRect(
            x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
            width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0
        )
        // Fullscreen signature: full width, top at the menu-bar line (or y=0), bottom at the
        // display edge.
        if abs(rect.minX - target.minX) <= 2, rect.width >= target.width - 2,
           rect.minY <= menuBarH + 4, rect.maxY >= target.maxY - 2
        {
            return true
        }
    }
    return false
}

func appAtCGPoint(_ point: CGPoint) -> NSRunningApplication? {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let infoList = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return nil }
    let myPID = ProcessInfo.processInfo.processIdentifier
    for info in infoList {
        let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
        if pid == myPID { continue }
        guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
        let x = bounds["X"] ?? 0
        let y = bounds["Y"] ?? 0
        let w = bounds["Width"] ?? 0
        let h = bounds["Height"] ?? 0
        if CGRect(x: x, y: y, width: w, height: h).contains(point) {
            return NSRunningApplication(processIdentifier: pid)
        }
    }
    return nil
}

private func axFrame(_ element: AXUIElement) -> CGRect? {
    var posValue: AnyObject?
    var sizeValue: AnyObject?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
          let posValue, let sizeValue,
          CFGetTypeID(posValue) == AXValueGetTypeID(),
          CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
    var pos = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(posValue as! AXValue, .cgPoint, &pos),
          AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
          size.width > 1, size.height > 1 else { return nil }
    return CGRect(origin: pos, size: size)
}
