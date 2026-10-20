import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Captures a photo or video directly from the device camera into memory so it is
/// encrypted straight into MyVault without ever being written to the Apple Photos library.
struct SecureCameraPicker: UIViewControllerRepresentable {
    let onCapture: (ImportPayload) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isCameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onDismiss: { dismiss() })
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        picker.videoQuality = .typeHigh
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onCapture: (ImportPayload) -> Void
        let onDismiss: () -> Void

        init(onCapture: @escaping (ImportPayload) -> Void, onDismiss: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onDismiss = onDismiss
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onDismiss()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let now = Date()
            if let mediaURL = info[.mediaURL] as? URL {
                defer { try? FileManager.default.removeItem(at: mediaURL) }
                if let data = try? Data(contentsOf: mediaURL), !data.isEmpty {
                    let ext = mediaURL.pathExtension.isEmpty ? "mov" : mediaURL.pathExtension
                    let payload = ImportPayload(
                        data: data,
                        assetIdentifier: nil,
                        suggestedFileName: "Camera_\(Int(now.timeIntervalSince1970)).\(ext)",
                        capturedAt: now
                    )
                    onCapture(payload)
                }
            } else if let image = (info[.editedImage] ?? info[.originalImage]) as? UIImage,
                      let data = image.jpegData(compressionQuality: 0.92) {
                let payload = ImportPayload(
                    data: data,
                    assetIdentifier: nil,
                    suggestedFileName: "Camera_\(Int(now.timeIntervalSince1970)).jpg",
                    capturedAt: now
                )
                onCapture(payload)
            }
            onDismiss()
        }
    }
}
