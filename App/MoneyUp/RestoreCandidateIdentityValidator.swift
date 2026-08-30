import Foundation
import MoneyUpCore
import MoneyUpPersistence

extension RestoreCandidateValidator {
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
