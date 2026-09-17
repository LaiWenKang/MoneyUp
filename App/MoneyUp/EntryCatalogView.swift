import MoneyUpCore
import SwiftUI

@MainActor
struct EntryCatalogView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let scope: LedgerPresetScope
    var showsDone = false
    @State private var query = ""
    @State private var currencyCode = SupportedCurrencies.regionalDefault
    @State private var didInitialize = false
    @State private var isSaving = false
    @State private var isAddingRestricted = false
    @State private var managedItem: LedgerAccount?
    @State private var errorMessage: String?

    private var currency: CurrencyCode? { try? CurrencyCode(currencyCode) }
    private var presets: [LedgerPreset] { LedgerPresetCatalog.presets(for: scope) }
    private var items: [LedgerAccount] {
        model.accounts.filter {
            $0.systemRole == nil && (scope == .expenses ? $0.kind == .expense
                : $0.kind == .asset || $0.kind == .liability)
        }
    }
    private var visibleIDs: Set<UUID> {
        Set(LedgerEntryChoices.visible(items.filter { !$0.isArchived }).map(\.id))
    }
    private var representedIDs: Set<UUID> {
        Set(presets.flatMap { preset -> [UUID] in
            let matches = matches(preset)
            return matches.count == 1 ? matches.map(\.id) : []
        })
    }
    private var existing: [LedgerAccount] {
        items.filter { !representedIDs.contains($0.id) && matchesSearch(itemTitle($0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var offered: [LedgerPreset] {
        presets.filter { preset in
            let title = AppLocalization.string(preset.labelKey)
            return (matchesSearch(title) || matchesSearch(preset.id))
                && (matches(preset).count > 0 || !items.contains(where: {
                    !$0.isArchived && $0.presetID == nil && $0.name == title
                        && (scope == .expenses || ($0.currency == currency && $0.accountType == preset.accountType))
                }))
        }
    }
    private var groups: [String] {
        var seen = Set<String>()
        return offered.map(\.groupLabelKey).filter { seen.insert($0).inserted }
    }

    var body: some View {
        List {
            Section {
                if scope == .accounts {
                    SearchableCurrencyPicker(title: "catalog.new_currency", selection: $currencyCode,
                        existing: model.accounts.compactMap(\.currency))
                }
                HStack(alignment: .top) {
                    Text("catalog.choose_needed").font(.subheadline).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    MoneyUpExplainer(scope == .accounts ? "catalog.accounts_intro" : "catalog.expenses_intro")
                }
            }
            if !existing.isEmpty {
                Section("catalog.existing") {
                    ForEach(existing.filter { !$0.isArchived }) { item in existingRow(item) }
                    if existing.contains(where: \.isArchived) {
                        DisclosureGroup("catalog.archived") {
                            ForEach(existing.filter(\.isArchived)) { item in manageRow(item) }
                        }
                    }
                }
            }
            ForEach(groups, id: \.self) { group in
                Section {
                    ForEach(offered.filter { $0.groupLabelKey == group }) { preset in presetRow(preset) }
                } header: { Text(LocalizedStringKey(group)) }
            }
            Section {
                if scope == .accounts {
                    Button { isAddingRestricted = true }
                    label: { Label("catalog.restricted_setup", systemImage: "giftcard") }
                }
                Text("catalog.visibility_detail").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .searchable(text: $query, prompt: "catalog.search")
        .scrollContentBackground(.hidden)
        .background { MoneyUpBackdrop() }
        .navigationTitle(scope == .accounts ? "catalog.accounts_title" : "catalog.expenses_title")
        .moneyUpNavigationSurface()
        .disabled(!didInitialize || isSaving || model.state != .ready || model.isBookReplacementInProgress)
        .toolbar {
            if showsDone {
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.done") { dismiss() }.disabled(isSaving)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .onAppear {
            guard !didInitialize else { return }
            currencyCode = model.profile?.baseCurrency.value ?? currencyCode
            didInitialize = true
        }
        .onChange(of: model.logicalBookRevision) { _, _ in
            managedItem = nil
            errorMessage = nil
            currencyCode = model.profile?.baseCurrency.value ?? SupportedCurrencies.regionalDefault
        }
        .sheet(isPresented: $isAddingRestricted) {
            AddAccountSheet(initialType: .restrictedAllowance, initialCurrencyCode: currencyCode)
        }
        .sheet(item: $managedItem) { item in
            if item.kind == .expense { CategoryManagementSheet(categoryID: item.id) }
            else { AccountManagementSheet(account: item) }
        }
        .moneyUpOperationErrorAlert(message: $errorMessage)
    }

    @ViewBuilder
    private func presetRow(_ preset: LedgerPreset) -> some View {
        let linked = matches(preset)
        if linked.count > 1 {
            Label("catalog.multiple_matches", systemImage: "info.circle")
                .font(.subheadline).foregroundStyle(.secondary)
        } else if let item = linked.first, item.isArchived {
            manageRow(item)
        } else {
            let item = linked.first
            Toggle(isOn: Binding(get: { item.map { visibleIDs.contains($0.id) } ?? false }, set: { enabled in
                change {
                    try await model.setEntryPresetEnabled(preset.id, enabled: enabled, currencyCode: currencyCode)
                }
            })) {
                optionLabel(title: item.map(itemTitle) ?? AppLocalization.string(preset.labelKey),
                    symbol: preset.symbol,
                    detail: item.map(itemDetail) ?? (scope == .accounts
                        ? currencyCode + " · " + AppLocalization.string("catalog.zero_balance")
                        : AppLocalization.string("catalog.no_budget_limit")))
            }
            .disabled(item.map(hasHiddenParent) ?? false)
            .accessibilityIdentifier("catalog-preset-" + preset.id)
        }
    }

    private func existingRow(_ item: LedgerAccount) -> some View {
        Toggle(isOn: Binding(get: { visibleIDs.contains(item.id) }, set: { enabled in
            change { try await model.setEntryOptionEnabled(id: item.id, enabled: enabled) }
        })) {
            optionLabel(title: itemTitle(item), symbol: item.accountType?.systemImage ?? (scope == .expenses ? "tag.fill" : "wallet.bifold"), detail: itemDetail(item))
        }
        .disabled(hasHiddenParent(item))
        .accessibilityIdentifier("catalog-existing-" + item.id.uuidString)
    }

    private func manageRow(_ item: LedgerAccount) -> some View {
        Button { managedItem = item } label: {
            optionLabel(title: itemTitle(item), symbol: "archivebox", detail: AppLocalization.string("catalog.restore_first"))
        }
    }

    private func optionLabel(title: String, symbol: String, detail: String) -> some View {
        HStack(spacing: MoneyUpLayout.compactSpacing) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.tint)
                .frame(width: 32, height: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(minHeight: 44)
    }

    private func matches(_ preset: LedgerPreset) -> [LedgerAccount] {
        guard let currency else { return [] }
        return model.entryPresetMatches(preset, currency: currency)
    }
    private func matchesSearch(_ text: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.localizedStandardContains(query)
    }
    private func itemTitle(_ item: LedgerAccount) -> String {
        scope == .expenses ? model.categoryPathName(for: item.id) : item.name
    }
    private func itemDetail(_ item: LedgerAccount) -> String {
        if hasHiddenParent(item) { return AppLocalization.string("catalog.parent_hidden") }
        return item.currency?.value ?? AppLocalization.string("transaction.expense")
    }
    private func hasHiddenParent(_ item: LedgerAccount) -> Bool {
        item.parentID.map { !visibleIDs.contains($0) } ?? false
    }

    private func change(_ action: @escaping @MainActor () async throws -> Void) {
        guard !isSaving else { return }
        isSaving = true
        let revision = model.logicalBookRevision
        Task { @MainActor in
            defer { isSaving = false }
            guard revision == model.logicalBookRevision, model.state == .ready else { return }
            do { try await action() }
            catch is CancellationError { return }
            catch {
                guard revision == model.logicalBookRevision, model.state == .ready else { return }
                errorMessage = safeUserMessage(for: error, context: .save)
            }
        }
    }
}
