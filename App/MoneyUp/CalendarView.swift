import MoneyUpCore
import SwiftUI

struct CalendarView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedDate = Date()
    @State private var isAddingSchedule = false
    @State private var errorMessage: String?
    @State private var entryPendingDeletion: JournalEntry?
    @State private var schedulePendingDeletion: ScheduledTransaction?

    private var selectedEntries: [JournalEntry] {
        model.entries.filter { Calendar.current.isDate($0.occurredAt, inSameDayAs: selectedDate) }
    }

    private var scheduledForDay: [ScheduledTransaction] {
        let calendar = Calendar.current
        return model.scheduledTransactions.filter { item in
            item.occurs(on: selectedDate, calendar: calendar)
        }
    }

    /// The day's money flow, one line per currency. A day spent abroad used to
    /// read as zero because everything outside the base currency was filtered
    /// out before the totals were taken.
    private var dayFlows: [CurrencyFlow] {
        guard let currency = model.profile?.baseCurrency,
              let interval = Calendar.current.dateInterval(of: .day, for: selectedDate),
              let report = try? FinanceCalculator.report(
                  interval: interval,
                  accounts: model.accounts,
                  entries: selectedEntries,
                  baseCurrency: currency
              ) else { return [] }
        return ([report.baseFlow] + report.foreignFlows).filter { !$0.isEmpty }
    }

    var body: some View {
        NavigationStack {
            List {
                DatePicker(
                    "calendar.select_date",
                    selection: $selectedDate,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)

                if !dayFlows.isEmpty {
                    Section("calendar.money_flow") {
                        ForEach(dayFlows) { flow in
                            LabeledContent {
                                Text(formattedMoney(flow.income))
                            } label: {
                                Text("\(String(localized: "transaction.income")) (\(flow.currency.value))")
                            }
                            LabeledContent {
                                Text(formattedMoney(flow.expense))
                            } label: {
                                Text("\(String(localized: "transaction.expense")) (\(flow.currency.value))")
                            }
                        }
                    }
                }

                Section("calendar.actual") {
                    if selectedEntries.isEmpty {
                        Text("calendar.no_actual")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(selectedEntries) { entry in
                            TransactionRow(entry: entry)
                                .swipeActions {
                                    Button(role: .destructive) {
                                        entryPendingDeletion = entry
                                    } label: {
                                        Label("action.delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }

                Section("calendar.scheduled") {
                    if scheduledForDay.isEmpty {
                        Text("calendar.no_scheduled")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(scheduledForDay) { item in
                            HStack {
                                Label(item.name, systemImage: "clock")
                                Spacer()
                                Text(formattedMoney(item.amount))
                                    .font(.subheadline.monospacedDigit())
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    schedulePendingDeletion = item
                                } label: {
                                    Label("action.delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("tab.calendar")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isAddingSchedule = true
                    } label: {
                        Label("schedule.add", systemImage: "calendar.badge.plus")
                    }
                }
            }
            .sheet(isPresented: $isAddingSchedule) {
                AddScheduleSheet()
            }
            .confirmationDialog(
                "transaction.delete_title",
                isPresented: deletionBinding(for: $entryPendingDeletion),
                titleVisibility: .visible,
                presenting: entryPendingDeletion
            ) { entry in
                Button("action.delete", role: .destructive) {
                    entryPendingDeletion = nil
                    Task { await delete(entry) }
                }
                Button("action.cancel", role: .cancel) {
                    entryPendingDeletion = nil
                }
            } message: { _ in
                Text("transaction.delete_detail")
            }
            .confirmationDialog(
                "schedule.delete_title",
                isPresented: deletionBinding(for: $schedulePendingDeletion),
                titleVisibility: .visible,
                presenting: schedulePendingDeletion
            ) { item in
                Button("action.delete", role: .destructive) {
                    schedulePendingDeletion = nil
                    Task { await delete(item) }
                }
                Button("action.cancel", role: .cancel) {
                    schedulePendingDeletion = nil
                }
            } message: { _ in
                Text("schedule.delete_detail")
            }
        }
    }

    private func deletionBinding<Value>(for value: Binding<Value?>) -> Binding<Bool> {
        Binding(
            get: { value.wrappedValue != nil },
            set: { if !$0 { value.wrappedValue = nil } }
        )
    }

    private func delete(_ entry: JournalEntry) async {
        do {
            try await model.deleteEntry(id: entry.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ item: ScheduledTransaction) async {
        do {
            try await model.deleteScheduledTransaction(id: item.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct AddScheduleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    @State private var kind: JournalEntryKind = .expense
    @State private var name = ""
    @State private var amountText = ""
    @State private var accountID: UUID?
    @State private var categoryID: UUID?
    @State private var nextOccurrence = Date()
    @State private var frequency: RecurrenceFrequency = .monthly
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var categories: [LedgerAccount] {
        kind == .income ? model.incomeCategories : model.expenseCategories
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let amount = decimalAmount(from: amountText), amount > .zero,
              accountID != nil, categoryID != nil else { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("transaction.kind", selection: $kind) {
                    Text("transaction.expense").tag(JournalEntryKind.expense)
                    Text("transaction.income").tag(JournalEntryKind.income)
                }
                .pickerStyle(.segmented)

                Section {
                    TextField("schedule.name", text: $name)
                    TextField("quick_log.amount", text: $amountText)
                        .keyboardType(.decimalPad)
                    Picker("transaction.account", selection: $accountID) {
                        ForEach(model.userAccounts) { account in
                            Text(account.name).tag(Optional(account.id))
                        }
                    }
                    Picker("transaction.category", selection: $categoryID) {
                        ForEach(categories) { category in
                            Text(category.name).tag(Optional(category.id))
                        }
                    }
                }

                Section {
                    DatePicker("schedule.next_date", selection: $nextOccurrence)
                    Picker("schedule.frequency", selection: $frequency) {
                        ForEach(RecurrenceFrequency.allCases, id: \.self) { item in
                            Text(item.localizedTitle).tag(item)
                        }
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("schedule.add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") { Task { await save() } }
                        .disabled(!canSave || isSaving)
                }
            }
            .onAppear { selectDefaults() }
            .onChange(of: kind) { _, _ in selectDefaults() }
        }
    }

    private func selectDefaults() {
        accountID = accountID ?? model.userAccounts.first?.id
        categoryID = categories.first { $0.parentID != nil }?.id ?? categories.first?.id
    }

    private func save() async {
        guard let amount = decimalAmount(from: amountText),
              let accountID,
              let categoryID,
              let currency = model.accounts.first(where: { $0.id == accountID })?.currency else {
            return
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let item = try ScheduledTransaction(
                kind: kind,
                name: name,
                amount: try Money(amount, currency: currency),
                accountID: accountID,
                categoryAccountID: categoryID,
                nextOccurrence: nextOccurrence,
                frequency: frequency
            )
            try await model.addScheduledTransaction(item)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private extension RecurrenceFrequency {
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .weekly: "schedule.weekly"
        case .monthly: "schedule.monthly"
        case .yearly: "schedule.yearly"
        }
    }
}
