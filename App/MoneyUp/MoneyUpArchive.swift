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
            String(localized: "backup.error.password_short")
        case .invalidArchive:
            String(localized: "backup.error.invalid")
        case let .unsupportedVersion(version):
            String(format: String(localized: "backup.error.version"), version)
        case .authenticationFailed:
            String(localized: "backup.error.authentication")
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
