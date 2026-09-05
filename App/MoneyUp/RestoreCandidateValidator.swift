import Foundation
import MoneyUpCore
import MoneyUpPersistence

/// Strict, side-effect-free checks used only after an archive has been loaded
/// into a disposable encrypted store. Normal unlock recovery remains tolerant
/// so one damaged row cannot hide the rest of a readable book.
enum RestoreCandidateValidator {
    struct SnapshotWorkLimitState: Sendable {
        var recordCount = 0
        var aggregateRecordIDByteCount = 0
        var collectionCounts: [String: Int] = [:]
        var journalPostingCount = 0
        var attributionPostingCount = 0
        var holdingActivityCount = 0
        var lifecycleReferenceCount = 0
        var scheduleResolutionCount = 0
        var savingsGoalActivityCount = 0
        var loanActivityCount = 0
        var allowanceUsageCount = 0
        var allowanceReconciliationCount = 0
        var allowancePeriodWorkCount = 0
        var allowanceArchiveTransitionCount = 0
        var aggregatePayloadByteCount = 0
    }

    /// Restore is an untrusted-work boundary even after archive
    /// authentication: a valid password does not make a corrupted or crafted
    /// payload safe to process without deterministic work ceilings.
    // These bounds are well above the product's 10,000-entry stress target,
    // while preventing one authenticated but crafted row from reaching the
    // quadratic legacy/investment validation paths or uninterruptible SQL
    // index loops. The v1 whole-buffer memory limit remains a separate gate.
    static let maximumCandidateRecordCount = 100_000
    static let maximumJournalEntryCount = 100_000
    static let maximumJournalRevisionCount = 100_000
    static let maximumBudgetAttributionCount = 100_000
    static let maximumLifecycleAuditCount = 100_000
    static let maximumJournalPostingsPerEntry = JournalEntry.maximumPostingCount
    static let maximumJournalPostingCount = 250_000
    static let maximumLifecycleEntryReferenceCount = 250_000
    static let maximumLifecycleReferencesPerAudit =
        LedgerAccountLifecycleAudit.maximumAffectedRecordCount
    static let maximumHoldingActivitiesPerCollection =
        InvestmentHolding.maximumActivitiesPerCollection
    static let maximumHoldingActivitiesPerHolding =
        InvestmentHolding.maximumActivitiesPerHolding
    static let maximumHoldingActivityCount = 100_000
    static let maximumRecordIDByteCount = RecordWrite.maximumRecordIDByteCount
    static let maximumAggregateRecordIDByteCount =
        maximumCandidateRecordCount * maximumRecordIDByteCount
    static let maximumAggregateCollectionByteCount =
        maximumCandidateRecordCount * maximumCollectionByteCount
    static let maximumCollectionByteCount = 64
    static let maximumPayloadByteCount = RecordWrite.maximumPayloadByteCount
    // A 15 MB receipt image expands to roughly 20 MB in its first JSON/base64
    // representation. Leave bounded encoding headroom for legitimate rows.
    static let maximumReceiptPayloadByteCount =
        RecordWrite.maximumReceiptPayloadByteCount
    static let maximumScheduleResolutionsPerSchedule =
        ScheduledTransaction.maximumResolutionCount
    static let maximumScheduleResolutionCount = 100_000
    static let maximumQuickLogSplitCount = QuickLogDraft.maximumSplitLineCount
    static let maximumSavingsGoalMovements = SavingsGoal.maximumMovementCount
    static let maximumSavingsGoalResets = SavingsGoal.maximumResetCount
    static let maximumSavingsGoalActivitiesPerGoal =
        SavingsGoal.maximumActivityCount
    static let maximumSavingsGoalActivityCount = 25_000
    static let maximumLoanActivitiesPerPlan = LoanPlan.maximumActivityCount
    static let maximumLoanActivityCount = 100_000
    static let maximumAllowanceUsagesPerPlan = AllowancePlan.maximumUsageCount
    static let maximumAllowanceUsageCount = 100_000
    static let maximumAllowanceReconciliationsPerPlan =
        AllowancePlan.maximumReconciliationCount
    static let maximumAllowanceReconciliationCount = 100_000
    static let maximumAllowancePeriodsPerPlan = 10_000
        + (AllowancePlan.maximumPolicyRevisionCount * 2)
    static let maximumAllowancePeriodWorkCount = 100_000
    static let maximumAllowanceArchiveTransitionsPerPlan =
        AllowancePlan.maximumArchiveTransitionCount
    static let maximumAllowanceArchiveTransitionCount = 100_000
    static let maximumBudgetTimelineRevisionCount =
        BudgetConfigurationTimeline.maximumRevisionCount
    static let maximumBudgetNodesPerRevision =
        BudgetConfigurationTimeline.maximumNodesPerRevision
    static let maximumBudgetTimelineNodeCount = 100_000
    static let maximumBackupStoredPayloadByteCount =
        PortableArchive.maximumStoredPayloadByteCount

    /// Backup remains a byte-preserving recovery operation even when normal
    /// startup quarantines a malformed known row. This pass therefore bounds
    /// only materialized storage; it never decodes or rewrites payload bytes.
    /// Strict nested work/identity validation belongs to restore, where a bad
    /// candidate must not replace the current readable book.
    static func validateBackupSnapshotStorageLimits(
        _ snapshot: DatabaseSnapshot,
        maximumAggregatePayloadByteCount: Int
    ) throws {
        guard isWithinCandidateRecordLimit(snapshot.records.count) else {
            throw AppModelError.invalidBook
        }
        var aggregatePayloadByteCount = 0
        var aggregateRecordIDByteCount = 0
        var aggregateCollectionByteCount = 0
        for (index, record) in snapshot.records.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            aggregatePayloadByteCount = try boundedByteCount(
                current: aggregatePayloadByteCount,
                adding: record.payload.count,
                limit: maximumAggregatePayloadByteCount
            )
            aggregateRecordIDByteCount = try boundedByteCount(
                current: aggregateRecordIDByteCount,
                adding: record.recordID.utf8.count,
                limit: maximumAggregateRecordIDByteCount
            )
            aggregateCollectionByteCount = try boundedByteCount(
                current: aggregateCollectionByteCount,
                adding: record.collection.utf8.count,
                limit: maximumAggregateCollectionByteCount
            )
        }
    }

    /// Strict authenticated-restore work validation. Count probes reject
    /// crafted nested work bombs before the more expensive domain decoders or
    /// SQL index rebuilds run.
    static func validateSnapshotWorkLimits(
        _ snapshot: DatabaseSnapshot,
        maximumAggregatePayloadByteCount: Int? = nil
    ) throws {
        guard isWithinCandidateRecordLimit(snapshot.records.count) else {
            throw AppModelError.invalidBook
        }
        let decoder = JSONDecoder()
        var state = SnapshotWorkLimitState()

        do {
            for (index, record) in snapshot.records.enumerated() {
                try validateSnapshotWorkLimitRecord(
                    record,
                    index: index,
                    maximumAggregatePayloadByteCount:
                        maximumAggregatePayloadByteCount,
                    decoder: decoder,
                    state: &state
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AppModelError.invalidBook
        }
    }

    /// One-row primitive shared by snapshot fixtures and the production
    /// actor-isolated SQL cursor. Keeping the ceiling state explicit prevents
    /// either path from drifting to a different nested-work contract.
    static func validateSnapshotWorkLimitRecord(
        _ record: StoredRecordSnapshot,
        index: Int,
        maximumAggregatePayloadByteCount: Int?,
        decoder: JSONDecoder,
        state: inout SnapshotWorkLimitState
    ) throws {
        if index.isMultiple(of: 256) { try Task.checkCancellation() }
        guard index == state.recordCount,
              index >= 0,
              index < maximumCandidateRecordCount else {
            throw AppModelError.invalidBook
        }
        state.recordCount += 1
        let collection = try validateSnapshotRecordEnvelope(
            record,
            maximumAggregatePayloadByteCount:
                maximumAggregatePayloadByteCount,
            state: &state
        )
        guard let collection else { return }
        try validateNestedWorkLimits(
            for: record,
            collection: collection,
            decoder: decoder,
            state: &state
        )
    }

    static func validateSnapshotRecordEnvelope(
        _ record: StoredRecordSnapshot,
        maximumAggregatePayloadByteCount: Int?,
        state: inout SnapshotWorkLimitState
    ) throws -> RecordCollection? {
        let recordIDByteCount = record.recordID.utf8.count
        let (nextIDBytes, overflow) = state.aggregateRecordIDByteCount
            .addingReportingOverflow(recordIDByteCount)
        guard !record.recordID.isEmpty,
              record.collection.utf8.count <= maximumCollectionByteCount,
              recordIDByteCount <= maximumRecordIDByteCount,
              !overflow,
              nextIDBytes <= maximumAggregateRecordIDByteCount,
              !record.payload.isEmpty,
              record.updatedAt.isFinite else {
            throw AppModelError.invalidBook
        }
        state.aggregateRecordIDByteCount = nextIDBytes
        let (nextPayloadBytes, payloadOverflow) = state
            .aggregatePayloadByteCount.addingReportingOverflow(
                record.payload.count
            )
        guard !payloadOverflow,
              maximumAggregatePayloadByteCount.map({
                  nextPayloadBytes <= $0
              }) ?? true else {
            throw AppModelError.invalidBook
        }
        state.aggregatePayloadByteCount = nextPayloadBytes

        let collection = RecordCollection(rawValue: record.collection)
        let payloadLimit = collection == .receiptAttachments
            ? maximumReceiptPayloadByteCount
            : maximumPayloadByteCount
        guard record.payload.count <= payloadLimit else {
            throw AppModelError.invalidBook
        }
        if let collection {
            state.collectionCounts[collection.rawValue, default: 0] += 1
            guard state.collectionCounts[collection.rawValue, default: 0]
                    <= maximumRecordCount(for: collection) else {
                throw AppModelError.invalidBook
            }
        }
        return collection
    }

    static func validateNestedWorkLimits(
        for record: StoredRecordSnapshot,
        collection: RecordCollection,
        decoder: JSONDecoder,
        state: inout SnapshotWorkLimitState
    ) throws {
        switch collection {
        case .journalEntries, .journalEntryRevisions:
            let shape = try decoder.decode(JournalWorkShape.self, from: record.payload)
            state.journalPostingCount = try boundedAggregateCount(
                current: state.journalPostingCount,
                adding: shape.postingCount,
                perRecordLimit: maximumJournalPostingsPerEntry,
                aggregateLimit: maximumJournalPostingCount
            )
        case .scheduledTransactions:
            let shape = try decoder.decode(
                ScheduledTransactionWorkShape.self,
                from: record.payload
            )
            state.scheduleResolutionCount = try boundedAggregateCount(
                current: state.scheduleResolutionCount,
                adding: shape.resolutionCount,
                perRecordLimit: maximumScheduleResolutionsPerSchedule,
                aggregateLimit: maximumScheduleResolutionCount
            )
        case .investmentHoldings:
            try validateHoldingWork(record, decoder: decoder, state: &state)
        case .quickLogDrafts:
            let shape = try decoder.decode(
                QuickLogDraftWorkShape.self,
                from: record.payload
            )
            guard shape.splitCount <= maximumQuickLogSplitCount else {
                throw AppModelError.invalidBook
            }
        case .accountLifecycleAudit:
            let shape = try decoder.decode(
                LifecycleAuditWorkShape.self,
                from: record.payload
            )
            state.lifecycleReferenceCount = try boundedAggregateCount(
                current: state.lifecycleReferenceCount,
                adding: shape.referenceCount,
                perRecordLimit: maximumLifecycleReferencesPerAudit,
                aggregateLimit: maximumLifecycleEntryReferenceCount
            )
        case .savingsGoals:
            try validateSavingsGoalWork(record, decoder: decoder, state: &state)
        case .loanPlans:
            let shape = try decoder.decode(LoanPlanWorkShape.self, from: record.payload)
            state.loanActivityCount = try boundedAggregateCount(
                current: state.loanActivityCount,
                adding: shape.activityCount,
                perRecordLimit: maximumLoanActivitiesPerPlan,
                aggregateLimit: maximumLoanActivityCount
            )
        case .allowancePlans:
            try validateAllowanceWork(record, decoder: decoder, state: &state)
        case .budgetConfigurationTimelines:
            try validateBudgetTimelineWork(record, decoder: decoder)
        case .budgetEntryAttributions:
            let shape = try decoder.decode(
                BudgetAttributionWorkShape.self,
                from: record.payload
            )
            state.attributionPostingCount = try boundedAggregateCount(
                current: state.attributionPostingCount,
                adding: shape.postingCount,
                perRecordLimit: maximumJournalPostingsPerEntry,
                aggregateLimit: maximumJournalPostingCount
            )
        case .profile, .accounts, .budgetNodes, .netWorthSnapshots,
             .receiptAttachments, .exchangeRates:
            break
        }
    }

    static func validateHoldingWork(
        _ record: StoredRecordSnapshot,
        decoder: JSONDecoder,
        state: inout SnapshotWorkLimitState
    ) throws {
        let shape = try decoder.decode(
            InvestmentHoldingWorkShape.self,
            from: record.payload
        )
        guard shape.counts.allSatisfy({
            $0 <= maximumHoldingActivitiesPerCollection
        }) else {
            throw AppModelError.invalidBook
        }
        state.holdingActivityCount = try boundedAggregateCount(
            current: state.holdingActivityCount,
            adding: shape.totalCount,
            perRecordLimit: maximumHoldingActivitiesPerHolding,
            aggregateLimit: maximumHoldingActivityCount
        )
    }

    static func validateSavingsGoalWork(
        _ record: StoredRecordSnapshot,
        decoder: JSONDecoder,
        state: inout SnapshotWorkLimitState
    ) throws {
        let shape = try decoder.decode(
            SavingsGoalWorkShape.self,
            from: record.payload
        )
        guard shape.movementCount <= maximumSavingsGoalMovements,
              shape.resetCount <= maximumSavingsGoalResets else {
            throw AppModelError.invalidBook
        }
        state.savingsGoalActivityCount = try boundedAggregateCount(
            current: state.savingsGoalActivityCount,
            adding: shape.totalCount,
            perRecordLimit: maximumSavingsGoalActivitiesPerGoal,
            aggregateLimit: maximumSavingsGoalActivityCount
        )
    }

    static func validateAllowanceWork(
        _ record: StoredRecordSnapshot,
        decoder: JSONDecoder,
        state: inout SnapshotWorkLimitState
    ) throws {
        let shape = try decoder.decode(
            AllowancePlanWorkShape.self,
            from: record.payload
        )
        guard shape.policyRevisionCount
                <= AllowancePlan.maximumPolicyRevisionCount else {
            throw AppModelError.invalidBook
        }
        state.allowanceUsageCount = try boundedAggregateCount(
            current: state.allowanceUsageCount,
            adding: shape.usageCount,
            perRecordLimit: maximumAllowanceUsagesPerPlan,
            aggregateLimit: maximumAllowanceUsageCount
        )
        state.allowanceReconciliationCount = try boundedAggregateCount(
            current: state.allowanceReconciliationCount,
            adding: shape.reconciliationCount,
            perRecordLimit: maximumAllowanceReconciliationsPerPlan,
            aggregateLimit: maximumAllowanceReconciliationCount
        )
        state.allowancePeriodWorkCount = try boundedAggregateCount(
            current: state.allowancePeriodWorkCount,
            adding: shape.periodWorkCount,
            perRecordLimit: maximumAllowancePeriodsPerPlan,
            aggregateLimit: maximumAllowancePeriodWorkCount
        )
        state.allowanceArchiveTransitionCount = try boundedAggregateCount(
            current: state.allowanceArchiveTransitionCount,
            adding: shape.archiveTransitionCount,
            perRecordLimit: maximumAllowanceArchiveTransitionsPerPlan,
            aggregateLimit: maximumAllowanceArchiveTransitionCount
        )
    }

    static func validateBudgetTimelineWork(
        _ record: StoredRecordSnapshot,
        decoder: JSONDecoder
    ) throws {
        let shape = try decoder.decode(
            BudgetTimelineWorkShape.self,
            from: record.payload
        )
        guard shape.revisionCount <= maximumBudgetTimelineRevisionCount,
              shape.nodeCounts.allSatisfy({
                  $0 <= maximumBudgetNodesPerRevision
              }),
              shape.totalNodeCount <= maximumBudgetTimelineNodeCount else {
            throw AppModelError.invalidBook
        }
    }
}
