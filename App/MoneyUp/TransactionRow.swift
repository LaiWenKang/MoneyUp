import MoneyUpCore
import SwiftUI

struct TransactionRow: View {
    @EnvironmentObject private var model: AppModel
    let entry: JournalEntry

    private var categoryName: String? {
        let categoryIDs = Set(
            entry.postings.compactMap { posting in
                model.accounts.first(where: { $0.id == posting.accountID })
                    .flatMap { ($0.kind == .expense || $0.kind == .income) ? $0.id : nil }
            }
        )
        return model.accounts.first { categoryIDs.contains($0.id) }?.name
    }

    private var title: String {
        entry.payee ?? categoryName ?? String(localized: entry.kind.localizedKey)
    }

    private var icon: String {
        switch entry.kind {
        case .expense: "arrow.up.right"
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
            if let money = displayMoney(for: entry, accounts: model.accounts) {
                Text(formattedMoney(money))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(entry.kind == .income ? .green : .primary)
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
