import Foundation
import MoneyUpCore
import MoneyUpPersistence
@testable import MoneyUp
import XCTest

final class CaptureDuplicateReviewTests: XCTestCase {
    @MainActor
    func testIndexedReviewFindsBackdatedMatchOutsideRecentCacheAndExactUpperBoundary() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let now = Date(timeIntervalSince1970: 1_783_411_200)
        let queryDate = now.addingTimeInterval(-90 * 86_400)
        let boundary = try fixture.expense(amount: 12.34, occurredAt: queryDate.addingTimeInterval(86_400))
        let outside = try fixture.expense(amount: 12.34, occurredAt: queryDate.addingTimeInterval(86_401))
        let recent = try fixture.expense(amount: 12.34, occurredAt: now)
        let profile = UserProfile(baseCurrency: fixture.sgd, reportingTimeZoneIdentifier: "Asia/Singapore")
        try await fixture.seed(profile: profile, accounts: [fixture.wallet, fixture.food], entries: [boundary, outside, recent])
        let model = fixture.model(profile: profile, entries: [recent], retainsCompleteJournal: false, currentDate: { now })
        let query = try CaptureDuplicateQuery.expense(amount: Money(12.34, currency: fixture.sgd),
            paidFrom: fixture.wallet.id, category: fixture.food.id, occurredAt: queryDate, payee: "Cafe")
        XCTAssertTrue(CaptureDuplicateDetector.matches(for: query, in: model.entries).matches.isEmpty)
        let review = try await model.captureDuplicateReview(for: query)
        XCTAssertEqual(review?.match.entryID, boundary.id)
        XCTAssertEqual(review?.historyDate, boundary.originContext.attributedDate(in: model.reportingCalendar))
        XCTAssertEqual(model.entries, [recent], "Review must not expand or replace the UI cache")
        await fixture.store.close()
    }

    @MainActor
    func testSourceReplayOutsideTimeWindowStillRequiresExactCurrencyAndSystem() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let entry = try JournalEntry(kind: .expense, occurredAt: Date(timeIntervalSince1970: 1_000),
            payee: "Cafe", postings: [
                Posting(accountID: fixture.wallet.id, money: Money(-7, currency: fixture.sgd)),
                Posting(accountID: fixture.food.id, money: Money(7, currency: fixture.sgd))
            ], sourceSystem: "receipt-test", sourceFingerprint: "same-source")
        try await fixture.seed(profile: UserProfile(baseCurrency: fixture.sgd),
            accounts: [fixture.wallet, fixture.food], entries: [entry])
        let model = fixture.model(entries: [], retainsCompleteJournal: false)
        for (system, currency, matches) in [("receipt-test", fixture.sgd, true),
                                           ("different", fixture.sgd, false),
                                           ("receipt-test", fixture.usd, false)] {
            let query = try CaptureDuplicateQuery.expense(amount: Money(7, currency: currency),
                paidFrom: fixture.wallet.id, category: fixture.food.id, occurredAt: Date(),
                sourceReference: CaptureSourceReference(system: system, fingerprint: "same-source"))
            let result = try await model.captureDuplicateReview(for: query)
            XCTAssertEqual(result?.match.entryID, matches ? entry.id : nil)
        }
        await fixture.store.close()
    }

    @MainActor
    func testObsoleteReadCannotReturnAfterFinancialEditOrLock() async throws {
        for interruptWithLock in [false, true] {
            let fixture = try AppModelFixture()
            defer { fixture.removeFiles() }
            let entry = try fixture.expense(amount: 8)
            try await fixture.seed(profile: UserProfile(baseCurrency: fixture.sgd),
                accounts: [fixture.wallet, fixture.food], entries: [entry])
            let gate = JourneyReadGate()
            let model = fixture.model(entries: [entry], lifecycleHooks: AppModelLifecycleHooks {
                if $0 == .afterBookScopedReadBeforeReturn { await gate.pause() }
            })
            let query = try CaptureDuplicateQuery.expense(amount: Money(8, currency: fixture.sgd),
                paidFrom: fixture.wallet.id, category: fixture.food.id, occurredAt: entry.occurredAt)
            let read = Task { try await model.captureDuplicateReview(for: query) }
            await gate.waitUntilPaused()
            if interruptWithLock { model.lockManually() }
            else { model.invalidateInFlightJournalProjection() }
            await gate.resume()
            do { _ = try await read.value; XCTFail("Obsolete evidence escaped") }
            catch { XCTAssertTrue(error is CancellationError || error is AppModelError) }
            await model.waitForPendingStoreClose()
            await fixture.store.close()
        }
    }

    @MainActor
    func testTenThousandEntryReviewFindsOldestCandidateWithBoundedPages() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let start = Date(timeIntervalSince1970: 1_783_411_200)
        let entries = try (0..<10_000).map { index in
            try fixture.expense(amount: index == 0 ? 7.25 : 8.50,
                occurredAt: start.addingTimeInterval(Double(index)), payee: "Fixture")
        }
        try await fixture.seed(profile: UserProfile(baseCurrency: fixture.sgd),
            accounts: [fixture.wallet, fixture.food], entries: entries)
        let model = fixture.model(entries: Array(entries.suffix(80)), retainsCompleteJournal: false)
        let query = try CaptureDuplicateQuery.expense(amount: Money(7.25, currency: fixture.sgd),
            paidFrom: fixture.wallet.id, category: fixture.food.id, occurredAt: start, payee: "Fixture")
        var samples: [Double] = []
        for _ in 0..<5 {
            let clock = ContinuousClock()
            let began = clock.now
            let result = try await model.captureDuplicateReview(for: query)
            let elapsed = began.duration(to: clock.now).components
            samples.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
            XCTAssertEqual(result?.match.entryID, entries.first?.id)
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "operation": "duplicate_review_dense_window", "entry_count": 10_000,
            "page_size": 200, "sample_count": samples.count, "milliseconds": samples,
            "configuration": "Debug app tests; not a physical or Golden threshold result"
        ], options: [.sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "duplicate-review-10000.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(model.entries.count, 80)
        await fixture.store.close()
    }
}

actor JourneyReadGate {
    private var paused = false
    private var observer: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
        paused = true
        observer?.resume(); observer = nil
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilPaused() async {
        if !paused { await withCheckedContinuation { observer = $0 } }
    }
    func resume() { continuation?.resume(); continuation = nil }
}
