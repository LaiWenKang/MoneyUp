import AVFoundation
import CoreVideo
import MoneyUpCore
@testable import MoneyUp
import Observation
import SwiftUI
import UIKit
import XCTest

@MainActor @Observable
private final class StoreMoviePhase {
    var elapsed: Double = 0
}

private struct StoreMovieScene: View {
    let model: AppModel
    let snapshot: AppReportingSnapshot
    let navigation: MoneyUpTabNavigation
    let phase: StoreMoviePhase
    let chinese: Bool
    let brandOnly: Bool

    var body: some View {
        ZStack {
            if !brandOnly {
                MainTabView(initialReportingSnapshot: snapshot, navigation: navigation)
                    .environment(model).environment(MoneyUpOverviewNavigation())
            }
            StoreMovieBrandLayer(phase: phase, chinese: chinese, brandOnly: brandOnly)
        }
        .preferredColorScheme(.dark)
    }
}

private struct StoreMovieBrandLayer: View {
    let phase: StoreMoviePhase
    let chinese: Bool
    let brandOnly: Bool

    var body: some View {
        Group {
            if brandOnly || phase.elapsed < 1.8 {
                let opacity = brandOnly ? 1 : min(1, max(0, (1.8 - phase.elapsed) / 0.5))
                VStack(spacing: 20) {
                    Text(verbatim: "MONEYUP").font(.system(size: 14, weight: .semibold)).tracking(6)
                        .foregroundStyle(Color(red: 0.64, green: 0.85, blue: 0.75))
                    Image("MoneyUpMoneyWorld").resizable().scaledToFit()
                        .frame(maxWidth: 360)
                        .rotation3DEffect(.degrees(sin(phase.elapsed * 1.15) * 7), axis: (x: 0.15, y: 1, z: 0))
                        .offset(y: sin(phase.elapsed * 1.8) * 8)
                        .scaleEffect(0.95 + 0.025 * sin(phase.elapsed * 0.9))
                        .shadow(color: Color.green.opacity(0.12 + 0.05 * sin(phase.elapsed * 1.4)), radius: 38)
                    Text(verbatim: chinese ? "你的钱，更清楚。" : "Your money. A little clearer.")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.94, green: 0.97, blue: 0.91))
                    Text(verbatim: chinese ? "私密记账 · 从容生活" : "Private money. Calmer days.")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    RadialGradient(colors: [Color(red: 0.11, green: 0.26, blue: 0.19), Color(red: 0.025, green: 0.055, blue: 0.045)],
                                   center: .center, startRadius: 30, endRadius: 520)
                }
                .opacity(opacity).ignoresSafeArea()
            }
        }
    }
}

enum AppStorePreviewRecorder {
    @MainActor
    static func record(model: AppModel, snapshot: AppReportingSnapshot,
                       language: AppLanguagePreference, brandOnly: Bool = false) async throws -> URL {
        let chinese = language == .simplifiedChinese
        let defaults = AppLanguagePreference.defaults
        let previous = defaults?.object(forKey: AppLanguagePreference.storageKey)
        defaults?.set(language.rawValue, forKey: AppLanguagePreference.storageKey)
        defer {
            if let previous { defaults?.set(previous, forKey: AppLanguagePreference.storageKey) }
            else { defaults?.removeObject(forKey: AppLanguagePreference.storageKey) }
        }
        let phase = StoreMoviePhase()
        let navigation = MoneyUpTabNavigation(section: .today)
        let root = StoreMovieScene(model: model, snapshot: snapshot, navigation: navigation,
                                  phase: phase, chinese: chinese, brandOnly: brandOnly)
            .environment(\.locale, language.locale)
        let host = UIHostingController(rootView: root)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let prior = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 428, height: 926)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        defer { window.isHidden = true; window.rootViewController = nil; prior?.makeKey() }
        try await Task.sleep(for: .milliseconds(500))
        let name = "MoneyUp-\(brandOnly ? "brand" : "preview")-\(chinese ? "zh" : "en")-\(UUID().uuidString).mp4"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 886, AVVideoHeightKey: 1920,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264High40, AVVideoMaxKeyFrameIntervalKey: 30]
        ])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 886, kCVPixelBufferHeightKey as String: 1920,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        try await frames(window: window, host: host, navigation: navigation, phase: phase,
                         writer: writer, input: input, adapter: adapter, duration: brandOnly ? 6 : 18, brandOnly: brandOnly)
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return url
    }

    @MainActor
    private static func frames<Content: View>(window: UIWindow, host: UIHostingController<Content>,
        navigation: MoneyUpTabNavigation, phase: StoreMoviePhase, writer: AVAssetWriter,
        input: AVAssetWriterInput, adapter: AVAssetWriterInputPixelBufferAdaptor,
        duration: Int, brandOnly: Bool) async throws {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 3
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        for frame in 0..<(duration * 30) {
            try Task.checkCancellation()
            phase.elapsed = Double(frame) / 30
            if !brandOnly {
                if frame == 180 { navigation.section = .plan }
                if frame == 300 { navigation.section = .history }
                if frame == 420 { navigation.section = .assets }
            }
            try await Task.sleep(for: .milliseconds(8))
            host.view.layoutIfNeeded()
            let deadline = ContinuousClock.now + .seconds(10)
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, ContinuousClock.now < deadline else {
                    throw writer.error ?? CocoaError(.fileWriteUnknown)
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            try autoreleasepool {
                let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                let pool = try XCTUnwrap(adapter.pixelBufferPool)
                var candidate: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &candidate) == kCVReturnSuccess,
                      let buffer = candidate else { throw CocoaError(.fileWriteUnknown) }
                try draw(image, into: buffer)
                guard adapter.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                    throw writer.error ?? CocoaError(.fileWriteUnknown)
                }
            }
        }
    }

    @MainActor
    private static func draw(_ image: UIImage, into buffer: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 886, height: 1920,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue))
        context.translateBy(x: 0, y: 1920)
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        image.draw(in: CGRect(x: 0, y: 0, width: 886, height: 1920))
        UIGraphicsPopContext()
    }
}
