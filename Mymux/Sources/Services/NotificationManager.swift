import AppKit
import UserNotifications

final class NotificationManager {
    // CRITICAL: Guard all UNUserNotificationCenter access with bundle ID check
    private var canSendNotifications: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    private var waitingTerminals: Set<String> = []
    private var notifiedTerminals: Set<String> = []

    // MARK: - Authorization

    func requestAuthorization() {
        guard canSendNotifications else {
            print("NotificationManager: No bundle identifier — skipping authorization")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Notification authorization error: \(error)")
            }
        }
    }

    // MARK: - Waiting State

    func terminalBecameWaiting(terminalId: String, terminalName: String) {
        waitingTerminals.insert(terminalId)
        updateDockBadge()

        // Only fire notification once per waiting cycle
        guard !notifiedTerminals.contains(terminalId) else { return }
        notifiedTerminals.insert(terminalId)

        guard canSendNotifications else { return }

        let content = UNMutableNotificationContent()
        content.title = "mymux"
        content.body = "\(terminalName) is waiting for input"
        content.sound = .default
        content.userInfo = ["terminalId": terminalId]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "waiting-\(terminalId)",
            content: content,
            trigger: trigger
        )

        let center = UNUserNotificationCenter.current()
        center.add(request) { error in
            if let error = error {
                print("Failed to schedule notification: \(error)")
            }
        }
    }

    func terminalStoppedWaiting(terminalId: String) {
        waitingTerminals.remove(terminalId)
        notifiedTerminals.remove(terminalId)
        updateDockBadge()

        guard canSendNotifications else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: ["waiting-\(terminalId)"])
    }

    // MARK: - Custom Notification (notify_user MCP tool)

    func sendCustomNotification(message: String, urgency: String, terminalId: String) {
        guard canSendNotifications else { return }

        let content = UNMutableNotificationContent()
        content.title = "mymux"
        content.body = message
        content.sound = .default
        content.userInfo = ["terminalId": terminalId]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let identifier = "custom-\(terminalId)-\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        let center = UNUserNotificationCenter.current()
        center.add(request) { error in
            if let error = error {
                print("Failed to schedule custom notification: \(error)")
            }
        }

        // Critical urgency also requests dock attention
        if urgency == "critical" {
            DispatchQueue.main.async {
                NSApp.requestUserAttention(.criticalRequest)
            }
        }
    }

    // MARK: - Dock Badge

    func updateDockBadge() {
        DispatchQueue.main.async {
            if self.waitingTerminals.isEmpty {
                NSApp.dockTile.badgeLabel = nil
            } else {
                NSApp.dockTile.badgeLabel = String(self.waitingTerminals.count)
            }
        }
    }
}
