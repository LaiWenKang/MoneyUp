import Foundation
@testable import MoneyUpCore
import XCTest

final class LedgerAccountLifecycleTests: XCTestCase {
    func testLifecycleAuditRoundTripsHistoricalNameAndAffectedRecords() throws {
        let source = LedgerAccount(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Old groceries",
            kind: .expense,
            isArchived: true
        )
        let target = LedgerAccount(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "Food",
            kind: .expense
        )
        let affectedEntryID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000003"
        )!
        let audit = LedgerAccountLifecycleAudit(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            occurredAt: Date(timeIntervalSinceReferenceDate: 123),
            action: .merged,
            before: source,
            after: target,
            targetID: target.id,
            affectedJournalEntryIDs: [affectedEntryID]
        )

        let data = try JSONEncoder().encode(audit)
        let decoded = try JSONDecoder().decode(
            LedgerAccountLifecycleAudit.self,
            from: data
        )

        XCTAssertEqual(decoded, audit)
        XCTAssertEqual(decoded.before.name, "Old groceries")
        XCTAssertEqual(decoded.after?.name, "Food")
        XCTAssertEqual(decoded.affectedJournalEntryIDs, [affectedEntryID])
    }

    func testLifecycleAuditRejectsCombinedAffectedRecordOverflowOnEncodeAndDecode() throws {
        let source = LedgerAccount(name: "Source", kind: .expense)
        let oversized = LedgerAccountLifecycleAudit(
            action: .merged,
            before: source,
            after: nil,
            affectedJournalEntryIDs: Array(
                repeating: UUID(),
                count: LedgerAccountLifecycleAudit.maximumAffectedRecordCount
            ),
            affectedScheduleIDs: [UUID()]
        )
        XCTAssertThrowsError(try JSONEncoder().encode(oversized)) { error in
            XCTAssertEqual(
                error as? LedgerAccountLifecycleAuditValidationError,
                .tooManyAffectedRecords
            )
        }

        let baseline = LedgerAccountLifecycleAudit(
            action: .merged,
            before: source,
            after: nil
        )
        let encoded = try JSONEncoder().encode(baseline)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["affectedHoldingIDs"] = Array(
            repeating: UUID().uuidString,
            count: LedgerAccountLifecycleAudit.maximumAffectedRecordCount
        )
        object["affectedScheduleIDs"] = [UUID().uuidString]
        let crafted = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                LedgerAccountLifecycleAudit.self,
                from: crafted
            )
        ) { error in
            XCTAssertEqual(
                error as? LedgerAccountLifecycleAuditValidationError,
                .tooManyAffectedRecords
            )
        }
    }
}
