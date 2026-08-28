import Foundation

/// Durable reason for a lifecycle change to an account or category.
///
/// The journal revision collection preserves the exact pre-change entries.
/// This companion record preserves the human-facing account/category names and
/// the scope of the operation so a merge or reassignment remains explainable
/// after the source record is removed.
public enum LedgerAccountLifecycleAction: String, Codable, Sendable {
    case renamed
    case categoryMetadataUpdated = "category_metadata_updated"
    case archived
    case restored
    case merged
    case deleted
    case deletedWithReassignment = "deleted_with_reassignment"
}

public enum LedgerAccountLifecycleAuditValidationError: Error, Equatable, Sendable {
    case tooManyAffectedRecords
}

public struct LedgerAccountLifecycleAudit: Codable, Equatable, Identifiable, Sendable {
    /// One lifecycle operation may touch several record families. Keeping the
    /// combined reference list bounded prevents a validly encoded audit row
    /// from becoming an allocation/validation work bomb on a later restore.
    public static let maximumAffectedRecordCount = 16_384

    public let id: UUID
    public let occurredAt: Date
    public let action: LedgerAccountLifecycleAction
    public let before: LedgerAccount
    public let after: LedgerAccount?
    public let targetID: UUID?
    public let beforeBudget: BudgetNode?
    public let afterBudget: BudgetNode?
    public let affectedJournalEntryIDs: [UUID]
    public let affectedScheduleIDs: [UUID]
    public let affectedHoldingIDs: [UUID]

    public init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        action: LedgerAccountLifecycleAction,
        before: LedgerAccount,
        after: LedgerAccount?,
        targetID: UUID? = nil,
        beforeBudget: BudgetNode? = nil,
        afterBudget: BudgetNode? = nil,
        affectedJournalEntryIDs: [UUID] = [],
        affectedScheduleIDs: [UUID] = [],
        affectedHoldingIDs: [UUID] = []
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.action = action
        self.before = before
        self.after = after
        self.targetID = targetID
        self.beforeBudget = beforeBudget
        self.afterBudget = afterBudget
        self.affectedJournalEntryIDs = affectedJournalEntryIDs.sorted {
            $0.uuidString < $1.uuidString
        }
        self.affectedScheduleIDs = affectedScheduleIDs.sorted {
            $0.uuidString < $1.uuidString
        }
        self.affectedHoldingIDs = affectedHoldingIDs.sorted {
            $0.uuidString < $1.uuidString
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case occurredAt
        case action
        case before
        case after
        case targetID
        case beforeBudget
        case afterBudget
        case affectedJournalEntryIDs
        case affectedScheduleIDs
        case affectedHoldingIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let journalIDs = try container.decodeIfPresent(
            [UUID].self,
            forKey: .affectedJournalEntryIDs
        ) ?? []
        let scheduleIDs = try container.decodeIfPresent(
            [UUID].self,
            forKey: .affectedScheduleIDs
        ) ?? []
        let holdingIDs = try container.decodeIfPresent(
            [UUID].self,
            forKey: .affectedHoldingIDs
        ) ?? []
        try Self.validateReferenceCounts(
            journalIDs.count,
            scheduleIDs.count,
            holdingIDs.count
        )

        id = try container.decode(UUID.self, forKey: .id)
        occurredAt = try container.decode(Date.self, forKey: .occurredAt)
        action = try container.decode(
            LedgerAccountLifecycleAction.self,
            forKey: .action
        )
        before = try container.decode(LedgerAccount.self, forKey: .before)
        after = try container.decodeIfPresent(LedgerAccount.self, forKey: .after)
        targetID = try container.decodeIfPresent(UUID.self, forKey: .targetID)
        beforeBudget = try container.decodeIfPresent(
            BudgetNode.self,
            forKey: .beforeBudget
        )
        afterBudget = try container.decodeIfPresent(
            BudgetNode.self,
            forKey: .afterBudget
        )
        affectedJournalEntryIDs = journalIDs.sorted {
            $0.uuidString < $1.uuidString
        }
        affectedScheduleIDs = scheduleIDs.sorted {
            $0.uuidString < $1.uuidString
        }
        affectedHoldingIDs = holdingIDs.sorted {
            $0.uuidString < $1.uuidString
        }
    }

    public func encode(to encoder: Encoder) throws {
        try Self.validateReferenceCounts(
            affectedJournalEntryIDs.count,
            affectedScheduleIDs.count,
            affectedHoldingIDs.count
        )
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(occurredAt, forKey: .occurredAt)
        try container.encode(action, forKey: .action)
        try container.encode(before, forKey: .before)
        try container.encodeIfPresent(after, forKey: .after)
        try container.encodeIfPresent(targetID, forKey: .targetID)
        try container.encodeIfPresent(beforeBudget, forKey: .beforeBudget)
        try container.encodeIfPresent(afterBudget, forKey: .afterBudget)
        try container.encode(
            affectedJournalEntryIDs,
            forKey: .affectedJournalEntryIDs
        )
        try container.encode(affectedScheduleIDs, forKey: .affectedScheduleIDs)
        try container.encode(affectedHoldingIDs, forKey: .affectedHoldingIDs)
    }

    private static func validateReferenceCounts(_ counts: Int...) throws {
        var total = 0
        for count in counts {
            let (next, overflow) = total.addingReportingOverflow(count)
            guard count >= 0,
                  !overflow,
                  next <= maximumAffectedRecordCount else {
                throw LedgerAccountLifecycleAuditValidationError
                    .tooManyAffectedRecords
            }
            total = next
        }
    }
}
