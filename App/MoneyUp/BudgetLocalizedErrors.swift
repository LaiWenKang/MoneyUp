import Foundation
import MoneyUpCore

extension BudgetMergeError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingCategory: AppLocalization.string("error.missing_record")
        case .overallocatedEnvelope: AppLocalization.string("budget.merge_overallocated")
        case .rolloverRequiresReview: AppLocalization.string("budget.merge_rollover_review")
        }
    }
}

extension MonthlyBudgetError: @retroactive LocalizedError {
    public var errorDescription: String? { AppLocalization.string("budget.invalid_allocation") }
}
