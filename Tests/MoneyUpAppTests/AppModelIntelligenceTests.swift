import Foundation
@testable import MoneyUp
import MoneyUpCore
import MoneyUpIntelligence
import MoneyUpPersistence
import XCTest

final class AppModelIntelligenceTests: XCTestCase {
    @MainActor
    func testIndexedCaptureSuggestionDoesNotDependOnRecentEntryCache() async throws {
        let fixture = try IntelligenceAppFixture()
        defer { fixture.removeFiles() }
        let profile = fixture.profile()
        let dates = fixture.weeklyDates
        let entries = try fixture.expenses(
            dates: dates,
            amount: 12,
            payee: "Whole Book Cafe"
        )
        try await fixture.seed(profile: profile, entries: entries)
        let model = fixture.model(profile: profile)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertFalse(model.journalRecentEntriesAreCurrent)

        let result = await model.indexedCaptureSuggestion(
            for: CaptureSuggestionQuery(
                kind: .expense,
                payee: "Whole Book Cafe",
                currency: fixture.currency,
                occurredAt: dates[3]
            ),
            eligibleCategoryIDs: [fixture.category.id]
        )

        XCTAssertNil(result.accountSuggestion)
        XCTAssertEqual(result.categorySuggestion?.ledgerAccountID, fixture.category.id)
        XCTAssertEqual(result.categorySuggestion?.confidence, .high)
        XCTAssertEqual(
            result.categorySuggestion?.evidence.supportingEntryCount,
            entries.count
        )
        await fixture.store.close()
    }

    @MainActor
    func testRefreshPublishesThenOptOutClearsDerivedState() async throws {
        let fixture = try IntelligenceAppFixture()
        defer { fixture.removeFiles() }
        let profile = fixture.profile()
        let dates = fixture.weeklyDates
        let entries = try fixture.expenses(
            dates: dates,
            amount: 8,
            payee: "Weekly Cafe"
        )
        try await fixture.seed(profile: profile, entries: entries)
        let currentDate = dates[3].addingTimeInterval(86_400)
        let model = fixture.model(profile: profile, currentDate: { currentDate })

        model.refreshIntelligence()
        try await waitForIntelligenceToSettle(model)
        XCTAssertTrue(model.intelligenceFindings.contains {
            $0.kind == .recurrence
        })

        try await model.updateIntelligenceEnabled(false)
        XCTAssertEqual(model.profile?.intelligenceEnabled, false)
        XCTAssertTrue(model.intelligenceFindings.isEmpty)
        XCTAssertFalse(model.isIntelligenceRefreshing)
        let candidates = try await fixture.store.payeeAffinityCandidates(
            payee: "Weekly Cafe",
            currency: fixture.currency
        )
        XCTAssertTrue(candidates.isEmpty)
        let persisted = try await fixture.store.fetch(
            UserProfile.self,
            id: UserProfile.primaryRecordID,
            from: .profile
        )
        XCTAssertEqual(persisted?.intelligenceEnabled, false)
        await fixture.store.close()
    }

    @MainActor
    private func waitForIntelligenceToSettle(
        _ model: AppModel
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while model.isIntelligenceRefreshing, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isIntelligenceRefreshing)
    }
}

private struct IntelligenceAppFixture {
    let directoryURL: URL
    let store: EncryptedRecordStore
    let currency: CurrencyCode
    let account: LedgerAccount
    let category: LedgerAccount

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoneyUpIntelligenceAppTests-\(UUID().uuidString)")
        currency = try CurrencyCode("SGD")
        account = LedgerAccount(name: "Wallet", kind: .asset, currency: currency)
        category = LedgerAccount(name: "Food", kind: .expense)
        store = try EncryptedRecordStore(
            databaseURL: directoryURL.appendingPathComponent("moneyup.sqlite3"),
            key: Data(repeating: 0x5c, count: 32)
        )
    }

    var weeklyDates: [Date] {
        [0, 7, 14, 21].map {
            Date(timeIntervalSinceReferenceDate: 800_000_000 + Double($0 * 86_400))
        }
    }

    func profile() -> UserProfile {
        UserProfile(
            baseCurrency: currency,
            reportingTimeZoneIdentifier: "GMT"
        )
    }

    func expenses(
        dates: [Date],
        amount: Decimal,
        payee: String
    ) throws -> [JournalEntry] {
        try dates.map { date in
            try TransactionFactory.expense(
                amount: Money(amount, currency: currency),
                paidFrom: account.id,
                category: category.id,
                occurredAt: date,
                payee: payee
            )
        }
    }

    func seed(
        profile: UserProfile,
        entries: [JournalEntry]
    ) async throws {
        var writes = try [
            RecordWrite(profile, id: UserProfile.primaryRecordID, in: .profile),
            RecordWrite(account, id: account.id.uuidString, in: .accounts),
            RecordWrite(category, id: category.id.uuidString, in: .accounts)
        ]
        writes += try entries.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .journalEntries)
        }
        try await store.write(writes)
    }

    @MainActor
    func model(
        profile: UserProfile,
        currentDate: @escaping @Sendable () -> Date = Date.init
    ) -> AppModel {
        AppModel(
            store: store,
            profile: profile,
            accounts: [account, category],
            entries: [],
            lockedCaptureStore: EmptyLockedCaptureStore(),
            databaseURLForErase: directoryURL.appendingPathComponent("moneyup.sqlite3"),
            retainsCompleteJournal: false,
            currentDate: currentDate
        )
    }

    func removeFiles() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private actor EmptyLockedCaptureStore: LockedCaptureStoring {
    func all() async throws -> [LockedCapture] { [] }
    func append(_ capture: LockedCapture) async throws -> Int { 0 }
    func remove(id: UUID) async throws -> Int { 0 }
    func eraseAll() async throws {}
}
