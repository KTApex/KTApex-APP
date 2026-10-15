import Foundation
import UserNotifications
import UIKit

/// Local-only notifications for Special Days. No server involved.
final class NotificationService {
    static let shared = NotificationService()
    private init() {}

    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
        }
    }

    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            return false
        }
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        Task { @MainActor in UIApplication.shared.open(url, options: [:], completionHandler: nil) }
    }

    /// Schedules one notification per daysBefore value. Identifier encodes the SpecialDay id.
    func scheduleReminders(for event: SpecialDay) async {
        await cancelReminders(for: event.id)
        let center = UNUserNotificationCenter.current()
        let status = await authorizationStatus()
        guard status == .authorized || status == .provisional else { return }

        for days in event.reminderDays {
            guard let triggerDate = CountdownEngine.notificationDate(for: event, daysBefore: days) else { continue }
            guard triggerDate > Date() else { continue }
            let content = UNMutableNotificationContent()
            content.title = CountdownEngine.notificationTitle(for: event, daysBefore: days)
            content.body = CountdownEngine.notificationBody(for: event, daysBefore: days)
            content.sound = .default
            content.userInfo = ["specialDayID": event.id]
            var comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: triggerDate)
            comps.second = 0
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let req = UNNotificationRequest(
                identifier: "mv.\(event.id).\(days)",
                content: content,
                trigger: trigger
            )
            try? await center.add(req)
        }
    }

    func cancelReminders(for eventID: String) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix("mv.\(eventID).") }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    func cancelAll() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}
