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

    static func validateSnapshotIdentities(
        _ snapshot: DatabaseSnapshot
    ) throws {
        try validateSnapshotWorkLimits(snapshot)
        let decoder = JSONDecoder()
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

        do {
            for (index, record) in snapshot.records.enumerated() {
                if index.isMultiple(of: 256) { try Task.checkCancellation() }
                let recordIDByteCount = record.recordID.utf8.count
                let (nextRecordIDByteCount, recordIDByteCountOverflow) =
                    aggregateRecordIDByteCount.addingReportingOverflow(
                        recordIDByteCount
                    )
                guard !record.recordID.isEmpty,
                      record.collection.utf8.count <= maximumCollectionByteCount,
                      recordIDByteCount <= maximumRecordIDByteCount,
                      !recordIDByteCountOverflow,
                      nextRecordIDByteCount
                        <= maximumAggregateRecordIDByteCount,
                      !record.payload.isEmpty,
                      record.updatedAt.isFinite else {
                    throw AppModelError.invalidBook
                }
                aggregateRecordIDByteCount = nextRecordIDByteCount
                guard let collection = RecordCollection(
                    rawValue: record.collection
                ) else {
                    throw AppModelError.invalidBook
                }
                let payloadLimit = collection == .receiptAttachments
                    ? maximumReceiptPayloadByteCount
                    : maximumPayloadByteCount
                guard record.payload.count <= payloadLimit else {
                    throw AppModelError.invalidBook
                }
                collectionCounts[collection.rawValue, default: 0] += 1
                guard collectionCounts[collection.rawValue, default: 0]
                    <= maximumRecordCount(for: collection) else {
                    throw AppModelError.invalidBook
                }
                let physicalIdentity = collection.rawValue
                    + "\u{1f}" + record.recordID.lowercased()
                guard physicalRecordIDs.insert(physicalIdentity).inserted else {
                    throw AppModelError.invalidBook
                }

                let logicalID: UUID?
                switch collection {
                case .profile:
                    guard record.recordID == UserProfile.primaryRecordID else {
                        throw AppModelError.invalidBook
                    }
                    _ = try decoder.decode(UserProfile.self, from: record.payload)
                    logicalID = nil
                case .accounts:
                    logicalID = try decoder.decode(
                        LedgerAccount.self,
                        from: record.payload
                    ).id
                case .journalEntries:
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
                    logicalID = try decoder.decode(
                        JournalEntry.self,
                        from: record.payload
                    ).id
                case .journalEntryRevisions:
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
                    let entry = try decoder.decode(
                        JournalEntry.self,
                        from: record.payload
                    )
                    guard isValidJournalRevisionRecordID(
                        record.recordID,
                        entryID: entry.id
                    ) else {
                        throw AppModelError.invalidBook
                    }
                    logicalID = nil
                case .budgetNodes:
                    logicalID = try decoder.decode(
                        BudgetNode.self,
                        from: record.payload
                    ).id
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
                    logicalID = try decoder.decode(
                        ScheduledTransaction.self,
                        from: record.payload
                    ).id
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
                    logicalID = try decoder.decode(
                        InvestmentHolding.self,
                        from: record.payload
                    ).id
                case .netWorthSnapshots:
                    logicalID = try decoder.decode(
                        NetWorthSnapshot.self,
                        from: record.payload
                    ).id
                case .quickLogDrafts:
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
                    logicalID = nil
                case .accountLifecycleAudit:
                    let shape = try decoder.decode(
                        LifecycleAuditWorkShape.self,
                        from: record.payload
                    )
                    lifecycleEntryReferenceCount = try boundedAggregateCount(
                        current: lifecycleEntryReferenceCount,
                        adding: shape.referenceCount,
                        perRecordLimit: maximumLifecycleReferencesPerAudit,
                        aggregateLimit: maximumLifecycleEntryReferenceCount
                    )
                    logicalID = try decoder.decode(
                        LedgerAccountLifecycleAudit.self,
                        from: record.payload
                    ).id
                case .receiptAttachments:
                    logicalID = try decoder.decode(
                        ReceiptAttachment.self,
                        from: record.payload
                    ).id
                case .exchangeRates:
                    let rate = try decoder.decode(
                        DatedExchangeRate.self,
                        from: record.payload
                    )
                    let pair = [
                        rate.baseCurrency.value,
                        rate.quoteCurrency.value
                    ].sorted()
                    let pairDay = pair.joined(separator: "\u{1f}")
                        + "\u{1f}\(rate.effectiveContext.dayKey)"
                    guard exchangeRatePairDays.insert(pairDay).inserted else {
                        throw AppModelError.invalidBook
                    }
                    logicalID = rate.id
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
                    logicalID = try decoder.decode(
                        SavingsGoal.self,
                        from: record.payload
                    ).id
                case .budgetConfigurationTimelines:
                    guard record.recordID
                        == BudgetConfigurationTimeline.primaryRecordID else {
                        throw AppModelError.invalidBook
                    }
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
                    _ = try decoder.decode(
                        BudgetConfigurationTimeline.self,
                        from: record.payload
                    )
                    logicalID = nil
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
                    logicalID = try decoder.decode(
                        BudgetEntryAttribution.self,
                        from: record.payload
                    ).id
                }

                guard let logicalID else { continue }
                // Every normal mutation addresses UUID records by the exact,
                // canonical `UUID.uuidString` key. Accepting a lowercase (or
                // otherwise noncanonical) physical alias here would let a
                // validly encrypted archive install a row that later edits or
                // deletes cannot reach, so it could reappear after reload.
                guard record.recordID == logicalID.uuidString else {
                    throw AppModelError.invalidBook
                }
                let inserted = logicalIDsByCollection[
                    collection.rawValue,
                    default: []
                ].insert(logicalID).inserted
                guard inserted else { throw AppModelError.invalidBook }
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

    static func isWithinCandidateRecordLimit(_ count: Int) -> Bool {
        count >= 0 && count <= maximumCandidateRecordCount
    }

    private static func boundedAggregateCount(
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

    private static func boundedByteCount(
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
    private struct JournalWorkShape: Decodable {
        let postingCount: Int

        private enum CodingKeys: String, CodingKey { case postings }

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

    private struct BudgetAttributionWorkShape: Decodable {
        let postingCount: Int

        private enum CodingKeys: String, CodingKey { case postings }

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

    private struct LifecycleAuditWorkShape: Decodable {
        let referenceCount: Int

        private enum CodingKeys: String, CodingKey {
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

    private struct InvestmentHoldingWorkShape: Decodable {
        let counts: [Int]
        let totalCount: Int

        private enum CodingKeys: String, CodingKey {
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

    private struct ScheduledTransactionWorkShape: Decodable {
        let resolutionCount: Int

        private enum CodingKeys: String, CodingKey { case resolutions }

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

    private struct QuickLogDraftWorkShape: Decodable {
        let splitCount: Int

        private enum CodingKeys: String, CodingKey { case splitLines }

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

    private struct SavingsGoalWorkShape: Decodable {
        let movementCount: Int
        let resetCount: Int
        let totalCount: Int

        private enum CodingKeys: String, CodingKey {
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

    private struct BudgetTimelineWorkShape: Decodable {
        let revisionCount: Int
        let nodeCounts: [Int]
        let totalNodeCount: Int

        private enum CodingKeys: String, CodingKey { case revisions }

        private struct RevisionShape: Decodable {
            let nodeCount: Int

            private enum CodingKeys: String, CodingKey { case nodes }

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

    private static func maximumRecordCount(
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

    private static func isValidJournalRevisionRecordID(
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

    static func validateRelationships(
        profile: UserProfile?,
        accounts: [LedgerAccount],
        budgetNodes: [BudgetNode],
        scheduledTransactions: [ScheduledTransaction],
        investmentHoldings: [InvestmentHolding],
        netWorthSnapshots: [NetWorthSnapshot],
        quickLogDraft: QuickLogDraft?,
        in store: EncryptedRecordStore
    ) async throws {
        guard let profile,
              Set(accounts.map(\.id)).count == accounts.count,
              Set(scheduledTransactions.map(\.id)).count
                == scheduledTransactions.count,
              Set(investmentHoldings.map(\.id)).count
                == investmentHoldings.count,
              Set(netWorthSnapshots.map(\.id)).count
                == netWorthSnapshots.count,
              netWorthSnapshots.allSatisfy({
                  $0.capturedAt.timeIntervalSinceReferenceDate.isFinite
              }) else { throw AppModelError.invalidBook }
        let accountByID = Dictionary(
            uniqueKeysWithValues: accounts.map { ($0.id, $0) }
        )
        let reportingCalendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: profile.reportingTimeZoneIdentifier
        )
        let journalEntries = try await store.fetchAll(
            JournalEntry.self,
            from: .journalEntries
        )
        guard journalEntries.count <= maximumJournalEntryCount,
              Set(journalEntries.map(\.id)).count == journalEntries.count else {
            throw AppModelError.invalidBook
        }
        var journalPostingCount = 0
        for (entryIndex, entry) in journalEntries.enumerated() {
            if entryIndex.isMultiple(of: 256) { try Task.checkCancellation() }
            let (nextPostingCount, overflow) = journalPostingCount
                .addingReportingOverflow(entry.postings.count)
            guard entry.postings.count <= maximumJournalPostingsPerEntry,
                  !overflow,
                  nextPostingCount <= maximumJournalPostingCount else {
                throw AppModelError.invalidBook
            }
            journalPostingCount = nextPostingCount
        }
        let journalByID = Dictionary(
            uniqueKeysWithValues: journalEntries.map { ($0.id, $0) }
        )

        for (index, account) in accounts.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            if account.kind == .asset || account.kind == .liability {
                guard account.currency != nil else {
                    throw AppModelError.invalidBook
                }
            }
            if let parentID = account.parentID {
                guard let parent = accountByID[parentID],
                      parent.kind == account.kind else {
                    throw AppModelError.invalidBook
                }
            }
        }
        // Parent pointers are functional. Tri-color each path once instead of
        // walking every account to the root (quadratic for a crafted chain).
        var accountVisitState: [UUID: UInt8] = [:]
        var accountVisitCount = 0
        for start in accountByID.keys where accountVisitState[start] != 2 {
            var path: [UUID] = []
            var current: UUID? = start
            while let candidate = current {
                if accountVisitCount.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                accountVisitCount += 1
                if accountVisitState[candidate] == 1 {
                    throw AppModelError.invalidBook
                }
                if accountVisitState[candidate] == 2 { break }
                accountVisitState[candidate] = 1
                path.append(candidate)
                current = accountByID[candidate]?.parentID
            }
            for candidate in path { accountVisitState[candidate] = 2 }
        }

        var openingBalancesID: UUID?
        var currencyScopedSystemRoles = Set<String>()
        for account in accounts {
            guard let role = account.systemRole else { continue }
            guard account.parentID == nil,
                  account.accountType == nil else {
                throw AppModelError.invalidBook
            }
            switch role {
            case .openingBalances:
                guard account.kind == .equity,
                      account.currency == nil,
                      !account.isArchived,
                      openingBalancesID == nil else {
                    throw AppModelError.invalidBook
                }
                openingBalancesID = account.id
            case .foreignExchange, .investmentGainLoss:
                guard account.kind == .trading,
                      let currency = account.currency,
                      !account.isArchived else {
                    throw AppModelError.invalidBook
                }
                let identity = role.rawValue + "\u{1f}" + currency.value
                guard currencyScopedSystemRoles.insert(identity).inserted else {
                    throw AppModelError.invalidBook
                }
            case .investmentPosition:
                guard account.kind == .asset,
                      account.currency != nil else {
                    throw AppModelError.invalidBook
                }
            }
        }

        var validatedPostingCount = 0
        for entry in journalEntries {
            for posting in entry.postings {
                if validatedPostingCount.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                validatedPostingCount += 1
                guard let role = accountByID[posting.accountID]?.systemRole else {
                    continue
                }
                let hasValidOwner: Bool
                switch role {
                case .openingBalances:
                    hasValidOwner = entry.kind == .adjustment
                        || entry.kind == .investment
                case .foreignExchange:
                    hasValidOwner = entry.kind == .transfer
                case .investmentPosition, .investmentGainLoss:
                    hasValidOwner = entry.kind == .investment
                }
                guard hasValidOwner else { throw AppModelError.invalidBook }
            }
        }

        for node in budgetNodes {
            guard let account = accountByID[node.id],
                  account.kind == .expense,
                  node.parentID == account.parentID else {
                throw AppModelError.invalidBook
            }
        }

        func requirePreference(
            _ id: UUID?,
            kinds: [LedgerAccountKind]
        ) throws {
            guard let id else { return }
            guard let account = accountByID[id], kinds.contains(account.kind) else {
                throw AppModelError.invalidBook
            }
        }
        try requirePreference(
            profile.preferredAccountID,
            kinds: [.asset, .liability]
        )
        try requirePreference(
            profile.preferredExpenseCategoryID,
            kinds: [.expense]
        )
        try requirePreference(
            profile.preferredIncomeCategoryID,
            kinds: [.income]
        )

        var scheduleEntryOwners: [UUID: UUID] = [:]
        for schedule in scheduledTransactions {
            guard let account = accountByID[schedule.accountID],
                  let category = accountByID[schedule.categoryAccountID],
                  !account.isArchived,
                  !category.isArchived,
                  let currency = account.currency,
                  currency == schedule.amount.currency,
                  account.kind == .asset || account.kind == .liability,
                  account.systemRole == nil,
                  category.systemRole == nil,
                  ((schedule.kind == .expense && category.kind == .expense)
                    || (schedule.kind == .income && category.kind == .income)) else {
                throw AppModelError.invalidBook
            }
            do {
                try schedule.validateLifecycle(calendar: reportingCalendar)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AppModelError.invalidBook
            }
            for linkedID in schedule.resolutions.compactMap(\.linkedEntryID) {
                guard scheduleEntryOwners.updateValue(
                    schedule.id,
                    forKey: linkedID
                ) == nil,
                let linkedEntry = journalByID[linkedID],
                schedule.matches(linkedEntry) else {
                    throw AppModelError.invalidBook
                }
            }
        }

        var holdingEntryOwners: [UUID: UUID] = [:]
        var positionOwners: [UUID: UUID] = [:]
        var linkedInvestmentEntries: [UUID: JournalEntry] = [:]
        var holdingActivityCount = 0
        for (holdingIndex, holding) in investmentHoldings.enumerated() {
            if holdingIndex.isMultiple(of: 64) { try Task.checkCancellation() }
            let counts = [
                holding.priceHistory.count,
                holding.lots.count,
                holding.disposals.count,
                holding.corrections.count
            ]
            guard counts.allSatisfy({
                $0 <= maximumHoldingActivitiesPerCollection
            }) else {
                throw AppModelError.invalidBook
            }
            let holdingTotal = counts.reduce(0, +)
            holdingActivityCount = try boundedAggregateCount(
                current: holdingActivityCount,
                adding: holdingTotal,
                perRecordLimit: maximumHoldingActivitiesPerHolding,
                aggregateLimit: maximumHoldingActivityCount
            )
            for linkedID in holding.linkedEntryIDs {
                guard holdingEntryOwners.updateValue(
                    holding.id,
                    forKey: linkedID
                ) == nil,
                let entry = journalByID[linkedID] else {
                    throw AppModelError.invalidBook
                }
                linkedInvestmentEntries[linkedID] = entry
            }
        }
        let investmentEntryIDs = Set(
            journalEntries.lazy.filter { $0.kind == .investment }.map(\.id)
        )
        guard Set(holdingEntryOwners.keys) == investmentEntryIDs else {
            throw AppModelError.invalidBook
        }
        let ledger = try await store.journalLedgerIndex(
            validAccountIDs: Set(accountByID.keys),
            expectedAccountCurrencies: Dictionary(
                uniqueKeysWithValues: accounts.compactMap { account in
                    account.currency.map { (account.id, $0) }
                }
            )
        )
        guard ledger.issues.isEmpty,
              ledger.invalidRelationshipEntryIDs.isEmpty else {
            throw AppModelError.invalidBook
        }

        for holding in investmentHoldings {
            guard let funding = accountByID[holding.accountID],
                  funding.kind == .asset,
                  funding.systemRole == nil,
                  funding.accountType == .brokerage
                    || funding.accountType == .investment,
                  let currency = funding.currency,
                  holding.isArchived || !funding.isArchived else {
                throw AppModelError.invalidBook
            }
            let holdingCurrencies = Set(
                [holding.price?.currency]
                    + holding.priceHistory.map { Optional($0.price.currency) }
                    + holding.lots.map { Optional($0.unitCost.currency) }
                    + holding.disposals.flatMap {
                        [Optional($0.costBasis.currency), Optional($0.proceeds.currency),
                         Optional($0.realizedGainLoss.currency)]
                    }
            ).compactMap { $0 }
            guard holdingCurrencies.allSatisfy({ $0 == currency }) else {
                throw AppModelError.invalidBook
            }
            guard let positionID = holding.positionAccountID else {
                guard !holding.isArchived,
                      holding.linkedEntryIDs.isEmpty,
                      holding.quantity == .zero || holding.needsLedgerConnection else {
                    throw AppModelError.invalidBook
                }
                continue
            }
            guard positionID != funding.id,
                  positionOwners.updateValue(holding.id, forKey: positionID) == nil,
                  let position = accountByID[positionID],
                  position.kind == .asset,
                  position.systemRole == .investmentPosition,
                  position.currency == currency,
                  position.isArchived == holding.isArchived else {
                throw AppModelError.invalidBook
            }
            do {
                try InvestmentLedgerIntegrity.validate(
                    holding: holding,
                    accountsByID: accountByID,
                    entriesByID: linkedInvestmentEntries
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AppModelError.invalidBook
            }
            guard holding.linkedEntryIDs.allSatisfy({ linkedID in
                guard let entry = linkedInvestmentEntries[linkedID] else {
                    return false
                }
                return entry.kind == .investment
                    && entry.postings.contains { $0.accountID == positionID }
            }) else { throw AppModelError.invalidBook }
            let expected = try holding.marketValue()
                ?? Money.zero(currency: currency)
            let positionBalances = ledger.balances[positionID] ?? [:]
            guard positionBalances.allSatisfy({ pair in
                pair.key == currency || pair.value.isZero
            }),
            (positionBalances[currency] ?? Money.zero(currency: currency))
                == expected else { throw AppModelError.invalidBook }
        }

        for position in accounts where position.systemRole == .investmentPosition {
            guard positionOwners[position.id] != nil else {
                throw AppModelError.invalidBook
            }
        }

        try await validateBudgetAttributions(
            journalEntries: journalEntries,
            journalByID: journalByID,
            accountByID: accountByID,
            in: store
        )

        if let quickLogDraft {
            guard quickLogDraft.occurredAt.timeIntervalSinceReferenceDate.isFinite,
                  Set(quickLogDraft.splitLines.map(\.id)).count
                    == quickLogDraft.splitLines.count else {
                throw AppModelError.invalidBook
            }
            for id in [
                quickLogDraft.accountID,
                quickLogDraft.destinationAccountID,
                quickLogDraft.categoryID
            ].compactMap({ $0 }) where accountByID[id] == nil {
                throw AppModelError.invalidBook
            }
            let expectedSplitKind: LedgerAccountKind?
            switch quickLogDraft.kind {
            case .expense, .refund:
                expectedSplitKind = .expense
            case .income:
                expectedSplitKind = .income
            case .transfer:
                expectedSplitKind = nil
            }
            guard expectedSplitKind != nil || quickLogDraft.splitLines.isEmpty else {
                throw AppModelError.invalidBook
            }
            for split in quickLogDraft.splitLines {
                if let categoryID = split.categoryID,
                   accountByID[categoryID]?.kind != expectedSplitKind {
                    throw AppModelError.invalidBook
                }
            }
        }

    }

    private static func validateBudgetAttributions(
        journalEntries: [JournalEntry],
        journalByID: [UUID: JournalEntry],
        accountByID: [UUID: LedgerAccount],
        in store: EncryptedRecordStore
    ) async throws {
        let attributions = try await store.fetchAll(
            BudgetEntryAttribution.self,
            from: .budgetEntryAttributions
        )
        guard Set(attributions.map(\.id)).count == attributions.count else {
            throw AppModelError.invalidBook
        }
        try await validateBudgetAttributionIntegrity(
            attributions: attributions,
            journalEntries: journalEntries,
            journalByID: journalByID,
            accountByID: accountByID,
            in: store,
            enforcesRestoreWorkLimits: true
        )
    }

    /// Shared by strict restore validation and normal recovering startup. The
    /// caller controls how journal rows are loaded; startup can fetch only the
    /// entries referenced by attributions instead of decoding the full journal.
    static func validateBudgetAttributionIntegrity(
        attributions: [BudgetEntryAttribution],
        journalEntries: [JournalEntry],
        journalByID: [UUID: JournalEntry],
        accountByID: [UUID: LedgerAccount],
        in store: EncryptedRecordStore,
        enforcesRestoreWorkLimits: Bool = false
    ) async throws {
        guard !attributions.isEmpty else { return }
        guard (!enforcesRestoreWorkLimits
                || attributions.count <= maximumBudgetAttributionCount),
              Set(attributions.map(\.id)).count == attributions.count else {
            throw AppModelError.invalidBook
        }

        var remappingsByEntryID: [UUID: [(source: UUID, target: UUID)]] = [:]
        for (index, attribution) in attributions.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard let entry = journalByID[attribution.id],
                  attribution.occurredAt == entry.occurredAt,
                  attribution.postings.count == entry.postings.count else {
                throw AppModelError.invalidBook
            }
            if !entry.originContext.wasInferred {
                let rawDayKey = entry.originContext.dayKey
                let originDayKey = String(
                    format: "%04d-%02d-%02d",
                    rawDayKey / 10_000,
                    rawDayKey / 100 % 100,
                    rawDayKey % 100
                )
                guard attribution.originDayKey == originDayKey,
                      attribution.originTimeZoneIdentifier
                        == entry.originContext.timeZoneIdentifier,
                      attribution.originUTCOffsetSeconds
                        == entry.originContext.utcOffsetSeconds else {
                    throw AppModelError.invalidBook
                }
            }
            let entryPostings = Dictionary(
                uniqueKeysWithValues: entry.postings.map { ($0.id, $0) }
            )
            for attributedPosting in attribution.postings {
                guard let currentPosting = entryPostings[attributedPosting.id],
                      attributedPosting.money == currentPosting.money,
                      attributedPosting.memo == currentPosting.memo else {
                    throw AppModelError.invalidBook
                }
                guard attributedPosting.accountID != currentPosting.accountID else {
                    continue
                }
                remappingsByEntryID[entry.id, default: []].append((
                    attributedPosting.accountID,
                    currentPosting.accountID
                ))
            }
        }
        guard !remappingsByEntryID.isEmpty else { return }

        let revisions = try await store.fetchAll(
            JournalEntry.self,
            from: .journalEntryRevisions
        )
        guard !enforcesRestoreWorkLimits
                || revisions.count <= maximumJournalRevisionCount else {
            throw AppModelError.invalidBook
        }
        let lifecycleAudits = try await store.fetchAll(
            LedgerAccountLifecycleAudit.self,
            from: .accountLifecycleAudit
        )
        guard (!enforcesRestoreWorkLimits
                || lifecycleAudits.count <= maximumLifecycleAuditCount),
              Set(lifecycleAudits.map(\.id)).count == lifecycleAudits.count else {
            throw AppModelError.invalidBook
        }
        var lifecycleMappingsByEntryID: [UUID: [LifecycleAccountMapping]] = [:]
        var lifecycleEntryReferenceCount = 0
        for (index, audit) in lifecycleAudits.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            if enforcesRestoreWorkLimits {
                let (nextReferenceCount, overflow) = lifecycleEntryReferenceCount
                    .addingReportingOverflow(audit.affectedJournalEntryIDs.count)
                guard audit.affectedJournalEntryIDs.count
                        <= maximumLifecycleReferencesPerAudit,
                      !overflow,
                      nextReferenceCount
                        <= maximumLifecycleEntryReferenceCount else {
                    throw AppModelError.invalidBook
                }
                lifecycleEntryReferenceCount = nextReferenceCount
            }
            var affectedEntryIDs = Set<UUID>()
            for (referenceIndex, entryID) in audit.affectedJournalEntryIDs.enumerated() {
                if referenceIndex.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                guard affectedEntryIDs.insert(entryID).inserted else {
                    throw AppModelError.invalidBook
                }
            }
            guard audit.action == .merged
                    || audit.action == .deletedWithReassignment,
                  let targetID = audit.targetID,
                  targetID != audit.before.id,
                  let after = audit.after,
                  after.id == targetID,
                  after.kind == audit.before.kind,
                  after.currency == audit.before.currency,
                  after.systemRole == nil,
                  audit.before.systemRole == nil else {
                continue
            }
            let mapping = LifecycleAccountMapping(
                auditID: audit.id,
                source: audit.before.id,
                target: targetID,
                shape: lifecycleAccountShape(of: audit.before)
            )
            for entryID in affectedEntryIDs {
                lifecycleMappingsByEntryID[entryID, default: []].append(mapping)
            }
        }
        let lineageIndex = try JournalLineageIndex(
            journalEntries: journalEntries,
            revisions: revisions,
            enforcesRestoreWorkLimits: enforcesRestoreWorkLimits
        )

        for (index, pair) in remappingsByEntryID.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            let (entryID, accountRemappings) = pair
            let lineage = try lineageIndex.lineage(for: entryID)
            let lifecycleReachability = try validLifecycleReachability(
                forAny: lineage,
                mappingsByEntryID: lifecycleMappingsByEntryID,
                accountByID: accountByID
            )
            guard accountRemappings.allSatisfy({ mapping in
                lifecycleReachability.reaches(
                    from: mapping.source,
                    to: mapping.target
                )
            }) else {
                throw AppModelError.invalidBook
            }
        }
    }

    private static func validLifecycleReachability(
        forAny entryIDs: Set<UUID>,
        mappingsByEntryID: [UUID: [LifecycleAccountMapping]],
        accountByID: [UUID: LedgerAccount]
    ) throws -> LifecycleReachability {
        typealias Candidate = (source: UUID, target: UUID)
        var candidates: [Candidate] = []
        var shapes: [UUID: String] = [:]
        var conflictingIDs = Set<UUID>()

        func recordShape(_ shape: String, for id: UUID) {
            if let existing = shapes[id], existing != shape {
                conflictingIDs.insert(id)
            } else {
                shapes[id] = shape
            }
        }

        var relevantMappings: [UUID: LifecycleAccountMapping] = [:]
        for (index, entryID) in entryIDs.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            for mapping in mappingsByEntryID[entryID] ?? [] {
                relevantMappings[mapping.auditID] = mapping
            }
        }
        for mapping in relevantMappings.values {
            recordShape(mapping.shape, for: mapping.source)
            recordShape(mapping.shape, for: mapping.target)
            candidates.append((mapping.source, mapping.target))
        }
        for (id, accountShape) in shapes {
            if let current = accountByID[id],
               current.systemRole != nil
                || lifecycleAccountShape(of: current) != accountShape {
                conflictingIDs.insert(id)
            }
        }

        var mappings: [UUID: Set<UUID>] = [:]
        for candidate in candidates
        where !conflictingIDs.contains(candidate.source)
            && !conflictingIDs.contains(candidate.target) {
            mappings[candidate.source, default: []].insert(candidate.target)
        }
        return try LifecycleReachability(mappings: mappings)
    }

    private static func lifecycleAccountShape(of account: LedgerAccount) -> String {
        account.kind.rawValue + "\u{1f}" + (account.currency?.value ?? "")
    }

    private struct LifecycleAccountMapping {
        let auditID: UUID
        let source: UUID
        let target: UUID
        let shape: String
    }

    /// A valid edit history is a set of disjoint linear identity chains.
    /// Production writers retain the predecessor row, never fork an old entry,
    /// and preserve one `supersedesID` for every snapshot of a logical ID.
    /// Enforcing those invariants makes total lineage work linear and rejects
    /// crafted shared-ancestry/DAG amplification before any audit scan.
    private struct JournalLineageIndex {
        private let predecessorByEntryID: [UUID: UUID]
        private let knownEntryIDs: Set<UUID>

        init(
            journalEntries: [JournalEntry],
            revisions: [JournalEntry],
            enforcesRestoreWorkLimits: Bool
        ) throws {
            guard !enforcesRestoreWorkLimits
                    || (journalEntries.count <= maximumJournalEntryCount
                        && revisions.count <= maximumJournalRevisionCount) else {
                throw AppModelError.invalidBook
            }

            let currentEntryIDs = Set(journalEntries.map(\.id))
            guard currentEntryIDs.count == journalEntries.count else {
                throw AppModelError.invalidBook
            }
            var seenEntryIDs = Set<UUID>()
            var predecessorByEntryID: [UUID: UUID] = [:]
            var journalPostingCount = 0
            var iteration = 0

            for entries in [journalEntries, revisions] {
                for entry in entries {
                    if iteration.isMultiple(of: 256) {
                        try Task.checkCancellation()
                    }
                    iteration += 1
                    let (nextPostingCount, overflow) = journalPostingCount
                        .addingReportingOverflow(entry.postings.count)
                    guard entry.postings.count
                            <= maximumJournalPostingsPerEntry,
                          !overflow,
                          !enforcesRestoreWorkLimits
                            || nextPostingCount
                                <= maximumJournalPostingCount else {
                        throw AppModelError.invalidBook
                    }
                    journalPostingCount = nextPostingCount

                    if !seenEntryIDs.insert(entry.id).inserted {
                        guard predecessorByEntryID[entry.id]
                            == entry.supersedesID else {
                            throw AppModelError.invalidBook
                        }
                    } else if let predecessor = entry.supersedesID {
                        guard predecessor != entry.id else {
                            throw AppModelError.invalidBook
                        }
                        predecessorByEntryID[entry.id] = predecessor
                    }
                }
            }

            var successorByEntryID: [UUID: UUID] = [:]
            for (index, edge) in predecessorByEntryID.enumerated() {
                if index.isMultiple(of: 256) { try Task.checkCancellation() }
                let (successor, predecessor) = edge
                guard seenEntryIDs.contains(predecessor),
                      !currentEntryIDs.contains(predecessor) else {
                    throw AppModelError.invalidBook
                }
                if let existing = successorByEntryID[predecessor],
                   existing != successor {
                    throw AppModelError.invalidBook
                }
                successorByEntryID[predecessor] = successor
            }

            var visitState: [UUID: UInt8] = [:]
            iteration = 0
            for start in seenEntryIDs where visitState[start] != 2 {
                var path: [UUID] = []
                var current: UUID? = start
                while let candidate = current {
                    if iteration.isMultiple(of: 256) {
                        try Task.checkCancellation()
                    }
                    iteration += 1
                    if visitState[candidate] == 1 {
                        throw AppModelError.invalidBook
                    }
                    if visitState[candidate] == 2 { break }
                    visitState[candidate] = 1
                    path.append(candidate)
                    current = predecessorByEntryID[candidate]
                }
                for candidate in path { visitState[candidate] = 2 }
            }

            self.predecessorByEntryID = predecessorByEntryID
            knownEntryIDs = seenEntryIDs
        }

        func lineage(for entryID: UUID) throws -> Set<UUID> {
            guard knownEntryIDs.contains(entryID) else {
                throw AppModelError.invalidBook
            }
            var lineage = Set<UUID>()
            var current: UUID? = entryID
            var iteration = 0
            while let candidate = current {
                if iteration.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                iteration += 1
                guard lineage.insert(candidate).inserted else {
                    throw AppModelError.invalidBook
                }
                current = predecessorByEntryID[candidate]
            }
            return lineage
        }
    }

    /// Lifecycle reassignment is likewise functional: one retired source can
    /// have only one successor in a journal lineage. Euler intervals on the
    /// reverse forest make every source-to-current authorization query O(1)
    /// after one linear, cancellation-aware graph build.
    private struct LifecycleReachability {
        private let intervals: [UUID: (start: Int, end: Int)]

        init(mappings: [UUID: Set<UUID>]) throws {
            var parentBySource: [UUID: UUID] = [:]
            var nodes = Set<UUID>()
            for (index, pair) in mappings.enumerated() {
                if index.isMultiple(of: 256) { try Task.checkCancellation() }
                let (source, targets) = pair
                guard targets.count == 1,
                      let target = targets.first,
                      source != target else {
                    throw AppModelError.invalidBook
                }
                parentBySource[source] = target
                nodes.insert(source)
                nodes.insert(target)
            }

            var visitState: [UUID: UInt8] = [:]
            var iteration = 0
            for start in nodes where visitState[start] != 2 {
                var path: [UUID] = []
                var current: UUID? = start
                while let candidate = current {
                    if iteration.isMultiple(of: 256) {
                        try Task.checkCancellation()
                    }
                    iteration += 1
                    if visitState[candidate] == 1 {
                        throw AppModelError.invalidBook
                    }
                    if visitState[candidate] == 2 { break }
                    visitState[candidate] = 1
                    path.append(candidate)
                    current = parentBySource[candidate]
                }
                for candidate in path { visitState[candidate] = 2 }
            }

            var childrenByParent: [UUID: [UUID]] = [:]
            for (source, parent) in parentBySource {
                childrenByParent[parent, default: []].append(source)
            }
            let roots = nodes.filter { parentBySource[$0] == nil }
            var intervals: [UUID: (start: Int, end: Int)] = [:]
            var clock = 0
            for root in roots {
                var stack: [(node: UUID, isExiting: Bool)] = [(root, false)]
                while let item = stack.popLast() {
                    if clock.isMultiple(of: 256) {
                        try Task.checkCancellation()
                    }
                    if item.isExiting {
                        let start = intervals[item.node]?.start ?? clock
                        intervals[item.node] = (start, clock)
                        continue
                    }
                    intervals[item.node] = (clock, clock)
                    clock += 1
                    stack.append((item.node, true))
                    for child in childrenByParent[item.node] ?? [] {
                        stack.append((child, false))
                    }
                }
            }
            guard intervals.count == nodes.count else {
                throw AppModelError.invalidBook
            }
            self.intervals = intervals
        }

        func reaches(from source: UUID, to target: UUID) -> Bool {
            guard source != target,
                  let sourceInterval = intervals[source],
                  let targetInterval = intervals[target] else {
                return false
            }
            return targetInterval.start <= sourceInterval.start
                && sourceInterval.end <= targetInterval.end
        }
    }
}
