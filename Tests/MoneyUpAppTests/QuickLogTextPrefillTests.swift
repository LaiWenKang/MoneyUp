@testable import MoneyUp
import XCTest

/// Words said to Siri wait in one in-memory slot for the request that brought
/// them, and only that request can collect them.
final class QuickLogTextPrefillTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor
    func testWordsAreHeldTrimmedAndCollectedOnceByTheirOwnRequest() {
        let holder = QuickLogTextPrefill()
        let token = UUID()
        XCTAssertTrue(holder.hold("  coffee 4.50\n", for: token, now: now))
        XCTAssertEqual(holder.take(for: token, now: now), "coffee 4.50")
        XCTAssertNil(holder.take(for: token, now: now), "Words are handed over once")
    }

    @MainActor
    func testAnotherRequestCannotCollectTheWords() {
        let holder = QuickLogTextPrefill()
        let token = UUID()
        holder.hold("lunch 12.50", for: token, now: now)
        XCTAssertNil(holder.take(for: UUID(), now: now), "A widget or Home Screen Smart Entry must not pick them up")
        XCTAssertEqual(holder.take(for: token, now: now), "lunch 12.50", "The owner of the words still can")
    }

    @MainActor
    func testNothingIsHeldForBlankWords() {
        let holder = QuickLogTextPrefill()
        let token = UUID()
        XCTAssertFalse(holder.hold("", for: token, now: now))
        XCTAssertFalse(holder.hold(" \n\t ", for: token, now: now))
        XCTAssertNil(holder.take(for: token, now: now))
    }

    @MainActor
    func testWordsExpireAfterTheLifetime() {
        let holder = QuickLogTextPrefill()
        let token = UUID()
        holder.hold("coffee 4.50", for: token, now: now)
        let justBefore = now.addingTimeInterval(QuickLogTextPrefill.lifetime - 1)
        XCTAssertEqual(holder.take(for: token, now: justBefore), "coffee 4.50")

        holder.hold("coffee 4.50", for: token, now: now)
        let expired = now.addingTimeInterval(QuickLogTextPrefill.lifetime)
        XCTAssertNil(holder.take(for: token, now: expired))
        XCTAssertNil(holder.take(for: token, now: now), "Expired words are dropped, not kept")
    }

    @MainActor
    func testNewerWordsReplaceOlderOnesThatWereNeverCollected() {
        let holder = QuickLogTextPrefill()
        let first = UUID()
        let second = UUID()
        holder.hold("old words", for: first, now: now)
        holder.hold("new words", for: second, now: now)
        XCTAssertNil(holder.take(for: first, now: now))
        XCTAssertEqual(holder.take(for: second, now: now), "new words")
    }

    @MainActor
    func testDiscardingTakesBackOnlyTheWordsOfThatRequest() {
        let holder = QuickLogTextPrefill()
        let token = UUID()
        holder.hold("coffee 4.50", for: token, now: now)
        holder.discard(for: UUID())
        XCTAssertEqual(holder.take(for: token, now: now), "coffee 4.50")

        holder.hold("coffee 4.50", for: token, now: now)
        holder.discard(for: token)
        XCTAssertNil(holder.take(for: token, now: now))
    }

    @MainActor
    func testVeryLongWordsAreCutToTheLimit() throws {
        let holder = QuickLogTextPrefill()
        let token = UUID()
        holder.hold(String(repeating: "a", count: QuickLogTextPrefill.maximumCharacterCount + 200), for: token, now: now)
        let taken = try XCTUnwrap(holder.take(for: token, now: now))
        XCTAssertEqual(taken.count, QuickLogTextPrefill.maximumCharacterCount)
    }

    func testTheIntentCarriesOnlyTheWordsItWasGiven() {
        let intent = LogWithWordsIntent(words: "coffee 4.50")
        XCTAssertEqual(intent.words, "coffee 4.50")
    }

    @MainActor
    func testTheIntentRefusesBlankWordsWithoutAskingForAnyScreen() async {
        do {
            _ = try await LogWithWordsIntent(words: "   ").perform()
            XCTFail("Blank words must not open Smart Entry")
        } catch {
            XCTAssertTrue(error is LogWithWordsError, "\(error)")
        }
    }
}
