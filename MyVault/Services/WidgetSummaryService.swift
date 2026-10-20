import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Writes a lightweight, non-sensitive summary of the next Special Day into the
/// shared App Group so the home-screen widget can render a countdown without
/// ever touching (or having access to) vault media.
///
/// Privacy note: only the event *title* and a short headline are shared. The
/// vault's encrypted files and its Keychain key are never exposed to widgets.
final class WidgetSummaryService {
    static let suiteName = "group.com.myvault.shared"

    static func refresh(
        events: [SpecialDay],
        reference: Date = Date(),
        privacyMode: Bool = AppSettingsStore.notificationPrivacyMode,
        defaults: UserDefaults? = UserDefaults(suiteName: suiteName)
    ) {
        guard let defaults else { return }
        defaults.set(privacyMode, forKey: "mv.widget.privacyMode")
        let upcoming = events
            .filter { CountdownEngine.nextOccurrence(of: $0, from: reference).daysRemaining >= 0 }
            .sorted {
                CountdownEngine.nextOccurrence(of: $0, from: reference).daysRemaining
                    < CountdownEngine.nextOccurrence(of: $1, from: reference).daysRemaining
            }
            .first
        if let event = upcoming {
            let countdown = CountdownEngine.nextOccurrence(of: event, from: reference)
            defaults.set(event.title, forKey: "mv.widget.title")
            defaults.set(CountdownEngine.headline(for: event, from: reference), forKey: "mv.widget.headline")
            defaults.set(countdown.daysRemaining, forKey: "mv.widget.daysRemaining")
        } else {
            defaults.removeObject(forKey: "mv.widget.title")
            defaults.removeObject(forKey: "mv.widget.headline")
            defaults.removeObject(forKey: "mv.widget.daysRemaining")
        }
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// Builds the spoken/displayed response for `ShowNextSpecialDayIntent` without
    /// opening SwiftData, honoring Lock Screen notification privacy when enabled.
    static func nextSpecialDayDialog(
        privacyMode: Bool = AppSettingsStore.notificationPrivacyMode,
        defaults: UserDefaults? = UserDefaults(suiteName: suiteName)
    ) -> String {
        guard let defaults,
              let title = defaults.string(forKey: "mv.widget.title"), !title.isEmpty,
              let headline = defaults.string(forKey: "mv.widget.headline"), !headline.isEmpty else {
            return "Open MyVault to see your next special day."
        }
        if privacyMode {
            return "You have an upcoming special day (\(headline)). Open MyVault for details."
        }
        return "Your next special day is \(title) (\(headline))."
    }
}
