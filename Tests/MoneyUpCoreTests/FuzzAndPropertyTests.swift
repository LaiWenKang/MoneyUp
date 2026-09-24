import Foundation
@testable import MoneyUpCore
import XCTest

/// Seeded, bounded fuzz and property checks. Every run uses the same seeds, so
/// a failure reproduces exactly; the seed is part of each assertion message.
final class FuzzAndPropertyTests: XCTestCase {
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Fragments that stress tokenisation: numbers in several notations,
    /// currencies, CJK, dates, punctuation, emoji, RTL, controls, and noise.
    private static let fragments = [
        "12", "12.50", "12,50", "1,234.56", "1.234,56", "0", "0.00", "-3", "+4", "007",
        "99999999999999999999999999", "1e9", "½", "٣٤", "１２３", ".", ",", "..", "  ",
        "SGD", "USD", "MYR", "JPY", "sgd", "S$", "$", "¥", "€", "RM", "£",
        "lunch", "coffee", "cash", "card", "wallet", "yesterday", "today", "tomorrow",
        "last week", "next friday", "3/4", "31/02", "2026-02-30", "午饭", "昨天", "支付宝",
        "花了", "给", "@", "#", "*", "\n", "\t", "\r\n", "🍜", "💳", "\u{202E}", "\u{0000}",
        "\u{FEFF}", "\"", "'", "\\", "income", "refund", "transfer", "to", "from", "×"
    ]

    private func randomText(_ rng: inout SplitMix64, maxPieces: Int = 12) -> String {
        let count = Int.random(in: 0...maxPieces, using: &rng)
        return (0..<count).map { _ in
            Self.fragments.randomElement(using: &rng) ?? ""
        }.joined(separator: Bool.random(using: &rng) ? " " : "")
    }

    private let fixedNow = Date(timeIntervalSince1970: 1_790_000_000)

    private func accounts() throws -> [LedgerAccount] {
        let sgd = try CurrencyCode("SGD")
        return [
            LedgerAccount(name: "Wallet", kind: .asset, currency: sgd),
            LedgerAccount(name: "Card", kind: .liability, currency: sgd),
            LedgerAccount(name: "Food", kind: .expense),
            LedgerAccount(name: "Salary", kind: .income)
        ]
    }

    func testSmartEntryNeverCrashesAndOnlyYieldsFinitePositiveAmounts() throws {
        let ledger = try accounts()
        var rng = SplitMix64(state: 0x5EED_0001)
        for iteration in 0..<600 {
            let text = randomText(&rng)
            let interpretation = SmartEntryInterpreter.interpret(text, accounts: ledger, now: fixedNow)
            if let amount = interpretation.parsed.draft.amount {
                XCTAssertFalse(amount.isNaN, "seed 1 #\(iteration): \(text.debugDescription)")
                XCTAssertGreaterThan(amount, 0, "seed 1 #\(iteration): \(text.debugDescription)")
            }
            let draft = NaturalLanguageEntryParser.draft(from: text, accounts: ledger, now: fixedNow)
            if let amount = draft.amount { XCTAssertFalse(amount.isNaN) }
        }
        let oversized = String(repeating: "lunch 12 ", count: SmartEntryInterpreter.maximumInputBytes / 8)
        XCTAssertTrue(SmartEntryInterpreter.interpret(oversized, accounts: ledger).issues.contains(.inputLimit))
    }

    func testReceiptParserToleratesArbitraryOCRLines() throws {
        let ledger = try accounts()
        var rng = SplitMix64(state: 0x5EED_0002)
        for iteration in 0..<300 {
            let lines = (0..<Int.random(in: 0...40, using: &rng)).map { _ in randomText(&rng, maxPieces: 6) }
            let result = ReceiptTextParser.analyze(fromLines: lines, now: fixedNow, accounts: ledger)
            if let amount = result.draft.amount {
                XCTAssertFalse(amount.isNaN, "seed 2 #\(iteration)")
                XCTAssertGreaterThan(amount, 0, "seed 2 #\(iteration)")
            }
        }
    }

    func testDelimitedImportRejectsOrBoundsEveryMalformedFile() {
        var rng = SplitMix64(state: 0x5EED_0003)
        let cells = ["Date", "Amount", "Payee", "2026-09-01", "12.50", "\"quoted, field\"", "\"",
                     "\"\"", "\"open", "", " ", "1,234.56", "-5", "abc", "午饭", "\u{FEFF}Date", "💳"]
        for iteration in 0..<300 {
            let rows = Int.random(in: 0...20, using: &rng)
            let text = (0...rows).map { _ in
                (0..<Int.random(in: 0...6, using: &rng)).map { _ in
                    cells.randomElement(using: &rng) ?? ""
                }.joined(separator: [",", ";", "\t"].randomElement(using: &rng) ?? ",")
            }.joined(separator: ["\n", "\r\n", "\r"].randomElement(using: &rng) ?? "\n")
            do {
                let preview = try TransactionCSVImporter.parse(text)
                XCTAssertLessThanOrEqual(preview.rows.count, rows + 1, "seed 3 #\(iteration)")
                for row in preview.rows {
                    XCTAssertFalse(row.amount.isNaN, "seed 3 #\(iteration)")
                    XCTAssertGreaterThanOrEqual(row.sourceLine, 1)
                }
            } catch {
                // A clear, typed rejection is an acceptable outcome for noise.
                continue
            }
        }
    }

    func testCheckedDecimalArithmeticLaws() throws {
        var rng = SplitMix64(state: 0x5EED_0004)
        func value() -> Decimal {
            let units = Int64.random(in: -1_000_000_000_000...1_000_000_000_000, using: &rng)
            let scale = Int16.random(in: 0...6, using: &rng)
            return Decimal(sign: units < 0 ? .minus : .plus, exponent: -Int(scale),
                           significand: Decimal(units.magnitude))
        }
        for iteration in 0..<500 {
            let a = value(), b = value()
            XCTAssertEqual(try CheckedDecimal.adding(a, b), try CheckedDecimal.adding(b, a), "#\(iteration)")
            XCTAssertEqual(try CheckedDecimal.subtracting(try CheckedDecimal.adding(a, b), b), a, "#\(iteration)")
            XCTAssertEqual(try CheckedDecimal.multiplying(a, 1), a)
            XCTAssertEqual(try CheckedDecimal.adding(a, 0), a)
        }
        XCTAssertThrowsError(try CheckedDecimal.dividing(1, 0))
        let huge = try XCTUnwrap(Decimal(string: "9e127", locale: Locale(identifier: "en_US_POSIX")))
        XCTAssertThrowsError(try CheckedDecimal.multiplying(huge, 10), "Overflow must throw, never wrap")
    }

    func testMoneyRejectsCrossCurrencyArithmeticAndKeepsTotals() throws {
        var rng = SplitMix64(state: 0x5EED_0005)
        let sgd = try CurrencyCode("SGD"), usd = try CurrencyCode("USD")
        var total = Money.zero(currency: sgd)
        var expected = Decimal.zero
        for _ in 0..<400 {
            let cents = Decimal(Int.random(in: 1...1_000_000, using: &rng)) / 100
            total = try total.adding(try Money(cents, currency: sgd))
            expected += cents
        }
        XCTAssertEqual(total.amount, expected, "Totals are conserved exactly")
        XCTAssertThrowsError(try total.adding(try Money(1, currency: usd)))
    }

    func testCurrencyCodeAcceptsOnlyItsDocumentedAlphabet() {
        var rng = SplitMix64(state: 0x5EED_0006)
        let alphabet = Array("ABCXYZsgdusd 1$-\u{0000}ÄÅ")
        for _ in 0..<500 {
            let raw = String((0..<Int.random(in: 0...5, using: &rng)).map { _ in
                alphabet.randomElement(using: &rng) ?? "A"
            })
            // Documented contract: 3-8 ASCII letters or digits, stored uppercased,
            // so digital-asset codes fit; nothing else may slip through.
            if let code = try? CurrencyCode(raw) {
                XCTAssertNotNil(code.value.range(of: "^[A-Z0-9]{3,8}$", options: .regularExpression),
                                "Accepted non-canonical code \(raw.debugDescription)")
                XCTAssertEqual(code.value, raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
            }
        }
    }

    func testProfileDecodingNeverTrustsMalformedFavouritesOrPins() throws {
        var rng = SplitMix64(state: 0x5EED_0007)
        let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            UserProfile(baseCurrency: try CurrencyCode("SGD"))
        )) as? [String: Any] ?? [:]
        let junk: [Any] = ["", String(repeating: "x", count: 500), 7, -1, NSNull(), [String: Any](),
                           UUID().uuidString, "not-a-uuid", 1e300, true]
        for iteration in 0..<300 {
            var object = base
            object["quickLogFavourites"] = (0..<Int.random(in: 0...30, using: &rng)).map { _ -> Any in
                var favourite: [String: Any] = ["id": UUID().uuidString, "name": "F", "kind": "expense"]
                for key in ["id", "name", "kind", "amount", "accountID", "payee", "note"]
                    where Bool.random(using: &rng) {
                    favourite[key] = junk.randomElement(using: &rng)
                }
                return favourite
            }
            object["pinnedBudgetNodeIDs"] = (0..<Int.random(in: 0...20, using: &rng)).map { _ in UUID().uuidString }
            guard let data = try? JSONSerialization.data(withJSONObject: object),
                  let profile = try? JSONDecoder().decode(UserProfile.self, from: data) else { continue }
            XCTAssertLessThanOrEqual(profile.quickLogFavourites.count, QuickLogFavourite.maximumCount, "#\(iteration)")
            XCTAssertTrue(profile.quickLogFavourites.allSatisfy {
                !$0.name.isEmpty && $0.name.count <= QuickLogFavourite.maximumNameLength
                    && ($0.amount.map { $0 > 0 } ?? true)
            }, "#\(iteration)")
            XCTAssertLessThanOrEqual(profile.pinnedBudgetNodeIDs.count, UserProfile.maximumPinnedBudgetNodes)
        }
    }

    func testFavouriteNormalizationIsIdempotentAndOrderPreserving() {
        var rng = SplitMix64(state: 0x5EED_0008)
        for _ in 0..<300 {
            let pool = (0..<Int.random(in: 0...8, using: &rng)).map { index in
                QuickLogFavourite(name: Bool.random(using: &rng) ? "  " : "F\(index)", kind: .expense)
            }
            let candidates = (0..<Int.random(in: 0...30, using: &rng)).compactMap { _ in
                pool.randomElement(using: &rng)
            }
            let once = QuickLogFavourite.normalized(candidates)
            XCTAssertEqual(QuickLogFavourite.normalized(once), once, "Normalizing twice must change nothing")
            let firstSeen = candidates.filter(\.isValid).reduce(into: [UUID]()) { ids, favourite in
                if !ids.contains(favourite.id) { ids.append(favourite.id) }
            }
            XCTAssertEqual(once.map(\.id), Array(firstSeen.prefix(QuickLogFavourite.maximumCount)))
        }
    }

    func testLedgerExportIsReadableByTheImporterInspector() throws {
        let sgd = try CurrencyCode("SGD")
        let wallet = LedgerAccount(name: "Wallet, \"main\"", kind: .asset, currency: sgd)
        let food = LedgerAccount(name: "Food\nand drink", kind: .expense)
        var rng = SplitMix64(state: 0x5EED_0009)
        let entries = try (0..<120).map { index in
            try TransactionFactory.expense(
                amount: Money(Decimal(Int.random(in: 1...99_999, using: &rng)) / 100, currency: sgd),
                paidFrom: wallet.id, category: food.id,
                occurredAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 977),
                payee: ["Kopi, \"tiam\"", "午饭", "=cmd|' /C calc'!A0", "tab\there"][index % 4]
            )
        }
        let csv = LedgerCSVExporter.export(entries, accounts: [wallet, food])
        let inspection = try TransactionCSVImporter.inspect(csv)
        XCTAssertFalse(inspection.headers.isEmpty, "Exported headers must be readable")
        XCTAssertLessThanOrEqual(inspection.sampleRows.count, 5)
        XCTAssertFalse(csv.contains("\n=cmd"), "Formula-like cells must not start a line unescaped")
    }

    func testNaturalLanguageParsingIsDeterministic() throws {
        let ledger = try accounts()
        var rng = SplitMix64(state: 0x5EED_000A)
        for _ in 0..<200 {
            let text = randomText(&rng)
            let first = NaturalLanguageEntryParser.draft(from: text, accounts: ledger, now: fixedNow)
            let second = NaturalLanguageEntryParser.draft(from: text, accounts: ledger, now: fixedNow)
            XCTAssertEqual(first, second, "Same input, same result: \(text.debugDescription)")
        }
    }

    /// Regression: Swift reads "\r\n" as a single Character, which once made
    /// every Windows-style CSV (Excel, banks, MoneyUp's own export) fail.
    func testCSVImportIsIdenticalForLFCRLFAndCRLineEndings() throws {
        let rows = [
            "Date,Amount,Payee,Note",
            "2026-09-01,12.50,Hawker,\"line one\nline two\"",
            "2026-09-02,3.20,\"Kopi, tiam\",",
            "2026-09-03,40,Taxi,late"
        ]
        let lf = try TransactionCSVImporter.inspect(rows.joined(separator: "\n"))
        for ending in ["\r\n", "\r"] {
            let other = try TransactionCSVImporter.inspect(rows.joined(separator: ending) + ending)
            XCTAssertEqual(other.headers, lf.headers, "Headers differ for \(ending.debugDescription)")
            XCTAssertEqual(other.sampleRows.count, lf.sampleRows.count, "Rows differ for \(ending.debugDescription)")
            XCTAssertEqual(other.sampleRows.map { $0.prefix(3) }, lf.sampleRows.map { $0.prefix(3) })
        }
    }
}
