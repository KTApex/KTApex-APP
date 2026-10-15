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
        guard value.count >= 4, value.count <= 8, value.allSatisfy(\.isNumber) else {
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
