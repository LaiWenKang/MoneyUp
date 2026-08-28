import Foundation

/// Reads a regular file to EOF without ever retaining more than one byte past
/// the caller's limit. `FileHandle.read(upToCount:)` may legally return a
/// partial chunk, so every file-import boundary shares this loop instead of
/// treating a single read as the whole file.
enum BoundedFileReader {
    private static let chunkByteCount = 64 * 1_024

    static func read(
        from handle: FileHandle,
        maximumByteCount: Int
    ) throws -> Data {
        precondition(maximumByteCount >= 0)
        var result = Data()
        while result.count <= maximumByteCount {
            let remainingThroughSentinel = maximumByteCount - result.count + 1
            let requested = min(chunkByteCount, remainingThroughSentinel)
            guard let chunk = try handle.read(upToCount: requested),
                  !chunk.isEmpty else {
                return result
            }
            result.append(chunk)
        }
        return result
    }
}
