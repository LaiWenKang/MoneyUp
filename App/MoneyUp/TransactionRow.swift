import MoneyUpCore
import SwiftUI

struct TransactionRow: View {
    @EnvironmentObject private var model: AppModel
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
        entry.payee ?? categoryName ?? String(localized: entry.kind.localizedKey)
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

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(entry.occurredAt, format: .dateTime.month().day().hour().minute())
                    if let categoryName, categoryName != title {
                        Text("•")
                        Text(categoryName)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            if let money = displayMoney(for: entry, accountsByID: model.accountsByID) {
                Text(formattedMoney(isRefund ? money.negated : money))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(entry.kind == .income || isRefund ? .green : .primary)
            } else {
                Text("transaction.transfer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
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
