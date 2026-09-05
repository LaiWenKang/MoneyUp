import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

extension AppModel {
    @discardableResult
    func logExpense(
        amount: Decimal,
        accountID: UUID,
        categoryID: UUID,
        occurredAt: Date,
        payee: String?,
        note: String?,
        receiptData: Data? = nil,
        attachmentDrafts: [ReceiptAttachmentDraft] = [],
        allowancePlanID: UUID? = nil
    ) async throws -> UUID? {
        try requireActiveCategory(categoryID, kind: .expense)
        try requireAllowanceGovernedExpenseSource(
            accountID,
            allowancePlanID: allowancePlanID
        )
        let currency = try currency(for: accountID)
        try requireValidNewWriteAmount(amount, currency: currency)
        let entry = try TransactionFactory.expense(
            amount: try Money(amount, currency: currency),
            paidFrom: accountID,
            category: categoryID,
            occurredAt: occurredAt,
            payee: payee,
            note: note
        )
        return try await save(
            entry,
            applyingAllowance: allowancePlanID,
            receiptData: receiptData,
            attachmentDrafts: attachmentDrafts
        )
    }

    @discardableResult
    func logIncome(
        amount: Decimal,
        accountID: UUID,
        categoryID: UUID,
        occurredAt: Date,
        payee: String?,
        note: String?,
        receiptData: Data? = nil,
        attachmentDrafts: [ReceiptAttachmentDraft] = []
    ) async throws -> UUID? {
        try requireActiveCategory(categoryID, kind: .income)
        let currency = try currency(for: accountID)
        try requireValidNewWriteAmount(amount, currency: currency)
        let entry = try TransactionFactory.income(
            amount: try Money(amount, currency: currency),
            depositedInto: accountID,
            category: categoryID,
            occurredAt: occurredAt,
            payee: payee,
            note: note
        )
        return try await save(
            entry,
            receiptData: receiptData,
            attachmentDrafts: attachmentDrafts
        )
    }

    @discardableResult
    func logRefund(
        amount: Decimal,
        accountID: UUID,
        categoryID: UUID,
        occurredAt: Date,
        payee: String?,
        note: String?,
        receiptData: Data? = nil,
        attachmentDrafts: [ReceiptAttachmentDraft] = []
    ) async throws -> UUID? {
        try requireActiveCategory(categoryID, kind: .expense)
        let currency = try currency(for: accountID)
        try requireValidNewWriteAmount(amount, currency: currency)
        let entry = try TransactionFactory.refund(
            amount: try Money(amount, currency: currency),
            returnedTo: accountID,
            category: categoryID,
            occurredAt: occurredAt,
            payee: payee,
            note: note
        )
        return try await save(
            entry,
            receiptData: receiptData,
            attachmentDrafts: attachmentDrafts
        )
    }

    @discardableResult
    func logSplitTransaction(
        kind: QuickLogKind,
        amount: Decimal,
        accountID: UUID,
        lines: [TransactionSplitLine],
        occurredAt: Date,
        payee: String?,
        note: String?,
        receiptData: Data? = nil,
        attachmentDrafts: [ReceiptAttachmentDraft] = [],
        allowancePlanID: UUID? = nil
    ) async throws -> UUID? {
        guard kind != .transfer else { throw AppModelError.invalidCategoryKind }
        if kind == .expense {
            try requireAllowanceGovernedExpenseSource(
                accountID,
                allowancePlanID: allowancePlanID
            )
        }
        let currency = try currency(for: accountID)
        try requireValidNewWriteAmount(amount, currency: currency)
        for line in lines {
            let expectedKind: LedgerAccountKind = kind == .income ? .income : .expense
            try requireActiveCategory(line.categoryAccountID, kind: expectedKind)
            try requireValidNewWriteAmount(line.amount.amount, currency: currency)
        }
        let total = try Money(amount, currency: currency)
        let entry: JournalEntry
        switch kind {
        case .expense:
            entry = try TransactionFactory.splitExpense(
                amount: total,
                paidFrom: accountID,
                splits: lines,
                occurredAt: occurredAt,
                payee: payee,
                note: note
            )
        case .income:
            entry = try TransactionFactory.splitIncome(
                amount: total,
                depositedInto: accountID,
                splits: lines,
                occurredAt: occurredAt,
                payee: payee,
                note: note
            )
        case .refund:
            entry = try TransactionFactory.splitRefund(
                amount: total,
                returnedTo: accountID,
                splits: lines,
                occurredAt: occurredAt,
                payee: payee,
                note: note
            )
        case .transfer:
            throw AppModelError.invalidCategoryKind
        }
        if kind == .expense {
            return try await save(
                entry,
                applyingAllowance: allowancePlanID,
                receiptData: receiptData,
                attachmentDrafts: attachmentDrafts
            )
        }
        guard allowancePlanID == nil else {
            throw AppModelError.invalidAllowance
        }
        return try await save(
            entry,
            receiptData: receiptData,
            attachmentDrafts: attachmentDrafts
        )
    }

    @discardableResult
    func logTransfer(
        amount: Decimal,
        destinationAmount: Decimal? = nil,
        sourceAccountID: UUID,
        destinationAccountID: UUID,
        occurredAt: Date,
        payee: String?,
        note: String?,
        attachmentDrafts: [ReceiptAttachmentDraft] = []
    ) async throws -> UUID? {
        try requireGenericOutgoingSource(sourceAccountID)
        let sourceCurrency = try currency(for: sourceAccountID)
        let destinationCurrency = try currency(for: destinationAccountID)
        try requireValidNewWriteAmount(amount, currency: sourceCurrency)
        if sourceCurrency == destinationCurrency {
            let entry = try TransactionFactory.transfer(
                amount: try Money(amount, currency: sourceCurrency),
                from: sourceAccountID,
                to: destinationAccountID,
                occurredAt: occurredAt,
                payee: payee,
                note: note
            )
            return try await save(entry, attachmentDrafts: attachmentDrafts)
        }

        guard let destinationAmount, destinationAmount > .zero else {
            throw AppModelError.foreignCurrencyTransferRequiresExchangeRate
        }
        try requireValidNewWriteAmount(destinationAmount, currency: destinationCurrency)
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
            payee: payee,
            note: note
        )
        let writes = try newTradingAccounts.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .accounts)
        }
        return try await save(
            entry,
            additionalWrites: writes,
            additionalAccounts: newTradingAccounts,
            attachmentDrafts: attachmentDrafts
        )
    }

    func deleteEntry(id: UUID) async throws {
        let linkedScheduleIDs = linkedScheduleIDs(forDeletedEntryID: id)
        try beginJournalAndScheduleMutation(scheduleIDs: linkedScheduleIDs)
        defer { endJournalAndScheduleMutation(scheduleIDs: linkedScheduleIDs) }
        let generation = storeGeneration
        let entryStore = try requireStore()
        let entry = try await validatedEntryForDeletion(id: id, in: entryStore)
        let originalAttribution = try await budgetEntryAttribution(
            for: id,
            in: entryStore
        )
        var candidateAttributions = budgetEntryAttributions
        candidateAttributions.removeValue(forKey: id)
        let affectedMonth = try budgetAffectedMonth(
            for: entry,
            attribution: originalAttribution
        )
        let affectedMonths = [affectedMonth].compactMap { $0 }
        var candidateEntries = try await journalEntriesForBudgetMutation(
            from: entryStore,
            affectedReportingMonths: affectedMonths
        )
        if candidateEntries != nil {
            candidateAttributions = budgetEntryAttributions
            candidateAttributions.removeValue(forKey: id)
        }
        candidateEntries?.removeAll { $0.id == id }
        let candidateTimeline: BudgetConfigurationTimeline?
        if let candidateEntries {
            candidateTimeline = try budgetTimelineAfterJournalMutation(
                journalEntries: candidateEntries,
                attributions: candidateAttributions,
                affectedReportingMonths: affectedMonths
            )
        } else {
            candidateTimeline = nil
        }
        let attachmentIDs = try await entryStore.receiptAttachmentIDs(entryID: id)
        let updatedSchedules = try schedulesAfterDeletingLinkedEntry(
            id: id,
            linkedScheduleIDs: linkedScheduleIDs
        )
        var writes = try updatedSchedules.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .scheduledTransactions)
        }
        let updatedAllowances = try allowancesAfterDeletingLinkedEntry(id)
        writes += try allowanceWrites(changedTo: updatedAllowances)
        if let candidateTimeline {
            writes.append(try budgetConfigurationTimelineWrite(candidateTimeline))
        }
        var deletions = [
            RecordDeletion(id: id.uuidString, from: .journalEntries)
        ] + attachmentIDs.map {
            RecordDeletion(id: $0.uuidString, from: .receiptAttachments)
        }
        if originalAttribution != nil {
            deletions.append(
                RecordDeletion(id: id.uuidString, from: .budgetEntryAttributions)
            )
        }
        invalidateCommittedJournalProjection()
        await lifecycleHooks.checkpoint(
            .afterJournalProjectionInvalidationBeforeCommit
        )
        try await entryStore.write(
            writes,
            removing: deletions
        )
        guard isCurrentStoreGeneration(generation) else { return }
        applyDeletedEntry(
            id: id,
            candidateTimeline: candidateTimeline,
            candidateAttributions: candidateAttributions,
            candidateEntries: candidateEntries,
            updatedSchedules: updatedSchedules
        )
        allowancePlans = updatedAllowances
        await refreshJournalAfterMutation()
    }

    private func linkedScheduleIDs(forDeletedEntryID id: UUID) -> Set<UUID> {
        Set(scheduledTransactions.compactMap { schedule in
            schedule.resolutions.contains { $0.linkedEntryID == id }
                ? schedule.id
                : nil
        })
    }

    private func validatedEntryForDeletion(
        id: UUID,
        in store: EncryptedRecordStore
    ) async throws -> JournalEntry {
        let entry = try await entryForDeletion(id: id, in: store)
        guard !isProtectedJournalEntry(entry) else {
            throw AppModelError.investmentEntryMutationForbidden
        }
        try await requireNonnegativeRestrictedBalances(
            afterRemoving: entry,
            adding: nil,
            in: store
        )
        return entry
    }

    private func allowancesAfterDeletingLinkedEntry(
        _ entryID: UUID
    ) throws -> [AllowancePlan] {
        try allowancePlans.map { plan in
            guard let usage = plan.usages.first(where: {
                $0.linkedJournalEntryID == entryID
            }) else { return plan }
            guard !plan.hasGrandfatheredActivity else {
                throw AppModelError.invalidAllowance
            }
            if plan.fundingMode == .prepaidAsset,
               plan.reconciliations.contains(where: {
                   FinancialPeriodBoundary.contains(
                       usage.occurredAt,
                       in: DateInterval(start: $0.periodStart, end: $0.periodEnd)
                   )
               }) {
                throw AppModelError.invalidAllowance
            }
            return try plan.removingUsages(linkedTo: entryID)
        }
    }

    private func allowanceWrites(
        changedTo updatedPlans: [AllowancePlan]
    ) throws -> [RecordWrite] {
        try zip(allowancePlans, updatedPlans).compactMap { prior, updated in
            guard prior != updated else { return nil }
            return try RecordWrite(
                updated,
                id: updated.id.uuidString,
                in: .allowancePlans
            )
        }
    }

    private func entryForDeletion(
        id: UUID,
        in entryStore: EncryptedRecordStore
    ) async throws -> JournalEntry {
        if let cached = entries.first(where: { $0.id == id }) {
            return cached
        }
        if let stored = try await entryStore.fetch(
            JournalEntry.self,
            id: id.uuidString,
            from: .journalEntries
        ) {
            return stored
        }
        throw AppModelError.missingRecord
    }

    private func schedulesAfterDeletingLinkedEntry(
        id: UUID,
        linkedScheduleIDs: Set<UUID>
    ) throws -> [ScheduledTransaction] {
        var updatedSchedules: [ScheduledTransaction] = []
        let deletedAt = currentDate()
        for schedule in scheduledTransactions where linkedScheduleIDs.contains(schedule.id) {
            var updated = schedule
            try updated.markLinkedEntryDeleted(id, at: deletedAt)
            updatedSchedules.append(updated)
        }
        return updatedSchedules
    }

    private func applyDeletedEntry(
        id: UUID,
        candidateTimeline: BudgetConfigurationTimeline?,
        candidateAttributions: [UUID: BudgetEntryAttribution],
        candidateEntries: [JournalEntry]?,
        updatedSchedules: [ScheduledTransaction]
    ) {
        if let candidateTimeline { budgetConfigurationTimeline = candidateTimeline }
        budgetEntryAttributions = candidateAttributions
        if retainsCompleteJournal, let candidateEntries { entries = candidateEntries }
        receiptAttachmentMetadata.removeAll { $0.entryID == id }
        let schedulesByID = Dictionary(
            uniqueKeysWithValues: updatedSchedules.map { ($0.id, $0) }
        )
        scheduledTransactions = scheduledTransactions.map {
            schedulesByID[$0.id] ?? $0
        }
        existingScheduledLinkedEntryIDs.remove(id)
    }

    /// Loads exactly one user-selected encrypted receipt. No attachment bytes
    /// are cached on AppModel, and a lock that races the read discards them.
}
