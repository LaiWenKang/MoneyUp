public enum RecordCollection: String, CaseIterable, Sendable {
    case profile
    case accounts
    case journalEntries = "journal_entries"
    case budgetNodes = "budget_nodes"
    case scheduledTransactions = "scheduled_transactions"
    case investmentHoldings = "investment_holdings"
}
