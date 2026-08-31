import Foundation
import MoneyUpCore

extension QuickLogEntryView {
    func attemptSave() async {
        guard !isSaving, canSave else { return }
        pendingDuplicateReview = nil
        if model.journalRecentEntriesAreCurrent,
           let query = duplicateQuery() {
            let result = CaptureDuplicateDetector.matches(
                for: query,
                in: model.entries
            )
            if let match = result.matches.first {
                let historyDate = model.entries.first(where: {
                    $0.id == match.entryID
                }).map { entry in
                    QuickLogDuplicateReviewPolicy.historyDate(
                        for: entry,
                        calendar: model.reportingCalendar
                    )
                }
                dismissKeyboard()
                pendingDuplicateReview = PendingDuplicateReview(
                    queryFingerprint: result.queryFingerprint,
                    match: match,
                    historyDate: historyDate
                )
                return
            }
        }
        await commitSave()
    }

    func confirmDuplicateSave(_ pending: PendingDuplicateReview) async {
        guard duplicateQuery()?.fingerprint == pending.queryFingerprint else {
            await attemptSave()
            return
        }
        await commitSave()
    }

    var duplicateReviewMessage: String {
        guard let pending = pendingDuplicateReview else {
            return String(localized: "quick_log.duplicate_message_fallback")
        }
        let date = pending.historyDate?.formattedForReporting(
            .dateTime.year().month(.abbreviated).day(),
            calendar: model.reportingCalendar
        ) ?? String(localized: "quick_log.duplicate_recent_time")
        return String(
            format: String(localized: "quick_log.duplicate_message_format"),
            date,
            duplicateReason(pending.match.evidence),
            captureConfidenceText(pending.match.confidence)
        )
    }

    private func duplicateReason(_ evidence: CaptureDuplicateEvidence) -> String {
        if evidence.sourceMatched {
            return String(localized: "quick_log.duplicate_reason_source")
        }
        if evidence.categoryMatched && evidence.descriptorMatched {
            return String(localized: "quick_log.duplicate_reason_category_payee")
        }
        if evidence.descriptorMatched {
            return String(localized: "quick_log.duplicate_reason_payee")
        }
        if evidence.categoryMatched {
            return String(localized: "quick_log.duplicate_reason_category")
        }
        return String(localized: "quick_log.duplicate_reason_time")
    }

    private func duplicateQuery() -> CaptureDuplicateQuery? {
        guard let amount,
              let accountID,
              let sourceCurrency = selectedAccountCurrency,
              let sourceAmount = try? Money(amount, currency: sourceCurrency) else {
            return nil
        }
        do {
            switch kind {
            case .expense:
                return try expenseDuplicateQuery(sourceAmount, accountID: accountID)
            case .income:
                return try incomeDuplicateQuery(sourceAmount, accountID: accountID)
            case .refund:
                return try refundDuplicateQuery(sourceAmount, accountID: accountID)
            case .transfer:
                return try transferDuplicateQuery(
                    sourceAmount,
                    sourceAccountID: accountID
                )
            }
        } catch {
            return nil
        }
    }

    private var captureSourceReference: CaptureSourceReference? {
        sourceCaptureID.map {
            CaptureSourceReference(
                system: AppModel.lockedCaptureSourceSystem,
                fingerprint: AppModel.lockedCaptureFingerprint($0)
            )
        }
    }

    private func expenseDuplicateQuery(
        _ amount: Money,
        accountID: UUID
    ) throws -> CaptureDuplicateQuery {
        try .expense(
            amount: amount,
            paidFrom: accountID,
            category: splitLines.isEmpty ? categoryID : nil,
            occurredAt: occurredAt,
            payee: payee,
            sourceReference: captureSourceReference
        )
    }

    private func incomeDuplicateQuery(
        _ amount: Money,
        accountID: UUID
    ) throws -> CaptureDuplicateQuery {
        try .income(
            amount: amount,
            depositedInto: accountID,
            category: splitLines.isEmpty ? categoryID : nil,
            occurredAt: occurredAt,
            payee: payee,
            sourceReference: captureSourceReference
        )
    }

    private func refundDuplicateQuery(
        _ amount: Money,
        accountID: UUID
    ) throws -> CaptureDuplicateQuery {
        try .refund(
            amount: amount,
            returnedTo: accountID,
            category: splitLines.isEmpty ? categoryID : nil,
            occurredAt: occurredAt,
            payee: payee,
            sourceReference: captureSourceReference
        )
    }

    private func transferDuplicateQuery(
        _ sourceAmount: Money,
        sourceAccountID: UUID
    ) throws -> CaptureDuplicateQuery? {
        guard let destinationAccountID,
              let destinationCurrency = selectedDestinationCurrency else {
            return nil
        }
        if destinationCurrency == sourceAmount.currency {
            return try .transfer(
                amount: sourceAmount,
                from: sourceAccountID,
                to: destinationAccountID,
                occurredAt: occurredAt,
                note: note,
                sourceReference: captureSourceReference
            )
        }
        return try foreignTransferDuplicateQuery(
            sourceAmount,
            sourceAccountID: sourceAccountID,
            destinationAccountID: destinationAccountID,
            destinationCurrency: destinationCurrency
        )
    }

    private func foreignTransferDuplicateQuery(
        _ sourceAmount: Money,
        sourceAccountID: UUID,
        destinationAccountID: UUID,
        destinationCurrency: CurrencyCode
    ) throws -> CaptureDuplicateQuery? {
        guard let destinationAmount,
              let received = try? Money(
                  destinationAmount,
                  currency: destinationCurrency
              ),
              let sourceTrading = foreignExchangeAccount(sourceAmount.currency),
              let destinationTrading = foreignExchangeAccount(destinationCurrency) else {
            return nil
        }
        return try .foreignCurrencyTransfer(
            sourceAmount: sourceAmount,
            destinationAmount: received,
            from: sourceAccountID,
            to: destinationAccountID,
            sourceTradingAccountID: sourceTrading.id,
            destinationTradingAccountID: destinationTrading.id,
            occurredAt: occurredAt,
            note: note,
            sourceReference: captureSourceReference
        )
    }

    private func foreignExchangeAccount(_ currency: CurrencyCode) -> LedgerAccount? {
        model.accounts.first {
            $0.kind == .trading
                && $0.systemRole == .foreignExchange
                && $0.currency == currency
        }
    }
}
