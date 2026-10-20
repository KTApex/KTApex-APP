import SwiftUI

struct PINSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var confirm = ""
    @State private var step = 0
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(step == 0 ? "Create a PIN" : "Confirm your PIN").font(MVFont.title)
                SecureField(step == 0 ? "Enter 4–8 digit PIN" : "Re-enter PIN", text: step == 0 ? $pin : $confirm)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .multilineTextAlignment(.center)
                    .accessibilityLabel("PIN entry")
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                MVPrimaryButton(title: step == 0 ? "Continue" : "Save PIN") { advance() }
                    .padding(.horizontal, 24)
                Spacer()
            }
            .padding()
            .navigationTitle("Vault PIN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func advance() {
        let value = step == 0 ? pin : confirm
        guard PINService.isValidPIN(value) else {
            error = "PIN must be 4–8 digits."
            return
        }
        if step == 0 { step = 1; error = nil }
        else if confirm == pin {
            PINService.shared.setPIN(pin)
            Haptics.success()
            dismiss()
        } else {
            Haptics.error()
            error = "PINs do not match. Try again."
            confirm = ""
        }
    }
}

/// Configures a secondary Decoy (Duress) PIN that unlocks into an empty decoy vault.
struct DecoyPINSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var confirm = ""
    @State private var step = 0
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(step == 0 ? "Create a Decoy PIN" : "Confirm Decoy PIN")
                    .font(MVFont.title)
                Text("Entering this PIN on the lock screen opens a clean decoy vault while keeping your real photos, albums, special days, and notes hidden.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                SecureField(step == 0 ? "Enter 4–8 digit Decoy PIN" : "Re-enter Decoy PIN", text: step == 0 ? $pin : $confirm)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .multilineTextAlignment(.center)
                    .accessibilityLabel("Decoy PIN entry")
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                MVPrimaryButton(title: step == 0 ? "Continue" : "Save Decoy PIN") { advance() }
                    .padding(.horizontal, 24)
                Spacer()
            }
            .padding()
            .navigationTitle("Decoy PIN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func advance() {
        let value = step == 0 ? pin : confirm
        guard PINService.isValidPIN(value) else {
            error = "Decoy PIN must be 4–8 digits."
            return
        }
        if step == 0 {
            step = 1
            error = nil
        } else if confirm == pin {
            if PINService.shared.setDecoyPIN(pin) {
                Haptics.success()
                dismiss()
            } else {
                Haptics.error()
                error = "Decoy PIN must be different from your primary Vault PIN."
                step = 0
                pin = ""
                confirm = ""
            }
        } else {
            Haptics.error()
            error = "PINs do not match. Try again."
            confirm = ""
        }
    }
}
