import Foundation
@testable import MoneyUpCore
import XCTest

final class LedgerEntryChoicesTests: XCTestCase {
    func testLegacyAccountsKeepVisibilityWithoutActivatingAnyPreset() throws {
        let original = LedgerAccount(name: "Existing", kind: .asset, currency: try CurrencyCode("SGD"))
        let bytes = try JSONEncoder().encode(original)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertNil(object["presetID"])
        XCTAssertNil(object["isHiddenFromEntry"])
        let decoded = try JSONDecoder().decode(LedgerAccount.self, from: bytes)
        XCTAssertFalse(decoded.isHiddenFromEntry)
        XCTAssertNil(decoded.presetID)
        XCTAssertEqual(LedgerEntryChoices.visible([decoded]), [original])
    }

    func testHiddenParentHidesDescendantsButPreservesAnExistingSelectionAndAncestors() {
        let root = LedgerAccount(name: "Home", kind: .expense, isHiddenFromEntry: true)
        let chosen = LedgerAccount(name: "Rent", kind: .expense, parentID: root.id)
        let sibling = LedgerAccount(name: "Water", kind: .expense, parentID: root.id)
        let other = LedgerAccount(name: "Food", kind: .expense)
        let all = [root, chosen, sibling, other]
        XCTAssertEqual(LedgerEntryChoices.visible(all).map(\.id), [other.id])
        XCTAssertEqual(LedgerEntryChoices.visible(all, preserving: [chosen.id]).map(\.id), [root.id, chosen.id, other.id])
        XCTAssertEqual(all[0].isHiddenFromEntry, true)
        XCTAssertFalse(chosen.isArchived)
    }

    func testVisibilityIsSafeForCyclesAndDeepTrees() {
        var first = LedgerAccount(name: "A", kind: .expense)
        let second = LedgerAccount(name: "B", kind: .expense, parentID: first.id)
        first.parentID = second.id
        XCTAssertTrue(LedgerEntryChoices.visible([first, second]).isEmpty)
        var nodes: [LedgerAccount] = []
        for index in 0..<5_000 {
            nodes.append(LedgerAccount(name: String(index), kind: .expense, parentID: nodes.last?.id))
        }
        XCTAssertEqual(LedgerEntryChoices.visible(nodes).count, nodes.count)
        nodes[0].isHiddenFromEntry = true
        XCTAssertTrue(LedgerEntryChoices.visible(nodes).isEmpty)
        XCTAssertEqual(LedgerEntryChoices.visible(nodes, preserving: [nodes.last!.id]).count, nodes.count)
    }

    func testHiddenPresetMetadataRoundTripsWithoutChangingAccountingExport() throws {
        let currency = try CurrencyCode("SGD")
        var wallet = LedgerAccount(name: "Cash", kind: .asset, currency: currency, accountType: .cash)
        let food = LedgerAccount(name: "Food", kind: .expense)
        let entry = try TransactionFactory.expense(amount: Money(12, currency: currency),
            paidFrom: wallet.id, category: food.id)
        let original = LedgerCSVExporter.export([entry], accounts: [wallet, food])
        wallet.isHiddenFromEntry = true
        wallet.presetID = "account.cash"
        let restored = try JSONDecoder().decode(LedgerAccount.self, from: JSONEncoder().encode(wallet))
        XCTAssertEqual(restored, wallet)
        XCTAssertEqual(LedgerCSVExporter.export([entry], accounts: [restored, food]), original)
        XCTAssertEqual(restored.kind, .asset)
        XCTAssertEqual(restored.currency, currency)
        XCTAssertFalse(restored.isArchived)
    }

    func testInvalidPresetMetadataCannotBeWrittenOrDecoded() throws {
        for value in ["", String(repeating: "x", count: 81), "account.\nsecret"] {
            var account = LedgerAccount(name: "Cash", kind: .asset)
            account.presetID = value
            XCTAssertThrowsError(try JSONEncoder().encode(account))
            account.presetID = nil
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(account)) as? [String: Any])
            object["presetID"] = value
            XCTAssertThrowsError(try JSONDecoder().decode(LedgerAccount.self,
                from: JSONSerialization.data(withJSONObject: object)))
        }
    }

    func testCatalogueIdentifiersAreUniqueAndKindsAreExplicit() {
        let presets = LedgerPresetCatalog.accounts + LedgerPresetCatalog.expenses
        XCTAssertEqual(Set(presets.map(\.id)).count, presets.count)
        XCTAssertTrue(LedgerPresetCatalog.accounts.allSatisfy { $0.accountType != nil && $0.scope == .accounts })
        XCTAssertTrue(LedgerPresetCatalog.expenses.allSatisfy { $0.accountType == nil && $0.scope == .expenses })
        XCTAssertEqual(LedgerPresetCatalog.preset(id: "account.credit_card")?.accountType, .creditCard)
        XCTAssertEqual(LedgerPresetCatalog.preset(id: "account.mortgage")?.accountType, .loan)
        XCTAssertEqual(LedgerPresetCatalog.preset(id: "account.retirement")?.accountType, .investment)
    }
}
