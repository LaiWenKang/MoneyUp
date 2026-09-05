@testable import MoneyUp
import Foundation
import MoneyUpCore
import XCTest

final class AllowanceEditorAccountPolicyTests: XCTestCase {
    func testAddPickerExcludesAccountOwnedByActivePrepaidPlan() throws {
        let fixture = try Fixture()
        let owner = try fixture.plan(linkedAccountID: fixture.owned.id)
        let archivedOwner = try fixture.plan(
            linkedAccountID: fixture.archivedOwnerAccount.id,
            isArchived: true
        )

        let result = AllowanceEditorAccountPolicy.eligibleLinkedAccounts(
            from: fixture.accounts,
            plans: [owner, archivedOwner],
            editingPlanID: nil,
            currency: fixture.currency
        )

        XCTAssertEqual(Set(result.map(\.id)), [
            fixture.available.id,
            fixture.archivedOwnerAccount.id
        ])
    }

    func testEditPickerRetainsOwnAccountButExcludesOtherOwner() throws {
        let fixture = try Fixture()
        let edited = try fixture.plan(linkedAccountID: fixture.owned.id)
        let other = try fixture.plan(linkedAccountID: fixture.available.id)

        let result = AllowanceEditorAccountPolicy.eligibleLinkedAccounts(
            from: fixture.accounts,
            plans: [edited, other],
            editingPlanID: edited.id,
            currency: fixture.currency
        )

        XCTAssertEqual(Set(result.map(\.id)), [
            fixture.owned.id, fixture.archivedOwnerAccount.id
        ])
    }

    func testNameOnlyEditPreservesPlanZoneWhenProfileZoneDiffers() throws {
        let fixture = try Fixture()
        let existing = try fixture.plan(linkedAccountID: fixture.owned.id)
        let selectedZone = AllowanceEditorAccountPolicy.initialTimeZoneIdentifier(
            for: existing,
            newPlanDefault: "Asia/Singapore"
        )
        let candidate = try AllowancePlan(
            id: existing.id,
            name: "Renamed meals",
            amount: existing.amount,
            cadence: existing.cadence,
            fundingMode: existing.fundingMode,
            linkedAccountID: existing.linkedAccountID,
            startsAt: existing.startsAt,
            endsAt: existing.endsAt,
            timeZoneIdentifier: selectedZone,
            eligibleCategoryIDs: existing.eligibleCategoryIDs,
            rolloverRule: existing.rolloverRule,
            rolloverCap: existing.rolloverCap
        )

        let updated = try existing.applyingUpdate(
            candidate,
            effectiveAt: existing.startsAt.addingTimeInterval(3_600)
        )

        XCTAssertEqual(selectedZone, "UTC")
        XCTAssertEqual(updated.name, "Renamed meals")
        XCTAssertEqual(updated.timeZoneIdentifier, "UTC")
        XCTAssertEqual(updated.policyRevisions, existing.policyRevisions)
    }

    func testVisibleInclusiveEndUsesNextCivilDayAcrossDST() throws {
        let zone = "America/New_York"
        let visibleDate = try XCTUnwrap(Self.utcDate(2026, 3, 8, 12))

        let storedStart = try XCTUnwrap(AllowanceEditorDatePolicy.storedStart(
            fromVisibleDate: visibleDate,
            timeZoneIdentifier: zone
        ))
        let storedEnd = try XCTUnwrap(
            AllowanceEditorDatePolicy.storedExclusiveEnd(
                fromVisibleInclusiveDate: visibleDate,
                timeZoneIdentifier: zone
            )
        )
        let displayedEnd = try XCTUnwrap(
            AllowanceEditorDatePolicy.visibleInclusiveEnd(
                fromStoredExclusiveEnd: storedEnd,
                timeZoneIdentifier: zone
            )
        )
        let calendar = try XCTUnwrap(
            AllowanceEditorDatePolicy.calendar(timeZoneIdentifier: zone)
        )

        XCTAssertEqual(
            calendar.dateComponents([.year, .month, .day], from: storedStart),
            DateComponents(year: 2026, month: 3, day: 8)
        )
        XCTAssertEqual(
            calendar.dateComponents([.year, .month, .day], from: storedEnd),
            DateComponents(year: 2026, month: 3, day: 9)
        )
        XCTAssertEqual(storedEnd.timeIntervalSince(storedStart), 23 * 3_600)
        XCTAssertEqual(displayedEnd, storedStart)
    }

    func testZoneEditSchedulesFutureRevisionWithoutRewritingPriorZone() throws {
        let currency = try CurrencyCode("USD")
        let start = try XCTUnwrap(Self.utcDate(2026, 1, 1))
        let plan = try AllowancePlan(
            name: "Meals",
            amount: Money(20, currency: currency),
            cadence: .daily,
            startsAt: start,
            timeZoneIdentifier: "UTC"
        )
        let candidate = try AllowancePlan(
            id: plan.id,
            name: plan.name,
            amount: plan.amount,
            cadence: plan.cadence,
            startsAt: plan.startsAt,
            timeZoneIdentifier: "Asia/Singapore"
        )

        let updated = try plan.applyingUpdate(
            candidate,
            effectiveAt: start.addingTimeInterval(12 * 3_600)
        )

        XCTAssertEqual(updated.policyRevisions.count, 2)
        XCTAssertEqual(updated.policyRevisions[0].timeZoneIdentifier, "UTC")
        XCTAssertEqual(
            updated.policyRevisions[1].effectiveAt,
            start.addingTimeInterval(24 * 3_600)
        )
        XCTAssertEqual(
            updated.policyRevisions[1].timeZoneIdentifier,
            "Asia/Singapore"
        )
    }

    func testUsageEditorUsesRevisionCategoriesAndNormalizesStaleSelection() throws {
        let currency = try CurrencyCode("USD")
        let food = LedgerAccount(name: "Food", kind: .expense)
        let travel = LedgerAccount(name: "Travel", kind: .expense)
        let archived = LedgerAccount(
            name: "Old",
            kind: .expense,
            isArchived: true
        )
        let start = try XCTUnwrap(Self.utcDate(2026, 1, 1))
        let initial = try AllowancePlan(
            name: "Meals",
            amount: Money(20, currency: currency),
            cadence: .daily,
            startsAt: start,
            timeZoneIdentifier: "UTC",
            eligibleCategoryIDs: [food.id]
        )
        let candidate = try AllowancePlan(
            id: initial.id,
            name: initial.name,
            amount: initial.amount,
            cadence: initial.cadence,
            startsAt: initial.startsAt,
            timeZoneIdentifier: "Asia/Singapore",
            eligibleCategoryIDs: [travel.id]
        )
        let plan = try initial.applyingUpdate(
            candidate,
            effectiveAt: start.addingTimeInterval(12 * 3_600)
        )
        let categories = [food, travel, archived]

        let before = AllowanceUsageEditorPolicy.state(
            plan: plan,
            occurredAt: start.addingTimeInterval(15 * 3_600),
            availableCategories: categories,
            selectedCategoryID: travel.id
        )
        let after = AllowanceUsageEditorPolicy.state(
            plan: plan,
            occurredAt: start.addingTimeInterval(25 * 3_600),
            availableCategories: categories,
            selectedCategoryID: food.id
        )

        XCTAssertFalse(before.permitsGeneral)
        XCTAssertEqual(before.categories.map(\.id), [food.id])
        XCTAssertEqual(before.normalizedCategoryID, food.id)
        XCTAssertEqual(before.policy?.timeZoneIdentifier, "UTC")
        XCTAssertFalse(after.permitsGeneral)
        XCTAssertEqual(after.categories.map(\.id), [travel.id])
        XCTAssertEqual(after.normalizedCategoryID, travel.id)
        XCTAssertEqual(after.policy?.timeZoneIdentifier, "Asia/Singapore")
    }

    func testLegacyPartialDayBoundsRemainExactDuringEdit() throws {
        let currency = try CurrencyCode("USD")
        let start = try XCTUnwrap(Self.utcDate(2026, 9, 1, 12))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let end = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 30,
            hour: 15,
            minute: 30
        )))
        let plan = try AllowancePlan(
            name: "Legacy",
            amount: Money(20, currency: currency),
            cadence: .daily,
            startsAt: start,
            endsAt: end,
            timeZoneIdentifier: "UTC"
        )
        let candidate = try AllowancePlan(
            id: plan.id,
            name: "Renamed legacy",
            amount: plan.amount,
            cadence: plan.cadence,
            startsAt: plan.startsAt,
            endsAt: plan.endsAt,
            timeZoneIdentifier: plan.timeZoneIdentifier
        )

        let updated = try plan.applyingUpdate(
            candidate,
            effectiveAt: start.addingTimeInterval(60)
        )

        XCTAssertFalse(AllowanceEditorDatePolicy.isCivilDayBoundary(
            start,
            timeZoneIdentifier: "UTC"
        ))
        XCTAssertFalse(AllowanceEditorDatePolicy.isCivilDayBoundary(
            end,
            timeZoneIdentifier: "UTC"
        ))
        XCTAssertEqual(updated.startsAt, start)
        XCTAssertEqual(updated.endsAt, end)
    }

    func testUndoRequestRetainsEvidenceAfterPresentationStateClears() throws {
        let currency = try CurrencyCode("USD")
        let policyID = UUID()
        let planID = UUID()
        var presentationUsage: AllowanceUsage? = try AllowanceUsage(
            amount: Money(10, currency: currency),
            occurredAt: Date(timeIntervalSince1970: 1_780_000_000),
            policyRevisionID: policyID
        )
        let request = try XCTUnwrap(AllowanceUsageUndoPolicy.request(
            planID: planID,
            deletedUsage: presentationUsage
        ))

        presentationUsage = nil

        XCTAssertNil(presentationUsage)
        XCTAssertEqual(request.planID, planID)
        XCTAssertEqual(request.policyRevisionID, policyID)
        XCTAssertEqual(request.usage.amount.amount, 10)
    }
}

private extension AllowanceEditorAccountPolicyTests {
    static func utcDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 0
    ) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour
        ))
    }

    struct Fixture {
        let currency: CurrencyCode
        let owned: LedgerAccount
        let available: LedgerAccount
        let archivedOwnerAccount: LedgerAccount
        let accounts: [LedgerAccount]
        let startsAt = Date(timeIntervalSince1970: 1_700_000_000)

        init() throws {
            currency = try CurrencyCode("SGD")
            owned = Self.restricted(name: "Owned", currency: currency)
            available = Self.restricted(name: "Available", currency: currency)
            archivedOwnerAccount = Self.restricted(
                name: "Prior owner",
                currency: currency
            )
            accounts = [owned, available, archivedOwnerAccount]
        }

        func plan(
            linkedAccountID: UUID,
            isArchived: Bool = false
        ) throws -> AllowancePlan {
            try AllowancePlan(
                name: "Meals",
                amount: Money(20, currency: currency),
                cadence: .daily,
                fundingMode: .prepaidAsset,
                linkedAccountID: linkedAccountID,
                startsAt: startsAt,
                timeZoneIdentifier: "UTC",
                isArchived: isArchived
            )
        }

        private static func restricted(
            name: String,
            currency: CurrencyCode
        ) -> LedgerAccount {
            LedgerAccount(
                name: name,
                kind: .asset,
                currency: currency,
                accountType: .restrictedAllowance
            )
        }
    }
}
