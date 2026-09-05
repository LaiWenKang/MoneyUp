import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

private struct LoadedInvestmentValidationContext {
    let linkedEntriesByID: [UUID: JournalEntry]
    let balances: [UUID: [CurrencyCode: Money]]
}

extension AppModel {
    func clearDecodedState() {
        logicalBookRevision &+= 1
        invalidateWidgetIntelligencePublication()
        intelligenceService.cancelPendingWork()
        journalProjectionRevision &+= 1
        journalDerivedRefreshTask?.cancel()
        journalDerivedRefreshTask = nil
        journalDerivedRefreshTaskToken = nil
        journalDerivedRefreshWasDeferred = false
        quickLogDraftWriteTask?.cancel()
        quickLogDraftWriteTask = nil
        presentedQuickLogRequest = nil
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
        loanPlans = []
        allowancePlans = []
        quickLogDraft = nil
        recoveryIssues = []
        pendingRestoreCompletionAnnouncement = nil
    }

    func validateLoadedBook() throws {
        guard let profile else { return }
        let accountIDs = try validateLoadedAccountsAndJournal(profile: profile)
        try validateLoadedSchedules(accountIDs: accountIDs)
        let investmentContext = try loadedInvestmentValidationContext()
        for holding in investmentHoldings {
            try validateLoadedHolding(
                holding,
                context: investmentContext
            )
        }
        try validateLoadedInvestmentPositions(
            balances: investmentContext.balances
        )
        try validateLoadedAttachmentsAndGoals()
        try validateLoadedLoanAndAllowancePlans(accountIDs: accountIDs)
    }

    private func validateLoadedLoanAndAllowancePlans(
        accountIDs: Set<UUID>
    ) throws {
        let loanAccountIDs = Set(accounts.filter {
            $0.kind == .liability && $0.accountType == .loan
        }.map(\.id))
        let expenseCategoryIDs = Set(accounts.filter { $0.kind == .expense }.map(\.id))
        let loadedAccountsByID = Dictionary(
            accounts.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let activePrepaidLinks = allowancePlans.compactMap { plan -> UUID? in
            guard !plan.isArchived,
                  plan.fundingMode == .prepaidAsset,
                  Self.allowanceFundingCompatibility(
                      for: plan,
                      accountsByID: loadedAccountsByID
                  ) == .current else {
                return nil
            }
            return plan.linkedAccountID
        }
        guard Set(loanPlans.map(\.id)).count == loanPlans.count,
              Set(loanPlans.map(\.accountID)).count == loanPlans.count,
              loanAccountIDs.isSubset(of: accountIDs),
              loanPlans.allSatisfy({ plan in
                  loanAccountIDs.contains(plan.accountID)
                      && (plan.interestExpenseAccountID.map(
                          expenseCategoryIDs.contains
                      ) ?? true)
                      && (plan.feeExpenseAccountID.map(
                          expenseCategoryIDs.contains
                      ) ?? true)
              }),
              Set(allowancePlans.map(\.id)).count == allowancePlans.count,
              Set(activePrepaidLinks).count == activePrepaidLinks.count,
              allowancePlans.allSatisfy({ plan in
                  plan.policyRevisions.allSatisfy {
                      $0.eligibleCategoryIDs.isSubset(of: expenseCategoryIDs)
                  }
                      && Self.allowanceFundingCompatibility(
                          for: plan,
                          accountsByID: loadedAccountsByID
                      ) != .invalid
                      && plan.usages.allSatisfy { usage in
                          usage.categoryID.map(expenseCategoryIDs.contains) ?? true
                      }
              }) else {
            throw AppModelError.invalidBook
        }
    }

    private func validateLoadedAccountsAndJournal(
        profile: UserProfile
    ) throws -> Set<UUID> {
        let accountIDs = Set(accounts.map(\.id))
        guard accountIDs.count == accounts.count else { throw AppModelError.invalidBook }

        for account in accounts {
            if let parentID = account.parentID, !accountIDs.contains(parentID) {
                throw AppModelError.invalidBook
            }
            if account.accountType == .restrictedAllowance {
                guard account.kind == .asset,
                      account.currency != nil,
                      account.systemRole == nil,
                      account.parentID == nil else {
                    throw AppModelError.invalidBook
                }
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
        try validateLoadedRestrictedAllowanceLedgers()
        return accountIDs
    }

    private func validateLoadedRestrictedAllowanceLedgers() throws {
        let restrictedCurrencies: [UUID: CurrencyCode] = Dictionary(
            uniqueKeysWithValues: accounts.compactMap { account in
                guard account.accountType == .restrictedAllowance,
                      let currency = account.currency else { return nil }
                return (account.id, currency)
            }
        )
        guard !restrictedCurrencies.isEmpty else { return }
        if retainsCompleteJournal {
            let restrictedIDs = Set(restrictedCurrencies.keys)
            do {
                let events = try RestrictedAllowanceLedgerInvariant.events(
                    for: entries,
                    restrictedAccountIDs: restrictedIDs,
                    observesCancellation: true
                )
                try RestrictedAllowanceLedgerInvariant.requireValid(
                    expectedCurrencies: restrictedCurrencies,
                    events: events
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AppModelError.invalidBook
            }
            return
        }
        guard case let .available(balances) = accountBalancesResult(),
              restrictedCurrencies.allSatisfy({ accountID, currency in
                  let accountBalances = balances[accountID] ?? [:]
                  return accountBalances.allSatisfy {
                      $0.key == currency || $0.value.isZero
                  } && (accountBalances[currency]?.amount ?? .zero) >= .zero
              }) else {
            throw AppModelError.invalidBook
        }
    }

    private func validateLoadedSchedules(
        accountIDs: Set<UUID>
    ) throws {
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
    }

    private func loadedInvestmentValidationContext()
    throws -> LoadedInvestmentValidationContext {
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
        return LoadedInvestmentValidationContext(
            linkedEntriesByID: knownLinkedEntries,
            balances: balances
        )
    }

    private func validateLoadedHolding(
        _ holding: InvestmentHolding,
        context: LoadedInvestmentValidationContext
    ) throws {
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
            return
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
                entriesByID: context.linkedEntriesByID
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
        let positionBalances = context.balances[positionID] ?? [:]
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

    private func validateLoadedInvestmentPositions(
        balances: [UUID: [CurrencyCode: Money]]
    ) throws {
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
    }

    private func validateLoadedAttachmentsAndGoals() throws {
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
        removeKeyCliffRecoveryArtifacts: @Sendable () throws -> Void = {},
        clearEraseIntent: @Sendable () throws -> Void
    ) async throws {
        try deleteDatabaseKey()
        for artifactURL in DatabaseKeyCreationPolicy.artifactURLs(
            for: databaseURL
        ) {
            try removeIfPresent(artifactURL)
        }
        try removeKeyCliffRecoveryArtifacts()
        try await lockedCaptureStore.eraseAll()
        try clearEraseIntent()
    }

    static func defaultBook(
        mainAccount: LedgerAccount
    ) -> (accounts: [LedgerAccount], budgetNodes: [BudgetNode]) {
        let openingBalances = LedgerAccount(
            name: AppLocalization.string("account.opening_balances"),
            kind: .equity,
            systemRole: .openingBalances
        )
        let essentials = LedgerAccount(name: AppLocalization.string("category.essentials"), kind: .expense)
        let food = LedgerAccount(
            name: AppLocalization.string("category.food"),
            kind: .expense,
            parentID: essentials.id
        )
        let transport = LedgerAccount(
            name: AppLocalization.string("category.transport"),
            kind: .expense,
            parentID: essentials.id
        )
        let housing = LedgerAccount(name: AppLocalization.string("category.housing"), kind: .expense)
        let rent = LedgerAccount(
            name: AppLocalization.string("category.rent"),
            kind: .expense,
            parentID: housing.id
        )
        let utilities = LedgerAccount(
            name: AppLocalization.string("category.utilities"),
            kind: .expense,
            parentID: housing.id
        )
        let lifestyle = LedgerAccount(name: AppLocalization.string("category.lifestyle"), kind: .expense)
        let shopping = LedgerAccount(
            name: AppLocalization.string("category.shopping"),
            kind: .expense,
            parentID: lifestyle.id
        )
        let entertainment = LedgerAccount(
            name: AppLocalization.string("category.entertainment"),
            kind: .expense,
            parentID: lifestyle.id
        )
        let salary = LedgerAccount(name: AppLocalization.string("category.salary"), kind: .income)
        let otherIncome = LedgerAccount(name: AppLocalization.string("category.other_income"), kind: .income)
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
    case restorePreviewChanged
    case restorePreviewRequired
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
    case invalidLoan
    case loanOverpayment
    case loanNotPaidOff
    case invalidAllowance
    case allowanceClaimRemovalConfirmationRequired
    case invalidCategoryParent
}

extension AppModelError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .locked: AppLocalization.string("error.app_locked")
        case .emptyName: AppLocalization.string("error.empty_name")
        case .invalidCategoryKind: AppLocalization.string("error.invalid_category")
        case .missingRecord: AppLocalization.string("error.missing_record")
        case .negativeAmount: AppLocalization.string("error.negative_amount")
        case .accountHasNoCurrency: AppLocalization.string("error.account_currency")
        case .foreignCurrencyTransferRequiresExchangeRate:
            AppLocalization.string("error.fx_transfer_not_supported")
        case .invalidBook: AppLocalization.string("error.invalid_book")
        case .transactionInProgress: AppLocalization.string("error.transaction_in_progress")
        case let .unsupportedPrecision(currency):
            String(
                format: AppLocalization.string("error.currency_precision"),
                currency.value,
                currency.minorUnits
            )
        case .amountTooLarge:
            AppLocalization.string("error.amount_too_large")
        case .crossCurrencyEditRequiresConversion:
            AppLocalization.string("error.cross_currency_edit")
        case .importTooLarge: AppLocalization.string("import.error.too_large")
        case .ledgerItemInUse: AppLocalization.string("lifecycle.error.in_use")
        case .incompatibleLedgerItems:
            AppLocalization.string("lifecycle.error.incompatible")
        case .systemAccountLifecycleForbidden:
            AppLocalization.string("lifecycle.error.system_account")
        case .ledgerItemArchived: AppLocalization.string("lifecycle.error.archived")
        case .scheduleEntryMismatch: AppLocalization.string("schedule.error.entry_mismatch")
        case .scheduleEntryAlreadyMatched:
            AppLocalization.string("schedule.error.entry_already_matched")
        case .restoreRecoveryFailed:
            AppLocalization.string("error.restore_recovery_failed")
        case .restorePreviewChanged:
            AppLocalization.string("restore.error.preview_changed")
        case .restorePreviewRequired:
            AppLocalization.string("restore.error.preview_required")
        case .investmentCurrencyMismatch:
            AppLocalization.string("holding.error.currency_mismatch")
        case .investmentNeedsLedgerConnection:
            AppLocalization.string("holding.error.needs_ledger")
        case .missingInvestmentPrice:
            AppLocalization.string("holding.error.missing_price")
        case .investmentHoldingNotEmpty:
            AppLocalization.string("holding.error.not_empty")
        case .invalidInvestmentTrade:
            AppLocalization.string("holding.error.invalid_trade")
        case .insufficientInvestmentQuantity:
            AppLocalization.string("holding.error.insufficient_quantity")
        case .investmentDateOutOfOrder:
            AppLocalization.string("holding.error.date_out_of_order")
        case .investmentDateInFuture:
            AppLocalization.string("holding.error.date_in_future")
        case .investmentEntryMutationForbidden:
            AppLocalization.string("holding.error.linked_entry_protected")
        case .legacyInvestmentSnapshotForbidden:
            AppLocalization.string("holding.error.snapshot_needs_ledger")
        case .invalidGoal: AppLocalization.string("goal.error.invalid")
        case .goalWithdrawalExceedsBalance:
            AppLocalization.string("goal.error.withdrawal_exceeds_balance")
        case .pendingLockedCaptures:
            AppLocalization.string("backup.error.pending_captures")
        case .invalidLoan: AppLocalization.string("loan.error.invalid")
        case .loanOverpayment: AppLocalization.string("loan.error.overpayment")
        case .loanNotPaidOff: AppLocalization.string("loan.error.not_paid_off")
        case .invalidAllowance: AppLocalization.string("allowance.error.invalid")
        case .allowanceClaimRemovalConfirmationRequired:
            AppLocalization.string(
                "allowance.claim.edit_invalidation_confirmation_detail"
            )
        case .invalidCategoryParent:
            AppLocalization.string("lifecycle.error.invalid_parent")
        }
    }
}
