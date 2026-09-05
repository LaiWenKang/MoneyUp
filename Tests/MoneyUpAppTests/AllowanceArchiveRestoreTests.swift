import Foundation
@testable import MoneyUp
import MoneyUpCore
import MoneyUpPersistence
import XCTest

final class AllowanceArchiveRestoreTests: XCTestCase {
    @MainActor
    func testAppModelPersistsArchiveAtUserActionWithoutRewritingHistory() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let archiveAt = start.addingTimeInterval(9 * 86_400)
        let plan = try AllowancePlan(
            name: "Meals",
            amount: Money(10, currency: fixture.sgd),
            cadence: .daily,
            startsAt: start,
            timeZoneIdentifier: "UTC"
        )
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await fixture.seed(
            profile: profile,
            accounts: [fixture.wallet, fixture.food],
            allowancePlans: [plan]
        )
        let model = fixture.model(
            profile: profile,
            accounts: [fixture.wallet, fixture.food],
            allowancePlans: [plan],
            currentDate: { archiveAt }
        )
        let historical = try plan.summary(
            asOf: start.addingTimeInterval(3_600)
        )
        let candidate = try AllowancePlan(
            id: plan.id,
            name: plan.name,
            amount: plan.amount,
            cadence: plan.cadence,
            startsAt: plan.startsAt,
            timeZoneIdentifier: plan.timeZoneIdentifier,
            isArchived: true
        )

        try await model.updateAllowancePlan(candidate)

        let updated = try XCTUnwrap(model.allowancePlans.first)
        XCTAssertTrue(updated.isArchived)
        XCTAssertEqual(updated.archiveTransitions.first?.effectiveAt, archiveAt)
        XCTAssertEqual(
            try updated.summary(asOf: start.addingTimeInterval(3_600)),
            historical
        )
        let persisted = try await fixture.store.fetch(
            AllowancePlan.self,
            id: plan.id.uuidString,
            from: .allowancePlans
        )
        XCTAssertEqual(persisted, updated)
        await fixture.store.close()
    }

    func testRestoreWorkLimitBoundsAllowanceArchiveTransitionsBeforeDomainDecode() throws {
        func snapshot(transitionCount: Int) throws -> DatabaseSnapshot {
            let payload = try JSONSerialization.data(withJSONObject: [
                "archiveTransitions": Array(
                    repeating: [String: Any](),
                    count: transitionCount
                )
            ])
            return DatabaseSnapshot(
                schemaVersion: EncryptedRecordStore.currentSchemaVersion,
                records: [StoredRecordSnapshot(
                    collection: RecordCollection.allowancePlans.rawValue,
                    recordID: UUID().uuidString,
                    payload: payload,
                    updatedAt: 1
                )]
            )
        }

        XCTAssertNoThrow(
            try RestoreCandidateValidator.validateSnapshotWorkLimits(
                snapshot(
                    transitionCount: AllowancePlan.maximumArchiveTransitionCount
                )
            )
        )
        XCTAssertThrowsError(
            try RestoreCandidateValidator.validateSnapshotWorkLimits(
                snapshot(
                    transitionCount:
                        AllowancePlan.maximumArchiveTransitionCount + 1
                )
            )
        ) { error in
            XCTAssertTrue(error is AppModelError)
        }
    }

    func testRestoreWorkLimitBoundsAllowanceReconciliationsBeforeDomainDecode()
    throws {
        func snapshot(reconciliationCount: Int) throws -> DatabaseSnapshot {
            let payload = try JSONSerialization.data(withJSONObject: [
                "reconciliations": Array(
                    repeating: [String: Any](),
                    count: reconciliationCount
                )
            ])
            return DatabaseSnapshot(
                schemaVersion: EncryptedRecordStore.currentSchemaVersion,
                records: [StoredRecordSnapshot(
                    collection: RecordCollection.allowancePlans.rawValue,
                    recordID: UUID().uuidString,
                    payload: payload,
                    updatedAt: 1
                )]
            )
        }

        XCTAssertNoThrow(
            try RestoreCandidateValidator.validateSnapshotWorkLimits(
                snapshot(
                    reconciliationCount:
                        AllowancePlan.maximumReconciliationCount
                )
            )
        )
        XCTAssertThrowsError(
            try RestoreCandidateValidator.validateSnapshotWorkLimits(
                snapshot(
                    reconciliationCount:
                        AllowancePlan.maximumReconciliationCount + 1
                )
            )
        ) { error in
            XCTAssertTrue(error is AppModelError)
        }
    }

    func testRestoreWorkLimitBoundsAggregateAllowanceReconciliations() throws {
        func snapshot(counts: [Int]) throws -> DatabaseSnapshot {
            DatabaseSnapshot(
                schemaVersion: EncryptedRecordStore.currentSchemaVersion,
                records: try counts.map { count in
                    StoredRecordSnapshot(
                        collection: RecordCollection.allowancePlans.rawValue,
                        recordID: UUID().uuidString,
                        payload: try JSONSerialization.data(withJSONObject: [
                            "reconciliations": Array(
                                repeating: [String: Any](),
                                count: count
                            )
                        ]),
                        updatedAt: 1
                    )
                }
            )
        }
        let maximumPerPlan = AllowancePlan.maximumReconciliationCount
        let fullPlanCount = RestoreCandidateValidator
            .maximumAllowanceReconciliationCount / maximumPerPlan
        let remainder = RestoreCandidateValidator
            .maximumAllowanceReconciliationCount % maximumPerPlan
        let boundary = Array(repeating: maximumPerPlan, count: fullPlanCount)
            + [remainder]

        XCTAssertNoThrow(
            try RestoreCandidateValidator.validateSnapshotWorkLimits(
                snapshot(counts: boundary)
            )
        )
        var excessive = boundary
        excessive[excessive.count - 1] += 1
        XCTAssertThrowsError(
            try RestoreCandidateValidator.validateSnapshotWorkLimits(
                snapshot(counts: excessive)
            )
        ) { error in
            XCTAssertTrue(error is AppModelError)
        }
    }

    func testRestoreWorkLimitBoundsAggregateAllowanceUsages() throws {
        func snapshot(counts: [Int]) throws -> DatabaseSnapshot {
            DatabaseSnapshot(
                schemaVersion: EncryptedRecordStore.currentSchemaVersion,
                records: try counts.map { count in
                    StoredRecordSnapshot(
                        collection: RecordCollection.allowancePlans.rawValue,
                        recordID: UUID().uuidString,
                        payload: try JSONSerialization.data(withJSONObject: [
                            "usages": Array(
                                repeating: [String: Any](),
                                count: count
                            )
                        ]),
                        updatedAt: 1
                    )
                }
            )
        }
        let maximumPerPlan = AllowancePlan.maximumUsageCount
        let fullPlanCount = RestoreCandidateValidator
            .maximumAllowanceUsageCount / maximumPerPlan
        let remainder = RestoreCandidateValidator
            .maximumAllowanceUsageCount % maximumPerPlan
        let boundary = Array(repeating: maximumPerPlan, count: fullPlanCount)
            + [remainder]
        XCTAssertEqual(
            boundary.reduce(0, +),
            RestoreCandidateValidator.maximumAllowanceUsageCount
        )

        XCTAssertNoThrow(
            try RestoreCandidateValidator.validateSnapshotWorkLimits(
                snapshot(counts: boundary)
            )
        )
        var excessive = boundary
        excessive[excessive.count - 1] += 1
        XCTAssertThrowsError(
            try RestoreCandidateValidator.validateSnapshotWorkLimits(
                snapshot(counts: excessive)
            )
        ) { error in
            XCTAssertTrue(error is AppModelError)
        }
    }

    func testRestoreWorkLimitBoundsAggregateAllowancePeriodWalks() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2020,
            month: 1,
            day: 1
        )))
        func snapshot(dayOffsets: [Int]) throws -> DatabaseSnapshot {
            DatabaseSnapshot(
                schemaVersion: EncryptedRecordStore.currentSchemaVersion,
                records: try dayOffsets.map { offset in
                    let occurredAt = try XCTUnwrap(
                        calendar.date(byAdding: .day, value: offset, to: start)
                    )
                    let payload = try JSONSerialization.data(withJSONObject: [
                        "startsAt": start.timeIntervalSinceReferenceDate,
                        "cadence": AllowanceCadence.daily.rawValue,
                        "timeZoneIdentifier": "UTC",
                        "usages": [[
                            "occurredAt": occurredAt.timeIntervalSinceReferenceDate
                        ]]
                    ])
                    return StoredRecordSnapshot(
                        collection: RecordCollection.allowancePlans.rawValue,
                        recordID: UUID().uuidString,
                        payload: payload,
                        updatedAt: 1
                    )
                }
            )
        }
        let boundary = Array(repeating: 9_998, count: 10)

        XCTAssertNoThrow(
            try RestoreCandidateValidator.validateSnapshotWorkLimits(
                snapshot(dayOffsets: boundary)
            )
        )
        var excessive = boundary
        excessive[excessive.count - 1] += 1
        XCTAssertThrowsError(
            try RestoreCandidateValidator.validateSnapshotWorkLimits(
                snapshot(dayOffsets: excessive)
            )
        ) { error in
            XCTAssertTrue(error is AppModelError)
        }
    }

    func testRestoreWorkLimitBoundsPerPlanCadenceDerivedPeriodWork() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2020,
            month: 1,
            day: 1
        )))
        func snapshot(dayOffset: Int) throws -> DatabaseSnapshot {
            let occurredAt = try XCTUnwrap(
                calendar.date(byAdding: .day, value: dayOffset, to: start)
            )
            let payload = try JSONSerialization.data(withJSONObject: [
                "startsAt": start.timeIntervalSinceReferenceDate,
                "cadence": AllowanceCadence.daily.rawValue,
                "timeZoneIdentifier": "UTC",
                "usages": [[
                    "occurredAt": occurredAt.timeIntervalSinceReferenceDate
                ]]
            ])
            return DatabaseSnapshot(
                schemaVersion: EncryptedRecordStore.currentSchemaVersion,
                records: [StoredRecordSnapshot(
                    collection: RecordCollection.allowancePlans.rawValue,
                    recordID: UUID().uuidString,
                    payload: payload,
                    updatedAt: 1
                )]
            )
        }
        // Daily work includes two conservative boundary periods, so an
        // offset of limit - 2 exercises the exact production ceiling.
        let boundaryDayOffset = RestoreCandidateValidator
            .maximumAllowancePeriodsPerPlan - 2

        XCTAssertNoThrow(
            try RestoreCandidateValidator.validateSnapshotWorkLimits(
                snapshot(dayOffset: boundaryDayOffset)
            )
        )
        XCTAssertThrowsError(
            try RestoreCandidateValidator.validateSnapshotWorkLimits(
                snapshot(dayOffset: boundaryDayOffset + 1)
            )
        ) { error in
            XCTAssertTrue(error is AppModelError)
        }
    }

    func testRestoreWorkLimitCountsWeekdayPeriodsInsteadOfCalendarDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2020,
            month: 1,
            day: 1
        )))
        let activityDay = try XCTUnwrap(
            calendar.date(byAdding: .day, value: 12_000, to: start)
        )
        XCTAssertEqual(calendar.component(.weekday, from: activityDay), 6)
        let currency = try CurrencyCode("SGD")
        let plan = try AllowancePlan(
            name: "Long-lived weekday allowance",
            amount: Money(1, currency: currency),
            cadence: .weekdays,
            startsAt: start,
            timeZoneIdentifier: "UTC",
            usages: [try AllowanceUsage(
                amount: Money(1, currency: currency),
                occurredAt: activityDay.addingTimeInterval(3_600)
            )]
        )
        let snapshot = DatabaseSnapshot(
            schemaVersion: EncryptedRecordStore.currentSchemaVersion,
            records: [StoredRecordSnapshot(
                collection: RecordCollection.allowancePlans.rawValue,
                recordID: plan.id.uuidString,
                payload: try JSONEncoder().encode(plan),
                updatedAt: 1
            )]
        )

        XCTAssertNoThrow(
            try RestoreCandidateValidator.validateSnapshotWorkLimits(snapshot)
        )
    }
}
