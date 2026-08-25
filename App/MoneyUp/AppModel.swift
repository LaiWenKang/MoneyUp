import Foundation
import MoneyUpCore
import MoneyUpPersistence
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
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

    private struct PendingQuickLogCommit {
        let id: UUID
        let generation: Int
        let task: Task<Void, Error>
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

    private var store: EncryptedRecordStore?
    private var quickLogDraftWriteTask: Task<Void, Never>?
    private var quickLogCommit: PendingQuickLogCommit?
    private var storeCloseTask: Task<Void, Never>?
    private var storeGeneration = 0
    private var lockAfterStart = false
    private var isStarting = false
    private var reportCache: [ReportPeriod: PeriodReport] = [:]
    private var reportCacheDay: Date?
    private var monthToDateComparisonCache: MonthToDateExpenseComparison?
    private var monthToDateComparisonCacheDay: Date?
    private var balanceCache: [UUID: [CurrencyCode: Money]]?

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
        state = .launching

        do {
            var key = try DatabaseKeyStore.loadOrCreateKey()
            defer { key.resetBytes(in: 0..<key.count) }

            let openedStore = try EncryptedRecordStore(
                databaseURL: try Self.databaseURL(),
                key: key
            )
            storeGeneration &+= 1
            store = openedStore
            try await load(from: openedStore)

            if profile == nil {
                try await discardIncompleteOnboarding(from: openedStore)
                state = .onboarding
            } else {
                try validateLoadedBook()
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
            let failedStore = store
            clearDecodedState()
            store = nil
            storeGeneration &+= 1
            await failedStore?.close()
            state = .failed(error.localizedDescription)
        }
    }

    func lock() {
        if isStarting || state == .launching {
            lockAfterStart = true
            return
        }
        guard state == .ready || state == .onboarding else { return }
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

    func consumeQuickLogRequest(_ mode: QuickLogLaunchMode) {
        guard requestedQuickLogMode == mode else { return }
        requestedQuickLogMode = nil
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
        guard startingBalance >= .zero else { throw AppModelError.negativeAmount }
        let normalizedName = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw AppModelError.emptyName
        }

        let mainAccount = LedgerAccount(
            name: normalizedName,
            kind: accountType == .creditCard || accountType == .loan ? .liability : .asset,
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
        if startingBalance > .zero,
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
        guard startingBalance >= .zero else { throw AppModelError.negativeAmount }
        let currency = try CurrencyCode(currencyCode)
        let account = LedgerAccount(
            name: normalizedName,
            kind: type == .creditCard || type == .loan ? .liability : .asset,
            currency: currency,
            accountType: type
        )
        var accountsToAdd = [account]
        var writes = [
            try RecordWrite(account, id: account.id.uuidString, in: .accounts)
        ]
        var openingEntry: JournalEntry?

        if startingBalance > .zero {
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
        let current = self.displayBalance(for: account)?.amount ?? .zero
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

    func setBudgetLimit(categoryID: UUID, amount: Decimal?) async throws {
        guard let currency = profile?.baseCurrency,
              let index = budgetNodes.firstIndex(where: { $0.id == categoryID }) else {
            throw AppModelError.missingRecord
        }
        if let amount, amount < .zero { throw AppModelError.negativeAmount }

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

    func updateLockWhenBackgrounded(_ enabled: Bool) async throws {
        guard var updated = profile else { throw AppModelError.missingRecord }
        updated.lockWhenBackgrounded = enabled
        let generation = storeGeneration
        let profileStore = try requireStore()
        try await profileStore.upsert(
            updated,
            id: UserProfile.primaryRecordID,
            in: .profile
        )
        guard isCurrentStoreGeneration(generation) else { return }
        profile = updated
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
            let databaseURL = try Self.databaseURL()
            for suffix in ["-wal", "-shm"] {
                try Self.removeIfPresent(
                    URL(fileURLWithPath: databaseURL.path + suffix)
                )
            }
            try Self.removeIfPresent(databaseURL)
            try DatabaseKeyStore.deleteKey()
            isWorking = false
            await start()
        } catch {
            lockAfterStart = false
            clearDecodedState()
            state = .failed(error.localizedDescription)
            isWorking = false
        }
    }

    func displayBalance(for account: LedgerAccount) -> Money? {
        guard let currency = account.currency else { return nil }
        let raw = accountBalances()[account.id]?[currency]
            ?? Money.zero(currency: currency)
        return account.kind == .liability ? raw.negated : raw
    }

    /// The period report used by every reporting screen. Results are cached
    /// until the journal changes or the calendar day rolls over, so a SwiftUI
    /// body evaluation never rescans the whole journal.
    func report(for period: ReportPeriod) -> PeriodReport? {
        let today = Calendar.current.startOfDay(for: Date())
        if reportCacheDay != today {
            reportCache.removeAll()
            reportCacheDay = today
        }
        if let cached = reportCache[period] { return cached }

        guard let currency = profile?.baseCurrency,
              let interval = period.interval(containing: Date()) else { return nil }
        guard let built = try? FinanceCalculator.report(
            interval: interval,
            trendInterval: interval,
            accounts: accounts,
            entries: entries,
            baseCurrency: currency
        ) else { return nil }

        reportCache[period] = built
        return built
    }

    func spendingThisMonth() -> [UUID: Money] {
        guard let report = report(for: .thisMonth) else { return [:] }
        return Dictionary(
            uniqueKeysWithValues: report.categorySpending.map {
                ($0.accountID, $0.amount)
            }
        )
    }

    func budgetProgressThisMonth() -> [BudgetProgress] {
        guard let currency = profile?.baseCurrency,
              let tree = try? BudgetTree(currency: currency, nodes: budgetNodes) else {
            return []
        }
        return (try? tree.progress(directSpending: spendingThisMonth())) ?? []
    }

    func budgetPlanSummaryThisMonth() -> BudgetPlanSummary? {
        guard let currency = profile?.baseCurrency,
              let tree = try? BudgetTree(currency: currency, nodes: budgetNodes) else {
            return nil
        }
        return try? tree.planSummary(directSpending: spendingThisMonth())
    }

    /// Compares equal elapsed portions of this month and the prior month.
    /// A full prior month against a partial current month would produce a
    /// dramatic but misleading “spending down” sentence early in the month.
    func monthToDateExpenseComparison() -> MonthToDateExpenseComparison? {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        if monthToDateComparisonCacheDay == today,
           let cached = monthToDateComparisonCache {
            return cached
        }

        guard let currency = profile?.baseCurrency,
              let intervals = MonthToDateComparisonIntervals(
                  containing: now,
                  calendar: calendar
              ) else { return nil }

        guard let currentReport = try? FinanceCalculator.report(
            interval: intervals.current,
            accounts: accounts,
            entries: entries,
            baseCurrency: currency,
            calendar: calendar
        ), let previousReport = try? FinanceCalculator.report(
            interval: intervals.previous,
            accounts: accounts,
            entries: entries,
            baseCurrency: currency,
            calendar: calendar
        ) else { return nil }

        let comparison = MonthToDateExpenseComparison(
            previous: previousReport.baseFlow.expense,
            current: currentReport.baseFlow.expense,
            holdsUnconvertedActivity: currentReport.holdsUnconvertedActivity
                || previousReport.holdsUnconvertedActivity
        )
        monthToDateComparisonCache = comparison
        monthToDateComparisonCacheDay = today
        return comparison
    }

    func csvExport() -> String {
        LedgerCSVExporter.export(
            entries.sorted { $0.occurredAt < $1.occurredAt },
            accounts: accounts
        )
    }

    private func invalidateDerivedData() {
        reportCache.removeAll()
        monthToDateComparisonCache = nil
        monthToDateComparisonCacheDay = nil
        balanceCache = nil
    }

    private func accountBalances() -> [UUID: [CurrencyCode: Money]] {
        if let balanceCache { return balanceCache }
        let computed = (try? FinanceCalculator.balancesByAccount(entries: entries))
            ?? [:]
        balanceCache = computed
        return computed
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
        profile = try await store.fetch(
            UserProfile.self,
            id: UserProfile.primaryRecordID,
            from: .profile
        )
        accounts = try await store.fetchAll(LedgerAccount.self, from: .accounts)
        entries = try await store.fetchAll(JournalEntry.self, from: .journalEntries)
            .sorted { $0.occurredAt > $1.occurredAt }
        budgetNodes = try await store.fetchAll(BudgetNode.self, from: .budgetNodes)
        scheduledTransactions = try await store.fetchAll(
            ScheduledTransaction.self,
            from: .scheduledTransactions
        ).sorted { $0.nextOccurrence < $1.nextOccurrence }
        investmentHoldings = try await store.fetchAll(
            InvestmentHolding.self,
            from: .investmentHoldings
        )
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

    private func discardIncompleteOnboarding(
        from store: EncryptedRecordStore
    ) async throws {
        try await store.removeAll(from: .accounts)
        try await store.removeAll(from: .journalEntries)
        try await store.removeAll(from: .budgetNodes)
        try await store.removeAll(from: .scheduledTransactions)
        try await store.removeAll(from: .investmentHoldings)
        try await store.removeAll(from: .quickLogDrafts)
        clearDecodedState()
    }

    private func requireStore() throws -> EncryptedRecordStore {
        guard let store else { throw AppModelError.locked }
        return store
    }

    private func isCurrentStoreGeneration(_ generation: Int) -> Bool {
        generation == storeGeneration
            && store != nil
            && (state == .ready || state == .onboarding)
    }

    private func currency(for accountID: UUID) throws -> CurrencyCode {
        guard let currency = accounts.first(where: { $0.id == accountID })?.currency else {
            throw AppModelError.accountHasNoCurrency
        }
        return currency
    }

    private func openingBalancesAccount() -> LedgerAccount {
        accounts.first(where: { $0.systemRole == .openingBalances })
            ?? LedgerAccount(
                name: String(localized: "account.opening_balances"),
                kind: .equity,
                systemRole: .openingBalances
            )
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
        }
    }
}
