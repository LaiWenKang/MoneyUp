import Foundation
import MoneyUpCore
import MoneyUpPersistence
import XCTest

final class JournalPostingMatchTests: XCTestCase {
    func testExactPostingFilterPreservesPrecisionCurrencyAndCursorBoundaries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try EncryptedRecordStore(databaseURL: directory.appendingPathComponent("fixture.db"),
            key: Data(repeating: 0x42, count: 32))
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountID = UUID()
        let categoryID = UUID()
        let sgd = try CurrencyCode("SGD")
        let usd = try CurrencyCode("USD")
        let kwd = try CurrencyCode("KWD")
        let now = Date(timeIntervalSince1970: 1_783_411_200)
        func entry(_ text: String, _ currency: CurrencyCode, source: String? = nil) throws -> JournalEntry {
            let money = try Money(try XCTUnwrap(Decimal(string: text)), currency: currency)
            return try JournalEntry(kind: .expense, occurredAt: now, postings: [
                Posting(accountID: accountID, money: money.negated),
                Posting(accountID: categoryID, money: money)
            ], sourceSystem: source == nil ? nil : "fixture", sourceFingerprint: source)
        }
        let first = try entry("2.00", sgd, source: "receipt")
        let second = try entry("2", sgd)
        let foreign = try entry("2", usd)
        let precise = try entry("999999999999999999.123", kwd)
        let different = try entry("999999999999999999.124", kwd)
        try await store.write([first, second, foreign, precise, different].map {
            try RecordWrite($0, id: $0.id.uuidString, in: .journalEntries)
        })
        let predicate = JournalPostingMatch(accountID: accountID, money: try Money(-2, currency: sgd))
        var ids: [UUID] = []
        var cursor: JournalEntryPageCursor?
        repeat {
            let page = try await store.fetchJournalEntryPage(startDate: now,
                endDateExclusive: now.addingTimeInterval(1), matchingPosting: predicate, after: cursor, limit: 1)
            XCTAssertTrue(page.issues.isEmpty)
            ids += page.entries.map(\.id)
            cursor = page.nextCursor
        } while cursor != nil
        XCTAssertEqual(Set(ids), [first.id, second.id])
        XCTAssertEqual(ids.count, 2)
        let source = try await store.fetchJournalEntryPage(sourceFingerprint: "receipt", matchingPosting: predicate)
        XCTAssertEqual(source.entries.map(\.id), [first.id])
        let large = try await store.fetchJournalEntryPage(matchingPosting: JournalPostingMatch(
            accountID: accountID, money: Money(try XCTUnwrap(Decimal(string: "-999999999999999999.123")), currency: kwd)))
        XCTAssertEqual(large.entries.map(\.id), [precise.id], "No REAL conversion or currency rounding")
        let wrongSign = try await store.fetchJournalEntryPage(matchingPosting: JournalPostingMatch(
            accountID: accountID, money: Money(2, currency: sgd)))
        XCTAssertTrue(wrongSign.entries.isEmpty)
        await store.close()
    }
}
