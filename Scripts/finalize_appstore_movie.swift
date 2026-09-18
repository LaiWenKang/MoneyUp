#!/usr/bin/env swift
import AVFoundation
import Foundation

// Add the stereo AAC track required by App Store previews, without re-encoding
// the native video. Usage: swift Scripts/finalize_appstore_movie.swift in.mp4 out.mp4
func invalid(_ message: String) -> NSError {
    NSError(domain: "AppStoreMovie", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var value = value.littleEndian
    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
}

func silentWAV(frames: Int) -> Data {
    let byteCount = UInt32(frames * 4)
    var data = Data("RIFF".utf8)
    appendLE(byteCount + 36, to: &data)
    data.append(contentsOf: "WAVEfmt ".utf8)
    appendLE(UInt32(16), to: &data)
    appendLE(UInt16(1), to: &data)
    appendLE(UInt16(2), to: &data)
    appendLE(UInt32(48_000), to: &data)
    appendLE(UInt32(192_000), to: &data)
    appendLE(UInt16(4), to: &data)
    appendLE(UInt16(16), to: &data)
    data.append(contentsOf: "data".utf8)
    appendLE(byteCount, to: &data)
    data.append(Data(count: Int(byteCount)))
    return data
}

@MainActor
func finalize() async throws {
    guard CommandLine.arguments.count == 3 else { throw invalid("Expected input.mp4 output.mp4") }
    let input = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let output = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
    guard input != output, output.pathExtension == "mp4",
          !FileManager.default.fileExists(atPath: output.path) else {
        throw invalid("Output must be a new MP4 file distinct from the input")
    }
    let asset = AVURLAsset(url: input)
    let duration = try await asset.load(.duration)
    guard duration.seconds.isFinite, duration.seconds > 0, duration.seconds <= 30 else {
        throw invalid("Expected a movie of no more than 30 seconds")
    }
    let videos = try await asset.loadTracks(withMediaType: .video)
    guard videos.count == 1, let video = videos.first,
          try await asset.loadTracks(withMediaType: .audio).isEmpty else {
        throw invalid("Expected one video track and no existing audio; existing audio is never replaced")
    }
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("moneyup-movie-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let wav = temporary.appendingPathComponent("silence.wav")
    let aac = temporary.appendingPathComponent("silence.m4a")
    try silentWAV(frames: Int((duration.seconds * 48_000).rounded())).write(to: wav)
    let encoder = Process()
    encoder.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
    encoder.arguments = ["-f", "m4af", "-d", "aac", "-c", "2", "-b", "256000", "-s", "0", "-q", "127", wav.path, aac.path]
    try encoder.run()
    encoder.waitUntilExit()
    guard encoder.terminationStatus == 0 else { throw invalid("AAC encoding failed") }
    let audioAsset = AVURLAsset(url: aac)
    guard let audio = try await audioAsset.loadTracks(withMediaType: .audio).first else {
        throw invalid("AAC track is missing")
    }
    let composition = AVMutableComposition()
    guard let videoCopy = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
          let audioCopy = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
        throw invalid("Unable to create movie tracks")
    }
    let range = CMTimeRange(start: .zero, duration: duration)
    try videoCopy.insertTimeRange(range, of: video, at: .zero)
    videoCopy.preferredTransform = try await video.load(.preferredTransform)
    try audioCopy.insertTimeRange(range, of: audio, at: .zero)
    guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
        throw invalid("Passthrough MP4 export is unavailable")
    }
    exporter.shouldOptimizeForNetworkUse = true
    try await exporter.export(to: output, as: .mp4)
    let final = AVURLAsset(url: output)
    guard let finalAudio = try await final.loadTracks(withMediaType: .audio).first,
          let description = try await finalAudio.load(.formatDescriptions).first,
          let format = CMAudioFormatDescriptionGetStreamBasicDescription(description),
          format.pointee.mChannelsPerFrame == 2, format.pointee.mSampleRate == 48_000,
          format.pointee.mFormatID == kAudioFormatMPEG4AAC else {
        throw invalid("Final audio format does not match stereo AAC at 48 kHz")
    }
    print("\(output.lastPathComponent): video passthrough; stereo AAC, 48 kHz, 256 kbps CBR; \(duration.seconds)s")
}

try await finalize()
