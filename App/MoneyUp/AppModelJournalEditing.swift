import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

private struct JournalEntryReplacementRequest: Sendable {
    let kind: QuickLogKind
    let amount: Decimal
    let destinationAmount: Decimal?
    let accountID: UUID
    let destinationAccountID: UUID?
    let categoryID: UUID?
    let splitLines: [TransactionSplitLine]?
    let occurredAt: Date
    let payee: String?
    let note: String?
}

private struct JournalEntryReplacementCandidate: Sendable {
    let entry: JournalEntry
    let addedAccounts: [LedgerAccount]
}

private struct JournalEntryReplacementAttributions: Sendable {
    let original: BudgetEntryAttribution?
    let replacement: BudgetEntryAttribution
}

private struct JournalEntryReplacementBudgetPlan: Sendable {
    let attribution: BudgetEntryAttribution
    let attributions: [UUID: BudgetEntryAttribution]
    let entries: [JournalEntry]?
    let timeline: BudgetConfigurationTimeline?
}

private struct JournalEntryReplacementWritePlan: Sendable {
    let writes: [RecordWrite]
    let attachmentMetadata: [ReceiptAttachmentMetadata]
    let schedules: [ScheduledTransaction]
}

extension AppModel {
    func receiptAttachment(id: UUID) async throws -> ReceiptAttachment {
        let read = try beginLogicalBookRead()
        guard let expectedMetadata = receiptAttachmentMetadata.first(
            where: { $0.id == id }
        ) else {
            throw AppModelError.missingRecord
        }
        let attachmentStore = read.store
        guard let attachment = try await attachmentStore.receiptAttachment(id: id)
        else { throw AppModelError.missingRecord }
        try requireLogicalBookRead(read.token)
        guard receiptAttachmentMetadata.contains(expectedMetadata),
              ReceiptAttachmentMetadata(attachment) == expectedMetadata else {
            throw AppModelError.invalidBook
        }
        return try await finishLogicalBookRead(attachment, token: read.token)
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
        let request = JournalEntryReplacementRequest(
            kind: kind,
            amount: amount,
            destinationAmount: destinationAmount,
            accountID: accountID,
            destinationAccountID: destinationAccountID,
            categoryID: categoryID,
            splitLines: splitLines,
            occurredAt: occurredAt,
            payee: payee,
            note: note
        )
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
        let original = try await replacementOriginalEntry(id: id, in: lookupStore)
        guard !isProtectedJournalEntry(original) else {
            throw AppModelError.investmentEntryMutationForbidden
        }
        let candidate = try makeReplacementCandidate(request, original: original)
        let replacement = try makeReplacementEntry(
            from: candidate.entry,
            original: original
        )
        let budgetPlan = try await replacementBudgetPlan(
            original: original,
            replacement: replacement,
            store: lookupStore
        )
        let writePlan = try replacementWritePlan(
            original: original,
            replacement: replacement,
            addedAccounts: candidate.addedAccounts,
            budgetPlan: budgetPlan,
            linkedScheduleIDs: linkedScheduleIDs
        )
        let generation = storeGeneration
        let transactionStore = try requireStore()
        invalidateCommittedJournalProjection()
        await lifecycleHooks.checkpoint(
            .afterJournalProjectionInvalidationBeforeCommit
        )
        try await transactionStore.write(
            writePlan.writes,
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
        publishReplacement(
            original: original,
            replacement: replacement,
            addedAccounts: candidate.addedAccounts,
            budgetPlan: budgetPlan,
            writePlan: writePlan
        )
        await refreshJournalAfterMutation()
    }
}

extension AppModel {
    private func replacementOriginalEntry(
        id: UUID,
        in store: EncryptedRecordStore
    ) async throws -> JournalEntry {
        if let cached = entries.first(where: { $0.id == id }) {
            return cached
        }
        guard let stored = try await store.fetch(
            JournalEntry.self,
            id: id.uuidString,
            from: .journalEntries
        ) else { throw AppModelError.missingRecord }
        return stored
    }

    private func makeReplacementEntry(
        from candidate: JournalEntry,
        original: JournalEntry
    ) throws -> JournalEntry {
        try JournalEntry(
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
    }

    private func replacementMoneyContext(
        for request: JournalEntryReplacementRequest,
        original: JournalEntry
    ) throws -> (EditableMoneySnapshot?, CurrencyCode) {
        let originalMoney = try editableMoneySnapshot(for: original)
        let accountCurrency = try replacementCurrency(
            for: request.accountID,
            preservingFrom: original
        )
        if let originalMoney,
           originalMoney.source.currency != accountCurrency {
            throw AppModelError.crossCurrencyEditRequiresConversion
        }
        try requireValidNewWriteAmount(
            request.amount,
            currency: accountCurrency,
            preserving: originalMoney?.source.amount
        )
        if let splitLines = request.splitLines {
            guard request.kind != .transfer else {
                throw AppModelError.invalidCategoryKind
            }
            let kind: LedgerAccountKind = request.kind == .income
                ? .income : .expense
            for line in splitLines {
                try requireReplacementCategory(
                    line.categoryAccountID,
                    kind: kind,
                    preservingFrom: original
                )
                let priorAmount = original.postings.first {
                    $0.id == line.id && $0.money.currency == accountCurrency
                }.map { abs($0.money.amount) }
                try requireValidNewWriteAmount(
                    line.amount.amount,
                    currency: accountCurrency,
                    preserving: priorAmount
                )
            }
        }
        return (originalMoney, accountCurrency)
    }

    private func makeReplacementCandidate(
        _ request: JournalEntryReplacementRequest,
        original: JournalEntry
    ) throws -> JournalEntryReplacementCandidate {
        let (originalMoney, currency) = try replacementMoneyContext(
            for: request,
            original: original
        )
        switch request.kind {
        case .expense:
            return try expenseReplacementCandidate(
                request,
                currency: currency,
                original: original
            )
        case .income:
            return try incomeReplacementCandidate(
                request,
                currency: currency,
                original: original
            )
        case .refund:
            return try refundReplacementCandidate(
                request,
                currency: currency,
                original: original
            )
        case .transfer:
            return try transferReplacementCandidate(
                request,
                sourceCurrency: currency,
                originalMoney: originalMoney,
                original: original
            )
        }
    }

    private func expenseReplacementCandidate(
        _ request: JournalEntryReplacementRequest,
        currency: CurrencyCode,
        original: JournalEntry
    ) throws -> JournalEntryReplacementCandidate {
        let entry: JournalEntry
        if let splitLines = request.splitLines {
            entry = try TransactionFactory.splitExpense(
                amount: try Money(request.amount, currency: currency),
                paidFrom: request.accountID,
                splits: splitLines,
                occurredAt: request.occurredAt,
                payee: request.payee,
                note: request.note
            )
        } else {
            guard let categoryID = request.categoryID else {
                throw AppModelError.missingRecord
            }
            try requireReplacementCategory(
                categoryID,
                kind: .expense,
                preservingFrom: original
            )
            entry = try TransactionFactory.expense(
                amount: try Money(request.amount, currency: currency),
                paidFrom: request.accountID,
                category: categoryID,
                occurredAt: request.occurredAt,
                payee: request.payee,
                note: request.note
            )
        }
        return JournalEntryReplacementCandidate(entry: entry, addedAccounts: [])
    }

    private func incomeReplacementCandidate(
        _ request: JournalEntryReplacementRequest,
        currency: CurrencyCode,
        original: JournalEntry
    ) throws -> JournalEntryReplacementCandidate {
        let entry: JournalEntry
        if let splitLines = request.splitLines {
            entry = try TransactionFactory.splitIncome(
                amount: try Money(request.amount, currency: currency),
                depositedInto: request.accountID,
                splits: splitLines,
                occurredAt: request.occurredAt,
                payee: request.payee,
                note: request.note
            )
        } else {
            guard let categoryID = request.categoryID else {
                throw AppModelError.missingRecord
            }
            try requireReplacementCategory(
                categoryID,
                kind: .income,
                preservingFrom: original
            )
            entry = try TransactionFactory.income(
                amount: try Money(request.amount, currency: currency),
                depositedInto: request.accountID,
                category: categoryID,
                occurredAt: request.occurredAt,
                payee: request.payee,
                note: request.note
            )
        }
        return JournalEntryReplacementCandidate(entry: entry, addedAccounts: [])
    }

    private func refundReplacementCandidate(
        _ request: JournalEntryReplacementRequest,
        currency: CurrencyCode,
        original: JournalEntry
    ) throws -> JournalEntryReplacementCandidate {
        let entry: JournalEntry
        if let splitLines = request.splitLines {
            entry = try TransactionFactory.splitRefund(
                amount: try Money(request.amount, currency: currency),
                returnedTo: request.accountID,
                splits: splitLines,
                occurredAt: request.occurredAt,
                payee: request.payee,
                note: request.note
            )
        } else {
            guard let categoryID = request.categoryID else {
                throw AppModelError.missingRecord
            }
            try requireReplacementCategory(
                categoryID,
                kind: .expense,
                preservingFrom: original
            )
            entry = try TransactionFactory.refund(
                amount: try Money(request.amount, currency: currency),
                returnedTo: request.accountID,
                category: categoryID,
                occurredAt: request.occurredAt,
                payee: request.payee,
                note: request.note
            )
        }
        return JournalEntryReplacementCandidate(entry: entry, addedAccounts: [])
    }

    private func transferReplacementCandidate(
        _ request: JournalEntryReplacementRequest,
        sourceCurrency: CurrencyCode,
        originalMoney: EditableMoneySnapshot?,
        original: JournalEntry
    ) throws -> JournalEntryReplacementCandidate {
        guard let destinationID = request.destinationAccountID else {
            throw AppModelError.missingRecord
        }
        let destinationCurrency = try replacementCurrency(
            for: destinationID,
            preservingFrom: original
        )
        if let priorDestination = originalMoney?.destination,
           priorDestination.currency != destinationCurrency {
            throw AppModelError.crossCurrencyEditRequiresConversion
        }
        guard destinationCurrency != sourceCurrency else {
            let entry = try TransactionFactory.transfer(
                amount: try Money(request.amount, currency: sourceCurrency),
                from: request.accountID,
                to: destinationID,
                occurredAt: request.occurredAt,
                payee: request.payee,
                note: request.note
            )
            return JournalEntryReplacementCandidate(entry: entry, addedAccounts: [])
        }
        guard let destinationAmount = request.destinationAmount,
              destinationAmount > .zero else {
            throw AppModelError.foreignCurrencyTransferRequiresExchangeRate
        }
        try requireValidNewWriteAmount(
            destinationAmount,
            currency: destinationCurrency,
            preserving: originalMoney?.destination?.amount
        )
        let sourceTrading = foreignExchangeAccount(for: sourceCurrency)
        let destinationTrading = foreignExchangeAccount(for: destinationCurrency)
        let addedAccounts = [sourceTrading, destinationTrading].filter { candidate in
            !accounts.contains(where: { $0.id == candidate.id })
        }
        let entry = try TransactionFactory.foreignCurrencyTransfer(
            sourceAmount: try Money(request.amount, currency: sourceCurrency),
            destinationAmount: try Money(destinationAmount, currency: destinationCurrency),
            from: request.accountID,
            to: destinationID,
            sourceTradingAccountID: sourceTrading.id,
            destinationTradingAccountID: destinationTrading.id,
            occurredAt: request.occurredAt,
            payee: request.payee,
            note: request.note
        )
        return JournalEntryReplacementCandidate(
            entry: entry,
            addedAccounts: addedAccounts
        )
    }

    private func replacementAttributions(
        original: JournalEntry,
        replacement: JournalEntry,
        store: EncryptedRecordStore
    ) async throws -> JournalEntryReplacementAttributions {
        let originalAttribution = try await budgetEntryAttribution(
            for: original.id,
            in: store
        )
        let reportingZone = profile?.reportingTimeZoneIdentifier
            ?? reportingCalendar.timeZone.identifier
        let replacementAttribution: BudgetEntryAttribution
        if let originalAttribution {
            let attributedEntry = try replacementPreservingImplicitBudgetAttribution(
                replacement,
                original: original,
                priorAttribution: originalAttribution
            )
            replacementAttribution = try BudgetEntryAttribution(
                replacing: attributedEntry,
                prior: originalAttribution,
                reportingTimeZoneIdentifier: reportingZone
            )
        } else {
            replacementAttribution = try BudgetEntryAttribution(
                entry: replacement,
                originTimeZoneIdentifier: reportingZone
            )
        }
        return JournalEntryReplacementAttributions(
            original: originalAttribution,
            replacement: replacementAttribution
        )
    }

    private func replacementBudgetPlan(
        original: JournalEntry,
        replacement: JournalEntry,
        store: EncryptedRecordStore
    ) async throws -> JournalEntryReplacementBudgetPlan {
        let pair = try await replacementAttributions(
            original: original,
            replacement: replacement,
            store: store
        )
        var attributions = budgetEntryAttributions
        attributions.removeValue(forKey: original.id)
        attributions[replacement.id] = pair.replacement
        let affectedMonths = try [
            budgetAffectedMonth(for: original, attribution: pair.original),
            budgetAffectedMonth(for: replacement, attribution: pair.replacement)
        ].compactMap { $0 }
        var candidateEntries = try await journalEntriesForBudgetMutation(
            from: store,
            affectedReportingMonths: affectedMonths
        )
        if candidateEntries != nil {
            attributions = budgetEntryAttributions
            attributions.removeValue(forKey: original.id)
            attributions[replacement.id] = pair.replacement
            candidateEntries?.removeAll { $0.id == original.id }
            candidateEntries?.append(replacement)
            candidateEntries?.sort {
                if $0.occurredAt == $1.occurredAt {
                    return $0.createdAt > $1.createdAt
                }
                return $0.occurredAt > $1.occurredAt
            }
        }
        let timeline: BudgetConfigurationTimeline?
        if let candidateEntries {
            timeline = try budgetTimelineAfterJournalMutation(
                journalEntries: candidateEntries,
                attributions: attributions,
                affectedReportingMonths: affectedMonths
            )
        } else {
            timeline = nil
        }
        return JournalEntryReplacementBudgetPlan(
            attribution: pair.replacement,
            attributions: attributions,
            entries: candidateEntries,
            timeline: timeline
        )
    }

    private func replacementWritePlan(
        original: JournalEntry,
        replacement: JournalEntry,
        addedAccounts: [LedgerAccount],
        budgetPlan: JournalEntryReplacementBudgetPlan,
        linkedScheduleIDs: Set<UUID>
    ) throws -> JournalEntryReplacementWritePlan {
        var writes = try addedAccounts.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .accounts)
        }
        writes.append(try RecordWrite(
            original,
            id: "\(original.id.uuidString)-\(UUID().uuidString)",
            in: .journalEntryRevisions
        ))
        writes.append(try RecordWrite(
            replacement,
            id: replacement.id.uuidString,
            in: .journalEntries
        ))
        let attachmentMetadata = try receiptAttachmentMetadata
            .filter { $0.entryID == original.id }
            .map { try $0.relinked(to: replacement.id) }
        var schedules: [ScheduledTransaction] = []
        for schedule in scheduledTransactions where linkedScheduleIDs.contains(schedule.id) {
            var updated = schedule
            try updated.relinkEntry(from: original.id, to: replacement.id)
            schedules.append(updated)
        }
        writes += try schedules.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .scheduledTransactions)
        }
        writes.append(try RecordWrite(
            budgetPlan.attribution,
            id: budgetPlan.attribution.id.uuidString,
            in: .budgetEntryAttributions
        ))
        if let timeline = budgetPlan.timeline {
            writes.append(try budgetConfigurationTimelineWrite(timeline))
        }
        return JournalEntryReplacementWritePlan(
            writes: writes,
            attachmentMetadata: attachmentMetadata,
            schedules: schedules
        )
    }

    private func publishReplacement(
        original: JournalEntry,
        replacement: JournalEntry,
        addedAccounts: [LedgerAccount],
        budgetPlan: JournalEntryReplacementBudgetPlan,
        writePlan: JournalEntryReplacementWritePlan
    ) {
        accounts.append(contentsOf: addedAccounts)
        if let timeline = budgetPlan.timeline {
            budgetConfigurationTimeline = timeline
        }
        budgetEntryAttributions = budgetPlan.attributions
        if retainsCompleteJournal, let entries = budgetPlan.entries {
            self.entries = entries
        }
        if !writePlan.attachmentMetadata.isEmpty {
            receiptAttachmentMetadata.removeAll { $0.entryID == original.id }
            receiptAttachmentMetadata.append(
                contentsOf: writePlan.attachmentMetadata
            )
        }
        let schedulesByID = Dictionary(
            uniqueKeysWithValues: writePlan.schedules.map { ($0.id, $0) }
        )
        scheduledTransactions = scheduledTransactions.map {
            schedulesByID[$0.id] ?? $0
        }
        if !writePlan.schedules.isEmpty {
            existingScheduledLinkedEntryIDs.remove(original.id)
            existingScheduledLinkedEntryIDs.insert(replacement.id)
        }
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
