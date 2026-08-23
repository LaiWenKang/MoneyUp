import Foundation
import MoneyUpCore
import SwiftUI

enum QuickLogKind: String, CaseIterable, Identifiable {
    case expense
    case income
    case transfer

    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .expense: "transaction.expense"
        case .income: "transaction.income"
        case .transfer: "transaction.transfer"
        }
    }
}

struct QuickLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @FocusState private var isAmountFocused: Bool

    @State private var kind: QuickLogKind
    @State private var amountText = ""
    @State private var accountID: UUID?
    @State private var destinationAccountID: UUID?
    @State private var categoryID: UUID?
    @State private var occurredAt = Date()
    @State private var payee = ""
    @State private var note = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(initialKind: QuickLogKind = .expense) {
        _kind = State(initialValue: initialKind)
    }

    private var amount: Decimal? {
        guard let value = decimalAmount(from: amountText), value > .zero else { return nil }
        return value
    }

    private var categories: [LedgerAccount] {
        kind == .income ? model.incomeCategories : model.expenseCategories
    }

    private var canSave: Bool {
        guard amount != nil, accountID != nil else { return false }
        switch kind {
        case .expense, .income:
            return categoryID != nil
        case .transfer:
            return destinationAccountID != nil && destinationAccountID != accountID
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("transaction.kind", selection: $kind) {
                    ForEach(QuickLogKind.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                Section {
                    TextField("quick_log.amount", text: $amountText)
                        .keyboardType(.decimalPad)
                        .font(.title2.monospacedDigit())
                        .focused($isAmountFocused)

                    Picker(
                        kind == .transfer ? "transaction.from_account" : "transaction.account",
                        selection: $accountID
                    ) {
                        ForEach(model.userAccounts) { account in
                            Text(account.name).tag(Optional(account.id))
                        }
                    }

                    if kind == .transfer {
                        Picker("transaction.to_account", selection: $destinationAccountID) {
                            ForEach(model.userAccounts.filter { $0.id != accountID }) { account in
                                Text(account.name).tag(Optional(account.id))
                            }
                        }
                    } else {
                        Picker("transaction.category", selection: $categoryID) {
                            ForEach(categories) { category in
                                Text(category.name).tag(Optional(category.id))
                            }
                        }
                    }
                }

                Section {
                    DatePicker(
                        "quick_log.date",
                        selection: $occurredAt,
                        displayedComponents: [.date, .hourAndMinute]
                    )

                    if kind != .transfer {
                        TextField("transaction.payee", text: $payee)
                    }
                    TextField("quick_log.note", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }

                if model.userAccounts.isEmpty {
                    Section {
                        Text("transaction.no_accounts")
                            .foregroundStyle(.secondary)
                    }
                } else if kind == .transfer && model.userAccounts.count < 2 {
                    Section {
                        Text("transaction.need_two_accounts")
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("quick_log.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") {
                        Task { await save() }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
            .onAppear {
                selectDefaults()
                isAmountFocused = true
            }
            .onChange(of: kind) { _, _ in selectDefaults() }
            .onChange(of: accountID) { _, _ in
                if destinationAccountID == accountID {
                    destinationAccountID = model.userAccounts.first { $0.id != accountID }?.id
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .presentationDetents([.large])
    }

    private func selectDefaults() {
        accountID = accountID ?? model.userAccounts.first?.id
        switch kind {
        case .expense:
            categoryID = model.expenseCategories.first { $0.parentID != nil }?.id
                ?? model.expenseCategories.first?.id
        case .income:
            categoryID = model.incomeCategories.first?.id
        case .transfer:
            destinationAccountID = model.userAccounts.first { $0.id != accountID }?.id
        }
    }

    private func save() async {
        guard let amount, let accountID else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            switch kind {
            case .expense:
                guard let categoryID else { return }
                try await model.logExpense(
                    amount: amount,
                    accountID: accountID,
                    categoryID: categoryID,
                    occurredAt: occurredAt,
                    payee: payee,
                    note: note
                )
            case .income:
                guard let categoryID else { return }
                try await model.logIncome(
                    amount: amount,
                    accountID: accountID,
                    categoryID: categoryID,
                    occurredAt: occurredAt,
                    payee: payee,
                    note: note
                )
            case .transfer:
                guard let destinationAccountID else { return }
                try await model.logTransfer(
                    amount: amount,
                    sourceAccountID: accountID,
                    destinationAccountID: destinationAccountID,
                    occurredAt: occurredAt,
                    note: note
                )
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
