import SwiftUI
import UIKit

/// The system share sheet.
///
/// `ShareLink` is the modern SwiftUI way to share, but it cannot tell the vault
/// when the sheet finished with the exported file. The share flow needs that
/// signal to decide when decrypted plaintext can be removed, so the activity
/// controller is presented directly and its completion handler is forwarded.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    var onComplete: ((Bool) -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            onComplete?(completed)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Presents a prepared vault share and retires its plaintext afterwards.
private struct ShareSheetModifier: ViewModifier {
    @Binding var prepared: ShareService.Prepared?
    let onSkipped: ([String]) -> Void

    func body(content: Content) -> some View {
        content.sheet(item: $prepared) { bundle in
            ActivityView(items: bundle.urls) { _ in
                if !bundle.skipped.isEmpty { onSkipped(bundle.skipped) }
                // Deferred, not immediate: AirDrop and "Save to Files" read the
                // file *after* the sheet reports completion.
                ShareService.shared.scheduleCleanup(bundle)
                prepared = nil
            }
        }
    }
}

extension View {
    /// Presents the native share sheet for decrypted vault media.
    /// - Parameter onSkipped: called with the display names of items that could
    ///   not be prepared, so the caller can tell the user what was left out.
    func vaultShareSheet(
        prepared: Binding<ShareService.Prepared?>,
        onSkipped: @escaping ([String]) -> Void = { _ in }
    ) -> some View {
        modifier(ShareSheetModifier(prepared: prepared, onSkipped: onSkipped))
    }
}
