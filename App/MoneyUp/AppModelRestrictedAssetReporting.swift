import Foundation
import MoneyUpCore

extension AppModel {
    func accountBalanceResultForPresentation(
        for account: LedgerAccount,
        asOf date: Date
    ) -> DerivedValue<Money> {
        account.accountType == .restrictedAllowance
            ? restrictedAllowanceBalanceResult(for: account, asOf: date)
            : displayBalanceResult(for: account)
    }

    /// Authoritative policy-bound stored value, kept separate by currency.
    ///
    /// This deliberately reads the exact point-in-time restricted ledger
    /// projection instead of allowance metadata or all-time ending balances.
    /// Archived accounts remain included because archiving must not erase value.
    func restrictedAllowanceValueByCurrencyResult(
        asOf requestedDate: Date? = nil
    ) -> DerivedValue<[Money]> {
        let date = requestedDate ?? currentDateForUserAction()
        let restrictedAccounts = allUserAccounts.filter {
            $0.accountType == .restrictedAllowance
        }
        guard !restrictedAccounts.isEmpty else { return .available([]) }

        var accountCurrencies: [(
            account: LedgerAccount,
            currency: CurrencyCode
        )] = []
        accountCurrencies.reserveCapacity(restrictedAccounts.count)
        for account in restrictedAccounts {
            guard let currency = account.currency else {
                DerivedValueDiagnostics.record(
                    .missingCurrency,
                    operation: "restricted-allowance-value-by-currency"
                )
                return .unavailable(.missingCurrency)
            }
            accountCurrencies.append((account, currency))
        }

        var totals: [CurrencyCode: Decimal] = [:]
        do {
            for item in accountCurrencies {
                let amount: Decimal
                switch restrictedAllowanceBalanceResult(
                    for: item.account,
                    asOf: date
                ) {
                case let .available(balance):
                    amount = balance.amount
                case let .unavailable(issue):
                    return .unavailable(issue)
                }
                totals[item.currency] = try CheckedDecimal.adding(
                    totals[item.currency] ?? .zero,
                    amount
                )
            }
            return .available(try totals.sorted { $0.key < $1.key }.map {
                try Money($0.value, currency: $0.key)
            })
        } catch {
            DerivedValueDiagnostics.record(
                .amountCalculationFailed,
                operation: "restricted-allowance-value-by-currency",
                error: error
            )
            return .unavailable(.amountCalculationFailed)
        }
    }
}
