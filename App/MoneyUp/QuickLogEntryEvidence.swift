import Foundation
import MoneyUpCore
import PhotosUI
import SwiftUI

extension QuickLogEntryView {
    func addEvidencePhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        isPreparingEvidence = true
        evidenceMessage = nil
        defer {
            isPreparingEvidence = false
            evidencePhotoItems = []
            evidencePreparationTask = nil
        }

        do {
            for item in items.prefix(remainingEvidenceCapacity) {
                try Task.checkCancellation()
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw ReceiptAttachmentError.invalidMetadata
                }
                let ordinal = attachmentDrafts.count + 1
                let draft = try await EvidenceAttachmentPreparer.image(
                    data: data,
                    displayName: String(
                        format: AppLocalization.string("evidence.photo_numbered"),
                        ordinal
                    )
                )
                try appendEvidence(draft)
            }
            evidenceMessage = AppLocalization.string("evidence.ready")
        } catch is CancellationError {
            return
        } catch {
            evidenceMessage = evidenceErrorMessage(error)
        }
    }

    func addEvidencePDFs(_ result: Result<[URL], Error>) async {
        isPreparingEvidence = true
        evidenceMessage = nil
        defer {
            isPreparingEvidence = false
            evidencePreparationTask = nil
        }
        do {
            for url in try result.get().prefix(remainingEvidenceCapacity) {
                try Task.checkCancellation()
                let hasAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if hasAccess { url.stopAccessingSecurityScopedResource() }
                }
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                if let size = values.fileSize,
                   size > ReceiptAttachment.maximumByteCount {
                    throw ReceiptAttachmentError.tooLarge
                }
                let data = try await EvidenceAttachmentPreparer.localPDFData(
                    from: url
                )
                let draft = try await EvidenceAttachmentPreparer.pdf(
                    data: data,
                    displayName: url.lastPathComponent
                )
                try appendEvidence(draft)
            }
            evidenceMessage = AppLocalization.string("evidence.ready")
        } catch is CancellationError {
            return
        } catch {
            evidenceMessage = evidenceErrorMessage(error)
        }
    }

    private func appendEvidence(_ draft: ReceiptAttachmentDraft) throws {
        try ReceiptAttachment.validateEntryLimits(
            existingByteCounts: retainReceiptAttachment
                ? receiptAttachmentData.map { [$0.count] } ?? []
                : [],
            adding: attachmentDrafts + [draft]
        )
        attachmentDrafts.append(draft)
    }

    private func evidenceErrorMessage(_ error: Error) -> String {
        switch error as? ReceiptAttachmentError {
        case .tooManyAttachments:
            return AppLocalization.string("evidence.error_count")
        case .tooLarge:
            return AppLocalization.string("evidence.error_file_size")
        case .totalTooLarge:
            return AppLocalization.string("evidence.error_total_size")
        case .emptyData, .invalidMetadata:
            return AppLocalization.string("evidence.error_unreadable")
        case nil:
            return AppLocalization.string("evidence.error_unreadable")
        }
    }
}
