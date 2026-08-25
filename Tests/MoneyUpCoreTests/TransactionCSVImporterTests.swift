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
}
