import Foundation
@testable import MoneyUpCore
import Testing

struct TransactionCSVImporterTests {
    @Test
    func parsesGenericCSVWithQuotedCommasAndBOM() throws {
        let csv = """
        \u{feff}Date,Type,Amount,Account,Category,Payee,Note
        2026-08-20 12:30:00,Expense,12.50,Wallet,Food,"Cafe, One","Lunch, tea"
        2026-08-21 09:00:00,Income,1000,Bank,Salary,Employer,
        """

        let preview = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(preview.issues.isEmpty)
        #expect(preview.rows.count == 2)
        #expect(preview.rows[0].kind == .expense)
        #expect(preview.rows[0].amount == Decimal(string: "12.50"))
        #expect(preview.rows[0].payee == "Cafe, One")
        #expect(preview.rows[0].note == "Lunch, tea")
        #expect(preview.rows[1].kind == .income)
    }

    @Test
    func parsesChineseQianjiStyleHeadersAndRefund() throws {
        let csv = """
        时间,账单类型,金额,资产账户,分类,交易对象,备注,账单ID
        2026-08-20 12:30:00,支出,12.50,现金,餐饮,咖啡店,午餐,a-1
        2026-08-21 12:30:00,退款,3.00,现金,餐饮,咖啡店,退差价,a-2
        """

        let preview = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "zh_CN"),
            timeZone: TimeZone(secondsFromGMT: 8 * 3_600)!
        )

        #expect(preview.issues.isEmpty)
        #expect(preview.rows.map(\.kind) == [.expense, .refund])
        #expect(preview.rows[0].accountName == "现金")
        #expect(preview.rows[0].id != preview.rows[1].id)
    }

    @Test
    func safelyAcceptsForeignDecimalSeparatorWithoutTurningItIntoThousands() throws {
        let csv = "Date;Type;Amount\n2026-08-20;Expense;12,50\n"

        let preview = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(preview.rows.first?.amount == Decimal(string: "12.50"))
    }

    @Test
    func previewsBadRowsInsteadOfDroppingWholeFile() throws {
        let csv = """
        Date,Type,Amount
        bad date,Expense,12
        2026-08-20,Debt,10
        2026-08-21,Income,5
        """

        let preview = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(preview.rows.count == 1)
        #expect(preview.issues.map(\.reason) == ["invalid_date", "unsupported_type"])
    }

    @Test
    func parsesYNABOutflowAndInflowColumns() throws {
        let csv = """
        Date,Payee,Category,Memo,Outflow,Inflow
        2026-08-20,Shop,Food,,12.50,
        2026-08-21,Employer,Salary,,,2000
        """

        let preview = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(preview.rows.map(\.kind) == [.expense, .income])
    }

    @Test
    func rejectsMoneyUpPostingExportRatherThanDuplicatingJournalRows() {
        let csv = "entry_id,posting_id,occurred_at,amount,currency\na,b,2026-08-20,-5,SGD\n"

        do {
            _ = try TransactionCSVImporter.parse(csv)
            Issue.record("Expected the posting-level export to be rejected")
        } catch let error as TransactionCSVImportError {
            #expect(error == .postingLevelExportRequiresArchive)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func mapsUnknownHeadersWithoutGuessingColumns() throws {
        let csv = "When,Flow,Value,Wallet Name,Bucket\n2026-08-26,Expense,12.50,Cash,Food\n"
        let inspection = try TransactionCSVImporter.inspect(csv)
        #expect(!inspection.suggestedMapping.hasRequiredColumns)

        var mapping = CSVColumnMapping()
        mapping[.date] = 0
        mapping[.kind] = 1
        mapping[.amount] = 2
        mapping[.account] = 3
        mapping[.category] = 4
        let preview = try TransactionCSVImporter.parse(
            csv,
            mapping: mapping,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(preview.rows.count == 1)
        #expect(preview.rows[0].accountName == "Cash")
        #expect(preview.rows[0].categoryName == "Food")
    }

    @Test
    func preservesExplicitImportOffsetForStableOriginDay() throws {
        let csv = "Date,Type,Amount\n2026-08-27T00:30:00+14:00,Expense,5\n"

        let preview = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(preview.rows.first?.originContext?.dayKey == 20260827)
        #expect(preview.rows.first?.originContext?.utcOffsetSeconds == 14 * 3_600)
    }

    @Test
    func rejectsGarbageSuffixInsteadOfSilentlyTruncatingAmount() throws {
        let csv = "Date,Type,Amount\n2026-08-20,Expense,12abc\n"

        let preview = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(preview.rows.isEmpty)
        #expect(preview.issues.map(\.reason) == ["invalid_amount"])
    }

    @Test
    func rejectsOversizedAmountTokensBeforeNumericParsing() throws {
        let csv = "Date,Type,Amount\n2026-08-20,Expense,"
            + String(repeating: "1", count: 129)
            + "\n"

        let preview = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(preview.rows.isEmpty)
        #expect(preview.issues.map(\.reason) == ["invalid_amount"])
    }

    @Test
    func acceptsOnlyRecognizedCurrencyDecorationsAroundCompleteAmount() throws {
        let csv = """
        Date,Type,Amount
        2026-08-20,Expense,$12.50
        2026-08-21,Income,SGD 8.25
        2026-08-22,Refund,7.00 SGD
        """

        let preview = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(preview.issues.isEmpty)
        #expect(preview.rows.map(\.amount) == [
            Decimal(string: "12.50")!,
            Decimal(string: "8.25")!,
            Decimal(string: "7.00")!
        ])
    }

    @Test
    func ambiguousSlashDateUsesImportLocaleOrder() throws {
        let csv = "Date,Type,Amount\n03/04/2026,Expense,1\n"
        let utc = TimeZone(secondsFromGMT: 0)!

        let us = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_US"),
            timeZone: utc
        )
        let gb = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_GB"),
            timeZone: utc
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc

        #expect(calendar.component(.month, from: us.rows[0].occurredAt) == 3)
        #expect(calendar.component(.day, from: us.rows[0].occurredAt) == 4)
        #expect(calendar.component(.month, from: gb.rows[0].occurredAt) == 4)
        #expect(calendar.component(.day, from: gb.rows[0].occurredAt) == 3)
    }

    @Test
    func explicitTypeCanUseMappedOutflowAndInflowWithoutAmountColumn() throws {
        let csv = """
        Date,Type,Outflow,Inflow
        2026-08-20,Expense,12.50,
        2026-08-21,Income,,2000
        2026-08-22,Refund,,3.25
        """

        let preview = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(preview.issues.isEmpty)
        #expect(preview.rows.map(\.kind) == [.expense, .income, .refund])
        #expect(preview.rows.map(\.amount) == [
            Decimal(string: "12.50")!,
            Decimal(2000),
            Decimal(string: "3.25")!
        ])
    }

    @Test
    func rejectsContradictoryOrMismatchedFlowColumns() throws {
        let csv = """
        Date,Type,Amount,Outflow,Inflow
        2026-08-20,Expense,,12,5
        2026-08-21,Income,10,,9
        2026-08-22,Income,,4,
        """

        let preview = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(preview.rows.isEmpty)
        #expect(preview.issues.map(\.reason) == [
            "invalid_amount", "invalid_amount", "invalid_amount"
        ])
    }

    @Test
    func rejectsMalformedQuotePlacementAndTrailingCharacters() {
        let malformedInputs = [
            "Date,Type,Amount\n2026-08-20,Exp\"ense,12\n",
            "Date,Type,Amount\n2026-08-20,\"Expense\"oops,12\n"
        ]

        for csv in malformedInputs {
            do {
                _ = try TransactionCSVImporter.parse(csv)
                Issue.record("Expected malformed quote placement to be rejected")
            } catch let error as TransactionCSVImportError {
                #expect(error == .malformedCSV)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test
    func rejectsRowsBeyondTheAggregateImportBudgetDuringParsing() {
        let header = "Date,Type,Amount\n"
        let row = "2026-08-20,Expense,1\n"
        let csv = header + String(
            repeating: row,
            count: MonetaryInputPolicy.aggregateRecordBudget + 1
        )

        do {
            _ = try TransactionCSVImporter.parse(csv)
            Issue.record("Expected oversized row count to be rejected")
        } catch let error as TransactionCSVImportError {
            #expect(error == .tooManyRows)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func issueLinesRemainPhysicalAfterQuotedMultilineFields() throws {
        let csv = """
        Date,Type,Amount,Note
        2026-08-20,Expense,12,"first line
        second line"
        bad date,Expense,3,invalid
        """

        let preview = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(preview.rows.count == 1)
        #expect(preview.rows.first?.sourceLine == 2)
        #expect(preview.rows.first?.note == "first line\nsecond line")
        #expect(preview.issues.map(\.line) == [4])
    }
}
