import Foundation
import MoneyUpCore
import MoneyUpPersistence

private struct AllowanceRecoveryFixedPoint: Equatable {
    let accountIDs: Set<UUID>
    let planIDs: Set<UUID>
    let invalidEntryIDs: Set<UUID>
}

extension AppModel {
    func recoveryAllowanceRelationshipEvidence(
        accountsByID: [UUID: LedgerAccount],
        observesCancellation: Bool
    ) throws -> (
        linkedEntryIDs: [UUID],
        restrictedEntryIDsByPlan: [UUID: Set<UUID>]
    ) {
        var linkedEntryIDs: [UUID] = []
        var restrictedEntryIDsByPlan: [UUID: Set<UUID>] = [:]
        var evidenceCount = 0
        for (planOffset, plan) in allowancePlans.enumerated() {
            if observesCancellation, planOffset.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            let isCurrentRestricted = plan.fundingMode == .prepaidAsset
                && plan.linkedAccountID.flatMap {
                    accountsByID[$0]?.accountType
                } == .restrictedAllowance
            for entryID in try recoveryAllowanceEntryIDs(
                plan,
                evidenceCount: &evidenceCount,
                observesCancellation: observesCancellation
            ) {
                linkedEntryIDs.append(entryID)
                if isCurrentRestricted {
                    restrictedEntryIDsByPlan[plan.id, default: []].insert(entryID)
                }
            }
        }
        return (linkedEntryIDs, restrictedEntryIDsByPlan)
    }

    private func recoveryAllowanceEntryIDs(
        _ plan: AllowancePlan,
        evidenceCount: inout Int,
        observesCancellation: Bool
    ) throws -> [UUID] {
        var result: [UUID] = []
        for usage in plan.usages {
            if observesCancellation, evidenceCount.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            evidenceCount += 1
            if let entryID = usage.linkedJournalEntryID { result.append(entryID) }
        }
        for reconciliation in plan.reconciliations {
            if observesCancellation, evidenceCount.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            evidenceCount += 1
            if let entryID = reconciliation.linkedJournalEntryID {
                result.append(entryID)
            }
        }
        return result
    }

    /// Account, plan, and journal quarantine are mutually dependent. Every
    /// nonconverged pass grows the entry quarantine or removes an account/plan,
    /// so the initial object counts plus two stabilization passes are a finite
    /// monotonic bound.
    func convergeRecoveredLedgerRelationships(
        _ relationships: AppModelRecoveryRelationships,
        in store: EncryptedRecordStore,
        mode: BookLoadMode
    ) async throws {
        let maximumPassCount = accounts.count + allowancePlans.count + 2
        var invalidEntryIDs = invalidJournalEntryIDs
        for pass in 0..<maximumPassCount {
            if mode.observesCancellationWhileLoading,
               pass.isMultiple(of: 16) {
                try Task.checkCancellation()
            }
            let before = allowanceRecoveryFixedPoint(invalidEntryIDs)
            try quarantineRecoveredRelationships(
                relationships,
                excludingEntryIDs: invalidEntryIDs,
                observesCancellation: mode.observesCancellationWhileLoading
            )
            let removedPlanIDs = before.planIDs
                .subtracting(allowancePlans.map(\.id))
            try addRemovedPrepaidEvidence(
                for: removedPlanIDs,
                relationships: relationships,
                to: &invalidEntryIDs,
                observesCancellation: mode.observesCancellationWhileLoading
            )
            guard Set(accounts.map(\.id)) == before.accountIDs else { continue }
            let expectedCurrencies = Dictionary(
                uniqueKeysWithValues: accounts.compactMap { account in
                    account.currency.map { (account.id, $0) }
                }
            )
            let ledger = try await store.journalLedgerIndex(
                validAccountIDs: before.accountIDs,
                expectedAccountCurrencies: expectedCurrencies,
                excludingEntryIDs: invalidEntryIDs
            )
            invalidEntryIDs.formUnion(
                ledger.invalidRelationshipEntryIDs.union(
                    ledger.issues.compactMap { UUID(uuidString: $0.recordID) }
                )
            )
            let beforeAllowanceIntegrity = allowanceRecoveryFixedPoint(
                invalidEntryIDs
            )
            let result = try await recoveredAllowanceJournalIntegrity(
                in: store,
                excludingEntryIDs: invalidEntryIDs,
                observesCancellation: mode.observesCancellationWhileLoading
            )
            applyRecoveredAllowanceJournalResult(result, to: &invalidEntryIDs)
            guard allowanceRecoveryFixedPoint(invalidEntryIDs)
                == beforeAllowanceIntegrity else { continue }
            try await quarantineInvalidRestrictedAllowanceLedgers(
                in: store,
                excludingEntryIDs: invalidEntryIDs,
                observesCancellation: mode.observesCancellationWhileLoading
            )
            guard Set(accounts.map(\.id)) == before.accountIDs else { continue }
            if !mode.rejectsRecoveryIssues,
               quarantineInvestmentLedgerMismatches(balances: ledger.balances) {
                continue
            }
            if allowanceRecoveryFixedPoint(invalidEntryIDs) == before {
                invalidJournalEntryIDs = invalidEntryIDs
                return
            }
        }
        throw AppModelError.invalidBook
    }

    private func allowanceRecoveryFixedPoint(
        _ invalidEntryIDs: Set<UUID>
    ) -> AllowanceRecoveryFixedPoint {
        AllowanceRecoveryFixedPoint(
            accountIDs: Set(accounts.map(\.id)),
            planIDs: Set(allowancePlans.map(\.id)),
            invalidEntryIDs: invalidEntryIDs
        )
    }

    private func applyRecoveredAllowanceJournalResult(
        _ result: AllowanceJournalIntegrityResult,
        to invalidEntryIDs: inout Set<UUID>
    ) {
        if !result.invalidPlanIDs.isEmpty {
            recoveryIssues.append(contentsOf: result.invalidPlanIDs.sorted {
                $0.uuidString < $1.uuidString
            }.map { "allowance_plans/journal-\($0)" })
            allowancePlans.removeAll { result.invalidPlanIDs.contains($0.id) }
        }
        let newlyUnauthorized = result.unauthorizedRestrictedDebitEntryIDs
            .subtracting(invalidEntryIDs)
        if !newlyUnauthorized.isEmpty {
            recoveryIssues.append(contentsOf: newlyUnauthorized.sorted {
                $0.uuidString < $1.uuidString
            }.map { "journal_entries/restricted-unauthorized-\($0)" })
            invalidEntryIDs.formUnion(newlyUnauthorized)
        }
        let invalidEvidence = result.invalidPrepaidEvidenceEntryIDs
            .subtracting(invalidEntryIDs)
        if !invalidEvidence.isEmpty {
            recoveryIssues.append(contentsOf: invalidEvidence.sorted {
                $0.uuidString < $1.uuidString
            }.map { "journal_entries/restricted-invalid-evidence-\($0)" })
            invalidEntryIDs.formUnion(invalidEvidence)
        }
    }

    private func addRemovedPrepaidEvidence(
        for planIDs: Set<UUID>,
        relationships: AppModelRecoveryRelationships,
        to invalidEntryIDs: inout Set<UUID>,
        observesCancellation: Bool
    ) throws {
        var evidenceIDs = Set<UUID>()
        var evidenceCount = 0
        for (offset, planID) in planIDs.enumerated() {
            if observesCancellation, offset.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            for entryID in relationships
                .restrictedPrepaidEvidenceEntryIDsByPlan[planID] ?? [] {
                if observesCancellation, evidenceCount.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                evidenceCount += 1
                if !invalidEntryIDs.contains(entryID) {
                    evidenceIDs.insert(entryID)
                }
            }
        }
        guard !evidenceIDs.isEmpty else { return }
        let orderedIDs = evidenceIDs.sorted {
            $0.uuidString < $1.uuidString
        }
        if observesCancellation { try Task.checkCancellation() }
        for entryID in orderedIDs {
            recoveryIssues.append(
                "journal_entries/restricted-invalid-evidence-\(entryID)"
            )
        }
        invalidEntryIDs.formUnion(evidenceIDs)
    }

    /// Loads only complete evidence referenced by an allowance or carrying a
    /// negative restricted posting. Positive funding remains ordinary ledger
    /// history and needs no plan authorization.
    private func recoveredAllowanceJournalIntegrity(
        in store: EncryptedRecordStore,
        excludingEntryIDs: Set<UUID>,
        observesCancellation: Bool
    ) async throws -> AllowanceJournalIntegrityResult {
        let accountsByID = Dictionary(
            uniqueKeysWithValues: accounts.map { ($0.id, $0) }
        )
        let restrictedAccountIDs = Set(accounts.compactMap { account in
            account.accountType == .restrictedAllowance ? account.id : nil
        })
        let restrictedEvents = try await store.fetchJournalPostingEvents(
            accountIDs: restrictedAccountIDs,
            excludingEntryIDs: excludingEntryIDs,
            observesCancellation: observesCancellation
        )
        let request = try allowanceJournalRequest(
            restrictedEvents: restrictedEvents,
            observesCancellation: observesCancellation
        )
        let requestedIDs = request.liveDebitIDs.union(request.linkedEvidenceIDs)
            .subtracting(excludingEntryIDs)
        let recovered = try await store.fetchJournalEntriesRecovering(
            ids: requestedIDs,
            observesCancellation: observesCancellation
        )
        let unreadableIDs = Set(recovered.issues.compactMap {
            UUID(uuidString: $0.recordID)
        })
        recoveryIssues.append(contentsOf: recovered.issues.map {
            "\($0.collection.rawValue)/\($0.recordID)"
        })
        var entriesByID: [UUID: JournalEntry] = [:]
        for (offset, entry) in recovered.values.enumerated() {
            if observesCancellation, offset.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            entriesByID[entry.id] = entry
        }
        let result = try AllowanceJournalIntegrity.validationResult(
            plans: allowancePlans,
            accountsByID: accountsByID,
            entriesByID: entriesByID,
            liveRestrictedDebitEntryIDs: request.liveDebitIDs,
            restrictedLedgerEvents: restrictedEvents,
            observesCancellation: observesCancellation
        )
        return AllowanceJournalIntegrityResult(
            invalidPlanIDs: result.invalidPlanIDs,
            unauthorizedRestrictedDebitEntryIDs:
                result.unauthorizedRestrictedDebitEntryIDs.union(unreadableIDs),
            invalidPrepaidEvidenceEntryIDs:
                result.invalidPrepaidEvidenceEntryIDs
        )
    }

    private func allowanceJournalRequest(
        restrictedEvents: [LedgerPostingEvent],
        observesCancellation: Bool
    ) throws -> (liveDebitIDs: Set<UUID>, linkedEvidenceIDs: Set<UUID>) {
        var liveDebitIDs = Set<UUID>()
        for (offset, event) in restrictedEvents.enumerated() {
            if observesCancellation, offset.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            if event.posting.money.amount < .zero {
                liveDebitIDs.insert(event.entryID)
            }
        }
        var linkedEvidenceIDs = Set<UUID>()
        var evidenceCount = 0
        for (planOffset, plan) in allowancePlans.enumerated() {
            if observesCancellation, planOffset.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            for usage in plan.usages {
                if observesCancellation, evidenceCount.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                evidenceCount += 1
                if let entryID = usage.linkedJournalEntryID {
                    linkedEvidenceIDs.insert(entryID)
                }
            }
            for reconciliation in plan.reconciliations {
                if observesCancellation, evidenceCount.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                evidenceCount += 1
                if let entryID = reconciliation.linkedJournalEntryID {
                    linkedEvidenceIDs.insert(entryID)
                }
            }
        }
        return (liveDebitIDs, linkedEvidenceIDs)
    }
}
