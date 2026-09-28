import SwiftUI
import UIKit
import VisionKit

/// The system document camera: finds the receipt's edges, straightens it and
/// returns a clean page, all on this iPhone. The page then goes through the
/// same private, on-device reading as a chosen photo.
struct ReceiptDocumentCamera: UIViewControllerRepresentable {
    /// Devices without a camera (and the simulator) keep the photo picker.
    static var isAvailable: Bool { VNDocumentCameraViewController.isSupported }

    let onScan: (Data) -> Void
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let camera = VNDocumentCameraViewController()
        camera.delegate = context.coordinator
        return camera
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onFinish: onFinish)
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let onScan: (Data) -> Void
        private let onFinish: () -> Void

        init(onScan: @escaping (Data) -> Void, onFinish: @escaping () -> Void) {
            self.onScan = onScan
            self.onFinish = onFinish
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            // A receipt is one page; the first is the one read.
            if scan.pageCount > 0, let data = scan.imageOfPage(at: 0).jpegData(compressionQuality: 0.9) {
                onScan(data)
            }
            onFinish()
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish()
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            onFinish()
        }
    }
}
