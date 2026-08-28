import Foundation

/// A dependency-free Office Open XML export. The workbook uses inline-string
/// cells for every user-controlled value, so text beginning with `=`, `+`,
/// `-`, or `@` can never become an executable spreadsheet formula.
public enum LedgerXLSXExporter {
    /// Source-compatible convenience for callers already holding selected
    /// receipt payloads. The exporter immediately drops the bytes and uses
    /// only compact metadata/counts.
    public static func export(
        entries: [JournalEntry],
        accounts: [LedgerAccount],
        rates: [DatedExchangeRate] = [],
        attachments: [ReceiptAttachment]
    ) -> Data {
        export(
            entries: entries,
            accounts: accounts,
            rates: rates,
            attachmentMetadata: attachments.map(ReceiptAttachmentMetadata.init)
        )
    }

    public static func export(
        entries: [JournalEntry],
        accounts: [LedgerAccount],
        rates: [DatedExchangeRate] = [],
        attachmentMetadata: [ReceiptAttachmentMetadata] = []
    ) -> Data {
        let accountByID = Dictionary(
            accounts.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let attachmentCounts = Dictionary(grouping: attachmentMetadata, by: \.entryID)
            .mapValues { $0.count }
        let sortedEntries = entries.sorted {
            if $0.occurredAt == $1.occurredAt { return $0.createdAt < $1.createdAt }
            return $0.occurredAt < $1.occurredAt
        }

        var transactionRows: [[XLSXCell]] = [[
            .text("entry_id"), .text("entry_kind"), .text("occurred_at"),
            .text("origin_day"), .text("origin_calendar"), .text("origin_time_zone"),
            .text("origin_utc_offset_seconds"), .text("origin_inferred"),
            .text("created_at"), .text("payee"), .text("entry_note"),
            .text("posting_id"), .text("account_id"), .text("account_name"),
            .text("account_kind"), .number("amount"), .text("currency"),
            .text("posting_memo"), .text("source_system"),
            .text("source_fingerprint"), .number("receipt_attachment_count")
        ]]
        for entry in sortedEntries {
            for posting in entry.postings {
                let account = accountByID[posting.accountID]
                transactionRows.append([
                    .text(entry.id.uuidString.lowercased()),
                    .text(entry.kind.rawValue),
                    .text(iso8601(entry.occurredAt)),
                    .text(dayString(entry.originContext.dayKey)),
                    .text(entry.originContext.calendarIdentifier),
                    .text(entry.originContext.timeZoneIdentifier),
                    .number(String(entry.originContext.utcOffsetSeconds)),
                    .text(entry.originContext.wasInferred ? "true" : "false"),
                    .text(iso8601(entry.createdAt)),
                    .text(entry.payee ?? ""),
                    .text(entry.note ?? ""),
                    .text(posting.id.uuidString.lowercased()),
                    .text(posting.accountID.uuidString.lowercased()),
                    .text(account?.name ?? ""),
                    .text(account?.kind.rawValue ?? ""),
                    .number(NSDecimalNumber(decimal: posting.money.amount).stringValue),
                    .text(posting.money.currency.value),
                    .text(posting.memo ?? ""),
                    .text(entry.sourceSystem ?? ""),
                    .text(entry.sourceFingerprint ?? ""),
                    .number(String(attachmentCounts[entry.id, default: 0]))
                ])
            }
        }

        var accountRows: [[XLSXCell]] = [[
            .text("account_id"), .text("name"), .text("kind"),
            .text("currency"), .text("account_type"), .text("system_role"),
            .text("parent_account_id"), .text("archived")
        ]]
        accountRows += accounts.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { account in
                [
                    .text(account.id.uuidString.lowercased()),
                    .text(account.name),
                    .text(account.kind.rawValue),
                    .text(account.currency?.value ?? ""),
                    .text(account.accountType?.rawValue ?? ""),
                    .text(account.systemRole?.rawValue ?? ""),
                    .text(account.parentID?.uuidString.lowercased() ?? ""),
                    .text(account.isArchived ? "true" : "false")
                ]
            }

        var rateRows: [[XLSXCell]] = [[
            .text("rate_id"), .text("base_currency"), .text("quote_currency"),
            .number("quote_per_base"), .text("effective_day"),
            .text("origin_calendar"), .text("origin_time_zone"),
            .number("origin_utc_offset_seconds"),
            .text("created_at")
        ]]
        rateRows += rates.sorted { left, right in
            left.effectiveContext.dayKey < right.effectiveContext.dayKey
        }.map { rate in
            [
                .text(rate.id.uuidString.lowercased()),
                .text(rate.baseCurrency.value),
                .text(rate.quoteCurrency.value),
                .number(NSDecimalNumber(decimal: rate.rate).stringValue),
                .text(dayString(rate.effectiveContext.dayKey)),
                .text(rate.effectiveContext.calendarIdentifier),
                .text(rate.effectiveContext.timeZoneIdentifier),
                .number(String(rate.effectiveContext.utcOffsetSeconds)),
                .text(iso8601(rate.createdAt))
            ]
        }

        let files: [(String, Data)] = [
            ("[Content_Types].xml", xmlData(contentTypesXML)),
            ("_rels/.rels", xmlData(rootRelationshipsXML)),
            ("docProps/app.xml", xmlData(appPropertiesXML)),
            ("docProps/core.xml", xmlData(corePropertiesXML)),
            ("xl/workbook.xml", xmlData(workbookXML)),
            ("xl/_rels/workbook.xml.rels", xmlData(workbookRelationshipsXML)),
            ("xl/styles.xml", xmlData(stylesXML)),
            ("xl/worksheets/sheet1.xml", xmlData(worksheetXML(transactionRows))),
            ("xl/worksheets/sheet2.xml", xmlData(worksheetXML(accountRows))),
            ("xl/worksheets/sheet3.xml", xmlData(worksheetXML(rateRows)))
        ]
        return StoredZIPArchive(files: files).data()
    }

    private enum XLSXCell {
        case text(String)
        case number(String)
    }

    private static func worksheetXML(_ rows: [[XLSXCell]]) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        xml += "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
        xml += "<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews>"
        xml += "<sheetFormatPr defaultRowHeight=\"15\"/><sheetData>"
        for (rowIndex, row) in rows.enumerated() {
            let excelRow = rowIndex + 1
            xml += "<row r=\"\(excelRow)\">"
            for (columnIndex, cell) in row.enumerated() {
                let reference = columnName(columnIndex + 1) + String(excelRow)
                switch cell {
                case let .text(value):
                    xml += "<c r=\"\(reference)\" t=\"inlineStr\"\(rowIndex == 0 ? " s=\"1\"" : "")><is><t xml:space=\"preserve\">\(xmlEscape(value))</t></is></c>"
                case let .number(value):
                    if rowIndex == 0 {
                        xml += "<c r=\"\(reference)\" t=\"inlineStr\" s=\"1\"><is><t>\(xmlEscape(value))</t></is></c>"
                    } else {
                        xml += "<c r=\"\(reference)\"><v>\(xmlEscape(value))</v></c>"
                    }
                }
            }
            xml += "</row>"
        }
        xml += "</sheetData><autoFilter ref=\"A1:\(columnName(rows.first?.count ?? 1))\(max(rows.count, 1))\"/></worksheet>"
        return xml
    }

    private static func columnName(_ index: Int) -> String {
        var value = index
        var result = ""
        while value > 0 {
            value -= 1
            result.insert(Character(UnicodeScalar(65 + value % 26)!), at: result.startIndex)
            value /= 26
        }
        return result
    }

    private static func xmlEscape(_ value: String) -> String {
        var xmlSafe = ""
        for scalar in value.unicodeScalars {
            let codePoint = scalar.value
            let isAllowed = codePoint == 0x09 || codePoint == 0x0a || codePoint == 0x0d
                || (0x20...0xd7ff).contains(codePoint)
                || (0xe000...0xfffd).contains(codePoint)
                || (0x10000...0x10ffff).contains(codePoint)
            if isAllowed { xmlSafe.unicodeScalars.append(scalar) }
        }
        return xmlSafe
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func xmlData(_ value: String) -> Data { Data(value.utf8) }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func dayString(_ key: Int) -> String {
        String(format: "%04d-%02d-%02d", key / 10_000, key / 100 % 100, key % 100)
    }

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/worksheets/sheet3.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>
    """

    private static let rootRelationshipsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>
    """

    private static let workbookXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Transactions" sheetId="1" r:id="rId1"/><sheet name="Accounts" sheetId="2" r:id="rId2"/><sheet name="FX Rates" sheetId="3" r:id="rId3"/></sheets></workbook>
    """

    private static let workbookRelationshipsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet3.xml"/><Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
    """

    private static let stylesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Aptos"/></font><font><b/><color rgb="FFFFFFFF"/><sz val="11"/><name val="Aptos"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF39765B"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFill="1" applyFont="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
    """

    private static let appPropertiesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>MoneyUp</Application></Properties>
    """

    private static let corePropertiesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:creator>MoneyUp</dc:creator><dc:title>MoneyUp Ledger Export</dc:title></cp:coreProperties>
    """
}

private struct StoredZIPArchive {
    let files: [(String, Data)]

    func data() -> Data {
        struct DirectoryEntry {
            let name: Data
            let crc: UInt32
            let size: UInt32
            let offset: UInt32
        }

        var output = Data()
        var directory: [DirectoryEntry] = []
        for (nameString, contents) in files {
            let name = Data(nameString.utf8)
            let crc = CRC32.checksum(contents)
            let offset = UInt32(output.count)
            output.appendLittleEndian(UInt32(0x04034b50))
            output.appendLittleEndian(UInt16(20))
            output.appendLittleEndian(UInt16(0x0800))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(crc)
            output.appendLittleEndian(UInt32(contents.count))
            output.appendLittleEndian(UInt32(contents.count))
            output.appendLittleEndian(UInt16(name.count))
            output.appendLittleEndian(UInt16(0))
            output.append(name)
            output.append(contents)
            directory.append(
                DirectoryEntry(
                    name: name,
                    crc: crc,
                    size: UInt32(contents.count),
                    offset: offset
                )
            )
        }

        let centralOffset = UInt32(output.count)
        for entry in directory {
            output.appendLittleEndian(UInt32(0x02014b50))
            output.appendLittleEndian(UInt16(20))
            output.appendLittleEndian(UInt16(20))
            output.appendLittleEndian(UInt16(0x0800))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(entry.crc)
            output.appendLittleEndian(entry.size)
            output.appendLittleEndian(entry.size)
            output.appendLittleEndian(UInt16(entry.name.count))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt32(0))
            output.appendLittleEndian(entry.offset)
            output.append(entry.name)
        }
        let centralSize = UInt32(output.count) - centralOffset
        output.appendLittleEndian(UInt32(0x06054b50))
        output.appendLittleEndian(UInt16(0))
        output.appendLittleEndian(UInt16(0))
        output.appendLittleEndian(UInt16(directory.count))
        output.appendLittleEndian(UInt16(directory.count))
        output.appendLittleEndian(centralSize)
        output.appendLittleEndian(centralOffset)
        output.appendLittleEndian(UInt16(0))
        return output
    }
}

private enum CRC32 {
    static func checksum(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0)
            }
        }
        return crc ^ UInt32.max
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
