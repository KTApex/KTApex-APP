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
        // Explicitly non-private: these assert the wording used when the user has
        // turned the privacy toggle off.
        XCTAssertTrue(CountdownEngine.notificationBody(for: e, daysBefore: 0, privacyMode: false).contains("today"))
        XCTAssertTrue(CountdownEngine.notificationBody(for: e, daysBefore: 1, privacyMode: false).contains("tomorrow"))
    }

    // MARK: - Notification privacy mode

    /// The security property: with privacy mode on, nothing in the banner identifies
    /// the event. A Lock Screen banner is readable without unlocking the phone, so a
    /// title here would leak vault contents to anyone glancing at the device.
    func testPrivacyModeNeverRevealsTheEventTitle() {
        let e = event(date: Date())
        e.title = "Mum's Birthday"

        for days in [0, 1, 3, 7] {
            let title = CountdownEngine.notificationTitle(for: e, daysBefore: days, privacyMode: true)
            let body = CountdownEngine.notificationBody(for: e, daysBefore: days, privacyMode: true)
            XCTAssertFalse(title.localizedCaseInsensitiveContains("Mum"), "title leaked for daysBefore \(days): \(title)")
            XCTAssertFalse(body.localizedCaseInsensitiveContains("Mum"), "body leaked for daysBefore \(days): \(body)")
            XCTAssertFalse(body.localizedCaseInsensitiveContains("Birthday"), "body leaked the type for daysBefore \(days): \(body)")
            XCTAssertEqual(title, "MyVault")
            XCTAssertTrue(body.hasPrefix("You have a special day"))
        }
    }

    /// Privacy mode must not remove the information the user needs to act: the wording
    /// still distinguishes today from tomorrow from later.
    func testPrivacyModeStillDistinguishesTiming() {
        let e = event(date: Date())
        e.title = "Private"
        XCTAssertEqual(CountdownEngine.notificationBody(for: e, daysBefore: 0, privacyMode: true), "You have a special day today.")
        XCTAssertEqual(CountdownEngine.notificationBody(for: e, daysBefore: 1, privacyMode: true), "You have a special day tomorrow.")
        XCTAssertEqual(CountdownEngine.notificationBody(for: e, daysBefore: 5, privacyMode: true), "You have a special day coming up.")
    }

    /// With privacy mode off the feature is unchanged, so this is a toggle and not a
    /// silent removal of detail.
    func testPrivacyModeOffKeepsTheTitle() {
        let e = event(date: Date())
        e.title = "Anniversary"
        XCTAssertTrue(CountdownEngine.notificationBody(for: e, daysBefore: 0, privacyMode: false).contains("Anniversary"))
        XCTAssertEqual(CountdownEngine.notificationTitle(for: e, daysBefore: 0, privacyMode: false), "Special Day")
    }

    /// The default must be the private one: forgetting to set the preference should
    /// never expose a title.
    ///
    /// The default is the *absence* of the key, so the key is cleared first. Without
    /// this the test would pass or fail depending on what other tests or a previous run
    /// left in UserDefaults, which is not a property of the code at all.
    func testPrivacyModeDefaultsToOn() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "mv.notifPrivacy")
        defaults.removeObject(forKey: "mv.notifPrivacy")
        defer {
            if let previous { defaults.set(previous, forKey: "mv.notifPrivacy") }
            else { defaults.removeObject(forKey: "mv.notifPrivacy") }
        }

        XCTAssertTrue(AppSettingsStore.notificationPrivacyMode, "privacy mode must default to on")

        let e = event(date: Date())
        e.title = "Anniversary"
        XCTAssertFalse(CountdownEngine.notificationBody(for: e, daysBefore: 0).contains("Anniversary"))
    }

    /// The stored preference round-trips, so the toggle actually persists.
    func testPrivacyModePreferencePersists() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "mv.notifPrivacy")
        defer {
            if let previous { defaults.set(previous, forKey: "mv.notifPrivacy") }
            else { defaults.removeObject(forKey: "mv.notifPrivacy") }
        }

        AppSettingsStore.setNotificationPrivacyMode(false)
        XCTAssertFalse(AppSettingsStore.notificationPrivacyMode)
        AppSettingsStore.setNotificationPrivacyMode(true)
        XCTAssertTrue(AppSettingsStore.notificationPrivacyMode)
    }

    func testSpecialDayCoverAndLinkedAlbumResolution() {
        let e = SpecialDay(title: "Wedding", date: Date(), type: .wedding)
        let photo = VaultMedia(fileName: "ring.jpg", encryptedFileName: "enc-ring", mediaType: "photo")
        let trashed = VaultMedia(fileName: "old.jpg", encryptedFileName: "enc-old", mediaType: "photo")
        trashed.isInTrash = true
        let album = VaultAlbum(name: "Wedding Album")

        e.photoFileName = photo.id
        e.linkedAlbumID = album.id
        XCTAssertEqual(e.coverMedia(in: [photo, trashed])?.id, photo.id)
        XCTAssertEqual(e.linkedAlbum(in: [album])?.id, album.id)

        e.photoFileName = trashed.id
        XCTAssertNil(e.coverMedia(in: [photo, trashed]), "trashed media must never be used as a cover")
    }

    func testSecureNoteSortingAndSearch() {
        let older = SecureNote(title: "Trip", body: "Café in Paris", isPinned: false, updatedAt: Date(timeIntervalSince1970: 100))
        let pinned = SecureNote(title: "Codes", body: "Safe combination", isPinned: true, updatedAt: Date(timeIntervalSince1970: 50))
        let sorted = SecureNoteService.sorted([older, pinned])
        XCTAssertEqual(sorted.map(\.title), ["Codes", "Trip"], "pinned notes must sort ahead of unpinned notes")
        XCTAssertTrue(SecureNoteService.matches(older, search: "cafe"), "search must be case- and diacritic-insensitive")
        XCTAssertFalse(SecureNoteService.matches(older, search: "combination"))
    }
}
