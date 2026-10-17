import Foundation
import MoneyUpCore
import SwiftUI

enum HistoryQuickRange: String, CaseIterable, Hashable {
    case today
    case sevenDays
    case month
    case all

    var titleKeyString: String {
        switch self {
        case .today: "history.scope.today"
        case .sevenDays: "history.scope.seven_days"
        case .month: "history.scope.month"
        case .all: "history.scope.all"
        }
    }

    var title: LocalizedStringKey { LocalizedStringKey(titleKeyString) }

    var systemImage: String {
        switch self {
        case .today: "sun.max.fill"
        case .sevenDays: "calendar.badge.clock"
        case .month: "calendar"
        case .all: "tray.full"
        }
    }

    var isRolling: Bool {
        switch self {
        case .today, .sevenDays, .month: true
        case .all: false
        }
    }
}

/// A search looks through every date. Starting one on a rolling range (Today,
/// 7 days, Month) widens History to All and remembers the range; clearing the
/// search brings it back, unless another range was chosen meanwhile. A custom
/// date range is the user's own choice and is never widened.
enum HistorySearchScopePolicy {
    struct State: Equatable {
        var range: HistoryQuickRange?
        var rangeBeforeSearch: HistoryQuickRange?
    }

    static func applying(
        search newSearch: String,
        after oldSearch: String,
        to state: State
    ) -> State {
        let wasSearching = !oldSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isSearching = !newSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var next = state
        if isSearching, !wasSearching, let range = state.range, range.isRolling {
            next.rangeBeforeSearch = range
            next.range = .all
        } else if !isSearching, wasSearching, let previous = state.rangeBeforeSearch {
            next.rangeBeforeSearch = nil
            if state.range == .all { next.range = previous }
        }
        return next
    }
}

/// Filters and the range row share one draft, so each must leave the other
/// alone. Applying the filter sheet keeps Today, 7 days, Month or All selected
/// unless the sheet's own dates changed: a category or kind filter then still
/// rolls over at midnight, and a later search still looks through every date.
/// Clear removes the search and the filters, never the range the person chose.
enum HistoryFilterScopePolicy {
    /// The calendar days a draft's date predicates cover; the time of day a
    /// date picker happens to carry is not a change of scope.
    struct DateScope: Equatable {
        let start: Date?
        let end: Date?
    }

    static func dateScope(of filters: HistoryFilterDraft, calendar: Calendar) -> DateScope {
        DateScope(
            start: filters.includesStartDate
                ? FinancialPeriodBoundary.startOfDay(containing: filters.startDate, calendar: calendar) : nil,
            end: filters.includesEndDate
                ? FinancialPeriodBoundary.startOfDay(containing: filters.endDate, calendar: calendar) : nil
        )
    }

    static func range(
        afterApplying updated: HistoryFilterDraft,
        over current: HistoryFilterDraft,
        selected range: HistoryQuickRange?,
        calendar: Calendar
    ) -> HistoryQuickRange? {
        if dateScope(of: updated, calendar: calendar) == dateScope(of: current, calendar: calendar) {
            return range
        }
        // Removing both dates is every date, not a custom range.
        return updated.includesStartDate || updated.includesEndDate ? nil : .all
    }

    /// Clear is offered only when it would remove something the person set:
    /// a search, or a filter the range row does not already show.
    static func canClear(
        filters: HistoryFilterDraft,
        range: HistoryQuickRange?,
        searchText: String
    ) -> Bool {
        !searchText.isEmpty || filters.advancedFilterCount(quickRange: range) > 0
    }

    /// The range shown after Clear, as ending the search would leave it: the
    /// range a search widened to All comes back, a range chosen during the
    /// search stays, and a custom date range clears to every date.
    static func rangeAfterClearing(
        range: HistoryQuickRange?,
        rangeBeforeSearch: HistoryQuickRange?
    ) -> HistoryQuickRange {
        if range == .all, let rangeBeforeSearch { return rangeBeforeSearch }
        return range ?? .all
    }
}

enum HistoryScopeSelectorPolicy {
    static let minimumTapDimension: CGFloat = 44

    static func usesMenu(
        at dynamicTypeSize: DynamicTypeSize,
        selection: HistoryQuickRange?
    ) -> Bool {
        dynamicTypeSize.isAccessibilitySize || selection == nil
    }

    static func showsTitle(
        for range: HistoryQuickRange,
        selection: HistoryQuickRange?
    ) -> Bool {
        range == selection
    }
}

enum HistoryRollingRangeRefreshPolicy {
    static func shouldReapply(
        range: HistoryQuickRange?,
        lastAppliedDay: ReportingDayIdentity?,
        currentDay: ReportingDayIdentity
    ) -> Bool {
        range?.isRolling == true && lastAppliedDay != currentDay
    }
}

extension HistoryFilterDraft {
    /// Quick scopes only own the date portion of the filter draft. Category,
    /// kind, account, search, and amount choices remain untouched at rollover.
    mutating func applyQuickRange(
        _ range: HistoryQuickRange,
        asOf now: Date,
        calendar: Calendar
    ) {
        endDate = now
        switch range {
        case .today:
            includesStartDate = true
            startDate = now
            includesEndDate = true
        case .sevenDays:
            includesStartDate = true
            startDate = calendar.date(
                byAdding: .day,
                value: -6,
                to: now
            ) ?? now
            includesEndDate = true
        case .month:
            includesStartDate = true
            startDate = calendar.dateInterval(of: .month, for: now)?.start ?? now
            includesEndDate = true
        case .all:
            includesStartDate = false
            includesEndDate = false
        }
    }
}

/// History's range selector and its filter buttons share a row; at
/// accessibility text sizes the selector takes the full width and the buttons
/// sit beneath it, so the range's name is never squeezed to a letter a line.
struct HistoryScopeHeader<Selector: View, Actions: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let selector: Selector
    private let actions: Actions

    init(@ViewBuilder selector: () -> Selector, @ViewBuilder actions: () -> Actions) {
        self.selector = selector()
        self.actions = actions()
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                selector
                actions
            }
        } else {
            HStack(alignment: .center, spacing: 8) {
                selector
                Spacer(minLength: 0)
                actions
            }
        }
    }
}

struct HistoryScopeSelector: View {
    @Binding private var selection: HistoryQuickRange?
    @Environment(\.moneyUpReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Namespace private var scopeSelection

    init(selection: Binding<HistoryQuickRange?>) {
        _selection = selection
    }

    var body: some View {
        Group {
            if HistoryScopeSelectorPolicy.usesMenu(
                at: dynamicTypeSize,
                selection: selection
            ) {
                scopeMenu
            } else {
                ViewThatFits(in: .horizontal) {
                    compactScopeStrip
                    scopeMenu
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectedTitle: LocalizedStringKey {
        selection?.title ?? LocalizedStringKey("history.scope.custom")
    }

    private var selectedSystemImage: String {
        selection?.systemImage ?? "line.3.horizontal.decrease.circle.fill"
    }

    private var compactScopeStrip: some View {
        HStack(spacing: 8) {
            ForEach(HistoryQuickRange.allCases, id: \.self) { range in
                scopeButton(range)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var scopeMenu: some View {
        Menu {
            ForEach(HistoryQuickRange.allCases, id: \.self) { range in
                Button {
                    select(range)
                } label: {
                    Label {
                        Text(range.title)
                    } icon: {
                        Image(
                            systemName: selection == range
                                ? "checkmark.circle.fill"
                                : range.systemImage
                        )
                    }
                }
                .accessibilityAddTraits(
                    selection == range ? .isSelected : []
                )
            }
        } label: {
            HStack(spacing: 10) {
                Label(selectedTitle, systemImage: selectedSystemImage).labelStyle(.titleAndIcon)
                    // One word, whole: at accessibility sizes it shrinks
                    // before it would break between letters.
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 1 : nil)
                    .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 0.5 : 1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down").font(.caption).accessibilityHidden(true)
            }
                .font(.headline)
                .frame(
                    maxWidth: .infinity,
                    minHeight: HistoryScopeSelectorPolicy.minimumTapDimension,
                    alignment: .leading
                )
                .padding(.horizontal, 14)
                .background(Color.accentColor.opacity(0.18), in: Capsule())
        }
        .buttonStyle(MoneyUpPressableButtonStyle())
        .accessibilityLabel("history.scope")
        .accessibilityValue(Text(selectedTitle))
    }

    private func scopeButton(_ range: HistoryQuickRange) -> some View {
        MoneyUpSectionChip(
            title: range.title,
            systemImage: range.systemImage,
            isSelected: HistoryScopeSelectorPolicy.showsTitle(for: range, selection: selection),
            selectionNamespace: scopeSelection
        ) { select(range) }
    }

    private func select(_ range: HistoryQuickRange) {
        guard selection != range else { return }
        withAnimation(
            MoneyUpMotion.animation(
                for: .selection,
                reduceMotion: reduceMotion
            )
        ) {
            selection = range
        }
    }
}
