import Foundation
@testable import MoneyUpCore
@testable import MoneyUpIntelligence
@testable import MoneyUpPersistence
import XCTest

final class IntelligenceIndexTests: XCTestCase {
    func testAffinityUsesEntireEncryptedIndexAndTracksEditDelete() async throws {
        let fixture = try IntelligenceDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let book = try makeBook(entryCount: 240, payee: "  North Café  ")
        try await store.write(book.accountWrites + book.entryWrites)

        var candidates = try await store.payeeAffinityCandidates(
            payee: "north cafe",
            currency: book.currency
        )
        XCTAssertEqual(candidates.first?.categoryID, book.category.id)
        XCTAssertEqual(candidates.first?.occurrenceCount, 240)
        let initialDiagnostics = await store.lastIntelligenceReadDiagnostics()
        XCTAssertEqual(initialDiagnostics.journalPayloadsDecoded, 0)

        let original = try XCTUnwrap(book.entries.last)
        let edited = try replacement(original, payee: "South Market")
        try await store.upsert(
            edited,
            id: edited.id.uuidString,
            in: .journalEntries
        )
        candidates = try await store.payeeAffinityCandidates(
            payee: "north cafe",
            currency: book.currency
        )
        XCTAssertEqual(candidates.first?.occurrenceCount, 239)
        let editedCandidates = try await store.payeeAffinityCandidates(
            payee: "south market",
            currency: book.currency
        )
        XCTAssertEqual(editedCandidates.first?.occurrenceCount, 1)

        try await store.remove(id: edited.id.uuidString, from: .journalEntries)
        let removedCandidates = try await store.payeeAffinityCandidates(
            payee: "south market",
            currency: book.currency
        )
        XCTAssertTrue(removedCandidates.isEmpty)
        await store.close()
    }

    func testIndexedObservationsAreBoundedCurrencyExactAndPayloadFree() async throws {
        let fixture = try IntelligenceDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let book = try makeBook(entryCount: 12, payee: "Transit")
        try await store.write(book.accountWrites + book.entryWrites)
        let firstDay = try XCTUnwrap(
            book.entries.map(\.originContext.dayKey).min()
        )
        let lastDay = try XCTUnwrap(
            book.entries.map(\.originContext.dayKey).max()
        )

        let observations = try await store.intelligenceObservations(
            originDayKeyRange: firstDay...lastDay,
            limit: 5
        )
        let diagnostics = await store.lastIntelligenceReadDiagnostics()

        XCTAssertEqual(observations.count, 5)
        XCTAssertTrue(observations.allSatisfy { $0.amount.currency == book.currency })
        XCTAssertTrue(observations.allSatisfy { $0.amount.amount == 12.34 })
        XCTAssertEqual(diagnostics.observationRowsRead, 5)
        XCTAssertEqual(diagnostics.journalPayloadsDecoded, 0)
        await store.close()
    }

    func testProfileOptOutClearsAndReenableRebuildsDerivedIndexes() async throws {
        let fixture = try IntelligenceDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let book = try makeBook(entryCount: 8, payee: "Grocer")
        try await store.write(book.accountWrites + book.entryWrites)
        var profile = UserProfile(
            baseCurrency: book.currency,
            intelligenceEnabled: false,
            reportingTimeZoneIdentifier: "GMT"
        )
        try await store.upsert(
            profile,
            id: UserProfile.primaryRecordID,
            in: .profile
        )

        let disabledCandidates = try await store.payeeAffinityCandidates(
            payee: "Grocer",
            currency: book.currency
        )
        let disabledObservations = try await store.intelligenceObservations(
            originDayKeyRange: 20260101...20261231
        )
        let retainedEntryCount = try await store.count(in: .journalEntries)
        XCTAssertTrue(disabledCandidates.isEmpty)
        XCTAssertTrue(disabledObservations.isEmpty)
        XCTAssertEqual(retainedEntryCount, 8)

        profile.intelligenceEnabled = true
        try await store.upsert(
            profile,
            id: UserProfile.primaryRecordID,
            in: .profile
        )
        let enabledCandidates = try await store.payeeAffinityCandidates(
            payee: "Grocer",
            currency: book.currency
        )
        XCTAssertEqual(enabledCandidates.first?.occurrenceCount, 8)
        await store.close()
    }

    func testSchema6MigrationPreservesPayloadBytesAndBuildsCurrentIndex() async throws {
        let fixture = try IntelligenceDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let book = try makeBook(entryCount: 5, payee: "Legacy Café")
        try await store.write(book.accountWrites + book.entryWrites)
        let before = try await store.snapshot().records
        try await store.installSchema6IntelligenceStateForTesting()
        await store.close()

        let migrated = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let after = try await migrated.snapshot().records
        let counts = try await migrated.recordCountSnapshot()

        XCTAssertEqual(after, before)
        XCTAssertEqual(counts.schemaVersion, 8)
        let candidates = try await migrated.payeeAffinityCandidates(
            payee: "legacy cafe",
            currency: book.currency
        )
        XCTAssertEqual(candidates.first?.occurrenceCount, 5)
        await migrated.close()
    }

    func testSnapshotRestoreRebuildsAffinityInsideReplacementTransaction() async throws {
        let fixture = try IntelligenceDatabaseFixture()
        let store = try EncryptedRecordStore(
            databaseURL: fixture.databaseURL,
            key: fixture.key
        )
        let book = try makeBook(entryCount: 6, payee: "Restore Shop")
        try await store.write(book.accountWrites + book.entryWrites)
        let snapshot = try await store.snapshot()
        try await store.removeAll(from: .journalEntries)
        let removedCandidates = try await store.payeeAffinityCandidates(
            payee: "Restore Shop",
            currency: book.currency
        )
        XCTAssertTrue(removedCandidates.isEmpty)

        try await store.restore(snapshot)

        let restoredCandidates = try await store.payeeAffinityCandidates(
            payee: "Restore Shop",
            currency: book.currency
        )
        XCTAssertEqual(restoredCandidates.first?.occurrenceCount, 6)
        await store.close()
    }

    private func makeBook(
        entryCount: Int,
        payee: String
    ) throws -> IntelligenceBook {
        let currency = try CurrencyCode("SGD")
        let account = LedgerAccount(
            name: "Wallet",
            kind: .asset,
            currency: currency
        )
        let category = LedgerAccount(name: "Category", kind: .expense)
        let start = try utcDate(year: 2026, month: 1, day: 1)
        let entries = try (0..<entryCount).map { offset in
            let date = start.addingTimeInterval(TimeInterval(offset * 86_400))
            let origin = TransactionOriginContext.capture(
                for: date,
                timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0))
            )
            return try JournalEntry(
                kind: .expense,
                occurredAt: date,
                payee: payee,
                postings: [
                    Posting(
                        accountID: category.id,
                        money: try Money(12.34, currency: currency)
                    ),
                    Posting(
                        accountID: account.id,
                        money: try Money(-12.34, currency: currency)
                    )
                ],
                originContext: origin
            )
        }
        return IntelligenceBook(
            currency: currency,
            account: account,
            category: category,
            entries: entries,
            accountWrites: [
                try RecordWrite(account, id: account.id.uuidString, in: .accounts),
                try RecordWrite(category, id: category.id.uuidString, in: .accounts)
            ],
            entryWrites: try entries.map {
                try RecordWrite($0, id: $0.id.uuidString, in: .journalEntries)
            }
        )
    }

    private func replacement(
        _ entry: JournalEntry,
        payee: String
    ) throws -> JournalEntry {
        try JournalEntry(
            id: entry.id,
            kind: entry.kind,
            occurredAt: entry.occurredAt,
            createdAt: entry.createdAt,
            payee: payee,
            note: entry.note,
            postings: entry.postings,
            supersedesID: entry.supersedesID,
            revisedAt: entry.revisedAt,
            sourceSystem: entry.sourceSystem,
            sourceFingerprint: entry.sourceFingerprint,
            originContext: entry.originContext
        )
    }

    private func utcDate(year: Int, month: Int, day: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        return try XCTUnwrap(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day
        )))
    }
}

private struct IntelligenceBook {
    let currency: CurrencyCode
    let account: LedgerAccount
    let category: LedgerAccount
    let entries: [JournalEntry]
    let accountWrites: [RecordWrite]
    let entryWrites: [RecordWrite]
}

private struct IntelligenceDatabaseFixture {
    let directoryURL: URL
    let databaseURL: URL
    let key = Data(repeating: 0x27, count: 32)

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        databaseURL = directoryURL.appendingPathComponent("moneyup.sqlite")
    }
}
