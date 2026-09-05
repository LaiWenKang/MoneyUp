import Foundation
import MoneyUpCore
import MoneyUpPersistence

extension AppModel {
    func prepareBudgetConfigurationTimelineAfterLoad(
        in store: EncryptedRecordStore,
        persistsMigration: Bool
    ) async throws {
        try await loadBudgetConfigurationTimeline(in: store, persistsMigration: persistsMigration)
        guard persistsMigration, !budgetConfigurationTimelineInvalid,
              let timeline = budgetConfigurationTimeline else { return }
        let parents = Set(budgetNodes.compactMap(\.parentID))
        let normalized = budgetNodes.map { node -> BudgetNode in
            guard node.limit == nil, node.allocationMode == .fixedTotal,
                  parents.contains(node.id) else { return node }
            var updated = node
            updated.allocationMode = .automatic
            return updated
        }
        guard normalized != budgetNodes else { return }
        let month = try reportingMonthStart(containing: currentDate())
        // Only today's revision changes. Existing caps, closed revisions,
        // carry mappings and opening checkpoints retain their interpretation.
        let revised = try timeline.recording(nodes: normalized, effectiveMonth: month)
        let old = Dictionary(uniqueKeysWithValues: budgetNodes.map { ($0.id, $0) })
        var writes = try normalized.filter { old[$0.id] != $0 }.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .budgetNodes)
        }
        writes.append(try budgetConfigurationTimelineWrite(revised))
        let generation = storeGeneration
        try await store.write(writes)
        guard ownsStoreGeneration(generation) else { throw AppModelError.locked }
        budgetConfigurationTimeline = revised
        budgetNodes = normalized
    }
}
