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

    /// Without a merchant the row leads with the category's own name; the
    /// glyph already places it, and VoiceOver still hears the full path.
    private var title: String {
        entry.payee
            ?? transferRouteTitle
            ?? categoryID.flatMap { model.accountsByID[$0]?.name }
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

    /// Spending and income lead with their category's glyph, so a day of
    /// rows scans by shape; a corner mark and the signed amount carry the
    /// direction. Transfers and investment events keep their movement glyph
    /// because no category explains them.
    private var transactionIcon: some View {
        MoneyUpCategoryBadge(
            systemImage: categoryID.map {
                MoneyUpCategorySymbol.symbol(for: $0, accountsByID: model.accountsByID)
            } ?? icon,
            tint: categoryID.map(MoneyUpCategorySymbol.tint(for:)) ?? iconColor,
            cornerSymbol: cornerSymbol
        )
    }

    private var categoryID: UUID? {
        guard entry.kind == .expense || entry.kind == .income else { return nil }
        return entry.postings.lazy.compactMap { posting -> UUID? in
            if let budgetCategoryIDs, !budgetCategoryIDs.contains(posting.accountID) { return nil }
            let account = model.accountsByID[posting.accountID]
            return account?.kind == .expense || account?.kind == .income ? posting.accountID : nil
        }.first
    }

    private var cornerSymbol: String? {
        guard categoryID != nil else { return nil }
        if isRefund { return "arrow.uturn.backward" }
        return entry.kind == .income ? "arrow.down" : nil
    }

    private var transactionMetadata: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(reportingDateDescription)
                if let categoryName, entry.payee != nil || transferRouteTitle != nil {
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
                    Text(rowFormattedAmount(amount))
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

/// Money coming back (income, refund) reads with an explicit plus in a row,
/// so its direction never depends on the green alone.
@MainActor
func rowFormattedAmount(_ amount: TransactionDisplayAmount) -> String {
    let value = formattedTransactionAmount(amount)
    guard !MoneyAmountPrivacy.hidesAmounts,
          amount.role == .income || amount.role == .refund else { return value }
    return "+" + value
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
