import Foundation
import MoneyUpCore
import Observation

@MainActor
protocol LedgerServicing: AnyObject {
    var accounts: [LedgerAccount] { get }
    var accountsByID: [UUID: LedgerAccount] { get }
    var entries: [JournalEntry] { get }
    var journalEntryCount: Int { get }
    var journalRecentEntriesAreCurrent: Bool { get }
}

@MainActor
@Observable
final class LedgerService: LedgerServicing {
    var accounts: [LedgerAccount]
    var accountsByID: [UUID: LedgerAccount]
    var entries: [JournalEntry]
    var journalEntryCount: Int
    var journalRecentEntriesAreCurrent: Bool

    init(
        accounts: [LedgerAccount] = [],
        accountsByID: [UUID: LedgerAccount] = [:],
        entries: [JournalEntry] = [],
        journalEntryCount: Int = 0,
        journalRecentEntriesAreCurrent: Bool = false
    ) {
        self.accounts = accounts
        self.accountsByID = accountsByID
        self.entries = entries
        self.journalEntryCount = journalEntryCount
        self.journalRecentEntriesAreCurrent = journalRecentEntriesAreCurrent
    }
}

@MainActor
protocol PlanningServicing: AnyObject {
    var budgetNodes: [BudgetNode] { get }
    var scheduledTransactions: [ScheduledTransaction] { get }
    var savingsGoals: [SavingsGoal] { get }
}

@MainActor
@Observable
final class PlanningService: PlanningServicing {
    var budgetNodes: [BudgetNode]
    var scheduledTransactions: [ScheduledTransaction]
    var savingsGoals: [SavingsGoal]

    init(
        budgetNodes: [BudgetNode] = [],
        scheduledTransactions: [ScheduledTransaction] = [],
        savingsGoals: [SavingsGoal] = []
    ) {
        self.budgetNodes = budgetNodes
        self.scheduledTransactions = scheduledTransactions
        self.savingsGoals = savingsGoals
    }
}

@MainActor
protocol AssetsServicing: AnyObject {
    var investmentHoldings: [InvestmentHolding] { get }
    var exchangeRates: [DatedExchangeRate] { get }
    var netWorthSnapshots: [NetWorthSnapshot] { get }
}

@MainActor
@Observable
final class AssetsService: AssetsServicing {
    var investmentHoldings: [InvestmentHolding]
    var exchangeRates: [DatedExchangeRate]
    var netWorthSnapshots: [NetWorthSnapshot]

    init(
        investmentHoldings: [InvestmentHolding] = [],
        exchangeRates: [DatedExchangeRate] = [],
        netWorthSnapshots: [NetWorthSnapshot] = []
    ) {
        self.investmentHoldings = investmentHoldings
        self.exchangeRates = exchangeRates
        self.netWorthSnapshots = netWorthSnapshots
    }
}

@MainActor
protocol PortabilityServicing: AnyObject {
    var recoveryIssues: [String] { get }
}

@MainActor
@Observable
final class PortabilityService: PortabilityServicing {
    var recoveryIssues: [String]

    init(recoveryIssues: [String] = []) {
        self.recoveryIssues = recoveryIssues
    }
}

@MainActor
protocol CaptureServicing: AnyObject {
    var receiptAttachmentMetadata: [ReceiptAttachmentMetadata] { get }
    var requestedQuickLogMode: QuickLogLaunchMode? { get }
    var quickLogDraft: QuickLogDraft? { get }
    var pendingLockedCaptureCount: Int { get }
}

@MainActor
@Observable
final class CaptureService: CaptureServicing {
    var receiptAttachmentMetadata: [ReceiptAttachmentMetadata]
    var requestedQuickLogMode: QuickLogLaunchMode?
    var quickLogDraft: QuickLogDraft?
    var pendingLockedCaptureCount: Int

    init(
        receiptAttachmentMetadata: [ReceiptAttachmentMetadata] = [],
        requestedQuickLogMode: QuickLogLaunchMode? = nil,
        quickLogDraft: QuickLogDraft? = nil,
        pendingLockedCaptureCount: Int = 0
    ) {
        self.receiptAttachmentMetadata = receiptAttachmentMetadata
        self.requestedQuickLogMode = requestedQuickLogMode
        self.quickLogDraft = quickLogDraft
        self.pendingLockedCaptureCount = pendingLockedCaptureCount
    }
}

@MainActor
protocol IntelligenceServicing: AnyObject {
    func cancelPendingWork()
}

@MainActor
final class IntelligenceService: IntelligenceServicing {
    func cancelPendingWork() {}
}

/// Concrete services are injected as one dependency so previews and tests can
/// seed each domain independently without adding another persistence owner.
@MainActor
struct AppModelServices {
    let ledger: LedgerService
    let planning: PlanningService
    let assets: AssetsService
    let portability: PortabilityService
    let capture: CaptureService
    let intelligence: any IntelligenceServicing

    init(
        ledger: LedgerService = LedgerService(),
        planning: PlanningService = PlanningService(),
        assets: AssetsService = AssetsService(),
        portability: PortabilityService = PortabilityService(),
        capture: CaptureService = CaptureService(),
        intelligence: any IntelligenceServicing = IntelligenceService()
    ) {
        self.ledger = ledger
        self.planning = planning
        self.assets = assets
        self.portability = portability
        self.capture = capture
        self.intelligence = intelligence
    }
}
