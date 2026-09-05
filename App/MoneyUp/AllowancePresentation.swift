import Foundation
import MoneyUpCore

enum AllowanceRemainingMeaning: Equatable, Sendable {
    /// Real stored value that can be spent from the linked restricted ledger
    /// account now. This is never inferred from policy entitlement alone.
    case prepaidSpendable
    /// Planning-only employer benefit capacity; it is not cash or an asset.
    case benefitPolicyCapacity
    /// Capacity under which an expense may be submitted as a claim; it is not
    /// cash or a receivable merely because the policy accepts the expense.
    case reimbursementClaimCapacity

    var titleKeyString: String {
        switch self {
        case .prepaidSpendable:
            "allowance.prepaid_spendable"
        case .benefitPolicyCapacity:
            "allowance.benefit_capacity"
        case .reimbursementClaimCapacity:
            "allowance.claim_capacity"
        }
    }

    var applicationKeyString: String {
        switch self {
        case .prepaidSpendable:
            "allowance.apply_amount.prepaid"
        case .benefitPolicyCapacity:
            "allowance.apply_amount.benefit"
        case .reimbursementClaimCapacity:
            "allowance.apply_amount.reimbursement"
        }
    }
}

enum AllowanceRemainingAvailability: Equatable, Sendable {
    case available(Money)
    case unavailable(DerivedValueIssue)

    var value: Money? {
        guard case let .available(value) = self else { return nil }
        return value
    }
}

/// A truth-preserving allowance projection for presentation surfaces.
///
/// Policy math remains visible even when a prepaid ledger value cannot be
/// established, while `remaining` fails closed so policy entitlement is never
/// presented or applied as stored money.
struct AllowancePresentation: Equatable, Sendable {
    let policySummary: AllowanceSummary?
    let activePolicy: AllowancePolicyRevision?
    let pendingPolicy: AllowancePolicyRevision?
    let remainingMeaning: AllowanceRemainingMeaning
    let remaining: AllowanceRemainingAvailability
}

extension AppModel {
    func allowancePresentation(
        _ plan: AllowancePlan,
        asOf requestedDate: Date? = nil
    ) -> AllowancePresentation {
        let date = requestedDate ?? currentDateForUserAction()
        let activePolicy = plan.policy(at: date)
        let pendingPolicy = plan.policyRevisions.first { $0.effectiveAt > date }
        let meaning = allowanceRemainingMeaning(for: plan.fundingMode)
        switch allowancePolicySummary(plan, asOf: date) {
        case let .unavailable(issue):
            return AllowancePresentation(
                policySummary: nil,
                activePolicy: activePolicy,
                pendingPolicy: pendingPolicy,
                remainingMeaning: meaning,
                remaining: .unavailable(issue)
            )
        case let .available(summary):
            return AllowancePresentation(
                policySummary: summary,
                activePolicy: activePolicy,
                pendingPolicy: pendingPolicy,
                remainingMeaning: meaning,
                remaining: presentedAllowanceRemaining(
                    for: plan,
                    policySummary: summary,
                    asOf: date
                )
            )
        }
    }

    private func allowanceRemainingMeaning(
        for mode: AllowanceFundingMode
    ) -> AllowanceRemainingMeaning {
        switch mode {
        case .benefitLimit:
            .benefitPolicyCapacity
        case .prepaidAsset:
            .prepaidSpendable
        case .reimbursement:
            .reimbursementClaimCapacity
        }
    }

    private func allowancePolicySummary(
        _ plan: AllowancePlan,
        asOf date: Date
    ) -> DerivedValue<AllowanceSummary> {
        do {
            return .available(try plan.summary(asOf: date))
        } catch {
            DerivedValueDiagnostics.record(
                .amountCalculationFailed,
                operation: "allowance-policy-presentation",
                error: error
            )
            return .unavailable(.amountCalculationFailed)
        }
    }

    private func presentedAllowanceRemaining(
        for plan: AllowancePlan,
        policySummary summary: AllowanceSummary,
        asOf date: Date
    ) -> AllowanceRemainingAvailability {
        switch plan.fundingMode {
        case .benefitLimit, .reimbursement:
            return availableAllowanceMoney(
                max(summary.remaining.amount, .zero),
                currency: summary.remaining.currency
            )
        case .prepaidAsset:
            return prepaidAllowanceSpendable(
                plan,
                policySummary: summary,
                asOf: date
            )
        }
    }

    private func prepaidAllowanceSpendable(
        _ plan: AllowancePlan,
        policySummary summary: AllowanceSummary,
        asOf date: Date
    ) -> AllowanceRemainingAvailability {
        guard Self.allowanceFundingCompatibility(
            for: plan,
            accountsByID: accountsByID
        ) == .current,
        let accountID = plan.linkedAccountID,
        let account = accountsByID[accountID] else {
            return .unavailable(.ledgerCalculationFailed)
        }
        switch restrictedAllowanceBalanceResult(for: account, asOf: date) {
        case let .unavailable(issue):
            return .unavailable(issue)
        case let .available(balance):
            guard balance.currency == summary.remaining.currency,
                  balance.amount >= .zero else {
                return .unavailable(.ledgerCalculationFailed)
            }
            return availableAllowanceMoney(
                min(max(summary.remaining.amount, .zero), balance.amount),
                currency: summary.remaining.currency
            )
        }
    }

    private func availableAllowanceMoney(
        _ amount: Decimal,
        currency: CurrencyCode
    ) -> AllowanceRemainingAvailability {
        do {
            return .available(try Money(amount, currency: currency))
        } catch {
            return .unavailable(.amountCalculationFailed)
        }
    }
}
