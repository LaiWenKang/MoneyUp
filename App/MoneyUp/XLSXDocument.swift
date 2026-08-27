import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let officeOpenXMLSpreadsheet = UTType(
        importedAs: "org.openxmlformats.spreadsheetml.sheet",
        conformingTo: .spreadsheet
    )
}

struct XLSXDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.officeOpenXMLSpreadsheet] }

    var data: Data

    init(data: Data = Data()) { self.data = data }

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
