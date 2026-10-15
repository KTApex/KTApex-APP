import SwiftUI
import SwiftData

struct SpecialDayEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let existing: SpecialDay?

    @State private var title = ""
    @State private var date = Date()
    @State private var type: SpecialDayType = .birthday
    @State private var notes = ""
    @State private var repeatsYearly = true
    @State private var reminderDays: Set<Int> = [7, 1, 0]
    @State private var hour = 9
    @State private var minute = 0
    @State private var error: String?

    private let options = [30, 14, 7, 3, 1, 0]

    init(event: SpecialDay?) {
        existing = event
        if let e = event {
            _title = State(initialValue: e.title)
            _date = State(initialValue: e.date)
            _type = State(initialValue: e.type)
            _notes = State(initialValue: e.notes)
            _repeatsYearly = State(initialValue: e.repeatsYearly)
            _reminderDays = State(initialValue: Set(e.reminderDays))
            _hour = State(initialValue: e.reminderTimeHour)
            _minute = State(initialValue: e.reminderTimeMinute)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                eventSection
                reminderSection
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(existing == nil ? "New Special Day" : "Edit Special Day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
        }
    }

    @ViewBuilder
    private var eventSection: some View {
        Section("Event") {
            TextField("Title", text: $title)
                .accessibilityLabel("Event title")
            DatePicker("Date", selection: $date, displayedComponents: .date)
            Picker("Type", selection: $type) {
                ForEach(SpecialDayType.allCases, id: \.self) { t in
                    Text(t.displayName).tag(t)
                }
            }
            Toggle("Repeats yearly", isOn: $repeatsYearly)
            TextField("Notes (optional)", text: $notes, axis: .vertical)
        }
    }

    @ViewBuilder
    private var reminderSection: some View {
        Section("Reminders") {
            ForEach(options, id: \.self) { d in
                Toggle(remindLabel(d), isOn: reminderBinding(for: d))
            }
            DatePicker(
                "Reminder time",
                selection: Binding<Date>(
                    get: { Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? Date() },
                    set: { newValue in
                        hour = Calendar.current.component(.hour, from: newValue)
                        minute = Calendar.current.component(.minute, from: newValue)
                    }
                ),
                displayedComponents: .hourAndMinute
            )
        }
    }

    private func reminderBinding(for day: Int) -> Binding<Bool> {
        Binding<Bool>(
            get: { reminderDays.contains(day) },
            set: { isOn in
                if isOn { reminderDays.insert(day) } else { reminderDays.remove(day) }
            }
        )
    }

    private func remindLabel(_ d: Int) -> String {
        d == 0 ? "Same day" : "\(d) \(d == 1 ? "day" : "days") before"
    }

    private func save() {
        guard !title.isBlank else { error = "Please give this day a title."; return }
        let event: SpecialDay
        if let existing {
            event = existing
        } else {
            event = SpecialDay(title: "", date: Date())
            context.insert(event)
        }
        event.title = title.trimmingCharacters(in: .whitespaces)
        event.date = date
        event.typeRaw = type.rawValue
        event.notes = notes
        event.repeatsYearly = repeatsYearly
        event.reminderDays = Array(reminderDays).sorted()
        event.reminderTimeHour = hour
        event.reminderTimeMinute = minute
        do {
            try context.save()
            Haptics.success()
            refreshWidgetSummary()
            Task { await NotificationService.shared.scheduleReminders(for: event) }
            dismiss()
        } catch {
            self.error = "Could not save. Please try again."
        }
    }

    private func refreshWidgetSummary() {
        let all = (try? context.fetch(FetchDescriptor<SpecialDay>())) ?? []
        WidgetSummaryService.refresh(events: all)
    }
}
