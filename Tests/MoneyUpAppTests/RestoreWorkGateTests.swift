import Foundation
@testable import MoneyUp
import MoneyUpCore
import MoneyUpPersistence
import XCTest

final class RestoreWorkGateTests: XCTestCase {
    @MainActor
    func testRestorePreviewRejectsOversizedAllowanceArchiveTimelineBeforeLoad()
        async throws {
        let oversizedPayload = try JSONSerialization.data(withJSONObject: [
            "archiveTransitions": Array(
                repeating: [
                    "effectiveAt": 1,
                    "isArchived": true,
                ],
                count: AllowancePlan.maximumArchiveTransitionCount + 1
            ),
        ])

        try await assertRestorePreviewRejectsAllowancePayloadsBeforeLoad(
            [oversizedPayload],
            archiveName: "oversized-allowance-archive.moneyup"
        )
    }

    @MainActor
    func testRestorePreviewRejectsOversizedAllowanceReconciliationsBeforeLoad()
        async throws {
        let oversizedPayload = try JSONSerialization.data(withJSONObject: [
            "reconciliations": Array(
                repeating: [String: Any](),
                count: AllowancePlan.maximumReconciliationCount + 1
            ),
        ])

        try await assertRestorePreviewRejectsAllowancePayloadsBeforeLoad(
            [oversizedPayload],
            archiveName: "oversized-allowance-reconciliations.moneyup"
        )
    }

    @MainActor
    func testRestorePreviewRejectsPerPlanAllowancePeriodWorkBeforeLoad()
        async throws {
        let start = try utcDate(year: 2020, month: 1, day: 1)
        let payload = try allowancePeriodWorkPayload(
            start: start,
            dayOffset: RestoreCandidateValidator
                .maximumAllowancePeriodsPerPlan - 1
        )

        try await assertRestorePreviewRejectsAllowancePayloadsBeforeLoad(
            [payload],
            archiveName: "oversized-per-plan-allowance-periods.moneyup"
        )
    }

    @MainActor
    func testRestorePreviewRejectsAggregateAllowancePeriodWorkBeforeLoad()
        async throws {
        let start = try utcDate(year: 2020, month: 1, day: 1)
        let offsets = Array(repeating: 9_998, count: 9) + [9_999]
        let payloads = try offsets.map {
            try allowancePeriodWorkPayload(start: start, dayOffset: $0)
        }

        try await assertRestorePreviewRejectsAllowancePayloadsBeforeLoad(
            payloads,
            archiveName: "oversized-aggregate-allowance-periods.moneyup"
        )
    }

    private func utcDate(year: Int, month: Int, day: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        return try XCTUnwrap(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day
        )))
    }

    private func allowancePeriodWorkPayload(
        start: Date,
        dayOffset: Int
    ) throws -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let occurredAt = try XCTUnwrap(
            calendar.date(byAdding: .day, value: dayOffset, to: start)
        )
        return try JSONSerialization.data(withJSONObject: [
            "startsAt": start.timeIntervalSinceReferenceDate,
            "cadence": AllowanceCadence.daily.rawValue,
            "timeZoneIdentifier": "UTC",
            "usages": [[
                "occurredAt": occurredAt.timeIntervalSinceReferenceDate
            ]],
        ])
    }

    @MainActor
    private func assertRestorePreviewRejectsAllowancePayloadsBeforeLoad(
        _ allowancePayloads: [Data],
        archiveName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await fixture.seed(
            profile: profile,
            accounts: [fixture.wallet, fixture.food]
        )
        let liveBefore = try await fixture.store.snapshot().records
        let candidateURL = fixture.directoryURL.appendingPathComponent(
            archiveName
        )
        let password = "streaming-work-gate"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var records = [StoredRecordSnapshot(
            collection: RecordCollection.profile.rawValue,
            recordID: UserProfile.primaryRecordID,
            payload: try encoder.encode(profile),
            updatedAt: 1
        )]
        records += allowancePayloads.map { payload in
            StoredRecordSnapshot(
                collection: RecordCollection.allowancePlans.rawValue,
                recordID: UUID().uuidString,
                payload: payload,
                updatedAt: 1
            )
        }
        try PortableArchive.seal(
            DatabaseSnapshot(
                schemaVersion: EncryptedRecordStore.currentSchemaVersion,
                records: records
            ),
            password: password,
            to: candidateURL
        )
        let model = fixture.model(
            profile: profile,
            accounts: [fixture.wallet, fixture.food]
        )

        do {
            _ = try await model.prepareEncryptedRestorePreview(
                from: candidateURL,
                password: password
            )
            XCTFail(
                "Oversized nested restore work must fail before model load",
                file: file,
                line: line
            )
        } catch AppModelError.invalidBook {
            // These rows have only the lightweight count/date shape, not a
            // decodable AllowancePlan. The production raw SQL cursor rejects
            // their work before restore-domain decoding begins.
        }

        let liveAfter = try await fixture.store.snapshot().records
        XCTAssertEqual(liveAfter, liveBefore, file: file, line: line)
        XCTAssertEqual(model.state, .ready, file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: model.restoreValidationDirectoryURL.path
        ), file: file, line: line)
        await fixture.store.close()
    }
}
