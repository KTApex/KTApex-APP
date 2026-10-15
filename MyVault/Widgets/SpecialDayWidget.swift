import WidgetKit
import SwiftUI

struct SpecialDayWidgetEntry: TimelineEntry {
    let date: Date
    let title: String
    let headline: String
}

struct SpecialDayProvider: TimelineProvider {
    func placeholder(in context: Context) -> SpecialDayWidgetEntry {
        SpecialDayWidgetEntry(date: Date(), title: "Anniversary", headline: "10 days left")
    }

    func getSnapshot(in context: Context, completion: @escaping (SpecialDayWidgetEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SpecialDayWidgetEntry>) -> Void) {
        // Widgets never read vault media. This shows the next Special Day title only.
        // The main app writes a lightweight summary to the shared App Group when events change.
        let entry = readSharedSummary() ?? SpecialDayWidgetEntry(date: Date(), title: "No special days", headline: "Open MyVault")
        let next = Calendar.current.date(byAdding: .hour, value: 6, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func readSharedSummary() -> SpecialDayWidgetEntry? {
        guard let defaults = UserDefaults(suiteName: "group.com.myvault.shared"),
              let title = defaults.string(forKey: "mv.widget.title") else { return nil }
        let headline = defaults.string(forKey: "mv.widget.headline") ?? ""
        return SpecialDayWidgetEntry(date: Date(), title: title, headline: headline)
    }
}

struct SpecialDayWidgetView: View {
    let entry: SpecialDayWidgetEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Upcoming", systemImage: "heart.fill")
                .font(.caption).foregroundStyle(.secondary)
            Text(entry.title).font(.headline).lineLimit(1)
            Text(entry.headline).font(.subheadline).foregroundStyle(.secondary)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct SpecialDayWidget: Widget {
    let kind = "SpecialDayWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SpecialDayProvider()) { entry in
            SpecialDayWidgetView(entry: entry)
        }
        .configurationDisplayName("Upcoming Special Day")
        .description("Shows your next special day countdown.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct MyVaultWidgetBundle: WidgetBundle {
    var body: some Widget {
        SpecialDayWidget()
    }
}
