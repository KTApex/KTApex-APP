import SwiftUI
import SwiftData

struct SpecialDayDetailView: View {
    @Environment(\.modelContext) private var context
    @State private var showingEditor = false
    let event: SpecialDay
    private var occ: CountdownEngine.Occurrence { CountdownEngine.nextOccurrence(of: event) }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: event.type.symbol)
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                Text(event.title).font(MVFont.greeting)
                Text(CountdownEngine.headline(for: event))
                    .font(MVFont.countdown)
                Text("Next: \(occ.nextDate.formatted(date: .long, time: .omitted))")
                    .foregroundStyle(.secondary)
                if occ.yearsCompleted > 0 {
                    Text("\(occ.yearsCompleted) \(occ.yearsCompleted == 1 ? "year" : "years") together")
                        .font(MVFont.headline)
                }
                if !event.notes.isEmpty {
                    MVCard {
                        Text(event.notes).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal)
                }
                MVCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Reminders").font(MVFont.headline)
                        ForEach(event.reminderDays.sorted(), id: \.self) { d in
                            Label(d == 0 ? "Same day" : "\(d) days before", systemImage: "bell.fill")
                                .font(.subheadline)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .navigationTitle(event.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Edit") { showingEditor = true }
        }
        .sheet(isPresented: $showingEditor) { SpecialDayEditor(event: event) }
    }
}
