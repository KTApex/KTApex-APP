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
    ///
    /// `privacyMode` is read per call rather than cached, because notifications are
    /// scheduled while the app may be locked and the setting can change between
    /// launches. When on, neither the title nor the body contains the event title.
    func scheduleReminders(for event: SpecialDay, privacyMode: Bool? = nil) async {
        await cancelReminders(for: event.id)
        let center = UNUserNotificationCenter.current()
        let status = await authorizationStatus()
        guard status == .authorized || status == .provisional else { return }
        let privateMode = privacyMode ?? AppSettingsStore.notificationPrivacyMode

        for days in event.reminderDays {
            guard let triggerDate = CountdownEngine.notificationDate(for: event, daysBefore: days) else { continue }
            // Yearly events recur, so a reminder that already passed this year still
            // makes sense (it fires next year). A one-off reminder in the past would
            // never fire at all, so drop it.
            let repeats = event.repeatsYearly
            guard repeats || triggerDate > Date() else { continue }
            let content = UNMutableNotificationContent()
            content.title = CountdownEngine.notificationTitle(for: event, daysBefore: days, privacyMode: privateMode)
            content.body = CountdownEngine.notificationBody(for: event, daysBefore: days, privacyMode: privateMode)
            content.sound = .default
            // The id is what makes the tap deep-link, so it is always present even when
            // the visible text is deliberately unrevealing.
            content.userInfo = ["specialDayID": event.id]
            var comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: triggerDate)
            comps.second = 0
            if repeats {
                // A repeating yearly trigger must omit the year (keeping it would make
                // the notification fire exactly once), and Feb 29 is clamped to Feb 28
                // so it still fires in non-leap years.
                comps.year = nil
                if comps.month == 2 && comps.day == 29 { comps.day = 28 }
            }
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: repeats)
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

    /// Re-applies every event's reminders using the current privacy setting.
    ///
    /// Needed because reminders are otherwise only scheduled when an event is edited:
    /// without this, flipping the toggle would leave already-scheduled banners still
    /// showing their titles until each event happened to be touched again.
    func rescheduleAll(_ events: [SpecialDay]) async {
        for event in events {
            await scheduleReminders(for: event)
        }
    }
}
