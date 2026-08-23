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
    @Published private(set) var profile: UserProfile?
    @Published private(set) var accounts: [LedgerAccount] = []
    @Published private(set) var entries: [JournalEntry] = []
    @Published private(set) var budgetNodes: [BudgetNode] = []
    @Published private(set) var scheduledTransactions: [ScheduledTransaction] = []
    @Published private(set) var investmentHoldings: [InvestmentHolding] = []
    @Published private(set) var isWorking = false

    private var store: EncryptedRecordStore?

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

    func completeOnboarding(
        baseCurrencyCode: String,
        accountName: String,
        accountType: FinancialAccountType
    ) async throws {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        let store = try requireStore()
        let currency = try CurrencyCode(baseCurrencyCode)
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

        for account in defaults.accounts {
            try await store.upsert(account, id: account.id.uuidString, in: .accounts)
        }
        for node in defaults.budgetNodes {
            try await store.upsert(node, id: node.id.uuidString, in: .budgetNodes)
        }

        // The profile is the onboarding commit marker and is intentionally last.
        let newProfile = UserProfile(baseCurrency: currency)
        try await store.upsert(
            newProfile,
            id: UserProfile.primaryRecordID,
            in: .profile
        )

        profile = newProfile
        accounts = defaults.accounts
        budgetNodes = defaults.budgetNodes
        state = .ready
    }

    func addAccount(
        name: String,
        type: FinancialAccountType,
        currencyCode: String
    ) async throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { throw AppModelError.emptyName }
        let currency = try CurrencyCode(currencyCode)
        let account = LedgerAccount(
            name: normalizedName,
            kind: type == .creditCard || type == .loan ? .liability : .asset,
            currency: currency,
            accountType: type
        )
        try await requireStore().upsert(account, id: account.id.uuidString, in: .accounts)
        accounts.append(account)
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
        try await store.upsert(category, id: category.id.uuidString, in: .accounts)

        if kind == .expense, let currency = profile?.baseCurrency {
            let node = BudgetNode(
                id: category.id,
                parentID: parentID,
                name: normalizedName,
                limit: nil
            )
            _ = try BudgetTree(currency: currency, nodes: budgetNodes + [node])
            try await store.upsert(node, id: node.id.uuidString, in: .budgetNodes)
            budgetNodes.append(node)
        }
        accounts.append(category)
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
        sourceAccountID: UUID,
        destinationAccountID: UUID,
        occurredAt: Date,
        note: String?
    ) async throws {
        let sourceCurrency = try currency(for: sourceAccountID)
        let destinationCurrency = try currency(for: destinationAccountID)
        guard sourceCurrency == destinationCurrency else {
            throw AppModelError.foreignCurrencyTransferRequiresExchangeRate
        }
        let entry = try TransactionFactory.transfer(
            amount: try Money(amount, currency: sourceCurrency),
            from: sourceAccountID,
            to: destinationAccountID,
            occurredAt: occurredAt,
            note: note
        )
        try await save(entry)
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

    func addInvestmentHolding(_ holding: InvestmentHolding) async throws {
        try await requireStore().upsert(
            holding,
            id: holding.id.uuidString,
            in: .investmentHoldings
        )
        investmentHoldings.append(holding)
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
        try? FinanceCalculator.displayBalance(for: account, entries: entries)
    }

    func spendingThisMonth() -> [UUID: Money] {
        guard let currency = profile?.baseCurrency,
              let interval = Calendar.current.dateInterval(of: .month, for: Date()) else {
            return [:]
        }
        return (try? FinanceCalculator.spendingByCategory(
            accounts: accounts,
            entries: entries,
            currency: currency,
            interval: interval
        )) ?? [:]
    }

    func budgetProgressThisMonth() -> [BudgetProgress] {
        guard let currency = profile?.baseCurrency,
              let tree = try? BudgetTree(currency: currency, nodes: budgetNodes) else {
            return []
        }
        return (try? tree.progress(directSpending: spendingThisMonth())) ?? []
    }

    func csvExport() -> String {
        LedgerCSVExporter.export(entries.sorted { $0.occurredAt < $1.occurredAt })
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

    private func clearDecodedState() {
        profile = nil
        accounts = []
        entries = []
        budgetNodes = []
        scheduledTransactions = []
        investmentHoldings = []
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
        return ([mainAccount] + expenseAccounts + [salary, otherIncome], nodes)
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
        }
    }
}
