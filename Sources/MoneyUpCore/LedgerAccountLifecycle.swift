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

public struct LedgerAccountLifecycleAudit: Codable, Equatable, Identifiable, Sendable {
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
}
