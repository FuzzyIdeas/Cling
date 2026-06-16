import UserNotifications

final class NotificationManager {
    static let shared = NotificationManager()

    func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyDownload(roomID: String, summary: String, count: Int) {
        let content = UNMutableNotificationContent()
        content.title = "File downloaded"
        content.body = count <= 1 ? "\(summary) was downloaded" : "\(summary) was downloaded \(count)×"
        // Stable per-transfer id: a later download updates this one notification instead of stacking
        // a new one for every person who grabs the link.
        let req = UNNotificationRequest(identifier: "download-\(roomID)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
