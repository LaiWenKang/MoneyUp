import Foundation
import MoneyUpCore

struct AllowanceUsageEditorState: Equatable {
    let policy: AllowancePolicyRevision?
    let categories: [LedgerAccount]
    let normalizedCategoryID: UUID?
    let permitsGeneral: Bool
    let isAvailable: Bool

    var canSaveSelection: Bool {
        isAvailable && (permitsGeneral || normalizedCategoryID != nil)
    }
}

struct AllowanceUsageUndoRequest: Equatable, Sendable {
    let planID: UUID
    let usage: AllowanceUsage
    let policyRevisionID: UUID
}

enum AllowanceUsageUndoPolicy {
    static func request(
        planID: UUID,
        deletedUsage: AllowanceUsage?
    ) -> AllowanceUsageUndoRequest? {
        guard let deletedUsage,
              let policyRevisionID = deletedUsage.policyRevisionID else {
            return nil
        }
        return AllowanceUsageUndoRequest(
            planID: planID,
            usage: deletedUsage,
            policyRevisionID: policyRevisionID
        )
    }
}

enum AllowanceUsageEditorPolicy {
    static func state(
        plan: AllowancePlan,
        occurredAt: Date,
        availableCategories: [LedgerAccount],
        selectedCategoryID: UUID?
    ) -> AllowanceUsageEditorState {
        let policy = plan.policy(at: occurredAt)
        let permitsGeneral = policy?.eligibleCategoryIDs.isEmpty == true
        let categories = availableCategories.filter { category in
            guard category.kind == .expense, !category.isArchived else {
                return false
            }
            return permitsGeneral
                || policy?.eligibleCategoryIDs.contains(category.id) == true
        }
        let categoryIDs = Set(categories.map(\.id))
        let normalizedCategoryID: UUID?
        if selectedCategoryID.map(categoryIDs.contains) == true {
            normalizedCategoryID = selectedCategoryID
        } else {
            normalizedCategoryID = permitsGeneral ? nil : categories.first?.id
        }
        let summary = try? plan.summary(asOf: occurredAt)
        let isAvailable = !plan.isArchived
            && !plan.hasGrandfatheredActivity
            && plan.fundingMode == .benefitLimit
            && policy != nil
            && summary?.isAvailableToday == true
        return AllowanceUsageEditorState(
            policy: policy,
            categories: categories,
            normalizedCategoryID: normalizedCategoryID,
            permitsGeneral: permitsGeneral,
            isAvailable: isAvailable
        )
    }
}

enum AllowanceEditorDatePolicy {
    static func calendar(timeZoneIdentifier: String) -> Calendar? {
        guard TimeZone(identifier: timeZoneIdentifier) != nil else { return nil }
        return FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    static func storedStart(
        fromVisibleDate date: Date,
        timeZoneIdentifier: String
    ) -> Date? {
        guard date.timeIntervalSinceReferenceDate.isFinite,
              let calendar = calendar(
                  timeZoneIdentifier: timeZoneIdentifier
              ) else { return nil }
        return calendar.startOfDay(for: date)
    }

    static func storedExclusiveEnd(
        fromVisibleInclusiveDate date: Date,
        timeZoneIdentifier: String
    ) -> Date? {
        guard let calendar = calendar(timeZoneIdentifier: timeZoneIdentifier),
              let visibleDay = storedStart(
                  fromVisibleDate: date,
                  timeZoneIdentifier: timeZoneIdentifier
              ) else { return nil }
        return calendar.date(byAdding: .day, value: 1, to: visibleDay)
    }

    static func visibleStart(
        fromStoredStart date: Date,
        timeZoneIdentifier: String
    ) -> Date? {
        storedStart(
            fromVisibleDate: date,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    static func visibleInclusiveEnd(
        fromStoredExclusiveEnd date: Date,
        timeZoneIdentifier: String
    ) -> Date? {
        guard date.timeIntervalSinceReferenceDate.isFinite,
              let calendar = calendar(timeZoneIdentifier: timeZoneIdentifier),
              let priorDay = calendar.date(
                  byAdding: .day,
                  value: -1,
                  to: calendar.startOfDay(for: date)
              ) else { return nil }
        return priorDay
    }

    static func isCivilDayBoundary(
        _ date: Date,
        timeZoneIdentifier: String
    ) -> Bool {
        guard date.timeIntervalSinceReferenceDate.isFinite,
              let calendar = calendar(
                  timeZoneIdentifier: timeZoneIdentifier
              ) else { return false }
        return calendar.startOfDay(for: date) == date
    }

    static func rebasedVisibleDate(
        _ date: Date,
        from sourceTimeZoneIdentifier: String,
        to destinationTimeZoneIdentifier: String
    ) -> Date? {
        guard date.timeIntervalSinceReferenceDate.isFinite,
              let source = calendar(
                  timeZoneIdentifier: sourceTimeZoneIdentifier
              ),
              let destination = calendar(
                  timeZoneIdentifier: destinationTimeZoneIdentifier
              ) else { return nil }
        let components = source.dateComponents(
            [.year, .month, .day],
            from: date
        )
        return destination.date(from: components).map {
            destination.startOfDay(for: $0)
        }
    }
}

enum AllowancePolicyDatePresentation {
    static func policy(
        for usage: AllowanceUsage,
        in plan: AllowancePlan
    ) -> AllowancePolicyRevision? {
        usage.policyRevisionID.flatMap { policyID in
            plan.policyRevisions.first { $0.id == policyID }
        } ?? plan.policy(at: usage.occurredAt)
    }

    static func policy(
        for reconciliation: AllowanceReconciliation,
        in plan: AllowancePlan
    ) -> AllowancePolicyRevision? {
        plan.policyRevisions.first {
            $0.id == reconciliation.policyRevisionID
        }
    }

    static func calendar(
        for policy: AllowancePolicyRevision?,
        fallbackPlan: AllowancePlan
    ) -> Calendar {
        FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: policy?.timeZoneIdentifier
                ?? fallbackPlan.timeZoneIdentifier
        )
    }
}
