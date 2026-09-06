import Foundation
import MoneyUpCore
import MoneyUpPersistence

extension AppModel {
    /// Pinning and display controls do not change any source financial value.
    /// Other profile changes retain the existing invalidation behavior.
    static func preservesFinancialProjection(
        previous: UserProfile?, updated: UserProfile?
    ) -> Bool {
        guard var previous, let updated else { return false }
        previous.pinnedBudgetNodeIDs = updated.pinnedBudgetNodeIDs
        previous.displayPreferences = updated.displayPreferences
        previous.currencyDisplay = updated.currencyDisplay
        return previous == updated
    }

    func budgetChangeForReportingTimeZone(
        updatedProfile: UserProfile
    ) throws -> BudgetReportingTimeZoneChange? {
        guard let profile else { throw AppModelError.missingRecord }
        guard profile.baseCurrency == updatedProfile.baseCurrency else {
            throw BudgetReportingConfigurationError.currencyMismatch
        }
        guard profile.reportingTimeZoneIdentifier != updatedProfile.reportingTimeZoneIdentifier else { return nil }
        guard TimeZone(identifier: profile.reportingTimeZoneIdentifier) != nil else {
            throw BudgetReportingConfigurationError.invalidCalendar
        }
        let now = currentDate()
        let timeline = try validatedBudgetConfigurationTimeline(asOf: now)
        return try BudgetReportingTimeZoneChange(
            nodes: budgetNodes, timeline: timeline, baseCurrency: profile.baseCurrency,
            asOf: now, oldCalendar: reportingCalendar,
            newCalendar: FinancialPeriodBoundary.gregorianCalendar(
                timeZoneIdentifier: updatedProfile.reportingTimeZoneIdentifier
            )
        )
    }
}
