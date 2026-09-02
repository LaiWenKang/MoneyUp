import CoreGraphics
import Foundation
import ImageIO
@testable import MoneyUp
import MoneyUpCore
import UniformTypeIdentifiers
import XCTest

final class ReceiptImageSanitizerTests: XCTestCase {
    func testQuickLogSavedFeedbackUsesSharedReduceMotionPolicy() {
        XCTAssertEqual(
            MoneyUpMotion.policy(for: .confirmation, reduceMotion: true),
            .immediate
        )
        XCTAssertEqual(
            MoneyUpMotion.policy(for: .confirmation, reduceMotion: false),
            .snappy(duration: 0.22)
        )
    }

    @MainActor
    func testQuickLogPublishesSuggestionsBeforePreparingRetention() async throws {
        var events: [String] = []

        try await QuickLogReceiptPipeline.run {
            events.append("recognized")
            return "suggestion"
        } handleSuggestions: { suggestion in
            XCTAssertEqual(suggestion, "suggestion")
            events.append("published")
            return true
        } handleNoSuggestions: {
            XCTFail("Expected a suggestion.")
            return false
        } handleRecognitionFailure: { error in
            XCTFail("Unexpected recognition error: \(error)")
            return false
        } prepareRetention: {
            XCTAssertEqual(events, ["recognized", "published"])
            events.append("sanitized")
        }

        XCTAssertEqual(events, ["recognized", "published", "sanitized"])
    }

    @MainActor
    func testLateSupersededScanCannotPublishOrPrepareRetention() async throws {
        let gate = ReceiptPipelineGate()
        var activeGeneration = 1
        var published: [String] = []
        var prepared: [String] = []

        let first = Task { @MainActor in
            try await QuickLogReceiptPipeline.run {
                await gate.suspend()
                return "first"
            } handleSuggestions: { suggestion in
                guard activeGeneration == 1 else { return false }
                published.append(suggestion)
                return true
            } handleNoSuggestions: {
                activeGeneration == 1
            } handleRecognitionFailure: { _ in
                activeGeneration == 1
            } prepareRetention: {
                prepared.append("first")
            }
        }

        let suspensionDeadline = ProcessInfo.processInfo.systemUptime + 2
        var isSuspended = await gate.isSuspended
        while !isSuspended
            && ProcessInfo.processInfo.systemUptime < suspensionDeadline {
            await Task.yield()
            isSuspended = await gate.isSuspended
        }
        guard isSuspended else {
            first.cancel()
            await gate.release()
            _ = try? await first.value
            XCTFail("First receipt pipeline did not suspend.")
            return
        }
        activeGeneration = 2
        try await QuickLogReceiptPipeline.run {
            "second"
        } handleSuggestions: { suggestion in
            guard activeGeneration == 2 else { return false }
            published.append(suggestion)
            return true
        } handleNoSuggestions: {
            false
        } handleRecognitionFailure: { _ in
            false
        } prepareRetention: {
            prepared.append("second")
        }
        await gate.release()
        try await first.value

        XCTAssertEqual(published, ["second"])
        XCTAssertEqual(prepared, ["second"])
    }

    @MainActor
    func testQuickLogCanPrepareRetentionAfterRecognitionFailure() async throws {
        var events: [String] = []

        try await QuickLogReceiptPipeline.run {
            throw PipelineTestError.recognitionFailed
        } handleSuggestions: { (_: String) in
            XCTFail("A failed recognition must not publish suggestions.")
            return false
        } handleNoSuggestions: {
            XCTFail("A thrown recognition must use the failure path.")
            return false
        } handleRecognitionFailure: { error in
            XCTAssertTrue(error is PipelineTestError)
            events.append("failure published")
            return true
        } prepareRetention: {
            XCTAssertEqual(events, ["failure published"])
            events.append("sanitized")
        }

        XCTAssertEqual(events, ["failure published", "sanitized"])
    }

    @MainActor
    func testQuickLogCanPrepareRetentionWithoutSuggestions() async throws {
        var didPrepareRetention = false

        try await QuickLogReceiptPipeline.run {
            Optional<String>.none
        } handleSuggestions: { _ in
            XCTFail("No suggestion should be published.")
            return false
        } handleNoSuggestions: {
            true
        } handleRecognitionFailure: { error in
            XCTFail("Unexpected recognition error: \(error)")
            return false
        } prepareRetention: {
            didPrepareRetention = true
        }

        XCTAssertTrue(didPrepareRetention)
    }

    @MainActor
    func testCancelDuringSanitizationCannotPublishAttachment() async {
        let probe = CancellationAwareSanitizer()
        var didPublishSuggestions = false
        var attachmentData: Data?
        let preparation = Task { @MainActor in
            try await QuickLogReceiptPipeline.run {
                "suggestion"
            } handleSuggestions: { _ in
                didPublishSuggestions = true
                return true
            } handleNoSuggestions: {
                false
            } handleRecognitionFailure: { _ in
                false
            } prepareRetention: {
                let sanitized = try await ReceiptImageSanitizer
                    .prepareForEncryptedStorage(
                        Data([0x01]),
                        sanitizer: { data in
                            try probe.sanitize(data)
                        }
                    )
                try Task.checkCancellation()
                attachmentData = sanitized
            }
        }

        let startDeadline = ProcessInfo.processInfo.systemUptime + 2
        while !probe.hasStarted,
              ProcessInfo.processInfo.systemUptime < startDeadline {
            await Task.yield()
        }
        guard probe.hasStarted else {
            preparation.cancel()
            _ = try? await preparation.value
            XCTFail("Receipt preparation did not start.")
            return
        }
        XCTAssertTrue(didPublishSuggestions)
        preparation.cancel()

        do {
            _ = try await preparation.value
            XCTFail("Expected canceled receipt preparation to throw.")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(type(of: error))")
        }
        XCTAssertTrue(probe.observedCancellation)
        XCTAssertNil(attachmentData)
    }

    func testRetentionPreparationsUseOneSerialImageBoundary() async {
        let probe = CancellationAwareSanitizer()
        let first = Task {
            try await ReceiptImageSanitizer.prepareForEncryptedStorage(
                Data([0x01]),
                sanitizer: { try probe.sanitize($0) }
            )
        }
        let startDeadline = ProcessInfo.processInfo.systemUptime + 2
        while probe.startCount == 0,
              ProcessInfo.processInfo.systemUptime < startDeadline {
            await Task.yield()
        }
        guard probe.startCount == 1 else {
            first.cancel()
            _ = try? await first.value
            XCTFail("First retention preparation did not start.")
            return
        }

        let second = Task {
            try await ReceiptImageSanitizer.prepareForEncryptedStorage(
                Data([0x02]),
                sanitizer: { try probe.sanitize($0) }
            )
        }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(
            probe.startCount,
            1,
            "Retention decodes must not overlap."
        )

        first.cancel()
        second.cancel()
        _ = try? await first.value
        _ = try? await second.value
        XCTAssertEqual(probe.startCount, 1)
    }

    func testReplacementRecognitionWaitsForPendingSanitizerBoundary() async {
        let probe = CancellationAwareSanitizer()
        let preparation = Task {
            try await ReceiptImageSanitizer.prepareForEncryptedStorage(
                Data([0x01]),
                sanitizer: { try probe.sanitize($0) }
            )
        }
        let startDeadline = ProcessInfo.processInfo.systemUptime + 2
        while !probe.hasStarted,
              ProcessInfo.processInfo.systemUptime < startDeadline {
            await Task.yield()
        }
        guard probe.hasStarted else {
            preparation.cancel()
            _ = try? await preparation.value
            XCTFail("Receipt preparation did not start.")
            return
        }

        let waiter = Task {
            try await ReceiptImageSanitizer.waitForPendingPreparation()
            probe.recordWaitCompletion()
        }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(
            probe.didCompleteWait,
            "Replacement OCR must not overlap an older large image boundary."
        )

        preparation.cancel()
        _ = try? await preparation.value
        _ = try? await waiter.value
        XCTAssertTrue(probe.didCompleteWait)
    }

    func testSanitizerRemovesLocationEXIFAndDeviceMetadata() throws {
        let source = try makeImage(width: 320, height: 180)
        let original = try jpegData(
            from: source,
            properties: [
                kCGImagePropertyGPSDictionary as String: [
                    kCGImagePropertyGPSLatitude as String: 1.3521,
                    kCGImagePropertyGPSLatitudeRef as String: "N",
                    kCGImagePropertyGPSLongitude as String: 103.8198,
                    kCGImagePropertyGPSLongitudeRef as String: "E"
                ],
                kCGImagePropertyExifDictionary as String: [
                    kCGImagePropertyExifUserComment as String:
                        "private receipt annotation"
                ],
                kCGImagePropertyTIFFDictionary as String: [
                    kCGImagePropertyTIFFMake as String: "Private Camera Maker",
                    kCGImagePropertyTIFFModel as String: "Private Device Model"
                ]
            ]
        )
        let originalProperties = try properties(in: original)
        XCTAssertNotNil(
            originalProperties[kCGImagePropertyGPSDictionary as String]
        )

        let sanitized = try ReceiptImageSanitizer
            .sanitizedForEncryptedStorage(original)
        let sanitizedProperties = try properties(in: sanitized)

        XCTAssertEqual(
            ReceiptAttachmentMediaType.detected(from: sanitized),
            .jpeg
        )
        XCTAssertNil(
            sanitizedProperties[kCGImagePropertyGPSDictionary as String]
        )
        let exif = sanitizedProperties[
            kCGImagePropertyExifDictionary as String
        ] as? [String: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifUserComment as String])
        let tiff = sanitizedProperties[
            kCGImagePropertyTIFFDictionary as String
        ] as? [String: Any]
        XCTAssertNil(tiff?[kCGImagePropertyTIFFMake as String])
        XCTAssertNil(tiff?[kCGImagePropertyTIFFModel as String])
    }

    func testSanitizerAppliesOrientationAndBoundsRetainedPixels() throws {
        let original = try jpegData(
            from: makeImage(width: 5_000, height: 2_500),
            properties: [
                kCGImagePropertyOrientation as String:
                    CGImagePropertyOrientation.right.rawValue
            ]
        )

        let sanitized = try ReceiptImageSanitizer
            .sanitizedForEncryptedStorage(original)
        guard let source = CGImageSourceCreateWithData(
            sanitized as CFData,
            nil
        ),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return XCTFail("Sanitized receipt was not decodable.")
        }

        XCTAssertEqual(image.width, 2_048)
        XCTAssertEqual(image.height, 4_096)
        let sanitizedProperties = try properties(in: sanitized)
        let orientation = sanitizedProperties[
            kCGImagePropertyOrientation as String
        ] as? NSNumber
        XCTAssertTrue(orientation == nil || orientation?.intValue == 1)
    }

    private func properties(in data: Data) throws -> [String: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                nil
              ) as? [String: Any] else {
            throw TestError.imageDecodingFailed
        }
        return properties
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestError.imageCreationFailed
        }
        context.setFillColor(red: 0.2, green: 0.6, blue: 0.35, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw TestError.imageCreationFailed
        }
        return image
    }

    private func jpegData(
        from image: CGImage,
        properties: [String: Any]
    ) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw TestError.imageEncodingFailed
        }
        var properties = properties
        properties[kCGImageDestinationLossyCompressionQuality as String] = 0.9
        CGImageDestinationAddImage(
            destination,
            image,
            properties as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw TestError.imageEncodingFailed
        }
        return output as Data
    }

    private enum TestError: Error {
        case imageCreationFailed
        case imageEncodingFailed
        case imageDecodingFailed
    }

    private enum PipelineTestError: Error {
        case recognitionFailed
    }
}

private final class CancellationAwareSanitizer: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var startedCount = 0
    private var cancellationObserved = false
    private var waitCompleted = false

    var hasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    var observedCancellation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationObserved
    }

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return startedCount
    }

    var didCompleteWait: Bool {
        lock.lock()
        defer { lock.unlock() }
        return waitCompleted
    }

    func recordWaitCompletion() {
        lock.lock()
        waitCompleted = true
        lock.unlock()
    }

    func sanitize(_ data: Data) throws -> Data {
        _ = data
        lock.lock()
        started = true
        startedCount += 1
        lock.unlock()

        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !Task.isCancelled,
              ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }

        guard Task.isCancelled else {
            throw ProbeError.cancellationNotPropagated
        }

        lock.lock()
        cancellationObserved = true
        lock.unlock()
        throw CancellationError()
    }

    private enum ProbeError: Error {
        case cancellationNotPropagated
    }
}

private actor ReceiptPipelineGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isSuspended = false

    func suspend() async {
        isSuspended = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        isSuspended = false
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
