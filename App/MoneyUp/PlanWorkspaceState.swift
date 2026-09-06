import MoneyUpCore
import Observation
import Foundation

/// Owned by Plan, so visiting a peer section preserves the user's period and
/// display choices. This contains no ledger data and is discarded at lock.
@Observable
final class PlanWorkspaceState {
    var budgetDate: Date?
    var budgetCurrencyCode: String?
    var pacingCadence: BudgetPacingCadence = .daily
    var calendarDate = Date()
}
