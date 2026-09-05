import Foundation
import MoneyUpCore

enum CategoryParentChange {
    case unchanged
    case set(UUID?)
}

extension AppModel {
    func categoryMetadataAccount(
        id: UUID,
        name: String,
        parentChange: CategoryParentChange
    ) throws -> (Int, LedgerAccount, LedgerAccount) {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { throw AppModelError.emptyName }
        guard let index = accounts.firstIndex(where: { $0.id == id }) else {
            throw AppModelError.missingRecord
        }
        let original = accounts[index]
        try requireLifecycleEligible(original)
        guard original.kind == .expense || original.kind == .income else {
            throw AppModelError.invalidCategoryKind
        }
        var updated = original
        updated.name = normalizedName
        if case let .set(parentID) = parentChange {
            if let parentID {
                guard compatibleCategoryParents(for: id).contains(where: { $0.id == parentID }) else {
                    throw AppModelError.invalidCategoryParent
                }
            }
            updated.parentID = parentID
        }
        return (index, original, updated)
    }
}

extension AppModel {
    struct LedgerItemLifecycleImpact: Equatable {
        let transactionCount: Int
        /// False means `transactionCount` is only a last-known value. In that
        /// state destructive "unused" actions must fail closed until the
        /// compact journal projection has been rebuilt.
        let transactionReferencesAreCurrent: Bool
        let scheduleCount: Int
        let holdingCount: Int
        let childCount: Int
        let defaultReferenceCount: Int
        let planningReferenceCount: Int
        let draftReferenceCount: Int
        let hasConfiguredBudget: Bool

        var isUnused: Bool {
            canDeleteWithoutReassignment && !hasConfiguredBudget && defaultReferenceCount == 0
        }

        /// A standalone budget is removable with the category after an explicit
        /// confirmation. It is not a historical transaction/reference.
        var canDeleteWithoutReassignment: Bool {
            transactionReferencesAreCurrent
                && transactionCount == 0
                && scheduleCount == 0
                && holdingCount == 0
                && childCount == 0
                && planningReferenceCount == 0
                && draftReferenceCount == 0
        }

        var totalReferenceCount: Int {
            transactionCount
                + scheduleCount
                + holdingCount
                + childCount
                + defaultReferenceCount
                + draftReferenceCount
                + (hasConfiguredBudget ? 1 : 0)
        }
    }

}
