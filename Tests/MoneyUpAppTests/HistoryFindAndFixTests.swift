import Foundation
@testable import MoneyUp
import MoneyUpCore
import MoneyUpPersistence
import XCTest

/// History, round 3: a delete says everything it deletes, and a refresh after
/// an edit or a delete keeps the rows the person had reached. Search by
/// written amount and parent category is covered in `HistoryQueryTests`.
/// Fictional data only.
final class HistoryFindAndFixTests: XCTestCase {
    /// History and Calendar used the generic wording even when the expense
    /// carried a reimbursement claim, which the delete removes with it.
    @MainActor
    func testEveryDeleteConfirmationNamesALinkedClaim() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let occurredAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let plan = try AllowancePlan(
            name: "Travel claim",
            amount: Money(100, currency: fixture.sgd),
            cadence: .monthly,
            fundingMode: .reimbursement,
            startsAt: occurredAt.addingTimeInterval(-3_600),
            timeZoneIdentifier: "UTC",
            eligibleCategoryIDs: [fixture.food.id]
        )
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await fixture.seed(profile: profile, accounts: [fixture.wallet, fixture.food], allowancePlans: [plan])
        let model = fixture.model(
            profile: profile,
            accounts: [fixture.wallet, fixture.food],
            allowancePlans: [plan],
            currentDate: { occurredAt.addingTimeInterval(120) }
        )
        let claimed = try await model.logExpense(
            amount: 20, accountID: fixture.wallet.id, categoryID: fixture.food.id,
            occurredAt: occurredAt, payee: "Client lunch", note: nil, allowancePlanID: plan.id
        )
        let plain = try await model.logExpense(
            amount: 8, accountID: fixture.wallet.id, categoryID: fixture.food.id,
            occurredAt: occurredAt, payee: "Coffee", note: nil, allowancePlanID: nil
        )
        let claimedID = try XCTUnwrap(claimed)
        let plainID = try XCTUnwrap(plain)
        XCTAssertNotNil(
            model.allowancePlans.first?.usages.first { $0.linkedJournalEntryID == claimedID }?.claimStatus,
            "Logging against a reimbursement plan opens a claim"
        )

        XCTAssertTrue(model.hasLinkedAllowanceClaim(entryID: claimedID))
        XCTAssertFalse(model.hasLinkedAllowanceClaim(entryID: plainID))
        XCTAssertEqual(
            TransactionDeleteConfirmation.detailKey(for: claimedID, in: model),
            "allowance.claim.delete_confirmation_detail"
        )
        XCTAssertEqual(TransactionDeleteConfirmation.detailKey(for: plainID, in: model), "transaction.delete_detail")
        for language in [AppLanguagePreference.english, .simplifiedChinese] {
            let claimText = AppLocalization.string("allowance.claim.delete_confirmation_detail", language: language)
            XCTAssertNotEqual(claimText, "allowance.claim.delete_confirmation_detail", "\(language) has no wording")
        }

        // What the dialog now says is what the delete does.
        try await model.deleteEntry(id: claimedID)
        XCTAssertFalse(model.hasLinkedAllowanceClaim(entryID: claimedID))
        XCTAssertEqual(model.allowancePlans.first?.usages.isEmpty, true)
        await fixture.store.close()
    }

    /// After an edit or a delete, History used to reload one page of 80 rows,
    /// dropping the person from row 200 back to the end of page one.
    @MainActor
    func testRefreshReadsAsDeepAsTheRowsAlreadyLoaded() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let entries = try (0..<250).map { offset in
            try TransactionFactory.expense(
                amount: Money(Decimal(offset % 7 + 1), currency: fixture.sgd),
                paidFrom: fixture.wallet.id,
                category: fixture.food.id,
                occurredAt: Date(timeIntervalSinceReferenceDate: TimeInterval(offset * 60)),
                payee: "Grocer \(offset)"
            )
        }
        try await fixture.seed(
            profile: UserProfile(baseCurrency: fixture.sgd),
            accounts: [fixture.wallet, fixture.usAccount, fixture.food],
            entries: entries
        )
        let model = fixture.model(entries: entries)
        let query = HistoryQuery()

        // Three pages, as scrolling loads them.
        var scrolled: [JournalEntry] = []
        var cursor: JournalEntryPageCursor?
        for _ in 0..<3 {
            let page = try await model.historyPage(query: query, after: cursor)
            scrolled += page.entries
            cursor = page.nextCursor
        }
        XCTAssertEqual(scrolled.count, 240)

        let refreshed = try await model.historyPage(query: query, coveringAtLeast: scrolled.count)
        XCTAssertEqual(refreshed.entries.map(\.id), scrolled.map(\.id), "Same rows, same order")
        let refreshCursor = try XCTUnwrap(refreshed.nextCursor)
        let rest = try await model.historyPage(query: query, after: refreshCursor)
        XCTAssertEqual(rest.entries.count, 10, "Scrolling on continues where the refresh stopped")
        XCTAssertNil(rest.nextCursor)

        let firstVisit = try await model.historyPage(query: query, coveringAtLeast: 0)
        XCTAssertEqual(firstVisit.entries.count, 80, "A list nobody has scrolled is still one page")
        let everything = try await model.historyPage(query: query, coveringAtLeast: 1_000)
        XCTAssertEqual(everything.entries.count, 250)
        XCTAssertEqual(Set(everything.entries.map(\.id)).count, 250, "No row is read twice")
        XCTAssertNil(everything.nextCursor)

        // Deleting a row on page three keeps every other row the person had reached.
        let deleted = scrolled[200]
        try await model.deleteEntry(id: deleted.id)
        let afterDelete = try await model.historyPage(query: query, coveringAtLeast: scrolled.count)
        let kept = Set(afterDelete.entries.map(\.id))
        XCTAssertFalse(kept.contains(deleted.id))
        XCTAssertTrue(Set(scrolled.map(\.id)).subtracting([deleted.id]).isSubset(of: kept))
        await fixture.store.close()
    }
}
