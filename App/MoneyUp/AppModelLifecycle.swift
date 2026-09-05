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

    @discardableResult
    func start() async -> Bool {
        guard !isWorking else { return false }
        finishUnlockToFirstUsefulContentMeasurement(outcome: .cancelled)
        var quickActionBoundaryEpoch: UInt64?
        var quickActionRecoveryWasValidated = false
        beginStartupWork()
        defer {
            isWorking = false
            isStarting = false
            finishQuickActionBoundary(
                quickActionBoundaryEpoch,
                validatedRecovery: quickActionRecoveryWasValidated
            )
        }
        let dataEraseInspection = await inspectDataEraseIntent()
        quickActionBoundaryEpoch = dataEraseInspection.boundaryEpoch
        await lifecycleHooks.checkpoint(.afterStartupTombstoneInspection)
        await closeStoreBeforeStartup()
        state = .launching
        startupFailureKind = nil
        var pendingDataEraseIsIncomplete = false
        do {
            // A prior jetsam, power loss, or process termination can interrupt
            // isolated restore validation before its defer-like cleanup. The
            // production directory is stable, so startup bounds abandoned
            // SQLCipher/WAL artifacts to one owned location.
            let databaseURL = try databaseURLForErase ?? Self.databaseURL()
            // A durable erase tombstone always wins over normal startup. Do not
            // read or create the SQLCipher key until every idempotent erase step
            // has converged. Scrub the widget immediately as well: a transient
            // cleanup failure must not keep an old-book projection visible.
            let pendingDataErase = try dataEraseInspection.result.get()
            if pendingDataErase {
                pendingDataEraseIsIncomplete = true
                requestedQuickLogMode = nil
                disableBudgetWidgetSnapshot()
                clearDecodedState()
                try await Self.completePendingDataErase(
                    databaseURL: databaseURL,
                    deleteDatabaseKey: deleteDatabaseKey,
                    lockedCaptureStore: lockedCaptureStore,
                    removeKeyCliffRecoveryArtifacts: {
                        try KeyCliffRecoveryTransaction.removeAll(for: databaseURL)
                    },
                    clearEraseIntent: dataEraseIntent.clear
                )
                pendingDataEraseIsIncomplete = false
                pendingLockedCaptureCount = 0
            }
            try? Self.removeRestoreValidationDirectory(
                restoreValidationDirectoryURL
            )
            try? Self.removeLegacyRestoreValidationDirectories()
            scavengeRestorePreviewArtifacts()
            try await openAndFinishStartupIncludingKeyCliffRecovery(
                databaseURL: databaseURL
            )
            quickActionRecoveryWasValidated = true
            finishDeferredStartupLockIfNeeded()
        } catch let error as DatabaseKeyStoreError
            where error == .authenticationCancelled
                && !pendingDataEraseIsIncomplete {
            finishCancelledAuthentication()
        } catch let error as DatabaseKeyStoreError
            where error == .missingDeviceBoundKey {
            await enterMissingDeviceBoundKeyRecovery(error)
        } catch {
            // Keep an opened store available to the recovery screen. It can
            // still produce a raw authenticated backup even when a domain
            // record cannot be decoded. Other pre-open key/cipher failures
            // expose no raw backup; missing-key recovery was routed above.
            if store == nil {
                clearDecodedState()
            }
            finishFailedStartup(
                message: safeUserMessage(for: error, context: .unlock)
            )
        }
        return quickActionRecoveryWasValidated
    }

    private func beginStartupWork() {
        isWorking = true
        isStarting = true
    }

    private func finishDeferredStartupLockIfNeeded() {
        guard lockAfterStart else { return }
        lockAfterStart = false
        isWorking = false
        isStarting = false
        lock()
    }

    func finishQuickActionBoundary(
        _ epoch: UInt64?,
        validatedRecovery: Bool
    ) {
        if let epoch {
            quickActionRouteBroker.endAuthoritativeBoundary(epoch)
        }
        if validatedRecovery {
            finishValidatedQuickActionIngressRecovery()
        }
    }

    private func inspectDataEraseIntent() async -> (
        result: Result<Bool, Error>,
        boundaryEpoch: UInt64?
    ) {
        do {
            let isPending = try await dataEraseIntent
                .isPendingWithoutBlockingLaunch()
            if isPending {
                do {
                    return (
                        .success(true),
                        try beginAuthoritativeQuickActionBoundary()
                    )
                } catch {
                    return (.failure(error), nil)
                }
            }
            return (.success(false), nil)
        } catch {
            let inspectionError = error
            do {
                return (
                    .failure(inspectionError),
                    try beginAuthoritativeQuickActionBoundary()
                )
            } catch {
                return (.failure(error), nil)
            }
        }
    }
}

extension AppModel {
    private func closeStoreBeforeStartup() async {
        if let pendingClose = storeCloseTask {
            await pendingClose.value
            storeCloseTask = nil
        }
        if let existingStore = store {
            await existingStore.close()
            store = nil
            storeGeneration &+= 1
        }
    }

    /// Authentication cancellation is a normal locked-state transition, not
    /// a startup failure. Kept as one transition so lifecycle tests can cover
    /// the background/foreground race without invoking process Keychain UI.
    func finishCancelledAuthentication() {
        finishUnlockToFirstUsefulContentMeasurement(outcome: .cancelled)
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
        finishUnlockToFirstUsefulContentMeasurement(outcome: .failure)
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
        if pendingDisplayPreferences != nil, let write = displayPreferenceWriteTask {
            requiresAuthenticationPrivacyCover = true
            Task { @MainActor in
                await write.value
                lock()
            }
            return
        }
        // Stop day-boundary work as soon as authentication is required, even
        // when an atomic mutation must drain before decoded state is cleared.
        cancelWidgetReportingDayRefresh()
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
        finishUnlockToFirstUsefulContentMeasurement(outcome: .cancelled)
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
        widgetLifecycleRefresh.isSceneActive = false
        cancelWidgetReportingDayRefresh()
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
        // A shielded/background interval is not a first-useful-content sample.
        // End it as a fixed cancellation before any inactive time can pollute
        // the foreground performance distribution.
        finishUnlockToFirstUsefulContentMeasurement(outcome: .cancelled)
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
        let wasAlreadyActive = widgetLifecycleRefresh.isSceneActive
        widgetLifecycleRefresh.isSceneActive = true
        autoLockTask?.cancel()
        autoLockTask = nil
        // A startup authentication prompt can be cancelled while the scene is
        // inactive. In that path the model is already locked, so calling
        // `lock()` again would be a no-op and could leave the scene-level
        // privacy window permanently covering the unlock UI.
        if state == .locked {
            leftActiveAt = nil
            requiresAuthenticationPrivacyCover = false
            cancelWidgetReportingDayRefresh()
            return
        }
        guard let leftActiveAt else {
            requiresAuthenticationPrivacyCover = false
            if wasAlreadyActive {
                rearmWidgetReportingDayRefreshIfEligible()
            } else {
                refreshWidgetForSceneActivationIfEligible()
            }
            return
        }
        self.leftActiveAt = nil
        let delay = profile?.autoLockDelay ?? 60
        let elapsed = date.timeIntervalSince(leftActiveAt)
        if !elapsed.isFinite || elapsed < 0 || elapsed >= delay {
            lock()
        } else {
            requiresAuthenticationPrivacyCover = false
            refreshWidgetForSceneActivationIfEligible()
        }
    }

    @discardableResult
    func handleDeepLink(_ url: URL) -> Bool {
        guard !quickActionRouteBroker.isAuthoritativeBoundaryActive,
              !goalMutationBarrierClosed else { return false }
        do {
            guard try dataEraseIntent.isPending() == false else { return false }
        } catch {
            return false
        }
        // A request carries old-book intent even when it contains no amount.
        // Deny it throughout missing-key recovery and every durable install /
        // rollback phase so it cannot surface against the replacement book.
        guard !isBookReplacementInProgress,
              startupFailureKind != .missingDeviceBoundKey,
              (try? hasPendingKeyCliffRecoveryTransaction()) == false else {
            requestedQuickLogMode = nil
            return false
        }
        guard let action = MoneyUpQuickAction(exactDeepLink: url) else {
            return false
        }
        let mode = QuickLogLaunchMode(action)
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

    /// Durable erase and key-cliff replacement markers are authoritative even
    /// before normal startup. Lock-safe capture cannot cross either book
    /// replacement boundary.
    var lockedCaptureIsAllowedByLifecycleAndEraseIntent: Bool {
        guard !isWorking,
              !isLifecycleMutationInProgress,
              !goalMutationBarrierClosed,
              !quickActionRouteBroker.isAuthoritativeBoundaryActive,
              !lockedCaptureWriteInProgress else { return false }
        do {
            guard try dataEraseIntent.isPending() == false else { return false }
            return !(try hasPendingKeyCliffRecoveryTransaction())
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
        request: QuickLogRouteRequest,
        amountText: String,
        payee: String,
        note: String
    ) async throws {
        guard requestedQuickLogRequest == request else {
            throw AppModelError.locked
        }
        try await saveLockedCapture(
            mode: request.mode,
            captureID: request.ingressToken,
            amountText: amountText,
            payee: payee,
            note: note
        )
        if request.requiresIngressAcknowledgement {
            _ = quickActionRouteBroker.acknowledge(
                token: request.ingressToken,
                allowingCommittedCaptureReplay: true
            )
        }
    }

    func saveLockedCapture(
        mode: QuickLogLaunchMode,
        captureID: UUID = UUID(),
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
                id: captureID,
                kind: kind,
                amountText: amountText,
                payee: payee,
                note: note
            )
        )
        recoveryIssues.removeAll { $0.hasPrefix("locked_captures/") }
    }

    func consumeQuickLogRequest(_ request: QuickLogRouteRequest) {
        guard requestedQuickLogRequest == request,
              presentedQuickLogRequest == nil
                || presentedQuickLogRequest == request else { return }
        if request.requiresIngressAcknowledgement {
            guard quickActionRouteBroker.acknowledge(
                token: request.ingressToken
            ) else { return }
        }
        requestedQuickLogMode = nil
    }

    @discardableResult
    func presentQuickLogRequest(_ request: QuickLogRouteRequest) -> Bool {
        guard requestedQuickLogRequest == request,
              request.generation == quickActionRouteBroker.handoffGeneration,
              !quickActionRouteBroker.isAuthoritativeBoundaryActive,
              presentedQuickLogRequest == nil
                || presentedQuickLogRequest == request else {
            return false
        }
        presentedQuickLogRequest = request
        return true
    }

    /// The only AppModel entry point for an erase or book-replacement action
    /// boundary. The broker generation and occupied UI slot are invalidated in
    /// the same main-actor turn, before lifecycle code can suspend.
    func beginAuthoritativeQuickActionBoundary() throws -> UInt64 {
        let epoch = try quickActionRouteBroker.beginAuthoritativeBoundary()
        requestedQuickLogMode = nil
        return epoch
    }

    /// Successful authoritative startup may replace an unreadable/closed
    /// ingress envelope with a new empty protocol epoch. Any still-present UI
    /// request whose token no longer owns a delivery belongs to the old epoch.
    private func clearOrphanedQuickActionRequestAfterDurableRecovery() {
        guard let request = requestedQuickLogRequest,
              request.requiresIngressAcknowledgement,
              !quickActionRouteBroker.ownsActiveDelivery(
                  token: request.ingressToken
              ) else { return }
        requestedQuickLogMode = nil
    }

    func finishValidatedQuickActionIngressRecovery() {
        guard quickActionRouteBroker
            .reopenDurableAdmissionAfterAuthoritativeRecovery() else { return }
        clearOrphanedQuickActionRequestAfterDurableRecovery()
    }

    /// Runs OCR outside the view and only returns a parsed draft to the same
    /// unlocked store generation that requested it. A lock during Vision work
    /// therefore cannot repopulate sensitive form state afterward.
    func receiptAnalysis(
        from imageData: Data,
        prefersDayFirst: Bool
    ) async throws -> ReceiptParseResult? {
        guard state == .ready else { return nil }
        let read = try beginLogicalBookRead()
        let projectionRevision = journalProjectionRevision
        let accountsSnapshot = accounts
        let now = currentDate()
        let calendar = reportingCalendar
        try Task.checkCancellation()
        let recognition = try await receiptRecognizer(imageData)
        try Task.checkCancellation()
        guard ownsLogicalBookRead(read.token),
              projectionRevision == journalProjectionRevision else { return nil }

        let boundedRecognition = Self.boundedReceiptRecognition(recognition)
        let parsingTask = Task.detached(priority: .userInitiated) {
            ReceiptTextParser.analyze(
                fromLines: boundedRecognition.lines,
                now: now,
                calendar: calendar,
                prefersDayFirst: prefersDayFirst,
                accounts: accountsSnapshot,
                ocrConfidence: boundedRecognition.meanConfidence,
                ocrLineConfidences: boundedRecognition.lineConfidences
            )
        }
        let result = await withTaskCancellationHandler {
            await parsingTask.value
        } onCancel: {
            parsingTask.cancel()
        }
        try Task.checkCancellation()
        guard ownsLogicalBookRead(read.token),
              projectionRevision == journalProjectionRevision else { return nil }
        return try await finishLogicalBookRead(result, token: read.token)
    }

    static func boundedReceiptLines(_ lines: [String]) -> [String] {
        boundedReceiptRecognition(
            ReceiptRecognitionResult(lines: lines)
        ).lines
    }

    static func boundedReceiptRecognition(
        _ recognition: ReceiptRecognitionResult
    ) -> ReceiptRecognitionResult {
        let maximumLineCount = 160
        let maximumLineUTF8Count = 512
        let selectedIndices: [Int]
        if recognition.lines.count > maximumLineCount {
            let edgeCount = maximumLineCount / 2
            let suffixStart = recognition.lines.count - edgeCount
            selectedIndices = Array(0..<edgeCount)
                + Array(suffixStart..<recognition.lines.count)
        } else {
            selectedIndices = Array(recognition.lines.indices)
        }

        let alignedLineConfidences = recognition.lineConfidences.flatMap {
            $0.count == recognition.lines.count ? $0 : nil
        }
        var boundedLines: [String] = []
        var boundedLineConfidences: [Float] = []
        boundedLines.reserveCapacity(selectedIndices.count)
        if alignedLineConfidences != nil {
            boundedLineConfidences.reserveCapacity(selectedIndices.count)
        }

        for index in selectedIndices {
            let line = recognition.lines[index]
            var bytes = Array(line.utf8.prefix(maximumLineUTF8Count))
            while !bytes.isEmpty,
                  String(bytes: bytes, encoding: .utf8) == nil {
                bytes.removeLast()
            }
            let bounded = String(decoding: bytes, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bounded.isEmpty else { continue }
            boundedLines.append(bounded)
            if let alignedLineConfidences {
                boundedLineConfidences.append(alignedLineConfidences[index])
            }
        }

        return ReceiptRecognitionResult(
            lines: boundedLines,
            meanConfidence: recognition.meanConfidence,
            lineConfidences: alignedLineConfidences == nil
                ? nil : boundedLineConfidences
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
}
