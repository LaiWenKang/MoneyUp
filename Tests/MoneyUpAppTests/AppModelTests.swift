import Foundation
@testable import MoneyUp
import MoneyUpCore
import MoneyUpPersistence
import XCTest

final class AppModelTests: XCTestCase {
    func testAmountParserUsesLocaleAndRequiresTheWholeString() {
        let french = Locale(identifier: "fr_FR")

        XCTAssertEqual(
            decimalAmount(from: "12,50", locale: french),
            Decimal(string: "12.50")
        )
        XCTAssertEqual(
            decimalAmount(from: "-0,75", locale: french),
            Decimal(string: "-0.75")
        )
        XCTAssertNil(decimalAmount(from: "12,50 EUR", locale: french))
        XCTAssertNil(decimalAmount(from: "1,2,3", locale: french))
        XCTAssertNil(decimalAmount(from: "NaN", locale: french))
    }

    func testAmountParserPreservesLargeDecimalWithoutBinaryConversion() {
        let text = "9999999999999999999999999999.99"

        XCTAssertEqual(
            decimalAmount(from: text, locale: Locale(identifier: "en_US_POSIX")),
            Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
        )
    }

    @MainActor
    func testLockDuringSaveCommitsExactlyOnceWithoutRepopulatingLockedState() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let gate = AsyncGate()
        let model = fixture.model(
            lifecycleHooks: hooks(pausing: .beforeJournalCommit, at: gate)
        )

        let saveTask = Task { @MainActor in
            try await model.logExpense(
                amount: 12,
                accountID: fixture.wallet.id,
                categoryID: fixture.food.id,
                occurredAt: Date(timeIntervalSinceReferenceDate: 200),
                payee: "Cafe",
                note: nil
            )
        }

        await gate.waitUntilReached()
        model.lock()
        await gate.release()

        let savedID = try await saveTask.value
        XCTAssertNil(savedID)
        await model.waitForPendingStoreClose()
        XCTAssertEqual(model.state, .locked)
        XCTAssertTrue(model.entries.isEmpty)

        let reopened = try fixture.reopenStore()
        let persisted = try await reopened.fetchAll(
            JournalEntry.self,
            from: .journalEntries
        )
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted.first?.payee, "Cafe")
        let draftCount = try await reopened.count(in: .quickLogDrafts)
        XCTAssertEqual(draftCount, 0)
        await reopened.close()
    }

    @MainActor
    func testLockDuringReceiptScanDiscardsTheStaleResult() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let gate = AsyncGate()
        let model = fixture.model(receiptRecognizer: { _ in
            await gate.suspend()
            return ["Cafe", "Total 12.50"]
        })

        let scanTask = Task { @MainActor in
            try await model.receiptDraft(
                from: Data([0x01]),
                prefersDayFirst: true
            )
        }

        await gate.waitUntilReached()
        model.lock()
        await gate.release()

        let scannedDraft = try await scanTask.value
        XCTAssertNil(scannedDraft)
        await model.waitForPendingStoreClose()
        XCTAssertEqual(model.state, .locked)
        XCTAssertNil(model.quickLogDraft)
    }

    @MainActor
    func testEraseDuringPendingCommitWaitsThenRemovesTheCommittedDatabase() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let gate = AsyncGate()
        let model = fixture.model(
            lifecycleHooks: hooks(pausing: .beforeJournalCommit, at: gate)
        )

        let saveTask = Task { @MainActor in
            try await model.logExpense(
                amount: 18,
                accountID: fixture.wallet.id,
                categoryID: fixture.food.id,
                occurredAt: Date(timeIntervalSinceReferenceDate: 300),
                payee: "Pending cafe",
                note: nil
            )
        }
        await gate.waitUntilReached()

        let eraseTask = Task { @MainActor in
            await model.eraseAllDataAndRestart()
        }
        for _ in 0..<100 {
            if model.state == .launching { break }
            await Task.yield()
        }
        XCTAssertEqual(model.state, .launching)
        await gate.release()

        let savedID = try await saveTask.value
        XCTAssertNil(savedID)
        await eraseTask.value
        XCTAssertEqual(model.state, .onboarding)
        XCTAssertNil(model.profile)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.databaseURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.databaseURL.path + "-wal")
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.databaseURL.path + "-shm")
        )
    }

    @MainActor
    func testStaleGenerationWriteDoesNotRepopulateMemoryAfterLock() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let gate = AsyncGate()
        let model = fixture.model(
            lifecycleHooks: hooks(pausing: .afterAccountWriteBeforeApply, at: gate)
        )

        let addTask = Task { @MainActor in
            try await model.addAccount(
                name: "Secondary wallet",
                type: .cash,
                currencyCode: "SGD"
            )
        }

        await gate.waitUntilReached()
        model.lock()
        await gate.release()
        try await addTask.value
        await model.waitForPendingStoreClose()

        XCTAssertEqual(model.state, .locked)
        XCTAssertTrue(model.accounts.isEmpty)
        let reopened = try fixture.reopenStore()
        let persisted = try await reopened.fetchAll(
            LedgerAccount.self,
            from: .accounts
        )
        XCTAssertEqual(persisted.map(\.name), ["Secondary wallet"])
        await reopened.close()
    }

    @MainActor
    func testOnboardingAcceptsAssetOverdraftAndCreatesItsOpeningEntry() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()

        try await model.completeOnboarding(
            baseCurrencyCode: "SGD",
            accountName: "Overdraft account",
            accountType: .bank,
            startingBalance: -75
        )

        let account = try XCTUnwrap(
            model.userAccounts.first { $0.name == "Overdraft account" }
        )
        XCTAssertEqual(account.kind, .asset)
        XCTAssertEqual(
            model.displayBalanceResult(for: account).value?.amount,
            -75
        )
        XCTAssertEqual(model.entries.count, 1)
        let storedEntryCount = try await fixture.store.count(in: .journalEntries)
        XCTAssertEqual(storedEntryCount, 1)
        await fixture.store.close()
    }

    @MainActor
    func testAddingLiabilityTreatsPositiveOpeningValueAsAmountOwed() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()

        try await model.addAccount(
            name: "Travel card",
            type: .creditCard,
            currencyCode: "SGD",
            startingBalance: 450
        )

        let account = try XCTUnwrap(
            model.userAccounts.first { $0.name == "Travel card" }
        )
        XCTAssertEqual(account.kind, .liability)
        XCTAssertEqual(
            model.displayBalanceResult(for: account).value?.amount,
            450
        )
        XCTAssertEqual(model.entries.count, 1)

        do {
            try await model.setAccountBalance(
                accountID: account.id,
                displayBalance: -1
            )
            XCTFail("Expected a negative amount-owed rejection")
        } catch AppModelError.negativeAmount {
            // Expected: balance reconciliation keeps liability semantics too.
        }
        XCTAssertEqual(
            model.displayBalanceResult(for: account).value?.amount,
            450
        )
        await fixture.store.close()
    }

    @MainActor
    func testAddingLiabilityRejectsNegativeAmountOwedBeforeWriting() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()

        do {
            try await model.addAccount(
                name: "Invalid card",
                type: .creditCard,
                currencyCode: "SGD",
                startingBalance: -10
            )
            XCTFail("Expected a negative amount-owed rejection")
        } catch AppModelError.negativeAmount {
            // Expected: liabilities use a non-negative consumer amount owed.
        }

        let storedAccountCount = try await fixture.store.count(in: .accounts)
        let storedEntryCount = try await fixture.store.count(in: .journalEntries)
        XCTAssertEqual(storedAccountCount, 0)
        XCTAssertEqual(storedEntryCount, 0)
        await fixture.store.close()
    }

    @MainActor
    func testCapturePromotionInterruptedByLockResumesExactlyOnce() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let capture = LockedCapture(
            kind: .expense,
            amountText: "12.50",
            occurredAt: Date(timeIntervalSinceReferenceDate: 400),
            payee: "Captured cafe"
        )
        let captureStore = InMemoryLockedCaptureStore(captures: [capture])
        let gate = AsyncGate()
        let model = fixture.model(
            lockedCaptureStore: captureStore,
            lifecycleHooks: hooks(pausing: .afterCaptureDraftPersisted, at: gate)
        )

        let promotionTask = Task { @MainActor in
            try await model.promotePendingLockedCapture()
        }
        await gate.waitUntilReached()
        model.lock()
        await gate.release()
        try await promotionTask.value
        await model.waitForPendingStoreClose()

        XCTAssertEqual(model.state, .locked)
        XCTAssertNil(model.quickLogDraft)
        let interruptedCaptures = try await captureStore.all()
        XCTAssertEqual(interruptedCaptures, [capture])

        let reopened = try fixture.reopenStore()
        let resumedModel = fixture.model(
            store: reopened,
            lockedCaptureStore: captureStore
        )
        try await resumedModel.promotePendingLockedCapture()
        let remainingCaptures = try await captureStore.all()
        XCTAssertTrue(remainingCaptures.isEmpty)
        let promotedDraft = try await reopened.fetch(
            QuickLogDraft.self,
            id: QuickLogDraft.primaryRecordID,
            from: .quickLogDrafts
        )
        let promotedDraftCount = try await reopened.count(in: .quickLogDrafts)
        XCTAssertEqual(promotedDraft?.sourceCaptureID, capture.id)
        XCTAssertEqual(promotedDraftCount, 1)
        XCTAssertEqual(resumedModel.quickLogDraft?.sourceCaptureID, capture.id)
        XCTAssertEqual(resumedModel.pendingLockedCaptureCount, 0)
        await reopened.close()
    }

    @MainActor
    func testInvalidBudgetReturnsUnavailableStateInsteadOfEmptyOrZeroValues() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let duplicate = BudgetNode(id: fixture.food.id, name: "Food")
        let model = fixture.model(budgetNodes: [duplicate, duplicate])

        switch model.budgetProgressThisMonthResult() {
        case .available:
            XCTFail("Expected an explicit unavailable budget state")
        case let .unavailable(issue):
            XCTAssertEqual(issue, .budgetCalculationFailed)
        }

        switch model.budgetPlanSummaryThisMonthResult() {
        case .available:
            XCTFail("Expected an explicit unavailable budget summary")
        case let .unavailable(issue):
            XCTAssertEqual(issue, .budgetCalculationFailed)
        }
        await fixture.store.close()
    }

    @MainActor
    func testReplacingEntryRetainsEncryptedRevisionAndInvalidatesBalanceCache() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let original = try fixture.expense(amount: 10)
        let model = fixture.model(entries: [original])

        XCTAssertEqual(
            model.displayBalanceResult(for: fixture.wallet).value?.amount,
            -10
        )

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
        XCTAssertEqual(
            model.displayBalanceResult(for: fixture.wallet).value?.amount,
            -20
        )
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
    let databaseURL: URL
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
        let databaseURL = directoryURL.appendingPathComponent("moneyup.sqlite3")
        self.directoryURL = directoryURL
        self.databaseURL = databaseURL
        store = try EncryptedRecordStore(
            databaseURL: databaseURL,
            key: Data(repeating: 0x2a, count: 32)
        )
        self.sgd = sgd
        self.usd = usd
        wallet = LedgerAccount(name: "Wallet", kind: .asset, currency: sgd)
        usAccount = LedgerAccount(name: "USD Cash", kind: .asset, currency: usd)
        food = LedgerAccount(name: "Food", kind: .expense)
    }

    @MainActor
    func model(
        store: EncryptedRecordStore? = nil,
        entries: [JournalEntry] = [],
        budgetNodes: [BudgetNode] = [],
        quickLogDraft: QuickLogDraft? = nil,
        lockedCaptureStore: any LockedCaptureStoring = LockedCaptureStore(),
        receiptRecognizer: @escaping ReceiptLineRecognizer = { data in
            try await ReceiptScanner.recognizeLines(inImageData: data)
        },
        lifecycleHooks: AppModelLifecycleHooks = .none
    ) -> AppModel {
        AppModel(
            store: store ?? self.store,
            profile: UserProfile(baseCurrency: sgd),
            accounts: [wallet, usAccount, food],
            entries: entries,
            budgetNodes: budgetNodes,
            quickLogDraft: quickLogDraft,
            lockedCaptureStore: lockedCaptureStore,
            receiptRecognizer: receiptRecognizer,
            lifecycleHooks: lifecycleHooks,
            databaseURLForErase: databaseURL
        )
    }

    func reopenStore() throws -> EncryptedRecordStore {
        try EncryptedRecordStore(
            databaseURL: databaseURL,
            key: Data(repeating: 0x2a, count: 32)
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

private func hooks(
    pausing checkpoint: AppModelLifecycleCheckpoint,
    at gate: AsyncGate
) -> AppModelLifecycleHooks {
    AppModelLifecycleHooks { candidate in
        guard candidate == checkpoint else { return }
        await gate.suspend()
    }
}

private actor AsyncGate {
    private var reached = false
    private var released = false
    private var reachWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        reached = true
        let waiters = reachWaiters
        reachWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilReached() async {
        guard !reached else { return }
        await withCheckedContinuation { continuation in
            reachWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor InMemoryLockedCaptureStore: LockedCaptureStoring {
    private var captures: [LockedCapture]

    init(captures: [LockedCapture]) {
        self.captures = captures
    }

    func all() async throws -> [LockedCapture] {
        captures
    }

    func append(_ capture: LockedCapture) async throws {
        guard !captures.contains(where: { $0.id == capture.id }) else { return }
        captures.append(capture)
    }

    func remove(id: UUID) async throws {
        captures.removeAll { $0.id == id }
    }
}
