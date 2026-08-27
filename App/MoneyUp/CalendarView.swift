import MoneyUpCore
import SwiftUI

private struct CalendarLoadRequest: Hashable {
    let day: Date
    let generation: Int
}

struct CalendarView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedDate = Date()
    @State private var isAddingSchedule = false
    @State private var errorMessage: String?
    @State private var entryPendingDeletion: JournalEntry?
    @State private var schedulePendingDeletion: ScheduledTransaction?
    @State private var scheduleBeingEdited: ScheduledTransaction?
    @State private var selectedEntries: [JournalEntry] = []
    @State private var isLoadingActuals = true
    @State private var actualsUnavailable = false
    @State private var reloadGeneration = 0
    @State private var scheduleMatchCandidates: [UUID: [JournalEntry]] = [:]
    @State private var scheduleMatchesLoading = Set<UUID>()

    private var selectedDayInterval: DateInterval? {
        FinancialPeriodBoundary.inclusiveDayInterval(
            from: selectedDate,
            through: selectedDate,
            calendar: model.reportingCalendar
        )
    }

    private var loadRequest: CalendarLoadRequest {
        CalendarLoadRequest(
            day: selectedDayInterval?.start ?? selectedDate,
            generation: reloadGeneration
        )
    }

    private var scheduledForDay: [ScheduledTransaction] {
        let calendar = model.reportingCalendar
        return model.scheduledTransactions.filter { item in
            item.occurs(on: selectedDate, calendar: calendar)
        }
    }

    /// The day's money flow, one line per currency. A day spent abroad used to
    /// read as zero because everything outside the base currency was filtered
    /// out before the totals were taken.
    private var dayFlows: DerivedValue<[CurrencyFlow]> {
        guard let currency = model.profile?.baseCurrency else {
            return .unavailable(.appNotReady)
        }
        guard let interval = selectedDayInterval else {
            DerivedValueDiagnostics.record(
                .invalidPeriod,
                operation: "calendar-day-interval"
            )
            return .unavailable(.invalidPeriod)
        }
        do {
            return .available(try FinanceCalculator.dailyFlows(
                interval: interval,
                accounts: model.accounts,
                entries: selectedEntries,
                baseCurrency: currency,
                calendar: model.reportingCalendar
            )
            return .available(
                ([report.baseFlow] + report.foreignFlows).filter { !$0.isEmpty }
            )
        } catch {
            DerivedValueDiagnostics.record(
                .ledgerCalculationFailed,
                operation: "calendar-day-flow",
                error: error
            )
            return .unavailable(.ledgerCalculationFailed)
        }
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

                if isLoadingActuals {
                    Section("calendar.money_flow") {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("calendar.loading_actuals")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if actualsUnavailable {
                    Section("calendar.money_flow") {
                        ContentUnavailableView {
                            Label("calendar.actuals_unavailable", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        } description: {
                            Text("calendar.actuals_unavailable_detail")
                        } actions: {
                            Button("action.retry") { reloadGeneration += 1 }
                        }
                    }
                } else if case let .available(flows) = dayFlows,
                   !flows.isEmpty {
                    Section("calendar.money_flow") {
                        ForEach(flows) { flow in
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
                } else if case let .unavailable(issue) = dayFlows {
                    Section("calendar.money_flow") {
                        DerivedValueUnavailableView(issue: issue)
                    }
                }

                Section("calendar.actual") {
                    if isLoadingActuals {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                            .accessibilityLabel("calendar.loading_actuals")
                    } else if actualsUnavailable {
                        Text("calendar.actuals_unavailable_detail")
                            .foregroundStyle(.secondary)
                    } else if selectedEntries.isEmpty {
                        Text("calendar.no_actual")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(selectedEntries) { entry in
                            TransactionRow(entry: entry)
                                .swipeActions {
                                    if !model.isProtectedJournalEntry(entry) {
                                        Button(role: .destructive) {
                                            entryPendingDeletion = entry
                                        } label: {
                                            Label("action.delete", systemImage: "trash")
                                        }
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
                                Label(
                                    item.name,
                                    systemImage: item.isCurrentOccurrenceConfirmed
                                        ? "checkmark.circle"
                                        : "clock"
                                )
                                Spacer()
                                Text(formattedMoney(item.amount))
                                    .font(.subheadline.monospacedDigit())
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { scheduleBeingEdited = item }
                            .contextMenu { scheduleActions(for: item) }
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
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .navigationTitle("tab.calendar")
            .task(id: loadRequest) {
                await loadSelectedActuals()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        if model.scheduledTransactions.isEmpty {
                            Text("calendar.no_scheduled")
                        } else {
                            ForEach(model.scheduledTransactions) { item in
                                Menu(item.name) { scheduleActions(for: item) }
                            }
                        }
                    } label: {
                        Label("schedule.manage", systemImage: "calendar.badge.clock")
                    }
                }
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
            .sheet(item: $scheduleBeingEdited) { item in
                AddScheduleSheet(schedule: item)
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
        .environment(\.calendar, model.reportingCalendar)
        .environment(\.timeZone, model.reportingCalendar.timeZone)
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
            reloadGeneration += 1
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }

    private func delete(_ item: ScheduledTransaction) async {
        do {
            try await model.deleteScheduledTransaction(id: item.id)
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }

    @ViewBuilder
    private func scheduleActions(for item: ScheduledTransaction) -> some View {
        Button {
            scheduleBeingEdited = item
        } label: {
            Label("action.edit", systemImage: "pencil")
        }

        switch item.status {
        case .active:
            Button {
                perform {
                    try await model.confirmScheduledOccurrence(
                        scheduleID: item.id,
                        occurrenceID: item.currentOccurrenceID
                    )
                }
            } label: {
                Label(
                    item.isCurrentOccurrenceConfirmed
                        ? String(localized: "schedule.confirmed")
                        : String(localized: "schedule.confirm"),
                    systemImage: "checkmark.circle"
                )
            }
            .disabled(item.isCurrentOccurrenceConfirmed)

            Button {
                perform {
                    _ = try await model.postScheduledOccurrence(
                        scheduleID: item.id,
                        occurrenceID: item.currentOccurrenceID,
                        calendar: model.reportingCalendar
                    )
                }
            } label: {
                Label("schedule.post", systemImage: "arrow.down.doc")
            }

            Menu {
                if scheduleMatchesLoading.contains(item.id) {
                    ProgressView()
                } else if let matches = scheduleMatchCandidates[item.id] {
                    if matches.isEmpty {
                        Text("schedule.match_none")
                    } else {
                        ForEach(matches.prefix(8)) { entry in
                            Button(entry.payee ?? entry.occurredAt.formatted(date: .abbreviated, time: .omitted)) {
                                perform {
                                    try await model.matchScheduledOccurrence(
                                        scheduleID: item.id,
                                        occurrenceID: item.currentOccurrenceID,
                                        entryID: entry.id,
                                        calendar: model.reportingCalendar
                                    )
                                }
                            }
                        }
                    }
                } else {
                    Button("schedule.find_matches") {
                        Task { await loadMatches(for: item) }
                    }
                }
            } label: {
                Label("schedule.match", systemImage: "link")
            }

            Button {
                perform {
                    try await model.skipScheduledOccurrence(
                        scheduleID: item.id,
                        occurrenceID: item.currentOccurrenceID,
                        calendar: model.reportingCalendar
                    )
                }
            } label: {
                Label("schedule.skip", systemImage: "forward.end")
            }
            Button {
                perform { try await model.pauseScheduledTransaction(id: item.id) }
            } label: {
                Label("schedule.pause", systemImage: "pause")
            }
        case .paused:
            Button {
                perform { try await model.resumeScheduledTransaction(id: item.id) }
            } label: {
                Label("schedule.resume", systemImage: "play")
            }
        case .ended:
            EmptyView()
        }

        if item.status != .ended {
            Button(role: .destructive) {
                perform { try await model.endScheduledTransaction(id: item.id) }
            } label: {
                Label("schedule.end", systemImage: "stop.circle")
            }
        }
    }

    private func loadSelectedActuals() async {
        guard let interval = selectedDayInterval else {
            selectedEntries = []
            actualsUnavailable = true
            isLoadingActuals = false
            return
        }
        isLoadingActuals = true
        actualsUnavailable = false
        do {
            let loaded = try await model.calendarEntries(in: interval)
            try Task.checkCancellation()
            selectedEntries = loaded
            isLoadingActuals = false
        } catch is CancellationError {
            return
        } catch {
            selectedEntries = []
            actualsUnavailable = true
            isLoadingActuals = false
        }
    }

    private func loadMatches(for item: ScheduledTransaction) async {
        guard scheduleMatchesLoading.insert(item.id).inserted else { return }
        defer { scheduleMatchesLoading.remove(item.id) }
        do {
            scheduleMatchCandidates[item.id] = try await model.matchingEntries(
                for: item,
                calendar: model.reportingCalendar
            )
        } catch {
            errorMessage = safeUserMessage(for: error, context: .read)
        }
    }

    private func perform(
        _ operation: @escaping @MainActor () async throws -> Void
    ) {
        Task { @MainActor in
            do {
                try await operation()
                // Calendar owns a range-scoped actuals snapshot. Production's
                // recent cache is intentionally not authoritative, so every
                // successful schedule action re-queries the selected day and
                // discards match candidates derived before the mutation.
                scheduleMatchCandidates.removeAll()
                reloadGeneration &+= 1
            } catch {
                errorMessage = safeUserMessage(for: error, context: .save)
            }
        }
    }
}

private struct AddScheduleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    let schedule: ScheduledTransaction?

    @State private var kind: JournalEntryKind = .expense
    @State private var name = ""
    @State private var amountText = ""
    @State private var accountID: UUID?
    @State private var categoryID: UUID?
    @State private var nextOccurrence = Date()
    @State private var frequency: RecurrenceFrequency = .monthly
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(schedule: ScheduledTransaction? = nil) {
        self.schedule = schedule
        if let schedule {
            _kind = State(initialValue: schedule.kind)
            _name = State(initialValue: schedule.name)
            _amountText = State(initialValue: editableAmount(schedule.amount.amount))
            _accountID = State(initialValue: schedule.accountID)
            _categoryID = State(initialValue: schedule.categoryAccountID)
            _nextOccurrence = State(initialValue: schedule.nextOccurrence)
            _frequency = State(initialValue: schedule.frequency)
        }
    }

    private var categories: [LedgerAccount] {
        kind == .income ? model.incomeCategories : model.expenseCategories
    }

    private var selectedCurrency: CurrencyCode? {
        model.userAccounts.first(where: { $0.id == accountID })?.currency
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
                        .moneyAmountKeyboard(currency: selectedCurrency)
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
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .navigationTitle(
                schedule == nil
                    ? String(localized: "schedule.add")
                    : String(localized: "schedule.edit")
            )
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
        .environment(\.calendar, model.reportingCalendar)
        .environment(\.timeZone, model.reportingCalendar.timeZone)
    }

    private func selectDefaults() {
        accountID = accountID ?? model.userAccounts.first?.id
        if !categories.contains(where: { $0.id == categoryID }) {
            categoryID = categories.first { $0.parentID != nil }?.id ?? categories.first?.id
        }
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
            let money = try Money(amount, currency: currency)
            if let schedule {
                try await model.updateScheduledTransaction(
                    id: schedule.id,
                    kind: kind,
                    name: name,
                    amount: money,
                    accountID: accountID,
                    categoryAccountID: categoryID,
                    nextOccurrence: nextOccurrence,
                    frequency: frequency
                )
            } else {
                let item = try ScheduledTransaction(
                    kind: kind,
                    name: name,
                    amount: money,
                    accountID: accountID,
                    categoryAccountID: categoryID,
                    nextOccurrence: nextOccurrence,
                    frequency: frequency
                )
                try await model.addScheduledTransaction(item)
            }
            dismiss()
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
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
