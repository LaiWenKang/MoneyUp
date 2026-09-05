@testable import MoneyUp
import Foundation
import MoneyUpCore
import XCTest

final class QuickLogPrepaidFundingPolicyTests: XCTestCase {
    func testPendingHistoricalResultMatchesEveryAuthorizationDimension() throws {
        let currency = try CurrencyCode("USD")
        let restrictedID = UUID()
        let occurredAt = Date(timeIntervalSince1970: 1_780_000_000)
        let plan = try AllowancePlan(
            name: "Meal card",
            amount: Money(20, currency: currency),
            cadence: .daily,
            fundingMode: .prepaidAsset,
            linkedAccountID: restrictedID,
            startsAt: occurredAt.addingTimeInterval(-3_600),
            timeZoneIdentifier: "UTC"
        )
        let changedPlan = try AllowancePlan(
            id: plan.id,
            name: "Changed meal card",
            amount: plan.amount,
            cadence: plan.cadence,
            fundingMode: plan.fundingMode,
            linkedAccountID: plan.linkedAccountID,
            startsAt: plan.startsAt,
            timeZoneIdentifier: plan.timeZoneIdentifier
        )
        let request = QuickLogPrepaidFundingRequest(
            plan: plan,
            sourceAccountID: restrictedID,
            occurredAt: occurredAt,
            journalProjectionRevision: 7,
            logicalBookRevision: 11
        )
        let expected = AllowanceRemainingAvailability.available(
            Money(15, currency: currency)
        )
        let load = QuickLogPrepaidFundingLoad(
            request: request,
            remaining: expected
        )

        XCTAssertEqual(
            QuickLogPrepaidFundingPresentationPolicy.remaining(
                load,
                matching: request
            ),
            expected
        )
        let staleRequests = [
            QuickLogPrepaidFundingRequest(
                plan: changedPlan,
                sourceAccountID: restrictedID,
                occurredAt: occurredAt,
                journalProjectionRevision: 7,
                logicalBookRevision: 11
            ),
            QuickLogPrepaidFundingRequest(
                plan: plan,
                sourceAccountID: UUID(),
                occurredAt: occurredAt,
                journalProjectionRevision: 7,
                logicalBookRevision: 11
            ),
            QuickLogPrepaidFundingRequest(
                plan: plan,
                sourceAccountID: restrictedID,
                occurredAt: occurredAt.addingTimeInterval(60),
                journalProjectionRevision: 7,
                logicalBookRevision: 11
            ),
            QuickLogPrepaidFundingRequest(
                plan: plan,
                sourceAccountID: restrictedID,
                occurredAt: occurredAt,
                journalProjectionRevision: 8,
                logicalBookRevision: 11
            ),
            QuickLogPrepaidFundingRequest(
                plan: plan,
                sourceAccountID: restrictedID,
                occurredAt: occurredAt,
                journalProjectionRevision: 7,
                logicalBookRevision: 12
            )
        ]
        for staleRequest in staleRequests {
            XCTAssertNil(QuickLogPrepaidFundingPresentationPolicy.remaining(
                load,
                matching: staleRequest
            ))
        }
    }

    func testSourcePolicyKeepsOrdinaryDeselectAndRestrictedFullCoverage() throws {
        let currency = try CurrencyCode("USD")
        let ordinary = LedgerAccount(
            name: "Wallet",
            kind: .asset,
            currency: currency,
            accountType: .cash
        )
        let restricted = LedgerAccount(
            name: "Meal card",
            kind: .asset,
            currency: currency,
            accountType: .restrictedAllowance
        )
        let plan = try AllowancePlan(
            name: "Meal card",
            amount: Money(20, currency: currency),
            cadence: .daily,
            fundingMode: .prepaidAsset,
            linkedAccountID: restricted.id,
            startsAt: Date(timeIntervalSince1970: 1_780_000_000),
            timeZoneIdentifier: "UTC"
        )
        let total = Money(20, currency: currency)

        XCTAssertTrue(QuickLogAllowanceSourcePolicy.canCommitExpense(
            sourceAccount: ordinary,
            hasAllowanceSelection: false,
            selectedPlan: nil,
            total: total,
            application: nil
        ))
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
            application: Money(19, currency: currency)
        ))
        XCTAssertTrue(QuickLogAllowanceSourcePolicy.canCommitExpense(
            sourceAccount: restricted,
            hasAllowanceSelection: true,
            selectedPlan: plan,
            total: total,
            application: total
        ))
    }
}
