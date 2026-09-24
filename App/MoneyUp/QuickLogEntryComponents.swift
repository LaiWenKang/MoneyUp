import Foundation
import MoneyUpCore
import OSLog
import PhotosUI
import SwiftUI
import UIKit

extension QuickLogEntryView {
    @ViewBuilder
    var primaryAmountControl: some View {
        let amountValidationMessage = monetaryInputError(
            text: amountText,
            currency: selectedAccountCurrency
        )
        HStack(alignment: .firstTextBaseline) {
            TextField(
                "quick_log.amount",
                text: trackedBinding(
                    $amountText,
                    \.amountText,
                    refreshesOccurrenceDate: true
                )
            )
            .moneyAmountKeyboard(currency: selectedAccountCurrency)
            .moneyUpFinancialValue(.hero)
            .focused($focusedField, equals: .amount)
            .id(QuickLogFieldFocus.amount)
            .moneyUpFieldValidation(amountValidationMessage)
            .moneyUpPrivateAmountInput(
                masked: masksPrimaryAmount,
                accessibilityLabel: Text("quick_log.amount"),
                placeholderFont: MoneyUpTypography.financialValueFont(for: .hero)
            ) {
                focusedField = .amount
            }
            amountCurrencyControl
        }
        if let amountValidationMessage {
            MoneyUpFieldError(message: amountValidationMessage)
        }
        quickRouteBar
    }

    @ViewBuilder
    var destinationAmountControl: some View {
        let destinationAmountValidationMessage = monetaryInputError(
            text: destinationAmountText,
            currency: selectedDestinationCurrency
        )
        HStack {
            TextField(
                "transaction.received_amount",
                text: trackedBinding(
                    $destinationAmountText,
                    \.destinationAmountText,
                    refreshesOccurrenceDate: true
                )
            )
            .moneyAmountKeyboard(currency: selectedDestinationCurrency)
            .focused($focusedField, equals: .destinationAmount)
            .id(QuickLogFieldFocus.destinationAmount)
            .moneyUpFieldValidation(destinationAmountValidationMessage)
            .moneyUpPrivateAmountInput(
                masked: masksDestinationAmount,
                accessibilityLabel: Text("transaction.received_amount")
            ) {
                focusedField = .destinationAmount
            }
            if let currency = selectedDestinationCurrency {
                Text(currency.value).foregroundStyle(.secondary)
            }
        }
        if let destinationAmountValidationMessage {
            MoneyUpFieldError(message: destinationAmountValidationMessage)
        }
    }

    @ViewBuilder
    var categoryAndAllowanceControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack { addCategoryButton; manageCategoriesButton }
            VStack(alignment: .leading) { addCategoryButton; manageCategoriesButton }
        }
        if kind == .expense, !availableAllowances.isEmpty {
            Picker("allowance.apply", selection: $selectedAllowanceID) {
                Text("allowance.none").tag(UUID?.none)
                ForEach(availableAllowances) { plan in
                    Text(plan.name).tag(Optional(plan.id))
                }
            }
            if let presentation = selectedAllowancePresentation,
               let remaining = selectedAllowanceRemaining?.value {
                let remainingTitleKey = presentation.remainingMeaning
                    == .prepaidSpendable
                    ? "allowance.prepaid_spendable_at_transaction_time"
                    : presentation.remainingMeaning.titleKeyString
                LabeledContent(LocalizedStringKey(
                    remainingTitleKey
                )) {
                    Text(formattedMoney(remaining))
                        .monospacedDigit()
                }
                .font(.caption)
            } else if selectedPrepaidFundingIsLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("allowance.checking_prepaid_balance")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            } else if let remaining = selectedAllowanceRemaining,
                      case let .unavailable(issue) = remaining {
                DerivedValueUnavailableView(issue: issue)
            }
            if let application = selectedAllowanceApplication {
                let applicationKey = selectedAllowancePresentation?
                    .remainingMeaning.applicationKeyString
                    ?? "allowance.apply_amount"
                Label(
                    String(
                        format: AppLocalization.string(applicationKey),
                        formattedMoney(application)
                    ),
                    systemImage: "giftcard.fill"
                )
                .font(.caption)
                .foregroundStyle(.tint)
            }
        }
        if kind == .expense,
           selectedSourceAccount?.accountType == .restrictedAllowance {
            Label(
                "quick_log.restricted_source_rule",
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        prepaidFundingLifecycleAnchor
    }

    var addCategoryButton: some View {
        Button { isAddingCategory = true } label: {
            Label("category.add", systemImage: "plus.circle")
        }
    }

    var manageCategoriesButton: some View {
        Button { isManagingCategories = true } label: {
            Label("lifecycle.manage_categories", systemImage: "square.grid.2x2")
        }
    }

    var availableAllowances: [AllowancePlan] {
        guard kind == .expense,
              let currency = selectedAccountCurrency,
              let sourceAccount = selectedSourceAccount else { return [] }
        return model.allowancePlans.filter { plan in
            let presentation = model.allowancePresentation(plan, asOf: occurredAt)
            guard !plan.isArchived,
                  model.isAllowanceWritable(plan),
                  plan.amount.currency == currency,
                  QuickLogAllowanceSourcePolicy.planIsEligible(
                      plan,
                      for: sourceAccount
                  ),
                  let summary = presentation.policySummary,
                  summary.isAvailableToday else { return false }
            guard summary.remaining.amount > .zero else { return false }
            if plan.fundingMode != .prepaidAsset {
                guard case let .available(remaining) = presentation.remaining,
                      remaining.amount > .zero else {
                    return false
                }
            }
            return true
        }
    }

    var selectedAllowancePlan: AllowancePlan? {
        guard let selectedAllowanceID,
              let plan = availableAllowances.first(where: {
                  $0.id == selectedAllowanceID
              }) else { return nil }
        return plan
    }

    var selectedAllowancePresentation: AllowancePresentation? {
        guard let plan = selectedAllowancePlan else { return nil }
        return model.allowancePresentation(plan, asOf: occurredAt)
    }

    var occurrenceSection: some View {
        // One row: when it happened. The picker and time zone open on tap.
        Section {
            DisclosureGroup(isExpanded: $isShowingOptionalDetails) {
                LabeledContent("quick_log.time_zone") {
                    Text(verbatim: userActionTimeContext.displayName(at: occurredAt))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                DatePicker(
                    "quick_log.date",
                    selection: Binding(
                        get: { occurredAt },
                        set: { newDate in
                            cancelSmartParsing()
                            smartState.edited(.date)
                            cancelOnDeviceAssistance()
                            occurredAt = newDate
                            dateWasEdited = true
                            invalidateCaptureSuggestions()
                            persistUserDraftChange { snapshot in
                                snapshot.occurredAt = newDate
                                snapshot.dateWasEdited = true
                            }
                        }
                    ),
                    displayedComponents: [.date, .hourAndMinute]
                )
                Text("quick_log.time_zone_detail")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } label: {
                LabeledContent("quick_log.occurred_at") {
                    Text(
                        occurredAt.formattedForReporting(
                            .dateTime.month().day().hour().minute(),
                            calendar: captureCalendar
                        )
                    )
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// One row: describe in words, or scan. The fill arrow appears only once
    /// there is something to fill; the scan glyph takes its place otherwise.
    var smartEntrySection: some View {
        let hasSmartText = !smartText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Section {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                TextField(
                    "quick_log.smart_placeholder",
                    text: trackedBinding(
                        $smartText,
                        \.smartText,
                        refreshesOccurrenceDate: true
                    ),
                    axis: .vertical
                )
                    .lineLimit(1...3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focused($focusedField, equals: .smartEntry)
                    .id(QuickLogFieldFocus.smartEntry)
                    .accessibilityIdentifier("quick-log-smart-input")
                    .moneyUpPrivateAmountInput(
                        masked: hidesAmounts && focusedField != .smartEntry && !smartText.isEmpty,
                        accessibilityLabel: Text("quick_log.smart_entry")
                    ) { focusedField = .smartEntry }
                if hasSmartText {
                    Button { applyTypedPhrase() } label: {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.title2)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("quick_log.smart_fill")
                    .accessibilityIdentifier("quick-log-smart-fill")
                } else {
                    Button { isPresentingReceiptPicker = true } label: {
                        Image(systemName: MoneyUpEntryGlyph.receipt)
                            .font(.title3)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isScanning)
                    .accessibilityLabel("quick_log.scan_receipt")
                    .accessibilityIdentifier("quick-log-scan-receipt")
                }
                Menu { merchantLearningControl } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 32, minHeight: 44)
                }
                .accessibilityLabel("quick_log.suggestion_options")
            }
            .accessibilityHint("quick_log.smart_footer")
            .photosPicker(
                isPresented: $isPresentingReceiptPicker,
                selection: $photoItem,
                matching: .images
            )

            if batch == nil, smartText.contains(where: \.isNewline), !dismissAfterSave {
                Button("quick_log.batch.start") { startBatchReview() }
                    .disabled(isParsingSmartEntry)
                    .accessibilityIdentifier("quick-log-start-batch")
            }

            if isParsingSmartEntry {
                Label("quick_log.parsing", systemImage: "ellipsis")
                    .foregroundStyle(.secondary)
            }
            if smartState.hasPreview { smartReviewSummary }

            if isScanning {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("quick_log.scanning").foregroundStyle(.secondary)
                }
            }

            if let smartMessage {
                Text(smartMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let onDeviceAssistance {
                onDeviceAssistanceCard(onDeviceAssistance)
            }

            if let receiptResult {
                receiptSuggestions(receiptResult)
            }

            if let captureSuggestionResult,
               (!accountWasEdited && !smartState.manualFields.contains(.account)
                    && !smartState.automaticFields.contains(.account) && captureSuggestionResult.accountSuggestion != nil
                    && captureSuggestionResult.accountSuggestion?.ledgerAccountID != accountID)
                || (splitLines.isEmpty && !categoryWasEdited && !smartState.manualFields.contains(.category)
                    && !smartState.automaticFields.contains(.category) && captureSuggestionResult.categorySuggestion != nil
                    && captureSuggestionResult.categorySuggestion?.ledgerAccountID != categoryID) {
                captureSuggestions(captureSuggestionResult)
            }

            if receiptAttachmentData != nil {
                Toggle("quick_log.keep_receipt", isOn: $retainReceiptAttachment)
                    .accessibilityHint("quick_log.keep_receipt_hint")
                Text("quick_log.keep_receipt_detail")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let receiptRetentionMessage {
                Text(receiptRetentionMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    func kindPicker<Style: PickerStyle>(style: Style) -> some View {
        Picker(
            "transaction.kind",
            selection: trackedBinding($kind, \.kind)
        ) {
            ForEach(QuickLogKind.allCases) { item in
                Text(item.title).tag(item)
            }
        }
        .pickerStyle(style)
    }

    @ViewBuilder
    var splitEditor: some View {
        Menu {
            Button {
                applyEqualSplit()
            } label: {
                Label("quick_log.split_equal", systemImage: "equal.circle")
            }
            Button {
                rebalanceUnlockedSplits()
            } label: {
                Label("quick_log.split_balance_unlocked", systemImage: "scale.3d")
            }
            if splitLines.count == 2 {
                Button("quick_log.split_50_50") {
                    applyPercentageSplit([50, 50])
                }
                Button("quick_log.split_60_40") {
                    applyPercentageSplit([60, 40])
                }
                Button("quick_log.split_70_30") {
                    applyPercentageSplit([70, 30])
                }
            }
        } label: {
            Label("quick_log.split_assistant", systemImage: "wand.and.stars")
        }
        .disabled(amount == nil || selectedAccountCurrency == nil)

        ForEach(Array(splitLines.enumerated()), id: \.element.id) { index, line in
            let lineID = line.id
            let lineValidationMessage = monetaryInputError(
                text: line.amountText,
                currency: selectedAccountCurrency
            )
            let masksLineAmount = hidesAmounts
                && focusedField != .splitAmount(lineID)
                && !line.amountText.isEmpty
            let amountAccessibilityLabel = String(
                format: AppLocalization.string("quick_log.split_amount_numbered"),
                index + 1
            )
            VStack(alignment: .leading, spacing: 8) {
                Picker(
                    "quick_log.split_category",
                    selection: Binding(
                        get: {
                            splitLines.first(where: { $0.id == lineID })?.categoryID
                        },
                        set: { value in
                            updateSplitLine(lineID) { $0.categoryID = value }
                        }
                    )
                ) {
                    ForEach(categories) { category in
                        Text(model.categoryPathName(for: category.id))
                            .tag(Optional(category.id))
                    }
                }
                .accessibilityLabel(
                    Text(
                        String(
                            format: AppLocalization.string("quick_log.split_category_numbered"),
                            index + 1
                        )
                    )
                )

                HStack {
                    TextField(
                        "quick_log.split_amount",
                        text: Binding(
                            get: {
                                splitLines.first(where: { $0.id == lineID })?
                                    .amountText ?? ""
                            },
                            set: { value in
                                updateSplitLine(lineID) { $0.amountText = value }
                            }
                        )
                    )
                    .moneyAmountKeyboard(currency: selectedAccountCurrency)
                    .focused($focusedField, equals: .splitAmount(lineID))
                    .id(QuickLogFieldFocus.splitAmount(lineID))
                    .moneyUpFieldValidation(lineValidationMessage)
                    .accessibilityLabel(Text(amountAccessibilityLabel))
                    .moneyUpPrivateAmountInput(
                        masked: masksLineAmount,
                        accessibilityLabel: Text(amountAccessibilityLabel)
                    ) {
                        focusedField = .splitAmount(lineID)
                    }
                    if let currency = selectedAccountCurrency {
                        Text(currency.value).foregroundStyle(.secondary)
                    }
                    Button {
                        updateSplitLine(lineID) { $0.isLocked.toggle() }
                    } label: {
                        Image(systemName: line.isLocked ? "lock.fill" : "lock.open")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(line.isLocked ? Color.accentColor : Color.secondary)
                    .accessibilityLabel(
                        line.isLocked
                            ? Text("quick_log.split_unlock")
                            : Text("quick_log.split_lock")
                    )
                    if splitLines.count > 2 {
                        Button(role: .destructive) {
                            removeSplitLine(lineID)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel(
                            Text(
                                String(
                                    format: AppLocalization.string(
                                        "quick_log.split_remove_numbered"
                                    ),
                                    index + 1
                                )
                            )
                        )
                    }
                }
                if let lineValidationMessage {
                    MoneyUpFieldError(message: lineValidationMessage)
                }

                TextField(
                    "quick_log.split_memo",
                    text: Binding(
                        get: {
                            splitLines.first(where: { $0.id == lineID })?.memo ?? ""
                        },
                        set: { value in
                            updateSplitLine(lineID) { $0.memo = value }
                        }
                    )
                )
                .font(.caption)
                .focused($focusedField, equals: .splitMemo(lineID))
                .id(QuickLogFieldFocus.splitMemo(lineID))
                .accessibilityLabel(
                    Text(
                        String(
                            format: AppLocalization.string("quick_log.split_memo_numbered"),
                            index + 1
                        )
                    )
                )
            }
            .padding(.vertical, 4)
        }

        Button {
            smartState.edited(.splits)
            splitLines.append(
                QuickLogSplitDraftLine(categoryID: categoryID ?? categories.first?.id)
            )
            persistUserDraftChange { $0.splitLines = splitLines }
        } label: {
            Label("quick_log.split_add", systemImage: "plus.circle")
        }
        .disabled(splitLines.count >= QuickLogDraft.maximumSplitLineCount)

        if let remainder = splitRemainder, let currency = selectedAccountCurrency {
            LabeledContent("quick_log.split_remainder") {
                Text(
                    "\(MoneyAmountPrivacy.protected(editableAmount(remainder))) "
                        + currency.value
                )
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(remainder == .zero ? Color.moneyUpPositive : Color.moneyUpDanger)
            }
            .accessibilityHint(
                remainder == .zero
                    ? Text("quick_log.split_balanced")
                    : Text("quick_log.split_not_balanced")
            )
        }
    }

}

/// Most-used categories first, from the recent entries already in memory, so
/// the chips under the amount are usually the one a person wants. Ties keep
/// the book's own order. The current choice is always present but never
/// moved, so chips do not shift under a finger as selection changes.
enum QuickLogCategoryRanking {
    static func ranked(
        choices rawChoices: [LedgerAccount],
        recentEntries: [JournalEntry],
        selected: UUID?,
        limit: Int
    ) -> [LedgerAccount] {
        // A real book can hold the same account record twice; every other
        // account table in the app keeps the first, and so does this one.
        var seen = Set<UUID>()
        let choices = rawChoices.filter { seen.insert($0.id).inserted }
        let parents = Set(choices.compactMap(\.parentID))
        var counts: [UUID: Int] = [:]
        for entry in recentEntries {
            for posting in entry.postings where seen.contains(posting.accountID) {
                counts[posting.accountID, default: 0] += 1
            }
        }
        let order = Dictionary(
            choices.enumerated().map { ($1.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // A group with children is a heading, not somewhere money usually
        // lands; it appears only once it has actually been used.
        let candidates = choices.filter { !parents.contains($0.id) || counts[$0.id] != nil }
        let sorted = candidates.sorted {
            let left = counts[$0.id] ?? 0
            let right = counts[$1.id] ?? 0
            return left != right ? left > right : (order[$0.id] ?? 0) < (order[$1.id] ?? 0)
        }
        var result = Array(sorted.prefix(limit))
        if let selected, !result.contains(where: { $0.id == selected }),
           let chosen = choices.first(where: { $0.id == selected }) {
            if result.count >= limit { result.removeLast() }
            result.append(chosen)
        }
        return result
    }
}

extension QuickLogEntryView {
    /// Where this entry goes, kept beside the amount so it stays visible above
    /// the keyboard. It is a concrete view on purpose: an inline `@ViewBuilder`
    /// here splices the whole bar's generic type into the Log form's type,
    /// which a real iPhone's main-thread stack cannot decode (0.7.2 1064.1).
    var quickRouteBar: QuickLogRouteBar {
        QuickLogRouteBar(
            kind: kind,
            isSplit: !splitLines.isEmpty,
            sourceAccounts: sourceAccounts,
            destinationAccounts: recordingAccounts.filter { $0.id != accountID },
            categories: categories,
            limit: dynamicTypeSize.isAccessibilitySize ? 3 : 5,
            category: trackedBinding($categoryID, \.categoryID, onUserEdit: {
                categoryWasEdited = true
                autoAppliedCategorySuggestionID = nil
            }),
            account: trackedBinding($accountID, \.accountID, onUserEdit: {
                accountWasEdited = true
                autoAppliedAccountSuggestionID = nil
                invalidateCaptureSuggestions(preservingAccount: true)
            }),
            destination: trackedBinding($destinationAccountID, \.destinationAccountID, onUserEdit: {
                accountWasEdited = true
            })
        )
    }
}

/// The paying account, then the likeliest categories as one-tap glyph chips.
/// Selection goes through the same tracked bindings as the full pickers
/// further down, so drafts and smart entry behave the same.
struct QuickLogRouteBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.moneyUpReduceMotion) private var reduceMotion
    let kind: QuickLogKind
    let isSplit: Bool
    let sourceAccounts: [LedgerAccount]
    let destinationAccounts: [LedgerAccount]
    let categories: [LedgerAccount]
    let limit: Int
    let category: Binding<UUID?>
    let account: Binding<UUID?>
    let destination: Binding<UUID?>

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                QuickLogAccountChip(selection: account, choices: sourceAccounts, label: "transaction.account")
                trailing
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quick-log-route-bar")
    }

    @ViewBuilder
    private var trailing: some View {
        if kind == .transfer {
            Image(systemName: "arrow.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            QuickLogAccountChip(selection: destination, choices: destinationAccounts, label: "transaction.to_account")
        } else if isSplit {
            Label("flow.split_categories", systemImage: "square.split.2x1")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
        } else {
            Divider().frame(height: 24)
            ForEach(QuickLogCategoryRanking.ranked(
                choices: categories, recentEntries: model.entries,
                selected: category.wrappedValue, limit: limit
            )) { choice in
                QuickLogCategoryChip(
                    category: choice,
                    isSelected: category.wrappedValue == choice.id,
                    select: {
                        withAnimation(MoneyUpMotion.animation(for: .selection, reduceMotion: reduceMotion)) {
                            category.wrappedValue = choice.id
                        }
                    }
                )
            }
            QuickLogAllCategoriesMenu(selection: category, categories: categories)
        }
    }
}

/// Only the chosen chip spells its name; the others are glyphs so five or
/// six choices fit in view. Each keeps its full path for VoiceOver.
struct QuickLogCategoryChip: View {
    @Environment(AppModel.self) private var model
    let category: LedgerAccount
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        let tint = MoneyUpCategorySymbol.tint(for: category.id)
        Button(action: select) {
            HStack(spacing: 6) {
                MoneyUpCategoryBadge(
                    systemImage: MoneyUpCategorySymbol.symbol(for: category.id, accountsByID: model.accountsByID),
                    tint: tint,
                    size: isSelected ? 28 : 34
                )
                if isSelected {
                    Text(category.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
            .padding(.leading, isSelected ? 6 : 5)
            .padding(.trailing, isSelected ? 12 : 5)
            .frame(minWidth: 44, minHeight: 44)
            .background(isSelected ? tint.opacity(0.16) : Color.primary.opacity(0.05), in: Capsule())
            .overlay { Capsule().stroke(isSelected ? tint : .clear, lineWidth: 1.5) }
            .contentShape(Capsule())
        }
        .buttonStyle(MoneyUpPressableButtonStyle())
        .foregroundStyle(.primary)
        .accessibilityLabel(model.categoryPathName(for: category.id))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct QuickLogAllCategoriesMenu: View {
    @Environment(AppModel.self) private var model
    let selection: Binding<UUID?>
    let categories: [LedgerAccount]

    var body: some View {
        Menu {
            Picker("transaction.category", selection: selection) {
                ForEach(uniqueCategories) { category in
                    Label(
                        model.categoryPathName(for: category.id),
                        systemImage: MoneyUpCategorySymbol.symbol(for: category.id, accountsByID: model.accountsByID)
                    )
                    .tag(Optional(category.id))
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline.weight(.bold))
                .frame(width: 44, height: 44)
                .background(Color.primary.opacity(0.05), in: Circle())
        }
        .accessibilityLabel("quick_log.more_categories")
    }

    private var uniqueCategories: [LedgerAccount] {
        var seen = Set<UUID>()
        return categories.filter { seen.insert($0.id).inserted }
    }
}

struct QuickLogAccountChip: View {
    let selection: Binding<UUID?>
    let choices: [LedgerAccount]
    let label: LocalizedStringKey

    var body: some View {
        let selected = choices.first { $0.id == selection.wrappedValue }
        Menu {
            Picker(label, selection: selection) {
                ForEach(uniqueChoices) { account in
                    Label(
                        accountCurrencyLabel(account),
                        systemImage: account.accountType?.systemImage ?? "wallet.bifold"
                    )
                    .tag(Optional(account.id))
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selected?.accountType?.systemImage ?? "wallet.bifold")
                    .font(.subheadline.weight(.semibold))
                Text(selected?.name ?? AppLocalization.string("quick_log.choose_account"))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .foregroundStyle(selected == nil ? Color.moneyUpWarning : Color.accentColor)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Color.accentColor.opacity(0.10), in: Capsule())
        }
        .accessibilityLabel(label)
        .accessibilityValue(selected.map(accountCurrencyLabel) ?? "")
    }

    private var uniqueChoices: [LedgerAccount] {
        var seen = Set<UUID>()
        return choices.filter { seen.insert($0.id).inserted }
    }
}
