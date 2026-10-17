import XCTest
@testable import MyVault

/// Auto-lock policy.
///
/// These test the *decision rules*, not `AppState.didBecomeActive` directly: that
/// method needs a full app state and real timing. What matters for safety is that the
/// sentinel is unambiguous, that "Never" is only honoured when it is safe, and that
/// every other value still locks.
final class AutoLockPolicyTests: XCTestCase {

    private var defaults: UserDefaults { .standard }
    private var previous: Any?

    override func setUp() {
        super.setUp()
        previous = defaults.object(forKey: "mv.autolock")
    }

    override func tearDown() {
        if let previous { defaults.set(previous, forKey: "mv.autolock") }
        else { defaults.removeObject(forKey: "mv.autolock") }
        super.tearDown()
    }

    /// The sentinel must be distinguishable from "immediately". Storing "Never" as 0
    /// would make the app lock the moment it became active, which is the opposite of
    /// what the user asked for.
    func testNeverSentinelIsNotZero() {
        XCTAssertNotEqual(AppSettingsStore.neverLocks, 0)
        XCTAssertLessThan(AppSettingsStore.neverLocks, 0, "Never must be negative so it can never be read as a live timeout")
    }

    func testNeverRoundTripsAndIsDetected() {
        AppSettingsStore.setAutoLock(AppSettingsStore.neverLocks)
        XCTAssertEqual(AppSettingsStore.autoLockTimeout, AppSettingsStore.neverLocks)
        XCTAssertTrue(AppSettingsStore.autoLockDisabled)
    }

    func testOtherValuesAreNotMistakenForNever() {
        for value in [0, 30, 60, 300] {
            AppSettingsStore.setAutoLock(value)
            XCTAssertFalse(AppSettingsStore.autoLockDisabled, "\(value) must not read as Never")
            XCTAssertFalse(AppSettingsStore.autoLockTimeout == AppSettingsStore.neverLocks)
        }
        // Immediate is still immediate, not "never".
        AppSettingsStore.setAutoLock(0)
        XCTAssertEqual(AppSettingsStore.autoLockTimeout, 0)
    }

    /// "Never" is only defensible when the user can still lock the vault some other
    /// way. With no PIN and no biometrics there is no re-entry path, so the option must
    /// be refused rather than silently accepted.
    func testNeverIsOnlyAllowedWithASecondUnlockMethod() {
        let storePreviousBio = defaults.object(forKey: "mv.bio")
        defer {
            if let storePreviousBio { defaults.set(storePreviousBio, forKey: "mv.bio") }
            else { defaults.removeObject(forKey: "mv.bio") }
        }

        // Biometrics on: Never is allowed regardless of PIN state.
        AppSettingsStore.setBiometricEnabled(true)
        XCTAssertTrue(AppSettingsStore.neverAutoLockAllowed)
        XCTAssertTrue(AppState.shouldHonourNeverAutoLock)

        // Biometrics off and no PIN: refused.
        AppSettingsStore.setBiometricEnabled(false)
        if PINService.shared.isEnabled {
            // A PIN exists on this simulator, so the refusal case cannot be expressed.
            // Assert the disjunction instead of skipping silently.
            XCTAssertTrue(AppSettingsStore.neverAutoLockAllowed)
        } else {
            XCTAssertFalse(AppSettingsStore.neverAutoLockAllowed)
            XCTAssertFalse(AppState.shouldHonourNeverAutoLock, "a stored Never must not be obeyed without a second unlock method")
        }
    }
}