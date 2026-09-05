import Foundation
@testable import MoneyUpCore
import XCTest

final class LoanAllowancePacingTests: XCTestCase {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        if let utc = TimeZone(identifier: "UTC") {
            calendar.timeZone = utc
        }
        return calendar
    }

    private func allowanceCandidate(
        for plan: AllowancePlan,
        isArchived: Bool,
        amount: Money? = nil
    ) throws -> AllowancePlan {
        try AllowancePlan(
            id: plan.id,
            name: plan.name,
            amount: amount ?? plan.amount,
            cadence: plan.cadence,
            fundingMode: plan.fundingMode,
            linkedAccountID: plan.linkedAccountID,
            startsAt: plan.startsAt,
            endsAt: plan.endsAt,
            timeZoneIdentifier: plan.timeZoneIdentifier,
            eligibleCategoryIDs: plan.eligibleCategoryIDs,
            rolloverRule: plan.rolloverRule,
            rolloverCap: plan.rolloverCap,
            isArchived: isArchived
        )
    }

    func testRestrictedAllowanceIsNotUnrestrictedLiquidity() {
        XCTAssertFalse(FinancialAccountType.restrictedAllowance.isUnrestrictedLiquidity)
        XCTAssertTrue(FinancialAccountType.bank.isUnrestrictedLiquidity)
    }

    func testLoanPaymentIsBalancedAndSeparatesPrincipalInterestAndFees() throws {
        let currency = try CurrencyCode("MYR")
        let cashID = UUID()
        let loanID = UUID()
        let interestID = UUID()
        let feeID = UUID()
        let entry = try TransactionFactory.loanPayment(
            principal: try Money(350, currency: currency),
            interest: try Money(30, currency: currency),
            fees: try Money(8, currency: currency),
            paidFrom: cashID,
            loanAccountID: loanID,
            interestCategoryID: interestID,
            feeCategoryID: feeID
        )

        XCTAssertEqual(entry.sourceSystem, TransactionFactory.loanPaymentSource)
        XCTAssertEqual(entry.balanceByCurrency[currency], .zero)
        XCTAssertEqual(entry.postings.first { $0.accountID == cashID }?.money.amount, -388)
        XCTAssertEqual(entry.postings.first { $0.accountID == loanID }?.money.amount, 350)
        XCTAssertEqual(entry.postings.first { $0.accountID == interestID }?.money.amount, 30)
        XCTAssertEqual(entry.postings.first { $0.accountID == feeID }?.money.amount, 8)
    }

    func testLoanSummaryUsesLedgerPrincipalAndTracksActivityTotals() throws {
        let currency = try CurrencyCode("MYR")
        let zero = Money.zero(currency: currency)
        let activity = try LoanActivity(
            kind: .repayment,
            occurredAt: Date(timeIntervalSince1970: 200),
            principal: try Money(350, currency: currency),
            interest: try Money(30, currency: currency),
            fees: zero,
            journalEntryID: UUID()
        )
        let plan = try LoanPlan(
            accountID: UUID(),
            name: "Car loan",
            originalPrincipal: try Money(20_500, currency: currency),
            openedAt: Date(timeIntervalSince1970: 100),
            activities: [activity]
        )
        let summary = try plan.summary(
            currentPrincipal: try Money(15_285, currency: currency)
        )

        XCTAssertEqual(summary.remainingPrincipal.amount, 15_285)
        XCTAssertEqual(summary.totalPrincipalAdvanced.amount, 20_500)
        XCTAssertEqual(summary.principalPaid.amount, 5_215)
        XCTAssertEqual(summary.totalInterestPaid.amount, 30)
    }

    func testLegacyLoanAndAllowanceDecodeWithNeutralPurposes() throws {
        let currency = try CurrencyCode("SGD")
        let loan = try LoanPlan(
            accountID: UUID(),
            name: "Home",
            purpose: .home,
            originalPrincipal: try Money(100, currency: currency),
            openedAt: Date(timeIntervalSince1970: 100)
        )
        var loanObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(loan)) as? [String: Any]
        )
        loanObject.removeValue(forKey: "purpose")
        let decodedLoan = try JSONDecoder().decode(
            LoanPlan.self,
            from: JSONSerialization.data(withJSONObject: loanObject)
        )
        XCTAssertEqual(decodedLoan.purpose, .other)

        let allowance = try AllowancePlan(
            name: "Meal",
            amount: try Money(12, currency: currency),
            cadence: .daily,
            fundingMode: .prepaidAsset,
            linkedAccountID: UUID(),
            startsAt: Date(timeIntervalSince1970: 100)
        )
        var allowanceObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(allowance))
                as? [String: Any]
        )
        allowanceObject.removeValue(forKey: "fundingMode")
        allowanceObject.removeValue(forKey: "linkedAccountID")
        allowanceObject.removeValue(forKey: "policyRevisions")
        let decodedAllowance = try JSONDecoder().decode(
            AllowancePlan.self,
            from: JSONSerialization.data(withJSONObject: allowanceObject)
        )
        XCTAssertEqual(decodedAllowance.fundingMode, .benefitLimit)
        XCTAssertNil(decodedAllowance.linkedAccountID)
        XCTAssertEqual(decodedAllowance.policyRevisions.first?.id, allowance.id)
        let decodedAgain = try JSONDecoder().decode(
            AllowancePlan.self,
            from: JSONSerialization.data(withJSONObject: allowanceObject)
        )
        XCTAssertEqual(
            decodedAgain.policyRevisions.first?.id,
            decodedAllowance.policyRevisions.first?.id
        )
    }

    func testDailyAllowanceExpiresInsteadOfRollingOver() throws {
        let currency = try CurrencyCode("SGD")
        let start = try XCTUnwrap(
            utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 1))
        )
        let usage = try AllowanceUsage(
            amount: try Money(4, currency: currency),
            occurredAt: start.addingTimeInterval(3_600)
        )
        let plan = try AllowancePlan(
            name: "Meal allowance",
            amount: try Money(12, currency: currency),
            cadence: .daily,
            startsAt: start,
            timeZoneIdentifier: "UTC",
            rolloverRule: .none,
            usages: [usage]
        )

        XCTAssertEqual(try plan.summary(asOf: start.addingTimeInterval(7_200)).remaining.amount, 8)
        XCTAssertEqual(try plan.summary(asOf: start.addingTimeInterval(90_000)).remaining.amount, 12)
    }

    func testCappedAllowanceCarriesOnlyUpToConfiguredCap() throws {
        let currency = try CurrencyCode("SGD")
        let start = try XCTUnwrap(
            utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 1))
        )
        let plan = try AllowancePlan(
            name: "Meals",
            amount: try Money(10, currency: currency),
            cadence: .daily,
            startsAt: start,
            timeZoneIdentifier: "UTC",
            rolloverRule: .capped,
            rolloverCap: try Money(5, currency: currency)
        )

        XCTAssertEqual(
            try plan.summary(asOf: start.addingTimeInterval(90_000)).entitlement.amount,
            15
        )
    }

    func testAllowanceRejectsManualOveruse() throws {
        let currency = try CurrencyCode("SGD")
        let start = try XCTUnwrap(
            utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 1))
        )
        let plan = try AllowancePlan(
            name: "Meals",
            amount: try Money(10, currency: currency),
            cadence: .daily,
            startsAt: start,
            timeZoneIdentifier: "UTC"
        )
        let policyID = try XCTUnwrap(plan.policy(at: start)?.id)
        let usage = try AllowanceUsage(
            amount: try Money(11, currency: currency),
            occurredAt: start.addingTimeInterval(3_600),
            policyRevisionID: policyID
        )

        XCTAssertThrowsError(try plan.addingUsage(usage)) { error in
            XCTAssertEqual(error as? AllowancePlanError, .usageExceedsAvailable)
        }
    }

    func testAllowancePolicyUpdateKeepsPriorSummaryStable() throws {
        let currency = try CurrencyCode("SGD")
        let start = try XCTUnwrap(
            utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 1))
        )
        var plan = try AllowancePlan(
            name: "Meals",
            amount: try Money(10, currency: currency),
            cadence: .daily,
            startsAt: start,
            timeZoneIdentifier: "UTC"
        )
        plan = try plan.addingUsage(AllowanceUsage(
            amount: try Money(4, currency: currency),
            occurredAt: start.addingTimeInterval(3_600),
            policyRevisionID: plan.policy(at: start)?.id
        ))
        let candidate = try AllowancePlan(
            id: plan.id,
            name: "Meals",
            amount: try Money(20, currency: currency),
            cadence: .daily,
            startsAt: start,
            timeZoneIdentifier: "UTC"
        )
        let requestedAt = start.addingTimeInterval(6 * 3_600)
        let effectiveAt = start.addingTimeInterval(86_400)
        let updated = try plan.applyingUpdate(candidate, effectiveAt: requestedAt)

        XCTAssertEqual(
            try updated.summary(asOf: start.addingTimeInterval(7_200)).remaining.amount,
            6
        )
        XCTAssertEqual(
            try updated.summary(asOf: effectiveAt.addingTimeInterval(3_600)).remaining.amount,
            20
        )
        XCTAssertEqual(updated.policyRevisions.count, 2)
        XCTAssertEqual(updated.policyRevisions.last?.effectiveAt, effectiveAt)
    }

    func testEffectiveAllowanceWithoutActivitySchedulesPolicyUpdate() throws {
        let currency = try CurrencyCode("SGD")
        let start = try XCTUnwrap(
            utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 1))
        )
        let plan = try AllowancePlan(
            name: "Meals",
            amount: try Money(10, currency: currency),
            cadence: .daily,
            startsAt: start,
            timeZoneIdentifier: "UTC"
        )
        let originalPolicyID = try XCTUnwrap(plan.policyRevisions.first?.id)
        let updated = try plan.applyingUpdate(
            AllowancePlan(
                id: plan.id,
                name: plan.name,
                amount: try Money(20, currency: currency),
                cadence: .daily,
                startsAt: start,
                timeZoneIdentifier: "UTC"
            ),
            effectiveAt: start.addingTimeInterval(6 * 3_600)
        )

        XCTAssertEqual(updated.policyRevisions.count, 2)
        XCTAssertEqual(updated.policyRevisions.first?.id, originalPolicyID)
        XCTAssertEqual(updated.policyRevisions.first?.amount.amount, 10)
        XCTAssertEqual(
            updated.policyRevisions.last?.effectiveAt,
            start.addingTimeInterval(86_400)
        )
        XCTAssertEqual(updated.policyRevisions.last?.amount.amount, 20)
    }

    func testEffectiveNoActivityPolicyEditKeepsHistoricalSummaryStable() throws {
        let currency = try CurrencyCode("SGD")
        let start = try XCTUnwrap(
            utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 1))
        )
        let historicalInstant = start.addingTimeInterval(2 * 3_600)
        let plan = try AllowancePlan(
            name: "Meals",
            amount: try Money(10, currency: currency),
            cadence: .daily,
            startsAt: start,
            timeZoneIdentifier: "UTC"
        )
        let summaryBeforeEdit = try plan.summary(asOf: historicalInstant)
        let updated = try plan.applyingUpdate(
            AllowancePlan(
                id: plan.id,
                name: plan.name,
                amount: try Money(25, currency: currency),
                cadence: .daily,
                startsAt: start,
                timeZoneIdentifier: "UTC"
            ),
            effectiveAt: start.addingTimeInterval(12 * 3_600)
        )

        XCTAssertEqual(
            try updated.summary(asOf: historicalInstant),
            summaryBeforeEdit
        )
        XCTAssertEqual(
            try updated.summary(asOf: start.addingTimeInterval(90_000))
                .entitlement.amount,
            25
        )
    }

    func testAllowanceArchiveChangesAvailabilityAtExactInstantWithoutRewritingPast() throws {
        let currency = try CurrencyCode("SGD")
        let start = try XCTUnwrap(
            utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 1))
        )
        let archiveAt = start.addingTimeInterval(9 * 86_400 + 12 * 3_600)
        let historicalInstant = start.addingTimeInterval(36 * 3_600)
        let plan = try AllowancePlan(
            name: "Meals",
            amount: try Money(10, currency: currency),
            cadence: .daily,
            startsAt: start,
            timeZoneIdentifier: "UTC"
        )
        let historicalSummary = try plan.summary(asOf: historicalInstant)
        let archived = try plan.applyingUpdate(
            allowanceCandidate(for: plan, isArchived: true),
            effectiveAt: archiveAt
        )

        XCTAssertTrue(archived.isArchived)
        XCTAssertEqual(
            archived.archiveTransitions,
            [try AllowanceArchiveTransition(
                effectiveAt: archiveAt,
                isArchived: true
            )]
        )
        XCTAssertEqual(try archived.summary(asOf: historicalInstant), historicalSummary)
        XCTAssertTrue(
            try archived.summary(asOf: archiveAt.addingTimeInterval(-1))
                .isAvailableToday
        )
        for instant in [archiveAt, archiveAt.addingTimeInterval(1)] {
            let summary = try archived.summary(asOf: instant)
            XCTAssertFalse(summary.isAvailableToday)
            XCTAssertNil(summary.interval)
            XCTAssertEqual(summary.remaining.amount, .zero)
        }
    }

    func testAllowanceUnarchiveKeepsArchivedWindowAndReactivatesAtExactInstant() throws {
        let currency = try CurrencyCode("SGD")
        let start = try XCTUnwrap(
            utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 1))
        )
        let archiveAt = start.addingTimeInterval(9 * 86_400)
        let unarchiveAt = start.addingTimeInterval(11 * 86_400)
        let plan = try AllowancePlan(
            name: "Meals",
            amount: try Money(10, currency: currency),
            cadence: .daily,
            startsAt: start,
            timeZoneIdentifier: "UTC"
        )
        let archived = try plan.applyingUpdate(
            allowanceCandidate(for: plan, isArchived: true),
            effectiveAt: archiveAt
        )
        let unarchived = try archived.applyingUpdate(
            allowanceCandidate(for: archived, isArchived: false),
            effectiveAt: unarchiveAt
        )

        XCTAssertFalse(unarchived.isArchived)
        XCTAssertEqual(unarchived.archiveTransitions.map(\.effectiveAt), [archiveAt, unarchiveAt])
        XCTAssertEqual(unarchived.archiveTransitions.map(\.isArchived), [true, false])
        XCTAssertTrue(
            try unarchived.summary(asOf: archiveAt.addingTimeInterval(-1))
                .isAvailableToday
        )
        XCTAssertFalse(try unarchived.summary(asOf: archiveAt).isAvailableToday)
        XCTAssertFalse(
            try unarchived.summary(asOf: unarchiveAt.addingTimeInterval(-1))
                .isAvailableToday
        )
        XCTAssertTrue(try unarchived.summary(asOf: unarchiveAt).isAvailableToday)
        XCTAssertTrue(
            try unarchived.summary(asOf: unarchiveAt.addingTimeInterval(1))
                .isAvailableToday
        )
    }

    func testWhollyArchivedPeriodsDoNotAccrueFullOrCappedRollover() throws {
        let currency = try CurrencyCode("SGD")
        let start = try XCTUnwrap(
            utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 1))
        )
        let archiveAt = start.addingTimeInterval(86_400)
        let unarchiveAt = start.addingTimeInterval(3 * 86_400)
        let cases: [(AllowanceRolloverRule, Money?)] = [
            (.full, nil),
            (.capped, try Money(50, currency: currency))
        ]

        for (rollover, cap) in cases {
            let plan = try AllowancePlan(
                name: "Meals",
                amount: try Money(10, currency: currency),
                cadence: .daily,
                startsAt: start,
                timeZoneIdentifier: "UTC",
                rolloverRule: rollover,
                rolloverCap: cap
            )
            let archived = try plan.applyingUpdate(
                allowanceCandidate(for: plan, isArchived: true),
                effectiveAt: archiveAt
            )
            let unarchived = try archived.applyingUpdate(
                allowanceCandidate(for: archived, isArchived: false),
                effectiveAt: unarchiveAt
            )

            // Day one contributes one carried grant and the newly active day
            // contributes one current grant. The two paused days add nothing.
            XCTAssertEqual(
                try unarchived.summary(
                    asOf: unarchiveAt.addingTimeInterval(3_600)
                ).entitlement.amount,
                20
            )
        }
    }

    func testPrepaidExpirySkipsWhollyArchivedPeriods() throws {
        let currency = try CurrencyCode("SGD")
        let start = try XCTUnwrap(
            utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 1))
        )
        let archiveAt = start.addingTimeInterval(86_400)
        let unarchiveAt = start.addingTimeInterval(3 * 86_400)
        let asOf = start.addingTimeInterval(4 * 86_400)
        let plan = try AllowancePlan(
            name: "Meal card",
            amount: try Money(12, currency: currency),
            cadence: .daily,
            fundingMode: .prepaidAsset,
            linkedAccountID: UUID(),
            startsAt: start,
            timeZoneIdentifier: "UTC",
            rolloverRule: .none
        )
        let archived = try plan.applyingUpdate(
            allowanceCandidate(for: plan, isArchived: true),
            effectiveAt: archiveAt
        )
        let unarchived = try archived.applyingUpdate(
            allowanceCandidate(for: archived, isArchived: false),
            effectiveAt: unarchiveAt
        )
        let requirements = try unarchived.expiryRequirements(asOf: asOf)

        XCTAssertEqual(requirements.map(\.interval.start), [start, unarchiveAt])
        XCTAssertEqual(requirements.map(\.amount.amount), [12, 12])
    }

    func testSameInstantArchiveActionsCoalesceAndPolicyEditPreservesTimeline() throws {
        let currency = try CurrencyCode("SGD")
        let start = try XCTUnwrap(
            utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 1))
        )
        let transitionAt = start.addingTimeInterval(3 * 86_400 + 3_600)
        let plan = try AllowancePlan(
            name: "Meals",
            amount: try Money(10, currency: currency),
            cadence: .daily,
            startsAt: start,
            timeZoneIdentifier: "UTC"
        )
        let archived = try plan.applyingUpdate(
            allowanceCandidate(for: plan, isArchived: true),
            effectiveAt: transitionAt
        )
        let cancelled = try archived.applyingUpdate(
            allowanceCandidate(for: archived, isArchived: false),
            effectiveAt: transitionAt
        )
        XCTAssertFalse(cancelled.isArchived)
        XCTAssertTrue(cancelled.archiveTransitions.isEmpty)

        let rearchived = try cancelled.applyingUpdate(
            allowanceCandidate(for: cancelled, isArchived: true),
            effectiveAt: transitionAt
        )
        let timeline = rearchived.archiveTransitions
        let policyEdited = try rearchived.applyingUpdate(
            allowanceCandidate(
                for: rearchived,
                isArchived: true,
                amount: try Money(20, currency: currency)
            ),
            effectiveAt: transitionAt.addingTimeInterval(3_600)
        )

        XCTAssertEqual(policyEdited.archiveTransitions, timeline)
        XCTAssertEqual(policyEdited.archiveTransitions.count, 1)
        XCTAssertTrue(policyEdited.isArchived)
    }

    func testAllowanceArchiveTimelineRoundTripsAndLegacyArchiveStartsAtPlanStart() throws {
        let currency = try CurrencyCode("SGD")
        let start = try XCTUnwrap(
            utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 1))
        )
        let legacyArchived = try AllowancePlan(
            name: "Legacy meals",
            amount: try Money(10, currency: currency),
            cadence: .daily,
            startsAt: start,
            timeZoneIdentifier: "UTC",
            isArchived: true
        )
        let encoded = try JSONEncoder().encode(legacyArchived)
        XCTAssertEqual(
            try JSONDecoder().decode(AllowancePlan.self, from: encoded),
            legacyArchived
        )
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertNotNil(legacyObject["archiveTransitions"])
        legacyObject.removeValue(forKey: "archiveTransitions")
        legacyObject.removeValue(forKey: "archiveTimelineVersion")
        let decodedLegacy = try JSONDecoder().decode(
            AllowancePlan.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )

        XCTAssertTrue(decodedLegacy.isArchived)
        XCTAssertEqual(decodedLegacy.archiveTransitions.count, 1)
        XCTAssertEqual(decodedLegacy.archiveTransitions.first?.effectiveAt, start)
        XCTAssertEqual(decodedLegacy.archiveTransitions.first?.isArchived, true)
        XCTAssertFalse(try decodedLegacy.summary(asOf: start).isAvailableToday)
    }

    func testLegacyArchivedActivityMigratesImmediatelyAfterExactUsageInstant() throws {
        let currency = try CurrencyCode("SGD")
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let usageAt = start.addingTimeInterval(60)
        var plan = try AllowancePlan(
            name: "Legacy meals",
            amount: try Money(10, currency: currency),
            cadence: .daily,
            startsAt: start,
            timeZoneIdentifier: "UTC"
        )
        plan = try plan.addingUsage(AllowanceUsage(
            amount: try Money(2, currency: currency),
            occurredAt: usageAt,
            policyRevisionID: plan.policy(at: usageAt)?.id
        ))
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(plan))
                as? [String: Any]
        )
        legacyObject["isArchived"] = true
        legacyObject.removeValue(forKey: "archiveTransitions")
        legacyObject.removeValue(forKey: "archiveTimelineVersion")

        let decoded = try JSONDecoder().decode(
            AllowancePlan.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )
        let transition = try XCTUnwrap(decoded.archiveTransitions.first)

        XCTAssertEqual(
            transition.effectiveAt.timeIntervalSinceReferenceDate,
            usageAt.timeIntervalSinceReferenceDate.nextUp
        )
        XCTAssertTrue(try decoded.summary(asOf: usageAt).isAvailableToday)
        XCTAssertFalse(
            try decoded.summary(asOf: transition.effectiveAt).isAvailableToday
        )
    }

    func testLegacyArchivedReconciliationKeepsItsPeriodActiveThroughEnd() throws {
        let currency = try CurrencyCode("SGD")
        let start = utcCalendar.startOfDay(
            for: Date(timeIntervalSinceReferenceDate: 800_000_000)
        )
        let periodEnd = start.addingTimeInterval(86_400)
        var plan = try AllowancePlan(
            name: "Legacy meal card",
            amount: try Money(10, currency: currency),
            cadence: .daily,
            fundingMode: .prepaidAsset,
            linkedAccountID: UUID(),
            startsAt: start,
            timeZoneIdentifier: "UTC"
        )
        plan = try plan.recordingReconciliation(AllowanceReconciliation(
            policyRevisionID: try XCTUnwrap(plan.policy(at: start)?.id),
            periodStart: start,
            periodEnd: periodEnd,
            expired: .zero(currency: currency),
            recordedAt: periodEnd.addingTimeInterval(60),
            linkedJournalEntryID: nil
        ))
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(plan))
                as? [String: Any]
        )
        legacyObject["isArchived"] = true
        legacyObject.removeValue(forKey: "archiveTransitions")
        legacyObject.removeValue(forKey: "archiveTimelineVersion")

        let decoded = try JSONDecoder().decode(
            AllowancePlan.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )

        XCTAssertEqual(decoded.archiveTransitions.first?.effectiveAt, periodEnd)
        XCTAssertTrue(
            try decoded.summary(asOf: periodEnd.addingTimeInterval(-1))
                .isAvailableToday
        )
        XCTAssertFalse(try decoded.summary(asOf: periodEnd).isAvailableToday)
    }

    func testRecordingReconciliationRejectsWhollyArchivedPeriodInMemory() throws {
        let currency = try CurrencyCode("SGD")
        let start = utcCalendar.startOfDay(
            for: Date(timeIntervalSinceReferenceDate: 800_000_000)
        )
        let periodEnd = start.addingTimeInterval(86_400)
        let archived = try AllowancePlan(
            name: "Paused meal card",
            amount: try Money(10, currency: currency),
            cadence: .daily,
            fundingMode: .prepaidAsset,
            linkedAccountID: UUID(),
            startsAt: start,
            timeZoneIdentifier: "UTC",
            isArchived: true
        )
        let evidence = try AllowanceReconciliation(
            policyRevisionID: try XCTUnwrap(archived.policy(at: start)?.id),
            periodStart: start,
            periodEnd: periodEnd,
            expired: .zero(currency: currency),
            recordedAt: periodEnd,
            linkedJournalEntryID: nil
        )

        XCTAssertThrowsError(try archived.recordingReconciliation(evidence)) { error in
            XCTAssertEqual(error as? AllowancePlanError, .invalidPolicyRevision)
        }
    }

    func testCurrentArchivePayloadRejectsPartialDowngradeNullsAndEmptyState() throws {
        let currency = try CurrencyCode("SGD")
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let plan = try AllowancePlan(
            name: "Meals",
            amount: try Money(10, currency: currency),
            cadence: .daily,
            startsAt: start,
            timeZoneIdentifier: "UTC",
            isArchived: true
        )
        let current = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(plan))
                as? [String: Any]
        )
        var invalidPayloads: [[String: Any]] = []

        var missingTimeline = current
        missingTimeline.removeValue(forKey: "archiveTransitions")
        invalidPayloads.append(missingTimeline)
        var missingVersion = current
        missingVersion.removeValue(forKey: "archiveTimelineVersion")
        invalidPayloads.append(missingVersion)
        var nullTimeline = current
        nullTimeline["archiveTransitions"] = NSNull()
        invalidPayloads.append(nullTimeline)
        var nullState = current
        nullState["isArchived"] = NSNull()
        invalidPayloads.append(nullState)
        var missingState = current
        missingState.removeValue(forKey: "isArchived")
        invalidPayloads.append(missingState)
        var nullVersion = current
        nullVersion["archiveTimelineVersion"] = NSNull()
        invalidPayloads.append(nullVersion)
        var emptyArchivedTimeline = current
        emptyArchivedTimeline["archiveTransitions"] = []
        invalidPayloads.append(emptyArchivedTimeline)
        var unsupportedVersion = current
        unsupportedVersion["archiveTimelineVersion"] = 2
        invalidPayloads.append(unsupportedVersion)

        for payload in invalidPayloads {
            XCTAssertThrowsError(try JSONDecoder().decode(
                AllowancePlan.self,
                from: JSONSerialization.data(withJSONObject: payload)
            ))
        }
    }

    func testTamperedArchiveTimelineCannotReinterpretUsageOrReconciliation() throws {
        let currency = try CurrencyCode("SGD")
        let start = utcCalendar.startOfDay(
            for: Date(timeIntervalSinceReferenceDate: 800_000_000)
        )

        func payload(
            for plan: AllowancePlan,
            archivedAt: Date
        ) throws -> Data {
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(plan))
                    as? [String: Any]
            )
            let transition = try AllowanceArchiveTransition(
                effectiveAt: archivedAt,
                isArchived: true
            )
            object["isArchived"] = true
            object["archiveTransitions"] = [try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(transition)
            )]
            return try JSONSerialization.data(withJSONObject: object)
        }

        var withUsage = try AllowancePlan(
            name: "Meals",
            amount: try Money(10, currency: currency),
            cadence: .daily,
            startsAt: start,
            timeZoneIdentifier: "UTC"
        )
        let usageAt = start.addingTimeInterval(60)
        withUsage = try withUsage.addingUsage(AllowanceUsage(
            amount: try Money(2, currency: currency),
            occurredAt: usageAt,
            policyRevisionID: withUsage.policy(at: usageAt)?.id
        ))
        XCTAssertThrowsError(try JSONDecoder().decode(
            AllowancePlan.self,
            from: payload(for: withUsage, archivedAt: usageAt)
        ))

        var withReconciliation = try AllowancePlan(
            name: "Meal card",
            amount: try Money(10, currency: currency),
            cadence: .daily,
            fundingMode: .prepaidAsset,
            linkedAccountID: UUID(),
            startsAt: start,
            timeZoneIdentifier: "UTC"
        )
        let periodEnd = start.addingTimeInterval(86_400)
        withReconciliation = try withReconciliation.recordingReconciliation(
            AllowanceReconciliation(
                policyRevisionID: try XCTUnwrap(
                    withReconciliation.policy(at: start)?.id
                ),
                periodStart: start,
                periodEnd: periodEnd,
                expired: .zero(currency: currency),
                recordedAt: periodEnd,
                linkedJournalEntryID: nil
            )
        )
        XCTAssertThrowsError(try JSONDecoder().decode(
            AllowancePlan.self,
            from: payload(for: withReconciliation, archivedAt: start)
        ))
    }

    func testAllowanceArchiveTimelineRejectsInvalidOrderingStatesAndBounds() throws {
        let currency = try CurrencyCode("SGD")
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertThrowsError(try AllowanceArchiveTransition(
            effectiveAt: Date(timeIntervalSinceReferenceDate: .infinity),
            isArchived: true
        )) { error in
            XCTAssertEqual(error as? AllowancePlanError, .invalidDate)
        }
        let first = try AllowanceArchiveTransition(
            effectiveAt: start.addingTimeInterval(60),
            isArchived: true
        )
        let second = try AllowanceArchiveTransition(
            effectiveAt: start.addingTimeInterval(120),
            isArchived: false
        )
        let redundant = try AllowanceArchiveTransition(
            effectiveAt: start.addingTimeInterval(180),
            isArchived: false
        )

        for transitions in [[second, first], [first, second, redundant]] {
            XCTAssertThrowsError(try AllowancePlan(
                name: "Meals",
                amount: try Money(10, currency: currency),
                cadence: .daily,
                startsAt: start,
                timeZoneIdentifier: "UTC",
                isArchived: transitions.last?.isArchived ?? false,
                archiveTransitions: transitions
            ))
        }

        let excessive = try (0...AllowancePlan.maximumArchiveTransitionCount).map {
            try AllowanceArchiveTransition(
                effectiveAt: start.addingTimeInterval(Double($0 + 1)),
                isArchived: $0.isMultiple(of: 2)
            )
        }
        XCTAssertThrowsError(try AllowancePlan(
            name: "Meals",
            amount: try Money(10, currency: currency),
            cadence: .daily,
            startsAt: start,
            timeZoneIdentifier: "UTC",
            isArchived: excessive.last?.isArchived ?? false,
            archiveTransitions: excessive
        )) { error in
            XCTAssertEqual(error as? AllowancePlanError, .invalidPolicyRevision)
        }
    }

    func testEffectiveAllowanceRejectsEndDateChange() throws {
        let currency = try CurrencyCode("SGD")
        let start = try XCTUnwrap(
            utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 1))
        )
        let originalEnd = start.addingTimeInterval(3 * 86_400)
        let plan = try AllowancePlan(
            name: "Meals",
            amount: try Money(10, currency: currency),
            cadence: .daily,
            startsAt: start,
            endsAt: originalEnd,
            timeZoneIdentifier: "UTC"
        )
        let candidate = try AllowancePlan(
            id: plan.id,
            name: plan.name,
            amount: plan.amount,
            cadence: plan.cadence,
            startsAt: start,
            endsAt: originalEnd.addingTimeInterval(86_400),
            timeZoneIdentifier: "UTC"
        )

        XCTAssertThrowsError(try plan.applyingUpdate(
            candidate,
            effectiveAt: start.addingTimeInterval(3_600)
        )) { error in
            XCTAssertEqual(error as? AllowancePlanError, .invalidPolicyRevision)
        }
    }

    func testFutureUnstartedAllowanceWithoutActivityCanBeEditedDirectly() throws {
        let currency = try CurrencyCode("SGD")
        let editInstant = try XCTUnwrap(
            utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 1))
        )
        let originalStart = editInstant.addingTimeInterval(9 * 86_400)
        let revisedStart = originalStart.addingTimeInterval(2 * 86_400)
        let revisedEnd = revisedStart.addingTimeInterval(30 * 86_400)
        let restrictedAccountID = UUID()
        let plan = try AllowancePlan(
            name: "Meals",
            amount: try Money(10, currency: currency),
            cadence: .daily,
            startsAt: originalStart,
            timeZoneIdentifier: "UTC"
        )
        let updated = try plan.applyingUpdate(
            AllowancePlan(
                id: plan.id,
                name: "Meal card",
                amount: try Money(50, currency: currency),
                cadence: .monthly,
                fundingMode: .prepaidAsset,
                linkedAccountID: restrictedAccountID,
                startsAt: revisedStart,
                endsAt: revisedEnd,
                timeZoneIdentifier: "Asia/Singapore",
                rolloverRule: .full
            ),
            effectiveAt: editInstant
        )

        XCTAssertEqual(updated.policyRevisions.count, 1)
        XCTAssertEqual(updated.policyRevisions.first?.effectiveAt, revisedStart)
        XCTAssertEqual(updated.policyRevisions.first?.amount.amount, 50)
        XCTAssertEqual(updated.startsAt, revisedStart)
        XCTAssertEqual(updated.endsAt, revisedEnd)
        XCTAssertEqual(updated.fundingMode, .prepaidAsset)
        XCTAssertEqual(updated.linkedAccountID, restrictedAccountID)
        XCTAssertEqual(updated.cadence, .monthly)
    }

    func testAllowancePolicyRevisionPreservesPriorFullRolloverCarry() throws {
        let currency = try CurrencyCode("SGD")
        let start = try XCTUnwrap(
            utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 1))
        )
        var plan = try AllowancePlan(
            name: "Meals",
            amount: try Money(10, currency: currency),
            cadence: .daily,
            startsAt: start,
            timeZoneIdentifier: "UTC",
            rolloverRule: .full
        )
        plan = try plan.addingUsage(AllowanceUsage(
            amount: try Money(4, currency: currency),
            occurredAt: start.addingTimeInterval(3_600),
            policyRevisionID: plan.policy(at: start)?.id
        ))
        let candidate = try AllowancePlan(
            id: plan.id,
            name: plan.name,
            amount: try Money(20, currency: currency),
            cadence: .daily,
            startsAt: start,
            timeZoneIdentifier: "UTC",
            rolloverRule: .full
        )

        let updated = try plan.applyingUpdate(
            candidate,
            effectiveAt: start.addingTimeInterval(6 * 3_600)
        )

        XCTAssertEqual(
            try updated.summary(asOf: start.addingTimeInterval(90_000))
                .entitlement.amount,
            26
        )
    }

    func testSecondPreEffectivePolicyEditReplacesPendingAndCanCancelIt() throws {
        let currency = try CurrencyCode("SGD")
        let start = try XCTUnwrap(
            utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 1))
        )
        let editTime = start.addingTimeInterval(6 * 3_600)
        var plan = try AllowancePlan(
            name: "Meals",
            amount: try Money(10, currency: currency),
            cadence: .daily,
            startsAt: start,
            timeZoneIdentifier: "UTC"
        )
        plan = try plan.addingUsage(AllowanceUsage(
            amount: try Money(2, currency: currency),
            occurredAt: start.addingTimeInterval(3_600),
            policyRevisionID: plan.policy(at: start)?.id
        ))

        let firstCandidate = try AllowancePlan(
            id: plan.id,
            name: plan.name,
            amount: try Money(20, currency: currency),
            cadence: .daily,
            startsAt: start,
            timeZoneIdentifier: "UTC"
        )
        let futureUsageOnActivePolicy = try plan.addingUsage(AllowanceUsage(
            amount: try Money(1, currency: currency),
            occurredAt: start.addingTimeInterval(90_000)
        ))
        XCTAssertThrowsError(try futureUsageOnActivePolicy.applyingUpdate(
            firstCandidate,
            effectiveAt: editTime
        )) { error in
            XCTAssertEqual(error as? AllowancePlanError, .invalidPolicyRevision)
        }
        let firstUpdate = try plan.applyingUpdate(
            firstCandidate,
            effectiveAt: editTime
        )
        let replacedID = try XCTUnwrap(firstUpdate.policyRevisions.last?.id)

        let replacementCandidate = try AllowancePlan(
            id: plan.id,
            name: plan.name,
            amount: try Money(30, currency: currency),
            cadence: .daily,
            startsAt: start,
            timeZoneIdentifier: "UTC"
        )
        let replacement = try firstUpdate.applyingUpdate(
            replacementCandidate,
            effectiveAt: editTime.addingTimeInterval(60)
        )

        XCTAssertEqual(replacement.policyRevisions.count, 2)
        XCTAssertEqual(replacement.policy(at: editTime)?.amount.amount, 10)
        XCTAssertEqual(replacement.policyRevisions.last?.amount.amount, 30)
        XCTAssertEqual(
            replacement.policyRevisions.last?.effectiveAt,
            start.addingTimeInterval(86_400)
        )
        XCTAssertFalse(replacement.policyRevisions.contains { $0.id == replacedID })

        let activeCandidate = try AllowancePlan(
            id: plan.id,
            name: plan.name,
            amount: try Money(10, currency: currency),
            cadence: .daily,
            startsAt: start,
            timeZoneIdentifier: "UTC"
        )
        let cancelled = try replacement.applyingUpdate(
            activeCandidate,
            effectiveAt: editTime.addingTimeInterval(120)
        )

        XCTAssertEqual(cancelled.policyRevisions.count, 1)
        XCTAssertEqual(cancelled.policyRevisions.first?.id, plan.policyRevisions.first?.id)
        XCTAssertEqual(cancelled.amount.amount, 10)

        let activatedRevisionID = try XCTUnwrap(
            replacement.policyRevisions.last?.id
        )
        let followingCandidate = try AllowancePlan(
            id: plan.id,
            name: plan.name,
            amount: try Money(40, currency: currency),
            cadence: .daily,
            startsAt: start,
            timeZoneIdentifier: "UTC"
        )
        let afterActivation = try replacement.applyingUpdate(
            followingCandidate,
            effectiveAt: start.addingTimeInterval(86_400)
        )
        XCTAssertEqual(afterActivation.policyRevisions.count, 3)
        XCTAssertEqual(afterActivation.policyRevisions[1].id, activatedRevisionID)
        XCTAssertEqual(
            afterActivation.policyRevisions.last?.effectiveAt,
            start.addingTimeInterval(2 * 86_400)
        )
    }

    func testReferencedFuturePolicyCannotBeReplacedBeforeItBecomesEffective() throws {
        let currency = try CurrencyCode("SGD")
        let start = try XCTUnwrap(
            utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 1))
        )
        let editTime = start.addingTimeInterval(6 * 3_600)
        var plan = try AllowancePlan(
            name: "Meals",
            amount: try Money(10, currency: currency),
            cadence: .daily,
            startsAt: start,
            timeZoneIdentifier: "UTC"
        )
        plan = try plan.addingUsage(AllowanceUsage(
            amount: try Money(1, currency: currency),
            occurredAt: start.addingTimeInterval(3_600),
            policyRevisionID: plan.policy(at: start)?.id
        ))
        let scheduled = try plan.applyingUpdate(
            AllowancePlan(
                id: plan.id,
                name: plan.name,
                amount: try Money(20, currency: currency),
                cadence: .daily,
                startsAt: start,
                timeZoneIdentifier: "UTC"
            ),
            effectiveAt: editTime
        )
        let pending = try XCTUnwrap(scheduled.policyRevisions.last)
        let withFutureEvidence = try scheduled.addingUsage(AllowanceUsage(
            amount: try Money(2, currency: currency),
            occurredAt: pending.effectiveAt.addingTimeInterval(3_600)
        ))
        let replacementCandidate = try AllowancePlan(
            id: plan.id,
            name: plan.name,
            amount: try Money(30, currency: currency),
            cadence: .daily,
            startsAt: start,
            timeZoneIdentifier: "UTC"
        )

        XCTAssertThrowsError(try withFutureEvidence.applyingUpdate(
            replacementCandidate,
            effectiveAt: editTime.addingTimeInterval(60)
        )) { error in
            XCTAssertEqual(error as? AllowancePlanError, .invalidPolicyRevision)
        }
        XCTAssertEqual(withFutureEvidence.policyRevisions.last?.id, pending.id)
    }

    func testReimbursementClaimTransitionsAreForwardOnly() throws {
        let currency = try CurrencyCode("SGD")
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let usage = try AllowanceUsage(
            amount: try Money(10, currency: currency),
            occurredAt: start.addingTimeInterval(60)
        )
        let legacy = try AllowancePlan(
            name: "Travel claim",
            amount: try Money(100, currency: currency),
            cadence: .monthly,
            fundingMode: .reimbursement,
            startsAt: start,
            timeZoneIdentifier: "UTC",
            usages: [usage]
        )
        XCTAssertEqual(legacy.usages.first?.claimStatus, .pendingApproval)
        let approved = try legacy.updatingClaimStatus(
            usageID: usage.id,
            to: .approved
        )
        XCTAssertNoThrow(try approved.updatingClaimStatus(
            usageID: usage.id,
            to: .reimbursed
        ))
        let rejected = try legacy.updatingClaimStatus(
            usageID: usage.id,
            to: .rejected
        )
        XCTAssertThrowsError(try rejected.updatingClaimStatus(
            usageID: usage.id,
            to: .approved
        ))
    }

    func testAllowanceDecodeRejectsUsageOutsideEffectiveCategories() throws {
        let currency = try CurrencyCode("SGD")
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let eligibleID = UUID()
        let plan = try AllowancePlan(
            name: "Meals",
            amount: try Money(20, currency: currency),
            cadence: .daily,
            startsAt: start,
            timeZoneIdentifier: "UTC",
            eligibleCategoryIDs: [eligibleID],
            usages: [try AllowanceUsage(
                amount: try Money(5, currency: currency),
                occurredAt: start.addingTimeInterval(60),
                categoryID: eligibleID
            )]
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(plan))
                as? [String: Any]
        )
        var usages = try XCTUnwrap(object["usages"] as? [[String: Any]])
        usages[0]["categoryID"] = UUID().uuidString
        object["usages"] = usages

        XCTAssertThrowsError(try JSONDecoder().decode(
            AllowancePlan.self,
            from: JSONSerialization.data(withJSONObject: object)
        ))
    }

    func testLegacyAllowanceDecodeGrandfathersPriorInvalidActivityAsReadOnly() throws {
        let currency = try CurrencyCode("SGD")
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let categoryID = UUID()
        let firstEntryID = UUID()
        let secondEntryID = UUID()
        let plan = try AllowancePlan(
            name: "Legacy meals",
            amount: try Money(10, currency: currency),
            cadence: .daily,
            startsAt: start,
            timeZoneIdentifier: "UTC",
            eligibleCategoryIDs: [categoryID],
            usages: [try AllowanceUsage(
                amount: try Money(5, currency: currency),
                occurredAt: start.addingTimeInterval(60),
                categoryID: categoryID,
                linkedJournalEntryID: firstEntryID
            ), try AllowanceUsage(
                amount: try Money(5, currency: currency),
                occurredAt: start.addingTimeInterval(120),
                categoryID: categoryID,
                linkedJournalEntryID: secondEntryID
            )]
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(plan))
                as? [String: Any]
        )
        var usages = try XCTUnwrap(object["usages"] as? [[String: Any]])
        var money = try XCTUnwrap(usages[0]["amount"] as? [String: Any])
        money["amount"] = 20
        usages[0]["amount"] = money
        usages[0]["categoryID"] = UUID().uuidString
        usages[1]["linkedJournalEntryID"] = firstEntryID.uuidString
        object["usages"] = usages
        object.removeValue(forKey: "policyRevisions")
        object.removeValue(forKey: "hasGrandfatheredActivity")

        let decoded = try JSONDecoder().decode(
            AllowancePlan.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertTrue(decoded.hasGrandfatheredActivity)
        XCTAssertEqual(decoded.policyRevisions.first?.id, decoded.id)
        XCTAssertThrowsError(try decoded.addingUsage(AllowanceUsage(
            amount: try Money(1, currency: currency),
            occurredAt: start.addingTimeInterval(120)
        )))
        XCTAssertThrowsError(try decoded.removingUsages(linkedTo: firstEntryID))
        XCTAssertThrowsError(try decoded.replacingUsage(
            linkedTo: firstEntryID,
            with: nil
        ))
    }

    func testPrepaidExpiryRequirementIsIdempotentAndZoneBounded() throws {
        let currency = try CurrencyCode("SGD")
        let start = try XCTUnwrap(
            utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 1))
        )
        var plan = try AllowancePlan(
            name: "Meal card",
            amount: try Money(12, currency: currency),
            cadence: .daily,
            fundingMode: .prepaidAsset,
            linkedAccountID: UUID(),
            startsAt: start,
            timeZoneIdentifier: "UTC",
            rolloverRule: .none
        )
        let nextDay = try XCTUnwrap(
            utcCalendar.date(byAdding: .day, value: 1, to: start)
        )
        let requirement = try XCTUnwrap(plan.expiryRequirements(asOf: nextDay).first)
        XCTAssertEqual(requirement.interval.start, start)
        XCTAssertEqual(requirement.interval.end, nextDay)
        XCTAssertEqual(requirement.amount.amount, 12)

        plan = try plan.recordingReconciliation(AllowanceReconciliation(
            policyRevisionID: requirement.policyRevisionID,
            periodStart: requirement.interval.start,
            periodEnd: requirement.interval.end,
            expired: requirement.amount,
            recordedAt: nextDay,
            linkedJournalEntryID: UUID()
        ))
        XCTAssertTrue(try plan.expiryRequirements(asOf: nextDay).isEmpty)
    }

    func testAllowanceValidationHandlesMaximumDistinctUsagePeriods() throws {
        let currency = try CurrencyCode("SGD")
        let start = try XCTUnwrap(
            utcCalendar.date(from: DateComponents(year: 2020, month: 1, day: 1))
        )
        let usages = try (0..<AllowancePlan.maximumUsageCount).map { offset in
            let day = try XCTUnwrap(
                utcCalendar.date(byAdding: .day, value: offset, to: start)
            )
            return try AllowanceUsage(
                amount: Money(1, currency: currency),
                occurredAt: day.addingTimeInterval(3_600)
            )
        }

        XCTAssertNoThrow(try AllowancePlan(
            name: "Long-lived daily allowance",
            amount: Money(1, currency: currency),
            cadence: .daily,
            startsAt: start,
            timeZoneIdentifier: "UTC",
            rolloverRule: .none,
            usages: usages
        ))
    }

    func testAllowanceDecodePreservesCancellation() async throws {
        let currency = try CurrencyCode("SGD")
        let plan = try AllowancePlan(
            name: "Meals",
            amount: Money(10, currency: currency),
            cadence: .daily,
            startsAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            timeZoneIdentifier: "UTC"
        )
        let data = try JSONEncoder().encode(plan)
        let decode = Task<AllowancePlan, Error> {
            withUnsafeCurrentTask { task in task?.cancel() }
            return try JSONDecoder().decode(AllowancePlan.self, from: data)
        }

        do {
            _ = try await decode.value
            XCTFail("Cancelled allowance decoding must not finish normally.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testBudgetPacingUsesOneConservedMinorUnitAllocation() throws {
        let currency = try CurrencyCode("SGD")
        let asOf = try XCTUnwrap(
            utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 12))
        )
        let daily = try BudgetPaceCalculator.pace(
            remaining: try Money(310, currency: currency),
            cadence: .daily,
            asOf: asOf,
            calendar: utcCalendar
        )
        let weekly = try BudgetPaceCalculator.pace(
            remaining: try Money(310, currency: currency),
            cadence: .weekly,
            asOf: asOf,
            calendar: utcCalendar
        )

        XCTAssertEqual(daily.remainingDayCount, 29)
        // SGD 310.00 is 31,000 cents. Twenty-eight ordinary days receive
        // 1,068 cents; the final day receives 1,096 including the residual.
        XCTAssertEqual(daily.available.amount, Decimal(string: "10.68"))
        XCTAssertEqual(weekly.available.amount, Decimal(string: "74.76"))
    }

    func testPaceSpreadResolvesEveryCadenceFromOneInstant() throws {
        let currency = try CurrencyCode("SGD")
        let asOf = try XCTUnwrap(
            utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 12))
        )
        let remaining = try Money(310, currency: currency)
        let spread = try BudgetPaceCalculator.spread(
            remaining: remaining,
            asOf: asOf,
            calendar: utcCalendar
        )

        // The month bucket is the whole remainder; the shorter buckets are the
        // same figures the single-cadence calculator already produces.
        XCTAssertEqual(spread.monthly.available, remaining)
        XCTAssertEqual(spread.monthly.cadence, .monthly)
        XCTAssertEqual(
            spread.weekly.available,
            try BudgetPaceCalculator.pace(
                remaining: remaining,
                cadence: .weekly,
                asOf: asOf,
                calendar: utcCalendar
            ).available
        )
        XCTAssertEqual(
            spread.daily.available,
            try BudgetPaceCalculator.pace(
                remaining: remaining,
                cadence: .daily,
                asOf: asOf,
                calendar: utcCalendar
            ).available
        )
        for pace in [spread.monthly, spread.weekly, spread.daily] {
            XCTAssertEqual(pace.remainingDayCount, 29)
        }
        XCTAssertLessThanOrEqual(spread.daily.available.amount, spread.weekly.available.amount)
        XCTAssertLessThanOrEqual(spread.weekly.available.amount, spread.monthly.available.amount)
    }

    func testPaceSpreadCollapsesToOneDayOnTheFinalReportingDay() throws {
        let currency = try CurrencyCode("SGD")
        let asOf = try XCTUnwrap(
            utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 9))
        )
        let remaining = try Money(45, currency: currency)
        let spread = try BudgetPaceCalculator.spread(
            remaining: remaining,
            asOf: asOf,
            calendar: utcCalendar
        )

        // One day left means every horizon is the same money; a week bucket
        // must never reach past the month it belongs to.
        XCTAssertEqual(spread.monthly.available, remaining)
        XCTAssertEqual(spread.weekly.available, remaining)
        XCTAssertEqual(spread.daily.available, remaining)
        XCTAssertEqual(spread.daily.remainingDayCount, 1)
    }

    func testJPYResidualIsAssignedToTheFinalReportingDay() throws {
        let jpy = try CurrencyCode("JPY")
        let penultimateDay = try XCTUnwrap(
            utcCalendar.date(
                from: DateComponents(year: 2026, month: 8, day: 30, hour: 12)
            )
        )
        let firstSpread = try BudgetPaceCalculator.spread(
            remaining: try Money(101, currency: jpy),
            asOf: penultimateDay,
            calendar: utcCalendar
        )

        XCTAssertEqual(firstSpread.daily.available.amount, 50)
        XCTAssertEqual(firstSpread.weekly.available.amount, 101)
        XCTAssertEqual(firstSpread.monthly.available.amount, 101)

        let finalDay = try XCTUnwrap(
            utcCalendar.date(
                from: DateComponents(year: 2026, month: 8, day: 31, hour: 12)
            )
        )
        let finalSpread = try BudgetPaceCalculator.spread(
            remaining: try Money(51, currency: jpy),
            asOf: finalDay,
            calendar: utcCalendar
        )

        XCTAssertEqual(finalSpread.daily.available.amount, 51)
        XCTAssertEqual(
            try CheckedDecimal.adding(
                firstSpread.daily.available.amount,
                finalSpread.daily.available.amount
            ),
            101
        )
    }

    func testKWDResidualIsAssignedToTheFinalReportingDay() throws {
        let kwd = try CurrencyCode("KWD")
        let penultimateDay = try XCTUnwrap(
            utcCalendar.date(
                from: DateComponents(year: 2026, month: 8, day: 30, hour: 12)
            )
        )
        let firstSpread = try BudgetPaceCalculator.spread(
            remaining: try Money(
                Decimal(string: "1.001")!,
                currency: kwd
            ),
            asOf: penultimateDay,
            calendar: utcCalendar
        )

        XCTAssertEqual(
            firstSpread.daily.available.amount,
            Decimal(string: "0.500")
        )
        XCTAssertEqual(
            firstSpread.weekly.available.amount,
            Decimal(string: "1.001")
        )
        XCTAssertEqual(
            firstSpread.monthly.available.amount,
            Decimal(string: "1.001")
        )

        let finalDay = try XCTUnwrap(
            utcCalendar.date(
                from: DateComponents(year: 2026, month: 8, day: 31, hour: 12)
            )
        )
        let finalSpread = try BudgetPaceCalculator.spread(
            remaining: try Money(
                Decimal(string: "0.501")!,
                currency: kwd
            ),
            asOf: finalDay,
            calendar: utcCalendar
        )

        XCTAssertEqual(
            finalSpread.daily.available.amount,
            Decimal(string: "0.501")
        )
        XCTAssertEqual(
            try CheckedDecimal.adding(
                firstSpread.daily.available.amount,
                finalSpread.daily.available.amount
            ),
            Decimal(string: "1.001")
        )
    }

    func testBudgetPacingRejectsUnsupportedCurrencyPrecision() throws {
        let jpy = try CurrencyCode("JPY")
        let date = try XCTUnwrap(
            utcCalendar.date(
                from: DateComponents(year: 2026, month: 8, day: 30, hour: 12)
            )
        )

        XCTAssertThrowsError(
            try BudgetPaceCalculator.pace(
                remaining: try Money(
                    Decimal(string: "101.5")!,
                    currency: jpy
                ),
                cadence: .daily,
                asOf: date,
                calendar: utcCalendar
            )
        ) { error in
            XCTAssertEqual(
                error as? BudgetPaceError,
                .unsupportedCurrencyPrecision
            )
        }
    }

    func testReportingPeriodCountsLeapMonthCivilDays() throws {
        let date = try XCTUnwrap(
            utcCalendar.date(
                from: DateComponents(year: 2028, month: 2, day: 28, hour: 12)
            )
        )
        let period = try BudgetPaceCalculator.reportingPeriod(
            asOf: date,
            calendar: utcCalendar
        )

        XCTAssertEqual(period.startOfToday, utcCalendar.startOfDay(for: date))
        XCTAssertEqual(period.remainingDayCount, 2)
    }

    func testReportingPeriodUsesCivilDaysAcrossDST() throws {
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try XCTUnwrap(
            TimeZone(identifier: "America/Los_Angeles")
        )
        let date = try XCTUnwrap(
            losAngeles.date(
                from: DateComponents(year: 2026, month: 3, day: 8, hour: 12)
            )
        )
        let period = try BudgetPaceCalculator.reportingPeriod(
            asOf: date,
            calendar: losAngeles
        )

        XCTAssertEqual(period.remainingDayCount, 24)
        XCTAssertNotEqual(
            period.endOfMonth.timeIntervalSince(period.startOfToday),
            24 * 86_400
        )
    }

    func testHistorySummarySeparatesSpendIncomeAndRefunds() throws {
        let currency = try CurrencyCode("SGD")
        let cash = LedgerAccount(name: "Cash", kind: .asset, currency: currency)
        let food = LedgerAccount(name: "Food", kind: .expense)
        let salary = LedgerAccount(name: "Salary", kind: .income)
        let expense = try TransactionFactory.expense(
            amount: try Money(20, currency: currency),
            paidFrom: cash.id,
            category: food.id
        )
        let refund = try TransactionFactory.refund(
            amount: try Money(5, currency: currency),
            returnedTo: cash.id,
            category: food.id
        )
        let income = try TransactionFactory.income(
            amount: try Money(100, currency: currency),
            depositedInto: cash.id,
            category: salary.id
        )
        let summary = try HistoryQuery().summary(
            for: [expense, refund, income],
            accounts: [cash, food, salary]
        )

        XCTAssertEqual(summary.spendingByCurrency[currency], 20)
        XCTAssertEqual(summary.refundsByCurrency[currency], 5)
        XCTAssertEqual(summary.incomeByCurrency[currency], 100)
        XCTAssertEqual(summary.amountsByCurrency[currency], 85)
    }
}
