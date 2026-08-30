import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

extension AppModel {
    func validateLifecycleRelationshipCandidates(
        accounts candidateAccounts: [LedgerAccount],
        entries candidateEntries: [JournalEntry],
        schedules candidateSchedules: [ScheduledTransaction],
        holdings candidateHoldings: [InvestmentHolding]
    ) throws {
        guard Set(candidateAccounts.map(\.id)).count == candidateAccounts.count,
              Set(candidateSchedules.map(\.id)).count == candidateSchedules.count,
              Set(candidateHoldings.map(\.id)).count == candidateHoldings.count else {
            throw AppModelError.invalidBook
        }
        let accountsByID = Dictionary(
            uniqueKeysWithValues: candidateAccounts.map { ($0.id, $0) }
        )
        for schedule in candidateSchedules {
            try validateScheduleReferences(schedule, in: accountsByID)
            try schedule.validateLifecycle(calendar: reportingCalendar)
        }
        let scheduleLinks = candidateSchedules.flatMap {
            $0.resolutions.compactMap(\.linkedEntryID)
        }
        guard Set(scheduleLinks).count == scheduleLinks.count else {
            throw AppModelError.invalidBook
        }

        var entriesByID: [UUID: JournalEntry] = [:]
        for entry in candidateEntries {
            guard entriesByID.updateValue(entry, forKey: entry.id) == nil else {
                throw AppModelError.invalidBook
            }
        }
        var positionOwners = Set<UUID>()
        var entryOwners = Set<UUID>()
        for holding in candidateHoldings {
            let isUnconnectedLegacyHolding = holding.positionAccountID == nil
            guard let funding = accountsByID[holding.accountID],
                  (isUnconnectedLegacyHolding
                    ? funding.kind == .asset
                        && funding.systemRole == nil
                        && funding.currency != nil
                    : isInvestmentFundingAccountShape(funding)),
                  holding.isArchived || !funding.isArchived else {
                throw AppModelError.incompatibleLedgerItems
            }
            guard holding.linkedEntryIDs.isDisjoint(with: entryOwners) else {
                throw AppModelError.invalidBook
            }
            entryOwners.formUnion(holding.linkedEntryIDs)
            guard let positionID = holding.positionAccountID else {
                guard !holding.isArchived,
                      holding.linkedEntryIDs.isEmpty,
                      holding.quantity == .zero || holding.needsLedgerConnection else {
                    throw AppModelError.invalidBook
                }
                continue
            }
            guard positionOwners.insert(positionID).inserted,
                  let position = accountsByID[positionID],
                  position.isArchived == holding.isArchived else {
                throw AppModelError.invalidBook
            }
            do {
                try InvestmentLedgerIntegrity.validate(
                    holding: holding,
                    accountsByID: accountsByID,
                    entriesByID: entriesByID
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AppModelError.invalidBook
            }
        }
    }

    func accountsAfterReassigningCategoryHierarchy(
        source: LedgerAccount,
        target: LedgerAccount
    ) throws -> [LedgerAccount] {
        var candidate = accounts.filter { $0.id != source.id }
        guard source.kind == .expense || source.kind == .income else { return candidate }

        let targetWasDescendant = isDescendant(
            target.id,
            of: source.id,
            in: accounts
        )
        for index in candidate.indices {
            if candidate[index].id == target.id, targetWasDescendant {
                candidate[index].parentID = source.parentID
            } else if candidate[index].parentID == source.id {
                candidate[index].parentID = target.id
            }
        }
        try validateCategoryHierarchy(accounts: candidate)
        return candidate
    }

    func budgetsAfterReassigningCategoryHierarchy(
        source: LedgerAccount,
        target: LedgerAccount,
        candidateAccounts: [LedgerAccount]
    ) throws -> [BudgetNode] {
        guard source.kind == .expense else { return budgetNodes }
        guard let currency = profile?.baseCurrency else { throw AppModelError.invalidBook }

        let sourceNode = budgetNodes.first { $0.id == source.id }
        var candidate = budgetNodes.filter { $0.id != source.id }
        let accountByID = Dictionary(
            uniqueKeysWithValues: candidateAccounts.map { ($0.id, $0) }
        )

        if let sourceNode {
            if let targetIndex = candidate.firstIndex(where: { $0.id == target.id }) {
                if let sourceLimit = sourceNode.limit {
                    if let targetLimit = candidate[targetIndex].limit {
                        candidate[targetIndex].limit = try targetLimit.adding(sourceLimit)
                    } else {
                        candidate[targetIndex].limit = sourceLimit
                    }
                }
                if candidate[targetIndex].purpose == .unclassified {
                    candidate[targetIndex].purpose = sourceNode.purpose
                }
                if candidate[targetIndex].rolloverRule == .none,
                   sourceNode.rolloverRule != .none {
                    candidate[targetIndex].rolloverRule = sourceNode.rolloverRule
                    candidate[targetIndex].rolloverStartedAt = sourceNode.rolloverStartedAt
                }
            } else {
                candidate.append(
                    BudgetNode(
                        id: target.id,
                        parentID: accountByID[target.id]?.parentID,
                        name: target.name,
                        limit: sourceNode.limit,
                        purpose: sourceNode.purpose,
                        rolloverRule: sourceNode.rolloverRule,
                        rolloverStartedAt: sourceNode.rolloverStartedAt
                    )
                )
            }
        }

        let directlyAffectedIDs = Set(
            [target.id] + budgetNodes.filter { $0.parentID == source.id }.map(\.id)
        )
        for index in candidate.indices where directlyAffectedIDs.contains(candidate[index].id) {
            guard let account = accountByID[candidate[index].id] else {
                throw AppModelError.invalidBook
            }
            candidate[index].parentID = account.parentID
            if candidate[index].id == target.id {
                candidate[index].name = account.name
            }
        }

        _ = try BudgetTree(currency: currency, nodes: candidate)
        return candidate
    }

    func repoint(
        entry: JournalEntry,
        from sourceID: UUID,
        to targetID: UUID
    ) throws -> JournalEntry {
        let postings = entry.postings.map { posting in
            guard posting.accountID == sourceID else { return posting }
            return Posting(
                id: posting.id,
                accountID: targetID,
                money: posting.money,
                memo: posting.memo
            )
        }
        return try JournalEntry(
            id: entry.id,
            kind: entry.kind,
            occurredAt: entry.occurredAt,
            createdAt: entry.createdAt,
            payee: entry.payee,
            note: entry.note,
            postings: postings,
            supersedesID: entry.supersedesID,
            revisedAt: entry.revisedAt,
            sourceSystem: entry.sourceSystem,
            sourceFingerprint: entry.sourceFingerprint,
            originContext: entry.originContext
        )
    }

    func isDescendant(
        _ candidateID: UUID,
        of ancestorID: UUID,
        in sourceAccounts: [LedgerAccount]
    ) -> Bool {
        let parentByID = Dictionary(
            uniqueKeysWithValues: sourceAccounts.compactMap { account in
                account.parentID.map { (account.id, $0) }
            }
        )
        var currentID: UUID? = candidateID
        var visited = Set<UUID>()
        while let id = currentID, visited.insert(id).inserted {
            guard let parent = parentByID[id] else { return false }
            if parent == ancestorID { return true }
            currentID = parent
        }
        return false
    }

    func validateCategoryHierarchy(
        accounts candidateAccounts: [LedgerAccount]
    ) throws {
        guard try Self.invalidAccountHierarchyIDs(
            in: candidateAccounts
        ).isEmpty else {
            throw AppModelError.incompatibleLedgerItems
        }
    }

    func requireLifecycleEligible(_ account: LedgerAccount) throws {
        guard account.systemRole == nil else {
            throw AppModelError.systemAccountLifecycleForbidden
        }
        guard account.kind == .asset
                || account.kind == .liability
                || account.kind == .expense
                || account.kind == .income else {
            throw AppModelError.incompatibleLedgerItems
        }
    }

    func lifecycleAuditWrite(
        _ audit: LedgerAccountLifecycleAudit
    ) throws -> RecordWrite {
        try RecordWrite(
            audit,
            id: audit.id.uuidString,
            in: .accountLifecycleAudit
        )
    }

    func clearReferences(to id: UUID, in profile: inout UserProfile?) {
        guard var updated = profile else { return }
        if updated.preferredAccountID == id { updated.preferredAccountID = nil }
        if updated.preferredExpenseCategoryID == id {
            updated.preferredExpenseCategoryID = nil
        }
        if updated.preferredIncomeCategoryID == id {
            updated.preferredIncomeCategoryID = nil
        }
        profile = updated
    }

    func clearReferences(to id: UUID, in draft: inout QuickLogDraft?) {
        guard var updated = draft else { return }
        if updated.accountID == id { updated.accountID = nil }
        if updated.destinationAccountID == id { updated.destinationAccountID = nil }
        if updated.categoryID == id { updated.categoryID = nil }
        draft = updated
    }

    func repointReferences(
        from sourceID: UUID,
        to targetID: UUID,
        in profile: inout UserProfile?
    ) {
        guard var updated = profile else { return }
        if updated.preferredAccountID == sourceID { updated.preferredAccountID = targetID }
        if updated.preferredExpenseCategoryID == sourceID {
            updated.preferredExpenseCategoryID = targetID
        }
        if updated.preferredIncomeCategoryID == sourceID {
            updated.preferredIncomeCategoryID = targetID
        }
        profile = updated
    }

    func repointReferences(
        from sourceID: UUID,
        to targetID: UUID,
        in draft: inout QuickLogDraft?
    ) {
        guard var updated = draft else { return }
        if updated.accountID == sourceID { updated.accountID = targetID }
        if updated.destinationAccountID == sourceID {
            updated.destinationAccountID = targetID
        }
        if updated.categoryID == sourceID { updated.categoryID = targetID }
        if updated.accountID == updated.destinationAccountID {
            updated.destinationAccountID = nil
        }
        draft = updated
    }

    func finishPendingQuickLogDraftWrite() async {
        while let pendingWrite = quickLogDraftWriteTask {
            quickLogDraftWriteTask = nil
            pendingWrite.cancel()
            await pendingWrite.value
        }
    }

    /// Creates an exact durable draft boundary for a backup. Unlike restore's
    /// authoritative replacement barrier, backup must not cancel a debounce:
    /// cancellation can discard the newest form revision. Await the chain and
    /// then write the in-memory value with error propagation before snapshot.
    func flushQuickLogDraftForBackup(
        to backupStore: EncryptedRecordStore
    ) async throws {
        await quickLogDraftWriteTask?.value
        if let quickLogDraft {
            try await backupStore.upsert(
                quickLogDraft,
                id: QuickLogDraft.primaryRecordID,
                in: .quickLogDrafts
            )
        } else {
            try await backupStore.remove(
                id: QuickLogDraft.primaryRecordID,
                from: .quickLogDrafts
            )
        }
    }

    func requireEmptyLockedCaptureInbox() async throws {
        do {
            let captures = try await lockedCaptureStore.all()
            pendingLockedCaptureCount = captures.count
            recoveryIssues.removeAll { $0.hasPrefix("locked_captures/") }
            guard captures.isEmpty else {
                throw AppModelError.pendingLockedCaptures
            }
        } catch let error as LockedCaptureStoreError {
            recordLockedCaptureStoreIssue(error)
            throw error
        }
    }

    /// Explicitly discards only an inbox that is already cryptographically
    /// unreadable. The authenticated main book remains untouched, restoring
    /// backup/restore availability without pretending the lost captures can
    /// be recovered.
    func discardUnavailableLockedCaptures() async throws {
        let hasUsableRecoveryStore: Bool
        switch state {
        case .ready, .onboarding:
            hasUsableRecoveryStore = true
        case .failed:
            hasUsableRecoveryStore = store != nil
        case .launching, .locked:
            hasUsableRecoveryStore = false
        }
        guard hasUsableRecoveryStore, lockedCaptureInboxIsUnrecoverable else {
            throw AppModelError.missingRecord
        }
        try beginLifecycleMutation(invalidatesJournalProjection: false)
        defer { endLifecycleMutation() }

        // The marker can outlive a transient Keychain state change. Re-read at
        // the destructive boundary: successful recovery or a retryable failure
        // must disable deletion, while only a fresh definitive failure permits
        // erasing the orphaned inbox.
        do {
            let captures = try await lockedCaptureStore.all()
            pendingLockedCaptureCount = captures.count
            recoveryIssues.removeAll { $0.hasPrefix("locked_captures/") }
            if captures.isEmpty {
                throw AppModelError.missingRecord
            }
            throw AppModelError.pendingLockedCaptures
        } catch let error as LockedCaptureStoreError {
            recordLockedCaptureStoreIssue(error)
            guard error.isDefinitivelyUnrecoverable else { throw error }
        }
        try await lockedCaptureStore.eraseAll()
        pendingLockedCaptureCount = 0
        recoveryIssues.removeAll { $0.hasPrefix("locked_captures/") }
    }

    func beginLifecycleMutation(
        invalidatesJournalProjection: Bool = true
    ) throws {
        guard !isLifecycleMutationInProgress,
              !isWorking,
              goalMutationsInProgress == 0,
              !goalMutationBarrierClosed,
              !isJournalMutationInProgress,
              scheduleMutationsInProgress.isEmpty,
              scheduleEntryMatchesInProgress.isEmpty,
              investmentMutationsInProgress.isEmpty else {
            throw AppModelError.transactionInProgress
        }
        isLifecycleMutationInProgress = true
        if invalidatesJournalProjection {
            invalidateInFlightJournalProjection()
        }
    }

    func beginStandaloneJournalMutation() throws {
        guard !isLifecycleMutationInProgress,
              !isWorking,
              !isJournalMutationInProgress,
              state == .ready else {
            throw AppModelError.transactionInProgress
        }
        standaloneJournalMutationsInProgress += 1
        invalidateInFlightJournalProjection()
    }

    func endStandaloneJournalMutation() {
        guard standaloneJournalMutationsInProgress > 0 else { return }
        standaloneJournalMutationsInProgress -= 1
        guard standaloneJournalMutationsInProgress == 0 else { return }
        applyDeferredLockIfPossible()
        resumeDeferredJournalDerivedRefreshIfPossible()
    }

    func endLifecycleMutation() {
        isLifecycleMutationInProgress = false
        applyDeferredLockIfPossible()
        resumeDeferredJournalDerivedRefreshIfPossible()
    }

    func beginJournalMutation(
        invalidatesJournalProjection: Bool = true
    ) throws {
        guard !isLifecycleMutationInProgress,
              !isWorking,
              state == .ready,
              !isJournalMutationInProgress,
              scheduleMutationsInProgress.isEmpty,
              scheduleEntryMatchesInProgress.isEmpty,
              investmentMutationsInProgress.isEmpty else {
            throw AppModelError.transactionInProgress
        }
        manualJournalMutationIsActive = true
        if invalidatesJournalProjection {
            invalidateInFlightJournalProjection()
        }
    }

    func endJournalMutation() {
        manualJournalMutationIsActive = false
        applyDeferredLockIfPossible()
        resumeDeferredJournalDerivedRefreshIfPossible()
    }

    func applyDeferredLockIfPossible() {
        guard lockAfterLifecycleMutation,
              !isLifecycleMutationInProgress,
              !isJournalMutationInProgress,
              scheduleMutationsInProgress.isEmpty,
              scheduleEntryMatchesInProgress.isEmpty,
              investmentMutationsInProgress.isEmpty else { return }
        lockAfterLifecycleMutation = false
        lock()
    }

    func beginGoalMutation() throws {
        guard !isLifecycleMutationInProgress,
              !goalMutationBarrierClosed,
              !isWorking,
              state == .ready else {
            throw AppModelError.transactionInProgress
        }
        goalMutationsInProgress += 1
    }

    func endGoalMutation() {
        guard goalMutationsInProgress > 0 else { return }
        goalMutationsInProgress -= 1
        guard goalMutationsInProgress == 0 else { return }
        let waiters = goalMutationDrainWaiters
        goalMutationDrainWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard lockAfterLifecycleMutation,
              !isLifecycleMutationInProgress,
              !isWorking else { return }
        lockAfterLifecycleMutation = false
        lock()
    }

    func waitForGoalMutationDrain() async {
        guard goalMutationsInProgress > 0 else { return }
        await withCheckedContinuation { continuation in
            goalMutationDrainWaiters.append(continuation)
        }
    }

    func finishExclusiveDataLifecycleMutation() {
        goalMutationBarrierClosed = false
        isWorking = false
        endLifecycleMutation()
    }

    func requireStore() throws -> EncryptedRecordStore {
        guard let store else { throw AppModelError.locked }
        return store
    }

    /// A missing profile is onboarding only when every durable book
    /// collection is truly empty. Decode quarantine must not turn an orphaned
    /// journal, audit, goal, or derived-accounting record into a fresh book.
    static func containsPersistedBookData(
        in store: EncryptedRecordStore
    ) async throws -> Bool {
        for collection in RecordCollection.allCases
        where collection != .profile && collection != .quickLogDrafts {
            if try await store.count(in: collection) > 0 { return true }
        }
        return false
    }

    func isCurrentStoreGeneration(_ generation: Int) -> Bool {
        ownsStoreGeneration(generation)
            && (state == .ready || state == .onboarding)
    }

    func ownsStoreGeneration(_ generation: Int) -> Bool {
        generation == storeGeneration && store != nil
    }

    func currency(for accountID: UUID) throws -> CurrencyCode {
        guard let account = accounts.first(where: { $0.id == accountID }),
              !account.isArchived else {
            throw AppModelError.ledgerItemArchived
        }
        guard account.systemRole == nil else {
            throw AppModelError.systemAccountLifecycleForbidden
        }
        guard account.kind == .asset || account.kind == .liability,
              let currency = account.currency else {
            throw AppModelError.accountHasNoCurrency
        }
        return currency
    }

    /// History corrections may keep an archived user account already present
    /// on the source entry. They must not make an archived account newly
    /// spendable, and hidden system accounts are never valid editor choices.
    func replacementCurrency(
        for accountID: UUID,
        preservingFrom original: JournalEntry
    ) throws -> CurrencyCode {
        guard let account = accounts.first(where: { $0.id == accountID }) else {
            throw AppModelError.missingRecord
        }
        guard account.systemRole == nil else {
            throw AppModelError.systemAccountLifecycleForbidden
        }
        guard account.kind == .asset || account.kind == .liability,
              let currency = account.currency else {
            throw AppModelError.accountHasNoCurrency
        }
        guard !account.isArchived || original.postings.contains(where: {
            $0.accountID == accountID
        }) else {
            throw AppModelError.ledgerItemArchived
        }
        return currency
    }

    func requireActiveCategory(
        _ id: UUID,
        kind: LedgerAccountKind
    ) throws {
        guard let category = accounts.first(where: { $0.id == id }) else {
            throw AppModelError.missingRecord
        }
        guard !category.isArchived else { throw AppModelError.ledgerItemArchived }
        guard category.systemRole == nil else {
            throw AppModelError.systemAccountLifecycleForbidden
        }
        guard category.kind == kind else {
            throw AppModelError.invalidCategoryKind
        }
    }

    /// Mirrors `replacementCurrency`: an archived category is valid only when
    /// it is part of the historical transaction being corrected.
    func requireReplacementCategory(
        _ id: UUID,
        kind: LedgerAccountKind,
        preservingFrom original: JournalEntry
    ) throws {
        guard let category = accounts.first(where: { $0.id == id }) else {
            throw AppModelError.missingRecord
        }
        guard category.systemRole == nil else {
            throw AppModelError.systemAccountLifecycleForbidden
        }
        guard category.kind == kind else {
            throw AppModelError.invalidCategoryKind
        }
        guard !category.isArchived || original.postings.contains(where: {
            $0.accountID == id
        }) else {
            throw AppModelError.ledgerItemArchived
        }
    }

    func editableMoneySnapshot(
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
                accountKinds[$0.accountID] == .asset
                    || accountKinds[$0.accountID] == .liability
            }) ?? entry.postings.first(where: {
                accountKinds[$0.accountID] == .expense
            }) else { return nil }
            let source = try positiveMoney(from: posting)
            return EditableMoneySnapshot(source: source, destination: nil)
        case .income:
            guard let posting = entry.postings.first(where: {
                accountKinds[$0.accountID] == .asset
                    || accountKinds[$0.accountID] == .liability
            }) ?? entry.postings.first(where: {
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

    func reportingOriginContext(
        for occurredAt: Date,
        reportingTimeZoneIdentifier: String? = nil
    ) -> TransactionOriginContext {
        let calendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: reportingTimeZoneIdentifier
                ?? profile?.reportingTimeZoneIdentifier
                ?? TimeZone.current.identifier
        )
        return .capture(
            for: occurredAt,
            calendar: calendar,
            timeZone: calendar.timeZone
        )
    }

    /// All entries authored by MoneyUp use the encrypted profile's fixed
    /// reporting zone. Device travel must not move a DatePicker selection to
    /// an adjacent financial day before it reaches the normalized index.
    func appAuthoredEntry(
        _ entry: JournalEntry,
        reportingTimeZoneIdentifier: String? = nil,
        sourceSystemOverride: String? = nil,
        sourceFingerprintOverride: String? = nil
    ) throws -> JournalEntry {
        try JournalEntry(
            id: entry.id,
            kind: entry.kind,
            occurredAt: entry.occurredAt,
            createdAt: entry.createdAt,
            payee: entry.payee,
            note: entry.note,
            postings: entry.postings,
            supersedesID: entry.supersedesID,
            revisedAt: entry.revisedAt,
            sourceSystem: sourceSystemOverride ?? entry.sourceSystem,
            sourceFingerprint: sourceFingerprintOverride ?? entry.sourceFingerprint,
            originContext: reportingOriginContext(
                for: entry.occurredAt,
                reportingTimeZoneIdentifier: reportingTimeZoneIdentifier
            )
        )
    }

    func openingBalancesAccount() -> LedgerAccount {
        accounts.first(where: { $0.systemRole == .openingBalances })
            ?? LedgerAccount(
                name: String(localized: "account.opening_balances"),
                kind: .equity,
                systemRole: .openingBalances
            )
    }

    func requireValidNewWriteAmount(
        _ amount: Decimal,
        currency: CurrencyCode,
        preserving originalAmount: Decimal? = nil
    ) throws {
        do {
            try MonetaryInputPolicy.validate(
                amount,
                currency: currency,
                preserving: originalAmount
            )
        } catch MoneyError.unsupportedPrecision(_) {
            throw AppModelError.unsupportedPrecision(currency)
        } catch MoneyError.exceedsNewWriteMaximum(_) {
            throw AppModelError.amountTooLarge
        } catch {
            throw error
        }
    }

    func foreignExchangeAccount(for currency: CurrencyCode) -> LedgerAccount {
        accounts.first {
            $0.systemRole == .foreignExchange && $0.currency == currency
        } ?? LedgerAccount(
            name: "\(String(localized: "account.fx_clearing")) \(currency.value)",
            kind: .trading,
            currency: currency,
            systemRole: .foreignExchange
        )
    }

    func investmentGainLossAccount(for currency: CurrencyCode) -> LedgerAccount {
        accounts.first {
            $0.systemRole == .investmentGainLoss && $0.currency == currency
        } ?? LedgerAccount(
            name: "\(String(localized: "holding.gain_loss")) \(currency.value)",
            kind: .trading,
            currency: currency,
            systemRole: .investmentGainLoss
        )
    }

    /// System adjustments and investment events require dedicated compensating
    /// workflows. Generic mutation would either erase reconciliation evidence
    /// or split persisted holding metadata from the authoritative journal.
    func isProtectedJournalEntry(_ entry: JournalEntry) -> Bool {
        entry.kind == .adjustment || entry.kind == .investment || entry.postings.contains {
            accountsByID[$0.accountID]?.systemRole == .investmentPosition
        }
    }

    func isEligibleInvestmentFundingAccount(
        _ account: LedgerAccount
    ) -> Bool {
        !account.isArchived && isInvestmentFundingAccountShape(account)
    }

    func isInvestmentFundingAccountShape(
        _ account: LedgerAccount
    ) -> Bool {
        account.kind == .asset
            && account.systemRole == nil
            && (account.accountType == .brokerage
                || account.accountType == .investment)
            && account.currency != nil
    }

    func linkedInvestmentAccounts(
        for holding: InvestmentHolding
    ) -> (
        funding: LedgerAccount,
        position: LedgerAccount,
        currency: CurrencyCode
    )? {
        guard let positionID = holding.positionAccountID,
              positionID != holding.accountID,
              let funding = accountsByID[holding.accountID],
              isEligibleInvestmentFundingAccount(funding),
              let currency = funding.currency,
              let position = accountsByID[positionID],
              !position.isArchived,
              position.kind == .asset,
              position.systemRole == .investmentPosition,
              position.currency == currency else {
            return nil
        }
        return (funding, position, currency)
    }

    func investmentOriginContext(for date: Date) -> TransactionOriginContext {
        reportingOriginContext(for: date)
    }

    func validatedInvestmentPositionValue(
        quantity: Decimal,
        unitPrice: Money
    ) throws -> Money {
        let value: Money
        do {
            value = try InvestmentHolding.positionValue(
                quantity: quantity,
                unitPrice: unitPrice
            )
        } catch InvestmentHoldingError.arithmeticOverflow {
            throw AppModelError.amountTooLarge
        }
        try requireValidNewWriteAmount(value.amount, currency: value.currency)
        return value
    }

    func validatedInvestmentMarketValue(
        _ holding: InvestmentHolding
    ) throws -> Money? {
        guard let price = holding.price else { return nil }
        return try validatedInvestmentPositionValue(
            quantity: holding.quantity,
            unitPrice: price
        )
    }

    func checkedInvestmentDifference(
        _ left: Decimal,
        _ right: Decimal
    ) throws -> Decimal {
        do {
            return try CheckedDecimal.subtracting(left, right)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AppModelError.amountTooLarge
        }
    }

    func checkedEstimatedSum(
        _ left: Decimal,
        _ right: Decimal
    ) throws -> Decimal {
        do {
            return try CheckedDecimal.adding(left, right)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AppModelError.amountTooLarge
        }
    }

    func performInvestmentDomainOperation<Value>(
        _ operation: () throws -> Value
    ) throws -> Value {
        do {
            return try operation()
        } catch let error as InvestmentHoldingError {
            switch error {
            case .arithmeticOverflow:
                throw AppModelError.amountTooLarge
            case .activityOutOfOrder:
                throw AppModelError.investmentDateOutOfOrder
            case .insufficientQuantity:
                throw AppModelError.insufficientInvestmentQuantity
            case .lotCurrencyMismatch, .valuationCurrencyMismatch:
                throw AppModelError.investmentCurrencyMismatch
            case .quantityCannotBeNegative, .priceCannotBeNegative,
                 .lotQuantityMustBePositive, .lotRemainingQuantityInvalid:
                throw AppModelError.invalidInvestmentTrade
            case .lotQuantityMismatch, .duplicateIdentifier,
                 .duplicateLinkedEntry, .invalidDisposal, .historyMismatch:
                throw AppModelError.invalidBook
            case .correctionUnavailable:
                throw AppModelError.invalidInvestmentTrade
            }
        }
    }

    func beginInvestmentMutation(id: UUID) throws {
        guard investmentMutationsInProgress.insert(id).inserted else {
            throw AppModelError.transactionInProgress
        }
    }

    func validateInvestmentActivityDate(
        _ date: Date,
        after latestDate: Date?
    ) throws {
        // A one-second tolerance avoids rejecting a Date captured immediately
        // before this main-actor validation executes.
        guard date <= Date().addingTimeInterval(1) else {
            throw AppModelError.investmentDateInFuture
        }
        if let latestDate, date < latestDate {
            throw AppModelError.investmentDateOutOfOrder
        }
    }

    func positionLedgerValue(
        id: UUID,
        currency: CurrencyCode
    ) throws -> Money {
        switch accountBalancesResult() {
        case let .available(balances):
            return balances[id]?[currency] ?? Money.zero(currency: currency)
        case .unavailable:
            throw AppModelError.invalidBook
        }
    }
}
