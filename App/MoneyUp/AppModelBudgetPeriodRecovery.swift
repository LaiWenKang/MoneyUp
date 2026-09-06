import Foundation
import MoneyUpCore
import MoneyUpPersistence

extension AppModel {
    /// Runs only during book load, before any derived budget value is published.
    /// Original evidence, live activations, and corrected history commit together.
    func recoverLegacyBudgetPeriods(in store: EncryptedRecordStore) async throws {
        try Task.checkCancellation()
        guard recoveryIssues.isEmpty, let profile,
              let originalTimeline = budgetConfigurationTimeline else {
            throw BudgetReportingConfigurationError.invalidMonthBoundary
        }
        let generation = storeGeneration
        let originalNodes = budgetNodes
        let repair = try BudgetPeriodRecovery(
            nodes: originalNodes, timeline: originalTimeline,
            baseCurrency: profile.baseCurrency, asOf: currentDate(), calendar: reportingCalendar
        )
        let priorOriginal = try await store.fetch(
            BudgetPeriodRecoveryOriginal.self,
            id: BudgetPeriodRecoveryOriginal.recordID, from: .budgetConfigurationTimelines
        )
        // The preventive profile transaction makes this a one-time migration.
        // A second inconsistency must never overwrite the first recovery evidence.
        guard priorOriginal == nil else {
            throw BudgetReportingConfigurationError.invalidMonthBoundary
        }
        let original = BudgetPeriodRecoveryOriginal(
            nodes: originalNodes, timeline: originalTimeline,
            reportingTimeZoneIdentifier: profile.reportingTimeZoneIdentifier
        )
        try original.validate()
        let originalBytes = try JSONEncoder().encode(original).count
        guard originalBytes <= RestoreCandidateValidator.maximumPayloadByteCount else {
            throw AppModelError.invalidBook
        }
        let originalsByID = Dictionary(uniqueKeysWithValues: originalNodes.map { ($0.id, $0) })
        let changedNodes = repair.nodes.filter { originalsByID[$0.id] != $0 }
        // Conservatively reserve the entire new payload, including replacement
        // rows, so retaining recovery evidence cannot make this book unexportable.
        let additionalBytes = try originalBytes + JSONEncoder().encode(repair.timeline).count
            + changedNodes.reduce(0) { try $0 + JSONEncoder().encode($1).count }
        let metrics = try await store.storageMetrics()
        guard metrics.recordCount < RestoreCandidateValidator.maximumCandidateRecordCount,
              metrics.payloadByteCount <= RestoreCandidateValidator.maximumBackupStoredPayloadByteCount - additionalBytes,
              metrics.recordIDByteCount <= RestoreCandidateValidator.maximumAggregateRecordIDByteCount
                - BudgetPeriodRecoveryOriginal.recordID.utf8.count,
              metrics.collectionByteCount <= RestoreCandidateValidator.maximumAggregateCollectionByteCount
                - RecordCollection.budgetConfigurationTimelines.rawValue.utf8.count else {
            throw AppModelError.invalidBook
        }
        var writes = try changedNodes.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .budgetNodes)
        }
        writes.append(try RecordWrite(original, id: BudgetPeriodRecoveryOriginal.recordID, in: .budgetConfigurationTimelines))
        writes.append(try budgetConfigurationTimelineWrite(repair.timeline))
        try Task.checkCancellation()
        guard ownsStoreGeneration(generation) else { throw AppModelError.locked }
        try await store.write(writes)
        guard ownsStoreGeneration(generation) else { throw AppModelError.locked }
        budgetNodes = repair.nodes
        budgetConfigurationTimeline = repair.timeline
    }
}
