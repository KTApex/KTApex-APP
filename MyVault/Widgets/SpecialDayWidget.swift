import WidgetKit
import SwiftUI

struct SpecialDayWidgetEntry: TimelineEntry {
    let date: Date
    let title: String
    let headline: String
    let daysRemaining: Int?
}

struct SpecialDayProvider: TimelineProvider {
    func placeholder(in context: Context) -> SpecialDayWidgetEntry {
        SpecialDayWidgetEntry(date: Date(), title: "Anniversary", headline: "10 days left", daysRemaining: 10)
    }

    func getSnapshot(in context: Context, completion: @escaping (SpecialDayWidgetEntry) -> Void) {
        completion(readSharedSummary() ?? placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SpecialDayWidgetEntry>) -> Void) {
        // Widgets never read vault media. This shows the next Special Day title only
        // (or masks it when Lock Screen privacy mode is enabled).
        let entry = readSharedSummary() ?? SpecialDayWidgetEntry(
            date: Date(),
            title: "No special days",
            headline: "Open MyVault",
            daysRemaining: nil
        )
        let next = Calendar.current.date(byAdding: .hour, value: 6, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func readSharedSummary() -> SpecialDayWidgetEntry? {
        guard let defaults = UserDefaults(suiteName: "group.com.myvault.shared"),
              let rawTitle = defaults.string(forKey: "mv.widget.title") else { return nil }
        let privacyMode = defaults.bool(forKey: "mv.widget.privacyMode")
        let title = privacyMode ? "Private Special Day" : rawTitle
        let headline = defaults.string(forKey: "mv.widget.headline") ?? ""
        let days = defaults.object(forKey: "mv.widget.daysRemaining") as? Int
        return SpecialDayWidgetEntry(date: Date(), title: title, headline: headline, daysRemaining: days)
    }
}

struct SpecialDayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SpecialDayWidgetEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 1) {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                    if let days = entry.daysRemaining {
                        Text("\(days)d")
                            .font(.system(.caption, design: .rounded).weight(.bold))
                    } else {
                        Text("—")
                            .font(.caption2)
                    }
                }
            }
            .containerBackground(.fill.tertiary, for: .widget)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label("MyVault", systemImage: "heart.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(entry.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(entry.headline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .containerBackground(.fill.tertiary, for: .widget)
        default:
            VStack(alignment: .leading, spacing: 4) {
                Label("Upcoming", systemImage: "heart.fill")
                    .font(.caption).foregroundStyle(.secondary)
                Text(entry.title).font(.headline).lineLimit(1)
                Text(entry.headline).font(.subheadline).foregroundStyle(.secondary)
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
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
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

@main
struct MyVaultWidgetBundle: WidgetBundle {
    var body: some Widget {
        SpecialDayWidget()
    }
}
