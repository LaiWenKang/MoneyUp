import Foundation
@testable import MoneyUpCore
import Testing

struct ReceiptAttachmentTests {
    @Test
    func detectsOnlyFormatsWhoseSignaturesArePresent() {
        let jpeg = Data([0xff, 0xd8, 0xff, 0xe0])
        let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        let heic = Data([0, 0, 0, 24])
            + Data("ftypheic".utf8)
            + Data([0, 0, 0, 0])
            + Data("mif1heic".utf8)
        let pdf = Data("%PDF-1.7\n".utf8)

        #expect(ReceiptAttachmentMediaType.detected(from: jpeg) == .jpeg)
        #expect(ReceiptAttachmentMediaType.detected(from: png) == .png)
        #expect(ReceiptAttachmentMediaType.detected(from: heic) == .heic)
        #expect(ReceiptAttachmentMediaType.detected(from: pdf) == .pdf)
    }

    @Test
    func doesNotMislabelOtherIsoBaseMediaOrRandomBytesAsHeicOrJpeg() {
        let avif = Data([0, 0, 0, 24])
            + Data("ftypavif".utf8)
            + Data([0, 0, 0, 0])
            + Data("mif1avif".utf8)
        let avifWithHeicOutsideFileTypeBox = avif + Data("heic".utf8)
        let impossibleSize = Data([0, 0, 1, 0])
            + Data("ftypheic".utf8)
            + Data([0, 0, 0, 0])

        #expect(ReceiptAttachmentMediaType.detected(from: avif) == .unknown)
        #expect(
            ReceiptAttachmentMediaType.detected(from: avifWithHeicOutsideFileTypeBox)
                == .unknown
        )
        #expect(ReceiptAttachmentMediaType.detected(from: impossibleSize) == .unknown)
        #expect(
            ReceiptAttachmentMediaType.detected(from: Data("not an image".utf8))
                == .unknown
        )
    }

    @Test
    func enforcesPerTransactionEvidenceLimits() throws {
        let draft = try ReceiptAttachmentDraft(
            mediaType: .pdf,
            data: Data("%PDF-1.7".utf8),
            displayName: "invoice.pdf",
            searchText: "IKEA Alexandra SGD 129.90"
        )

        #expect(throws: ReceiptAttachmentError.tooManyAttachments) {
            try ReceiptAttachment.validateEntryLimits(
                existingByteCounts: Array(repeating: 1, count: 5),
                adding: [draft]
            )
        }
        #expect(throws: ReceiptAttachmentError.totalTooLarge) {
            try ReceiptAttachment.validateEntryLimits(
                existingByteCounts: [ReceiptAttachment.maximumTotalByteCountPerEntry],
                adding: [draft]
            )
        }
        #expect(throws: ReceiptAttachmentError.invalidMetadata) {
            try ReceiptAttachmentDraft(
                mediaType: .jpeg,
                data: Data("%PDF-1.7".utf8)
            )
        }
    }

    @Test
    func draftRetainsOnlyBoundedSearchMetadata() throws {
        let longName = String(repeating: "é", count: 500)
        let draft = try ReceiptAttachmentDraft(
            mediaType: .pdf,
            data: Data("%PDF-1.7".utf8),
            displayName: longName,
            searchText: String(repeating: "receipt ", count: 5_000),
            classificationLabels: Array(repeating: "document", count: 30)
        )

        #expect((draft.displayName?.utf8.count ?? 0)
            <= ReceiptAttachment.maximumDisplayNameUTF8Count)
        #expect((draft.searchText?.utf8.count ?? 0)
            <= ReceiptAttachment.maximumSearchTextUTF8Count)
        #expect(draft.classificationLabels == ["document"])
    }
}
