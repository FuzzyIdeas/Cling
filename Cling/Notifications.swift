import UserNotifications

final class NotificationManager {
    static let shared = NotificationManager()

    func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyDownload(fileNames: String, count: Int) {
        let content = UNMutableNotificationContent()
        content.title = "File downloaded"
        content.body = count <= 1 ? "\(fileNames) was downloaded" : "\(fileNames) was downloaded \(count)×"
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
