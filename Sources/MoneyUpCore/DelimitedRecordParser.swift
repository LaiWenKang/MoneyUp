import CryptoKit
import Foundation

extension TransactionCSVImporter {
    static func parseRecords(_ text: String) throws -> [DelimitedRecord] {
        guard !text.isEmpty else { throw TransactionCSVImportError.emptyFile }
        guard text.utf8.count <= maximumInputByteCount else {
            throw TransactionCSVImportError.inputTooLarge
        }
        let delimiter: Character
        let candidates: [Character] = [",", "\t", ";"]
        delimiter = candidates.max { left, right in
            delimiterCount(left, inFirstRecordOf: text)
                < delimiterCount(right, inFirstRecordOf: text)
        } ?? ","

        var records: [DelimitedRecord] = []
        var record: [String] = []
        var field = ""
        var fieldByteCount = 0
        var inQuotes = false
        var closedQuotedField = false
        var index = text.startIndex
        var physicalLine = 1
        var recordStartLine = 1

        func appendToField(_ character: Character) throws {
            let byteCount = String(character).utf8.count
            guard fieldByteCount <= maximumFieldByteCount - byteCount else {
                throw TransactionCSVImportError.malformedCSV
            }
            field.append(character)
            fieldByteCount += byteCount
        }

        func appendCurrentField() throws {
            guard record.count < maximumColumnCount else {
                throw TransactionCSVImportError.malformedCSV
            }
            record.append(field)
            field = ""
            fieldByteCount = 0
        }

        func appendCurrentRecord() throws {
            // The AppModel enforces the same aggregate write budget. Enforce
            // it while parsing too, before an oversized preview can allocate
            // an unbounded array of row models.
            guard records.count < MonetaryInputPolicy.aggregateRecordBudget + 1 else {
                throw TransactionCSVImportError.tooManyRows
            }
            if records.isEmpty {
                guard record.allSatisfy({
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && $0.utf8.count <= maximumHeaderByteCount
                }) else {
                    throw TransactionCSVImportError.malformedCSV
                }
                let normalizedHeaders = record.map(normalizedHeader)
                guard Set(normalizedHeaders).count == normalizedHeaders.count else {
                    throw TransactionCSVImportError.malformedCSV
                }
            }
            records.append(DelimitedRecord(
                fields: record,
                sourceLine: recordStartLine
            ))
        }

        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if inQuotes {
                if character == "\"" {
                    if next < text.endIndex, text[next] == "\"" {
                        try appendToField("\"")
                        index = text.index(after: next)
                        continue
                    }
                    inQuotes = false
                    closedQuotedField = true
                } else {
                    try appendToField(character)
                    if character == "\n"
                        || (character == "\r"
                            && (next == text.endIndex || text[next] != "\n")) {
                        physicalLine += 1
                    }
                }
            } else if closedQuotedField {
                if character == delimiter {
                    try appendCurrentField()
                    closedQuotedField = false
                } else if character == "\n" || character == "\r" {
                    try appendCurrentField()
                    try appendCurrentRecord()
                    record = []
                    closedQuotedField = false
                    physicalLine += 1
                    recordStartLine = physicalLine
                    if character == "\r", next < text.endIndex, text[next] == "\n" {
                        index = text.index(after: next)
                        continue
                    }
                } else {
                    throw TransactionCSVImportError.malformedCSV
                }
            } else if character == "\"" {
                guard field.isEmpty else {
                    throw TransactionCSVImportError.malformedCSV
                }
                inQuotes = true
            } else if character == delimiter {
                try appendCurrentField()
            } else if character == "\n" || character == "\r" {
                try appendCurrentField()
                try appendCurrentRecord()
                record = []
                physicalLine += 1
                recordStartLine = physicalLine
                if character == "\r", next < text.endIndex, text[next] == "\n" {
                    index = text.index(after: next)
                    continue
                }
            } else {
                try appendToField(character)
            }
            index = next
        }
        guard !inQuotes else { throw TransactionCSVImportError.malformedCSV }
        if !field.isEmpty || !record.isEmpty || closedQuotedField {
            try appendCurrentField()
            try appendCurrentRecord()
        }
        return records
    }

    static func delimiterCount(
        _ delimiter: Character,
        inFirstRecordOf text: String
    ) -> Int {
        var count = 0
        var inQuotes = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == "\"" {
                if inQuotes, next < text.endIndex, text[next] == "\"" {
                    index = text.index(after: next)
                    continue
                }
                inQuotes.toggle()
            } else if !inQuotes, character == delimiter {
                count += 1
            } else if !inQuotes, character == "\n" || character == "\r" {
                break
            }
            index = next
        }
        return count
    }
}
