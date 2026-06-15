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
    var tempArchives: [URL]
    @Published var downloadCount = 0
    @Published var expiresAt: Date?
    @Published var stopped = false

    init(id: String, files: [URL], task: Task<String, Error>, expiresAt: Date?, tempArchives: [URL] = []) {
        self.id = id; self.files = files; self.task = task; self.expiresAt = expiresAt; self.tempArchives = tempArchives
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

struct PendingSend: Equatable { let files: [URL]; let expiration: TimeInterval }

@MainActor final class SendManager: ObservableObject {
    static let shared = SendManager()
    @Published var sessions: [SendSession] = []          // active transfers
    @Published var recentSessions: [SendSession] = []    // session-only history (kept after stop/expiry, cleared on quit)
    @Published var connectingPaths: Set<String> = []     // in-flight guard against duplicate sends
    @Published var linkCopiedTick = 0                    // incremented each time a new link is auto-copied
    @Published var pendingFolderConfirm: PendingSend?    // deferred send awaiting folder-archive confirmation
    var expiryTimers: [String: Task<Void, Never>] = [:]  // auto-stop timers
    var pendingTasks: [String: Task<String, Error>] = [:]
}

extension SendManager {
    // MARK: - Directory helpers

    func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    func folderCount(in files: [URL]) -> Int { files.filter { isDirectory($0) }.count }

    // MARK: - Confirmation gate

    /// Entry point used by the UI. If the selection contains folders, defer to a confirmation;
    /// otherwise send immediately.
    func requestSend(files: [URL], expiration: TimeInterval) {
        guard !files.isEmpty else { return }
        if folderCount(in: files) > 0 {
            pendingFolderConfirm = PendingSend(files: files, expiration: expiration)
        } else {
            send(files: files, expiration: expiration)
        }
    }

    func confirmPendingSend() {
        guard let p = pendingFolderConfirm else { return }
        pendingFolderConfirm = nil
        send(files: p.files, expiration: p.expiration)
    }

    func cancelPendingSend() { pendingFolderConfirm = nil }

    // MARK: - Zip helper (nonisolated — runs off-main inside detached tasks)

    nonisolated static func archive(folder: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClingSend-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let archiveURL = dir.appendingPathComponent(folder.lastPathComponent + ".zip")

        // Primary: bundled 7zz (attribute-preserving)
        let sevenZipURL = SEVEN_ZIP.url
        let p = Process()
        p.executableURL = sevenZipURL
        p.currentDirectoryURL = folder.deletingLastPathComponent()
        p.arguments = ["a", "-tzip", "-bd", "-bso0", "-bsp0", archiveURL.path, folder.lastPathComponent]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        if p.terminationStatus == 0, FileManager.default.fileExists(atPath: archiveURL.path) {
            return archiveURL
        }

        // Fallback: ditto (attribute-preserving, keeps resource forks)
        let d = Process()
        d.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        d.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, archiveURL.path]
        try d.run(); d.waitUntilExit()
        guard d.terminationStatus == 0 else {
            throw NSError(
                domain: "Cling.Send", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not archive \(folder.lastPathComponent)"]
            )
        }
        return archiveURL
    }

    // MARK: - Send

    func send(files: [URL], expiration: TimeInterval) {
        guard !files.isEmpty else { return }
        let key = files.map(\.path).joined(separator: "|")
        guard !connectingPaths.contains(key) else { return }
        connectingPaths.insert(key)
        NotificationManager.shared.requestAuthorizationIfNeeded()

        let roomIDRef = Box<String?>(nil)
        let task = Task.detached {
            // Replace any directories with .zip archives
            var prepared: [URL] = []
            var temps: [URL] = []
            do {
                for url in files {
                    var isDir: ObjCBool = false
                    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                    if exists, isDir.boolValue {
                        let zip = try SendManager.archive(folder: url)
                        prepared.append(zip)
                        temps.append(zip)
                    } else {
                        prepared.append(url)
                    }
                }
            } catch {
                await MainActor.run {
                    SendManager.shared.connectingPaths.remove(key)
                    SendManager.shared.pendingTasks.removeValue(forKey: key)
                }
                temps.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) }
                throw error
            }

            do {
                let client = WarpDropClient()
                return try await client.send(
                    files: prepared,
                    keep: true,
                    onRoomCreated: { roomID in
                        roomIDRef.value = roomID
                        Task { @MainActor in
                            SendManager.shared.roomCreated(roomID: roomID, files: prepared, tempArchives: temps, expiration: expiration, key: key)
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
                    temps.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) }
                }
                throw error
            }
        }
        pendingTasks[key] = task
    }

    func roomCreated(roomID: String, files: [URL], tempArchives: [URL] = [], expiration: TimeInterval, key: String) {
        connectingPaths.remove(key)
        guard let task = pendingTasks.removeValue(forKey: key) else { return }
        let expiresAt = expiration > 0 ? Date().addingTimeInterval(expiration) : nil
        let session = SendSession(id: roomID, files: files, task: task, expiresAt: expiresAt, tempArchives: tempArchives)
        sessions.append(session)
        recentSessions.insert(session, at: 0)
        session.copyLink()
        linkCopiedTick += 1
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
        // Clean up any temp archives created for this session
        session.tempArchives.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) }
        // session stays in recentSessions (session-only history)
    }

    func stopAll() { sessions.forEach { stop($0) } }

    func didCompleteDownload(roomID: String, count: Int) {
        guard let s = sessions.first(where: { $0.id == roomID }) else { return }
        s.downloadCount = count
        NotificationManager.shared.notifyDownload(fileNames: s.fileNames, count: count)
    }
}
