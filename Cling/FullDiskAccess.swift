import AppKit
import Foundation
import OSLog
import UniformTypeIdentifiers

// A helper for managing Full Disk Access (FDA). An app that's granted FDA can access other apps' containers.
// Checking whether FDA is granted will add the app to the FDA entries in Privacy & Security (an exception to that is
// macOS 10.14 for which we cannot automatically add the entry)

public enum FullDiskAccess {
    /// Checks and returns the status of Full Disk Access for the current app. Accessing this property automatically
    /// adds the current app to the Full Disk Access entries in Privacy & Security.
    public static var isGranted: Bool {
        guard !appIsSandboxed else {
            os_log(.error, log: .fullDiskAccess, "isGranted will always return false in a sandboxed app.")
            return false
        }

        let checkPath = switch currentOS {
        case .monterey, .ventura, .sonoma, .sequoia, .tahoe:
            "~/Library/Containers/com.apple.stocks"
        case .mojave, .catalina, .bigSur:
            "~/Library/Safari"
        }

        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: expandedPath(checkPath))
            os_log(.debug, log: .fullDiskAccess, "Full Disk Access is granted (able to read %@)", checkPath)
            return true
        } catch {
            os_log(.debug, log: .fullDiskAccess, "Full Disk Access is not granted (Unable to read %@)", checkPath)
            return false
        }
    }

    /// Opens the System Settings (aka System Preferences) with the Privacy & Security preference pane open and the
    /// Full Disk Access tab pre-selected.
    public static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    /// Displays an alert to the user if Full Disk Access is not granted to the current app, with the option to open
    /// the Privacy & Security preference pane or skip.
    public static func promptIfNotGranted(
        title: String,
        message: String,
        settingsButtonTitle: String = "Open Settings",
        skipButtonTitle: String = "Later",
        canBeSuppressed: Bool = false,
        icon: NSImage? = nil
    ) {
        guard !canBeSuppressed || !promptSuppressed else {
            // Prompt has been suppressed by the user because they checked "Do not ask again."
            os_log(.debug, log: .fullDiskAccess, "Prompt has not appeared because it has been suppressed by the user")
            return
        }

        guard !appIsSandboxed else {
            // Sandboxed app cannot gain FDA
            os_log(.error, log: .fullDiskAccess, "Prompt has not appeared because the app is sandboxed")
            return
        }

        guard !isGranted else {
            // Granted app doesn't need it
            os_log(.debug, log: .fullDiskAccess, "Prompt has not appeared because Full Disk Access is already granted")
            return
        }

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.icon = icon ?? alertIcon()

        if canBeSuppressed {
            alert.showsSuppressionButton = true
        }

        alert.addButton(withTitle: settingsButtonTitle)
        alert.addButton(withTitle: skipButtonTitle)

        let response = alert.runModal()

        if alert.suppressionButton?.state == .on {
            promptSuppressed = true
        }

        switch response {
        case .alertFirstButtonReturn:
            // Settings button
            openSystemSettings()
        case .alertSecondButtonReturn:
            // Skip button
            return
        default:
            return
        }
    }

    /// Resets the prompt suppression (i.e. if the user has selected "Do not ask again.", this resets their choice)
    public static func resetPromptSuppression() {
        promptSuppressed = false
    }

    private enum MacOS {
        case mojave // 10.14
        case catalina // 10.15
        case bigSur // 11
        case monterey // 12
        case ventura // 13
        case sonoma // 14
        case sequoia // 15
        case tahoe // 16
    }

    private static var currentOS: MacOS {
        if #available(macOS 16, *) {
            .tahoe
        } else if #available(macOS 15, *) {
            .sequoia
        } else if #available(macOS 14, *) {
            .sonoma
        } else if #available(macOS 13, *) {
            .ventura
        } else if #available(macOS 12, *) {
            .monterey
        } else if #available(macOS 11, *) {
            .bigSur
        } else if #available(macOS 10.15, *) {
            .catalina
        } else {
            .tahoe
        }
    }

}

extension FullDiskAccess {
    private static var appIsSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    private static var promptSuppressed: Bool {
        get {
            UserDefaults.standard.bool(forKey: "fda_suppressed") ?? false
        }
        set {
            UserDefaults.standard.setValue(newValue, forKey: "fda_suppressed")
        }
    }

    private static func expandedPath(_ path: String) -> String {
        guard let pw = getpwuid(getuid()) else { return path }
        let homeURL = URL(fileURLWithFileSystemRepresentation: pw.pointee.pw_dir, isDirectory: true, relativeTo: nil)
        return path.replacingOccurrences(of: "~", with: homeURL.path)
    }

    private static func alertIcon() -> NSImage? {
        guard let appIconImage = NSApp.applicationIconImage else {
            return NSImage(named: "NSInfo")
        }

        // Draw the app icon with a badge (privacy icon or info icon if unavailable)
        let appIconInset: CGFloat = 4
        let badgeImage: NSImage?
        let badgeSize: CGSize?
        let badgeDrawingScale: CGFloat

        if #available(macOS 13.0, *), let privacyPrefPaneType = UTType("com.apple.graphic-icon.privacy") {
            let privacyIcon = NSWorkspace.shared.icon(for: privacyPrefPaneType)
            badgeImage = privacyIcon
            badgeSize = privacyIcon.size
            badgeDrawingScale = 1.8
        } else {
            badgeImage = NSImage(named: "NSInfo")
            badgeSize = nil
            badgeDrawingScale = 0.45
        }

        return NSImage(size: appIconImage.size, flipped: false) { drawRect in
            appIconImage.draw(in: drawRect.insetBy(dx: appIconInset, dy: appIconInset))

            // Draw the badge
            if let badgeImage {
                let size = badgeSize ?? drawRect.size
                let badgeRect = NSRect(
                    x: drawRect.size.width - (size.width * badgeDrawingScale),
                    y: 0,
                    width: size.width * badgeDrawingScale,
                    height: size.height * badgeDrawingScale
                )
                badgeImage.draw(in: badgeRect)
            }

            return true
        }
    }
}

private extension OSLog {
    static let fullDiskAccess = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "FDA",
        category: "FullDiskAccess"
    )
}
