import SwiftUI
import SwiftData

struct SpecialDaysView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var context
    @Query(sort: \SpecialDay.date) private var events: [SpecialDay]
    @State private var showingEditor = false
    @State private var editingEvent: SpecialDay?
    @State private var selectedEventID: String?

    private var sorted: [SpecialDay] {
        events.sorted { CountdownEngine.nextOccurrence(of: $0).daysRemaining < CountdownEngine.nextOccurrence(of: $1).daysRemaining }
    }

    var body: some View {
        NavigationStack {
            Group {
                if events.isEmpty {
                    MVEmptyState(
                        symbol: "heart",
                        title: "No special days yet",
                        subtitle: "Create a reminder for someone special.",
                        actionTitle: "Add Special Day",
                        action: { showingEditor = true }
                    )
                } else {
                    List(sorted) { event in
                        SpecialDayCard(event: event)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .onTapGesture { selectedEventID = event.id }
                            .swipeActions {
                                Button("Delete", role: .destructive) { delete(event) }
                                Button("Edit") { editingEvent = event }
                            }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Special Days")
            .toolbar {
                Button { showingEditor = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add special day")
            }
            .sheet(isPresented: $showingEditor) { SpecialDayEditor(event: nil) }
            .sheet(item: $editingEvent) { SpecialDayEditor(event: $0) }
            .navigationDestination(isPresented: detailBinding) {
                if let event = events.first(where: { $0.id == selectedEventID }) {
                    SpecialDayDetailView(event: event)
                }
            }
            .onChange(of: appState.deepLinkedSpecialDayID) { _, id in
                if let id, events.contains(where: { $0.id == id }) {
                    selectedEventID = id
                    appState.deepLinkedSpecialDayID = nil
                }
            }
        }
    }

    private var detailBinding: Binding<Bool> {
        Binding(
            get: { selectedEventID != nil },
            set: { if !$0 { selectedEventID = nil } }
        )
    }

    private func delete(_ event: SpecialDay) {
        Task { await NotificationService.shared.cancelReminders(for: event.id) }
        context.delete(event)
        try? context.save()
        Haptics.success()
        WidgetSummaryService.refresh(events: events.filter { $0.id != event.id })
    }
}

struct SpecialDayCard: View {
    let event: SpecialDay
    private var occ: CountdownEngine.Occurrence { CountdownEngine.nextOccurrence(of: event) }

    var body: some View {
        MVCard {
            HStack(spacing: 16) {
                CountdownRing(progress: ringProgress)
                    .frame(width: 56, height: 56)
                    .overlay {
                        Image(systemName: event.type.symbol)
                            .foregroundStyle(.tint)
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title).font(MVFont.headline)
                    Text(event.date.formatted(date: .abbreviated, time: .omitted))
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(CountdownEngine.headline(for: event))
                        .font(.subheadline).foregroundStyle(.tint).fontWeight(.semibold)
                    if occ.yearsCompleted > 0 {
                        Text("\(occ.yearsCompleted) \(occ.yearsCompleted == 1 ? "year" : "years") together")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.title), \(CountdownEngine.headline(for: event))")
    }

    private var ringProgress: Double {
        let days = occ.daysRemaining
        if days <= 0 { return 1 }
        if days >= 365 { return 0.05 }
        return 1 - Double(days) / 365.0
    }
}
