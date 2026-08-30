import Foundation
import MoneyUpCore
import MoneyUpPersistence

extension RestoreCandidateValidator {
    static func validateBudgetAttributions(
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

    static func validLifecycleReachability(
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

    static func lifecycleAccountShape(of account: LedgerAccount) -> String {
        account.kind.rawValue + "\u{1f}" + (account.currency?.value ?? "")
    }

    struct LifecycleAccountMapping {
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
    struct JournalLineageIndex {
        let predecessorByEntryID: [UUID: UUID]
        let knownEntryIDs: Set<UUID>

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
    struct LifecycleReachability {
        let intervals: [UUID: (start: Int, end: Int)]

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
