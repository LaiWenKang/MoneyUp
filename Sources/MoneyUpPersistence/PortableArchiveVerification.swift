import Foundation

extension PortableArchive {
    /// Authenticates and decrypts every record without retaining the decoded
    /// book or writing to a database. Version 2 keeps its bounded streaming read.
    public static func verify(from sourceURL: URL, password: String) throws {
        try Task.checkCancellation()
        try PortableArchiveV2.read(from: sourceURL, password: password) { _ in
            try Task.checkCancellation()
        }
    }
}
