import Foundation

typealias WidgetReportingDaySleep = @Sendable (Date) async throws -> Void

let productionWidgetReportingDaySleep: WidgetReportingDaySleep = {
    boundary in
    let delay = boundary.timeIntervalSinceNow
    guard delay > 0 else { return }
    try await Task.sleep(for: .seconds(delay))
}

struct WidgetReportingDayRefreshSchedule: Equatable, Sendable {
    let boundary: Date
    let storeGeneration: Int
    let logicalBookRevision: UInt64
}

/// One actor-isolated holder keeps scheduler mechanics out of the observable
/// financial model and prevents multiple reporting-day loops from coexisting.
struct WidgetLifecycleRefreshState {
    var isSceneActive = false
    var task: Task<Void, Never>?
    var schedule: WidgetReportingDayRefreshSchedule?
    var revision: UInt64 = 0
    /// Tests replace only the wait primitive; eligibility and publication
    /// continue through the production lifecycle path.
    var sleep: WidgetReportingDaySleep = productionWidgetReportingDaySleep
}

extension AppModel {
    var canRefreshWidgetForActiveScene: Bool {
        widgetLifecycleRefresh.isSceneActive
            && state == .ready
            && store != nil
            && profile?.showsBudgetStatusWidget == true
            && !requiresAuthenticationPrivacyCover
            && !hasDeferredAuthenticationLock
            && !isBookReplacementInProgress
    }

    func cancelWidgetReportingDayRefresh() {
        widgetLifecycleRefresh.revision &+= 1
        widgetLifecycleRefresh.task?.cancel()
        widgetLifecycleRefresh.task = nil
        widgetLifecycleRefresh.schedule = nil
    }

    /// Maintains exactly one wait for the book's next civil reporting day.
    /// Repeated snapshot publications within that day reuse the same wait.
    func rearmWidgetReportingDayRefreshIfEligible() {
        guard canRefreshWidgetForActiveScene else {
            cancelWidgetReportingDayRefresh()
            return
        }
        let now = currentDate()
        guard now.timeIntervalSinceReferenceDate.isFinite,
              let boundary = reportingCalendar.dateInterval(
                  of: .day,
                  for: now
              )?.end,
              boundary > now else {
            cancelWidgetReportingDayRefresh()
            return
        }
        let schedule = WidgetReportingDayRefreshSchedule(
            boundary: boundary,
            storeGeneration: storeGeneration,
            logicalBookRevision: logicalBookRevision
        )
        if widgetLifecycleRefresh.task != nil,
           widgetLifecycleRefresh.schedule == schedule {
            return
        }

        cancelWidgetReportingDayRefresh()
        widgetLifecycleRefresh.schedule = schedule
        let revision = widgetLifecycleRefresh.revision
        let sleep = widgetLifecycleRefresh.sleep
        widgetLifecycleRefresh.task = Task { [weak self] in
            do {
                try await sleep(schedule.boundary)
            } catch {
                return
            }
            guard !Task.isCancelled, let self,
                  revision == self.widgetLifecycleRefresh.revision,
                  self.widgetLifecycleRefresh.schedule == schedule else {
                return
            }
            self.widgetLifecycleRefresh.task = nil
            self.widgetLifecycleRefresh.schedule = nil
            self.refreshWidgetAtReportingDayBoundary(schedule)
        }
    }

    func refreshWidgetForSceneActivationIfEligible() {
        guard canRefreshWidgetForActiveScene else {
            cancelWidgetReportingDayRefresh()
            return
        }
        let now = currentDate()
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            cancelWidgetReportingDayRefresh()
            return
        }
        let published = budgetWidgetSnapshotStore.readPublishedSnapshot(now: now)
        if profile?.intelligenceEnabled == true,
           case .stale = published.budget {
            // Crossing a reporting day also changes the intelligence query's
            // as-of day. Publish a current generation immediately with review
            // count withheld, then republish after the bounded refresh.
            refreshIntelligence()
        } else {
            refreshBudgetWidgetSnapshot()
        }
    }

    private func refreshWidgetAtReportingDayBoundary(
        _ schedule: WidgetReportingDayRefreshSchedule
    ) {
        guard schedule.storeGeneration == storeGeneration,
              schedule.logicalBookRevision == logicalBookRevision,
              canRefreshWidgetForActiveScene else {
            cancelWidgetReportingDayRefresh()
            return
        }
        let now = currentDate()
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            cancelWidgetReportingDayRefresh()
            return
        }
        // A wall-clock rollback can make a continuous-clock sleep finish
        // before the civil boundary. Recompute instead of publishing early.
        guard now >= schedule.boundary else {
            rearmWidgetReportingDayRefreshIfEligible()
            return
        }
        if profile?.intelligenceEnabled == true {
            refreshIntelligence()
        } else {
            refreshBudgetWidgetSnapshot()
        }
    }
}
