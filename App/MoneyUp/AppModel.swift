import Foundation
import MoneyUpCore
import MoneyUpPersistence
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    enum State: Equatable {
        case launching
        case locked
        case onboarding
        case ready
        case failed(String)
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
    @Published private(set) var requestedQuickLogKind: QuickLogKind?

    private var store: EncryptedRecordStore?
    private var reportCache: [ReportPeriod: PeriodReport] = [:]
    private var reportCacheDay: Date?
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
        state = .launching
        defer { isWorking = false }

        do {
            var key = try DatabaseKeyStore.loadOrCreateKey()
            defer { key.resetBytes(in: 0..<key.count) }

            let openedStore = try EncryptedRecordStore(
                databaseURL: try Self.databaseURL(),
                key: key
            )
            store = openedStore
            try await load(from: openedStore)

            if profile == nil {
                try await discardIncompleteOnboarding(from: openedStore)
                state = .onboarding
            } else {
                try validateLoadedBook()
                state = .ready
            }
        } catch let error as DatabaseKeyStoreError where error == .authenticationCancelled {
            state = .locked
        } catch {
            clearDecodedState()
            store = nil
            state = .failed(error.localizedDescription)
        }
    }

    func lock() {
        guard state == .ready || state == .onboarding else { return }
        let storeToClose = store
        store = nil
        clearDecodedState()
        state = .locked

        Task {
            await storeToClose?.close()
        }
    }

    func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "moneyup",
              url.host?.lowercased() == "quick-log" else { return }
        let rawKind = url.pathComponents.dropFirst().first?.lowercased()
        requestedQuickLogKind = rawKind.flatMap(QuickLogKind.init(rawValue:)) ?? .expense
    }

    func consumeQuickLogRequest() {
        requestedQuickLogKind = nil
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

        try await requireStore().write(writes)
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
            budgetNodes.append(node)
        } else {
            try await store.upsert(category, id: category.id.uuidString, in: .accounts)
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

        try await requireStore().write(writes)
        if shouldAddEquity { accounts.append(equity) }
        entries.insert(entry, at: 0)
    }

    func logExpense(
        amount: Decimal,
        accountID: UUID,
        categoryID: UUID,
        occurredAt: Date,
        payee: String?,
        note: String?
    ) async throws {
        let currency = try currency(for: accountID)
        let entry = try TransactionFactory.expense(
            amount: try Money(amount, currency: currency),
            paidFrom: accountID,
            category: categoryID,
            occurredAt: occurredAt,
            payee: payee,
            note: note
        )
        try await save(entry)
    }

    func logIncome(
        amount: Decimal,
        accountID: UUID,
        categoryID: UUID,
        occurredAt: Date,
        payee: String?,
        note: String?
    ) async throws {
        let currency = try currency(for: accountID)
        let entry = try TransactionFactory.income(
            amount: try Money(amount, currency: currency),
            depositedInto: accountID,
            category: categoryID,
            occurredAt: occurredAt,
            payee: payee,
            note: note
        )
        try await save(entry)
    }

    func logTransfer(
        amount: Decimal,
        destinationAmount: Decimal? = nil,
        sourceAccountID: UUID,
        destinationAccountID: UUID,
        occurredAt: Date,
        note: String?
    ) async throws {
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
            try await save(entry)
            return
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
        var writes = try newTradingAccounts.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .accounts)
        }
        writes.append(
            try RecordWrite(entry, id: entry.id.uuidString, in: .journalEntries)
        )
        try await requireStore().write(writes)
        accounts.append(contentsOf: newTradingAccounts)
        entries.insert(entry, at: 0)
    }

    func deleteEntry(id: UUID) async throws {
        try await requireStore().remove(id: id.uuidString, from: .journalEntries)
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

        try await requireStore().upsert(
            updated,
            id: updated.id.uuidString,
            in: .budgetNodes
        )
        budgetNodes = candidate
    }

    func addScheduledTransaction(_ transaction: ScheduledTransaction) async throws {
        try await requireStore().upsert(
            transaction,
            id: transaction.id.uuidString,
            in: .scheduledTransactions
        )
        scheduledTransactions.append(transaction)
        scheduledTransactions.sort { $0.nextOccurrence < $1.nextOccurrence }
    }

    func deleteScheduledTransaction(id: UUID) async throws {
        try await requireStore().remove(id: id.uuidString, from: .scheduledTransactions)
        scheduledTransactions.removeAll { $0.id == id }
    }

    func addInvestmentHolding(_ holding: InvestmentHolding) async throws {
        try await requireStore().upsert(
            holding,
            id: holding.id.uuidString,
            in: .investmentHoldings
        )
        investmentHoldings.append(holding)
    }

    func deleteInvestmentHolding(id: UUID) async throws {
        try await requireStore().remove(id: id.uuidString, from: .investmentHoldings)
        investmentHoldings.removeAll { $0.id == id }
    }

    func updateLockWhenBackgrounded(_ enabled: Bool) async throws {
        guard var updated = profile else { throw AppModelError.missingRecord }
        updated.lockWhenBackgrounded = enabled
        try await requireStore().upsert(
            updated,
            id: UserProfile.primaryRecordID,
            in: .profile
        )
        profile = updated
    }

    func eraseAllDataAndRestart() async {
        guard !isWorking else { return }
        isWorking = true
        let storeToClose = store
        store = nil
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
            clearDecodedState()
            state = .launching
            isWorking = false
            await start()
        } catch {
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
        let trend = period.monthSpan >= ReportPeriod.sixMonths.monthSpan
            ? interval
            : ReportPeriod.sixMonths.interval(containing: Date()) ?? interval
        guard let built = try? FinanceCalculator.report(
            interval: interval,
            trendInterval: trend,
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

    func csvExport() -> String {
        LedgerCSVExporter.export(
            entries.sorted { $0.occurredAt < $1.occurredAt },
            accounts: accounts
        )
    }

    private func invalidateDerivedData() {
        reportCache.removeAll()
        balanceCache = nil
    }

    private func accountBalances() -> [UUID: [CurrencyCode: Money]] {
        if let balanceCache { return balanceCache }
        let computed = (try? FinanceCalculator.balancesByAccount(entries: entries))
            ?? [:]
        balanceCache = computed
        return computed
    }

    private func save(_ entry: JournalEntry) async throws {
        try await requireStore().upsert(
            entry,
            id: entry.id.uuidString,
            in: .journalEntries
        )
        entries.insert(entry, at: 0)
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
    }

    private func discardIncompleteOnboarding(
        from store: EncryptedRecordStore
    ) async throws {
        try await store.removeAll(from: .accounts)
        try await store.removeAll(from: .journalEntries)
        try await store.removeAll(from: .budgetNodes)
        try await store.removeAll(from: .scheduledTransactions)
        try await store.removeAll(from: .investmentHoldings)
        clearDecodedState()
    }

    private func requireStore() throws -> EncryptedRecordStore {
        guard let store else { throw AppModelError.locked }
        return store
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
        profile = nil
        accounts = []
        entries = []
        budgetNodes = []
        scheduledTransactions = []
        investmentHoldings = []
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
        }
    }
}
