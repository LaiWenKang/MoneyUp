import Foundation
import MoneyUpCore
import MoneyUpPersistence
@testable import MoneyUp
import XCTest

final class DailyJourneyAcceptanceTests: XCTestCase {
    @MainActor
    func testDailyLoggingCorrectionPreparationSettingsAndReviewedRestore() async throws {
        for dailyCount in [5, 10] {
            let fixture = try AppModelFixture()
            defer { fixture.removeFiles() }
            let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-07T04:00:00Z"))
            let profile = UserProfile(baseCurrency: fixture.sgd, reportingTimeZoneIdentifier: "Asia/Singapore")
            let salary = LedgerAccount(name: "Salary", kind: .income)
            let accounts = [fixture.wallet, fixture.usAccount, fixture.food, salary]
            let node = BudgetNode(id: fixture.food.id, name: "Food", limit: try Money(1000, currency: fixture.sgd), purpose: .flexible)
            let month = try XCTUnwrap(FinancialPeriodBoundary.gregorianCalendar(timeZoneIdentifier: "Asia/Singapore").dateInterval(of: .month, for: now)?.start)
            let timeline = try BudgetConfigurationTimeline(currency: fixture.sgd,
                revisions: [BudgetConfigurationRevision(effectiveMonth: month, nodes: [node])])
            try await fixture.seed(profile: profile, accounts: accounts, budgetNodes: [node], budgetConfigurationTimeline: timeline)
            let model = fixture.model(profile: profile, accounts: accounts, budgetNodes: [node],
                retainsCompleteJournal: false, budgetConfigurationTimeline: timeline, currentDate: { now })
            try await model.reloadPersistedBookForTesting()
            _ = try await model.logIncome(amount: 1000, accountID: fixture.wallet.id, categoryID: salary.id, occurredAt: now, payee: nil, note: nil)
            var ids: [UUID] = []
            for index in 0..<dailyCount {
                let id = try await model.logExpense(amount: 10, accountID: fixture.wallet.id, categoryID: fixture.food.id,
                    occurredAt: now.addingTimeInterval(Double(index)), payee: "Daily fixture", note: nil)
                ids.append(try XCTUnwrap(id))
            }
            try await model.replaceEntry(id: try XCTUnwrap(ids.last), kind: .expense, amount: 20, destinationAmount: nil,
                accountID: fixture.wallet.id, destinationAccountID: nil, categoryID: fixture.food.id, occurredAt: now, payee: "Correction", note: nil)
            let corrected = try XCTUnwrap(model.entries.first { $0.supersedesID == ids.last })
            try await model.deleteEntry(id: corrected.id)
            let original = try XCTUnwrap(model.entries.first { $0.id == ids.first })
            let beforePreparation = model.journalEntryCount
            try await model.prepareTransaction(from: original, action: .repeatEntry, replacing: model.quickLogDraft)
            XCTAssertEqual(model.journalEntryCount, beforePreparation)
            try await model.prepareTransaction(from: original, action: .refund, replacing: model.quickLogDraft)
            XCTAssertEqual(model.quickLogDraft?.kind, .refund)
            _ = try await model.logRefund(amount: 5, accountID: fixture.wallet.id, categoryID: fixture.food.id, occurredAt: now, payee: nil, note: nil)
            _ = try await model.logExpense(amount: Decimal(string: "7.25")!, accountID: fixture.usAccount.id, categoryID: fixture.food.id, occurredAt: now, payee: nil, note: nil)
            try await model.updateAutoLockDelay(300)
            var draft = try XCTUnwrap(TransactionPreparationPolicy.draft(from: original, action: .repeatEntry, accounts: accounts, now: now))
            draft.amountText = "12."; draft.note = "Unfinished screenshot review"
            model.updateQuickLogDraft(draft)
            let expected = Decimal(1000 - (dailyCount - 1) * 10 + 5)
            try assertBook(model, fixture: fixture, balance: expected, draft: draft)
            let archive = fixture.directoryURL.appendingPathComponent("daily.moneyup")
            let password = "daily-journey-acceptance-password"
            try await model.encryptedBackup(to: archive, password: password)
            try await model.updateAutoLockDelay(60)
            let ticket = try await model.prepareEncryptedRestorePreview(from: archive, password: password)
            try await model.restoreEncryptedBackup(ticket, password: password)
            try assertBook(model, fixture: fixture, balance: expected, draft: draft)
            model.lockManually()
            await model.waitForPendingStoreClose()
            let reopened = try fixture.reopenStore()
            let restored = fixture.model(store: reopened, retainsCompleteJournal: false, currentDate: { now })
            try await restored.reloadPersistedBookForTesting()
            try assertBook(restored, fixture: fixture, balance: expected, draft: draft)
            await reopened.close()
        }
    }

    @MainActor
    func testTenThousandEntriesAtNormalDailyVolumeKeepBackdatedReviewBounded() async throws {
        var measurements: [[String: Any]] = []
        for dailyCount in [5, 10] {
            let fixture = try AppModelFixture()
            defer { fixture.removeFiles() }
            let calendar = FinancialPeriodBoundary.gregorianCalendar(timeZoneIdentifier: "Asia/Singapore")
            let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2020, month: 1, day: 1, hour: 9)))
            let entries = try (0..<10_000).map { index in
                let day = try XCTUnwrap(calendar.date(byAdding: .day, value: index / dailyCount, to: start))
                return try fixture.expense(amount: index == 1000 ? Decimal(string: "7.25")! : 10,
                    occurredAt: day.addingTimeInterval(Double(index % dailyCount) * 600), payee: "Daily fixture")
            }
            try await fixture.seed(profile: UserProfile(baseCurrency: fixture.sgd), accounts: [fixture.wallet, fixture.food], entries: entries)
            let model = fixture.model(entries: Array(entries.suffix(80)), retainsCompleteJournal: false)
            let query = try CaptureDuplicateQuery.expense(amount: Money(Decimal(string: "7.25")!, currency: fixture.sgd),
                paidFrom: fixture.wallet.id, category: fixture.food.id, occurredAt: entries[1000].occurredAt, payee: "Daily fixture")
            var milliseconds: [Double] = []
            for _ in 0..<5 {
                let start = ContinuousClock.now
                let result = try await model.captureDuplicateReview(for: query)
                let duration = start.duration(to: .now).components
                milliseconds.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
                XCTAssertEqual(result?.match.entryID, entries[1000].id)
            }
            XCTAssertEqual(model.entries.count, 80)
            measurements.append(["entries_per_day": dailyCount, "total_entries": 10000, "milliseconds": milliseconds])
            await fixture.store.close()
        }
        let evidence = XCTAttachment(data: try JSONSerialization.data(withJSONObject: measurements, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        evidence.name = "daily-volume-10000.json"; evidence.lifetime = .keepAlways; add(evidence)
    }

    @MainActor
    private func assertBook(_ model: AppModel, fixture: AppModelFixture, balance: Decimal, draft: QuickLogDraft) throws {
        XCTAssertEqual(model.displayBalanceResult(for: fixture.wallet).value?.amount, balance)
        XCTAssertEqual(model.displayBalanceResult(for: fixture.usAccount).value?.amount, Decimal(string: "-7.25"))
        let budget = try XCTUnwrap(model.budgetPlanSummaryThisMonthResult().value.flatMap { $0 })
        XCTAssertEqual(budget.remaining.amount, balance)
        XCTAssertEqual(model.quickLogDraft, draft)
        XCTAssertEqual(model.profile?.autoLockDelay, 300)
        XCTAssertTrue(model.recoveryIssues.isEmpty)
    }
}
