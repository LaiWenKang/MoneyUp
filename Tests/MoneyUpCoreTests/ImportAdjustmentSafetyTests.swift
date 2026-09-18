import Foundation
import MoneyUpCore
import XCTest

final class ImportAdjustmentSafetyTests: XCTestCase {
    func testAmbiguousReimbursementIsNeverAssumedToBeIncomingMoney() throws {
        let input = "date,type,amount\n2026-09-18,报销,48.50\n2026-09-18,reimbursement,12.80\n2026-09-18,报销入账,40.00\n"
        let preview = try TransactionCSVImporter.parse(input)
        XCTAssertEqual(preview.rows.count, 1)
        XCTAssertEqual(preview.rows.first?.kind, .refund)
        XCTAssertEqual(preview.rows.first?.amount, 40)
        XCTAssertEqual(preview.issues.map(\.reason), ["unsupported_type", "unsupported_type"])
    }

    func testFeesAndCouponsCannotBeSilentlyDroppedByAutomaticOrManualMapping() throws {
        for column in ["fee", "coupon", "手续费", "优惠券"] {
            let csv = "date,type,amount,\(column)\n2026-09-18,expense,10,1\n2026-09-18,expense,10,0\n"
            let automatic = try TransactionCSVImporter.parse(csv)
            let mapping = CSVColumnMapping(columns: [.date: 0, .kind: 1, .amount: 2])
            let manual = try TransactionCSVImporter.parse(csv, mapping: mapping)
            for preview in [automatic, manual] {
                XCTAssertEqual(preview.rows.count, 1)
                XCTAssertEqual(preview.issues.first?.reason, "unsupported_adjustment")
            }
        }
    }
}
