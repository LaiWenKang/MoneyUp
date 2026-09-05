import Foundation
import MoneyUpCore
import SwiftUI

extension QuickLogEntryView {
    var prepaidFundingLifecycleAnchor: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: prepaidFundingRequest) {
                await refreshPrepaidAllowanceFunding()
            }
    }

    var prepaidFundingRequest: QuickLogPrepaidFundingRequest? {
        guard kind == .expense,
              let plan = selectedAllowancePlan,
              plan.fundingMode == .prepaidAsset,
              let sourceAccountID = selectedSourceAccount?.id else {
            return nil
        }
        return QuickLogPrepaidFundingRequest(
            plan: plan,
            sourceAccountID: sourceAccountID,
            occurredAt: occurredAt,
            journalProjectionRevision: model.journalProjectionRevision,
            logicalBookRevision: model.logicalBookRevision
        )
    }

    var selectedAllowanceRemaining: AllowanceRemainingAvailability? {
        guard let plan = selectedAllowancePlan else { return nil }
        guard plan.fundingMode == .prepaidAsset else {
            return selectedAllowancePresentation?.remaining
        }
        return QuickLogPrepaidFundingPresentationPolicy.remaining(
            prepaidFundingLoad,
            matching: prepaidFundingRequest
        )
    }

    var selectedPrepaidFundingIsLoading: Bool {
        guard let request = prepaidFundingRequest else { return false }
        return prepaidFundingLoad?.request != request
    }

    var selectedAllowanceApplication: Money? {
        guard selectedAllowanceID != nil,
              let totalAmount = amount,
              let currency = selectedAccountCurrency,
              let presentation = selectedAllowancePresentation,
              let policy = presentation.activePolicy,
              let remainingAvailability = selectedAllowanceRemaining,
              case let .available(remaining) = remainingAvailability else {
            return nil
        }
        let eligibleAmount = eligibleAllowanceAmount(
            totalAmount: totalAmount,
            policy: policy
        )
        guard eligibleAmount > .zero,
              let money = try? Money(
                  min(eligibleAmount, remaining.amount),
                  currency: currency
              ),
              money.amount > .zero else { return nil }
        return money
    }

    private func eligibleAllowanceAmount(
        totalAmount: Decimal,
        policy: AllowancePolicyRevision
    ) -> Decimal {
        if splitLines.isEmpty {
            guard let categoryID,
                  policy.accepts(categoryID: categoryID) else { return .zero }
            return totalAmount
        }
        var eligibleAmount = Decimal.zero
        for line in splitLines {
            guard let categoryID = line.categoryID,
                  policy.accepts(categoryID: categoryID),
                  let lineAmount = decimalAmount(from: line.amountText) else {
                continue
            }
            eligibleAmount = (try? CheckedDecimal.adding(
                eligibleAmount,
                lineAmount
            )) ?? eligibleAmount
        }
        return eligibleAmount
    }

    @MainActor
    func refreshPrepaidAllowanceFunding() async {
        guard let request = prepaidFundingRequest else {
            prepaidFundingLoad = nil
            return
        }
        do {
            let remaining = try await model.prepaidAllowanceSpendable(
                planID: request.plan.id,
                asOf: request.occurredAt
            )
            try Task.checkCancellation()
            guard prepaidFundingRequest == request else { return }
            prepaidFundingLoad = QuickLogPrepaidFundingLoad(
                request: request,
                remaining: .available(remaining)
            )
        } catch is CancellationError {
            return
        } catch {
            publishPrepaidFundingFailure(error, for: request)
        }
    }

    @MainActor
    private func publishPrepaidFundingFailure(
        _ error: Error,
        for request: QuickLogPrepaidFundingRequest
    ) {
        guard prepaidFundingRequest == request else { return }
        let issue: DerivedValueIssue = model.state == .ready
            ? .ledgerCalculationFailed : .appNotReady
        DerivedValueDiagnostics.record(
            issue,
            operation: "quick-log-prepaid-as-of",
            error: error
        )
        prepaidFundingLoad = QuickLogPrepaidFundingLoad(
            request: request,
            remaining: .unavailable(issue)
        )
    }
}

enum QuickLogPrepaidFundingPresentationPolicy {
    static func remaining(
        _ load: QuickLogPrepaidFundingLoad?,
        matching request: QuickLogPrepaidFundingRequest?
    ) -> AllowanceRemainingAvailability? {
        guard let request, load?.request == request else { return nil }
        return load?.remaining
    }
}
