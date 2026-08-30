import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

extension AppModel {
    /// One injected clock for user-authored timestamps and local parsers keeps
    /// financial-day attribution testable and aligned with the book's fixed
    /// reporting zone.
    func currentDateForUserAction() -> Date {
        currentDate()
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

    func sceneDidLeaveActive(at date: Date) {
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

    var isLockSafeQuickCaptureRequested: Bool {
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
    var lockedCaptureIsAllowedByLifecycleAndEraseIntent: Bool {
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
            now: currentDate(),
            calendar: reportingCalendar,
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

    func journalEntries(
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
    func journalSnapshot(
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

    func recordHistoryDecodeIssues(_ issues: [RecordDecodeIssue]) {
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
}
