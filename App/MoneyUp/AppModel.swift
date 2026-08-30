import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

struct PreparedJournalReports: Sendable {
    let reports: [ReportPeriod: PeriodReport]
    let previousMonthToDateExpense: Money?
    let currentMonthToDateExpense: Money?
    let monthToDateHasUnconvertedActivity: Bool
}

/// Complete closed-month budget actuals prepared from the normalized journal
/// index. The tags prevent a month rollover or reporting-zone change from
/// silently reusing civil-month totals produced under different boundaries.
struct ClosedMonthBudgetProjection: Sendable {
    let reportingTimeZoneIdentifier: String
    let currentMonthStart: Date
    let coverageStart: Date
    let currency: CurrencyCode
    let monthlySpending: [MonthlyBudgetSpending]
}

@MainActor
@Observable
final class AppModel {
    static let lockedQuickCapturePreferenceKey = "moneyup.allowLockedQuickCapture"
    enum State: Equatable {
        case launching
        case locked
        case onboarding
        case ready
        case failed(String)
    }

    struct MonthToDateExpenseComparison: Sendable {
        let previous: Money
        let current: Money
        let holdsUnconvertedActivity: Bool
    }

    struct EstimatedNetWorth: Equatable, Sendable {
        let total: Money
        let conversionAsOf: Date
        let conversionAsOfDayKey: Int
        let evidence: [NetWorthConversionEvidence]
    }

    struct TransactionImportResult: Equatable {
        let imported: Int
        let duplicates: Int
        let skipped: Int
        let categoriesCreated: Int
    }

    struct HistoryPageResult: Sendable {
        let entries: [JournalEntry]
        let nextCursor: JournalEntryPageCursor?
    }

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
        let draftReferenceCount: Int
        let hasConfiguredBudget: Bool

        var isUnused: Bool {
            transactionReferencesAreCurrent
                && transactionCount == 0
                && scheduleCount == 0
                && holdingCount == 0
                && childCount == 0
                && defaultReferenceCount == 0
                && draftReferenceCount == 0
                && !hasConfiguredBudget
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

    enum InvestmentOpeningTreatment: String, CaseIterable, Identifiable {
        case deductFromCash
        case cashAlreadyExcludesPosition

        var id: String { rawValue }
    }

    struct BudgetPurposeOverview: Equatable {
        let effectivePurposeByID: [UUID: BudgetPurpose]
        let reviewCount: Int
    }

    struct PendingQuickLogCommit {
        let id: UUID
        let generation: Int
        let task: Task<Void, Error>
    }

    struct EditableMoneySnapshot {
        let source: Money
        let destination: Money?
    }

    enum BookLoadMode {
        /// Normal unlock/recovery keeps readable records available and reports
        /// damaged rows for the recovery UI.
        case recovering
        /// Restore validation is intentionally all-or-nothing. No convenience
        /// record is repaired or discarded while evaluating an archive.
        case restoreValidation
        /// Rebuilds UI state after the original snapshot is put back without
        /// allowing recovery conveniences to rewrite any restored byte.
        case rollbackRecovery

        var updatesPreferences: Bool {
            switch self {
            case .recovering: return true
            case .restoreValidation, .rollbackRecovery: return false
            }
        }

        var rejectsRecoveryIssues: Bool {
            switch self {
            case .restoreValidation: return true
            case .recovering, .rollbackRecovery: return false
            }
        }

        var removesMalformedDraft: Bool {
            switch self {
            case .recovering: return true
            case .restoreValidation, .rollbackRecovery: return false
            }
        }

        var observesCancellationWhileLoading: Bool {
            switch self {
            case .recovering, .restoreValidation: return true
            case .rollbackRecovery: return false
            }
        }

        var persistsBudgetTimelineMigration: Bool {
            switch self {
            case .recovering, .restoreValidation: return true
            case .rollbackRecovery: return false
            }
        }

        var loadsCompleteBudgetAttributions: Bool {
            switch self {
            case .restoreValidation: return true
            case .recovering, .rollbackRecovery: return false
            }
        }
    }

    struct BudgetTreeCacheEntry {
        let currency: CurrencyCode
        let revision: UInt64
        let result: Result<BudgetTree, Error>
    }

    let services: AppModelServices

    var state: State = .launching
    /// Keeps decoded financial UI opaque while an auto-lock request waits for
    /// an atomic mutation to reach its durable boundary. Once the mutation
    /// drains, `lock()` clears decoded state before removing this cover.
    var requiresAuthenticationPrivacyCover = false
    var profile: UserProfile? {
        didSet {
            journalProjectionRevision &+= 1
            if oldValue?.baseCurrency != profile?.baseCurrency
                || oldValue?.reportingTimeZoneIdentifier
                    != profile?.reportingTimeZoneIdentifier {
                closedMonthBudgetProjection = nil
            }
            invalidateDerivedData()
            budgetTreeCache = nil
            refreshBudgetWidgetSnapshot()
        }
    }
    var accounts: [LedgerAccount] {
        get { services.ledger.accounts }
        set {
            let oldShape = services.ledger.accounts.map(Self.ledgerShape).sorted()
            services.ledger.accounts = newValue
            journalProjectionRevision &+= 1
            let newShape = newValue.map(Self.ledgerShape).sorted()
            if oldShape != newShape { closedMonthBudgetProjection = nil }
            services.ledger.accountsByID = Dictionary(
                newValue.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            invalidateDerivedData()
        }
    }
    /// Maintained once per account mutation so transaction rows and other hot
    /// view paths never rebuild an O(accounts) lookup table per rendered row.
    var accountsByID: [UUID: LedgerAccount] {
        get { services.ledger.accountsByID }
        set { services.ledger.accountsByID = newValue }
    }
    /// A deliberately bounded recent-activity cache. Production startup never
    /// fills this with the complete journal; History and Calendar query the
    /// encrypted chronological index directly.
    var entries: [JournalEntry] {
        get { services.ledger.entries }
        set {
            services.ledger.entries = newValue
            if retainsCompleteJournal { invalidateDerivedData() }
            refreshBudgetWidgetSnapshot()
        }
    }
    var journalEntryCount: Int {
        get { services.ledger.journalEntryCount }
        set { services.ledger.journalEntryCount = newValue }
    }
    /// Qualifies both the bounded `entries` cache and `journalEntryCount`.
    /// False means callers must present an unavailable/loading state rather
    /// than interpreting an empty cache as an empty durable journal.
    var journalRecentEntriesAreCurrent: Bool {
        get { services.ledger.journalRecentEntriesAreCurrent }
        set { services.ledger.journalRecentEntriesAreCurrent = newValue }
    }
    var budgetNodes: [BudgetNode] {
        get { services.planning.budgetNodes }
        set {
            services.planning.budgetNodes = newValue
            budgetNodesRevision &+= 1
            budgetTreeCache = nil
            refreshBudgetWidgetSnapshot()
        }
    }
    var scheduledTransactions: [ScheduledTransaction] {
        get { services.planning.scheduledTransactions }
        set { services.planning.scheduledTransactions = newValue }
    }
    var investmentHoldings: [InvestmentHolding] {
        get { services.assets.investmentHoldings }
        set { services.assets.investmentHoldings = newValue }
    }
    var savingsGoals: [SavingsGoal] {
        get { services.planning.savingsGoals }
        set { services.planning.savingsGoals = newValue }
    }
    /// Blob-free attachment inventory. Image bytes are never retained by the
    /// application model and are fetched only for a selected History row.
    var receiptAttachmentMetadata: [ReceiptAttachmentMetadata] {
        get { services.capture.receiptAttachmentMetadata }
        set { services.capture.receiptAttachmentMetadata = newValue }
    }
    var exchangeRates: [DatedExchangeRate] {
        get { services.assets.exchangeRates }
        set { services.assets.exchangeRates = newValue }
    }
    var netWorthSnapshots: [NetWorthSnapshot] {
        get { services.assets.netWorthSnapshots }
        set { services.assets.netWorthSnapshots = newValue }
    }
    var isWorking = false
    var requestedQuickLogMode: QuickLogLaunchMode? {
        get { services.capture.requestedQuickLogMode }
        set { services.capture.requestedQuickLogMode = newValue }
    }
    var quickLogDraft: QuickLogDraft? {
        get { services.capture.quickLogDraft }
        set { services.capture.quickLogDraft = newValue }
    }
    var recoveryIssues: [String] {
        get { services.portability.recoveryIssues }
        set { services.portability.recoveryIssues = newValue }
    }
    var pendingLockedCaptureCount: Int {
        get { services.capture.pendingLockedCaptureCount }
        set { services.capture.pendingLockedCaptureCount = newValue }
    }

    var ledgerService: any LedgerServicing { services.ledger }
    var planningService: any PlanningServicing { services.planning }
    var assetsService: any AssetsServicing { services.assets }
    var portabilityService: any PortabilityServicing { services.portability }
    var captureService: any CaptureServicing { services.capture }
    var intelligenceService: any IntelligenceServicing { services.intelligence }

    static func ledgerShape(_ account: LedgerAccount) -> String {
        "\(account.id.uuidString)|\(account.currency?.value ?? "-")"
    }

    var store: EncryptedRecordStore?
    let lockedCaptureStore: any LockedCaptureStoring
    let receiptRecognizer: ReceiptLineRecognizer
    let lifecycleHooks: AppModelLifecycleHooks
    let databaseURLForErase: URL?
    let deleteDatabaseKey: @Sendable () throws -> Void
    let dataEraseIntent: DataEraseIntentAccess
    let openDatabaseStore: DatabaseStoreOpener
    let restartAfterErase: Bool
    let budgetWidgetSnapshotStore: BudgetWidgetSnapshotStore
    let currentDate: @Sendable () -> Date
    let savingsGoalMutationSerializer = SavingsGoalMutationSerializer()
    let profileMutationSerializer = ProfileMutationSerializer()
    var quickLogDraftWriteTask: Task<Void, Never>?
    var quickLogCommit: PendingQuickLogCommit?
    var standaloneJournalMutationsInProgress = 0
    var scheduleMutationsInProgress = Set<UUID>()
    var scheduleEntryMatchesInProgress = Set<UUID>()
    var investmentMutationsInProgress = Set<UUID>()
    var lockedCapturePromotionInProgress = false
    /// Closes the erase/capture time-of-check-to-time-of-use gap while the
    /// redacted inbox actor is writing. An erase that starts after the marker
    /// check must wait for (or, through the public guard, decline during) this
    /// write rather than deleting a capture the UI has just reported as saved.
    var lockedCaptureWriteInProgress = false
    var storeCloseTask: Task<Void, Never>?
    var autoLockTask: Task<Void, Never>?
    /// First instant the scene stopped being active. iOS normally sends
    /// `.inactive` before `.background`; retaining the first instant prevents
    /// the second transition from silently extending the lock deadline.
    var leftActiveAt: Date?
    var storeGeneration = 0
    var lockAfterStart = false
    var isLifecycleMutationInProgress = false
    var manualJournalMutationIsActive = false
    var lockAfterLifecycleMutation = false
    var goalMutationsInProgress = 0
    var goalMutationBarrierClosed = false
    var goalMutationDrainWaiters: [CheckedContinuation<Void, Never>] = []
    var isStarting = false
    var reportCache: [ReportPeriod: DerivedValue<PeriodReport>] = [:]
    var reportCacheDay: Date?
    var monthToDateComparisonCache: DerivedValue<MonthToDateExpenseComparison>?
    var monthToDateComparisonCacheDay: Date?
    var balanceCache: DerivedValue<[UUID: [CurrencyCode: Money]]>?
    var journalReferenceCounts: [UUID: Int] = [:]
    var journalReferenceCountsAreCurrent = false
    var invalidJournalEntryIDs = Set<UUID>()
    var investmentLinkedEntriesByID: [UUID: JournalEntry] = [:]
    var existingScheduledLinkedEntryIDs = Set<UUID>()
    var journalStoredEntryCount = 0
    var retainsCompleteJournal = false
    var journalDerivedRefreshTask: Task<Void, Never>?
    var journalDerivedRefreshTaskToken: UUID?
    var journalDerivedRefreshWasDeferred = false
    var journalProjectionRevision: UInt64 = 0
    var exchangeRateMutationIsActive = false
    var exchangeRateMutationWaiters: [CheckedContinuation<Void, Never>] = []
    var budgetNodesRevision: UInt64 = 0
    var budgetTreeCache: BudgetTreeCacheEntry?
    var budgetConfigurationTimeline: BudgetConfigurationTimeline?
    var budgetConfigurationTimelineInvalid = false
    var budgetEntryAttributions: [UUID: BudgetEntryAttribution] = [:]
    var budgetAttributionCacheIsComplete = false
    var closedMonthBudgetProjection: ClosedMonthBudgetProjection?
    var budgetTreeCacheBuildCount = 0
    /// Test-visible evidence that a lazy mutation materialized the complete
    /// journal specifically to replay a later opening-carry checkpoint.
    var budgetJournalReplayReadCount = 0

    var isJournalMutationInProgress: Bool {
        manualJournalMutationIsActive
            || lockedCapturePromotionInProgress
            || (quickLogCommit?.generation == storeGeneration)
            || !scheduleMutationsInProgress.isEmpty
            || !scheduleEntryMatchesInProgress.isEmpty
            || !investmentMutationsInProgress.isEmpty
            || standaloneJournalMutationsInProgress > 0
    }

    init(dataEraseIntent: DataEraseIntentAccess = .production) {
        services = AppModelServices()
        lockedCaptureStore = LockedCaptureStore()
        receiptRecognizer = { data in
            try await ReceiptScanner.recognizeLines(inImageData: data)
        }
        lifecycleHooks = .none
        databaseURLForErase = nil
        deleteDatabaseKey = { try DatabaseKeyStore.deleteKey() }
        self.dataEraseIntent = dataEraseIntent
        openDatabaseStore = DatabaseStoreOpeners.production
        restartAfterErase = true
        retainsCompleteJournal = false
        budgetWidgetSnapshotStore = BudgetWidgetSnapshotStore()
        currentDate = Date.init
        UserDefaults.standard.register(defaults: [
            Self.lockedQuickCapturePreferenceKey: true
        ])
    }

    /// Dependency-injected construction for app-level tests and previews.
    /// Production startup still owns key access, store opening, and recovery.
    init(
        store: EncryptedRecordStore,
        profile: UserProfile?,
        accounts: [LedgerAccount],
        entries: [JournalEntry] = [],
        budgetNodes: [BudgetNode] = [],
        scheduledTransactions: [ScheduledTransaction] = [],
        investmentHoldings: [InvestmentHolding] = [],
        receiptAttachments: [ReceiptAttachment] = [],
        exchangeRates: [DatedExchangeRate] = [],
        netWorthSnapshots: [NetWorthSnapshot] = [],
        savingsGoals: [SavingsGoal] = [],
        quickLogDraft: QuickLogDraft? = nil,
        lockedCaptureStore: any LockedCaptureStoring = LockedCaptureStore(),
        receiptRecognizer: @escaping ReceiptLineRecognizer = { data in
            try await ReceiptScanner.recognizeLines(inImageData: data)
        },
        lifecycleHooks: AppModelLifecycleHooks = .none,
        databaseURLForErase: URL? = nil,
        deleteDatabaseKey: @escaping @Sendable () throws -> Void = {},
        dataEraseIntent: DataEraseIntentAccess = .none,
        openDatabaseStore: @escaping DatabaseStoreOpener =
            DatabaseStoreOpeners.production,
        restartAfterErase: Bool = false,
        retainsCompleteJournal: Bool = true,
        budgetWidgetSnapshotStore: BudgetWidgetSnapshotStore = BudgetWidgetSnapshotStore(),
        budgetConfigurationTimeline: BudgetConfigurationTimeline? = nil,
        budgetEntryAttributions: [UUID: BudgetEntryAttribution] = [:],
        currentDate: @escaping @Sendable () -> Date = Date.init,
        services: AppModelServices? = nil
    ) {
        self.services = services ?? AppModelServices()
        self.lockedCaptureStore = lockedCaptureStore
        self.receiptRecognizer = receiptRecognizer
        self.lifecycleHooks = lifecycleHooks
        self.databaseURLForErase = databaseURLForErase
        self.deleteDatabaseKey = deleteDatabaseKey
        self.dataEraseIntent = dataEraseIntent
        self.openDatabaseStore = openDatabaseStore
        self.restartAfterErase = restartAfterErase
        self.budgetWidgetSnapshotStore = budgetWidgetSnapshotStore
        self.currentDate = currentDate
        self.budgetConfigurationTimeline = budgetConfigurationTimeline
        self.budgetEntryAttributions = budgetEntryAttributions
        budgetAttributionCacheIsComplete = retainsCompleteJournal
        UserDefaults.standard.register(defaults: [
            Self.lockedQuickCapturePreferenceKey: true
        ])
        self.store = store
        storeGeneration = 1
        self.profile = profile
        self.accounts = accounts
        accountsByID = Dictionary(
            accounts.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.entries = entries.sorted { $0.occurredAt > $1.occurredAt }
        investmentLinkedEntriesByID = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.id, $0) }
        )
        existingScheduledLinkedEntryIDs = Set(entries.map(\.id))
        journalEntryCount = entries.count
        journalStoredEntryCount = entries.count
        self.retainsCompleteJournal = retainsCompleteJournal
        journalRecentEntriesAreCurrent = retainsCompleteJournal
        self.budgetNodes = budgetNodes
        self.scheduledTransactions = scheduledTransactions
        self.investmentHoldings = investmentHoldings
        receiptAttachmentMetadata = receiptAttachments.map(ReceiptAttachmentMetadata.init)
        self.exchangeRates = exchangeRates
        self.netWorthSnapshots = netWorthSnapshots.sorted { $0.capturedAt > $1.capturedAt }
        self.savingsGoals = savingsGoals
        self.quickLogDraft = quickLogDraft
        if profile == nil {
            state = .onboarding
            disableBudgetWidgetSnapshot()
        } else {
            state = .ready
            refreshBudgetWidgetSnapshot()
        }
    }

    /// A side-effect-free model used only to run the same domain load as the
    /// live app against a disposable encrypted database. In particular, it
    /// does not touch UserDefaults, Keychain, the capture inbox, or the live
    /// store while a restore candidate is being evaluated.
    init(
        restoreValidationStore: EncryptedRecordStore,
        lockedCaptureStore: any LockedCaptureStoring,
        receiptRecognizer: @escaping ReceiptLineRecognizer
    ) {
        services = AppModelServices()
        self.lockedCaptureStore = lockedCaptureStore
        self.receiptRecognizer = receiptRecognizer
        lifecycleHooks = .none
        databaseURLForErase = nil
        deleteDatabaseKey = {}
        dataEraseIntent = .none
        openDatabaseStore = DatabaseStoreOpeners.production
        restartAfterErase = false
        budgetWidgetSnapshotStore = BudgetWidgetSnapshotStore(defaults: nil)
        currentDate = Date.init
        store = restoreValidationStore
        storeGeneration = 1
        retainsCompleteJournal = false
    }

    var userAccounts: [LedgerAccount] {
        accounts.filter {
            ($0.kind == .asset || $0.kind == .liability)
                && $0.systemRole == nil
                && !$0.isArchived
        }
    }

    var hasJournalEntries: Bool {
        journalRecentEntriesAreCurrent && journalEntryCount > 0
    }

    var recoveryIssueCount: Int { recoveryIssues.count }

    var lockedCaptureInboxIsUnrecoverable: Bool {
        recoveryIssues.contains("locked_captures/unrecoverable")
    }

    /// Compatibility/read-only inventory for app tests and count badges. The
    /// value intentionally contains metadata only, never image bytes.
    var receiptAttachments: [ReceiptAttachmentMetadata] {
        receiptAttachmentMetadata
    }

    var recoveryIssueSummaries: [String] {
        safeRecoveryIssueSummaries(recoveryIssues)
    }

    /// Includes archived financial accounts for balances, net worth, and
    /// historical explanations. New-entry/default pickers use `userAccounts`.
    var allUserAccounts: [LedgerAccount] {
        accounts.filter { $0.kind == .asset || $0.kind == .liability }
    }

    var expenseCategories: [LedgerAccount] {
        accounts.filter { $0.kind == .expense && !$0.isArchived }
    }

    var incomeCategories: [LedgerAccount] {
        accounts.filter { $0.kind == .income && !$0.isArchived }
    }

    var manageableLedgerItems: [LedgerAccount] {
        accounts.filter {
            $0.systemRole == nil
                && ($0.kind == .asset
                    || $0.kind == .liability
                    || $0.kind == .expense
                    || $0.kind == .income)
        }
    }

    var reportingCalendar: Calendar {
        FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: profile?.reportingTimeZoneIdentifier
                ?? TimeZone.current.identifier
        )
    }
}
