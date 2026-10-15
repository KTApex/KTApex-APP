import Foundation
extension Date {
    func daysUntil(_ other: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: self), to: calendar.startOfDay(for: other)).day ?? 0
    }
}
extension String { var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
