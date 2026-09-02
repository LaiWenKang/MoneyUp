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

    func testLatinKindKeywordsDoNotMatchInsidePayeeWords() throws {
        let salaryman = NaturalLanguageEntryParser.draft(
            from: "Salaryman 25",
            accounts: accounts,
            now: try now(),
            calendar: calendar,
            locale: Locale(identifier: "en_SG")
        )
        let refundable = NaturalLanguageEntryParser.draft(
            from: "Refundable deposit 40",
            accounts: accounts,
            now: try now(),
            calendar: calendar,
            locale: Locale(identifier: "en_SG")
        )

        XCTAssertEqual(salaryman.kind, .expense)
        XCTAssertEqual(salaryman.payee, "Salaryman")
        XCTAssertEqual(refundable.kind, .expense)
        XCTAssertEqual(refundable.payee, "Refundable deposit")
    }

    func testLatinDateTokenDoesNotMatchOrStripTomorrowlandPayee() throws {
        let draft = NaturalLanguageEntryParser.draft(
            from: "Tomorrowland 42",
            accounts: accounts,
            now: try now(),
            calendar: calendar,
            locale: Locale(identifier: "en_SG")
        )

        XCTAssertNil(draft.occurredAt)
        XCTAssertEqual(draft.amount, Decimal(42))
        XCTAssertEqual(draft.payee, "Tomorrowland")
    }

    func testStandaloneDateTokenDoesNotStripEarlierPrefixedPayee() throws {
        let reference = try now()
        let draft = NaturalLanguageEntryParser.draft(
            from: "Tomorrowland 42 tomorrow",
            accounts: accounts,
            now: reference,
            calendar: calendar,
            locale: Locale(identifier: "en_SG")
        )

        let expected = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: reference))
        XCTAssertEqual(draft.occurredAt, expected)
        XCTAssertEqual(draft.payee, "Tomorrowland")
    }

    func testUnicodeBoundariesProtectPayeesAndLocaleAmount() throws {
        let draft = NaturalLanguageEntryParser.draft(
            from: "érefundé café 1.234,50",
            accounts: accounts,
            now: try now(),
            calendar: calendar,
            locale: Locale(identifier: "de_DE")
        )
        let nonLatinBoundary = NaturalLanguageEntryParser.draft(
            from: "界tomorrow界 9",
            accounts: accounts,
            now: try now(),
            calendar: calendar,
            locale: Locale(identifier: "en_SG")
        )

        XCTAssertEqual(draft.kind, .expense)
        XCTAssertEqual(draft.amount, Decimal(string: "1234.50"))
        XCTAssertEqual(draft.payee, "érefundé café")
        XCTAssertNil(nonLatinBoundary.occurredAt)
        XCTAssertEqual(nonLatinBoundary.payee, "界tomorrow界")
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
        let chineseCash = LedgerAccount(
            name: "现金",
            kind: .asset,
            accountType: .cash
        )
        let expected = try XCTUnwrap(
            calendar.date(byAdding: .day, value: -1, to: reference)
        )

        for phrase in [
            "昨天 现金 午餐 12.50",
            "昨天 现\u{200B}金 午餐 12.50",
            "昨天 现\u{FE0F}金 午餐 12.50"
        ] {
            let parsed = NaturalLanguageEntryParser.parse(
                phrase,
                accounts: accounts + [chineseCash],
                now: reference,
                calendar: calendar
            )

            XCTAssertEqual(parsed.draft.amount, Decimal(string: "12.50"), phrase)
            XCTAssertEqual(parsed.draft.accountID, chineseCash.id, phrase)
            XCTAssertEqual(parsed.draft.payee, "午餐", phrase)
            XCTAssertEqual(parsed.draft.occurredAt, expected, phrase)
            XCTAssertEqual(parsed.context, "午餐", phrase)
        }
    }

    func testImpossibleCivilDateFailsClosedWithoutInventingAnAmount() throws {
        for phrase in [
            "31/02/2026 dinner 20",
            "2026-13-01 dinner 20",
            "32/01/2026 dinner 20"
        ] {
            let draft = NaturalLanguageEntryParser.draft(
                from: phrase,
                accounts: accounts,
                now: try now(),
                calendar: calendar,
                locale: Locale(identifier: "en_SG")
            )

            XCTAssertNil(draft.occurredAt, phrase)
            XCTAssertNil(draft.amount, phrase)
        }
    }

    func testLeapDayIsAcceptedOnlyInALeapYear() throws {
        let invalid = NaturalLanguageEntryParser.draft(
            from: "29/02/2025 dinner 20",
            accounts: accounts,
            now: try now(),
            calendar: calendar,
            locale: Locale(identifier: "en_SG")
        )
        let valid = NaturalLanguageEntryParser.draft(
            from: "29/02/2024 dinner 20",
            accounts: accounts,
            now: try now(),
            calendar: calendar,
            locale: Locale(identifier: "en_SG")
        )
        let expected = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2024,
            month: 2,
            day: 29,
            hour: calendar.component(.hour, from: try now()),
            minute: calendar.component(.minute, from: try now()),
            second: calendar.component(.second, from: try now())
        )))

        XCTAssertNil(invalid.occurredAt)
        XCTAssertNil(invalid.amount)
        XCTAssertEqual(valid.occurredAt, expected)
        XCTAssertEqual(valid.amount, Decimal(20))
    }

    func testMultipleExplicitDatesFailClosedWithoutInventingAnAmount() throws {
        for phrase in [
            "15/03/2026 2026-04-01 dinner 20",
            "2026-04-01 31/02/2026 dinner 20",
            "31/02/2026 2026-04-01 dinner 20"
        ] {
            let draft = NaturalLanguageEntryParser.draft(
                from: phrase,
                accounts: accounts,
                now: try now(),
                calendar: calendar,
                locale: Locale(identifier: "en_SG")
            )

            XCTAssertNil(draft.occurredAt, phrase)
            XCTAssertNil(draft.amount, phrase)
        }
    }

    func testCJKTokensKeepSubstringMatchingWithoutSpaces() throws {
        let reference = try now()
        let draft = NaturalLanguageEntryParser.draft(
            from: "昨天午餐 12.50",
            accounts: accounts,
            now: reference,
            calendar: calendar,
            locale: Locale(identifier: "zh_CN")
        )

        let expected = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: reference))
        XCTAssertEqual(draft.occurredAt, expected)
        XCTAssertEqual(draft.amount, Decimal(string: "12.50"))
        XCTAssertEqual(draft.payee, "午餐")
    }

    func testCJKRefundKeywordKeepsSubstringMatching() throws {
        let draft = NaturalLanguageEntryParser.draft(
            from: "退款到账 40 food",
            accounts: accounts,
            now: try now(),
            calendar: calendar,
            locale: Locale(identifier: "zh_CN")
        )

        XCTAssertEqual(draft.kind, .refund)
        XCTAssertEqual(draft.categoryID, food.id)
        XCTAssertEqual(draft.amount, Decimal(40))
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

    func testAccountRemovalUsesTheExactBoundaryAwareWinningRange() throws {
        let office = LedgerAccount(name: "Office", kind: .asset)
        let cafe = LedgerAccount(name: "Café", kind: .asset)
        let cases = [
            ("Cashback supper Cash 12", "Cashback supper", cash),
            ("Cash\u{200B}back supper Cash 12", "Cashback supper", cash),
            ("back\u{200B}Cash supper Cash 12", "backCash supper", cash),
            ("supper Ca\u{200B}sh 12", "supper", cash),
            ("supper Ca\u{FE0F}sh 12", "supper", cash),
            ("supper Ｃａｓｈ 12", "supper", cash),
            ("supper Oﬃce 12", "supper", office),
            ("supper Cafe\u{301} 12", "supper", cafe)
        ]

        for (phrase, expectedContext, account) in cases {
            let parsed = NaturalLanguageEntryParser.parse(
                phrase,
                accounts: [account],
                now: try now(),
                calendar: calendar,
                locale: Locale(identifier: "en_SG")
            )

            XCTAssertEqual(parsed.draft.accountID, account.id, phrase)
            XCTAssertEqual(parsed.context, expectedContext, phrase)
            if expectedContext == "supper" {
                XCTAssertEqual(parsed.draft.payee, "supper", phrase)
            }
        }

        for phrase in [
            "a\u{301}Cash supper Cash 12",
            "Cash\u{301}back supper Cash 12",
            "a\u{301}\u{200B}\u{20DD}Cash supper Cash 12",
            "Cash\u{20DD}\u{200B}\u{301}back supper Cash 12"
        ] {
            let parsed = NaturalLanguageEntryParser.parse(
                phrase,
                accounts: [cash],
                now: try now(),
                calendar: calendar,
                locale: Locale(identifier: "en_SG")
            )

            XCTAssertEqual(parsed.draft.accountID, cash.id, phrase)
            XCTAssertEqual(parsed.context?.hasSuffix("supper"), true, phrase)
            XCTAssertEqual(parsed.context?.hasSuffix("supper Cash"), false, phrase)
        }
    }

    func testCategoryRemovalUsesTheExactBoundaryAwareWinningRange() throws {
        let parsed = NaturalLanguageEntryParser.parse(
            "Foodie lunch Food 12",
            accounts: [food],
            now: try now(),
            calendar: calendar,
            locale: Locale(identifier: "en_SG")
        )

        XCTAssertEqual(parsed.draft.categoryID, food.id)
        XCTAssertEqual(parsed.draft.payee, "Foodie lunch")
        XCTAssertEqual(parsed.context, "Foodie lunch")
    }

    func testEquivalentNameTieUsesStableIdentityAcrossInputOrder() throws {
        let lowerID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        )
        let higherID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")
        )
        let lower = LedgerAccount(id: lowerID, name: "Cash", kind: .asset)
        let higher = LedgerAccount(id: higherID, name: "cash", kind: .asset)

        for candidates in [[higher, lower], [lower, higher]] {
            let draft = NaturalLanguageEntryParser.draft(
                from: "lunch CASH 12",
                accounts: candidates,
                now: try now(),
                calendar: calendar,
                locale: Locale(identifier: "en_SG")
            )
            XCTAssertEqual(draft.accountID, lowerID)
            XCTAssertEqual(draft.payee, "lunch")
        }
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

    func testAssistanceContextSeparatesEveryParsedFinancialSpan() throws {
        let sgd = try CurrencyCode("SGD")
        let wallet = LedgerAccount(
            name: "Green Wallet",
            kind: .asset,
            currency: sgd
        )
        let dining = LedgerAccount(name: "Dining", kind: .expense)
        let parsed = NaturalLanguageEntryParser.parse(
            "Supper SGD $1,234.50 Green Wallet Dining on 15/03/2026",
            accounts: [wallet, dining],
            now: try now(),
            calendar: calendar,
            prefersDayFirst: true,
            locale: Locale(identifier: "en_SG")
        )

        XCTAssertEqual(parsed.draft.amount, Decimal(string: "1234.50"))
        XCTAssertEqual(parsed.draft.accountID, wallet.id)
        XCTAssertEqual(parsed.draft.categoryID, dining.id)
        XCTAssertNotNil(parsed.draft.occurredAt)
        XCTAssertEqual(parsed.context, "Supper")
    }

    func testAssistanceContextFailsClosedWhenOnlyFinancialSpansRemain() throws {
        let usd = try CurrencyCode("USD")
        let wallet = LedgerAccount(
            name: "Wallet",
            kind: .asset,
            currency: usd
        )
        let parsed = NaturalLanguageEntryParser.parse(
            "USD $42.10 on 2026-03-15 Wallet",
            accounts: [wallet],
            now: try now(),
            calendar: calendar,
            locale: Locale(identifier: "en_US")
        )

        XCTAssertNil(parsed.context)
        XCTAssertEqual(parsed.draft.amount, Decimal(string: "42.10"))
        XCTAssertEqual(parsed.draft.accountID, wallet.id)
        XCTAssertNotNil(parsed.draft.occurredAt)

        let archivedCash = LedgerAccount(
            name: "Cash",
            kind: .asset,
            isArchived: true
        )
        let crossingBoundary = NaturalLanguageEntryParser.parse(
            String(repeating: "x", count: 126) + " Ｃａｓｈ 12",
            accounts: [archivedCash],
            now: try now(),
            calendar: calendar,
            locale: Locale(identifier: "en_SG")
        )
        XCTAssertNil(crossingBoundary.draft.accountID)
        XCTAssertNil(crossingBoundary.context)

        let asciiPrefix = String(repeating: "x", count: 123)
        let scalarBoundary = NaturalLanguageEntryParser.parse(
            asciiPrefix + " Cashback 12",
            accounts: [archivedCash],
            now: try now(),
            calendar: calendar,
            locale: Locale(identifier: "en_SG")
        )
        XCTAssertEqual(scalarBoundary.context, asciiPrefix)

        let cjkPrefix = String(repeating: "餐", count: 83)
        let utf8Boundary = NaturalLanguageEntryParser.parse(
            cjkPrefix + " xx Cashback 12",
            accounts: [archivedCash],
            now: try now(),
            calendar: calendar,
            locale: Locale(identifier: "en_SG")
        )
        XCTAssertEqual(utf8Boundary.context, cjkPrefix + " xx")
        XCTAssertEqual(utf8Boundary.context?.utf8.count, 252)

        let nonLetterBoundary = NaturalLanguageEntryParser.parse(
            String(repeating: "\u{301}", count: 128) + " lunch 12",
            accounts: [],
            now: try now(),
            calendar: calendar,
            locale: Locale(identifier: "en_SG")
        )
        XCTAssertNil(nonLetterBoundary.context)
    }

    func testAssistanceContextSeparatesPunctuationBeforeRemovingCurrency() throws {
        let sgd = try CurrencyCode("SGD")
        let wallet = LedgerAccount(name: "Wallet", kind: .asset, currency: sgd)

        let slash = NaturalLanguageEntryParser.parse(
            "SGD/lunch 12",
            accounts: [wallet],
            now: try now(),
            calendar: calendar,
            locale: Locale(identifier: "en_SG")
        )
        let cjkPunctuation = NaturalLanguageEntryParser.parse(
            "午餐，SGD。好友 12",
            accounts: [wallet],
            now: try now(),
            calendar: calendar,
            locale: Locale(identifier: "en_SG")
        )
        let fullwidthSlash = NaturalLanguageEntryParser.parse(
            "SGD／午餐 12",
            accounts: [wallet],
            now: try now(),
            calendar: calendar,
            locale: Locale(identifier: "en_SG")
        )
        let fullwidthCurrency = NaturalLanguageEntryParser.parse(
            "ＳＧＤ／午餐 12",
            accounts: [wallet],
            now: try now(),
            calendar: calendar,
            locale: Locale(identifier: "en_SG")
        )
        let zeroWidthSeparator = NaturalLanguageEntryParser.parse(
            "SGD\u{200B}/lunch 12",
            accounts: [wallet],
            now: try now(),
            calendar: calendar,
            locale: Locale(identifier: "en_SG")
        )
        let embeddedZeroWidth = NaturalLanguageEntryParser.parse(
            "S\u{200B}GD/lunch 12",
            accounts: [wallet],
            now: try now(),
            calendar: calendar,
            locale: Locale(identifier: "en_SG")
        )
        let embeddedVariationSelector = NaturalLanguageEntryParser.parse(
            "S\u{FE0F}GD/lunch 12",
            accounts: [wallet],
            now: try now(),
            calendar: calendar,
            locale: Locale(identifier: "en_SG")
        )

        XCTAssertEqual(slash.context, "lunch")
        XCTAssertEqual(cjkPunctuation.context, "午餐 好友")
        XCTAssertEqual(fullwidthSlash.context, "午餐")
        XCTAssertEqual(fullwidthCurrency.context, "午餐")
        XCTAssertEqual(zeroWidthSeparator.context, "lunch")
        XCTAssertEqual(embeddedZeroWidth.context, "lunch")
        XCTAssertEqual(embeddedVariationSelector.context, "lunch")
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

    func testEqualCountAndRecencyTieIsDeterministicAcrossInputOrder() throws {
        let sgd = try CurrencyCode("SGD")
        let bank = LedgerAccount(name: "Bank", kind: .asset, currency: sgd)
        let lowerID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        )
        let higherID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")
        )
        let first = LedgerAccount(id: lowerID, name: "Coffee", kind: .expense)
        let second = LedgerAccount(id: higherID, name: "Snacks", kind: .expense)
        let occurredAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let entries = [
            try TransactionFactory.expense(
                amount: try Money(6, currency: sgd),
                paidFrom: bank.id,
                category: first.id,
                occurredAt: occurredAt,
                payee: "Tie Cafe"
            ),
            try TransactionFactory.expense(
                amount: try Money(7, currency: sgd),
                paidFrom: bank.id,
                category: second.id,
                occurredAt: occurredAt,
                payee: "Tie Cafe"
            )
        ]

        XCTAssertEqual(
            CategorySuggester.suggestedCategory(
                forPayee: "Tie Cafe",
                entries: entries,
                accounts: [bank, first, second]
            ),
            lowerID
        )
        XCTAssertEqual(
            CategorySuggester.suggestedCategory(
                forPayee: "Tie Cafe",
                entries: Array(entries.reversed()),
                accounts: [second, bank, first]
            ),
            lowerID
        )
    }
}
