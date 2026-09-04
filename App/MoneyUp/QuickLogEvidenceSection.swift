import Foundation
import MoneyUpCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

extension QuickLogEntryView {
    var remainingEvidenceCapacity: Int {
        let retainedScanCount = retainReceiptAttachment
            && receiptAttachmentData != nil ? 1 : 0
        return max(
            0,
            ReceiptAttachment.maximumCountPerEntry
                - retainedScanCount
                - attachmentDrafts.count
        )
    }

    var evidenceSection: some View {
        Section {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { evidencePhotoButton; evidencePDFButton }
                VStack(alignment: .leading, spacing: 12) {
                    evidencePhotoButton
                    evidencePDFButton
                }
            }
            if isPreparingEvidence {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("evidence.preparing").foregroundStyle(.secondary)
                }
            }
            ForEach(attachmentDrafts) { attachment in
                HStack(spacing: 12) {
                    Image(systemName: attachment.mediaType == .pdf
                        ? "doc.richtext.fill" : "photo.fill")
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachment.displayName ?? AppLocalization.string(
                            attachment.mediaType == .pdf
                                ? "evidence.pdf" : "evidence.photo"
                        ))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(ByteCountFormatter.string(
                            fromByteCount: Int64(attachment.data.count),
                            countStyle: .file
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        attachmentDrafts.removeAll { $0.id == attachment.id }
                        evidenceMessage = nil
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("evidence.remove")
                }
            }
            if let evidenceMessage {
                Text(evidenceMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("evidence.title")
        } footer: {
            Text("evidence.encrypted_detail")
        }
    }

    private var evidencePhotoButton: some View {
        Button {
            isPresentingEvidencePhotoPicker = true
        } label: {
            Label("evidence.add_photos", systemImage: "photo.on.rectangle.angled")
        }
        .disabled(
            isPreparingEvidence
                || remainingEvidenceCapacity == 0
        )
        .photosPicker(
            isPresented: $isPresentingEvidencePhotoPicker,
            selection: $evidencePhotoItems,
            maxSelectionCount: max(1, remainingEvidenceCapacity),
            matching: .images
        )
    }

    private var evidencePDFButton: some View {
        Button {
            isPresentingEvidencePDFPicker = true
        } label: {
            Label("evidence.add_pdf", systemImage: "doc.badge.plus")
        }
        .disabled(
            isPreparingEvidence
                || remainingEvidenceCapacity == 0
        )
        .fileImporter(
            isPresented: $isPresentingEvidencePDFPicker,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: true
        ) { result in
            evidencePreparationTask?.cancel()
            evidencePreparationTask = Task { @MainActor in
                await addEvidencePDFs(result)
            }
        }
    }
}
