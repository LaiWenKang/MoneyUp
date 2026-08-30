import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

extension AppModel {
    func setBudgetLimit(
        categoryID: UUID,
        amount: Decimal?,
        purpose: BudgetPurpose? = nil,
        rolloverRule: BudgetRolloverRule? = nil
    ) async throws {
        try beginJournalMutation()
        defer { endJournalMutation() }
        guard let currency = profile?.baseCurrency,
              let index = budgetNodes.firstIndex(where: { $0.id == categoryID }) else {
            throw AppModelError.missingRecord
        }
        let updated = try budgetNodeUpdating(
            budgetNodes[index],
            amount: amount,
            purpose: purpose,
            rolloverRule: rolloverRule,
            currency: currency
        )
        var candidate = budgetNodes
        candidate[index] = updated
        _ = try BudgetTree(currency: currency, nodes: candidate)
        let candidateTimeline = try budgetConfigurationTimelineRecording(
            nodes: candidate
        )

        let generation = storeGeneration
        let budgetStore = try requireStore()
        try await budgetStore.write([
            try RecordWrite(updated, id: updated.id.uuidString, in: .budgetNodes),
            try budgetConfigurationTimelineWrite(candidateTimeline)
        ])
        guard isCurrentStoreGeneration(generation) else { return }
        budgetConfigurationTimeline = candidateTimeline
        budgetNodes = candidate
    }

    func budgetNodeUpdating(
        _ original: BudgetNode,
        amount: Decimal?,
        purpose: BudgetPurpose?,
        rolloverRule: BudgetRolloverRule?,
        currency: CurrencyCode
    ) throws -> BudgetNode {
        if let amount, amount < .zero { throw AppModelError.negativeAmount }
        if let amount {
            try requireValidNewWriteAmount(
                amount,
                currency: currency,
                preserving: original.limit?.amount
            )
        }

        var updated = original
        updated.limit = try amount.map { try Money($0, currency: currency) }
        if let purpose { updated.purpose = purpose }
        if let rolloverRule {
            if rolloverRule == .none {
                updated.rolloverRule = .none
                updated.rolloverStartedAt = nil
            } else {
                if updated.rolloverRule != rolloverRule
                    || updated.rolloverStartedAt == nil {
                    let now = currentDate()
                    updated.rolloverStartedAt = reportingCalendar.dateInterval(
                        of: .month,
                        for: now
                    )?.start ?? now
                }
                updated.rolloverRule = rolloverRule
            }
        }
        if updated.limit == nil {
            updated.rolloverRule = .none
            updated.rolloverStartedAt = nil
        }
        return updated
    }

    func withSerializedSavingsGoalMutation<T: Sendable>(
        id: UUID,
        operation: @MainActor () async throws -> T
    ) async throws -> T {
        try beginGoalMutation()
        await savingsGoalMutationSerializer.acquire(id)
        do {
            try Task.checkCancellation()
            let result = try await operation()
            await savingsGoalMutationSerializer.release(id)
            endGoalMutation()
            return result
        } catch {
            await savingsGoalMutationSerializer.release(id)
            endGoalMutation()
            throw error
        }
    }

    func addSavingsGoal(_ goal: SavingsGoal) async throws {
        try await withSerializedSavingsGoalMutation(id: goal.id) {
            guard !self.savingsGoals.contains(where: { $0.id == goal.id }) else {
                throw AppModelError.invalidBook
            }
            try self.requireValidNewWriteAmount(
                goal.target.amount,
                currency: goal.target.currency
            )
            let generation = self.storeGeneration
            let goalStore = try self.requireStore()
            await self.lifecycleHooks.checkpoint(.beforeSavingsGoalWrite)
            try await goalStore.upsert(
                goal,
                id: goal.id.uuidString,
                in: .savingsGoals
            )
            guard self.isCurrentStoreGeneration(generation) else { return }
            self.savingsGoals.removeAll { $0.id == goal.id }
            self.savingsGoals.append(goal)
            self.savingsGoals.sort { $0.targetDate < $1.targetDate }
        }
    }

    func updateSavingsGoal(
        id: UUID,
        name: String,
        kind: SavingsGoalKind,
        targetAmount: Decimal,
        targetDate: Date,
        resetRule: SavingsGoalResetRule
    ) async throws {
        try await withSerializedSavingsGoalMutation(id: id) {
            guard let goal = self.savingsGoals.first(where: { $0.id == id }) else {
                throw AppModelError.missingRecord
            }
            let currency = goal.target.currency
            try self.requireValidNewWriteAmount(targetAmount, currency: currency)
            let target = try Money(targetAmount, currency: currency)
            let updated: SavingsGoal
            do {
                updated = try goal.updating(
                    name: name,
                    kind: kind,
                    target: target,
                    targetDate: targetDate,
                    resetRule: resetRule
                )
            } catch {
                throw AppModelError.invalidGoal
            }
            try await self.persist(goal: updated)
        }
    }

    func addSavingsGoalMovement(
        goalID: UUID,
        kind: SavingsGoalMovementKind,
        amount: Decimal,
        occurredAt: Date = Date()
    ) async throws {
        try await withSerializedSavingsGoalMutation(id: goalID) {
            guard let goal = self.savingsGoals.first(where: { $0.id == goalID }) else {
                throw AppModelError.missingRecord
            }
            try self.requireValidNewWriteAmount(
                amount,
                currency: goal.target.currency
            )
            let movement: SavingsGoalMovement
            let updated: SavingsGoal
            do {
                movement = try SavingsGoalMovement(
                    kind: kind,
                    money: try Money(amount, currency: goal.target.currency),
                    occurredAt: occurredAt,
                    originTimeZoneIdentifier: self.profile?
                        .reportingTimeZoneIdentifier ?? "GMT"
                )
                updated = try goal.adding(
                    movement,
                    calendar: self.reportingCalendar
                )
            } catch SavingsGoalError.withdrawalExceedsBalance {
                throw AppModelError.goalWithdrawalExceedsBalance
            } catch {
                throw AppModelError.invalidGoal
            }
            try await self.persist(goal: updated)
        }
    }

    func resetSavingsGoal(id: UUID, at date: Date = Date()) async throws {
        try await withSerializedSavingsGoalMutation(id: id) {
            guard let goal = self.savingsGoals.first(where: { $0.id == id }) else {
                throw AppModelError.missingRecord
            }
            let updated: SavingsGoal
            do {
                updated = try goal.resetting(
                    at: date,
                    originTimeZoneIdentifier: self.profile?
                        .reportingTimeZoneIdentifier ?? "GMT"
                )
            } catch {
                throw AppModelError.invalidGoal
            }
            try await self.persist(goal: updated)
        }
    }

    func setSavingsGoalArchived(id: UUID, isArchived: Bool) async throws {
        try await withSerializedSavingsGoalMutation(id: id) {
            guard let goal = self.savingsGoals.first(where: { $0.id == id }) else {
                throw AppModelError.missingRecord
            }
            let updated = try goal.updating(
                name: goal.name,
                kind: goal.kind,
                target: goal.target,
                targetDate: goal.targetDate,
                resetRule: goal.resetRule,
                isArchived: isArchived
            )
            try await self.persist(goal: updated)
        }
    }

    func deleteSavingsGoal(id: UUID) async throws {
        try await withSerializedSavingsGoalMutation(id: id) {
            guard self.savingsGoals.contains(where: { $0.id == id }) else {
                throw AppModelError.missingRecord
            }
            let generation = self.storeGeneration
            let goalStore = try self.requireStore()
            await self.lifecycleHooks.checkpoint(.beforeSavingsGoalWrite)
            try await goalStore.remove(id: id.uuidString, from: .savingsGoals)
            guard self.isCurrentStoreGeneration(generation) else { return }
            self.savingsGoals.removeAll { $0.id == id }
        }
    }

    func savingsGoalSummary(
        _ goal: SavingsGoal,
        asOf: Date = Date()
    ) -> DerivedValue<SavingsGoalSummary> {
        do {
            return .available(
                try goal.summary(asOf: asOf)
            )
        } catch {
            DerivedValueDiagnostics.record(
                .goalCalculationFailed,
                operation: "savings-goal-summary",
                error: error
            )
            return .unavailable(.goalCalculationFailed)
        }
    }

    func persist(goal: SavingsGoal) async throws {
        let generation = storeGeneration
        let goalStore = try requireStore()
        await lifecycleHooks.checkpoint(.beforeSavingsGoalWrite)
        try await goalStore.upsert(
            goal,
            id: goal.id.uuidString,
            in: .savingsGoals
        )
        guard isCurrentStoreGeneration(generation) else { return }
        guard savingsGoals.contains(where: { $0.id == goal.id }) else {
            throw AppModelError.missingRecord
        }
        savingsGoals.removeAll { $0.id == goal.id }
        savingsGoals.append(goal)
        savingsGoals.sort { $0.targetDate < $1.targetDate }
    }

    func addScheduledTransaction(_ transaction: ScheduledTransaction) async throws {
        try beginScheduleMutation(id: transaction.id)
        defer { endScheduleMutation(id: transaction.id) }
        guard !scheduledTransactions.contains(where: { $0.id == transaction.id }) else {
            throw AppModelError.transactionInProgress
        }
        let canonical = try transaction.updating(
            kind: transaction.kind,
            name: transaction.name,
            amount: transaction.amount,
            accountID: transaction.accountID,
            categoryAccountID: transaction.categoryAccountID,
            nextOccurrence: transaction.nextOccurrence,
            frequency: transaction.frequency,
            recurrenceTimeZone: reportingCalendar.timeZone
        )
        try validateScheduleReferences(canonical)
        try requireValidNewWriteAmount(
            canonical.amount.amount,
            currency: canonical.amount.currency
        )
        let generation = storeGeneration
        let scheduleStore = try requireStore()
        await lifecycleHooks.checkpoint(.beforeScheduleMutationCommit)
        guard ownsStoreGeneration(generation) else { throw AppModelError.locked }
        try await scheduleStore.upsert(
            canonical,
            id: canonical.id.uuidString,
            in: .scheduledTransactions
        )
        guard isCurrentStoreGeneration(generation) else { return }
        scheduledTransactions.append(canonical)
        scheduledTransactions.sort { $0.nextOccurrence < $1.nextOccurrence }
    }

    func updateScheduledTransaction(
        id: UUID,
        kind: JournalEntryKind,
        name: String,
        amount: Money,
        accountID: UUID,
        categoryAccountID: UUID,
        nextOccurrence: Date,
        frequency: RecurrenceFrequency
    ) async throws {
        try await mutateSchedule(id: id) { existing in
            let updated = try existing.updating(
                kind: kind,
                name: name,
                amount: amount,
                accountID: accountID,
                categoryAccountID: categoryAccountID,
                nextOccurrence: nextOccurrence,
                frequency: frequency,
                recurrenceTimeZone: self.reportingCalendar.timeZone
            )
            try self.validateScheduleReferences(updated)
            try self.requireValidNewWriteAmount(
                updated.amount.amount,
                currency: updated.amount.currency,
                preserving: existing.amount.currency == updated.amount.currency
                    ? existing.amount.amount
                    : nil
            )
            existing = updated
        }
    }

    func pauseScheduledTransaction(id: UUID) async throws {
        try await mutateSchedule(id: id) { try $0.pause() }
    }

    func resumeScheduledTransaction(id: UUID) async throws {
        try await mutateSchedule(id: id) { try $0.resume() }
    }

    func endScheduledTransaction(id: UUID, at date: Date = Date()) async throws {
        try await mutateSchedule(id: id) { try $0.end(at: date) }
    }

    func confirmScheduledOccurrence(
        scheduleID: UUID,
        occurrenceID: ScheduledOccurrenceID,
        at date: Date = Date()
    ) async throws {
        try await mutateSchedule(id: scheduleID) {
            try $0.confirmCurrent(occurrenceID: occurrenceID, at: date)
        }
    }

    func skipScheduledOccurrence(
        scheduleID: UUID,
        occurrenceID: ScheduledOccurrenceID,
        at date: Date = Date(),
        calendar: Calendar? = nil
    ) async throws {
        let recurrenceCalendar = calendar ?? reportingCalendar
        try await mutateSchedule(id: scheduleID) {
            try $0.resolveCurrent(
                occurrenceID: occurrenceID,
                as: .skipped,
                at: date,
                calendar: recurrenceCalendar
            )
        }
    }

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
