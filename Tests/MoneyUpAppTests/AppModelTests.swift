import Foundation
@testable import MoneyUp
import MoneyUpCore
import MoneyUpPersistence
import XCTest

final class AppModelTests: XCTestCase {
    @MainActor
    func testReplacingEntryRetainsEncryptedRevisionAndInvalidatesBalanceCache() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let original = try fixture.expense(amount: 10)
        let model = fixture.model(entries: [original])

        XCTAssertEqual(model.displayBalance(for: fixture.wallet)?.amount, -10)

        try await model.replaceEntry(
            id: original.id,
            kind: .expense,
            amount: 20,
            destinationAmount: nil,
            accountID: fixture.wallet.id,
            destinationAccountID: nil,
            categoryID: fixture.food.id,
            occurredAt: original.occurredAt,
            payee: "Updated cafe",
            note: "Corrected"
        )

        let revisions = try await fixture.store.fetchAll(
            JournalEntry.self,
            from: .journalEntryRevisions
        )
        let replacement = try XCTUnwrap(model.entries.first)
        let fetchedLive = try await fixture.store.fetch(
            JournalEntry.self,
            id: replacement.id.uuidString,
            from: .journalEntries
        )
        let retiredLive = try await fixture.store.fetch(
            JournalEntry.self,
            id: original.id.uuidString,
            from: .journalEntries
        )
        let live = try XCTUnwrap(fetchedLive)

        XCTAssertEqual(revisions, [original])
        XCTAssertNotEqual(live.id, original.id)
        XCTAssertEqual(live.supersedesID, original.id)
        XCTAssertNotNil(live.revisedAt)
        XCTAssertNil(retiredLive)
        XCTAssertEqual(model.displayBalance(for: fixture.wallet)?.amount, -20)
        await fixture.store.close()
    }

    @MainActor
    func testReplacingEntryRejectsImplicitCurrencyChangeWithoutWriting() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let original = try fixture.expense(amount: 10)
        let model = fixture.model(entries: [original])

        do {
            try await model.replaceEntry(
                id: original.id,
                kind: .expense,
                amount: 10,
                destinationAmount: nil,
                accountID: fixture.usAccount.id,
                destinationAccountID: nil,
                categoryID: fixture.food.id,
                occurredAt: original.occurredAt,
                payee: original.payee,
                note: original.note
            )
            XCTFail("Expected a currency-change rejection")
        } catch AppModelError.crossCurrencyEditRequiresConversion {
            // Expected: the UI has no explicit conversion contract for edits.
        }

        let revisionCount = try await fixture.store.count(in: .journalEntryRevisions)
        let entryCount = try await fixture.store.count(in: .journalEntries)
        XCTAssertEqual(revisionCount, 0)
        XCTAssertEqual(entryCount, 0)
        XCTAssertEqual(model.entries, [original])
        await fixture.store.close()
    }

    @MainActor
    func testLegacyPrecisionCanBePreservedButNotChangedToAnotherInvalidValue() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let original = try fixture.expense(amount: Decimal(string: "12.345")!)
        let model = fixture.model(entries: [original])

        try await model.replaceEntry(
            id: original.id,
            kind: .expense,
            amount: Decimal(string: "12.345")!,
            destinationAmount: nil,
            accountID: fixture.wallet.id,
            destinationAccountID: nil,
            categoryID: fixture.food.id,
            occurredAt: original.occurredAt,
            payee: original.payee,
            note: "Preserve the imported amount"
        )
        let replacementID = try XCTUnwrap(model.entries.first?.id)

        do {
            try await model.replaceEntry(
                id: replacementID,
                kind: .expense,
                amount: Decimal(string: "12.346")!,
                destinationAmount: nil,
                accountID: fixture.wallet.id,
                destinationAccountID: nil,
                categoryID: fixture.food.id,
                occurredAt: original.occurredAt,
                payee: original.payee,
                note: "Invalid precision"
            )
            XCTFail("Expected unsupported precision")
        } catch AppModelError.unsupportedPrecision(let currency) {
            XCTAssertEqual(currency, fixture.sgd)
        }

        XCTAssertEqual(model.entries.first?.postings.first?.money.amount, Decimal(string: "12.345"))
        let revisionCount = try await fixture.store.count(in: .journalEntryRevisions)
        XCTAssertEqual(revisionCount, 1)
        await fixture.store.close()
    }

    @MainActor
    func testSchedulesAndHoldingPricesEnforceCurrencyMinorUnits() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()
        let unsupported = try Money(Decimal(string: "1.234")!, currency: fixture.sgd)
        let schedule = try ScheduledTransaction(
            kind: .expense,
            name: "Rent",
            amount: unsupported,
            accountID: fixture.wallet.id,
            categoryAccountID: fixture.food.id,
            nextOccurrence: Date(),
            frequency: .monthly
        )
        let holding = try InvestmentHolding(
            accountID: fixture.wallet.id,
            symbol: "TEST",
            name: "Test holding",
            quantity: 1,
            price: unsupported
        )

        do {
            try await model.addScheduledTransaction(schedule)
            XCTFail("Expected unsupported schedule precision")
        } catch AppModelError.unsupportedPrecision(let currency) {
            XCTAssertEqual(currency, fixture.sgd)
        }
        do {
            try await model.addInvestmentHolding(holding)
            XCTFail("Expected unsupported holding precision")
        } catch AppModelError.unsupportedPrecision(let currency) {
            XCTAssertEqual(currency, fixture.sgd)
        }

        let scheduleCount = try await fixture.store.count(in: .scheduledTransactions)
        let holdingCount = try await fixture.store.count(in: .investmentHoldings)
        XCTAssertEqual(scheduleCount, 0)
        XCTAssertEqual(holdingCount, 0)
        await fixture.store.close()
    }

    @MainActor
    func testExpenseDeepLinkWhileLockedOffersOnlyLockedCapture() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()
        UserDefaults.standard.set(
            true,
            forKey: AppModel.lockedQuickCapturePreferenceKey
        )

        model.lock()
        let handled = model.handleDeepLink(
            try XCTUnwrap(URL(string: "moneyup://quick-log/expense"))
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(model.state, .locked)
        XCTAssertEqual(model.requestedQuickLogMode, .expense)
        XCTAssertTrue(model.canPresentLockedQuickCapture)
        await fixture.store.close()
    }
}

private struct AppModelFixture {
    let directoryURL: URL
    let store: EncryptedRecordStore
    let sgd: CurrencyCode
    let usd: CurrencyCode
    let wallet: LedgerAccount
    let usAccount: LedgerAccount
    let food: LedgerAccount

    init() throws {
        let sgd = try CurrencyCode("SGD")
        let usd = try CurrencyCode("USD")
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoneyUpAppTests-\(UUID().uuidString)")
        self.directoryURL = directoryURL
        store = try EncryptedRecordStore(
            databaseURL: directoryURL.appendingPathComponent("moneyup.sqlite3"),
            key: Data(repeating: 0x2a, count: 32)
        )
        self.sgd = sgd
        self.usd = usd
        wallet = LedgerAccount(name: "Wallet", kind: .asset, currency: sgd)
        usAccount = LedgerAccount(name: "USD Cash", kind: .asset, currency: usd)
        food = LedgerAccount(name: "Food", kind: .expense)
    }

    @MainActor
    func model(entries: [JournalEntry] = []) -> AppModel {
        AppModel(
            store: store,
            profile: UserProfile(baseCurrency: sgd),
            accounts: [wallet, usAccount, food],
            entries: entries
        )
    }

    func expense(amount: Decimal) throws -> JournalEntry {
        try TransactionFactory.expense(
            amount: Money(amount, currency: sgd),
            paidFrom: wallet.id,
            category: food.id,
            occurredAt: Date(timeIntervalSinceReferenceDate: 100),
            payee: "Cafe"
        )
    }

    func removeFiles() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
