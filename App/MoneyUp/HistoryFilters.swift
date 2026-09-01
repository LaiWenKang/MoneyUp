import MoneyUpCore
import MoneyUpPersistence
import SwiftUI
import UIKit

struct HistorySummaryView: View {
    let summary: HistorySummary

    private var currencies: [CurrencyCode] {
        summary.amountsByCurrency.keys.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("history.transactions") {
                Text(summary.transactionCount, format: .number)
                    .monospacedDigit()
            }
            if currencies.isEmpty {
                Text("history.no_filtered_total")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(currencies, id: \.self) { currency in
                    LabeledContent {
                        if let amount = summary.amountsByCurrency[currency] {
                            switch DerivedValue<Money>.money(
                                amount,
                                currency: currency,
                                operation: "history-filtered-total"
                            ) {
                            case let .available(money):
                                Text(formattedMoney(money))
                                    .monospacedDigit()
                            case let .unavailable(issue):
                                DerivedValueUnavailableView(issue: issue)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("history.filtered_total")
                            Text(currency.value)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text("history.total_explanation")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
    }
}

struct HistoryFilterSheet: View {
    private static let anyCategorySelection = "history-category:any"
    private static let chartGroupSelection = "history-category:chart-group"

    @Environment(\.dismiss) private var dismiss
    @State private var draft: HistoryFilterDraft

    let accounts: [LedgerAccount]
    let categories: [LedgerAccount]
    let calendar: Calendar
    let onApply: (HistoryFilterDraft) -> Void

    private var selectedCurrency: CurrencyCode? {
        accounts.first(where: { $0.id == draft.accountID })?.currency
    }

    private var categorySelection: Binding<String> {
        Binding(
            get: {
                guard let categoryIDs = draft.categoryIDs else {
                    return Self.anyCategorySelection
                }
                guard categoryIDs.count == 1, let categoryID = categoryIDs.first else {
                    return Self.chartGroupSelection
                }
                return Self.selectionKey(for: categoryID)
            },
            set: { selection in
                if selection == Self.anyCategorySelection {
                    draft.categoryIDs = nil
                    draft.categoryPostingCurrency = nil
                } else if selection == Self.chartGroupSelection {
                    // Keep the exact chart bucket when its existing row is
                    // reselected. This tag is only offered for that scope.
                } else if let categoryID = Self.categoryID(from: selection) {
                    draft.categoryIDs = [categoryID]
                    draft.categoryPostingCurrency = nil
                } else {
                    // Unknown tags fail closed instead of silently broadening
                    // a chart drill-through to every category.
                    draft.categoryIDs = []
                    draft.categoryPostingCurrency = nil
                }
            }
        )
    }

    private var hasChartCategoryGroup: Bool {
        guard let categoryIDs = draft.categoryIDs else { return false }
        return categoryIDs.count != 1
    }

    private static func selectionKey(for categoryID: UUID) -> String {
        "history-category:id:\(categoryID.uuidString.lowercased())"
    }

    private static func categoryID(from selection: String) -> UUID? {
        let prefix = "history-category:id:"
        guard selection.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(selection.dropFirst(prefix.count)))
    }

    init(
        filters: HistoryFilterDraft,
        accounts: [LedgerAccount],
        categories: [LedgerAccount],
        calendar: Calendar,
        onApply: @escaping (HistoryFilterDraft) -> Void
    ) {
        _draft = State(initialValue: filters)
        self.accounts = accounts
        self.categories = categories
        self.calendar = calendar
        self.onApply = onApply
    }

    var body: some View {
        let dateValidationMessage = draft.hasValidDateRange(calendar: calendar)
            ? nil
            : AppLocalization.string("history.filter.invalid_date_range")
        let amountValidationMessage = draft.hasValidAmountRange
            ? nil
            : AppLocalization.string("history.filter.invalid_range")
        NavigationStack {
            Form {
                Section {
                    Picker("history.filter.kind", selection: $draft.kind) {
                        ForEach(HistoryKindFilter.allCases, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    Picker("history.filter.account", selection: $draft.accountID) {
                        Text("history.filter.any_account").tag(nil as UUID?)
                        ForEach(accounts) { account in
                            Text(account.name).tag(Optional(account.id))
                        }
                    }
                    Picker("history.filter.category", selection: categorySelection) {
                        Text("history.filter.any_category")
                            .tag(Self.anyCategorySelection)
                        if hasChartCategoryGroup {
                            Text("insights.other_category")
                                .tag(Self.chartGroupSelection)
                        }
                        ForEach(categories) { category in
                            Text(category.name)
                                .tag(Self.selectionKey(for: category.id))
                        }
                    }
                    if let currency = draft.categoryPostingCurrency {
                        LabeledContent("transaction.currency", value: currency.value)
                    }
                }

                Section("history.filter.date") {
                    Toggle("history.filter.start_date", isOn: $draft.includesStartDate)
                    if draft.includesStartDate {
                        DatePicker(
                            "history.filter.start_date",
                            selection: $draft.startDate,
                            displayedComponents: .date
                        )
                        .moneyUpFieldValidation(dateValidationMessage)
                    }
                    Toggle("history.filter.end_date", isOn: $draft.includesEndDate)
                    if draft.includesEndDate {
                        DatePicker(
                            "history.filter.end_date",
                            selection: $draft.endDate,
                            displayedComponents: .date
                        )
                        .moneyUpFieldValidation(dateValidationMessage)
                    }
                    if let dateValidationMessage {
                        MoneyUpFieldError(message: dateValidationMessage)
                    }
                }

                Section {
                    TextField("history.filter.minimum", text: $draft.minimumAmountText)
                        .moneyAmountKeyboard(currency: selectedCurrency)
                        .moneyUpFieldValidation(amountValidationMessage)
                    TextField("history.filter.maximum", text: $draft.maximumAmountText)
                        .moneyAmountKeyboard(currency: selectedCurrency)
                        .moneyUpFieldValidation(amountValidationMessage)
                    if let amountValidationMessage {
                        MoneyUpFieldError(message: amountValidationMessage)
                    }
                } header: {
                    Text("history.filter.amount")
                } footer: {
                    Text("history.filter.amount_note")
                }

                Section {
                    Button("action.reset", role: .destructive) {
                        draft = HistoryFilterDraft(calendar: calendar)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .navigationTitle("history.filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.apply") {
                        onApply(draft)
                        dismiss()
                    }
                    .disabled(!draft.isValid(calendar: calendar))
                }
                MoneyUpKeyboardDoneToolbar()
            }
        }
        .environment(\.calendar, calendar)
        .environment(\.timeZone, calendar.timeZone)
    }
}
