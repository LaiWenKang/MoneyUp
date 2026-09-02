import Foundation
import MoneyUpCore
import OSLog
import PhotosUI
import SwiftUI
import UIKit

extension QuickLogEntryView {
    var occurrenceSection: some View {
        Section {
            LabeledContent("quick_log.occurred_at") {
                Text(
                    occurredAt.formattedForReporting(
                        .dateTime.month().day().hour().minute(),
                        calendar: model.reportingCalendar
                    )
                )
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
        ForEach(Array(splitLines.enumerated()), id: \.element.id) { index, line in
            let lineID = line.id
            let lineValidationMessage = monetaryInputError(
                text: line.amountText,
                currency: selectedAccountCurrency
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
                                splitLines.first(where: { $0.id == lineID })?.amountText
                                    ?? ""
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
                    .accessibilityLabel(
                        Text(
                            String(
                                format: AppLocalization.string("quick_log.split_amount_numbered"),
                                index + 1
                            )
                        )
                    )
                    if let currency = selectedAccountCurrency {
                        Text(currency.value).foregroundStyle(.secondary)
                    }
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
                Text("\(editableAmount(remainder)) \(currency.value)")
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
}
