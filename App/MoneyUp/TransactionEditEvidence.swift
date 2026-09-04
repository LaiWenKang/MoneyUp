import Foundation
import MoneyUpCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

extension TransactionEditView {
    var remainingEvidenceCapacity: Int {
        max(
            0,
            ReceiptAttachment.maximumCountPerEntry
                - attachmentMetadata.count
                - pendingEvidence.count
        )
    }

    var editEvidencePhotoButton: some View {
        Button {
            isPresentingEvidencePhotoPicker = true
        } label: {
            Label("evidence.add_photos", systemImage: "photo.on.rectangle.angled")
        }
        .disabled(isPreparingEvidence || remainingEvidenceCapacity == 0)
        .photosPicker(
            isPresented: $isPresentingEvidencePhotoPicker,
            selection: $evidencePhotoItems,
            maxSelectionCount: max(1, remainingEvidenceCapacity),
            matching: .images
        )
    }

    var editEvidencePDFButton: some View {
        Button {
            isPresentingEvidencePDFPicker = true
        } label: {
            Label("evidence.add_pdf", systemImage: "doc.badge.plus")
        }
        .disabled(isPreparingEvidence || remainingEvidenceCapacity == 0)
        .fileImporter(
            isPresented: $isPresentingEvidencePDFPicker,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: true
        ) { result in
            evidencePreparationTask?.cancel()
            evidencePreparationTask = Task { @MainActor in
                await addEditEvidencePDFs(result)
            }
        }
    }

    func addEditEvidencePhotos(_ items: [PhotosPickerItem]) async {
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
                let ordinal = attachmentMetadata.count + pendingEvidence.count + 1
                let draft = try await EvidenceAttachmentPreparer.image(
                    data: data,
                    displayName: String(
                        format: AppLocalization.string("evidence.photo_numbered"),
                        ordinal
                    )
                )
                try appendEditEvidence(draft)
            }
            evidenceMessage = AppLocalization.string("evidence.ready")
        } catch is CancellationError {
            return
        } catch {
            evidenceMessage = editEvidenceErrorMessage(error)
        }
    }

    func addEditEvidencePDFs(_ result: Result<[URL], Error>) async {
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
                try appendEditEvidence(draft)
            }
            evidenceMessage = AppLocalization.string("evidence.ready")
        } catch is CancellationError {
            return
        } catch {
            evidenceMessage = editEvidenceErrorMessage(error)
        }
    }

    private func appendEditEvidence(_ draft: ReceiptAttachmentDraft) throws {
        try ReceiptAttachment.validateEntryLimits(
            existingByteCounts: attachmentMetadata.map(\.byteCount),
            adding: pendingEvidence + [draft]
        )
        pendingEvidence.append(draft)
    }

    private func editEvidenceErrorMessage(_ error: Error) -> String {
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
