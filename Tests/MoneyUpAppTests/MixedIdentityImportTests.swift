import Foundation
@testable import MoneyUp
import MoneyUpCore
import MoneyUpPersistence
import XCTest

/// A posted row and its ID-less pending copy must remain one transaction,
/// without collapsing genuine repeated purchases or rewriting saved identities.
final class MixedIdentityImportTests: XCTestCase {
    private let salary = LedgerAccount(name: "Salary", kind: .income)
    private let tap = "2026-08-20 08:15:00,Expense,2.10,Transit"

    private func statement(_ identities: [String]) throws -> [ImportedTransaction] {
        try TransactionCSVImporter.parse(
            (["ID,Date,Type,Amount,Payee"] + identities.map { "\($0),\(tap)" })
                .joined(separator: "\n"),
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        ).rows
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
    func testPostedAndPendingCopiesStayIdempotentInEitherSourceOrderAfterReopen() async throws {
        for identities in [["BANK-9", ""], ["", "BANK-9"]] {
            let fixture = try AppModelFixture()
            defer { fixture.removeFiles() }
            let accounts = [fixture.wallet, fixture.food, salary]
            let profile = UserProfile(baseCurrency: fixture.sgd)
            try await fixture.seed(profile: profile, accounts: accounts)
            let model = fixture.model(profile: profile, accounts: accounts)
            let rows = try statement(identities)
            let posted = try XCTUnwrap(rows.first(where: \.hasExternalID))
            let expectedFingerprint = TransactionCSVImporter.persistenceFingerprint(
                for: posted.id, sourceSystem: "CSV/Qianji"
            )

            let first = try await importing(rows, into: model, fixture: fixture)
            XCTAssertEqual(first.imported, 1)
            XCTAssertEqual(first.duplicates, 1)
            XCTAssertEqual(first.skipped, 0)
            let originalIDs = Set(model.entries.map(\.id))
            XCTAssertEqual(Set(model.entries.compactMap(\.sourceFingerprint)), [expectedFingerprint])
            for _ in 0..<2 {
                let repeated = try await importing(rows, into: model, fixture: fixture)
                XCTAssertEqual(repeated.imported, 0)
                XCTAssertEqual(repeated.duplicates, 2)
                XCTAssertEqual(repeated.skipped, 0)
                XCTAssertEqual(Set(model.entries.map(\.id)), originalIDs)
            }
            await fixture.store.close()
            let reopened = try fixture.reopenStore()
            let persisted = try await reopened.fetchAll(JournalEntry.self, from: .journalEntries)
            XCTAssertEqual(Set(persisted.map(\.id)), originalIDs)
            XCTAssertEqual(Set(persisted.compactMap(\.sourceFingerprint)), [expectedFingerprint])
            // The paged path must consult the encrypted journal, not an old in-memory cache.
            let restored = fixture.model(
                store: reopened, profile: profile, accounts: accounts,
                retainsCompleteJournal: false
            )
            let repeated = try await importing(rows, into: restored, fixture: fixture)
            XCTAssertEqual(repeated.imported, 0)
            XCTAssertEqual(repeated.duplicates, 2)
            let after = try await reopened.fetchAll(JournalEntry.self, from: .journalEntries)
            XCTAssertEqual(Set(after.map(\.id)), originalIDs)
            XCTAssertEqual(Set(after.compactMap(\.sourceFingerprint)), [expectedFingerprint])
            await reopened.close()
        }
    }

    @MainActor
    func testTwoPostedRowsCoverTwoPendingCopiesButPreserveTheExcessPurchase() async throws {
        for identities in [["BANK-A", "BANK-B", "", "", ""], ["", "BANK-A", "", "BANK-B", ""]] {
            let fixture = try AppModelFixture()
            defer { fixture.removeFiles() }
            let model = fixture.model(accounts: [fixture.wallet, fixture.food, salary])
            let rows = try statement(identities)
            let first = try await importing(rows, into: model, fixture: fixture)
            XCTAssertEqual(first.imported, 3)
            XCTAssertEqual(first.duplicates, 2)
            let originalIDs = Set(model.entries.map(\.id))
            let fingerprints = Set(model.entries.compactMap(\.sourceFingerprint))
            XCTAssertEqual(fingerprints.count, 3)
            for posted in rows.filter(\.hasExternalID) {
                XCTAssertTrue(fingerprints.contains(TransactionCSVImporter.persistenceFingerprint(
                    for: posted.id, sourceSystem: "CSV/Qianji"
                )))
            }
            let again = try await importing(rows, into: model, fixture: fixture)
            XCTAssertEqual(again.imported, 0)
            XCTAssertEqual(again.duplicates, 5)
            XCTAssertEqual(Set(model.entries.map(\.id)), originalIDs)
            XCTAssertEqual(Set(model.entries.compactMap(\.sourceFingerprint)), fingerprints)
            await fixture.store.close()
        }
    }

    @MainActor
    func testRepeatedPostedIdentityDoesNotCreateExtraPendingCoverage() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model(accounts: [fixture.wallet, fixture.food, salary])
        let rows = try statement(["BANK-A", "BANK-A", "", ""])
        let first = try await importing(rows, into: model, fixture: fixture)
        XCTAssertEqual(first.imported, 2, "Repeating BANK-A must not consume a second ID-less purchase")
        XCTAssertEqual(first.duplicates, 2)
        let originalIDs = Set(model.entries.map(\.id))
        let again = try await importing(rows, into: model, fixture: fixture)
        XCTAssertEqual(again.imported, 0)
        XCTAssertEqual(again.duplicates, 4)
        XCTAssertEqual(Set(model.entries.map(\.id)), originalIDs)
        await fixture.store.close()
    }

    @MainActor
    func testLegacyPostedIdentityStillCoversPendingCopyWithoutRewritingFingerprint() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let rows = try statement(["BANK-A", ""])
        let posted = rows[0]
        let legacyFingerprint = try XCTUnwrap(posted.legacyFingerprintCandidates.sorted().first)
        let base = try fixture.expense(amount: posted.amount, occurredAt: posted.occurredAt, payee: "Transit")
        let saved = try JournalEntry(
            kind: base.kind, occurredAt: base.occurredAt, createdAt: base.createdAt,
            payee: base.payee, note: base.note, postings: base.postings,
            sourceSystem: "CSV/Qianji", sourceFingerprint: legacyFingerprint,
            originContext: base.originContext
        )
        let profile = UserProfile(baseCurrency: fixture.sgd)
        let accounts = [fixture.wallet, fixture.food, salary]
        try await fixture.seed(profile: profile, accounts: accounts, entries: [saved])
        let model = fixture.model(profile: profile, accounts: accounts, entries: [saved])
        for _ in 0..<2 {
            let result = try await importing(rows, into: model, fixture: fixture)
            XCTAssertEqual(result.imported, 0)
            XCTAssertEqual(result.duplicates, 2)
            XCTAssertEqual(model.entries.map(\.id), [saved.id])
            XCTAssertEqual(model.entries.compactMap(\.sourceFingerprint), [legacyFingerprint])
        }
        await fixture.store.close()
    }

    @MainActor
    func testLegacyCandidateCollisionCannotCoverTwoDifferentPostedIdentities() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let posted = try statement(["BANK-A"])[0]
        let legacyFingerprint = try XCTUnwrap(posted.legacyFingerprintCandidates.sorted().first)
        let base = try fixture.expense(amount: posted.amount, occurredAt: posted.occurredAt, payee: "Transit")
        let saved = try JournalEntry(
            kind: base.kind, occurredAt: base.occurredAt, createdAt: base.createdAt,
            payee: base.payee, note: base.note, postings: base.postings,
            sourceSystem: "CSV/Qianji", sourceFingerprint: legacyFingerprint
        )
        let collision = ImportedTransaction(
            id: "distinct-authoritative-bank-id", hasExternalID: true,
            legacyFingerprintCandidates: [legacyFingerprint], sourceLine: 3,
            kind: posted.kind, occurredAt: posted.occurredAt,
            amount: posted.amount, payee: posted.payee
        )
        let profile = UserProfile(baseCurrency: fixture.sgd)
        let accounts = [fixture.wallet, fixture.food, salary]
        try await fixture.seed(profile: profile, accounts: accounts, entries: [saved])
        let model = fixture.model(profile: profile, accounts: accounts, entries: [saved])
        let result = try await importing([posted, collision], into: model, fixture: fixture)
        XCTAssertEqual(result.imported, 1, "A collision-prone legacy candidate has only one prior transaction to match")
        XCTAssertEqual(result.duplicates, 1)
        XCTAssertEqual(model.entries.count, 2)
        XCTAssertTrue(model.entries.contains { $0.id == saved.id && $0.sourceFingerprint == legacyFingerprint })
        await fixture.store.close()
    }

    @MainActor
    func testLegacyAndExactAliasesCannotCoverTwoPendingCopies() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let parsed = try statement(["BANK-A", "", ""])
        let posted = parsed[0]
        let legacyFingerprint = try XCTUnwrap(posted.legacyFingerprintCandidates.sorted().first)
        let base = try fixture.expense(amount: posted.amount, occurredAt: posted.occurredAt, payee: "Transit")
        let saved = try JournalEntry(
            kind: base.kind, occurredAt: base.occurredAt, createdAt: base.createdAt,
            payee: base.payee, note: base.note, postings: base.postings,
            sourceSystem: "CSV/Qianji", sourceFingerprint: legacyFingerprint
        )
        // A caller still using the old unscoped identity names the same saved entry.
        let exactAlias = ImportedTransaction(
            id: legacyFingerprint, hasExternalID: true, sourceLine: 3,
            kind: posted.kind, occurredAt: posted.occurredAt,
            amount: posted.amount, payee: posted.payee
        )
        let profile = UserProfile(baseCurrency: fixture.sgd)
        let accounts = [fixture.wallet, fixture.food, salary]
        try await fixture.seed(profile: profile, accounts: accounts, entries: [saved])
        let model = fixture.model(profile: profile, accounts: accounts, entries: [saved])
        let result = try await importing(
            [posted, exactAlias, parsed[1], parsed[2]], into: model, fixture: fixture
        )
        XCTAssertEqual(result.imported, 1, "Two aliases of one saved entry provide only one pending-copy slot")
        XCTAssertEqual(result.duplicates, 3)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(model.entries.count, 2)
        XCTAssertTrue(model.entries.contains { $0.id == saved.id && $0.sourceFingerprint == legacyFingerprint })
        await fixture.store.close()
    }

}
