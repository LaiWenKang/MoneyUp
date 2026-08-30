import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

extension AppModel {
    func invalidateDerivedData() {
        reportCache.removeAll()
        monthToDateComparisonCache = nil
        monthToDateComparisonCacheDay = nil
        balanceCache = nil
    }

    func refreshBudgetWidgetSnapshot() {
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
        if case let .available(.some(summary)) = budgetPlanSummaryThisMonthResult(
            asOf: now
        ),
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

    func disableBudgetWidgetSnapshot() {
        budgetWidgetSnapshotStore.publish(enabled: false, percentUsed: nil)
        WidgetCenter.shared.reloadTimelines(ofKind: "MoneyUpQuickLog")
    }

    func accountBalancesResult() -> DerivedValue<[UUID: [CurrencyCode: Money]]> {
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
    func save(
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

    func scheduleQuickLogDraftWrite(_ draft: QuickLogDraft?) {
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
    func flushQuickLogDraftImmediately() {
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

    func writeQuickLogDraft(
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
    func refreshJournalDerivedState(
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

    func scheduleJournalDerivedRefresh() {
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
    func republishRetainedJournalProjectionIfPossible() {
        guard retainsCompleteJournal,
              store != nil,
              state == .ready || state == .onboarding else { return }
        journalEntryCount = entries.count
        journalStoredEntryCount = entries.count
        journalRecentEntriesAreCurrent = true
        journalDerivedRefreshWasDeferred = false
        refreshBudgetWidgetSnapshot()
    }

    func resumeDeferredJournalDerivedRefreshIfPossible() {
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
    func invalidateInFlightJournalProjection() {
        journalProjectionRevision &+= 1
        journalDerivedRefreshWasDeferred = true
    }

    func invalidateCommittedJournalProjection(
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
    func publishUnavailableBudgetWidgetSnapshot() {
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
}
