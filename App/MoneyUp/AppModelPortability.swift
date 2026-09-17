import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

extension AppModel {
    func csvExport(
        renderer: @escaping @Sendable (LedgerExportSnapshot) throws -> String = { $0.csv() }
    ) async throws -> String {
        try await prepareLedgerExport(renderer)
    }

    func xlsxExport(
        renderer: @escaping @Sendable (LedgerExportSnapshot) throws -> Data = { $0.xlsx() }
    ) async throws -> Data {
        try await prepareLedgerExport(renderer)
    }

    private func prepareLedgerExport<Value: Sendable>(
        _ renderer: @escaping @Sendable (LedgerExportSnapshot) throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard !requiresAuthenticationPrivacyCover else { throw AppModelError.locked }
        try beginJournalMutation(invalidatesJournalProjection: false)
        defer { endJournalMutation() }
        let read = try beginLogicalBookRead()
        let exportEntries: [JournalEntry]
        if retainsCompleteJournal {
            exportEntries = entries
        } else {
            exportEntries = try await journalSnapshot(
                includeInvalidRelationships: false
            )
        }
        try requireLogicalBookRead(read.token)
        guard state == .ready, !requiresAuthenticationPrivacyCover else {
            throw AppModelError.locked
        }
        let snapshot = LedgerExportSnapshot(
            entries: exportEntries,
            accounts: accounts,
            rates: exchangeRates,
            attachments: receiptAttachmentMetadata
        )
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let result = try renderer(snapshot)
            try Task.checkCancellation()
            return result
        }
        let result = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        let current = try await finishLogicalBookRead(result, token: read.token)
        try Task.checkCancellation()
        guard state == .ready, !requiresAuthenticationPrivacyCover,
              !hasDeferredAuthenticationLock else { throw AppModelError.locked }
        return current
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
        let pendingLockedCaptures = try await pendingLockedCaptures(in: inventoryStore)
        let currentPendingLockedCaptureCount = pendingLockedCaptures.count
        pendingLockedCaptureCount = currentPendingLockedCaptureCount
        try Task.checkCancellation()
        return PrivacySafeDataInventory(
            snapshot: snapshot,
            investmentHoldings: investmentHoldings,
            savingsGoals: savingsGoals,
            loanPlans: loanPlans,
            allowancePlans: allowancePlans,
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
}
