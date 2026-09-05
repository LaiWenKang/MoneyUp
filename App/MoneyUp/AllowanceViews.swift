import MoneyUpCore
import SwiftUI

struct AllowanceCenterView: View {
    @Environment(AppModel.self) private var model
    @State private var isAdding = false

    var body: some View {
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

private struct AllowanceRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appReportingSnapshot) private var sharedReportingSnapshot
    let plan: AllowancePlan

    var body: some View {
        // Reading the shared instant is intentional: a reporting-midnight
        // publication must invalidate an already-mounted row even though the
        // calendar and model data themselves did not change.
        let now = sharedReportingSnapshot?.instant
            ?? model.currentDateForUserAction()
        let presentation = model.allowancePresentation(plan, asOf: now)
        HStack(spacing: 12) {
            MoneyUpSymbolBadge(
                systemImage: plan.fundingMode == .prepaidAsset
                    ? "giftcard.fill" : "fork.knife.circle.fill",
                color: .accentColor
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(plan.name).fontWeight(.semibold)
                if let activePolicy = presentation.activePolicy {
                    Text(activePolicy.cadence.titleKey)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("allowance.not_available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let pendingPolicy = presentation.pendingPolicy {
                    let pendingCalendar = AllowancePolicyDatePresentation.calendar(
                        for: pendingPolicy,
                        fallbackPlan: plan
                    )
                    let effectiveDate = pendingPolicy.effectiveAt.formattedForReporting(
                        .dateTime.year().month().day(),
                        calendar: pendingCalendar
                    )
                    Text(
                        String(
                            format: AppLocalization.string(
                                "allowance.pending_compact"
                            ),
                            effectiveDate
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if presentation.policySummary?.isAvailableToday != true {
                    Text("allowance.not_available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    switch presentation.remaining {
                    case let .available(remaining):
                        Text(formattedMoney(remaining))
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                    case let .unavailable(issue):
                        DerivedValueUnavailableView(issue: issue)
                    }
                    Text(LocalizedStringKey(
                        presentation.remainingMeaning.titleKeyString
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

private struct AllowanceDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appReportingSnapshot) private var sharedReportingSnapshot
    let planID: UUID
    @State private var isRecordingUse = false
    @State private var isEditing = false
    @State private var presentedExpiry: PresentedAllowanceExpiry?
    @State private var deletedUsageForUndo: AllowanceUsage?
    @State private var isRestoringUsage = false
    @State private var errorMessage: String?

    private var plan: AllowancePlan? {
        model.allowancePlans.first { $0.id == planID }
    }

    private var isWritable: Bool {
        plan.map { model.isAllowanceWritable($0) } == true
    }

    var body: some View {
        List {
            if let plan {
                // Keep policy availability, remaining value, and expiry CTA on
                // the same reporting-clock snapshot for this complete render.
                let now = sharedReportingSnapshot?.instant
                    ?? model.currentDateForUserAction()
                let presentation = model.allowancePresentation(plan, asOf: now)
                Section {
                    if let summary = presentation.policySummary {
                        switch presentation.remaining {
                        case let .available(remaining):
                            LabeledContent(LocalizedStringKey(
                                presentation.remainingMeaning.titleKeyString
                            )) {
                                Text(formattedMoney(remaining))
                                    .font(.title3.monospacedDigit().weight(.bold))
                            }
                        case let .unavailable(issue):
                            LabeledContent(LocalizedStringKey(
                                presentation.remainingMeaning.titleKeyString
                            )) {
                                DerivedValueUnavailableView(issue: issue, prominent: true)
                            }
                            if plan.fundingMode == .prepaidAsset {
                                LabeledContent(
                                    "allowance.policy_remaining",
                                    value: formattedMoney(summary.remaining)
                                )
                            }
                        }
                        LabeledContent(
                            "allowance.policy_entitlement",
                            value: formattedMoney(summary.entitlement)
                        )
                        LabeledContent(
                            "allowance.policy_used",
                            value: formattedMoney(summary.used)
                        )
                        if !summary.isAvailableToday {
                            Text("allowance.not_available_detail")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if case let .unavailable(issue) = presentation.remaining {
                        DerivedValueUnavailableView(issue: issue, prominent: true)
                    }
                    if let activePolicy = presentation.activePolicy {
                        LabeledContent(
                            "allowance.cadence",
                            value: AppLocalization.string(
                                activePolicy.cadence.titleKeyString
                            )
                        )
                        LabeledContent(
                            "allowance.rollover",
                            value: AppLocalization.string(
                                activePolicy.rolloverRule.titleKeyString
                            )
                        )
                        LabeledContent(
                            "allowance.policy_time_zone",
                            value: activePolicy.timeZoneIdentifier
                        )
                    }
                    LabeledContent(
                        "allowance.funding_mode",
                        value: AppLocalization.string(plan.fundingMode.titleKeyString)
                    )
                    if let accountID = plan.linkedAccountID,
                       let account = model.accounts.first(where: { $0.id == accountID }) {
                        LabeledContent("allowance.linked_account", value: account.name)
                    }
                }

                if let pendingPolicy = presentation.pendingPolicy {
                    let pendingCalendar = AllowancePolicyDatePresentation.calendar(
                        for: pendingPolicy,
                        fallbackPlan: plan
                    )
                    Section("allowance.pending_policy_title") {
                        LabeledContent(
                            "allowance.pending_amount",
                            value: formattedMoney(pendingPolicy.amount)
                        )
                        LabeledContent(
                            "allowance.cadence",
                            value: AppLocalization.string(
                                pendingPolicy.cadence.titleKeyString
                            )
                        )
                        LabeledContent(
                            "allowance.rollover",
                            value: AppLocalization.string(
                                pendingPolicy.rolloverRule.titleKeyString
                            )
                        )
                        LabeledContent(
                            "allowance.policy_time_zone",
                            value: pendingPolicy.timeZoneIdentifier
                        )
                        LabeledContent("allowance.pending_effective") {
                            Text(
                                pendingPolicy.effectiveAt.formattedForReporting(
                                    .dateTime.year().month().day(),
                                    calendar: pendingCalendar
                                )
                            )
                        }
                        Text("allowance.pending_policy_detail")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("allowance.usage_history") {
                    if plan.usages.isEmpty {
                        Text("allowance.no_usage").foregroundStyle(.secondary)
                    } else {
                        ForEach(plan.usages.reversed()) { usage in
                            AllowanceUsageRow(
                                plan: plan,
                                usage: usage,
                                allowsClaimActions: !plan.isArchived
                                    && isWritable
                                    && plan.fundingMode == .reimbursement,
                                onDeleted: { deletedUsageForUndo = $0 }
                            )
                        }
                        if plan.fundingMode == .reimbursement {
                            Text("allowance.claim.evidence_only_detail")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityElement(children: .combine)
                        }
                    }
                }

                let compatibility = AppModel.allowanceFundingCompatibility(
                    for: plan,
                    accountsByID: model.accountsByID
                )
                if plan.hasGrandfatheredActivity || compatibility != .current {
                    Section("allowance.read_only_title") {
                        Label {
                            Text(LocalizedStringKey(
                                plan.hasGrandfatheredActivity
                                    ? "allowance.legacy_activity_detail"
                                    : compatibility == .legacyReimbursementLink
                                    ? "allowance.legacy_reimbursement_detail"
                                    : "allowance.legacy_prepaid_detail"
                            ))
                        } icon: {
                            Image(systemName: "lock.fill")
                        }
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .combine)
                    }
                }

                if !plan.isArchived,
                   !plan.hasGrandfatheredActivity,
                   compatibility == .current,
                   let requirement = (try? plan.expiryRequirements(
                       asOf: now
                   ))?.first {
                    Section("allowance.reconciliation_title") {
                        LabeledContent(
                            "allowance.policy_expiry_maximum",
                            value: formattedMoney(requirement.amount)
                        )
                        Text("allowance.reconciliation_detail")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            let policy = plan.policyRevisions.first {
                                $0.id == requirement.policyRevisionID
                            }
                            presentedExpiry = PresentedAllowanceExpiry(
                                requirement: requirement,
                                timeZoneIdentifier: policy?.timeZoneIdentifier
                                    ?? plan.timeZoneIdentifier
                            )
                        } label: {
                            Label(
                                "allowance.confirm_expiry",
                                systemImage: "checkmark.seal"
                            )
                        }
                    }
                }

                if !plan.isArchived,
                   isWritable,
                   plan.fundingMode == .benefitLimit {
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
            if isWritable {
                ToolbarItem(placement: .primaryAction) {
                    Button("action.edit") { isEditing = true }
                }
            }
        }
        .sheet(isPresented: $isRecordingUse) {
            if let plan, isWritable { AllowanceUsageSheet(plan: plan) }
        }
        .sheet(isPresented: $isEditing) {
            if let plan, isWritable { AllowanceEditorSheet(plan: plan) }
        }
        .sheet(item: $presentedExpiry) { presented in
            AllowanceReconciliationSheet(
                planID: planID,
                requirement: presented.requirement,
                timeZoneIdentifier: presented.timeZoneIdentifier
            )
        }
        .confirmationDialog(
            "allowance.usage.deleted_title",
            isPresented: Binding(
                get: { deletedUsageForUndo != nil },
                set: { if !$0 { deletedUsageForUndo = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("action.undo") {
                guard let request = AllowanceUsageUndoPolicy.request(
                    planID: planID,
                    deletedUsage: deletedUsageForUndo
                ) else { return }
                Task { await restoreDeletedUsage(request) }
            }
                .disabled(isRestoringUsage)
            Button("action.done", role: .cancel) {
                deletedUsageForUndo = nil
            }
        } message: {
            Text("allowance.usage.deleted_detail")
        }
        .moneyUpOperationErrorAlert(message: $errorMessage)
    }

    private func restoreDeletedUsage(
        _ request: AllowanceUsageUndoRequest
    ) async {
        isRestoringUsage = true
        defer { isRestoringUsage = false }
        do {
            try await model.restoreDeletedUnlinkedBenefitAllowanceUsage(
                planID: request.planID,
                deletedUsage: request.usage,
                expectedPolicyRevisionID: request.policyRevisionID
            )
            self.deletedUsageForUndo = nil
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }
}

private struct PresentedAllowanceExpiry: Identifiable {
    let id = UUID()
    let requirement: AllowanceExpiryRequirement
    let timeZoneIdentifier: String
}

private struct AllowanceReconciliationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let planID: UUID
    let requirement: AllowanceExpiryRequirement
    let timeZoneIdentifier: String
    @State private var amountText = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(
                        "allowance.policy_expiry_maximum",
                        value: formattedMoney(requirement.amount)
                    )
                    LabeledContent("allowance.period_ended") {
                        Text(
                            requirement.interval.end.formattedForReporting(
                                .dateTime.year().month().day().hour().minute(),
                                calendar: policyCalendar
                            )
                        )
                    }
                    LabeledContent(
                        "allowance.policy_time_zone",
                        value: timeZoneIdentifier
                    )
                    TextField("allowance.confirmed_expired_amount", text: $amountText)
                        .moneyAmountKeyboard(currency: requirement.amount.currency)
                } footer: {
                    Text("allowance.reconciliation_entry_detail")
                }
            }
            .navigationTitle("allowance.confirm_expiry")
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
            .moneyUpOperationErrorAlert(message: $errorMessage)
        }
    }

    private var canSave: Bool {
        decimalAmount(from: amountText).map {
            $0 >= .zero && $0 <= requirement.amount.amount
        } == true
    }

    private var policyCalendar: Calendar {
        FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    private func save() async {
        guard let amount = decimalAmount(from: amountText) else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.confirmExpiredPrepaidAllowance(
                planID: planID,
                requirement: requirement,
                confirmedExpiredAmount: amount,
                asOf: model.currentDateForUserAction()
            )
            dismiss()
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
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
    @State private var fundingMode: AllowanceFundingMode
    @State private var linkedAccountID: UUID?
    @State private var timeZoneIdentifier: String
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
        let initialTimeZoneIdentifier = AllowanceEditorAccountPolicy
            .initialTimeZoneIdentifier(
                for: plan,
                newPlanDefault: TimeZone.current.identifier
            )
        let definitionTimeZoneIdentifier = plan?.policyRevisions.first?
            .timeZoneIdentifier ?? initialTimeZoneIdentifier
        let visibleStart = plan.flatMap {
            AllowanceEditorDatePolicy.visibleStart(
                fromStoredStart: $0.startsAt,
                timeZoneIdentifier: definitionTimeZoneIdentifier
            )
        } ?? Date()
        let visibleEnd = plan.flatMap { existingPlan in
            existingPlan.endsAt.flatMap {
                AllowanceEditorDatePolicy.visibleInclusiveEnd(
                    fromStoredExclusiveEnd: $0,
                    timeZoneIdentifier: definitionTimeZoneIdentifier
                )
            }
        } ?? visibleStart.addingTimeInterval(86_400 * 29)
        _name = State(initialValue: plan?.name ?? "")
        _amountText = State(initialValue: plan.map { editableAmount($0.amount.amount) } ?? "")
        _currencyCode = State(initialValue: plan?.amount.currency.value ?? "USD")
        _cadence = State(initialValue: plan?.cadence ?? .daily)
        _fundingMode = State(initialValue: plan?.fundingMode ?? .benefitLimit)
        _linkedAccountID = State(initialValue: plan?.linkedAccountID)
        _timeZoneIdentifier = State(initialValue: initialTimeZoneIdentifier)
        _startsAt = State(initialValue: visibleStart)
        _hasEndDate = State(initialValue: plan?.endsAt != nil)
        _endsAt = State(initialValue: visibleEnd)
        _eligibleCategoryIDs = State(initialValue: plan?.eligibleCategoryIDs ?? [])
        _rollover = State(initialValue: plan?.rolloverRule ?? .none)
        _rolloverCapText = State(
            initialValue: plan?.rolloverCap.map { editableAmount($0.amount) } ?? ""
        )
        _isArchived = State(initialValue: plan?.isArchived ?? false)
    }

    var body: some View {
        let editInstant = model.currentDateForUserAction()
        let preservesPolicyHistory = plan?.requiresEffectiveDatedUpdate(
            at: editInstant
        ) == true
        let definitionTimeZoneIdentifier = preservesPolicyHistory
            ? plan?.policyRevisions.first?.timeZoneIdentifier
                ?? timeZoneIdentifier
            : timeZoneIdentifier
        let definitionCalendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: definitionTimeZoneIdentifier
        )
        NavigationStack {
            Form {
                if let plan {
                    if let pendingPolicy = plan.policyRevisions.first(where: {
                        $0.effectiveAt > editInstant
                    }) {
                        let pendingCalendar = AllowancePolicyDatePresentation.calendar(
                            for: pendingPolicy,
                            fallbackPlan: plan
                        )
                        Section("allowance.editor_pending_title") {
                            LabeledContent("allowance.pending_effective") {
                                Text(
                                    pendingPolicy.effectiveAt.formattedForReporting(
                                        .dateTime.year().month().day(),
                                        calendar: pendingCalendar
                                    )
                                )
                            }
                            LabeledContent(
                                "allowance.policy_time_zone",
                                value: pendingPolicy.timeZoneIdentifier
                            )
                            Text("allowance.editor_pending_detail")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if preservesPolicyHistory {
                        Section {
                            Text("allowance.editor_future_change_detail")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

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
                    Picker(
                        "allowance.policy_time_zone",
                        selection: Binding(
                            get: { timeZoneIdentifier },
                            set: { selectedTimeZoneIdentifier in
                                if !preservesPolicyHistory {
                                    rebaseVisibleDates(
                                        from: timeZoneIdentifier,
                                        to: selectedTimeZoneIdentifier
                                    )
                                }
                                timeZoneIdentifier = selectedTimeZoneIdentifier
                            }
                        )
                    ) {
                        ForEach(
                            AllowanceEditorAccountPolicy.timeZoneIdentifiers,
                            id: \.self
                        ) { identifier in
                            Text(identifier).tag(identifier)
                        }
                    }
                    Picker("allowance.funding_mode", selection: $fundingMode) {
                        ForEach(AllowanceFundingMode.allCases, id: \.self) { mode in
                            Text(mode.titleKey).tag(mode)
                        }
                    }
                    .disabled(preservesPolicyHistory)
                    if fundingMode == .prepaidAsset {
                        Picker("allowance.linked_account", selection: $linkedAccountID) {
                            Text("category.none").tag(UUID?.none)
                            ForEach(eligibleLinkedAccounts) { account in
                                Text(accountCurrencyLabel(account)).tag(Optional(account.id))
                            }
                        }
                        .disabled(preservesPolicyHistory)
                        if eligibleLinkedAccounts.isEmpty {
                            Text("allowance.restricted_account_required")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    DatePicker("allowance.starts", selection: $startsAt, displayedComponents: .date)
                        .disabled(preservesPolicyHistory)
                        .environment(\.calendar, definitionCalendar)
                        .environment(\.timeZone, definitionCalendar.timeZone)
                    Toggle("allowance.has_end", isOn: $hasEndDate)
                        .disabled(preservesPolicyHistory)
                    if hasEndDate {
                        DatePicker("allowance.ends", selection: $endsAt, displayedComponents: .date)
                            .disabled(preservesPolicyHistory)
                            .environment(\.calendar, definitionCalendar)
                            .environment(\.timeZone, definitionCalendar.timeZone)
                    }
                    if let plan, preservesPolicyHistory,
                       !AllowanceEditorDatePolicy.isCivilDayBoundary(
                           plan.startsAt,
                           timeZoneIdentifier: definitionTimeZoneIdentifier
                       ) || plan.endsAt.map({
                           !AllowanceEditorDatePolicy.isCivilDayBoundary(
                               $0,
                               timeZoneIdentifier: definitionTimeZoneIdentifier
                           )
                       }) == true {
                        Text("allowance.legacy_partial_day_detail")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        LabeledContent("allowance.legacy_exact_start") {
                            Text(plan.startsAt.formattedForReporting(
                                .dateTime.year().month().day().hour().minute(),
                                calendar: definitionCalendar
                            ))
                        }
                        if let exactEnd = plan.endsAt {
                            LabeledContent("allowance.legacy_exact_end") {
                                Text(exactEnd.formattedForReporting(
                                    .dateTime.year().month().day().hour().minute(),
                                    calendar: definitionCalendar
                                ))
                            }
                        }
                        LabeledContent(
                            "allowance.policy_time_zone",
                            value: definitionTimeZoneIdentifier
                        )
                    }
                    Text("allowance.policy_time_zone_detail")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    MoneyUpExplainer("allowance.expiry_detail")
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
                    MoneyUpExplainer("allowance.categories_detail")
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
                    let currentDate = model.currentDateForUserAction()
                    timeZoneIdentifier = model.reportingCalendar.timeZone.identifier
                    if let calendar = AllowanceEditorDatePolicy.calendar(
                        timeZoneIdentifier: timeZoneIdentifier
                    ) {
                        startsAt = calendar.startOfDay(for: currentDate)
                        endsAt = calendar.date(
                            byAdding: .day,
                            value: 29,
                            to: startsAt
                        ) ?? startsAt
                    }
                    currencyCode = model.profile?.baseCurrency.value ?? currencyCode
                }
            }
            .onChange(of: fundingMode) { _, mode in
                if mode != .prepaidAsset {
                    linkedAccountID = nil
                } else if !eligibleLinkedAccounts.contains(where: { $0.id == linkedAccountID }) {
                    linkedAccountID = eligibleLinkedAccounts.first?.id
                }
            }
            .onChange(of: currencyCode) { _, _ in
                if !eligibleLinkedAccounts.contains(where: { $0.id == linkedAccountID }) {
                    linkedAccountID = fundingMode != .prepaidAsset
                        ? nil : eligibleLinkedAccounts.first?.id
                }
            }
            .moneyUpOperationErrorAlert(message: $errorMessage)
        }
    }

    private var canSave: Bool {
        guard let storedStartsAt else { return false }
        let validEnd = !hasEndDate
            || storedEndsAt.map { $0 > storedStartsAt } == true
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && currency != nil
            && decimalAmount(from: amountText).map { $0 > .zero } == true
            && validEnd
            && (rollover != .capped
                || decimalAmount(from: rolloverCapText).map { $0 >= .zero } == true)
            && (fundingMode != .prepaidAsset || linkedAccountID != nil)
    }

    private var currency: CurrencyCode? { try? CurrencyCode(currencyCode) }

    private var storedStartsAt: Date? {
        let editInstant = model.currentDateForUserAction()
        if let plan, plan.requiresEffectiveDatedUpdate(at: editInstant) {
            return plan.startsAt
        }
        return AllowanceEditorDatePolicy.storedStart(
            fromVisibleDate: startsAt,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    private var storedEndsAt: Date? {
        guard hasEndDate else { return nil }
        let editInstant = model.currentDateForUserAction()
        if let plan, plan.requiresEffectiveDatedUpdate(at: editInstant) {
            return plan.endsAt
        }
        return AllowanceEditorDatePolicy.storedExclusiveEnd(
            fromVisibleInclusiveDate: endsAt,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    private var eligibleLinkedAccounts: [LedgerAccount] {
        AllowanceEditorAccountPolicy.eligibleLinkedAccounts(
            from: model.userAccounts,
            plans: model.allowancePlans,
            editingPlanID: plan?.id,
            currency: currency
        )
    }

    private func save() async {
        guard let amount = decimalAmount(from: amountText),
              let currency,
              let storedStartsAt,
              !hasEndDate || storedEndsAt != nil else { return }
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
                fundingMode: fundingMode,
                linkedAccountID: fundingMode == .prepaidAsset ? linkedAccountID : nil,
                startsAt: storedStartsAt,
                endsAt: storedEndsAt,
                timeZoneIdentifier: timeZoneIdentifier,
                eligibleCategoryIDs: eligibleCategoryIDs,
                rolloverRule: rollover,
                rolloverCap: rolloverCap,
                usages: [],
                isArchived: isArchived
            )
            if plan == nil { try await model.addAllowancePlan(updated) }
            else { try await model.updateAllowancePlan(updated) }
            dismiss()
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }

    private func rebaseVisibleDates(
        from sourceTimeZoneIdentifier: String,
        to destinationTimeZoneIdentifier: String
    ) {
        if let rebasedStart = AllowanceEditorDatePolicy.rebasedVisibleDate(
            startsAt,
            from: sourceTimeZoneIdentifier,
            to: destinationTimeZoneIdentifier
        ) {
            startsAt = rebasedStart
        }
        if let rebasedEnd = AllowanceEditorDatePolicy.rebasedVisibleDate(
            endsAt,
            from: sourceTimeZoneIdentifier,
            to: destinationTimeZoneIdentifier
        ) {
            endsAt = rebasedEnd
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

private extension AllowanceFundingMode {
    var titleKeyString: String {
        switch self {
        case .benefitLimit: "allowance.funding.benefit"
        case .prepaidAsset: "allowance.funding.prepaid"
        case .reimbursement: "allowance.funding.reimbursement"
        }
    }

    var titleKey: LocalizedStringKey { LocalizedStringKey(titleKeyString) }
}

enum AllowanceClaimActionPolicy {
    static func targets(
        from status: AllowanceClaimStatus
    ) -> [AllowanceClaimStatus] {
        switch status {
        case .pendingApproval: [.approved, .rejected]
        case .approved: [.reimbursed]
        case .reimbursed, .rejected: []
        }
    }

    static func titleKeyString(for target: AllowanceClaimStatus) -> String {
        switch target {
        case .approved: "allowance.claim.action.approve"
        case .rejected: "allowance.claim.action.reject"
        case .reimbursed: "allowance.claim.action.mark_reimbursed"
        case .pendingApproval: "allowance.claim.pending"
        }
    }

    static func hintKeyString(for target: AllowanceClaimStatus) -> String {
        switch target {
        case .approved: "allowance.claim.action.approve_hint"
        case .rejected: "allowance.claim.action.reject_hint"
        case .reimbursed: "allowance.claim.action.mark_reimbursed_hint"
        case .pendingApproval: "allowance.claim.pending"
        }
    }

    static func systemImage(for target: AllowanceClaimStatus) -> String {
        switch target {
        case .approved: "checkmark.circle"
        case .rejected: "xmark.circle"
        case .reimbursed: "banknote"
        case .pendingApproval: "clock"
        }
    }
}

enum AllowanceEditorAccountPolicy {
    static func initialTimeZoneIdentifier(
        for plan: AllowancePlan?,
        newPlanDefault: String
    ) -> String {
        plan?.timeZoneIdentifier ?? newPlanDefault
    }

    static let timeZoneIdentifiers = TimeZone.knownTimeZoneIdentifiers.sorted()

    static func eligibleLinkedAccounts(
        from accounts: [LedgerAccount],
        plans: [AllowancePlan],
        editingPlanID: UUID?,
        currency: CurrencyCode?
    ) -> [LedgerAccount] {
        let accountsClaimedByAnotherPlan = Set(plans.compactMap { plan in
            guard plan.id != editingPlanID,
                  !plan.isArchived,
                  plan.fundingMode == .prepaidAsset else { return nil }
            return plan.linkedAccountID
        })
        return accounts.filter { account in
            account.kind == .asset
                && account.accountType == .restrictedAllowance
                && !account.isArchived
                && account.currency == currency
                && !accountsClaimedByAnotherPlan.contains(account.id)
        }
    }
}
