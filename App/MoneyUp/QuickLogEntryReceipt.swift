import Foundation
import MoneyUpCore
import OSLog
import PhotosUI
import SwiftUI
import UIKit

extension QuickLogEntryView {
    func scanReceipt(
        _ item: PhotosPickerItem?,
        generation: Int
    ) async {
        guard let item else { return }
        let suggestionsSignpostID = Self.receiptSignposter.makeSignpostID()
        let suggestionsInterval = Self.receiptSignposter.beginInterval(
            "Receipt selection to suggestions",
            id: suggestionsSignpostID
        )
        var suggestionsIntervalEnded = false
        defer {
            if !suggestionsIntervalEnded {
                Self.receiptSignposter.endInterval(
                    "Receipt selection to suggestions",
                    suggestionsInterval,
                    "outcome=incomplete"
                )
            }
            if generation == receiptScanGeneration {
                isScanning = false
                receiptScanTask = nil
                receiptScanBaseline = nil
                photoItem = nil
            }
        }
        guard !Task.isCancelled,
              generation == receiptScanGeneration else { return }
        isScanning = true
        smartMessage = nil
        receiptResult = nil
        receiptAttachmentData = nil
        retainReceiptAttachment = false
        receiptRetentionMessage = nil

        do {
            try Task.checkCancellation()
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw ReceiptScannerError.unreadableImage
            }
            try Task.checkCancellation()
            guard generation == receiptScanGeneration else { return }
            try await ReceiptImageSanitizer.waitForPendingPreparation()
            try Task.checkCancellation()
            guard generation == receiptScanGeneration else { return }
            try await QuickLogReceiptPipeline.run {
                try await model.receiptAnalysis(
                    from: data,
                    prefersDayFirst: Self.localePrefersDayFirst
                )
            } handleSuggestions: { result in
                guard generation == receiptScanGeneration else { return false }
                let didApplySuggestions = applyReceipt(result)

                // Saving and editing can resume as soon as the OCR result is
                // handled. The optional attachment remains
                // unavailable until its private copy is ready.
                isScanning = false
                if didApplySuggestions {
                    Self.receiptSignposter.endInterval(
                        "Receipt selection to suggestions",
                        suggestionsInterval,
                        "outcome=ready"
                    )
                } else {
                    Self.receiptSignposter.endInterval(
                        "Receipt selection to suggestions",
                        suggestionsInterval,
                        "outcome=empty"
                    )
                }
                suggestionsIntervalEnded = true
                return true
            } handleNoSuggestions: {
                guard generation == receiptScanGeneration,
                      model.state == .ready else { return false }
                isScanning = false
                Self.receiptSignposter.endInterval(
                    "Receipt selection to suggestions",
                    suggestionsInterval,
                    "outcome=empty"
                )
                suggestionsIntervalEnded = true
                return true
            } handleRecognitionFailure: { error in
                guard generation == receiptScanGeneration else { return false }
                smartMessage = safeUserMessage(for: error, context: .scan)
                isScanning = false
                Self.receiptSignposter.endInterval(
                    "Receipt selection to suggestions",
                    suggestionsInterval,
                    "outcome=failed"
                )
                suggestionsIntervalEnded = true
                return true
            } prepareRetention: {
                let sanitizationSignpostID = Self.receiptSignposter.makeSignpostID()
                let sanitizationInterval = Self.receiptSignposter.beginInterval(
                    "Receipt sanitization",
                    id: sanitizationSignpostID
                )
                defer {
                    Self.receiptSignposter.endInterval(
                        "Receipt sanitization",
                        sanitizationInterval
                    )
                }

                do {
                    let sanitized = try await ReceiptImageSanitizer
                        .prepareForEncryptedStorage(data)
                    try Task.checkCancellation()
                    guard generation == receiptScanGeneration else { return }
                    receiptAttachmentData = sanitized
                    receiptRetentionMessage = nil
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard generation == receiptScanGeneration else { return }
                    receiptAttachmentData = nil
                    receiptRetentionMessage = safeUserMessage(
                        for: error,
                        context: .scan
                    )
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == receiptScanGeneration else { return }
            smartMessage = safeUserMessage(for: error, context: .scan)
        }
    }

    /// Receipt fields are suggestions, not an automatic commit. Populate the
    /// best candidates, reveal any filled optional details, and keep the full
    /// ranked result in transient view state so alternatives remain reviewable.
    @discardableResult
    func applyReceipt(_ result: ReceiptParseResult) -> Bool {
        guard let baseline = receiptScanBaseline else {
            receiptResult = nil
            return false
        }
        guard !result.draft.isEmpty else {
            receiptResult = nil
            smartMessage = String(localized: "quick_log.smart_nothing_found")
            return false
        }

        var reviewDraft = result.draft
        // Suggestions may arrive after the user has corrected a field. Apply
        // only values whose field still matches the scan-start snapshot, and
        // never reinterpret the explicitly selected transaction kind.
        if amountText != baseline.amountText { reviewDraft.amount = nil }
        if occurredAt != baseline.occurredAt
            || dateWasEdited != baseline.dateWasEdited {
            reviewDraft.occurredAt = nil
        }
        if payee != baseline.payee { reviewDraft.payee = nil }
        if accountID != baseline.accountID { reviewDraft.accountID = nil }
        if categoryID != baseline.categoryID {
            reviewDraft.categoryID = nil
        } else if let parsedCategoryID = reviewDraft.categoryID,
                  let category = model.accountsByID[parsedCategoryID],
                  category.kind != (kind == .income ? .income : .expense) {
            reviewDraft.categoryID = nil
        }
        _ = apply(
            reviewDraft,
            preservesKind: true,
            suggestsLearnedCategory: false
        )

        if note == baseline.note,
           note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let noteCandidate = result.noteCandidate {
            note = noteCandidate
        }
        if result.draft.occurredAt != nil
            || result.draft.payee != nil
            || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            isShowingOptionalDetails = true
        }

        receiptResult = result
        smartMessage = nil
        if !dismissAfterSave {
            model.updateQuickLogDraft(draftSnapshot)
        }
        return true
    }

    @ViewBuilder
    func receiptSuggestions(_ result: ReceiptParseResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("quick_log.scan_ready", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
            Text("quick_log.scan_review")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if result.amountCandidates.count > 1 {
                Text("quick_log.scan_alternative_amounts")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(
                            Array(result.amountCandidates.prefix(4).enumerated()),
                            id: \.offset
                        ) { _, candidate in
                            Button {
                                amountText = editableAmount(candidate)
                                persistUserDraftChange { snapshot in
                                    snapshot.amountText = amountText
                                }
                            } label: {
                                if let currency = selectedAccountCurrency {
                                    Text("\(editableAmount(candidate)) \(currency.value)")
                                } else {
                                    Text(editableAmount(candidate))
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Applies whatever the reader was sure about and leaves the rest alone.
    /// Returns false when nothing was recognized, so the caller can keep the
    /// user's input instead of clearing it.
    @discardableResult
    func apply(
        _ draft: TransactionDraft,
        preservesKind: Bool = false,
        suggestsLearnedCategory: Bool = true
    ) -> Bool {
        guard !draft.isEmpty else {
            smartMessage = String(localized: "quick_log.smart_nothing_found")
            return false
        }

        if !preservesKind {
            switch draft.kind {
            case .expense: kind = .expense
            case .income: kind = .income
            case .refund: kind = .refund
            }
        }
        if let amount = draft.amount {
            amountText = editableAmount(amount)
        }
        if let parsedDate = draft.occurredAt {
            occurredAt = parsedDate
            dateWasEdited = true
        }
        if let parsedPayee = draft.payee { payee = parsedPayee }
        if let parsedAccount = draft.accountID { accountID = parsedAccount }

        if let parsedCategory = draft.categoryID {
            categoryID = parsedCategory
        } else if suggestsLearnedCategory,
                  let parsedPayee = draft.payee,
                  let learned = CategorySuggester.suggestedCategory(
                      forPayee: parsedPayee,
                      kind: draft.kind == .income ? .income : .expense,
                      entries: model.entries,
                      accounts: model.accounts
                  ) {
            categoryID = learned
        }

        smartMessage = nil
        dismissKeyboard()
        if !dismissAfterSave { model.updateQuickLogDraft(draftSnapshot) }
        return true
    }

    /// Fills what is still unset. It must not overwrite a value the user or a
    /// parsed draft already chose, because it also runs when the kind changes.
    func selectDefaults() {
        if !model.userAccounts.contains(where: { $0.id == accountID }) {
            accountID = validPreferred(
                model.profile?.preferredAccountID,
                in: model.userAccounts
            ) ?? recentAccountID() ?? model.userAccounts.first?.id
        }
        switch kind {
        case .expense:
            if !model.expenseCategories.contains(where: { $0.id == categoryID }) {
                categoryID = validPreferred(
                    model.profile?.preferredExpenseCategoryID,
                    in: model.expenseCategories
                ) ?? recentCategoryID(kind: .expense)
                    ?? model.expenseCategories.first { $0.parentID != nil }?.id
                    ?? model.expenseCategories.first?.id
            }
        case .income:
            if !model.incomeCategories.contains(where: { $0.id == categoryID }) {
                categoryID = validPreferred(
                    model.profile?.preferredIncomeCategoryID,
                    in: model.incomeCategories
                ) ?? recentCategoryID(kind: .income)
                    ?? model.incomeCategories.first?.id
            }
        case .refund:
            if !model.expenseCategories.contains(where: { $0.id == categoryID }) {
                categoryID = validPreferred(
                    model.profile?.preferredExpenseCategoryID,
                    in: model.expenseCategories
                ) ?? recentCategoryID(kind: .expense)
                    ?? model.expenseCategories.first { $0.parentID != nil }?.id
                    ?? model.expenseCategories.first?.id
            }
        case .transfer:
            if !model.userAccounts.contains(where: {
                $0.id == destinationAccountID && $0.id != accountID
            }) {
                destinationAccountID = model.userAccounts.first { $0.id != accountID }?.id
            }
        }
        if hasRestoredDraft, !dismissAfterSave {
            model.updateQuickLogDraft(draftSnapshot)
        }
    }

    func validPreferred(
        _ id: UUID?,
        in choices: [LedgerAccount]
    ) -> UUID? {
        guard let id, choices.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    func recentAccountID() -> UUID? {
        // AppModel intentionally retains only the 80 newest valid entries.
        // Defaults favor recent behavior and never trigger a historical scan.
        let validIDs = Set(model.userAccounts.map(\.id))
        return model.entries.lazy
            .filter { entry in
                switch kind {
                case .expense: entry.kind == .expense
                case .income: entry.kind == .income
                case .transfer: entry.kind == .transfer
                case .refund: entry.kind == .expense
                }
            }
            .flatMap(\.postings)
            .first { validIDs.contains($0.accountID) }?
            .accountID
    }

    func recentCategoryID(kind: LedgerAccountKind) -> UUID? {
        let choices = kind == .income ? model.incomeCategories : model.expenseCategories
        let validIDs = Set(choices.map(\.id))
        let cutoff = model.reportingCalendar.date(
            byAdding: .day,
            value: -30,
            to: Date()
        ) ?? .distantPast
        var counts: [UUID: Int] = [:]
        var firstSeenOrder: [UUID: Int] = [:]

        for (index, entry) in model.entries.enumerated() where entry.occurredAt >= cutoff {
            guard accountID == nil || entry.postings.contains(where: { $0.accountID == accountID })
            else { continue }
            for posting in entry.postings where validIDs.contains(posting.accountID) {
                counts[posting.accountID, default: 0] += 1
                firstSeenOrder[posting.accountID] = firstSeenOrder[posting.accountID] ?? index
            }
        }
        return counts.keys.max { first, second in
            let firstCount = counts[first, default: 0]
            let secondCount = counts[second, default: 0]
            if firstCount == secondCount {
                return firstSeenOrder[first, default: .max]
                    > firstSeenOrder[second, default: .max]
            }
            return firstCount < secondCount
        }
    }
}
