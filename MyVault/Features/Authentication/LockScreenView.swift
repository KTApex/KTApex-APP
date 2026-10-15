import SwiftUI

struct LockScreenView: View {
    @EnvironmentObject private var appState: AppState
    @State private var pin = ""
    @State private var error: String?
    @State private var isAuthenticating = false
    private let pinService = PINService.shared

    /// Biometrics are offered unless the user switched them off in Settings while
    /// keeping a PIN as the fallback unlock method.
    private var biometricUnlockAllowed: Bool { AppSettingsStore.biometricUnlockAllowed }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("MyVault").font(MVFont.greeting)
            Text("Private memories. Special moments.")
                .foregroundStyle(.secondary)

            if isAuthenticating {
                ProgressView("Authenticating…")
            } else if pinService.isEnabled {
                SecureField("Enter PIN", text: $pin)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 220)
                    .accessibilityLabel("Enter PIN")
                    .onSubmit(unlockWithPIN)
                if let error {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
                Button("Unlock with PIN") { unlockWithPIN() }
                    .buttonStyle(.borderedProminent)
                if biometricUnlockAllowed {
                    Button("Use biometrics") { unlockWithBiometrics() }
                }
            } else {
                Button("Unlock with Face ID / Passcode") { unlockWithBiometrics() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Unlock with biometrics or device passcode")
            }
            Spacer()
        }
        .padding()
        .onAppear { if biometricUnlockAllowed { unlockWithBiometrics() } }
    }

    private func unlockWithBiometrics() {
        isAuthenticating = true
        Task {
            do {
                let ok = try await AuthenticationService.shared.authenticate(reason: "Unlock MyVault")
                await MainActor.run {
                    isAuthenticating = false
                    if ok {
                        Haptics.success()
                        appState.isUnlocked = true
                    }
                }
            } catch {
                await MainActor.run {
                    isAuthenticating = false
                    if PINService.shared.isEnabled == false {
                        self.error = error.localizedDescription
                    }
                }
            }
        }
    }

    private func unlockWithPIN() {
        if pinService.verify(pin) {
            Haptics.success()
            pin = ""
            error = nil
            appState.isUnlocked = true
        } else {
            Haptics.error()
            if let until = pinService.lockoutUntil, until > Date() {
                error = "Too many attempts. Try again later."
            } else {
                error = "Incorrect PIN. Please try again."
            }
            pin = ""
        }
    }
}
