import Foundation
import LocalAuthentication

enum AuthError: Error, LocalizedError {
    case notAvailable
    case failed
    case cancelled
    case lockout

    var errorDescription: String? {
        switch self {
        case .notAvailable: return "Biometric authentication is not available on this device."
        case .failed: return "Authentication failed. Please try again."
        case .cancelled: return "Authentication was cancelled."
        case .lockout: return "Too many attempts. Please try again later."
        }
    }
}

final class AuthenticationService {
    static let shared = AuthenticationService()
    private init() {}

    func biometricType() -> LABiometryType {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return ctx.biometryType
    }

    func canUseBiometrics() -> Bool {
        let ctx = LAContext()
        var e: NSError?
        return ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &e)
    }

    func authenticate(reason: String = "Unlock MyVault") async throws -> Bool {
        let ctx = LAContext()
        ctx.localizedCancelTitle = "Cancel"
        var e: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &e) else {
            throw AuthError.notAvailable
        }
        do {
            return try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch LAError.userCancel {
            throw AuthError.cancelled
        } catch {
            throw AuthError.failed
        }
    }
}
