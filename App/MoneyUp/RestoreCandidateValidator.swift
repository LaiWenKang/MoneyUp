import Foundation
import MoneyUpCore
import MoneyUpPersistence

/// Strict, side-effect-free checks used only after an archive has been loaded
/// into a disposable encrypted store. Normal unlock recovery remains tolerant
/// so one damaged row cannot hide the rest of a readable book.
enum RestoreCandidateValidator {
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
        var aggregateRecordIDByteCount = 0
        var collectionCounts: [String: Int] = [:]
        var journalPostingCount = 0
        var attributionPostingCount = 0
        var holdingActivityCount = 0
        var lifecycleReferenceCount = 0
        var scheduleResolutionCount = 0
        var savingsGoalActivityCount = 0
        var aggregatePayloadByteCount = 0

        do {
            for (index, record) in snapshot.records.enumerated() {
                if index.isMultiple(of: 256) { try Task.checkCancellation() }
                let recordIDByteCount = record.recordID.utf8.count
                let (nextIDBytes, overflow) = aggregateRecordIDByteCount
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
                aggregateRecordIDByteCount = nextIDBytes
                let (nextPayloadBytes, payloadOverflow) =
                    aggregatePayloadByteCount.addingReportingOverflow(
                        record.payload.count
                    )
                guard !payloadOverflow,
                      maximumAggregatePayloadByteCount.map({
                          nextPayloadBytes <= $0
                      }) ?? true else {
                    throw AppModelError.invalidBook
                }
                aggregatePayloadByteCount = nextPayloadBytes

                let collection = RecordCollection(rawValue: record.collection)
                let payloadLimit = collection == .receiptAttachments
                    ? maximumReceiptPayloadByteCount
                    : maximumPayloadByteCount
                guard record.payload.count <= payloadLimit else {
                    throw AppModelError.invalidBook
                }
                if let collection {
                    collectionCounts[collection.rawValue, default: 0] += 1
                    guard collectionCounts[collection.rawValue, default: 0]
                            <= maximumRecordCount(for: collection) else {
                        throw AppModelError.invalidBook
                    }
                }
                guard let collection else { continue }

                switch collection {
                case .journalEntries, .journalEntryRevisions:
                    let shape = try decoder.decode(
                        JournalWorkShape.self,
                        from: record.payload
                    )
                    journalPostingCount = try boundedAggregateCount(
                        current: journalPostingCount,
                        adding: shape.postingCount,
                        perRecordLimit: maximumJournalPostingsPerEntry,
                        aggregateLimit: maximumJournalPostingCount
                    )
                case .scheduledTransactions:
                    let shape = try decoder.decode(
                        ScheduledTransactionWorkShape.self,
                        from: record.payload
                    )
                    scheduleResolutionCount = try boundedAggregateCount(
                        current: scheduleResolutionCount,
                        adding: shape.resolutionCount,
                        perRecordLimit: maximumScheduleResolutionsPerSchedule,
                        aggregateLimit: maximumScheduleResolutionCount
                    )
                case .investmentHoldings:
                    let shape = try decoder.decode(
                        InvestmentHoldingWorkShape.self,
                        from: record.payload
                    )
                    guard shape.counts.allSatisfy({
                        $0 <= maximumHoldingActivitiesPerCollection
                    }) else {
                        throw AppModelError.invalidBook
                    }
                    holdingActivityCount = try boundedAggregateCount(
                        current: holdingActivityCount,
                        adding: shape.totalCount,
                        perRecordLimit: maximumHoldingActivitiesPerHolding,
                        aggregateLimit: maximumHoldingActivityCount
                    )
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
                    lifecycleReferenceCount = try boundedAggregateCount(
                        current: lifecycleReferenceCount,
                        adding: shape.referenceCount,
                        perRecordLimit: maximumLifecycleReferencesPerAudit,
                        aggregateLimit: maximumLifecycleEntryReferenceCount
                    )
                case .savingsGoals:
                    let shape = try decoder.decode(
                        SavingsGoalWorkShape.self,
                        from: record.payload
                    )
                    guard shape.movementCount <= maximumSavingsGoalMovements,
                          shape.resetCount <= maximumSavingsGoalResets else {
                        throw AppModelError.invalidBook
                    }
                    savingsGoalActivityCount = try boundedAggregateCount(
                        current: savingsGoalActivityCount,
                        adding: shape.totalCount,
                        perRecordLimit: maximumSavingsGoalActivitiesPerGoal,
                        aggregateLimit: maximumSavingsGoalActivityCount
                    )
                case .budgetConfigurationTimelines:
                    let shape = try decoder.decode(
                        BudgetTimelineWorkShape.self,
                        from: record.payload
                    )
                    guard shape.revisionCount
                            <= maximumBudgetTimelineRevisionCount,
                          shape.nodeCounts.allSatisfy({
                              $0 <= maximumBudgetNodesPerRevision
                          }),
                          shape.totalNodeCount
                            <= maximumBudgetTimelineNodeCount else {
                        throw AppModelError.invalidBook
                    }
                case .budgetEntryAttributions:
                    let shape = try decoder.decode(
                        BudgetAttributionWorkShape.self,
                        from: record.payload
                    )
                    attributionPostingCount = try boundedAggregateCount(
                        current: attributionPostingCount,
                        adding: shape.postingCount,
                        perRecordLimit: maximumJournalPostingsPerEntry,
                        aggregateLimit: maximumJournalPostingCount
                    )
                case .profile, .accounts, .budgetNodes, .netWorthSnapshots,
                     .receiptAttachments, .exchangeRates:
                    break
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AppModelError.invalidBook
        }
    }
}
