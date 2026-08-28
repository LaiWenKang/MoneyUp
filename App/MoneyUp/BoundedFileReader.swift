import Foundation
import MoneyUpPersistence

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

    /// Copies to a caller-owned file while retaining only one small chunk.
    /// The sentinel byte is never committed: an oversized source deletes the
    /// partial destination before returning an error.
    @discardableResult
    static func copy(
        from sourceHandle: FileHandle,
        to destinationURL: URL,
        maximumByteCount: Int
    ) throws -> Int {
        precondition(maximumByteCount >= 0)
        let fileManager = FileManager.default
        guard fileManager.createFile(
            atPath: destinationURL.path,
            contents: nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var succeeded = false
        defer {
            if !succeeded { try? fileManager.removeItem(at: destinationURL) }
        }
        let destinationHandle = try FileHandle(forWritingTo: destinationURL)
        defer { try? destinationHandle.close() }
        var copiedByteCount = 0
        while copiedByteCount <= maximumByteCount {
            try Task.checkCancellation()
            let remainingThroughSentinel = maximumByteCount
                - copiedByteCount + 1
            let requested = min(chunkByteCount, remainingThroughSentinel)
            guard let chunk = try sourceHandle.read(upToCount: requested),
                  !chunk.isEmpty else {
                try destinationHandle.synchronize()
                succeeded = true
                return copiedByteCount
            }
            let nextByteCount = copiedByteCount + chunk.count
            guard nextByteCount <= maximumByteCount else {
                throw PortableArchiveError.archiveTooLarge
            }
            try destinationHandle.write(contentsOf: chunk)
            copiedByteCount = nextByteCount
        }
        throw PortableArchiveError.archiveTooLarge
    }
}
