extension BudgetWidgetSnapshot {
    /// Expired or unshared data cannot support a trustworthy summary. Keep
    /// the widget useful with data-free capture instead of a dead-end message.
    var usesQuickActionFallback: Bool {
        switch self {
        case .disabled, .stale: true
        case .needsBudget, .zeroBudget, .negativeBudget, .available: false
        }
    }
}
