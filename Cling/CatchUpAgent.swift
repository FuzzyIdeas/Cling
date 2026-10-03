import Defaults
import Foundation
import OSLog
import ServiceManagement

private let log = Logger(subsystem: clingSubsystem, category: "CatchUpAgent")

// MARK: - CatchUpAgent

/// The launchd agent that gathers file changes while Cling is closed (`cling catch-up`, see ClingCLI/CatchUp.swift),
/// registered from the app bundle so it goes wherever Cling goes and is listed under Login Items in System Settings.
enum CatchUpAgent {
    static let service = SMAppService.agent(plistName: "com.lowtechguys.Cling.catch-up.plist")

    /// Registers or unregisters the agent to match the setting. One the user turned off in System Settings is left
    /// that way.
    static func sync() {
        #if DEBUG
            // A development build lives in a temporary folder the agent would outlive.
            return
        #else
            do {
                switch (Defaults[.updateWhileClosed], service.status) {
                case (true, .notRegistered), (true, .notFound):
                    try service.register()
                    log.info("Catch-up agent registered")
                case (false, .enabled), (false, .requiresApproval):
                    try service.unregister()
                    log.info("Catch-up agent unregistered")
                default:
                    break
                }
            } catch {
                log.error("Catch-up agent: \(error.localizedDescription)")
            }
        #endif
    }
}
