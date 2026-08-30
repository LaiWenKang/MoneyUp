import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

extension AppModel {
    func receiptAttachment(id: UUID) async throws -> ReceiptAttachment {
        guard let expectedMetadata = receiptAttachmentMetadata.first(
            where: { $0.id == id }
        ) else {
            throw AppModelError.missingRecord
        }
        let generation = storeGeneration
        let attachmentStore = try requireStore()
        guard let attachment = try await attachmentStore.receiptAttachment(id: id)
        else { throw AppModelError.missingRecord }
        guard isCurrentStoreGeneration(generation) else {
            throw AppModelError.locked
        }
        guard receiptAttachmentMetadata.contains(expectedMetadata),
              ReceiptAttachmentMetadata(attachment) == expectedMetadata else {
            throw AppModelError.invalidBook
        }
        return attachment
    }

    func deleteReceiptAttachment(id: UUID) async throws {
        try beginJournalMutation(invalidatesJournalProjection: false)
        defer { endJournalMutation() }
        guard receiptAttachmentMetadata.contains(where: { $0.id == id }) else {
            throw AppModelError.missingRecord
        }
        let generation = storeGeneration
        let attachmentStore = try requireStore()
        try await attachmentStore.remove(id: id.uuidString, from: .receiptAttachments)
        guard isCurrentStoreGeneration(generation) else { return }
        receiptAttachmentMetadata.removeAll { $0.id == id }
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
        splitLines: [TransactionSplitLine]? = nil,
        occurredAt: Date,
        payee: String?,
        note: String?
    ) async throws {
        let linkedScheduleIDs = Set(scheduledTransactions.compactMap { schedule in
            schedule.resolutions.contains { $0.linkedEntryID == id }
                ? schedule.id
                : nil
        })
        try beginJournalAndScheduleMutation(scheduleIDs: linkedScheduleIDs)
        defer {
            endJournalAndScheduleMutation(scheduleIDs: linkedScheduleIDs)
        }
        let lookupStore = try requireStore()
        let original: JournalEntry
        if let cached = entries.first(where: { $0.id == id }) {
            original = cached
        } else if let stored = try await lookupStore.fetch(
            JournalEntry.self,
            id: id.uuidString,
            from: .journalEntries
        ) {
            original = stored
        } else {
            throw AppModelError.missingRecord
        }
        guard !isProtectedJournalEntry(original) else {
            throw AppModelError.investmentEntryMutationForbidden
        }

        let originalMoney = try editableMoneySnapshot(for: original)
        let accountCurrency = try replacementCurrency(
            for: accountID,
            preservingFrom: original
        )
        if let originalMoney, originalMoney.source.currency != accountCurrency {
            throw AppModelError.crossCurrencyEditRequiresConversion
        }
        try requireValidNewWriteAmount(
            amount,
            currency: accountCurrency,
            preserving: originalMoney?.source.amount
        )
        if let splitLines {
            guard kind != .transfer else { throw AppModelError.invalidCategoryKind }
            let expectedKind: LedgerAccountKind = kind == .income ? .income : .expense
            for line in splitLines {
                try requireReplacementCategory(
                    line.categoryAccountID,
                    kind: expectedKind,
                    preservingFrom: original
                )
                let originalLineAmount = original.postings.first {
                    $0.id == line.id && $0.money.currency == accountCurrency
                }.map { abs($0.money.amount) }
                try requireValidNewWriteAmount(
                    line.amount.amount,
                    currency: accountCurrency,
                    preserving: originalLineAmount
                )
            }
        }
        let candidate: JournalEntry
        var addedAccounts: [LedgerAccount] = []

        switch kind {
        case .expense:
            if let splitLines {
                candidate = try TransactionFactory.splitExpense(
                    amount: try Money(amount, currency: accountCurrency),
                    paidFrom: accountID,
                    splits: splitLines,
                    occurredAt: occurredAt,
                    payee: payee,
                    note: note
                )
            } else {
                guard let categoryID else { throw AppModelError.missingRecord }
                try requireReplacementCategory(
                    categoryID,
                    kind: .expense,
                    preservingFrom: original
                )
                candidate = try TransactionFactory.expense(
                    amount: try Money(amount, currency: accountCurrency),
                    paidFrom: accountID,
                    category: categoryID,
                    occurredAt: occurredAt,
                    payee: payee,
                    note: note
                )
            }
        case .income:
            if let splitLines {
                candidate = try TransactionFactory.splitIncome(
                    amount: try Money(amount, currency: accountCurrency),
                    depositedInto: accountID,
                    splits: splitLines,
                    occurredAt: occurredAt,
                    payee: payee,
                    note: note
                )
            } else {
                guard let categoryID else { throw AppModelError.missingRecord }
                try requireReplacementCategory(
                    categoryID,
                    kind: .income,
                    preservingFrom: original
                )
                candidate = try TransactionFactory.income(
                    amount: try Money(amount, currency: accountCurrency),
                    depositedInto: accountID,
                    category: categoryID,
                    occurredAt: occurredAt,
                    payee: payee,
                    note: note
                )
            }
        case .refund:
            if let splitLines {
                candidate = try TransactionFactory.splitRefund(
                    amount: try Money(amount, currency: accountCurrency),
                    returnedTo: accountID,
                    splits: splitLines,
                    occurredAt: occurredAt,
                    payee: payee,
                    note: note
                )
            } else {
                guard let categoryID else { throw AppModelError.missingRecord }
                try requireReplacementCategory(
                    categoryID,
                    kind: .expense,
                    preservingFrom: original
                )
                candidate = try TransactionFactory.refund(
                    amount: try Money(amount, currency: accountCurrency),
                    returnedTo: accountID,
                    category: categoryID,
                    occurredAt: occurredAt,
                    payee: payee,
                    note: note
                )
            }
        case .transfer:
            guard let destinationAccountID else { throw AppModelError.missingRecord }
            let destinationCurrency = try replacementCurrency(
                for: destinationAccountID,
                preservingFrom: original
            )
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
                try requireValidNewWriteAmount(
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
            revisedAt: currentDate(),
            sourceSystem: original.sourceSystem,
            sourceFingerprint: original.sourceFingerprint,
            originContext: candidate.occurredAt == original.occurredAt
                ? original.originContext
                : reportingOriginContext(for: candidate.occurredAt)
        )
        let originalAttribution = try await budgetEntryAttribution(
            for: original.id,
            in: lookupStore
        )
        let reportingZone = profile?.reportingTimeZoneIdentifier
            ?? reportingCalendar.timeZone.identifier
        let replacementAttribution: BudgetEntryAttribution
        if let originalAttribution {
            let attributedReplacement = try replacementPreservingImplicitBudgetAttribution(
                replacement,
                original: original,
                priorAttribution: originalAttribution
            )
            replacementAttribution = try BudgetEntryAttribution(
                replacing: attributedReplacement,
                prior: originalAttribution,
                reportingTimeZoneIdentifier: reportingZone
            )
        } else {
            replacementAttribution = try BudgetEntryAttribution(
                entry: replacement,
                originTimeZoneIdentifier: reportingZone
            )
        }
        var candidateAttributions = budgetEntryAttributions
        candidateAttributions.removeValue(forKey: original.id)
        candidateAttributions[replacement.id] = replacementAttribution
        let originalAffectedMonth = try budgetAffectedMonth(
            for: original,
            attribution: originalAttribution
        )
        let replacementAffectedMonth = try budgetAffectedMonth(
            for: replacement,
            attribution: replacementAttribution
        )
        let affectedMonths = [
            originalAffectedMonth,
            replacementAffectedMonth
        ].compactMap { $0 }
        var candidateEntries = try await journalEntriesForBudgetMutation(
            from: lookupStore,
            affectedReportingMonths: affectedMonths
        )
        if candidateEntries != nil {
            candidateAttributions = budgetEntryAttributions
            candidateAttributions.removeValue(forKey: original.id)
            candidateAttributions[replacement.id] = replacementAttribution
            candidateEntries?.removeAll { $0.id == original.id }
            candidateEntries?.append(replacement)
            candidateEntries?.sort {
                if $0.occurredAt == $1.occurredAt {
                    return $0.createdAt > $1.createdAt
                }
                return $0.occurredAt > $1.occurredAt
            }
        }
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
        let relinkedAttachmentMetadata = try receiptAttachmentMetadata
            .filter { $0.entryID == original.id }
            .map { try $0.relinked(to: replacement.id) }
        var relinkedSchedules: [ScheduledTransaction] = []
        for schedule in scheduledTransactions where linkedScheduleIDs.contains(schedule.id) {
            var updated = schedule
            try updated.relinkEntry(from: original.id, to: replacement.id)
            relinkedSchedules.append(updated)
        }
        writes += try relinkedSchedules.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .scheduledTransactions)
        }
        writes.append(
            try RecordWrite(
                replacementAttribution,
                id: replacementAttribution.id.uuidString,
                in: .budgetEntryAttributions
            )
        )
        if let candidateTimeline {
            writes.append(try budgetConfigurationTimelineWrite(candidateTimeline))
        }

        let generation = storeGeneration
        let transactionStore = try requireStore()
        invalidateCommittedJournalProjection()
        await lifecycleHooks.checkpoint(
            .afterJournalProjectionInvalidationBeforeCommit
        )
        try await transactionStore.write(
            writes,
            removing: [
                RecordDeletion(
                    id: original.id.uuidString,
                    from: .journalEntries
                ),
                RecordDeletion(
                    id: original.id.uuidString,
                    from: .budgetEntryAttributions
                )
            ],
            relinkingReceiptAttachments: ReceiptAttachmentRelink(
                sourceEntryID: original.id,
                destinationEntryID: replacement.id
            )
        )
        guard isCurrentStoreGeneration(generation) else { return }
        accounts.append(contentsOf: addedAccounts)
        if let candidateTimeline { budgetConfigurationTimeline = candidateTimeline }
        budgetEntryAttributions = candidateAttributions
        if retainsCompleteJournal, let candidateEntries { entries = candidateEntries }
        if !relinkedAttachmentMetadata.isEmpty {
            receiptAttachmentMetadata.removeAll { $0.entryID == original.id }
            receiptAttachmentMetadata.append(contentsOf: relinkedAttachmentMetadata)
        }
        let schedulesByID = Dictionary(
            uniqueKeysWithValues: relinkedSchedules.map { ($0.id, $0) }
        )
        scheduledTransactions = scheduledTransactions.map {
            schedulesByID[$0.id] ?? $0
        }
        if !relinkedSchedules.isEmpty {
            existingScheduledLinkedEntryIDs.remove(original.id)
            existingScheduledLinkedEntryIDs.insert(replacement.id)
        }
        await refreshJournalAfterMutation()
    }

    /// A lifecycle merge changes the live category ID without changing the
    /// user's historical intent. A later amount/date edit presents that merged
    /// target in the form, so an unchanged visible category must keep the
    /// pre-merge attribution. Selecting a genuinely different category is an
    /// explicit recategorization and uses the replacement postings as-is.
    func replacementPreservingImplicitBudgetAttribution(
        _ replacement: JournalEntry,
        original: JournalEntry,
        priorAttribution: BudgetEntryAttribution
    ) throws -> JournalEntry {
        guard let timeline = budgetConfigurationTimeline else { return replacement }
        let budgetIDs = Set(timeline.revisions.flatMap(\.nodes).map(\.id))
        let originalBudgetPostings = original.postings.filter {
            budgetIDs.contains($0.accountID)
        }
        let replacementBudgetPostings = replacement.postings.filter {
            budgetIDs.contains($0.accountID)
        }
        let attributedBudgetPostings = priorAttribution.postings.filter {
            budgetIDs.contains($0.accountID)
        }
        guard originalBudgetPostings.count == 1,
              replacementBudgetPostings.count == 1,
              attributedBudgetPostings.count == 1,
              originalBudgetPostings[0].accountID
                == replacementBudgetPostings[0].accountID else {
            return replacement
        }
        let liveID = replacementBudgetPostings[0].accountID
        let attributedID = attributedBudgetPostings[0].accountID
        guard liveID != attributedID else { return replacement }
        let postings = replacement.postings.map { posting in
            guard posting.accountID == liveID else { return posting }
            return Posting(
                id: posting.id,
                accountID: attributedID,
                money: posting.money,
                memo: posting.memo
            )
        }
        return try JournalEntry(
            id: replacement.id,
            kind: replacement.kind,
            occurredAt: replacement.occurredAt,
            createdAt: replacement.createdAt,
            payee: replacement.payee,
            note: replacement.note,
            postings: postings,
            supersedesID: replacement.supersedesID,
            revisedAt: replacement.revisedAt,
            sourceSystem: replacement.sourceSystem,
            sourceFingerprint: replacement.sourceFingerprint,
            originContext: replacement.originContext
        )
    }
}
