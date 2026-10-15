import XCTest
@testable import MyVault

/// Keychain-backed integration tests. These require a running test host with a
/// Keychain (iOS Simulator / device). They are intentionally separated from the
/// pure-logic unit tests because they mutate real Keychain state.
///
/// NOTE: tests use a dedicated PIN value and clean up after themselves. Nothing
/// sensitive is logged or printed.
final class KeychainIntegrationTests: XCTestCase {

    private let pin = "2468"

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Start from a clean slate.
        PINService.shared.disable()
    }

    override func tearDownWithError() throws {
        PINService.shared.disable()
    }

    func testSetPINStoresVerifierOnlyInKeychain() throws {
        PINService.shared.setPIN(pin)
        XCTAssertTrue(PINService.shared.isEnabled)

        // Verifier + salt live in the Keychain.
        XCTAssertNotNil(KeychainService.shared.get(KeychainService.Key.pinVerifier))
        XCTAssertNotNil(KeychainService.shared.get(KeychainService.Key.pinSalt))

        // The raw PIN must NOT be recoverable from Keychain or UserDefaults.
        for account in [KeychainService.Key.pinVerifier, KeychainService.Key.pinSalt] {
            guard let d = KeychainService.shared.get(account) else { continue }
            XCTAssertFalse(String(data: d, encoding: .utf8)?.contains(pin) ?? false,
                           "Plaintext PIN must never be stored")
        }
    }

    func testCorrectPINAccepted() {
        PINService.shared.setPIN(pin)
        XCTAssertTrue(PINService.shared.verify(pin))
    }

    func testIncorrectPINRejected() {
        PINService.shared.setPIN(pin)
        XCTAssertFalse(PINService.shared.verify("0000"))
    }

    func testRepeatedFailuresTriggerLockout() {
        PINService.shared.setPIN(pin)
        for _ in 0..<4 {
            XCTAssertFalse(PINService.shared.verify("9999"))
        }
        // The 5th consecutive failure triggers lockout; subsequent attempts are
        // rejected even with the correct PIN.
        XCTAssertFalse(PINService.shared.verify("9999"))
        XCTAssertNotNil(PINService.shared.lockoutUntil)
        XCTAssertFalse(PINService.shared.verify(pin), "Correct PIN must be rejected during lockout")
    }

    func testLockoutNotResetByClearingUserDefaults() {
        PINService.shared.setPIN(pin)
        for _ in 0..<5 { _ = PINService.shared.verify("9999") }
        XCTAssertNotNil(PINService.shared.lockoutUntil)

        // Wiping UserDefaults must NOT clear the lockout (stored in Keychain).
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        XCTAssertNotNil(PINService.shared.lockoutUntil,
                       "Lockout must persist in Keychain, not UserDefaults")
    }

    func testVaultKeyStoredOnlyInKeychain() async {
        await KeychainService.shared.ensureVaultKeyExists()
        let key = try? KeychainService.shared.vaultKey()
        XCTAssertNotNil(key)
        XCTAssertEqual(key?.count, 32)

        // The key must not be mirrored into UserDefaults.
        let all = UserDefaults.standard.dictionaryRepresentation()
        let leak = all.values.contains { ($0 as? Data) == key }
        XCTAssertFalse(leak, "Vault key must not be stored in UserDefaults")
    }

    func testDisableClearsAllPINMaterial() {
        PINService.shared.setPIN(pin)
        PINService.shared.disable()
        XCTAssertFalse(PINService.shared.isEnabled)
        XCTAssertNil(KeychainService.shared.get(KeychainService.Key.pinVerifier))
        XCTAssertNil(KeychainService.shared.get(KeychainService.Key.pinSalt))
    }
}
