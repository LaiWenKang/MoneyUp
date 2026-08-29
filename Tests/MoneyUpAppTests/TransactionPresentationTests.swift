@testable import MoneyUp
import MoneyUpCore
import XCTest

final class TransactionPresentationTests: XCTestCase {
    func testDashboardRefreshUsesReportingMidnightAcrossDifferentZones() throws {
        let now = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-28T15:59:00Z")
        )
        let singapore = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: "Asia/Singapore"
        )
        let utc = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: "UTC"
        )

        let reportingBoundary = try XCTUnwrap(
            DashboardReportingClockPolicy.nextRefresh(
                after: now,
                calendar: singapore
            )
        )
        let deviceBoundary = try XCTUnwrap(
            DashboardReportingClockPolicy.nextRefresh(after: now, calendar: utc)
        )

        XCTAssertEqual(reportingBoundary.timeIntervalSince(now), 60)
        XCTAssertNotEqual(reportingBoundary, deviceBoundary)
    }

    func testDashboardRefreshDoesNotAssumeFixedLengthDays() throws {
        let now = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-03-08T08:30:00Z")
        )
        let losAngeles = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: "America/Los_Angeles"
        )

        let boundary = try XCTUnwrap(
            DashboardReportingClockPolicy.nextRefresh(
                after: now,
                calendar: losAngeles
            )
        )

        XCTAssertEqual(boundary.timeIntervalSince(now), 22.5 * 60 * 60)
    }

    func testDashboardRefreshAdvancesPastAnIntradaySchedule() throws {
        let now = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-28T02:00:00Z")
        )
        let occurrence = now.addingTimeInterval(5 * 60)
        let singapore = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: "Asia/Singapore"
        )

        let refresh = try XCTUnwrap(
            DashboardReportingClockPolicy.nextRefresh(
                after: now,
                calendar: singapore,
                scheduledOccurrences: [occurrence]
            )
        )

        XCTAssertEqual(refresh, occurrence.addingTimeInterval(1))
    }

    func testQuickLogSplitFocusUsesStableLineIdentity() {
        let first = UUID()
        let second = UUID()

        XCTAssertNotEqual(
            QuickLogFieldFocus.splitAmount(first),
            QuickLogFieldFocus.splitMemo(first)
        )
        XCTAssertNotEqual(
            QuickLogFieldFocus.splitAmount(first),
            QuickLogFieldFocus.splitAmount(second)
        )
        XCTAssertEqual(QuickLogFieldFocus.splitMemo(first).splitLineID, first)
        XCTAssertNil(QuickLogFieldFocus.note.splitLineID)
    }

    func testOccurrenceDateRefreshesOnlyForAnUntouchedNewDraft() {
        XCTAssertTrue(
            QuickLogOccurrencePolicy.shouldRefresh(
                hasTransactionContent: false,
                dateWasEdited: false,
                sourceCaptureID: nil
            )
        )
        XCTAssertFalse(
            QuickLogOccurrencePolicy.shouldRefresh(
                hasTransactionContent: true,
                dateWasEdited: false,
                sourceCaptureID: nil
            )
        )
        XCTAssertFalse(
            QuickLogOccurrencePolicy.shouldRefresh(
                hasTransactionContent: false,
                dateWasEdited: true,
                sourceCaptureID: nil
            )
        )
        XCTAssertFalse(
            QuickLogOccurrencePolicy.shouldRefresh(
                hasTransactionContent: false,
                dateWasEdited: false,
                sourceCaptureID: UUID()
            )
        )
    }

    func testSuggestionPolicyRequiresReviewForLowConfidenceOrEditedFields() {
        XCTAssertFalse(
            QuickLogSuggestionPolicy.shouldPrefillReceiptCandidate(
                confidence: .low,
                fieldIsUnchanged: true
            )
        )
        XCTAssertFalse(
            QuickLogSuggestionPolicy.shouldPrefillReceiptCandidate(
                confidence: .high,
                fieldIsUnchanged: false
            )
        )
        XCTAssertTrue(
            QuickLogSuggestionPolicy.shouldPrefillReceiptCandidate(
                confidence: .medium,
                fieldIsUnchanged: true
            )
        )

        XCTAssertTrue(
            QuickLogSuggestionPolicy.shouldPrefillHistorySuggestion(
                confidence: .high,
                fieldWasEdited: false,
                parserSuppliedValue: false
            )
        )
        for confidence in [CaptureConfidence.low, .medium] {
            XCTAssertFalse(
                QuickLogSuggestionPolicy.shouldPrefillHistorySuggestion(
                    confidence: confidence,
                    fieldWasEdited: false,
                    parserSuppliedValue: false
                )
            )
        }
        XCTAssertFalse(
            QuickLogSuggestionPolicy.shouldPrefillHistorySuggestion(
                confidence: .high,
                fieldWasEdited: true,
                parserSuppliedValue: false
            )
        )
        XCTAssertFalse(
            QuickLogSuggestionPolicy.shouldPrefillHistorySuggestion(
                confidence: .high,
                fieldWasEdited: false,
                parserSuppliedValue: true
            )
        )
        XCTAssertFalse(
            QuickLogSuggestionPolicy.shouldPrefillHistorySuggestion(
                confidence: .high,
                fieldWasEdited: false,
                parserSuppliedValue: false,
                hasFixedDefault: true
            )
        )
        XCTAssertFalse(
            QuickLogSuggestionPolicy.shouldPrefillHistorySuggestion(
                confidence: .high,
                fieldWasEdited: false,
                parserSuppliedValue: false,
                usedPayeeHistory: false
            )
        )
        XCTAssertTrue(
            QuickLogSuggestionPolicy.receiptContextIsCurrent(
                scannedKind: .expense,
                currentKind: .expense
            )
        )
        XCTAssertFalse(
            QuickLogSuggestionPolicy.receiptContextIsCurrent(
                scannedKind: .expense,
                currentKind: .income
            )
        )
    }

    func testDuplicateReviewUsesFrozenOriginDayForHistory() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try XCTUnwrap(
            TimeZone(identifier: "America/Los_Angeles")
        )
        let occurredAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-01-01T01:00:00Z")
        )
        let currency = try CurrencyCode("USD")
        let entry = try JournalEntry(
            kind: .expense,
            occurredAt: occurredAt,
            postings: [
                Posting(accountID: UUID(), money: try Money(1, currency: currency)),
                Posting(accountID: UUID(), money: try Money(-1, currency: currency))
            ],
            originContext: .capture(
                for: occurredAt,
                calendar: utc,
                timeZone: utc.timeZone
            )
        )

        let historyDate = QuickLogDuplicateReviewPolicy.historyDate(
            for: entry,
            calendar: losAngeles
        )

        XCTAssertEqual(
            FinancialPeriodBoundary.dayKey(
                for: historyDate,
                calendar: losAngeles
            ),
            20260101
        )
        XCTAssertEqual(
            FinancialPeriodBoundary.dayKey(
                for: occurredAt,
                calendar: losAngeles
            ),
            20251231
        )
    }

    func testZeroBudgetLimitWithSpendingIsConsistentlyOverPlan() {
        let result = moneyUpPaceRatio(
            spent: 1,
            limit: 0,
            operation: "test-pace"
        )

        guard case let .available(ratio) = result else {
            return XCTFail("Expected a representable pace ratio")
        }
        XCTAssertEqual(ratio, 2)
    }

    func testNegativeBudgetLimitIsUnavailable() {
        guard case .unavailable = moneyUpPaceRatio(
            spent: 1,
            limit: -1,
            operation: "test-invalid-pace"
        ) else {
            return XCTFail("An invalid limit must not be presented as zero or full")
        }
    }

    func testIncomePresentsPositiveUserFacingAmount() throws {
        let currency = try CurrencyCode("SGD")
        let bank = LedgerAccount(
            name: "Bank",
            kind: .asset,
            currency: currency,
            accountType: .bank
        )
        let salary = LedgerAccount(name: "Salary", kind: .income)
        let entry = try TransactionFactory.income(
            amount: try Money(250, currency: currency),
            depositedInto: bank.id,
            category: salary.id
        )

        let result = transactionDisplayAmountsResult(
            for: entry,
            accountsByID: accountsByID([bank, salary])
        )
        guard case let .available(amounts) = result else {
            return XCTFail("Expected an exact income presentation")
        }
        XCTAssertEqual(amounts, [
            TransactionDisplayAmount(
                money: try Money(250, currency: currency),
                role: .income
            )
        ])
    }

    func testSplitExpensePresentsCompleteCheckedTotal() throws {
        let currency = try CurrencyCode("SGD")
        let wallet = LedgerAccount(
            name: "Wallet",
            kind: .asset,
            currency: currency,
            accountType: .cash
        )
        let food = LedgerAccount(name: "Food", kind: .expense)
        let transit = LedgerAccount(name: "Transit", kind: .expense)
        let entry = try TransactionFactory.splitExpense(
            amount: try Money(12.50, currency: currency),
            paidFrom: wallet.id,
            splits: [
                TransactionSplitLine(
                    categoryAccountID: food.id,
                    amount: try Money(8.25, currency: currency)
                ),
                TransactionSplitLine(
                    categoryAccountID: transit.id,
                    amount: try Money(4.25, currency: currency)
                )
            ]
        )

        let result = transactionDisplayAmountsResult(
            for: entry,
            accountsByID: accountsByID([wallet, food, transit])
        )
        guard case let .available(amounts) = result else {
            return XCTFail("Expected an exact transaction presentation")
        }
        XCTAssertEqual(amounts, [
            TransactionDisplayAmount(
                money: try Money(12.50, currency: currency),
                role: .expense
            )
        ])
    }

    func testSplitRefundPresentsPositiveRefundTotal() throws {
        let currency = try CurrencyCode("USD")
        let bank = LedgerAccount(
            name: "Bank",
            kind: .asset,
            currency: currency,
            accountType: .bank
        )
        let first = LedgerAccount(name: "First", kind: .expense)
        let second = LedgerAccount(name: "Second", kind: .expense)
        let entry = try TransactionFactory.splitRefund(
            amount: try Money(7, currency: currency),
            returnedTo: bank.id,
            splits: [
                TransactionSplitLine(
                    categoryAccountID: first.id,
                    amount: try Money(2, currency: currency)
                ),
                TransactionSplitLine(
                    categoryAccountID: second.id,
                    amount: try Money(5, currency: currency)
                )
            ]
        )

        let result = transactionDisplayAmountsResult(
            for: entry,
            accountsByID: accountsByID([bank, first, second]),
            isRefund: true
        )
        guard case let .available(amounts) = result else {
            return XCTFail("Expected an exact refund presentation")
        }
        XCTAssertEqual(amounts.first?.money, try Money(7, currency: currency))
        XCTAssertEqual(amounts.first?.role, .refund)
    }

    func testForeignTransferKeepsBothCurrenciesSeparate() throws {
        let sgd = try CurrencyCode("SGD")
        let usd = try CurrencyCode("USD")
        let source = LedgerAccount(
            name: "Singapore",
            kind: .asset,
            currency: sgd,
            accountType: .bank
        )
        let destination = LedgerAccount(
            name: "US",
            kind: .asset,
            currency: usd,
            accountType: .bank
        )
        let sourceTrading = LedgerAccount(
            name: "FX SGD",
            kind: .trading,
            currency: sgd,
            systemRole: .foreignExchange
        )
        let destinationTrading = LedgerAccount(
            name: "FX USD",
            kind: .trading,
            currency: usd,
            systemRole: .foreignExchange
        )
        let entry = try TransactionFactory.foreignCurrencyTransfer(
            sourceAmount: try Money(135, currency: sgd),
            destinationAmount: try Money(100, currency: usd),
            from: source.id,
            to: destination.id,
            sourceTradingAccountID: sourceTrading.id,
            destinationTradingAccountID: destinationTrading.id
        )

        let result = transactionDisplayAmountsResult(
            for: entry,
            accountsByID: accountsByID([
                source,
                destination,
                sourceTrading,
                destinationTrading
            ])
        )
        guard case let .available(amounts) = result else {
            return XCTFail("Expected a separated transfer presentation")
        }
        XCTAssertEqual(amounts.map(\.money), [
            try Money(135, currency: sgd),
            try Money(100, currency: usd)
        ])
        XCTAssertEqual(amounts.map(\.role), [.outgoing, .incoming])
    }

    func testSameCurrencyTransferKeepsOutgoingAndIncomingRoles() throws {
        let currency = try CurrencyCode("SGD")
        let source = LedgerAccount(
            name: "Wallet",
            kind: .asset,
            currency: currency,
            accountType: .cash
        )
        let destination = LedgerAccount(
            name: "Bank",
            kind: .asset,
            currency: currency,
            accountType: .bank
        )
        let entry = try TransactionFactory.transfer(
            amount: try Money(40, currency: currency),
            from: source.id,
            to: destination.id
        )

        let result = transactionDisplayAmountsResult(
            for: entry,
            accountsByID: accountsByID([source, destination])
        )
        guard case let .available(amounts) = result else {
            return XCTFail("Expected an exact transfer presentation")
        }
        XCTAssertEqual(amounts.map(\.money), [
            try Money(40, currency: currency),
            try Money(40, currency: currency)
        ])
        XCTAssertEqual(amounts.map(\.role), [.outgoing, .incoming])
    }

    func testLiabilityAdjustmentUsesUserFacingSign() throws {
        let currency = try CurrencyCode("CNY")
        let card = LedgerAccount(
            name: "Card",
            kind: .liability,
            currency: currency,
            accountType: .creditCard
        )
        let equity = LedgerAccount(
            name: "Opening",
            kind: .equity,
            currency: currency,
            systemRole: .openingBalances
        )
        let entry = try TransactionFactory.balanceAdjustment(
            displayBalanceDelta: try Money(500, currency: currency),
            accountID: card.id,
            equityAccountID: equity.id,
            accountIsLiability: true
        )

        let result = transactionDisplayAmountsResult(
            for: entry,
            accountsByID: accountsByID([card, equity])
        )
        guard case let .available(amounts) = result else {
            return XCTFail("Expected an adjustment presentation")
        }
        XCTAssertEqual(amounts.first?.money, try Money(500, currency: currency))
        XCTAssertEqual(amounts.first?.role, .change)
    }

    func testInvestmentPurchaseAndSaleExposeOnlyTheCashLeg() throws {
        let currency = try CurrencyCode("USD")
        let cash = LedgerAccount(
            name: "Broker cash",
            kind: .asset,
            currency: currency,
            accountType: .brokerage
        )
        let position = LedgerAccount(
            name: "Position",
            kind: .asset,
            currency: currency,
            accountType: .investment,
            systemRole: .investmentPosition
        )
        let gain = LedgerAccount(
            name: "Gain",
            kind: .trading,
            currency: currency,
            systemRole: .investmentGainLoss
        )
        let purchase = try TransactionFactory.investmentPurchase(
            cashCost: try Money(400, currency: currency),
            resultingPositionValue: try Money(400, currency: currency),
            previousPositionValue: .zero(currency: currency),
            cashAccountID: cash.id,
            positionAccountID: position.id,
            gainLossAccountID: gain.id
        )
        let sale = try TransactionFactory.investmentSale(
            proceeds: try Money(450, currency: currency),
            resultingPositionValue: .zero(currency: currency),
            previousPositionValue: try Money(400, currency: currency),
            cashAccountID: cash.id,
            positionAccountID: position.id,
            gainLossAccountID: gain.id
        )
        let accounts = accountsByID([cash, position, gain])

        guard case let .available(purchaseAmounts) = transactionDisplayAmountsResult(
            for: purchase,
            accountsByID: accounts
        ), case let .available(saleAmounts) = transactionDisplayAmountsResult(
            for: sale,
            accountsByID: accounts
        ) else {
            return XCTFail("Expected exact investment cash-leg presentations")
        }
        XCTAssertEqual(purchaseAmounts, [
            TransactionDisplayAmount(
                money: try Money(-400, currency: currency),
                role: .change
            )
        ])
        XCTAssertEqual(saleAmounts, [
            TransactionDisplayAmount(
                money: try Money(450, currency: currency),
                role: .change
            )
        ])
    }

    func testMixedCurrencyCategoryLegsAreUnavailable() throws {
        let sgd = try CurrencyCode("SGD")
        let usd = try CurrencyCode("USD")
        let category = LedgerAccount(name: "Mixed", kind: .expense)
        let sgdAccount = LedgerAccount(
            name: "SGD",
            kind: .asset,
            currency: sgd,
            accountType: .bank
        )
        let usdAccount = LedgerAccount(
            name: "USD",
            kind: .asset,
            currency: usd,
            accountType: .bank
        )
        let entry = try JournalEntry(
            kind: .expense,
            postings: [
                Posting(accountID: category.id, money: try Money(10, currency: sgd)),
                Posting(accountID: sgdAccount.id, money: try Money(-10, currency: sgd)),
                Posting(accountID: category.id, money: try Money(5, currency: usd)),
                Posting(accountID: usdAccount.id, money: try Money(-5, currency: usd))
            ]
        )

        guard case .unavailable = transactionDisplayAmountsResult(
            for: entry,
            accountsByID: accountsByID([category, sgdAccount, usdAccount])
        ) else {
            return XCTFail("Mixed currencies must not be combined")
        }
    }

    private func accountsByID(_ accounts: [LedgerAccount]) -> [UUID: LedgerAccount] {
        Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
    }
}
