import MoneyUpCore
import SwiftUI

struct AllowanceCenterView: View {
    @Environment(AppModel.self) private var model
    @State private var isAdding = false

    var body: some View {
        NavigationStack {
            List {
                if model.allowancePlans.filter({ !$0.isArchived }).isEmpty {
                    ContentUnavailableView(
                        "allowance.empty",
                        systemImage: "fork.knife.circle",
                        description: Text("allowance.empty_detail")
                    )
                } else {
                    Section("allowance.current") {
                        ForEach(model.allowancePlans.filter { !$0.isArchived }) { plan in
                            NavigationLink {
                                AllowanceDetailView(planID: plan.id)
                            } label: {
                                AllowanceRow(plan: plan)
                            }
                        }
                    }
                }

                if model.allowancePlans.contains(where: \.isArchived) {
                    Section("lifecycle.archived") {
                        ForEach(model.allowancePlans.filter(\.isArchived)) { plan in
                            NavigationLink {
                                AllowanceDetailView(planID: plan.id)
                            } label: {
                                Label(plan.name, systemImage: "archivebox.fill")
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .navigationTitle("allowance.title")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isAdding = true
                    } label: {
                        Label("allowance.add", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isAdding) {
                AllowanceEditorSheet(plan: nil)
            }
        }
    }
}

private struct AllowanceRow: View {
    @Environment(AppModel.self) private var model
    let plan: AllowancePlan

    var body: some View {
        HStack(spacing: 12) {
            MoneyUpSymbolBadge(systemImage: "fork.knife.circle.fill", color: .accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(plan.name).fontWeight(.semibold)
                Text(plan.cadence.titleKey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch model.allowanceSummary(plan) {
            case let .available(summary):
                if summary.isAvailableToday {
                    Text(formattedMoney(summary.remaining))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                } else {
                    Text("allowance.not_available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case let .unavailable(issue):
                DerivedValueUnavailableView(issue: issue)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct AllowanceDetailView: View {
    @Environment(AppModel.self) private var model
    let planID: UUID
    @State private var isRecordingUse = false
    @State private var isEditing = false

    private var plan: AllowancePlan? {
        model.allowancePlans.first { $0.id == planID }
    }

    var body: some View {
        List {
            if let plan {
                Section {
                    switch model.allowanceSummary(plan) {
                    case let .available(summary):
                        LabeledContent("allowance.available") {
                            Text(formattedMoney(summary.remaining))
                                .font(.title3.monospacedDigit().weight(.bold))
                        }
                        LabeledContent(
                            "allowance.entitlement",
                            value: formattedMoney(summary.entitlement)
                        )
                        LabeledContent("allowance.used", value: formattedMoney(summary.used))
                        if !summary.isAvailableToday {
                            Text("allowance.not_available_detail")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    case let .unavailable(issue):
                        DerivedValueUnavailableView(issue: issue, prominent: true)
                    }
                    LabeledContent("allowance.cadence", value: AppLocalization.string(plan.cadence.titleKeyString))
                    LabeledContent("allowance.rollover", value: AppLocalization.string(plan.rolloverRule.titleKeyString))
                }

                Section("allowance.usage_history") {
                    if plan.usages.isEmpty {
                        Text("allowance.no_usage").foregroundStyle(.secondary)
                    } else {
                        ForEach(plan.usages.reversed()) { usage in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(
                                        usage.categoryID.map {
                                            model.categoryPathName(for: $0)
                                        }
                                            ?? AppLocalization.string("allowance.general")
                                    )
                                    Spacer()
                                    Text(formattedMoney(usage.amount)).monospacedDigit()
                                }
                                Text(usage.occurredAt, format: .dateTime.year().month().day().hour().minute())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let note = usage.note {
                                    Text(note).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if !plan.isArchived {
                    Section {
                        Button {
                            isRecordingUse = true
                        } label: {
                            Label("allowance.record_use", systemImage: "minus.circle")
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.moneyUpBackground)
        .navigationTitle(plan?.name ?? AppLocalization.string("allowance.title"))
        .toolbar {
            if plan != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("action.edit") { isEditing = true }
                }
            }
        }
        .sheet(isPresented: $isRecordingUse) {
            if let plan { AllowanceUsageSheet(plan: plan) }
        }
        .sheet(isPresented: $isEditing) {
            if let plan { AllowanceEditorSheet(plan: plan) }
        }
    }
}

private struct AllowanceEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let plan: AllowancePlan?
    @State private var name: String
    @State private var amountText: String
    @State private var currencyCode: String
    @State private var cadence: AllowanceCadence
    @State private var startsAt: Date
    @State private var hasEndDate: Bool
    @State private var endsAt: Date
    @State private var eligibleCategoryIDs: Set<UUID>
    @State private var rollover: AllowanceRolloverRule
    @State private var rolloverCapText: String
    @State private var isArchived: Bool
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(plan: AllowancePlan?) {
        self.plan = plan
        _name = State(initialValue: plan?.name ?? "")
        _amountText = State(initialValue: plan.map { editableAmount($0.amount.amount) } ?? "")
        _currencyCode = State(initialValue: plan?.amount.currency.value ?? "USD")
        _cadence = State(initialValue: plan?.cadence ?? .daily)
        _startsAt = State(initialValue: plan?.startsAt ?? Date())
        _hasEndDate = State(initialValue: plan?.endsAt != nil)
        _endsAt = State(initialValue: plan?.endsAt ?? Date().addingTimeInterval(86_400 * 30))
        _eligibleCategoryIDs = State(initialValue: plan?.eligibleCategoryIDs ?? [])
        _rollover = State(initialValue: plan?.rolloverRule ?? .none)
        _rolloverCapText = State(
            initialValue: plan?.rolloverCap.map { editableAmount($0.amount) } ?? ""
        )
        _isArchived = State(initialValue: plan?.isArchived ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("allowance.name", text: $name)
                    TextField("allowance.amount", text: $amountText)
                        .moneyAmountKeyboard(currency: currency)
                    if plan == nil {
                        SearchableCurrencyPicker(
                            title: "transaction.currency",
                            selection: $currencyCode,
                            existing: model.allUserAccounts.compactMap(\.currency)
                        )
                    }
                    Picker("allowance.cadence", selection: $cadence) {
                        ForEach(AllowanceCadence.allCases, id: \.self) { option in
                            Text(option.titleKey).tag(option)
                        }
                    }
                    DatePicker("allowance.starts", selection: $startsAt, displayedComponents: .date)
                    Toggle("allowance.has_end", isOn: $hasEndDate)
                    if hasEndDate {
                        DatePicker("allowance.ends", selection: $endsAt, displayedComponents: .date)
                    }
                }

                Section {
                    Picker("allowance.rollover", selection: $rollover) {
                        ForEach(AllowanceRolloverRule.allCases, id: \.self) { rule in
                            Text(rule.titleKey).tag(rule)
                        }
                    }
                    if rollover == .capped {
                        TextField("allowance.rollover_cap", text: $rolloverCapText)
                            .moneyAmountKeyboard(currency: currency)
                    }
                } footer: {
                    Text("allowance.expiry_detail")
                }

                Section {
                    ForEach(model.expenseCategories) { category in
                        Toggle(
                            model.categoryPathName(for: category.id),
                            isOn: Binding(
                                get: { eligibleCategoryIDs.contains(category.id) },
                                set: { enabled in
                                    if enabled { eligibleCategoryIDs.insert(category.id) }
                                    else { eligibleCategoryIDs.remove(category.id) }
                                }
                            )
                        )
                    }
                } header: {
                    Text("allowance.categories")
                } footer: {
                    Text("allowance.categories_detail")
                }

                if plan != nil {
                    Toggle("lifecycle.archived", isOn: $isArchived)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .navigationTitle(
                plan == nil
                    ? LocalizedStringKey("allowance.add")
                    : LocalizedStringKey("action.edit")
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
            .onAppear {
                if plan == nil {
                    startsAt = model.currentDateForUserAction()
                    currencyCode = model.profile?.baseCurrency.value ?? currencyCode
                }
            }
            .moneyUpOperationErrorAlert(message: $errorMessage)
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && currency != nil
            && decimalAmount(from: amountText).map { $0 > .zero } == true
            && (!hasEndDate || endsAt > startsAt)
            && (rollover != .capped
                || decimalAmount(from: rolloverCapText).map { $0 >= .zero } == true)
    }

    private var currency: CurrencyCode? { try? CurrencyCode(currencyCode) }

    private func save() async {
        guard let amount = decimalAmount(from: amountText), let currency else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let rolloverCap: Money?
            if rollover == .capped {
                guard let capAmount = decimalAmount(from: rolloverCapText) else {
                    return
                }
                rolloverCap = try Money(capAmount, currency: currency)
            } else {
                rolloverCap = nil
            }
            let updated = try AllowancePlan(
                id: plan?.id ?? UUID(),
                name: name,
                amount: try Money(amount, currency: currency),
                cadence: cadence,
                startsAt: startsAt,
                endsAt: hasEndDate ? endsAt : nil,
                timeZoneIdentifier: model.reportingCalendar.timeZone.identifier,
                eligibleCategoryIDs: eligibleCategoryIDs,
                rolloverRule: rollover,
                rolloverCap: rolloverCap,
                usages: plan?.usages ?? [],
                isArchived: isArchived
            )
            if plan == nil { try await model.addAllowancePlan(updated) }
            else { try await model.updateAllowancePlan(updated) }
            dismiss()
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }
}

private struct AllowanceUsageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let plan: AllowancePlan
    @State private var amountText = ""
    @State private var categoryID: UUID?
    @State private var occurredAt = Date()
    @State private var note = ""
    @State private var errorMessage: String?

    private var categories: [LedgerAccount] {
        model.expenseCategories.filter {
            plan.eligibleCategoryIDs.isEmpty || plan.eligibleCategoryIDs.contains($0.id)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("allowance.amount", text: $amountText)
                    .moneyAmountKeyboard(currency: plan.amount.currency)
                Picker("transaction.category", selection: $categoryID) {
                    Text("allowance.general").tag(UUID?.none)
                    ForEach(categories) { category in
                        Text(model.categoryPathName(for: category.id)).tag(Optional(category.id))
                    }
                }
                DatePicker(
                    "quick_log.date_and_time",
                    selection: $occurredAt,
                    displayedComponents: [.date, .hourAndMinute]
                )
                TextField("transaction.description_or_notes", text: $note, axis: .vertical)
            }
            .navigationTitle("allowance.record_use")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") { Task { await save() } }
                        .disabled(decimalAmount(from: amountText).map { $0 > .zero } != true)
                }
                MoneyUpKeyboardDoneToolbar()
            }
            .onAppear { occurredAt = model.currentDateForUserAction() }
            .moneyUpOperationErrorAlert(message: $errorMessage)
        }
    }

    private func save() async {
        guard let amount = decimalAmount(from: amountText) else { return }
        do {
            try await model.recordAllowanceUsage(
                planID: plan.id,
                amount: amount,
                categoryID: categoryID,
                occurredAt: occurredAt,
                note: note
            )
            dismiss()
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }
}

private extension AllowanceCadence {
    var titleKeyString: String {
        switch self {
        case .daily: "allowance.cadence.daily"
        case .weekdays: "allowance.cadence.weekdays"
        case .weekly: "allowance.cadence.weekly"
        case .monthly: "allowance.cadence.monthly"
        }
    }
    var titleKey: LocalizedStringKey { LocalizedStringKey(titleKeyString) }
}

private extension AllowanceRolloverRule {
    var titleKeyString: String {
        switch self {
        case .none: "allowance.rollover.none"
        case .capped: "allowance.rollover.capped"
        case .full: "allowance.rollover.full"
        }
    }
    var titleKey: LocalizedStringKey { LocalizedStringKey(titleKeyString) }
}
