import AppIntents
import Foundation

struct OpenVaultIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Vault"
    static var description = IntentDescription("Opens MyVault.")

    func perform() async throws -> some IntentResult {
        .result()
    }
}

struct ShowNextSpecialDayIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Next Special Day"
    static var description = IntentDescription("Shows the next upcoming special day.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "Open MyVault to see your next special day.")
    }
}
