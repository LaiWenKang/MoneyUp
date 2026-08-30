import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

extension AppModel {
    func clearDecodedState() {
        journalProjectionRevision &+= 1
        journalDerivedRefreshTask?.cancel()
        journalDerivedRefreshTask = nil
        journalDerivedRefreshTaskToken = nil
        journalDerivedRefreshWasDeferred = false
        quickLogDraftWriteTask?.cancel()
        quickLogDraftWriteTask = nil
        profile = nil
        accounts = []
        entries = []
        journalEntryCount = 0
        journalRecentEntriesAreCurrent = false
        journalStoredEntryCount = 0
        journalReferenceCounts = [:]
        journalReferenceCountsAreCurrent = false
        invalidJournalEntryIDs = []
        investmentLinkedEntriesByID = [:]
        existingScheduledLinkedEntryIDs = []
        budgetNodes = []
        budgetConfigurationTimeline = nil
        budgetConfigurationTimelineInvalid = false
        budgetEntryAttributions = [:]
        budgetAttributionCacheIsComplete = false
        closedMonthBudgetProjection = nil
        scheduledTransactions = []
        investmentHoldings = []
        receiptAttachmentMetadata = []
        exchangeRates = []
        netWorthSnapshots = []
        savingsGoals = []
        quickLogDraft = nil
        recoveryIssues = []
    }

    func validateLoadedBook() throws {
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
        for item in scheduledTransactions {
            guard accountIDs.contains(item.accountID),
                  accountIDs.contains(item.categoryAccountID) else {
                throw AppModelError.invalidBook
            }
            do {
                try item.validateLifecycle(calendar: reportingCalendar)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AppModelError.invalidBook
            }
        }
        let scheduledLinkedEntryIDs = scheduledTransactions.flatMap {
            $0.resolutions.compactMap(\.linkedEntryID)
        }
        let knownScheduledEntryIDs = retainsCompleteJournal
            ? Set(entries.map(\.id))
            : existingScheduledLinkedEntryIDs
        guard Set(scheduledLinkedEntryIDs).count == scheduledLinkedEntryIDs.count,
              Set(scheduledLinkedEntryIDs).isSubset(of: knownScheduledEntryIDs) else {
            throw AppModelError.invalidBook
        }
        guard Set(investmentHoldings.map(\.id)).count == investmentHoldings.count else {
            throw AppModelError.invalidBook
        }
        let linkedPositionIDs = investmentHoldings.compactMap(\.positionAccountID)
        guard Set(linkedPositionIDs).count == linkedPositionIDs.count else {
            throw AppModelError.invalidBook
        }
        let allHoldingEntryIDs = investmentHoldings.flatMap {
            Array($0.linkedEntryIDs)
        }
        guard Set(allHoldingEntryIDs).count == allHoldingEntryIDs.count else {
            throw AppModelError.invalidBook
        }
        let knownLinkedEntries = retainsCompleteJournal
            ? Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
            : investmentLinkedEntriesByID
        let balances: [UUID: [CurrencyCode: Money]]
        switch accountBalancesResult() {
        case let .available(value):
            balances = value
        case .unavailable:
            throw AppModelError.invalidBook
        }
        for holding in investmentHoldings {
            guard let funding = accountsByID[holding.accountID],
                  isInvestmentFundingAccountShape(funding),
                  holding.isArchived || !funding.isArchived else {
                throw AppModelError.invalidBook
            }
            let holdingCurrencies = Set(
                [holding.price?.currency]
                    + holding.priceHistory.map { Optional($0.price.currency) }
                    + holding.lots.map { Optional($0.unitCost.currency) }
                    + holding.disposals.flatMap {
                        [Optional($0.costBasis.currency), Optional($0.proceeds.currency),
                         Optional($0.realizedGainLoss.currency)]
                    }
            ).compactMap { $0 }
            guard holdingCurrencies.allSatisfy({ $0 == funding.currency }) else {
                throw AppModelError.invalidBook
            }
            guard let positionID = holding.positionAccountID else {
                guard !holding.isArchived,
                      holding.linkedEntryIDs.isEmpty,
                      holding.quantity == .zero || holding.needsLedgerConnection else {
                    throw AppModelError.invalidBook
                }
                continue
            }
            guard positionID != funding.id,
                  let currency = funding.currency,
                  let position = accountsByID[positionID],
                  position.kind == .asset,
                  position.systemRole == .investmentPosition,
                  position.currency == currency,
                  position.isArchived == holding.isArchived else {
                throw AppModelError.invalidBook
            }
            do {
                try InvestmentLedgerIntegrity.validate(
                    holding: holding,
                    accountsByID: accountsByID,
                    entriesByID: knownLinkedEntries
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AppModelError.invalidBook
            }
            let expectedValue: Money
            do {
                expectedValue = try holding.marketValue()
                    ?? Money.zero(currency: currency)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AppModelError.invalidBook
            }
            let positionBalances = balances[positionID] ?? [:]
            guard positionBalances.allSatisfy({ pair in
                pair.key == funding.currency || pair.value.isZero
            }) else {
                throw AppModelError.invalidBook
            }
            let actualValue = positionBalances[currency]
                ?? Money.zero(currency: currency)
            guard actualValue == expectedValue else {
                throw AppModelError.invalidBook
            }
        }
        let linkedPositionArchiveState = Dictionary(
            uniqueKeysWithValues: investmentHoldings.compactMap { holding in
                holding.positionAccountID.map { ($0, holding.isArchived) }
            }
        )
        guard accounts.filter({ $0.systemRole == .investmentPosition }).allSatisfy({ position in
            if let shouldBeArchived = linkedPositionArchiveState[position.id] {
                return position.isArchived == shouldBeArchived
            }
            guard position.isArchived, let currency = position.currency else { return false }
            let positionBalances = balances[position.id] ?? [:]
            return positionBalances.allSatisfy({ pair in
                (pair.key == currency || pair.value.isZero) && pair.value.isZero
            })
        }) else {
            throw AppModelError.invalidBook
        }
        if retainsCompleteJournal {
            let entryIDs = Set(entries.map(\.id))
            let attachmentIDs = Set(receiptAttachmentMetadata.map(\.id))
            guard attachmentIDs.count == receiptAttachmentMetadata.count,
                  receiptAttachmentMetadata.allSatisfy({
                    entryIDs.contains($0.entryID)
                  }) else {
                throw AppModelError.invalidBook
            }
        }
        guard Set(savingsGoals.map(\.id)).count == savingsGoals.count else {
            throw AppModelError.invalidBook
        }
    }

    static func databaseURL() throws -> URL {
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

    static func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Idempotent completion shared by an in-process erase and startup recovery.
    /// The high-value book key is destroyed first; the marker remains durable
    /// until main/WAL/SHM, locked-inbox key/ciphertext, and every retryable step
    /// have completed successfully.
    static func completePendingDataErase(
        databaseURL: URL,
        deleteDatabaseKey: @Sendable () throws -> Void,
        lockedCaptureStore: any LockedCaptureStoring,
        clearEraseIntent: @Sendable () throws -> Void
    ) async throws {
        try deleteDatabaseKey()
        for artifactURL in DatabaseKeyCreationPolicy.artifactURLs(
            for: databaseURL
        ) {
            try removeIfPresent(artifactURL)
        }
        try await lockedCaptureStore.eraseAll()
        try clearEraseIntent()
    }

    static func defaultBook(
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
    case amountTooLarge
    case crossCurrencyEditRequiresConversion
    case importTooLarge
    case ledgerItemInUse
    case incompatibleLedgerItems
    case systemAccountLifecycleForbidden
    case ledgerItemArchived
    case scheduleEntryMismatch
    case scheduleEntryAlreadyMatched
    case restoreRecoveryFailed
    case investmentCurrencyMismatch
    case investmentNeedsLedgerConnection
    case missingInvestmentPrice
    case investmentHoldingNotEmpty
    case invalidInvestmentTrade
    case insufficientInvestmentQuantity
    case investmentDateOutOfOrder
    case investmentDateInFuture
    case investmentEntryMutationForbidden
    case legacyInvestmentSnapshotForbidden
    case invalidGoal
    case goalWithdrawalExceedsBalance
    case pendingLockedCaptures
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
        case .amountTooLarge:
            String(localized: "error.amount_too_large")
        case .crossCurrencyEditRequiresConversion:
            String(localized: "error.cross_currency_edit")
        case .importTooLarge: String(localized: "import.error.too_large")
        case .ledgerItemInUse: String(localized: "lifecycle.error.in_use")
        case .incompatibleLedgerItems:
            String(localized: "lifecycle.error.incompatible")
        case .systemAccountLifecycleForbidden:
            String(localized: "lifecycle.error.system_account")
        case .ledgerItemArchived: String(localized: "lifecycle.error.archived")
        case .scheduleEntryMismatch: String(localized: "schedule.error.entry_mismatch")
        case .scheduleEntryAlreadyMatched:
            String(localized: "schedule.error.entry_already_matched")
        case .restoreRecoveryFailed:
            String(localized: "error.restore_recovery_failed")
        case .investmentCurrencyMismatch:
            String(localized: "holding.error.currency_mismatch")
        case .investmentNeedsLedgerConnection:
            String(localized: "holding.error.needs_ledger")
        case .missingInvestmentPrice:
            String(localized: "holding.error.missing_price")
        case .investmentHoldingNotEmpty:
            String(localized: "holding.error.not_empty")
        case .invalidInvestmentTrade:
            String(localized: "holding.error.invalid_trade")
        case .insufficientInvestmentQuantity:
            String(localized: "holding.error.insufficient_quantity")
        case .investmentDateOutOfOrder:
            String(localized: "holding.error.date_out_of_order")
        case .investmentDateInFuture:
            String(localized: "holding.error.date_in_future")
        case .investmentEntryMutationForbidden:
            String(localized: "holding.error.linked_entry_protected")
        case .legacyInvestmentSnapshotForbidden:
            String(localized: "holding.error.snapshot_needs_ledger")
        case .invalidGoal: String(localized: "goal.error.invalid")
        case .goalWithdrawalExceedsBalance:
            String(localized: "goal.error.withdrawal_exceeds_balance")
        case .pendingLockedCaptures:
            String(localized: "backup.error.pending_captures")
        }
    }
}
