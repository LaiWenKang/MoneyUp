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
}
