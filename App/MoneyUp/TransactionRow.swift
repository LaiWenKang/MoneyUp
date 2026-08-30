import MoneyUpCore
import SwiftUI

struct TransactionRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: JournalEntry

    private var categoryName: String? {
        entry.postings.lazy.compactMap { posting in
            let account = model.accountsByID[posting.accountID]
            return account?.kind == .expense || account?.kind == .income
                ? account?.name
                : nil
        }.first
    }

    private var title: String {
        entry.payee
            ?? transferRouteTitle
            ?? categoryName
            ?? localizedKind
    }

    private var isRefund: Bool {
        guard entry.kind == .expense else { return false }
        // Archived categories remain part of historical explanations even
        // though new-entry pickers intentionally hide them.
        return entry.postings.contains {
            model.accountsByID[$0.accountID]?.kind == .expense
                && $0.money.amount < .zero
        }
    }

    private var icon: String {
        switch entry.kind {
        case .expense: isRefund ? "arrow.uturn.backward.circle" : "arrow.up.right"
        case .income: "arrow.down.left"
        case .transfer: "arrow.left.arrow.right"
        case .adjustment: "slider.horizontal.3"
        case .investment: "chart.line.uptrend.xyaxis"
        }
    }

    private var iconColor: Color {
        switch entry.kind {
        case .expense: isRefund ? .green : .orange
        case .income: .green
        case .transfer: .accentColor
        case .adjustment: .secondary
        case .investment: .accentColor
        }
    }

    private var financialAccountNames: [String] {
        entry.postings.compactMap { posting in
            guard let account = model.accountsByID[posting.accountID],
                  account.systemRole == nil,
                  account.kind == .asset || account.kind == .liability else {
                return nil
            }
            return account.name
        }
    }

    private var transferRouteTitle: String? {
        guard entry.kind == .transfer, financialAccountNames.count >= 2 else {
            return nil
        }
        return "\(financialAccountNames[0]) → \(financialAccountNames[1])"
    }

    private var displayedAmountsResult: DerivedValue<[TransactionDisplayAmount]> {
        transactionDisplayAmountsResult(
            for: entry,
            accountsByID: model.accountsByID,
            isRefund: isRefund
        )
    }

    private var localizedKind: String {
        isRefund
            ? String(localized: "transaction.refund")
            : String(localized: entry.kind.localizedKey)
    }

    private var reportingDateDescription: String {
        entry.occurredAt.formattedForReporting(
            .dateTime.month().day().hour().minute(),
            calendar: model.reportingCalendar
        )
    }

    private var accessibilityValue: String {
        var components: [String] = []
        if localizedKind != title { components.append(localizedKind) }
        if let categoryName, categoryName != title { components.append(categoryName) }
        components.append(reportingDateDescription)
        switch displayedAmountsResult {
        case let .available(amounts):
            components.append(contentsOf: amounts.map(formattedTransactionAmount))
        case let .unavailable(issue):
            components.append(issue.localizedDescription)
        }
        return components.joined(separator: ", ")
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 10) {
                        transactionIcon
                        Text(title)
                            .fontWeight(.semibold)
                            .lineLimit(3)
                    }
                    transactionMetadata
                    amountContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(spacing: 12) {
                    transactionIcon
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .lineLimit(1)
                        transactionMetadata
                    }
                    Spacer()
                    amountContent
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
    }

    private var transactionIcon: some View {
        Image(systemName: icon)
            .foregroundStyle(iconColor)
            .frame(width: 34, height: 34)
            .background(iconColor.opacity(0.11))
            .clipShape(Circle())
            .accessibilityHidden(true)
    }

    private var transactionMetadata: some View {
        HStack(spacing: 5) {
            Text(reportingDateDescription)
            if let categoryName, categoryName != title {
                Text("•")
                Text(categoryName)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
    }

    @ViewBuilder
    private var amountContent: some View {
        if case let .available(amounts) = displayedAmountsResult,
           !amounts.isEmpty {
            VStack(
                alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing,
                spacing: 2
            ) {
                ForEach(Array(amounts.prefix(2).enumerated()), id: \.offset) {
                    _, amount in
                    Text(formattedTransactionAmount(amount))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(
                            amount.role == .income
                                || amount.role == .refund
                                || amount.role == .incoming
                                ? Color.green
                                : Color.primary
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
            }
        } else if case let .unavailable(issue) = displayedAmountsResult {
            VStack(
                alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing,
                spacing: 2
            ) {
                Text("—")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                Text(issue.localizedDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        } else {
            Text(localizedKind)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private extension JournalEntryKind {
    var localizedKey: String.LocalizationValue {
        switch self {
        case .expense: "transaction.expense"
        case .income: "transaction.income"
        case .transfer: "transaction.transfer"
        case .adjustment: "transaction.adjustment"
        case .investment: "transaction.investment"
        }
    }
}
