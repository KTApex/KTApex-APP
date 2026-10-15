import XCTest
@testable import MyVault

final class CountdownEngineTests: XCTestCase {
    private func event(date: Date, repeats: Bool = true) -> SpecialDay {
        let e = SpecialDay(title: "Test", date: date)
        e.repeatsYearly = repeats
        return e
    }

    func testDaysRemainingFuture() {
        let cal = Calendar(identifier: .gregorian)
        let today = cal.startOfDay(for: Date())
        let target = cal.date(byAdding: .day, value: 10, to: today)!
        // Non-repeating event exactly 10 days out.
        let e = event(date: target, repeats: false)
        let occ = CountdownEngine.nextOccurrence(of: e, from: today, calendar: cal)
        XCTAssertEqual(occ.daysRemaining, 10)
    }

    func testTodayAndTomorrowHeadlines() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let eToday = event(date: today, repeats: false)
        XCTAssertEqual(CountdownEngine.headline(for: eToday), "Today")
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        let eTom = event(date: tomorrow, repeats: false)
        XCTAssertEqual(CountdownEngine.headline(for: eTom), "Tomorrow")
    }

    func testLeapYearFeb29() {
        XCTAssertTrue(CountdownEngine.isLeapYear(2024))
        XCTAssertFalse(CountdownEngine.isLeapYear(2025))
        XCTAssertTrue(CountdownEngine.isLeapYear(2000))
        XCTAssertFalse(CountdownEngine.isLeapYear(1900))
    }

    func testFeb29ClampedInNonLeapYear() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let origin = cal.date(from: DateComponents(year: 2020, month: 2, day: 29))!
        let ref = cal.date(from: DateComponents(year: 2025, month: 1, day: 15))!
        let e = event(date: origin)
        let occ = CountdownEngine.nextOccurrence(of: e, from: ref, calendar: cal)
        let comps = cal.dateComponents([.month, .day], from: occ.nextDate)
        XCTAssertEqual(comps.month, 2)
        XCTAssertEqual(comps.day, 28)
    }

    func testNotificationDateRespectsTime() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let target = cal.date(byAdding: .day, value: 7, to: today)!
        let e = event(date: target, repeats: false)
        e.reminderTimeHour = 9
        e.reminderTimeMinute = 30
        let nd = CountdownEngine.notificationDate(for: e, daysBefore: 1)
        XCTAssertNotNil(nd)
        XCTAssertEqual(cal.component(.hour, from: nd!), 9)
        XCTAssertEqual(cal.component(.minute, from: nd!), 30)
    }

    func testNotificationBody() {
        let e = event(date: Date())
        e.title = "Anniversary"
        XCTAssertTrue(CountdownEngine.notificationBody(for: e, daysBefore: 0).contains("today"))
        XCTAssertTrue(CountdownEngine.notificationBody(for: e, daysBefore: 1).contains("tomorrow"))
    }
}
