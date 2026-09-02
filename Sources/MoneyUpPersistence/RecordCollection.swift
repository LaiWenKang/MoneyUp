public enum RecordCollection: String, CaseIterable, Sendable {
    case profile
    case accounts
    case journalEntries = "journal_entries"
    case journalEntryRevisions = "journal_entry_revisions"
    case budgetNodes = "budget_nodes"
    case scheduledTransactions = "scheduled_transactions"
    case investmentHoldings = "investment_holdings"
    case netWorthSnapshots = "net_worth_snapshots"
    case quickLogDrafts = "quick_log_drafts"
    case accountLifecycleAudit = "account_lifecycle_audit"
    case receiptAttachments = "receipt_attachments"
    case exchangeRates = "exchange_rates"
    case savingsGoals = "savings_goals"
    case loanPlans = "loan_plans"
    case allowancePlans = "allowance_plans"
    case budgetConfigurationTimelines = "budget_configuration_timelines"
    case budgetEntryAttributions = "budget_entry_attributions"
}
