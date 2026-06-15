import Foundation
import AppKit
import WarpDrop

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

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

@MainActor final class SendManager: ObservableObject {
    static let shared = SendManager()
    @Published var sessions: [SendSession] = []          // active transfers
    @Published var recentSessions: [SendSession] = []    // session-only history (kept after stop/expiry, cleared on quit)
    @Published var connectingPaths: Set<String> = []     // in-flight guard against duplicate sends
    var expiryTimers: [String: Task<Void, Never>] = [:]  // auto-stop timers
    var pendingTasks: [String: Task<String, Error>] = [:]
}

extension SendManager {
    func send(files: [URL], expiration: TimeInterval) {
        guard !files.isEmpty else { return }
        let key = files.map(\.path).joined(separator: "|")
        guard !connectingPaths.contains(key) else { return }
        connectingPaths.insert(key)
        NotificationManager.shared.requestAuthorizationIfNeeded()

        let roomIDRef = Box<String?>(nil)
        let task = Task.detached {
            do {
                let client = WarpDropClient()
                return try await client.send(
                    files: files,
                    keep: true,
                    onRoomCreated: { roomID in
                        roomIDRef.value = roomID
                        Task { @MainActor in
                            SendManager.shared.roomCreated(roomID: roomID, files: files, expiration: expiration, key: key)
                        }
                    },
                    onDownloadCompleted: { count in
                        guard let roomID = roomIDRef.value else { return }
                        Task { @MainActor in SendManager.shared.didCompleteDownload(roomID: roomID, count: count) }
                    }
                )
            } catch {
                if roomIDRef.value == nil {
                    await MainActor.run {
                        SendManager.shared.connectingPaths.remove(key)
                        SendManager.shared.pendingTasks.removeValue(forKey: key)
                    }
                }
                throw error
            }
        }
        pendingTasks[key] = task
    }

    func roomCreated(roomID: String, files: [URL], expiration: TimeInterval, key: String) {
        connectingPaths.remove(key)
        guard let task = pendingTasks.removeValue(forKey: key) else { return }
        let expiresAt = expiration > 0 ? Date().addingTimeInterval(expiration) : nil
        let session = SendSession(id: roomID, files: files, task: task, expiresAt: expiresAt)
        sessions.append(session)
        recentSessions.insert(session, at: 0)
        session.copyLink()
        scheduleExpiry(session)
    }

    func scheduleExpiry(_ session: SendSession) {
        expiryTimers[session.id]?.cancel()
        guard let expiresAt = session.expiresAt else { return }
        let delay = max(0, expiresAt.timeIntervalSinceNow)
        let id = session.id
        expiryTimers[id] = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await MainActor.run {
                if let s = SendManager.shared.sessions.first(where: { $0.id == id }) {
                    SendManager.shared.stop(s)
                }
            }
        }
    }

    func reschedule(_ session: SendSession, to expiration: TimeInterval) {
        session.expiresAt = expiration > 0 ? Date().addingTimeInterval(expiration) : nil
        scheduleExpiry(session)
    }

    func stop(_ session: SendSession) {
        session.task.cancel()
        session.stopped = true
        expiryTimers[session.id]?.cancel()
        expiryTimers[session.id] = nil
        sessions.removeAll { $0.id == session.id }
        // session stays in recentSessions (session-only history)
    }

    func stopAll() { sessions.forEach { stop($0) } }

    func didCompleteDownload(roomID: String, count: Int) {
        guard let s = sessions.first(where: { $0.id == roomID }) else { return }
        s.downloadCount = count
        NotificationManager.shared.notifyDownload(fileNames: s.fileNames, count: count)
    }
}
