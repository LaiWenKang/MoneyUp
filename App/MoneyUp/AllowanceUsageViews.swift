import MoneyUpCore
import SwiftUI

struct AllowanceUsageRow: View {
    @Environment(AppModel.self) private var model
    let plan: AllowancePlan
    let usage: AllowanceUsage
    let allowsClaimActions: Bool
    let onDeleted: (AllowanceUsage) -> Void
    @State private var isMutating = false
    @State private var editingUsage: AllowanceUsage?
    @State private var showsDeleteConfirmation = false
    @State private var showsApproveConfirmation = false
    @State private var showsRejectConfirmation = false
    @State private var showsReimbursedConfirmation = false
    @State private var errorMessage: String?

    private var claimActions: [AllowanceClaimStatus] {
        guard allowsClaimActions, let status = usage.claimStatus else { return [] }
        return AllowanceClaimActionPolicy.targets(from: status)
    }

    private var allowsUsageMutation: Bool {
        !plan.isArchived
            && !plan.hasGrandfatheredActivity
            && plan.fundingMode == .benefitLimit
            && usage.linkedJournalEntryID == nil
            && usage.claimStatus == nil
            && model.isAllowanceWritable(plan)
    }

    private var usageCalendar: Calendar {
        AllowancePolicyDatePresentation.calendar(
            for: AllowancePolicyDatePresentation.policy(for: usage, in: plan),
            fallbackPlan: plan
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(usage.categoryID.map { model.categoryPathName(for: $0) }
                    ?? AppLocalization.string("allowance.general"))
                Spacer()
                Text(formattedMoney(usage.amount)).monospacedDigit()
            }
            Text(usage.occurredAt.formattedForReporting(
                .dateTime.year().month().day().hour().minute(),
                calendar: usageCalendar
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            if let note = usage.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if let status = usage.claimStatus {
                Text(status.allowanceTitleKey)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if !claimActions.isEmpty || allowsUsageMutation {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { rowActionButtons }
                    VStack(alignment: .leading, spacing: 8) { rowActionButtons }
                }
                .padding(.top, 3)
            }
            if isMutating {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("allowance.usage.updating")
            }
        }
        .sheet(item: $editingUsage) { item in
            AllowanceUsageSheet(plan: plan, usage: item)
        }
        .confirmationDialog(
            "allowance.usage.delete_title",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("action.delete", role: .destructive) {
                Task { await deleteUsage() }
            }
            Button("action.cancel", role: .cancel) {}
        } message: {
            Text("allowance.usage.delete_detail")
        }
        .confirmationDialog(
            "allowance.claim.approve_confirmation_title",
            isPresented: $showsApproveConfirmation,
            titleVisibility: .visible
        ) {
            Button("allowance.claim.action.approve") {
                Task { await updateClaim(to: .approved) }
            }
            Button("action.cancel", role: .cancel) {}
        } message: { Text("allowance.claim.approve_confirmation_detail") }
        .confirmationDialog(
            "allowance.claim.reject_confirmation_title",
            isPresented: $showsRejectConfirmation,
            titleVisibility: .visible
        ) {
            Button("allowance.claim.action.reject", role: .destructive) {
                Task { await updateClaim(to: .rejected) }
            }
            Button("action.cancel", role: .cancel) {}
        } message: { Text("allowance.claim.reject_confirmation_detail") }
        .confirmationDialog(
            "allowance.claim.reimbursed_confirmation_title",
            isPresented: $showsReimbursedConfirmation,
            titleVisibility: .visible
        ) {
            Button("allowance.claim.action.mark_reimbursed") {
                Task { await updateClaim(to: .reimbursed) }
            }
            Button("action.cancel", role: .cancel) {}
        } message: { Text("allowance.claim.reimbursed_confirmation_detail") }
        .moneyUpOperationErrorAlert(message: $errorMessage)
    }

    @ViewBuilder
    private var rowActionButtons: some View {
        ForEach(claimActions, id: \.self) { target in
            Button { presentClaimConfirmation(target) } label: {
                Label(
                    LocalizedStringKey(
                        AllowanceClaimActionPolicy.titleKeyString(for: target)
                    ),
                    systemImage: AllowanceClaimActionPolicy.systemImage(for: target)
                )
            }
            .buttonStyle(.borderless)
            .frame(minHeight: 44)
            .disabled(isMutating)
            .accessibilityHint(Text(LocalizedStringKey(
                AllowanceClaimActionPolicy.hintKeyString(for: target)
            )))
        }
        if allowsUsageMutation {
            Button { editingUsage = usage } label: {
                Label("action.edit", systemImage: "pencil")
            }
            .buttonStyle(.borderless)
            .frame(minHeight: 44)
            .disabled(isMutating)
            Button(role: .destructive) {
                showsDeleteConfirmation = true
            } label: {
                Label("action.delete", systemImage: "trash")
            }
            .buttonStyle(.borderless)
            .frame(minHeight: 44)
            .disabled(isMutating)
        }
    }

    private func presentClaimConfirmation(_ target: AllowanceClaimStatus) {
        switch target {
        case .approved: showsApproveConfirmation = true
        case .rejected: showsRejectConfirmation = true
        case .reimbursed: showsReimbursedConfirmation = true
        case .pendingApproval: break
        }
    }

    private func updateClaim(to status: AllowanceClaimStatus) async {
        guard let expectedStatus = usage.claimStatus else { return }
        await performMutation {
            try await model.updateAllowanceClaimStatus(
                planID: plan.id,
                usageID: usage.id,
                expectedCurrentStatus: expectedStatus,
                to: status
            )
        }
    }

    private func deleteUsage() async {
        isMutating = true
        defer { isMutating = false }
        do {
            let deleted = try await model.deleteUnlinkedBenefitAllowanceUsage(
                planID: plan.id,
                expectedUsage: usage
            )
            onDeleted(deleted)
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }

    private func performMutation(
        _ operation: () async throws -> Void
    ) async {
        isMutating = true
        defer { isMutating = false }
        do { try await operation() }
        catch { errorMessage = safeUserMessage(for: error, context: .save) }
    }
}

struct AllowanceUsageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let plan: AllowancePlan
    let usage: AllowanceUsage?
    @State private var amountText: String
    @State private var categoryID: UUID?
    @State private var occurredAt: Date
    @State private var note: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(plan: AllowancePlan, usage: AllowanceUsage? = nil) {
        self.plan = plan
        self.usage = usage
        _amountText = State(initialValue: usage.map {
            editableAmount($0.amount.amount)
        } ?? "")
        _categoryID = State(initialValue: usage?.categoryID)
        _occurredAt = State(initialValue: usage?.occurredAt ?? Date())
        _note = State(initialValue: usage?.note ?? "")
    }

    private var editorState: AllowanceUsageEditorState {
        AllowanceUsageEditorPolicy.state(
            plan: plan,
            occurredAt: occurredAt,
            availableCategories: model.expenseCategories,
            selectedCategoryID: categoryID
        )
    }

    private var policyCalendar: Calendar {
        AllowancePolicyDatePresentation.calendar(
            for: editorState.policy,
            fallbackPlan: plan
        )
    }

    private var canSave: Bool {
        editorState.canSaveSelection
            && decimalAmount(from: amountText).map { $0 > .zero } == true
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("allowance.amount", text: $amountText)
                    .moneyAmountKeyboard(currency: plan.amount.currency)
                Picker("transaction.category", selection: $categoryID) {
                    if editorState.permitsGeneral {
                        Text("allowance.general").tag(UUID?.none)
                    }
                    ForEach(editorState.categories) { category in
                        Text(model.categoryPathName(for: category.id))
                            .tag(Optional(category.id))
                    }
                }
                DatePicker(
                    "quick_log.date_and_time",
                    selection: $occurredAt,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .environment(\.calendar, policyCalendar)
                .environment(\.timeZone, policyCalendar.timeZone)
                LabeledContent(
                    "allowance.policy_time_zone",
                    value: editorState.policy?.timeZoneIdentifier
                        ?? plan.timeZoneIdentifier
                )
                if !editorState.isAvailable {
                    Text("allowance.date_unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField(
                    "transaction.description_or_notes",
                    text: $note,
                    axis: .vertical
                )
            }
            .navigationTitle(usage == nil
                ? LocalizedStringKey("allowance.record_use")
                : LocalizedStringKey("allowance.usage.edit"))
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
                if usage == nil { occurredAt = model.currentDateForUserAction() }
                normalizeCategorySelection()
            }
            .onChange(of: occurredAt) { _, _ in normalizeCategorySelection() }
            .moneyUpOperationErrorAlert(message: $errorMessage)
        }
    }

    private func normalizeCategorySelection() {
        categoryID = editorState.normalizedCategoryID
    }

    private func save() async {
        guard let amount = decimalAmount(from: amountText),
              let policyID = editorState.policy?.id,
              editorState.canSaveSelection else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            if let usage {
                try await model.updateUnlinkedBenefitAllowanceUsage(
                    planID: plan.id,
                    expectedUsage: usage,
                    expectedPolicyRevisionID: policyID,
                    amount: amount,
                    categoryID: editorState.normalizedCategoryID,
                    occurredAt: occurredAt,
                    note: note
                )
            } else {
                try await model.recordAllowanceUsage(
                    planID: plan.id,
                    expectedPolicyRevisionID: policyID,
                    amount: amount,
                    categoryID: editorState.normalizedCategoryID,
                    occurredAt: occurredAt,
                    note: note
                )
            }
            dismiss()
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }
}

private extension AllowanceClaimStatus {
    var allowanceTitleKey: LocalizedStringKey {
        switch self {
        case .pendingApproval: "allowance.claim.pending"
        case .approved: "allowance.claim.approved"
        case .reimbursed: "allowance.claim.reimbursed"
        case .rejected: "allowance.claim.rejected"
        }
    }
}
