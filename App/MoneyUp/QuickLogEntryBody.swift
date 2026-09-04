import Foundation
import MoneyUpCore
import OSLog
import PhotosUI
import SwiftUI
import UIKit

extension QuickLogEntryView {
    @ViewBuilder
    var body: some View {
        let historicalFXConversionResult = historicalFXConversion
        let amountValidationMessage = monetaryInputError(
            text: amountText,
            currency: selectedAccountCurrency
        )
        let destinationAmountValidationMessage = monetaryInputError(
            text: destinationAmountText,
            currency: selectedDestinationCurrency
        )
        NavigationStack {
            ScrollViewReader { scrollProxy in
            Form {
                if dynamicTypeSize.isAccessibilitySize {
                    kindPicker(style: .menu)
                } else {
                    kindPicker(style: .segmented)
                }

                Section {
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

                    Picker(
                        kind == .transfer ? "transaction.from_account" : "transaction.account",
                        selection: trackedBinding(
                            $accountID,
                            \.accountID,
                            onUserEdit: {
                                accountWasEdited = true
                                autoAppliedAccountSuggestionID = nil
                                invalidateCaptureSuggestions(preservingAccount: true)
                            }
                        )
                    ) {
                        ForEach(model.userAccounts) { account in
                            Text(accountCurrencyLabel(account)).tag(Optional(account.id))
                        }
                    }

                    if kind == .transfer {
                        Picker(
                            "transaction.to_account",
                            selection: trackedBinding(
                                $destinationAccountID,
                                \.destinationAccountID
                            )
                        ) {
                            ForEach(model.userAccounts.filter { $0.id != accountID }) { account in
                                Text(accountCurrencyLabel(account)).tag(Optional(account.id))
                            }
                        }
                        if isForeignCurrencyTransfer {
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
                                if let currency = selectedDestinationCurrency {
                                    Text(currency.value)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let destinationAmountValidationMessage {
                                MoneyUpFieldError(message: destinationAmountValidationMessage)
                            }

                            if case let .available(.some(conversion)) =
                                historicalFXConversionResult {
                                Button {
                                    destinationAmountText = editableAmount(
                                        conversion.converted.amount
                                    )
                                    persistUserDraftChange { snapshot in
                                        snapshot.destinationAmountText = destinationAmountText
                                    }
                                } label: {
                                    Label(
                                        String(
                                            format: AppLocalization.string("fx.use_estimate_format"),
                                            conversion.converted.currency.value,
                                            NSDecimalNumber(
                                                decimal: conversion.converted.amount
                                            ).stringValue,
                                            conversion.effectiveDayKey
                                        ),
                                        systemImage: "function"
                                    )
                                }
                                .accessibilityHint("fx.estimate_accessibility_hint")
                            } else if case let .unavailable(issue) =
                                historicalFXConversionResult {
                                DerivedValueUnavailableView(issue: issue)
                            } else {
                                Label("fx.unconverted_mode", systemImage: "equal.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Toggle(
                            "quick_log.split_transaction",
                            isOn: Binding(
                                get: { !splitLines.isEmpty },
                                set: { enabled in
                                    cancelOnDeviceAssistance()
                                    if enabled {
                                        refreshUntouchedOccurrenceDate()
                                    }
                                    if enabled {
                                        let initialCategory = categoryID ?? categories.first?.id
                                        splitLines = [
                                            QuickLogSplitDraftLine(categoryID: initialCategory),
                                            QuickLogSplitDraftLine(categoryID: initialCategory)
                                        ]
                                    } else {
                                        clearSplitFocus()
                                        splitLines = []
                                    }
                                    persistUserDraftChange { snapshot in
                                        snapshot.splitLines = splitLines
                                    }
                                }
                            )
                        )

                        if splitLines.isEmpty {
                            Picker(
                                "transaction.category",
                                selection: trackedBinding(
                                    $categoryID,
                                    \.categoryID,
                                    onUserEdit: {
                                        categoryWasEdited = true
                                        autoAppliedCategorySuggestionID = nil
                                    }
                                )
                            ) {
                                ForEach(categories) { category in
                                    Text(model.categoryPathName(for: category.id))
                                        .tag(Optional(category.id))
                                }
                            }
                        } else {
                            splitEditor
                        }

                        categoryAndAllowanceControls
                    }
                }

                if kind != .transfer {
                    smartEntrySection
                }

                Section {
                    TextField(
                        "transaction.title_or_merchant",
                        text: trackedBinding(
                            $payee,
                            \.payee,
                            refreshesOccurrenceDate: true,
                            onUserEdit: {
                                refreshTypedPayeeSuggestion()
                            }
                        )
                    )
                    .focused($focusedField, equals: .payee)
                    .id(QuickLogFieldFocus.payee)

                    TextField(
                        "transaction.description_or_notes",
                        text: trackedBinding(
                            $note,
                            \.note,
                            refreshesOccurrenceDate: true
                        ),
                        axis: .vertical
                    )
                    .lineLimit(2...4)
                    .focused($focusedField, equals: .note)
                    .id(QuickLogFieldFocus.note)
                    .accessibilityIdentifier("quick-log-note")
                } header: {
                    Text("transaction.details")
                } footer: {
                    Text("transaction.details_help")
                }

                occurrenceSection

                if model.userAccounts.isEmpty {
                    Section {
                        Text("transaction.no_accounts")
                            .foregroundStyle(.secondary)
                    }
                } else if kind == .transfer && model.userAccounts.count < 2 {
                    Section {
                        Text("transaction.need_two_accounts")
                            .foregroundStyle(.secondary)
                    }
                }

            }
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .disabled(isSaving || isUndoing)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if dismissAfterSave {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("action.cancel") { dismiss() }
                            .disabled(isSaving)
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    if !dismissAfterSave {
                        Menu {
                            Button {
                                navigate(to: .today)
                            } label: {
                                Label("tab.today", systemImage: "house.fill")
                            }
                            Button {
                                navigate(to: .history(nil))
                            } label: {
                                Label("tab.history", systemImage: "clock.arrow.circlepath")
                            }
                            Button {
                                navigate(to: .plan)
                            } label: {
                                Label("tab.plan", systemImage: "chart.pie.fill")
                            }
                            Button {
                                navigate(to: .assets)
                            } label: {
                                Label("tab.assets", systemImage: "wallet.bifold.fill")
                            }
                        } label: {
                            Label("quick_log.switch_tab", systemImage: "square.grid.2x2")
                        }
                    }

                    Button {
                        Task { await attemptSave() }
                    } label: {
                        Label("action.save", systemImage: "checkmark.circle.fill")
                    }
                    .disabled(!canSave || isSaving || isUndoing)

                    Spacer()
                    Button {
                        dismissKeyboard()
                    } label: {
                        Label("action.done", systemImage: "keyboard.chevron.compact.down")
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                refreshUserActionTimeContext()
                restoreDraftIfAvailable()
                selectDefaults()
                hasRestoredDraft = true
                refreshUntouchedOccurrenceDate()
                handleRequestedLaunch()
                Task { @MainActor in
                    await Task.yield()
                    if isActive && amountText.isEmpty && !isHandlingFocusedLaunch {
                        focusedField = .amount
                    }
                }
            }
            .onChange(of: isActive) { _, newValue in
                handleActiveStateChange(newValue)
            }
            .onUserActionTimeChange(perform: refreshUserActionTimeContext)
            .onChange(of: model.logicalBookRevision) { _, _ in
                reloadDraftForLogicalBookReplacement()
            }
            .onChange(of: model.state) { _, state in
                guard state != .ready else { return }
                cancelReceiptProcessing()
                invalidateCaptureSuggestions(restoresDefaults: false)
            }
            .onChange(of: kind) { _, newKind in
                if preservesCaptureSuggestionsAcrossNextKindChange {
                    preservesCaptureSuggestionsAcrossNextKindChange = false
                } else {
                    cancelOnDeviceAssistance()
                    invalidateCaptureSuggestions(restoresDefaults: false)
                }
                pendingDuplicateReview = nil
                cancelReceiptProcessing()
                receiptResult = nil
                receiptAttachmentData = nil
                retainReceiptAttachment = false
                receiptRetentionMessage = nil
                if newKind == .transfer {
                    clearSplitFocus()
                    splitLines = []
                }
                if newKind != .expense {
                    selectedAllowanceID = nil
                }
                selectDefaults()
                if newKind != .transfer, !splitLines.isEmpty {
                    for index in splitLines.indices where !categories.contains(
                        where: { $0.id == splitLines[index].categoryID }
                    ) {
                        splitLines[index].categoryID = categories.first?.id
                    }
                }
                persistUserDraftChange { $0.splitLines = splitLines }
            }
            .onChange(of: launchRequest) { _, _ in
                handleRequestedLaunch()
            }
            .onChange(of: isSaving) { _, newValue in
                if !newValue { handleRequestedLaunch() }
            }
            .onChange(of: isScanning) { _, newValue in
                if !newValue { handleRequestedLaunch() }
            }
            .onChange(of: photoItem) { _, item in
                receiptScanGeneration &+= 1
                let generation = receiptScanGeneration
                receiptScanTask?.cancel()
                guard let item = QuickLogInputAuthority.receiptItemThatMayBegin(
                    item,
                    isActive: isActive,
                    cancelAssistance: { cancelOnDeviceAssistance() }
                ) else {
                    receiptScanTask = nil
                    receiptScanBaseline = nil
                    if !isActive {
                        photoItem = nil
                        receiptAttachmentData = nil
                        retainReceiptAttachment = false
                        receiptRetentionMessage = nil
                        isScanning = false
                    }
                    return
                }
                refreshUntouchedOccurrenceDate()
                receiptScanBaseline = ReceiptScanBaseline(
                    kind: kind,
                    amountText: amountText,
                    occurredAt: occurredAt,
                    dateWasEdited: dateWasEdited,
                    payee: payee,
                    note: note,
                    accountID: accountID,
                    categoryID: categoryID
                )
                isScanning = true
                smartMessage = nil
                receiptResult = nil
                invalidateCaptureSuggestions()
                pendingDuplicateReview = nil
                receiptAttachmentData = nil
                retainReceiptAttachment = false
                receiptRetentionMessage = nil
                receiptScanTask = Task { @MainActor in
                    await scanReceipt(
                        item,
                        generation: generation,
                        logicalBookRevision: model.logicalBookRevision
                    )
                }
            }
            .onChange(of: accountID) { _, _ in
                if destinationAccountID == accountID {
                    destinationAccountID = model.userAccounts.first { $0.id != accountID }?.id
                }
                if selectedAllowanceID != nil,
                   selectedAllowanceApplication == nil {
                    selectedAllowanceID = nil
                }
            }
            .onChange(of: draftSnapshot) { _, snapshot in
                guard hasRestoredDraft, !dismissAfterSave else { return }
                model.updateQuickLogDraft(snapshot)
            }
            .onChange(
                of: model.profile?.foundationModelAssistanceEnabled
            ) { _, enabled in
                if enabled != true { cancelOnDeviceAssistance() }
            }
            .onChange(of: focusedField) { _, field in
                guard let field = QuickLogFocusScrollPolicy.target(for: field) else {
                    return
                }
                withAnimation(.easeOut(duration: 0.2)) {
                    scrollProxy.scrollTo(field, anchor: .center)
                }
                Task { @MainActor in
                    try? await Task.sleep(
                        nanoseconds: QuickLogFocusScrollPolicy.layoutSettlingNanoseconds)
                    guard focusedField == field else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        scrollProxy.scrollTo(field, anchor: .center)
                    }
                }
            }
            .onDisappear {
                cancelReceiptProcessing()
                cancelCaptureSuggestionLookup()
                cancelOnDeviceAssistance()
                receiptScanTask = nil
                photoItem = nil
                pendingDuplicateReview = nil
                receiptAttachmentData = nil
                retainReceiptAttachment = false
                receiptRetentionMessage = nil
                isPresentingReceiptPicker = false
            }
            .scrollDismissesKeyboard(.interactively)
            .contentMargins(.bottom, focusedField == nil ? 72 : 200, for: .scrollContent)
            .sheet(isPresented: $isAddingCategory) {
                AddCategorySheet(kind: categoryKind) { categoryID in
                    cancelOnDeviceAssistance()
                    self.categoryID = categoryID
                    categoryWasEdited = true
                    autoAppliedCategorySuggestionID = nil
                    persistUserDraftChange { snapshot in
                        snapshot.categoryID = categoryID
                    }
                }
            }
            .sheet(isPresented: $isManagingCategories) { CategoryManagementList() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let lastSavedEntryID {
                HStack(spacing: 12) {
                    Label("quick_log.saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Button("action.undo") {
                        Task { await undo(entryID: lastSavedEntryID) }
                    }
                    .fontWeight(.semibold)
                    .disabled(isUndoing)
                    Button {
                        updateSavedEntry(nil)
                    } label: {
                        Image(systemName: "xmark")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("action.close")
                    .disabled(isUndoing)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
                .transition(
                    MoneyUpMotion.confirmationTransition(
                        reduceMotion: accessibilityReduceMotion
                    )
                )
            } else {
                Button {
                    Task { await attemptSave() }
                } label: {
                    Label("action.save", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.moneyUpAction)
                .disabled(!canSave || isSaving || isUndoing)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
        .moneyUpFeedback(
            for: .financialCommit,
            trigger: successFeedback,
            visibleStatus: lastSavedEntryID != nil
        )
        .interactiveDismissDisabled(isSaving)
        .presentationDetents([.large])
        .confirmationDialog(
            "quick_log.unfinished_title",
            isPresented: $isConfirmingDraftSwitch,
            titleVisibility: .visible
        ) {
            Button("quick_log.resume_draft") {
                if let request = pendingLaunchRequest {
                    onRequestHandled(request)
                }
                pendingLaunchRequest = nil
                isHandlingFocusedLaunch = false
                focusedField = .amount
            }
            Button("quick_log.start_new", role: .destructive) {
                guard let request = pendingLaunchRequest else { return }
                pendingLaunchRequest = nil
                discardDraftAndLaunch(request)
                onRequestHandled(request)
            }
            Button("action.cancel", role: .cancel) {
                if let request = pendingLaunchRequest {
                    onRequestHandled(request)
                }
                pendingLaunchRequest = nil
            }
        } message: {
            Text("quick_log.unfinished_detail")
        }
        .onChange(of: isConfirmingDraftSwitch) { wasPresented, isPresented in
            guard wasPresented, !isPresented,
                  let request = pendingLaunchRequest else { return }
            // Tapping outside the system dialog is also a cancellation. Ack it
            // so the same external request cannot remain stuck indefinitely.
            pendingLaunchRequest = nil
            onRequestHandled(request)
        }
        .confirmationDialog(
            "quick_log.duplicate_title",
            isPresented: Binding(
                get: { pendingDuplicateReview != nil },
                set: { if !$0 { pendingDuplicateReview = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("quick_log.duplicate_save_anyway") {
                guard let pending = pendingDuplicateReview else { return }
                pendingDuplicateReview = nil
                Task { await confirmDuplicateSave(pending) }
            }
            Button("quick_log.duplicate_review") {
                let matchDate = pendingDuplicateReview?.historyDate
                pendingDuplicateReview = nil
                if dismissAfterSave {
                    dismiss()
                } else {
                    navigate(to: .history(matchDate))
                }
            }
            Button("action.cancel", role: .cancel) {
                pendingDuplicateReview = nil
            }
        } message: {
            Text(duplicateReviewMessage)
        }
        .moneyUpOperationErrorAlert(message: $errorMessage)
        .environment(\.calendar, captureCalendar)
        .environment(\.timeZone, captureCalendar.timeZone)
    }

}
