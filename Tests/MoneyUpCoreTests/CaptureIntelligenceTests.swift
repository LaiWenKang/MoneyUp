import Foundation
@testable import MoneyUpCore
import XCTest

final class CaptureSuggestionEngineTests: XCTestCase {
    func testSuggestsAccountAndCategoryWithInspectableHighConfidenceEvidence() throws {
        let fixture = try CaptureIntelligenceFixture()
        let entries = [
            try fixture.expense(
                amount: 6,
                account: fixture.bank,
                category: fixture.coffee,
                at: fixture.date(100),
                payee: "Café Central"
            ),
            try fixture.expense(
                amount: 7,
                account: fixture.bank,
                category: fixture.coffee,
                at: fixture.date(200),
                payee: "Cafe Central"
            ),
            try fixture.expense(
                amount: 8,
                account: fixture.bank,
                category: fixture.coffee,
                at: fixture.date(300),
                payee: "CAFE CENTRAL"
            ),
            try fixture.expense(
                amount: 40,
                account: fixture.card,
                category: fixture.groceries,
                at: fixture.date(400),
                payee: "Cafe Central"
            )
        ]
        let query = CaptureSuggestionQuery(
            kind: .expense,
            payee: "cafe central",
            currency: fixture.sgd,
            occurredAt: fixture.date(500)
        )

        let result = CaptureSuggestionEngine.suggestions(
            for: query,
            entries: entries,
            accounts: fixture.accounts
        )

        XCTAssertEqual(result.queryFingerprint, query.fingerprint)
        XCTAssertEqual(result.accountSuggestion?.ledgerAccountID, fixture.bank.id)
        XCTAssertEqual(result.accountSuggestion?.confidence, .high)
        XCTAssertEqual(result.accountSuggestion?.evidence.supportingEntryCount, 3)
        XCTAssertEqual(result.accountSuggestion?.evidence.eligibleEntryCount, 4)
        XCTAssertEqual(result.accountSuggestion?.evidence.exactPayeeEntryCount, 3)
        XCTAssertEqual(result.accountSuggestion?.evidence.mostRecentUse, fixture.date(300))
        XCTAssertEqual(result.accountSuggestion?.evidence.competingEntryCount, 1)
        XCTAssertEqual(result.categorySuggestion?.ledgerAccountID, fixture.coffee.id)
        XCTAssertEqual(result.categorySuggestion?.confidence, .high)
        XCTAssertTrue(result.categorySuggestion?.evidence.usedPayeeHistory == true)
    }

    func testOneSupportingEntryRemainsExplicitlyLowConfidence() throws {
        let fixture = try CaptureIntelligenceFixture()
        let entry = try fixture.expense(
            amount: 5,
            account: fixture.bank,
            category: fixture.coffee,
            at: fixture.date(100),
            payee: "Solo Cafe"
        )
        let result = CaptureSuggestionEngine.suggestions(
            for: CaptureSuggestionQuery(
                kind: .expense,
                payee: "Solo Cafe",
                currency: fixture.sgd,
                occurredAt: fixture.date(200)
            ),
            entries: [entry],
            accounts: fixture.accounts
        )

        XCTAssertEqual(result.accountSuggestion?.confidence, .low)
        XCTAssertEqual(result.categorySuggestion?.confidence, .low)
        XCTAssertEqual(result.categorySuggestion?.evidence.supportingEntryCount, 1)
        XCTAssertEqual(result.categorySuggestion?.evidence.eligibleEntryCount, 1)
    }

    func testStableTieUsesLowerUUIDRegardlessOfInputOrder() throws {
        let fixture = try CaptureIntelligenceFixture()
        let lowerID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        )
        let higherID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")
        )
        let lower = LedgerAccount(id: lowerID, name: "Coffee", kind: .expense)
        let higher = LedgerAccount(id: higherID, name: "Snacks", kind: .expense)
        let occurredAt = fixture.date(100)
        let entries = [
            try fixture.expense(
                amount: 5,
                account: fixture.bank,
                category: lower,
                at: occurredAt,
                payee: "Tie Cafe"
            ),
            try fixture.expense(
                amount: 6,
                account: fixture.bank,
                category: higher,
                at: occurredAt,
                payee: "Tie Cafe"
            )
        ]
        let query = CaptureSuggestionQuery(
            kind: .expense,
            payee: "Tie Cafe",
            currency: fixture.sgd,
            occurredAt: fixture.date(200)
        )

        for candidateEntries in [entries, Array(entries.reversed())] {
            for candidateAccounts in [
                fixture.accounts + [lower, higher],
                [higher, lower] + Array(fixture.accounts.reversed())
            ] {
                let result = CaptureSuggestionEngine.suggestions(
                    for: query,
                    entries: candidateEntries,
                    accounts: Array(candidateAccounts)
                )
                XCTAssertEqual(result.categorySuggestion?.ledgerAccountID, lowerID)
            }
        }
    }

    func testCJKSubstringMatchingSupportsASingleMeaningfulCharacter() throws {
        let fixture = try CaptureIntelligenceFixture()
        let tea = LedgerAccount(name: "茶饮", kind: .expense)
        let entry = try fixture.expense(
            amount: 8,
            account: fixture.bank,
            category: tea,
            at: fixture.date(100),
            payee: "老街茶馆"
        )
        let result = CaptureSuggestionEngine.suggestions(
            for: CaptureSuggestionQuery(
                kind: .expense,
                payee: "茶",
                currency: fixture.sgd,
                occurredAt: fixture.date(200)
            ),
            entries: [entry],
            accounts: fixture.accounts + [tea]
        )

        XCTAssertEqual(result.accountSuggestion?.ledgerAccountID, fixture.bank.id)
        XCTAssertEqual(result.categorySuggestion?.ledgerAccountID, tea.id)
        XCTAssertEqual(result.categorySuggestion?.evidence.exactPayeeEntryCount, 0)
    }

    func testPartialPayeeHistoryCannotReachAutoPrefillConfidence() throws {
        let fixture = try CaptureIntelligenceFixture()
        let entries = try (0..<3).map { index in
            try fixture.expense(
                amount: Decimal(index + 1),
                account: fixture.bank,
                category: fixture.coffee,
                at: fixture.date(TimeInterval(index)),
                payee: "Cafe Central Orchard"
            )
        }
        let result = CaptureSuggestionEngine.suggestions(
            for: CaptureSuggestionQuery(
                kind: .expense,
                payee: "Cafe Central",
                currency: fixture.sgd,
                occurredAt: fixture.date(100)
            ),
            entries: entries,
            accounts: fixture.accounts
        )

        XCTAssertEqual(result.accountSuggestion?.evidence.supportingEntryCount, 3)
        XCTAssertEqual(result.accountSuggestion?.evidence.exactPayeeEntryCount, 0)
        XCTAssertEqual(result.accountSuggestion?.confidence, .medium)
        XCTAssertEqual(result.categorySuggestion?.confidence, .medium)
    }

    func testLatinPayeeDoesNotMatchInsideAnotherWord() throws {
        let fixture = try CaptureIntelligenceFixture()
        let entry = try fixture.expense(
            amount: 20,
            account: fixture.bank,
            category: fixture.groceries,
            at: fixture.date(100),
            payee: "Walmart"
        )
        let result = CaptureSuggestionEngine.suggestions(
            for: CaptureSuggestionQuery(
                kind: .expense,
                payee: "Art",
                currency: fixture.sgd,
                occurredAt: fixture.date(200)
            ),
            entries: [entry],
            accounts: fixture.accounts
        )

        XCTAssertNil(result.accountSuggestion)
        XCTAssertNil(result.categorySuggestion)
    }

    func testKindCurrencyArchiveAndSystemRoleFiltersFailClosed() throws {
        let fixture = try CaptureIntelligenceFixture()
        let archived = LedgerAccount(
            name: "Old category",
            kind: .expense,
            isArchived: true
        )
        let hiddenPosition = LedgerAccount(
            name: "Hidden position",
            kind: .asset,
            currency: fixture.sgd,
            systemRole: .investmentPosition
        )
        let sgdExpense = try fixture.expense(
            amount: 10,
            account: fixture.bank,
            category: fixture.coffee,
            at: fixture.date(100),
            payee: "Mixed Merchant"
        )
        let secondSGDExpense = try fixture.expense(
            amount: 11,
            account: fixture.bank,
            category: fixture.coffee,
            at: fixture.date(110),
            payee: "Mixed Merchant"
        )
        let thirdSGDExpense = try fixture.expense(
            amount: 12,
            account: fixture.bank,
            category: fixture.coffee,
            at: fixture.date(120),
            payee: "Mixed Merchant"
        )
        let usdExpense = try fixture.expense(
            amount: 10,
            currency: fixture.usd,
            account: fixture.usBank,
            category: fixture.groceries,
            at: fixture.date(200),
            payee: "Mixed Merchant"
        )
        let income = try TransactionFactory.income(
            amount: try Money(10, currency: fixture.sgd),
            depositedInto: fixture.card.id,
            category: fixture.salary.id,
            occurredAt: fixture.date(300),
            payee: "Mixed Merchant"
        )
        let archivedEntry = try fixture.expense(
            amount: 10,
            account: fixture.card,
            category: archived,
            at: fixture.date(400),
            payee: "Mixed Merchant"
        )
        let hiddenEntry = try fixture.expense(
            amount: 10,
            account: hiddenPosition,
            category: fixture.groceries,
            at: fixture.date(500),
            payee: "Mixed Merchant"
        )

        let result = CaptureSuggestionEngine.suggestions(
            for: CaptureSuggestionQuery(
                kind: .expense,
                payee: "Mixed Merchant",
                currency: fixture.sgd,
                occurredAt: fixture.date(600)
            ),
            entries: [
                usdExpense,
                income,
                archivedEntry,
                hiddenEntry,
                thirdSGDExpense,
                sgdExpense,
                secondSGDExpense
            ],
            accounts: fixture.accounts + [archived, hiddenPosition]
        )

        XCTAssertEqual(result.accountSuggestion?.ledgerAccountID, fixture.bank.id)
        XCTAssertEqual(result.categorySuggestion?.ledgerAccountID, fixture.coffee.id)
        XCTAssertEqual(result.accountSuggestion?.evidence.supportingEntryCount, 3)
        XCTAssertEqual(result.accountSuggestion?.evidence.eligibleEntryCount, 4)
        XCTAssertEqual(result.categorySuggestion?.evidence.supportingEntryCount, 3)
        XCTAssertEqual(result.categorySuggestion?.evidence.eligibleEntryCount, 4)
    }

    func testRefundHistoryIsNotConflatedWithOrdinaryExpenseHistory() throws {
        let fixture = try CaptureIntelligenceFixture()
        let expense = try fixture.expense(
            amount: 10,
            account: fixture.bank,
            category: fixture.groceries,
            at: fixture.date(100),
            payee: "Store"
        )
        let refund = try TransactionFactory.refund(
            amount: try Money(10, currency: fixture.sgd),
            returnedTo: fixture.card.id,
            category: fixture.coffee.id,
            occurredAt: fixture.date(200),
            payee: "Store"
        )

        let result = CaptureSuggestionEngine.suggestions(
            for: CaptureSuggestionQuery(
                kind: .refund,
                payee: "Store",
                currency: fixture.sgd,
                occurredAt: fixture.date(300)
            ),
            entries: [expense, refund],
            accounts: fixture.accounts
        )

        XCTAssertEqual(result.accountSuggestion?.ledgerAccountID, fixture.card.id)
        XCTAssertEqual(result.categorySuggestion?.ledgerAccountID, fixture.coffee.id)
        XCTAssertEqual(result.categorySuggestion?.evidence.eligibleEntryCount, 1)
    }

    func testMissingPayeeUsesKindAndCurrencyHistoryAndSaysSo() throws {
        let fixture = try CaptureIntelligenceFixture()
        let entries = [
            try fixture.expense(
                amount: 5,
                account: fixture.bank,
                category: fixture.coffee,
                at: fixture.date(100),
                payee: "First"
            ),
            try fixture.expense(
                amount: 6,
                account: fixture.bank,
                category: fixture.coffee,
                at: fixture.date(200),
                payee: "Second"
            ),
            try fixture.expense(
                amount: 40,
                account: fixture.card,
                category: fixture.groceries,
                at: fixture.date(300),
                payee: "Third"
            )
        ]

        let result = CaptureSuggestionEngine.suggestions(
            for: CaptureSuggestionQuery(
                kind: .expense,
                currency: fixture.sgd,
                occurredAt: fixture.date(400)
            ),
            entries: entries,
            accounts: fixture.accounts
        )

        XCTAssertEqual(result.accountSuggestion?.ledgerAccountID, fixture.bank.id)
        XCTAssertEqual(result.categorySuggestion?.ledgerAccountID, fixture.coffee.id)
        XCTAssertTrue(result.categorySuggestion?.evidence.usedPayeeHistory == false)
        XCTAssertEqual(result.categorySuggestion?.confidence, .medium)
    }

    func testFutureHistoryAndTransferKindsDoNotProduceSuggestions() throws {
        let fixture = try CaptureIntelligenceFixture()
        let future = try fixture.expense(
            amount: 10,
            account: fixture.bank,
            category: fixture.coffee,
            at: fixture.date(500),
            payee: "Future"
        )
        let pastBoundary = fixture.date(100)

        for kind in [CaptureIntelligenceKind.transfer, .foreignCurrencyTransfer] {
            let result = CaptureSuggestionEngine.suggestions(
                for: CaptureSuggestionQuery(
                    kind: kind,
                    payee: "Future",
                    currency: fixture.sgd,
                    occurredAt: pastBoundary
                ),
                entries: [future],
                accounts: fixture.accounts
            )
            XCTAssertNil(result.accountSuggestion)
            XCTAssertNil(result.categorySuggestion)
        }
    }

    func testNonFiniteSuggestionDateFailsClosed() throws {
        let fixture = try CaptureIntelligenceFixture()
        let entry = try fixture.expense(
            amount: 10,
            account: fixture.bank,
            category: fixture.coffee,
            at: fixture.date(100),
            payee: "Invalid date"
        )
        let result = CaptureSuggestionEngine.suggestions(
            for: CaptureSuggestionQuery(
                kind: .expense,
                payee: "Invalid date",
                currency: fixture.sgd,
                occurredAt: Date(timeIntervalSinceReferenceDate: .infinity)
            ),
            entries: [entry],
            accounts: fixture.accounts
        )

        XCTAssertNil(result.accountSuggestion)
        XCTAssertNil(result.categorySuggestion)
    }

    func testRepeatedSplitLinesForSameCategoryVoteOncePerTransaction() throws {
        let fixture = try CaptureIntelligenceFixture()
        let split = try TransactionFactory.splitExpense(
            amount: try Money(10, currency: fixture.sgd),
            paidFrom: fixture.bank.id,
            splits: [
                TransactionSplitLine(
                    categoryAccountID: fixture.coffee.id,
                    amount: try Money(4, currency: fixture.sgd)
                ),
                TransactionSplitLine(
                    categoryAccountID: fixture.coffee.id,
                    amount: try Money(6, currency: fixture.sgd)
                )
            ],
            occurredAt: fixture.date(100),
            payee: "Split Cafe"
        )
        let result = CaptureSuggestionEngine.suggestions(
            for: CaptureSuggestionQuery(
                kind: .expense,
                payee: "Split Cafe",
                currency: fixture.sgd,
                occurredAt: fixture.date(200)
            ),
            entries: [split],
            accounts: fixture.accounts
        )

        XCTAssertEqual(result.categorySuggestion?.evidence.supportingEntryCount, 1)
        XCTAssertEqual(result.categorySuggestion?.evidence.eligibleEntryCount, 1)
    }

    func testAmbiguousMultiCategorySplitsNeverCreateASingleCategorySuggestion() throws {
        let fixture = try CaptureIntelligenceFixture()
        let entries = try (0..<3).map { index in
            try TransactionFactory.splitExpense(
                amount: try Money(10, currency: fixture.sgd),
                paidFrom: fixture.bank.id,
                splits: [
                    TransactionSplitLine(
                        categoryAccountID: fixture.coffee.id,
                        amount: try Money(4, currency: fixture.sgd)
                    ),
                    TransactionSplitLine(
                        categoryAccountID: fixture.groceries.id,
                        amount: try Money(6, currency: fixture.sgd)
                    )
                ],
                occurredAt: fixture.date(TimeInterval(100 + index)),
                payee: "Split Cafe"
            )
        }
        let query = CaptureSuggestionQuery(
            kind: .expense,
            payee: "Split Cafe",
            currency: fixture.sgd,
            occurredAt: fixture.date(200)
        )
        let archivedGroceries = LedgerAccount(
            id: fixture.groceries.id,
            name: fixture.groceries.name,
            kind: .expense,
            isArchived: true
        )
        let accountSnapshots = [
            fixture.accounts,
            fixture.accounts.filter { $0.id != fixture.groceries.id },
            fixture.accounts.filter { $0.id != fixture.groceries.id }
                + [archivedGroceries]
        ]

        for accounts in accountSnapshots {
            let result = CaptureSuggestionEngine.suggestions(
                for: query,
                entries: entries,
                accounts: accounts
            )
            XCTAssertEqual(result.accountSuggestion?.confidence, .high)
            XCTAssertNil(result.categorySuggestion)
        }
    }

    func testTenThousandEntrySnapshotRemainsDeterministic() throws {
        let fixture = try CaptureIntelligenceFixture()
        var entries: [JournalEntry] = []
        entries.reserveCapacity(10_000)
        for index in 0..<10_000 {
            entries.append(try fixture.expense(
                amount: Decimal(index + 1),
                account: fixture.bank,
                category: fixture.coffee,
                at: fixture.date(TimeInterval(index)),
                payee: "Bulk Merchant"
            ))
        }
        let query = CaptureSuggestionQuery(
            kind: .expense,
            payee: "Bulk Merchant",
            currency: fixture.sgd,
            occurredAt: fixture.date(10_001)
        )
        let clock = ContinuousClock()
        let started = clock.now

        let forward = CaptureSuggestionEngine.suggestions(
            for: query,
            entries: entries,
            accounts: fixture.accounts
        )
        let reverse = CaptureSuggestionEngine.suggestions(
            for: query,
            entries: Array(entries.reversed()),
            accounts: Array(fixture.accounts.reversed())
        )
        let elapsed = started.duration(to: clock.now)

        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(forward.accountSuggestion?.evidence.supportingEntryCount, 10_000)
        XCTAssertEqual(forward.categorySuggestion?.confidence, .high)
        // Production Quick Log supplies at most the 80-entry current snapshot.
        // CI only guards broad algorithmic regressions; physical-device p95 is
        // a separate release measurement.
        XCTAssertLessThan(elapsed, .seconds(2))
    }
}

final class CaptureDuplicateDetectorTests: XCTestCase {
    func testExactExpenseProducesExplainableHighConfidenceAdvisory() throws {
        let fixture = try CaptureIntelligenceFixture()
        let entry = try fixture.expense(
            amount: 12.34,
            account: fixture.bank,
            category: fixture.coffee,
            at: fixture.date(100),
            payee: "Café Néro!"
        )
        let query = try CaptureDuplicateQuery.expense(
            amount: try Money.newWrite(12.34, currency: fixture.sgd),
            paidFrom: fixture.bank.id,
            category: fixture.coffee.id,
            occurredAt: fixture.date(160),
            payee: "CAFE NERO"
        )

        let result = CaptureDuplicateDetector.matches(for: query, in: [entry])

        XCTAssertEqual(result.queryFingerprint, query.fingerprint)
        XCTAssertTrue(result.hasAdvisory)
        XCTAssertEqual(result.matches.map(\.entryID), [entry.id])
        XCTAssertEqual(result.matches.first?.confidence, .high)
        XCTAssertEqual(result.matches.first?.evidence.timeDifference, 60)
        XCTAssertTrue(result.matches.first?.evidence.movementMatched == true)
        XCTAssertTrue(result.matches.first?.evidence.categoryMatched == true)
        XCTAssertTrue(result.matches.first?.evidence.descriptorMatched == true)
        XCTAssertTrue(result.matches.first?.evidence.sourceMatched == false)
    }

    func testDuplicateTimeThresholdsAreInclusiveAndDeterministic() throws {
        let fixture = try CaptureIntelligenceFixture()
        let entry = try fixture.expense(
            amount: 10,
            account: fixture.bank,
            category: fixture.coffee,
            at: fixture.date(100),
            payee: "Boundary"
        )

        func query(after interval: TimeInterval) throws -> CaptureDuplicateQuery {
            try .expense(
                amount: Money.newWrite(10, currency: fixture.sgd),
                paidFrom: fixture.bank.id,
                category: fixture.coffee.id,
                occurredAt: fixture.date(100 + interval),
                payee: "Boundary"
            )
        }

        XCTAssertEqual(
            CaptureDuplicateDetector.matches(
                for: try query(after: 600),
                in: [entry]
            ).matches.first?.confidence,
            .high
        )
        XCTAssertEqual(
            CaptureDuplicateDetector.matches(
                for: try query(after: 601),
                in: [entry]
            ).matches.first?.confidence,
            .medium
        )
        XCTAssertEqual(
            CaptureDuplicateDetector.matches(
                for: try query(after: 86_400),
                in: [entry]
            ).matches.first?.confidence,
            .medium
        )
        XCTAssertFalse(
            CaptureDuplicateDetector.matches(
                for: try query(after: 86_401),
                in: [entry]
            ).hasAdvisory
        )
    }

    func testMissingDescriptorIsLowConfidenceAndSplitCategoryCanBeOmitted() throws {
        let fixture = try CaptureIntelligenceFixture()
        let entry = try fixture.expense(
            amount: 10,
            account: fixture.bank,
            category: fixture.coffee,
            at: fixture.date(100),
            payee: nil
        )
        let withCategory = try CaptureDuplicateQuery.expense(
            amount: try Money.newWrite(10, currency: fixture.sgd),
            paidFrom: fixture.bank.id,
            category: fixture.coffee.id,
            occurredAt: fixture.date(101)
        )
        let split = try TransactionFactory.splitExpense(
            amount: try Money.newWrite(10, currency: fixture.sgd),
            paidFrom: fixture.bank.id,
            splits: [
                TransactionSplitLine(
                    categoryAccountID: fixture.coffee.id,
                    amount: try Money.newWrite(4, currency: fixture.sgd)
                ),
                TransactionSplitLine(
                    categoryAccountID: fixture.groceries.id,
                    amount: try Money.newWrite(6, currency: fixture.sgd)
                )
            ],
            occurredAt: fixture.date(100),
            payee: "Split Cafe"
        )
        let splitWithoutCategory = try CaptureDuplicateQuery.expense(
            amount: try Money.newWrite(10, currency: fixture.sgd),
            paidFrom: fixture.bank.id,
            occurredAt: fixture.date(101),
            payee: "split cafe"
        )
        let splitWithoutCategoryOrPayee = try CaptureDuplicateQuery.expense(
            amount: try Money.newWrite(10, currency: fixture.sgd),
            paidFrom: fixture.bank.id,
            occurredAt: fixture.date(101)
        )

        XCTAssertEqual(
            CaptureDuplicateDetector.matches(for: withCategory, in: [entry])
                .matches.first?.confidence,
            .low
        )
        let splitResult = CaptureDuplicateDetector.matches(
            for: splitWithoutCategory,
            in: [split]
        )
        XCTAssertEqual(splitResult.matches.first?.confidence, .medium)
        XCTAssertTrue(splitResult.matches.first?.evidence.movementMatched == true)
        XCTAssertTrue(splitResult.matches.first?.evidence.categoryMatched == false)
        XCTAssertTrue(splitResult.matches.first?.evidence.descriptorMatched == true)
        XCTAssertEqual(
            CaptureDuplicateDetector.matches(
                for: splitWithoutCategoryOrPayee,
                in: [split]
            ).matches.first?.confidence,
            .low
        )
    }

    func testExpenseIncomeAndRefundDirectionsNeverCrossMatch() throws {
        let fixture = try CaptureIntelligenceFixture()
        let amount = try Money.newWrite(20, currency: fixture.sgd)
        let expense = try fixture.expense(
            amount: 20,
            account: fixture.bank,
            category: fixture.coffee,
            at: fixture.date(100),
            payee: "Direction"
        )
        let income = try TransactionFactory.income(
            amount: amount,
            depositedInto: fixture.bank.id,
            category: fixture.salary.id,
            occurredAt: fixture.date(100),
            payee: "Direction"
        )
        let refund = try TransactionFactory.refund(
            amount: amount,
            returnedTo: fixture.bank.id,
            category: fixture.coffee.id,
            occurredAt: fixture.date(100),
            payee: "Direction"
        )

        let queries = [
            try CaptureDuplicateQuery.expense(
                amount: amount,
                paidFrom: fixture.bank.id,
                category: fixture.coffee.id,
                occurredAt: fixture.date(101),
                payee: "Direction"
            ),
            try CaptureDuplicateQuery.income(
                amount: amount,
                depositedInto: fixture.bank.id,
                category: fixture.salary.id,
                occurredAt: fixture.date(101),
                payee: "Direction"
            ),
            try CaptureDuplicateQuery.refund(
                amount: amount,
                returnedTo: fixture.bank.id,
                category: fixture.coffee.id,
                occurredAt: fixture.date(101),
                payee: "Direction"
            )
        ]
        let entries = [expense, income, refund]

        XCTAssertEqual(
            CaptureDuplicateDetector.matches(for: queries[0], in: entries).matches.map(\.entryID),
            [expense.id]
        )
        XCTAssertEqual(
            CaptureDuplicateDetector.matches(for: queries[1], in: entries).matches.map(\.entryID),
            [income.id]
        )
        XCTAssertEqual(
            CaptureDuplicateDetector.matches(for: queries[2], in: entries).matches.map(\.entryID),
            [refund.id]
        )
    }

    func testDifferentCurrencyAmountOrAccountNeverMatches() throws {
        let fixture = try CaptureIntelligenceFixture()
        let entry = try fixture.expense(
            amount: 10,
            account: fixture.bank,
            category: fixture.coffee,
            at: fixture.date(100),
            payee: "Exactness"
        )
        let queries = [
            try CaptureDuplicateQuery.expense(
                amount: try Money.newWrite(10, currency: fixture.usd),
                paidFrom: fixture.bank.id,
                category: fixture.coffee.id,
                occurredAt: fixture.date(101),
                payee: "Exactness"
            ),
            try CaptureDuplicateQuery.expense(
                amount: try Money.newWrite(10.01, currency: fixture.sgd),
                paidFrom: fixture.bank.id,
                category: fixture.coffee.id,
                occurredAt: fixture.date(101),
                payee: "Exactness"
            ),
            try CaptureDuplicateQuery.expense(
                amount: try Money.newWrite(10, currency: fixture.sgd),
                paidFrom: fixture.card.id,
                category: fixture.coffee.id,
                occurredAt: fixture.date(101),
                payee: "Exactness"
            )
        ]

        for query in queries {
            XCTAssertFalse(
                CaptureDuplicateDetector.matches(for: query, in: [entry]).hasAdvisory
            )
        }
    }

    func testSameCurrencyTransferRequiresBothDirectedLegs() throws {
        let fixture = try CaptureIntelligenceFixture()
        let amount = try Money.newWrite(50, currency: fixture.sgd)
        let forward = try TransactionFactory.transfer(
            amount: amount,
            from: fixture.bank.id,
            to: fixture.card.id,
            occurredAt: fixture.date(100),
            note: "Card payment"
        )
        let reverse = try TransactionFactory.transfer(
            amount: amount,
            from: fixture.card.id,
            to: fixture.bank.id,
            occurredAt: fixture.date(100),
            note: "Card payment"
        )
        let query = try CaptureDuplicateQuery.transfer(
            amount: amount,
            from: fixture.bank.id,
            to: fixture.card.id,
            occurredAt: fixture.date(101),
            note: "card payment"
        )

        let result = CaptureDuplicateDetector.matches(
            for: query,
            in: [reverse, forward]
        )

        XCTAssertEqual(result.matches.map(\.entryID), [forward.id])
        XCTAssertEqual(result.matches.first?.confidence, .high)
    }

    func testForeignTransferRequiresAllFourExactCurrencyLegs() throws {
        let fixture = try CaptureIntelligenceFixture()
        let source = try Money.newWrite(135, currency: fixture.sgd)
        let destination = try Money.newWrite(100, currency: fixture.usd)
        let exact = try TransactionFactory.foreignCurrencyTransfer(
            sourceAmount: source,
            destinationAmount: destination,
            from: fixture.bank.id,
            to: fixture.usBank.id,
            sourceTradingAccountID: fixture.sgdTrading.id,
            destinationTradingAccountID: fixture.usdTrading.id,
            occurredAt: fixture.date(100),
            note: "FX"
        )
        let differentDestination = try TransactionFactory.foreignCurrencyTransfer(
            sourceAmount: source,
            destinationAmount: try Money.newWrite(99.99, currency: fixture.usd),
            from: fixture.bank.id,
            to: fixture.usBank.id,
            sourceTradingAccountID: fixture.sgdTrading.id,
            destinationTradingAccountID: fixture.usdTrading.id,
            occurredAt: fixture.date(100),
            note: "FX"
        )
        let wrongTradingLeg = try TransactionFactory.foreignCurrencyTransfer(
            sourceAmount: source,
            destinationAmount: destination,
            from: fixture.bank.id,
            to: fixture.usBank.id,
            sourceTradingAccountID: UUID(),
            destinationTradingAccountID: fixture.usdTrading.id,
            occurredAt: fixture.date(100),
            note: "FX"
        )
        let query = try CaptureDuplicateQuery.foreignCurrencyTransfer(
            sourceAmount: source,
            destinationAmount: destination,
            from: fixture.bank.id,
            to: fixture.usBank.id,
            sourceTradingAccountID: fixture.sgdTrading.id,
            destinationTradingAccountID: fixture.usdTrading.id,
            occurredAt: fixture.date(101),
            note: "fx"
        )

        let result = CaptureDuplicateDetector.matches(
            for: query,
            in: [wrongTradingLeg, differentDestination, exact]
        )

        XCTAssertEqual(result.matches.map(\.entryID), [exact.id])
        XCTAssertEqual(result.matches.first?.confidence, .high)
    }

    func testSourceFingerprintCanIdentifyReplayOutsideTimeWindow() throws {
        let fixture = try CaptureIntelligenceFixture()
        let base = try fixture.expense(
            amount: 10,
            account: fixture.bank,
            category: fixture.coffee,
            at: fixture.date(100),
            payee: "Old receipt"
        )
        let entry = try fixture.copy(
            base,
            id: fixture.fixedUUID(100),
            sourceSystem: "MoneyUp Receipt",
            sourceFingerprint: "receipt-123"
        )
        let query = try CaptureDuplicateQuery.expense(
            amount: try Money.newWrite(10, currency: fixture.sgd),
            paidFrom: fixture.bank.id,
            category: fixture.coffee.id,
            occurredAt: fixture.date(1_000_000),
            payee: "Different",
            sourceReference: CaptureSourceReference(
                system: "moneyup receipt",
                fingerprint: "receipt-123"
            )
        )

        let result = CaptureDuplicateDetector.matches(
            for: query,
            in: [entry],
            maximumTimeInterval: 10
        )

        XCTAssertEqual(result.matches.map(\.entryID), [entry.id])
        XCTAssertEqual(result.matches.first?.confidence, .high)
        XCTAssertTrue(result.matches.first?.evidence.sourceMatched == true)
    }

    func testExcludingEditedEntryRemovesSelfAdvisory() throws {
        let fixture = try CaptureIntelligenceFixture()
        let entry = try fixture.expense(
            amount: 10,
            account: fixture.bank,
            category: fixture.coffee,
            at: fixture.date(100),
            payee: "Edit"
        )
        let query = try CaptureDuplicateQuery.expense(
            amount: try Money.newWrite(10, currency: fixture.sgd),
            paidFrom: fixture.bank.id,
            category: fixture.coffee.id,
            occurredAt: fixture.date(100),
            payee: "Edit"
        )

        XCTAssertFalse(CaptureDuplicateDetector.matches(
            for: query,
            in: [entry],
            excludingEntryID: entry.id
        ).hasAdvisory)
    }

    func testMatchOrderingIsStableByConfidenceTimeThenUUID() throws {
        let fixture = try CaptureIntelligenceFixture()
        let base = try fixture.expense(
            amount: 10,
            account: fixture.bank,
            category: fixture.coffee,
            at: fixture.date(100),
            payee: "Stable"
        )
        let lower = try fixture.copy(base, id: fixture.fixedUUID(1))
        let higher = try fixture.copy(base, id: fixture.fixedUUID(2))
        let query = try CaptureDuplicateQuery.expense(
            amount: try Money.newWrite(10, currency: fixture.sgd),
            paidFrom: fixture.bank.id,
            category: fixture.coffee.id,
            occurredAt: fixture.date(101),
            payee: "Stable"
        )

        let expected = [lower.id, higher.id]
        XCTAssertEqual(
            CaptureDuplicateDetector.matches(for: query, in: [higher, lower])
                .matches.map(\.entryID),
            expected
        )
        XCTAssertEqual(
            CaptureDuplicateDetector.matches(for: query, in: [lower, higher])
                .matches.map(\.entryID),
            expected
        )
    }

    func testKWDAndBTCUseExactDecimalAndCurrencyWithoutConversion() throws {
        let fixture = try CaptureIntelligenceFixture()
        let kwd = try CurrencyCode("KWD")
        let btc = try CurrencyCode("BTC")
        let kwdAccount = LedgerAccount(
            name: "KWD Cash",
            kind: .asset,
            currency: kwd,
            accountType: .cash
        )
        let btcAccount = LedgerAccount(
            name: "BTC Wallet",
            kind: .asset,
            currency: btc,
            accountType: .other
        )
        let kwdEntry = try TransactionFactory.expense(
            amount: try Money.newWrite(
                try XCTUnwrap(Decimal(string: "12.345")),
                currency: kwd
            ),
            paidFrom: kwdAccount.id,
            category: fixture.coffee.id,
            occurredAt: fixture.date(100),
            payee: "Precision"
        )
        let btcEntry = try TransactionFactory.expense(
            amount: try Money.newWrite(
                try XCTUnwrap(Decimal(string: "0.00000001")),
                currency: btc
            ),
            paidFrom: btcAccount.id,
            category: fixture.coffee.id,
            occurredAt: fixture.date(100),
            payee: "Precision"
        )
        let kwdQuery = try CaptureDuplicateQuery.expense(
            amount: try Money.newWrite(
                try XCTUnwrap(Decimal(string: "12.345")),
                currency: kwd
            ),
            paidFrom: kwdAccount.id,
            category: fixture.coffee.id,
            occurredAt: fixture.date(101),
            payee: "Precision"
        )
        let btcQuery = try CaptureDuplicateQuery.expense(
            amount: try Money.newWrite(
                try XCTUnwrap(Decimal(string: "0.00000001")),
                currency: btc
            ),
            paidFrom: btcAccount.id,
            category: fixture.coffee.id,
            occurredAt: fixture.date(101),
            payee: "Precision"
        )

        XCTAssertEqual(
            CaptureDuplicateDetector.matches(
                for: kwdQuery,
                in: [btcEntry, kwdEntry]
            ).matches.map(\.entryID),
            [kwdEntry.id]
        )
        XCTAssertEqual(
            CaptureDuplicateDetector.matches(
                for: btcQuery,
                in: [kwdEntry, btcEntry]
            ).matches.map(\.entryID),
            [btcEntry.id]
        )
    }

    func testJPYUsesZeroMinorUnitsForDuplicateQueries() throws {
        let fixture = try CaptureIntelligenceFixture()
        let jpy = try CurrencyCode("JPY")
        let jpyAccount = LedgerAccount(
            name: "JPY Cash",
            kind: .asset,
            currency: jpy,
            accountType: .cash
        )
        let entry = try TransactionFactory.expense(
            amount: Money.newWrite(1_000, currency: jpy),
            paidFrom: jpyAccount.id,
            category: fixture.coffee.id,
            occurredAt: fixture.date(100),
            payee: "JPY"
        )
        let query = try CaptureDuplicateQuery.expense(
            amount: Money.newWrite(1_000, currency: jpy),
            paidFrom: jpyAccount.id,
            category: fixture.coffee.id,
            occurredAt: fixture.date(101),
            payee: "JPY"
        )

        XCTAssertEqual(
            CaptureDuplicateDetector.matches(for: query, in: [entry])
                .matches.map(\.entryID),
            [entry.id]
        )
        XCTAssertThrowsError(try CaptureDuplicateQuery.expense(
            amount: Money(1_000.5, currency: jpy),
            paidFrom: jpyAccount.id,
            occurredAt: fixture.date(101)
        )) { error in
            XCTAssertEqual(
                error as? MoneyError,
                .unsupportedPrecision(currency: jpy)
            )
        }
    }

    func testDuplicateQueryFactoriesEnforceNewWriteAndTransferInvariants() throws {
        let fixture = try CaptureIntelligenceFixture()
        let excessivePrecision = try Money(
            try XCTUnwrap(Decimal(string: "1.001")),
            currency: fixture.sgd
        )

        XCTAssertThrowsError(try CaptureDuplicateQuery.expense(
            amount: excessivePrecision,
            paidFrom: fixture.bank.id,
            occurredAt: fixture.date(100)
        )) { error in
            XCTAssertEqual(
                error as? MoneyError,
                .unsupportedPrecision(currency: fixture.sgd)
            )
        }
        XCTAssertThrowsError(try CaptureDuplicateQuery.expense(
            amount: try Money(-1, currency: fixture.sgd),
            paidFrom: fixture.bank.id,
            occurredAt: fixture.date(100)
        )) { error in
            XCTAssertEqual(
                error as? TransactionFactoryError,
                .amountMustBePositive
            )
        }
        XCTAssertThrowsError(try CaptureDuplicateQuery.transfer(
            amount: try Money.newWrite(1, currency: fixture.sgd),
            from: fixture.bank.id,
            to: fixture.bank.id
        )) { error in
            XCTAssertEqual(
                error as? CaptureDuplicateQueryError,
                .accountsMustDiffer
            )
        }
        XCTAssertThrowsError(try CaptureDuplicateQuery.foreignCurrencyTransfer(
            sourceAmount: try Money.newWrite(1, currency: fixture.sgd),
            destinationAmount: try Money.newWrite(1, currency: fixture.sgd),
            from: fixture.bank.id,
            to: fixture.card.id,
            sourceTradingAccountID: fixture.sgdTrading.id,
            destinationTradingAccountID: fixture.usdTrading.id
        )) { error in
            XCTAssertEqual(
                error as? CaptureDuplicateQueryError,
                .foreignTransferCurrenciesMustDiffer
            )
        }
        XCTAssertThrowsError(try CaptureDuplicateQuery.expense(
            amount: try Money.newWrite(1, currency: fixture.sgd),
            paidFrom: fixture.bank.id,
            occurredAt: Date(timeIntervalSinceReferenceDate: .infinity)
        )) { error in
            XCTAssertEqual(
                error as? CaptureDuplicateQueryError,
                .invalidEventDate
            )
        }
    }

    func testFingerprintCanonicalizesTextAndChangesWithFinancialFields() throws {
        let fixture = try CaptureIntelligenceFixture()
        let occurredAt = fixture.date(100)
        let first = try CaptureDuplicateQuery.expense(
            amount: try Money.newWrite(10, currency: fixture.sgd),
            paidFrom: fixture.bank.id,
            category: fixture.coffee.id,
            occurredAt: occurredAt,
            payee: "  Café--Néro  "
        )
        let equivalent = try CaptureDuplicateQuery.expense(
            amount: try Money.newWrite(10, currency: fixture.sgd),
            paidFrom: fixture.bank.id,
            category: fixture.coffee.id,
            occurredAt: occurredAt,
            payee: "CAFE NERO"
        )
        let changedAmount = try CaptureDuplicateQuery.expense(
            amount: try Money.newWrite(10.01, currency: fixture.sgd),
            paidFrom: fixture.bank.id,
            category: fixture.coffee.id,
            occurredAt: occurredAt,
            payee: "CAFE NERO"
        )

        XCTAssertEqual(first.fingerprint, equivalent.fingerprint)
        XCTAssertNotEqual(first.fingerprint, changedAmount.fingerprint)
    }

    func testTenThousandEntryDuplicateScanFindsOnlyExactMovement() throws {
        let fixture = try CaptureIntelligenceFixture()
        var entries: [JournalEntry] = []
        entries.reserveCapacity(10_000)
        for index in 0..<10_000 {
            entries.append(try fixture.expense(
                amount: Decimal(index + 1),
                account: fixture.bank,
                category: fixture.coffee,
                at: fixture.date(TimeInterval(index)),
                payee: "Bulk"
            ))
        }
        let query = try CaptureDuplicateQuery.expense(
            amount: try Money.newWrite(10_000, currency: fixture.sgd),
            paidFrom: fixture.bank.id,
            category: fixture.coffee.id,
            occurredAt: fixture.date(10_000),
            payee: "Bulk"
        )
        let clock = ContinuousClock()
        let started = clock.now

        let result = CaptureDuplicateDetector.matches(for: query, in: entries)
        let elapsed = started.duration(to: clock.now)

        XCTAssertEqual(result.matches.count, 1)
        XCTAssertEqual(result.matches.first?.entryID, entries.last?.id)
        // Production Quick Log supplies at most the 80-entry current snapshot.
        // CI only guards broad algorithmic regressions; physical-device p95 is
        // a separate release measurement.
        XCTAssertLessThan(elapsed, .seconds(2))
    }
}

private struct CaptureIntelligenceFixture {
    let sgd: CurrencyCode
    let usd: CurrencyCode
    let bank: LedgerAccount
    let card: LedgerAccount
    let usBank: LedgerAccount
    let coffee: LedgerAccount
    let groceries: LedgerAccount
    let salary: LedgerAccount
    let sgdTrading: LedgerAccount
    let usdTrading: LedgerAccount

    init() throws {
        let sgd = try CurrencyCode("SGD")
        let usd = try CurrencyCode("USD")
        self.sgd = sgd
        self.usd = usd
        bank = LedgerAccount(
            id: try Self.uuid(10),
            name: "Bank",
            kind: .asset,
            currency: sgd,
            accountType: .bank
        )
        card = LedgerAccount(
            id: try Self.uuid(11),
            name: "Card",
            kind: .liability,
            currency: sgd,
            accountType: .creditCard
        )
        usBank = LedgerAccount(
            id: try Self.uuid(12),
            name: "US Bank",
            kind: .asset,
            currency: usd,
            accountType: .bank
        )
        coffee = LedgerAccount(id: try Self.uuid(20), name: "Coffee", kind: .expense)
        groceries = LedgerAccount(
            id: try Self.uuid(21),
            name: "Groceries",
            kind: .expense
        )
        salary = LedgerAccount(id: try Self.uuid(22), name: "Salary", kind: .income)
        sgdTrading = LedgerAccount(
            id: try Self.uuid(30),
            name: "SGD FX",
            kind: .trading,
            currency: sgd,
            systemRole: .foreignExchange
        )
        usdTrading = LedgerAccount(
            id: try Self.uuid(31),
            name: "USD FX",
            kind: .trading,
            currency: usd,
            systemRole: .foreignExchange
        )
    }

    var accounts: [LedgerAccount] {
        [bank, card, usBank, coffee, groceries, salary, sgdTrading, usdTrading]
    }

    func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: 1_000_000 + offset)
    }

    func fixedUUID(_ value: Int) -> UUID {
        try! Self.uuid(value)
    }

    func expense(
        amount: Decimal,
        currency: CurrencyCode? = nil,
        account: LedgerAccount,
        category: LedgerAccount,
        at occurredAt: Date,
        payee: String?
    ) throws -> JournalEntry {
        try TransactionFactory.expense(
            amount: try Money.newWrite(amount, currency: currency ?? sgd),
            paidFrom: account.id,
            category: category.id,
            occurredAt: occurredAt,
            payee: payee
        )
    }

    func copy(
        _ entry: JournalEntry,
        id: UUID,
        sourceSystem: String? = nil,
        sourceFingerprint: String? = nil
    ) throws -> JournalEntry {
        try JournalEntry(
            id: id,
            kind: entry.kind,
            occurredAt: entry.occurredAt,
            createdAt: entry.createdAt,
            payee: entry.payee,
            note: entry.note,
            postings: entry.postings,
            supersedesID: entry.supersedesID,
            revisedAt: entry.revisedAt,
            sourceSystem: sourceSystem,
            sourceFingerprint: sourceFingerprint,
            originContext: entry.originContext
        )
    }

    private static func uuid(_ value: Int) throws -> UUID {
        guard let uuid = UUID(
            uuidString: String(format: "00000000-0000-0000-0000-%012d", value)
        ) else {
            throw FixtureError.invalidUUID
        }
        return uuid
    }

    private enum FixtureError: Error {
        case invalidUUID
    }
}
