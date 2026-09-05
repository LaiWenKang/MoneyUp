import Foundation
@testable import MoneyUpCore
import XCTest

final class AllowanceUsageMutationCoreTests: XCTestCase {
    func testReplaceAndRemoveTargetExactlyOneUnlinkedBenefitUsage() throws {
        let currency = try CurrencyCode("USD")
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let base = try AllowancePlan(
            name: "Meals",
            amount: Money(100, currency: currency),
            cadence: .daily,
            startsAt: start,
            timeZoneIdentifier: "UTC"
        )
        let usage = try AllowanceUsage(
            amount: Money(20, currency: currency),
            occurredAt: start.addingTimeInterval(60),
            policyRevisionID: base.policyRevisions[0].id
        )
        let plan = try base.addingUsage(usage)
        let replacement = try AllowanceUsage(
            id: usage.id,
            amount: Money(30, currency: currency),
            occurredAt: usage.occurredAt,
            note: "Corrected",
            policyRevisionID: usage.policyRevisionID
        )

        let replaced = try plan.replacingUsage(id: usage.id, with: replacement)
        XCTAssertEqual(replaced.usages, [replacement])
        XCTAssertEqual(replaced.usages.first?.id, usage.id)

        let removed = try replaced.removingUsage(id: usage.id)
        XCTAssertTrue(removed.usages.isEmpty)
        XCTAssertEqual(removed.policyRevisions, plan.policyRevisions)
    }

    func testMutationRejectsLinkedWrongIdentityAndNonBenefitUsage() throws {
        let currency = try CurrencyCode("USD")
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let linkedID = UUID()
        let base = try AllowancePlan(
            name: "Meals",
            amount: Money(100, currency: currency),
            cadence: .daily,
            startsAt: start,
            timeZoneIdentifier: "UTC"
        )
        let linked = try AllowanceUsage(
            amount: Money(20, currency: currency),
            occurredAt: start.addingTimeInterval(60),
            linkedJournalEntryID: linkedID,
            policyRevisionID: base.policyRevisions[0].id
        )
        let linkedPlan = try base.addingUsage(linked)

        XCTAssertThrowsError(try linkedPlan.removingUsage(id: linked.id))
        XCTAssertThrowsError(try linkedPlan.replacingUsage(
            id: linked.id,
            with: linked
        ))
        XCTAssertThrowsError(try base.removingUsage(id: UUID()))

        let reimbursement = try AllowancePlan(
            name: "Claims",
            amount: Money(100, currency: currency),
            cadence: .daily,
            fundingMode: .reimbursement,
            startsAt: start,
            timeZoneIdentifier: "UTC"
        )
        XCTAssertThrowsError(try reimbursement.removingUsage(id: UUID()))
    }
}
