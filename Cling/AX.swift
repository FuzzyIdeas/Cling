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
            log.warning("[DropFocused] no resolvable AX target for \(appName, privacy: .public)")
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
