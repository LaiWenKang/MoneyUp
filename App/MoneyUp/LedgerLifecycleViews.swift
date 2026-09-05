import Foundation
import MoneyUpCore
import SwiftUI

func impactSummary(_ impact: AppModel.LedgerItemLifecycleImpact) -> String {
    String(
        format: AppLocalization.string("lifecycle.impact_summary"),
        impact.transactionCount,
        impact.scheduleCount,
        impact.holdingCount,
        impact.childCount,
        impact.defaultReferenceCount,
        impact.draftReferenceCount,
        impact.hasConfiguredBudget ? 1 : 0
    )
}
