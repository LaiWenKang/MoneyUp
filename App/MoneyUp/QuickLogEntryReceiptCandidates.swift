import Foundation
import MoneyUpCore
import SwiftUI

extension QuickLogEntryView {
    @ViewBuilder
    func receiptSuggestions(_ result: ReceiptParseResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("quick_log.scan_ready", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
            Text("quick_log.scan_review")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let confidence = result.overallConfidence {
                Label(
                    captureConfidenceText(confidence),
                    systemImage: confidence == .low
                        ? "questionmark.circle" : "checkmark.seal"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            receiptAmountCandidates(result.amountCandidateDetails)
            receiptMerchantCandidates(result.merchantCandidateDetails)
            receiptDateCandidates(result.dateCandidateDetails)
            receiptCategoryCandidate(result)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func receiptAmountCandidates(
        _ candidates: [ReceiptCandidate<Decimal>]
    ) -> some View {
        if !candidates.isEmpty {
            Text("quick_log.scan_amount_candidates")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(candidates.prefix(4).enumerated()), id: \.offset) {
                        _, candidate in
                        Button {
                            amountText = editableAmount(candidate.value)
                            persistUserDraftChange { $0.amountText = amountText }
                        } label: {
                            receiptAmountCandidateLabel(candidate)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func receiptAmountCandidateLabel(
        _ candidate: ReceiptCandidate<Decimal>
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let currency = selectedAccountCurrency {
                Text("\(editableAmount(candidate.value)) \(currency.value)")
                    .font(.body.monospacedDigit())
                Text("quick_log.scan_amount_account_currency")
                    .font(.caption2)
            } else {
                Text(editableAmount(candidate.value))
                    .font(.body.monospacedDigit())
            }
            Text(receiptCandidateDetail(candidate))
                .font(.caption2)
        }
    }

    @ViewBuilder
    private func receiptMerchantCandidates(
        _ candidates: [ReceiptCandidate<String>]
    ) -> some View {
        if !candidates.isEmpty {
            Text("quick_log.scan_merchant_candidates")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(candidates.prefix(3).enumerated()), id: \.offset) {
                        _, candidate in
                        Button {
                            applyReceiptMerchantCandidate(candidate.value)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.value)
                                Text(receiptCandidateDetail(candidate)).font(.caption2)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func applyReceiptMerchantCandidate(_ candidate: String) {
        invalidateCaptureSuggestions()
        payee = candidate
        persistUserDraftChange { $0.payee = candidate }
        refreshCaptureSuggestions(
            for: TransactionDraft(
                kind: kind == .income ? .income
                    : kind == .refund ? .refund : .expense,
                payee: candidate,
                source: .receipt
            )
        )
        if !dismissAfterSave {
            model.updateQuickLogDraft(draftSnapshot)
        }
    }

    @ViewBuilder
    private func receiptDateCandidates(
        _ candidates: [ReceiptCandidate<Date>]
    ) -> some View {
        if !candidates.isEmpty {
            Text("quick_log.scan_date_candidates")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(candidates.prefix(3).enumerated()), id: \.offset) {
                        _, candidate in
                        Button {
                            applyReceiptDateCandidate(candidate.value)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.value.formattedForReporting(
                                    .dateTime.year().month(.abbreviated).day(),
                                    calendar: model.reportingCalendar
                                ))
                                Text(receiptCandidateDetail(candidate)).font(.caption2)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func applyReceiptDateCandidate(_ candidate: Date) {
        occurredAt = candidate
        dateWasEdited = true
        invalidateCaptureSuggestions()
        isShowingOptionalDetails = true
        persistUserDraftChange { snapshot in
            snapshot.occurredAt = candidate
            snapshot.dateWasEdited = true
        }
    }

    @ViewBuilder
    private func receiptCategoryCandidate(_ result: ReceiptParseResult) -> some View {
        if splitLines.isEmpty,
           let categoryID = result.draft.categoryID,
           let category = model.accountsByID[categoryID],
           categories.contains(where: { $0.id == categoryID }),
           QuickLogSuggestionPolicy.receiptCategoryIsCompatible(category, with: kind),
           let candidate = result.categoryCandidateDetails.first {
            Text("quick_log.scan_category_candidate")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Button {
                QuickLogInputAuthority.applyReceiptCategory(
                    invalidateAssistance: {
                        invalidateOnDeviceCategoryForDeterministicChange()
                    }
                ) {
                    self.categoryID = categoryID
                    categoryWasEdited = true
                    autoAppliedCategorySuggestionID = nil
                    persistUserDraftChange { $0.categoryID = categoryID }
                }
            } label: {
                HStack {
                    Text(category.name)
                    Spacer(minLength: 8)
                    Text(receiptCandidateDetail(candidate)).font(.caption2)
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private func receiptCandidateDetail<Value>(
        _ candidate: ReceiptCandidate<Value>
    ) -> String where Value: Equatable & Sendable {
        "\(captureConfidenceText(candidate.confidence)) · "
            + receiptEvidenceText(candidate.evidence)
    }

    private func receiptEvidenceText(_ evidence: [ReceiptCandidateEvidence]) -> String {
        if evidence.contains(.lowOCRConfidence) {
            return AppLocalization.string("quick_log.scan_reason_low_ocr")
        }
        if evidence.contains(.payableAmountLabel)
            || evidence.contains(.precedingPayableAmountLabel) {
            return AppLocalization.string("quick_log.scan_reason_total_label")
        }
        if evidence.contains(.explicitMerchantLabel)
            || evidence.contains(.businessNameMarker)
            || evidence.contains(.receiptHeaderPosition) {
            return AppLocalization.string("quick_log.scan_reason_merchant")
        }
        if evidence.contains(.transactionDateLabel)
            || evidence.contains(.genericDateLabel)
            || evidence.contains(.timeComponent) {
            return AppLocalization.string("quick_log.scan_reason_date")
        }
        if evidence.contains(.categoryKeywordMatch)
            || evidence.contains(.multipleCategoryKeywordMatches) {
            return AppLocalization.string("quick_log.scan_reason_category")
        }
        if evidence.contains(.currencyMarker)
            || evidence.contains(.fractionalAmount) {
            return AppLocalization.string("quick_log.scan_reason_amount_shape")
        }
        return AppLocalization.string("quick_log.scan_reason_pattern")
    }
}
