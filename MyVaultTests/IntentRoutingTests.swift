import XCTest
import SwiftUI
import AppIntents
@testable import MyVault

/// App Intent routing.
///
/// The intents themselves only post notifications — the security-relevant part is what
/// the app does with them, and the rule that matters is: locking is always applied,
/// navigation is only applied once unlocked. These test the pieces of that rule which
/// are pure and observable without a running app.
final class IntentRoutingTests: XCTestCase {

    /// Every tab must survive the trip through its string form, because that string is
    /// the only thing an intent can send across the process boundary.
    func testEveryTabRoundTripsThroughItsIntentIdentifier() {
        for tab in [AppTab.home, .vault, .specialDays, .settings] {
            XCTAssertEqual(
                AppTab.fromIntentIdentifier(tab.intentIdentifier),
                tab,
                "\(tab) did not round-trip"
            )
        }
    }

    func testUnknownIntentIdentifierIsRejected() {
        XCTAssertNil(AppTab.fromIntentIdentifier("photos"))
        XCTAssertNil(AppTab.fromIntentIdentifier(""))
        XCTAssertNil(AppTab.fromIntentIdentifier("VAULT"), "matching is exact, not case-folded")
    }

    /// `openAppWhenRun` is what actually brings the app forward. An intent that changes
    /// UI but leaves this false runs invisibly, so the intent kinds that navigate must
    /// declare it.
    func testNavigatingIntentsOpenTheApp() {
        XCTAssertTrue(OpenVaultIntent.openAppWhenRun)
        XCTAssertTrue(OpenBackupIntent.openAppWhenRun)
        XCTAssertTrue(OpenSpecialDaysIntent.openAppWhenRun)
    }

    /// Locking must be able to happen without bringing the app forward: the whole point
    /// is to secure the vault without showing it.
    func testLockIntentDoesNotRequireForegrounding() {
        XCTAssertFalse(LockVaultIntent.openAppWhenRun)
        XCTAssertFalse(ShowNextSpecialDayIntent.openAppWhenRun)
    }

    /// The notification channel is the entire contract between an out-of-process intent
    /// and the app, so the names must be distinct and namespaced.
    func testIntentNotificationNamesAreDistinctAndNamespaced() {
        let names = [
            MyVaultIntentNotifications.lockVault.rawValue,
            MyVaultIntentNotifications.openTab.rawValue,
            MyVaultIntentNotifications.openBackup.rawValue
        ]
        XCTAssertEqual(Set(names).count, names.count, "names must not collide")
        for name in names {
            XCTAssertTrue(name.hasPrefix("mv.intent."), "unexpected name \(name)")
        }
    }
}