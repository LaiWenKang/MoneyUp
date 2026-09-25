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
    /// The Plan root supplies its shared stack. Other callers may request a
    /// standalone stack while sheets continue to own their own containers.
    let providesNavigationStack: Bool

    init(providesNavigationStack: Bool = true, workspace: PlanWorkspaceState = PlanWorkspaceState()) {
        self.workspace = workspace
        self.providesNavigationStack = providesNavigationStack
    }

    @Environment(AppModel.self) private var model
    @Bindable private var workspace: PlanWorkspaceState
    private var selectedDate: Date { workspace.calendarDate }
    @State private var isAddingSchedule = false
    @State private var errorMessage: String?
    @State private var entryPendingDeletion: JournalEntry?
    @State private var schedulePendingChange: PendingScheduleChange?
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
        VStack(alignment: .leading, spacing: 8) {
            if !model.reportingCalendar.isDate(selectedDate, inSameDayAs: model.currentDateForUserAction()) {
                Button("history.scope.today") { workspace.calendarDate = model.currentDateForUserAction() }
                    .font(.subheadline.weight(.semibold))
            }
            ReportingDaySelector(selection: $workspace.calendarDate, calendar: model.reportingCalendar)
        }
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
        .scrollDismissesKeyboard(.interactively)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .background(Color.moneyUpBackground)
        .navigationTitle("tab.calendar")
            .moneyUpNavigationSurface()
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
        schedulePendingChange = nil
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
                schedulePendingChange?.title ?? "schedule.delete_title",
                isPresented: deletionBinding(for: $schedulePendingChange),
                titleVisibility: .visible,
                presenting: schedulePendingChange
            ) { change in
                Button(change.action, role: .destructive) {
                    schedulePendingChange = nil
                    if change.ends {
                        perform { try await model.endScheduledTransaction(id: change.item.id) }
                    } else {
                        Task { await delete(change.item) }
                    }
                }
                Button("action.cancel", role: .cancel) {
                    schedulePendingChange = nil
                }
            } message: { change in
                Text(change.detail)
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
                MoneyUpLoadingPlaceholder(title: "calendar.loading_actuals")
            }
        } else if actualsUnavailable {
            Section("calendar.money_flow") {
                MoneyUpStatePlaceholder(
                    systemImage: "exclamationmark.arrow.triangle.2.circlepath",
                    tint: Color.moneyUpWarning,
                    title: "calendar.actuals_unavailable",
                    detail: "calendar.actuals_unavailable_detail"
                ) {
                    Button("action.retry") { reloadGeneration += 1 }
                        .buttonStyle(.bordered)
                }
            }
        } else if let dateComputation,
                  case let .available(flows) = dateComputation.dayFlows,
                  !flows.isEmpty {
            Section("calendar.money_flow") {
                ForEach(flows) { flow in
                    MoneyUpCashFlowGraphic(income: flow.income, expense: flow.expense)
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
                    TransactionRow(entry: entry, listedDay: selectedDate)
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
                schedulePendingChange = PendingScheduleChange(item: item, ends: false)
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
                schedulePendingChange = PendingScheduleChange(item: item, ends: true)
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
    @State private var initialDraftSignature: [String]?
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
        LedgerEntryChoices.visible(kind == .income ? model.incomeCategories : model.expenseCategories,
            preserving: Set([categoryID].compactMap { $0 }))
    }

    private var eligibleAccounts: [LedgerAccount] {
        LedgerEntryChoices.visible(model.userAccounts,
            preserving: Set([accountID].compactMap { $0 })).filter {
            kind != .expense || $0.accountType != .restrictedAllowance
        }
    }

    private var selectedCurrency: CurrencyCode? {
        eligibleAccounts.first(where: { $0.id == accountID })?.currency
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let amount = moneyAmount(from: amountText, currency: selectedCurrency), amount > .zero,
              let accountID,
              eligibleAccounts.contains(where: { $0.id == accountID }),
              categoryID != nil else { return false }
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
                        ForEach(eligibleAccounts) { account in
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
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .navigationTitle(
                schedule == nil
                    ? AppLocalization.string("schedule.add")
                    : AppLocalization.string("schedule.edit")
            )
            .moneyUpNavigationSurface()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") { Task { await save() } }
                        .disabled(!canSave || isSaving)
                }
                MoneyUpKeyboardDoneToolbar()
            }
            .onAppear {
                guard initialDraftSignature == nil else { return }
                selectDefaults()
                initialDraftSignature = draftSignature
            }
            .moneyUpProtectDraft(
                hasChanges: initialDraftSignature.map { $0 != draftSignature } ?? false,
                isSaving: isSaving
            )
            .disabled(isSaving)
            .onChange(of: kind) { _, _ in selectDefaults() }
            .moneyUpOperationErrorAlert(message: $errorMessage)
        }
        .environment(\.calendar, model.reportingCalendar)
        .environment(\.timeZone, model.reportingCalendar.timeZone)
    }

    private var draftSignature: [String] {
        [kind.rawValue, name, amountText, accountID?.uuidString ?? "",
         categoryID?.uuidString ?? "", String(nextOccurrence.timeIntervalSinceReferenceDate), frequency.rawValue]
    }

    private func selectDefaults() {
        if !eligibleAccounts.contains(where: { $0.id == accountID }) {
            accountID = eligibleAccounts.first?.id
        }
        if !categories.contains(where: { $0.id == categoryID }) {
            categoryID = categories.first { $0.parentID != nil }?.id ?? categories.first?.id
        }
    }

    private func save() async {
        guard let accountID,
              let categoryID,
              let currency = model.accounts.first(where: { $0.id == accountID })?.currency,
              let amount = moneyAmount(from: amountText, currency: currency) else {
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

/// What happened on one day, reduced to three marks. Kept separate from the
/// grid so the reading is testable without rendering.
struct CalendarDayMarks: Equatable, Sendable {
    var spent = false
    var received = false
    var scheduled = false

    static func byDay(
        entries: [JournalEntry],
        calendar: Calendar
    ) -> [Date: CalendarDayMarks] {
        var marks: [Date: CalendarDayMarks] = [:]
        for entry in entries {
            let day = calendar.startOfDay(
                for: entry.originContext.attributedDate(in: calendar) ?? entry.occurredAt
            )
            switch entry.kind {
            case .expense: marks[day, default: .init()].spent = true
            case .income: marks[day, default: .init()].received = true
            case .transfer, .adjustment, .investment: break
            }
        }
        return marks
    }
}

/// A schedule change that asks first: deleting it, or ending it for good.
private struct PendingScheduleChange {
    let item: ScheduledTransaction
    let ends: Bool
    var title: LocalizedStringKey { ends ? "schedule.end_title" : "schedule.delete_title" }
    var action: LocalizedStringKey { ends ? "schedule.end" : "action.delete" }
    var detail: LocalizedStringKey { ends ? "schedule.end_detail" : "schedule.delete_detail" }
}

/// Picks a reporting day. Grid days are reporting-zone midnights, so the
/// system picker used at accessibility sizes gets the same zone; in the device
/// zone it would show and select the previous day west of the reporting zone.
private struct ReportingDaySelector: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var selection: Date
    let calendar: Calendar

    private var displayCalendar: Calendar {
        var display = calendar
        display.firstWeekday = Calendar.autoupdatingCurrent.firstWeekday
        return display
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // Seven columns cannot hold accessibility-size digits; the
                // system picker reflows where a custom grid would clip.
                DatePicker("calendar.select_date", selection: $selection, displayedComponents: .date)
                    .datePickerStyle(.graphical)
            } else {
                CalendarMonthGrid(selection: $selection)
            }
        }
        .environment(\.calendar, displayCalendar)
        .environment(\.timeZone, calendar.timeZone)
    }
}

/// A month grid that shows, before any tap, which days had spending, income,
/// or a scheduled item. The system graphical picker cannot carry per-day
/// marks. Swipe or the arrows change month; tapping a day selects it.
private struct CalendarMonthGrid: View {
    @Environment(AppModel.self) private var model
    @Environment(\.moneyUpReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @Binding var selection: Date
    @State private var displayedMonth: Date?
    @State private var marks: [Date: CalendarDayMarks] = [:]

    private var calendar: Calendar { model.reportingCalendar }
    private var month: Date {
        calendar.dateInterval(of: .month, for: displayedMonth ?? selection)?.start ?? selection
    }
    private var today: Date { calendar.startOfDay(for: model.currentDateForUserAction()) }

    private var layout: CalendarMonthLayout {
        CalendarMonthLayout(
            month: month,
            calendar: calendar,
            firstWeekday: Calendar.autoupdatingCurrent.firstWeekday,
            locale: locale
        )
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            weekdayRow
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
                ForEach(Array(layout.cells.enumerated()), id: \.offset) { _, day in
                    if let day { dayCell(day) } else { Color.clear.frame(height: 46) }
                }
            }
            .gesture(DragGesture(minimumDistance: 24).onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                shiftMonth(value.translation.width < 0 ? 1 : -1)
            })
            legend
        }
        .padding(.vertical, 4)
        .task(id: "\(month.timeIntervalSince1970)-\(model.logicalBookRevision)-\(model.journalProjectionRevision)") {
            await loadMarks()
        }
        .onChange(of: selection) { _, newValue in
            if !calendar.isDate(newValue, equalTo: month, toGranularity: .month) {
                displayedMonth = newValue
            }
        }
    }

    private var header: some View {
        HStack {
            Text(month.formattedForReporting(.dateTime.year().month(.wide), calendar: calendar))
                .font(.headline)
            Spacer()
            Button { shiftMonth(-1) } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("calendar.previous_month")
            Button { shiftMonth(1) } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("calendar.next_month")
        }
        .buttonStyle(.borderless)
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(layout.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private func dayCell(_ day: Date) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selection)
        let isToday = calendar.isDate(day, inSameDayAs: today)
        var dayMarks = marks[calendar.startOfDay(for: day)] ?? .init()
        dayMarks.scheduled = model.scheduledTransactions.contains { $0.occurs(on: day, calendar: calendar) }
        return Button {
            withAnimation(MoneyUpMotion.animation(for: .selection, reduceMotion: reduceMotion)) {
                selection = day
            }
        } label: {
            VStack(spacing: 3) {
                // A bare numeral: a localized "18日" cannot fit the circle.
                Text(verbatim: CalendarMonthLayout.dayNumeral(day, calendar: calendar))
                    .font(.callout.monospacedDigit().weight(isSelected || isToday ? .bold : .regular))
                    .foregroundStyle(isSelected ? Color.white : isToday ? Color.accentColor : Color.primary)
                    .frame(width: 32, height: 32)
                    .background {
                        if isSelected {
                            Circle().fill(Color.moneyUpAction)
                        } else if isToday {
                            Circle().stroke(Color.accentColor, lineWidth: 1.5)
                        }
                    }
                HStack(spacing: 3) {
                    if dayMarks.spent { Circle().fill(MoneyUpChartPalette.expense).frame(width: 5, height: 5) }
                    if dayMarks.received { Circle().fill(Color.moneyUpPositive).frame(width: 5, height: 5) }
                    if dayMarks.scheduled {
                        Circle().stroke(Color.moneyUpWarning, lineWidth: 1.2).frame(width: 5, height: 5)
                    }
                }
                .frame(height: 6)
            }
            .frame(maxWidth: .infinity, minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(day.formattedForReporting(
            .dateTime.weekday(.wide).month(.wide).day(),
            calendar: calendar
        )))
        .accessibilityValue(accessibilityValue(dayMarks))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem("history.spent") { Circle().fill(MoneyUpChartPalette.expense) }
            legendItem("transaction.income") { Circle().fill(Color.moneyUpPositive) }
            legendItem("calendar.scheduled") { Circle().stroke(Color.moneyUpWarning, lineWidth: 1.2) }
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    private func legendItem<Mark: View>(_ title: LocalizedStringKey, @ViewBuilder mark: () -> Mark) -> some View {
        HStack(spacing: 4) {
            mark().frame(width: 6, height: 6)
            Text(title)
        }
    }

    private func accessibilityValue(_ marks: CalendarDayMarks) -> String {
        var parts: [String] = []
        if marks.spent { parts.append(AppLocalization.string("history.spent")) }
        if marks.received { parts.append(AppLocalization.string("transaction.income")) }
        if marks.scheduled { parts.append(AppLocalization.string("calendar.scheduled")) }
        return parts.joined(separator: ", ")
    }

    private func shiftMonth(_ delta: Int) {
        guard let next = calendar.date(byAdding: .month, value: delta, to: month) else { return }
        withAnimation(MoneyUpMotion.animation(for: .selection, reduceMotion: reduceMotion)) {
            displayedMonth = next
        }
    }

    private func loadMarks() async {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return }
        let requested = month
        do {
            let entries = try await model.calendarEntries(in: interval)
            guard !Task.isCancelled, requested == month else { return }
            marks = CalendarDayMarks.byDay(entries: entries, calendar: calendar)
        } catch {
            // Marks are a glance aid; the selected day's list still reports
            // its own unavailable state, so a failed month read shows no dots.
            guard requested == month else { return }
            marks = [:]
        }
    }
}
