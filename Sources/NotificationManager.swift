import Foundation
import UserNotifications

/// Phase-end notifications. Authorization is requested once, on the first
/// Start press, never mid-focus. The sound + menu status line still fire
/// even if the user denies notifications, so nothing depends on this.
enum NotificationManager {
    private static let requestedKey = "notifAuthRequested"

    static func requestIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: requestedKey) else { return }
        UserDefaults.standard.set(true, forKey: requestedKey)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            // Denial is fine; the sound + menu status line still fire.
        }
    }

    static func phaseEnded(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
