@testable import MoneyUp
import Foundation
import MoneyUpCore
import XCTest

final class RestrictedAllowanceLedgerInvariantTests: XCTestCase {
    func testPointInTimeBalanceNeverUsesFutureFunding() throws {
        let currency = try CurrencyCode("SGD")
        let accountID = UUID()
        let spendAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let events = [try event(
            accountID: accountID,
            amount: 10,
            currency: currency,
            occurredAt: spendAt.addingTimeInterval(3_600)
        )]

        XCTAssertEqual(
            try RestrictedAllowanceLedgerInvariant.balance(
                for: accountID,
                currency: currency,
                through: spendAt,
                events: events
            ),
            .zero
        )
    }

    func testEqualTimestampMovementsAreOneDeterministicBatch() throws {
        let currency = try CurrencyCode("SGD")
        let accountID = UUID()
        let occurredAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let funding = try event(
            accountID: accountID,
            amount: 10,
            currency: currency,
            occurredAt: occurredAt
        )
        let spending = try event(
            accountID: accountID,
            amount: -10,
            currency: currency,
            occurredAt: occurredAt
        )

        for events in [[funding, spending], [spending, funding]] {
            XCTAssertNoThrow(try RestrictedAllowanceLedgerInvariant.requireValid(
                expectedCurrencies: [accountID: currency],
                events: events
            ))
            XCTAssertEqual(
                try RestrictedAllowanceLedgerInvariant.balance(
                    for: accountID,
                    currency: currency,
                    through: occurredAt,
                    events: events
                ),
                .zero
            )
        }
    }

    func testLaterFundingCannotMaskAnEarlierNegativeBalance() throws {
        let currency = try CurrencyCode("SGD")
        let accountID = UUID()
        let first = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let events = [
            try event(
                accountID: accountID,
                amount: -5,
                currency: currency,
                occurredAt: first
            ),
            try event(
                accountID: accountID,
                amount: 10,
                currency: currency,
                occurredAt: first.addingTimeInterval(3_600)
            )
        ]

        XCTAssertThrowsError(try RestrictedAllowanceLedgerInvariant.requireValid(
            expectedCurrencies: [accountID: currency],
            events: events
        ))
        XCTAssertEqual(
            try RestrictedAllowanceLedgerInvariant.invalidAccountIDs(
                expectedCurrencies: [accountID: currency],
                events: events
            ),
            [accountID]
        )
    }

    func testFutureIncomingFundingIsAValidNonnegativeHistory() throws {
        let currency = try CurrencyCode("SGD")
        let accountID = UUID()
        let future = Date(timeIntervalSinceReferenceDate: 810_000_000)
        let events = [try event(
            accountID: accountID,
            amount: 25,
            currency: currency,
            occurredAt: future
        )]

        XCTAssertNoThrow(try RestrictedAllowanceLedgerInvariant.requireValid(
            expectedCurrencies: [accountID: currency],
            events: events
        ))
        XCTAssertEqual(
            try RestrictedAllowanceLedgerInvariant.balance(
                for: accountID,
                currency: currency,
                through: future,
                events: events
            ),
            25
        )
    }

    private func event(
        accountID: UUID,
        amount: Decimal,
        currency: CurrencyCode,
        occurredAt: Date
    ) throws -> LedgerPostingEvent {
        LedgerPostingEvent(
            entryID: UUID(),
            occurredAt: occurredAt,
            originDayKey: 20260904,
            posting: Posting(
                accountID: accountID,
                money: try Money(amount, currency: currency)
            )
        )
    }
}
