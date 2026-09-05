import Foundation
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

struct HistoryScopeSelector: View {
    @Binding private var selection: HistoryQuickRange?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
            Label(selectedTitle, systemImage: selectedSystemImage)
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
        let isSelected = selection == range
        return Button {
            select(range)
        } label: {
            Group {
                if HistoryScopeSelectorPolicy.showsTitle(
                    for: range,
                    selection: selection
                ) {
                    Label(range.title, systemImage: range.systemImage)
                        .padding(.horizontal, 14)
                } else {
                    Image(systemName: range.systemImage)
                        .frame(width: HistoryScopeSelectorPolicy.minimumTapDimension)
                }
            }
            .font(.subheadline.weight(.semibold))
            .frame(minHeight: HistoryScopeSelectorPolicy.minimumTapDimension)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.18)
                    : Color.secondary.opacity(0.10),
                in: Capsule()
            )
        }
        .buttonStyle(MoneyUpPressableButtonStyle())
        .accessibilityLabel(Text(range.title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
