import CryptoKit
import Foundation

extension TransactionCSVImporter {
    private struct DelimitedParserState {
        let delimiter: Character
        var records: [DelimitedRecord] = []
        var record: [String] = []
        var field = ""
        var fieldByteCount = 0
        var inQuotes = false
        var closedQuotedField = false
        var physicalLine = 1
        var recordStartLine = 1

        mutating func consume(
            _ character: Character,
            next: Character?
        ) throws -> Bool {
            if inQuotes { return try consumeQuoted(character, next: next) }
            if closedQuotedField {
                return try consumeAfterQuotedField(character, next: next)
            }
            return try consumeUnquoted(character, next: next)
        }

        mutating func finish() throws -> [DelimitedRecord] {
            guard !inQuotes else { throw TransactionCSVImportError.malformedCSV }
            if !field.isEmpty || !record.isEmpty || closedQuotedField {
                try appendCurrentField()
                try appendCurrentRecord()
            }
            return records
        }

        private mutating func consumeQuoted(
            _ character: Character,
            next: Character?
        ) throws -> Bool {
            if character == "\"" {
                if next == "\"" {
                    try appendToField("\"")
                    return true
                }
                inQuotes = false
                closedQuotedField = true
                return false
            }
            try appendToField(character)
            if character == "\n" || (character == "\r" && next != "\n") {
                physicalLine += 1
            }
            return false
        }

        private mutating func consumeAfterQuotedField(
            _ character: Character,
            next: Character?
        ) throws -> Bool {
            if character == delimiter {
                try appendCurrentField()
                closedQuotedField = false
                return false
            }
            guard character == "\n" || character == "\r" else {
                throw TransactionCSVImportError.malformedCSV
            }
            try finishRecordLine()
            closedQuotedField = false
            return character == "\r" && next == "\n"
        }

        private mutating func consumeUnquoted(
            _ character: Character,
            next: Character?
        ) throws -> Bool {
            if character == "\"" {
                guard field.isEmpty else { throw TransactionCSVImportError.malformedCSV }
                inQuotes = true
            } else if character == delimiter {
                try appendCurrentField()
            } else if character == "\n" || character == "\r" {
                try finishRecordLine()
                return character == "\r" && next == "\n"
            } else {
                try appendToField(character)
            }
            return false
        }

        private mutating func finishRecordLine() throws {
            try appendCurrentField()
            try appendCurrentRecord()
            record = []
            physicalLine += 1
            recordStartLine = physicalLine
        }

        private mutating func appendToField(_ character: Character) throws {
            let byteCount = String(character).utf8.count
            guard fieldByteCount
                    <= TransactionCSVImporter.maximumFieldByteCount - byteCount else {
                throw TransactionCSVImportError.malformedCSV
            }
            field.append(character)
            fieldByteCount += byteCount
        }

        private mutating func appendCurrentField() throws {
            guard record.count < TransactionCSVImporter.maximumColumnCount else {
                throw TransactionCSVImportError.malformedCSV
            }
            record.append(field)
            field = ""
            fieldByteCount = 0
        }

        private mutating func appendCurrentRecord() throws {
            guard records.count < MonetaryInputPolicy.aggregateRecordBudget + 1 else {
                throw TransactionCSVImportError.tooManyRows
            }
            if records.isEmpty {
                try validateHeaderRecord()
            }
            records.append(DelimitedRecord(fields: record, sourceLine: recordStartLine))
        }

        private func validateHeaderRecord() throws {
            guard record.allSatisfy({
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && $0.utf8.count <= TransactionCSVImporter.maximumHeaderByteCount
            }) else {
                throw TransactionCSVImportError.malformedCSV
            }
            let headers = record.map(TransactionCSVImporter.normalizedHeader)
            guard Set(headers).count == headers.count else {
                throw TransactionCSVImportError.malformedCSV
            }
        }
    }

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
        var parser = DelimitedParserState(delimiter: delimiter)
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            let nextCharacter = next < text.endIndex ? text[next] : nil
            if try parser.consume(character, next: nextCharacter) {
                index = next
            }
            index = text.index(after: index)
        }
        return try parser.finish()
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
