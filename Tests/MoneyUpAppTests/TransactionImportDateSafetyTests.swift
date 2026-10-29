import Foundation
@testable import MoneyUp
import MoneyUpCore
import MoneyUpPersistence
import XCTest

final class TransactionImportDateSafetyTests: XCTestCase {
    private let salary = LedgerAccount(name: "Salary", kind: .income)
    private let ordinaryDate = Date(timeIntervalSince1970: 1_787_213_700.75)

    private var unsafeSeconds: [Double] {
        [
            .nan, .infinity, -.infinity,
            Double(Int64.max), Double(Int64.max).nextUp,
            Double(Int64.min).nextDown, 1e20, -1e20
        ]
    }

    private func row(
        id: String,
        date: Date,
        category: String? = nil
    ) -> ImportedTransaction {
        ImportedTransaction(
            id: id,
            sourceLine: 2,
            kind: .expense,
            occurredAt: date,
            amount: 2,
            categoryName: category,
            payee: "Transit"
        )
    }

    @MainActor
    private func importing(
        _ rows: [ImportedTransaction],
        into model: AppModel,
        fixture: AppModelFixture
    ) async throws -> AppModel.TransactionImportResult {
        try await model.importTransactions(
            rows,
            fallbackAccountID: fixture.wallet.id,
            fallbackExpenseCategoryID: fixture.food.id,
            fallbackIncomeCategoryID: salary.id
        )
    }

    @MainActor
    private func key(
        for date: Date,
        model: AppModel,
        fixture: AppModelFixture
    ) -> String? {
        model.transactionImportDuplicateKey(
            kind: .expense,
            occurredAt: date,
            amount: 2,
            currency: fixture.sgd,
            sourceID: fixture.wallet.id,
            payee: nil
        )
    }

    @MainActor
    func testValidDuplicateKeysRetainExactEncodingAndFloorRounding() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()
        // The upper endpoint is exclusive: Double(Int64.max) rounds to 2^63.
        // These test key conversion only, not calendar/ledger date acceptance.
        let cases: [(Double, String)] = [
            (0, "0"), (0.75, "0"), (-0.25, "-1"),
            (-1.25, "-2"), (1_787_213_700.75, "1787213700"),
            (Double(Int64.min), "-9223372036854775808"),
            (Double(Int64.max).nextDown, "9223372036854774784")
        ]
        for (seconds, expectedSeconds) in cases {
            let components = [
                "expense", expectedSeconds, "2", "SGD",
                fixture.wallet.id.uuidString.lowercased(), "", "", "", ""
            ]
            let expected = components.map { "\($0.utf8.count):\($0)" }.joined()
            XCTAssertEqual(
                key(for: Date(timeIntervalSince1970: seconds), model: model, fixture: fixture),
                expected
            )
        }
        await fixture.store.close()
    }

    @MainActor
    func testNonfiniteAndOutOfRangeDuplicateKeysAreRejected() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()
        for seconds in unsafeSeconds {
            XCTAssertNil(key(
                for: Date(timeIntervalSince1970: seconds),
                model: model,
                fixture: fixture
            ))
        }
        await fixture.store.close()
    }

    @MainActor
    func testUnsafeRowsAreSkippedWithoutAnyPersistedOrInMemorySideEffects() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let accounts = [fixture.wallet, fixture.food, salary]
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await fixture.seed(profile: profile, accounts: accounts)
        let model = fixture.model(profile: profile, accounts: accounts)
        let before = try await fixture.store.snapshot().records
        let rows = unsafeSeconds.enumerated().map { index, seconds in
            row(
                id: "unsafe-\(index)",
                date: Date(timeIntervalSince1970: seconds),
                category: "Must not be created"
            )
        }

        let result = try await importing(rows, into: model, fixture: fixture)

        XCTAssertEqual(result.imported, 0)
        XCTAssertEqual(result.skipped, rows.count)
        XCTAssertEqual(result.duplicates, 0)
        XCTAssertEqual(result.categoriesCreated, 0)
        XCTAssertEqual(model.accounts, accounts)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertTrue(model.budgetNodes.isEmpty)
        XCTAssertTrue(model.budgetEntryAttributions.isEmpty)
        let after = try await fixture.store.snapshot().records
        XCTAssertEqual(after, before, "No category, timeline, attribution or journal writes")
        await fixture.store.close()
    }

    @MainActor
    func testUnsafeRowReleasesIdentityForValidRowInSameBatch() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model(accounts: [fixture.wallet, fixture.food, salary])
        let valid = row(id: "same-identity", date: ordinaryDate)
        let invalid = row(
            id: valid.id,
            date: Date(timeIntervalSince1970: .infinity),
            category: "Must not be created"
        )

        let result = try await importing([invalid, valid], into: model, fixture: fixture)

        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.duplicates, 0)
        XCTAssertEqual(result.categoriesCreated, 0)
        XCTAssertEqual(model.entries.count, 1)
        XCTAssertEqual(model.entries.first?.occurredAt, ordinaryDate)
        XCTAssertFalse(model.accounts.contains { $0.name == "Must not be created" })
        let stored = try await fixture.store.fetchAll(
            JournalEntry.self,
            from: .journalEntries
        )
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.occurredAt, ordinaryDate)

        let again = try await importing([valid], into: model, fixture: fixture)
        XCTAssertEqual(again.imported, 0)
        XCTAssertEqual(again.duplicates, 1)
        XCTAssertEqual(again.skipped, 0)

        // A changed source identity still matches by the same floored second.
        let beforeSemanticDuplicate = try await fixture.store.snapshot().records
        let semanticDuplicate = try await importing(
            [row(id: "different-identity", date: ordinaryDate.addingTimeInterval(-0.5))],
            into: model,
            fixture: fixture
        )
        XCTAssertEqual(semanticDuplicate.imported, 0)
        XCTAssertEqual(semanticDuplicate.duplicates, 1)
        XCTAssertEqual(semanticDuplicate.skipped, 0)
        XCTAssertEqual(model.entries.count, 1)
        let afterSemanticDuplicate = try await fixture.store.snapshot().records
        XCTAssertEqual(afterSemanticDuplicate, beforeSemanticDuplicate)
        await fixture.store.close()
    }

    @MainActor
    func testExistingFingerprintStillTakesPrecedenceOverUnsafeDate() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model(accounts: [fixture.wallet, fixture.food, salary])
        let valid = row(id: "existing-identity", date: ordinaryDate)
        _ = try await importing([valid], into: model, fixture: fixture)
        let before = try await fixture.store.snapshot().records

        let result = try await importing(
            [row(id: valid.id, date: Date(timeIntervalSince1970: .nan))],
            into: model,
            fixture: fixture
        )

        XCTAssertEqual(result.imported, 0)
        XCTAssertEqual(result.duplicates, 1)
        XCTAssertEqual(result.skipped, 0)
        let after = try await fixture.store.snapshot().records
        XCTAssertEqual(after, before)
        await fixture.store.close()
    }
}
