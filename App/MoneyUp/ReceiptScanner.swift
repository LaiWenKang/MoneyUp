import CoreGraphics
import Foundation
import ImageIO
import MoneyUpCore
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

/// Reads text from a receipt photo or payment screenshot with Vision.
///
/// Decode, bounded downsampling, and OCR all run off the caller's executor.
/// This keeps the form responsive even when receiptDraft was entered on the
/// main actor. Work is cancellable, the image is never persisted or uploaded,
/// and only recognized strings survive the operation.
enum ReceiptScanner {
    /// Leaves roughly half a second inside the Golden <8 s capture budget for
    /// PhotosPicker transfer and main-actor form population.
    private static let timeoutNanoseconds: UInt64 = 7_500_000_000

    static func recognizeLines(inImageData data: Data) async throws -> [String] {
        try Task.checkCancellation()
        let operation = ReceiptRecognitionOperation(imageData: data)
        let race = ReceiptRecognitionRace()
        let recognitionTask = Task.detached(priority: .userInitiated) {
            let result: Result<[String], Error>
            do {
                result = .success(try operation.run())
            } catch {
                result = .failure(error)
            }
            _ = race.resolve(with: result)
        }
        let timeoutTask = Task.detached(priority: .utility) {
            do {
                try await Task<Never, Never>.sleep(
                    nanoseconds: Self.timeoutNanoseconds
                )
                // Reuse the existing localized recovery message. To the user,
                // a scan with no usable text in the bounded window has the same
                // recovery: retake or crop it.
                if race.resolve(with: .failure(ReceiptScannerError.noTextFound)) {
                    operation.cancel()
                    recognitionTask.cancel()
                }
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
        defer { timeoutTask.cancel() }

        let lines = try await withTaskCancellationHandler {
            try await race.value()
        } onCancel: {
            if race.resolve(with: .failure(CancellationError())) {
                operation.cancel()
                recognitionTask.cancel()
            }
            timeoutTask.cancel()
        }

        try Task.checkCancellation()
        guard !lines.isEmpty else { throw ReceiptScannerError.noTextFound }
        return lines
    }
}

/// First-result-wins bridge for OCR, timeout, and caller cancellation. Unlike a
/// structured task group it does not wait for a losing synchronous ImageIO or
/// Vision call before returning to the UI. Late results are ignored safely.
private final class ReceiptRecognitionRace: @unchecked Sendable {
    private enum State {
        case pending
        case waiting(CheckedContinuation<[String], Error>)
        case completed(Result<[String], Error>)
    }

    private let lock = NSLock()
    private var state: State = .pending

    func value() async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            var completedResult: Result<[String], Error>?
            lock.lock()
            switch state {
            case .pending:
                state = .waiting(continuation)
            case .waiting:
                // ReceiptScanner awaits each race exactly once.
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            case let .completed(result):
                completedResult = result
            }
            lock.unlock()
            if let completedResult {
                continuation.resume(with: completedResult)
            }
        }
    }

    /// Returns true only to the winner, which owns cancellation of losing work.
    @discardableResult
    func resolve(with result: Result<[String], Error>) -> Bool {
        var continuation: CheckedContinuation<[String], Error>?
        lock.lock()
        switch state {
        case .pending:
            state = .completed(result)
        case let .waiting(waiter):
            continuation = waiter
            state = .completed(result)
        case .completed:
            lock.unlock()
            return false
        }
        lock.unlock()
        continuation?.resume(with: result)
        return true
    }
}

/// One short-lived scanner operation. VNRequest.cancel() is safe to call from
/// another thread; the lock only protects request registration and cancellation
/// state, never the expensive Vision work itself.
private final class ReceiptRecognitionOperation: @unchecked Sendable {
    private struct OCRResult {
        let lines: [String]
        let meanConfidence: Float
    }

    private struct Fragment {
        let text: String
        let confidence: Float
        let box: CGRect
    }

    private struct TextRow {
        var fragments: [Fragment]
        var minimumY: CGFloat
        var maximumY: CGFloat
        var averageMidY: CGFloat

        init(_ fragment: Fragment) {
            fragments = [fragment]
            minimumY = fragment.box.minY
            maximumY = fragment.box.maxY
            averageMidY = fragment.box.midY
        }

        mutating func append(_ fragment: Fragment) {
            fragments.append(fragment)
            minimumY = min(minimumY, fragment.box.minY)
            maximumY = max(maximumY, fragment.box.maxY)
            averageMidY = fragments.map { $0.box.midY }.reduce(0, +)
                / CGFloat(fragments.count)
        }

        func matches(_ fragment: Fragment) -> Bool {
            let overlap = min(maximumY, fragment.box.maxY)
                - max(minimumY, fragment.box.minY)
            let shortestHeight = min(maximumY - minimumY, fragment.box.height)
            let overlapsEnough = shortestHeight > 0 && overlap / shortestHeight >= 0.35
            let centersAlign = abs(averageMidY - fragment.box.midY)
                <= max(0.006, min(shortestHeight, fragment.box.height) * 0.48)
            return overlapsEnough || centersAlign
        }
    }

    /// Around 5 MP is ample for Vision receipt text while avoiding the decode
    /// and OCR cost of modern 12/24/48 MP camera originals.
    private static let maximumPixelDimension = 2_600

    private static let accurateRecognitionLanguages = ["en-US", "zh-Hans", "zh-Hant"]

    private static let customWords = [
        "TOTAL", "SUBTOTAL", "GRAND TOTAL", "AMOUNT DUE", "AMOUNT PAID",
        "SGD", "MYR", "RM", "S$", "GST", "SST", "NETS", "PayNow",
        "合计", "合計", "总计", "總計", "应付", "應付", "实付", "實付"
    ]

    private let imageData: Data
    private let lock = NSLock()
    private var activeRequest: VNRecognizeTextRequest?
    private var wasCancelled = false

    init(imageData: Data) {
        self.imageData = imageData
    }

    func cancel() {
        lock.lock()
        wasCancelled = true
        let request = activeRequest
        lock.unlock()
        request?.cancel()
    }

    func run() throws -> [String] {
        try checkCancellation()
        guard let image = Self.preparedImage(from: imageData) else {
            throw ReceiptScannerError.unreadableImage
        }
        try checkCancellation()

        // Most clear receipts/screenshots finish on the fast path. An accurate
        // pass is paid for only when the fast text is not trustworthy enough to
        // populate an amount.
        let fast: OCRResult?
        do {
            fast = try recognize(in: image, level: .fast)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Fast-language/model availability can vary by device. The
            // accurate pass is the authoritative fallback for those cases.
            fast = nil
        }
        if let fast, Self.isActionable(fast) {
            return fast.lines
        }

        try checkCancellation()
        return try recognize(in: image, level: .accurate).lines
    }

    private func recognize(
        in image: CGImage,
        level: VNRequestTextRecognitionLevel
    ) throws -> OCRResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = level == .accurate
        // Fast recognition has a narrower language matrix on some devices.
        // English covers SG/MY currency/total labels on the latency path;
        // Chinese receipts naturally fall through to the multilingual pass.
        request.recognitionLanguages = level == .fast
            ? ["en-US"]
            : Self.accurateRecognitionLanguages
        request.automaticallyDetectsLanguage = true
        request.customWords = Self.customWords
        request.minimumTextHeight = level == .fast ? 0.007 : 0.004

        try register(request)
        defer { unregister(request) }

        do {
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
            try handler.perform([request])
        } catch {
            if isCancelled || Task.isCancelled { throw CancellationError() }
            throw error
        }
        try checkCancellation()

        let observations = request.results as? [VNRecognizedTextObservation] ?? []
        return Self.readingOrderText(from: observations)
    }

    private func register(_ request: VNRecognizeTextRequest) throws {
        lock.lock()
        if wasCancelled {
            lock.unlock()
            request.cancel()
            throw CancellationError()
        }
        activeRequest = request
        lock.unlock()
    }

    private func unregister(_ request: VNRecognizeTextRequest) {
        lock.lock()
        if activeRequest === request {
            activeRequest = nil
        }
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wasCancelled
    }

    private func checkCancellation() throws {
        if isCancelled || Task.isCancelled { throw CancellationError() }
    }

    private static func preparedImage(from data: Data) -> CGImage? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            sourceOptions as CFDictionary
        ) else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        )
    }

    /// Vision observations can split a single visual row into label and amount
    /// fragments. Group aligned fragments first, then sort rows top-to-bottom
    /// and fragments left-to-right so the parser receives actual reading order.
    private static func readingOrderText(
        from observations: [VNRecognizedTextObservation]
    ) -> OCRResult {
        let fragments = observations.compactMap { observation -> Fragment? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, candidate.confidence >= 0.12 else { return nil }
            return Fragment(text: text, confidence: candidate.confidence, box: observation.boundingBox)
        }.sorted { lhs, rhs in
            if lhs.box.midY != rhs.box.midY { return lhs.box.midY > rhs.box.midY }
            return lhs.box.minX < rhs.box.minX
        }

        var rows: [TextRow] = []
        for fragment in fragments {
            let matchingIndex = rows.indices
                .filter { rows[$0].matches(fragment) }
                .min { lhs, rhs in
                    abs(rows[lhs].averageMidY - fragment.box.midY)
                        < abs(rows[rhs].averageMidY - fragment.box.midY)
                }
            if let matchingIndex {
                rows[matchingIndex].append(fragment)
            } else {
                rows.append(TextRow(fragment))
            }
        }

        let orderedRows = rows.sorted { lhs, rhs in
            if lhs.averageMidY != rhs.averageMidY { return lhs.averageMidY > rhs.averageMidY }
            return (lhs.fragments.map { $0.box.minX }.min() ?? 0)
                < (rhs.fragments.map { $0.box.minX }.min() ?? 0)
        }
        var lines: [String] = []
        var confidences: [Float] = []
        for row in orderedRows {
            let orderedFragments = row.fragments.sorted { lhs, rhs in
                if lhs.box.minX != rhs.box.minX { return lhs.box.minX < rhs.box.minX }
                return lhs.text < rhs.text
            }
            let line = orderedFragments
                .map(\.text)
                .joined(separator: " ")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if lines.last != line {
                lines.append(line)
                confidences.append(contentsOf: orderedFragments.map(\.confidence))
            }
        }

        let meanConfidence = confidences.isEmpty
            ? 0
            : confidences.reduce(0, +) / Float(confidences.count)
        return OCRResult(lines: lines, meanConfidence: meanConfidence)
    }

    private static func isActionable(_ result: OCRResult) -> Bool {
        guard result.lines.count >= 2, result.meanConfidence >= 0.82 else { return false }
        // Use the authoritative parser as the quality gate so fast OCR and the
        // final parse cannot disagree about decimal commas, grouping, or safe
        // OCR digit repair.
        let parsed = ReceiptTextParser.analyze(fromLines: result.lines)
        guard parsed.draft.amount != nil else { return false }

        let strongLabels = [
            "grand total", "amount due", "amount payable", "amount paid", "you paid",
            "payment amount", "transfer amount", "jumlah besar", "jumlah bayaran", "jumlah",
            "合计", "合計", "总计", "總計", "应付", "應付", "实付", "實付"
        ]
        let excludedLabelLines = [
            "subtotal", "sub total", "sub-total", "total items", "total qty",
            "total savings", "total discount", "total points", "available balance",
            "account balance", "cash tendered", "change", "subjumlah", "jumlah kecil",
            "jumlah diskaun", "baki", "total gst", "gst total", "total sst",
            "sst total", "total vat", "vat total", "total tax", "tax total",
            "total service charge", "jumlah cukai", "jumlah caj perkhidmatan",
            "税额", "稅額", "服务费", "服務費"
        ]
        if result.lines.contains(where: { rawLine in
            let line = rawLine.lowercased()
            if excludedLabelLines.contains(where: { line.contains($0) }) { return false }
            if strongLabels.contains(where: { line.contains($0) }) { return true }
            return line.contains("total")
        }) {
            return true
        }

        let text = result.lines.joined(separator: " ").lowercased()
        return ["payment successful", "transaction successful", "transfer successful",
                "paid to", "payment to", "transferred to", "sent to"]
            .contains(where: { text.contains($0) })
    }
}
