import CoreFoundation
import Foundation
import MoneyUpCore
import UniformTypeIdentifiers

enum DelimitedImportFile {
    // Files providers may report a CSV as an Excel document or an opaque data
    // file. Filter by contents after selection, not by unreliable provider UTIs.
    static let allowedContentTypes: [UTType] = [.item]

    static func read(_ url: URL) throws -> String {
        try decode(readData(url))
    }

    static func readData(_ url: URL) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        var result: Result<Data, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { coordinatedURL in
            result = Result {
                let maximum = TransactionCSVImporter.maximumInputByteCount
                guard try coordinatedURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true else {
                    throw CSVImportViewError.unsupportedDocument
                }
                if let size = try coordinatedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maximum {
                    throw AppModelError.importTooLarge
                }
                let handle = try FileHandle(forReadingFrom: coordinatedURL)
                defer { try? handle.close() }
                return try BoundedFileReader.read(from: handle, maximumByteCount: maximum)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    static func decode(_ data: Data) throws -> String {
        guard data.count <= TransactionCSVImporter.maximumInputByteCount else { throw AppModelError.importTooLarge }
        guard !data.isEmpty else { throw TransactionCSVImportError.emptyFile }
        if data.starts(with: [0x50, 0x4b, 0x03, 0x04]) || data.starts(with: [0xd0, 0xcf, 0x11, 0xe0]) {
            throw CSVImportViewError.requiresCSVExport
        }
        let text: String?
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) {
            text = String(data: data, encoding: .utf16)
        } else if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else {
            // Older exports re-saved by Windows Excel commonly use GB18030.
            let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            text = String(data: data, encoding: String.Encoding(rawValue: encoding))
        }
        guard var text else { throw CSVImportViewError.unsupportedEncoding }
        if text.first == "\u{feff}" { text.removeFirst() }
        // Foundation's controlCharacters also includes format scalars on older
        // systems. Keep valid Unicode (including emoji joiners), but reject
        // binary C0/C1 controls independently of the OS character-set tables.
        guard !containsUnsupportedControls(text) else { throw CSVImportViewError.unsupportedEncoding }
        return text
    }

    static func containsUnsupportedControls(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            let value = $0.value
            return (value < 0x20 || (0x7f...0x9f).contains(value)) && ![9, 10, 13].contains(value)
        }
    }
}
