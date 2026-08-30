import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

extension AppModel {
    /// Creates the actual journal entry and advances its forecast in one
    /// SQLCipher transaction. The occurrence token prevents a stale UI or a
    /// retry from posting the same due item a second time.
    @discardableResult
    func postScheduledOccurrence(
        scheduleID: UUID,
        occurrenceID: ScheduledOccurrenceID,
        occurredAt: Date? = nil,
        resolvedAt: Date = Date(),
        calendar: Calendar? = nil
    ) async throws -> UUID? {
        let recurrenceCalendar = calendar ?? reportingCalendar
        let mutationScheduleIDs: Set<UUID> = [scheduleID]
        try beginJournalAndScheduleMutation(scheduleIDs: mutationScheduleIDs)
        defer {
            endJournalAndScheduleMutation(scheduleIDs: mutationScheduleIDs)
        }
        guard let index = scheduledTransactions.firstIndex(where: { $0.id == scheduleID }) else {
            throw AppModelError.missingRecord
        }

        let schedule = scheduledTransactions[index]
        guard schedule.currentOccurrenceID == occurrenceID else {
            throw ScheduledTransactionError.staleOccurrence
        }
        try validateScheduleReferences(schedule)
        try requireValidNewWriteAmount(
            schedule.amount.amount,
            currency: schedule.amount.currency
        )
        let candidate: JournalEntry
        switch schedule.kind {
        case .expense:
            candidate = try TransactionFactory.expense(
                amount: schedule.amount,
                paidFrom: schedule.accountID,
                category: schedule.categoryAccountID,
                occurredAt: occurredAt ?? schedule.nextOccurrence,
                payee: schedule.name
            )
        case .income:
            candidate = try TransactionFactory.income(
                amount: schedule.amount,
                depositedInto: schedule.accountID,
                category: schedule.categoryAccountID,
                occurredAt: occurredAt ?? schedule.nextOccurrence,
                payee: schedule.name
            )
        case .transfer, .adjustment, .investment:
            throw ScheduledTransactionError.unsupportedKind
        }
        let fingerprint = Self.scheduleFingerprint(for: occurrenceID)
        let generation = storeGeneration
        let scheduleStore = try requireStore()
        let occurrenceAlreadyExists = try await scheduleStore.containsJournalEntry(
            sourceFingerprint: fingerprint
        )
        guard !occurrenceAlreadyExists else {
            throw ScheduledTransactionError.occurrenceAlreadyResolved
        }
        let entry = try JournalEntry(
            id: candidate.id,
            kind: candidate.kind,
            occurredAt: candidate.occurredAt,
            createdAt: candidate.createdAt,
            payee: candidate.payee,
            note: candidate.note,
            postings: candidate.postings,
            sourceSystem: "MoneyUp Schedule",
            sourceFingerprint: fingerprint,
            originContext: .capture(
                for: candidate.occurredAt,
                calendar: recurrenceCalendar,
                timeZone: recurrenceCalendar.timeZone
            )
        )
        var updated = schedule
        try updated.resolveCurrent(
            occurrenceID: occurrenceID,
            as: .posted,
            linkedEntryID: entry.id,
            at: resolvedAt,
            calendar: recurrenceCalendar
        )

        let attribution = try BudgetEntryAttribution(
            entry: entry,
            originTimeZoneIdentifier: profile?.reportingTimeZoneIdentifier
                ?? reportingCalendar.timeZone.identifier
        )
        var candidateAttributions = budgetEntryAttributions
        candidateAttributions[entry.id] = attribution
        let affectedMonths = [
            try budgetAffectedMonth(for: entry, attribution: attribution)
        ].compactMap { $0 }
        var candidateEntries = try await journalEntriesForBudgetMutation(
            from: scheduleStore,
            affectedReportingMonths: affectedMonths
        )
        if candidateEntries != nil {
            candidateAttributions = budgetEntryAttributions
            candidateAttributions[entry.id] = attribution
            candidateEntries?.append(entry)
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

        var writes = [
            try RecordWrite(entry, id: entry.id.uuidString, in: .journalEntries),
            try RecordWrite(
                attribution,
                id: attribution.id.uuidString,
                in: .budgetEntryAttributions
            ),
            try RecordWrite(updated, id: updated.id.uuidString, in: .scheduledTransactions)
        ]
        if let candidateTimeline {
            writes.append(try budgetConfigurationTimelineWrite(candidateTimeline))
        }
        invalidateCommittedJournalProjection()
        await lifecycleHooks.checkpoint(
            .afterJournalProjectionInvalidationBeforeCommit
        )
        try await scheduleStore.write(writes)
        guard isCurrentStoreGeneration(generation) else { return nil }
        scheduledTransactions[index] = updated
        scheduledTransactions.sort { $0.nextOccurrence < $1.nextOccurrence }
        if let candidateTimeline { budgetConfigurationTimeline = candidateTimeline }
        budgetEntryAttributions = candidateAttributions
        if retainsCompleteJournal, let candidateEntries { entries = candidateEntries }
        existingScheduledLinkedEntryIDs.insert(entry.id)
        await refreshJournalAfterMutation()
        return entry.id
    }

    /// Links an existing actual entry and advances the forecast atomically.
    func matchScheduledOccurrence(
        scheduleID: UUID,
        occurrenceID: ScheduledOccurrenceID,
        entryID: UUID,
        resolvedAt: Date = Date(),
        calendar: Calendar? = nil
    ) async throws {
        let recurrenceCalendar = calendar ?? reportingCalendar
        let mutationScheduleIDs: Set<UUID> = [scheduleID]
        try beginJournalAndScheduleMutation(
            scheduleIDs: mutationScheduleIDs,
            matchingEntryID: entryID,
            invalidatesJournalProjection: false
        )
        defer {
            endJournalAndScheduleMutation(
                scheduleIDs: mutationScheduleIDs,
                matchingEntryID: entryID
            )
        }
        let generation = storeGeneration
        let matchStore = try requireStore()
        let entry: JournalEntry
        if let cached = entries.first(where: { $0.id == entryID }) {
            entry = cached
        } else if let stored = try await matchStore.fetch(
            JournalEntry.self,
            id: entryID.uuidString,
            from: .journalEntries
        ) {
            entry = stored
        } else {
            throw AppModelError.missingRecord
        }
        guard ownsStoreGeneration(generation) else { throw AppModelError.locked }
        guard !scheduledTransactions.contains(where: { schedule in
            schedule.resolutions.contains(where: { $0.linkedEntryID == entryID })
        }) else {
            throw AppModelError.scheduleEntryAlreadyMatched
        }
        guard let index = scheduledTransactions.firstIndex(where: {
            $0.id == scheduleID
        }) else {
            throw AppModelError.missingRecord
        }
        var updated = scheduledTransactions[index]
        guard updated.matches(entry) else {
            throw AppModelError.scheduleEntryMismatch
        }
        try updated.resolveCurrent(
            occurrenceID: occurrenceID,
            as: .matched,
            linkedEntryID: entryID,
            at: resolvedAt,
            calendar: recurrenceCalendar
        )
        await lifecycleHooks.checkpoint(.beforeScheduleMatchCommit)
        guard ownsStoreGeneration(generation) else { throw AppModelError.locked }
        try await matchStore.upsert(
            updated,
            id: updated.id.uuidString,
            in: .scheduledTransactions
        )
        guard isCurrentStoreGeneration(generation) else { return }
        scheduledTransactions[index] = updated
        scheduledTransactions.sort { $0.nextOccurrence < $1.nextOccurrence }
        existingScheduledLinkedEntryIDs.insert(entryID)
    }

    func deleteScheduledTransaction(id: UUID) async throws {
        try beginScheduleMutation(id: id)
        defer { endScheduleMutation(id: id) }
        let generation = storeGeneration
        let scheduleStore = try requireStore()
        try await scheduleStore.remove(id: id.uuidString, from: .scheduledTransactions)
        guard isCurrentStoreGeneration(generation) else { return }
        scheduledTransactions.removeAll { $0.id == id }
    }

    func mutateSchedule(
        id: UUID,
        _ mutation: (inout ScheduledTransaction) throws -> Void
    ) async throws {
        try beginScheduleMutation(id: id)
        defer { endScheduleMutation(id: id) }
        guard let index = scheduledTransactions.firstIndex(where: { $0.id == id }) else {
            throw AppModelError.missingRecord
        }
        var updated = scheduledTransactions[index]
        try mutation(&updated)

        let generation = storeGeneration
        let scheduleStore = try requireStore()
        await lifecycleHooks.checkpoint(.beforeScheduleMutationCommit)
        guard ownsStoreGeneration(generation) else { throw AppModelError.locked }
        try await scheduleStore.upsert(
            updated,
            id: updated.id.uuidString,
            in: .scheduledTransactions
        )
        guard isCurrentStoreGeneration(generation) else { return }
        scheduledTransactions[index] = updated
        scheduledTransactions.sort { $0.nextOccurrence < $1.nextOccurrence }
    }

    func beginScheduleMutation(id: UUID) throws {
        guard !isLifecycleMutationInProgress,
              !isWorking,
              state == .ready,
              !isJournalMutationInProgress,
              scheduleMutationsInProgress.insert(id).inserted else {
            throw AppModelError.transactionInProgress
        }
    }

    func endScheduleMutation(id: UUID) {
        scheduleMutationsInProgress.remove(id)
        applyDeferredLockIfPossible()
    }

    func beginJournalAndScheduleMutation(
        scheduleIDs: Set<UUID>,
        matchingEntryID: UUID? = nil,
        invalidatesJournalProjection: Bool = true
    ) throws {
        guard !isLifecycleMutationInProgress,
              !isWorking,
              state == .ready,
              !isJournalMutationInProgress,
              investmentMutationsInProgress.isEmpty,
              scheduleMutationsInProgress.isEmpty,
              scheduleEntryMatchesInProgress.isEmpty else {
            throw AppModelError.transactionInProgress
        }
        manualJournalMutationIsActive = true
        scheduleMutationsInProgress.formUnion(scheduleIDs)
        if let matchingEntryID {
            scheduleEntryMatchesInProgress.insert(matchingEntryID)
        }
        if invalidatesJournalProjection {
            invalidateInFlightJournalProjection()
        }
    }

    func endJournalAndScheduleMutation(
        scheduleIDs: Set<UUID>,
        matchingEntryID: UUID? = nil
    ) {
        scheduleMutationsInProgress.subtract(scheduleIDs)
        if let matchingEntryID {
            scheduleEntryMatchesInProgress.remove(matchingEntryID)
        }
        endJournalMutation()
    }

    func validateScheduleReferences(
        _ schedule: ScheduledTransaction
    ) throws {
        try validateScheduleReferences(schedule, in: accountsByID)
    }

    func validateScheduleReferences(
        _ schedule: ScheduledTransaction,
        in candidateAccountsByID: [UUID: LedgerAccount]
    ) throws {
        guard let account = candidateAccountsByID[schedule.accountID],
              let category = candidateAccountsByID[
                  schedule.categoryAccountID
              ] else {
            throw AppModelError.missingRecord
        }
        guard !account.isArchived, !category.isArchived else {
            throw AppModelError.ledgerItemArchived
        }
        guard let currency = account.currency,
              currency == schedule.amount.currency,
              account.kind == .asset || account.kind == .liability,
              account.systemRole == nil,
              category.systemRole == nil,
              (schedule.kind == .expense && category.kind == .expense)
                || (schedule.kind == .income && category.kind == .income) else {
            throw AppModelError.missingRecord
        }
    }

    static func scheduleFingerprint(
        for occurrenceID: ScheduledOccurrenceID
    ) -> String {
        "moneyup:schedule:\(occurrenceID.scheduleID.uuidString.lowercased()):"
            + "\(occurrenceID.seriesVersion):\(occurrenceID.index)"
    }
}
