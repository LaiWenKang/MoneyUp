import Foundation
import MoneyUpCore
import SwiftUI

extension QuickLogEntryView {
    var quickLogBatchDialogs: some View {
        quickLogBase
        .confirmationDialog(
            "quick_log.batch.remove_title",
            isPresented: Binding(get: { pendingBatchRemoval != nil }, set: { if !$0 { pendingBatchRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("quick_log.batch.remove", role: .destructive) {
                guard let expected = pendingBatchRemoval else { return }
                pendingBatchRemoval = nil
                Task { await removeBatchItem(expected) }
            }
            Button("action.cancel", role: .cancel) { pendingBatchRemoval = nil }
        } message: { Text("quick_log.batch.remove_detail") }
    }

    var canSwitchBatchItem: Bool {
        !isSaving && !isUndoing && !isClearingDraft && !isCheckingDuplicates
            && !isParsingSmartEntry && !isPreparingEvidence && !isScanning
            && attachmentDrafts.isEmpty && receiptAttachmentData == nil
    }

    func startBatchReview() {
        guard !isSaving, !isUndoing, !isClearingDraft, !isCheckingDuplicates, !isParsingSmartEntry else { return }
        guard !MoneyUpKeyboard.hasMarkedText else { smartMessage = AppLocalization.string("quick_log.finish_composition"); return }
        let original = draftSnapshot
        guard !dismissAfterSave, QuickLogBatchPreparation.canReplaceTextOnlyDraft(original),
              attachmentDrafts.isEmpty, receiptAttachmentData == nil else {
            smartMessage = AppLocalization.string("quick_log.batch.finish_current")
            return
        }
        cancelSmartParsing()
        cancelReceiptProcessing()
        cancelCaptureSuggestionLookup()
        cancelOnDeviceAssistance()
        let accountSnapshot = model.accounts
        let reference = original.smartState.referenceDate ?? original.occurredAt
        let calendar = captureCalendar
        let locale = Locale.current
        let dayFirst = Self.localePrefersDayFirst
        let bookRevision = model.logicalBookRevision
        let request = smartParseRequestID
        isParsingSmartEntry = true
        let worker = Task.detached(priority: .userInitiated) {
            try QuickLogBatchPreparation.prepare(original, accounts: accountSnapshot,
                now: reference, calendar: calendar, locale: locale, dayFirst: dayFirst)
        }
        smartParseTask = Task { @MainActor in
            defer { if request == smartParseRequestID { isParsingSmartEntry = false; smartParseTask = nil } }
            do {
                let prepared = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, request == smartParseRequestID, isActive,
                      bookRevision == model.logicalBookRevision, accountSnapshot == model.accounts,
                      draftSnapshot == original else { return }
                isClearingDraft = true
                defer { isClearingDraft = false }
                try await model.beginQuickLogBatch(prepared, replacing: original)
                clearPerTransactionReviewState()
                applyDraft(prepared)
                selectDefaults()
                dismissKeyboard()
            } catch is CancellationError { return }
            catch is SmartEntryBatchTextError { smartMessage = AppLocalization.string("quick_log.batch.line_rules") }
            catch { errorMessage = safeUserMessage(for: error, context: .save) }
        }
    }

    func selectBatchItem(_ id: UUID) async {
        guard canSwitchBatchItem, !MoneyUpKeyboard.hasMarkedText else { return }
        let expected = draftSnapshot
        isClearingDraft = true
        defer { isClearingDraft = false }
        cancelSmartParsing()
        dismissKeyboard()
        do {
            try await model.selectQuickLogBatchItem(id, replacing: expected)
            clearPerTransactionReviewState()
            clearedEvidence = nil
            if let current = model.quickLogDraft { applyDraft(current) }
            selectDefaults()
        } catch { errorMessage = safeUserMessage(for: error, context: .save) }
    }

    func removeBatchItem(_ expected: QuickLogDraft) async {
        guard draftSnapshot == expected, canSwitchBatchItem else { return }
        isClearingDraft = true
        defer { isClearingDraft = false }
        cancelSmartParsing()
        do {
            try await model.removeQuickLogBatchItem(replacing: expected)
            clearPerTransactionReviewState()
            clearedEvidence = nil
            if let current = model.quickLogDraft { applyDraft(current) }
            selectDefaults()
        } catch { errorMessage = safeUserMessage(for: error, context: .save) }
    }

    @ViewBuilder
    var batchReviewControls: some View {
        if let batch, let index = batch.selectedIndex {
            let controls = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout())
            Section {
                Text(String(format: AppLocalization.string("quick_log.batch.progress"),
                    batch.selectedOrdinal, batch.totalCount, batch.items.count))
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("quick-log-batch-progress")
                controls {
                    Button("quick_log.batch.previous") {
                        guard index > 0 else { return }
                        Task { await selectBatchItem(batch.items[index - 1].id) }
                    }.disabled(index == 0 || !canSwitchBatchItem)
                    if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                    Menu {
                        ForEach(batch.items) { item in
                            Button(String(format: AppLocalization.string("quick_log.batch.item"), item.ordinal)) {
                                Task { await selectBatchItem(item.id) }
                            }
                        }
                        Button("quick_log.batch.remove", role: .destructive) { pendingBatchRemoval = draftSnapshot }
                    } label: { Label("quick_log.batch.review", systemImage: "list.number") }
                    .disabled(!canSwitchBatchItem)
                    if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                    Button("quick_log.batch.next") {
                        guard index + 1 < batch.items.count else { return }
                        Task { await selectBatchItem(batch.items[index + 1].id) }
                    }.disabled(index + 1 == batch.items.count || !canSwitchBatchItem)
                }
                if !attachmentDrafts.isEmpty || receiptAttachmentData != nil {
                    Text("quick_log.batch.finish_attachments").font(.caption).foregroundStyle(.secondary)
                }
            } footer: { Text("quick_log.batch.save_one") }
        }
    }
}
