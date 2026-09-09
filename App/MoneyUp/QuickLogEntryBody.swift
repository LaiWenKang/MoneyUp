import Foundation
import MoneyUpCore
import OSLog
import PhotosUI
import SwiftUI
import UIKit

extension QuickLogEntryView {
    var body: some View {
        quickLogPresentation
    }

    private var quickLogNavigation: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                quickLogForm(scrollProxy: scrollProxy)
            }
        }
    }

    @ViewBuilder
    var quickLogFormContent: some View {
        let historicalFXConversionResult = historicalFXConversion
        Form {
                if dynamicTypeSize.isAccessibilitySize {
                    kindPicker(style: .menu)
                } else {
                    kindPicker(style: .segmented)
                }

                Section { primaryAmountControl }

                if kind != .transfer { smartEntrySection }

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


                Section {
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
                        ForEach(sourceAccounts) { account in
                            Text(accountCurrencyLabel(account)).tag(Optional(account.id))
                        }
                    }

                    if kind == .transfer {
                        Picker(
                            "transaction.to_account",
                            selection: trackedBinding(
                                $destinationAccountID,
                                \.destinationAccountID,
                                onUserEdit: { accountWasEdited = true }
                            )
                        ) {
                            ForEach(model.userAccounts.filter { $0.id != accountID }) { account in
                                Text(accountCurrencyLabel(account)).tag(Optional(account.id))
                            }
                        }
                        if isForeignCurrencyTransfer {
                            destinationAmountControl

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
                                            MoneyAmountPrivacy.protected(
                                                NSDecimalNumber(
                                                    decimal: conversion.converted.amount
                                                ).stringValue
                                            ),
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
                } footer: {
                    MoneyUpEntryRoutePreview(
                        kind: kind,
                        account: selectedSourceAccount?.name,
                        destination: model.userAccounts.first { $0.id == destinationAccountID }?.name,
                        category: splitLines.isEmpty
                            ? categoryID.map { model.categoryPathName(for: $0) }
                            : AppLocalization.string("flow.split_categories")
                    )
                }


                occurrenceSection

                evidenceSection

                if model.userAccounts.isEmpty {
                    Section {
                        Button("account.add") { isAddingAccount = true }
                        Text("transaction.no_accounts")
                            .foregroundStyle(.secondary)
                    }
                } else if kind == .transfer
                            && (sourceAccounts.isEmpty || model.userAccounts.count < 2) {
                    Section {
                        Button("account.add") { isAddingAccount = true }
                        Text("transaction.need_two_accounts")
                            .foregroundStyle(.secondary)
                    }
                }

        }
    }

    private func quickLogForm(scrollProxy: ScrollViewProxy) -> some View {
        quickLogFinalForm(scrollProxy: scrollProxy)
    }

    private var quickLogPrimaryLifecycle: some View {
        quickLogFormChrome
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
            .onChange(of: model.quickLogPreparationRevision) { _, _ in
                cancelReceiptProcessing()
                restoreDraftIfAvailable()
                selectDefaults()
            }
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
    }

    private var quickLogReceiptLifecycle: some View {
        quickLogPrimaryLifecycle
            .onChange(of: launchRequest) { _, _ in
                handleRequestedLaunch()
            }
            .onChange(of: isCheckingDuplicates) { _, checking in
                if !checking { handleRequestedLaunch() }
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
                receiptProtectedFields = QuickLogReceiptPrefillPolicy.protectedFields(
                    draft: draftSnapshot,
                    accountWasEdited: accountWasEdited,
                    categoryWasEdited: categoryWasEdited
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
    }

    private func quickLogFocusLifecycle(scrollProxy: ScrollViewProxy) -> some View {
        quickLogReceiptLifecycle
            .onChange(of: evidencePhotoItems) { _, items in
                guard !items.isEmpty else { return }
                evidencePreparationTask?.cancel()
                evidencePreparationTask = Task { @MainActor in
                    await addEvidencePhotos(items)
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
                withAnimation(MoneyUpMotion.animation(for: .stateChange, reduceMotion: accessibilityReduceMotion)) {
                    scrollProxy.scrollTo(field, anchor: .center)
                }
                Task { @MainActor in
                    try? await Task.sleep(
                        nanoseconds: QuickLogFocusScrollPolicy.layoutSettlingNanoseconds)
                    guard focusedField == field else { return }
                    withAnimation(MoneyUpMotion.animation(for: .stateChange, reduceMotion: accessibilityReduceMotion)) {
                        scrollProxy.scrollTo(field, anchor: .center)
                    }
                }
            }
    }

    private func quickLogFinalForm(scrollProxy: ScrollViewProxy) -> some View {
        quickLogFocusLifecycle(scrollProxy: scrollProxy)
            .onDisappear {
                cancelReceiptProcessing()
                cancelCaptureSuggestionLookup()
                cancelOnDeviceAssistance()
                receiptScanTask = nil
                evidencePreparationTask?.cancel()
                evidencePreparationTask = nil
                photoItem = nil
                pendingDuplicateReview = nil
                receiptAttachmentData = nil
                retainReceiptAttachment = false
                receiptRetentionMessage = nil
                isPresentingReceiptPicker = false
                isPresentingEvidencePhotoPicker = false
                isPresentingEvidencePDFPicker = false
            }
            .scrollDismissesKeyboard(.interactively)
            .contentMargins(.bottom, focusedField == nil ? 72 : 200, for: .scrollContent)
            .sheet(isPresented: $isAddingAccount, onDismiss: {
                selectDefaults()
                if isActive { focusedField = .amount }
            }) { AddAccountSheet() }
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

    private var quickLogBase: some View {
        quickLogNavigation
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
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
            }
                Button {
                    Task { await attemptSave() }
                } label: {
                    Label("action.save", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.moneyUpAction)
                .disabled(!canSave || isSaving || isUndoing || isPreparingEvidence || isClearingDraft)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background { Color.moneyUpBackground }
            }
        }
        .moneyUpFeedback(
            for: .financialCommit,
            trigger: successFeedback,
            visibleStatus: lastSavedEntryID != nil
        )
        .interactiveDismissDisabled(isSaving)
        .presentationDetents([.large])
    }

    private var quickLogDialogs: some View {
        quickLogBase
        .confirmationDialog(
            "quick_log.clear_title",
            isPresented: Binding(
                get: { pendingDraftClear != nil },
                set: { if !$0 { pendingDraftClear = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("quick_log.clear_entry", role: .destructive) {
                guard let expected = pendingDraftClear else { return }
                pendingDraftClear = nil
                Task { await clearConfirmedDraft(expected) }
            }
            Button("action.cancel", role: .cancel) { pendingDraftClear = nil }
        } message: {
            Text("quick_log.clear_detail")
        }
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
    }

    private var quickLogPresentation: some View {
        quickLogDialogs
        .moneyUpOperationErrorAlert(message: $errorMessage)
        .environment(\.calendar, captureCalendar)
        .environment(\.timeZone, captureCalendar.timeZone)
    }
}
