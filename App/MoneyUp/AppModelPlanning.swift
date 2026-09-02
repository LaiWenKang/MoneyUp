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
        pacingCadence: BudgetPacingCadence? = nil,
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
            pacingCadence: pacingCadence,
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
        pacingCadence: BudgetPacingCadence? = nil,
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
        if let pacingCadence { updated.pacingCadence = pacingCadence }
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
}
