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
        let reviewed = try await model.intelligenceHistoryEntries(
            entryIDs: entries.map(\.id)
        )
        XCTAssertEqual(Set(reviewed.map(\.id)), Set(entries.map(\.id)))
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
        await model.waitForCurrentIntelligenceRefresh()
        XCTAssertFalse(model.isIntelligenceRefreshing)
        XCTAssertTrue(model.intelligenceFindings.contains {
            $0.kind == .recurrence
        })
        XCTAssertTrue(model.scheduledTransactions.isEmpty)
        let recurrence = try XCTUnwrap(model.intelligenceFindings.first {
            $0.kind == .recurrence
        })
        guard case let .scheduleOffer(offer) = recurrence.route else {
            return XCTFail("Recurrence must remain review-only schedule offer")
        }
        let schedule = try ScheduledTransaction(
            kind: offer.kind,
            name: offer.payeeKey,
            amount: offer.amount,
            accountID: offer.accountID,
            categoryAccountID: offer.categoryID,
            nextOccurrence: dates[3].addingTimeInterval(7 * 86_400),
            frequency: offer.frequency,
            recurrenceTimeZoneIdentifier: "GMT"
        )
        try await model.addScheduledTransaction(schedule)
        XCTAssertFalse(model.intelligenceFindings.contains {
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
    func testMonthEndProjectionSeparatesCurrenciesAndConfirmedSchedules() async throws {
        let fixture = try IntelligenceAppFixture()
        defer { fixture.removeFiles() }
        let asOf = try fixture.date(2026, 7, 15)
        let profile = fixture.profile()
        let entries = try [
            fixture.expense(
                date: try fixture.date(2026, 7, 5),
                amount: 100,
                account: fixture.account,
                category: fixture.category,
                payee: "Food"
            ),
            fixture.expense(
                date: try fixture.date(2026, 7, 6),
                amount: 50,
                account: fixture.foreignAccount,
                category: fixture.foreignCategory,
                payee: "Travel"
            )
        ]
        let alignedNodes = [
            BudgetNode(
                id: fixture.category.id,
                name: "Food",
                purpose: .flexible
            ),
            BudgetNode(
                id: fixture.foreignCategory.id,
                name: "Travel",
                purpose: .flexible
            )
        ]
        var schedule = try ScheduledTransaction(
            kind: .expense,
            name: "Confirmed bill",
            amount: Money(40, currency: fixture.currency),
            accountID: fixture.account.id,
            categoryAccountID: fixture.category.id,
            nextOccurrence: try fixture.date(2026, 7, 20),
            frequency: .monthly,
            recurrenceTimeZoneIdentifier: "GMT"
        )
        try schedule.confirmCurrent(
            occurrenceID: schedule.currentOccurrenceID,
            at: asOf
        )
        try await fixture.seed(profile: profile, entries: entries)
        let model = fixture.model(
            profile: profile,
            currentDate: { asOf },
            budgetNodes: alignedNodes,
            scheduledTransactions: [schedule]
        )

        let result = await model.monthEndProjectionResult()
        guard case let .available(projections) = result else {
            return XCTFail("Expected an available projection")
        }
        XCTAssertEqual(projections.map(\.projectedTotal.currency), [
            fixture.currency, fixture.foreignCurrency
        ])
        let base = try XCTUnwrap(projections.first {
            $0.projectedTotal.currency == fixture.currency
        })
        XCTAssertEqual(base.committedActuals.amount, 100)
        XCTAssertEqual(base.remainingSchedules.amount, 40)
        XCTAssertEqual(base.flexibleBurnRateProjection.amount, Decimal(string: "106.67"))
        XCTAssertEqual(base.projectedTotal.amount, Decimal(string: "246.67"))
        let foreign = try XCTUnwrap(projections.first {
            $0.projectedTotal.currency == fixture.foreignCurrency
        })
        XCTAssertEqual(foreign.committedActuals.amount, 50)
        XCTAssertEqual(foreign.remainingSchedules.amount, .zero)
        XCTAssertEqual(foreign.flexibleBurnRateProjection.amount, Decimal(string: "53.33"))
        XCTAssertEqual(foreign.projectedTotal.amount, Decimal(string: "103.33"))

        let early = await model.monthEndProjectionResult(
            asOf: try fixture.date(2026, 7, 6)
        )
        guard case let .unavailable(issue) = early else {
            return XCTFail("An early-month projection must not substitute zero")
        }
        XCTAssertEqual(issue, .intelligenceProjectionUnavailable)
        await fixture.store.close()
    }

    @MainActor
    func testBudgetSuggestionsApplyAndUndoAsOneReviewedPatch() async throws {
        let fixture = try IntelligenceAppFixture()
        defer { fixture.removeFiles() }
        let profile = fixture.profile()
        let asOf = try fixture.date(2026, 8, 15)
        let firstNode = BudgetNode(
            id: fixture.category.id,
            name: "Food",
            limit: try Money(80, currency: fixture.currency),
            purpose: .flexible
        )
        let secondNode = BudgetNode(
            id: fixture.categoryTwo.id,
            name: "Transport",
            limit: try Money(40, currency: fixture.currency),
            purpose: .flexible
        )
        let nodes = [firstNode, secondNode]
        let timeline = try BudgetConfigurationTimeline(
            currency: fixture.currency,
            revisions: [BudgetConfigurationRevision(
                effectiveMonth: try fixture.monthStart(2026, 2),
                nodes: nodes
            )]
        )
        let monthStarts = try (2...7).map { try fixture.date(2026, $0, 5) }
        let foodAmounts: [Decimal] = [100, 110, 90, 100, 105, 95]
        let transportAmounts: [Decimal] = [50, 60, 55, 50, 65, 55]
        var entries: [JournalEntry] = []
        for index in monthStarts.indices {
            entries.append(try fixture.expense(
                date: monthStarts[index],
                amount: foodAmounts[index],
                account: fixture.account,
                category: fixture.category,
                payee: "Food"
            ))
            entries.append(try fixture.expense(
                date: monthStarts[index],
                amount: transportAmounts[index],
                account: fixture.account,
                category: fixture.categoryTwo,
                payee: "Transport"
            ))
        }
        try await fixture.seed(
            profile: profile,
            entries: entries,
            budgetNodes: nodes,
            timeline: timeline
        )
        let model = fixture.model(
            profile: profile,
            currentDate: { asOf },
            budgetNodes: nodes,
            budgetConfigurationTimeline: timeline
        )

        let result = await model.budgetLimitSuggestionsResult()
        guard case let .available(suggestions) = result else {
            return XCTFail("Expected budget suggestions")
        }
        XCTAssertEqual(suggestions.count, 2)
        XCTAssertEqual(Set(suggestions.map(\.sampleSize)), Set([6]))
        let patch = try await model.applyBudgetSuggestions(
            suggestions,
            expectedLogicalBookRevision: model.logicalBookRevision
        )
        XCTAssertEqual(Set(patch.before.map(\.id)), Set(nodes.map(\.id)))
        XCTAssertEqual(Set(model.budgetNodes.compactMap(\.limit?.amount)), [110, 65])
        let persistedAfter = try await fixture.persistedBudgetNodes()
        XCTAssertEqual(Set(persistedAfter.compactMap(\.limit?.amount)), [110, 65])

        try await model.undoBudgetSuggestionPatch(patch)
        XCTAssertEqual(model.budgetNodes, nodes)
        let persistedRestored = try await fixture.persistedBudgetNodes()
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: persistedRestored.map { ($0.id, $0) }),
            Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        )

        try await model.setBudgetLimit(
            categoryID: fixture.categoryTwo.id,
            amount: 41
        )
        do {
            _ = try await model.applyBudgetSuggestions(
                suggestions,
                expectedLogicalBookRevision: model.logicalBookRevision
            )
            XCTFail("A stale multi-category proposal must be rejected")
        } catch {
            // Preflight rejects the complete patch before its single write.
        }
        let persistedStale = try await fixture.persistedBudgetNodes()
        XCTAssertEqual(
            persistedStale.first { $0.id == fixture.category.id }?.limit?.amount,
            80
        )
        XCTAssertEqual(
            persistedStale.first { $0.id == fixture.categoryTwo.id }?.limit?.amount,
            41
        )
        await fixture.store.close()
    }

}

private struct IntelligenceAppFixture {
    let directoryURL: URL
    let store: EncryptedRecordStore
    let currency: CurrencyCode
    let foreignCurrency: CurrencyCode
    let account: LedgerAccount
    let foreignAccount: LedgerAccount
    let category: LedgerAccount
    let categoryTwo: LedgerAccount
    let foreignCategory: LedgerAccount

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoneyUpIntelligenceAppTests-\(UUID().uuidString)")
        currency = try CurrencyCode("SGD")
        foreignCurrency = try CurrencyCode("USD")
        account = LedgerAccount(name: "Wallet", kind: .asset, currency: currency)
        foreignAccount = LedgerAccount(
            name: "Travel Wallet",
            kind: .asset,
            currency: foreignCurrency
        )
        category = LedgerAccount(name: "Food", kind: .expense)
        categoryTwo = LedgerAccount(name: "Transport", kind: .expense)
        foreignCategory = LedgerAccount(name: "Travel", kind: .expense)
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

    func expense(
        date: Date,
        amount: Decimal,
        account: LedgerAccount,
        category: LedgerAccount,
        payee: String
    ) throws -> JournalEntry {
        guard let currency = account.currency else {
            throw AppModelError.accountHasNoCurrency
        }
        return try TransactionFactory.expense(
            amount: Money(amount, currency: currency),
            paidFrom: account.id,
            category: category.id,
            occurredAt: date,
            payee: payee
        )
    }

    func date(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "GMT"))
        return try XCTUnwrap(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: 12
        )))
    }

    func monthStart(_ year: Int, _ month: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "GMT"))
        return try XCTUnwrap(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: 1
        )))
    }

    func seed(
        profile: UserProfile,
        entries: [JournalEntry],
        budgetNodes: [BudgetNode] = [],
        timeline: BudgetConfigurationTimeline? = nil
    ) async throws {
        var writes = try [
            RecordWrite(profile, id: UserProfile.primaryRecordID, in: .profile),
            RecordWrite(account, id: account.id.uuidString, in: .accounts),
            RecordWrite(
                foreignAccount,
                id: foreignAccount.id.uuidString,
                in: .accounts
            ),
            RecordWrite(category, id: category.id.uuidString, in: .accounts),
            RecordWrite(categoryTwo, id: categoryTwo.id.uuidString, in: .accounts),
            RecordWrite(
                foreignCategory,
                id: foreignCategory.id.uuidString,
                in: .accounts
            )
        ]
        writes += try entries.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .journalEntries)
        }
        writes += try budgetNodes.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .budgetNodes)
        }
        if let timeline {
            writes.append(try RecordWrite(
                timeline,
                id: BudgetConfigurationTimeline.primaryRecordID,
                in: .budgetConfigurationTimelines
            ))
        }
        try await store.write(writes)
    }

    @MainActor
    func model(
        profile: UserProfile,
        currentDate: @escaping @Sendable () -> Date = Date.init,
        budgetNodes: [BudgetNode] = [],
        scheduledTransactions: [ScheduledTransaction] = [],
        budgetConfigurationTimeline: BudgetConfigurationTimeline? = nil
    ) -> AppModel {
        AppModel(
            store: store,
            profile: profile,
            accounts: [
                account, foreignAccount, category, categoryTwo, foreignCategory
            ],
            entries: [],
            budgetNodes: budgetNodes,
            scheduledTransactions: scheduledTransactions,
            lockedCaptureStore: EmptyLockedCaptureStore(),
            databaseURLForErase: directoryURL.appendingPathComponent("moneyup.sqlite3"),
            retainsCompleteJournal: false,
            budgetConfigurationTimeline: budgetConfigurationTimeline,
            currentDate: currentDate
        )
    }

    func persistedBudgetNodes() async throws -> [BudgetNode] {
        try await store.fetchAll(BudgetNode.self, from: .budgetNodes).sorted {
            $0.id.uuidString < $1.id.uuidString
        }
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
