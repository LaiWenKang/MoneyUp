import CoreTransferable
import Foundation
import MoneyUpPersistence
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let moneyUpArchive = UTType(
        exportedAs: "com.laiwenkang.moneyup.archive",
        conformingTo: .data
    )
}

extension PortableArchiveError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .passwordTooShort:
            AppLocalization.string("backup.error.password_short")
        case .passwordTooLong:
            AppLocalization.string("backup.error.password_long")
        case .archiveTooLarge:
            AppLocalization.string("backup.error.too_large")
        case .invalidArchive:
            AppLocalization.string("backup.error.invalid")
        case let .unsupportedVersion(version):
            String(format: AppLocalization.string("backup.error.version"), version)
        case .authenticationFailed:
            AppLocalization.string("backup.error.authentication")
        }
    }
}

struct MoneyUpArchiveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.moneyUpArchive] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// A file-backed export item. SwiftUI hands the existing encrypted file to the
/// destination provider instead of asking `FileDocument` to materialize its
/// complete contents as `Data` and `FileWrapper` copies.
struct MoneyUpArchiveTransfer: Transferable {
    let fileURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .moneyUpArchive) { archive in
            SentTransferredFile(archive.fileURL)
        }
    }
}
