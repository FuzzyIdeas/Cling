import Foundation
import AppKit

let LINK_EXPIRATION_PRESETS: [TimeInterval] = [60, 120, 300, 600, 900, 1800, 2700, 3600, 7200, 10800, 21600, 43200, 86400, 172800, 259200]
let LINK_EXPIRATION_NEVER: TimeInterval = 0

func nearestExpirationPresetIndex(_ value: TimeInterval) -> Int {
    guard value > 0 else { return 0 }
    return LINK_EXPIRATION_PRESETS.enumerated().min { abs($0.element - value) < abs($1.element - value) }?.offset ?? 0
}

func expirationDurationLabel(_ seconds: TimeInterval) -> String {
    guard seconds > 0 else { return "never" }
    let s = Int(seconds.rounded())
    switch s {
    case ..<3600:  let m = s / 60;    return "\(m) minute\(m == 1 ? "" : "s")"
    case ..<86400: let h = s / 3600;  return "\(h) hour\(h == 1 ? "" : "s")"
    default:       let d = s / 86400; return "\(d) day\(d == 1 ? "" : "s")"
    }
}

func expirationShortLabel(_ seconds: TimeInterval) -> String {
    guard seconds > 0 else { return "∞" }
    let s = Int(seconds.rounded())
    switch s {
    case ..<3600:  return "\(s / 60)m"
    case ..<86400: return "\(s / 3600)h"
    default:       return "\(s / 86400)d"
    }
}

@MainActor final class SendSession: ObservableObject, Identifiable {
    let id: String
    let files: [URL]
    let task: Task<String, Error>
    @Published var downloadCount = 0
    @Published var expiresAt: Date?
    @Published var stopped = false

    init(id: String, files: [URL], task: Task<String, Error>, expiresAt: Date?) {
        self.id = id; self.files = files; self.task = task; self.expiresAt = expiresAt
    }

    var directURL: String { "https://drop.lowtechguys.com/d/\(id)" }
    var roomURL: String { "https://drop.lowtechguys.com/r/\(id)" }
    var shareURL: String { files.count == 1 ? directURL : roomURL }
    var fileNames: String { files.map(\.lastPathComponent).joined(separator: ", ") }
    var expiresInLabel: String? {
        guard let expiresAt else { return nil }
        let r = expiresAt.timeIntervalSinceNow
        return r > 0 ? "Expires in \(expirationDurationLabel(r))" : "Expiring now"
    }

    func copyLink() {
        let pb = NSPasteboard.general; pb.clearContents(); pb.setString(shareURL, forType: .string)
    }
}

@MainActor final class SendManager: ObservableObject {
    static let shared = SendManager()
    @Published var sessions: [SendSession] = []          // active transfers
    @Published var recentSessions: [SendSession] = []    // session-only history (kept after stop/expiry, cleared on quit)
    @Published var connectingPaths: Set<String> = []     // in-flight guard against duplicate sends
    var expiryTimers: [String: Task<Void, Never>] = [:]  // auto-stop timers (used by a later task)
}
