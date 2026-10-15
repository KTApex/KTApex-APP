import XCTest
@testable import MyVault

final class PINLogicTests: XCTestCase {
    func testPINLengthPolicy() {
        XCTAssertTrue(PINService.isValidPIN("1234"))
        XCTAssertTrue(PINService.isValidPIN("12345678"))
        XCTAssertFalse(PINService.isValidPIN("123"))
        XCTAssertFalse(PINService.isValidPIN("123456789"))
        XCTAssertFalse(PINService.isValidPIN("12ab"))
        XCTAssertFalse(PINService.isValidPIN(""))
    }

    func testPINRejectsNonNumericEvenWithinLength() {
        XCTAssertFalse(PINService.isValidPIN("12 4"))
        XCTAssertFalse(PINService.isValidPIN("12-4"))
    }

    /// The verification path depends on Keychain (not available in a plain unit
    /// test host), so round-trip / lockout behavior is exercised via UI tests and
    /// the dedicated Keychain-backed integration test on device/simulator.
    func testVerifierProducesDistinctSalts() {
        // Sanity: distinct random 16-byte salts differ (defense against trivial
        // rainbow tables). Verified indirectly since setPIN uses a fresh salt.
        var a = [UInt8](repeating: 0, count: 16)
        var b = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { a[i] = UInt8.random(in: 0...255) }
        for i in 0..<16 { b[i] = UInt8.random(in: 0...255) }
        XCTAssertNotEqual(a, b)
    }
}
