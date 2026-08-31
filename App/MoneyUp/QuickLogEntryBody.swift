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
        NavigationStack {
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
                        if let currency = selectedAccountCurrency {
                            Text(currency.value)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("transaction.currency")
                                .accessibilityValue(Text(currency.value))
                        }
                    }
                    if let message = monetaryInputError(
                        text: amountText,
                        currency: selectedAccountCurrency
                    ) {
                        Label(message, systemImage: "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityAddTraits(.isStaticText)
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
                            Text(account.name).tag(Optional(account.id))
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
                                Text(account.name).tag(Optional(account.id))
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
                                if let currency = selectedDestinationCurrency {
                                    Text(currency.value)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let message = monetaryInputError(
                                text: destinationAmountText,
                                currency: selectedDestinationCurrency
                            ) {
                                Label(message, systemImage: "exclamationmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .accessibilityAddTraits(.isStaticText)
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
                                            format: String(localized: "fx.use_estimate_format"),
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
                                    Text(category.name).tag(Optional(category.id))
                                }
                            }
                        } else {
                            splitEditor
                        }
                    }
                }

                if kind != .transfer {
                    smartEntrySection
                }

                Section {
                    DisclosureGroup(
                        "quick_log.optional_details",
                        isExpanded: $isShowingOptionalDetails
                    ) {
                        DatePicker(
                            "quick_log.date",
                            selection: Binding(
                                get: { occurredAt },
                                set: { newDate in
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

                        if kind != .transfer {
                            TextField(
                                "transaction.payee",
                                text: trackedBinding(
                                    $payee,
                                    \.payee,
                                    refreshesOccurrenceDate: true,
                                    onUserEdit: {
                                        invalidateCaptureSuggestions()
                                    }
                                )
                            )
                            .focused($focusedField, equals: .payee)
                        }
                        TextField(
                            "quick_log.note",
                            text: trackedBinding(
                                $note,
                                \.note,
                                refreshesOccurrenceDate: true
                            ),
                            axis: .vertical
                        )
                            .lineLimit(2...4)
                            .focused($focusedField, equals: .note)
                    }
                }

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
                if !newValue {
                    cancelReceiptProcessing()
                    pendingDuplicateReview = nil
                    receiptAttachmentData = nil
                    retainReceiptAttachment = false
                    receiptRetentionMessage = nil
                    isPresentingReceiptPicker = false
                    dismissKeyboard()
                    isHandlingFocusedLaunch = false
                } else if amountText.isEmpty {
                    refreshUntouchedOccurrenceDate()
                    focusedField = .amount
                }
            }
            .onChange(of: kind) { _, newKind in
                if preservesCaptureSuggestionsAcrossNextKindChange {
                    preservesCaptureSuggestionsAcrossNextKindChange = false
                } else {
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
            .onChange(of: requestSequence) { _, _ in
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
                guard let item, isActive else {
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
                    await scanReceipt(item, generation: generation)
                }
            }
            .onChange(of: accountID) { _, _ in
                if destinationAccountID == accountID {
                    destinationAccountID = model.userAccounts.first { $0.id != accountID }?.id
                }
            }
            .onChange(of: draftSnapshot) { _, snapshot in
                guard hasRestoredDraft, !dismissAfterSave else { return }
                model.updateQuickLogDraft(snapshot)
            }
            .onDisappear {
                cancelReceiptProcessing()
                receiptScanTask = nil
                photoItem = nil
                pendingDuplicateReview = nil
                receiptAttachmentData = nil
                retainReceiptAttachment = false
                receiptRetentionMessage = nil
                isPresentingReceiptPicker = false
            }
            .scrollDismissesKeyboard(.interactively)
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
                    QuickLogMotionPolicy.animatesSavedFeedback(
                        reduceMotion: accessibilityReduceMotion
                    )
                        ? .move(edge: .bottom).combined(with: .opacity)
                        : .identity
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
        .sensoryFeedback(.success, trigger: successFeedback)
        .interactiveDismissDisabled(isSaving)
        .presentationDetents([.large])
        .confirmationDialog(
            "quick_log.unfinished_title",
            isPresented: $isConfirmingDraftSwitch,
            titleVisibility: .visible
        ) {
            Button("quick_log.resume_draft") {
                if let mode = pendingLaunchMode {
                    onRequestHandled(mode)
                }
                pendingLaunchMode = nil
                isHandlingFocusedLaunch = false
                focusedField = .amount
            }
            Button("quick_log.start_new", role: .destructive) {
                guard let mode = pendingLaunchMode else { return }
                pendingLaunchMode = nil
                discardDraftAndLaunch(mode)
                onRequestHandled(mode)
            }
            Button("action.cancel", role: .cancel) {
                if let mode = pendingLaunchMode {
                    onRequestHandled(mode)
                }
                pendingLaunchMode = nil
            }
        } message: {
            Text("quick_log.unfinished_detail")
        }
        .onChange(of: isConfirmingDraftSwitch) { wasPresented, isPresented in
            guard wasPresented, !isPresented,
                  let mode = pendingLaunchMode else { return }
            // Tapping outside the system dialog is also a cancellation. Ack it
            // so the same external request cannot remain stuck indefinitely.
            pendingLaunchMode = nil
            onRequestHandled(mode)
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
        .alert("error.could_not_save", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("action.okay", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .environment(\.calendar, model.reportingCalendar)
        .environment(\.timeZone, model.reportingCalendar.timeZone)
    }
}
