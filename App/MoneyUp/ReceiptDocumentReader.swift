import CoreGraphics
import Foundation
import ImageIO
import MoneyUpCore
import PDFKit
import UniformTypeIdentifiers

/// Turns whatever was chosen for Smart Entry (a photo, a screenshot or a PDF)
/// into lines of receipt text for the parser.
///
/// A PDF that carries its own text is read directly: the words are exact, so
/// nothing is recognised and no doubt has to be discounted. A PDF made of
/// scanned pictures has no usable text; its first and last pages are drawn to
/// bitmaps and read by the same Vision reader photos use. Nothing is stored,
/// uploaded or logged here, and every step is cancellable.
enum ReceiptDocumentReader {
    /// One line of embedded text with its box in display space (origin at the
    /// bottom left, y up), as the page looks when opened.
    struct ExtractedLine: Equatable, Sendable {
        let text: String
        let bounds: CGRect
    }

    private enum PDFReading: Sendable {
        case text([String])
        case pages([Data])
    }

    private static let maximumTextPages = 4
    private static let maximumRowsPerPage = 200
    private static let maximumCharactersPerPage = 60_000
    private static let maximumLineCharacters = 1_024
    private static let minimumAlphanumerics = 12
    private static let minimumDigits = 3
    private static let maximumRenderPixels: CGFloat = 2_600
    private static let maximumRenderScale: CGFloat = 3
    /// A character is about half a line high, so one copy of a text spans about
    /// half a line height per character and two copies side by side a whole one;
    /// three quarters divides them.
    private static let maximumRedrawWidthPerCharacter: CGFloat = 0.75

    static func recognize(_ data: Data) async throws -> ReceiptRecognitionResult {
        guard ReceiptAttachmentMediaType.detected(from: data) == .pdf else {
            return try await ReceiptScanner.recognize(inImageData: data)
        }
        // A detached task does not inherit cancellation, so forward it: leaving
        // the sheet must stop a large document from being drawn or read.
        let work = Task.detached(priority: .userInitiated) {
            try Self.readPDF(data)
        }
        let reading = try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
        switch reading {
        case let .text(rows):
            return ReceiptRecognitionResult(
                lines: rows,
                meanConfidence: 1,
                lineConfidences: Array(repeating: 1, count: rows.count)
            )
        case let .pages(images):
            return try await recognizeScannedPages(images)
        }
    }

    /// True when the document opens, has pages and is not locked, so a kept copy
    /// can be shown again later.
    static func isReadablePDF(_ data: Data) async -> Bool {
        await Task.detached(priority: .utility) {
            guard let document = PDFDocument(data: data) else { return false }
            return document.pageCount > 0 && !document.isLocked
        }.value
    }

    // MARK: Reading

    private static func readPDF(_ data: Data) throws -> PDFReading {
        try Task.checkCancellation()
        guard let document = PDFDocument(data: data), document.pageCount > 0 else {
            throw ReceiptScannerError.unreadable
        }
        if document.isLocked { throw ReceiptScannerError.lockedDocument }

        var pageRows: [String] = []
        for index in textPageIndexes(count: document.pageCount) {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            pageRows.append(contentsOf: boundedRows(rows(from: extractedLines(on: page))))
        }
        if hasUsableText(pageRows) { return .text(pageRows) }

        var images: [Data] = []
        for index in renderedPageIndexes(count: document.pageCount) {
            try Task.checkCancellation()
            guard let page = document.page(at: index),
                  let image = renderedPage(page),
                  let jpeg = jpegData(from: image) else { continue }
            images.append(jpeg)
        }
        guard !images.isEmpty else { throw ReceiptScannerError.unreadable }
        return .pages(images)
    }

    private static func recognizeScannedPages(
        _ images: [Data]
    ) async throws -> ReceiptRecognitionResult {
        var combined: ReceiptRecognitionResult?
        for image in images {
            try Task.checkCancellation()
            do {
                let page = try await ReceiptScanner.recognize(inImageData: image)
                combined = combined.map { merged($0, page) } ?? page
            } catch ReceiptScannerError.noTextFound {
                // A blank cover or back page must not hide a readable one.
                continue
            }
        }
        guard let combined else { throw ReceiptScannerError.noTextFound }
        return combined
    }

    static func merged(
        _ first: ReceiptRecognitionResult,
        _ second: ReceiptRecognitionResult
    ) -> ReceiptRecognitionResult {
        let firstCount = Float(first.lines.count)
        let secondCount = Float(second.lines.count)
        let mean: Float? = if let a = first.meanConfidence, let b = second.meanConfidence,
                              firstCount + secondCount > 0 {
            (a * firstCount + b * secondCount) / (firstCount + secondCount)
        } else {
            nil
        }
        let lineConfidences: [Float]? = if let a = first.lineConfidences,
                                           let b = second.lineConfidences {
            a + b
        } else {
            nil
        }
        return ReceiptRecognitionResult(
            lines: first.lines + second.lines,
            meanConfidence: mean,
            lineConfidences: lineConfidences,
            requiresExplicitReview: first.requiresExplicitReview
                || second.requiresExplicitReview
        )
    }

    // MARK: Page choice

    /// The first pages carry the merchant and date; the last carries the total.
    static func textPageIndexes(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        if count <= maximumTextPages { return Array(0..<count) }
        return Array(0..<(maximumTextPages - 1)) + [count - 1]
    }

    static func renderedPageIndexes(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        return count == 1 ? [0] : [0, count - 1]
    }

    // MARK: Embedded text

    private static func extractedLines(on page: PDFPage) -> [ExtractedLine] {
        guard page.numberOfCharacters > 0,
              page.numberOfCharacters <= maximumCharactersPerPage else { return [] }
        let box = page.bounds(for: .cropBox)
        guard let selection = page.selection(for: box) else { return [] }
        return selection.selectionsByLine().compactMap { line in
            guard let text = line.string, !text.isEmpty else { return nil }
            return ExtractedLine(
                text: String(text.prefix(maximumLineCharacters)),
                bounds: displayBounds(
                    of: line.bounds(for: page),
                    in: box,
                    rotation: page.rotation
                )
            )
        }
    }

    /// PDFKit reports boxes in the page's own unrotated space, so a page that is
    /// shown turned would otherwise stack its lines sideways.
    static func displayBounds(of rect: CGRect, in box: CGRect, rotation: Int) -> CGRect {
        let x0 = rect.minX - box.minX
        let x1 = rect.maxX - box.minX
        let y0 = rect.minY - box.minY
        let y1 = rect.maxY - box.minY
        switch ((rotation % 360) + 360) % 360 {
        case 90:
            return CGRect(x: y0, y: box.width - x1, width: y1 - y0, height: x1 - x0)
        case 180:
            return CGRect(x: box.width - x1, y: box.height - y1, width: x1 - x0, height: y1 - y0)
        case 270:
            return CGRect(x: box.height - y1, y: x0, width: y1 - y0, height: x1 - x0)
        default:
            return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }
    }

    /// Some documents draw every label first and every price afterwards, so the
    /// text layer holds "Latte" and "4.50" as separate lines. Rows are rebuilt
    /// from the geometry: lines that share a band of the page belong together,
    /// left to right, and bands run top to bottom, which is what the parser
    /// expects from a photo as well.
    static func rows(from lines: [ExtractedLine]) -> [String] {
        struct Band {
            let box: CGRect
            var members: [ExtractedLine]
        }

        let ordered = lines
            .filter {
                $0.bounds.minX.isFinite && $0.bounds.minY.isFinite
                    && $0.bounds.width.isFinite && $0.bounds.height.isFinite
            }
            .sorted { lhs, rhs in
                if lhs.bounds.midY != rhs.bounds.midY {
                    return lhs.bounds.midY > rhs.bounds.midY
                }
                if lhs.bounds.minX != rhs.bounds.minX {
                    return lhs.bounds.minX < rhs.bounds.minX
                }
                return lhs.text < rhs.text
            }
        var bands: [Band] = []
        for line in ordered {
            if let index = bands.indices.reversed().first(where: {
                verticalOverlap(bands[$0].box, line.bounds) >= 0.5
            }) {
                bands[index].members.append(line)
            } else {
                bands.append(Band(box: line.bounds, members: [line]))
            }
        }

        return bands.compactMap { band in
            let members = band.members.sorted { lhs, rhs in
                if lhs.bounds.minX != rhs.bounds.minX {
                    return lhs.bounds.minX < rhs.bounds.minX
                }
                return lhs.text < rhs.text
            }
            let joined = withoutRedraws(members)
                .map(\.text)
                .joined(separator: " ")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }
    }

    /// Text drawn twice a hair apart to look bold is one row of words. Two rows
    /// that merely repeat each other further down the page (two identical
    /// coffees) are different bands and stay as they are.
    private static func withoutRedraws(_ members: [ExtractedLine]) -> [ExtractedLine] {
        var kept: [ExtractedLine] = []
        for member in members.map(collapsedRedraw) {
            let repeated = kept.contains {
                $0.text == member.text && horizontalOverlap($0.bounds, member.bounds) >= 0.5
            }
            if !repeated { kept.append(member) }
        }
        return kept
    }

    /// PDFKit reads a line drawn twice in the same place as its text twice. It
    /// counts as a redraw only when the box is as narrow as one copy: the same
    /// word twice side by side, such as a shop called "Thai Thai", is twice as
    /// wide and stays whole.
    static func collapsedRedraw(_ line: ExtractedLine) -> ExtractedLine {
        let characters = Array(line.text)
        for separatorLength in 0...1 {
            let copies = characters.count - separatorLength
            guard copies >= 8, copies.isMultiple(of: 2) else { continue }
            let half = copies / 2
            let first = characters[..<half]
            guard characters[half..<(half + separatorLength)].allSatisfy(\.isWhitespace),
                  first.elementsEqual(characters[(half + separatorLength)...]),
                  first.contains(where: { $0.isLetter || $0 == "." || $0 == "," }),
                  line.bounds.width < maximumRedrawWidthPerCharacter
                      * CGFloat(half) * line.bounds.height else { continue }
            return ExtractedLine(text: String(first), bounds: line.bounds)
        }
        return line
    }

    /// Share of the shorter box that the other one covers vertically.
    private static func verticalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let shortest = min(a.height, b.height)
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        guard shortest > 0, overlap > 0 else { return 0 }
        return overlap / shortest
    }

    /// Share of the narrower box that the other one covers horizontally.
    private static func horizontalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let narrowest = min(a.width, b.width)
        let overlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        guard narrowest > 0, overlap > 0 else { return 0 }
        return overlap / narrowest
    }

    private static func boundedRows(_ rows: [String]) -> [String] {
        guard rows.count > maximumRowsPerPage else { return rows }
        let edge = maximumRowsPerPage / 2
        return Array(rows.prefix(edge)) + Array(rows.suffix(edge))
    }

    /// A text layer counts only when it holds real words and figures. A scan that
    /// merely carries a watermark, or a font that maps to nothing readable,
    /// falls through to reading the page as a picture.
    static func hasUsableText(_ rows: [String]) -> Bool {
        var alphanumerics = 0
        var digits = 0
        for row in rows {
            for scalar in row.unicodeScalars {
                switch scalar.properties.generalCategory {
                case .decimalNumber:
                    alphanumerics += 1
                    digits += 1
                case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
                     .modifierLetter, .otherLetter:
                    alphanumerics += 1
                default:
                    break
                }
            }
            if alphanumerics >= minimumAlphanumerics, digits >= minimumDigits { return true }
        }
        return false
    }

    // MARK: Drawing a page

    /// Draws a page upright on white, at most 2,600 px on the long side, so the
    /// bitmap stays near 20 MB however large the page is declared.
    static func renderedPage(_ page: PDFPage) -> CGImage? {
        guard let pageRef = page.pageRef else { return nil }
        let box = pageRef.getBoxRect(.cropBox)
        guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else {
            return nil
        }
        let turned = pageRef.rotationAngle % 180 != 0
        let size = turned ? CGSize(width: box.height, height: box.width) : box.size
        let scale = min(maximumRenderScale, maximumRenderPixels / max(size.width, size.height))
        let width = max(1, Int((size.width * scale).rounded(.down)))
        let height = max(1, Int((size.height * scale).rounded(.down)))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // getDrawingTransform never enlarges a page, so scale first and let it
        // place the page, including its own rotation, in the point-sized rect.
        context.scaleBy(x: scale, y: scale)
        context.concatenate(pageRef.getDrawingTransform(
            .cropBox,
            rect: CGRect(origin: .zero, size: size),
            rotate: 0,
            preserveAspectRatio: true
        ))
        context.drawPDFPage(pageRef)
        return context.makeImage()
    }

    private static func jpegData(from image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.9
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
