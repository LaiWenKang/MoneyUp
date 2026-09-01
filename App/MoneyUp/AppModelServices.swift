import Foundation
import MoneyUpCore
import MoneyUpIntelligence
import MoneyUpPersistence
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
    var findings: [IntelligenceFinding] { get }
    var isRefreshing: Bool { get }
    var isUnavailable: Bool { get }
    var resultsAreLimited: Bool { get }

    func refresh(
        store: EncryptedRecordStore,
        originDayKeyRange: ClosedRange<Int>,
        asOfDay: Int,
        enabled: Bool
    )
    func waitForCurrentRefresh() async
    func cancelPendingWork()
}

@MainActor
@Observable
final class IntelligenceService: IntelligenceServicing {
    private(set) var findings: [IntelligenceFinding] = []
    private(set) var isRefreshing = false
    private(set) var isUnavailable = false
    private(set) var resultsAreLimited = false
    @ObservationIgnored private(set) var refreshInvocationCount = 0
    @ObservationIgnored private(set) var cancelInvocationCount = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var revision: UInt64 = 0

    func refresh(
        store: EncryptedRecordStore,
        originDayKeyRange: ClosedRange<Int>,
        asOfDay: Int,
        enabled: Bool
    ) {
        refreshInvocationCount += 1
        beginRefresh()
        guard enabled else { return }
        isRefreshing = true
        let refreshRevision = revision
        refreshTask = Task { [weak self] in
            do {
                let observations = try await store.intelligenceObservations(
                    originDayKeyRange: originDayKeyRange
                )
                try Task.checkCancellation()
                let detected = try await Task.detached(priority: .utility) {
                    try Self.detectedFindings(
                        observations: observations,
                        asOfDay: asOfDay
                    )
                }.value
                guard let self,
                      !Task.isCancelled,
                      refreshRevision == revision else { return }
                findings = detected
                resultsAreLimited = observations.count
                    == EncryptedRecordStore.maximumIntelligenceObservationCount
                isRefreshing = false
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      !Task.isCancelled,
                      refreshRevision == revision else { return }
                findings = []
                resultsAreLimited = false
                isUnavailable = true
                isRefreshing = false
            }
        }
    }

    func cancelPendingWork() {
        cancelInvocationCount += 1
        revision &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        findings = []
        isRefreshing = false
        isUnavailable = false
        resultsAreLimited = false
    }

    func waitForCurrentRefresh() async {
        guard let refreshTask else { return }
        await refreshTask.value
    }

    private func beginRefresh() {
        revision &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        findings = []
        isRefreshing = false
        isUnavailable = false
        resultsAreLimited = false
    }

    nonisolated private static func detectedFindings(
        observations: [IntelligenceObservation],
        asOfDay: Int
    ) throws -> [IntelligenceFinding] {
        let performanceInterval = MoneyUpPerformanceSignposts.begin(
            .deterministicIntelligence
        )
        defer { MoneyUpPerformanceSignposts.end(performanceInterval) }
        let groups = try [
            RecurrenceDetector.findings(in: observations, asOfDay: asOfDay),
            DuplicateDetector.findings(in: observations),
            CategoryAnomalyDetector.findings(in: observations, asOfDay: asOfDay)
        ]
        return groups.flatMap { $0 }.sorted(by: findingOrder)
    }

    nonisolated private static func findingOrder(
        _ lhs: IntelligenceFinding,
        _ rhs: IntelligenceFinding
    ) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        return lhs.id < rhs.id
    }
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
    let intelligence: IntelligenceService

    init(
        ledger: LedgerService = LedgerService(),
        planning: PlanningService = PlanningService(),
        assets: AssetsService = AssetsService(),
        portability: PortabilityService = PortabilityService(),
        capture: CaptureService = CaptureService(),
        intelligence: IntelligenceService = IntelligenceService()
    ) {
        self.ledger = ledger
        self.planning = planning
        self.assets = assets
        self.portability = portability
        self.capture = capture
        self.intelligence = intelligence
    }
}
