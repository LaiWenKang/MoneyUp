import MoneyUpCore
import SwiftUI

struct LoanCenterView: View {
    @Environment(AppModel.self) private var model
    @State private var isAddingLoan = false

    private var unconfiguredLoanAccounts: [LedgerAccount] {
        let configured = Set(model.loanPlans.map(\.accountID))
        return model.userAccounts.filter {
            $0.kind == .liability && $0.accountType == .loan && !configured.contains($0.id)
        }
    }

    private var includedDebtTotals: DerivedValue<[Money]> {
        var totals: [CurrencyCode: Decimal] = [:]
        for plan in model.loanPlans where plan.includeInTotalDebt && plan.closedAt == nil {
            guard case let .available(summary) = model.loanSummary(plan) else {
                return .unavailable(.amountCalculationFailed)
            }
            do {
                let currency = summary.remainingPrincipal.currency
                totals[currency] = try CheckedDecimal.adding(
                    totals[currency] ?? .zero,
                    summary.remainingPrincipal.amount
                )
            } catch {
                return .unavailable(.amountCalculationFailed)
            }
        }
        do {
            return .available(try totals.sorted { $0.key < $1.key }.map {
                try Money($0.value, currency: $0.key)
            })
        } catch {
            return .unavailable(.amountCalculationFailed)
        }
    }

    var body: some View {
        List {
            if !model.loanPlans.isEmpty {
                Section("loan.included_total") {
                    switch includedDebtTotals {
                    case let .available(totals):
                        if totals.isEmpty {
                            Text("loan.no_included_debt").foregroundStyle(.secondary)
                        } else {
                            ForEach(totals, id: \.currency) { total in
                                Text(formattedMoney(total))
                                    .font(.title3.monospacedDigit().weight(.bold))
                            }
                        }
                    case let .unavailable(issue):
                        DerivedValueUnavailableView(issue: issue)
                    }
                }
            }
            if model.loanPlans.isEmpty {
                    ContentUnavailableView(
                        "loan.empty",
                        systemImage: "building.columns.fill",
                    description: Text("loan.empty_detail")
                )
            } else {
                Section("loan.active") {
                    ForEach(model.loanPlans.filter { $0.closedAt == nil }) { plan in
                        NavigationLink {
                            LoanDetailView(planID: plan.id)
                        } label: {
                            LoanRow(plan: plan)
                        }
                    }
                }
                if model.loanPlans.contains(where: { $0.closedAt != nil }) {
                    Section("loan.finished") {
                        ForEach(model.loanPlans.filter { $0.closedAt != nil }) { plan in
                            NavigationLink {
                                LoanDetailView(planID: plan.id)
                            } label: {
                                LoanRow(plan: plan)
                            }
                        }
                    }
                }
            }

            if !unconfiguredLoanAccounts.isEmpty {
                Section {
                    Button {
                        isAddingLoan = true
                    } label: {
                        Label("loan.configure", systemImage: "plus.circle")
                    }
                } footer: {
                    MoneyUpExplainer("loan.configure_detail")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.moneyUpBackground)
        .navigationTitle("loan.title")
        .toolbar {
            if !unconfiguredLoanAccounts.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isAddingLoan = true
                    } label: {
                        Label("loan.configure", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $isAddingLoan) {
            AddLoanPlanSheet(accounts: unconfiguredLoanAccounts)
        }
    }
}

private struct LoanRow: View {
    @Environment(AppModel.self) private var model
    let plan: LoanPlan

    var body: some View {
        HStack(spacing: 12) {
            MoneyUpSymbolBadge(systemImage: plan.purpose.systemImage, color: .accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(plan.name).fontWeight(.semibold)
                Text(
                    plan.closedAt == nil
                        ? LocalizedStringKey("loan.remaining")
                        : LocalizedStringKey("loan.finished")
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch model.loanSummary(plan) {
            case let .available(summary):
                Text(formattedMoney(summary.remainingPrincipal))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            case let .unavailable(issue):
                DerivedValueUnavailableView(issue: issue)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct LoanDetailView: View {
    @Environment(AppModel.self) private var model
    let planID: UUID
    @State private var isRecordingPayment = false
    @State private var isRecordingDrawdown = false
    @State private var isEditing = false
    @State private var errorMessage: String?

    private var plan: LoanPlan? { model.loanPlans.first { $0.id == planID } }

    var body: some View {
        List {
            if let plan {
                Section {
                    switch model.loanSummary(plan) {
                    case let .available(summary):
                        LabeledContent("loan.remaining") {
                            Text(formattedMoney(summary.remainingPrincipal))
                                .font(.title3.monospacedDigit().weight(.bold))
                        }
                        LabeledContent(
                            "loan.total_principal",
                            value: formattedMoney(summary.totalPrincipalAdvanced)
                        )
                        LabeledContent(
                            "loan.principal_paid",
                            value: formattedMoney(summary.principalPaid)
                        )
                        LabeledContent(
                            "loan.interest_paid",
                            value: formattedMoney(summary.totalInterestPaid)
                        )
                        if !summary.totalFeesPaid.isZero {
                            LabeledContent(
                                "loan.fees_paid",
                                value: formattedMoney(summary.totalFeesPaid)
                            )
                        }
                    case let .unavailable(issue):
                        DerivedValueUnavailableView(issue: issue, prominent: true)
                    }
                    LabeledContent("loan.opened") {
                        Text(plan.openedAt, format: .dateTime.year().month().day())
                    }
                    LabeledContent(
                        "loan.purpose",
                        value: AppLocalization.string(plan.purpose.titleKeyString)
                    )
                    if let apr = plan.annualPercentageRate {
                        LabeledContent("loan.apr") {
                            Text(apr, format: .number.precision(.fractionLength(0...3)))
                                + Text("%")
                        }
                    }
                    LabeledContent(
                        "loan.include_total_debt",
                        value: AppLocalization.string(
                            plan.includeInTotalDebt ? "answer.yes" : "answer.no"
                        )
                    )
                }

                Section("loan.activity") {
                    if plan.activities.isEmpty {
                        Text("loan.no_activity").foregroundStyle(.secondary)
                    } else {
                        ForEach(plan.activities.reversed()) { activity in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(activity.kind.titleKey)
                                    Spacer()
                                    Text(formattedMoney(activityTotal(activity)))
                                        .monospacedDigit()
                                }
                                Text(activity.occurredAt, format: .dateTime.year().month().day())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let note = activity.note {
                                    Text(note)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if plan.closedAt == nil {
                    Section {
                        Button {
                            isRecordingPayment = true
                        } label: {
                            Label("loan.repayment", systemImage: "arrow.left.arrow.right")
                        }
                        Button {
                            isRecordingDrawdown = true
                        } label: {
                            Label("loan.drawdown", systemImage: "plus.circle")
                        }
                        if case let .available(summary) = model.loanSummary(plan),
                           summary.remainingPrincipal.isZero {
                            Button("loan.finish") {
                                Task { await finish(plan) }
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.moneyUpBackground)
        .navigationTitle(plan?.name ?? AppLocalization.string("loan.title"))
        .toolbar {
            if plan != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("action.edit") { isEditing = true }
                }
            }
        }
        .sheet(isPresented: $isRecordingPayment) {
            if let plan { LoanPaymentSheet(plan: plan) }
        }
        .sheet(isPresented: $isRecordingDrawdown) {
            if let plan { LoanDrawdownSheet(plan: plan) }
        }
        .sheet(isPresented: $isEditing) {
            if let plan { LoanEditSheet(plan: plan) }
        }
        .moneyUpOperationErrorAlert(message: $errorMessage)
    }

    private func activityTotal(_ activity: LoanActivity) -> Money {
        (try? activity.principal.adding(activity.interest).adding(activity.fees))
            ?? activity.principal
    }

    private func finish(_ plan: LoanPlan) async {
        do {
            try await model.finishLoan(id: plan.id, at: model.currentDateForUserAction())
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }
}

private struct AddLoanPlanSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let accounts: [LedgerAccount]
    @State private var accountID: UUID?
    @State private var name = ""
    @State private var principalText = ""
    @State private var aprText = ""
    @State private var termText = ""
    @State private var openedAt = Date()
    @State private var includeInDebt = true
    @State private var interestCategoryID: UUID?
    @State private var feeCategoryID: UUID?
    @State private var purpose: LoanPurpose = .other
    @State private var errorMessage: String?
    @State private var isSaving = false

    private var selectedAccount: LedgerAccount? {
        accounts.first { $0.id == accountID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("loan.account", selection: $accountID) {
                    ForEach(accounts) { account in
                        Text(accountCurrencyLabel(account)).tag(Optional(account.id))
                    }
                }
                TextField("loan.name", text: $name)
                Picker("loan.purpose", selection: $purpose) {
                    ForEach(LoanPurpose.allCases, id: \.self) { option in
                        Label(option.titleKey, systemImage: option.systemImage).tag(option)
                    }
                }
                TextField("loan.original_principal", text: $principalText)
                    .moneyAmountKeyboard(currency: selectedAccount?.currency)
                DatePicker("loan.opened", selection: $openedAt, displayedComponents: .date)
                TextField("loan.apr_optional", text: $aprText)
                    .keyboardType(.decimalPad)
                TextField("loan.term_optional", text: $termText)
                    .keyboardType(.numberPad)
                Toggle("loan.include_total_debt", isOn: $includeInDebt)
                expenseCategoryPicker("loan.interest_category", selection: $interestCategoryID)
                expenseCategoryPicker("loan.fee_category", selection: $feeCategoryID)
            }
            .navigationTitle("loan.configure")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
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
                openedAt = model.currentDateForUserAction()
                accountID = accountID ?? accounts.first?.id
                if name.isEmpty { name = selectedAccount?.name ?? "" }
                interestCategoryID = interestCategoryID ?? model.expenseCategories.first?.id
                feeCategoryID = feeCategoryID ?? model.expenseCategories.first?.id
            }
            .onChange(of: accountID) { _, _ in
                if name.isEmpty { name = selectedAccount?.name ?? "" }
            }
            .moneyUpOperationErrorAlert(message: $errorMessage)
        }
    }

    private var canSave: Bool {
        accountID != nil
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && decimalAmount(from: principalText).map { $0 > .zero } == true
            && (aprText.isEmpty || decimalAmount(from: aprText) != nil)
            && (termText.isEmpty || Int(termText) != nil)
    }

    private func expenseCategoryPicker(
        _ title: LocalizedStringKey,
        selection: Binding<UUID?>
    ) -> some View {
        Picker(title, selection: selection) {
            Text("category.none").tag(UUID?.none)
            ForEach(model.expenseCategories) { category in
                Text(model.categoryPathName(for: category.id)).tag(Optional(category.id))
            }
        }
    }

    private func save() async {
        guard let accountID, let principal = decimalAmount(from: principalText) else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await model.addLoanPlan(
                accountID: accountID,
                name: name,
                originalPrincipal: principal,
                openedAt: openedAt,
                annualPercentageRate: aprText.isEmpty ? nil : decimalAmount(from: aprText),
                termMonths: termText.isEmpty ? nil : Int(termText),
                includeInTotalDebt: includeInDebt,
                interestExpenseAccountID: interestCategoryID,
                feeExpenseAccountID: feeCategoryID,
                purpose: purpose
            )
            dismiss()
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }
}

private struct LoanPaymentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let plan: LoanPlan
    @State private var accountID: UUID?
    @State private var principal = ""
    @State private var interest = ""
    @State private var fees = ""
    @State private var occurredAt = Date()
    @State private var note = ""
    @State private var errorMessage: String?
    @State private var isSaving = false

    private var currency: CurrencyCode { plan.originalPrincipal.currency }
    private var accounts: [LedgerAccount] {
        model.userAccounts.filter {
            $0.kind == .asset
                && $0.accountType != .restrictedAllowance
                && $0.currency == currency
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("loan.paid_from", selection: $accountID) {
                    ForEach(accounts) { Text($0.name).tag(Optional($0.id)) }
                }
                amountField("loan.principal", text: $principal)
                amountField("loan.interest", text: $interest)
                amountField("loan.fees", text: $fees)
                DatePicker(
                    "quick_log.date_and_time",
                    selection: $occurredAt,
                    displayedComponents: [.date, .hourAndMinute]
                )
                TextField("transaction.description_or_notes", text: $note, axis: .vertical)
            }
            .navigationTitle("loan.repayment")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
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
                accountID = accounts.first?.id
                occurredAt = model.currentDateForUserAction()
            }
            .moneyUpOperationErrorAlert(message: $errorMessage)
        }
    }

    private var parsed: (Decimal, Decimal, Decimal)? {
        guard let principal = zeroableAmount(principal),
              let interest = zeroableAmount(interest),
              let fees = zeroableAmount(fees),
              let subtotal = try? CheckedDecimal.adding(principal, interest),
              let total = try? CheckedDecimal.adding(subtotal, fees),
              total > .zero else { return nil }
        return (principal, interest, fees)
    }

    private var canSave: Bool { accountID != nil && parsed != nil }

    private func amountField(_ title: LocalizedStringKey, text: Binding<String>) -> some View {
        TextField(title, text: text).moneyAmountKeyboard(currency: currency)
    }

    private func zeroableAmount(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .zero }
        guard let value = decimalAmount(from: trimmed), value >= .zero else { return nil }
        return value
    }

    private func save() async {
        guard let accountID, let parsed else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.recordLoanPayment(
                loanID: plan.id,
                paidFrom: accountID,
                principal: parsed.0,
                interest: parsed.1,
                fees: parsed.2,
                occurredAt: occurredAt,
                note: note
            )
            dismiss()
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }
}

private struct LoanDrawdownSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let plan: LoanPlan
    @State private var accountID: UUID?
    @State private var amount = ""
    @State private var occurredAt = Date()
    @State private var note = ""
    @State private var errorMessage: String?
    @State private var isSaving = false

    private var accounts: [LedgerAccount] {
        model.userAccounts.filter {
            $0.kind == .asset && $0.currency == plan.originalPrincipal.currency
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("loan.deposit_into", selection: $accountID) {
                    ForEach(accounts) { Text($0.name).tag(Optional($0.id)) }
                }
                TextField("loan.principal", text: $amount)
                    .moneyAmountKeyboard(currency: plan.originalPrincipal.currency)
                DatePicker(
                    "quick_log.date_and_time",
                    selection: $occurredAt,
                    displayedComponents: [.date, .hourAndMinute]
                )
                TextField("transaction.description_or_notes", text: $note, axis: .vertical)
            }
            .navigationTitle("loan.drawdown")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") { Task { await save() } }
                        .disabled(
                            isSaving
                                || accountID == nil
                                || decimalAmount(from: amount).map { $0 > .zero } != true
                        )
                }
                MoneyUpKeyboardDoneToolbar()
            }
            .onAppear {
                accountID = accounts.first?.id
                occurredAt = model.currentDateForUserAction()
            }
            .moneyUpOperationErrorAlert(message: $errorMessage)
        }
    }

    private func save() async {
        guard let accountID, let amount = decimalAmount(from: amount) else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.recordLoanDrawdown(
                loanID: plan.id,
                depositedInto: accountID,
                principal: amount,
                occurredAt: occurredAt,
                note: note
            )
            dismiss()
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }
}

private struct LoanEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let plan: LoanPlan
    @State private var name: String
    @State private var apr: String
    @State private var term: String
    @State private var includeInDebt: Bool
    @State private var interestCategoryID: UUID?
    @State private var feeCategoryID: UUID?
    @State private var purpose: LoanPurpose
    @State private var errorMessage: String?

    init(plan: LoanPlan) {
        self.plan = plan
        _name = State(initialValue: plan.name)
        _apr = State(
            initialValue: plan.annualPercentageRate.map { editableAmount($0) } ?? ""
        )
        _term = State(initialValue: plan.termMonths.map(String.init) ?? "")
        _includeInDebt = State(initialValue: plan.includeInTotalDebt)
        _interestCategoryID = State(initialValue: plan.interestExpenseAccountID)
        _feeCategoryID = State(initialValue: plan.feeExpenseAccountID)
        _purpose = State(initialValue: plan.purpose)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("loan.name", text: $name)
                Picker("loan.purpose", selection: $purpose) {
                    ForEach(LoanPurpose.allCases, id: \.self) { option in
                        Label(option.titleKey, systemImage: option.systemImage).tag(option)
                    }
                }
                TextField("loan.apr_optional", text: $apr).keyboardType(.decimalPad)
                TextField("loan.term_optional", text: $term).keyboardType(.numberPad)
                Toggle("loan.include_total_debt", isOn: $includeInDebt)
                categoryPicker("loan.interest_category", selection: $interestCategoryID)
                categoryPicker("loan.fee_category", selection: $feeCategoryID)
            }
            .navigationTitle("action.edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") { Task { await save() } }
                }
                MoneyUpKeyboardDoneToolbar()
            }
            .moneyUpOperationErrorAlert(message: $errorMessage)
        }
    }

    private func categoryPicker(
        _ title: LocalizedStringKey,
        selection: Binding<UUID?>
    ) -> some View {
        Picker(title, selection: selection) {
            Text("category.none").tag(UUID?.none)
            ForEach(model.expenseCategories) { category in
                Text(model.categoryPathName(for: category.id)).tag(Optional(category.id))
            }
        }
    }

    private func save() async {
        do {
            try await model.updateLoanPlan(
                id: plan.id,
                name: name,
                annualPercentageRate: apr.isEmpty ? nil : decimalAmount(from: apr),
                termMonths: term.isEmpty ? nil : Int(term),
                includeInTotalDebt: includeInDebt,
                interestExpenseAccountID: interestCategoryID,
                feeExpenseAccountID: feeCategoryID,
                purpose: purpose
            )
            dismiss()
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }
}

private extension LoanActivityKind {
    var titleKey: LocalizedStringKey {
        switch self {
        case .drawdown: "loan.drawdown"
        case .repayment: "loan.repayment"
        case .reconciliation: "loan.reconciliation"
        }
    }
}

private extension LoanPurpose {
    var titleKeyString: String {
        switch self {
        case .home: "loan.purpose.home"
        case .vehicle: "loan.purpose.vehicle"
        case .education: "loan.purpose.education"
        case .medical: "loan.purpose.medical"
        case .personal: "loan.purpose.personal"
        case .business: "loan.purpose.business"
        case .installment: "loan.purpose.installment"
        case .creditLine: "loan.purpose.credit_line"
        case .other: "loan.purpose.other"
        }
    }

    var titleKey: LocalizedStringKey { LocalizedStringKey(titleKeyString) }

    var systemImage: String {
        switch self {
        case .home: "house.fill"
        case .vehicle: "car.side.fill"
        case .education: "graduationcap.fill"
        case .medical: "cross.case.fill"
        case .personal: "person.fill"
        case .business: "briefcase.fill"
        case .installment: "cart.fill.badge.clock"
        case .creditLine: "creditcard.fill"
        case .other: "building.columns.fill"
        }
    }
}
