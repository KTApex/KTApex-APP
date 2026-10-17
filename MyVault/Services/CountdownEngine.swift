import Foundation

/// Countdown math using Calendar APIs. Handles leap years and yearly repeats correctly.
enum CountdownEngine {
    struct Occurrence {
        let nextDate: Date
        let daysRemaining: Int
        let yearsCompleted: Int
    }

    static func nextOccurrence(of event: SpecialDay, from reference: Date = Date(), calendar: Calendar = .current) -> Occurrence {
        let cal = calendar
        let startOfToday = cal.startOfDay(for: reference)
        if !event.repeatsYearly {
            let target = cal.startOfDay(for: event.date)
            let days = cal.dateComponents([.day], from: startOfToday, to: target).day ?? 0
            // Keep the sign: a one-off date that has already passed must not be
            // reported as "Today" forever. Callers filter on `daysRemaining >= 0`
            // to decide what counts as upcoming.
            return Occurrence(nextDate: event.date, daysRemaining: days, yearsCompleted: 0)
        }
        let month = cal.component(.month, from: event.date)
        var day = cal.component(.day, from: event.date)
        var year = cal.component(.year, from: reference)
        // Clamp Feb 29 to Feb 28 in non-leap years.
        if month == 2 && day == 29 && !isLeapYear(year, calendar: cal) { day = 28 }
        var comps = DateComponents(year: year, month: month, day: day)
        var candidate = cal.date(from: comps) ?? reference
        if cal.startOfDay(for: candidate) < startOfToday {
            year += 1
            var d = cal.component(.day, from: event.date)
            if month == 2 && d == 29 && !isLeapYear(year, calendar: cal) { d = 28 }
            comps = DateComponents(year: year, month: month, day: d)
            candidate = cal.date(from: comps) ?? reference
        }
        let days = cal.dateComponents([.day], from: startOfToday, to: cal.startOfDay(for: candidate)).day ?? 0
        let originYear = cal.component(.year, from: event.date)
        let completed = days > 0 ? (year - originYear - 1) : (year - originYear)
        return Occurrence(nextDate: candidate, daysRemaining: max(days, 0), yearsCompleted: max(completed, 0))
    }

    static func headline(for event: SpecialDay, from reference: Date = Date()) -> String {
        let occ = nextOccurrence(of: event, from: reference)
        let days = occ.daysRemaining
        switch days {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case ..<0: return "\(-days) \(days == -1 ? "day" : "days") ago"
        default: return "\(days) days left"
        }
    }

    static func isLeapYear(_ year: Int, calendar: Calendar = .current) -> Bool {
        guard let feb = calendar.date(from: DateComponents(year: year, month: 2, day: 1)),
              let range = calendar.range(of: .day, in: .month, for: feb) else { return false }
        return range.count == 29
    }

    static func notificationDate(for event: SpecialDay, daysBefore: Int, calendar: Calendar = .current) -> Date? {
        let occ = nextOccurrence(of: event, calendar: calendar)
        guard let base = calendar.date(byAdding: .day, value: -daysBefore, to: occ.nextDate) else { return nil }
        var comps = calendar.dateComponents([.year, .month, .day], from: base)
        comps.hour = event.reminderTimeHour
        comps.minute = event.reminderTimeMinute
        return calendar.date(from: comps)
    }

    /// `privacyMode` defaults to **true** on purpose.
    ///
    /// The function default must match the app's own default, otherwise a caller that
    /// forgets the argument silently produces a banner containing the event title. The
    /// safe value has to be the one you get by omission.
    static func notificationTitle(for event: SpecialDay, daysBefore: Int, privacyMode: Bool = true) -> String {
        // A neutral title is used in privacy mode: the event type alone ("Birthday
        // Reminder") already hints at a date worth knowing, so the generic wording is
        // used for every type.
        if privacyMode { return "MyVault" }
        switch event.type {
        case .birthday: return "Birthday Reminder"
        default: return "Special Day"
        }
    }

    /// See `notificationTitle` for why `privacyMode` defaults to true.
    static func notificationBody(for event: SpecialDay, daysBefore: Int, privacyMode: Bool = true) -> String {
        // Privacy mode: no title, no type, no date — just a nudge to open the app. The
        // tap still deep-links because the identifier travels in `userInfo`.
        if privacyMode {
            switch daysBefore {
            case 0: return "You have a special day today."
            case 1: return "You have a special day tomorrow."
            default: return "You have a special day coming up."
            }
        }
        if daysBefore == 0 { return "\(event.title) is today." }
        if daysBefore == 1 { return "\(event.title) is tomorrow." }
        return "\(event.title) is in \(daysBefore) days."
    }
}
