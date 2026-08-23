import Foundation
@testable import MoneyUpCore
import XCTest

final class LedgerAccountTests: XCTestCase {
    func testLegacyAccountWithoutSystemRoleStillDecodes() throws {
        let data = Data(
            #"{"id":"00000000-0000-0000-0000-000000000001","name":"Legacy","kind":"asset","isArchived":false}"#.utf8
        )

        let account = try JSONDecoder().decode(LedgerAccount.self, from: data)

        XCTAssertEqual(account.name, "Legacy")
        XCTAssertNil(account.systemRole)
    }
}
