import Foundation
import MoneyUpCore
import PDFKit
import UIKit
import Vision

enum EvidenceAttachmentPreparer {
    static func localPDFData(from url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let limit = ReceiptAttachment.maximumByteCount + 1
            guard let data = try handle.read(upToCount: limit), !data.isEmpty else {
                throw ReceiptAttachmentError.emptyData
            }
            guard data.count <= ReceiptAttachment.maximumByteCount else {
                throw ReceiptAttachmentError.tooLarge
            }
            try Task.checkCancellation()
            return data
        }.value
    }

    static func image(
        data: Data,
        displayName: String?
    ) async throws -> ReceiptAttachmentDraft {
        async let sanitizedValue = ReceiptImageSanitizer.prepareForEncryptedStorage(data)
        async let recognizedValue = recognizedText(in: data)
        async let labelsValue = classificationLabels(in: data)
        let (sanitized, recognizedText, labels) = try await (
            sanitizedValue,
            recognizedValue,
            labelsValue
        )
        return try ReceiptAttachmentDraft(
            mediaType: .detected(from: sanitized),
            data: sanitized,
            displayName: displayName,
            searchText: recognizedText,
            classificationLabels: labels
        )
    }

    static func pdf(
        data: Data,
        displayName: String?
    ) async throws -> ReceiptAttachmentDraft {
        guard ReceiptAttachmentMediaType.detected(from: data) == .pdf else {
            throw ReceiptAttachmentError.invalidMetadata
        }
        guard data.count <= ReceiptAttachment.maximumByteCount else {
            throw ReceiptAttachmentError.tooLarge
        }
        let text = try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let document = PDFDocument(data: data), document.pageCount > 0 else {
                throw ReceiptAttachmentError.invalidMetadata
            }
            // Embedded text is exact document evidence. Scanned PDFs remain
            // attachable even when they contain no searchable text.
            let pageLimit = min(document.pageCount, 80)
            var parts: [String] = []
            for index in 0..<pageLimit {
                if index.isMultiple(of: 8) { try Task.checkCancellation() }
                guard let value = document.page(at: index)?.string else { continue }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { parts.append(trimmed) }
            }
            return parts.joined(separator: "\n")
        }.value
        return try ReceiptAttachmentDraft(
            mediaType: .pdf,
            data: data,
            displayName: displayName,
            searchText: text
        )
    }

    private static func recognizedText(in data: Data) async -> String? {
        do {
            let result = try await ReceiptScanner.recognize(inImageData: data)
            let text = result.lines.joined(separator: "\n")
            return text.isEmpty ? nil : text
        } catch {
            // Search enrichment is best effort; a valid photo remains useful
            // evidence even when it contains no readable text.
            return nil
        }
    }

    private static func classificationLabels(in data: Data) async -> [String] {
        (try? await Task.detached(priority: .utility) {
            try Task.checkCancellation()
            guard let image = UIImage(data: data)?.cgImage else { return [] }
            let request = VNClassifyImageRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])
            try Task.checkCancellation()
            return (request.results ?? [])
                .filter { $0.confidence >= 0.20 }
                .prefix(ReceiptAttachment.maximumClassificationLabelCount)
                .map(\.identifier)
        }.value) ?? []
    }
}
