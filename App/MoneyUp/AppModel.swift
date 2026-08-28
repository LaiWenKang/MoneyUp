import Foundation
import MoneyUpCore
import MoneyUpPersistence
import SwiftUI
import UIKit
import WidgetKit

private struct PreparedJournalReports: Sendable {
    let reports: [ReportPeriod: PeriodReport]
    let previousMonthToDateExpense: Money?
    let currentMonthToDateExpense: Money?
    let monthToDateHasUnconvertedActivity: Bool
}

/// Complete closed-month budget actuals prepared from the normalized journal
/// index. The tags prevent a month rollover or reporting-zone change from
/// silently reusing civil-month totals produced under different boundaries.
private struct ClosedMonthBudgetProjection: Sendable {
    let reportingTimeZoneIdentifier: String
    let currentMonthStart: Date
    let coverageStart: Date
    let currency: CurrencyCode
    let monthlySpending: [MonthlyBudgetSpending]
}

@MainActor
final class AppModel: ObservableObject {
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

    private struct PendingQuickLogCommit {
        let id: UUID
        let generation: Int
        let task: Task<Void, Error>
    }

    private struct EditableMoneySnapshot {
        let source: Money
        let destination: Money?
    }

    private enum BookLoadMode {
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

    private struct BudgetTreeCacheEntry {
        let currency: CurrencyCode
        let revision: UInt64
        let result: Result<BudgetTree, Error>
    }

    @Published private(set) var state: State = .launching
    /// Keeps decoded financial UI opaque while an auto-lock request waits for
    /// an atomic mutation to reach its durable boundary. Once the mutation
    /// drains, `lock()` clears decoded state before removing this cover.
    @Published private(set) var requiresAuthenticationPrivacyCover = false
    @Published private(set) var profile: UserProfile? {
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
    @Published private(set) var accounts: [LedgerAccount] = [] {
        didSet {
            journalProjectionRevision &+= 1
            let oldShape = oldValue.map {
                "\($0.id.uuidString)|\($0.currency?.value ?? "-")"
            }.sorted()
            let newShape = accounts.map {
                "\($0.id.uuidString)|\($0.currency?.value ?? "-")"
            }.sorted()
            if oldShape != newShape { closedMonthBudgetProjection = nil }
            accountsByID = Dictionary(
                accounts.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            invalidateDerivedData()
        }
    }
    /// Maintained once per account mutation so transaction rows and other hot
    /// view paths never rebuild an O(accounts) lookup table per rendered row.
    private(set) var accountsByID: [UUID: LedgerAccount] = [:]
    /// A deliberately bounded recent-activity cache. Production startup never
    /// fills this with the complete journal; History and Calendar query the
    /// encrypted chronological index directly.
    @Published private(set) var entries: [JournalEntry] = [] {
        didSet {
            if retainsCompleteJournal { invalidateDerivedData() }
            refreshBudgetWidgetSnapshot()
        }
    }
    @Published private(set) var journalEntryCount = 0
    /// Qualifies both the bounded `entries` cache and `journalEntryCount`.
    /// False means callers must present an unavailable/loading state rather
    /// than interpreting an empty cache as an empty durable journal.
    @Published private(set) var journalRecentEntriesAreCurrent = false
    @Published private(set) var budgetNodes: [BudgetNode] = [] {
        didSet {
            budgetNodesRevision &+= 1
            budgetTreeCache = nil
            refreshBudgetWidgetSnapshot()
        }
    }
    @Published private(set) var scheduledTransactions: [ScheduledTransaction] = []
    @Published private(set) var investmentHoldings: [InvestmentHolding] = []
    @Published private(set) var savingsGoals: [SavingsGoal] = []
    /// Blob-free attachment inventory. Image bytes are never retained by the
    /// application model and are fetched only for a selected History row.
    @Published private(set) var receiptAttachmentMetadata: [ReceiptAttachmentMetadata] = []
    @Published private(set) var exchangeRates: [DatedExchangeRate] = []
    @Published private(set) var netWorthSnapshots: [NetWorthSnapshot] = []
    @Published private(set) var isWorking = false
    @Published private(set) var requestedQuickLogMode: QuickLogLaunchMode?
    @Published private(set) var quickLogDraft: QuickLogDraft?
    @Published private(set) var recoveryIssues: [String] = []
    @Published private(set) var pendingLockedCaptureCount = 0

    private var store: EncryptedRecordStore?
    private let lockedCaptureStore: any LockedCaptureStoring
    private let receiptRecognizer: ReceiptLineRecognizer
    private let lifecycleHooks: AppModelLifecycleHooks
    private let databaseURLForErase: URL?
    private let deleteDatabaseKey: @Sendable () throws -> Void
    private let dataEraseIntent: DataEraseIntentAccess
    private let openDatabaseStore: DatabaseStoreOpener
    private let restartAfterErase: Bool
    private let budgetWidgetSnapshotStore: BudgetWidgetSnapshotStore
    private let currentDate: @Sendable () -> Date
    private let savingsGoalMutationSerializer = SavingsGoalMutationSerializer()
    private var quickLogDraftWriteTask: Task<Void, Never>?
    private var quickLogCommit: PendingQuickLogCommit?
    private var standaloneJournalMutationsInProgress = 0
    private var scheduleMutationsInProgress = Set<UUID>()
    private var scheduleEntryMatchesInProgress = Set<UUID>()
    private var investmentMutationsInProgress = Set<UUID>()
    private var lockedCapturePromotionInProgress = false
    /// Closes the erase/capture time-of-check-to-time-of-use gap while the
    /// redacted inbox actor is writing. An erase that starts after the marker
    /// check must wait for (or, through the public guard, decline during) this
    /// write rather than deleting a capture the UI has just reported as saved.
    private var lockedCaptureWriteInProgress = false
    private var storeCloseTask: Task<Void, Never>?
    private var autoLockTask: Task<Void, Never>?
    /// First instant the scene stopped being active. iOS normally sends
    /// `.inactive` before `.background`; retaining the first instant prevents
    /// the second transition from silently extending the lock deadline.
    private var leftActiveAt: Date?
    private var storeGeneration = 0
    private var lockAfterStart = false
    private var isLifecycleMutationInProgress = false
    private var manualJournalMutationIsActive = false
    private var lockAfterLifecycleMutation = false
    private var goalMutationsInProgress = 0
    private var goalMutationBarrierClosed = false
    private var goalMutationDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var isStarting = false
    private var reportCache: [ReportPeriod: DerivedValue<PeriodReport>] = [:]
    private var reportCacheDay: Date?
    private var monthToDateComparisonCache: DerivedValue<MonthToDateExpenseComparison>?
    private var monthToDateComparisonCacheDay: Date?
    private var balanceCache: DerivedValue<[UUID: [CurrencyCode: Money]]>?
    private var journalReferenceCounts: [UUID: Int] = [:]
    private var journalReferenceCountsAreCurrent = false
    private var invalidJournalEntryIDs = Set<UUID>()
    private var investmentLinkedEntriesByID: [UUID: JournalEntry] = [:]
    private var existingScheduledLinkedEntryIDs = Set<UUID>()
    private var journalStoredEntryCount = 0
    private var retainsCompleteJournal = false
    private var journalDerivedRefreshTask: Task<Void, Never>?
    private var journalDerivedRefreshTaskToken: UUID?
    private var journalDerivedRefreshWasDeferred = false
    private var journalProjectionRevision: UInt64 = 0
    private var exchangeRateMutationIsActive = false
    private var exchangeRateMutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var budgetNodesRevision: UInt64 = 0
    private var budgetTreeCache: BudgetTreeCacheEntry?
    private var budgetConfigurationTimeline: BudgetConfigurationTimeline?
    private var budgetConfigurationTimelineInvalid = false
    private var budgetEntryAttributions: [UUID: BudgetEntryAttribution] = [:]
    private var budgetAttributionCacheIsComplete = false
    private var closedMonthBudgetProjection: ClosedMonthBudgetProjection?
    private(set) var budgetTreeCacheBuildCount = 0
    /// Test-visible evidence that a lazy mutation materialized the complete
    /// journal specifically to replay a later opening-carry checkpoint.
    private(set) var budgetJournalReplayReadCount = 0

    private var isJournalMutationInProgress: Bool {
        manualJournalMutationIsActive
            || lockedCapturePromotionInProgress
            || (quickLogCommit?.generation == storeGeneration)
            || !scheduleMutationsInProgress.isEmpty
            || !scheduleEntryMatchesInProgress.isEmpty
            || !investmentMutationsInProgress.isEmpty
            || standaloneJournalMutationsInProgress > 0
    }

    init(dataEraseIntent: DataEraseIntentAccess = .production) {
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
        currentDate: @escaping @Sendable () -> Date = Date.init
    ) {
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
    private init(
        restoreValidationStore: EncryptedRecordStore,
        lockedCaptureStore: any LockedCaptureStoring,
        receiptRecognizer: @escaping ReceiptLineRecognizer
    ) {
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

    /// Onboarding is safe only when no encrypted domain row exists. Iterating
    /// the exhaustive collection enum makes future schema additions fail
    /// closed instead of requiring another hand-maintained startup list.
    static func hasPersistedBookData(
        in store: EncryptedRecordStore
    ) async throws -> Bool {
        for collection in RecordCollection.allCases {
            try Task.checkCancellation()
            if try await store.count(in: collection) > 0 { return true }
        }
        return false
    }

    func start() async {
        guard !isWorking else { return }
        isWorking = true
        isStarting = true
        defer {
            isWorking = false
            isStarting = false
        }

        if let pendingClose = storeCloseTask {
            await pendingClose.value
            storeCloseTask = nil
        }
        if let existingStore = store {
            await existingStore.close()
            store = nil
            storeGeneration &+= 1
        }
        state = .launching

        var pendingDataEraseIsIncomplete = false
        do {
            // A prior jetsam, power loss, or process termination can interrupt
            // isolated restore validation before its defer-like cleanup. The
            // production directory is stable, so startup bounds abandoned
            // SQLCipher/WAL artifacts to one owned location.
            let databaseURL = if let databaseURLForErase {
                databaseURLForErase
            } else {
                try Self.databaseURL()
            }
            // A durable erase tombstone always wins over normal startup. Do not
            // read or create the SQLCipher key until every idempotent erase step
            // has converged. Scrub the widget immediately as well: a transient
            // cleanup failure must not keep an old-book projection visible.
            if try dataEraseIntent.isPending() {
                pendingDataEraseIsIncomplete = true
                requestedQuickLogMode = nil
                disableBudgetWidgetSnapshot()
                clearDecodedState()
                try await Self.completePendingDataErase(
                    databaseURL: databaseURL,
                    deleteDatabaseKey: deleteDatabaseKey,
                    lockedCaptureStore: lockedCaptureStore,
                    clearEraseIntent: dataEraseIntent.clear
                )
                pendingDataEraseIsIncomplete = false
                pendingLockedCaptureCount = 0
            }
            try? Self.removeRestoreValidationDirectory(
                restoreValidationDirectoryURL
            )
            try? Self.removeLegacyRestoreValidationDirectories()
            let openedStore = try await openDatabaseStore(databaseURL)
            storeGeneration &+= 1
            store = openedStore
            try await load(from: openedStore)

            if profile == nil {
                // A profile is the root of a valid book. Treat onboarding as a
                // genuinely empty-store state only; otherwise an unlisted or
                // newly added collection could be silently overlaid by setup.
                let hasBookData = try await Self.hasPersistedBookData(
                    in: openedStore
                )
                guard !hasBookData else { throw AppModelError.invalidBook }
                disableBudgetWidgetSnapshot()
                state = .onboarding
            } else {
                try validateLoadedBook()
                do {
                    try await promoteLockedCaptureIfPossible(
                        to: openedStore,
                        generation: storeGeneration
                    )
                } catch let error as LockedCaptureStoreError {
                    recordLockedCaptureStoreIssue(error)
                }
                state = .ready
            }
            if lockAfterStart {
                lockAfterStart = false
                isWorking = false
                isStarting = false
                lock()
            }
        } catch let error as DatabaseKeyStoreError
            where error == .authenticationCancelled
                && !pendingDataEraseIsIncomplete {
            finishCancelledAuthentication()
        } catch {
            // Keep an opened store available to the recovery screen. It can
            // still produce a raw authenticated backup even when a domain
            // record cannot be decoded. A key/cipher failure happens before
            // `store` is assigned and therefore exposes no recovery operation.
            if store == nil {
                clearDecodedState()
            }
            finishFailedStartup(
                message: safeUserMessage(for: error, context: .unlock)
            )
        }
    }

    /// Authentication cancellation is a normal locked-state transition, not
    /// a startup failure. Kept as one transition so lifecycle tests can cover
    /// the background/foreground race without invoking process Keychain UI.
    func finishCancelledAuthentication() {
        autoLockTask?.cancel()
        autoLockTask = nil
        leftActiveAt = nil
        lockAfterStart = false
        if store != nil {
            // Defensive invariant: although Keychain cancellation normally
            // happens before a replacement store is assigned, never publish
            // `.locked` with an injected or future open store still attached.
            isWorking = false
            isStarting = false
            state = .failed("")
            lock()
            return
        }
        // `start()` closes any prior recovery store before requesting the
        // device-bound key. A cancelled retry must also discard decoded state
        // retained from that prior failed load before the locked UI is shown.
        clearDecodedState()
        state = .locked
        // The locked UI contains no decoded book data. Clearing the model
        // cover here handles both callback orderings: authentication may
        // cancel before or after the scene's active callback. While the scene
        // is still inactive, MoneyUpApp's independent scene-phase shield
        // remains opaque.
        requiresAuthenticationPrivacyCover = false
    }

    /// Publishes the recovery state unless an inactivity deadline already
    /// requested a deferred lock. In the latter ordering an opened or partly
    /// decoded store must be closed before the opaque cover is removed; the
    /// same failure will be rediscovered on the next explicit unlock.
    func finishFailedStartup(message: String) {
        let mustFinishDeferredLock = lockAfterStart
        lockAfterStart = false
        state = .failed(message)
        guard mustFinishDeferredLock else {
            if leftActiveAt == nil {
                requiresAuthenticationPrivacyCover = false
            }
            return
        }
        isWorking = false
        isStarting = false
        lock()
    }

    /// Gives SwiftUI's initial URL delivery one deterministic routing window
    /// before any protected key access can request authentication. A basic
    /// widget action can therefore enter the separate capture inbox without
    /// racing the normal encrypted-book startup path.
    func startAfterInitialRoutingWindow() async {
        do {
            try await Task.sleep(for: .milliseconds(350))
        } catch {
            return
        }
        guard !routeLockSafeRequestIfPossible() else { return }
        await start()
    }

    func lock() {
        if isLifecycleMutationInProgress
            || isJournalMutationInProgress
            || !investmentMutationsInProgress.isEmpty
            || !scheduleMutationsInProgress.isEmpty
            || !scheduleEntryMatchesInProgress.isEmpty
            || goalMutationsInProgress > 0
            || goalMutationBarrierClosed {
            requiresAuthenticationPrivacyCover = true
            lockAfterLifecycleMutation = true
            return
        }
        if isStarting || state == .launching {
            lockAfterStart = true
            return
        }
        let canLock: Bool
        switch state {
        case .ready, .onboarding, .failed:
            canLock = true
        case .launching, .locked:
            canLock = false
        }
        guard canLock else { return }
        autoLockTask?.cancel()
        autoLockTask = nil
        leftActiveAt = nil
        let pendingDraftWrite = quickLogDraftWriteTask
        let pendingQuickLogCommit = quickLogCommit.flatMap {
            $0.generation == storeGeneration ? $0.task : nil
        }
        pendingDraftWrite?.cancel()
        quickLogDraftWriteTask = nil
        let storeToClose = store
        let draftToSave = quickLogDraft
        store = nil
        storeGeneration &+= 1
        clearDecodedState()
        state = .locked
        requiresAuthenticationPrivacyCover = false

        guard let storeToClose else { return }
        let backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "Secure MoneyUp data",
            expirationHandler: nil
        )
        storeCloseTask = Task {
            defer {
                if backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                }
            }
            await pendingDraftWrite?.value
            var transactionCommitted = false
            if let pendingQuickLogCommit {
                do {
                    try await pendingQuickLogCommit.value
                    transactionCommitted = true
                } catch {
                    transactionCommitted = false
                }
            }
            if !transactionCommitted {
                await writeQuickLogDraft(draftToSave, to: storeToClose)
            }
            await storeToClose.close()
        }
    }

    /// Allows lifecycle callers and deterministic tests to wait until a lock
    /// has finished flushing/closing the store before reopening the file.
    func waitForPendingStoreClose() async {
        guard let pendingClose = storeCloseTask else { return }
        await pendingClose.value
        storeCloseTask = nil
    }

    func sceneDidBecomeInactive(at date: Date = Date()) {
        sceneDidLeaveActive(at: date)
    }

    func sceneDidEnterBackground(at date: Date = Date()) {
        sceneDidLeaveActive(at: date)
    }

    private func sceneDidLeaveActive(at date: Date) {
        // Startup can already hold a decrypted key/store while domain loading
        // is suspended. Track that interval too; `lock()` records a deferred
        // request until startup reaches an atomic publication boundary.
        let tracksInactivity: Bool
        switch state {
        case .ready, .onboarding, .launching, .failed:
            tracksInactivity = true
        case .locked:
            tracksInactivity = false
        }
        guard tracksInactivity || isStarting else { return }
        // Retain the opaque cover across the inactive -> active transition.
        // SwiftUI can reevaluate `scenePhase` before its `onChange` callback;
        // clearing only after the elapsed-time decision prevents a one-frame
        // disclosure before auto-lock is requested.
        requiresAuthenticationPrivacyCover = true
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            lock()
            return
        }

        // Flush the current form immediately instead of relying on a
        // debounced write to receive background execution time. This guard
        // also makes inactive -> background idempotent.
        guard leftActiveAt == nil else { return }
        leftActiveAt = date
        flushQuickLogDraftImmediately()
        autoLockTask?.cancel()
        let delay = profile?.autoLockDelay ?? 60
        guard delay > 0 else {
            lock()
            return
        }
        autoLockTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.lock()
        }
    }

    func sceneDidBecomeActive(at date: Date = Date()) {
        autoLockTask?.cancel()
        autoLockTask = nil
        // A startup authentication prompt can be cancelled while the scene is
        // inactive. In that path the model is already locked, so calling
        // `lock()` again would be a no-op and could leave the scene-level
        // privacy window permanently covering the unlock UI.
        if state == .locked {
            leftActiveAt = nil
            requiresAuthenticationPrivacyCover = false
            return
        }
        guard let leftActiveAt else {
            requiresAuthenticationPrivacyCover = false
            return
        }
        self.leftActiveAt = nil
        let delay = profile?.autoLockDelay ?? 60
        let elapsed = date.timeIntervalSince(leftActiveAt)
        if !elapsed.isFinite || elapsed < 0 || elapsed >= delay {
            lock()
        } else {
            requiresAuthenticationPrivacyCover = false
        }
    }

    @discardableResult
    func handleDeepLink(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "moneyup",
              url.host?.lowercased() == "quick-log" else { return false }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count == 1,
              let mode = QuickLogLaunchMode(rawValue: components[0].lowercased()) else {
            return false
        }
        requestedQuickLogMode = mode
        _ = routeLockSafeRequestIfPossible()
        return true
    }

    /// Moves only basic, privacy-redacted requests onto the locked capture
    /// screen. Smart text and receipts still require the protected book.
    @discardableResult
    func routeLockSafeRequestIfPossible() -> Bool {
        guard state == .launching || state == .locked,
              isLockSafeQuickCaptureRequested else { return false }
        guard lockedCaptureIsAllowedByLifecycleAndEraseIntent else {
            // Do not retain a request that was denied by an authoritative erase
            // boundary: otherwise it could surface later against the new blank
            // book after startup finishes converging the tombstone.
            requestedQuickLogMode = nil
            return false
        }
        state = .locked
        return true
    }

    private var isLockSafeQuickCaptureRequested: Bool {
        guard let requestedQuickLogMode,
              UserDefaults.standard.bool(
                  forKey: Self.lockedQuickCapturePreferenceKey
              ) else { return false }
        switch requestedQuickLogMode {
        case .expense, .income, .transfer, .refund:
            return true
        case .smartEntry, .scanReceipt:
            return false
        }
    }

    var canPresentLockedQuickCapture: Bool {
        state == .locked
            && isLockSafeQuickCaptureRequested
            && lockedCaptureIsAllowedByLifecycleAndEraseIntent
    }

    /// The durable erase marker is authoritative even before normal startup.
    /// A Keychain/protection-state error is not evidence that erase is absent,
    /// so lock-safe capture fails closed and lets startup resolve the condition.
    private var lockedCaptureIsAllowedByLifecycleAndEraseIntent: Bool {
        guard !isWorking,
              !isLifecycleMutationInProgress,
              !goalMutationBarrierClosed,
              !lockedCaptureWriteInProgress else { return false }
        do {
            return try dataEraseIntent.isPending() == false
        } catch {
            return false
        }
    }

    /// Testable/UI-safe evidence that authentication must precede any future
    /// decoded-content presentation, even though an atomic operation is still
    /// draining in `.ready` or `.launching`.
    var hasDeferredAuthenticationLock: Bool {
        lockAfterStart || lockAfterLifecycleMutation
    }

    func saveLockedCapture(
        mode: QuickLogLaunchMode,
        amountText: String,
        payee: String,
        note: String
    ) async throws {
        guard state == .locked,
              requestedQuickLogMode == mode,
              canPresentLockedQuickCapture,
              !lockedCaptureWriteInProgress else {
            throw AppModelError.locked
        }
        lockedCaptureWriteInProgress = true
        defer { lockedCaptureWriteInProgress = false }
        let kind: LockedCaptureKind
        switch mode {
        case .income:
            kind = .income
        case .transfer:
            kind = .transfer
        case .refund:
            kind = .refund
        case .expense:
            kind = .expense
        case .smartEntry, .scanReceipt:
            throw AppModelError.locked
        }
        pendingLockedCaptureCount = try await lockedCaptureStore.append(
            LockedCapture(
                kind: kind,
                amountText: amountText,
                payee: payee,
                note: note
            )
        )
        recoveryIssues.removeAll { $0.hasPrefix("locked_captures/") }
    }

    func consumeQuickLogRequest(_ mode: QuickLogLaunchMode) {
        guard requestedQuickLogMode == mode else { return }
        requestedQuickLogMode = nil
    }

    /// Runs OCR outside the view and only returns a parsed draft to the same
    /// unlocked store generation that requested it. A lock during Vision work
    /// therefore cannot repopulate sensitive form state afterward.
    func receiptAnalysis(
        from imageData: Data,
        prefersDayFirst: Bool
    ) async throws -> ReceiptParseResult? {
        guard state == .ready else { return nil }
        let generation = storeGeneration
        try Task.checkCancellation()
        let lines = try await receiptRecognizer(imageData)
        try Task.checkCancellation()
        guard isCurrentStoreGeneration(generation) else { return nil }
        return ReceiptTextParser.analyze(
            fromLines: lines,
            prefersDayFirst: prefersDayFirst,
            accounts: accounts
        )
    }

    /// Compatibility helper for tests and callers that only need the proposed
    /// transaction. The richer analysis is used by Log to show what was found
    /// and let the user choose among honest alternatives without rescanning.
    func receiptDraft(
        from imageData: Data,
        prefersDayFirst: Bool
    ) async throws -> TransactionDraft? {
        let result = try await receiptAnalysis(
            from: imageData,
            prefersDayFirst: prefersDayFirst
        )
        return result?.draft
    }

    /// Produces one exact History result page while keeping SQLCipher reads
    /// bounded. The storage actor applies the indexed date window and this
    /// method scans additional bounded chunks only when the remaining filters
    /// are sparse.
    func historyPage(
        query: HistoryQuery,
        after cursor: JournalEntryPageCursor? = nil,
        limit: Int = 80
    ) async throws -> HistoryPageResult {
        let generation = storeGeneration
        let historyStore = try requireStore()
        let accountSnapshot = accounts
        let calendarSnapshot = reportingCalendar
        let startDayKey = query.startDate.flatMap {
            FinancialPeriodBoundary.lowerDayKey(
                forStartDate: $0,
                calendar: calendarSnapshot
            )
        }
        let endDayKeyExclusive = query.endDateExclusive.flatMap {
            FinancialPeriodBoundary.upperDayKeyExclusive(
                forEndDateExclusive: $0,
                calendar: calendarSnapshot
            )
        }
        let validAccountIDs = Set(accountSnapshot.map(\.id))
        let quarantinedEntryIDs = invalidJournalEntryIDs
        let boundedLimit = min(max(limit, 1), 200)
        let scanLimit = min(max(boundedLimit * 2, 160), 500)
        var scanCursor = cursor
        var matches: [JournalEntry] = []

        while matches.count < boundedLimit {
            try Task.checkCancellation()
            let rawPage = try await historyStore.fetchJournalEntryPage(
                startDayKey: startDayKey,
                endDayKeyExclusive: endDayKeyExclusive,
                after: scanCursor,
                limit: scanLimit
            )
            guard isCurrentStoreGeneration(generation) else {
                throw AppModelError.locked
            }
            recordHistoryDecodeIssues(rawPage.issues)
            let relationshipIssues = rawPage.entries.filter { entry in
                entry.postings.contains { !validAccountIDs.contains($0.accountID) }
            }.map {
                RecordDecodeIssue(
                    collection: .journalEntries,
                    recordID: $0.id.uuidString
                )
            }
            recordHistoryDecodeIssues(relationshipIssues)
            let filtered = await Task.detached(priority: .userInitiated) {
                query.filteredEntries(
                    rawPage.entries.filter { entry in
                        !quarantinedEntryIDs.contains(entry.id)
                            && entry.postings.allSatisfy {
                            validAccountIDs.contains($0.accountID)
                        }
                    },
                    accounts: accountSnapshot,
                    calendar: calendarSnapshot
                )
            }.value
            let remaining = boundedLimit - matches.count
            matches.append(contentsOf: filtered.prefix(remaining))

            if filtered.count >= remaining {
                let moreResultsMayExist = filtered.count > remaining
                    || rawPage.nextCursor != nil
                return HistoryPageResult(
                    entries: matches,
                    nextCursor: moreResultsMayExist
                        ? matches.last.map {
                            JournalEntryPageCursor(
                                occurredAt: $0.occurredAt,
                                recordID: $0.id.uuidString
                            )
                        }
                        : nil
                )
            }
            guard let nextCursor = rawPage.nextCursor else {
                return HistoryPageResult(entries: matches, nextCursor: nil)
            }
            scanCursor = nextCursor
        }

        return HistoryPageResult(
            entries: matches,
            nextCursor: matches.last.map {
                JournalEntryPageCursor(
                    occurredAt: $0.occurredAt,
                    recordID: $0.id.uuidString
                )
            }
        )
    }

    /// Calculates the complete running total from bounded indexed pages. No
    /// full-journal filter runs on the main thread and no decoded result set is
    /// retained after the summary is returned.
    func historySummary(query: HistoryQuery) async throws -> HistorySummary {
        let generation = storeGeneration
        let historyStore = try requireStore()
        let accountSnapshot = accounts
        let calendarSnapshot = reportingCalendar
        let startDayKey = query.startDate.flatMap {
            FinancialPeriodBoundary.lowerDayKey(
                forStartDate: $0,
                calendar: calendarSnapshot
            )
        }
        let endDayKeyExclusive = query.endDateExclusive.flatMap {
            FinancialPeriodBoundary.upperDayKeyExclusive(
                forEndDateExclusive: $0,
                calendar: calendarSnapshot
            )
        }
        let validAccountIDs = Set(accountSnapshot.map(\.id))
        let quarantinedEntryIDs = invalidJournalEntryIDs
        var cursor: JournalEntryPageCursor?
        var transactionCount = 0
        var amountsByCurrency: [CurrencyCode: Decimal] = [:]

        repeat {
            try Task.checkCancellation()
            let rawPage = try await historyStore.fetchJournalEntryPage(
                startDayKey: startDayKey,
                endDayKeyExclusive: endDayKeyExclusive,
                after: cursor,
                limit: 500
            )
            guard isCurrentStoreGeneration(generation) else {
                throw AppModelError.locked
            }
            recordHistoryDecodeIssues(rawPage.issues)
            let relationshipIssues = rawPage.entries.filter { entry in
                entry.postings.contains { !validAccountIDs.contains($0.accountID) }
            }.map {
                RecordDecodeIssue(
                    collection: .journalEntries,
                    recordID: $0.id.uuidString
                )
            }
            recordHistoryDecodeIssues(relationshipIssues)
            let pageSummary = try await Task.detached(priority: .userInitiated) {
                let filtered = query.filteredEntries(
                    rawPage.entries.filter { entry in
                        !quarantinedEntryIDs.contains(entry.id)
                            && entry.postings.allSatisfy {
                            validAccountIDs.contains($0.accountID)
                        }
                    },
                    accounts: accountSnapshot,
                    calendar: calendarSnapshot
                )
                return try HistoryQuery().summary(
                    for: filtered,
                    accounts: accountSnapshot
                )
            }.value
            transactionCount += pageSummary.transactionCount
            for (currency, amount) in pageSummary.amountsByCurrency {
                amountsByCurrency[currency] = try CheckedDecimal.adding(
                    amountsByCurrency[currency] ?? .zero,
                    amount
                )
            }
            cursor = rawPage.nextCursor
        } while cursor != nil

        return HistorySummary(
            transactionCount: transactionCount,
            amountsByCurrency: amountsByCurrency
        )
    }

    /// Loads actuals for one visible Calendar range from the chronological
    /// SQLCipher index. The result is never merged into the recent cache and a
    /// date change can cancel the caller's task without leaving partial state.
    func calendarEntries(in interval: DateInterval) async throws -> [JournalEntry] {
        guard let dayKeys = FinancialPeriodBoundary.dayKeyRange(
            for: interval,
            calendar: reportingCalendar
        ) else { throw AppModelError.invalidBook }
        return try await journalEntries(
            startDayKey: dayKeys.lowerBound,
            endDayKeyExclusive: dayKeys.upperBound
        )
    }

    /// Complete normalized posting events for a bounded derived-data horizon.
    /// Budget rollover/snapshot preparation must use this hook (extending the
    /// interval to its earliest active rollover) rather than the 80-entry
    /// recent-activity cache.
    func journalPostingEvents(
        in interval: DateInterval
    ) async throws -> [LedgerPostingEvent] {
        let generation = storeGeneration
        let eventStore = try requireStore()
        guard let dayKeys = FinancialPeriodBoundary.dayKeyRange(
            for: interval,
            calendar: reportingCalendar
        ) else { throw AppModelError.invalidBook }
        let events = try await eventStore.fetchJournalPostingEvents(
            originDayKeyRange: dayKeys,
            excludingEntryIDs: invalidJournalEntryIDs
        )
        guard ownsStoreGeneration(generation) else { throw AppModelError.locked }
        return events
    }

    /// Schedule matching remains exact while bounding the candidate read to a
    /// useful window around the occurrence instead of scanning the journal.
    func matchingEntries(
        for schedule: ScheduledTransaction,
        calendar: Calendar? = nil
    ) async throws -> [JournalEntry] {
        let matchCalendar = calendar ?? reportingCalendar
        guard let start = matchCalendar.date(
            byAdding: .day,
            value: -31,
            to: schedule.nextOccurrence
        ), let end = matchCalendar.date(
            byAdding: .day,
            value: 32,
            to: schedule.nextOccurrence
        ) else { throw AppModelError.invalidBook }
        let linkedIDs = Set(
            scheduledTransactions.flatMap(\.resolutions).compactMap(\.linkedEntryID)
        )
        let candidateInterval = DateInterval(start: start, end: end)
        guard let dayKeys = FinancialPeriodBoundary.dayKeyRange(
            for: candidateInterval,
            calendar: matchCalendar
        ) else { throw AppModelError.invalidBook }
        let candidates = try await journalEntries(
            startDayKey: dayKeys.lowerBound,
            endDayKeyExclusive: dayKeys.upperBound
        )
        return candidates.filter {
            !linkedIDs.contains($0.id) && schedule.matches($0)
        }
    }

    private func journalEntries(
        startDate: Date? = nil,
        endDateExclusive: Date? = nil,
        startDayKey: Int? = nil,
        endDayKeyExclusive: Int? = nil,
        includeInvalidRelationships: Bool = false
    ) async throws -> [JournalEntry] {
        let generation = storeGeneration
        let journalStore = try requireStore()
        let validAccountIDs = Set(accounts.map(\.id))
        let quarantinedEntryIDs = invalidJournalEntryIDs
        var cursor: JournalEntryPageCursor?
        var result: [JournalEntry] = []
        repeat {
            try Task.checkCancellation()
            let page = try await journalStore.fetchJournalEntryPage(
                startDate: startDate,
                endDateExclusive: endDateExclusive,
                startDayKey: startDayKey,
                endDayKeyExclusive: endDayKeyExclusive,
                after: cursor,
                limit: 500
            )
            guard ownsStoreGeneration(generation) else {
                throw AppModelError.locked
            }
            recordHistoryDecodeIssues(page.issues)
            for entry in page.entries {
                guard !quarantinedEntryIDs.contains(entry.id) else { continue }
                let relationshipsAreValid = entry.postings.allSatisfy {
                    validAccountIDs.contains($0.accountID)
                }
                if relationshipsAreValid || includeInvalidRelationships {
                    result.append(entry)
                }
                if !relationshipsAreValid {
                    recordHistoryDecodeIssues([
                        RecordDecodeIssue(
                            collection: .journalEntries,
                            recordID: entry.id.uuidString
                        )
                    ])
                }
            }
            cursor = page.nextCursor
        } while cursor != nil
        return result
    }

    /// Explicit export/import/lifecycle operations need one coherent journal
    /// snapshot. SQLCipher returns it from a single actor-isolated SELECT; the
    /// temporary decoded array is released when the operation completes and is
    /// never assigned to the production recent cache.
    private func journalSnapshot(
        includeInvalidRelationships: Bool
    ) async throws -> [JournalEntry] {
        let generation = storeGeneration
        let snapshotStore = try requireStore()
        let recovered = try await snapshotStore.fetchAllIdentifiedRecovering(
            JournalEntry.self,
            from: .journalEntries
        )
        guard ownsStoreGeneration(generation) else { throw AppModelError.locked }
        recordHistoryDecodeIssues(recovered.issues)
        let validAccountIDs = Set(accounts.map(\.id))
        let quarantinedEntryIDs = invalidJournalEntryIDs.union(
            recovered.issues.compactMap { UUID(uuidString: $0.recordID) }
        )
        return recovered.values.filter { entry in
            guard !quarantinedEntryIDs.contains(entry.id) else { return false }
            let valid = entry.postings.allSatisfy {
                validAccountIDs.contains($0.accountID)
            }
            if !valid {
                recordHistoryDecodeIssues([
                    RecordDecodeIssue(
                        collection: .journalEntries,
                        recordID: entry.id.uuidString
                    )
                ])
            }
            return valid || includeInvalidRelationships
        }
    }

    private func recordHistoryDecodeIssues(_ issues: [RecordDecodeIssue]) {
        guard !issues.isEmpty else { return }
        var known = Set(recoveryIssues)
        recoveryIssues.append(contentsOf: issues.compactMap { issue in
            let identifier = "\(issue.collection.rawValue)/\(issue.recordID)"
            return known.insert(identifier).inserted ? identifier : nil
        })
    }

    /// Keeps the latest form state in memory immediately, then serializes a
    /// debounced copy into SQLCipher. Background locking cancels the debounce
    /// and flushes this latest snapshot before closing the store.
    func updateQuickLogDraft(_ draft: QuickLogDraft) {
        guard state == .ready else { return }
        // Save removes the draft in the same SQLCipher transaction as the
        // journal write. Refuse form callbacks while that transaction is
        // suspended so a later debounce cannot resurrect the committed draft.
        guard !isLifecycleMutationInProgress,
              !isWorking,
              !isJournalMutationInProgress,
              quickLogCommit == nil,
              goalMutationsInProgress == 0,
              !goalMutationBarrierClosed else { return }
        guard quickLogDraft != draft else { return }
        quickLogDraft = draft
        scheduleQuickLogDraftWrite(draft)
    }

    func completeOnboarding(
        baseCurrencyCode: String,
        accountName: String,
        accountType: FinancialAccountType,
        startingBalance: Decimal
    ) async throws {
        guard !isWorking else { return }
        isWorking = true
        invalidateInFlightJournalProjection()
        defer {
            isWorking = false
            resumeDeferredJournalDerivedRefreshIfPossible()
        }

        let generation = storeGeneration
        let store = try requireStore()
        let currency = try CurrencyCode(baseCurrencyCode)
        if accountType.isLiabilityAccount, startingBalance < .zero {
            throw AppModelError.negativeAmount
        }
        try requireValidNewWriteAmount(startingBalance, currency: currency)
        let normalizedName = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw AppModelError.emptyName
        }

        let mainAccount = LedgerAccount(
            name: normalizedName,
            kind: accountType.isLiabilityAccount ? .liability : .asset,
            currency: currency,
            accountType: accountType
        )
        let defaults = Self.defaultBook(mainAccount: mainAccount)
        let newProfile = UserProfile(baseCurrency: currency)
        let onboardingCalendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: newProfile.reportingTimeZoneIdentifier
        )
        guard let onboardingMonth = onboardingCalendar.dateInterval(
            of: .month,
            for: currentDate()
        )?.start else { throw AppModelError.invalidBook }
        let onboardingTimeline = try BudgetConfigurationTimeline(
            currency: currency,
            revisions: [BudgetConfigurationRevision(
                effectiveMonth: onboardingMonth,
                nodes: defaults.budgetNodes
            )]
        )
        var writes = try defaults.accounts.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .accounts)
        }
        writes += try defaults.budgetNodes.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .budgetNodes)
        }
        writes.append(
            try RecordWrite(
                newProfile,
                id: UserProfile.primaryRecordID,
                in: .profile
            )
        )
        writes.append(try budgetConfigurationTimelineWrite(onboardingTimeline))

        var openingEntry: JournalEntry?
        if startingBalance != .zero,
           let equity = defaults.accounts.first(where: { $0.systemRole == .openingBalances }) {
            let candidate = try TransactionFactory.balanceAdjustment(
                displayBalanceDelta: try Money(startingBalance, currency: currency),
                accountID: mainAccount.id,
                equityAccountID: equity.id,
                accountIsLiability: mainAccount.kind == .liability,
                note: String(localized: "account.opening_balance_note")
            )
            let entry = try appAuthoredEntry(
                candidate,
                reportingTimeZoneIdentifier: newProfile.reportingTimeZoneIdentifier
            )
            writes.append(
                try RecordWrite(entry, id: entry.id.uuidString, in: .journalEntries)
            )
            openingEntry = entry
        }

        invalidateCommittedJournalProjection()
        await lifecycleHooks.checkpoint(
            .afterJournalProjectionInvalidationBeforeCommit
        )
        try await store.write(writes)
        guard isCurrentStoreGeneration(generation) else { return }

        profile = newProfile
        accounts = defaults.accounts
        budgetConfigurationTimeline = onboardingTimeline
        budgetNodes = defaults.budgetNodes
        if retainsCompleteJournal {
            entries = openingEntry.map { [$0] } ?? []
        }
        await refreshJournalAfterMutation()
        state = .ready
        do {
            try await promoteLockedCaptureIfPossible(
                to: store,
                generation: generation
            )
        } catch let error as LockedCaptureStoreError {
            recordLockedCaptureStoreIssue(error)
        } catch {
            // Onboarding is already durable. Keep the new book usable and
            // expose a redacted recovery signal instead of stranding setup on
            // an inbox handoff failure.
            recordRecoveryIssue("locked_captures/promotion-unavailable")
        }
    }

    func addAccount(
        name: String,
        type: FinancialAccountType,
        currencyCode: String,
        startingBalance: Decimal = .zero
    ) async throws {
        try beginJournalMutation()
        defer { endJournalMutation() }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { throw AppModelError.emptyName }
        if type.isLiabilityAccount, startingBalance < .zero {
            throw AppModelError.negativeAmount
        }
        let currency = try CurrencyCode(currencyCode)
        try requireValidNewWriteAmount(startingBalance, currency: currency)
        let account = LedgerAccount(
            name: normalizedName,
            kind: type.isLiabilityAccount ? .liability : .asset,
            currency: currency,
            accountType: type
        )
        var accountsToAdd = [account]
        var writes = [
            try RecordWrite(account, id: account.id.uuidString, in: .accounts)
        ]
        var openingEntry: JournalEntry?

        if startingBalance != .zero {
            let equity = openingBalancesAccount()
            if !accounts.contains(where: { $0.id == equity.id }) {
                accountsToAdd.append(equity)
                writes.append(
                    try RecordWrite(equity, id: equity.id.uuidString, in: .accounts)
                )
            }
            let candidate = try TransactionFactory.balanceAdjustment(
                displayBalanceDelta: try Money(startingBalance, currency: currency),
                accountID: account.id,
                equityAccountID: equity.id,
                accountIsLiability: account.kind == .liability,
                note: String(localized: "account.opening_balance_note")
            )
            let entry = try appAuthoredEntry(candidate)
            writes.append(
                try RecordWrite(entry, id: entry.id.uuidString, in: .journalEntries)
            )
            openingEntry = entry
        }

        let generation = storeGeneration
        let accountStore = try requireStore()
        if openingEntry != nil {
            invalidateCommittedJournalProjection()
            await lifecycleHooks.checkpoint(
                .afterJournalProjectionInvalidationBeforeCommit
            )
        }
        try await accountStore.write(writes)
        await lifecycleHooks.checkpoint(.afterAccountWriteBeforeApply)
        guard isCurrentStoreGeneration(generation) else { return }
        accounts.append(contentsOf: accountsToAdd)
        if retainsCompleteJournal, let openingEntry { entries.insert(openingEntry, at: 0) }
        if openingEntry != nil { await refreshJournalAfterMutation() }
    }

    func addCategory(
        name: String,
        kind: LedgerAccountKind,
        parentID: UUID? = nil
    ) async throws {
        try beginJournalMutation()
        defer { endJournalMutation() }
        guard kind == .expense || kind == .income else {
            throw AppModelError.invalidCategoryKind
        }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { throw AppModelError.emptyName }
        let category = LedgerAccount(
            name: normalizedName,
            kind: kind,
            parentID: parentID
        )
        let generation = storeGeneration
        let store = try requireStore()

        if kind == .expense, let currency = profile?.baseCurrency {
            let node = BudgetNode(
                id: category.id,
                parentID: parentID,
                name: normalizedName,
                limit: nil
            )
            let candidate = budgetNodes + [node]
            _ = try BudgetTree(currency: currency, nodes: candidate)
            let candidateTimeline = try budgetConfigurationTimelineRecording(
                nodes: candidate
            )
            try await store.write([
                try RecordWrite(category, id: category.id.uuidString, in: .accounts),
                try RecordWrite(node, id: node.id.uuidString, in: .budgetNodes),
                try budgetConfigurationTimelineWrite(candidateTimeline)
            ])
            guard isCurrentStoreGeneration(generation) else { return }
            budgetConfigurationTimeline = candidateTimeline
            budgetNodes = candidate
        } else {
            try await store.upsert(category, id: category.id.uuidString, in: .accounts)
            guard isCurrentStoreGeneration(generation) else { return }
        }
        accounts.append(category)
    }

    func lifecycleImpact(for id: UUID) -> LedgerItemLifecycleImpact {
        let transactionCount = retainsCompleteJournal
            ? entries.reduce(into: 0) { count, entry in
                if entry.postings.contains(where: { $0.accountID == id }) { count += 1 }
            }
            : journalReferenceCounts[id, default: 0]
        let scheduleCount = scheduledTransactions.reduce(into: 0) { count, schedule in
            if schedule.accountID == id || schedule.categoryAccountID == id { count += 1 }
        }
        let holdingCount = investmentHoldings.reduce(into: 0) { count, holding in
            if holding.accountID == id { count += 1 }
        }
        let childCount = accounts.reduce(into: 0) { count, account in
            if account.parentID == id { count += 1 }
        }
        let defaultReferenceCount: Int
        if let profile {
            defaultReferenceCount = [
                profile.preferredAccountID,
                profile.preferredExpenseCategoryID,
                profile.preferredIncomeCategoryID
            ].compactMap { $0 }.filter { $0 == id }.count
        } else {
            defaultReferenceCount = 0
        }
        let draftReferenceCount: Int
        if let quickLogDraft {
            draftReferenceCount = [
                quickLogDraft.accountID,
                quickLogDraft.destinationAccountID,
                quickLogDraft.categoryID
            ].compactMap { $0 }.filter { $0 == id }.count
        } else {
            draftReferenceCount = 0
        }
        let budget = budgetNodes.first { $0.id == id }

        return LedgerItemLifecycleImpact(
            transactionCount: transactionCount,
            transactionReferencesAreCurrent: retainsCompleteJournal
                || journalReferenceCountsAreCurrent,
            scheduleCount: scheduleCount,
            holdingCount: holdingCount,
            childCount: childCount,
            defaultReferenceCount: defaultReferenceCount,
            draftReferenceCount: draftReferenceCount,
            hasConfiguredBudget: budget?.limit != nil
                || (budget?.purpose ?? .unclassified) != .unclassified
        )
    }

    func compatibleLifecycleTargets(for id: UUID) -> [LedgerAccount] {
        guard let source = accounts.first(where: { $0.id == id }),
              source.systemRole == nil else { return [] }
        let fundsInvestmentHolding = investmentHoldings.contains {
            $0.accountID == source.id
        }
        return accounts.filter {
            $0.id != source.id
                && $0.systemRole == nil
                && !$0.isArchived
                && $0.kind == source.kind
                && $0.currency == source.currency
                && (!fundsInvestmentHolding
                    || isInvestmentFundingAccountShape($0))
        }
    }

    func renameLedgerItem(id: UUID, name: String) async throws {
        try beginLifecycleMutation()
        defer { endLifecycleMutation() }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { throw AppModelError.emptyName }
        guard let index = accounts.firstIndex(where: { $0.id == id }) else {
            throw AppModelError.missingRecord
        }
        let original = accounts[index]
        try requireLifecycleEligible(original)
        guard original.name != normalizedName else { return }

        var updated = original
        updated.name = normalizedName
        var candidateBudgets = budgetNodes
        var candidateTimeline: BudgetConfigurationTimeline?
        var writes = [
            try RecordWrite(updated, id: updated.id.uuidString, in: .accounts)
        ]
        if original.kind == .expense,
           let budgetIndex = candidateBudgets.firstIndex(where: { $0.id == id }) {
            candidateBudgets[budgetIndex].name = normalizedName
            writes.append(
                try RecordWrite(
                    candidateBudgets[budgetIndex],
                    id: id.uuidString,
                    in: .budgetNodes
                )
            )
            candidateTimeline = try budgetConfigurationTimelineRecording(
                nodes: candidateBudgets
            )
            if let candidateTimeline {
                writes.append(try budgetConfigurationTimelineWrite(candidateTimeline))
            }
        }
        let audit = LedgerAccountLifecycleAudit(
            action: .renamed,
            before: original,
            after: updated,
            beforeBudget: budgetNodes.first { $0.id == id },
            afterBudget: candidateBudgets.first { $0.id == id }
        )
        writes.append(try lifecycleAuditWrite(audit))

        let generation = storeGeneration
        let lifecycleStore = try requireStore()
        try await lifecycleStore.write(writes)
        guard isCurrentStoreGeneration(generation) else { return }
        accounts[index] = updated
        if let candidateTimeline { budgetConfigurationTimeline = candidateTimeline }
        budgetNodes = candidateBudgets
        if !retainsCompleteJournal { await refreshJournalAfterMutation() }
    }

    /// Saves an expense category's account name and planning metadata as one
    /// SQLCipher transaction. Validation is completed before any row is
    /// written, and the lifecycle audit is committed in the same batch.
    func updateCategoryMetadata(
        categoryID: UUID,
        name: String,
        amount: Decimal?,
        purpose: BudgetPurpose,
        rolloverRule: BudgetRolloverRule
    ) async throws {
        try beginLifecycleMutation()
        defer { endLifecycleMutation() }

        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { throw AppModelError.emptyName }
        guard let accountIndex = accounts.firstIndex(where: { $0.id == categoryID }) else {
            throw AppModelError.missingRecord
        }
        let originalAccount = accounts[accountIndex]
        try requireLifecycleEligible(originalAccount)
        guard originalAccount.kind == .expense || originalAccount.kind == .income else {
            throw AppModelError.invalidCategoryKind
        }

        var updatedAccount = originalAccount
        updatedAccount.name = normalizedName
        var candidateBudgets = budgetNodes
        let beforeBudget = budgetNodes.first { $0.id == categoryID }

        if originalAccount.kind == .expense {
            guard let currency = profile?.baseCurrency,
                  let budgetIndex = candidateBudgets.firstIndex(where: {
                      $0.id == categoryID
                  }) else {
                throw AppModelError.missingRecord
            }
            var updatedBudget = try budgetNodeUpdating(
                candidateBudgets[budgetIndex],
                amount: amount,
                purpose: purpose,
                rolloverRule: rolloverRule,
                currency: currency
            )
            updatedBudget.name = normalizedName
            candidateBudgets[budgetIndex] = updatedBudget
            _ = try BudgetTree(currency: currency, nodes: candidateBudgets)
        }

        let afterBudget = candidateBudgets.first { $0.id == categoryID }
        guard updatedAccount != originalAccount || afterBudget != beforeBudget else { return }
        let candidateTimeline: BudgetConfigurationTimeline?
        if originalAccount.kind == .expense {
            candidateTimeline = try budgetConfigurationTimelineRecording(
                nodes: candidateBudgets
            )
        } else {
            candidateTimeline = nil
        }

        let audit = LedgerAccountLifecycleAudit(
            action: .categoryMetadataUpdated,
            before: originalAccount,
            after: updatedAccount,
            beforeBudget: beforeBudget,
            afterBudget: afterBudget
        )
        var writes: [RecordWrite] = []
        if updatedAccount != originalAccount {
            writes.append(
                try RecordWrite(
                    updatedAccount,
                    id: updatedAccount.id.uuidString,
                    in: .accounts
                )
            )
        }
        if let afterBudget, afterBudget != beforeBudget {
            writes.append(
                try RecordWrite(
                    afterBudget,
                    id: afterBudget.id.uuidString,
                    in: .budgetNodes
                )
            )
        }
        if let candidateTimeline {
            writes.append(try budgetConfigurationTimelineWrite(candidateTimeline))
        }
        writes.append(try lifecycleAuditWrite(audit))

        let generation = storeGeneration
        let lifecycleStore = try requireStore()
        try await lifecycleStore.write(writes)
        guard isCurrentStoreGeneration(generation) else { return }
        accounts[accountIndex] = updatedAccount
        if let candidateTimeline { budgetConfigurationTimeline = candidateTimeline }
        budgetNodes = candidateBudgets
    }

    func setLedgerItemArchived(id: UUID, isArchived: Bool) async throws {
        try beginLifecycleMutation()
        defer { endLifecycleMutation() }
        await finishPendingQuickLogDraftWrite()
        guard let index = accounts.firstIndex(where: { $0.id == id }) else {
            throw AppModelError.missingRecord
        }
        let original = accounts[index]
        try requireLifecycleEligible(original)
        guard original.isArchived != isArchived else { return }
        if isArchived {
            let hasScheduleReference = scheduledTransactions.contains {
                $0.accountID == id || $0.categoryAccountID == id
            }
            let fundsActiveHolding = investmentHoldings.contains {
                !$0.isArchived && $0.accountID == id
            }
            guard !hasScheduleReference, !fundsActiveHolding else {
                throw AppModelError.ledgerItemInUse
            }
        }

        var updated = original
        updated.isArchived = isArchived
        var candidateProfile = profile
        var candidateDraft = quickLogDraft
        if isArchived {
            clearReferences(to: id, in: &candidateProfile)
            clearReferences(to: id, in: &candidateDraft)
        }

        var writes = [
            try RecordWrite(updated, id: updated.id.uuidString, in: .accounts)
        ]
        if candidateProfile != profile, let candidateProfile {
            writes.append(
                try RecordWrite(
                    candidateProfile,
                    id: UserProfile.primaryRecordID,
                    in: .profile
                )
            )
        }
        if candidateDraft != quickLogDraft, let candidateDraft {
            writes.append(
                try RecordWrite(
                    candidateDraft,
                    id: QuickLogDraft.primaryRecordID,
                    in: .quickLogDrafts
                )
            )
        }
        let audit = LedgerAccountLifecycleAudit(
            action: isArchived ? .archived : .restored,
            before: original,
            after: updated
        )
        writes.append(try lifecycleAuditWrite(audit))

        let generation = storeGeneration
        let lifecycleStore = try requireStore()
        try await lifecycleStore.write(writes)
        guard isCurrentStoreGeneration(generation) else { return }
        accounts[index] = updated
        profile = candidateProfile
        quickLogDraft = candidateDraft
    }

    func mergeLedgerItem(id sourceID: UUID, into targetID: UUID) async throws {
        try beginLifecycleMutation()
        defer { endLifecycleMutation() }
        try await reassignAndDeleteLedgerItem(
            id: sourceID,
            to: targetID,
            action: .merged
        )
    }

    func deleteLedgerItem(id: UUID, reassigningTo targetID: UUID? = nil) async throws {
        try beginLifecycleMutation()
        defer { endLifecycleMutation() }
        if let targetID {
            try await reassignAndDeleteLedgerItem(
                id: id,
                to: targetID,
                action: .deletedWithReassignment
            )
            return
        }

        await finishPendingQuickLogDraftWrite()
        guard let source = accounts.first(where: { $0.id == id }) else {
            throw AppModelError.missingRecord
        }
        try requireLifecycleEligible(source)
        guard lifecycleImpact(for: id).isUnused else {
            throw AppModelError.ledgerItemInUse
        }

        let audit = LedgerAccountLifecycleAudit(
            action: .deleted,
            before: source,
            after: nil,
            beforeBudget: budgetNodes.first { $0.id == id }
        )
        let candidateBudgets = budgetNodes.filter { $0.id != id }
        let candidateTimeline: BudgetConfigurationTimeline?
        if source.kind == .expense {
            candidateTimeline = try budgetConfigurationTimelineRecording(
                nodes: candidateBudgets
            )
        } else {
            candidateTimeline = nil
        }
        var writes = [try lifecycleAuditWrite(audit)]
        if let candidateTimeline {
            writes.append(try budgetConfigurationTimelineWrite(candidateTimeline))
        }
        var deletions = [RecordDeletion(id: id.uuidString, from: .accounts)]
        if source.kind == .expense,
           budgetNodes.contains(where: { $0.id == id }) {
            deletions.append(RecordDeletion(id: id.uuidString, from: .budgetNodes))
        }

        let generation = storeGeneration
        let lifecycleStore = try requireStore()
        try await lifecycleStore.write(writes, removing: deletions)
        guard isCurrentStoreGeneration(generation) else { return }
        accounts.removeAll { $0.id == id }
        if let candidateTimeline { budgetConfigurationTimeline = candidateTimeline }
        budgetNodes = candidateBudgets
    }

    func setAccountBalance(accountID: UUID, displayBalance: Decimal) async throws {
        try beginJournalMutation()
        defer { endJournalMutation() }
        guard let account = accounts.first(where: { $0.id == accountID }),
              !account.isArchived,
              let currency = account.currency else {
            throw AppModelError.missingRecord
        }
        guard account.systemRole != .investmentPosition else {
            throw AppModelError.investmentEntryMutationForbidden
        }
        if account.kind == .liability, displayBalance < .zero {
            throw AppModelError.negativeAmount
        }
        let current: Decimal
        switch displayBalanceResult(for: account) {
        case let .available(balance):
            current = balance.amount
        case let .unavailable(issue):
            throw issue
        }
        try requireValidNewWriteAmount(
            displayBalance,
            currency: currency,
            preserving: current
        )
        let delta = try CheckedDecimal.subtracting(displayBalance, current)
        guard delta != .zero else { return }
        try requireValidNewWriteAmount(delta, currency: currency)

        let equity = openingBalancesAccount()
        let shouldAddEquity = !accounts.contains(where: { $0.id == equity.id })
        let candidate = try TransactionFactory.balanceAdjustment(
            displayBalanceDelta: try Money(delta, currency: currency),
            accountID: account.id,
            equityAccountID: equity.id,
            accountIsLiability: account.kind == .liability,
            note: String(localized: "account.balance_adjustment_note")
        )
        let entry = try appAuthoredEntry(candidate)
        var writes = [
            try RecordWrite(entry, id: entry.id.uuidString, in: .journalEntries)
        ]
        if shouldAddEquity {
            writes.append(
                try RecordWrite(equity, id: equity.id.uuidString, in: .accounts)
            )
        }

        let generation = storeGeneration
        let balanceStore = try requireStore()
        invalidateCommittedJournalProjection()
        await lifecycleHooks.checkpoint(
            .afterJournalProjectionInvalidationBeforeCommit
        )
        try await balanceStore.write(writes)
        guard isCurrentStoreGeneration(generation) else { return }
        if shouldAddEquity { accounts.append(equity) }
        if retainsCompleteJournal { entries.insert(entry, at: 0) }
        await refreshJournalAfterMutation()
    }

    @discardableResult
    func logExpense(
        amount: Decimal,
        accountID: UUID,
        categoryID: UUID,
        occurredAt: Date,
        payee: String?,
        note: String?,
        receiptData: Data? = nil
    ) async throws -> UUID? {
        try requireActiveCategory(categoryID, kind: .expense)
        let currency = try currency(for: accountID)
        try requireValidNewWriteAmount(amount, currency: currency)
        let entry = try TransactionFactory.expense(
            amount: try Money(amount, currency: currency),
            paidFrom: accountID,
            category: categoryID,
            occurredAt: occurredAt,
            payee: payee,
            note: note
        )
        return try await save(entry, receiptData: receiptData)
    }

    @discardableResult
    func logIncome(
        amount: Decimal,
        accountID: UUID,
        categoryID: UUID,
        occurredAt: Date,
        payee: String?,
        note: String?,
        receiptData: Data? = nil
    ) async throws -> UUID? {
        try requireActiveCategory(categoryID, kind: .income)
        let currency = try currency(for: accountID)
        try requireValidNewWriteAmount(amount, currency: currency)
        let entry = try TransactionFactory.income(
            amount: try Money(amount, currency: currency),
            depositedInto: accountID,
            category: categoryID,
            occurredAt: occurredAt,
            payee: payee,
            note: note
        )
        return try await save(entry, receiptData: receiptData)
    }

    @discardableResult
    func logRefund(
        amount: Decimal,
        accountID: UUID,
        categoryID: UUID,
        occurredAt: Date,
        payee: String?,
        note: String?,
        receiptData: Data? = nil
    ) async throws -> UUID? {
        try requireActiveCategory(categoryID, kind: .expense)
        let currency = try currency(for: accountID)
        try requireValidNewWriteAmount(amount, currency: currency)
        let entry = try TransactionFactory.refund(
            amount: try Money(amount, currency: currency),
            returnedTo: accountID,
            category: categoryID,
            occurredAt: occurredAt,
            payee: payee,
            note: note
        )
        return try await save(entry, receiptData: receiptData)
    }

    @discardableResult
    func logSplitTransaction(
        kind: QuickLogKind,
        amount: Decimal,
        accountID: UUID,
        lines: [TransactionSplitLine],
        occurredAt: Date,
        payee: String?,
        note: String?,
        receiptData: Data? = nil
    ) async throws -> UUID? {
        guard kind != .transfer else { throw AppModelError.invalidCategoryKind }
        let currency = try currency(for: accountID)
        try requireValidNewWriteAmount(amount, currency: currency)
        for line in lines {
            let expectedKind: LedgerAccountKind = kind == .income ? .income : .expense
            try requireActiveCategory(line.categoryAccountID, kind: expectedKind)
            try requireValidNewWriteAmount(line.amount.amount, currency: currency)
        }
        let total = try Money(amount, currency: currency)
        let entry: JournalEntry
        switch kind {
        case .expense:
            entry = try TransactionFactory.splitExpense(
                amount: total,
                paidFrom: accountID,
                splits: lines,
                occurredAt: occurredAt,
                payee: payee,
                note: note
            )
        case .income:
            entry = try TransactionFactory.splitIncome(
                amount: total,
                depositedInto: accountID,
                splits: lines,
                occurredAt: occurredAt,
                payee: payee,
                note: note
            )
        case .refund:
            entry = try TransactionFactory.splitRefund(
                amount: total,
                returnedTo: accountID,
                splits: lines,
                occurredAt: occurredAt,
                payee: payee,
                note: note
            )
        case .transfer:
            throw AppModelError.invalidCategoryKind
        }
        return try await save(entry, receiptData: receiptData)
    }

    @discardableResult
    func logTransfer(
        amount: Decimal,
        destinationAmount: Decimal? = nil,
        sourceAccountID: UUID,
        destinationAccountID: UUID,
        occurredAt: Date,
        note: String?
    ) async throws -> UUID? {
        let sourceCurrency = try currency(for: sourceAccountID)
        let destinationCurrency = try currency(for: destinationAccountID)
        try requireValidNewWriteAmount(amount, currency: sourceCurrency)
        if sourceCurrency == destinationCurrency {
            let entry = try TransactionFactory.transfer(
                amount: try Money(amount, currency: sourceCurrency),
                from: sourceAccountID,
                to: destinationAccountID,
                occurredAt: occurredAt,
                note: note
            )
            return try await save(entry)
        }

        guard let destinationAmount, destinationAmount > .zero else {
            throw AppModelError.foreignCurrencyTransferRequiresExchangeRate
        }
        try requireValidNewWriteAmount(destinationAmount, currency: destinationCurrency)
        let sourceTrading = foreignExchangeAccount(for: sourceCurrency)
        let destinationTrading = foreignExchangeAccount(for: destinationCurrency)
        let newTradingAccounts = [sourceTrading, destinationTrading].filter { candidate in
            !accounts.contains(where: { $0.id == candidate.id })
        }
        let entry = try TransactionFactory.foreignCurrencyTransfer(
            sourceAmount: try Money(amount, currency: sourceCurrency),
            destinationAmount: try Money(destinationAmount, currency: destinationCurrency),
            from: sourceAccountID,
            to: destinationAccountID,
            sourceTradingAccountID: sourceTrading.id,
            destinationTradingAccountID: destinationTrading.id,
            occurredAt: occurredAt,
            note: note
        )
        let writes = try newTradingAccounts.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .accounts)
        }
        return try await save(
            entry,
            additionalWrites: writes,
            additionalAccounts: newTradingAccounts
        )
    }

    func deleteEntry(id: UUID) async throws {
        let linkedScheduleIDs = Set(scheduledTransactions.compactMap { schedule in
            schedule.resolutions.contains { $0.linkedEntryID == id }
                ? schedule.id
                : nil
        })
        try beginJournalAndScheduleMutation(scheduleIDs: linkedScheduleIDs)
        defer {
            endJournalAndScheduleMutation(scheduleIDs: linkedScheduleIDs)
        }
        let generation = storeGeneration
        let entryStore = try requireStore()
        let entry: JournalEntry
        if let cached = entries.first(where: { $0.id == id }) {
            entry = cached
        } else if let stored = try await entryStore.fetch(
            JournalEntry.self,
            id: id.uuidString,
            from: .journalEntries
        ) {
            entry = stored
        } else {
            throw AppModelError.missingRecord
        }
        guard !isProtectedJournalEntry(entry) else {
            throw AppModelError.investmentEntryMutationForbidden
        }
        let originalAttribution = try await budgetEntryAttribution(
            for: id,
            in: entryStore
        )
        var candidateAttributions = budgetEntryAttributions
        candidateAttributions.removeValue(forKey: id)
        let affectedMonth = try budgetAffectedMonth(
            for: entry,
            attribution: originalAttribution
        )
        let affectedMonths = [affectedMonth].compactMap { $0 }
        var candidateEntries = try await journalEntriesForBudgetMutation(
            from: entryStore,
            affectedReportingMonths: affectedMonths
        )
        if candidateEntries != nil {
            candidateAttributions = budgetEntryAttributions
            candidateAttributions.removeValue(forKey: id)
        }
        candidateEntries?.removeAll { $0.id == id }
        let candidateTimeline: BudgetConfigurationTimeline?
        if let candidateEntries {
            candidateTimeline = try budgetTimelineAfterJournalMutation(
                journalEntries: candidateEntries,
                attributions: candidateAttributions,
                affectedReportingMonths: affectedMonths
            )
        } else {
            candidateTimeline = nil
        }
        let attachmentIDs = try await entryStore.receiptAttachmentIDs(entryID: id)
        var updatedSchedules: [ScheduledTransaction] = []
        let deletedAt = currentDate()
        for schedule in scheduledTransactions where linkedScheduleIDs.contains(schedule.id) {
            var updated = schedule
            try updated.markLinkedEntryDeleted(id, at: deletedAt)
            updatedSchedules.append(updated)
        }
        var writes = try updatedSchedules.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .scheduledTransactions)
        }
        if let candidateTimeline {
            writes.append(try budgetConfigurationTimelineWrite(candidateTimeline))
        }
        var deletions = [
            RecordDeletion(id: id.uuidString, from: .journalEntries)
        ] + attachmentIDs.map {
            RecordDeletion(id: $0.uuidString, from: .receiptAttachments)
        }
        if originalAttribution != nil {
            deletions.append(
                RecordDeletion(id: id.uuidString, from: .budgetEntryAttributions)
            )
        }
        invalidateCommittedJournalProjection()
        await lifecycleHooks.checkpoint(
            .afterJournalProjectionInvalidationBeforeCommit
        )
        try await entryStore.write(
            writes,
            removing: deletions
        )
        guard isCurrentStoreGeneration(generation) else { return }
        if let candidateTimeline { budgetConfigurationTimeline = candidateTimeline }
        budgetEntryAttributions = candidateAttributions
        if retainsCompleteJournal, let candidateEntries { entries = candidateEntries }
        receiptAttachmentMetadata.removeAll { $0.entryID == id }
        let schedulesByID = Dictionary(
            uniqueKeysWithValues: updatedSchedules.map { ($0.id, $0) }
        )
        scheduledTransactions = scheduledTransactions.map {
            schedulesByID[$0.id] ?? $0
        }
        existingScheduledLinkedEntryIDs.remove(id)
        await refreshJournalAfterMutation()
    }

    /// Loads exactly one user-selected encrypted receipt. No attachment bytes
    /// are cached on AppModel, and a lock that races the read discards them.
    func receiptAttachment(id: UUID) async throws -> ReceiptAttachment {
        guard let expectedMetadata = receiptAttachmentMetadata.first(
            where: { $0.id == id }
        ) else {
            throw AppModelError.missingRecord
        }
        let generation = storeGeneration
        let attachmentStore = try requireStore()
        guard let attachment = try await attachmentStore.receiptAttachment(id: id)
        else { throw AppModelError.missingRecord }
        guard isCurrentStoreGeneration(generation) else {
            throw AppModelError.locked
        }
        guard receiptAttachmentMetadata.contains(expectedMetadata),
              ReceiptAttachmentMetadata(attachment) == expectedMetadata else {
            throw AppModelError.invalidBook
        }
        return attachment
    }

    func deleteReceiptAttachment(id: UUID) async throws {
        try beginJournalMutation(invalidatesJournalProjection: false)
        defer { endJournalMutation() }
        guard receiptAttachmentMetadata.contains(where: { $0.id == id }) else {
            throw AppModelError.missingRecord
        }
        let generation = storeGeneration
        let attachmentStore = try requireStore()
        try await attachmentStore.remove(id: id.uuidString, from: .receiptAttachments)
        guard isCurrentStoreGeneration(generation) else { return }
        receiptAttachmentMetadata.removeAll { $0.id == id }
    }

    /// Rebuilds a consumer transaction and swaps it into the live journal in
    /// one database transaction. The replacement receives a new identity and
    /// points to the prior identity through `supersedesID`. The prior encrypted
    /// record is retained in a revision collection for recovery/audit purposes,
    /// but is excluded from balances and reports.
    func replaceEntry(
        id: UUID,
        kind: QuickLogKind,
        amount: Decimal,
        destinationAmount: Decimal?,
        accountID: UUID,
        destinationAccountID: UUID?,
        categoryID: UUID?,
        splitLines: [TransactionSplitLine]? = nil,
        occurredAt: Date,
        payee: String?,
        note: String?
    ) async throws {
        let linkedScheduleIDs = Set(scheduledTransactions.compactMap { schedule in
            schedule.resolutions.contains { $0.linkedEntryID == id }
                ? schedule.id
                : nil
        })
        try beginJournalAndScheduleMutation(scheduleIDs: linkedScheduleIDs)
        defer {
            endJournalAndScheduleMutation(scheduleIDs: linkedScheduleIDs)
        }
        let lookupStore = try requireStore()
        let original: JournalEntry
        if let cached = entries.first(where: { $0.id == id }) {
            original = cached
        } else if let stored = try await lookupStore.fetch(
            JournalEntry.self,
            id: id.uuidString,
            from: .journalEntries
        ) {
            original = stored
        } else {
            throw AppModelError.missingRecord
        }
        guard !isProtectedJournalEntry(original) else {
            throw AppModelError.investmentEntryMutationForbidden
        }

        let originalMoney = try editableMoneySnapshot(for: original)
        let accountCurrency = try replacementCurrency(
            for: accountID,
            preservingFrom: original
        )
        if let originalMoney, originalMoney.source.currency != accountCurrency {
            throw AppModelError.crossCurrencyEditRequiresConversion
        }
        try requireValidNewWriteAmount(
            amount,
            currency: accountCurrency,
            preserving: originalMoney?.source.amount
        )
        if let splitLines {
            guard kind != .transfer else { throw AppModelError.invalidCategoryKind }
            let expectedKind: LedgerAccountKind = kind == .income ? .income : .expense
            for line in splitLines {
                try requireReplacementCategory(
                    line.categoryAccountID,
                    kind: expectedKind,
                    preservingFrom: original
                )
                let originalLineAmount = original.postings.first {
                    $0.id == line.id && $0.money.currency == accountCurrency
                }.map { abs($0.money.amount) }
                try requireValidNewWriteAmount(
                    line.amount.amount,
                    currency: accountCurrency,
                    preserving: originalLineAmount
                )
            }
        }
        let candidate: JournalEntry
        var addedAccounts: [LedgerAccount] = []

        switch kind {
        case .expense:
            if let splitLines {
                candidate = try TransactionFactory.splitExpense(
                    amount: try Money(amount, currency: accountCurrency),
                    paidFrom: accountID,
                    splits: splitLines,
                    occurredAt: occurredAt,
                    payee: payee,
                    note: note
                )
            } else {
                guard let categoryID else { throw AppModelError.missingRecord }
                try requireReplacementCategory(
                    categoryID,
                    kind: .expense,
                    preservingFrom: original
                )
                candidate = try TransactionFactory.expense(
                    amount: try Money(amount, currency: accountCurrency),
                    paidFrom: accountID,
                    category: categoryID,
                    occurredAt: occurredAt,
                    payee: payee,
                    note: note
                )
            }
        case .income:
            if let splitLines {
                candidate = try TransactionFactory.splitIncome(
                    amount: try Money(amount, currency: accountCurrency),
                    depositedInto: accountID,
                    splits: splitLines,
                    occurredAt: occurredAt,
                    payee: payee,
                    note: note
                )
            } else {
                guard let categoryID else { throw AppModelError.missingRecord }
                try requireReplacementCategory(
                    categoryID,
                    kind: .income,
                    preservingFrom: original
                )
                candidate = try TransactionFactory.income(
                    amount: try Money(amount, currency: accountCurrency),
                    depositedInto: accountID,
                    category: categoryID,
                    occurredAt: occurredAt,
                    payee: payee,
                    note: note
                )
            }
        case .refund:
            if let splitLines {
                candidate = try TransactionFactory.splitRefund(
                    amount: try Money(amount, currency: accountCurrency),
                    returnedTo: accountID,
                    splits: splitLines,
                    occurredAt: occurredAt,
                    payee: payee,
                    note: note
                )
            } else {
                guard let categoryID else { throw AppModelError.missingRecord }
                try requireReplacementCategory(
                    categoryID,
                    kind: .expense,
                    preservingFrom: original
                )
                candidate = try TransactionFactory.refund(
                    amount: try Money(amount, currency: accountCurrency),
                    returnedTo: accountID,
                    category: categoryID,
                    occurredAt: occurredAt,
                    payee: payee,
                    note: note
                )
            }
        case .transfer:
            guard let destinationAccountID else { throw AppModelError.missingRecord }
            let destinationCurrency = try replacementCurrency(
                for: destinationAccountID,
                preservingFrom: original
            )
            if let originalDestination = originalMoney?.destination,
               originalDestination.currency != destinationCurrency {
                throw AppModelError.crossCurrencyEditRequiresConversion
            }
            if destinationCurrency == accountCurrency {
                candidate = try TransactionFactory.transfer(
                    amount: try Money(amount, currency: accountCurrency),
                    from: accountID,
                    to: destinationAccountID,
                    occurredAt: occurredAt,
                    note: note
                )
            } else {
                guard let destinationAmount, destinationAmount > .zero else {
                    throw AppModelError.foreignCurrencyTransferRequiresExchangeRate
                }
                try requireValidNewWriteAmount(
                    destinationAmount,
                    currency: destinationCurrency,
                    preserving: originalMoney?.destination?.amount
                )
                let sourceTrading = foreignExchangeAccount(for: accountCurrency)
                let destinationTrading = foreignExchangeAccount(for: destinationCurrency)
                addedAccounts = [sourceTrading, destinationTrading].filter { candidate in
                    !accounts.contains(where: { $0.id == candidate.id })
                }
                candidate = try TransactionFactory.foreignCurrencyTransfer(
                    sourceAmount: try Money(amount, currency: accountCurrency),
                    destinationAmount: try Money(
                        destinationAmount,
                        currency: destinationCurrency
                    ),
                    from: accountID,
                    to: destinationAccountID,
                    sourceTradingAccountID: sourceTrading.id,
                    destinationTradingAccountID: destinationTrading.id,
                    occurredAt: occurredAt,
                    note: note
                )
            }
        }

        let replacement = try JournalEntry(
            kind: candidate.kind,
            occurredAt: candidate.occurredAt,
            createdAt: original.createdAt,
            payee: candidate.payee,
            note: candidate.note,
            postings: candidate.postings,
            supersedesID: original.id,
            revisedAt: currentDate(),
            sourceSystem: original.sourceSystem,
            sourceFingerprint: original.sourceFingerprint,
            originContext: candidate.occurredAt == original.occurredAt
                ? original.originContext
                : reportingOriginContext(for: candidate.occurredAt)
        )
        let originalAttribution = try await budgetEntryAttribution(
            for: original.id,
            in: lookupStore
        )
        let reportingZone = profile?.reportingTimeZoneIdentifier
            ?? reportingCalendar.timeZone.identifier
        let replacementAttribution: BudgetEntryAttribution
        if let originalAttribution {
            let attributedReplacement = try replacementPreservingImplicitBudgetAttribution(
                replacement,
                original: original,
                priorAttribution: originalAttribution
            )
            replacementAttribution = try BudgetEntryAttribution(
                replacing: attributedReplacement,
                prior: originalAttribution,
                reportingTimeZoneIdentifier: reportingZone
            )
        } else {
            replacementAttribution = try BudgetEntryAttribution(
                entry: replacement,
                originTimeZoneIdentifier: reportingZone
            )
        }
        var candidateAttributions = budgetEntryAttributions
        candidateAttributions.removeValue(forKey: original.id)
        candidateAttributions[replacement.id] = replacementAttribution
        let originalAffectedMonth = try budgetAffectedMonth(
            for: original,
            attribution: originalAttribution
        )
        let replacementAffectedMonth = try budgetAffectedMonth(
            for: replacement,
            attribution: replacementAttribution
        )
        let affectedMonths = [
            originalAffectedMonth,
            replacementAffectedMonth
        ].compactMap { $0 }
        var candidateEntries = try await journalEntriesForBudgetMutation(
            from: lookupStore,
            affectedReportingMonths: affectedMonths
        )
        if candidateEntries != nil {
            candidateAttributions = budgetEntryAttributions
            candidateAttributions.removeValue(forKey: original.id)
            candidateAttributions[replacement.id] = replacementAttribution
            candidateEntries?.removeAll { $0.id == original.id }
            candidateEntries?.append(replacement)
            candidateEntries?.sort {
                if $0.occurredAt == $1.occurredAt {
                    return $0.createdAt > $1.createdAt
                }
                return $0.occurredAt > $1.occurredAt
            }
        }
        let candidateTimeline: BudgetConfigurationTimeline?
        if let candidateEntries {
            candidateTimeline = try budgetTimelineAfterJournalMutation(
                journalEntries: candidateEntries,
                attributions: candidateAttributions,
                affectedReportingMonths: affectedMonths
            )
        } else {
            candidateTimeline = nil
        }
        var writes = try addedAccounts.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .accounts)
        }
        writes.append(
            try RecordWrite(
                original,
                id: "\(original.id.uuidString)-\(UUID().uuidString)",
                in: .journalEntryRevisions
            )
        )
        writes.append(
            try RecordWrite(replacement, id: replacement.id.uuidString, in: .journalEntries)
        )
        let relinkedAttachmentMetadata = try receiptAttachmentMetadata
            .filter { $0.entryID == original.id }
            .map { try $0.relinked(to: replacement.id) }
        var relinkedSchedules: [ScheduledTransaction] = []
        for schedule in scheduledTransactions where linkedScheduleIDs.contains(schedule.id) {
            var updated = schedule
            try updated.relinkEntry(from: original.id, to: replacement.id)
            relinkedSchedules.append(updated)
        }
        writes += try relinkedSchedules.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .scheduledTransactions)
        }
        writes.append(
            try RecordWrite(
                replacementAttribution,
                id: replacementAttribution.id.uuidString,
                in: .budgetEntryAttributions
            )
        )
        if let candidateTimeline {
            writes.append(try budgetConfigurationTimelineWrite(candidateTimeline))
        }

        let generation = storeGeneration
        let transactionStore = try requireStore()
        invalidateCommittedJournalProjection()
        await lifecycleHooks.checkpoint(
            .afterJournalProjectionInvalidationBeforeCommit
        )
        try await transactionStore.write(
            writes,
            removing: [
                RecordDeletion(
                    id: original.id.uuidString,
                    from: .journalEntries
                ),
                RecordDeletion(
                    id: original.id.uuidString,
                    from: .budgetEntryAttributions
                )
            ],
            relinkingReceiptAttachments: ReceiptAttachmentRelink(
                sourceEntryID: original.id,
                destinationEntryID: replacement.id
            )
        )
        guard isCurrentStoreGeneration(generation) else { return }
        accounts.append(contentsOf: addedAccounts)
        if let candidateTimeline { budgetConfigurationTimeline = candidateTimeline }
        budgetEntryAttributions = candidateAttributions
        if retainsCompleteJournal, let candidateEntries { entries = candidateEntries }
        if !relinkedAttachmentMetadata.isEmpty {
            receiptAttachmentMetadata.removeAll { $0.entryID == original.id }
            receiptAttachmentMetadata.append(contentsOf: relinkedAttachmentMetadata)
        }
        let schedulesByID = Dictionary(
            uniqueKeysWithValues: relinkedSchedules.map { ($0.id, $0) }
        )
        scheduledTransactions = scheduledTransactions.map {
            schedulesByID[$0.id] ?? $0
        }
        if !relinkedSchedules.isEmpty {
            existingScheduledLinkedEntryIDs.remove(original.id)
            existingScheduledLinkedEntryIDs.insert(replacement.id)
        }
        await refreshJournalAfterMutation()
    }

    /// A lifecycle merge changes the live category ID without changing the
    /// user's historical intent. A later amount/date edit presents that merged
    /// target in the form, so an unchanged visible category must keep the
    /// pre-merge attribution. Selecting a genuinely different category is an
    /// explicit recategorization and uses the replacement postings as-is.
    private func replacementPreservingImplicitBudgetAttribution(
        _ replacement: JournalEntry,
        original: JournalEntry,
        priorAttribution: BudgetEntryAttribution
    ) throws -> JournalEntry {
        guard let timeline = budgetConfigurationTimeline else { return replacement }
        let budgetIDs = Set(timeline.revisions.flatMap(\.nodes).map(\.id))
        let originalBudgetPostings = original.postings.filter {
            budgetIDs.contains($0.accountID)
        }
        let replacementBudgetPostings = replacement.postings.filter {
            budgetIDs.contains($0.accountID)
        }
        let attributedBudgetPostings = priorAttribution.postings.filter {
            budgetIDs.contains($0.accountID)
        }
        guard originalBudgetPostings.count == 1,
              replacementBudgetPostings.count == 1,
              attributedBudgetPostings.count == 1,
              originalBudgetPostings[0].accountID
                == replacementBudgetPostings[0].accountID else {
            return replacement
        }
        let liveID = replacementBudgetPostings[0].accountID
        let attributedID = attributedBudgetPostings[0].accountID
        guard liveID != attributedID else { return replacement }
        let postings = replacement.postings.map { posting in
            guard posting.accountID == liveID else { return posting }
            return Posting(
                id: posting.id,
                accountID: attributedID,
                money: posting.money,
                memo: posting.memo
            )
        }
        return try JournalEntry(
            id: replacement.id,
            kind: replacement.kind,
            occurredAt: replacement.occurredAt,
            createdAt: replacement.createdAt,
            payee: replacement.payee,
            note: replacement.note,
            postings: postings,
            supersedesID: replacement.supersedesID,
            revisedAt: replacement.revisedAt,
            sourceSystem: replacement.sourceSystem,
            sourceFingerprint: replacement.sourceFingerprint,
            originContext: replacement.originContext
        )
    }

    func setBudgetLimit(
        categoryID: UUID,
        amount: Decimal?,
        purpose: BudgetPurpose? = nil,
        rolloverRule: BudgetRolloverRule? = nil
    ) async throws {
        try beginJournalMutation()
        defer { endJournalMutation() }
        guard let currency = profile?.baseCurrency,
              let index = budgetNodes.firstIndex(where: { $0.id == categoryID }) else {
            throw AppModelError.missingRecord
        }
        let updated = try budgetNodeUpdating(
            budgetNodes[index],
            amount: amount,
            purpose: purpose,
            rolloverRule: rolloverRule,
            currency: currency
        )
        var candidate = budgetNodes
        candidate[index] = updated
        _ = try BudgetTree(currency: currency, nodes: candidate)
        let candidateTimeline = try budgetConfigurationTimelineRecording(
            nodes: candidate
        )

        let generation = storeGeneration
        let budgetStore = try requireStore()
        try await budgetStore.write([
            try RecordWrite(updated, id: updated.id.uuidString, in: .budgetNodes),
            try budgetConfigurationTimelineWrite(candidateTimeline)
        ])
        guard isCurrentStoreGeneration(generation) else { return }
        budgetConfigurationTimeline = candidateTimeline
        budgetNodes = candidate
    }

    private func budgetNodeUpdating(
        _ original: BudgetNode,
        amount: Decimal?,
        purpose: BudgetPurpose?,
        rolloverRule: BudgetRolloverRule?,
        currency: CurrencyCode
    ) throws -> BudgetNode {
        if let amount, amount < .zero { throw AppModelError.negativeAmount }
        if let amount {
            try requireValidNewWriteAmount(
                amount,
                currency: currency,
                preserving: original.limit?.amount
            )
        }

        var updated = original
        updated.limit = try amount.map { try Money($0, currency: currency) }
        if let purpose { updated.purpose = purpose }
        if let rolloverRule {
            if rolloverRule == .none {
                updated.rolloverRule = .none
                updated.rolloverStartedAt = nil
            } else {
                if updated.rolloverRule != rolloverRule
                    || updated.rolloverStartedAt == nil {
                    let now = currentDate()
                    updated.rolloverStartedAt = reportingCalendar.dateInterval(
                        of: .month,
                        for: now
                    )?.start ?? now
                }
                updated.rolloverRule = rolloverRule
            }
        }
        if updated.limit == nil {
            updated.rolloverRule = .none
            updated.rolloverStartedAt = nil
        }
        return updated
    }

    private func withSerializedSavingsGoalMutation<T: Sendable>(
        id: UUID,
        operation: @MainActor () async throws -> T
    ) async throws -> T {
        try beginGoalMutation()
        await savingsGoalMutationSerializer.acquire(id)
        do {
            try Task.checkCancellation()
            let result = try await operation()
            await savingsGoalMutationSerializer.release(id)
            endGoalMutation()
            return result
        } catch {
            await savingsGoalMutationSerializer.release(id)
            endGoalMutation()
            throw error
        }
    }

    func addSavingsGoal(_ goal: SavingsGoal) async throws {
        try await withSerializedSavingsGoalMutation(id: goal.id) {
            guard !self.savingsGoals.contains(where: { $0.id == goal.id }) else {
                throw AppModelError.invalidBook
            }
            try self.requireValidNewWriteAmount(
                goal.target.amount,
                currency: goal.target.currency
            )
            let generation = self.storeGeneration
            let goalStore = try self.requireStore()
            await self.lifecycleHooks.checkpoint(.beforeSavingsGoalWrite)
            try await goalStore.upsert(
                goal,
                id: goal.id.uuidString,
                in: .savingsGoals
            )
            guard self.isCurrentStoreGeneration(generation) else { return }
            self.savingsGoals.removeAll { $0.id == goal.id }
            self.savingsGoals.append(goal)
            self.savingsGoals.sort { $0.targetDate < $1.targetDate }
        }
    }

    func updateSavingsGoal(
        id: UUID,
        name: String,
        kind: SavingsGoalKind,
        targetAmount: Decimal,
        targetDate: Date,
        resetRule: SavingsGoalResetRule
    ) async throws {
        try await withSerializedSavingsGoalMutation(id: id) {
            guard let goal = self.savingsGoals.first(where: { $0.id == id }) else {
                throw AppModelError.missingRecord
            }
            let currency = goal.target.currency
            try self.requireValidNewWriteAmount(targetAmount, currency: currency)
            let target = try Money(targetAmount, currency: currency)
            let updated: SavingsGoal
            do {
                updated = try goal.updating(
                    name: name,
                    kind: kind,
                    target: target,
                    targetDate: targetDate,
                    resetRule: resetRule
                )
            } catch {
                throw AppModelError.invalidGoal
            }
            try await self.persist(goal: updated)
        }
    }

    func addSavingsGoalMovement(
        goalID: UUID,
        kind: SavingsGoalMovementKind,
        amount: Decimal,
        occurredAt: Date = Date()
    ) async throws {
        try await withSerializedSavingsGoalMutation(id: goalID) {
            guard let goal = self.savingsGoals.first(where: { $0.id == goalID }) else {
                throw AppModelError.missingRecord
            }
            try self.requireValidNewWriteAmount(
                amount,
                currency: goal.target.currency
            )
            let movement: SavingsGoalMovement
            let updated: SavingsGoal
            do {
                movement = try SavingsGoalMovement(
                    kind: kind,
                    money: try Money(amount, currency: goal.target.currency),
                    occurredAt: occurredAt,
                    originTimeZoneIdentifier: self.profile?
                        .reportingTimeZoneIdentifier ?? "GMT"
                )
                updated = try goal.adding(
                    movement,
                    calendar: self.reportingCalendar
                )
            } catch SavingsGoalError.withdrawalExceedsBalance {
                throw AppModelError.goalWithdrawalExceedsBalance
            } catch {
                throw AppModelError.invalidGoal
            }
            try await self.persist(goal: updated)
        }
    }

    func resetSavingsGoal(id: UUID, at date: Date = Date()) async throws {
        try await withSerializedSavingsGoalMutation(id: id) {
            guard let goal = self.savingsGoals.first(where: { $0.id == id }) else {
                throw AppModelError.missingRecord
            }
            let updated: SavingsGoal
            do {
                updated = try goal.resetting(
                    at: date,
                    originTimeZoneIdentifier: self.profile?
                        .reportingTimeZoneIdentifier ?? "GMT"
                )
            } catch {
                throw AppModelError.invalidGoal
            }
            try await self.persist(goal: updated)
        }
    }

    func setSavingsGoalArchived(id: UUID, isArchived: Bool) async throws {
        try await withSerializedSavingsGoalMutation(id: id) {
            guard let goal = self.savingsGoals.first(where: { $0.id == id }) else {
                throw AppModelError.missingRecord
            }
            let updated = try goal.updating(
                name: goal.name,
                kind: goal.kind,
                target: goal.target,
                targetDate: goal.targetDate,
                resetRule: goal.resetRule,
                isArchived: isArchived
            )
            try await self.persist(goal: updated)
        }
    }

    func deleteSavingsGoal(id: UUID) async throws {
        try await withSerializedSavingsGoalMutation(id: id) {
            guard self.savingsGoals.contains(where: { $0.id == id }) else {
                throw AppModelError.missingRecord
            }
            let generation = self.storeGeneration
            let goalStore = try self.requireStore()
            await self.lifecycleHooks.checkpoint(.beforeSavingsGoalWrite)
            try await goalStore.remove(id: id.uuidString, from: .savingsGoals)
            guard self.isCurrentStoreGeneration(generation) else { return }
            self.savingsGoals.removeAll { $0.id == id }
        }
    }

    func savingsGoalSummary(
        _ goal: SavingsGoal,
        asOf: Date = Date()
    ) -> DerivedValue<SavingsGoalSummary> {
        do {
            return .available(
                try goal.summary(asOf: asOf)
            )
        } catch {
            DerivedValueDiagnostics.record(
                .goalCalculationFailed,
                operation: "savings-goal-summary",
                error: error
            )
            return .unavailable(.goalCalculationFailed)
        }
    }

    private func persist(goal: SavingsGoal) async throws {
        let generation = storeGeneration
        let goalStore = try requireStore()
        await lifecycleHooks.checkpoint(.beforeSavingsGoalWrite)
        try await goalStore.upsert(
            goal,
            id: goal.id.uuidString,
            in: .savingsGoals
        )
        guard isCurrentStoreGeneration(generation) else { return }
        guard savingsGoals.contains(where: { $0.id == goal.id }) else {
            throw AppModelError.missingRecord
        }
        savingsGoals.removeAll { $0.id == goal.id }
        savingsGoals.append(goal)
        savingsGoals.sort { $0.targetDate < $1.targetDate }
    }

    func addScheduledTransaction(_ transaction: ScheduledTransaction) async throws {
        try beginScheduleMutation(id: transaction.id)
        defer { endScheduleMutation(id: transaction.id) }
        guard !scheduledTransactions.contains(where: { $0.id == transaction.id }) else {
            throw AppModelError.transactionInProgress
        }
        let canonical = try transaction.updating(
            kind: transaction.kind,
            name: transaction.name,
            amount: transaction.amount,
            accountID: transaction.accountID,
            categoryAccountID: transaction.categoryAccountID,
            nextOccurrence: transaction.nextOccurrence,
            frequency: transaction.frequency,
            recurrenceTimeZone: reportingCalendar.timeZone
        )
        try validateScheduleReferences(canonical)
        try requireValidNewWriteAmount(
            canonical.amount.amount,
            currency: canonical.amount.currency
        )
        let generation = storeGeneration
        let scheduleStore = try requireStore()
        await lifecycleHooks.checkpoint(.beforeScheduleMutationCommit)
        guard ownsStoreGeneration(generation) else { throw AppModelError.locked }
        try await scheduleStore.upsert(
            canonical,
            id: canonical.id.uuidString,
            in: .scheduledTransactions
        )
        guard isCurrentStoreGeneration(generation) else { return }
        scheduledTransactions.append(canonical)
        scheduledTransactions.sort { $0.nextOccurrence < $1.nextOccurrence }
    }

    func updateScheduledTransaction(
        id: UUID,
        kind: JournalEntryKind,
        name: String,
        amount: Money,
        accountID: UUID,
        categoryAccountID: UUID,
        nextOccurrence: Date,
        frequency: RecurrenceFrequency
    ) async throws {
        try await mutateSchedule(id: id) { existing in
            let updated = try existing.updating(
                kind: kind,
                name: name,
                amount: amount,
                accountID: accountID,
                categoryAccountID: categoryAccountID,
                nextOccurrence: nextOccurrence,
                frequency: frequency,
                recurrenceTimeZone: self.reportingCalendar.timeZone
            )
            try self.validateScheduleReferences(updated)
            try self.requireValidNewWriteAmount(
                updated.amount.amount,
                currency: updated.amount.currency,
                preserving: existing.amount.currency == updated.amount.currency
                    ? existing.amount.amount
                    : nil
            )
            existing = updated
        }
    }

    func pauseScheduledTransaction(id: UUID) async throws {
        try await mutateSchedule(id: id) { try $0.pause() }
    }

    func resumeScheduledTransaction(id: UUID) async throws {
        try await mutateSchedule(id: id) { try $0.resume() }
    }

    func endScheduledTransaction(id: UUID, at date: Date = Date()) async throws {
        try await mutateSchedule(id: id) { try $0.end(at: date) }
    }

    func confirmScheduledOccurrence(
        scheduleID: UUID,
        occurrenceID: ScheduledOccurrenceID,
        at date: Date = Date()
    ) async throws {
        try await mutateSchedule(id: scheduleID) {
            try $0.confirmCurrent(occurrenceID: occurrenceID, at: date)
        }
    }

    func skipScheduledOccurrence(
        scheduleID: UUID,
        occurrenceID: ScheduledOccurrenceID,
        at date: Date = Date(),
        calendar: Calendar? = nil
    ) async throws {
        let recurrenceCalendar = calendar ?? reportingCalendar
        try await mutateSchedule(id: scheduleID) {
            try $0.resolveCurrent(
                occurrenceID: occurrenceID,
                as: .skipped,
                at: date,
                calendar: recurrenceCalendar
            )
        }
    }

    /// Creates the actual journal entry and advances its forecast in one
    /// SQLCipher transaction. The occurrence token prevents a stale UI or a
    /// retry from posting the same due item a second time.
    @discardableResult
    func postScheduledOccurrence(
        scheduleID: UUID,
        occurrenceID: ScheduledOccurrenceID,
        occurredAt: Date? = nil,
        resolvedAt: Date = Date(),
        calendar: Calendar? = nil
    ) async throws -> UUID? {
        let recurrenceCalendar = calendar ?? reportingCalendar
        let mutationScheduleIDs: Set<UUID> = [scheduleID]
        try beginJournalAndScheduleMutation(scheduleIDs: mutationScheduleIDs)
        defer {
            endJournalAndScheduleMutation(scheduleIDs: mutationScheduleIDs)
        }
        guard let index = scheduledTransactions.firstIndex(where: { $0.id == scheduleID }) else {
            throw AppModelError.missingRecord
        }

        let schedule = scheduledTransactions[index]
        guard schedule.currentOccurrenceID == occurrenceID else {
            throw ScheduledTransactionError.staleOccurrence
        }
        try validateScheduleReferences(schedule)
        try requireValidNewWriteAmount(
            schedule.amount.amount,
            currency: schedule.amount.currency
        )
        let candidate: JournalEntry
        switch schedule.kind {
        case .expense:
            candidate = try TransactionFactory.expense(
                amount: schedule.amount,
                paidFrom: schedule.accountID,
                category: schedule.categoryAccountID,
                occurredAt: occurredAt ?? schedule.nextOccurrence,
                payee: schedule.name
            )
        case .income:
            candidate = try TransactionFactory.income(
                amount: schedule.amount,
                depositedInto: schedule.accountID,
                category: schedule.categoryAccountID,
                occurredAt: occurredAt ?? schedule.nextOccurrence,
                payee: schedule.name
            )
        case .transfer, .adjustment, .investment:
            throw ScheduledTransactionError.unsupportedKind
        }
        let fingerprint = Self.scheduleFingerprint(for: occurrenceID)
        let generation = storeGeneration
        let scheduleStore = try requireStore()
        let occurrenceAlreadyExists = try await scheduleStore.containsJournalEntry(
            sourceFingerprint: fingerprint
        )
        guard !occurrenceAlreadyExists else {
            throw ScheduledTransactionError.occurrenceAlreadyResolved
        }
        let entry = try JournalEntry(
            id: candidate.id,
            kind: candidate.kind,
            occurredAt: candidate.occurredAt,
            createdAt: candidate.createdAt,
            payee: candidate.payee,
            note: candidate.note,
            postings: candidate.postings,
            sourceSystem: "MoneyUp Schedule",
            sourceFingerprint: fingerprint,
            originContext: .capture(
                for: candidate.occurredAt,
                calendar: recurrenceCalendar,
                timeZone: recurrenceCalendar.timeZone
            )
        )
        var updated = schedule
        try updated.resolveCurrent(
            occurrenceID: occurrenceID,
            as: .posted,
            linkedEntryID: entry.id,
            at: resolvedAt,
            calendar: recurrenceCalendar
        )

        let attribution = try BudgetEntryAttribution(
            entry: entry,
            originTimeZoneIdentifier: profile?.reportingTimeZoneIdentifier
                ?? reportingCalendar.timeZone.identifier
        )
        var candidateAttributions = budgetEntryAttributions
        candidateAttributions[entry.id] = attribution
        let affectedMonths = [
            try budgetAffectedMonth(for: entry, attribution: attribution)
        ].compactMap { $0 }
        var candidateEntries = try await journalEntriesForBudgetMutation(
            from: scheduleStore,
            affectedReportingMonths: affectedMonths
        )
        if candidateEntries != nil {
            candidateAttributions = budgetEntryAttributions
            candidateAttributions[entry.id] = attribution
            candidateEntries?.append(entry)
            candidateEntries?.sort {
                if $0.occurredAt == $1.occurredAt {
                    return $0.createdAt > $1.createdAt
                }
                return $0.occurredAt > $1.occurredAt
            }
        }
        let candidateTimeline: BudgetConfigurationTimeline?
        if let candidateEntries {
            candidateTimeline = try budgetTimelineAfterJournalMutation(
                journalEntries: candidateEntries,
                attributions: candidateAttributions,
                affectedReportingMonths: affectedMonths
            )
        } else {
            candidateTimeline = nil
        }

        var writes = [
            try RecordWrite(entry, id: entry.id.uuidString, in: .journalEntries),
            try RecordWrite(
                attribution,
                id: attribution.id.uuidString,
                in: .budgetEntryAttributions
            ),
            try RecordWrite(updated, id: updated.id.uuidString, in: .scheduledTransactions)
        ]
        if let candidateTimeline {
            writes.append(try budgetConfigurationTimelineWrite(candidateTimeline))
        }
        invalidateCommittedJournalProjection()
        await lifecycleHooks.checkpoint(
            .afterJournalProjectionInvalidationBeforeCommit
        )
        try await scheduleStore.write(writes)
        guard isCurrentStoreGeneration(generation) else { return nil }
        scheduledTransactions[index] = updated
        scheduledTransactions.sort { $0.nextOccurrence < $1.nextOccurrence }
        if let candidateTimeline { budgetConfigurationTimeline = candidateTimeline }
        budgetEntryAttributions = candidateAttributions
        if retainsCompleteJournal, let candidateEntries { entries = candidateEntries }
        existingScheduledLinkedEntryIDs.insert(entry.id)
        await refreshJournalAfterMutation()
        return entry.id
    }

    /// Links an existing actual entry and advances the forecast atomically.
    func matchScheduledOccurrence(
        scheduleID: UUID,
        occurrenceID: ScheduledOccurrenceID,
        entryID: UUID,
        resolvedAt: Date = Date(),
        calendar: Calendar? = nil
    ) async throws {
        let recurrenceCalendar = calendar ?? reportingCalendar
        let mutationScheduleIDs: Set<UUID> = [scheduleID]
        try beginJournalAndScheduleMutation(
            scheduleIDs: mutationScheduleIDs,
            matchingEntryID: entryID,
            invalidatesJournalProjection: false
        )
        defer {
            endJournalAndScheduleMutation(
                scheduleIDs: mutationScheduleIDs,
                matchingEntryID: entryID
            )
        }
        let generation = storeGeneration
        let matchStore = try requireStore()
        let entry: JournalEntry
        if let cached = entries.first(where: { $0.id == entryID }) {
            entry = cached
        } else if let stored = try await matchStore.fetch(
            JournalEntry.self,
            id: entryID.uuidString,
            from: .journalEntries
        ) {
            entry = stored
        } else {
            throw AppModelError.missingRecord
        }
        guard ownsStoreGeneration(generation) else { throw AppModelError.locked }
        guard !scheduledTransactions.contains(where: { schedule in
            schedule.resolutions.contains(where: { $0.linkedEntryID == entryID })
        }) else {
            throw AppModelError.scheduleEntryAlreadyMatched
        }
        guard let index = scheduledTransactions.firstIndex(where: {
            $0.id == scheduleID
        }) else {
            throw AppModelError.missingRecord
        }
        var updated = scheduledTransactions[index]
        guard updated.matches(entry) else {
            throw AppModelError.scheduleEntryMismatch
        }
        try updated.resolveCurrent(
            occurrenceID: occurrenceID,
            as: .matched,
            linkedEntryID: entryID,
            at: resolvedAt,
            calendar: recurrenceCalendar
        )
        await lifecycleHooks.checkpoint(.beforeScheduleMatchCommit)
        guard ownsStoreGeneration(generation) else { throw AppModelError.locked }
        try await matchStore.upsert(
            updated,
            id: updated.id.uuidString,
            in: .scheduledTransactions
        )
        guard isCurrentStoreGeneration(generation) else { return }
        scheduledTransactions[index] = updated
        scheduledTransactions.sort { $0.nextOccurrence < $1.nextOccurrence }
        existingScheduledLinkedEntryIDs.insert(entryID)
    }

    func deleteScheduledTransaction(id: UUID) async throws {
        try beginScheduleMutation(id: id)
        defer { endScheduleMutation(id: id) }
        let generation = storeGeneration
        let scheduleStore = try requireStore()
        try await scheduleStore.remove(id: id.uuidString, from: .scheduledTransactions)
        guard isCurrentStoreGeneration(generation) else { return }
        scheduledTransactions.removeAll { $0.id == id }
    }

    private func mutateSchedule(
        id: UUID,
        _ mutation: (inout ScheduledTransaction) throws -> Void
    ) async throws {
        try beginScheduleMutation(id: id)
        defer { endScheduleMutation(id: id) }
        guard let index = scheduledTransactions.firstIndex(where: { $0.id == id }) else {
            throw AppModelError.missingRecord
        }
        var updated = scheduledTransactions[index]
        try mutation(&updated)

        let generation = storeGeneration
        let scheduleStore = try requireStore()
        await lifecycleHooks.checkpoint(.beforeScheduleMutationCommit)
        guard ownsStoreGeneration(generation) else { throw AppModelError.locked }
        try await scheduleStore.upsert(
            updated,
            id: updated.id.uuidString,
            in: .scheduledTransactions
        )
        guard isCurrentStoreGeneration(generation) else { return }
        scheduledTransactions[index] = updated
        scheduledTransactions.sort { $0.nextOccurrence < $1.nextOccurrence }
    }

    private func beginScheduleMutation(id: UUID) throws {
        guard !isLifecycleMutationInProgress,
              !isWorking,
              state == .ready,
              !isJournalMutationInProgress,
              scheduleMutationsInProgress.insert(id).inserted else {
            throw AppModelError.transactionInProgress
        }
    }

    private func endScheduleMutation(id: UUID) {
        scheduleMutationsInProgress.remove(id)
        applyDeferredLockIfPossible()
    }

    private func beginJournalAndScheduleMutation(
        scheduleIDs: Set<UUID>,
        matchingEntryID: UUID? = nil,
        invalidatesJournalProjection: Bool = true
    ) throws {
        guard !isLifecycleMutationInProgress,
              !isWorking,
              state == .ready,
              !isJournalMutationInProgress,
              investmentMutationsInProgress.isEmpty,
              scheduleMutationsInProgress.isEmpty,
              scheduleEntryMatchesInProgress.isEmpty else {
            throw AppModelError.transactionInProgress
        }
        manualJournalMutationIsActive = true
        scheduleMutationsInProgress.formUnion(scheduleIDs)
        if let matchingEntryID {
            scheduleEntryMatchesInProgress.insert(matchingEntryID)
        }
        if invalidatesJournalProjection {
            invalidateInFlightJournalProjection()
        }
    }

    private func endJournalAndScheduleMutation(
        scheduleIDs: Set<UUID>,
        matchingEntryID: UUID? = nil
    ) {
        scheduleMutationsInProgress.subtract(scheduleIDs)
        if let matchingEntryID {
            scheduleEntryMatchesInProgress.remove(matchingEntryID)
        }
        endJournalMutation()
    }

    private func validateScheduleReferences(
        _ schedule: ScheduledTransaction
    ) throws {
        try validateScheduleReferences(schedule, in: accountsByID)
    }

    private func validateScheduleReferences(
        _ schedule: ScheduledTransaction,
        in candidateAccountsByID: [UUID: LedgerAccount]
    ) throws {
        guard let account = candidateAccountsByID[schedule.accountID],
              let category = candidateAccountsByID[
                  schedule.categoryAccountID
              ] else {
            throw AppModelError.missingRecord
        }
        guard !account.isArchived, !category.isArchived else {
            throw AppModelError.ledgerItemArchived
        }
        guard let currency = account.currency,
              currency == schedule.amount.currency,
              account.kind == .asset || account.kind == .liability,
              account.systemRole == nil,
              category.systemRole == nil,
              (schedule.kind == .expense && category.kind == .expense)
                || (schedule.kind == .income && category.kind == .income) else {
            throw AppModelError.missingRecord
        }
    }

    private static func scheduleFingerprint(
        for occurrenceID: ScheduledOccurrenceID
    ) -> String {
        "moneyup:schedule:\(occurrenceID.scheduleID.uuidString.lowercased()):"
            + "\(occurrenceID.seriesVersion):\(occurrenceID.index)"
    }

    func addInvestmentHolding(
        _ holding: InvestmentHolding,
        treatment: InvestmentOpeningTreatment
    ) async throws {
        try beginJournalMutation()
        defer { endJournalMutation() }
        try beginInvestmentMutation(id: holding.id)
        defer { investmentMutationsInProgress.remove(holding.id) }
        guard !investmentHoldings.contains(where: { $0.id == holding.id }) else {
            throw AppModelError.transactionInProgress
        }
        guard !holding.isArchived else { throw AppModelError.ledgerItemArchived }
        guard !holding.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppModelError.emptyName
        }
        guard let fundingAccount = accounts.first(where: { $0.id == holding.accountID }),
              isEligibleInvestmentFundingAccount(fundingAccount),
              let currency = fundingAccount.currency else {
            throw AppModelError.missingRecord
        }
        if let price = holding.price {
            guard price.currency == currency else {
                throw AppModelError.investmentCurrencyMismatch
            }
            try requireValidNewWriteAmount(price.amount, currency: price.currency)
            if holding.quantity > .zero, price.amount <= .zero {
                throw AppModelError.invalidInvestmentTrade
            }
        }
        guard holding.quantity == .zero || holding.price != nil else {
            throw AppModelError.missingInvestmentPrice
        }
        let activityDate = holding.priceAsOf ?? Date()
        try validateInvestmentActivityDate(activityDate, after: nil)

        let positionAccount = LedgerAccount(
            name: "\(holding.symbol.isEmpty ? holding.name : holding.symbol) · \(String(localized: "holding.position_value"))",
            kind: .asset,
            currency: currency,
            systemRole: .investmentPosition
        )
        var candidate = try InvestmentHolding(
            id: holding.id,
            accountID: holding.accountID,
            symbol: holding.symbol,
            name: holding.name,
            quantity: .zero,
            positionAccountID: positionAccount.id
        )
        var writes = [
            try RecordWrite(positionAccount, id: positionAccount.id.uuidString, in: .accounts)
        ]
        var addedAccounts = [positionAccount]
        var openingEntry: JournalEntry?
        if holding.quantity > .zero, let price = holding.price {
            let entryID = UUID()
            try performInvestmentDomainOperation {
                try candidate.recordPurchase(
                    quantity: holding.quantity,
                    unitCost: price,
                    occurredAt: activityDate,
                    entryID: entryID
                )
                try candidate.recordPrice(
                    price,
                    asOf: activityDate,
                    entryID: entryID
                )
            }
            guard let total = try validatedInvestmentMarketValue(candidate) else {
                throw AppModelError.missingInvestmentPrice
            }
            guard total.amount > .zero else {
                throw AppModelError.invalidInvestmentTrade
            }
            let entry: JournalEntry
            switch treatment {
            case .deductFromCash:
                entry = try TransactionFactory.investmentPurchase(
                    cashCost: total,
                    resultingPositionValue: total,
                    previousPositionValue: .zero(currency: currency),
                    cashAccountID: holding.accountID,
                    positionAccountID: positionAccount.id,
                    gainLossAccountID: UUID(),
                    occurredAt: activityDate,
                    payee: holding.name,
                    note: String(localized: "holding.purchase_note"),
                    id: entryID,
                    originContext: investmentOriginContext(for: activityDate)
                )
            case .cashAlreadyExcludesPosition:
                let equity = openingBalancesAccount()
                if !accounts.contains(where: { $0.id == equity.id }) {
                    writes.append(try RecordWrite(
                        equity,
                        id: equity.id.uuidString,
                        in: .accounts
                    ))
                    addedAccounts.append(equity)
                }
                entry = try TransactionFactory.investmentOpening(
                    positionValue: total,
                    positionAccountID: positionAccount.id,
                    equityAccountID: equity.id,
                    occurredAt: activityDate,
                    note: String(localized: "holding.opening_position_note"),
                    id: entryID,
                    originContext: investmentOriginContext(for: activityDate)
                )
            }
            writes.append(try RecordWrite(entry, id: entry.id.uuidString, in: .journalEntries))
            openingEntry = entry
        }
        writes.append(try RecordWrite(
            candidate,
            id: candidate.id.uuidString,
            in: .investmentHoldings
        ))
        let generation = storeGeneration
        let holdingStore = try requireStore()
        if openingEntry != nil {
            invalidateCommittedJournalProjection()
            await lifecycleHooks.checkpoint(
                .afterJournalProjectionInvalidationBeforeCommit
            )
        }
        try await holdingStore.write(writes)
        guard isCurrentStoreGeneration(generation) else { return }
        accounts.append(contentsOf: addedAccounts)
        investmentHoldings.append(candidate)
        if retainsCompleteJournal, let openingEntry {
            entries.insert(openingEntry, at: 0)
        }
        if let openingEntry {
            investmentLinkedEntriesByID[openingEntry.id] = openingEntry
        }
        if openingEntry != nil { await refreshJournalAfterMutation() }
    }

    func repriceInvestmentHolding(
        id: UUID,
        unitPrice: Decimal,
        asOf: Date
    ) async throws {
        try beginJournalMutation()
        defer { endJournalMutation() }
        try beginInvestmentMutation(id: id)
        defer { investmentMutationsInProgress.remove(id) }
        guard let index = investmentHoldings.firstIndex(where: { $0.id == id }) else {
            throw AppModelError.missingRecord
        }
        var holding = investmentHoldings[index]
        guard !holding.isArchived else { throw AppModelError.ledgerItemArchived }
        try validateInvestmentActivityDate(
            asOf,
            after: holding.latestActivityDate
        )
        guard let linkedAccounts = linkedInvestmentAccounts(for: holding) else {
            throw AppModelError.investmentNeedsLedgerConnection
        }
        let positionID = linkedAccounts.position.id
        let currency = linkedAccounts.currency
        try requireValidNewWriteAmount(unitPrice, currency: currency)
        guard unitPrice >= .zero else { throw AppModelError.invalidInvestmentTrade }
        let price = try Money(unitPrice, currency: currency)
        let previous = try positionLedgerValue(id: positionID, currency: currency)
        let desired = try validatedInvestmentPositionValue(
            quantity: holding.quantity,
            unitPrice: price
        )
        let delta = try checkedInvestmentDifference(
            desired.amount,
            previous.amount
        )
        let priceEntryID = delta == .zero ? nil : UUID()
        try performInvestmentDomainOperation {
            try holding.recordPrice(price, asOf: asOf, entryID: priceEntryID)
        }

        var writes = [try RecordWrite(
            holding,
            id: holding.id.uuidString,
            in: .investmentHoldings
        )]
        var newEntry: JournalEntry?
        var newlyCreatedGainAccount: LedgerAccount?
        if delta != .zero {
            guard let priceEntryID else { throw AppModelError.invalidBook }
            try requireValidNewWriteAmount(delta, currency: currency)
            let gain = investmentGainLossAccount(for: currency)
            if !accounts.contains(where: { $0.id == gain.id }) {
                writes.append(try RecordWrite(gain, id: gain.id.uuidString, in: .accounts))
                newlyCreatedGainAccount = gain
            }
            let entry = try TransactionFactory.investmentValuation(
                delta: try Money(delta, currency: currency),
                positionAccountID: positionID,
                gainLossAccountID: gain.id,
                occurredAt: asOf,
                note: String(localized: "holding.reprice_note"),
                id: priceEntryID,
                originContext: investmentOriginContext(for: asOf)
            )
            writes.append(try RecordWrite(entry, id: entry.id.uuidString, in: .journalEntries))
            newEntry = entry
        }
        let generation = storeGeneration
        let store = try requireStore()
        if newEntry != nil {
            invalidateCommittedJournalProjection()
            await lifecycleHooks.checkpoint(
                .afterJournalProjectionInvalidationBeforeCommit
            )
        }
        try await store.write(writes)
        guard isCurrentStoreGeneration(generation) else { return }
        if let newEntry {
            if let newlyCreatedGainAccount { accounts.append(newlyCreatedGainAccount) }
            if retainsCompleteJournal { entries.insert(newEntry, at: 0) }
            investmentLinkedEntriesByID[newEntry.id] = newEntry
        }
        investmentHoldings[index] = holding
        if newEntry != nil { await refreshJournalAfterMutation() }
    }

    /// Explicit one-time migration for beta holdings that predate ledger-linked
    /// positions. The caller must choose whether the recorded cash balance
    /// still includes the investment; MoneyUp never guesses this material fact.
    func connectLegacyInvestmentHolding(
        id: UUID,
        fundingAccountID: UUID? = nil,
        deductFromCash: Bool,
        occurredAt: Date = Date()
    ) async throws {
        try beginJournalMutation()
        defer { endJournalMutation() }
        try beginInvestmentMutation(id: id)
        defer { investmentMutationsInProgress.remove(id) }
        guard let index = investmentHoldings.firstIndex(where: { $0.id == id }) else {
            throw AppModelError.missingRecord
        }
        var holding = investmentHoldings[index]
        guard !holding.isArchived else { throw AppModelError.ledgerItemArchived }
        try validateInvestmentActivityDate(
            occurredAt,
            after: holding.latestActivityDate
        )
        let selectedFundingID = fundingAccountID ?? holding.accountID
        guard holding.positionAccountID == nil,
              holding.quantity > .zero,
              let price = holding.price,
              let funding = accounts.first(where: { $0.id == selectedFundingID }),
              isEligibleInvestmentFundingAccount(funding),
              let currency = funding.currency,
              price.currency == currency,
              price.amount > .zero else {
            throw AppModelError.investmentCurrencyMismatch
        }
        try requireValidNewWriteAmount(price.amount, currency: currency)
        holding.accountID = funding.id
        let position = LedgerAccount(
            name: "\(holding.symbol.isEmpty ? holding.name : holding.symbol) · \(String(localized: "holding.position_value"))",
            kind: .asset,
            currency: currency,
            systemRole: .investmentPosition
        )
        let entryID = UUID()
        let originalQuantity = holding.quantity
        holding.quantity = .zero
        holding.positionAccountID = position.id
        try performInvestmentDomainOperation {
            try holding.recordPurchase(
                quantity: originalQuantity,
                unitCost: price,
                occurredAt: occurredAt,
                entryID: entryID
            )
        }
        guard let value = try validatedInvestmentMarketValue(holding) else {
            throw AppModelError.missingInvestmentPrice
        }
        guard value.amount > .zero else {
            throw AppModelError.invalidInvestmentTrade
        }
        let entry: JournalEntry
        var addedAccounts = [position]
        if deductFromCash {
            let gain = investmentGainLossAccount(for: currency)
            entry = try TransactionFactory.investmentPurchase(
                cashCost: value,
                resultingPositionValue: value,
                previousPositionValue: .zero(currency: currency),
                cashAccountID: funding.id,
                positionAccountID: position.id,
                gainLossAccountID: gain.id,
                occurredAt: occurredAt,
                payee: holding.name,
                note: String(localized: "holding.migration_note"),
                id: entryID,
                originContext: investmentOriginContext(for: occurredAt)
            )
        } else {
            let equity = openingBalancesAccount()
            entry = try TransactionFactory.investmentOpening(
                positionValue: value,
                positionAccountID: position.id,
                equityAccountID: equity.id,
                occurredAt: occurredAt,
                note: String(localized: "holding.migration_note"),
                id: entryID,
                originContext: investmentOriginContext(for: occurredAt)
            )
            if !accounts.contains(where: { $0.id == equity.id }) { addedAccounts.append(equity) }
        }
        var writes = try addedAccounts.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .accounts)
        }
        writes += [
            try RecordWrite(holding, id: holding.id.uuidString, in: .investmentHoldings),
            try RecordWrite(entry, id: entry.id.uuidString, in: .journalEntries)
        ]
        let generation = storeGeneration
        let store = try requireStore()
        invalidateCommittedJournalProjection()
        await lifecycleHooks.checkpoint(
            .afterJournalProjectionInvalidationBeforeCommit
        )
        try await store.write(writes)
        guard isCurrentStoreGeneration(generation) else { return }
        accounts.append(contentsOf: addedAccounts.filter { account in
            !accounts.contains(where: { $0.id == account.id })
        })
        investmentHoldings[index] = holding
        if retainsCompleteJournal { entries.insert(entry, at: 0) }
        investmentLinkedEntriesByID[entry.id] = entry
        await refreshJournalAfterMutation()
    }

    func recordInvestmentPurchase(
        holdingID: UUID,
        quantity: Decimal,
        unitPrice: Decimal,
        occurredAt: Date
    ) async throws {
        try beginJournalMutation()
        defer { endJournalMutation() }
        try beginInvestmentMutation(id: holdingID)
        defer { investmentMutationsInProgress.remove(holdingID) }
        guard let index = investmentHoldings.firstIndex(where: { $0.id == holdingID }) else {
            throw AppModelError.missingRecord
        }
        var holding = investmentHoldings[index]
        guard !holding.isArchived else { throw AppModelError.ledgerItemArchived }
        try validateInvestmentActivityDate(
            occurredAt,
            after: holding.latestActivityDate
        )
        guard let linkedAccounts = linkedInvestmentAccounts(for: holding) else {
            throw AppModelError.investmentNeedsLedgerConnection
        }
        let funding = linkedAccounts.funding
        let positionID = linkedAccounts.position.id
        let currency = linkedAccounts.currency
        guard quantity > .zero, unitPrice > .zero else {
            throw AppModelError.invalidInvestmentTrade
        }
        try requireValidNewWriteAmount(unitPrice, currency: currency)
        let price = try Money(unitPrice, currency: currency)
        let previous = try positionLedgerValue(id: positionID, currency: currency)
        let entryID = UUID()
        try performInvestmentDomainOperation {
            try holding.recordPurchase(
                quantity: quantity,
                unitCost: price,
                occurredAt: occurredAt,
                entryID: entryID
            )
            try holding.recordPrice(price, asOf: occurredAt, entryID: entryID)
        }
        let cashCost = try validatedInvestmentPositionValue(
            quantity: quantity,
            unitPrice: price
        )
        guard cashCost.amount > .zero else {
            throw AppModelError.invalidInvestmentTrade
        }
        guard let desired = try validatedInvestmentMarketValue(holding) else {
            throw AppModelError.missingInvestmentPrice
        }
        let gain = investmentGainLossAccount(for: currency)
        let entry = try TransactionFactory.investmentPurchase(
            cashCost: cashCost,
            resultingPositionValue: desired,
            previousPositionValue: previous,
            cashAccountID: funding.id,
            positionAccountID: positionID,
            gainLossAccountID: gain.id,
            occurredAt: occurredAt,
            payee: holding.name,
            note: String(localized: "holding.purchase_note"),
            id: entryID,
            originContext: investmentOriginContext(for: occurredAt)
        )
        var writes = [
            try RecordWrite(holding, id: holding.id.uuidString, in: .investmentHoldings),
            try RecordWrite(entry, id: entry.id.uuidString, in: .journalEntries)
        ]
        if !accounts.contains(where: { $0.id == gain.id }) {
            writes.append(try RecordWrite(gain, id: gain.id.uuidString, in: .accounts))
        }
        let generation = storeGeneration
        let store = try requireStore()
        invalidateCommittedJournalProjection()
        await lifecycleHooks.checkpoint(
            .afterJournalProjectionInvalidationBeforeCommit
        )
        try await store.write(writes)
        guard isCurrentStoreGeneration(generation) else { return }
        if !accounts.contains(where: { $0.id == gain.id }) { accounts.append(gain) }
        investmentHoldings[index] = holding
        if retainsCompleteJournal { entries.insert(entry, at: 0) }
        investmentLinkedEntriesByID[entry.id] = entry
        await refreshJournalAfterMutation()
    }

    @discardableResult
    func recordInvestmentSale(
        holdingID: UUID,
        quantity: Decimal,
        unitPrice: Decimal,
        occurredAt: Date
    ) async throws -> InvestmentSaleBreakdown {
        try beginJournalMutation()
        defer { endJournalMutation() }
        try beginInvestmentMutation(id: holdingID)
        defer { investmentMutationsInProgress.remove(holdingID) }
        guard let index = investmentHoldings.firstIndex(where: { $0.id == holdingID }) else {
            throw AppModelError.missingRecord
        }
        var holding = investmentHoldings[index]
        guard !holding.isArchived else { throw AppModelError.ledgerItemArchived }
        try validateInvestmentActivityDate(
            occurredAt,
            after: holding.latestActivityDate
        )
        guard let linkedAccounts = linkedInvestmentAccounts(for: holding) else {
            throw AppModelError.investmentNeedsLedgerConnection
        }
        let funding = linkedAccounts.funding
        let positionID = linkedAccounts.position.id
        let currency = linkedAccounts.currency
        guard quantity > .zero,
              quantity <= holding.quantity,
              unitPrice > .zero else {
            throw AppModelError.insufficientInvestmentQuantity
        }
        try requireValidNewWriteAmount(unitPrice, currency: currency)
        let price = try Money(unitPrice, currency: currency)
        let previous = try positionLedgerValue(id: positionID, currency: currency)
        let entryID = UUID()
        let breakdown = try performInvestmentDomainOperation {
            try holding.recordSale(
                quantity: quantity,
                unitPrice: price,
                occurredAt: occurredAt,
                entryID: entryID
            )
        }
        guard breakdown.proceeds.amount > .zero else {
            throw AppModelError.invalidInvestmentTrade
        }
        try requireValidNewWriteAmount(breakdown.proceeds.amount, currency: currency)
        try requireValidNewWriteAmount(breakdown.costBasis.amount, currency: currency)
        try requireValidNewWriteAmount(breakdown.realizedGainLoss.amount, currency: currency)
        try performInvestmentDomainOperation {
            try holding.recordPrice(price, asOf: occurredAt, entryID: entryID)
        }
        guard let desired = try validatedInvestmentMarketValue(holding) else {
            throw AppModelError.missingInvestmentPrice
        }
        let gain = investmentGainLossAccount(for: currency)
        let entry = try TransactionFactory.investmentSale(
            proceeds: breakdown.proceeds,
            resultingPositionValue: desired,
            previousPositionValue: previous,
            cashAccountID: funding.id,
            positionAccountID: positionID,
            gainLossAccountID: gain.id,
            occurredAt: occurredAt,
            payee: holding.name,
            note: String(localized: "holding.sale_note"),
            id: entryID,
            originContext: investmentOriginContext(for: occurredAt)
        )
        var writes = [
            try RecordWrite(holding, id: holding.id.uuidString, in: .investmentHoldings),
            try RecordWrite(entry, id: entry.id.uuidString, in: .journalEntries)
        ]
        if !accounts.contains(where: { $0.id == gain.id }) {
            writes.append(try RecordWrite(gain, id: gain.id.uuidString, in: .accounts))
        }
        let generation = storeGeneration
        let store = try requireStore()
        invalidateCommittedJournalProjection()
        await lifecycleHooks.checkpoint(
            .afterJournalProjectionInvalidationBeforeCommit
        )
        try await store.write(writes)
        guard isCurrentStoreGeneration(generation) else { return breakdown }
        if !accounts.contains(where: { $0.id == gain.id }) { accounts.append(gain) }
        investmentHoldings[index] = holding
        if retainsCompleteJournal { entries.insert(entry, at: 0) }
        investmentLinkedEntriesByID[entry.id] = entry
        await refreshJournalAfterMutation()
        return breakdown
    }

    func captureNetWorthSnapshot(at date: Date = Date()) async throws {
        try beginJournalMutation(invalidatesJournalProjection: false)
        defer { endJournalMutation() }
        guard !investmentHoldings.contains(where: { $0.needsLedgerConnection }) else {
            throw AppModelError.legacyInvestmentSnapshotForbidden
        }
        guard case let .available(amounts) = netWorthByCurrencyResult() else {
            throw AppModelError.invalidBook
        }
        let estimate: EstimatedNetWorth?
        switch estimatedNetWorthResult(at: date) {
        case let .available(value):
            estimate = value
        case .unavailable:
            throw AppModelError.invalidBook
        }
        let snapshot = try NetWorthSnapshot(
            capturedAt: date,
            amounts: amounts,
            estimatedBaseTotal: estimate?.total,
            conversionAsOf: estimate?.conversionAsOf,
            conversionAsOfDayKey: estimate?.conversionAsOfDayKey,
            conversionEvidence: estimate?.evidence ?? []
        )
        let generation = storeGeneration
        let store = try requireStore()
        await lifecycleHooks.checkpoint(.beforeNetWorthSnapshotCommit)
        try await store.upsert(
            snapshot,
            id: snapshot.id.uuidString,
            in: .netWorthSnapshots
        )
        guard isCurrentStoreGeneration(generation) else { return }
        netWorthSnapshots.insert(snapshot, at: 0)
    }

    func deleteInvestmentHolding(id: UUID) async throws {
        try beginJournalMutation()
        defer { endJournalMutation() }
        try beginInvestmentMutation(id: id)
        defer { investmentMutationsInProgress.remove(id) }
        guard let holdingIndex = investmentHoldings.firstIndex(where: { $0.id == id }) else {
            throw AppModelError.missingRecord
        }
        var holding = investmentHoldings[holdingIndex]
        guard !holding.isArchived else { throw AppModelError.ledgerItemArchived }
        guard holding.quantity == .zero else {
            throw AppModelError.investmentHoldingNotEmpty
        }
        try performInvestmentDomainOperation { try holding.archive() }
        var writes: [RecordWrite] = [try RecordWrite(
            holding,
            id: holding.id.uuidString,
            in: .investmentHoldings
        )]
        var archivedPosition: LedgerAccount?
        if let positionID = holding.positionAccountID {
            guard let linkedAccounts = linkedInvestmentAccounts(for: holding),
                  linkedAccounts.position.id == positionID,
                  try positionLedgerValue(
                    id: positionID,
                    currency: linkedAccounts.currency
                  ).isZero else {
                throw AppModelError.invalidBook
            }
            var position = linkedAccounts.position
            position.isArchived = true
            writes.append(try RecordWrite(
                position,
                id: position.id.uuidString,
                in: .accounts
            ))
            archivedPosition = position
        }
        let generation = storeGeneration
        let holdingStore = try requireStore()
        try await holdingStore.write(writes)
        guard isCurrentStoreGeneration(generation) else { return }
        if let archivedPosition,
           let positionIndex = accounts.firstIndex(where: {
               $0.id == archivedPosition.id
           }) {
            accounts[positionIndex] = archivedPosition
        }
        investmentHoldings[holdingIndex] = holding
    }

    func saveExchangeRate(
        baseCurrency: CurrencyCode,
        quoteCurrency: CurrencyCode,
        rate: Decimal,
        effectiveAt: Date,
        calendar: Calendar? = nil,
        timeZone: TimeZone? = nil
    ) async throws {
        await beginExchangeRateMutation()
        defer { endExchangeRateMutation() }
        try Task.checkCancellation()
        try beginJournalMutation(invalidatesJournalProjection: false)
        defer { endJournalMutation() }
        let effectiveCalendar = calendar ?? reportingCalendar
        let effectiveTimeZone = timeZone ?? effectiveCalendar.timeZone
        let candidate = try DatedExchangeRate(
            baseCurrency: baseCurrency,
            quoteCurrency: quoteCurrency,
            rate: rate,
            effectiveAt: effectiveAt,
            calendar: effectiveCalendar,
            timeZone: effectiveTimeZone
        )
        let replaced = exchangeRates.filter { existing in
            existing.effectiveContext.dayKey == candidate.effectiveContext.dayKey
                && ((existing.baseCurrency == baseCurrency
                        && existing.quoteCurrency == quoteCurrency)
                    || (existing.baseCurrency == quoteCurrency
                        && existing.quoteCurrency == baseCurrency))
        }
        let generation = storeGeneration
        let rateStore = try requireStore()
        try await rateStore.write(
            [try RecordWrite(candidate, id: candidate.id.uuidString, in: .exchangeRates)],
            removing: replaced.map {
                RecordDeletion(id: $0.id.uuidString, from: .exchangeRates)
            }
        )
        guard isCurrentStoreGeneration(generation) else { return }
        let replacedIDs = Set(replaced.map(\.id))
        exchangeRates.removeAll { replacedIDs.contains($0.id) }
        exchangeRates.append(candidate)
        exchangeRates.sort {
            if $0.effectiveContext.dayKey == $1.effectiveContext.dayKey {
                return $0.createdAt > $1.createdAt
            }
            return $0.effectiveContext.dayKey > $1.effectiveContext.dayKey
        }
    }

    func deleteExchangeRate(id: UUID) async throws {
        await beginExchangeRateMutation()
        defer { endExchangeRateMutation() }
        try Task.checkCancellation()
        try beginJournalMutation(invalidatesJournalProjection: false)
        defer { endJournalMutation() }
        let generation = storeGeneration
        let rateStore = try requireStore()
        try await rateStore.remove(id: id.uuidString, from: .exchangeRates)
        guard isCurrentStoreGeneration(generation) else { return }
        exchangeRates.removeAll { $0.id == id }
    }

    private func beginExchangeRateMutation() async {
        guard exchangeRateMutationIsActive else {
            exchangeRateMutationIsActive = true
            return
        }
        await withCheckedContinuation { continuation in
            exchangeRateMutationWaiters.append(continuation)
        }
    }

    private func endExchangeRateMutation() {
        guard !exchangeRateMutationWaiters.isEmpty else {
            exchangeRateMutationIsActive = false
            return
        }
        exchangeRateMutationWaiters.removeFirst().resume()
    }

    func historicalConversion(
        amount: Decimal,
        from sourceCurrency: CurrencyCode,
        to destinationCurrency: CurrencyCode,
        occurredAt: Date
    ) throws -> HistoricalCurrencyConversion? {
        try HistoricalExchangeRateLookup.conversion(
            of: Money(amount, currency: sourceCurrency),
            to: destinationCurrency,
            on: reportingOriginContext(for: occurredAt),
            rates: exchangeRates
        )
    }

    func updateAutoLockDelay(_ seconds: TimeInterval) async throws {
        guard UserProfile.allowedAutoLockDelays.contains(seconds) else {
            throw AppModelError.invalidBook
        }
        guard var updated = profile else { throw AppModelError.missingRecord }
        updated.autoLockDelay = seconds
        try await persist(updatedProfile: updated)
    }

    func updateLockedQuickCapture(_ enabled: Bool) async throws {
        guard var updated = profile else { throw AppModelError.missingRecord }
        updated.allowLockedQuickCapture = enabled
        try await persist(updatedProfile: updated)
        UserDefaults.standard.set(enabled, forKey: Self.lockedQuickCapturePreferenceKey)
    }

    func updateBudgetStatusWidget(_ enabled: Bool) async throws {
        guard var updated = profile else { throw AppModelError.missingRecord }
        updated.showsBudgetStatusWidget = enabled
        try await persist(updatedProfile: updated)
        // `profile`'s observer publishes the redacted snapshot. Reloading is
        // explicit here as well so disabling takes effect immediately.
        WidgetCenter.shared.reloadTimelines(ofKind: "MoneyUpQuickLog")
    }

    func updatePreferredAccount(_ id: UUID?) async throws {
        guard var updated = profile else { throw AppModelError.missingRecord }
        updated.preferredAccountID = id
        try await persist(updatedProfile: updated)
    }

    func updatePreferredExpenseCategory(_ id: UUID?) async throws {
        guard var updated = profile else { throw AppModelError.missingRecord }
        updated.preferredExpenseCategoryID = id
        try await persist(updatedProfile: updated)
    }

    func updatePreferredIncomeCategory(_ id: UUID?) async throws {
        guard var updated = profile else { throw AppModelError.missingRecord }
        updated.preferredIncomeCategoryID = id
        try await persist(updatedProfile: updated)
    }

    private func persist(updatedProfile: UserProfile) async throws {
        guard UserProfile.allowedAutoLockDelays.contains(
            updatedProfile.autoLockDelay
        ), TimeZone(
            identifier: updatedProfile.reportingTimeZoneIdentifier
        ) != nil else {
            throw AppModelError.invalidBook
        }
        try beginLifecycleMutation()
        defer { endLifecycleMutation() }
        let generation = storeGeneration
        let profileStore = try requireStore()
        await lifecycleHooks.checkpoint(.beforeProfileWrite)
        try await profileStore.upsert(
            updatedProfile,
            id: UserProfile.primaryRecordID,
            in: .profile
        )
        guard isCurrentStoreGeneration(generation) else { return }
        profile = updatedProfile
    }

    func eraseAllDataAndRestart() async {
        let pendingCommit = quickLogCommit.flatMap {
            $0.generation == storeGeneration ? $0.task : nil
        }
        guard !isWorking,
              !isLifecycleMutationInProgress,
              standaloneJournalMutationsInProgress == 0,
              scheduleMutationsInProgress.isEmpty,
              scheduleEntryMatchesInProgress.isEmpty,
              investmentMutationsInProgress.isEmpty,
              !lockedCapturePromotionInProgress,
              !lockedCaptureWriteInProgress,
              !manualJournalMutationIsActive || pendingCommit != nil else {
            return
        }
        isWorking = true
        goalMutationBarrierClosed = true
        isLifecycleMutationInProgress = true
        // Persist intent before the first destructive step. From this point a
        // process kill or power loss makes startup resume the erase instead of
        // silently reopening the old book.
        do {
            try dataEraseIntent.markPending()
        } catch {
            state = .failed(safeUserMessage(for: error, context: .save))
            finishExclusiveDataLifecycleMutation()
            return
        }
        requestedQuickLogMode = nil
        await waitForGoalMutationDrain()
        invalidateInFlightJournalProjection()
        state = .launching
        lockAfterStart = false
        let pendingDraftWrite = quickLogDraftWriteTask
        pendingDraftWrite?.cancel()
        quickLogDraftWriteTask = nil
        quickLogCommit = nil
        if let pendingClose = storeCloseTask {
            await pendingClose.value
            storeCloseTask = nil
        }
        let storeToClose = store
        store = nil
        storeGeneration &+= 1
        disableBudgetWidgetSnapshot()
        clearDecodedState()
        await pendingDraftWrite?.value
        if let pendingCommit {
            _ = try? await pendingCommit.value
        }
        await storeToClose?.close()

        do {
            let databaseURL: URL
            if let databaseURLForErase {
                databaseURL = databaseURLForErase
            } else {
                databaseURL = try Self.databaseURL()
            }
            try await Self.completePendingDataErase(
                databaseURL: databaseURL,
                deleteDatabaseKey: deleteDatabaseKey,
                lockedCaptureStore: lockedCaptureStore,
                clearEraseIntent: dataEraseIntent.clear
            )
            pendingLockedCaptureCount = 0
            if restartAfterErase {
                finishExclusiveDataLifecycleMutation()
                await start()
            } else {
                state = .onboarding
                finishExclusiveDataLifecycleMutation()
            }
        } catch {
            lockAfterStart = false
            clearDecodedState()
            state = .failed(safeUserMessage(for: error, context: .save))
            isWorking = false
            finishExclusiveDataLifecycleMutation()
        }
    }

    func displayBalanceResult(for account: LedgerAccount) -> DerivedValue<Money> {
        guard let currency = account.currency else {
            return .unavailable(.missingCurrency)
        }
        switch accountBalancesResult() {
        case let .available(balances):
            let raw = balances[account.id]?[currency]
                ?? Money.zero(currency: currency)
            return .available(account.kind == .liability ? raw.negated : raw)
        case let .unavailable(issue):
            return .unavailable(issue)
        }
    }

    /// Authoritative ledger net worth, separated by currency. Holdings are not
    /// added here: their hidden position accounts already carry their value.
    func netWorthByCurrencyResult() -> DerivedValue<[Money]> {
        var totals: [CurrencyCode: Decimal] = [:]
        for account in allUserAccounts {
            guard let currency = account.currency else { continue }
            switch displayBalanceResult(for: account) {
            case let .available(balance):
                do {
                    let current = totals[currency, default: .zero]
                    totals[currency] = account.kind == .liability
                        ? try checkedInvestmentDifference(current, balance.amount)
                        : try checkedEstimatedSum(current, balance.amount)
                } catch {
                    DerivedValueDiagnostics.record(
                        .amountCalculationFailed,
                        operation: "net-worth-by-currency",
                        error: error
                    )
                    return .unavailable(.amountCalculationFailed)
                }
            case let .unavailable(issue):
                return .unavailable(issue)
            }
        }
        do {
            return .available(try totals.sorted { $0.key < $1.key }.map {
                try Money($0.value, currency: $0.key)
            })
        } catch {
            return .unavailable(.amountCalculationFailed)
        }
    }

    /// Returns a combined estimate only when every non-zero foreign component
    /// has an applicable user-entered historical rate. The authoritative
    /// currency-separated totals remain the primary result and are never
    /// partially folded into the base currency.
    func estimatedNetWorthResult(
        at date: Date = Date()
    ) -> DerivedValue<EstimatedNetWorth?> {
        guard let baseCurrency = profile?.baseCurrency else {
            return .unavailable(.appNotReady)
        }
        let amounts: [Money]
        switch netWorthByCurrencyResult() {
        case let .available(value):
            amounts = value
        case let .unavailable(issue):
            return .unavailable(issue)
        }
        let origin = reportingOriginContext(for: date)
        var total = Decimal.zero
        var evidence: [NetWorthConversionEvidence] = []
        do {
            for amount in amounts where !amount.isZero {
                if amount.currency == baseCurrency {
                    total = try checkedEstimatedSum(total, amount.amount)
                    continue
                }
                guard let conversion = try HistoricalExchangeRateLookup.conversion(
                    of: amount,
                    to: baseCurrency,
                    on: origin,
                    rates: exchangeRates
                ) else {
                    return .available(nil)
                }
                total = try checkedEstimatedSum(
                    total,
                    conversion.converted.amount
                )
                evidence.append(try NetWorthConversionEvidence(
                    source: amount,
                    appliedRate: conversion.appliedRate,
                    rateID: conversion.rateID,
                    effectiveDayKey: conversion.effectiveDayKey,
                    usedInverseRate: conversion.usedInverseRate,
                    converted: conversion.converted
                ))
            }
            guard !evidence.isEmpty,
                  let oldestDayKey = evidence.map(\.effectiveDayKey).min(),
                  let oldestRate = evidence
                    .filter({ $0.effectiveDayKey == oldestDayKey })
                    .compactMap({ item in
                        exchangeRates.first { $0.id == item.rateID }
                    })
                    .first,
                  let conversionAsOf = oldestRate.effectiveContext.attributedDate(
                    in: reportingCalendar
                  ) else {
                return .available(nil)
            }
            return .available(EstimatedNetWorth(
                total: try Money(total, currency: baseCurrency),
                conversionAsOf: conversionAsOf,
                conversionAsOfDayKey: oldestDayKey,
                evidence: evidence.sorted { $0.source.currency < $1.source.currency }
            ))
        } catch {
            DerivedValueDiagnostics.record(
                .amountCalculationFailed,
                operation: "net-worth-estimate",
                error: error
            )
            return .unavailable(.amountCalculationFailed)
        }
    }

    /// The period report used by every reporting screen. Results are cached
    /// until the journal changes or the calendar day rolls over, so a SwiftUI
    /// body evaluation never rescans the whole journal.
    func reportResult(for period: ReportPeriod) -> DerivedValue<PeriodReport> {
        let calendar = reportingCalendar
        let now = currentDate()
        let today = calendar.startOfDay(for: now)
        if reportCacheDay != today {
            reportCache.removeAll()
            reportCacheDay = today
            if !retainsCompleteJournal {
                scheduleJournalDerivedRefresh()
                return .unavailable(.appNotReady)
            }
        }
        if let cached = reportCache[period] { return cached }

        guard retainsCompleteJournal else {
            scheduleJournalDerivedRefresh()
            return .unavailable(.appNotReady)
        }

        guard let currency = profile?.baseCurrency else {
            return .unavailable(.appNotReady)
        }
        guard let interval = period.interval(containing: now, calendar: calendar) else {
            DerivedValueDiagnostics.record(
                .invalidPeriod,
                operation: "period-report-interval"
            )
            return .unavailable(.invalidPeriod)
        }
        let trendInterval = ReportPeriod.twelveMonths.interval(
            containing: now,
            calendar: calendar
        )
            ?? interval
        let result: DerivedValue<PeriodReport>
        do {
            result = .available(
                try FinanceCalculator.report(
                    interval: interval,
                    trendInterval: trendInterval,
                    accounts: accounts,
                    entries: entries,
                    baseCurrency: currency,
                    calendar: calendar
                )
            )
        } catch {
            DerivedValueDiagnostics.record(
                .ledgerCalculationFailed,
                operation: "period-report",
                error: error
            )
            result = .unavailable(.ledgerCalculationFailed)
        }
        reportCache[period] = result
        return result
    }

    func spendingThisMonthResult() -> DerivedValue<[UUID: Money]> {
        switch reportResult(for: .thisMonth) {
        case let .available(report):
            return .available(
                Dictionary(
                    uniqueKeysWithValues: report.categorySpending.map {
                        ($0.accountID, $0.amount)
                    }
                )
            )
        case let .unavailable(issue):
            return .unavailable(issue)
        }
    }

    func excludedForeignSpendingThisMonthResult() -> DerivedValue<[Money]> {
        switch reportResult(for: .thisMonth) {
        case let .available(report):
            return .available(
                report.foreignFlows
                    .map(\.expense)
                    .filter { $0.amount > .zero }
                    .sorted { $0.currency < $1.currency }
            )
        case let .unavailable(issue):
            return .unavailable(issue)
        }
    }

    /// One validated hierarchy per base-currency/budget revision. Invalid
    /// trees are cached too, so every view in one render observes the same
    /// failure without repeating validation work.
    private func reportingBudgetTree(currency: CurrencyCode) throws -> BudgetTree {
        if let budgetTreeCache,
           budgetTreeCache.currency == currency,
           budgetTreeCache.revision == budgetNodesRevision {
            return try budgetTreeCache.result.get()
        }

        let result: Result<BudgetTree, Error>
        do {
            result = .success(try BudgetTree(currency: currency, nodes: budgetNodes))
        } catch {
            result = .failure(error)
        }
        budgetTreeCache = BudgetTreeCacheEntry(
            currency: currency,
            revision: budgetNodesRevision,
            result: result
        )
        budgetTreeCacheBuildCount += 1
        return try result.get()
    }

    private func reportingMonthStart(containing date: Date) throws -> Date {
        guard let start = reportingCalendar.dateInterval(of: .month, for: date)?.start else {
            throw AppModelError.invalidBook
        }
        return start
    }

    /// Builds the one-time prospective baseline for a legacy book. The
    /// earliest known rollover activation is retained so the pre-upgrade
    /// calculation remains unchanged until the first dated edit.
    private func inferredBudgetConfigurationTimeline(
        nodes: [BudgetNode],
        currency: CurrencyCode,
        asOf: Date
    ) throws -> BudgetConfigurationTimeline {
        let calendar = reportingCalendar
        let currentMonth = try reportingMonthStart(containing: asOf)
        let earliestActivation = nodes.compactMap { node -> Date? in
            guard node.rolloverRule != .none,
                  let startedAt = node.rolloverStartedAt else { return nil }
            return calendar.dateInterval(of: .month, for: startedAt)?.start
        }.min()
        return try BudgetConfigurationTimeline(
            currency: currency,
            revisions: [BudgetConfigurationRevision(
                effectiveMonth: earliestActivation ?? currentMonth,
                nodes: nodes
            )]
        )
    }

    private func validatedBudgetConfigurationTimeline(
        asOf: Date
    ) throws -> BudgetConfigurationTimeline {
        guard !budgetConfigurationTimelineInvalid,
              let currency = profile?.baseCurrency else {
            throw AppModelError.invalidBook
        }
        let timeline: BudgetConfigurationTimeline
        if let existing = budgetConfigurationTimeline {
            timeline = existing
        } else {
            timeline = try inferredBudgetConfigurationTimeline(
                nodes: budgetNodes,
                currency: currency,
                asOf: asOf
            )
        }
        guard timeline.currency == currency else { throw AppModelError.invalidBook }
        for revision in timeline.revisions {
            guard reportingCalendar.dateInterval(
                of: .month,
                for: revision.effectiveMonth
            )?.start == revision.effectiveMonth else {
                throw AppModelError.invalidBook
            }
        }
        let currentMonth = try reportingMonthStart(containing: asOf)
        let currentTree = try timeline.tree(effectiveAt: currentMonth)
        let timelineNodes = Dictionary(
            uniqueKeysWithValues: currentTree.nodes.map { ($0.id, $0) }
        )
        let loadedNodes = Dictionary(
            uniqueKeysWithValues: budgetNodes.map { ($0.id, $0) }
        )
        guard timelineNodes == loadedNodes else { throw AppModelError.invalidBook }
        return timeline
    }

    private func budgetConfigurationTimelineRecording(
        nodes: [BudgetNode],
        carryMappings: [BudgetCarryMapping] = [],
        asOf: Date? = nil
    ) throws -> BudgetConfigurationTimeline {
        let now = asOf ?? currentDate()
        let effectiveMonth = try reportingMonthStart(containing: now)
        let timeline = try validatedBudgetConfigurationTimeline(asOf: now)
        let existingOpeningCarry = timeline.revisions.first {
            $0.effectiveMonth == effectiveMonth
        }?.openingCarryByID
        let openingCarry: [UUID: Money]
        if let existingOpeningCarry {
            openingCarry = existingOpeningCarry
        } else {
            guard let currency = profile?.baseCurrency else {
                throw AppModelError.invalidBook
            }
            let currentTree = try reportingBudgetTree(currency: currency)
            openingCarry = try budgetRolloverSnapshot(
                tree: currentTree,
                timeline: timeline,
                asOf: effectiveMonth
            ).carryIn
        }
        return try timeline.recording(
            nodes: nodes,
            effectiveMonth: effectiveMonth,
            carryMappings: carryMappings,
            openingCarry: openingCarry
        )
    }

    private func budgetConfigurationTimelineWrite(
        _ timeline: BudgetConfigurationTimeline
    ) throws -> RecordWrite {
        try RecordWrite(
            timeline,
            id: BudgetConfigurationTimeline.primaryRecordID,
            in: .budgetConfigurationTimelines
        )
    }

    private func prepareBudgetConfigurationTimelineAfterLoad(
        in store: EncryptedRecordStore,
        persistsMigration: Bool
    ) async throws {
        guard let profile else {
            if budgetConfigurationTimeline != nil {
                budgetConfigurationTimelineInvalid = true
                recoveryIssues.append("budget_configuration_timelines/orphan-primary")
            }
            return
        }
        guard !budgetConfigurationTimelineInvalid else { return }

        if budgetConfigurationTimeline == nil {
            let migrated = try inferredBudgetConfigurationTimeline(
                nodes: budgetNodes,
                currency: profile.baseCurrency,
                asOf: currentDate()
            )
            if persistsMigration {
                // One generic-record upsert is a SQL transaction. If it fails,
                // startup fails rather than running rollover from an ephemeral
                // baseline that a restart could reinterpret. Rollback recovery
                // alone must preserve the exact pre-restore byte snapshot; its
                // next normal open can persist this inferred legacy baseline.
                try await store.upsert(
                    migrated,
                    id: BudgetConfigurationTimeline.primaryRecordID,
                    in: .budgetConfigurationTimelines
                )
            }
            budgetConfigurationTimeline = migrated
            return
        }

        do {
            let now = currentDate()
            let timeline = try validatedBudgetConfigurationTimeline(
                asOf: now
            )
            let month = try reportingMonthStart(containing: now)
            let currentTree = try timeline.tree(effectiveAt: month)
            let persistedByID = Dictionary(
                uniqueKeysWithValues: currentTree.nodes.map { ($0.id, $0) }
            )
            let loadedByID = Dictionary(
                uniqueKeysWithValues: budgetNodes.map { ($0.id, $0) }
            )
            guard persistedByID == loadedByID else {
                throw AppModelError.invalidBook
            }
        } catch {
            budgetConfigurationTimelineInvalid = true
            recoveryIssues.append("budget_configuration_timelines/inconsistent-primary")
        }
    }

    /// Persists one authoritative carry boundary per reporting month. After
    /// the first indexed replay in a month, recurring unlocks start at this
    /// checkpoint instead of walking the user's complete rollover history.
    private func persistCurrentMonthBudgetCheckpointIfNeeded(
        in store: EncryptedRecordStore,
        persistsCheckpoint: Bool
    ) async throws {
        guard persistsCheckpoint,
              recoveryIssues.isEmpty,
              !budgetConfigurationTimelineInvalid,
              let timeline = budgetConfigurationTimeline else { return }
        let now = currentDate()
        let currentMonth = try reportingMonthStart(containing: now)
        guard budgetRolloverReplayStart(
            timeline: timeline,
            currentMonthStart: currentMonth,
            calendar: reportingCalendar
        ) != nil,
        !timeline.revisions.contains(where: {
            $0.effectiveMonth == currentMonth && $0.openingCarry != nil
        }) else { return }

        let tree = try timeline.tree(effectiveAt: currentMonth)
        let carry = try budgetRolloverSnapshot(
            tree: tree,
            timeline: timeline,
            asOf: currentMonth
        ).carryIn
        let checkpointed = try timeline.recording(
            nodes: tree.nodes,
            effectiveMonth: currentMonth,
            openingCarry: carry
        )
        try await store.upsert(
            checkpointed,
            id: BudgetConfigurationTimeline.primaryRecordID,
            in: .budgetConfigurationTimelines
        )
        budgetConfigurationTimeline = checkpointed
    }

    /// A decodable attribution is still untrusted recovery input. Validate it
    /// against only its referenced live journal row, then apply the restore
    /// validator's exact posting/audited-remap rule. A failure preserves the
    /// encrypted records but disables budget projection for this session.
    private func validateBudgetEntryAttributionsAfterLoad(
        in store: EncryptedRecordStore
    ) async throws {
        guard !budgetConfigurationTimelineInvalid,
              !budgetEntryAttributions.isEmpty else { return }
        do {
            let generation = storeGeneration
            let recoveredEntries = try await store.fetchJournalEntriesRecovering(
                ids: Set(budgetEntryAttributions.keys)
            )
            guard ownsStoreGeneration(generation) else {
                throw AppModelError.locked
            }
            recordHistoryDecodeIssues(recoveredEntries.issues)
            let journalByID = Dictionary(
                uniqueKeysWithValues: recoveredEntries.values.map { ($0.id, $0) }
            )
            try await RestoreCandidateValidator.validateBudgetAttributionIntegrity(
                attributions: Array(budgetEntryAttributions.values),
                journalEntries: Array(journalByID.values),
                journalByID: journalByID,
                accountByID: Dictionary(
                    uniqueKeysWithValues: accounts.map { ($0.id, $0) }
                ),
                in: store
            )
            guard ownsStoreGeneration(generation) else {
                throw AppModelError.locked
            }
        } catch AppModelError.locked {
            throw AppModelError.locked
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            budgetConfigurationTimelineInvalid = true
            budgetEntryAttributions.removeAll()
            closedMonthBudgetProjection = nil
            recordRecoveryIssue(
                "budget_entry_attributions/inconsistent-history"
            )
        }
    }

    private func budgetEntryAttribution(
        for entryID: UUID,
        in store: EncryptedRecordStore
    ) async throws -> BudgetEntryAttribution? {
        if let cached = budgetEntryAttributions[entryID] { return cached }
        let attribution = try await store.fetch(
            BudgetEntryAttribution.self,
            id: entryID.uuidString,
            from: .budgetEntryAttributions
        )
        guard attribution?.id == entryID || attribution == nil else {
            throw AppModelError.invalidBook
        }
        if let attribution { budgetEntryAttributions[entryID] = attribution }
        return attribution
    }

    /// Full attribution materialization is reserved for explicit operations
    /// that already need complete historical journal replay (for example a
    /// backdated mutation before a persisted checkpoint). Normal startup and
    /// month-to-month projection stay on the normalized SQL index.
    private func loadCompleteBudgetAttributionCacheIfNeeded(
        from store: EncryptedRecordStore
    ) async throws {
        guard !budgetAttributionCacheIsComplete else { return }
        let recovered = try await store.fetchAllIdentifiedRecovering(
            BudgetEntryAttribution.self,
            from: .budgetEntryAttributions
        )
        guard recovered.issues.isEmpty else { throw AppModelError.invalidBook }
        let values = try quarantiningDuplicateLogicalIDs(
            recovered.values,
            in: .budgetEntryAttributions,
            observesCancellation: true
        )
        guard values.count == recovered.values.count else {
            throw AppModelError.invalidBook
        }
        budgetEntryAttributions = Dictionary(
            uniqueKeysWithValues: values.map { ($0.id, $0) }
        )
        budgetAttributionCacheIsComplete = true
    }

    func budgetPurposeOverview() -> BudgetPurposeOverview {
        guard let currency = profile?.baseCurrency,
              let tree = try? reportingBudgetTree(currency: currency) else {
            return BudgetPurposeOverview(effectivePurposeByID: [:], reviewCount: 0)
        }
        return BudgetPurposeOverview(
            effectivePurposeByID: Dictionary(
                uniqueKeysWithValues: budgetNodes.map {
                    ($0.id, tree.effectivePurpose(for: $0.id))
                }
            ),
            reviewCount: tree.limitedNodesNeedingPurpose.count
        )
    }

    private func currentBudgetRolloverSnapshot(
        tree: BudgetTree,
        asOf requestedDate: Date? = nil
    ) throws -> BudgetRolloverSnapshot {
        let asOf = requestedDate ?? currentDate()
        let timeline = try validatedBudgetConfigurationTimeline(asOf: asOf)
        return try budgetRolloverSnapshot(
            tree: tree,
            timeline: timeline,
            asOf: asOf
        )
    }

    private func budgetRolloverSnapshot(
        tree: BudgetTree,
        timeline: BudgetConfigurationTimeline,
        asOf: Date,
        journalEntries: [JournalEntry]? = nil,
        attributions: [UUID: BudgetEntryAttribution]? = nil
    ) throws -> BudgetRolloverSnapshot {
        let calendar = reportingCalendar
        guard let currentMonth = calendar.dateInterval(of: .month, for: asOf) else {
            throw AppModelError.invalidBook
        }
        guard let replayStart = budgetRolloverReplayStart(
            timeline: timeline,
            currentMonthStart: currentMonth.start,
            calendar: calendar
        ) else {
            return try BudgetRolloverEngine.snapshot(
                tree: tree,
                monthlySpending: [],
                asOf: asOf,
                calendar: calendar
            )
        }

        let rawPeriods: [MonthlyBudgetSpending]
        if let journalEntries {
            rawPeriods = try closedMonthBudgetSpending(
                entries: journalEntries,
                attributions: attributions ?? budgetEntryAttributions,
                currency: tree.currency,
                replayStart: replayStart,
                currentMonthStart: currentMonth.start,
                calendar: calendar,
                excludingEntryIDs: invalidJournalEntryIDs
            )
        } else if retainsCompleteJournal {
            rawPeriods = try closedMonthBudgetSpending(
                entries: entries,
                attributions: budgetEntryAttributions,
                currency: tree.currency,
                replayStart: replayStart,
                currentMonthStart: currentMonth.start,
                calendar: calendar,
                excludingEntryIDs: invalidJournalEntryIDs
            )
        } else {
            guard let projection = closedMonthBudgetProjection,
                  projection.reportingTimeZoneIdentifier
                    == calendar.timeZone.identifier,
                  projection.currentMonthStart == currentMonth.start,
                  projection.coverageStart <= replayStart,
                  projection.currency == tree.currency else {
                // Never substitute the deliberately bounded recent-entry UI
                // cache. Make the result unavailable until the complete SQL
                // projection for the new boundary has published.
                scheduleJournalDerivedRefresh()
                throw AppModelError.invalidBook
            }
            rawPeriods = projection.monthlySpending
        }

        let periods = rawPeriods.compactMap { period -> MonthlyBudgetSpending? in
            guard FinancialPeriodBoundary.contains(
                period.monthStart,
                start: replayStart,
                endExclusive: currentMonth.start
            ) else { return nil }
            // A backdated recategorization can target a category created only
            // in a later revision. It is honestly unbudgeted in the earlier
            // month, so filter the raw compact projection through that month's
            // historical tree before rollover consumes it.
            let validIDs = Set(
                timeline.revision(effectiveAt: period.monthStart).nodes.map(\.id)
            )
            return MonthlyBudgetSpending(
                monthStart: period.monthStart,
                directSpending: period.directSpending.filter {
                    validIDs.contains($0.key) && $0.value.currency == tree.currency
                }
            )
        }
        return try BudgetRolloverEngine.snapshot(
            timeline: timeline,
            monthlySpending: periods,
            asOf: asOf,
            calendar: calendar
        )
    }

    private func budgetRolloverReplayStart(
        timeline: BudgetConfigurationTimeline,
        currentMonthStart: Date,
        calendar: Calendar
    ) -> Date? {
        let activation = timeline.revisions.flatMap(\.nodes).compactMap {
            node -> Date? in
            guard node.rolloverRule != .none,
                  let startedAt = node.rolloverStartedAt else { return nil }
            return calendar.dateInterval(of: .month, for: startedAt)?.start
        }.min()
        let latestCheckpoint = timeline.revisions.last {
            $0.effectiveMonth <= currentMonthStart && $0.openingCarry != nil
        }
        return latestCheckpoint?.effectiveMonth ?? activation
    }

    private func closedMonthBudgetSpending(
        entries sourceEntries: [JournalEntry],
        attributions: [UUID: BudgetEntryAttribution],
        currency: CurrencyCode,
        replayStart: Date,
        currentMonthStart: Date,
        calendar: Calendar,
        excludingEntryIDs: Set<UUID>
    ) throws -> [MonthlyBudgetSpending] {
        var amountsByMonth: [Date: [UUID: Decimal]] = [:]
        for entry in sourceEntries where !excludingEntryIDs.contains(entry.id) {
            let attribution = attributions[entry.id]
            let attributedDate: Date
            if let attribution {
                guard let date = attribution.attributedDate(in: calendar) else {
                    throw AppModelError.invalidBook
                }
                attributedDate = date
            } else {
                attributedDate = entry.occurredAt
            }
            try accumulateClosedMonthBudgetPostings(
                attribution?.postings ?? entry.postings,
                attributedDate: attributedDate,
                currency: currency,
                replayStart: replayStart,
                currentMonthStart: currentMonthStart,
                calendar: calendar,
                amountsByMonth: &amountsByMonth
            )
        }
        return try makeMonthlyBudgetSpending(
            amountsByMonth,
            currency: currency
        )
    }

    private func closedMonthBudgetSpending(
        events: [LedgerPostingEvent],
        attributions: [UUID: BudgetEntryAttribution],
        currency: CurrencyCode,
        replayStart: Date,
        currentMonthStart: Date,
        calendar: Calendar,
        excludingEntryIDs: Set<UUID>
    ) throws -> [MonthlyBudgetSpending] {
        var amountsByMonth: [Date: [UUID: Decimal]] = [:]
        let attributedEntryIDs = Set(attributions.keys)
        for (entryID, attribution) in attributions
            where !excludingEntryIDs.contains(entryID) {
            guard let attributedDate = attribution.attributedDate(in: calendar) else {
                throw AppModelError.invalidBook
            }
            try accumulateClosedMonthBudgetPostings(
                attribution.postings,
                attributedDate: attributedDate,
                currency: currency,
                replayStart: replayStart,
                currentMonthStart: currentMonthStart,
                calendar: calendar,
                amountsByMonth: &amountsByMonth
            )
        }
        for event in events where !attributedEntryIDs.contains(event.entryID)
            && !excludingEntryIDs.contains(event.entryID) {
            guard let attributedDate = event.attributedDate(in: calendar) else {
                throw AppModelError.invalidBook
            }
            try accumulateClosedMonthBudgetPostings(
                [event.posting],
                attributedDate: attributedDate,
                currency: currency,
                replayStart: replayStart,
                currentMonthStart: currentMonthStart,
                calendar: calendar,
                amountsByMonth: &amountsByMonth
            )
        }
        return try makeMonthlyBudgetSpending(
            amountsByMonth,
            currency: currency
        )
    }

    private func accumulateClosedMonthBudgetPostings(
        _ postings: [Posting],
        attributedDate: Date,
        currency: CurrencyCode,
        replayStart: Date,
        currentMonthStart: Date,
        calendar: Calendar,
        amountsByMonth: inout [Date: [UUID: Decimal]]
    ) throws {
        guard FinancialPeriodBoundary.contains(
            attributedDate,
            start: replayStart,
            endExclusive: currentMonthStart
        ), let month = calendar.dateInterval(
            of: .month,
            for: attributedDate
        )?.start else { return }
        for posting in postings where posting.money.currency == currency {
            let prior = amountsByMonth[month]?[posting.accountID] ?? .zero
            do {
                amountsByMonth[month, default: [:]][posting.accountID] =
                    try CheckedDecimal.adding(prior, posting.money.amount)
            } catch {
                throw AppModelError.invalidBook
            }
        }
    }

    private func makeMonthlyBudgetSpending(
        _ amountsByMonth: [Date: [UUID: Decimal]],
        currency: CurrencyCode
    ) throws -> [MonthlyBudgetSpending] {
        try amountsByMonth.keys.sorted().map { month in
            MonthlyBudgetSpending(
                monthStart: month,
                directSpending: try amountsByMonth[month, default: [:]].reduce(
                    into: [UUID: Money]()
                ) { result, item in
                    guard item.value != .zero else { return }
                    result[item.key] = try Money(item.value, currency: currency)
                }
            )
        }
    }

    /// Rebuilds only derived opening-carry checkpoints after a backdated
    /// journal mutation. Configuration revisions remain immutable; preserved
    /// attribution lets replay use the category IDs that existed before a
    /// lifecycle merge rewrote the live journal.
    private func budgetTimelineRecomputingOpeningCarries(
        _ timeline: BudgetConfigurationTimeline,
        journalEntries: [JournalEntry],
        attributions: [UUID: BudgetEntryAttribution]
    ) throws -> BudgetConfigurationTimeline {
        var revisions = timeline.revisions
        for index in revisions.indices where revisions[index].openingCarry != nil {
            let revision = revisions[index]
            let openingCarry: [UUID: Money]
            if index == revisions.startIndex {
                openingCarry = [:]
            } else {
                let priorTimeline = try BudgetConfigurationTimeline(
                    currency: timeline.currency,
                    revisions: Array(revisions[..<index])
                )
                let priorTree = try priorTimeline.tree(
                    effectiveAt: revision.effectiveMonth
                )
                openingCarry = try budgetRolloverSnapshot(
                    tree: priorTree,
                    timeline: priorTimeline,
                    asOf: revision.effectiveMonth,
                    journalEntries: journalEntries,
                    attributions: attributions
                ).carryIn
            }
            revisions[index] = BudgetConfigurationRevision(
                id: revision.id,
                effectiveMonth: revision.effectiveMonth,
                nodes: revision.nodes,
                carryMappings: revision.carryMappings,
                openingCarry: openingCarry
            )
        }
        return try BudgetConfigurationTimeline(
            currency: timeline.currency,
            revisions: revisions
        )
    }

    private func budgetTimelineAfterJournalMutation(
        timeline candidateTimeline: BudgetConfigurationTimeline? = nil,
        journalEntries: [JournalEntry],
        attributions: [UUID: BudgetEntryAttribution],
        affectedReportingMonths: [Date]
    ) throws -> BudgetConfigurationTimeline? {
        guard !budgetConfigurationTimelineInvalid,
              let earliestAffected = affectedReportingMonths.min(),
              let timeline = candidateTimeline ?? budgetConfigurationTimeline,
              timeline.revisions.contains(where: {
                  $0.openingCarry != nil && earliestAffected < $0.effectiveMonth
              }) else {
            return nil
        }
        return try budgetTimelineRecomputingOpeningCarries(
            timeline,
            journalEntries: journalEntries,
            attributions: attributions
        )
    }

    private func budgetCheckpointNeedsJournalReplay(
        timeline candidateTimeline: BudgetConfigurationTimeline? = nil,
        affectedReportingMonths: [Date]
    ) -> Bool {
        !budgetConfigurationTimelineInvalid
            && laterBudgetCheckpointExists(
                timeline: candidateTimeline,
                affectedReportingMonths: affectedReportingMonths
            )
    }

    private func laterBudgetCheckpointExists(
        timeline candidateTimeline: BudgetConfigurationTimeline? = nil,
        affectedReportingMonths: [Date]
    ) -> Bool {
        guard let earliestAffected = affectedReportingMonths.min(),
              let timeline = candidateTimeline ?? budgetConfigurationTimeline else {
            return false
        }
        return timeline.revisions.contains {
            $0.openingCarry != nil && earliestAffected < $0.effectiveMonth
        }
    }

    /// Retained mode still needs a candidate array for its in-memory journal.
    /// Lazy mode materializes the complete journal only when a later persisted
    /// opening carry can actually change.
    private func journalEntriesForBudgetMutation(
        from journalStore: EncryptedRecordStore,
        affectedReportingMonths: [Date]
    ) async throws -> [JournalEntry]? {
        if budgetConfigurationTimelineInvalid,
           laterBudgetCheckpointExists(
               affectedReportingMonths: affectedReportingMonths
           ) {
            // Saving without replay would make a persisted checkpoint silently
            // stale after the quarantined budget data is repaired.
            throw AppModelError.invalidBook
        }
        if retainsCompleteJournal { return entries }
        guard budgetCheckpointNeedsJournalReplay(
            affectedReportingMonths: affectedReportingMonths
        ) else {
            return nil
        }

        try await loadCompleteBudgetAttributionCacheIfNeeded(
            from: journalStore
        )
        budgetJournalReplayReadCount += 1
        let generation = storeGeneration
        let recovered = try await journalStore.fetchAllIdentifiedRecovering(
            JournalEntry.self,
            from: .journalEntries
        )
        guard ownsStoreGeneration(generation) else { throw AppModelError.locked }
        recordHistoryDecodeIssues(recovered.issues)
        guard Set(recovered.values.map(\.id)).count == recovered.values.count else {
            recordRecoveryIssue("journal_entries/duplicate-logical-identity")
            throw AppModelError.invalidBook
        }

        let malformedIDs = Set(recovered.issues.compactMap {
            UUID(uuidString: $0.recordID)
        })
        let validAccountIDs = Set(accounts.map(\.id))
        let expectedAccountCurrencies = Dictionary(
            uniqueKeysWithValues: accounts.compactMap { account in
                account.currency.map { (account.id, $0) }
            }
        )
        var newlyQuarantined = Set<UUID>()
        for entry in recovered.values where !invalidJournalEntryIDs.contains(entry.id) {
            let isValid = entry.postings.allSatisfy { posting in
                guard validAccountIDs.contains(posting.accountID) else { return false }
                return expectedAccountCurrencies[posting.accountID].map {
                    $0 == posting.money.currency
                } ?? true
            }
            if !isValid { newlyQuarantined.insert(entry.id) }
        }
        if !newlyQuarantined.isEmpty {
            invalidJournalEntryIDs.formUnion(newlyQuarantined)
            recordHistoryDecodeIssues(newlyQuarantined.map {
                RecordDecodeIssue(
                    collection: .journalEntries,
                    recordID: $0.uuidString
                )
            })
        }
        let excludedIDs = invalidJournalEntryIDs.union(malformedIDs)
        return recovered.values.filter { !excludedIDs.contains($0.id) }
    }

    private func budgetAffectedMonth(
        for entry: JournalEntry,
        attribution: BudgetEntryAttribution?,
        timeline candidateTimeline: BudgetConfigurationTimeline? = nil
    ) throws -> Date? {
        let timeline = candidateTimeline ?? budgetConfigurationTimeline
        guard let timeline else { return nil }
        let budgetIDs = Set(timeline.revisions.flatMap(\.nodes).map(\.id))
        let postings = attribution?.postings ?? entry.postings
        guard postings.contains(where: { budgetIDs.contains($0.accountID) }) else {
            return nil
        }
        let date: Date
        if let attribution {
            guard let attributedDate = attribution.attributedDate(
                in: reportingCalendar
            ) else { throw AppModelError.invalidBook }
            date = attributedDate
        } else {
            date = entry.occurredAt
        }
        guard let month = reportingCalendar.dateInterval(
            of: .month,
            for: date
        )?.start else {
            throw AppModelError.invalidBook
        }
        return month
    }

    func budgetProgressThisMonthResult() -> DerivedValue<[BudgetProgress]> {
        guard let currency = profile?.baseCurrency else {
            return .unavailable(.appNotReady)
        }
        do {
            let tree = try reportingBudgetTree(currency: currency)
            let rollover = try currentBudgetRolloverSnapshot(tree: tree)
            switch spendingThisMonthResult() {
            case let .available(spending):
                return .available(try tree.progress(
                    directSpending: spendingRepresented(in: tree, from: spending),
                    effectiveLimits: rollover.effectiveLimits
                ))
            case let .unavailable(issue):
                return .unavailable(issue)
            }
        } catch {
            DerivedValueDiagnostics.record(
                .budgetCalculationFailed,
                operation: "budget-progress",
                error: error
            )
            return .unavailable(.budgetCalculationFailed)
        }
    }

    func budgetPlanSummaryThisMonthResult() -> DerivedValue<BudgetPlanSummary?> {
        guard let currency = profile?.baseCurrency else {
            return .unavailable(.appNotReady)
        }
        do {
            let tree = try reportingBudgetTree(currency: currency)
            let rollover = try currentBudgetRolloverSnapshot(tree: tree)
            switch spendingThisMonthResult() {
            case let .available(spending):
                return .available(try tree.planSummary(
                    directSpending: spendingRepresented(in: tree, from: spending),
                    effectiveLimits: rollover.effectiveLimits
                ))
            case let .unavailable(issue):
                return .unavailable(issue)
            }
        } catch {
            DerivedValueDiagnostics.record(
                .budgetCalculationFailed,
                operation: "budget-summary",
                error: error
            )
            return .unavailable(.budgetCalculationFailed)
        }
    }

    func flexibleTodayResult(asOf date: Date = Date()) -> DerivedValue<FlexibleTodayStatus> {
        guard let currency = profile?.baseCurrency else {
            return .unavailable(.appNotReady)
        }
        let spending: [UUID: Money]
        switch spendingThisMonthResult() {
        case let .available(values):
            spending = values
        case let .unavailable(issue):
            return .unavailable(issue)
        }
        let foreignSpending: [Money]
        switch excludedForeignSpendingThisMonthResult() {
        case let .available(values):
            foreignSpending = values
        case let .unavailable(issue):
            return .unavailable(issue)
        }

        do {
            let tree = try reportingBudgetTree(currency: currency)
            let rollover = try currentBudgetRolloverSnapshot(tree: tree)
            let representedSpending = spendingRepresented(in: tree, from: spending)
            guard try tree.planSummary(
                directSpending: representedSpending,
                effectiveLimits: rollover.effectiveLimits
            ) != nil else {
                return .available(.needsBudget)
            }
            let unclassifiedCount = tree.limitedNodesNeedingPurpose.count
            guard unclassifiedCount == 0 else {
                return .available(.needsClassification(count: unclassifiedCount))
            }
            guard let flexibleSummary = try tree.planSummary(
                directSpending: representedSpending,
                purpose: .flexible,
                effectiveLimits: rollover.effectiveLimits
            ) else {
                return .available(.needsFlexibleBudget)
            }
            guard let breakdown = try FinanceCalculator.flexibleToday(
                flexibleBudgetRemaining: flexibleSummary.remaining,
                schedules: scheduledTransactions,
                flexibleCategoryIDs: tree.categoryIDs(governedBy: .flexible),
                excludedForeignSpending: foreignSpending,
                asOf: date,
                calendar: reportingCalendar
            ) else {
                return .unavailable(.invalidPeriod)
            }
            return .available(.available(breakdown))
        } catch {
            DerivedValueDiagnostics.record(
                .budgetCalculationFailed,
                operation: "flexible-today",
                error: error
            )
            return .unavailable(.budgetCalculationFailed)
        }
    }

    /// An expense account can legitimately exist without a configured budget
    /// node (for example after an older-book migration). Such spending remains
    /// unbudgeted; it must not make every configured budget unavailable through
    /// `BudgetTreeError.unknownSpendingNode`.
    private func spendingRepresented(
        in tree: BudgetTree,
        from spending: [UUID: Money]
    ) -> [UUID: Money] {
        let representedIDs = Set(tree.nodes.map(\.id))
        return spending.filter { representedIDs.contains($0.key) }
    }

    /// Compares equal elapsed portions of this month and the prior month.
    /// A full prior month against a partial current month would produce a
    /// dramatic but misleading “spending down” sentence early in the month.
    func monthToDateExpenseComparisonResult() -> DerivedValue<MonthToDateExpenseComparison> {
        let calendar = reportingCalendar
        let now = Date()
        let today = calendar.startOfDay(for: now)
        if monthToDateComparisonCacheDay == today,
           let cached = monthToDateComparisonCache {
            return cached
        }

        guard retainsCompleteJournal else {
            scheduleJournalDerivedRefresh()
            return .unavailable(.appNotReady)
        }

        guard let currency = profile?.baseCurrency else {
            return .unavailable(.appNotReady)
        }
        guard let intervals = MonthToDateComparisonIntervals(
            containing: now,
            calendar: calendar
        ) else {
            DerivedValueDiagnostics.record(
                .invalidPeriod,
                operation: "month-to-date-interval"
            )
            return .unavailable(.invalidPeriod)
        }

        let result: DerivedValue<MonthToDateExpenseComparison>
        do {
            let currentReport = try FinanceCalculator.report(
                interval: intervals.current,
                accounts: accounts,
                entries: entries,
                baseCurrency: currency,
                calendar: calendar
            )
            let previousReport = try FinanceCalculator.report(
                interval: intervals.previous,
                accounts: accounts,
                entries: entries,
                baseCurrency: currency,
                calendar: calendar
            )
            result = .available(
                MonthToDateExpenseComparison(
                    previous: previousReport.baseFlow.expense,
                    current: currentReport.baseFlow.expense,
                    holdsUnconvertedActivity: currentReport.holdsUnconvertedActivity
                        || previousReport.holdsUnconvertedActivity
                )
            )
        } catch {
            DerivedValueDiagnostics.record(
                .ledgerCalculationFailed,
                operation: "month-to-date-comparison",
                error: error
            )
            result = .unavailable(.ledgerCalculationFailed)
        }
        monthToDateComparisonCache = result
        monthToDateComparisonCacheDay = today
        return result
    }

    func csvExport() async throws -> String {
        try beginJournalMutation(invalidatesJournalProjection: false)
        defer { endJournalMutation() }
        let exportEntries: [JournalEntry]
        if retainsCompleteJournal {
            exportEntries = entries
        } else {
            exportEntries = try await journalSnapshot(
                includeInvalidRelationships: false
            )
        }
        return LedgerCSVExporter.export(
            exportEntries.sorted { $0.occurredAt < $1.occurredAt },
            accounts: accounts
        )
    }

    func xlsxExport() async throws -> Data {
        try beginJournalMutation(invalidatesJournalProjection: false)
        defer { endJournalMutation() }
        let exportEntries: [JournalEntry]
        if retainsCompleteJournal {
            exportEntries = entries
        } else {
            exportEntries = try await journalSnapshot(
                includeInvalidRelationships: false
            )
        }
        return LedgerXLSXExporter.export(
            entries: exportEntries,
            accounts: accounts,
            rates: exchangeRates,
            attachmentMetadata: receiptAttachmentMetadata
        )
    }

    /// Produces a coherent, metadata-only manifest for upgrade and restore drills.
    /// The exclusive lifecycle guard prevents a write from crossing the single
    /// payload-free count snapshot used by the inventory.
    func privacySafeDataInventory(
        generatedAt: Date? = nil,
        appVersion: String = AppVersion.marketing,
        buildNumber: String = AppVersion.build
    ) async throws -> PrivacySafeDataInventory {
        guard state == .ready else { throw AppModelError.locked }
        try beginLifecycleMutation(invalidatesJournalProjection: false)
        isWorking = true
        defer {
            isWorking = false
            endLifecycleMutation()
        }

        await finishPendingQuickLogDraftWrite()
        try Task.checkCancellation()
        let inventoryStore = try requireStore()
        let snapshot = try await inventoryStore.recordCountSnapshot()
        try Task.checkCancellation()
        let pendingLockedCaptures = try await lockedCaptureStore.all()
        let currentPendingLockedCaptureCount = pendingLockedCaptures.count
        pendingLockedCaptureCount = currentPendingLockedCaptureCount
        try Task.checkCancellation()
        return PrivacySafeDataInventory(
            snapshot: snapshot,
            investmentHoldings: investmentHoldings,
            savingsGoals: savingsGoals,
            generatedAt: generatedAt,
            appVersion: appVersion,
            buildNumber: buildNumber,
            pendingLockedCaptureCount: currentPendingLockedCaptureCount,
            quarantinedRecordCount: recoveryIssueCount,
            budgetStatusWidgetEnabled: profile?.showsBudgetStatusWidget ?? false
        )
    }

    /// Resolves a parsed CSV preview against the current book, then commits
    /// every new category, FX helper, and journal entry together. A failure
    /// therefore imports either all accepted rows or none of them.
    func importTransactions(
        _ rows: [ImportedTransaction],
        fallbackAccountID: UUID,
        fallbackExpenseCategoryID: UUID,
        fallbackIncomeCategoryID: UUID,
        accountMappings: [String: UUID] = [:],
        expenseCategoryMappings: [String: UUID] = [:],
        incomeCategoryMappings: [String: UUID] = [:],
        sourceSystem: String = "CSV/Qianji"
    ) async throws -> TransactionImportResult {
        try beginStandaloneJournalMutation()
        defer { endStandaloneJournalMutation() }
        guard rows.count <= MonetaryInputPolicy.aggregateRecordBudget else {
            throw AppModelError.importTooLarge
        }
        guard let fallbackAccount = userAccounts.first(where: {
            $0.id == fallbackAccountID
        }), expenseCategories.contains(where: {
            $0.id == fallbackExpenseCategoryID && $0.systemRole == nil
        }), incomeCategories.contains(where: {
            $0.id == fallbackIncomeCategoryID && $0.systemRole == nil
        }) else { throw AppModelError.missingRecord }
        let canonicalImportSource = TransactionCSVImporter.canonicalSourceSystem(
            sourceSystem
        )
        let existingEntries: [JournalEntry]
        let existingFingerprints: Set<String>
        if retainsCompleteJournal {
            existingEntries = entries
            existingFingerprints = Set(entries.compactMap(\.sourceFingerprint))
        } else {
            // Import is an explicit heavy operation. Fetch one encrypted
            // snapshot for semantic keys and read the compact source index so even
            // quarantined valid JSON remains a global fingerprint duplicate.
            existingEntries = try await journalSnapshot(
                includeInvalidRelationships: true
            )
            existingFingerprints = try await requireStore().journalSourceFingerprints()
        }

        func normalizedName(_ value: String) -> String {
            CSVImportNameResolver.normalizedKey(for: value)
        }

        let sameSourceLegacyFingerprints: Set<String> = Set(
            existingEntries.compactMap { entry -> String? in
                guard TransactionCSVImporter.canonicalSourceSystem(
                    entry.sourceSystem ?? ""
                ) == canonicalImportSource else {
                    return nil
                }
                return entry.sourceFingerprint
            }
        )

        var candidateAccounts = accounts
        var newAccounts: [LedgerAccount] = []
        var newBudgetNodes: [BudgetNode] = []
        var importedEntries: [JournalEntry] = []
        var fingerprints = existingFingerprints
        var duplicates = 0
        var skipped = 0
        let initialAccountKinds = Dictionary(
            uniqueKeysWithValues: accounts.map { ($0.id, $0.kind) }
        )

        func duplicateKey(
            kind: ImportedTransactionKind,
            occurredAt: Date,
            amount: Decimal,
            currency: CurrencyCode,
            sourceID: UUID,
            destinationID: UUID? = nil,
            destinationAmount: Decimal? = nil,
            destinationCurrency: CurrencyCode? = nil,
            payee: String?
        ) -> String {
            let components = [
                kind.rawValue,
                String(Int64(occurredAt.timeIntervalSince1970.rounded(.down))),
                NSDecimalNumber(decimal: amount).stringValue,
                currency.value,
                sourceID.uuidString.lowercased(),
                destinationID?.uuidString.lowercased() ?? "",
                destinationAmount.map {
                    NSDecimalNumber(decimal: $0).stringValue
                } ?? "",
                destinationCurrency?.value ?? "",
                normalizedName(payee ?? "")
            ]
            return components.map { "\($0.utf8.count):\($0)" }.joined()
        }

        func duplicateKey(for entry: JournalEntry) -> String? {
            let userPosting: Posting?
            let amountPosting: Posting?
            let destinationPosting: Posting?
            let kind: ImportedTransactionKind?
            switch entry.kind {
            case .expense:
                userPosting = entry.postings.first {
                    initialAccountKinds[$0.accountID] == .asset
                        || initialAccountKinds[$0.accountID] == .liability
                }
                amountPosting = entry.postings.first {
                    initialAccountKinds[$0.accountID] == .expense
                } ?? entry.postings.first { $0.id != userPosting?.id }
                destinationPosting = nil
                kind = (amountPosting?.money.amount ?? .zero) < .zero
                    ? .refund : .expense
            case .income:
                userPosting = entry.postings.first {
                    initialAccountKinds[$0.accountID] == .asset
                        || initialAccountKinds[$0.accountID] == .liability
                }
                amountPosting = entry.postings.first {
                    initialAccountKinds[$0.accountID] == .income
                } ?? entry.postings.first { $0.id != userPosting?.id }
                destinationPosting = nil
                kind = .income
            case .transfer:
                let userPostings = entry.postings.filter {
                    initialAccountKinds[$0.accountID] == .asset
                        || initialAccountKinds[$0.accountID] == .liability
                }
                let sourcePostings = userPostings.filter { $0.money.amount < .zero }
                let destinationPostings = userPostings.filter { $0.money.amount > .zero }
                guard sourcePostings.count == 1,
                      destinationPostings.count == 1 else {
                    return nil
                }
                userPosting = sourcePostings[0]
                amountPosting = userPosting
                destinationPosting = destinationPostings[0]
                kind = .transfer
            case .adjustment, .investment:
                return nil
            }
            guard let userPosting, let amountPosting, let kind else { return nil }
            if kind == .transfer, destinationPosting == nil { return nil }
            return duplicateKey(
                kind: kind,
                occurredAt: entry.occurredAt,
                amount: abs(amountPosting.money.amount),
                currency: amountPosting.money.currency,
                sourceID: userPosting.accountID,
                destinationID: destinationPosting?.accountID,
                destinationAmount: destinationPosting.map { abs($0.money.amount) },
                destinationCurrency: destinationPosting?.money.currency,
                payee: entry.payee
            )
        }

        var duplicateKeys = Set(existingEntries.compactMap { duplicateKey(for: $0) })

        func isEligibleImportAccount(
            _ account: LedgerAccount,
            currency: CurrencyCode?
        ) -> Bool {
            (account.kind == .asset || account.kind == .liability)
                && account.systemRole == nil
                && !account.isArchived
                && (currency == nil || account.currency == currency)
        }

        func isEligibleImportCategory(
            _ account: LedgerAccount,
            kind: LedgerAccountKind
        ) -> Bool {
            account.kind == kind
                && account.systemRole == nil
                && !account.isArchived
        }

        func account(named name: String?, currency: CurrencyCode?) -> LedgerAccount? {
            guard let name else { return nil }
            let normalized = normalizedName(name)
            if let mappedID = accountMappings[normalized],
               let mapped = candidateAccounts.first(where: {
                   $0.id == mappedID && isEligibleImportAccount($0, currency: currency)
               }) {
                return mapped
            }
            return candidateAccounts.first {
                isEligibleImportAccount($0, currency: currency)
                    && normalizedName($0.name) == normalized
            }
        }

        func category(
            named name: String?,
            kind: LedgerAccountKind,
            fallbackID: UUID
        ) -> LedgerAccount? {
            guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return candidateAccounts.first {
                    $0.id == fallbackID && isEligibleImportCategory($0, kind: kind)
                }
            }
            let normalized = normalizedName(name)
            let reviewedMappings = kind == .income
                ? incomeCategoryMappings
                : expenseCategoryMappings
            if let mappedID = reviewedMappings[normalized],
               let mapped = candidateAccounts.first(where: {
                   $0.id == mappedID && isEligibleImportCategory($0, kind: kind)
               }) {
                return mapped
            }
            if let existing = candidateAccounts.first(where: {
                isEligibleImportCategory($0, kind: kind)
                    && normalizedName($0.name) == normalized
            }) {
                return existing
            }
            let created = LedgerAccount(name: name, kind: kind)
            candidateAccounts.append(created)
            newAccounts.append(created)
            if kind == .expense {
                newBudgetNodes.append(BudgetNode(id: created.id, name: created.name))
            }
            return created
        }

        func candidateForeignExchangeAccount(
            for currency: CurrencyCode
        ) -> LedgerAccount {
            candidateAccounts.first {
                $0.systemRole == .foreignExchange && $0.currency == currency
            } ?? LedgerAccount(
                name: "\(String(localized: "account.fx_clearing")) \(currency.value)",
                kind: .trading,
                currency: currency,
                systemRole: .foreignExchange
            )
        }

        for row in rows {
            let persistedFingerprint = TransactionCSVImporter.persistenceFingerprint(
                for: row.id,
                sourceSystem: sourceSystem
            )
            let insertedFingerprint = fingerprints.insert(persistedFingerprint).inserted
            let matchesUnscopedIdentity = sameSourceLegacyFingerprints.contains(row.id)
            let matchesLegacyCandidate = !row.legacyFingerprintCandidates.isDisjoint(
                with: sameSourceLegacyFingerprints
            )
            guard insertedFingerprint, !matchesUnscopedIdentity else {
                if insertedFingerprint {
                    fingerprints.remove(persistedFingerprint)
                }
                duplicates += 1
                continue
            }
            let declaredCurrency = row.currencyCode.flatMap { try? CurrencyCode($0) }
            if row.currencyCode != nil, declaredCurrency == nil {
                fingerprints.remove(persistedFingerprint)
                skipped += 1
                continue
            }
            let source = account(named: row.accountName, currency: declaredCurrency)
                ?? (declaredCurrency == nil || declaredCurrency == fallbackAccount.currency
                    ? fallbackAccount
                    : nil)
            guard let source, let sourceCurrency = source.currency,
                  MonetaryInputPolicy.accepts(
                    row.amount,
                    currency: sourceCurrency
                  ) else {
                fingerprints.remove(persistedFingerprint)
                skipped += 1
                continue
            }
            let transferDestination: LedgerAccount?
            let semanticDestinationAmount: Decimal?
            if row.kind == .transfer {
                guard let destination = account(
                    named: row.destinationAccountName,
                    currency: nil
                ), destination.id != source.id,
                let destinationCurrency = destination.currency else {
                    fingerprints.remove(persistedFingerprint)
                    skipped += 1
                    continue
                }
                let destinationAmount: Decimal? = sourceCurrency == destinationCurrency
                    ? row.amount
                    : row.destinationAmount
                guard let destinationAmount,
                      MonetaryInputPolicy.accepts(
                        destinationAmount,
                        currency: destinationCurrency
                      ) else {
                    fingerprints.remove(persistedFingerprint)
                    skipped += 1
                    continue
                }
                transferDestination = destination
                semanticDestinationAmount = destinationAmount
            } else {
                transferDestination = nil
                semanticDestinationAmount = nil
            }
            let rowDuplicateKey = duplicateKey(
                kind: row.kind,
                occurredAt: row.occurredAt,
                amount: row.amount,
                currency: sourceCurrency,
                sourceID: source.id,
                destinationID: transferDestination?.id,
                destinationAmount: semanticDestinationAmount,
                destinationCurrency: transferDestination?.currency,
                // Transfer factories do not persist a payee. Build the key
                // from the shape that can be reconstructed after reopening.
                payee: row.kind == .transfer ? nil : row.payee
            )
            let insertedSemanticKey = duplicateKeys.insert(rowDuplicateKey).inserted
            // FNV-era candidates are collision-prone and interim SHA candidates
            // contain mutable fields. Treat either as a legacy duplicate only
            // when the reconstructed ledger semantics also match. A prior
            // unscoped exact row identity was handled above and needs no
            // heuristic corroboration.
            let matchesSafeLegacyDuplicate = matchesLegacyCandidate
                && !insertedSemanticKey
            guard !matchesSafeLegacyDuplicate,
                  row.hasExternalID || insertedSemanticKey else {
                fingerprints.remove(persistedFingerprint)
                duplicates += 1
                continue
            }

            let candidateAccountsCheckpoint = candidateAccounts.count
            let newAccountsCheckpoint = newAccounts.count
            let newBudgetNodesCheckpoint = newBudgetNodes.count

            let baseEntry: JournalEntry
            do {
                switch row.kind {
                case .expense:
                    guard let category = category(
                        named: row.categoryName,
                        kind: .expense,
                        fallbackID: fallbackExpenseCategoryID
                    ) else { throw AppModelError.missingRecord }
                    baseEntry = try TransactionFactory.expense(
                        amount: try Money(row.amount, currency: sourceCurrency),
                        paidFrom: source.id,
                        category: category.id,
                        occurredAt: row.occurredAt,
                        payee: row.payee,
                        note: row.note
                    )
                case .income:
                    guard let category = category(
                        named: row.categoryName,
                        kind: .income,
                        fallbackID: fallbackIncomeCategoryID
                    ) else { throw AppModelError.missingRecord }
                    baseEntry = try TransactionFactory.income(
                        amount: try Money(row.amount, currency: sourceCurrency),
                        depositedInto: source.id,
                        category: category.id,
                        occurredAt: row.occurredAt,
                        payee: row.payee,
                        note: row.note
                    )
                case .refund:
                    guard let category = category(
                        named: row.categoryName,
                        kind: .expense,
                        fallbackID: fallbackExpenseCategoryID
                    ) else { throw AppModelError.missingRecord }
                    baseEntry = try TransactionFactory.refund(
                        amount: try Money(row.amount, currency: sourceCurrency),
                        returnedTo: source.id,
                        category: category.id,
                        occurredAt: row.occurredAt,
                        payee: row.payee,
                        note: row.note
                    )
                case .transfer:
                    guard let destination = transferDestination,
                    let destinationCurrency = destination.currency else {
                        throw AppModelError.missingRecord
                    }
                    if sourceCurrency == destinationCurrency {
                        baseEntry = try TransactionFactory.transfer(
                            amount: try Money(row.amount, currency: sourceCurrency),
                            from: source.id,
                            to: destination.id,
                            occurredAt: row.occurredAt,
                            note: row.note
                        )
                    } else {
                        guard let destinationAmount = semanticDestinationAmount else {
                            throw AppModelError.foreignCurrencyTransferRequiresExchangeRate
                        }
                        let sourceTrading = candidateForeignExchangeAccount(
                            for: sourceCurrency
                        )
                        let destinationTrading = candidateForeignExchangeAccount(
                            for: destinationCurrency
                        )
                        for trading in [sourceTrading, destinationTrading]
                        where !candidateAccounts.contains(where: { $0.id == trading.id }) {
                            candidateAccounts.append(trading)
                            newAccounts.append(trading)
                        }
                        baseEntry = try TransactionFactory.foreignCurrencyTransfer(
                            sourceAmount: try Money(row.amount, currency: sourceCurrency),
                            destinationAmount: try Money(
                                destinationAmount,
                                currency: destinationCurrency
                            ),
                            from: source.id,
                            to: destination.id,
                            sourceTradingAccountID: sourceTrading.id,
                            destinationTradingAccountID: destinationTrading.id,
                            occurredAt: row.occurredAt,
                            note: row.note
                        )
                    }
                }

                importedEntries.append(
                    try JournalEntry(
                        kind: baseEntry.kind,
                        occurredAt: baseEntry.occurredAt,
                        createdAt: baseEntry.createdAt,
                        payee: baseEntry.payee,
                        note: baseEntry.note,
                        postings: baseEntry.postings,
                        sourceSystem: sourceSystem,
                        sourceFingerprint: persistedFingerprint,
                        originContext: row.originContext
                            ?? reportingOriginContext(for: baseEntry.occurredAt)
                    )
                )
            } catch {
                candidateAccounts.removeSubrange(candidateAccountsCheckpoint...)
                newAccounts.removeSubrange(newAccountsCheckpoint...)
                newBudgetNodes.removeSubrange(newBudgetNodesCheckpoint...)
                fingerprints.remove(persistedFingerprint)
                if insertedSemanticKey {
                    duplicateKeys.remove(rowDuplicateKey)
                }
                skipped += 1
            }
        }

        guard !importedEntries.isEmpty else {
            return TransactionImportResult(
                imported: 0,
                duplicates: duplicates,
                skipped: skipped,
                categoriesCreated: 0
            )
        }
        let candidateBudgetNodes = budgetNodes + newBudgetNodes
        if let currency = profile?.baseCurrency {
            _ = try BudgetTree(currency: currency, nodes: candidateBudgetNodes)
        }
        let recordedTimeline: BudgetConfigurationTimeline?
        if newBudgetNodes.isEmpty {
            recordedTimeline = nil
        } else {
            recordedTimeline = try budgetConfigurationTimelineRecording(
                nodes: candidateBudgetNodes
            )
        }
        let reportingZone = profile?.reportingTimeZoneIdentifier
            ?? reportingCalendar.timeZone.identifier
        let importedAttributions = try importedEntries.map {
            try BudgetEntryAttribution(
                entry: $0,
                originTimeZoneIdentifier: reportingZone
            )
        }
        let importStore = try requireStore()
        try await loadCompleteBudgetAttributionCacheIfNeeded(from: importStore)
        var candidateEntries = existingEntries + importedEntries
        candidateEntries.sort {
            if $0.occurredAt == $1.occurredAt { return $0.createdAt > $1.createdAt }
            return $0.occurredAt > $1.occurredAt
        }
        var candidateAttributions = budgetEntryAttributions
        for attribution in importedAttributions {
            candidateAttributions[attribution.id] = attribution
        }
        let recomputedTimeline = try budgetTimelineAfterJournalMutation(
            timeline: recordedTimeline,
            journalEntries: candidateEntries,
            attributions: candidateAttributions,
            affectedReportingMonths: try importedEntries.compactMap { entry in
                try budgetAffectedMonth(
                    for: entry,
                    attribution: candidateAttributions[entry.id],
                    timeline: recordedTimeline
                )
            }
        )
        let candidateTimeline = recomputedTimeline ?? recordedTimeline

        var writes = try newAccounts.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .accounts)
        }
        writes += try newBudgetNodes.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .budgetNodes)
        }
        writes += try importedEntries.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .journalEntries)
        }
        writes += try importedAttributions.map {
            try RecordWrite(
                $0,
                id: $0.id.uuidString,
                in: .budgetEntryAttributions
            )
        }
        if let candidateTimeline {
            writes.append(try budgetConfigurationTimelineWrite(candidateTimeline))
        }

        let generation = storeGeneration
        await lifecycleHooks.checkpoint(.beforeJournalCommit)
        invalidateCommittedJournalProjection()
        await lifecycleHooks.checkpoint(
            .afterJournalProjectionInvalidationBeforeCommit
        )
        try await importStore.write(writes)
        guard isCurrentStoreGeneration(generation) else {
            return TransactionImportResult(
                imported: 0,
                duplicates: duplicates,
                skipped: skipped,
                categoriesCreated: 0
            )
        }
        accounts.append(contentsOf: newAccounts)
        if let candidateTimeline { budgetConfigurationTimeline = candidateTimeline }
        budgetEntryAttributions = candidateAttributions
        budgetNodes = candidateBudgetNodes
        if retainsCompleteJournal { entries = candidateEntries }
        await refreshJournalAfterMutation()
        return TransactionImportResult(
            imported: importedEntries.count,
            duplicates: duplicates,
            skipped: skipped,
            categoriesCreated: newBudgetNodes.count
                + newAccounts.filter { $0.kind == .income }.count
        )
    }

    func encryptedBackup(password: String) async throws -> Data {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MoneyUp-Backup-\(UUID().uuidString).moneyup",
                isDirectory: false
            )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try await encryptedBackup(to: temporaryURL, password: password)
        return try Data(contentsOf: temporaryURL)
    }

    /// Production backup entry point. The returned artifact stays file-backed
    /// from the SQL cursor through SwiftUI's export handoff.
    func encryptedBackup(
        to destinationURL: URL,
        password: String
    ) async throws {
        try beginLifecycleMutation(invalidatesJournalProjection: false)
        isWorking = true
        defer {
            isWorking = false
            endLifecycleMutation()
        }

        // A portable archive contains the SQLCipher snapshot but not the
        // separately encrypted, book-agnostic locked-capture inbox. Refuse to
        // label an incomplete recovery point as ready.
        let backupStore = try requireStore()
        try await flushQuickLogDraftForBackup(to: backupStore)
        try await requireEmptyLockedCaptureInbox()
        try Task.checkCancellation()
        let metrics = try await backupStore.storageMetrics()
        guard metrics.recordCount
                <= RestoreCandidateValidator.maximumCandidateRecordCount,
              metrics.payloadByteCount
                <= RestoreCandidateValidator.maximumBackupStoredPayloadByteCount,
              metrics.recordIDByteCount
                <= RestoreCandidateValidator.maximumAggregateRecordIDByteCount,
              metrics.collectionByteCount
                <= RestoreCandidateValidator.maximumAggregateCollectionByteCount else {
            throw PortableArchiveError.archiveTooLarge
        }
        try Task.checkCancellation()
        try await backupStore.exportPortableArchive(
            to: destinationURL,
            password: password
        )
    }

    /// Restores only after the candidate has passed the exact encrypted-store
    /// and domain load used by the app in an isolated temporary database.
    /// Cancellation and deterministic lifecycle interruption remain entirely
    /// before the one live replacement transaction.
    func restoreEncryptedBackup(_ data: Data, password: String) async throws {
        guard PortableArchive.isWithinArchiveByteLimit(data.count) else {
            throw PortableArchiveError.archiveTooLarge
        }
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MoneyUp-Imported-\(UUID().uuidString).moneyup",
                isDirectory: false
            )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL, options: [.atomic])
        try await restoreEncryptedBackup(
            from: temporaryURL,
            password: password
        )
    }

    func restoreEncryptedBackup(
        from archiveURL: URL,
        password: String
    ) async throws {
        guard !isWorking,
              !isLifecycleMutationInProgress,
              !goalMutationBarrierClosed,
              !isJournalMutationInProgress else {
            throw AppModelError.transactionInProgress
        }
        isWorking = true
        goalMutationBarrierClosed = true
        await waitForGoalMutationDrain()
        isLifecycleMutationInProgress = true
        invalidateInFlightJournalProjection()
        defer { finishExclusiveDataLifecycleMutation() }

        // A cancelled debounce can already be inside its store operation.
        // Drain it before taking the rollback snapshot so no pre-restore draft
        // can wake and overwrite the restored logical book afterward.
        await finishPendingQuickLogDraftWrite()
        let restoreStore = try requireStore()
        // A wrong password, malformed archive, or failed candidate validation
        // leaves the old book authoritative. Persist the newest in-memory form
        // before parsing untrusted input so cancelling its debounce cannot turn
        // a harmless failed restore into later power-loss data loss.
        try await flushQuickLogDraftForBackup(to: restoreStore)

        // The redacted inbox is outside the portable archive and has no book
        // identity. Keeping it across replacement could apply old-book input
        // to the restored book; dropping it would lose user input.
        try await requireEmptyLockedCaptureInbox()
        do {
            try Self.removeRestoreValidationDirectory(
                restoreValidationDirectoryURL
            )
            try Self.removeLegacyRestoreValidationDirectories()
        } catch {
            throw AppModelError.invalidBook
        }
        try Task.checkCancellation()

        let generation = storeGeneration
        let stateBeforeRestore = state
        try await validateRestoreCandidateInIsolation(
            from: archiveURL,
            password: password
        )
        try Task.checkCancellation()

        let rollbackURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MoneyUp-Rollback-\(UUID().uuidString).moneyup",
                isDirectory: false
            )
        let rollbackPassword = UUID().uuidString + UUID().uuidString
        defer { try? FileManager.default.removeItem(at: rollbackURL) }
        try await restoreStore.exportPortableArchive(
            to: rollbackURL,
            password: rollbackPassword
        )
        guard ownsStoreGeneration(generation) else { throw AppModelError.locked }

        await lifecycleHooks.checkpoint(.beforeRestoreCommit)
        try Task.checkCancellation()
        guard ownsStoreGeneration(generation) else { throw AppModelError.locked }

        let retainedEntriesBeforeRestore = retainsCompleteJournal ? entries : nil
        var liveStoreWasReplaced = false
        // The actor can finish its replacement transaction while this main-
        // actor task is suspended. Make every old-book derived value and
        // destructive reference decision fail closed before that handoff.
        invalidateCommittedJournalProjection(invalidateRecentEntries: true)
        await lifecycleHooks.checkpoint(
            .afterJournalProjectionInvalidationBeforeCommit
        )
        do {
            try await restoreStore.restorePortableArchive(
                from: archiveURL,
                password: password
            )
            liveStoreWasReplaced = true
            await lifecycleHooks.checkpoint(
                .afterRestoreCommitBeforeCandidateLoad
            )
            try Task.checkCancellation()
            guard ownsStoreGeneration(generation) else {
                throw AppModelError.locked
            }
            try await load(from: restoreStore, mode: .restoreValidation)
            try Task.checkCancellation()
            guard ownsStoreGeneration(generation) else {
                throw AppModelError.locked
            }
            guard profile != nil else { throw AppModelError.invalidBook }
            try validateLoadedBook()
            try await RestoreCandidateValidator.validateRelationships(
                profile: profile,
                accounts: accounts,
                budgetNodes: budgetNodes,
                scheduledTransactions: scheduledTransactions,
                investmentHoldings: investmentHoldings,
                netWorthSnapshots: netWorthSnapshots,
                quickLogDraft: quickLogDraft,
                in: restoreStore
            )
            if let profile {
                UserDefaults.standard.set(
                    profile.allowLockedQuickCapture,
                    forKey: Self.lockedQuickCapturePreferenceKey
                )
            }
            state = .ready
        } catch {
            if case PersistenceError.restoreTransactionStateIndeterminate = error {
                // A failed SQLite rollback means neither the old nor candidate
                // state may be trusted. Force the same authoritative recovery
                // used after a committed candidate before republishing data.
                liveStoreWasReplaced = true
            }
            guard liveStoreWasReplaced else {
                // A failed/rolled-back store replacement leaves the old durable
                // book intact. Restore the deliberately cleared complete test/
                // preview journal so the normal idle-end republish cannot mark
                // a false empty cache as current.
                if let retainedEntriesBeforeRestore {
                    entries = retainedEntriesBeforeRestore
                }
                throw error
            }
            do {
                // `Task.init` creates a fresh unstructured task, so cancellation
                // of the failed restore is not inherited. Recovery must remain
                // uncancelled through both index rebuilding and domain decode:
                // those paths deliberately observe their current task's state.
                let rollbackRecoveryTask = Task { @MainActor [self] in
                    guard ownsStoreGeneration(generation) else {
                        throw AppModelError.locked
                    }
                    // Candidate loading may have partially assigned decoded
                    // state. Keep every projection unavailable across the
                    // rollback transaction; `load` republishes only a coherent
                    // book.
                    invalidateCommittedJournalProjection(
                        invalidateRecentEntries: true
                    )
                    try await restoreStore.restorePortableArchive(
                        from: rollbackURL,
                        password: rollbackPassword,
                        observesCancellation: false
                    )
                    guard ownsStoreGeneration(generation) else {
                        throw AppModelError.locked
                    }
                    try await load(from: restoreStore, mode: .rollbackRecovery)
                    guard ownsStoreGeneration(generation) else {
                        throw AppModelError.locked
                    }
                    if profile != nil { try validateLoadedBook() }
                }
                try await rollbackRecoveryTask.value
                guard ownsStoreGeneration(generation) else {
                    throw AppModelError.locked
                }
                state = stateBeforeRestore
            } catch {
                clearDecodedState()
                state = .failed(
                    AppModelError.restoreRecoveryFailed.localizedDescription
                )
                throw AppModelError.restoreRecoveryFailed
            }
            throw error
        }
    }

    /// A restore candidate is never trial-applied to the live database. The
    /// temporary key exists only long enough to open a disposable SQLCipher
    /// file and is explicitly overwritten on every exit path.
    private func validateRestoreCandidateInIsolation(
        from archiveURL: URL,
        password: String
    ) async throws {
        try Task.checkCancellation()
        let directoryURL = restoreValidationDirectoryURL
        let databaseURL = directoryURL.appendingPathComponent(
            "candidate.sqlite3",
            isDirectory: false
        )
        do {
            // Reuse one exact owned directory. A crash can leave it behind,
            // but the next validation removes it before any untrusted row is
            // copied, preventing unbounded UUID-directory accumulation.
            try Self.removeRestoreValidationDirectory(directoryURL)
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw AppModelError.invalidBook
        }
        var validationKey = Self.temporaryRestoreValidationKey()
        defer { validationKey.resetBytes(in: 0..<validationKey.count) }

        let validationStore: EncryptedRecordStore
        do {
            validationStore = try EncryptedRecordStore(
                databaseURL: databaseURL,
                key: validationKey
            )
        } catch {
            let creationFailure = error
            do {
                try Self.removeRestoreValidationDirectory(directoryURL)
            } catch {
                throw AppModelError.invalidBook
            }
            throw creationFailure
        }
        validationKey.resetBytes(in: 0..<validationKey.count)

        var validationFailure: (any Error)?
        do {
            try await validationStore.restorePortableArchive(
                from: archiveURL,
                password: password
            )
            try Task.checkCancellation()

            let metrics = try await validationStore.storageMetrics()
            guard metrics.recordCount
                    <= RestoreCandidateValidator.maximumCandidateRecordCount,
                  metrics.payloadByteCount
                    <= RestoreCandidateValidator
                        .maximumBackupStoredPayloadByteCount,
                  metrics.recordIDByteCount
                    <= RestoreCandidateValidator
                        .maximumAggregateRecordIDByteCount,
                  metrics.collectionByteCount
                    <= RestoreCandidateValidator
                        .maximumAggregateCollectionByteCount else {
                throw AppModelError.invalidBook
            }

            let validationModel = AppModel(
                restoreValidationStore: validationStore,
                lockedCaptureStore: lockedCaptureStore,
                receiptRecognizer: receiptRecognizer
            )
            try await validationModel.load(
                from: validationStore,
                mode: .restoreValidation
            )
            guard validationModel.profile != nil else {
                throw AppModelError.invalidBook
            }
            try validationModel.validateLoadedBook()
            try await RestoreCandidateValidator.validateRelationships(
                profile: validationModel.profile,
                accounts: validationModel.accounts,
                budgetNodes: validationModel.budgetNodes,
                scheduledTransactions: validationModel.scheduledTransactions,
                investmentHoldings: validationModel.investmentHoldings,
                netWorthSnapshots: validationModel.netWorthSnapshots,
                quickLogDraft: validationModel.quickLogDraft,
                in: validationStore
            )
            try Task.checkCancellation()
        } catch {
            validationFailure = error
        }

        await validationStore.close()
        do {
            try Self.removeRestoreValidationDirectory(directoryURL)
        } catch {
            // A disposable plaintext path must not be left behind even though
            // its contents are encrypted. Treat cleanup failure as a failed
            // validation and keep the live book untouched.
            validationFailure = AppModelError.invalidBook
        }
        if let validationFailure { throw validationFailure }
    }

    private static func temporaryRestoreValidationKey() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        })
    }

    private var restoreValidationDirectoryURL: URL {
        // Dependency-injected test/preview models share the host temporary
        // directory, so isolate them by their already-unique database parent.
        // Production has no injected URL and always uses the single `primary`
        // location scavenged by `start()` and before every restore.
        let discriminator = databaseURLForErase?
            .deletingLastPathComponent()
            .lastPathComponent ?? "primary"
        return FileManager.default.temporaryDirectory.appendingPathComponent(
            "MoneyUp-RestoreValidation-\(discriminator)",
            isDirectory: true
        )
    }

    private static func removeRestoreValidationDirectory(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private static func removeLegacyRestoreValidationDirectories() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let prefix = "MoneyUp-RestoreValidation-"
        let children = try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for child in children {
            let name = child.lastPathComponent
            guard name.hasPrefix(prefix) else { continue }
            let suffix = String(name.dropFirst(prefix.count))
            // Old builds used UUID.uuidString verbatim. Restrict cleanup to
            // that exact canonical shape so no unrelated temporary directory
            // sharing the human-readable prefix can ever be removed.
            guard let id = UUID(uuidString: suffix),
                  id.uuidString == suffix,
                  try child.resourceValues(forKeys: [.isDirectoryKey])
                      .isDirectory == true else {
                continue
            }
            try FileManager.default.removeItem(at: child)
        }
    }

    private func invalidateDerivedData() {
        reportCache.removeAll()
        monthToDateComparisonCache = nil
        monthToDateComparisonCacheDay = nil
        balanceCache = nil
    }

    private func refreshBudgetWidgetSnapshot() {
        // A nil profile during normal lock is intentional: the last explicitly
        // opted-in percentage remains available to the Lock/Home widget. Only
        // destructive erase or a confirmed no-book startup calls the explicit
        // disable helper below.
        guard let profile else { return }
        guard profile.showsBudgetStatusWidget else {
            disableBudgetWidgetSnapshot()
            return
        }
        let now = currentDate()
        guard let period = reportingCalendar.dateInterval(of: .month, for: now),
              let periodToken = BudgetWidgetSnapshotStore.periodToken(
                  for: period.start,
                  calendar: reportingCalendar
              ) else {
            budgetWidgetSnapshotStore.publish(
                enabled: true,
                percentUsed: nil
            )
            WidgetCenter.shared.reloadTimelines(ofKind: "MoneyUpQuickLog")
            return
        }

        let percentage: Int?
        if case let .available(.some(summary)) = budgetPlanSummaryThisMonthResult(),
           summary.limit.amount > .zero {
            do {
                var raw = try CheckedDecimal.multiplying(
                    CheckedDecimal.ratio(
                        summary.spent.amount,
                        summary.limit.amount
                    ),
                    100
                )
                var rounded = Decimal.zero
                NSDecimalRound(&rounded, &raw, 0, .plain)
                let clamped = min(max(rounded, .zero), Decimal(9_999))
                percentage = NSDecimalNumber(decimal: clamped).intValue
            } catch {
                percentage = nil
            }
        } else {
            percentage = nil
        }
        budgetWidgetSnapshotStore.publish(
            enabled: true,
            percentUsed: percentage,
            periodToken: periodToken,
            validUntil: period.end
        )
        WidgetCenter.shared.reloadTimelines(ofKind: "MoneyUpQuickLog")
    }

    private func disableBudgetWidgetSnapshot() {
        budgetWidgetSnapshotStore.publish(enabled: false, percentUsed: nil)
        WidgetCenter.shared.reloadTimelines(ofKind: "MoneyUpQuickLog")
    }

    private func accountBalancesResult() -> DerivedValue<[UUID: [CurrencyCode: Money]]> {
        if let balanceCache { return balanceCache }
        guard retainsCompleteJournal else {
            scheduleJournalDerivedRefresh()
            return .unavailable(.appNotReady)
        }
        let result: DerivedValue<[UUID: [CurrencyCode: Money]]>
        do {
            result = .available(
                try FinanceCalculator.balancesByAccount(entries: entries)
            )
        } catch {
            DerivedValueDiagnostics.record(
                .ledgerCalculationFailed,
                operation: "account-balances",
                error: error
            )
            result = .unavailable(.ledgerCalculationFailed)
        }
        balanceCache = result
        return result
    }

    @discardableResult
    private func save(
        _ entry: JournalEntry,
        additionalWrites: [RecordWrite] = [],
        additionalAccounts: [LedgerAccount] = [],
        receiptData: Data? = nil
    ) async throws -> UUID? {
        try beginJournalMutation()
        defer { endJournalMutation() }
        let completedLockedCaptureID = quickLogDraft?.sourceCaptureID
        let entry = try appAuthoredEntry(
            entry,
            sourceSystemOverride: completedLockedCaptureID == nil
                ? nil : "MoneyUp Locked Capture",
            sourceFingerprintOverride: completedLockedCaptureID.map(
                Self.lockedCaptureFingerprint
            )
        )
        let generation = storeGeneration
        let currentDraft = quickLogDraft
        if let existingCommit = quickLogCommit {
            guard existingCommit.generation != generation else {
                throw AppModelError.transactionInProgress
            }
            quickLogCommit = nil
        }
        let transactionStore = try requireStore()
        let pendingDraftWrite = quickLogDraftWriteTask
        pendingDraftWrite?.cancel()
        quickLogDraftWriteTask = nil
        let attribution = try BudgetEntryAttribution(
            entry: entry,
            originTimeZoneIdentifier: profile?.reportingTimeZoneIdentifier
                ?? reportingCalendar.timeZone.identifier
        )
        var candidateAttributions = budgetEntryAttributions
        candidateAttributions[entry.id] = attribution
        let affectedMonths = [
            try budgetAffectedMonth(for: entry, attribution: attribution)
        ].compactMap { $0 }
        var candidateEntries = try await journalEntriesForBudgetMutation(
            from: transactionStore,
            affectedReportingMonths: affectedMonths
        )
        if candidateEntries != nil {
            candidateAttributions = budgetEntryAttributions
            candidateAttributions[entry.id] = attribution
            candidateEntries?.append(entry)
            candidateEntries?.sort {
                if $0.occurredAt == $1.occurredAt {
                    return $0.createdAt > $1.createdAt
                }
                return $0.occurredAt > $1.occurredAt
            }
        }
        let candidateTimeline: BudgetConfigurationTimeline?
        if let candidateEntries {
            candidateTimeline = try budgetTimelineAfterJournalMutation(
                journalEntries: candidateEntries,
                attributions: candidateAttributions,
                affectedReportingMonths: affectedMonths
            )
        } else {
            candidateTimeline = nil
        }
        var pendingWrites = additionalWrites
        let receiptAttachment: ReceiptAttachment?
        if let receiptData {
            let createdAttachment = try ReceiptAttachment(
                entryID: entry.id,
                mediaType: .detected(from: receiptData),
                data: receiptData
            )
            receiptAttachment = createdAttachment
            pendingWrites.append(
                try RecordWrite(
                    createdAttachment,
                    id: createdAttachment.id.uuidString,
                    in: .receiptAttachments
                )
            )
        } else {
            receiptAttachment = nil
        }
        pendingWrites.append(
            try RecordWrite(entry, id: entry.id.uuidString, in: .journalEntries)
        )
        pendingWrites.append(
            try RecordWrite(
                attribution,
                id: attribution.id.uuidString,
                in: .budgetEntryAttributions
            )
        )
        if let candidateTimeline {
            pendingWrites.append(
                try budgetConfigurationTimelineWrite(candidateTimeline)
            )
        }
        // A capture is represented durably by the SQLCipher draft before it is
        // removed from the redacted inbox. Remove any surviving inbox copy
        // before committing the journal entry: if this fails, the encrypted
        // draft remains retryable; if the process stops afterward, either the
        // draft or the committed journal entry remains, never a promotable
        // duplicate of an already committed transaction.
        if let completedLockedCaptureID {
            guard let currentDraft,
                  currentDraft.sourceCaptureID == completedLockedCaptureID else {
                throw AppModelError.invalidBook
            }
            await pendingDraftWrite?.value
            try await transactionStore.upsert(
                currentDraft,
                id: QuickLogDraft.primaryRecordID,
                in: .quickLogDrafts
            )
            let remainingCaptureCount = try await lockedCaptureStore.remove(
                id: completedLockedCaptureID
            )
            guard ownsStoreGeneration(generation) else {
                throw AppModelError.locked
            }
            pendingLockedCaptureCount = remainingCaptureCount
            recoveryIssues.removeAll { $0.hasPrefix("locked_captures/") }
        }
        let writes = pendingWrites
        let commitTask = Task {
            await pendingDraftWrite?.value
            await lifecycleHooks.checkpoint(.beforeJournalCommit)
            invalidateCommittedJournalProjection()
            await lifecycleHooks.checkpoint(
                .afterJournalProjectionInvalidationBeforeCommit
            )
            try await transactionStore.write(
                writes,
                removing: [
                    RecordDeletion(
                        id: QuickLogDraft.primaryRecordID,
                        from: .quickLogDrafts
                    )
                ]
            )
        }
        let commitID = UUID()
        quickLogCommit = PendingQuickLogCommit(
            id: commitID,
            generation: generation,
            task: commitTask
        )
        defer {
            if quickLogCommit?.id == commitID {
                quickLogCommit = nil
            }
        }
        try await commitTask.value
        await lifecycleHooks.checkpoint(
            .afterJournalCommitBeforeProjectionRefresh
        )
        guard isCurrentStoreGeneration(generation) else { return nil }
        quickLogDraft = nil
        if !additionalAccounts.isEmpty {
            accounts.append(contentsOf: additionalAccounts)
        }
        if let receiptAttachment {
            receiptAttachmentMetadata.append(ReceiptAttachmentMetadata(receiptAttachment))
        }
        if let candidateTimeline { budgetConfigurationTimeline = candidateTimeline }
        budgetEntryAttributions = candidateAttributions
        if retainsCompleteJournal, let candidateEntries { entries = candidateEntries }
        await refreshJournalAfterMutation()
        if completedLockedCaptureID != nil {
            do {
                try await promoteLockedCaptureIfPossible(
                    to: transactionStore,
                    generation: generation,
                    requestLogRoute: false
                )
            } catch let error as LockedCaptureStoreError {
                recordLockedCaptureStoreIssue(error)
            } catch {
                // The journal entry is already durable. Surface a safe
                // recovery signal instead of reporting Save as failed.
                recordRecoveryIssue("locked_captures/promotion-unavailable")
            }
        }
        return entry.id
    }

    private func scheduleQuickLogDraftWrite(_ draft: QuickLogDraft?) {
        let previousWrite = quickLogDraftWriteTask
        previousWrite?.cancel()
        guard let draftStore = store else {
            quickLogDraftWriteTask = nil
            return
        }

        quickLogDraftWriteTask = Task {
            // Chain revisions so Save/Lock can await one task and know every
            // older draft write has also finished before deleting or closing.
            await previousWrite?.value
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await lifecycleHooks.checkpoint(.beforeQuickLogDraftWrite)
            guard !Task.isCancelled else { return }
            await writeQuickLogDraft(draft, to: draftStore)
        }
    }

    /// Replaces the debounce with a chained immediate write. Keeping the
    /// previous task in the chain ensures an older draft can never land after
    /// the latest inactivity snapshot.
    private func flushQuickLogDraftImmediately() {
        // Restore and journal commit own the durable draft boundary. Starting
        // a convenience write inside either transaction could resurrect the
        // pre-transaction form after its authoritative commit. Their normal
        // completion/lock path performs the required final flush instead.
        guard !isLifecycleMutationInProgress,
              !isJournalMutationInProgress,
              quickLogCommit == nil else { return }
        let previousWrite = quickLogDraftWriteTask
        previousWrite?.cancel()
        guard let draftStore = store else {
            quickLogDraftWriteTask = nil
            return
        }
        let draft = quickLogDraft
        let backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "Save MoneyUp draft",
            expirationHandler: nil
        )

        quickLogDraftWriteTask = Task {
            defer {
                if backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                }
            }
            await previousWrite?.value
            await lifecycleHooks.checkpoint(.beforeQuickLogDraftWrite)
            await writeQuickLogDraft(draft, to: draftStore)
        }
    }

    /// Deterministic lifecycle synchronization without timing sleeps.
    func waitForPendingQuickLogDraftFlush() async {
        await quickLogDraftWriteTask?.value
    }

    private func writeQuickLogDraft(
        _ draft: QuickLogDraft?,
        to draftStore: EncryptedRecordStore
    ) async {
        do {
            if let draft {
                try await draftStore.upsert(
                    draft,
                    id: QuickLogDraft.primaryRecordID,
                    in: .quickLogDrafts
                )
            } else {
                try await draftStore.remove(
                    id: QuickLogDraft.primaryRecordID,
                    from: .quickLogDrafts
                )
            }
        } catch {
            // A draft is a convenience cache. A write failure must never block
            // locking or make a completed transaction appear to have failed.
        }
    }

    /// Rebuilds only compact derived state from the normalized encrypted
    /// ledger index. No full `JournalEntry` collection is decoded or retained.
    private func refreshJournalDerivedState(
        from journalStore: EncryptedRecordStore? = nil,
        loadRecentEntries: Bool = true,
        now requestedNow: Date? = nil,
        calendar: Calendar? = nil,
        observesCancellation: Bool = true,
        expectedProjectionRevision: UInt64? = nil
    ) async throws {
        let generation = storeGeneration
        let projectionRevision = expectedProjectionRevision
            ?? journalProjectionRevision
        guard projectionRevision == journalProjectionRevision else {
            throw CancellationError()
        }
        let now = requestedNow ?? currentDate()
        let reportCalendar = calendar ?? reportingCalendar
        let currentStore: EncryptedRecordStore
        if let journalStore {
            currentStore = journalStore
        } else {
            currentStore = try requireStore()
        }
        let accountSnapshot = accounts
        let validAccountIDs = Set(accountSnapshot.map(\.id))
        let expectedAccountCurrencies = Dictionary(
            uniqueKeysWithValues: accountSnapshot.compactMap { account in
                account.currency.map { (account.id, $0) }
            }
        )
        let ledgerIndex = try await currentStore.journalLedgerIndex(
            validAccountIDs: validAccountIDs,
            expectedAccountCurrencies: expectedAccountCurrencies
        )
        let quarantinedJournalEntryIDs = ledgerIndex.invalidRelationshipEntryIDs.union(
            ledgerIndex.issues.compactMap { UUID(uuidString: $0.recordID) }
        )
        let diagnostics = try await currentStore.journalIndexDiagnostics()
        guard ownsStoreGeneration(generation) else { throw AppModelError.locked }

        var recentEntries = entries
        if loadRecentEntries {
            recentEntries = []
            var cursor: JournalEntryPageCursor?
            var scannedPageCount = 0
            repeat {
                if observesCancellation { try Task.checkCancellation() }
                let page = try await currentStore.fetchJournalEntryPage(
                    after: cursor,
                    limit: 160
                )
                scannedPageCount += 1
                guard ownsStoreGeneration(generation) else {
                    throw AppModelError.locked
                }
                recordHistoryDecodeIssues(page.issues)
                for entry in page.entries where recentEntries.count < 80 {
                    if !quarantinedJournalEntryIDs.contains(entry.id),
                       entry.postings.allSatisfy({
                           validAccountIDs.contains($0.accountID)
                       }) {
                        recentEntries.append(entry)
                    }
                }
                cursor = recentEntries.count >= 80 || scannedPageCount >= 4
                    ? nil : page.nextCursor
            } while cursor != nil
        }

        var preparedReports: PreparedJournalReports?
        if let baseCurrency = profile?.baseCurrency,
           let trendInterval = ReportPeriod.twelveMonths.interval(
            containing: now,
            calendar: reportCalendar
           ) {
            let periods = Dictionary(
                uniqueKeysWithValues: ReportPeriod.allCases.compactMap { period in
                    period.interval(containing: now, calendar: reportCalendar).map {
                        (period, $0)
                    }
                }
            )
            var start = trendInterval.start
            var end = trendInterval.end
            for interval in periods.values {
                start = min(start, interval.start)
                end = max(end, interval.end)
            }
            let comparisonIntervals = MonthToDateComparisonIntervals(
                containing: now,
                calendar: reportCalendar
            )
            if let comparisonIntervals {
                start = min(start, comparisonIntervals.previous.start)
                end = max(end, comparisonIntervals.current.end)
            }
            guard let eventDayKeys = FinancialPeriodBoundary.dayKeyRange(
                for: DateInterval(start: start, end: end),
                calendar: reportCalendar
            ) else { throw AppModelError.invalidBook }
            let events = try await currentStore.fetchJournalPostingEvents(
                originDayKeyRange: eventDayKeys,
                excludingEntryIDs: quarantinedJournalEntryIDs
            )
            guard ownsStoreGeneration(generation) else {
                throw AppModelError.locked
            }
            preparedReports = try await Task.detached(priority: .userInitiated) {
                var reports: [ReportPeriod: PeriodReport] = [:]
                for (period, interval) in periods {
                    reports[period] = try FinanceCalculator.report(
                        interval: interval,
                        trendInterval: trendInterval,
                        accounts: accountSnapshot,
                        postingEvents: events,
                        baseCurrency: baseCurrency,
                        calendar: reportCalendar
                    )
                }
                let comparison = try comparisonIntervals.map { intervals in
                    let current = try FinanceCalculator.report(
                        interval: intervals.current,
                        accounts: accountSnapshot,
                        postingEvents: events,
                        baseCurrency: baseCurrency,
                        calendar: reportCalendar
                    )
                    let previous = try FinanceCalculator.report(
                        interval: intervals.previous,
                        accounts: accountSnapshot,
                        postingEvents: events,
                        baseCurrency: baseCurrency,
                        calendar: reportCalendar
                    )
                    return (
                        previous.baseFlow.expense,
                        current.baseFlow.expense,
                        current.holdsUnconvertedActivity
                            || previous.holdsUnconvertedActivity
                    )
                }
                return PreparedJournalReports(
                    reports: reports,
                    previousMonthToDateExpense: comparison?.0,
                    currentMonthToDateExpense: comparison?.1,
                    monthToDateHasUnconvertedActivity: comparison?.2 ?? false
                )
            }.value
        }

        var preparedBudgetProjection: ClosedMonthBudgetProjection?
        if profile != nil, !budgetConfigurationTimelineInvalid {
            let budgetCalendar = reportingCalendar
            let timeline = try validatedBudgetConfigurationTimeline(asOf: now)
            guard let currentMonth = budgetCalendar.dateInterval(
                of: .month,
                for: now
            )?.start else { throw AppModelError.invalidBook }
            let replayStart = budgetRolloverReplayStart(
                timeline: timeline,
                currentMonthStart: currentMonth,
                calendar: budgetCalendar
            ) ?? currentMonth
            let events: [LedgerPostingEvent]
            if replayStart < currentMonth {
                guard let dayKeys = FinancialPeriodBoundary.dayKeyRange(
                    for: DateInterval(start: replayStart, end: currentMonth),
                    calendar: budgetCalendar
                ) else { throw AppModelError.invalidBook }
                events = try await currentStore.fetchBudgetPostingEvents(
                    originDayKeyRange: dayKeys,
                    excludingEntryIDs: quarantinedJournalEntryIDs
                )
            } else {
                events = []
            }
            guard ownsStoreGeneration(generation) else {
                throw AppModelError.locked
            }
            preparedBudgetProjection = ClosedMonthBudgetProjection(
                reportingTimeZoneIdentifier: budgetCalendar.timeZone.identifier,
                currentMonthStart: currentMonth,
                coverageStart: replayStart,
                currency: timeline.currency,
                monthlySpending: try closedMonthBudgetSpending(
                    events: events,
                    attributions: [:],
                    currency: timeline.currency,
                    replayStart: replayStart,
                    currentMonthStart: currentMonth,
                    calendar: budgetCalendar,
                    excludingEntryIDs: quarantinedJournalEntryIDs
                )
            )
        }

        await lifecycleHooks.checkpoint(.afterJournalProjectionReadBeforePublish)
        guard ownsStoreGeneration(generation) else { throw AppModelError.locked }
        guard projectionRevision == journalProjectionRevision else {
            throw CancellationError()
        }
        journalEntryCount = max(0, ledgerIndex.entryCount)
        journalStoredEntryCount = diagnostics.journalRecordCount
        journalReferenceCounts = ledgerIndex.referenceCounts
        journalReferenceCountsAreCurrent = true
        invalidJournalEntryIDs = quarantinedJournalEntryIDs
        recordHistoryDecodeIssues(ledgerIndex.issues)
        if loadRecentEntries { entries = recentEntries }
        closedMonthBudgetProjection = preparedBudgetProjection
        balanceCache = .available(ledgerIndex.balances)
        reportCache = preparedReports?.reports.mapValues { .available($0) } ?? [:]
        reportCacheDay = reportCalendar.startOfDay(for: now)
        if let previous = preparedReports?.previousMonthToDateExpense,
           let current = preparedReports?.currentMonthToDateExpense {
            monthToDateComparisonCache = .available(
                MonthToDateExpenseComparison(
                    previous: previous,
                    current: current,
                    holdsUnconvertedActivity: preparedReports?
                        .monthToDateHasUnconvertedActivity ?? false
                )
            )
        } else {
            monthToDateComparisonCache = nil
        }
        monthToDateComparisonCacheDay = reportCalendar.startOfDay(for: now)
        if loadRecentEntries { journalRecentEntriesAreCurrent = true }
        // Clear the recovery marker in the same actor turn as the guarded
        // publish. Clearing it in a caller after this async method returns
        // creates a reentrancy window where a newer mutation can set the
        // marker and then have this older continuation erase it.
        journalDerivedRefreshWasDeferred = false
        recoveryIssues.removeAll {
            $0 == "journal_entries/derived-refresh-unavailable"
        }
        // `entries` publishes before the complete closed-month projection, so
        // make one final redacted widget publication from the coherent state.
        refreshBudgetWidgetSnapshot()
    }

    private func scheduleJournalDerivedRefresh() {
        guard store != nil,
              state == .ready || state == .onboarding else { return }
        guard !isWorking,
              !isLifecycleMutationInProgress,
              !manualJournalMutationIsActive,
              standaloneJournalMutationsInProgress == 0 else {
            journalDerivedRefreshWasDeferred = true
            return
        }
        // Test fixtures that deliberately retain the complete journal derive
        // synchronously from that collection. Wait until a writer finishes so
        // a postcommit/prepublish window cannot expose its old widget state.
        // A compact refresh would replace the collection with a bounded window.
        guard !retainsCompleteJournal else {
            republishRetainedJournalProjectionIfPossible()
            return
        }
        guard journalDerivedRefreshTask == nil else {
            // A real invalidation always advances `journalProjectionRevision`.
            // If the running task can still publish, it also satisfies a
            // duplicate view request and clears this marker on success.
            journalDerivedRefreshWasDeferred = true
            return
        }

        let scheduledRevision = journalProjectionRevision
        journalDerivedRefreshWasDeferred = false
        let token = UUID()
        journalDerivedRefreshTaskToken = token
        journalDerivedRefreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.refreshJournalDerivedState(
                    expectedProjectionRevision: scheduledRevision
                )
            } catch {
                // A mutation invalidates the revision before its durable
                // write. Its end path observes the retained deferred marker
                // and starts one coherent successor refresh.
            }
            guard self.journalDerivedRefreshTaskToken == token else { return }
            self.journalDerivedRefreshTask = nil
            self.journalDerivedRefreshTaskToken = nil
            self.resumeDeferredJournalDerivedRefreshIfPossible()
        }
    }

    /// Test/previews can deliberately retain the complete journal in memory.
    /// If a store write fails after commit-boundary invalidation, that retained
    /// collection still represents the durable precommit book; restore its
    /// recent/count/widget projection instead of leaving the widget unavailable.
    private func republishRetainedJournalProjectionIfPossible() {
        guard retainsCompleteJournal,
              store != nil,
              state == .ready || state == .onboarding else { return }
        journalEntryCount = entries.count
        journalStoredEntryCount = entries.count
        journalRecentEntriesAreCurrent = true
        journalDerivedRefreshWasDeferred = false
        refreshBudgetWidgetSnapshot()
    }

    private func resumeDeferredJournalDerivedRefreshIfPossible() {
        guard journalDerivedRefreshWasDeferred else { return }
        scheduleJournalDerivedRefresh()
    }

    /// Lets an unavailable-state surface request a fresh compact projection.
    /// A retry is deliberately user driven after a standalone read failure so
    /// persistent store errors cannot create a tight background retry loop.
    func retryUnavailableJournalProjection() {
        guard !retainsCompleteJournal,
              !journalRecentEntriesAreCurrent else { return }
        scheduleJournalDerivedRefresh()
    }

    /// Invalidates every in-flight read before a writer suspends. The last
    /// published caches remain internally usable while they still describe the
    /// durable pre-commit book; the commit path clears them synchronously before
    /// yielding again. This separation keeps balance and rollover validation
    /// available to the mutation without allowing an older async read to win.
    private func invalidateInFlightJournalProjection() {
        journalProjectionRevision &+= 1
        journalDerivedRefreshWasDeferred = true
    }

    private func invalidateCommittedJournalProjection(
        invalidateRecentEntries: Bool = false
    ) {
        journalReferenceCountsAreCurrent = false
        closedMonthBudgetProjection = nil
        invalidateDerivedData()
        if invalidateRecentEntries || !retainsCompleteJournal {
            // Never let an empty/stale bounded cache masquerade as the durable
            // journal after the store actor crosses its commit boundary.
            journalRecentEntriesAreCurrent = false
            entries = []
            journalEntryCount = 0
        }
        publishUnavailableBudgetWidgetSnapshot()
    }

    /// A committed journal mutation must never leave a pre-commit percentage
    /// visible while its complete budget projection is being rebuilt. Preserve
    /// only the opt-in bit and current reporting-period boundary.
    private func publishUnavailableBudgetWidgetSnapshot() {
        guard let profile else { return }
        guard profile.showsBudgetStatusWidget else {
            disableBudgetWidgetSnapshot()
            return
        }
        let now = currentDate()
        guard let period = reportingCalendar.dateInterval(of: .month, for: now),
              let periodToken = BudgetWidgetSnapshotStore.periodToken(
                  for: period.start,
                  calendar: reportingCalendar
              ) else {
            budgetWidgetSnapshotStore.publish(enabled: true, percentUsed: nil)
            WidgetCenter.shared.reloadTimelines(ofKind: "MoneyUpQuickLog")
            return
        }
        budgetWidgetSnapshotStore.publish(
            enabled: true,
            percentUsed: nil,
            periodToken: periodToken,
            validUntil: period.end
        )
        WidgetCenter.shared.reloadTimelines(ofKind: "MoneyUpQuickLog")
    }

    /// Deterministic app-level tests use this to observe completion of the
    /// single scheduled compact projection refresh without timing sleeps.
    func waitForPendingJournalDerivedRefresh() async {
        while let pending = journalDerivedRefreshTask {
            await pending.value
        }
    }

    /// Exercises the production recovering-load path against an injected test
    /// store without involving Keychain-backed application startup.
    func reloadPersistedBookForTesting() async throws {
        try await load(from: requireStore())
    }

    /// The journal transaction is already durable when this runs. A compact
    /// refresh failure must make derived UI unavailable and schedule recovery,
    /// not throw a misleading Save error for an operation that did commit.
    private func refreshJournalAfterMutation() async {
        journalProjectionRevision &+= 1
        invalidateCommittedJournalProjection()
        if retainsCompleteJournal {
            journalEntryCount = entries.count
            journalStoredEntryCount = entries.count
            journalRecentEntriesAreCurrent = true
            journalDerivedRefreshWasDeferred = false
            refreshBudgetWidgetSnapshot()
            return
        }
        let mutationGeneration = storeGeneration
        do {
            try await refreshJournalDerivedState()
        } catch {
            guard ownsStoreGeneration(mutationGeneration),
                  state == .ready || state == .onboarding else { return }
            balanceCache = .unavailable(.appNotReady)
            reportCache.removeAll()
            reportCacheDay = nil
            monthToDateComparisonCache = nil
            monthToDateComparisonCacheDay = nil
            closedMonthBudgetProjection = nil
            if let refreshStore = store,
               let diagnostics = try? await refreshStore.journalIndexDiagnostics() {
                journalStoredEntryCount = diagnostics.journalRecordCount
            }
            let issue = "journal_entries/derived-refresh-unavailable"
            if !recoveryIssues.contains(issue) { recoveryIssues.append(issue) }
            scheduleJournalDerivedRefresh()
        }
    }

    private func load(
        from store: EncryptedRecordStore,
        mode: BookLoadMode = .recovering
    ) async throws {
        journalProjectionRevision &+= 1
        retainsCompleteJournal = false
        invalidateCommittedJournalProjection()
        recoveryIssues = []
        closedMonthBudgetProjection = nil
        budgetConfigurationTimeline = nil
        budgetConfigurationTimelineInvalid = false
        profile = try await store.fetch(
            UserProfile.self,
            id: UserProfile.primaryRecordID,
            from: .profile
        )
        if let profile, mode.updatesPreferences {
            UserDefaults.standard.set(
                profile.allowLockedQuickCapture,
                forKey: Self.lockedQuickCapturePreferenceKey
            )
            // Re-encode on open so legacy profiles persist the inferred
            // opt-out and reporting zone instead of re-inferring after travel.
            try await store.upsert(
                profile,
                id: UserProfile.primaryRecordID,
                in: .profile
            )
        }
        let recoveredAccounts = try await store.fetchAllIdentifiedRecovering(
            LedgerAccount.self,
            from: .accounts
        )
        let recoveredBudgets = try await store.fetchAllIdentifiedRecovering(
            BudgetNode.self,
            from: .budgetNodes
        )
        let recoveredSchedules = try await store.fetchAllIdentifiedRecovering(
            ScheduledTransaction.self,
            from: .scheduledTransactions
        )
        let recoveredHoldings = try await store.fetchAllIdentifiedRecovering(
            InvestmentHolding.self,
            from: .investmentHoldings
        )
        let recoveredAttachments = try await store.receiptAttachmentIndexSnapshot()
        let recoveredRates = try await store.fetchAllIdentifiedRecovering(
            DatedExchangeRate.self,
            from: .exchangeRates
        )
        let recoveredSnapshots = try await store.fetchAllIdentifiedRecovering(
            NetWorthSnapshot.self,
            from: .netWorthSnapshots
        )
        let recoveredGoals = try await store.fetchAllIdentifiedRecovering(
            SavingsGoal.self,
            from: .savingsGoals
        )
        let attributionIndex = try await store.budgetAttributionIndexSnapshot()
        let loadsCompleteBudgetAttributions =
            mode.loadsCompleteBudgetAttributions
            || attributionIndex.requiresDetailedValidation
        let recoveredBudgetAttributions: RecoveredRecords<BudgetEntryAttribution>?
        if loadsCompleteBudgetAttributions {
            recoveredBudgetAttributions = try await store
                .fetchAllIdentifiedRecovering(
                    BudgetEntryAttribution.self,
                    from: .budgetEntryAttributions
                )
        } else {
            recoveredBudgetAttributions = nil
        }
        do {
            budgetConfigurationTimeline = try await store.fetch(
                BudgetConfigurationTimeline.self,
                id: BudgetConfigurationTimeline.primaryRecordID,
                from: .budgetConfigurationTimelines
            )
        } catch {
            budgetConfigurationTimelineInvalid = true
            recoveryIssues.append(
                "budget_configuration_timelines/\(BudgetConfigurationTimeline.primaryRecordID)"
            )
        }
        accounts = try quarantiningDuplicateLogicalIDs(
            recoveredAccounts.values,
            in: .accounts,
            observesCancellation: mode.observesCancellationWhileLoading
        )
        entries = []
        budgetNodes = try quarantiningDuplicateLogicalIDs(
            recoveredBudgets.values,
            in: .budgetNodes,
            observesCancellation: mode.observesCancellationWhileLoading
        )
        scheduledTransactions = try quarantiningDuplicateLogicalIDs(
            recoveredSchedules.values,
            in: .scheduledTransactions,
            observesCancellation: mode.observesCancellationWhileLoading
        ).sorted {
            $0.nextOccurrence < $1.nextOccurrence
        }
        investmentHoldings = try quarantiningDuplicateLogicalIDs(
            recoveredHoldings.values,
            in: .investmentHoldings,
            observesCancellation: mode.observesCancellationWhileLoading
        )
        receiptAttachmentMetadata = try quarantiningDuplicateLogicalIDs(
            recoveredAttachments.metadata,
            in: .receiptAttachments,
            observesCancellation: mode.observesCancellationWhileLoading
        )
        exchangeRates = try quarantiningDuplicateLogicalIDs(
            recoveredRates.values,
            in: .exchangeRates,
            observesCancellation: mode.observesCancellationWhileLoading
        ).sorted {
            if $0.effectiveContext.dayKey == $1.effectiveContext.dayKey {
                return $0.createdAt > $1.createdAt
            }
            return $0.effectiveContext.dayKey > $1.effectiveContext.dayKey
        }
        netWorthSnapshots = try quarantiningDuplicateLogicalIDs(
            recoveredSnapshots.values,
            in: .netWorthSnapshots,
            observesCancellation: mode.observesCancellationWhileLoading
        ).sorted { $0.capturedAt > $1.capturedAt }
        savingsGoals = try quarantiningDuplicateLogicalIDs(
            recoveredGoals.values,
            in: .savingsGoals,
            observesCancellation: mode.observesCancellationWhileLoading
        ).sorted { $0.targetDate < $1.targetDate }
        budgetEntryAttributions = [:]
        budgetAttributionCacheIsComplete = loadsCompleteBudgetAttributions
        if let recoveredBudgetAttributions {
            let recoveredAttributions = try quarantiningDuplicateLogicalIDs(
                recoveredBudgetAttributions.values,
                in: .budgetEntryAttributions,
                observesCancellation: mode.observesCancellationWhileLoading
            )
            if recoveredAttributions.count
                != recoveredBudgetAttributions.values.count {
                budgetConfigurationTimelineInvalid = true
            }
            for attribution in recoveredAttributions {
                if budgetEntryAttributions.updateValue(
                    attribution,
                    forKey: attribution.id
                ) != nil {
                    budgetConfigurationTimelineInvalid = true
                    recoveryIssues.append(
                        "budget_entry_attributions/duplicate-\(attribution.id)"
                    )
                }
            }
        }
        if attributionIndex.recordCount
                > RestoreCandidateValidator.maximumBudgetAttributionCount
            || attributionIndex.indexedEntryCount != attributionIndex.recordCount
            || attributionIndex.indexedPostingCount
                > RestoreCandidateValidator.maximumJournalPostingCount
            || !attributionIndex.issues.isEmpty
            || !(recoveredBudgetAttributions?.issues.isEmpty ?? true) {
            budgetConfigurationTimelineInvalid = true
            recoveryIssues.append(
                "budget_entry_attributions/inconsistent-index"
            )
        }
        var decodeIssues: [RecordDecodeIssue] = []
        decodeIssues.append(contentsOf: recoveredAccounts.issues)
        decodeIssues.append(contentsOf: recoveredBudgets.issues)
        decodeIssues.append(contentsOf: recoveredSchedules.issues)
        decodeIssues.append(contentsOf: recoveredHoldings.issues)
        decodeIssues.append(contentsOf: recoveredAttachments.issues)
        decodeIssues.append(contentsOf: recoveredRates.issues)
        decodeIssues.append(contentsOf: recoveredSnapshots.issues)
        decodeIssues.append(contentsOf: recoveredGoals.issues)
        decodeIssues.append(contentsOf: attributionIndex.issues)
        decodeIssues.append(contentsOf: recoveredBudgetAttributions?.issues ?? [])
        recoveryIssues.append(contentsOf: decodeIssues.map {
            "\($0.collection.rawValue)/\($0.recordID)"
        })
        let existingAttachmentEntryIDs = try await store.existingJournalEntryIDs(
            in: Set(receiptAttachmentMetadata.map(\.entryID))
        )
        let scheduledLinkedEntryIDs = Set(
            scheduledTransactions.flatMap(\.resolutions).compactMap(\.linkedEntryID)
        )
        let existingScheduledEntryIDs = try await store.existingJournalEntryIDs(
            in: scheduledLinkedEntryIDs
        )
        let existingBudgetAttributionEntryIDs: Set<UUID>?
        if loadsCompleteBudgetAttributions {
            existingBudgetAttributionEntryIDs = try await store
                .existingJournalEntryIDs(
                    in: Set(budgetEntryAttributions.keys)
                )
        } else {
            existingBudgetAttributionEntryIDs = nil
        }
        existingScheduledLinkedEntryIDs = existingScheduledEntryIDs
        let requestedInvestmentEntryIDs = Set(
            investmentHoldings.flatMap { Array($0.linkedEntryIDs) }
        )
        var investmentEntriesByID: [UUID: JournalEntry] = [:]
        for entryID in requestedInvestmentEntryIDs.sorted(by: {
            $0.uuidString < $1.uuidString
        }) {
            if mode.observesCancellationWhileLoading {
                try Task.checkCancellation()
            }
            do {
                if let entry = try await store.fetch(
                    JournalEntry.self,
                    id: entryID.uuidString,
                    from: .journalEntries
                ) {
                    investmentEntriesByID[entryID] = entry
                } else {
                    recoveryIssues.append("journal_entries/missing-investment-link")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                recoveryIssues.append("journal_entries/unreadable-investment-link")
            }
        }
        investmentLinkedEntriesByID = investmentEntriesByID
        try quarantineInvalidRelationships(
            existingAttachmentEntryIDs: existingAttachmentEntryIDs,
            existingScheduledEntryIDs: existingScheduledEntryIDs,
            existingBudgetAttributionEntryIDs: existingBudgetAttributionEntryIDs,
            investmentEntriesByID: investmentEntriesByID,
            observesCancellation: mode.observesCancellationWhileLoading
        )
        if loadsCompleteBudgetAttributions {
            try await validateBudgetEntryAttributionsAfterLoad(in: store)
        }
        // Rollover's complete closed-month projection depends on the persisted
        // dated configuration. Prepare or quarantine that timeline before the
        // normalized journal refresh derives any budget state from it.
        try await prepareBudgetConfigurationTimelineAfterLoad(
            in: store,
            persistsMigration: mode.persistsBudgetTimelineMigration
        )
        try await refreshJournalDerivedState(
            from: store,
            loadRecentEntries: true,
            observesCancellation: mode.observesCancellationWhileLoading
        )
        if !mode.rejectsRecoveryIssues,
           quarantineInvestmentLedgerMismatches() {
            try await refreshJournalDerivedState(
                from: store,
                loadRecentEntries: true,
                observesCancellation: mode.observesCancellationWhileLoading
            )
        }
        // The normalized ledger snapshot identifies entries that exist but are
        // quarantined as one atomic unit because an account reference is bad.
        // Their attachments remain preserved in SQLCipher/backups but hidden
        // from the live book with the entry itself.
        receiptAttachmentMetadata.removeAll { attachment in
            let invalid = invalidJournalEntryIDs.contains(attachment.entryID)
            if invalid {
                recoveryIssues.append("receipt_attachments/orphan-\(attachment.id)")
            }
            return invalid
        }
        do {
            quickLogDraft = try await store.fetch(
                QuickLogDraft.self,
                id: QuickLogDraft.primaryRecordID,
                from: .quickLogDrafts
            )
        } catch {
            if mode.rejectsRecoveryIssues {
                throw AppModelError.invalidBook
            }
            // A malformed convenience draft should not lock the user out of
            // the valid encrypted book. Discard it and continue opening.
            quickLogDraft = nil
            if mode.removesMalformedDraft {
                try? await store.remove(
                    id: QuickLogDraft.primaryRecordID,
                    from: .quickLogDrafts
                )
            }
        }
        try await persistCurrentMonthBudgetCheckpointIfNeeded(
            in: store,
            persistsCheckpoint: mode.persistsBudgetTimelineMigration
        )
        if mode.rejectsRecoveryIssues, !recoveryIssues.isEmpty {
            throw AppModelError.invalidBook
        }
    }

    func promotePendingLockedCapture() async throws {
        try beginLockedCapturePromotion()
        defer { endLockedCapturePromotion() }
        let generation = storeGeneration
        let currentStore = try requireStore()
        try await promoteLockedCaptureIfPossible(
            to: currentStore,
            generation: generation
        )
    }

    private func beginLockedCapturePromotion() throws {
        guard !isLifecycleMutationInProgress,
              !isWorking,
              state == .ready,
              !isJournalMutationInProgress,
              scheduleMutationsInProgress.isEmpty,
              scheduleEntryMatchesInProgress.isEmpty,
              investmentMutationsInProgress.isEmpty else {
            throw AppModelError.transactionInProgress
        }
        lockedCapturePromotionInProgress = true
    }

    private func endLockedCapturePromotion() {
        lockedCapturePromotionInProgress = false
        applyDeferredLockIfPossible()
    }

    private static func lockedCaptureFingerprint(_ id: UUID) -> String {
        "locked-capture:\(id.uuidString.lowercased())"
    }

    private func promoteLockedCaptureIfPossible(
        to store: EncryptedRecordStore,
        generation: Int,
        requestLogRoute: Bool = true
    ) async throws {
        var captures = try await lockedCaptureStore.all()
        guard ownsStoreGeneration(generation) else { return }
        pendingLockedCaptureCount = captures.count

        if let sourceID = quickLogDraft?.sourceCaptureID {
            let remainingCaptureCount = try await lockedCaptureStore.remove(id: sourceID)
            guard ownsStoreGeneration(generation) else { return }
            pendingLockedCaptureCount = remainingCaptureCount
            recoveryIssues.removeAll { $0.hasPrefix("locked_captures/") }
            return
        }
        guard quickLogDraft == nil else {
            recoveryIssues.removeAll { $0.hasPrefix("locked_captures/") }
            return
        }

        while let replay = captures.first,
              try await store.containsJournalEntry(
                sourceFingerprint: Self.lockedCaptureFingerprint(replay.id)
              ) {
            pendingLockedCaptureCount = try await lockedCaptureStore.remove(
                id: replay.id
            )
            captures.removeFirst()
            guard ownsStoreGeneration(generation) else { return }
        }
        guard let capture = captures.first else {
            recoveryIssues.removeAll { $0.hasPrefix("locked_captures/") }
            return
        }

        let kind: QuickLogKind
        let mode: QuickLogLaunchMode
        switch capture.kind {
        case .income:
            kind = .income
            mode = .income
        case .transfer:
            kind = .transfer
            mode = .transfer
        case .expense:
            kind = .expense
            mode = .expense
        case .refund:
            kind = .refund
            mode = .refund
        }
        let draft = QuickLogDraft(
            kind: kind,
            amountText: capture.amountText,
            destinationAmountText: "",
            accountID: nil,
            destinationAccountID: nil,
            categoryID: nil,
            occurredAt: capture.occurredAt,
            dateWasEdited: true,
            payee: capture.payee,
            note: capture.note,
            smartText: "",
            sourceCaptureID: capture.id
        )
        try await store.upsert(
            draft,
            id: QuickLogDraft.primaryRecordID,
            in: .quickLogDrafts
        )
        await lifecycleHooks.checkpoint(.afterCaptureDraftPersisted)
        guard ownsStoreGeneration(generation) else { return }
        quickLogDraft = draft
        let remainingCaptureCount = try await lockedCaptureStore.remove(id: capture.id)
        guard ownsStoreGeneration(generation) else { return }
        pendingLockedCaptureCount = remainingCaptureCount
        recoveryIssues.removeAll { $0.hasPrefix("locked_captures/") }
        if requestLogRoute { requestedQuickLogMode = mode }
    }

    private func recordRecoveryIssue(_ issue: String) {
        guard !recoveryIssues.contains(issue) else { return }
        recoveryIssues.append(issue)
    }

    private func recordLockedCaptureStoreIssue(
        _ error: LockedCaptureStoreError
    ) {
        recoveryIssues.removeAll { $0.hasPrefix("locked_captures/") }
        let suffix = error.isDefinitivelyUnrecoverable
            ? "unrecoverable"
            : "unavailable"
        recordRecoveryIssue("locked_captures/\(suffix)")
    }

    /// Classifies each account hierarchy once. A root-to-leaf walk for every
    /// account is quadratic for a deep but otherwise valid hierarchy and can
    /// make opening an authenticated archive appear to hang. Invalidity is
    /// inherited by descendants, so missing parents, kind mismatches, and
    /// every member/descendant of a cycle are quarantined together.
    nonisolated static func invalidAccountHierarchyIDs(
        in accounts: [LedgerAccount],
        observesCancellation: Bool = true
    ) throws -> Set<UUID> {
        let accountByID = Dictionary(
            uniqueKeysWithValues: accounts.map { ($0.id, $0) }
        )
        // 1 = active path, 2 = resolves to a valid root, 3 = invalid.
        var resolutionByID: [UUID: UInt8] = [:]
        resolutionByID.reserveCapacity(accountByID.count)
        var inspectedCount = 0

        for account in accounts where resolutionByID[account.id] == nil {
            var path: [UUID] = []
            var currentID: UUID? = account.id
            var resolvesToValidRoot = true

            while let id = currentID {
                if observesCancellation,
                   inspectedCount.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                inspectedCount += 1

                switch resolutionByID[id] {
                case 1:
                    resolvesToValidRoot = false
                    currentID = nil
                    continue
                case 2:
                    resolvesToValidRoot = true
                    currentID = nil
                    continue
                case 3:
                    resolvesToValidRoot = false
                    currentID = nil
                    continue
                default:
                    break
                }

                guard let current = accountByID[id] else {
                    resolvesToValidRoot = false
                    break
                }
                resolutionByID[id] = 1
                path.append(id)

                guard let parentID = current.parentID else {
                    resolvesToValidRoot = true
                    break
                }
                guard let parent = accountByID[parentID],
                      parent.kind == current.kind else {
                    resolvesToValidRoot = false
                    break
                }
                currentID = parentID
            }

            let resolution: UInt8 = resolvesToValidRoot ? 2 : 3
            for id in path {
                resolutionByID[id] = resolution
            }
        }

        return Set(resolutionByID.compactMap { item in
            item.value == 3 ? item.key : nil
        })
    }

    /// Rejects logical identity ambiguity without deleting forensic/recovery
    /// evidence from the encrypted store.
    private func quarantiningDuplicateLogicalIDs<Value: Identifiable>(
        _ values: [Value],
        in collection: RecordCollection,
        observesCancellation: Bool
    ) throws -> [Value] where Value.ID == UUID {
        var identityCounts: [UUID: Int] = [:]
        for (offset, value) in values.enumerated() {
            if observesCancellation, offset.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            identityCounts[value.id, default: 0] += 1
        }
        let duplicateIDs = Set(identityCounts.compactMap {
            $0.value > 1 ? $0.key : nil
        })
        guard !duplicateIDs.isEmpty else { return values }

        recoveryIssues.append(contentsOf: duplicateIDs.sorted {
            $0.uuidString < $1.uuidString
        }.map {
            "\(collection.rawValue)/duplicate-\($0)"
        })
        // Physical record keys are not exposed by decoded domain values.
        // Keeping an arbitrary winner would let another physical row restore
        // stale data after a canonical update/delete. Preserve every encrypted
        // row for recovery, but expose none of the ambiguous logical values.
        return values.filter { !duplicateIDs.contains($0.id) }
    }

    /// Invalid rows remain untouched in SQLCipher and in portable backups, but
    /// are excluded from calculations until repaired. This keeps one orphan
    /// from turning the entire otherwise-readable book into an erase screen.
    private func quarantineInvalidRelationships(
        existingAttachmentEntryIDs: Set<UUID>? = nil,
        existingScheduledEntryIDs: Set<UUID>? = nil,
        existingBudgetAttributionEntryIDs: Set<UUID>? = nil,
        investmentEntriesByID: [UUID: JournalEntry] = [:],
        observesCancellation: Bool
    ) throws {
        let invalidHierarchyIDs = try Self.invalidAccountHierarchyIDs(
            in: accounts,
            observesCancellation: observesCancellation
        )
        if !invalidHierarchyIDs.isEmpty {
            recoveryIssues.append(contentsOf: invalidHierarchyIDs.map {
                "accounts/orphan-or-cycle-\($0)"
            })
            accounts.removeAll { invalidHierarchyIDs.contains($0.id) }
        }
        var accountIDs = Set(accounts.map(\.id))
        let retainedAccountByID = Dictionary(
            uniqueKeysWithValues: accounts.map { ($0.id, $0) }
        )

        let expenseIDs = Set(accounts.filter { $0.kind == .expense }.map(\.id))
        let invalidBudgetIDs = Set(budgetNodes.filter {
            !expenseIDs.contains($0.id)
                || ($0.parentID.map { !expenseIDs.contains($0) } ?? false)
        }.map(\.id))
        if !invalidBudgetIDs.isEmpty {
            recoveryIssues.append(contentsOf: invalidBudgetIDs.map { "budgets/orphan-\($0)" })
            budgetNodes.removeAll { invalidBudgetIDs.contains($0.id) }
        }
        if let currency = profile?.baseCurrency,
           (try? BudgetTree(currency: currency, nodes: budgetNodes)) == nil,
           !budgetNodes.isEmpty {
            recoveryIssues.append("budgets/invalid-tree")
            budgetNodes = []
        }

        entries.removeAll { entry in
            let invalid = entry.postings.contains { !accountIDs.contains($0.accountID) }
            if invalid { recoveryIssues.append("journal_entries/orphan-\(entry.id)") }
            return invalid
        }
        var scheduleLinkOwners: [UUID: Set<UUID>] = [:]
        for schedule in scheduledTransactions {
            for entryID in schedule.resolutions.compactMap(\.linkedEntryID) {
                scheduleLinkOwners[entryID, default: []].insert(schedule.id)
            }
        }
        let reusedScheduleEntryIDs = Set(
            scheduleLinkOwners.filter { $0.value.count > 1 }.keys
        )
        let entryIDs = Set(entries.map(\.id))
        budgetEntryAttributions = budgetEntryAttributions.filter { item in
            let valid = existingBudgetAttributionEntryIDs?.contains(item.key)
                ?? entryIDs.contains(item.key)
            if !valid {
                recoveryIssues.append(
                    "budget_entry_attributions/orphan-\(item.key)"
                )
            }
            return valid
        }
        try scheduledTransactions.removeAll { item in
            let linkedEntryIDs = Set(item.resolutions.compactMap(\.linkedEntryID))
            let invalidLifecycle: Bool
            do {
                try item.validateLifecycle(calendar: reportingCalendar)
                invalidLifecycle = false
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                invalidLifecycle = true
            }
            let invalid = !accountIDs.contains(item.accountID)
                || !accountIDs.contains(item.categoryAccountID)
                || invalidLifecycle
                || !linkedEntryIDs.isDisjoint(with: reusedScheduleEntryIDs)
                || existingScheduledEntryIDs.map {
                    !linkedEntryIDs.isSubset(of: $0)
                } == true
            if invalid { recoveryIssues.append("scheduled_transactions/orphan-\(item.id)") }
            return invalid
        }
        let duplicateHoldingIDs = Set(
            Dictionary(grouping: investmentHoldings, by: \.id)
                .filter { $0.value.count > 1 }
                .keys
        )
        let duplicatePositionIDs = Set(
            Dictionary(
                grouping: investmentHoldings.compactMap(\.positionAccountID),
                by: { $0 }
            )
            .filter { $0.value.count > 1 }
            .keys
        )
        var entryOwners: [UUID: Set<UUID>] = [:]
        for holding in investmentHoldings {
            for entryID in holding.linkedEntryIDs {
                entryOwners[entryID, default: []].insert(holding.id)
            }
        }
        let reusedEntryIDs = Set(entryOwners.filter { $0.value.count > 1 }.keys)
        try investmentHoldings.removeAll { holding in
            let funding = retainedAccountByID[holding.accountID]
            let position = holding.positionAccountID.flatMap { id in
                retainedAccountByID[id]
            }
            let holdingCurrencies = Set(
                [holding.price?.currency]
                    + holding.priceHistory.map { Optional($0.price.currency) }
                    + holding.lots.map { Optional($0.unitCost.currency) }
                    + holding.disposals.flatMap {
                        [Optional($0.costBasis.currency), Optional($0.proceeds.currency),
                         Optional($0.realizedGainLoss.currency)]
                    }
            ).compactMap { $0 }
            let invalidFunding = funding.map {
                !isInvestmentFundingAccountShape($0)
                    || (!holding.isArchived && $0.isArchived)
            } ?? true
            let invalidPosition: Bool
            if let positionID = holding.positionAccountID {
                invalidPosition = positionID == holding.accountID
                    || position?.systemRole != .investmentPosition
                    || position?.kind != .asset
                    || position?.currency != funding?.currency
                    || position?.isArchived != holding.isArchived
            } else {
                invalidPosition = holding.isArchived
                    || !holding.linkedEntryIDs.isEmpty
                    || !(holding.quantity == .zero || holding.needsLedgerConnection)
            }
            let invalidLinks: Bool
            if holding.positionAccountID != nil {
                do {
                    try InvestmentLedgerIntegrity.validate(
                        holding: holding,
                        accountsByID: retainedAccountByID,
                        entriesByID: investmentEntriesByID
                    )
                    invalidLinks = false
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    invalidLinks = true
                }
            } else {
                invalidLinks = !holding.linkedEntryIDs.isEmpty
            }
            let invalid = duplicateHoldingIDs.contains(holding.id)
                || holding.positionAccountID.map(duplicatePositionIDs.contains) == true
                || !holding.linkedEntryIDs.isDisjoint(with: reusedEntryIDs)
                || invalidFunding
                || holdingCurrencies.contains { $0 != funding?.currency }
                || invalidPosition
                || invalidLinks
            if invalid { recoveryIssues.append("investment_holdings/orphan-\(holding.id)") }
            return invalid
        }
        let retainedPositionIDs = Set(investmentHoldings.compactMap(\.positionAccountID))
        let activeOrphanPositionIDs = Set(accounts.compactMap { account -> UUID? in
            guard account.systemRole == .investmentPosition,
                  !account.isArchived,
                  !retainedPositionIDs.contains(account.id) else { return nil }
            return account.id
        })
        if !activeOrphanPositionIDs.isEmpty {
            recoveryIssues.append(contentsOf: activeOrphanPositionIDs.map {
                "accounts/orphan-investment-position-\($0)"
            })
            accounts.removeAll { activeOrphanPositionIDs.contains($0.id) }
            accountIDs.subtract(activeOrphanPositionIDs)
            entries.removeAll { entry in
                entry.postings.contains {
                    activeOrphanPositionIDs.contains($0.accountID)
                }
            }
            scheduledTransactions.removeAll { schedule in
                activeOrphanPositionIDs.contains(schedule.accountID)
                    || activeOrphanPositionIDs.contains(
                        schedule.categoryAccountID
                    )
            }
        }
        let retainedInvestmentEntryIDs = Set(
            investmentHoldings.flatMap { Array($0.linkedEntryIDs) }
        )
        investmentLinkedEntriesByID = investmentLinkedEntriesByID.filter {
            retainedInvestmentEntryIDs.contains($0.key)
        }
        let attachmentEntryIDs = existingAttachmentEntryIDs
            ?? Set(entries.map(\.id))
        var seenAttachmentIDs = Set<UUID>()
        receiptAttachmentMetadata.removeAll { attachment in
            let duplicate = !seenAttachmentIDs.insert(attachment.id).inserted
            let invalid = duplicate
                || !attachmentEntryIDs.contains(attachment.entryID)
            if duplicate {
                recoveryIssues.append("receipt_attachments/duplicate-\(attachment.id)")
            } else if invalid {
                recoveryIssues.append("receipt_attachments/orphan-\(attachment.id)")
            }
            return invalid
        }
        var seenGoalIDs = Set<UUID>()
        savingsGoals = savingsGoals.filter { goal in
            let unique = seenGoalIDs.insert(goal.id).inserted
            if !unique { recoveryIssues.append("savings_goals/duplicate-\(goal.id)") }
            return unique
        }
    }

    /// Normal unlock keeps the rest of a readable book available when a
    /// holding's reconstructed market value disagrees with its ledger account.
    /// Restore validation deliberately skips this repair and rejects instead.
    @discardableResult
    private func quarantineInvestmentLedgerMismatches() -> Bool {
        guard case let .available(balances) = accountBalancesResult() else {
            return false
        }
        var invalidHoldingIDs = Set<UUID>()
        var invalidPositionIDs = Set<UUID>()
        for holding in investmentHoldings {
            guard let positionID = holding.positionAccountID,
                  let funding = accountsByID[holding.accountID],
                  let currency = funding.currency else { continue }
            let expected: Money
            do {
                expected = try holding.marketValue()
                    ?? Money.zero(currency: currency)
            } catch {
                invalidHoldingIDs.insert(holding.id)
                invalidPositionIDs.insert(positionID)
                continue
            }
            let positionBalances = balances[positionID] ?? [:]
            let hasForeignBalance = positionBalances.contains {
                $0.key != currency && !$0.value.isZero
            }
            let actual = positionBalances[currency]
                ?? Money.zero(currency: currency)
            if hasForeignBalance || actual != expected {
                invalidHoldingIDs.insert(holding.id)
                invalidPositionIDs.insert(positionID)
            }
        }
        if !invalidHoldingIDs.isEmpty {
            recoveryIssues.append("investment_holdings/ledger-mismatch")
            investmentHoldings.removeAll { invalidHoldingIDs.contains($0.id) }
        }

        let retainedPositionIDs = Set(investmentHoldings.compactMap(\.positionAccountID))
        for position in accounts where position.systemRole == .investmentPosition
            && !retainedPositionIDs.contains(position.id) {
            let positionBalances = balances[position.id] ?? [:]
            if !position.isArchived
                || positionBalances.values.contains(where: { !$0.isZero }) {
                invalidPositionIDs.insert(position.id)
            }
        }
        guard !invalidPositionIDs.isEmpty else { return false }
        if !recoveryIssues.contains("accounts/orphan-investment-position") {
            recoveryIssues.append("accounts/orphan-investment-position")
        }
        accounts.removeAll { invalidPositionIDs.contains($0.id) }
        scheduledTransactions.removeAll { schedule in
            invalidPositionIDs.contains(schedule.accountID)
                || invalidPositionIDs.contains(schedule.categoryAccountID)
        }
        let retainedInvestmentEntryIDs = Set(
            investmentHoldings.flatMap { Array($0.linkedEntryIDs) }
        )
        investmentLinkedEntriesByID = investmentLinkedEntriesByID.filter {
            retainedInvestmentEntryIDs.contains($0.key)
        }
        existingScheduledLinkedEntryIDs = Set(
            scheduledTransactions.flatMap(\.resolutions).compactMap(\.linkedEntryID)
        )
        return true
    }

    private func reassignAndDeleteLedgerItem(
        id sourceID: UUID,
        to targetID: UUID,
        action: LedgerAccountLifecycleAction
    ) async throws {
        await finishPendingQuickLogDraftWrite()
        guard let source = accounts.first(where: { $0.id == sourceID }),
              let target = accounts.first(where: { $0.id == targetID }) else {
            throw AppModelError.missingRecord
        }
        try requireLifecycleEligible(source)
        try requireLifecycleEligible(target)
        guard sourceID != targetID else { throw AppModelError.incompatibleLedgerItems }
        guard !target.isArchived,
              source.kind == target.kind,
              source.currency == target.currency else {
            throw AppModelError.incompatibleLedgerItems
        }
        if investmentHoldings.contains(where: {
            $0.accountID == sourceID && $0.positionAccountID != nil
        }),
           !isInvestmentFundingAccountShape(target) {
            throw AppModelError.incompatibleLedgerItems
        }

        let candidateAccounts = try accountsAfterReassigningCategoryHierarchy(
            source: source,
            target: target
        )
        let candidateBudgets = try budgetsAfterReassigningCategoryHierarchy(
            source: source,
            target: target,
            candidateAccounts: candidateAccounts
        )
        let candidateTimeline: BudgetConfigurationTimeline?
        if source.kind == .expense {
            candidateTimeline = try budgetConfigurationTimelineRecording(
                nodes: candidateBudgets,
                carryMappings: [BudgetCarryMapping(
                    sourceID: sourceID,
                    targetID: targetID
                )]
            )
        } else {
            candidateTimeline = nil
        }

        let sourceEntries: [JournalEntry]
        if retainsCompleteJournal {
            sourceEntries = entries
        } else {
            // Account merge/delete is explicitly confirmed and may touch every
            // historical row. Page it on demand, commit all replacements in
            // one SQLCipher transaction, then release this temporary array.
            sourceEntries = try await journalSnapshot(
                includeInvalidRelationships: true
            )
        }
        var originalEntriesByID: [UUID: JournalEntry] = [:]
        let candidateEntries = try sourceEntries.map { entry in
            guard entry.postings.contains(where: { $0.accountID == sourceID }) else {
                return entry
            }
            originalEntriesByID[entry.id] = entry
            return try repoint(entry: entry, from: sourceID, to: targetID)
        }
        let lifecycleStore = try requireStore()
        if source.kind == .expense {
            try await loadCompleteBudgetAttributionCacheIfNeeded(
                from: lifecycleStore
            )
        }
        var candidateBudgetAttributions = budgetEntryAttributions
        var newBudgetAttributions: [BudgetEntryAttribution] = []
        if source.kind == .expense {
            for original in originalEntriesByID.values
            where candidateBudgetAttributions[original.id] == nil {
                let attribution = try BudgetEntryAttribution(
                    entry: original,
                    originTimeZoneIdentifier: profile?.reportingTimeZoneIdentifier
                        ?? reportingCalendar.timeZone.identifier
                )
                candidateBudgetAttributions[original.id] = attribution
                newBudgetAttributions.append(attribution)
            }
        }

        var changedScheduleIDs = Set<UUID>()
        let candidateSchedules = scheduledTransactions.map { schedule -> ScheduledTransaction in
            var updated = schedule
            if updated.accountID == sourceID {
                updated.accountID = targetID
                changedScheduleIDs.insert(updated.id)
            }
            if updated.categoryAccountID == sourceID {
                updated.categoryAccountID = targetID
                changedScheduleIDs.insert(updated.id)
            }
            return updated
        }

        var changedHoldingIDs = Set<UUID>()
        let candidateHoldings = investmentHoldings.map { holding -> InvestmentHolding in
            var updated = holding
            if updated.accountID == sourceID {
                updated.accountID = targetID
                changedHoldingIDs.insert(updated.id)
            }
            return updated
        }

        try validateLifecycleRelationshipCandidates(
            accounts: candidateAccounts,
            entries: candidateEntries,
            schedules: candidateSchedules,
            holdings: candidateHoldings
        )

        var candidateProfile = profile
        var candidateDraft = quickLogDraft
        repointReferences(from: sourceID, to: targetID, in: &candidateProfile)
        repointReferences(from: sourceID, to: targetID, in: &candidateDraft)

        guard let resultingTarget = candidateAccounts.first(where: { $0.id == targetID }) else {
            throw AppModelError.invalidBook
        }
        let audit = LedgerAccountLifecycleAudit(
            action: action,
            before: source,
            after: resultingTarget,
            targetID: targetID,
            beforeBudget: budgetNodes.first { $0.id == sourceID },
            afterBudget: candidateBudgets.first { $0.id == targetID },
            affectedJournalEntryIDs: Array(originalEntriesByID.keys),
            affectedScheduleIDs: Array(changedScheduleIDs),
            affectedHoldingIDs: Array(changedHoldingIDs)
        )

        var writes: [RecordWrite] = []
        let originalAccountsByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        for account in candidateAccounts
        where originalAccountsByID[account.id] != account {
            writes.append(
                try RecordWrite(account, id: account.id.uuidString, in: .accounts)
            )
        }

        for entry in candidateEntries where originalEntriesByID[entry.id] != nil {
            guard let original = originalEntriesByID[entry.id] else { continue }
            writes.append(
                try RecordWrite(
                    original,
                    id: "\(original.id.uuidString)-lifecycle-\(audit.id.uuidString)",
                    in: .journalEntryRevisions
                )
            )
            writes.append(
                try RecordWrite(entry, id: entry.id.uuidString, in: .journalEntries)
            )
        }
        writes += try newBudgetAttributions.map {
            try RecordWrite(
                $0,
                id: $0.id.uuidString,
                in: .budgetEntryAttributions
            )
        }

        let originalBudgetsByID = Dictionary(uniqueKeysWithValues: budgetNodes.map { ($0.id, $0) })
        for node in candidateBudgets where originalBudgetsByID[node.id] != node {
            writes.append(try RecordWrite(node, id: node.id.uuidString, in: .budgetNodes))
        }
        if let candidateTimeline {
            writes.append(try budgetConfigurationTimelineWrite(candidateTimeline))
        }
        for schedule in candidateSchedules where changedScheduleIDs.contains(schedule.id) {
            writes.append(
                try RecordWrite(
                    schedule,
                    id: schedule.id.uuidString,
                    in: .scheduledTransactions
                )
            )
        }
        for holding in candidateHoldings where changedHoldingIDs.contains(holding.id) {
            writes.append(
                try RecordWrite(
                    holding,
                    id: holding.id.uuidString,
                    in: .investmentHoldings
                )
            )
        }
        if candidateProfile != profile, let candidateProfile {
            writes.append(
                try RecordWrite(
                    candidateProfile,
                    id: UserProfile.primaryRecordID,
                    in: .profile
                )
            )
        }
        if candidateDraft != quickLogDraft, let candidateDraft {
            writes.append(
                try RecordWrite(
                    candidateDraft,
                    id: QuickLogDraft.primaryRecordID,
                    in: .quickLogDrafts
                )
            )
        }
        writes.append(try lifecycleAuditWrite(audit))

        var deletions = [RecordDeletion(id: sourceID.uuidString, from: .accounts)]
        if source.kind == .expense,
           budgetNodes.contains(where: { $0.id == sourceID }) {
            deletions.append(
                RecordDeletion(id: sourceID.uuidString, from: .budgetNodes)
            )
        }

        let generation = storeGeneration
        invalidateCommittedJournalProjection()
        await lifecycleHooks.checkpoint(
            .afterJournalProjectionInvalidationBeforeCommit
        )
        try await lifecycleStore.write(writes, removing: deletions)
        guard isCurrentStoreGeneration(generation) else { return }

        accounts = candidateAccounts
        if retainsCompleteJournal { entries = candidateEntries }
        budgetEntryAttributions = candidateBudgetAttributions
        if let candidateTimeline { budgetConfigurationTimeline = candidateTimeline }
        budgetNodes = candidateBudgets
        scheduledTransactions = candidateSchedules.sorted {
            $0.nextOccurrence < $1.nextOccurrence
        }
        investmentHoldings = candidateHoldings
        profile = candidateProfile
        quickLogDraft = candidateDraft
        await refreshJournalAfterMutation()
    }

    private func validateLifecycleRelationshipCandidates(
        accounts candidateAccounts: [LedgerAccount],
        entries candidateEntries: [JournalEntry],
        schedules candidateSchedules: [ScheduledTransaction],
        holdings candidateHoldings: [InvestmentHolding]
    ) throws {
        guard Set(candidateAccounts.map(\.id)).count == candidateAccounts.count,
              Set(candidateSchedules.map(\.id)).count == candidateSchedules.count,
              Set(candidateHoldings.map(\.id)).count == candidateHoldings.count else {
            throw AppModelError.invalidBook
        }
        let accountsByID = Dictionary(
            uniqueKeysWithValues: candidateAccounts.map { ($0.id, $0) }
        )
        for schedule in candidateSchedules {
            try validateScheduleReferences(schedule, in: accountsByID)
            try schedule.validateLifecycle(calendar: reportingCalendar)
        }
        let scheduleLinks = candidateSchedules.flatMap {
            $0.resolutions.compactMap(\.linkedEntryID)
        }
        guard Set(scheduleLinks).count == scheduleLinks.count else {
            throw AppModelError.invalidBook
        }

        var entriesByID: [UUID: JournalEntry] = [:]
        for entry in candidateEntries {
            guard entriesByID.updateValue(entry, forKey: entry.id) == nil else {
                throw AppModelError.invalidBook
            }
        }
        var positionOwners = Set<UUID>()
        var entryOwners = Set<UUID>()
        for holding in candidateHoldings {
            let isUnconnectedLegacyHolding = holding.positionAccountID == nil
            guard let funding = accountsByID[holding.accountID],
                  (isUnconnectedLegacyHolding
                    ? funding.kind == .asset
                        && funding.systemRole == nil
                        && funding.currency != nil
                    : isInvestmentFundingAccountShape(funding)),
                  holding.isArchived || !funding.isArchived else {
                throw AppModelError.incompatibleLedgerItems
            }
            guard holding.linkedEntryIDs.isDisjoint(with: entryOwners) else {
                throw AppModelError.invalidBook
            }
            entryOwners.formUnion(holding.linkedEntryIDs)
            guard let positionID = holding.positionAccountID else {
                guard !holding.isArchived,
                      holding.linkedEntryIDs.isEmpty,
                      holding.quantity == .zero || holding.needsLedgerConnection else {
                    throw AppModelError.invalidBook
                }
                continue
            }
            guard positionOwners.insert(positionID).inserted,
                  let position = accountsByID[positionID],
                  position.isArchived == holding.isArchived else {
                throw AppModelError.invalidBook
            }
            do {
                try InvestmentLedgerIntegrity.validate(
                    holding: holding,
                    accountsByID: accountsByID,
                    entriesByID: entriesByID
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AppModelError.invalidBook
            }
        }
    }

    private func accountsAfterReassigningCategoryHierarchy(
        source: LedgerAccount,
        target: LedgerAccount
    ) throws -> [LedgerAccount] {
        var candidate = accounts.filter { $0.id != source.id }
        guard source.kind == .expense || source.kind == .income else { return candidate }

        let targetWasDescendant = isDescendant(
            target.id,
            of: source.id,
            in: accounts
        )
        for index in candidate.indices {
            if candidate[index].id == target.id, targetWasDescendant {
                candidate[index].parentID = source.parentID
            } else if candidate[index].parentID == source.id {
                candidate[index].parentID = target.id
            }
        }
        try validateCategoryHierarchy(accounts: candidate)
        return candidate
    }

    private func budgetsAfterReassigningCategoryHierarchy(
        source: LedgerAccount,
        target: LedgerAccount,
        candidateAccounts: [LedgerAccount]
    ) throws -> [BudgetNode] {
        guard source.kind == .expense else { return budgetNodes }
        guard let currency = profile?.baseCurrency else { throw AppModelError.invalidBook }

        let sourceNode = budgetNodes.first { $0.id == source.id }
        var candidate = budgetNodes.filter { $0.id != source.id }
        let accountByID = Dictionary(
            uniqueKeysWithValues: candidateAccounts.map { ($0.id, $0) }
        )

        if let sourceNode {
            if let targetIndex = candidate.firstIndex(where: { $0.id == target.id }) {
                if let sourceLimit = sourceNode.limit {
                    if let targetLimit = candidate[targetIndex].limit {
                        candidate[targetIndex].limit = try targetLimit.adding(sourceLimit)
                    } else {
                        candidate[targetIndex].limit = sourceLimit
                    }
                }
                if candidate[targetIndex].purpose == .unclassified {
                    candidate[targetIndex].purpose = sourceNode.purpose
                }
                if candidate[targetIndex].rolloverRule == .none,
                   sourceNode.rolloverRule != .none {
                    candidate[targetIndex].rolloverRule = sourceNode.rolloverRule
                    candidate[targetIndex].rolloverStartedAt = sourceNode.rolloverStartedAt
                }
            } else {
                candidate.append(
                    BudgetNode(
                        id: target.id,
                        parentID: accountByID[target.id]?.parentID,
                        name: target.name,
                        limit: sourceNode.limit,
                        purpose: sourceNode.purpose,
                        rolloverRule: sourceNode.rolloverRule,
                        rolloverStartedAt: sourceNode.rolloverStartedAt
                    )
                )
            }
        }

        let directlyAffectedIDs = Set(
            [target.id] + budgetNodes.filter { $0.parentID == source.id }.map(\.id)
        )
        for index in candidate.indices where directlyAffectedIDs.contains(candidate[index].id) {
            guard let account = accountByID[candidate[index].id] else {
                throw AppModelError.invalidBook
            }
            candidate[index].parentID = account.parentID
            if candidate[index].id == target.id {
                candidate[index].name = account.name
            }
        }

        _ = try BudgetTree(currency: currency, nodes: candidate)
        return candidate
    }

    private func repoint(
        entry: JournalEntry,
        from sourceID: UUID,
        to targetID: UUID
    ) throws -> JournalEntry {
        let postings = entry.postings.map { posting in
            guard posting.accountID == sourceID else { return posting }
            return Posting(
                id: posting.id,
                accountID: targetID,
                money: posting.money,
                memo: posting.memo
            )
        }
        return try JournalEntry(
            id: entry.id,
            kind: entry.kind,
            occurredAt: entry.occurredAt,
            createdAt: entry.createdAt,
            payee: entry.payee,
            note: entry.note,
            postings: postings,
            supersedesID: entry.supersedesID,
            revisedAt: entry.revisedAt,
            sourceSystem: entry.sourceSystem,
            sourceFingerprint: entry.sourceFingerprint,
            originContext: entry.originContext
        )
    }

    private func isDescendant(
        _ candidateID: UUID,
        of ancestorID: UUID,
        in sourceAccounts: [LedgerAccount]
    ) -> Bool {
        let parentByID = Dictionary(
            uniqueKeysWithValues: sourceAccounts.compactMap { account in
                account.parentID.map { (account.id, $0) }
            }
        )
        var currentID: UUID? = candidateID
        var visited = Set<UUID>()
        while let id = currentID, visited.insert(id).inserted {
            guard let parent = parentByID[id] else { return false }
            if parent == ancestorID { return true }
            currentID = parent
        }
        return false
    }

    private func validateCategoryHierarchy(
        accounts candidateAccounts: [LedgerAccount]
    ) throws {
        guard try Self.invalidAccountHierarchyIDs(
            in: candidateAccounts
        ).isEmpty else {
            throw AppModelError.incompatibleLedgerItems
        }
    }

    private func requireLifecycleEligible(_ account: LedgerAccount) throws {
        guard account.systemRole == nil else {
            throw AppModelError.systemAccountLifecycleForbidden
        }
        guard account.kind == .asset
                || account.kind == .liability
                || account.kind == .expense
                || account.kind == .income else {
            throw AppModelError.incompatibleLedgerItems
        }
    }

    private func lifecycleAuditWrite(
        _ audit: LedgerAccountLifecycleAudit
    ) throws -> RecordWrite {
        try RecordWrite(
            audit,
            id: audit.id.uuidString,
            in: .accountLifecycleAudit
        )
    }

    private func clearReferences(to id: UUID, in profile: inout UserProfile?) {
        guard var updated = profile else { return }
        if updated.preferredAccountID == id { updated.preferredAccountID = nil }
        if updated.preferredExpenseCategoryID == id {
            updated.preferredExpenseCategoryID = nil
        }
        if updated.preferredIncomeCategoryID == id {
            updated.preferredIncomeCategoryID = nil
        }
        profile = updated
    }

    private func clearReferences(to id: UUID, in draft: inout QuickLogDraft?) {
        guard var updated = draft else { return }
        if updated.accountID == id { updated.accountID = nil }
        if updated.destinationAccountID == id { updated.destinationAccountID = nil }
        if updated.categoryID == id { updated.categoryID = nil }
        draft = updated
    }

    private func repointReferences(
        from sourceID: UUID,
        to targetID: UUID,
        in profile: inout UserProfile?
    ) {
        guard var updated = profile else { return }
        if updated.preferredAccountID == sourceID { updated.preferredAccountID = targetID }
        if updated.preferredExpenseCategoryID == sourceID {
            updated.preferredExpenseCategoryID = targetID
        }
        if updated.preferredIncomeCategoryID == sourceID {
            updated.preferredIncomeCategoryID = targetID
        }
        profile = updated
    }

    private func repointReferences(
        from sourceID: UUID,
        to targetID: UUID,
        in draft: inout QuickLogDraft?
    ) {
        guard var updated = draft else { return }
        if updated.accountID == sourceID { updated.accountID = targetID }
        if updated.destinationAccountID == sourceID {
            updated.destinationAccountID = targetID
        }
        if updated.categoryID == sourceID { updated.categoryID = targetID }
        if updated.accountID == updated.destinationAccountID {
            updated.destinationAccountID = nil
        }
        draft = updated
    }

    private func finishPendingQuickLogDraftWrite() async {
        while let pendingWrite = quickLogDraftWriteTask {
            quickLogDraftWriteTask = nil
            pendingWrite.cancel()
            await pendingWrite.value
        }
    }

    /// Creates an exact durable draft boundary for a backup. Unlike restore's
    /// authoritative replacement barrier, backup must not cancel a debounce:
    /// cancellation can discard the newest form revision. Await the chain and
    /// then write the in-memory value with error propagation before snapshot.
    private func flushQuickLogDraftForBackup(
        to backupStore: EncryptedRecordStore
    ) async throws {
        await quickLogDraftWriteTask?.value
        if let quickLogDraft {
            try await backupStore.upsert(
                quickLogDraft,
                id: QuickLogDraft.primaryRecordID,
                in: .quickLogDrafts
            )
        } else {
            try await backupStore.remove(
                id: QuickLogDraft.primaryRecordID,
                from: .quickLogDrafts
            )
        }
    }

    private func requireEmptyLockedCaptureInbox() async throws {
        do {
            let captures = try await lockedCaptureStore.all()
            pendingLockedCaptureCount = captures.count
            recoveryIssues.removeAll { $0.hasPrefix("locked_captures/") }
            guard captures.isEmpty else {
                throw AppModelError.pendingLockedCaptures
            }
        } catch let error as LockedCaptureStoreError {
            recordLockedCaptureStoreIssue(error)
            throw error
        }
    }

    /// Explicitly discards only an inbox that is already cryptographically
    /// unreadable. The authenticated main book remains untouched, restoring
    /// backup/restore availability without pretending the lost captures can
    /// be recovered.
    func discardUnavailableLockedCaptures() async throws {
        let hasUsableRecoveryStore: Bool
        switch state {
        case .ready, .onboarding:
            hasUsableRecoveryStore = true
        case .failed:
            hasUsableRecoveryStore = store != nil
        case .launching, .locked:
            hasUsableRecoveryStore = false
        }
        guard hasUsableRecoveryStore, lockedCaptureInboxIsUnrecoverable else {
            throw AppModelError.missingRecord
        }
        try beginLifecycleMutation(invalidatesJournalProjection: false)
        defer { endLifecycleMutation() }

        // The marker can outlive a transient Keychain state change. Re-read at
        // the destructive boundary: successful recovery or a retryable failure
        // must disable deletion, while only a fresh definitive failure permits
        // erasing the orphaned inbox.
        do {
            let captures = try await lockedCaptureStore.all()
            pendingLockedCaptureCount = captures.count
            recoveryIssues.removeAll { $0.hasPrefix("locked_captures/") }
            if captures.isEmpty {
                throw AppModelError.missingRecord
            }
            throw AppModelError.pendingLockedCaptures
        } catch let error as LockedCaptureStoreError {
            recordLockedCaptureStoreIssue(error)
            guard error.isDefinitivelyUnrecoverable else { throw error }
        }
        try await lockedCaptureStore.eraseAll()
        pendingLockedCaptureCount = 0
        recoveryIssues.removeAll { $0.hasPrefix("locked_captures/") }
    }

    private func beginLifecycleMutation(
        invalidatesJournalProjection: Bool = true
    ) throws {
        guard !isLifecycleMutationInProgress,
              !isWorking,
              goalMutationsInProgress == 0,
              !goalMutationBarrierClosed,
              !isJournalMutationInProgress,
              scheduleMutationsInProgress.isEmpty,
              scheduleEntryMatchesInProgress.isEmpty,
              investmentMutationsInProgress.isEmpty else {
            throw AppModelError.transactionInProgress
        }
        isLifecycleMutationInProgress = true
        if invalidatesJournalProjection {
            invalidateInFlightJournalProjection()
        }
    }

    private func beginStandaloneJournalMutation() throws {
        guard !isLifecycleMutationInProgress,
              !isWorking,
              !isJournalMutationInProgress,
              state == .ready else {
            throw AppModelError.transactionInProgress
        }
        standaloneJournalMutationsInProgress += 1
        invalidateInFlightJournalProjection()
    }

    private func endStandaloneJournalMutation() {
        guard standaloneJournalMutationsInProgress > 0 else { return }
        standaloneJournalMutationsInProgress -= 1
        guard standaloneJournalMutationsInProgress == 0 else { return }
        applyDeferredLockIfPossible()
        resumeDeferredJournalDerivedRefreshIfPossible()
    }

    private func endLifecycleMutation() {
        isLifecycleMutationInProgress = false
        applyDeferredLockIfPossible()
        resumeDeferredJournalDerivedRefreshIfPossible()
    }

    private func beginJournalMutation(
        invalidatesJournalProjection: Bool = true
    ) throws {
        guard !isLifecycleMutationInProgress,
              !isWorking,
              state == .ready,
              !isJournalMutationInProgress,
              scheduleMutationsInProgress.isEmpty,
              scheduleEntryMatchesInProgress.isEmpty,
              investmentMutationsInProgress.isEmpty else {
            throw AppModelError.transactionInProgress
        }
        manualJournalMutationIsActive = true
        if invalidatesJournalProjection {
            invalidateInFlightJournalProjection()
        }
    }

    private func endJournalMutation() {
        manualJournalMutationIsActive = false
        applyDeferredLockIfPossible()
        resumeDeferredJournalDerivedRefreshIfPossible()
    }

    private func applyDeferredLockIfPossible() {
        guard lockAfterLifecycleMutation,
              !isLifecycleMutationInProgress,
              !isJournalMutationInProgress,
              scheduleMutationsInProgress.isEmpty,
              scheduleEntryMatchesInProgress.isEmpty,
              investmentMutationsInProgress.isEmpty else { return }
        lockAfterLifecycleMutation = false
        lock()
    }

    private func beginGoalMutation() throws {
        guard !isLifecycleMutationInProgress,
              !goalMutationBarrierClosed,
              !isWorking,
              state == .ready else {
            throw AppModelError.transactionInProgress
        }
        goalMutationsInProgress += 1
    }

    private func endGoalMutation() {
        guard goalMutationsInProgress > 0 else { return }
        goalMutationsInProgress -= 1
        guard goalMutationsInProgress == 0 else { return }
        let waiters = goalMutationDrainWaiters
        goalMutationDrainWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard lockAfterLifecycleMutation,
              !isLifecycleMutationInProgress,
              !isWorking else { return }
        lockAfterLifecycleMutation = false
        lock()
    }

    private func waitForGoalMutationDrain() async {
        guard goalMutationsInProgress > 0 else { return }
        await withCheckedContinuation { continuation in
            goalMutationDrainWaiters.append(continuation)
        }
    }

    private func finishExclusiveDataLifecycleMutation() {
        goalMutationBarrierClosed = false
        isWorking = false
        endLifecycleMutation()
    }

    private func requireStore() throws -> EncryptedRecordStore {
        guard let store else { throw AppModelError.locked }
        return store
    }

    /// A missing profile is onboarding only when every durable book
    /// collection is truly empty. Decode quarantine must not turn an orphaned
    /// journal, audit, goal, or derived-accounting record into a fresh book.
    static func containsPersistedBookData(
        in store: EncryptedRecordStore
    ) async throws -> Bool {
        for collection in RecordCollection.allCases
        where collection != .profile && collection != .quickLogDrafts {
            if try await store.count(in: collection) > 0 { return true }
        }
        return false
    }

    private func isCurrentStoreGeneration(_ generation: Int) -> Bool {
        ownsStoreGeneration(generation)
            && (state == .ready || state == .onboarding)
    }

    private func ownsStoreGeneration(_ generation: Int) -> Bool {
        generation == storeGeneration && store != nil
    }

    private func currency(for accountID: UUID) throws -> CurrencyCode {
        guard let account = accounts.first(where: { $0.id == accountID }),
              !account.isArchived else {
            throw AppModelError.ledgerItemArchived
        }
        guard account.systemRole == nil else {
            throw AppModelError.systemAccountLifecycleForbidden
        }
        guard account.kind == .asset || account.kind == .liability,
              let currency = account.currency else {
            throw AppModelError.accountHasNoCurrency
        }
        return currency
    }

    /// History corrections may keep an archived user account already present
    /// on the source entry. They must not make an archived account newly
    /// spendable, and hidden system accounts are never valid editor choices.
    private func replacementCurrency(
        for accountID: UUID,
        preservingFrom original: JournalEntry
    ) throws -> CurrencyCode {
        guard let account = accounts.first(where: { $0.id == accountID }) else {
            throw AppModelError.missingRecord
        }
        guard account.systemRole == nil else {
            throw AppModelError.systemAccountLifecycleForbidden
        }
        guard account.kind == .asset || account.kind == .liability,
              let currency = account.currency else {
            throw AppModelError.accountHasNoCurrency
        }
        guard !account.isArchived || original.postings.contains(where: {
            $0.accountID == accountID
        }) else {
            throw AppModelError.ledgerItemArchived
        }
        return currency
    }

    private func requireActiveCategory(
        _ id: UUID,
        kind: LedgerAccountKind
    ) throws {
        guard let category = accounts.first(where: { $0.id == id }) else {
            throw AppModelError.missingRecord
        }
        guard !category.isArchived else { throw AppModelError.ledgerItemArchived }
        guard category.systemRole == nil else {
            throw AppModelError.systemAccountLifecycleForbidden
        }
        guard category.kind == kind else {
            throw AppModelError.invalidCategoryKind
        }
    }

    /// Mirrors `replacementCurrency`: an archived category is valid only when
    /// it is part of the historical transaction being corrected.
    private func requireReplacementCategory(
        _ id: UUID,
        kind: LedgerAccountKind,
        preservingFrom original: JournalEntry
    ) throws {
        guard let category = accounts.first(where: { $0.id == id }) else {
            throw AppModelError.missingRecord
        }
        guard category.systemRole == nil else {
            throw AppModelError.systemAccountLifecycleForbidden
        }
        guard category.kind == kind else {
            throw AppModelError.invalidCategoryKind
        }
        guard !category.isArchived || original.postings.contains(where: {
            $0.accountID == id
        }) else {
            throw AppModelError.ledgerItemArchived
        }
    }

    private func editableMoneySnapshot(
        for entry: JournalEntry
    ) throws -> EditableMoneySnapshot? {
        let accountKinds = Dictionary(
            uniqueKeysWithValues: accounts.map { ($0.id, $0.kind) }
        )

        func positiveMoney(from posting: Posting) throws -> Money {
            do {
                return try Money(
                    abs(posting.money.amount),
                    currency: posting.money.currency
                )
            } catch {
                DerivedValueDiagnostics.record(
                    .amountCalculationFailed,
                    operation: "editable-money-snapshot",
                    error: error
                )
                throw DerivedValueIssue.amountCalculationFailed
            }
        }

        switch entry.kind {
        case .expense:
            guard let posting = entry.postings.first(where: {
                accountKinds[$0.accountID] == .asset
                    || accountKinds[$0.accountID] == .liability
            }) ?? entry.postings.first(where: {
                accountKinds[$0.accountID] == .expense
            }) else { return nil }
            let source = try positiveMoney(from: posting)
            return EditableMoneySnapshot(source: source, destination: nil)
        case .income:
            guard let posting = entry.postings.first(where: {
                accountKinds[$0.accountID] == .asset
                    || accountKinds[$0.accountID] == .liability
            }) ?? entry.postings.first(where: {
                accountKinds[$0.accountID] == .income
            }) else { return nil }
            let source = try positiveMoney(from: posting)
            return EditableMoneySnapshot(source: source, destination: nil)
        case .transfer:
            let userPostings = entry.postings.filter {
                accountKinds[$0.accountID] == .asset
                    || accountKinds[$0.accountID] == .liability
            }
            guard let sourcePosting = userPostings.first(where: {
                $0.money.amount < .zero
            }), let destinationPosting = userPostings.first(where: {
                $0.money.amount > .zero
            }) else { return nil }
            let source = try positiveMoney(from: sourcePosting)
            let destination = try positiveMoney(from: destinationPosting)
            return EditableMoneySnapshot(source: source, destination: destination)
        case .adjustment, .investment:
            return nil
        }
    }

    private func reportingOriginContext(
        for occurredAt: Date,
        reportingTimeZoneIdentifier: String? = nil
    ) -> TransactionOriginContext {
        let calendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: reportingTimeZoneIdentifier
                ?? profile?.reportingTimeZoneIdentifier
                ?? TimeZone.current.identifier
        )
        return .capture(
            for: occurredAt,
            calendar: calendar,
            timeZone: calendar.timeZone
        )
    }

    /// All entries authored by MoneyUp use the encrypted profile's fixed
    /// reporting zone. Device travel must not move a DatePicker selection to
    /// an adjacent financial day before it reaches the normalized index.
    private func appAuthoredEntry(
        _ entry: JournalEntry,
        reportingTimeZoneIdentifier: String? = nil,
        sourceSystemOverride: String? = nil,
        sourceFingerprintOverride: String? = nil
    ) throws -> JournalEntry {
        try JournalEntry(
            id: entry.id,
            kind: entry.kind,
            occurredAt: entry.occurredAt,
            createdAt: entry.createdAt,
            payee: entry.payee,
            note: entry.note,
            postings: entry.postings,
            supersedesID: entry.supersedesID,
            revisedAt: entry.revisedAt,
            sourceSystem: sourceSystemOverride ?? entry.sourceSystem,
            sourceFingerprint: sourceFingerprintOverride ?? entry.sourceFingerprint,
            originContext: reportingOriginContext(
                for: entry.occurredAt,
                reportingTimeZoneIdentifier: reportingTimeZoneIdentifier
            )
        )
    }

    private func openingBalancesAccount() -> LedgerAccount {
        accounts.first(where: { $0.systemRole == .openingBalances })
            ?? LedgerAccount(
                name: String(localized: "account.opening_balances"),
                kind: .equity,
                systemRole: .openingBalances
            )
    }

    private func requireValidNewWriteAmount(
        _ amount: Decimal,
        currency: CurrencyCode,
        preserving originalAmount: Decimal? = nil
    ) throws {
        do {
            try MonetaryInputPolicy.validate(
                amount,
                currency: currency,
                preserving: originalAmount
            )
        } catch MoneyError.unsupportedPrecision(_) {
            throw AppModelError.unsupportedPrecision(currency)
        } catch MoneyError.exceedsNewWriteMaximum(_) {
            throw AppModelError.amountTooLarge
        } catch {
            throw error
        }
    }

    private func foreignExchangeAccount(for currency: CurrencyCode) -> LedgerAccount {
        accounts.first {
            $0.systemRole == .foreignExchange && $0.currency == currency
        } ?? LedgerAccount(
            name: "\(String(localized: "account.fx_clearing")) \(currency.value)",
            kind: .trading,
            currency: currency,
            systemRole: .foreignExchange
        )
    }

    private func investmentGainLossAccount(for currency: CurrencyCode) -> LedgerAccount {
        accounts.first {
            $0.systemRole == .investmentGainLoss && $0.currency == currency
        } ?? LedgerAccount(
            name: "\(String(localized: "holding.gain_loss")) \(currency.value)",
            kind: .trading,
            currency: currency,
            systemRole: .investmentGainLoss
        )
    }

    /// System adjustments and investment events require dedicated compensating
    /// workflows. Generic mutation would either erase reconciliation evidence
    /// or split persisted holding metadata from the authoritative journal.
    func isProtectedJournalEntry(_ entry: JournalEntry) -> Bool {
        entry.kind == .adjustment || entry.kind == .investment || entry.postings.contains {
            accountsByID[$0.accountID]?.systemRole == .investmentPosition
        }
    }

    private func isEligibleInvestmentFundingAccount(
        _ account: LedgerAccount
    ) -> Bool {
        !account.isArchived && isInvestmentFundingAccountShape(account)
    }

    private func isInvestmentFundingAccountShape(
        _ account: LedgerAccount
    ) -> Bool {
        account.kind == .asset
            && account.systemRole == nil
            && (account.accountType == .brokerage
                || account.accountType == .investment)
            && account.currency != nil
    }

    private func linkedInvestmentAccounts(
        for holding: InvestmentHolding
    ) -> (
        funding: LedgerAccount,
        position: LedgerAccount,
        currency: CurrencyCode
    )? {
        guard let positionID = holding.positionAccountID,
              positionID != holding.accountID,
              let funding = accountsByID[holding.accountID],
              isEligibleInvestmentFundingAccount(funding),
              let currency = funding.currency,
              let position = accountsByID[positionID],
              !position.isArchived,
              position.kind == .asset,
              position.systemRole == .investmentPosition,
              position.currency == currency else {
            return nil
        }
        return (funding, position, currency)
    }

    private func investmentOriginContext(for date: Date) -> TransactionOriginContext {
        reportingOriginContext(for: date)
    }

    private func validatedInvestmentPositionValue(
        quantity: Decimal,
        unitPrice: Money
    ) throws -> Money {
        let value: Money
        do {
            value = try InvestmentHolding.positionValue(
                quantity: quantity,
                unitPrice: unitPrice
            )
        } catch InvestmentHoldingError.arithmeticOverflow {
            throw AppModelError.amountTooLarge
        }
        try requireValidNewWriteAmount(value.amount, currency: value.currency)
        return value
    }

    private func validatedInvestmentMarketValue(
        _ holding: InvestmentHolding
    ) throws -> Money? {
        guard let price = holding.price else { return nil }
        return try validatedInvestmentPositionValue(
            quantity: holding.quantity,
            unitPrice: price
        )
    }

    private func checkedInvestmentDifference(
        _ left: Decimal,
        _ right: Decimal
    ) throws -> Decimal {
        do {
            return try CheckedDecimal.subtracting(left, right)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AppModelError.amountTooLarge
        }
    }

    private func checkedEstimatedSum(
        _ left: Decimal,
        _ right: Decimal
    ) throws -> Decimal {
        do {
            return try CheckedDecimal.adding(left, right)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AppModelError.amountTooLarge
        }
    }

    private func performInvestmentDomainOperation<Value>(
        _ operation: () throws -> Value
    ) throws -> Value {
        do {
            return try operation()
        } catch let error as InvestmentHoldingError {
            switch error {
            case .arithmeticOverflow:
                throw AppModelError.amountTooLarge
            case .activityOutOfOrder:
                throw AppModelError.investmentDateOutOfOrder
            case .insufficientQuantity:
                throw AppModelError.insufficientInvestmentQuantity
            case .lotCurrencyMismatch, .valuationCurrencyMismatch:
                throw AppModelError.investmentCurrencyMismatch
            case .quantityCannotBeNegative, .priceCannotBeNegative,
                 .lotQuantityMustBePositive, .lotRemainingQuantityInvalid:
                throw AppModelError.invalidInvestmentTrade
            case .lotQuantityMismatch, .duplicateIdentifier,
                 .duplicateLinkedEntry, .invalidDisposal, .historyMismatch:
                throw AppModelError.invalidBook
            case .correctionUnavailable:
                throw AppModelError.invalidInvestmentTrade
            }
        }
    }

    private func beginInvestmentMutation(id: UUID) throws {
        guard investmentMutationsInProgress.insert(id).inserted else {
            throw AppModelError.transactionInProgress
        }
    }

    private func validateInvestmentActivityDate(
        _ date: Date,
        after latestDate: Date?
    ) throws {
        // A one-second tolerance avoids rejecting a Date captured immediately
        // before this main-actor validation executes.
        guard date <= Date().addingTimeInterval(1) else {
            throw AppModelError.investmentDateInFuture
        }
        if let latestDate, date < latestDate {
            throw AppModelError.investmentDateOutOfOrder
        }
    }

    private func positionLedgerValue(
        id: UUID,
        currency: CurrencyCode
    ) throws -> Money {
        switch accountBalancesResult() {
        case let .available(balances):
            return balances[id]?[currency] ?? Money.zero(currency: currency)
        case .unavailable:
            throw AppModelError.invalidBook
        }
    }

    private func clearDecodedState() {
        journalProjectionRevision &+= 1
        journalDerivedRefreshTask?.cancel()
        journalDerivedRefreshTask = nil
        journalDerivedRefreshTaskToken = nil
        journalDerivedRefreshWasDeferred = false
        quickLogDraftWriteTask?.cancel()
        quickLogDraftWriteTask = nil
        profile = nil
        accounts = []
        entries = []
        journalEntryCount = 0
        journalRecentEntriesAreCurrent = false
        journalStoredEntryCount = 0
        journalReferenceCounts = [:]
        journalReferenceCountsAreCurrent = false
        invalidJournalEntryIDs = []
        investmentLinkedEntriesByID = [:]
        existingScheduledLinkedEntryIDs = []
        budgetNodes = []
        budgetConfigurationTimeline = nil
        budgetConfigurationTimelineInvalid = false
        budgetEntryAttributions = [:]
        budgetAttributionCacheIsComplete = false
        closedMonthBudgetProjection = nil
        scheduledTransactions = []
        investmentHoldings = []
        receiptAttachmentMetadata = []
        exchangeRates = []
        netWorthSnapshots = []
        savingsGoals = []
        quickLogDraft = nil
        recoveryIssues = []
    }

    func validateLoadedBook() throws {
        guard let profile else { return }
        let accountIDs = Set(accounts.map(\.id))
        guard accountIDs.count == accounts.count else { throw AppModelError.invalidBook }

        for account in accounts {
            if let parentID = account.parentID, !accountIDs.contains(parentID) {
                throw AppModelError.invalidBook
            }
        }
        let expenseIDs = Set(accounts.filter { $0.kind == .expense }.map(\.id))
        guard budgetNodes.allSatisfy({ expenseIDs.contains($0.id) }) else {
            throw AppModelError.invalidBook
        }
        _ = try BudgetTree(currency: profile.baseCurrency, nodes: budgetNodes)

        guard entries.allSatisfy({ entry in
            entry.postings.allSatisfy { accountIDs.contains($0.accountID) }
        }) else {
            throw AppModelError.invalidBook
        }
        for item in scheduledTransactions {
            guard accountIDs.contains(item.accountID),
                  accountIDs.contains(item.categoryAccountID) else {
                throw AppModelError.invalidBook
            }
            do {
                try item.validateLifecycle(calendar: reportingCalendar)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AppModelError.invalidBook
            }
        }
        let scheduledLinkedEntryIDs = scheduledTransactions.flatMap {
            $0.resolutions.compactMap(\.linkedEntryID)
        }
        let knownScheduledEntryIDs = retainsCompleteJournal
            ? Set(entries.map(\.id))
            : existingScheduledLinkedEntryIDs
        guard Set(scheduledLinkedEntryIDs).count == scheduledLinkedEntryIDs.count,
              Set(scheduledLinkedEntryIDs).isSubset(of: knownScheduledEntryIDs) else {
            throw AppModelError.invalidBook
        }
        guard Set(investmentHoldings.map(\.id)).count == investmentHoldings.count else {
            throw AppModelError.invalidBook
        }
        let linkedPositionIDs = investmentHoldings.compactMap(\.positionAccountID)
        guard Set(linkedPositionIDs).count == linkedPositionIDs.count else {
            throw AppModelError.invalidBook
        }
        let allHoldingEntryIDs = investmentHoldings.flatMap {
            Array($0.linkedEntryIDs)
        }
        guard Set(allHoldingEntryIDs).count == allHoldingEntryIDs.count else {
            throw AppModelError.invalidBook
        }
        let knownLinkedEntries = retainsCompleteJournal
            ? Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
            : investmentLinkedEntriesByID
        let balances: [UUID: [CurrencyCode: Money]]
        switch accountBalancesResult() {
        case let .available(value):
            balances = value
        case .unavailable:
            throw AppModelError.invalidBook
        }
        for holding in investmentHoldings {
            guard let funding = accountsByID[holding.accountID],
                  isInvestmentFundingAccountShape(funding),
                  holding.isArchived || !funding.isArchived else {
                throw AppModelError.invalidBook
            }
            let holdingCurrencies = Set(
                [holding.price?.currency]
                    + holding.priceHistory.map { Optional($0.price.currency) }
                    + holding.lots.map { Optional($0.unitCost.currency) }
                    + holding.disposals.flatMap {
                        [Optional($0.costBasis.currency), Optional($0.proceeds.currency),
                         Optional($0.realizedGainLoss.currency)]
                    }
            ).compactMap { $0 }
            guard holdingCurrencies.allSatisfy({ $0 == funding.currency }) else {
                throw AppModelError.invalidBook
            }
            guard let positionID = holding.positionAccountID else {
                guard !holding.isArchived,
                      holding.linkedEntryIDs.isEmpty,
                      holding.quantity == .zero || holding.needsLedgerConnection else {
                    throw AppModelError.invalidBook
                }
                continue
            }
            guard positionID != funding.id,
                  let currency = funding.currency,
                  let position = accountsByID[positionID],
                  position.kind == .asset,
                  position.systemRole == .investmentPosition,
                  position.currency == currency,
                  position.isArchived == holding.isArchived else {
                throw AppModelError.invalidBook
            }
            do {
                try InvestmentLedgerIntegrity.validate(
                    holding: holding,
                    accountsByID: accountsByID,
                    entriesByID: knownLinkedEntries
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AppModelError.invalidBook
            }
            let expectedValue: Money
            do {
                expectedValue = try holding.marketValue()
                    ?? Money.zero(currency: currency)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AppModelError.invalidBook
            }
            let positionBalances = balances[positionID] ?? [:]
            guard positionBalances.allSatisfy({ pair in
                pair.key == funding.currency || pair.value.isZero
            }) else {
                throw AppModelError.invalidBook
            }
            let actualValue = positionBalances[currency]
                ?? Money.zero(currency: currency)
            guard actualValue == expectedValue else {
                throw AppModelError.invalidBook
            }
        }
        let linkedPositionArchiveState = Dictionary(
            uniqueKeysWithValues: investmentHoldings.compactMap { holding in
                holding.positionAccountID.map { ($0, holding.isArchived) }
            }
        )
        guard accounts.filter({ $0.systemRole == .investmentPosition }).allSatisfy({ position in
            if let shouldBeArchived = linkedPositionArchiveState[position.id] {
                return position.isArchived == shouldBeArchived
            }
            guard position.isArchived, let currency = position.currency else { return false }
            let positionBalances = balances[position.id] ?? [:]
            return positionBalances.allSatisfy({ pair in
                (pair.key == currency || pair.value.isZero) && pair.value.isZero
            })
        }) else {
            throw AppModelError.invalidBook
        }
        if retainsCompleteJournal {
            let entryIDs = Set(entries.map(\.id))
            let attachmentIDs = Set(receiptAttachmentMetadata.map(\.id))
            guard attachmentIDs.count == receiptAttachmentMetadata.count,
                  receiptAttachmentMetadata.allSatisfy({
                    entryIDs.contains($0.entryID)
                  }) else {
                throw AppModelError.invalidBook
            }
        }
        guard Set(savingsGoals.map(\.id)).count == savingsGoals.count else {
            throw AppModelError.invalidBook
        }
    }

    private static func databaseURL() throws -> URL {
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return baseURL
            .appendingPathComponent("MoneyUp", isDirectory: true)
            .appendingPathComponent("moneyup.sqlite", isDirectory: false)
    }

    private static func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Idempotent completion shared by an in-process erase and startup recovery.
    /// The high-value book key is destroyed first; the marker remains durable
    /// until main/WAL/SHM, locked-inbox key/ciphertext, and every retryable step
    /// have completed successfully.
    static func completePendingDataErase(
        databaseURL: URL,
        deleteDatabaseKey: @Sendable () throws -> Void,
        lockedCaptureStore: any LockedCaptureStoring,
        clearEraseIntent: @Sendable () throws -> Void
    ) async throws {
        try deleteDatabaseKey()
        for artifactURL in DatabaseKeyCreationPolicy.artifactURLs(
            for: databaseURL
        ) {
            try removeIfPresent(artifactURL)
        }
        try await lockedCaptureStore.eraseAll()
        try clearEraseIntent()
    }

    private static func defaultBook(
        mainAccount: LedgerAccount
    ) -> (accounts: [LedgerAccount], budgetNodes: [BudgetNode]) {
        let openingBalances = LedgerAccount(
            name: String(localized: "account.opening_balances"),
            kind: .equity,
            systemRole: .openingBalances
        )
        let essentials = LedgerAccount(name: String(localized: "category.essentials"), kind: .expense)
        let food = LedgerAccount(
            name: String(localized: "category.food"),
            kind: .expense,
            parentID: essentials.id
        )
        let transport = LedgerAccount(
            name: String(localized: "category.transport"),
            kind: .expense,
            parentID: essentials.id
        )
        let housing = LedgerAccount(name: String(localized: "category.housing"), kind: .expense)
        let rent = LedgerAccount(
            name: String(localized: "category.rent"),
            kind: .expense,
            parentID: housing.id
        )
        let utilities = LedgerAccount(
            name: String(localized: "category.utilities"),
            kind: .expense,
            parentID: housing.id
        )
        let lifestyle = LedgerAccount(name: String(localized: "category.lifestyle"), kind: .expense)
        let shopping = LedgerAccount(
            name: String(localized: "category.shopping"),
            kind: .expense,
            parentID: lifestyle.id
        )
        let entertainment = LedgerAccount(
            name: String(localized: "category.entertainment"),
            kind: .expense,
            parentID: lifestyle.id
        )
        let salary = LedgerAccount(name: String(localized: "category.salary"), kind: .income)
        let otherIncome = LedgerAccount(name: String(localized: "category.other_income"), kind: .income)
        let expenseAccounts = [
            essentials, food, transport, housing, rent, utilities,
            lifestyle, shopping, entertainment
        ]
        let nodes = expenseAccounts.map {
            BudgetNode(id: $0.id, parentID: $0.parentID, name: $0.name)
        }
        return (
            [mainAccount, openingBalances] + expenseAccounts + [salary, otherIncome],
            nodes
        )
    }
}

enum AppModelError: Error {
    case locked
    case emptyName
    case invalidCategoryKind
    case missingRecord
    case negativeAmount
    case accountHasNoCurrency
    case foreignCurrencyTransferRequiresExchangeRate
    case invalidBook
    case transactionInProgress
    case unsupportedPrecision(CurrencyCode)
    case amountTooLarge
    case crossCurrencyEditRequiresConversion
    case importTooLarge
    case ledgerItemInUse
    case incompatibleLedgerItems
    case systemAccountLifecycleForbidden
    case ledgerItemArchived
    case scheduleEntryMismatch
    case scheduleEntryAlreadyMatched
    case restoreRecoveryFailed
    case investmentCurrencyMismatch
    case investmentNeedsLedgerConnection
    case missingInvestmentPrice
    case investmentHoldingNotEmpty
    case invalidInvestmentTrade
    case insufficientInvestmentQuantity
    case investmentDateOutOfOrder
    case investmentDateInFuture
    case investmentEntryMutationForbidden
    case legacyInvestmentSnapshotForbidden
    case invalidGoal
    case goalWithdrawalExceedsBalance
    case pendingLockedCaptures
}

extension AppModelError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .locked: String(localized: "error.app_locked")
        case .emptyName: String(localized: "error.empty_name")
        case .invalidCategoryKind: String(localized: "error.invalid_category")
        case .missingRecord: String(localized: "error.missing_record")
        case .negativeAmount: String(localized: "error.negative_amount")
        case .accountHasNoCurrency: String(localized: "error.account_currency")
        case .foreignCurrencyTransferRequiresExchangeRate:
            String(localized: "error.fx_transfer_not_supported")
        case .invalidBook: String(localized: "error.invalid_book")
        case .transactionInProgress: String(localized: "error.transaction_in_progress")
        case let .unsupportedPrecision(currency):
            String(
                format: String(localized: "error.currency_precision"),
                currency.value,
                currency.minorUnits
            )
        case .amountTooLarge:
            String(localized: "error.amount_too_large")
        case .crossCurrencyEditRequiresConversion:
            String(localized: "error.cross_currency_edit")
        case .importTooLarge: String(localized: "import.error.too_large")
        case .ledgerItemInUse: String(localized: "lifecycle.error.in_use")
        case .incompatibleLedgerItems:
            String(localized: "lifecycle.error.incompatible")
        case .systemAccountLifecycleForbidden:
            String(localized: "lifecycle.error.system_account")
        case .ledgerItemArchived: String(localized: "lifecycle.error.archived")
        case .scheduleEntryMismatch: String(localized: "schedule.error.entry_mismatch")
        case .scheduleEntryAlreadyMatched:
            String(localized: "schedule.error.entry_already_matched")
        case .restoreRecoveryFailed:
            String(localized: "error.restore_recovery_failed")
        case .investmentCurrencyMismatch:
            String(localized: "holding.error.currency_mismatch")
        case .investmentNeedsLedgerConnection:
            String(localized: "holding.error.needs_ledger")
        case .missingInvestmentPrice:
            String(localized: "holding.error.missing_price")
        case .investmentHoldingNotEmpty:
            String(localized: "holding.error.not_empty")
        case .invalidInvestmentTrade:
            String(localized: "holding.error.invalid_trade")
        case .insufficientInvestmentQuantity:
            String(localized: "holding.error.insufficient_quantity")
        case .investmentDateOutOfOrder:
            String(localized: "holding.error.date_out_of_order")
        case .investmentDateInFuture:
            String(localized: "holding.error.date_in_future")
        case .investmentEntryMutationForbidden:
            String(localized: "holding.error.linked_entry_protected")
        case .legacyInvestmentSnapshotForbidden:
            String(localized: "holding.error.snapshot_needs_ledger")
        case .invalidGoal: String(localized: "goal.error.invalid")
        case .goalWithdrawalExceedsBalance:
            String(localized: "goal.error.withdrawal_exceeds_balance")
        case .pendingLockedCaptures:
            String(localized: "backup.error.pending_captures")
        }
    }
}
