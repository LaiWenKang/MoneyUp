import MoneyUpCore
import SwiftUI

/// One place to discover every fast way into Log: the Home Screen widget, the
/// Control Center / Lock Screen / Action button control, Siri, favourites,
/// and the privacy switches that govern them.
struct WidgetsQuickAccessView: View {
    @Environment(AppModel.self) private var model
    @State private var previewFamily: QuickLogWidgetLayoutFamily = .medium
    @State private var previewAction: MoneyUpQuickAction = .expense
    @State private var editing: QuickLogFavourite?
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                QuickLogWidgetPreviewPanel(family: previewFamily, action: previewAction)
                    .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 12, trailing: 16))
                Picker("quick_access.preview_size", selection: $previewFamily) {
                    Text("quick_access.size_small").tag(QuickLogWidgetLayoutFamily.small)
                    Text("quick_access.size_medium").tag(QuickLogWidgetLayoutFamily.medium)
                    Text("quick_access.size_large").tag(QuickLogWidgetLayoutFamily.large)
                }
                .pickerStyle(.segmented)
                Picker("quick_access.main_action", selection: $previewAction) {
                    ForEach(MoneyUpQuickAction.allCases) { action in
                        Label(action.titleKey, systemImage: action.systemImage).tag(action)
                    }
                }
            } header: {
                MoneyUpSectionHeader("quick_access.widget_title", explanation: "quick_access.widget_detail")
            } footer: {
                Text("quick_access.widget_steps")
            }

            favouritesSection

            Section {
                QuickAccessSurfaceRow(
                    systemImage: "switch.2",
                    title: "quick_access.control_title",
                    detail: "quick_access.control_detail"
                )
                QuickAccessSurfaceRow(
                    systemImage: "waveform",
                    title: "quick_access.siri_title",
                    detail: "quick_access.siri_detail"
                )
            } header: {
                MoneyUpSectionHeader("quick_access.more_ways", explanation: "quick_access.more_ways_detail")
            }

            privacySection
        }
        .navigationTitle("quick_access.title")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { favourite in
            QuickLogFavouriteEditor(favourite: favourite, isNew: false)
        }
        .sheet(isPresented: $isCreating) {
            QuickLogFavouriteEditor(
                favourite: QuickLogFavourite(name: "", kind: .expense),
                isNew: true
            )
        }
        .moneyUpOperationErrorAlert(message: $errorMessage)
    }

    private var favouritesSection: some View {
        Section {
            ForEach(model.quickLogFavourites) { favourite in
                Button {
                    editing = favourite
                } label: {
                    QuickAccessFavouriteRow(
                        favourite: favourite,
                        needsRepair: !model.quickLogFavouriteRepairs(favourite).isEmpty
                    )
                }
                .buttonStyle(.plain)
            }
            .onMove { source, destination in
                Task { await run { try await model.moveQuickLogFavourites(fromOffsets: source, toOffset: destination) } }
            }
            .onDelete { offsets in
                let ids = offsets.map { model.quickLogFavourites[$0].id }
                Task { await run { for id in ids { try await model.deleteQuickLogFavourite(id: id) } } }
            }
            Button {
                isCreating = true
            } label: {
                Label("favourites.new", systemImage: "plus.circle.fill")
            }
            .disabled(!model.canAddQuickLogFavourite)
        } header: {
            HStack {
                MoneyUpSectionHeader("favourites.title", explanation: "favourites.section_detail")
                Spacer()
                if model.quickLogFavourites.count > 1 {
                    EditButton()
                        .font(.caption.weight(.semibold))
                        .padding(13).contentShape(Rectangle()).padding(-13)
                }
            }
        } footer: {
            Text("favourites.privacy_footer")
        }
    }

    private var privacySection: some View {
        Section {
            Toggle(
                "settings.widget.budget_status",
                isOn: Binding(
                    get: { model.profile?.showsBudgetStatusWidget ?? false },
                    set: { enabled in
                        Task { await run { try await model.updateBudgetStatusWidget(enabled) } }
                    }
                )
            )
            .accessibilityHint("settings.widget.budget_status_hint")
            Toggle(
                isOn: Binding(
                    get: { model.profile?.allowLockedQuickCapture ?? true },
                    set: { enabled in
                        Task { await run { try await model.updateLockedQuickCapture(enabled) } }
                    }
                )
            ) {
                Label("settings.locked_capture", systemImage: "bolt.badge.clock")
            }
            Toggle(
                isOn: Binding(
                    get: { model.profile?.showsFavouritesWhileLocked ?? false },
                    set: { enabled in
                        Task { await run { try await model.updateFavouritesWhileLocked(enabled) } }
                    }
                )
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("quick_access.favourites_while_locked", systemImage: "star.square.on.square")
                    Text("quick_access.favourites_while_locked_detail")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!(model.profile?.allowLockedQuickCapture ?? true))
            .accessibilityIdentifier("quick-access-favourites-while-locked")
        } header: {
            MoneyUpSectionHeader("quick_access.privacy_title", explanation: "quick_access.privacy_detail")
        } footer: {
            Text("quick_access.privacy_footer")
        }
    }

    private func run(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            errorMessage = nil
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }
}

/// The in-app preview renders the same shared card the widget extension uses,
/// on the same canvas colours, without any navigation.
struct QuickLogWidgetPreviewPanel: View {
    let family: QuickLogWidgetLayoutFamily
    let action: MoneyUpQuickAction

    private var size: CGSize {
        switch family {
        case .small: CGSize(width: 158, height: 158)
        case .medium: CGSize(width: 338, height: 158)
        case .large: CGSize(width: 338, height: 354)
        }
    }

    var body: some View {
        QuickLogWidgetCard(primary: action, family: family, density: .standard) { action, role in
            QuickLogWidgetTile(action: action, role: role)
        }
        .padding(16)
        .frame(width: size.width, height: size.height)
        .background {
            if family == .small {
                QuickLogWidgetPalette.heroGradient
            } else {
                Color.moneyUpSurfaceElevated
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
        .frame(maxWidth: .infinity)
        .animation(.snappy(duration: 0.25), value: family)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("quick_access.preview_accessibility")
    }
}

struct QuickAccessSurfaceRow: View {
    let systemImage: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            MoneyUpCategoryBadge(systemImage: systemImage, tint: .moneyUpAction, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct QuickAccessFavouriteRow: View {
    @Environment(AppModel.self) private var model
    let favourite: QuickLogFavourite
    let needsRepair: Bool

    var body: some View {
        HStack(spacing: 12) {
            MoneyUpCategoryBadge(
                systemImage: needsRepair ? "exclamationmark.triangle.fill" : symbol,
                tint: needsRepair ? .moneyUpWarning : .moneyUpAction,
                size: 32
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(favourite.name).font(.body.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        guard let categoryID = favourite.categoryID, model.accountsByID[categoryID] != nil else {
            return favourite.kind == .income
                ? MoneyUpCategorySymbol.fallbackIncome : MoneyUpCategorySymbol.fallbackExpense
        }
        return MoneyUpCategorySymbol.symbol(for: categoryID, accountsByID: model.accountsByID)
    }

    private var detail: String {
        if needsRepair { return AppLocalization.string("favourites.needs_attention") }
        let category = favourite.categoryID.flatMap { id in
            model.accountsByID[id] == nil ? nil : model.categoryPathName(for: id)
        }
        let amount = favourite.amount.map {
            QuickLogFavouriteFormatting.amount($0, accountID: favourite.accountID,
                accountsByID: model.accountsByID, hidesAmounts: MoneyAmountPrivacy.hidesAmounts)
        } ?? AppLocalization.string("favourites.amount_each_time")
        return [category, amount].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Creates, edits, and repairs one favourite. Saving a favourite never posts
/// a transaction; it only changes what a later tap prefills.
struct QuickLogFavouriteEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let original: QuickLogFavourite
    let isNew: Bool
    @State private var name: String
    @State private var kind: QuickLogFavourite.Kind
    @State private var remembersAmount: Bool
    @State private var amountText: String
    @State private var accountID: UUID?
    @State private var categoryID: UUID?
    @State private var payee: String
    @State private var note: String
    @State private var repairs: Set<QuickLogFavouriteRepair> = []
    @State private var isSaving = false
    @State private var isConfirmingDelete = false
    @State private var errorMessage: String?

    init(favourite: QuickLogFavourite, isNew: Bool) {
        original = favourite
        self.isNew = isNew
        _name = State(initialValue: favourite.name)
        _kind = State(initialValue: favourite.kind)
        // A new favourite from a saved entry starts amount-only: the safer
        // default for "Lunch"; "Coffee · 3.20" is one switch away.
        _remembersAmount = State(initialValue: !isNew && favourite.amount != nil)
        _amountText = State(initialValue: favourite.amount.map { editableAmount($0) } ?? "")
        _accountID = State(initialValue: favourite.accountID)
        _categoryID = State(initialValue: favourite.categoryID)
        _payee = State(initialValue: favourite.payee)
        _note = State(initialValue: favourite.note)
    }

    private var accounts: [LedgerAccount] {
        LedgerEntryChoices.visible(model.userAccounts, preserving: Set([accountID].compactMap { $0 }))
    }

    private var categories: [LedgerAccount] {
        let pool = kind == .income ? model.incomeCategories : model.expenseCategories
        return LedgerEntryChoices.visible(pool, preserving: Set([categoryID].compactMap { $0 }))
    }

    private var parsedAmount: Decimal? {
        guard remembersAmount else { return nil }
        guard let value = decimalAmount(from: amountText), value > 0 else { return nil }
        return value
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!remembersAmount || parsedAmount != nil) && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                if !repairs.isEmpty {
                    Section {
                        Label("favourites.repair_detail", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.moneyUpWarning)
                    }
                }
                Section {
                    TextField("favourites.name", text: $name)
                        .textInputAutocapitalization(.sentences)
                    Picker("favourites.kind", selection: $kind) {
                        Text("platform_action.expense").tag(QuickLogFavourite.Kind.expense)
                        Text("platform_action.income").tag(QuickLogFavourite.Kind.income)
                    }
                    .pickerStyle(.segmented)
                }
                amountSection
                Section {
                    Picker("transaction.account", selection: $accountID) {
                        Text("quick_log.choose_account").tag(UUID?.none)
                        ForEach(accounts) { account in
                            Text(accountCurrencyLabel(account)).tag(Optional(account.id))
                        }
                    }
                    Picker("transaction.category", selection: $categoryID) {
                        Text("quick_log.choose_category").tag(UUID?.none)
                        ForEach(categories) { category in
                            Text(model.categoryPathName(for: category.id)).tag(Optional(category.id))
                        }
                    }
                    TextField("transaction.title_or_merchant", text: $payee)
                    TextField("transaction.description_or_notes", text: $note, axis: .vertical)
                        .lineLimit(1...3)
                } header: {
                    MoneyUpSectionHeader("favourites.prefills", explanation: "favourites.prefill_hint")
                }
                if !isNew {
                    Section {
                        Button("favourites.delete", role: .destructive) { isConfirmingDelete = true }
                    }
                }
            }
            .navigationTitle(isNew ? "favourites.new" : "favourites.edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") { Task { await save() } }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
            .onAppear(perform: prepareRepair)
            .onChange(of: kind) { _, _ in
                if let categoryID, !categories.contains(where: { $0.id == categoryID }) {
                    self.categoryID = nil
                }
            }
            .confirmationDialog("favourites.delete", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button("favourites.delete", role: .destructive) { Task { await delete() } }
                Button("action.cancel", role: .cancel) {}
            } message: {
                Text("favourites.delete_detail")
            }
            .moneyUpOperationErrorAlert(message: $errorMessage)
        }
    }

    private var amountSection: some View {
        Section {
            Toggle("favourites.same_amount", isOn: $remembersAmount)
            if remembersAmount {
                TextField("favourites.amount", text: $amountText)
                    .keyboardType(.decimalPad)
                    .monospacedDigit()
            }
        } footer: {
            Text(remembersAmount ? "favourites.same_amount_detail" : "favourites.amount_each_time_detail")
        }
    }

    /// Stale references are cleared in the form so the pickers show a real
    /// choice; the banner says why instead of silently picking a replacement.
    private func prepareRepair() {
        repairs = model.quickLogFavouriteRepairs(original)
        if repairs.contains(.account) { accountID = nil }
        if repairs.contains(.category) { categoryID = nil }
    }

    private func save() async {
        guard canSave else { return }
        isSaving = true
        defer { isSaving = false }
        let favourite = QuickLogFavourite(
            id: original.id,
            name: name,
            kind: kind,
            amount: parsedAmount,
            accountID: accountID,
            categoryID: categoryID,
            payee: payee,
            note: note
        )
        do {
            try await model.saveQuickLogFavourite(favourite)
            dismiss()
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }

    private func delete() async {
        do {
            try await model.deleteQuickLogFavourite(id: original.id)
            dismiss()
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }
}
