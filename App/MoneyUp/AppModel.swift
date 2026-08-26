import Foundation
import MoneyUpCore
import MoneyUpPersistence
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    static let lockedQuickCapturePreferenceKey = "moneyup.allowLockedQuickCapture"
    enum State: Equatable {
        case launching
        case locked
        case onboarding
        case ready
        case failed(String)
    }

    struct MonthToDateExpenseComparison {
        let previous: Money
        let current: Money
        let holdsUnconvertedActivity: Bool
    }

    struct TransactionImportResult: Equatable {
        let imported: Int
        let duplicates: Int
        let skipped: Int
        let categoriesCreated: Int
    }

    private struct PendingQuickLogCommit {
        let id: UUID
        let generation: Int
        let task: Task<Void, Error>
    }

    private struct EditableMoneySnapshot {
        let source: Money
        let destination: Money?
    }

    @Published private(set) var state: State = .launching
    @Published private(set) var profile: UserProfile? {
        didSet { invalidateDerivedData() }
    }
    @Published private(set) var accounts: [LedgerAccount] = [] {
        didSet { invalidateDerivedData() }
    }
    @Published private(set) var entries: [JournalEntry] = [] {
        didSet { invalidateDerivedData() }
    }
    @Published private(set) var budgetNodes: [BudgetNode] = []
    @Published private(set) var scheduledTransactions: [ScheduledTransaction] = []
    @Published private(set) var investmentHoldings: [InvestmentHolding] = []
    @Published private(set) var isWorking = false
    @Published private(set) var requestedQuickLogMode: QuickLogLaunchMode?
    @Published private(set) var quickLogDraft: QuickLogDraft?
    @Published private(set) var recoveryIssues: [String] = []
    @Published private(set) var pendingLockedCaptureCount = 0

    private var store: EncryptedRecordStore?
    private let lockedCaptureStore: any LockedCaptureStoring
    private let receiptRecognizer: ReceiptLineRecognizer
    private let lifecycleHooks: AppModelLifecycleHooks
    private let databaseURLForErase: URL?
    private let deleteDatabaseKey: @Sendable () throws -> Void
    private let restartAfterErase: Bool
    private var quickLogDraftWriteTask: Task<Void, Never>?
    private var quickLogCommit: PendingQuickLogCommit?
    private var storeCloseTask: Task<Void, Never>?
    private var autoLockTask: Task<Void, Never>?
    private var backgroundedAt: Date?
    private var storeGeneration = 0
    private var lockAfterStart = false
    private var isStarting = false
    private var reportCache: [ReportPeriod: DerivedValue<PeriodReport>] = [:]
    private var reportCacheDay: Date?
    private var monthToDateComparisonCache: DerivedValue<MonthToDateExpenseComparison>?
    private var monthToDateComparisonCacheDay: Date?
    private var balanceCache: DerivedValue<[UUID: [CurrencyCode: Money]]>?

    init() {
        lockedCaptureStore = LockedCaptureStore()
        receiptRecognizer = { data in
            try await ReceiptScanner.recognizeLines(inImageData: data)
        }
        lifecycleHooks = .none
        databaseURLForErase = nil
        deleteDatabaseKey = { try DatabaseKeyStore.deleteKey() }
        restartAfterErase = true
        UserDefaults.standard.register(defaults: [
            Self.lockedQuickCapturePreferenceKey: true
        ])
    }

    /// Dependency-injected construction for app-level tests and previews.
    /// Production startup still owns key access, store opening, and recovery.
    init(
        store: EncryptedRecordStore,
        profile: UserProfile,
        accounts: [LedgerAccount],
        entries: [JournalEntry] = [],
        budgetNodes: [BudgetNode] = [],
        scheduledTransactions: [ScheduledTransaction] = [],
        investmentHoldings: [InvestmentHolding] = [],
        quickLogDraft: QuickLogDraft? = nil,
        lockedCaptureStore: any LockedCaptureStoring = LockedCaptureStore(),
        receiptRecognizer: @escaping ReceiptLineRecognizer = { data in
            try await ReceiptScanner.recognizeLines(inImageData: data)
        },
        lifecycleHooks: AppModelLifecycleHooks = .none,
        databaseURLForErase: URL? = nil,
        deleteDatabaseKey: @escaping @Sendable () throws -> Void = {},
        restartAfterErase: Bool = false
    ) {
        self.lockedCaptureStore = lockedCaptureStore
        self.receiptRecognizer = receiptRecognizer
        self.lifecycleHooks = lifecycleHooks
        self.databaseURLForErase = databaseURLForErase
        self.deleteDatabaseKey = deleteDatabaseKey
        self.restartAfterErase = restartAfterErase
        UserDefaults.standard.register(defaults: [
            Self.lockedQuickCapturePreferenceKey: true
        ])
        self.store = store
        storeGeneration = 1
        self.profile = profile
        self.accounts = accounts
        self.entries = entries.sorted { $0.occurredAt > $1.occurredAt }
        self.budgetNodes = budgetNodes
        self.scheduledTransactions = scheduledTransactions
        self.investmentHoldings = investmentHoldings
        self.quickLogDraft = quickLogDraft
        state = .ready
    }

    var userAccounts: [LedgerAccount] {
        accounts.filter {
            ($0.kind == .asset || $0.kind == .liability) && !$0.isArchived
        }
    }

    var expenseCategories: [LedgerAccount] {
        accounts.filter { $0.kind == .expense && !$0.isArchived }
    }

    var incomeCategories: [LedgerAccount] {
        accounts.filter { $0.kind == .income && !$0.isArchived }
    }

    func start() async {
        guard !isWorking else { return }
        isWorking = true
        isStarting = true
        defer {
            isWorking = false
            isStarting = false
        }

        if let pendingClose = storeCloseTask {
            await pendingClose.value
            storeCloseTask = nil
        }
        if let existingStore = store {
            await existingStore.close()
            store = nil
            storeGeneration &+= 1
        }
        state = .launching

        do {
            var key = try DatabaseKeyStore.loadOrCreateKey()
            defer { key.resetBytes(in: 0..<key.count) }

            let databaseURL = try Self.databaseURL()
            let openingKey = key
            let openedStore = try await Task.detached(priority: .userInitiated) {
                try EncryptedRecordStore(databaseURL: databaseURL, key: openingKey)
            }.value
            storeGeneration &+= 1
            store = openedStore
            try await load(from: openedStore)

            if profile == nil {
                let hasBookData = !accounts.isEmpty
                    || !entries.isEmpty
                    || !budgetNodes.isEmpty
                    || !scheduledTransactions.isEmpty
                    || !investmentHoldings.isEmpty
                guard !hasBookData else { throw AppModelError.invalidBook }
                state = .onboarding
            } else {
                try validateLoadedBook()
                try await promoteLockedCaptureIfPossible(
                    to: openedStore,
                    generation: storeGeneration
                )
                state = .ready
            }
            if lockAfterStart {
                lockAfterStart = false
                isWorking = false
                isStarting = false
                lock()
            }
        } catch let error as DatabaseKeyStoreError where error == .authenticationCancelled {
            lockAfterStart = false
            state = .locked
        } catch {
            lockAfterStart = false
            // Keep an opened store available to the recovery screen. It can
            // still produce a raw authenticated backup even when a domain
            // record cannot be decoded. A key/cipher failure happens before
            // `store` is assigned and therefore exposes no recovery operation.
            if store == nil {
                clearDecodedState()
            }
            state = .failed(error.localizedDescription)
        }
    }

    func lock() {
        if isStarting || state == .launching {
            lockAfterStart = true
            return
        }
        let canLock: Bool
        switch state {
        case .ready, .onboarding, .failed:
            canLock = true
        case .launching, .locked:
            canLock = false
        }
        guard canLock else { return }
        autoLockTask?.cancel()
        autoLockTask = nil
        backgroundedAt = nil
        let pendingDraftWrite = quickLogDraftWriteTask
        let pendingQuickLogCommit = quickLogCommit.flatMap {
            $0.generation == storeGeneration ? $0.task : nil
        }
        pendingDraftWrite?.cancel()
        quickLogDraftWriteTask = nil
        let storeToClose = store
        let draftToSave = quickLogDraft
        store = nil
        storeGeneration &+= 1
        clearDecodedState()
        state = .locked

        guard let storeToClose else { return }
        let backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "Secure MoneyUp data",
            expirationHandler: nil
        )
        storeCloseTask = Task {
            defer {
                if backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                }
            }
            await pendingDraftWrite?.value
            var transactionCommitted = false
            if let pendingQuickLogCommit {
                do {
                    try await pendingQuickLogCommit.value
                    transactionCommitted = true
                } catch {
                    transactionCommitted = false
                }
            }
            if !transactionCommitted {
                await writeQuickLogDraft(draftToSave, to: storeToClose)
            }
            await storeToClose.close()
        }
    }

    /// Allows lifecycle callers and deterministic tests to wait until a lock
    /// has finished flushing/closing the store before reopening the file.
    func waitForPendingStoreClose() async {
        guard let pendingClose = storeCloseTask else { return }
        await pendingClose.value
        storeCloseTask = nil
    }

    func sceneDidEnterBackground(at date: Date = Date()) {
        guard state == .ready || state == .onboarding else { return }
        backgroundedAt = date
        autoLockTask?.cancel()
        let delay = profile?.autoLockDelay ?? 60
        guard delay > 0 else {
            lock()
            return
        }
        autoLockTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.lock()
        }
    }

    func sceneDidBecomeActive(at date: Date = Date()) {
        autoLockTask?.cancel()
        autoLockTask = nil
        guard let backgroundedAt else { return }
        self.backgroundedAt = nil
        let delay = profile?.autoLockDelay ?? 60
        if date.timeIntervalSince(backgroundedAt) >= delay {
            lock()
        }
    }

    @discardableResult
    func handleDeepLink(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "moneyup",
              url.host?.lowercased() == "quick-log" else { return false }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count == 1,
              let mode = QuickLogLaunchMode(rawValue: components[0].lowercased()) else {
            return false
        }
        requestedQuickLogMode = mode
        return true
    }

    var canPresentLockedQuickCapture: Bool {
        guard state == .locked,
              let requestedQuickLogMode,
              UserDefaults.standard.bool(
                  forKey: Self.lockedQuickCapturePreferenceKey
              ) else { return false }
        switch requestedQuickLogMode {
        case .expense, .income, .transfer, .refund:
            return true
        case .smartEntry, .scanReceipt:
            return false
        }
    }

    func saveLockedCapture(
        mode: QuickLogLaunchMode,
        amountText: String,
        payee: String,
        note: String
    ) async throws {
        let kind: LockedCaptureKind
        switch mode {
        case .income:
            kind = .income
        case .transfer:
            kind = .transfer
        case .refund:
            kind = .refund
        case .expense, .smartEntry, .scanReceipt:
            kind = .expense
        }
        try await lockedCaptureStore.append(
            LockedCapture(
                kind: kind,
                amountText: amountText,
                payee: payee,
                note: note
            )
        )
        let pendingCaptures = try? await lockedCaptureStore.all()
        pendingLockedCaptureCount = pendingCaptures?.count ?? 0
        consumeQuickLogRequest(mode)
    }

    func consumeQuickLogRequest(_ mode: QuickLogLaunchMode) {
        guard requestedQuickLogMode == mode else { return }
        requestedQuickLogMode = nil
    }

    /// Runs OCR outside the view and only returns a parsed draft to the same
    /// unlocked store generation that requested it. A lock during Vision work
    /// therefore cannot repopulate sensitive form state afterward.
    func receiptDraft(
        from imageData: Data,
        prefersDayFirst: Bool
    ) async throws -> TransactionDraft? {
        guard state == .ready else { return nil }
        let generation = storeGeneration
        try Task.checkCancellation()
        let lines = try await receiptRecognizer(imageData)
        try Task.checkCancellation()
        guard isCurrentStoreGeneration(generation) else { return nil }
        return ReceiptTextParser.draft(
            fromLines: lines,
            prefersDayFirst: prefersDayFirst
        )
    }

    /// Keeps the latest form state in memory immediately, then serializes a
    /// debounced copy into SQLCipher. Background locking cancels the debounce
    /// and flushes this latest snapshot before closing the store.
    func updateQuickLogDraft(_ draft: QuickLogDraft) {
        guard state == .ready else { return }
        guard quickLogDraft != draft else { return }
        quickLogDraft = draft
        scheduleQuickLogDraftWrite(draft)
    }

    func completeOnboarding(
        baseCurrencyCode: String,
        accountName: String,
        accountType: FinancialAccountType,
        startingBalance: Decimal
    ) async throws {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        let generation = storeGeneration
        let store = try requireStore()
        let currency = try CurrencyCode(baseCurrencyCode)
        if accountType.isLiabilityAccount, startingBalance < .zero {
            throw AppModelError.negativeAmount
        }
        try requireSupportedPrecision(startingBalance, currency: currency)
        let normalizedName = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw AppModelError.emptyName
        }

        let mainAccount = LedgerAccount(
            name: normalizedName,
            kind: accountType.isLiabilityAccount ? .liability : .asset,
            currency: currency,
            accountType: accountType
        )
        let defaults = Self.defaultBook(mainAccount: mainAccount)
        let newProfile = UserProfile(baseCurrency: currency)
        var writes = try defaults.accounts.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .accounts)
        }
        writes += try defaults.budgetNodes.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .budgetNodes)
        }
        writes.append(
            try RecordWrite(
                newProfile,
                id: UserProfile.primaryRecordID,
                in: .profile
            )
        )

        var openingEntry: JournalEntry?
        if startingBalance != .zero,
           let equity = defaults.accounts.first(where: { $0.systemRole == .openingBalances }) {
            let entry = try TransactionFactory.balanceAdjustment(
                displayBalanceDelta: try Money(startingBalance, currency: currency),
                accountID: mainAccount.id,
                equityAccountID: equity.id,
                accountIsLiability: mainAccount.kind == .liability,
                note: String(localized: "account.opening_balance_note")
            )
            writes.append(
                try RecordWrite(entry, id: entry.id.uuidString, in: .journalEntries)
            )
            openingEntry = entry
        }

        try await store.write(writes)
        guard isCurrentStoreGeneration(generation) else { return }

        profile = newProfile
        accounts = defaults.accounts
        budgetNodes = defaults.budgetNodes
        entries = openingEntry.map { [$0] } ?? []
        state = .ready
    }

    func addAccount(
        name: String,
        type: FinancialAccountType,
        currencyCode: String,
        startingBalance: Decimal = .zero
    ) async throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { throw AppModelError.emptyName }
        if type.isLiabilityAccount, startingBalance < .zero {
            throw AppModelError.negativeAmount
        }
        let currency = try CurrencyCode(currencyCode)
        try requireSupportedPrecision(startingBalance, currency: currency)
        let account = LedgerAccount(
            name: normalizedName,
            kind: type.isLiabilityAccount ? .liability : .asset,
            currency: currency,
            accountType: type
        )
        var accountsToAdd = [account]
        var writes = [
            try RecordWrite(account, id: account.id.uuidString, in: .accounts)
        ]
        var openingEntry: JournalEntry?

        if startingBalance != .zero {
            let equity = openingBalancesAccount()
            if !accounts.contains(where: { $0.id == equity.id }) {
                accountsToAdd.append(equity)
                writes.append(
                    try RecordWrite(equity, id: equity.id.uuidString, in: .accounts)
                )
            }
            let entry = try TransactionFactory.balanceAdjustment(
                displayBalanceDelta: try Money(startingBalance, currency: currency),
                accountID: account.id,
                equityAccountID: equity.id,
                accountIsLiability: account.kind == .liability,
                note: String(localized: "account.opening_balance_note")
            )
            writes.append(
                try RecordWrite(entry, id: entry.id.uuidString, in: .journalEntries)
            )
            openingEntry = entry
        }

        let generation = storeGeneration
        let accountStore = try requireStore()
        try await accountStore.write(writes)
        await lifecycleHooks.checkpoint(.afterAccountWriteBeforeApply)
        guard isCurrentStoreGeneration(generation) else { return }
        accounts.append(contentsOf: accountsToAdd)
        if let openingEntry { entries.insert(openingEntry, at: 0) }
    }

    func addCategory(
        name: String,
        kind: LedgerAccountKind,
        parentID: UUID? = nil
    ) async throws {
        guard kind == .expense || kind == .income else {
            throw AppModelError.invalidCategoryKind
        }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { throw AppModelError.emptyName }
        let category = LedgerAccount(
            name: normalizedName,
            kind: kind,
            parentID: parentID
        )
        let generation = storeGeneration
        let store = try requireStore()

        if kind == .expense, let currency = profile?.baseCurrency {
            let node = BudgetNode(
                id: category.id,
                parentID: parentID,
                name: normalizedName,
                limit: nil
            )
            let candidate = budgetNodes + [node]
            _ = try BudgetTree(currency: currency, nodes: candidate)
            try await store.write([
                try RecordWrite(category, id: category.id.uuidString, in: .accounts),
                try RecordWrite(node, id: node.id.uuidString, in: .budgetNodes)
            ])
            guard isCurrentStoreGeneration(generation) else { return }
            budgetNodes.append(node)
        } else {
            try await store.upsert(category, id: category.id.uuidString, in: .accounts)
            guard isCurrentStoreGeneration(generation) else { return }
        }
        accounts.append(category)
    }

    func setAccountBalance(accountID: UUID, displayBalance: Decimal) async throws {
        guard let account = accounts.first(where: { $0.id == accountID }),
              let currency = account.currency else {
            throw AppModelError.missingRecord
        }
        if account.kind == .liability, displayBalance < .zero {
            throw AppModelError.negativeAmount
        }
        let current: Decimal
        switch displayBalanceResult(for: account) {
        case let .available(balance):
            current = balance.amount
        case let .unavailable(issue):
            throw issue
        }
        try requireSupportedPrecision(displayBalance, currency: currency)
        let delta = displayBalance - current
        guard delta != .zero else { return }

        let equity = openingBalancesAccount()
        let shouldAddEquity = !accounts.contains(where: { $0.id == equity.id })
        let entry = try TransactionFactory.balanceAdjustment(
            displayBalanceDelta: try Money(delta, currency: currency),
            accountID: account.id,
            equityAccountID: equity.id,
            accountIsLiability: account.kind == .liability,
            note: String(localized: "account.balance_adjustment_note")
        )
        var writes = [
            try RecordWrite(entry, id: entry.id.uuidString, in: .journalEntries)
        ]
        if shouldAddEquity {
            writes.append(
                try RecordWrite(equity, id: equity.id.uuidString, in: .accounts)
            )
        }

        let generation = storeGeneration
        let balanceStore = try requireStore()
        try await balanceStore.write(writes)
        guard isCurrentStoreGeneration(generation) else { return }
        if shouldAddEquity { accounts.append(equity) }
        entries.insert(entry, at: 0)
    }

    @discardableResult
    func logExpense(
        amount: Decimal,
        accountID: UUID,
        categoryID: UUID,
        occurredAt: Date,
        payee: String?,
        note: String?
    ) async throws -> UUID? {
        let currency = try currency(for: accountID)
        try requireSupportedPrecision(amount, currency: currency)
        let entry = try TransactionFactory.expense(
            amount: try Money(amount, currency: currency),
            paidFrom: accountID,
            category: categoryID,
            occurredAt: occurredAt,
            payee: payee,
            note: note
        )
        return try await save(entry)
    }

    @discardableResult
    func logIncome(
        amount: Decimal,
        accountID: UUID,
        categoryID: UUID,
        occurredAt: Date,
        payee: String?,
        note: String?
    ) async throws -> UUID? {
        let currency = try currency(for: accountID)
        try requireSupportedPrecision(amount, currency: currency)
        let entry = try TransactionFactory.income(
            amount: try Money(amount, currency: currency),
            depositedInto: accountID,
            category: categoryID,
            occurredAt: occurredAt,
            payee: payee,
            note: note
        )
        return try await save(entry)
    }

    @discardableResult
    func logRefund(
        amount: Decimal,
        accountID: UUID,
        categoryID: UUID,
        occurredAt: Date,
        payee: String?,
        note: String?
    ) async throws -> UUID? {
        let currency = try currency(for: accountID)
        try requireSupportedPrecision(amount, currency: currency)
        let entry = try TransactionFactory.refund(
            amount: try Money(amount, currency: currency),
            returnedTo: accountID,
            category: categoryID,
            occurredAt: occurredAt,
            payee: payee,
            note: note
        )
        return try await save(entry)
    }

    @discardableResult
    func logTransfer(
        amount: Decimal,
        destinationAmount: Decimal? = nil,
        sourceAccountID: UUID,
        destinationAccountID: UUID,
        occurredAt: Date,
        note: String?
    ) async throws -> UUID? {
        let sourceCurrency = try currency(for: sourceAccountID)
        let destinationCurrency = try currency(for: destinationAccountID)
        try requireSupportedPrecision(amount, currency: sourceCurrency)
        if sourceCurrency == destinationCurrency {
            let entry = try TransactionFactory.transfer(
                amount: try Money(amount, currency: sourceCurrency),
                from: sourceAccountID,
                to: destinationAccountID,
                occurredAt: occurredAt,
                note: note
            )
            return try await save(entry)
        }

        guard let destinationAmount, destinationAmount > .zero else {
            throw AppModelError.foreignCurrencyTransferRequiresExchangeRate
        }
        try requireSupportedPrecision(destinationAmount, currency: destinationCurrency)
        let sourceTrading = foreignExchangeAccount(for: sourceCurrency)
        let destinationTrading = foreignExchangeAccount(for: destinationCurrency)
        let newTradingAccounts = [sourceTrading, destinationTrading].filter { candidate in
            !accounts.contains(where: { $0.id == candidate.id })
        }
        let entry = try TransactionFactory.foreignCurrencyTransfer(
            sourceAmount: try Money(amount, currency: sourceCurrency),
            destinationAmount: try Money(destinationAmount, currency: destinationCurrency),
            from: sourceAccountID,
            to: destinationAccountID,
            sourceTradingAccountID: sourceTrading.id,
            destinationTradingAccountID: destinationTrading.id,
            occurredAt: occurredAt,
            note: note
        )
        let writes = try newTradingAccounts.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .accounts)
        }
        let savedEntryID = try await save(entry, additionalWrites: writes)
        if savedEntryID != nil {
            accounts.append(contentsOf: newTradingAccounts)
        }
        return savedEntryID
    }

    func deleteEntry(id: UUID) async throws {
        let generation = storeGeneration
        let entryStore = try requireStore()
        try await entryStore.remove(id: id.uuidString, from: .journalEntries)
        guard isCurrentStoreGeneration(generation) else { return }
        entries.removeAll { $0.id == id }
    }

    /// Rebuilds a consumer transaction and swaps it into the live journal in
    /// one database transaction. The replacement receives a new identity and
    /// points to the prior identity through `supersedesID`. The prior encrypted
    /// record is retained in a revision collection for recovery/audit purposes,
    /// but is excluded from balances and reports.
    func replaceEntry(
        id: UUID,
        kind: QuickLogKind,
        amount: Decimal,
        destinationAmount: Decimal?,
        accountID: UUID,
        destinationAccountID: UUID?,
        categoryID: UUID?,
        occurredAt: Date,
        payee: String?,
        note: String?
    ) async throws {
        guard let original = entries.first(where: { $0.id == id }) else {
            throw AppModelError.missingRecord
        }

        let originalMoney = try editableMoneySnapshot(for: original)
        let accountCurrency = try currency(for: accountID)
        if let originalMoney, originalMoney.source.currency != accountCurrency {
            throw AppModelError.crossCurrencyEditRequiresConversion
        }
        try requireSupportedPrecision(
            amount,
            currency: accountCurrency,
            preserving: originalMoney?.source.amount
        )
        let candidate: JournalEntry
        var addedAccounts: [LedgerAccount] = []

        switch kind {
        case .expense:
            guard let categoryID else { throw AppModelError.missingRecord }
            candidate = try TransactionFactory.expense(
                amount: try Money(amount, currency: accountCurrency),
                paidFrom: accountID,
                category: categoryID,
                occurredAt: occurredAt,
                payee: payee,
                note: note
            )
        case .income:
            guard let categoryID else { throw AppModelError.missingRecord }
            candidate = try TransactionFactory.income(
                amount: try Money(amount, currency: accountCurrency),
                depositedInto: accountID,
                category: categoryID,
                occurredAt: occurredAt,
                payee: payee,
                note: note
            )
        case .refund:
            guard let categoryID else { throw AppModelError.missingRecord }
            candidate = try TransactionFactory.refund(
                amount: try Money(amount, currency: accountCurrency),
                returnedTo: accountID,
                category: categoryID,
                occurredAt: occurredAt,
                payee: payee,
                note: note
            )
        case .transfer:
            guard let destinationAccountID else { throw AppModelError.missingRecord }
            let destinationCurrency = try currency(for: destinationAccountID)
            if let originalDestination = originalMoney?.destination,
               originalDestination.currency != destinationCurrency {
                throw AppModelError.crossCurrencyEditRequiresConversion
            }
            if destinationCurrency == accountCurrency {
                candidate = try TransactionFactory.transfer(
                    amount: try Money(amount, currency: accountCurrency),
                    from: accountID,
                    to: destinationAccountID,
                    occurredAt: occurredAt,
                    note: note
                )
            } else {
                guard let destinationAmount, destinationAmount > .zero else {
                    throw AppModelError.foreignCurrencyTransferRequiresExchangeRate
                }
                try requireSupportedPrecision(
                    destinationAmount,
                    currency: destinationCurrency,
                    preserving: originalMoney?.destination?.amount
                )
                let sourceTrading = foreignExchangeAccount(for: accountCurrency)
                let destinationTrading = foreignExchangeAccount(for: destinationCurrency)
                addedAccounts = [sourceTrading, destinationTrading].filter { candidate in
                    !accounts.contains(where: { $0.id == candidate.id })
                }
                candidate = try TransactionFactory.foreignCurrencyTransfer(
                    sourceAmount: try Money(amount, currency: accountCurrency),
                    destinationAmount: try Money(
                        destinationAmount,
                        currency: destinationCurrency
                    ),
                    from: accountID,
                    to: destinationAccountID,
                    sourceTradingAccountID: sourceTrading.id,
                    destinationTradingAccountID: destinationTrading.id,
                    occurredAt: occurredAt,
                    note: note
                )
            }
        }

        let replacement = try JournalEntry(
            kind: candidate.kind,
            occurredAt: candidate.occurredAt,
            createdAt: original.createdAt,
            payee: candidate.payee,
            note: candidate.note,
            postings: candidate.postings,
            supersedesID: original.id,
            revisedAt: Date(),
            sourceSystem: original.sourceSystem,
            sourceFingerprint: original.sourceFingerprint
        )
        var writes = try addedAccounts.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .accounts)
        }
        writes.append(
            try RecordWrite(
                original,
                id: "\(original.id.uuidString)-\(UUID().uuidString)",
                in: .journalEntryRevisions
            )
        )
        writes.append(
            try RecordWrite(replacement, id: replacement.id.uuidString, in: .journalEntries)
        )

        let generation = storeGeneration
        let transactionStore = try requireStore()
        try await transactionStore.write(
            writes,
            removing: [
                RecordDeletion(
                    id: original.id.uuidString,
                    from: .journalEntries
                )
            ]
        )
        guard isCurrentStoreGeneration(generation) else { return }
        accounts.append(contentsOf: addedAccounts)
        entries.removeAll { $0.id == original.id }
        entries.append(replacement)
        entries.sort {
            if $0.occurredAt == $1.occurredAt { return $0.createdAt > $1.createdAt }
            return $0.occurredAt > $1.occurredAt
        }
    }

    func setBudgetLimit(categoryID: UUID, amount: Decimal?) async throws {
        guard let currency = profile?.baseCurrency,
              let index = budgetNodes.firstIndex(where: { $0.id == categoryID }) else {
            throw AppModelError.missingRecord
        }
        if let amount, amount < .zero { throw AppModelError.negativeAmount }
        if let amount { try requireSupportedPrecision(amount, currency: currency) }

        var updated = budgetNodes[index]
        updated.limit = try amount.map { try Money($0, currency: currency) }
        var candidate = budgetNodes
        candidate[index] = updated
        _ = try BudgetTree(currency: currency, nodes: candidate)

        let generation = storeGeneration
        let budgetStore = try requireStore()
        try await budgetStore.upsert(
            updated,
            id: updated.id.uuidString,
            in: .budgetNodes
        )
        guard isCurrentStoreGeneration(generation) else { return }
        budgetNodes = candidate
    }

    func addScheduledTransaction(_ transaction: ScheduledTransaction) async throws {
        try requireSupportedPrecision(
            transaction.amount.amount,
            currency: transaction.amount.currency
        )
        let generation = storeGeneration
        let scheduleStore = try requireStore()
        try await scheduleStore.upsert(
            transaction,
            id: transaction.id.uuidString,
            in: .scheduledTransactions
        )
        guard isCurrentStoreGeneration(generation) else { return }
        scheduledTransactions.append(transaction)
        scheduledTransactions.sort { $0.nextOccurrence < $1.nextOccurrence }
    }

    func deleteScheduledTransaction(id: UUID) async throws {
        let generation = storeGeneration
        let scheduleStore = try requireStore()
        try await scheduleStore.remove(id: id.uuidString, from: .scheduledTransactions)
        guard isCurrentStoreGeneration(generation) else { return }
        scheduledTransactions.removeAll { $0.id == id }
    }

    func addInvestmentHolding(_ holding: InvestmentHolding) async throws {
        if let price = holding.price {
            try requireSupportedPrecision(price.amount, currency: price.currency)
        }
        let generation = storeGeneration
        let holdingStore = try requireStore()
        try await holdingStore.upsert(
            holding,
            id: holding.id.uuidString,
            in: .investmentHoldings
        )
        guard isCurrentStoreGeneration(generation) else { return }
        investmentHoldings.append(holding)
    }

    func deleteInvestmentHolding(id: UUID) async throws {
        let generation = storeGeneration
        let holdingStore = try requireStore()
        try await holdingStore.remove(id: id.uuidString, from: .investmentHoldings)
        guard isCurrentStoreGeneration(generation) else { return }
        investmentHoldings.removeAll { $0.id == id }
    }

    func updateAutoLockDelay(_ seconds: TimeInterval) async throws {
        guard var updated = profile else { throw AppModelError.missingRecord }
        updated.autoLockDelay = max(0, seconds)
        try await persist(updatedProfile: updated)
    }

    func updateLockedQuickCapture(_ enabled: Bool) async throws {
        guard var updated = profile else { throw AppModelError.missingRecord }
        updated.allowLockedQuickCapture = enabled
        try await persist(updatedProfile: updated)
        UserDefaults.standard.set(enabled, forKey: Self.lockedQuickCapturePreferenceKey)
    }

    func updatePreferredAccount(_ id: UUID?) async throws {
        guard var updated = profile else { throw AppModelError.missingRecord }
        updated.preferredAccountID = id
        try await persist(updatedProfile: updated)
    }

    func updatePreferredExpenseCategory(_ id: UUID?) async throws {
        guard var updated = profile else { throw AppModelError.missingRecord }
        updated.preferredExpenseCategoryID = id
        try await persist(updatedProfile: updated)
    }

    func updatePreferredIncomeCategory(_ id: UUID?) async throws {
        guard var updated = profile else { throw AppModelError.missingRecord }
        updated.preferredIncomeCategoryID = id
        try await persist(updatedProfile: updated)
    }

    private func persist(updatedProfile: UserProfile) async throws {
        let generation = storeGeneration
        let profileStore = try requireStore()
        try await profileStore.upsert(
            updatedProfile,
            id: UserProfile.primaryRecordID,
            in: .profile
        )
        guard isCurrentStoreGeneration(generation) else { return }
        profile = updatedProfile
    }

    func eraseAllDataAndRestart() async {
        guard !isWorking else { return }
        isWorking = true
        state = .launching
        lockAfterStart = false
        let pendingDraftWrite = quickLogDraftWriteTask
        let pendingCommit = quickLogCommit.flatMap {
            $0.generation == storeGeneration ? $0.task : nil
        }
        pendingDraftWrite?.cancel()
        quickLogDraftWriteTask = nil
        quickLogCommit = nil
        if let pendingClose = storeCloseTask {
            await pendingClose.value
            storeCloseTask = nil
        }
        let storeToClose = store
        store = nil
        storeGeneration &+= 1
        clearDecodedState()
        await pendingDraftWrite?.value
        if let pendingCommit {
            _ = try? await pendingCommit.value
        }
        await storeToClose?.close()

        do {
            let databaseURL: URL
            if let databaseURLForErase {
                databaseURL = databaseURLForErase
            } else {
                databaseURL = try Self.databaseURL()
            }
            for suffix in ["-wal", "-shm"] {
                try Self.removeIfPresent(
                    URL(fileURLWithPath: databaseURL.path + suffix)
                )
            }
            try Self.removeIfPresent(databaseURL)
            try deleteDatabaseKey()
            if restartAfterErase {
                isWorking = false
                await start()
            } else {
                state = .onboarding
                isWorking = false
            }
        } catch {
            lockAfterStart = false
            clearDecodedState()
            state = .failed(error.localizedDescription)
            isWorking = false
        }
    }

    func displayBalanceResult(for account: LedgerAccount) -> DerivedValue<Money> {
        guard let currency = account.currency else {
            return .unavailable(.missingCurrency)
        }
        switch accountBalancesResult() {
        case let .available(balances):
            let raw = balances[account.id]?[currency]
                ?? Money.zero(currency: currency)
            return .available(account.kind == .liability ? raw.negated : raw)
        case let .unavailable(issue):
            return .unavailable(issue)
        }
    }

    /// The period report used by every reporting screen. Results are cached
    /// until the journal changes or the calendar day rolls over, so a SwiftUI
    /// body evaluation never rescans the whole journal.
    func reportResult(for period: ReportPeriod) -> DerivedValue<PeriodReport> {
        let today = Calendar.current.startOfDay(for: Date())
        if reportCacheDay != today {
            reportCache.removeAll()
            reportCacheDay = today
        }
        if let cached = reportCache[period] { return cached }

        guard let currency = profile?.baseCurrency else {
            return .unavailable(.appNotReady)
        }
        guard let interval = period.interval(containing: Date()) else {
            DerivedValueDiagnostics.record(
                .invalidPeriod,
                operation: "period-report-interval"
            )
            return .unavailable(.invalidPeriod)
        }
        let trendInterval = ReportPeriod.twelveMonths.interval(containing: Date())
            ?? interval
        let result: DerivedValue<PeriodReport>
        do {
            result = .available(
                try FinanceCalculator.report(
                    interval: interval,
                    trendInterval: trendInterval,
                    accounts: accounts,
                    entries: entries,
                    baseCurrency: currency
                )
            )
        } catch {
            DerivedValueDiagnostics.record(
                .ledgerCalculationFailed,
                operation: "period-report",
                error: error
            )
            result = .unavailable(.ledgerCalculationFailed)
        }
        reportCache[period] = result
        return result
    }

    func spendingThisMonthResult() -> DerivedValue<[UUID: Money]> {
        switch reportResult(for: .thisMonth) {
        case let .available(report):
            return .available(
                Dictionary(
                    uniqueKeysWithValues: report.categorySpending.map {
                        ($0.accountID, $0.amount)
                    }
                )
            )
        case let .unavailable(issue):
            return .unavailable(issue)
        }
    }

    func excludedForeignSpendingThisMonthResult() -> DerivedValue<[Money]> {
        switch reportResult(for: .thisMonth) {
        case let .available(report):
            return .available(
                report.foreignFlows
                    .map(\.expense)
                    .filter { $0.amount > .zero }
                    .sorted { $0.currency < $1.currency }
            )
        case let .unavailable(issue):
            return .unavailable(issue)
        }
    }

    func budgetProgressThisMonthResult() -> DerivedValue<[BudgetProgress]> {
        guard let currency = profile?.baseCurrency else {
            return .unavailable(.appNotReady)
        }
        do {
            let tree = try BudgetTree(currency: currency, nodes: budgetNodes)
            switch spendingThisMonthResult() {
            case let .available(spending):
                return .available(try tree.progress(directSpending: spending))
            case let .unavailable(issue):
                return .unavailable(issue)
            }
        } catch {
            DerivedValueDiagnostics.record(
                .budgetCalculationFailed,
                operation: "budget-progress",
                error: error
            )
            return .unavailable(.budgetCalculationFailed)
        }
    }

    func budgetPlanSummaryThisMonthResult() -> DerivedValue<BudgetPlanSummary?> {
        guard let currency = profile?.baseCurrency else {
            return .unavailable(.appNotReady)
        }
        do {
            let tree = try BudgetTree(currency: currency, nodes: budgetNodes)
            switch spendingThisMonthResult() {
            case let .available(spending):
                return .available(try tree.planSummary(directSpending: spending))
            case let .unavailable(issue):
                return .unavailable(issue)
            }
        } catch {
            DerivedValueDiagnostics.record(
                .budgetCalculationFailed,
                operation: "budget-summary",
                error: error
            )
            return .unavailable(.budgetCalculationFailed)
        }
    }

    func safeToSpendTodayResult() -> DerivedValue<SafeToSpendBreakdown?> {
        switch budgetPlanSummaryThisMonthResult() {
        case .available(.none):
            return .available(nil)
        case let .available(.some(summary)):
            let foreignSpending: [Money]
            switch excludedForeignSpendingThisMonthResult() {
            case let .available(values):
                foreignSpending = values
            case let .unavailable(issue):
                return .unavailable(issue)
            }
            do {
                return .available(
                    try FinanceCalculator.safeToSpend(
                        budgetRemaining: summary.remaining,
                        schedules: scheduledTransactions,
                        excludedForeignSpending: foreignSpending,
                        asOf: Date()
                    )
                )
            } catch {
                DerivedValueDiagnostics.record(
                    .budgetCalculationFailed,
                    operation: "safe-to-spend",
                    error: error
                )
                return .unavailable(.budgetCalculationFailed)
            }
        case let .unavailable(issue):
            return .unavailable(issue)
        }
    }

    /// Compares equal elapsed portions of this month and the prior month.
    /// A full prior month against a partial current month would produce a
    /// dramatic but misleading “spending down” sentence early in the month.
    func monthToDateExpenseComparisonResult() -> DerivedValue<MonthToDateExpenseComparison> {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        if monthToDateComparisonCacheDay == today,
           let cached = monthToDateComparisonCache {
            return cached
        }

        guard let currency = profile?.baseCurrency else {
            return .unavailable(.appNotReady)
        }
        guard let intervals = MonthToDateComparisonIntervals(
            containing: now,
            calendar: calendar
        ) else {
            DerivedValueDiagnostics.record(
                .invalidPeriod,
                operation: "month-to-date-interval"
            )
            return .unavailable(.invalidPeriod)
        }

        let result: DerivedValue<MonthToDateExpenseComparison>
        do {
            let currentReport = try FinanceCalculator.report(
                interval: intervals.current,
                accounts: accounts,
                entries: entries,
                baseCurrency: currency,
                calendar: calendar
            )
            let previousReport = try FinanceCalculator.report(
                interval: intervals.previous,
                accounts: accounts,
                entries: entries,
                baseCurrency: currency,
                calendar: calendar
            )
            result = .available(
                MonthToDateExpenseComparison(
                    previous: previousReport.baseFlow.expense,
                    current: currentReport.baseFlow.expense,
                    holdsUnconvertedActivity: currentReport.holdsUnconvertedActivity
                        || previousReport.holdsUnconvertedActivity
                )
            )
        } catch {
            DerivedValueDiagnostics.record(
                .ledgerCalculationFailed,
                operation: "month-to-date-comparison",
                error: error
            )
            result = .unavailable(.ledgerCalculationFailed)
        }
        monthToDateComparisonCache = result
        monthToDateComparisonCacheDay = today
        return result
    }

    func csvExport() -> String {
        LedgerCSVExporter.export(
            entries.sorted { $0.occurredAt < $1.occurredAt },
            accounts: accounts
        )
    }

    /// Resolves a parsed CSV preview against the current book, then commits
    /// every new category, FX helper, and journal entry together. A failure
    /// therefore imports either all accepted rows or none of them.
    func importTransactions(
        _ rows: [ImportedTransaction],
        fallbackAccountID: UUID,
        fallbackExpenseCategoryID: UUID,
        fallbackIncomeCategoryID: UUID,
        sourceSystem: String = "CSV/Qianji"
    ) async throws -> TransactionImportResult {
        guard rows.count <= 20_000 else { throw AppModelError.importTooLarge }
        guard let fallbackAccount = userAccounts.first(where: {
            $0.id == fallbackAccountID
        }), expenseCategories.contains(where: {
            $0.id == fallbackExpenseCategoryID
        }), incomeCategories.contains(where: {
            $0.id == fallbackIncomeCategoryID
        }) else { throw AppModelError.missingRecord }

        func normalizedName(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }

        var candidateAccounts = accounts
        var newAccounts: [LedgerAccount] = []
        var newBudgetNodes: [BudgetNode] = []
        var importedEntries: [JournalEntry] = []
        var fingerprints = Set(entries.compactMap(\.sourceFingerprint))
        var duplicates = 0
        var skipped = 0
        let initialAccountKinds = Dictionary(
            uniqueKeysWithValues: accounts.map { ($0.id, $0.kind) }
        )

        func duplicateKey(
            kind: ImportedTransactionKind,
            occurredAt: Date,
            amount: Decimal,
            currency: CurrencyCode,
            sourceID: UUID,
            payee: String?
        ) -> String {
            [
                kind.rawValue,
                String(Int64(occurredAt.timeIntervalSince1970.rounded(.down))),
                NSDecimalNumber(decimal: amount).stringValue,
                currency.value,
                sourceID.uuidString.lowercased(),
                normalizedName(payee ?? "")
            ].joined(separator: "\u{1f}")
        }

        func duplicateKey(for entry: JournalEntry) -> String? {
            let userPosting: Posting?
            let amountPosting: Posting?
            let kind: ImportedTransactionKind?
            switch entry.kind {
            case .expense:
                userPosting = entry.postings.first {
                    initialAccountKinds[$0.accountID] == .asset
                        || initialAccountKinds[$0.accountID] == .liability
                }
                amountPosting = entry.postings.first {
                    initialAccountKinds[$0.accountID] == .expense
                }
                kind = (amountPosting?.money.amount ?? .zero) < .zero
                    ? .refund : .expense
            case .income:
                userPosting = entry.postings.first {
                    initialAccountKinds[$0.accountID] == .asset
                        || initialAccountKinds[$0.accountID] == .liability
                }
                amountPosting = entry.postings.first {
                    initialAccountKinds[$0.accountID] == .income
                }
                kind = .income
            case .transfer:
                userPosting = entry.postings.first {
                    (initialAccountKinds[$0.accountID] == .asset
                        || initialAccountKinds[$0.accountID] == .liability)
                        && $0.money.amount < .zero
                }
                amountPosting = userPosting
                kind = .transfer
            case .adjustment, .investment:
                return nil
            }
            guard let userPosting, let amountPosting, let kind else { return nil }
            return duplicateKey(
                kind: kind,
                occurredAt: entry.occurredAt,
                amount: abs(amountPosting.money.amount),
                currency: amountPosting.money.currency,
                sourceID: userPosting.accountID,
                payee: entry.payee
            )
        }

        var duplicateKeys = Set(entries.compactMap { duplicateKey(for: $0) })

        func account(named name: String?, currency: CurrencyCode?) -> LedgerAccount? {
            guard let name else { return nil }
            let normalized = normalizedName(name)
            return candidateAccounts.first {
                ($0.kind == .asset || $0.kind == .liability)
                    && !$0.isArchived
                    && normalizedName($0.name) == normalized
                    && (currency == nil || $0.currency == currency)
            }
        }

        func category(
            named name: String?,
            kind: LedgerAccountKind,
            fallbackID: UUID
        ) -> LedgerAccount? {
            guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return candidateAccounts.first { $0.id == fallbackID } }
            let normalized = normalizedName(name)
            if let existing = candidateAccounts.first(where: {
                $0.kind == kind && normalizedName($0.name) == normalized
            }) {
                return existing
            }
            let created = LedgerAccount(name: name, kind: kind)
            candidateAccounts.append(created)
            newAccounts.append(created)
            if kind == .expense {
                newBudgetNodes.append(BudgetNode(id: created.id, name: created.name))
            }
            return created
        }

        for row in rows {
            guard fingerprints.insert(row.id).inserted else {
                duplicates += 1
                continue
            }
            let declaredCurrency = row.currencyCode.flatMap { try? CurrencyCode($0) }
            if row.currencyCode != nil, declaredCurrency == nil {
                fingerprints.remove(row.id)
                skipped += 1
                continue
            }
            let source = account(named: row.accountName, currency: declaredCurrency)
                ?? (declaredCurrency == nil || declaredCurrency == fallbackAccount.currency
                    ? fallbackAccount
                    : nil)
            guard let source, let sourceCurrency = source.currency,
                  sourceCurrency.supports(row.amount) else {
                fingerprints.remove(row.id)
                skipped += 1
                continue
            }
            let rowDuplicateKey = duplicateKey(
                kind: row.kind,
                occurredAt: row.occurredAt,
                amount: row.amount,
                currency: sourceCurrency,
                sourceID: source.id,
                payee: row.payee
            )
            guard duplicateKeys.insert(rowDuplicateKey).inserted else {
                fingerprints.remove(row.id)
                duplicates += 1
                continue
            }

            let baseEntry: JournalEntry
            do {
                switch row.kind {
                case .expense:
                    guard let category = category(
                        named: row.categoryName,
                        kind: .expense,
                        fallbackID: fallbackExpenseCategoryID
                    ) else { throw AppModelError.missingRecord }
                    baseEntry = try TransactionFactory.expense(
                        amount: try Money(row.amount, currency: sourceCurrency),
                        paidFrom: source.id,
                        category: category.id,
                        occurredAt: row.occurredAt,
                        payee: row.payee,
                        note: row.note
                    )
                case .income:
                    guard let category = category(
                        named: row.categoryName,
                        kind: .income,
                        fallbackID: fallbackIncomeCategoryID
                    ) else { throw AppModelError.missingRecord }
                    baseEntry = try TransactionFactory.income(
                        amount: try Money(row.amount, currency: sourceCurrency),
                        depositedInto: source.id,
                        category: category.id,
                        occurredAt: row.occurredAt,
                        payee: row.payee,
                        note: row.note
                    )
                case .refund:
                    guard let category = category(
                        named: row.categoryName,
                        kind: .expense,
                        fallbackID: fallbackExpenseCategoryID
                    ) else { throw AppModelError.missingRecord }
                    baseEntry = try TransactionFactory.refund(
                        amount: try Money(row.amount, currency: sourceCurrency),
                        returnedTo: source.id,
                        category: category.id,
                        occurredAt: row.occurredAt,
                        payee: row.payee,
                        note: row.note
                    )
                case .transfer:
                    guard let destination = account(
                        named: row.destinationAccountName,
                        currency: nil
                    ), destination.id != source.id,
                    let destinationCurrency = destination.currency else {
                        throw AppModelError.missingRecord
                    }
                    if sourceCurrency == destinationCurrency {
                        baseEntry = try TransactionFactory.transfer(
                            amount: try Money(row.amount, currency: sourceCurrency),
                            from: source.id,
                            to: destination.id,
                            occurredAt: row.occurredAt,
                            note: row.note
                        )
                    } else {
                        guard let destinationAmount = row.destinationAmount,
                              destinationCurrency.supports(destinationAmount) else {
                            throw AppModelError.foreignCurrencyTransferRequiresExchangeRate
                        }
                        let sourceTrading = foreignExchangeAccount(for: sourceCurrency)
                        let destinationTrading = foreignExchangeAccount(for: destinationCurrency)
                        for trading in [sourceTrading, destinationTrading]
                        where !candidateAccounts.contains(where: { $0.id == trading.id }) {
                            candidateAccounts.append(trading)
                            newAccounts.append(trading)
                        }
                        baseEntry = try TransactionFactory.foreignCurrencyTransfer(
                            sourceAmount: try Money(row.amount, currency: sourceCurrency),
                            destinationAmount: try Money(
                                destinationAmount,
                                currency: destinationCurrency
                            ),
                            from: source.id,
                            to: destination.id,
                            sourceTradingAccountID: sourceTrading.id,
                            destinationTradingAccountID: destinationTrading.id,
                            occurredAt: row.occurredAt,
                            note: row.note
                        )
                    }
                }

                importedEntries.append(
                    try JournalEntry(
                        kind: baseEntry.kind,
                        occurredAt: baseEntry.occurredAt,
                        createdAt: baseEntry.createdAt,
                        payee: baseEntry.payee,
                        note: baseEntry.note,
                        postings: baseEntry.postings,
                        sourceSystem: sourceSystem,
                        sourceFingerprint: row.id
                    )
                )
            } catch {
                fingerprints.remove(row.id)
                duplicateKeys.remove(rowDuplicateKey)
                skipped += 1
            }
        }

        guard !importedEntries.isEmpty else {
            return TransactionImportResult(
                imported: 0,
                duplicates: duplicates,
                skipped: skipped,
                categoriesCreated: 0
            )
        }
        if let currency = profile?.baseCurrency {
            _ = try BudgetTree(currency: currency, nodes: budgetNodes + newBudgetNodes)
        }

        var writes = try newAccounts.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .accounts)
        }
        writes += try newBudgetNodes.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .budgetNodes)
        }
        writes += try importedEntries.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .journalEntries)
        }

        let generation = storeGeneration
        let importStore = try requireStore()
        try await importStore.write(writes)
        guard isCurrentStoreGeneration(generation) else {
            return TransactionImportResult(
                imported: 0,
                duplicates: duplicates,
                skipped: skipped,
                categoriesCreated: 0
            )
        }
        accounts.append(contentsOf: newAccounts)
        budgetNodes.append(contentsOf: newBudgetNodes)
        entries.append(contentsOf: importedEntries)
        entries.sort {
            if $0.occurredAt == $1.occurredAt { return $0.createdAt > $1.createdAt }
            return $0.occurredAt > $1.occurredAt
        }
        return TransactionImportResult(
            imported: importedEntries.count,
            duplicates: duplicates,
            skipped: skipped,
            categoriesCreated: newBudgetNodes.count
                + newAccounts.filter { $0.kind == .income }.count
        )
    }

    func encryptedBackup(password: String) async throws -> Data {
        let backupStore = try requireStore()
        let snapshot = try await backupStore.snapshot()
        return try await Task.detached(priority: .userInitiated) {
            try PortableArchive.seal(snapshot, password: password)
        }.value
    }

    /// Restores only after decryption and snapshot validation succeed. The
    /// previous logical store is retained in memory and written back if loading
    /// the candidate fails, so restore is atomic from the user's perspective.
    func restoreEncryptedBackup(_ data: Data, password: String) async throws {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        let candidate = try await Task.detached(priority: .userInitiated) {
            try PortableArchive.open(data, password: password)
        }.value
        let restoreStore = try requireStore()
        let rollback = try await restoreStore.snapshot()

        do {
            try await restoreStore.restore(candidate)
            try await load(from: restoreStore)
            guard profile != nil else { throw AppModelError.invalidBook }
            try validateLoadedBook()
            state = .ready
        } catch {
            try? await restoreStore.restore(rollback)
            try? await load(from: restoreStore)
            throw error
        }
    }

    private func invalidateDerivedData() {
        reportCache.removeAll()
        monthToDateComparisonCache = nil
        monthToDateComparisonCacheDay = nil
        balanceCache = nil
    }

    private func accountBalancesResult() -> DerivedValue<[UUID: [CurrencyCode: Money]]> {
        if let balanceCache { return balanceCache }
        let result: DerivedValue<[UUID: [CurrencyCode: Money]]>
        do {
            result = .available(
                try FinanceCalculator.balancesByAccount(entries: entries)
            )
        } catch {
            DerivedValueDiagnostics.record(
                .ledgerCalculationFailed,
                operation: "account-balances",
                error: error
            )
            result = .unavailable(.ledgerCalculationFailed)
        }
        balanceCache = result
        return result
    }

    @discardableResult
    private func save(
        _ entry: JournalEntry,
        additionalWrites: [RecordWrite] = []
    ) async throws -> UUID? {
        let generation = storeGeneration
        if let existingCommit = quickLogCommit {
            guard existingCommit.generation != generation else {
                throw AppModelError.transactionInProgress
            }
            quickLogCommit = nil
        }
        let transactionStore = try requireStore()
        let pendingDraftWrite = quickLogDraftWriteTask
        pendingDraftWrite?.cancel()
        quickLogDraftWriteTask = nil
        var pendingWrites = additionalWrites
        pendingWrites.append(
            try RecordWrite(entry, id: entry.id.uuidString, in: .journalEntries)
        )
        let writes = pendingWrites
        let commitTask = Task {
            await pendingDraftWrite?.value
            await lifecycleHooks.checkpoint(.beforeJournalCommit)
            try await transactionStore.write(
                writes,
                removing: [
                    RecordDeletion(
                        id: QuickLogDraft.primaryRecordID,
                        from: .quickLogDrafts
                    )
                ]
            )
        }
        let commitID = UUID()
        quickLogCommit = PendingQuickLogCommit(
            id: commitID,
            generation: generation,
            task: commitTask
        )
        defer {
            if quickLogCommit?.id == commitID {
                quickLogCommit = nil
            }
        }
        try await commitTask.value
        guard isCurrentStoreGeneration(generation) else { return nil }
        quickLogDraft = nil
        entries.insert(entry, at: 0)
        return entry.id
    }

    private func scheduleQuickLogDraftWrite(_ draft: QuickLogDraft?) {
        let previousWrite = quickLogDraftWriteTask
        previousWrite?.cancel()
        guard let draftStore = store else {
            quickLogDraftWriteTask = nil
            return
        }

        quickLogDraftWriteTask = Task {
            // Chain revisions so Save/Lock can await one task and know every
            // older draft write has also finished before deleting or closing.
            await previousWrite?.value
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await writeQuickLogDraft(draft, to: draftStore)
        }
    }

    private func writeQuickLogDraft(
        _ draft: QuickLogDraft?,
        to draftStore: EncryptedRecordStore
    ) async {
        do {
            if let draft {
                try await draftStore.upsert(
                    draft,
                    id: QuickLogDraft.primaryRecordID,
                    in: .quickLogDrafts
                )
            } else {
                try await draftStore.remove(
                    id: QuickLogDraft.primaryRecordID,
                    from: .quickLogDrafts
                )
            }
        } catch {
            // A draft is a convenience cache. A write failure must never block
            // locking or make a completed transaction appear to have failed.
        }
    }

    private func load(from store: EncryptedRecordStore) async throws {
        recoveryIssues = []
        profile = try await store.fetch(
            UserProfile.self,
            id: UserProfile.primaryRecordID,
            from: .profile
        )
        if let profile {
            UserDefaults.standard.set(
                profile.allowLockedQuickCapture,
                forKey: Self.lockedQuickCapturePreferenceKey
            )
        }
        let recoveredAccounts = try await store.fetchAllRecovering(
            LedgerAccount.self,
            from: .accounts
        )
        let recoveredEntries = try await store.fetchAllRecovering(
            JournalEntry.self,
            from: .journalEntries
        )
        let recoveredBudgets = try await store.fetchAllRecovering(
            BudgetNode.self,
            from: .budgetNodes
        )
        let recoveredSchedules = try await store.fetchAllRecovering(
            ScheduledTransaction.self,
            from: .scheduledTransactions
        )
        let recoveredHoldings = try await store.fetchAllRecovering(
            InvestmentHolding.self,
            from: .investmentHoldings
        )

        accounts = recoveredAccounts.values
        entries = recoveredEntries.values.sorted { $0.occurredAt > $1.occurredAt }
        budgetNodes = recoveredBudgets.values
        scheduledTransactions = recoveredSchedules.values.sorted {
            $0.nextOccurrence < $1.nextOccurrence
        }
        investmentHoldings = recoveredHoldings.values
        let decodeIssues = recoveredAccounts.issues
            + recoveredEntries.issues
            + recoveredBudgets.issues
            + recoveredSchedules.issues
            + recoveredHoldings.issues
        recoveryIssues.append(contentsOf: decodeIssues.map {
            "\($0.collection.rawValue)/\($0.recordID)"
        })
        quarantineInvalidRelationships()
        do {
            quickLogDraft = try await store.fetch(
                QuickLogDraft.self,
                id: QuickLogDraft.primaryRecordID,
                from: .quickLogDrafts
            )
        } catch {
            // A malformed convenience draft should not lock the user out of
            // the valid encrypted book. Discard it and continue opening.
            quickLogDraft = nil
            try? await store.remove(
                id: QuickLogDraft.primaryRecordID,
                from: .quickLogDrafts
            )
        }
    }

    func promotePendingLockedCapture() async throws {
        let generation = storeGeneration
        let currentStore = try requireStore()
        try await promoteLockedCaptureIfPossible(
            to: currentStore,
            generation: generation
        )
    }

    private func promoteLockedCaptureIfPossible(
        to store: EncryptedRecordStore,
        generation: Int
    ) async throws {
        let captures = (try? await lockedCaptureStore.all()) ?? []
        guard ownsStoreGeneration(generation) else { return }
        pendingLockedCaptureCount = captures.count

        if let sourceID = quickLogDraft?.sourceCaptureID {
            try? await lockedCaptureStore.remove(id: sourceID)
            guard ownsStoreGeneration(generation) else { return }
            pendingLockedCaptureCount = max(0, captures.count - 1)
            return
        }
        guard quickLogDraft == nil, let capture = captures.first else { return }

        let kind: QuickLogKind
        let mode: QuickLogLaunchMode
        switch capture.kind {
        case .income:
            kind = .income
            mode = .income
        case .transfer:
            kind = .transfer
            mode = .transfer
        case .expense:
            kind = .expense
            mode = .expense
        case .refund:
            kind = .refund
            mode = .refund
        }
        let draft = QuickLogDraft(
            kind: kind,
            amountText: capture.amountText,
            destinationAmountText: "",
            accountID: nil,
            destinationAccountID: nil,
            categoryID: nil,
            occurredAt: capture.occurredAt,
            dateWasEdited: true,
            payee: capture.payee,
            note: capture.note,
            smartText: "",
            sourceCaptureID: capture.id
        )
        try await store.upsert(
            draft,
            id: QuickLogDraft.primaryRecordID,
            in: .quickLogDrafts
        )
        await lifecycleHooks.checkpoint(.afterCaptureDraftPersisted)
        guard ownsStoreGeneration(generation) else { return }
        quickLogDraft = draft
        try await lockedCaptureStore.remove(id: capture.id)
        guard ownsStoreGeneration(generation) else { return }
        pendingLockedCaptureCount = max(0, captures.count - 1)
        requestedQuickLogMode = mode
    }

    /// Invalid rows remain untouched in SQLCipher and in portable backups, but
    /// are excluded from calculations until repaired. This keeps one orphan
    /// from turning the entire otherwise-readable book into an erase screen.
    private func quarantineInvalidRelationships() {
        var seenAccountIDs = Set<UUID>()
        accounts = accounts.filter { account in
            let unique = seenAccountIDs.insert(account.id).inserted
            if !unique { recoveryIssues.append("accounts/duplicate-\(account.id)") }
            return unique
        }

        var accountIDs = Set(accounts.map(\.id))
        var changed = true
        while changed {
            let invalid = Set(accounts.compactMap { account -> UUID? in
                guard let parentID = account.parentID,
                      !accountIDs.contains(parentID) else { return nil }
                return account.id
            })
            changed = !invalid.isEmpty
            if changed {
                recoveryIssues.append(contentsOf: invalid.map { "accounts/orphan-\($0)" })
                accounts.removeAll { invalid.contains($0.id) }
                accountIDs = Set(accounts.map(\.id))
            }
        }

        let expenseIDs = Set(accounts.filter { $0.kind == .expense }.map(\.id))
        let invalidBudgetIDs = Set(budgetNodes.filter {
            !expenseIDs.contains($0.id)
                || ($0.parentID.map { !expenseIDs.contains($0) } ?? false)
        }.map(\.id))
        if !invalidBudgetIDs.isEmpty {
            recoveryIssues.append(contentsOf: invalidBudgetIDs.map { "budgets/orphan-\($0)" })
            budgetNodes.removeAll { invalidBudgetIDs.contains($0.id) }
        }
        if let currency = profile?.baseCurrency,
           (try? BudgetTree(currency: currency, nodes: budgetNodes)) == nil,
           !budgetNodes.isEmpty {
            recoveryIssues.append("budgets/invalid-tree")
            budgetNodes = []
        }

        entries.removeAll { entry in
            let invalid = entry.postings.contains { !accountIDs.contains($0.accountID) }
            if invalid { recoveryIssues.append("journal_entries/orphan-\(entry.id)") }
            return invalid
        }
        scheduledTransactions.removeAll { item in
            let invalid = !accountIDs.contains(item.accountID)
                || !accountIDs.contains(item.categoryAccountID)
            if invalid { recoveryIssues.append("scheduled_transactions/orphan-\(item.id)") }
            return invalid
        }
        investmentHoldings.removeAll { holding in
            let invalid = !accountIDs.contains(holding.accountID)
            if invalid { recoveryIssues.append("investment_holdings/orphan-\(holding.id)") }
            return invalid
        }
    }

    private func requireStore() throws -> EncryptedRecordStore {
        guard let store else { throw AppModelError.locked }
        return store
    }

    private func isCurrentStoreGeneration(_ generation: Int) -> Bool {
        ownsStoreGeneration(generation)
            && (state == .ready || state == .onboarding)
    }

    private func ownsStoreGeneration(_ generation: Int) -> Bool {
        generation == storeGeneration && store != nil
    }

    private func currency(for accountID: UUID) throws -> CurrencyCode {
        guard let currency = accounts.first(where: { $0.id == accountID })?.currency else {
            throw AppModelError.accountHasNoCurrency
        }
        return currency
    }

    private func editableMoneySnapshot(
        for entry: JournalEntry
    ) throws -> EditableMoneySnapshot? {
        let accountKinds = Dictionary(
            uniqueKeysWithValues: accounts.map { ($0.id, $0.kind) }
        )

        func positiveMoney(from posting: Posting) throws -> Money {
            do {
                return try Money(
                    abs(posting.money.amount),
                    currency: posting.money.currency
                )
            } catch {
                DerivedValueDiagnostics.record(
                    .amountCalculationFailed,
                    operation: "editable-money-snapshot",
                    error: error
                )
                throw DerivedValueIssue.amountCalculationFailed
            }
        }

        switch entry.kind {
        case .expense:
            guard let posting = entry.postings.first(where: {
                accountKinds[$0.accountID] == .expense
            }) else { return nil }
            let source = try positiveMoney(from: posting)
            return EditableMoneySnapshot(source: source, destination: nil)
        case .income:
            guard let posting = entry.postings.first(where: {
                accountKinds[$0.accountID] == .income
            }) else { return nil }
            let source = try positiveMoney(from: posting)
            return EditableMoneySnapshot(source: source, destination: nil)
        case .transfer:
            let userPostings = entry.postings.filter {
                accountKinds[$0.accountID] == .asset
                    || accountKinds[$0.accountID] == .liability
            }
            guard let sourcePosting = userPostings.first(where: {
                $0.money.amount < .zero
            }), let destinationPosting = userPostings.first(where: {
                $0.money.amount > .zero
            }) else { return nil }
            let source = try positiveMoney(from: sourcePosting)
            let destination = try positiveMoney(from: destinationPosting)
            return EditableMoneySnapshot(source: source, destination: destination)
        case .adjustment, .investment:
            return nil
        }
    }

    private func openingBalancesAccount() -> LedgerAccount {
        accounts.first(where: { $0.systemRole == .openingBalances })
            ?? LedgerAccount(
                name: String(localized: "account.opening_balances"),
                kind: .equity,
                systemRole: .openingBalances
            )
    }

    private func requireSupportedPrecision(
        _ amount: Decimal,
        currency: CurrencyCode,
        preserving originalAmount: Decimal? = nil
    ) throws {
        if let originalAmount, originalAmount == amount { return }
        guard currency.supports(amount) else {
            throw AppModelError.unsupportedPrecision(currency)
        }
    }

    private func foreignExchangeAccount(for currency: CurrencyCode) -> LedgerAccount {
        accounts.first {
            $0.systemRole == .foreignExchange && $0.currency == currency
        } ?? LedgerAccount(
            name: "\(String(localized: "account.fx_clearing")) \(currency.value)",
            kind: .trading,
            currency: currency,
            systemRole: .foreignExchange
        )
    }

    private func clearDecodedState() {
        quickLogDraftWriteTask?.cancel()
        quickLogDraftWriteTask = nil
        profile = nil
        accounts = []
        entries = []
        budgetNodes = []
        scheduledTransactions = []
        investmentHoldings = []
        quickLogDraft = nil
        recoveryIssues = []
    }

    private func validateLoadedBook() throws {
        guard let profile else { return }
        let accountIDs = Set(accounts.map(\.id))
        guard accountIDs.count == accounts.count else { throw AppModelError.invalidBook }

        for account in accounts {
            if let parentID = account.parentID, !accountIDs.contains(parentID) {
                throw AppModelError.invalidBook
            }
        }
        let expenseIDs = Set(accounts.filter { $0.kind == .expense }.map(\.id))
        guard budgetNodes.allSatisfy({ expenseIDs.contains($0.id) }) else {
            throw AppModelError.invalidBook
        }
        _ = try BudgetTree(currency: profile.baseCurrency, nodes: budgetNodes)

        guard entries.allSatisfy({ entry in
            entry.postings.allSatisfy { accountIDs.contains($0.accountID) }
        }) else {
            throw AppModelError.invalidBook
        }
        guard scheduledTransactions.allSatisfy({ item in
            accountIDs.contains(item.accountID)
                && accountIDs.contains(item.categoryAccountID)
        }) else {
            throw AppModelError.invalidBook
        }
        guard investmentHoldings.allSatisfy({ accountIDs.contains($0.accountID) }) else {
            throw AppModelError.invalidBook
        }
    }

    private static func databaseURL() throws -> URL {
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return baseURL
            .appendingPathComponent("MoneyUp", isDirectory: true)
            .appendingPathComponent("moneyup.sqlite", isDirectory: false)
    }

    private static func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private static func defaultBook(
        mainAccount: LedgerAccount
    ) -> (accounts: [LedgerAccount], budgetNodes: [BudgetNode]) {
        let openingBalances = LedgerAccount(
            name: String(localized: "account.opening_balances"),
            kind: .equity,
            systemRole: .openingBalances
        )
        let essentials = LedgerAccount(name: String(localized: "category.essentials"), kind: .expense)
        let food = LedgerAccount(
            name: String(localized: "category.food"),
            kind: .expense,
            parentID: essentials.id
        )
        let transport = LedgerAccount(
            name: String(localized: "category.transport"),
            kind: .expense,
            parentID: essentials.id
        )
        let housing = LedgerAccount(name: String(localized: "category.housing"), kind: .expense)
        let rent = LedgerAccount(
            name: String(localized: "category.rent"),
            kind: .expense,
            parentID: housing.id
        )
        let utilities = LedgerAccount(
            name: String(localized: "category.utilities"),
            kind: .expense,
            parentID: housing.id
        )
        let lifestyle = LedgerAccount(name: String(localized: "category.lifestyle"), kind: .expense)
        let shopping = LedgerAccount(
            name: String(localized: "category.shopping"),
            kind: .expense,
            parentID: lifestyle.id
        )
        let entertainment = LedgerAccount(
            name: String(localized: "category.entertainment"),
            kind: .expense,
            parentID: lifestyle.id
        )
        let salary = LedgerAccount(name: String(localized: "category.salary"), kind: .income)
        let otherIncome = LedgerAccount(name: String(localized: "category.other_income"), kind: .income)
        let expenseAccounts = [
            essentials, food, transport, housing, rent, utilities,
            lifestyle, shopping, entertainment
        ]
        let nodes = expenseAccounts.map {
            BudgetNode(id: $0.id, parentID: $0.parentID, name: $0.name)
        }
        return (
            [mainAccount, openingBalances] + expenseAccounts + [salary, otherIncome],
            nodes
        )
    }
}

enum AppModelError: Error {
    case locked
    case emptyName
    case invalidCategoryKind
    case missingRecord
    case negativeAmount
    case accountHasNoCurrency
    case foreignCurrencyTransferRequiresExchangeRate
    case invalidBook
    case transactionInProgress
    case unsupportedPrecision(CurrencyCode)
    case crossCurrencyEditRequiresConversion
    case importTooLarge
}

extension AppModelError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .locked: String(localized: "error.app_locked")
        case .emptyName: String(localized: "error.empty_name")
        case .invalidCategoryKind: String(localized: "error.invalid_category")
        case .missingRecord: String(localized: "error.missing_record")
        case .negativeAmount: String(localized: "error.negative_amount")
        case .accountHasNoCurrency: String(localized: "error.account_currency")
        case .foreignCurrencyTransferRequiresExchangeRate:
            String(localized: "error.fx_transfer_not_supported")
        case .invalidBook: String(localized: "error.invalid_book")
        case .transactionInProgress: String(localized: "error.transaction_in_progress")
        case let .unsupportedPrecision(currency):
            String(
                format: String(localized: "error.currency_precision"),
                currency.value,
                currency.minorUnits
            )
        case .crossCurrencyEditRequiresConversion:
            String(localized: "error.cross_currency_edit")
        case .importTooLarge: String(localized: "import.error.too_large")
        }
    }
}
