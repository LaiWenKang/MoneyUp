import Foundation
@testable import MoneyUpCore
import XCTest

final class NaturalLanguageEntryParserTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()

    private let cash = LedgerAccount(name: "Cash", kind: .asset, accountType: .cash)
    private let cardAccount = LedgerAccount(
        name: "DBS Card",
        kind: .liability,
        accountType: .creditCard
    )
    private let food = LedgerAccount(name: "Food", kind: .expense)
    private let salary = LedgerAccount(name: "Salary", kind: .income)

    private var accounts: [LedgerAccount] { [cash, cardAccount, food, salary] }

    /// 2026-03-20 is a Friday.
    private func now() throws -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 20
        components.hour = 14
        components.minute = 30
        return try XCTUnwrap(calendar.date(from: components))
    }

    func testReadsAmountAccountAndRelativeDay() throws {
        let reference = try now()
        let draft = NaturalLanguageEntryParser.draft(
            from: "lunch 12.50 cash yesterday",
            accounts: accounts,
            now: reference,
            calendar: calendar
        )

        XCTAssertEqual(draft.kind, .expense)
        XCTAssertEqual(draft.amount, Decimal(string: "12.50"))
        XCTAssertEqual(draft.accountID, cash.id)
        XCTAssertEqual(draft.payee, "lunch")
        XCTAssertEqual(draft.source, .naturalLanguage)

        let expected = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: reference))
        XCTAssertEqual(draft.occurredAt, expected)
    }

    func testDayBeforeYesterdayWinsOverYesterday() throws {
        let reference = try now()
        let draft = NaturalLanguageEntryParser.draft(
            from: "coffee 4 day before yesterday",
            accounts: accounts,
            now: reference,
            calendar: calendar
        )

        let expected = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: reference))
        XCTAssertEqual(draft.occurredAt, expected)
        XCTAssertEqual(draft.amount, Decimal(4))
    }

    func testWeekdayResolvesToTheMostRecentOccurrence() throws {
        let reference = try now()
        let draft = NaturalLanguageEntryParser.draft(
            from: "groceries 42.10 wednesday",
            accounts: accounts,
            now: reference,
            calendar: calendar
        )

        let occurred = try XCTUnwrap(draft.occurredAt)
        XCTAssertEqual(calendar.component(.weekday, from: occurred), 4)
        XCTAssertLessThan(occurred, reference)
        XCTAssertEqual(calendar.component(.day, from: occurred), 18)
    }

    func testIncomeKeywordSwitchesTheDraftKindAndMatchesAnIncomeCategory() throws {
        let draft = NaturalLanguageEntryParser.draft(
            from: "salary 5000 today",
            accounts: accounts,
            now: try now(),
            calendar: calendar
        )

        XCTAssertEqual(draft.kind, .income)
        XCTAssertEqual(draft.amount, Decimal(5000))
        XCTAssertEqual(draft.categoryID, salary.id)
    }

    func testRefundKeywordUsesExpenseCategoryInsteadOfIncome() throws {
        let draft = NaturalLanguageEntryParser.draft(
            from: "refunded 40 food",
            accounts: accounts,
            now: try now(),
            calendar: calendar,
            locale: Locale(identifier: "en_SG")
        )

        XCTAssertEqual(draft.kind, .refund)
        XCTAssertEqual(draft.categoryID, food.id)
        XCTAssertEqual(draft.amount, Decimal(40))
    }

    func testExplicitDateIsPreferredAndNotMistakenForTheAmount() throws {
        let draft = NaturalLanguageEntryParser.draft(
            from: "dinner 88.00 on 15/03/2026",
            accounts: accounts,
            now: try now(),
            calendar: calendar,
            prefersDayFirst: true
        )

        XCTAssertEqual(draft.amount, Decimal(88))
        let occurred = try XCTUnwrap(draft.occurredAt)
        XCTAssertEqual(calendar.component(.month, from: occurred), 3)
        XCTAssertEqual(calendar.component(.day, from: occurred), 15)
        XCTAssertEqual(draft.payee, "dinner")
    }

    func testTypedDayKeepsTheCurrentTimeOfDayRatherThanMidnight() throws {
        let reference = try now()
        let draft = NaturalLanguageEntryParser.draft(
            from: "taxi 20 on 2026-03-15",
            accounts: accounts,
            now: reference,
            calendar: calendar
        )

        let occurred = try XCTUnwrap(draft.occurredAt)
        XCTAssertEqual(calendar.component(.hour, from: occurred), 14)
        XCTAssertEqual(calendar.component(.minute, from: occurred), 30)
    }

    func testChinesePhraseIsParsed() throws {
        let reference = try now()
        let draft = NaturalLanguageEntryParser.draft(
            from: "昨天 现金 午餐 12.50",
            accounts: accounts + [LedgerAccount(name: "现金", kind: .asset, accountType: .cash)],
            now: reference,
            calendar: calendar
        )

        XCTAssertEqual(draft.amount, Decimal(string: "12.50"))
        XCTAssertEqual(draft.payee, "午餐")
        let expected = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: reference))
        XCTAssertEqual(draft.occurredAt, expected)
    }

    func testLongerAccountNameWinsOverAShorterOneItContains() throws {
        let cashBack = LedgerAccount(name: "Cash Back Card", kind: .liability, accountType: .creditCard)
        let draft = NaturalLanguageEntryParser.draft(
            from: "fuel 60 cash back card",
            accounts: [cash, cashBack],
            now: try now(),
            calendar: calendar
        )

        XCTAssertEqual(draft.accountID, cashBack.id)
    }

    func testLatinAccountNameDoesNotMatchInsideAnotherWord() throws {
        let draft = NaturalLanguageEntryParser.draft(
            from: "cashew nuts 5",
            accounts: [cash],
            now: try now(),
            calendar: calendar,
            locale: Locale(identifier: "en_SG")
        )

        XCTAssertNil(draft.accountID)
        XCTAssertEqual(draft.payee, "cashew nuts")
    }

    func testCommaDecimalAmountUsesTheProvidedLocale() throws {
        let draft = NaturalLanguageEntryParser.draft(
            from: "déjeuner 12,50 cash",
            accounts: accounts,
            now: try now(),
            calendar: calendar,
            locale: Locale(identifier: "fr_FR")
        )

        XCTAssertEqual(draft.amount, Decimal(string: "12.50"))
        XCTAssertEqual(draft.accountID, cash.id)
    }

    func testUnparseablePhraseProducesAnEmptyDraft() throws {
        let draft = NaturalLanguageEntryParser.draft(
            from: "???",
            accounts: accounts,
            now: try now(),
            calendar: calendar
        )

        XCTAssertTrue(draft.isEmpty)
    }
}

final class CategorySuggesterTests: XCTestCase {
    func testSuggestsTheCategoryUsedMostOftenForThatPayee() throws {
        let sgd = try CurrencyCode("SGD")
        let bank = LedgerAccount(name: "Bank", kind: .asset, currency: sgd, accountType: .bank)
        let coffee = LedgerAccount(name: "Coffee", kind: .expense)
        let groceries = LedgerAccount(name: "Groceries", kind: .expense)

        let entries = [
            try TransactionFactory.expense(
                amount: try Money(6, currency: sgd),
                paidFrom: bank.id,
                category: coffee.id,
                payee: "Starbucks"
            ),
            try TransactionFactory.expense(
                amount: try Money(7, currency: sgd),
                paidFrom: bank.id,
                category: coffee.id,
                payee: "starbucks orchard"
            ),
            try TransactionFactory.expense(
                amount: try Money(30, currency: sgd),
                paidFrom: bank.id,
                category: groceries.id,
                payee: "Starbucks"
            )
        ]

        XCTAssertEqual(
            CategorySuggester.suggestedCategory(
                forPayee: "Starbucks",
                entries: entries,
                accounts: [bank, coffee, groceries]
            ),
            coffee.id
        )
    }

    func testReturnsNothingForAnUnseenPayee() throws {
        let sgd = try CurrencyCode("SGD")
        let bank = LedgerAccount(name: "Bank", kind: .asset, currency: sgd, accountType: .bank)
        let coffee = LedgerAccount(name: "Coffee", kind: .expense)
        let entry = try TransactionFactory.expense(
            amount: try Money(6, currency: sgd),
            paidFrom: bank.id,
            category: coffee.id,
            payee: "Starbucks"
        )

        XCTAssertNil(
            CategorySuggester.suggestedCategory(
                forPayee: "Hardware Store",
                entries: [entry],
                accounts: [bank, coffee]
            )
        )
    }

    func testIgnoresAPayeeTooShortToMeanAnything() throws {
        let sgd = try CurrencyCode("SGD")
        let bank = LedgerAccount(name: "Bank", kind: .asset, currency: sgd, accountType: .bank)
        let coffee = LedgerAccount(name: "Coffee", kind: .expense)
        let entry = try TransactionFactory.expense(
            amount: try Money(6, currency: sgd),
            paidFrom: bank.id,
            category: coffee.id,
            payee: "A"
        )

        XCTAssertNil(
            CategorySuggester.suggestedCategory(
                forPayee: "A",
                entries: [entry],
                accounts: [bank, coffee]
            )
        )
    }
}
