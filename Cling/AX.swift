import ApplicationServices
import Cocoa
import Combine
import Lowtech
import System

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
