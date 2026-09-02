import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

extension AppModel {
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
