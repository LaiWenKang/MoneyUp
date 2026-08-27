import Foundation
@testable import MoneyUpCore
import XCTest

final class JournalEntryTests: XCTestCase {
    func testLegacyEntryDecodesWithoutRevisionOrImportMetadata() throws {
        let accountID = UUID()
        let categoryID = UUID()
        let id = UUID()
        let json = """
        {
          "id":"\(id.uuidString)",
          "kind":"expense",
          "occurredAt":0,
          "createdAt":0,
          "postings":[
            {"id":"\(UUID().uuidString)","accountID":"\(accountID.uuidString)","money":{"amount":-1,"currency":"USD"}},
            {"id":"\(UUID().uuidString)","accountID":"\(categoryID.uuidString)","money":{"amount":1,"currency":"USD"}}
          ]
        }
        """

        let entry = try JSONDecoder().decode(JournalEntry.self, from: Data(json.utf8))

        XCTAssertEqual(entry.id, id)
        XCTAssertNil(entry.revisedAt)
        XCTAssertNil(entry.sourceSystem)
        XCTAssertNil(entry.sourceFingerprint)
    }

    func testBalancedExpenseIsAccepted() throws {
        let sgd = try CurrencyCode("SGD")
        let expenseAccountID = UUID()
        let bankAccountID = UUID()

        let entry = try JournalEntry(
            kind: .expense,
            postings: [
                Posting(
                    accountID: expenseAccountID,
                    money: try Money(5, currency: sgd)
                ),
                Posting(
                    accountID: bankAccountID,
                    money: try Money(-5, currency: sgd)
                )
            ]
        )

        XCTAssertEqual(entry.balanceByCurrency[sgd], .zero)
    }

    func testUnbalancedEntryIsRejected() throws {
        let sgd = try CurrencyCode("SGD")

        XCTAssertThrowsError(
            try JournalEntry(
                kind: .expense,
                postings: [
                    Posting(
                        accountID: UUID(),
                        money: try Money(5, currency: sgd)
                    ),
                    Posting(
                        accountID: UUID(),
                        money: try Money(-4, currency: sgd)
                    )
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? JournalEntryValidationError,
                .unbalanced(currency: sgd, residual: 1)
            )
        }
    }

    func testEveryCurrencyBalancesIndependently() throws {
        let sgd = try CurrencyCode("SGD")
        let usd = try CurrencyCode("USD")
        let sgdTradingAccount = UUID()
        let usdTradingAccount = UUID()

        let entry = try JournalEntry(
            kind: .transfer,
            postings: [
                Posting(
                    accountID: UUID(),
                    money: try Money(-100, currency: sgd)
                ),
                Posting(
                    accountID: sgdTradingAccount,
                    money: try Money(100, currency: sgd)
                ),
                Posting(
                    accountID: usdTradingAccount,
                    money: try Money(-75, currency: usd)
                ),
                Posting(
                    accountID: UUID(),
                    money: try Money(75, currency: usd)
                )
            ]
        )

        XCTAssertEqual(entry.balanceByCurrency[sgd], .zero)
        XCTAssertEqual(entry.balanceByCurrency[usd], .zero)
    }

    func testZeroPostingIsRejected() throws {
        let sgd = try CurrencyCode("SGD")
        let zeroPosting = Posting(
            accountID: UUID(),
            money: Money.zero(currency: sgd)
        )

        XCTAssertThrowsError(
            try JournalEntry(
                kind: .adjustment,
                postings: [
                    zeroPosting,
                    Posting(
                        accountID: UUID(),
                        money: try Money(1, currency: sgd)
                    )
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? JournalEntryValidationError,
                .zeroPosting(zeroPosting.id)
            )
        }
    }

    func testCheckedBalanceAggregationRejectsIntermediateDecimalOverflow() throws {
        let sgd = try CurrencyCode("SGD")
        let huge = try XCTUnwrap(
            Decimal(string: "9e127", locale: Locale(identifier: "en_US_POSIX"))
        )

        XCTAssertThrowsError(try JournalEntry(
            kind: .adjustment,
            postings: [
                Posting(accountID: UUID(), money: try Money(huge, currency: sgd)),
                Posting(accountID: UUID(), money: try Money(huge, currency: sgd)),
                Posting(accountID: UUID(), money: try Money(-huge, currency: sgd)),
                Posting(accountID: UUID(), money: try Money(-huge, currency: sgd))
            ]
        )) { error in
            XCTAssertEqual(
                error as? JournalEntryValidationError,
                .arithmeticOverflow(currency: sgd)
            )
        }
    }

    func testEventOriginUsesFrozenOffsetAndStillRequiresCapturedDay() throws {
        let usd = try CurrencyCode("USD")
        let occurredAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-01T16:00:00Z")
        )
        // This offset differs from the current tzdb rule for New York on this
        // date, but remains valid frozen evidence if zone rules later change.
        let historical = try TransactionOriginContext(
            calendarIdentifier: "gregorian",
            timeZoneIdentifier: "America/New_York",
            utcOffsetSeconds: -5 * 3_600,
            dayKey: 20260701
        )

        XCTAssertNoThrow(try JournalEntry(
            kind: .expense,
            occurredAt: occurredAt,
            postings: [
                Posting(accountID: UUID(), money: try Money(1, currency: usd)),
                Posting(accountID: UUID(), money: try Money(-1, currency: usd))
            ],
            originContext: historical
        ))

        let wrongDay = try TransactionOriginContext(
            calendarIdentifier: "gregorian",
            timeZoneIdentifier: "America/New_York",
            utcOffsetSeconds: -5 * 3_600,
            dayKey: 20260702
        )
        XCTAssertThrowsError(try JournalEntry(
            kind: .expense,
            occurredAt: occurredAt,
            postings: [
                Posting(accountID: UUID(), money: try Money(1, currency: usd)),
                Posting(accountID: UUID(), money: try Money(-1, currency: usd))
            ],
            originContext: wrongDay
        )) { error in
            XCTAssertEqual(
                error as? JournalEntryValidationError,
                .originContextMismatch
            )
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let captured = TransactionOriginContext.capture(
            for: occurredAt,
            calendar: calendar,
            timeZone: calendar.timeZone
        )
        XCTAssertEqual(captured.utcOffsetSeconds, -4 * 3_600)
        XCTAssertNoThrow(try JournalEntry(
            kind: .expense,
            occurredAt: occurredAt,
            postings: [
                Posting(accountID: UUID(), money: try Money(1, currency: usd)),
                Posting(accountID: UUID(), money: try Money(-1, currency: usd))
            ],
            originContext: captured
        ))
    }

    func testNonFiniteJournalDatesAreRejected() throws {
        let sgd = try CurrencyCode("SGD")
        XCTAssertThrowsError(try JournalEntry(
            kind: .expense,
            occurredAt: Date(timeIntervalSinceReferenceDate: .infinity),
            postings: [
                Posting(accountID: UUID(), money: try Money(1, currency: sgd)),
                Posting(accountID: UUID(), money: try Money(-1, currency: sgd))
            ]
        )) { error in
            XCTAssertEqual(
                error as? JournalEntryValidationError,
                .invalidEventDate
            )
        }
    }
}
