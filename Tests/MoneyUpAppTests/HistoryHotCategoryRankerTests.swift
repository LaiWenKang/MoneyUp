@testable import MoneyUp
import Foundation
import MoneyUpCore
import XCTest

final class HistoryHotCategoryRankerTests: XCTestCase {
    func testFrequencyLeadsAndRecencyBreaksTies() throws {
        let currency = try CurrencyCode("SGD")
        let cash = LedgerAccount(
            name: "Cash",
            kind: .asset,
            currency: currency,
            accountType: .cash
        )
        let food = LedgerAccount(name: "Food", kind: .expense)
        let transit = LedgerAccount(name: "Transit", kind: .expense)
        let archived = LedgerAccount(
            name: "Archived",
            kind: .expense,
            isArchived: true
        )
        let dates = try [
            "2026-08-01T12:00:00Z",
            "2026-08-02T12:00:00Z",
            "2026-08-03T12:00:00Z",
        ].map { rawDate in
            try XCTUnwrap(ISO8601DateFormatter().date(from: rawDate))
        }

        let entries = try [
            entry(
                categoryAmounts: [(food.id, 2), (food.id, 3)],
                cashID: cash.id,
                currency: currency,
                occurredAt: dates[0]
            ),
            entry(
                categoryAmounts: [(food.id, 5)],
                cashID: cash.id,
                currency: currency,
                occurredAt: dates[1]
            ),
            entry(
                categoryAmounts: [(transit.id, 5)],
                cashID: cash.id,
                currency: currency,
                occurredAt: dates[0]
            ),
            entry(
                categoryAmounts: [(transit.id, 5)],
                cashID: cash.id,
                currency: currency,
                occurredAt: dates[2]
            ),
            entry(
                categoryAmounts: [(archived.id, 5)],
                cashID: cash.id,
                currency: currency,
                occurredAt: dates[2]
            ),
        ]

        let ranked = HistoryHotCategoryRanker.ranked(
            entries: entries,
            accounts: [cash, food, transit, archived]
        )

        XCTAssertEqual(ranked.map(\.id), [transit.id, food.id])
        XCTAssertEqual(ranked.map(\.occurrenceCount), [2, 2])
        XCTAssertEqual(
            HistoryHotCategoryRanker.ranked(
                entries: entries,
                accounts: [cash, food, transit, archived],
                limit: 1
            ).map(\.id),
            [transit.id]
        )
    }

    private func entry(
        categoryAmounts: [(UUID, Decimal)],
        cashID: UUID,
        currency: CurrencyCode,
        occurredAt: Date
    ) throws -> JournalEntry {
        let total = categoryAmounts.reduce(Decimal.zero) { partial, item in
            partial + item.1
        }
        let categoryPostings = try categoryAmounts.map { item in
            Posting(
                accountID: item.0,
                money: try Money(item.1, currency: currency)
            )
        }
        return try JournalEntry(
            kind: .expense,
            occurredAt: occurredAt,
            postings: categoryPostings + [
                Posting(
                    accountID: cashID,
                    money: try Money(-total, currency: currency)
                )
            ]
        )
    }
}
