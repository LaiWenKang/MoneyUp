import CryptoKit
import Foundation
@testable import MoneyUpCore
import XCTest

/// Export speed-ups must not change a single byte. These digests were taken
/// from the exporters before they were optimized (2026-09-28), over a book
/// that exercises every escaping path: formula prefixes, quotes, ampersands,
/// angle brackets, apostrophes, control characters XML forbids, tabs and
/// newlines, emoji, Chinese text, splits, several currencies and FX rates.
final class LedgerExportGoldenTests: XCTestCase {
    func testCSVAndXLSXBytesAreUnchanged() throws {
        let book = try Self.goldenBook()
        let csv = LedgerCSVExporter.export(book.entries, accounts: book.accounts)
        let xlsx = LedgerXLSXExporter.export(entries: book.entries, accounts: book.accounts, rates: book.rates)
        XCTAssertEqual(Self.sha256(Data(csv.utf8)), Self.csvDigest)
        XCTAssertEqual(Self.sha256(xlsx), Self.xlsxDigest)
    }

    static let csvDigest = "a275cf86e74a4f0e8ff7c63c561989819d62dc5ee79917ee6097224dff161a89"
    static let xlsxDigest = "1437e71758e354dece6d5a8c88679be05d7849db68af8336c5da98edde2824dc"

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func goldenBook() throws -> (entries: [JournalEntry], accounts: [LedgerAccount], rates: [DatedExchangeRate]) {
        func id(_ value: Int) -> UUID {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
        }
        let sgd = try CurrencyCode("SGD")
        let usd = try CurrencyCode("USD")
        let jpy = try CurrencyCode("JPY")
        let texts = [
            "Plain", "=HYPERLINK(\"https://example.invalid\")", "+1 guest", "-refund", "@team",
            "Tom & Jerry's <Café> \"quoted\"", "Line\nbreak\r\nand\ttab", "Bell\u{07}and\u{0B}vertical",
            "Emoji 🍜☕️ and 👨‍👩‍👧", "街角咖啡 · 午餐", "  =padded", "Comma, separated", "",
            "Ampersand &amp; already", "Private use \u{E000} and \u{FFFD}", "Surrogate-plane 𝄞"
        ]
        let wallet = LedgerAccount(id: id(1), name: "Wallet & Cash", kind: .asset, currency: sgd)
        let card = LedgerAccount(id: id(2), name: "Card <Visa>", kind: .liability, currency: usd)
        let yen = LedgerAccount(id: id(3), name: "日本円", kind: .asset, currency: jpy)
        let food = LedgerAccount(id: id(4), name: "Food \"Dining\"", kind: .expense)
        let fun = LedgerAccount(id: id(5), name: "=Fun", kind: .expense, parentID: id(4), isArchived: true)
        let salary = LedgerAccount(id: id(6), name: "Salary", kind: .income)
        let accounts = [wallet, card, yen, food, fun, salary]
        let zones = ["Asia/Singapore", "America/New_York", "Asia/Tokyo"]
        var entries: [JournalEntry] = []
        for index in 0..<48 {
            let text = texts[index % texts.count]
            let occurredAt = Date(timeIntervalSince1970: 1_780_000_000 + TimeInterval(index * 9_973))
            let zone = zones[index % zones.count]
            let origin = TransactionOriginContext.capture(
                for: occurredAt,
                calendar: Calendar(identifier: .gregorian),
                timeZone: TimeZone(identifier: zone)!
            )
            let (currency, source) = [(sgd, wallet), (usd, card), (jpy, yen)][index % 3]
            let amount = currency == jpy ? Decimal(1_000 + index) : Decimal(string: "\(index + 1).\(index % 100)")!
            var postings = [
                Posting(id: id(1_000 + index * 3), accountID: source.id, money: try Money(-amount, currency: currency))
            ]
            if index.isMultiple(of: 4) {
                let half = amount / 2
                postings.append(Posting(id: id(1_001 + index * 3), accountID: food.id,
                                        money: try Money(half, currency: currency), memo: texts[(index + 3) % texts.count]))
                postings.append(Posting(id: id(1_002 + index * 3), accountID: fun.id,
                                        money: try Money(amount - half, currency: currency)))
            } else {
                postings.append(Posting(id: id(1_001 + index * 3), accountID: index.isMultiple(of: 7) ? salary.id : food.id,
                                        money: try Money(amount, currency: currency), memo: text))
            }
            entries.append(try JournalEntry(
                id: id(100 + index),
                kind: .expense,
                occurredAt: occurredAt,
                createdAt: occurredAt.addingTimeInterval(0.123),
                payee: text,
                note: texts[(index + 5) % texts.count],
                postings: postings,
                sourceSystem: index.isMultiple(of: 5) ? "csv & import" : nil,
                sourceFingerprint: index.isMultiple(of: 5) ? "fp<\(index)>" : nil,
                originContext: origin
            ))
        }
        let utc = TimeZone(secondsFromGMT: 0)!
        let rates = try (0..<5).map { index in
            try DatedExchangeRate(
                id: id(9_000 + index),
                baseCurrency: sgd,
                quoteCurrency: index.isMultiple(of: 2) ? usd : jpy,
                rate: Decimal(string: "0.7\(index)1")!,
                effectiveAt: Date(timeIntervalSince1970: 1_780_000_000 + TimeInterval(index * 86_400)),
                calendar: Calendar(identifier: .gregorian),
                timeZone: utc,
                createdAt: Date(timeIntervalSince1970: 1_780_000_000.5 + TimeInterval(index))
            )
        }
        return (entries, accounts, rates)
    }
}
