import Foundation

/// Writes a lightweight, non-sensitive summary of the next Special Day into the
/// shared App Group so the home-screen widget can render a countdown without
/// ever touching (or having access to) vault media.
///
/// Privacy note: only the event *title* and a short headline are shared. The
/// vault's encrypted files and its Keychain key are never exposed to widgets.
final class WidgetSummaryService {
    private static let suiteName = "group.com.myvault.shared"

    static func refresh(events: [SpecialDay], reference: Date = Date()) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        let upcoming = events
            .filter { CountdownEngine.nextOccurrence(of: $0, from: reference).daysRemaining >= 0 }
            .sorted {
                CountdownEngine.nextOccurrence(of: $0, from: reference).daysRemaining
                    < CountdownEngine.nextOccurrence(of: $1, from: reference).daysRemaining
            }
            .first
        if let event = upcoming {
            defaults.set(event.title, forKey: "mv.widget.title")
            defaults.set(CountdownEngine.headline(for: event, from: reference), forKey: "mv.widget.headline")
        } else {
            defaults.removeObject(forKey: "mv.widget.title")
            defaults.removeObject(forKey: "mv.widget.headline")
        }
    }
}
