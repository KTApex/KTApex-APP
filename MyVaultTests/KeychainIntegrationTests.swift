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

    func testDecoyPINVerificationAndRejectionOfSamePIN() {
        PINService.shared.setPIN("2468")
        XCTAssertFalse(PINService.shared.setDecoyPIN("2468"),
                       "Decoy PIN must not be identical to the primary PIN")
        XCTAssertTrue(PINService.shared.setDecoyPIN("9753"))
        XCTAssertTrue(PINService.shared.isDecoyEnabled)

        XCTAssertEqual(PINService.shared.verifyWithMode("2468"), .primary)
        XCTAssertEqual(PINService.shared.verifyWithMode("9753"), .decoy)
        XCTAssertNil(PINService.shared.verifyWithMode("0000"))

        PINService.shared.disable()
        XCTAssertFalse(PINService.shared.isDecoyEnabled)
    }

    func testSecureNoteServiceEncryptsAndDecryptsNotes() async throws {
        await KeychainService.shared.ensureVaultKeyExists()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyVaultNoteTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let service = SecureNoteService(directory: scratch)
        let note = SecureNote(title: "Secret Journal", body: "Private thought", isPinned: true)
        try service.save(note)

        let files = try FileManager.default.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let rawBytes = try Data(contentsOf: files[0])
        XCTAssertFalse(String(data: rawBytes, encoding: .utf8)?.contains("Secret Journal") ?? false,
                       "Note title and body must be encrypted at rest on disk")

        let loaded = service.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.title, "Secret Journal")
        XCTAssertEqual(loaded.first?.body, "Private thought")
        XCTAssertTrue(loaded.first?.isPinned ?? false)

        service.delete(id: note.id)
        XCTAssertTrue(service.loadAll().isEmpty)
    }

    func testFailedPINAttemptsRecordedInSecurityAuditLog() {
        PINService.shared.setPIN("2468")
        PINService.shared.clearSecurityEvents()
        XCTAssertTrue(PINService.shared.securityEvents().isEmpty)

        XCTAssertNil(PINService.shared.verifyWithMode("1111"))
        XCTAssertNil(PINService.shared.verifyWithMode("2222"))

        let events = PINService.shared.securityEvents()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first?.attemptNumber, 2, "Most recent event is listed first")

        PINService.shared.recordSecurityNote("Auto-locked due to screenshot")
        XCTAssertEqual(PINService.shared.securityEvents().count, 3)
        XCTAssertEqual(PINService.shared.securityEvents().first?.note, "Auto-locked due to screenshot")

        PINService.shared.clearSecurityEvents()
        XCTAssertTrue(PINService.shared.securityEvents().isEmpty)
    }
}
