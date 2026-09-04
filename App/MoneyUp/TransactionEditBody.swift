import MoneyUpCore
import MoneyUpPersistence
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension TransactionEditView {
    var body: some View {
        let _ = hidesAmounts
        return NavigationStack {
            ScrollViewReader { scrollProxy in
            Form {
                if isEditable {
                    if dynamicTypeSize.isAccessibilitySize {
                        kindPicker(style: .menu)
                    } else {
                        kindPicker(style: .segmented)
                    }

                    Section {
                        HStack {
                            TextField("quick_log.amount", text: $amountText)
                                .moneyAmountKeyboard(currency: sourceCurrency)
                                .focused($focusedField, equals: .amount)
                                .id(TransactionEditView.FieldFocus.amount)
                                .moneyUpPrivateAmountInput(
                                    masked: hidesAmounts
                                        && focusedField != .amount
                                        && !amountText.isEmpty,
                                    accessibilityLabel: Text("quick_log.amount")
                                ) {
                                    focusedField = .amount
                                }
                            if let sourceCurrency {
                                Text(sourceCurrency.value).foregroundStyle(.secondary)
                            }
                        }
                        Picker(
                            kind == .transfer
                                ? "transaction.from_account"
                                : "transaction.account",
                            selection: $accountID
                        ) {
                            ForEach(editableUserAccounts) { account in
                                Text(verbatim: editorLabel(for: account))
                                    .tag(Optional(account.id))
                            }
                        }

                        if kind == .transfer {
                            Picker("transaction.to_account", selection: $destinationAccountID) {
                                ForEach(
                                    editableUserAccounts.filter { $0.id != accountID }
                                ) { account in
                                    Text(verbatim: editorLabel(for: account))
                                        .tag(Optional(account.id))
                                }
                            }
                            if needsDestinationAmount {
                                HStack {
                                    TextField(
                                        "transaction.received_amount",
                                        text: $destinationAmountText
                                    )
                                    .moneyAmountKeyboard(currency: destinationCurrency)
                                    .focused($focusedField, equals: .destinationAmount)
                                    .id(TransactionEditView.FieldFocus.destinationAmount)
                                    .moneyUpPrivateAmountInput(
                                        masked: hidesAmounts
                                            && focusedField != .destinationAmount
                                            && !destinationAmountText.isEmpty,
                                        accessibilityLabel: Text(
                                            "transaction.received_amount"
                                        )
                                    ) {
                                        focusedField = .destinationAmount
                                    }
                                    if let destinationCurrency {
                                        Text(destinationCurrency.value)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } else {
                            Toggle(
                                "quick_log.split_transaction",
                                isOn: Binding(
                                    get: { isSplitTransaction },
                                    set: { enabled in
                                        isSplitTransaction = enabled
                                        if enabled, splitLines.count < 2 {
                                            let initialCategory = categoryID ?? categories.first?.id
                                            splitLines = [
                                                QuickLogSplitDraftLine(categoryID: initialCategory),
                                                QuickLogSplitDraftLine(categoryID: initialCategory)
                                            ]
                                        } else if !enabled {
                                            splitLines = []
                                        }
                                    }
                                )
                            )

                            if isSplitTransaction {
                                splitEditor
                            } else {
                                Picker("transaction.category", selection: $categoryID) {
                                    ForEach(categories) { category in
                                        Text(verbatim: editorLabel(for: category))
                                            .tag(Optional(category.id))
                                    }
                                }
                            }
                        }

                        DatePicker(
                            "transaction.date",
                            selection: $occurredAt,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        LabeledContent("quick_log.time_zone") {
                            Text(verbatim: userActionTimeContext.displayName(at: occurredAt))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        TextField("transaction.title_or_merchant", text: $payee)
                            .focused($focusedField, equals: .payee)
                            .id(TransactionEditView.FieldFocus.payee)
                        TextField(
                            "transaction.description_or_notes",
                            text: $note,
                            axis: .vertical
                        )
                        .focused($focusedField, equals: .note)
                        .id(TransactionEditView.FieldFocus.note)
                    }
                } else {
                    Section {
                        TransactionRow(entry: entry)
                        Text("history.edit_not_supported")
                            .foregroundStyle(.secondary)
                    }
                }

                if !model.isProtectedJournalEntry(entry) {
                    Section {
                        Button("action.delete", role: .destructive) {
                            isConfirmingDelete = true
                        }
                    }
                }

                if let revisedAt = entry.revisedAt {
                    Section {
                        LabeledContent("history.last_edited") {
                            Text(revisedAt, format: .dateTime.month().day().year().hour().minute())
                        }
                    }
                }


                Section {
                    if isEditable {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 16) {
                                editEvidencePhotoButton
                                editEvidencePDFButton
                            }
                            VStack(alignment: .leading, spacing: 12) {
                                editEvidencePhotoButton
                                editEvidencePDFButton
                            }
                        }
                    }

                    if isPreparingEvidence {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("evidence.preparing").foregroundStyle(.secondary)
                        }
                    }

                    ForEach(pendingEvidence) { attachment in
                        HStack(spacing: 12) {
                            Image(systemName: attachment.mediaType == .pdf
                                ? "doc.richtext.fill" : "photo.fill")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(attachment.displayName ?? AppLocalization.string(
                                    attachment.mediaType == .pdf
                                        ? "evidence.pdf" : "evidence.photo"
                                ))
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text("evidence.pending_save")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                pendingEvidence.removeAll { $0.id == attachment.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("evidence.remove")
                        }
                    }

                    if let evidenceMessage {
                        Text(evidenceMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !attachmentMetadata.isEmpty {
                        ForEach(attachmentMetadata) { attachment in
                            VStack(alignment: .leading, spacing: 8) {
                                if attachment.mediaType == .pdf {
                                    Label(
                                        attachment.displayName
                                            ?? AppLocalization.string("evidence.pdf"),
                                        systemImage: "doc.richtext.fill"
                                    )
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, minHeight: 64)
                                } else if let image = attachmentImages[attachment.id] {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxHeight: 240)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                        .accessibilityLabel("receipt.attachment_image")
                                } else if attachmentLoadFailures.contains(attachment.id) {
                                    Button("action.retry") {
                                        attachmentLoadFailures.remove(attachment.id)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 88)
                                } else {
                                    ProgressView()
                                        .frame(maxWidth: .infinity, minHeight: 88)
                                        .task(id: attachment.id) {
                                            await loadAttachmentImage(attachment.id)
                                        }
                                }
                                Button("receipt.delete_attachment", role: .destructive) {
                                    pendingAttachmentDeletionID = attachment.id
                                    isConfirmingAttachmentDelete = true
                                }
                                .accessibilityHint("receipt.delete_attachment_hint")
                            }
                        }
                    }
                } header: {
                    Text("evidence.title")
                } footer: {
                    Text("evidence.encrypted_detail")
                }

            }
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .scrollDismissesKeyboard(.interactively)
            .contentMargins(
                .bottom,
                focusedField == nil ? 72 : 200,
                for: .scrollContent
            )
            .navigationTitle("history.edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                if isEditable {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("action.save") { Task { await save() } }
                            .disabled(!canSave || isSaving || isPreparingEvidence)
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    MoneyUpAmountPrivacyButton()
                }
                MoneyUpKeyboardDoneToolbar()
            }
            .task {
                userActionTimeContext = UserActionTimeContext(
                    timeZone: .autoupdatingCurrent
                )
                loadValues()
            }
            .onUserActionTimeChange {
                userActionTimeContext = UserActionTimeContext(
                    timeZone: .autoupdatingCurrent
                )
            }
            .onDisappear {
                invalidateAttachmentPreviews()
                evidencePreparationTask?.cancel()
            }
            .onChange(of: evidencePhotoItems) { _, items in
                guard !items.isEmpty else { return }
                evidencePreparationTask?.cancel()
                evidencePreparationTask = Task { @MainActor in
                    await addEditEvidencePhotos(items)
                }
            }
            .onChange(of: model.state) { _, state in
                if state != .ready {
                    invalidateAttachmentPreviews()
                }
            }
            .onChange(of: model.logicalBookRevision) { _, _ in
                invalidateAttachmentPreviews()
                pendingAttachmentDeletionID = nil
                dismiss()
            }
            .onChange(of: kind) { _, newKind in
                if newKind == .transfer {
                    isSplitTransaction = false
                    splitLines = []
                }
                selectValidDefaults()
            }
            .onChange(of: focusedField) { _, field in
                guard let field else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    scrollProxy.scrollTo(field, anchor: .center)
                }
                Task { @MainActor in
                    try? await Task.sleep(
                        nanoseconds: QuickLogFocusScrollPolicy.layoutSettlingNanoseconds
                    )
                    guard focusedField == field else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        scrollProxy.scrollTo(field, anchor: .center)
                    }
                }
            }
            .confirmationDialog(
                "transaction.delete_title",
                isPresented: $isConfirmingDelete,
                titleVisibility: .visible
            ) {
                Button("action.delete", role: .destructive) {
                    Task { await delete() }
                }
                Button("action.cancel", role: .cancel) {}
            } message: {
                Text("transaction.delete_detail")
            }
            .confirmationDialog(
                "receipt.delete_title",
                isPresented: $isConfirmingAttachmentDelete,
                titleVisibility: .visible
            ) {
                Button("receipt.delete_attachment", role: .destructive) {
                    guard let id = pendingAttachmentDeletionID else { return }
                    Task { await deleteAttachment(id) }
                }
                Button("action.cancel", role: .cancel) {
                    pendingAttachmentDeletionID = nil
                }
            } message: {
                Text("receipt.delete_detail")
            }
            .moneyUpOperationErrorAlert(message: $errorMessage)
            }
        }
        .environment(\.calendar, captureCalendar)
        .environment(\.timeZone, captureCalendar.timeZone)
    }

    func kindPicker<Style: PickerStyle>(style: Style) -> some View {
        Picker("transaction.kind", selection: $kind) {
            ForEach(QuickLogKind.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(style)
    }

    func loadValues() {
        guard let values = EditableEntryValues(entry: entry, accounts: model.accounts) else {
            return
        }
        kind = values.kind
        amountText = editableAmount(values.amount)
        destinationAmountText = values.destinationAmount.map { editableAmount($0) } ?? ""
        accountID = values.accountID
        destinationAccountID = values.destinationAccountID
        categoryID = values.categoryID
        splitLines = values.splitLines
        isSplitTransaction = values.splitLines.count >= 2
    }

    func selectValidDefaults() {
        if !editableUserAccounts.contains(where: { $0.id == accountID }) {
            accountID = editableUserAccounts.first?.id
        }
        if kind == .transfer {
            if destinationAccountID == accountID
                || !editableUserAccounts.contains(where: { $0.id == destinationAccountID }) {
                destinationAccountID = editableUserAccounts.first { $0.id != accountID }?.id
            }
        } else if !categories.contains(where: { $0.id == categoryID }) {
            categoryID = categories.first?.id
        }
        if isSplitTransaction {
            for index in splitLines.indices where !categories.contains(
                where: { $0.id == splitLines[index].categoryID }
            ) {
                splitLines[index].categoryID = categories.first?.id
            }
        }
    }

    func save() async {
        guard let amount = decimalAmount(from: amountText),
              let accountID else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let revisedSplits = try splitTransactionLines()
            try await model.replaceEntry(
                id: entry.id,
                kind: kind,
                amount: amount,
                destinationAmount: decimalAmount(from: destinationAmountText),
                accountID: accountID,
                destinationAccountID: destinationAccountID,
                categoryID: categoryID,
                splitLines: revisedSplits,
                occurredAt: occurredAt,
                payee: payee,
                note: note,
                attachmentDrafts: pendingEvidence
            )
            dismiss()
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }

    func splitTransactionLines() throws -> [TransactionSplitLine]? {
        guard isSplitTransaction, kind != .transfer else { return nil }
        guard let currency = sourceCurrency else { throw AppModelError.accountHasNoCurrency }
        guard let amount = decimalAmount(from: amountText) else {
            throw AppModelError.missingRecord
        }
        let lines = try transactionSplitLines(currency: currency)
        try TransactionSplitCalculator.validate(
            total: Money(amount, currency: currency),
            lines: lines
        )
        return lines
    }

    func transactionSplitLines(
        currency: CurrencyCode
    ) throws -> [TransactionSplitLine] {
        try splitLines.map { line in
            guard let categoryID = line.categoryID,
                  let amount = decimalAmount(from: line.amountText) else {
                throw AppModelError.missingRecord
            }
            return TransactionSplitLine(
                id: line.id,
                categoryAccountID: categoryID,
                amount: try Money(amount, currency: currency),
                memo: line.memo
            )
        }
    }

    func delete() async {
        do {
            try await model.deleteEntry(id: entry.id)
            dismiss()
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }

    func deleteAttachment(_ id: UUID) async {
        do {
            try await model.deleteReceiptAttachment(id: id)
            attachmentLoadTokens[id] = nil
            attachmentImages[id] = nil
            attachmentLoadFailures.remove(id)
            pendingAttachmentDeletionID = nil
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }

    func loadAttachmentImage(_ id: UUID) async {
        guard model.state == .ready,
              attachmentImages[id] == nil,
              attachmentLoadTokens[id] == nil,
              attachmentMetadata.contains(where: { $0.id == id }) else { return }
        let loadToken = UUID()
        let logicalBookRevision = model.logicalBookRevision
        attachmentLoadTokens[id] = loadToken
        defer {
            if attachmentLoadTokens[id] == loadToken {
                attachmentLoadTokens[id] = nil
            }
        }
        do {
            let attachment = try await model.receiptAttachment(id: id)
            try Task.checkCancellation()
            let image = try await ReceiptThumbnailDecoder.image(from: attachment.data)
            try Task.checkCancellation()
            guard isCurrentAttachmentLoad(
                id: id,
                token: loadToken,
                logicalBookRevision: logicalBookRevision
            ) else { return }
            attachmentImages[id] = image
            attachmentLoadFailures.remove(id)
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentAttachmentLoad(
                id: id,
                token: loadToken,
                logicalBookRevision: logicalBookRevision
            ) else { return }
            attachmentLoadFailures.insert(id)
            errorMessage = safeUserMessage(for: error, context: .read)
        }
    }

    func isCurrentAttachmentLoad(
        id: UUID,
        token: UUID,
        logicalBookRevision: UInt64
    ) -> Bool {
        model.state == .ready
            && !model.isBookReplacementInProgress
            && model.logicalBookRevision == logicalBookRevision
            && attachmentLoadTokens[id] == token
            && attachmentMetadata.contains(where: { $0.id == id })
    }

    func invalidateAttachmentPreviews() {
        attachmentLoadTokens.removeAll()
        attachmentImages.removeAll()
        attachmentLoadFailures.removeAll()
    }
}
