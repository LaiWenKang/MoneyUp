import MoneyUpCore
import SwiftUI

struct TransactionRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(MoneyAmountPrivacy.storageKey)
    private var hidesAmounts = MoneyAmountPrivacy.defaultHidesAmounts
    let entry: JournalEntry
    let searchMatchLabel: String?
    let budgetCategoryIDs: Set<UUID>?
    let budgetCurrency: CurrencyCode?

    init(entry: JournalEntry, searchMatchLabel: String? = nil,
         budgetCategoryIDs: Set<UUID>? = nil, budgetCurrency: CurrencyCode? = nil) {
        self.entry = entry
        self.searchMatchLabel = searchMatchLabel
        self.budgetCategoryIDs = budgetCategoryIDs
        self.budgetCurrency = budgetCurrency
    }

    private var categoryName: String? {
        entry.postings.lazy.compactMap { posting in
            if let budgetCategoryIDs, !budgetCategoryIDs.contains(posting.accountID) { return nil }
            let account = model.accountsByID[posting.accountID]
            return account?.kind == .expense || account?.kind == .income
                ? model.categoryPathName(for: posting.accountID)
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
        case .expense: isRefund ? MoneyUpChartPalette.income : MoneyUpChartPalette.expense
        case .income: Color.moneyUpPositive
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
        if let budgetCategoryIDs, let budgetCurrency {
            do {
                let amount = try BudgetSpendingScope.amount(for: entry, categoryIDs: budgetCategoryIDs, currency: budgetCurrency)
                return .available([TransactionDisplayAmount(
                    money: amount.amount < .zero ? amount.negated : amount,
                    role: amount.amount < .zero ? .refund : .expense
                )])
            } catch { return .unavailable(.amountCalculationFailed) }
        }
        return transactionDisplayAmountsResult(
            for: entry,
            accountsByID: model.accountsByID,
            isRefund: isRefund
        )
    }

    private var localizedKind: String {
        isRefund
            ? AppLocalization.string("transaction.refund")
            : AppLocalization.string(entry.kind.localizedKey)
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
        if let note = entry.note { components.append(note) }
        if let searchMatchLabel { components.append(searchMatchLabel) }
        if budgetCategoryIDs != nil { components.append(AppLocalization.string("history.category_amount")) }
        components.append(reportingDateDescription)
        switch displayedAmountsResult {
        case let .available(amounts):
            components.append(
                contentsOf: amounts.map(accessibleFormattedTransactionAmount)
            )
        case let .unavailable(issue):
            components.append(issue.localizedDescription)
        }
        return components.joined(separator: ", ")
    }

    var body: some View {
        let _ = hidesAmounts
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 10) {
                        transactionIcon
                        Text(title)
                            .fontWeight(.semibold)
                            .lineLimit(2)
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
                            .lineLimit(2)
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

    /// The kind glyph carries a small, stable category tint so a day of
    /// rows can be scanned by colour before reading a single label.
    private var transactionIcon: some View {
        Image(systemName: icon)
            .foregroundStyle(iconColor)
            .frame(width: 34, height: 34)
            .background(iconColor.opacity(0.11))
            .clipShape(Circle())
            .overlay(alignment: .bottomTrailing) {
                if let tint = categoryTint {
                    Circle()
                        .fill(tint)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Color.moneyUpSurfaceElevated, lineWidth: 1.5))
                }
            }
            .accessibilityHidden(true)
    }

    private var categoryTint: Color? {
        guard let categoryID = entry.postings.lazy.compactMap({ posting -> UUID? in
            let account = model.accountsByID[posting.accountID]
            return account?.kind == .expense || account?.kind == .income ? posting.accountID : nil
        }).first else { return nil }
        let hash = categoryID.uuidString.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return MoneyUpChartPalette.color(at: hash % 6)
    }

    private var transactionMetadata: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(reportingDateDescription)
                if let categoryName, categoryName != title {
                    Text("•")
                    Text(categoryName)
                }
            }
            if let note = entry.note {
                Text(note)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
            }
            if let searchMatchLabel {
                Label(searchMatchLabel, systemImage: "doc.text.magnifyingglass")
                    .foregroundStyle(.tint)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
    }

    @ViewBuilder
    private var amountContent: some View {
        if case let .available(amounts) = displayedAmountsResult,
           !amounts.isEmpty {
            VStack(
                alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing,
                spacing: 2
            ) {
                if budgetCategoryIDs != nil {
                    Text("history.category_amount").font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(Array(amounts.prefix(2).enumerated()), id: \.offset) {
                    _, amount in
                    Text(formattedTransactionAmount(amount))
                        .moneyUpFinancialValue(.compact)
                        .foregroundStyle(
                            amount.role == .income
                                || amount.role == .refund
                                || amount.role == .incoming
                                ? Color.moneyUpPositive
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
                    .moneyUpFinancialValue(.compact)
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
    var localizedKey: String {
        switch self {
        case .expense: "transaction.expense"
        case .income: "transaction.income"
        case .transfer: "transaction.transfer"
        case .adjustment: "transaction.adjustment"
        case .investment: "transaction.investment"
        }
    }
}
