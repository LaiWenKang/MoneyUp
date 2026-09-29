import CoreGraphics
import CoreText
import Foundation
import ImageIO
@testable import MoneyUp
import MoneyUpCore
import PDFKit
import XCTest

/// PDFs drawn from scratch, so the reader is exercised on real files and no
/// personal document ever enters the repository.
private enum ReceiptPDFFixture {
    enum FixtureError: Error { case render }

    typealias Item = (text: String, point: CGPoint)

    /// Name and price share a baseline, drawn one after the other.
    static let orderedItems: [Item] = [
        ("Cafe Roma", CGPoint(x: 20, y: 360)),
        ("Latte", CGPoint(x: 20, y: 330)), ("4.50", CGPoint(x: 200, y: 330)),
        ("Total", CGPoint(x: 20, y: 300)), ("9.00", CGPoint(x: 200, y: 300))
    ]

    /// Every name first and every price afterwards, as some generators do, so
    /// the text layer holds them as separate lines.
    static let scrambledItems: [Item] = [
        ("Cafe Roma", CGPoint(x: 20, y: 360)),
        ("Latte", CGPoint(x: 20, y: 330)),
        ("Total", CGPoint(x: 20, y: 300)),
        ("4.50", CGPoint(x: 200, y: 330)),
        ("9.00", CGPoint(x: 200, y: 300))
    ]

    static let expectedRows = ["Cafe Roma", "Latte 4.50", "Total 9.00"]

    static func makePDF(
        size: CGSize = CGSize(width: 300, height: 400),
        auxiliary: [CFString: Any] = [:],
        draw: (CGContext) -> Void
    ) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(
                  consumer: consumer,
                  mediaBox: &box,
                  auxiliary as CFDictionary
              ) else { throw FixtureError.render }
        context.beginPDFPage(nil)
        draw(context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private static func drawText(_ text: String, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font])
        )
        CTLineDraw(line, context)
    }

    static func textPDF(
        _ items: [Item],
        userPassword: String? = nil,
        ownerPassword: String? = nil
    ) throws -> Data {
        var auxiliary: [CFString: Any] = [:]
        if let userPassword {
            auxiliary[kCGPDFContextUserPassword] = userPassword
            auxiliary[kCGPDFContextOwnerPassword] = ownerPassword ?? userPassword + "-owner"
        } else if let ownerPassword {
            auxiliary[kCGPDFContextOwnerPassword] = ownerPassword
        }
        return try makePDF(auxiliary: auxiliary) { context in
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            for item in items {
                context.textPosition = item.point
                drawText(item.text, in: context)
            }
        }
    }

    /// The receipt as it looks when the page is opened, stored on a page whose
    /// own rotation is `turns` quarter turns clockwise. `point` is the position
    /// on the displayed page, origin bottom left.
    static func rotatedTextPDF(turns: Int) throws -> Data {
        let rawWidth: CGFloat = 300
        let rawHeight: CGFloat = 400
        let displayWidth = turns.isMultiple(of: 2) ? rawWidth : rawHeight
        let displayHeight = turns.isMultiple(of: 2) ? rawHeight : rawWidth
        let items: [Item] = [
            ("Cafe Roma", CGPoint(x: 20, y: displayHeight - 40)),
            ("Latte", CGPoint(x: 20, y: displayHeight - 70)),
            ("Total", CGPoint(x: 20, y: displayHeight - 100)),
            ("4.50", CGPoint(x: displayWidth - 100, y: displayHeight - 70)),
            ("9.00", CGPoint(x: displayWidth - 100, y: displayHeight - 100))
        ]
        let raw = try makePDF(size: CGSize(width: rawWidth, height: rawHeight)) { context in
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            for item in items {
                context.saveGState()
                switch turns {
                case 1:
                    context.translateBy(x: rawWidth - item.point.y, y: item.point.x)
                    context.rotate(by: .pi / 2)
                case 2:
                    context.translateBy(x: rawWidth - item.point.x, y: rawHeight - item.point.y)
                    context.rotate(by: .pi)
                case 3:
                    context.translateBy(x: item.point.y, y: rawHeight - item.point.x)
                    context.rotate(by: -.pi / 2)
                default:
                    context.translateBy(x: item.point.x, y: item.point.y)
                }
                context.textPosition = .zero
                drawText(item.text, in: context)
                context.restoreGState()
            }
        }
        return try rotated(raw, turns: turns)
    }

    static func rotated(_ pdf: Data, turns: Int) throws -> Data {
        guard turns != 0,
              let source = PDFDocument(data: pdf),
              let page = source.page(at: 0) else { return pdf }
        page.rotation = turns * 90
        guard let data = source.dataRepresentation() else { throw FixtureError.render }
        return data
    }

    static func blankPDF(size: CGSize) throws -> Data {
        try makePDF(size: size) { _ in }
    }

    private static func image(from png: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw FixtureError.render
        }
        return image
    }

    /// A scan: one page that is a picture and carries no text at all.
    static func imageOnlyPDF(from png: Data) throws -> Data {
        let picture = try image(from: png)
        let size = CGSize(width: picture.width / 2, height: picture.height / 2)
        return try makePDF(size: size) { context in
            context.draw(picture, in: CGRect(origin: .zero, size: size))
        }
    }

    /// The same scan stored sideways with a page rotation that turns it upright,
    /// as scanners that save a landscape bitmap do.
    static func sidewaysImageOnlyPDF(from png: Data) throws -> Data {
        let picture = try image(from: png)
        let upright = CGSize(width: picture.width / 2, height: picture.height / 2)
        let raw = try makePDF(size: CGSize(width: upright.height, height: upright.width)) { context in
            context.translateBy(x: upright.height, y: 0)
            context.rotate(by: .pi / 2)
            context.draw(picture, in: CGRect(origin: .zero, size: upright))
        }
        return try rotated(raw, turns: 1)
    }
}

final class ReceiptDocumentReaderTests: XCTestCase {
    // MARK: Text the document already carries

    func testEmbeddedTextRowsFollowThePageWhateverTheDrawingOrder() async throws {
        for items in [ReceiptPDFFixture.orderedItems, ReceiptPDFFixture.scrambledItems] {
            let pdf = try ReceiptPDFFixture.textPDF(items)
            let recognition = try await ReceiptDocumentReader.recognize(pdf)
            XCTAssertEqual(recognition.lines, ReceiptPDFFixture.expectedRows)
            XCTAssertEqual(recognition.meanConfidence, 1, "Exact text carries no doubt")
            XCTAssertEqual(recognition.lineConfidences, [1, 1, 1])
            XCTAssertFalse(recognition.requiresExplicitReview)
        }
    }

    func testEmbeddedTextFeedsTheReceiptParser() async throws {
        let pdf = try ReceiptPDFFixture.textPDF(ReceiptPDFFixture.scrambledItems)
        let recognition = try await ReceiptDocumentReader.recognize(pdf)
        let result = ReceiptTextParser.analyze(
            fromLines: recognition.lines,
            ocrConfidence: recognition.meanConfidence,
            ocrLineConfidences: recognition.lineConfidences
        )
        XCTAssertTrue(
            result.amountCandidates.contains(Decimal(string: "9.00")!),
            "Read: \(recognition.lines)"
        )
    }

    func testRotatedPagesAreReadTopToBottomAsTheyAreShown() async throws {
        for turns in 0...3 {
            let pdf = try ReceiptPDFFixture.rotatedTextPDF(turns: turns)
            let recognition = try await ReceiptDocumentReader.recognize(pdf)
            XCTAssertEqual(
                recognition.lines,
                ReceiptPDFFixture.expectedRows,
                "A page turned \(turns * 90) degrees"
            )
        }
    }

    func testTextDrawnTwiceToLookBoldIsOneRow() async throws {
        // One line drawn twice in a row is read back as one line holding its text twice.
        let consecutive = try ReceiptPDFFixture.textPDF([
            ("Cafe Roma", CGPoint(x: 20, y: 360)), ("Cafe Roma", CGPoint(x: 20.4, y: 360)),
            ("Latte", CGPoint(x: 20, y: 330)), ("4.50", CGPoint(x: 200, y: 330)),
            ("Total", CGPoint(x: 20, y: 300)), ("9.00", CGPoint(x: 200, y: 300))
        ])
        // The whole page drawn again a hair to the right is separate lines.
        let shifted: [ReceiptPDFFixture.Item] = ReceiptPDFFixture.orderedItems.map {
            (text: $0.text, point: CGPoint(x: $0.point.x + 0.3, y: $0.point.y))
        }
        let wholePage = try ReceiptPDFFixture.textPDF(ReceiptPDFFixture.orderedItems + shifted)
        for (label, pdf) in [("line", consecutive), ("page", wholePage)] {
            let recognition = try await ReceiptDocumentReader.recognize(pdf)
            XCTAssertEqual(recognition.lines, ReceiptPDFFixture.expectedRows, "Redrawn \(label)")
        }
    }

    func testAnOwnerPasswordAloneDoesNotStopTheTextBeingRead() async throws {
        let pdf = try ReceiptPDFFixture.textPDF(
            ReceiptPDFFixture.orderedItems,
            ownerPassword: "owner"
        )
        let recognition = try await ReceiptDocumentReader.recognize(pdf)
        XCTAssertEqual(recognition.lines, ReceiptPDFFixture.expectedRows)
        let readable = await ReceiptDocumentReader.isReadablePDF(pdf)
        XCTAssertTrue(readable)
    }

    // MARK: Documents that cannot be read

    func testAPasswordProtectedPDFSaysSoInsteadOfLookingEmpty() async throws {
        let pdf = try ReceiptPDFFixture.textPDF(
            ReceiptPDFFixture.orderedItems,
            userPassword: "pw"
        )
        do {
            _ = try await ReceiptDocumentReader.recognize(pdf)
            XCTFail("A locked document must not produce suggestions.")
        } catch ReceiptScannerError.lockedDocument {
        } catch {
            XCTFail("Expected lockedDocument, got \(error)")
        }
        let readable = await ReceiptDocumentReader.isReadablePDF(pdf)
        XCTAssertFalse(readable, "A locked copy could not be shown again later")
    }

    func testADamagedPDFIsUnreadable() async throws {
        let damaged = Data("%PDF-1.7\nthis is not a document".utf8)
        XCTAssertEqual(ReceiptAttachmentMediaType.detected(from: damaged), .pdf)
        do {
            _ = try await ReceiptDocumentReader.recognize(damaged)
            XCTFail("A damaged document must not produce suggestions.")
        } catch ReceiptScannerError.unreadable {
        } catch {
            XCTFail("Expected unreadable, got \(error)")
        }
        let readable = await ReceiptDocumentReader.isReadablePDF(damaged)
        XCTAssertFalse(readable)
    }

    func testAWellFormedPDFIsReadable() async throws {
        let pdf = try ReceiptPDFFixture.textPDF(ReceiptPDFFixture.orderedItems)
        let readable = await ReceiptDocumentReader.isReadablePDF(pdf)
        XCTAssertTrue(readable)
    }

    func testAPageWithoutTextOrPictureHasNothingToRead() async throws {
        let blank = try ReceiptPDFFixture.blankPDF(size: CGSize(width: 300, height: 400))
        do {
            _ = try await ReceiptDocumentReader.recognize(blank)
            XCTFail("A blank page must not produce suggestions.")
        } catch ReceiptScannerError.noTextFound {
        } catch {
            XCTFail("Expected noTextFound, got \(error)")
        }
    }

    // MARK: Scans

    func testAScanWithoutATextLayerIsReadFromItsPicture() async throws {
        let png = try ScreenshotReceiptFixture.png(style: .englishLight)
        let pdf = try ReceiptPDFFixture.imageOnlyPDF(from: png)
        let page = try XCTUnwrap(PDFDocument(data: pdf)?.page(at: 0))
        XCTAssertTrue(
            (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "The fixture must be a picture only"
        )
        let recognition = try await ReceiptDocumentReader.recognize(pdf)
        let result = ReceiptTextParser.analyze(
            fromLines: recognition.lines,
            ocrConfidence: recognition.meanConfidence,
            ocrLineConfidences: recognition.lineConfidences,
            requiresExplicitReview: recognition.requiresExplicitReview
        )
        XCTAssertTrue(
            result.amountCandidates.contains(Decimal(string: "12.34")!),
            "Read: \(recognition.lines)"
        )
    }

    func testAScanStoredSidewaysIsDrawnUprightBeforeItIsRead() async throws {
        let png = try ScreenshotReceiptFixture.png(style: .englishLight)
        let pdf = try ReceiptPDFFixture.sidewaysImageOnlyPDF(from: png)
        let recognition = try await ReceiptDocumentReader.recognize(pdf)
        let result = ReceiptTextParser.analyze(
            fromLines: recognition.lines,
            ocrConfidence: recognition.meanConfidence,
            ocrLineConfidences: recognition.lineConfidences,
            requiresExplicitReview: recognition.requiresExplicitReview
        )
        XCTAssertTrue(
            result.amountCandidates.contains(Decimal(string: "12.34")!),
            "Read: \(recognition.lines)"
        )
    }

    func testPagesAreDrawnUprightAndWithinTheSizeBudget() throws {
        let cases: [(turns: Int, width: Int, height: Int)] = [
            (0, 900, 1_200), (1, 1_200, 900), (2, 900, 1_200), (3, 1_200, 900)
        ]
        for expected in cases {
            let pdf = try ReceiptPDFFixture.rotatedTextPDF(turns: expected.turns)
            let document = try XCTUnwrap(PDFDocument(data: pdf))
            let page = try XCTUnwrap(document.page(at: 0))
            let image = try XCTUnwrap(ReceiptDocumentReader.renderedPage(page))
            XCTAssertEqual(image.width, expected.width, "Turns \(expected.turns)")
            XCTAssertEqual(image.height, expected.height, "Turns \(expected.turns)")
            withExtendedLifetime(document) {}
        }

        let poster = try ReceiptPDFFixture.blankPDF(size: CGSize(width: 5_200, height: 3_120))
        let document = try XCTUnwrap(PDFDocument(data: poster))
        let page = try XCTUnwrap(document.page(at: 0))
        let image = try XCTUnwrap(ReceiptDocumentReader.renderedPage(page))
        XCTAssertEqual(image.width, 2_600)
        XCTAssertEqual(image.height, 1_560)
        withExtendedLifetime(document) {}
    }

    // MARK: Choosing pages

    func testTextIsReadFromTheFirstPagesAndTheLast() {
        XCTAssertEqual(ReceiptDocumentReader.textPageIndexes(count: 0), [])
        XCTAssertEqual(ReceiptDocumentReader.textPageIndexes(count: 1), [0])
        XCTAssertEqual(ReceiptDocumentReader.textPageIndexes(count: 4), [0, 1, 2, 3])
        XCTAssertEqual(ReceiptDocumentReader.textPageIndexes(count: 5), [0, 1, 2, 4])
        XCTAssertEqual(ReceiptDocumentReader.textPageIndexes(count: 40), [0, 1, 2, 39])
    }

    func testScansAreDrawnFromTheFirstPageAndTheLast() {
        XCTAssertEqual(ReceiptDocumentReader.renderedPageIndexes(count: 0), [])
        XCTAssertEqual(ReceiptDocumentReader.renderedPageIndexes(count: 1), [0])
        XCTAssertEqual(ReceiptDocumentReader.renderedPageIndexes(count: 2), [0, 1])
        XCTAssertEqual(ReceiptDocumentReader.renderedPageIndexes(count: 9), [0, 8])
    }

    // MARK: Row rebuilding

    func testRowsRunTopToBottomAndLeftToRight() {
        let rows = ReceiptDocumentReader.rows(from: [
            line("9.00", 200, 300), line("Cafe Roma", 20, 360), line("4.50", 200, 330),
            line("Total", 20, 300), line("Latte", 20, 330)
        ])
        XCTAssertEqual(rows, ["Cafe Roma", "Latte 4.50", "Total 9.00"])
    }

    func testLinesJoinOnlyWhenMostOfTheirHeightIsShared() {
        // 8 of 12 points shared joins; 4 of 12 does not.
        XCTAssertEqual(
            ReceiptDocumentReader.rows(from: [line("Latte", 20, 100), line("4.50", 200, 104)]),
            ["Latte 4.50"]
        )
        XCTAssertEqual(
            ReceiptDocumentReader.rows(from: [line("Latte", 20, 100), line("4.50", 200, 108)]),
            ["4.50", "Latte"]
        )
    }

    func testTwoIdenticalPurchasesStayTwoRows() {
        let rows = ReceiptDocumentReader.rows(from: [
            line("Coffee 3.50", 20, 360, width: 90), line("Coffee 3.50", 20, 340, width: 90)
        ])
        XCTAssertEqual(rows, ["Coffee 3.50", "Coffee 3.50"])
    }

    func testTheSameWordsSideBySideStayTwoWords() {
        XCTAssertEqual(
            ReceiptDocumentReader.rows(from: [line("1", 20, 360, width: 6), line("1", 200, 360, width: 6)]),
            ["1 1"]
        )
    }

    func testRedrawnLinesJoinIntoOneRow() {
        let rows = ReceiptDocumentReader.rows(from: [
            line("Cafe Roma", 20, 360, width: 60), line("Cafe Roma", 20.3, 360, width: 60),
            line("Latte", 20, 330), line("4.50", 200, 330)
        ])
        XCTAssertEqual(rows, ["Cafe Roma", "Latte 4.50"])
    }

    func testOnlyPlainlyDoubledTextIsCollapsed() {
        // Boxes are 12 high, so one copy spans about 6 per character.
        func collapse(_ text: String, width: CGFloat) -> String {
            ReceiptDocumentReader.collapsedRedraw(line(text, 20, 360, width: width)).text
        }
        XCTAssertEqual(collapse("Cafe Roma Cafe Roma", width: 60), "Cafe Roma")
        XCTAssertEqual(collapse("Total 9.00Total 9.00", width: 55), "Total 9.00")
        XCTAssertEqual(collapse("9.00 9.00", width: 27), "9.00")
        // Two copies side by side are twice as wide, so they are real words.
        XCTAssertEqual(collapse("Thai Thai", width: 55), "Thai Thai")
        XCTAssertEqual(collapse("Cafe Roma Cafe Roma", width: 115), "Cafe Roma Cafe Roma")
        // Too short, digits alone, or not a repeat at all.
        XCTAssertEqual(collapse("1212", width: 12), "1212", "A short figure is not a redraw")
        XCTAssertEqual(collapse("12341234", width: 24), "12341234", "Digits alone are not a redraw")
        XCTAssertEqual(collapse("Tuk Tuk", width: 20), "Tuk Tuk")
        XCTAssertEqual(collapse("Cafe Roma", width: 55), "Cafe Roma")
        XCTAssertEqual(collapse("", width: 10), "")
    }

    func testRowsIgnoreBoxesThatCannotBePlaced() {
        let rows = ReceiptDocumentReader.rows(from: [
            line("Latte", 20, 330), line("Broken", .nan, 330), line("Far", 20, .infinity),
            line("Wide", 20, 300, width: .nan)
        ])
        XCTAssertEqual(rows, ["Latte"])
    }

    // MARK: Page geometry

    func testBoundsAreTurnedIntoTheOrientationTheReaderSees() {
        let box = CGRect(x: 10, y: 20, width: 300, height: 400)
        let rect = CGRect(x: 30, y: 60, width: 50, height: 12)
        let expected: [Int: CGRect] = [
            0: CGRect(x: 20, y: 40, width: 50, height: 12),
            90: CGRect(x: 40, y: 230, width: 12, height: 50),
            180: CGRect(x: 230, y: 348, width: 50, height: 12),
            270: CGRect(x: 348, y: 20, width: 12, height: 50),
            450: CGRect(x: 40, y: 230, width: 12, height: 50),
            -90: CGRect(x: 348, y: 20, width: 12, height: 50)
        ]
        for (rotation, bounds) in expected {
            XCTAssertEqual(
                ReceiptDocumentReader.displayBounds(of: rect, in: box, rotation: rotation),
                bounds,
                "Rotation \(rotation)"
            )
        }
    }

    // MARK: Deciding whether a text layer is worth trusting

    func testAWatermarkOrEmptyTextLayerIsNotEnough() {
        XCTAssertFalse(ReceiptDocumentReader.hasUsableText([]))
        XCTAssertFalse(ReceiptDocumentReader.hasUsableText(["DRAFT", "CONFIDENTIAL COPY"]))
        XCTAssertFalse(ReceiptDocumentReader.hasUsableText(["12345 67890"]))
        XCTAssertFalse(ReceiptDocumentReader.hasUsableText([
            String(repeating: "\u{E000}", count: 30) + " 123"
        ]))
    }

    func testRealWordsAndFiguresAreEnough() {
        XCTAssertTrue(ReceiptDocumentReader.hasUsableText(["Cafe Roma", "Latte 4.50"]))
        XCTAssertTrue(ReceiptDocumentReader.hasUsableText(["Total 123456789 ABC"]))
        XCTAssertTrue(ReceiptDocumentReader.hasUsableText(["星河餐厅 实付 总计 合计 23.45 元"]))
        XCTAssertTrue(ReceiptDocumentReader.hasUsableText(["Total ٣٤٥ الإجمالي المبلغ"]))
    }

    // MARK: Combining pages

    func testTwoPagesOfRecognitionAreCombinedByLineWeight() {
        let first = ReceiptRecognitionResult(
            lines: ["a", "b"], meanConfidence: 1, lineConfidences: [1, 1]
        )
        let second = ReceiptRecognitionResult(
            lines: ["c"], meanConfidence: 0.4, lineConfidences: [0.4], requiresExplicitReview: true
        )
        let combined = ReceiptDocumentReader.merged(first, second)
        XCTAssertEqual(combined.lines, ["a", "b", "c"])
        XCTAssertEqual(try XCTUnwrap(combined.meanConfidence), 0.8, accuracy: 0.0001)
        XCTAssertEqual(combined.lineConfidences, [1, 1, 0.4])
        XCTAssertTrue(combined.requiresExplicitReview)
    }

    func testCombiningKeepsUnknownConfidenceUnknown() {
        let known = ReceiptRecognitionResult(lines: ["a"], meanConfidence: 1, lineConfidences: [1])
        let unknown = ReceiptRecognitionResult(lines: ["b"])
        let combined = ReceiptDocumentReader.merged(known, unknown)
        XCTAssertEqual(combined.lines, ["a", "b"])
        XCTAssertNil(combined.meanConfidence)
        XCTAssertNil(combined.lineConfidences)
        XCTAssertFalse(combined.requiresExplicitReview)
    }

    // MARK: A file chosen from Files

    func testAFileChosenFromFilesIsReadInFull() async throws {
        let pdf = try ReceiptPDFFixture.textPDF(ReceiptPDFFixture.orderedItems)
        let url = try makeTemporaryFile(pdf)
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try await ReceiptSource.file(url).loadData()
        XCTAssertEqual(loaded, pdf)
    }

    func testAFileOverTheLimitIsRefusedBeforeItIsRead() async throws {
        let url = try makeTemporaryFile(Data(count: ReceiptAttachment.maximumByteCount + 1))
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await ReceiptSource.file(url).loadData()
            XCTFail("An oversized file must be refused.")
        } catch ReceiptAttachmentError.tooLarge {
        } catch {
            XCTFail("Expected tooLarge, got \(error)")
        }
    }

    func testAnEmptyOrMissingFileIsAnErrorNotASilentNothing() async throws {
        let empty = try makeTemporaryFile(Data())
        defer { try? FileManager.default.removeItem(at: empty) }
        do {
            _ = try await ReceiptSource.file(empty).loadData()
            XCTFail("An empty file must be refused.")
        } catch ReceiptAttachmentError.emptyData {
        } catch {
            XCTFail("Expected emptyData, got \(error)")
        }

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoneyUpReceipt-\(UUID().uuidString).pdf")
        do {
            _ = try await ReceiptSource.file(missing).loadData()
            XCTFail("A missing file must be refused.")
        } catch {
            XCTAssertTrue(error is CocoaError, "Got \(error)")
        }
    }

    // MARK: Helpers

    private func line(
        _ text: String,
        _ x: CGFloat,
        _ y: CGFloat,
        width: CGFloat = 40,
        height: CGFloat = 12
    ) -> ReceiptDocumentReader.ExtractedLine {
        ReceiptDocumentReader.ExtractedLine(
            text: text,
            bounds: CGRect(x: x, y: y, width: width, height: height)
        )
    }

    private func makeTemporaryFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoneyUpReceipt-\(UUID().uuidString).pdf")
        try data.write(to: url)
        return url
    }
}
