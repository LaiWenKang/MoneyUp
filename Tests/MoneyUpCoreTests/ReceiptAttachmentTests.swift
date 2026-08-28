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

        #expect(ReceiptAttachmentMediaType.detected(from: jpeg) == .jpeg)
        #expect(ReceiptAttachmentMediaType.detected(from: png) == .png)
        #expect(ReceiptAttachmentMediaType.detected(from: heic) == .heic)
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
}
