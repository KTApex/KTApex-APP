import Foundation
import CryptoKit

/// PIN authentication gate.
///
/// SECURITY MODEL:
/// - The PIN is *only* an in-app gate, NOT a source of the vault encryption key.
///   The 256-bit vault key is generated independently and stored in the Keychain;
///   the PIN never derives it. This means cracking the PIN verifier can only
///   reproduce the UI unlock — it does not yield the vault key (which is bound to
///   the device through iOS Data Protection).
/// - The PIN is never stored. A salted, iteratively-stretched SHA-256 verifier is
///   stored in the Keychain; brute-force resistance comes from the iteration count.
/// - Failed-attempt counter and lockout timestamp are stored in the Keychain (not
///   UserDefaults) so resetting app preferences cannot defeat rate limiting.
final class PINService {
    static let shared = PINService()
    private let attemptsAccount = "mv.pinAttempts"
    private let lockoutAccount = "mv.pinLockoutUntil"
    /// Iterations for the salted hash. Slows offline brute force of short PINs.
    private let iterations = 120_000
    private init() {}

    var isEnabled: Bool {
        KeychainService.shared.get(KeychainService.Key.pinVerifier) != nil
    }

    static func isValidPIN(_ pin: String) -> Bool {
        pin.count >= 4 && pin.count <= 8 && pin.allSatisfy(\.isNumber)
    }

    func setPIN(_ pin: String) {
        // 16-byte cryptographically-random salt.
        var saltBytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { saltBytes[i] = UInt8.random(in: 0...255) }
        let salt = Data(saltBytes)
        let verifier = derive(pin: pin, salt: salt)
        KeychainService.shared.set(salt, for: KeychainService.Key.pinSalt)
        KeychainService.shared.set(verifier, for: KeychainService.Key.pinVerifier)
        // Reset rate limiting on (re)set.
        KeychainService.shared.delete(attemptsAccount)
        KeychainService.shared.delete(lockoutAccount)
    }

    func verify(_ pin: String) -> Bool {
        if let untilData = KeychainService.shared.get(lockoutAccount),
           let str = String(data: untilData, encoding: .utf8),
           let ts = Double(str), Date(timeIntervalSince1970: ts) > Date() {
            return false
        }
        guard let salt = KeychainService.shared.get(KeychainService.Key.pinSalt),
              let stored = KeychainService.shared.get(KeychainService.Key.pinVerifier) else { return false }
        if constantTimeEquals(derive(pin: pin, salt: salt), stored) {
            resetAttempts()
            return true
        }
        recordFailure()
        return false
    }

    func disable() {
        KeychainService.shared.delete(KeychainService.Key.pinVerifier)
        KeychainService.shared.delete(KeychainService.Key.pinSalt)
        KeychainService.shared.delete(attemptsAccount)
        KeychainService.shared.delete(lockoutAccount)
    }

    var lockoutUntil: Date? {
        guard let data = KeychainService.shared.get(lockoutAccount),
              let str = String(data: data, encoding: .utf8),
              let ts = Double(str) else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    // MARK: - Internals

    /// Iteratively stretched SHA-256 (PBKDF-style). Because the PIN is not the
    /// source of the vault key, choosing SHA-256 here is acceptable; the iteration
    /// count provides the brute-force cost for short PINs.
    private func derive(pin: String, salt: Data) -> Data {
        var state = salt + Data(pin.utf8)
        for _ in 0..<iterations {
            state = Data(SHA256.hash(data: state))
        }
        return state
    }

    private func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    private var attemptCount: Int {
        guard let data = KeychainService.shared.get(attemptsAccount),
              let str = String(data: data, encoding: .utf8) else { return 0 }
        return Int(str) ?? 0
    }

    private func recordFailure() {
        let n = attemptCount + 1
        KeychainService.shared.set(Data(String(n).utf8), for: attemptsAccount)
        if n >= 5 {
            let until = Date().addingTimeInterval(60)
            KeychainService.shared.set(Data(String(until.timeIntervalSince1970).utf8), for: lockoutAccount)
            KeychainService.shared.delete(attemptsAccount)
        }
    }

    private func resetAttempts() {
        KeychainService.shared.delete(attemptsAccount)
        KeychainService.shared.delete(lockoutAccount)
    }
}
