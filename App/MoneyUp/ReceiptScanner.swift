import CoreGraphics
import Foundation
import ImageIO
import UIKit
import Vision

enum ReceiptScannerError: Error, LocalizedError {
    case unreadableImage
    case noTextFound

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            return String(localized: "scan.error_unreadable")
        case .noTextFound:
            return String(localized: "scan.error_no_text")
        }
    }
}

/// Reads text off a receipt photo or screenshot using the Vision framework.
///
/// Recognition runs entirely on the device. The image is never uploaded, is
/// not written to the database, and is released as soon as the text has been
/// extracted, so adding this feature does not change what MoneyUp stores or
/// what leaves the phone.
enum ReceiptScanner {
    static func recognizeLines(inImageData data: Data) async throws -> [String] {
        guard let image = UIImage(data: data), let cgImage = image.cgImage else {
            throw ReceiptScannerError.unreadableImage
        }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        let lines = try await recognizeLines(in: cgImage, orientation: orientation)
        guard !lines.isEmpty else { throw ReceiptScannerError.noTextFound }
        return lines
    }

    private static func recognizeLines(
        in image: CGImage,
        orientation: CGImagePropertyOrientation
    ) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                continuation.resume(returning: readingOrderText(from: observations))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US", "zh-Hans"]

            let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Vision reports observations in confidence order with a bottom-left
    /// origin. Receipt parsing depends on reading order, so sort top to bottom.
    private static func readingOrderText(
        from observations: [VNRecognizedTextObservation]
    ) -> [String] {
        observations
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            .compactMap { $0.topCandidates(1).first?.string }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
