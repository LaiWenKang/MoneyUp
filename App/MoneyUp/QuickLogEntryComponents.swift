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
        HStack {
            TextField(
                "quick_log.amount",
                text: trackedBinding(
                    $amountText,
                    \.amountText,
                    refreshesOccurrenceDate: true
                )
            )
            .moneyAmountKeyboard(currency: selectedAccountCurrency)
            .font(.title2.monospacedDigit())
            .focused($focusedField, equals: .amount)
            .id(QuickLogFieldFocus.amount)
            .moneyUpFieldValidation(amountValidationMessage)
            .moneyUpPrivateAmountInput(
                masked: masksPrimaryAmount,
                accessibilityLabel: Text("quick_log.amount"),
                placeholderFont: .title2.monospacedDigit()
            ) {
                focusedField = .amount
            }
            if let currency = selectedAccountCurrency {
                Text(currency.value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("transaction.currency")
                    .accessibilityValue(Text(currency.value))
            }
        }
        if let amountValidationMessage {
            MoneyUpFieldError(message: amountValidationMessage)
        }
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
        Section {
            LabeledContent("quick_log.occurred_at") {
                Text(
                    occurredAt.formattedForReporting(
                        .dateTime.month().day().hour().minute(),
                        calendar: captureCalendar
                    )
                )
                .foregroundStyle(.secondary)
            }
            LabeledContent("quick_log.time_zone") {
                Text(verbatim: userActionTimeContext.displayName(at: occurredAt))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup(
                "quick_log.date_and_time",
                isExpanded: $isShowingOptionalDetails
            ) {
                DatePicker(
                    "quick_log.date",
                    selection: Binding(
                        get: { occurredAt },
                        set: { newDate in
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
            }
        } footer: {
            Text("quick_log.time_zone_detail")
        }
    }

    var smartEntrySection: some View {
        Section {
            HStack(alignment: .top, spacing: 8) {
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
                    .focused($focusedField, equals: .smartEntry)
                    .id(QuickLogFieldFocus.smartEntry)
                Button("quick_log.smart_fill") { applyTypedPhrase() }
                    .buttonStyle(.borderless)
                    .disabled(
                        smartText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }

            Button {
                isPresentingReceiptPicker = true
            } label: {
                Label("quick_log.scan_receipt", systemImage: "doc.text.viewfinder")
            }
            .disabled(isScanning)
            .photosPicker(
                isPresented: $isPresentingReceiptPicker,
                selection: $photoItem,
                matching: .images
            )

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
               captureSuggestionResult.accountSuggestion != nil
                || (splitLines.isEmpty
                    && captureSuggestionResult.categorySuggestion != nil) {
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
        } header: {
            Text("quick_log.smart_entry")
        } footer: {
            Text("quick_log.smart_footer")
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
                    .foregroundStyle(remainder == .zero ? Color.green : Color.red)
            }
            .accessibilityHint(
                remainder == .zero
                    ? Text("quick_log.split_balanced")
                    : Text("quick_log.split_not_balanced")
            )
        }
    }

    func updateSplitLine(
        _ lineID: UUID,
        update: (inout QuickLogSplitDraftLine) -> Void
    ) {
        cancelOnDeviceAssistance()
        guard let index = splitLines.firstIndex(where: { $0.id == lineID }) else {
            return
        }
        update(&splitLines[index])
        persistUserDraftChange { $0.splitLines = splitLines }
    }

    func removeSplitLine(_ lineID: UUID) {
        cancelOnDeviceAssistance()
        clearSplitFocus(for: lineID)
        splitLines.removeAll { $0.id == lineID }
        persistUserDraftChange { $0.splitLines = splitLines }
    }

    func applyEqualSplit() {
        guard let amount,
              let currency = selectedAccountCurrency,
              let allocations = try? TransactionSplitCalculator.equalAmounts(
                total: Money(amount, currency: currency),
                count: splitLines.count
              ) else {
            errorMessage = AppLocalization.string("split.error.allocation")
            return
        }
        applySplitAllocations(allocations)
    }

    func rebalanceUnlockedSplits() {
        guard let amount,
              let currency = selectedAccountCurrency else { return }
        let current: [Money?] = splitLines.map { line in
            guard let value = decimalAmount(from: line.amountText) else { return nil }
            return try? Money(value, currency: currency)
        }
        guard let allocations = try? TransactionSplitCalculator.rebalancedAmounts(
            total: Money(amount, currency: currency),
            current: current,
            locked: splitLines.map(\.isLocked)
        ) else {
            errorMessage = AppLocalization.string("split.error.allocation")
            return
        }
        applySplitAllocations(allocations)
    }

    func applyPercentageSplit(_ percentages: [Decimal]) {
        guard let amount,
              let currency = selectedAccountCurrency,
              let allocations = try? TransactionSplitCalculator.percentageAmounts(
                total: Money(amount, currency: currency),
                percentages: percentages
              ) else {
            errorMessage = AppLocalization.string("split.error.allocation")
            return
        }
        applySplitAllocations(allocations)
    }

    func applySplitAllocations(_ allocations: [Money]) {
        guard allocations.count == splitLines.count else { return }
        for index in splitLines.indices {
            splitLines[index].amountText = editableAmount(allocations[index].amount)
        }
        errorMessage = nil
        persistUserDraftChange { $0.splitLines = splitLines }
    }
}
