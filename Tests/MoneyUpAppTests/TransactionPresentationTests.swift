@testable import MoneyUp
import MoneyUpCore
import XCTest

final class TransactionPresentationTests: XCTestCase {
    func testFinalReportingDayContextIsLocalizedInEnglishAndSimplifiedChinese() throws {
        XCTAssertEqual(
            AppLocalization.string(
                "dashboard.safe_to_spend",
                language: .english
            ),
            "Flexible today"
        )
        XCTAssertEqual(
            AppLocalization.string(
                "dashboard.safe_to_spend",
                language: .simplifiedChinese
            ),
            "今日灵活可用"
        )

        let english = try reportingContext(
            day: 30,
            language: .english,
            deviceTimeZoneIdentifier: "Asia/Singapore"
        )
        XCTAssertEqual(english.inclusiveRemainingDayCount, 1)
        XCTAssertEqual(english.monthEndDescription, "Sep 30")
        XCTAssertEqual(english.reportingDayDescription, "Wed, Sep 30")
        XCTAssertEqual(
            english.contextDescription,
            "Wed, Sep 30 · 1 day through Sep 30 (today included)"
        )

        let chinese = try reportingContext(
            day: 30,
            language: .simplifiedChinese,
            deviceTimeZoneIdentifier: "Asia/Singapore"
        )
        XCTAssertEqual(chinese.inclusiveRemainingDayCount, 1)
        XCTAssertEqual(chinese.monthEndDescription, "9月30日")
        XCTAssertEqual(chinese.reportingDayDescription, "9月30日 周三")
        XCTAssertEqual(
            chinese.contextDescription,
            "9月30日 周三 · 至 9月30日 剩余 1 天（含今天）"
        )
    }

    func testMidMonthContextIsExactWithAndWithoutReportingZone() throws {
        let expectations: [(
            language: AppLanguagePreference,
            reportingDay: String,
            monthEnd: String,
            period: String,
            reportingZone: String,
            zonedContext: String
        )] = [
            (
                .english,
                "Tue, Sep 15",
                "Sep 30",
                "16 days through Sep 30 (today included)",
                "Singapore Time",
                "Tue, Sep 15 · 16 days through Sep 30 (today included) "
                    + "· Reporting: Singapore Time"
            ),
            (
                .simplifiedChinese,
                "9月15日 周二",
                "9月30日",
                "至 9月30日 剩余 16 天（含今天）",
                "新加坡时间",
                "9月15日 周二 · 至 9月30日 剩余 16 天（含今天） "
                    + "· 报表时区：新加坡时间"
            )
        ]

        for expectation in expectations {
            let matchingZone = try reportingContext(
                day: 15,
                language: expectation.language,
                deviceTimeZoneIdentifier: "Asia/Singapore"
            )
            XCTAssertEqual(
                matchingZone.reportingDayDescription,
                expectation.reportingDay
            )
            XCTAssertEqual(
                matchingZone.monthEndDescription,
                expectation.monthEnd
            )
            XCTAssertEqual(matchingZone.inclusiveRemainingDayCount, 16)
            XCTAssertNil(matchingZone.reportingTimeZoneDescription)
            XCTAssertEqual(
                matchingZone.contextDescription,
                "\(expectation.reportingDay) · \(expectation.period)"
            )

            let differentZone = try reportingContext(
                day: 15,
                language: expectation.language,
                deviceTimeZoneIdentifier: "America/Los_Angeles"
            )
            XCTAssertEqual(
                differentZone.reportingDayDescription,
                expectation.reportingDay
            )
            XCTAssertEqual(
                differentZone.monthEndDescription,
                expectation.monthEnd
            )
            XCTAssertEqual(differentZone.inclusiveRemainingDayCount, 16)
            XCTAssertEqual(
                differentZone.reportingTimeZoneDescription,
                expectation.reportingZone
            )
            XCTAssertEqual(
                differentZone.contextDescription,
                expectation.zonedContext
            )
        }
    }

    func testTodayContextShowsReportingZoneOnlyWhenDeviceZoneDiffers() throws {
        let singapore = try XCTUnwrap(TimeZone(identifier: "Asia/Singapore"))
        let losAngeles = try XCTUnwrap(
            TimeZone(identifier: "America/Los_Angeles")
        )

        XCTAssertFalse(
            DashboardReportingContextPolicy.shouldShowReportingTimeZone(
                reportingTimeZone: singapore,
                deviceTimeZone: singapore
            )
        )
        XCTAssertTrue(
            DashboardReportingContextPolicy.shouldShowReportingTimeZone(
                reportingTimeZone: singapore,
                deviceTimeZone: losAngeles
            )
        )
    }

    private func reportingContext(
        day: Int,
        language: AppLanguagePreference,
        deviceTimeZoneIdentifier: String
    ) throws -> TodayPeriodContextPresentation {
        let calendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: "Asia/Singapore"
        )
        let reportingDate = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 9,
                    day: day,
                    hour: 12
                )
            )
        )
        let deviceTimeZone = try XCTUnwrap(
            TimeZone(identifier: deviceTimeZoneIdentifier)
        )
        return try XCTUnwrap(
            TodayPeriodContextFormatter.presentation(
                reportingDate: reportingDate,
                reportingCalendar: calendar,
                locale: language.locale,
                deviceTimeZone: deviceTimeZone,
                localizedString: {
                    AppLocalization.string($0, language: language)
                }
            )
        )
    }

    func testTodayCashExcludesRestrictedAllowanceAssetsButKeepsDebt() throws {
        let sgd = try CurrencyCode("SGD")
        let cash = LedgerAccount(
            name: "Cash",
            kind: .asset,
            currency: sgd,
            accountType: .cash
        )
        let restrictedAllowance = LedgerAccount(
            name: "Meal benefit",
            kind: .asset,
            currency: sgd,
            accountType: .restrictedAllowance
        )
        let creditCard = LedgerAccount(
            name: "Card",
            kind: .liability,
            currency: sgd,
            accountType: .creditCard
        )

        XCTAssertTrue(DashboardAccountPolicy.isIncludedInCashAndDebt(cash))
        XCTAssertFalse(
            DashboardAccountPolicy.isIncludedInCashAndDebt(restrictedAllowance)
        )
        XCTAssertTrue(DashboardAccountPolicy.isIncludedInCashAndDebt(creditCard))
    }

    func testRestrictedSourceOnlyOffersItsOwningPrepaidPlan() throws {
        let sgd = try CurrencyCode("SGD")
        let restricted = LedgerAccount(
            name: "Meal wallet",
            kind: .asset,
            currency: sgd,
            accountType: .restrictedAllowance
        )
        let matching = try allowancePlan(
            currency: sgd,
            mode: .prepaidAsset,
            linkedAccountID: restricted.id
        )
        let mismatched = try allowancePlan(
            currency: sgd,
            mode: .prepaidAsset,
            linkedAccountID: UUID()
        )
        let benefit = try allowancePlan(
            currency: sgd,
            mode: .benefitLimit
        )

        XCTAssertTrue(
            QuickLogAllowanceSourcePolicy.planIsEligible(
                matching,
                for: restricted
            )
        )
        XCTAssertFalse(
            QuickLogAllowanceSourcePolicy.planIsEligible(
                mismatched,
                for: restricted
            )
        )
        XCTAssertFalse(
            QuickLogAllowanceSourcePolicy.planIsEligible(
                benefit,
                for: restricted
            )
        )
    }

    func testRestrictedSourceRequiresExactFullPrepaidCoverage() throws {
        let sgd = try CurrencyCode("SGD")
        let restricted = LedgerAccount(
            name: "Meal wallet",
            kind: .asset,
            currency: sgd,
            accountType: .restrictedAllowance
        )
        let plan = try allowancePlan(
            currency: sgd,
            mode: .prepaidAsset,
            linkedAccountID: restricted.id
        )
        let total = try Money(10, currency: sgd)

        XCTAssertFalse(QuickLogAllowanceSourcePolicy.canCommitExpense(
            sourceAccount: restricted,
            hasAllowanceSelection: false,
            selectedPlan: nil,
            total: total,
            application: nil
        ))
        XCTAssertFalse(QuickLogAllowanceSourcePolicy.canCommitExpense(
            sourceAccount: restricted,
            hasAllowanceSelection: true,
            selectedPlan: plan,
            total: total,
            application: try Money(4, currency: sgd)
        ))
        XCTAssertTrue(QuickLogAllowanceSourcePolicy.canCommitExpense(
            sourceAccount: restricted,
            hasAllowanceSelection: true,
            selectedPlan: plan,
            total: total,
            application: total
        ))
    }

    func testOrdinarySourceAllowsUncoveredOrSplitAllowanceExpense() throws {
        let sgd = try CurrencyCode("SGD")
        let cash = LedgerAccount(
            name: "Cash",
            kind: .asset,
            currency: sgd,
            accountType: .cash
        )
        let plan = try allowancePlan(
            currency: sgd,
            mode: .prepaidAsset,
            linkedAccountID: UUID()
        )
        let total = try Money(10, currency: sgd)

        XCTAssertTrue(QuickLogAllowanceSourcePolicy.canCommitExpense(
            sourceAccount: cash,
            hasAllowanceSelection: false,
            selectedPlan: nil,
            total: total,
            application: nil
        ))
        XCTAssertTrue(QuickLogAllowanceSourcePolicy.canCommitExpense(
            sourceAccount: cash,
            hasAllowanceSelection: true,
            selectedPlan: plan,
            total: total,
            application: try Money(4, currency: sgd)
        ))
        XCTAssertFalse(QuickLogAllowanceSourcePolicy.canCommitExpense(
            sourceAccount: cash,
            hasAllowanceSelection: true,
            selectedPlan: nil,
            total: total,
            application: nil
        ))
    }

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
            ReportingClockPolicy.nextRefresh(
                after: now,
                calendar: singapore
            )
        )
        let deviceBoundary = try XCTUnwrap(
            ReportingClockPolicy.nextRefresh(after: now, calendar: utc)
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
            ReportingClockPolicy.nextRefresh(
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
            ReportingClockPolicy.nextRefresh(
                after: now,
                calendar: singapore,
                scheduledOccurrences: [occurrence]
            )
        )

        XCTAssertEqual(refresh, occurrence.addingTimeInterval(1))
    }

    func testDashboardRefreshUsesEarlierRestrictedAllowanceChange() throws {
        let now = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-28T02:00:00Z")
        )
        let restrictedChange = now.addingTimeInterval(5 * 60)
        let laterSchedule = now.addingTimeInterval(15 * 60)
        let singapore = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: "Asia/Singapore"
        )

        XCTAssertEqual(
            ReportingClockPolicy.nextRefresh(
                after: now,
                calendar: singapore,
                scheduledOccurrences: [laterSchedule],
                restrictedAllowanceChange: restrictedChange
            ),
            restrictedChange
        )
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

    func testQuickLogKeyboardScrollTargetsEveryEditableDetailField() {
        let lineID = UUID()
        let fields: [QuickLogFieldFocus] = [
            .amount,
            .destinationAmount,
            .smartEntry,
            .payee,
            .note,
            .splitAmount(lineID),
            .splitMemo(lineID)
        ]

        for field in fields {
            XCTAssertEqual(QuickLogFocusScrollPolicy.target(for: field), field)
        }
        XCTAssertNil(QuickLogFocusScrollPolicy.target(for: nil))
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

        let instant = Date(timeIntervalSince1970: 1_788_406_140) // 2026-09-03 03:29Z
        let singapore = UserActionTimeContext(
            timeZone: TimeZone(identifier: "Asia/Singapore")!
        )
        let losAngeles = UserActionTimeContext(
            timeZone: TimeZone(identifier: "America/Los_Angeles")!
        )
        XCTAssertEqual(singapore.calendar.timeZone.identifier, "Asia/Singapore")
        XCTAssertEqual(singapore.calendar.component(.hour, from: instant), 11)
        XCTAssertEqual(losAngeles.calendar.component(.hour, from: instant), 20)
        XCTAssertTrue(singapore.displayName(at: instant).hasSuffix("GMT+8"))
        XCTAssertTrue(losAngeles.displayName(at: instant).hasSuffix("GMT-7"))
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

        let expense = LedgerAccount(name: "Food", kind: .expense)
        let income = LedgerAccount(name: "Salary", kind: .income)
        XCTAssertTrue(
            QuickLogSuggestionPolicy.receiptCategoryIsCompatible(
                expense,
                with: .refund
            )
        )
        XCTAssertFalse(
            QuickLogSuggestionPolicy.receiptCategoryIsCompatible(
                expense,
                with: .income
            )
        )
        XCTAssertTrue(
            QuickLogSuggestionPolicy.receiptCategoryIsCompatible(
                income,
                with: .income
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

    private func allowancePlan(
        currency: CurrencyCode,
        mode: AllowanceFundingMode,
        linkedAccountID: UUID? = nil
    ) throws -> AllowancePlan {
        try AllowancePlan(
            name: "Test allowance",
            amount: Money(100, currency: currency),
            cadence: .monthly,
            fundingMode: mode,
            linkedAccountID: linkedAccountID,
            startsAt: Date(timeIntervalSince1970: 1_700_000_000),
            timeZoneIdentifier: "UTC"
        )
    }
}
