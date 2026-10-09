import AppKit

// MARK: - Launchers

/// Cling's Alfred workflow and Raycast extension, offered in Settings > General. The workflow ships inside the app
/// (zipped from `Alfred/` at build time) and Alfred imports it from there. The extension lives in the Raycast Store,
/// so its button only opens its page.
enum Launchers {
    static let alfredWorkflow = Bundle.main.url(forResource: "Cling", withExtension: "alfredworkflow")
    static let alfredSite = URL(string: "https://www.alfredapp.com")!
    static let raycastStorePage = URL(string: "https://www.raycast.com/alin/cling")!
    static let raycastDeepLink = URL(string: "raycast://extensions/alin/cling")!

    /// Whether something on this Mac imports `.alfredworkflow` files, which is Alfred's preferences app.
    static var canInstallAlfredWorkflow: Bool {
        alfredWorkflow.flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) } != nil
    }

    static func installAlfredWorkflow() {
        guard let alfredWorkflow else { return }
        NSWorkspace.shared.open(alfredWorkflow)
    }

    /// The store page inside Raycast when it is installed, which has the Install button, otherwise on the web.
    static func openRaycastExtension() {
        let raycastInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.raycast.macos") != nil
        NSWorkspace.shared.open(raycastInstalled ? raycastDeepLink : raycastStorePage)
    }
}
