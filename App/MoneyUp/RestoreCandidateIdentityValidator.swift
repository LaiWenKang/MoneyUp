import Foundation
import MoneyUpCore
import MoneyUpPersistence

extension RestoreCandidateValidator {
    struct SnapshotIdentityState: Sendable {
        var recordCount = 0
        var logicalIDsByCollection: [String: Set<UUID>] = [:]
        var exchangeRatePairDays = Set<String>()
        var physicalRecordIDs = Set<String>()
        var collectionCounts: [String: Int] = [:]
        var aggregateRecordIDByteCount = 0
        var journalPostingCount = 0
        var attributionPostingCount = 0
        var holdingActivityCount = 0
        var lifecycleEntryReferenceCount = 0
        var scheduleResolutionCount = 0
        var savingsGoalActivityCount = 0
        var loanActivityCount = 0
        var allowanceUsageCount = 0
        var allowanceReconciliationCount = 0
        var allowancePeriodWorkCount = 0
        var allowanceArchiveTransitionCount = 0
    }

    static func validateSnapshotIdentities(
        _ snapshot: DatabaseSnapshot
    ) throws {
        try validateSnapshotWorkLimits(snapshot)
        let decoder = JSONDecoder()
        var state = SnapshotIdentityState()

        do {
            for (index, record) in snapshot.records.enumerated() {
                try validateSnapshotIdentityRecord(
                    record,
                    index: index,
                    decoder: decoder,
                    state: &state
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch is AppModelError {
            throw AppModelError.invalidBook
        } catch {
            // Decoding diagnostics can contain private payload details. The
            // restore boundary exposes only a generic integrity failure.
            throw AppModelError.invalidBook
        }
    }

    /// Production restore preflight. Both strict passes stream directly from
    /// the disposable SQLCipher store: nested collection sizes are rejected
    /// across the complete candidate before AppModel performs its collection-
    /// wide domain load, then canonical physical/logical identities are
    /// verified.
    static func validateStoredRecords(
        in store: EncryptedRecordStore,
        expectedRecordCount: Int,
        maximumAggregatePayloadByteCount: Int
    ) async throws {
        guard isWithinCandidateRecordLimit(expectedRecordCount) else {
            throw AppModelError.invalidBook
        }
        do {
            let workDecoder = JSONDecoder()
            let workState = try await store.reduceStoredRecords(
                into: SnapshotWorkLimitState()
            ) { state, record, index in
                try validateSnapshotWorkLimitRecord(
                    record,
                    index: index,
                    maximumAggregatePayloadByteCount:
                        maximumAggregatePayloadByteCount,
                    decoder: workDecoder,
                    state: &state
                )
            }
            guard workState.recordCount == expectedRecordCount else {
                throw AppModelError.invalidBook
            }

            let identityDecoder = JSONDecoder()
            let identityState = try await store.reduceStoredRecords(
                into: SnapshotIdentityState()
            ) { state, record, index in
                try validateSnapshotIdentityRecord(
                    record,
                    index: index,
                    decoder: identityDecoder,
                    state: &state
                )
            }
            guard identityState.recordCount == expectedRecordCount else {
                throw AppModelError.invalidBook
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Some legacy/domain decoders wrap an underlying cancellation in
            // a validation error. The task flag remains authoritative.
            try Task.checkCancellation()
            // Never surface record identifiers or decoder diagnostics from an
            // authenticated but untrusted archive.
            throw AppModelError.invalidBook
        }
    }

    static func validateSnapshotIdentityRecord(
        _ record: StoredRecordSnapshot,
        index: Int,
        decoder: JSONDecoder,
        state: inout SnapshotIdentityState
    ) throws {
        if index.isMultiple(of: 256) { try Task.checkCancellation() }
        guard index == state.recordCount,
              index >= 0,
              index < maximumCandidateRecordCount else {
            throw AppModelError.invalidBook
        }
        state.recordCount += 1
        let collection = try validateIdentityRecordEnvelope(
            record,
            state: &state
        )
        guard let logicalID = try decodeLogicalIdentity(
            record,
            collection: collection,
            decoder: decoder,
            state: &state
        ) else { return }
        // UUID records are always addressed by their exact canonical key.
        guard record.recordID == logicalID.uuidString else {
            throw AppModelError.invalidBook
        }
        let inserted = state.logicalIDsByCollection[
            collection.rawValue,
            default: []
        ].insert(logicalID).inserted
        guard inserted else { throw AppModelError.invalidBook }
    }

    static func validateIdentityRecordEnvelope(
        _ record: StoredRecordSnapshot,
        state: inout SnapshotIdentityState
    ) throws -> RecordCollection {
        let recordIDByteCount = record.recordID.utf8.count
        let (nextIDByteCount, overflow) = state.aggregateRecordIDByteCount
            .addingReportingOverflow(recordIDByteCount)
        guard !record.recordID.isEmpty,
              record.collection.utf8.count <= maximumCollectionByteCount,
              recordIDByteCount <= maximumRecordIDByteCount,
              !overflow,
              nextIDByteCount <= maximumAggregateRecordIDByteCount,
              !record.payload.isEmpty,
              record.updatedAt.isFinite,
              let collection = RecordCollection(rawValue: record.collection) else {
            throw AppModelError.invalidBook
        }
        state.aggregateRecordIDByteCount = nextIDByteCount
        let payloadLimit = collection == .receiptAttachments
            ? maximumReceiptPayloadByteCount : maximumPayloadByteCount
        guard record.payload.count <= payloadLimit else {
            throw AppModelError.invalidBook
        }
        state.collectionCounts[collection.rawValue, default: 0] += 1
        guard state.collectionCounts[collection.rawValue, default: 0]
            <= maximumRecordCount(for: collection) else {
            throw AppModelError.invalidBook
        }
        let physicalIdentity = collection.rawValue
            + "\u{1f}" + record.recordID.lowercased()
        guard state.physicalRecordIDs.insert(physicalIdentity).inserted else {
            throw AppModelError.invalidBook
        }
        return collection
    }

    static func decodeLogicalIdentity(
        _ record: StoredRecordSnapshot,
        collection: RecordCollection,
        decoder: JSONDecoder,
        state: inout SnapshotIdentityState
    ) throws -> UUID? {
        switch collection {
        case .profile:
            try decodePrimaryRecord(
                UserProfile.self,
                record: record,
                expectedID: UserProfile.primaryRecordID,
                decoder: decoder
            )
            return nil
        case .accounts:
            return try decoder.decode(LedgerAccount.self, from: record.payload).id
        case .journalEntries:
            return try decodeJournalIdentity(
                record,
                isRevision: false,
                decoder: decoder,
                state: &state
            )
        case .journalEntryRevisions:
            return try decodeJournalIdentity(
                record,
                isRevision: true,
                decoder: decoder,
                state: &state
            )
        case .budgetNodes:
            return try decoder.decode(BudgetNode.self, from: record.payload).id
        case .scheduledTransactions:
            return try decodeScheduleIdentity(record, decoder: decoder, state: &state)
        case .investmentHoldings:
            return try decodeHoldingIdentity(record, decoder: decoder, state: &state)
        case .netWorthSnapshots:
            return try decoder.decode(NetWorthSnapshot.self, from: record.payload).id
        case .quickLogDrafts:
            try validateQuickLogDraft(record, decoder: decoder)
            return nil
        case .accountLifecycleAudit:
            return try decodeLifecycleIdentity(record, decoder: decoder, state: &state)
        case .receiptAttachments:
            return try decoder.decode(ReceiptAttachment.self, from: record.payload).id
        case .exchangeRates:
            return try decodeExchangeRateIdentity(record, decoder: decoder, state: &state)
        case .savingsGoals:
            return try decodeSavingsGoalIdentity(record, decoder: decoder, state: &state)
        case .loanPlans:
            let shape = try decoder.decode(LoanPlanWorkShape.self, from: record.payload)
            state.loanActivityCount = try boundedAggregateCount(
                current: state.loanActivityCount,
                adding: shape.activityCount,
                perRecordLimit: maximumLoanActivitiesPerPlan,
                aggregateLimit: maximumLoanActivityCount
            )
            return try decoder.decode(LoanPlan.self, from: record.payload).id
        case .allowancePlans:
            return try decodeAllowanceIdentity(
                record,
                decoder: decoder,
                state: &state
            )
        case .budgetConfigurationTimelines:
            try validateBudgetTimeline(record, decoder: decoder)
            return nil
        case .budgetEntryAttributions:
            return try decodeAttributionIdentity(record, decoder: decoder, state: &state)
        }
    }

    static func decodeAllowanceIdentity(
        _ record: StoredRecordSnapshot,
        decoder: JSONDecoder,
        state: inout SnapshotIdentityState
    ) throws -> UUID {
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
        return try decoder.decode(AllowancePlan.self, from: record.payload).id
    }

    static func decodePrimaryRecord<Value: Decodable>(
        _ type: Value.Type,
        record: StoredRecordSnapshot,
        expectedID: String,
        decoder: JSONDecoder
    ) throws {
        guard record.recordID == expectedID else {
            throw AppModelError.invalidBook
        }
        _ = try decoder.decode(type, from: record.payload)
    }

    static func decodeJournalIdentity(
        _ record: StoredRecordSnapshot,
        isRevision: Bool,
        decoder: JSONDecoder,
        state: inout SnapshotIdentityState
    ) throws -> UUID? {
        let shape = try decoder.decode(JournalWorkShape.self, from: record.payload)
        state.journalPostingCount = try boundedAggregateCount(
            current: state.journalPostingCount,
            adding: shape.postingCount,
            perRecordLimit: maximumJournalPostingsPerEntry,
            aggregateLimit: maximumJournalPostingCount
        )
        let entry = try decoder.decode(JournalEntry.self, from: record.payload)
        guard isRevision else { return entry.id }
        guard isValidJournalRevisionRecordID(
            record.recordID,
            entryID: entry.id
        ) else { throw AppModelError.invalidBook }
        return nil
    }

    static func decodeScheduleIdentity(
        _ record: StoredRecordSnapshot,
        decoder: JSONDecoder,
        state: inout SnapshotIdentityState
    ) throws -> UUID {
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
        return try decoder.decode(
            ScheduledTransaction.self,
            from: record.payload
        ).id
    }

    static func decodeHoldingIdentity(
        _ record: StoredRecordSnapshot,
        decoder: JSONDecoder,
        state: inout SnapshotIdentityState
    ) throws -> UUID {
        let shape = try decoder.decode(
            InvestmentHoldingWorkShape.self,
            from: record.payload
        )
        guard shape.counts.allSatisfy({
            $0 <= maximumHoldingActivitiesPerCollection
        }) else { throw AppModelError.invalidBook }
        state.holdingActivityCount = try boundedAggregateCount(
            current: state.holdingActivityCount,
            adding: shape.totalCount,
            perRecordLimit: maximumHoldingActivitiesPerHolding,
            aggregateLimit: maximumHoldingActivityCount
        )
        return try decoder.decode(InvestmentHolding.self, from: record.payload).id
    }

    static func validateQuickLogDraft(
        _ record: StoredRecordSnapshot,
        decoder: JSONDecoder
    ) throws {
        guard record.recordID == QuickLogDraft.primaryRecordID else {
            throw AppModelError.invalidBook
        }
        let shape = try decoder.decode(
            QuickLogDraftWorkShape.self,
            from: record.payload
        )
        guard shape.splitCount <= maximumQuickLogSplitCount else {
            throw AppModelError.invalidBook
        }
        _ = try decoder.decode(QuickLogDraft.self, from: record.payload)
    }

    static func decodeLifecycleIdentity(
        _ record: StoredRecordSnapshot,
        decoder: JSONDecoder,
        state: inout SnapshotIdentityState
    ) throws -> UUID {
        let shape = try decoder.decode(
            LifecycleAuditWorkShape.self,
            from: record.payload
        )
        state.lifecycleEntryReferenceCount = try boundedAggregateCount(
            current: state.lifecycleEntryReferenceCount,
            adding: shape.referenceCount,
            perRecordLimit: maximumLifecycleReferencesPerAudit,
            aggregateLimit: maximumLifecycleEntryReferenceCount
        )
        return try decoder.decode(
            LedgerAccountLifecycleAudit.self,
            from: record.payload
        ).id
    }

    static func decodeExchangeRateIdentity(
        _ record: StoredRecordSnapshot,
        decoder: JSONDecoder,
        state: inout SnapshotIdentityState
    ) throws -> UUID {
        let rate = try decoder.decode(DatedExchangeRate.self, from: record.payload)
        let pair = [
            rate.baseCurrency.value,
            rate.quoteCurrency.value
        ].sorted()
        let pairDay = pair.joined(separator: "\u{1f}")
            + "\u{1f}\(rate.effectiveContext.dayKey)"
        guard state.exchangeRatePairDays.insert(pairDay).inserted else {
            throw AppModelError.invalidBook
        }
        return rate.id
    }

    static func decodeSavingsGoalIdentity(
        _ record: StoredRecordSnapshot,
        decoder: JSONDecoder,
        state: inout SnapshotIdentityState
    ) throws -> UUID {
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
        return try decoder.decode(SavingsGoal.self, from: record.payload).id
    }

    static func validateBudgetTimeline(
        _ record: StoredRecordSnapshot,
        decoder: JSONDecoder
    ) throws {
        guard record.recordID == BudgetConfigurationTimeline.primaryRecordID else {
            throw AppModelError.invalidBook
        }
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
        _ = try decoder.decode(
            BudgetConfigurationTimeline.self,
            from: record.payload
        )
    }

    static func decodeAttributionIdentity(
        _ record: StoredRecordSnapshot,
        decoder: JSONDecoder,
        state: inout SnapshotIdentityState
    ) throws -> UUID {
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
        return try decoder.decode(
            BudgetEntryAttribution.self,
            from: record.payload
        ).id
    }
}

extension RestoreCandidateValidator {
    static func isWithinCandidateRecordLimit(_ count: Int) -> Bool {
        count >= 0 && count <= maximumCandidateRecordCount
    }

    static func boundedAggregateCount(
        current: Int,
        adding: Int,
        perRecordLimit: Int,
        aggregateLimit: Int
    ) throws -> Int {
        let (next, overflow) = current.addingReportingOverflow(adding)
        guard adding >= 0,
              adding <= perRecordLimit,
              !overflow,
              next <= aggregateLimit else {
            throw AppModelError.invalidBook
        }
        return next
    }

    static func boundedByteCount(
        current: Int,
        adding: Int,
        limit: Int
    ) throws -> Int {
        let (next, overflow) = current.addingReportingOverflow(adding)
        guard adding >= 0, !overflow, next <= limit else {
            throw AppModelError.invalidBook
        }
        return next
    }

    /// Count probes use JSONDecoder's keyed/unkeyed containers but never
    /// construct nested domain objects. Foundation's JSON decoder knows the
    /// array count after its linear parse, allowing us to reject work bombs
    /// before `InvestmentHolding.init` or journal SQL indexing begins.
    struct JournalWorkShape: Decodable {
        let postingCount: Int

        enum CodingKeys: String, CodingKey { case postings }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard container.contains(.postings) else {
                postingCount = 0
                return
            }
            let postings = try container.nestedUnkeyedContainer(
                forKey: .postings
            )
            guard let count = postings.count else {
                throw AppModelError.invalidBook
            }
            postingCount = count
        }
    }

    struct BudgetAttributionWorkShape: Decodable {
        let postingCount: Int

        enum CodingKeys: String, CodingKey { case postings }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard container.contains(.postings) else {
                postingCount = 0
                return
            }
            let postings = try container.nestedUnkeyedContainer(
                forKey: .postings
            )
            guard let count = postings.count else {
                throw AppModelError.invalidBook
            }
            postingCount = count
        }
    }

    struct LifecycleAuditWorkShape: Decodable {
        let referenceCount: Int

        enum CodingKeys: String, CodingKey {
            case affectedJournalEntryIDs
            case affectedScheduleIDs
            case affectedHoldingIDs
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            func arrayCount(_ key: CodingKeys) throws -> Int {
                guard container.contains(key) else { return 0 }
                let references = try container.nestedUnkeyedContainer(
                    forKey: key
                )
                guard let count = references.count else {
                    throw AppModelError.invalidBook
                }
                return count
            }

            var total = 0
            for count in try [
                arrayCount(.affectedJournalEntryIDs),
                arrayCount(.affectedScheduleIDs),
                arrayCount(.affectedHoldingIDs)
            ] {
                let (next, overflow) = total.addingReportingOverflow(count)
                guard !overflow else { throw AppModelError.invalidBook }
                total = next
            }
            referenceCount = total
        }
    }

    struct InvestmentHoldingWorkShape: Decodable {
        let counts: [Int]
        let totalCount: Int

        enum CodingKeys: String, CodingKey {
            case priceHistory
            case lots
            case disposals
            case corrections
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            func arrayCount(_ key: CodingKeys) throws -> Int {
                guard container.contains(key) else { return 0 }
                let values = try container.nestedUnkeyedContainer(forKey: key)
                guard let count = values.count else {
                    throw AppModelError.invalidBook
                }
                return count
            }

            counts = try [
                arrayCount(.priceHistory),
                arrayCount(.lots),
                arrayCount(.disposals),
                arrayCount(.corrections)
            ]
            var total = 0
            for count in counts {
                let (next, overflow) = total.addingReportingOverflow(count)
                guard !overflow else { throw AppModelError.invalidBook }
                total = next
            }
            totalCount = total
        }
    }

    struct ScheduledTransactionWorkShape: Decodable {
        let resolutionCount: Int

        enum CodingKeys: String, CodingKey { case resolutions }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard container.contains(.resolutions) else {
                resolutionCount = 0
                return
            }
            let values = try container.nestedUnkeyedContainer(
                forKey: .resolutions
            )
            guard let count = values.count else {
                throw AppModelError.invalidBook
            }
            resolutionCount = count
        }
    }

    struct QuickLogDraftWorkShape: Decodable {
        let splitCount: Int

        enum CodingKeys: String, CodingKey { case splitLines }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard container.contains(.splitLines) else {
                splitCount = 0
                return
            }
            let values = try container.nestedUnkeyedContainer(
                forKey: .splitLines
            )
            guard let count = values.count else {
                throw AppModelError.invalidBook
            }
            splitCount = count
        }
    }

    struct SavingsGoalWorkShape: Decodable {
        let movementCount: Int
        let resetCount: Int
        let totalCount: Int

        enum CodingKeys: String, CodingKey {
            case movements
            case resets
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            func arrayCount(_ key: CodingKeys) throws -> Int {
                guard container.contains(key) else { return 0 }
                let values = try container.nestedUnkeyedContainer(forKey: key)
                guard let count = values.count else {
                    throw AppModelError.invalidBook
                }
                return count
            }

            movementCount = try arrayCount(.movements)
            resetCount = try arrayCount(.resets)
            let (total, overflow) = movementCount.addingReportingOverflow(
                resetCount
            )
            guard !overflow else { throw AppModelError.invalidBook }
            totalCount = total
        }
    }

    struct LoanPlanWorkShape: Decodable {
        let activityCount: Int
        enum CodingKeys: String, CodingKey { case activities }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard container.contains(.activities) else {
                activityCount = 0
                return
            }
            let values = try container.nestedUnkeyedContainer(forKey: .activities)
            guard let count = values.count else { throw AppModelError.invalidBook }
            activityCount = count
        }
    }

    struct AllowancePlanWorkShape: Decodable {
        let usageCount: Int
        let reconciliationCount: Int
        let policyRevisionCount: Int
        let periodWorkCount: Int
        let archiveTransitionCount: Int
        enum CodingKeys: String, CodingKey {
            case usages
            case reconciliations
            case archiveTransitions
            case startsAt
            case cadence
            case timeZoneIdentifier
            case policyRevisions
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if container.contains(.usages) {
                let values = try container.nestedUnkeyedContainer(forKey: .usages)
                guard let count = values.count else {
                    throw AppModelError.invalidBook
                }
                usageCount = count
            } else {
                usageCount = 0
            }
            if container.contains(.reconciliations) {
                let values = try container.nestedUnkeyedContainer(
                    forKey: .reconciliations
                )
                guard let count = values.count else {
                    throw AppModelError.invalidBook
                }
                reconciliationCount = count
            } else {
                reconciliationCount = 0
            }
            if container.contains(.archiveTransitions) {
                let values = try container.nestedUnkeyedContainer(
                    forKey: .archiveTransitions
                )
                guard let count = values.count else {
                    throw AppModelError.invalidBook
                }
                archiveTransitionCount = count
            } else {
                archiveTransitionCount = 0
            }
            if container.contains(.policyRevisions) {
                let values = try container.nestedUnkeyedContainer(
                    forKey: .policyRevisions
                )
                guard let count = values.count else {
                    throw AppModelError.invalidBook
                }
                policyRevisionCount = count
            } else {
                policyRevisionCount = 0
            }
            if usageCount <= AllowancePlan.maximumUsageCount,
               reconciliationCount <= AllowancePlan.maximumReconciliationCount,
               policyRevisionCount <= AllowancePlan.maximumPolicyRevisionCount {
                periodWorkCount = try Self.periodWorkCount(in: container)
            } else {
                periodWorkCount = 0
            }
        }
    }

    struct BudgetTimelineWorkShape: Decodable {
        let revisionCount: Int
        let nodeCounts: [Int]
        let totalNodeCount: Int

        enum CodingKeys: String, CodingKey { case revisions }

        struct RevisionShape: Decodable {
            let nodeCount: Int

            enum CodingKeys: String, CodingKey { case nodes }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                guard container.contains(.nodes) else {
                    nodeCount = 0
                    return
                }
                let nodes = try container.nestedUnkeyedContainer(forKey: .nodes)
                guard let count = nodes.count else {
                    throw AppModelError.invalidBook
                }
                nodeCount = count
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let revisions = try container.decode(
                [RevisionShape].self,
                forKey: .revisions
            )
            revisionCount = revisions.count
            nodeCounts = revisions.map(\.nodeCount)
            var total = 0
            for count in nodeCounts {
                let (next, overflow) = total.addingReportingOverflow(count)
                guard !overflow else { throw AppModelError.invalidBook }
                total = next
            }
            totalNodeCount = total
        }
    }

    static func maximumRecordCount(
        for collection: RecordCollection
    ) -> Int {
        switch collection {
        case .journalEntries:
            maximumJournalEntryCount
        case .journalEntryRevisions:
            maximumJournalRevisionCount
        case .budgetEntryAttributions:
            maximumBudgetAttributionCount
        case .accountLifecycleAudit:
            maximumLifecycleAuditCount
        default:
            maximumCandidateRecordCount
        }
    }

    static func isValidJournalRevisionRecordID(
        _ recordID: String,
        entryID: UUID
    ) -> Bool {
        let expectedPrefix = entryID.uuidString + "-"
        guard recordID.count > expectedPrefix.count,
              recordID.hasPrefix(expectedPrefix) else {
            return false
        }

        let suffix = String(recordID.dropFirst(expectedPrefix.count))
        if let revisionID = UUID(uuidString: suffix),
           revisionID.uuidString == suffix {
            return true
        }
        let lifecyclePrefix = "lifecycle-"
        guard suffix.hasPrefix(lifecyclePrefix) else {
            return false
        }
        let lifecycleID = String(suffix.dropFirst(lifecyclePrefix.count))
        return UUID(uuidString: lifecycleID)?.uuidString == lifecycleID
    }
}
