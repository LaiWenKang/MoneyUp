import MoneyUpCore
import SwiftUI

private struct CalendarLoadRequest: Hashable {
    let day: Date
    let generation: Int
    let computationGeneration: Int
    let logicalBookRevision: UInt64
}

private struct CalendarDateComputation {
    let day: Date
    let scheduledTransactions: [ScheduledTransaction]
    let dayFlows: DerivedValue<[CurrencyFlow]>
}

struct CalendarView: View {
    /// History pushes this screen onto its own stack, where the system draws
    /// the back button; Plan swaps it in as a section and must supply both the
    /// container and the way back itself. A nested stack in the pushed case
    /// would silently remove History's back button.
    let providesNavigationStack: Bool
    /// Supplied when Plan swaps this section in; nil when History pushes it.
    let sectionBack: MoneyUpSectionBackAction?

    init(
        providesNavigationStack: Bool = true,
        sectionBack: MoneyUpSectionBackAction? = nil
    ) {
        self.providesNavigationStack = providesNavigationStack
        self.sectionBack = sectionBack
    }

    @Environment(AppModel.self) private var model
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
    @State private var computationGeneration = 0
    @State private var dateComputation: CalendarDateComputation?
    @State private var scheduleMatchCandidates: [UUID: [JournalEntry]] = [:]
    @State private var scheduleMatchesLoading = Set<UUID>()

    private var selectedDayInterval: DateInterval? {
        dayInterval(for: selectedDate)
    }

    private func dayInterval(for date: Date) -> DateInterval? {
        FinancialPeriodBoundary.inclusiveDayInterval(
            from: date,
            through: date,
            calendar: model.reportingCalendar
        )
    }

    private var loadRequest: CalendarLoadRequest {
        CalendarLoadRequest(
            day: selectedDayInterval?.start ?? selectedDate,
            generation: reloadGeneration,
            computationGeneration: computationGeneration,
            logicalBookRevision: model.logicalBookRevision
        )
    }

    private var currentDateComputation: CalendarDateComputation? {
        guard dateComputation?.day == loadRequest.day else { return nil }
        return dateComputation
    }

    var body: some View {
        Group {
            if providesNavigationStack {
                NavigationStack { presentedCalendarList }
            } else {
                presentedCalendarList
            }
        }
        .environment(\.calendar, model.reportingCalendar)
        .environment(\.timeZone, model.reportingCalendar.timeZone)
    }

    private var calendarListContent: some View {
        List {
            calendarDatePicker
            calendarMoneyFlowSection
            actualsSection
            calendarScheduledSection
        }
    }

    private var calendarDatePicker: some View {
        DatePicker(
            "calendar.select_date",
            selection: $selectedDate,
            displayedComponents: .date
        )
        .datePickerStyle(.graphical)
    }

    private var calendarMoneyFlowSection: some View {
        let dateComputation = currentDateComputation
        let isDateComputationLoading = isLoadingActuals || dateComputation == nil
        return moneyFlowSection(
            dateComputation: dateComputation,
            isLoading: isDateComputationLoading
        )
    }

    private var calendarScheduledSection: some View {
        scheduledSection(dateComputation: currentDateComputation)
    }

    private var styledCalendarList: some View {
        calendarListContent
        .scrollContentBackground(.hidden)
        .background(Color.moneyUpBackground)
        .navigationTitle("tab.calendar")
        .moneyUpSectionBackToolbar(sectionBack)
    }

    private var loadingCalendarList: some View {
        styledCalendarList
        .task(id: loadRequest) {
            await loadSelectedActuals()
        }
    }

    private var scheduleObservedCalendarList: some View {
        loadingCalendarList
        .onChange(of: model.scheduledTransactions) { _, _ in
            invalidateDateComputation()
        }
    }

    private var accountObservedCalendarList: some View {
        scheduleObservedCalendarList
        .onChange(of: model.accounts) { _, _ in
            invalidateDateComputation()
        }
    }

    private var profileObservedCalendarList: some View {
        accountObservedCalendarList
        .onChange(of: model.profile) { _, _ in
            invalidateDateComputation()
        }
    }

    private var calendarList: some View {
        profileObservedCalendarList
        .onChange(of: model.logicalBookRevision) { _, _ in
            resetForLogicalBookRevision()
        }
    }

    private func invalidateDateComputation() {
        computationGeneration &+= 1
    }

    private func resetForLogicalBookRevision() {
        selectedEntries = []
        dateComputation = nil
        scheduleMatchCandidates = [:]
        scheduleMatchesLoading = []
        entryPendingDeletion = nil
        schedulePendingDeletion = nil
        scheduleBeingEdited = nil
        isAddingSchedule = false
        errorMessage = nil
        actualsUnavailable = false
        isLoadingActuals = true
    }

    private var calendarListWithToolbar: some View {
        calendarList
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
    }

    private var presentedCalendarList: some View {
        calendarListWithToolbar
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
            .moneyUpOperationErrorAlert(message: $errorMessage)
    }

    @ViewBuilder
    private func moneyFlowSection(
        dateComputation: CalendarDateComputation?,
        isLoading: Bool
    ) -> some View {
        if isLoading {
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
                    Label(
                        "calendar.actuals_unavailable",
                        systemImage: "exclamationmark.arrow.triangle.2.circlepath"
                    )
                } description: {
                    Text("calendar.actuals_unavailable_detail")
                } actions: {
                    Button("action.retry") { reloadGeneration += 1 }
                }
            }
        } else if let dateComputation,
                  case let .available(flows) = dateComputation.dayFlows,
                  !flows.isEmpty {
            Section("calendar.money_flow") {
                ForEach(flows) { flow in
                    LabeledContent {
                        Text(formattedMoney(flow.income))
                    } label: {
                        Text("\(AppLocalization.string("transaction.income")) (\(flow.currency.value))")
                    }
                    LabeledContent {
                        Text(formattedMoney(flow.expense))
                    } label: {
                        Text("\(AppLocalization.string("transaction.expense")) (\(flow.currency.value))")
                    }
                }
            }
        } else if let dateComputation,
                  case let .unavailable(issue) = dateComputation.dayFlows {
            Section("calendar.money_flow") {
                DerivedValueUnavailableView(issue: issue)
            }
        }
    }

    @ViewBuilder
    private var actualsSection: some View {
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
    }

    @ViewBuilder
    private func scheduledSection(
        dateComputation: CalendarDateComputation?
    ) -> some View {
        Section("calendar.scheduled") {
            if let dateComputation,
               dateComputation.scheduledTransactions.isEmpty {
                Text("calendar.no_scheduled")
                    .foregroundStyle(.secondary)
            } else if let dateComputation {
                ForEach(dateComputation.scheduledTransactions) { item in
                    scheduledRow(for: item)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private func scheduledRow(for item: ScheduledTransaction) -> some View {
        Button {
            scheduleBeingEdited = item
        } label: {
            HStack {
                Label(item.name, systemImage: scheduleStatusIcon(for: item))
                Spacer()
                Text(formattedMoney(item.amount))
                    .font(.subheadline.monospacedDigit())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.name)
        .accessibilityValue(scheduleAccessibilityValue(for: item))
        .accessibilityHint("schedule.edit")
        .contextMenu { scheduleActions(for: item) }
        .swipeActions {
            Button(role: .destructive) {
                schedulePendingDeletion = item
            } label: {
                Label("action.delete", systemImage: "trash")
            }
        }
    }

    private func scheduleStatusIcon(for item: ScheduledTransaction) -> String {
        item.isCurrentOccurrenceConfirmed ? "checkmark.circle" : "clock"
    }

    private func scheduleAccessibilityValue(
        for item: ScheduledTransaction
    ) -> String {
        let status = item.isCurrentOccurrenceConfirmed
            ? AppLocalization.string("schedule.confirmed")
            : AppLocalization.string("schedule.pending")
        return "\(formattedMoney(item.amount)), \(status)"
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
            activeScheduleActions(for: item)
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

    @ViewBuilder
    private func activeScheduleActions(for item: ScheduledTransaction) -> some View {
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
                    ? AppLocalization.string("schedule.confirmed")
                    : AppLocalization.string("schedule.confirm"),
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

        scheduleMatchMenu(for: item)

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
    }

    private func scheduleMatchMenu(for item: ScheduledTransaction) -> some View {
        Menu {
            if scheduleMatchesLoading.contains(item.id) {
                ProgressView()
            } else if let matches = scheduleMatchCandidates[item.id] {
                if matches.isEmpty {
                    Text("schedule.match_none")
                } else {
                    ForEach(matches.prefix(8)) { entry in
                        Button(entry.payee ?? entry.occurredAt.formattedForReporting(
                            Date.FormatStyle(date: .abbreviated, time: .omitted),
                            calendar: model.reportingCalendar
                        )) {
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
    }
}

extension CalendarView {
    private func loadSelectedActuals() async {
        let request = loadRequest
        isLoadingActuals = true
        actualsUnavailable = false
        selectedEntries = []
        dateComputation = nil
        guard let interval = dayInterval(for: request.day) else {
            guard loadRequest == request else { return }
            guard !model.isBookReplacementInProgress else { return }
            dateComputation = computeSelectedDate(
                request: request,
                entries: [],
                actualsAreAvailable: false
            )
            actualsUnavailable = true
            isLoadingActuals = false
            return
        }
        do {
            let loaded = try await model.calendarEntries(in: interval)
            try Task.checkCancellation()
            guard loadRequest == request else { return }
            guard !model.isBookReplacementInProgress else { return }
            let computed = computeSelectedDate(
                request: request,
                entries: loaded,
                actualsAreAvailable: true
            )
            selectedEntries = loaded
            dateComputation = computed
            isLoadingActuals = false
        } catch is CancellationError {
            return
        } catch {
            guard loadRequest == request else { return }
            guard !model.isBookReplacementInProgress else { return }
            selectedEntries = []
            dateComputation = computeSelectedDate(
                request: request,
                entries: [],
                actualsAreAvailable: false
            )
            actualsUnavailable = true
            isLoadingActuals = false
        }
    }

    /// Runs exactly once for a matching load request, after indexed I/O has
    /// returned. SwiftUI body reevaluations never create timing samples.
    private func computeSelectedDate(
        request: CalendarLoadRequest,
        entries: [JournalEntry],
        actualsAreAvailable: Bool
    ) -> CalendarDateComputation {
        let performanceInterval = MoneyUpPerformanceSignposts.begin(
            .calendarDateComputation
        )
        var performanceOutcome = MoneyUpPerformanceOutcome.success
        defer {
            MoneyUpPerformanceSignposts.end(
                performanceInterval,
                outcome: performanceOutcome
            )
        }
        let calendar = model.reportingCalendar
        let schedules = model.scheduledTransactions.filter {
            $0.occurs(on: request.day, calendar: calendar)
        }
        guard actualsAreAvailable else {
            performanceOutcome = .failure
            return CalendarDateComputation(
                day: request.day,
                scheduledTransactions: schedules,
                dayFlows: .unavailable(.appNotReady)
            )
        }
        let flows = calendarDayFlows(
            on: request.day,
            entries: entries,
            calendar: calendar,
            outcome: &performanceOutcome
        )
        return CalendarDateComputation(
            day: request.day,
            scheduledTransactions: schedules,
            dayFlows: flows
        )
    }

    private func calendarDayFlows(
        on day: Date,
        entries: [JournalEntry],
        calendar: Calendar,
        outcome: inout MoneyUpPerformanceOutcome
    ) -> DerivedValue<[CurrencyFlow]> {
        guard let currency = model.profile?.baseCurrency else {
            outcome = .failure
            return .unavailable(.appNotReady)
        }
        guard let interval = dayInterval(for: day) else {
            outcome = .failure
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
                entries: entries,
                baseCurrency: currency,
                calendar: calendar
            ))
        } catch {
            outcome = .failure
            DerivedValueDiagnostics.record(
                .ledgerCalculationFailed,
                operation: "calendar-day-flow",
                error: error
            )
            return .unavailable(.ledgerCalculationFailed)
        }
    }

    private func loadMatches(for item: ScheduledTransaction) async {
        let expectedRevision = model.logicalBookRevision
        guard scheduleMatchesLoading.insert(item.id).inserted else { return }
        defer {
            if expectedRevision == model.logicalBookRevision {
                scheduleMatchesLoading.remove(item.id)
            }
        }
        do {
            let matches = try await model.matchingEntries(
                for: item,
                calendar: model.reportingCalendar
            )
            guard expectedRevision == model.logicalBookRevision,
                  !model.isBookReplacementInProgress else { return }
            scheduleMatchCandidates[item.id] = matches
        } catch {
            guard expectedRevision == model.logicalBookRevision else { return }
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
                // successful schedule action discards match candidates. The
                // observed schedule change restarts the selected-day query.
                scheduleMatchCandidates.removeAll()
            } catch {
                errorMessage = safeUserMessage(for: error, context: .save)
            }
        }
    }
}

private struct AddScheduleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

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
                            Text(accountCurrencyLabel(account)).tag(Optional(account.id))
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

            }
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .navigationTitle(
                schedule == nil
                    ? AppLocalization.string("schedule.add")
                    : AppLocalization.string("schedule.edit")
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
                MoneyUpKeyboardDoneToolbar()
            }
            .onAppear { selectDefaults() }
            .onChange(of: kind) { _, _ in selectDefaults() }
            .moneyUpOperationErrorAlert(message: $errorMessage)
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
