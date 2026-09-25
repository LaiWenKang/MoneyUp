import Foundation
@testable import MoneyUp
import MoneyUpCore
import MoneyUpPersistence
import XCTest

/// P1: a statement lists each transaction once, so rows without a source ID
/// that match in every field are separate transactions (two coffees, several
/// transit taps). Each imports once, and re-importing skips them all.
final class RepeatedImportRowTests: XCTestCase {
    private let salary = LedgerAccount(name: "Salary", kind: .income)
    private let tap = "2026-08-20 08:15:00,Expense,2.10,Transit"

    private func statement(
        _ lines: [String],
        header: String = "Date,Type,Amount,Payee"
    ) throws -> [ImportedTransaction] {
        try TransactionCSVImporter.parse(
            ([header] + lines).joined(separator: "\n"),
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        ).rows
    }

    @MainActor
    private func importing(
        _ rows: [ImportedTransaction],
        into model: AppModel,
        _ fixture: AppModelFixture
    ) async throws -> (imported: Int, duplicates: Int) {
        let result = try await model.importTransactions(
            rows,
            fallbackAccountID: fixture.wallet.id,
            fallbackExpenseCategoryID: fixture.food.id,
            fallbackIncomeCategoryID: salary.id
        )
        return (result.imported, result.duplicates)
    }

    @MainActor
    private func transitCount(_ model: AppModel) -> Int {
        model.entries.filter { $0.payee == "Transit" }.count
    }

    @MainActor
    func testIdenticalStatementRowsImportOnceEachAndReimportSkipsThemAll() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model(accounts: [fixture.wallet, fixture.food, salary])
        let rows = try statement([tap, tap, tap])

        let first = try await importing(rows, into: model, fixture)
        XCTAssertEqual(first.imported, 3)
        XCTAssertEqual(first.duplicates, 0)
        XCTAssertEqual(Set(model.entries.compactMap(\.sourceFingerprint)).count, 3)

        let again = try await importing(rows, into: model, fixture)
        XCTAssertEqual(again.imported, 0)
        XCTAssertEqual(again.duplicates, 3)
        XCTAssertEqual(transitCount(model), 3)
        await fixture.store.close()
    }

    @MainActor
    func testAnEarlierEntryMatchesOneRowNotEveryRepeat() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let accounts = [fixture.wallet, fixture.food, salary]
        let logged = try TransactionFactory.expense(
            amount: try Money(try XCTUnwrap(Decimal(string: "2.10")), currency: fixture.sgd),
            paidFrom: fixture.wallet.id,
            category: fixture.food.id,
            occurredAt: try XCTUnwrap(
                ISO8601DateFormatter().date(from: "2026-08-20T08:15:00Z")
            ),
            payee: "Transit"
        )
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await fixture.seed(profile: profile, accounts: accounts, entries: [logged])
        let model = fixture.model(profile: profile, accounts: accounts, entries: [logged])

        let result = try await importing(try statement([tap, tap]), into: model, fixture)

        XCTAssertEqual(result.imported, 1, "The logged tap is one of the two")
        XCTAssertEqual(result.duplicates, 1)
        XCTAssertEqual(transitCount(model), 2)
        await fixture.store.close()
    }

    @MainActor
    func testAnOverlappingStatementImportsOnlyTheNewRepeat() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model(accounts: [fixture.wallet, fixture.food, salary])
        let evening = "2026-08-20 18:00:00,Expense,2.10,Transit"

        // A morning export holds one tap; the full-day export holds that tap,
        // a second identical one and an evening tap.
        let morning = try await importing(try statement([tap]), into: model, fixture)
        let fullDay = try await importing(
            try statement([tap, tap, evening]),
            into: model,
            fixture
        )

        XCTAssertEqual(morning.imported, 1)
        XCTAssertEqual(fullDay.imported, 2)
        XCTAssertEqual(fullDay.duplicates, 1)
        XCTAssertEqual(transitCount(model), 3)
        await fixture.store.close()
    }

    @MainActor
    func testARowWithASourceIDStillCoversALaterCopyWithoutOne() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model(accounts: [fixture.wallet, fixture.food, salary])
        // A bank export can list a posted transaction and its pending copy.
        let rows = try statement(
            ["BANK-9,\(tap)", ",\(tap)"],
            header: "ID,Date,Type,Amount,Payee"
        )
        XCTAssertEqual(rows.map(\.hasExternalID), [true, false])

        let result = try await importing(rows, into: model, fixture)

        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(result.duplicates, 1)
        XCTAssertEqual(transitCount(model), 1)
        await fixture.store.close()
    }
}
