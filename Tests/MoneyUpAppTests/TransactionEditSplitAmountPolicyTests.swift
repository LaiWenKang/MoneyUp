import Foundation
@testable import MoneyUp
import MoneyUpCore
import XCTest

final class TransactionEditSplitAmountPolicyTests: XCTestCase {
    func testUnchangedLegacyPrecisionRemainsEditableAndBalanced() throws {
        let (entry, lines, currency) = try fixture()
        XCTAssertFalse(lines.allSatisfy { currency.supports($0.amount.amount) })
        XCTAssertTrue(accepts(lines, original: entry, currency: currency))
        XCTAssertNoThrow(try TransactionSplitCalculator.validate(
            total: Money(Decimal(string: "0.03")!, currency: currency),
            lines: lines
        ))
    }

    func testReorderingPreservesLineIdentity() throws {
        let (entry, lines, currency) = try fixture()
        XCTAssertTrue(accepts(Array(lines.reversed()), original: entry, currency: currency))
    }

    func testChangedLegacyAmountCannotBorrowAnotherLinesExemption() throws {
        let (entry, lines, currency) = try fixture()
        let swapped = [
            TransactionSplitLine(id: lines[0].id, categoryAccountID: lines[0].categoryAccountID,
                                 amount: lines[1].amount),
            TransactionSplitLine(id: lines[1].id, categoryAccountID: lines[1].categoryAccountID,
                                 amount: lines[0].amount)
        ]
        XCTAssertFalse(accepts(swapped, original: entry, currency: currency))
    }

    func testNewIdentityCannotPreserveLegacyPrecision() throws {
        let (entry, lines, currency) = try fixture()
        let newLines = lines.map {
            TransactionSplitLine(categoryAccountID: $0.categoryAccountID, amount: $0.amount)
        }
        XCTAssertFalse(accepts(newLines, original: entry, currency: currency))
    }

    func testCurrencyChangeCannotPreserveLegacyPrecision() throws {
        let (entry, lines, _) = try fixture()
        let eur = try CurrencyCode("EUR")
        let changed = try lines.map {
            TransactionSplitLine(id: $0.id, categoryAccountID: $0.categoryAccountID,
                                 amount: try Money($0.amount.amount, currency: eur))
        }
        XCTAssertFalse(accepts(changed, original: entry, currency: eur))
        XCTAssertFalse(accepts(lines, original: entry, currency: eur))
    }

    func testDuplicateLineIdentityIsRejected() throws {
        let (entry, lines, currency) = try fixture()
        XCTAssertFalse(accepts([lines[0], lines[0]], original: entry, currency: currency))
    }

    func testNewLinesUseCurrentPrecisionAndMaximum() throws {
        let (entry, _, currency) = try fixture()
        let valid = [
            TransactionSplitLine(categoryAccountID: UUID(), amount: try Money(1, currency: currency)),
            TransactionSplitLine(categoryAccountID: UUID(), amount: try Money(2, currency: currency))
        ]
        XCTAssertTrue(accepts(valid, original: entry, currency: currency))
        let tooLarge = TransactionSplitLine(
            categoryAccountID: UUID(),
            amount: try Money(MonetaryInputPolicy.maximumAbsoluteNewWrite + 1, currency: currency)
        )
        XCTAssertFalse(accepts([tooLarge], original: entry, currency: currency))
    }

    func testNegativeOriginalPostingPreservesIncomeAndRefundMagnitude() throws {
        let (_, lines, currency) = try fixture()
        let entry = try TransactionFactory.splitIncome(
            amount: Money(Decimal(string: "0.03")!, currency: currency),
            depositedInto: UUID(), splits: lines
        )
        XCTAssertTrue(accepts(lines, original: entry, currency: currency))
        let refund = try TransactionFactory.splitRefund(
            amount: Money(Decimal(string: "0.03")!, currency: currency),
            returnedTo: UUID(), splits: lines
        )
        XCTAssertTrue(accepts(lines, original: refund, currency: currency))
    }

    func testPreservationDoesNotBypassSplitBalanceOrPositivity() throws {
        let (entry, lines, currency) = try fixture()
        XCTAssertTrue(accepts(lines, original: entry, currency: currency))
        XCTAssertThrowsError(try TransactionSplitCalculator.validate(
            total: Money(Decimal(string: "0.04")!, currency: currency), lines: lines
        ))
        for invalidAmount in [Decimal.zero, Decimal(-1)] {
            let invalid = [
                TransactionSplitLine(categoryAccountID: UUID(),
                                     amount: try Money(invalidAmount, currency: currency)),
                TransactionSplitLine(categoryAccountID: UUID(),
                                     amount: try Money(1, currency: currency))
            ]
            XCTAssertThrowsError(try TransactionSplitCalculator.validate(
                total: Money(invalidAmount + 1, currency: currency), lines: invalid
            ))
        }
    }

    private func accepts(
        _ lines: [TransactionSplitLine], original: JournalEntry, currency: CurrencyCode
    ) -> Bool {
        TransactionEditSplitAmountPolicy.accepts(lines, currency: currency, preserving: original)
    }

    private func fixture() throws -> (JournalEntry, [TransactionSplitLine], CurrencyCode) {
        let currency = try CurrencyCode("USD")
        let lines = try ["0.001", "0.029"].map {
            TransactionSplitLine(categoryAccountID: UUID(),
                                 amount: try Money(Decimal(string: $0)!, currency: currency))
        }
        let entry = try TransactionFactory.splitExpense(
            amount: Money(Decimal(string: "0.03")!, currency: currency),
            paidFrom: UUID(), splits: lines
        )
        return (entry, lines, currency)
    }
}
