@testable import MoneyUp
import Foundation
import MoneyUpCore
import XCTest

final class RestrictedAssetVisibilityTests: XCTestCase {
    @MainActor
    func testRestrictedStoredValueUsesLedgerBalancesAcrossCurrenciesAndArchives()
        throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let activeSGD = LedgerAccount(
            name: "Meal card",
            kind: .asset,
            currency: fixture.sgd,
            accountType: .restrictedAllowance
        )
        let archivedSGD = LedgerAccount(
            name: "Prior meal card",
            kind: .asset,
            currency: fixture.sgd,
            accountType: .restrictedAllowance,
            isArchived: true
        )
        let activeUSD = LedgerAccount(
            name: "Travel card",
            kind: .asset,
            currency: fixture.usd,
            accountType: .restrictedAllowance
        )
        let equity = LedgerAccount(
            name: "Opening balances",
            kind: .equity,
            systemRole: .openingBalances
        )
        let entries = [
            try TransactionFactory.balanceAdjustment(
                displayBalanceDelta: Money(12.10, currency: fixture.sgd),
                accountID: activeSGD.id,
                equityAccountID: equity.id,
                accountIsLiability: false
            ),
            try TransactionFactory.balanceAdjustment(
                displayBalanceDelta: Money(0.20, currency: fixture.sgd),
                accountID: archivedSGD.id,
                equityAccountID: equity.id,
                accountIsLiability: false
            ),
            try TransactionFactory.balanceAdjustment(
                displayBalanceDelta: Money(7.50, currency: fixture.usd),
                accountID: activeUSD.id,
                equityAccountID: equity.id,
                accountIsLiability: false
            ),
            try TransactionFactory.balanceAdjustment(
                displayBalanceDelta: Money(100, currency: fixture.sgd),
                accountID: fixture.wallet.id,
                equityAccountID: equity.id,
                accountIsLiability: false
            )
        ]
        let model = fixture.model(
            accounts: [
                fixture.wallet,
                activeSGD,
                archivedSGD,
                activeUSD,
                equity,
                fixture.food
            ],
            entries: entries
        )

        let restricted = try XCTUnwrap(
            model.restrictedAllowanceValueByCurrencyResult().value
        )
        XCTAssertEqual(
            restricted.first { $0.currency == fixture.sgd }?.amount,
            Decimal(string: "12.30")
        )
        XCTAssertEqual(
            restricted.first { $0.currency == fixture.usd }?.amount,
            Decimal(string: "7.50")
        )
        XCTAssertEqual(restricted.count, 2)

        let headline = try XCTUnwrap(model.netWorthByCurrencyResult().value)
        XCTAssertEqual(headline.count, 1)
        XCTAssertEqual(headline.first?.currency, fixture.sgd)
        XCTAssertEqual(headline.first?.amount, 100)
    }

    @MainActor
    func testRestrictedStoredValueIsExplicitlyUnavailableWithoutCompleteLedger()
        throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let restricted = LedgerAccount(
            name: "Meal card",
            kind: .asset,
            currency: fixture.sgd,
            accountType: .restrictedAllowance
        )
        let model = fixture.model(
            accounts: [restricted, fixture.food],
            retainsCompleteJournal: false
        )

        guard case .unavailable(.appNotReady) =
            model.restrictedAllowanceValueByCurrencyResult() else {
            return XCTFail("An incomplete ledger must not present a false subtotal")
        }
    }

    @MainActor
    func testRestrictedStoredValueRequiresAccountCurrency() throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let restricted = LedgerAccount(
            name: "Malformed legacy card",
            kind: .asset,
            accountType: .restrictedAllowance
        )
        let model = fixture.model(accounts: [restricted, fixture.food])

        guard case .unavailable(.missingCurrency) =
            model.restrictedAllowanceValueByCurrencyResult() else {
            return XCTFail("A restricted value without currency must be unavailable")
        }
    }

    @MainActor
    func testRestrictedStoredValueRejectsDecimalOverflow() throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let huge = try XCTUnwrap(
            Decimal(string: "9e127", locale: Locale(identifier: "en_US_POSIX"))
        )
        let first = LedgerAccount(
            name: "First card",
            kind: .asset,
            currency: fixture.sgd,
            accountType: .restrictedAllowance
        )
        let second = LedgerAccount(
            name: "Second card",
            kind: .asset,
            currency: fixture.sgd,
            accountType: .restrictedAllowance
        )
        let equity = LedgerAccount(
            name: "Opening balances",
            kind: .equity,
            systemRole: .openingBalances
        )
        let entries = try [first, second].map { account in
            try TransactionFactory.balanceAdjustment(
                displayBalanceDelta: Money(huge, currency: fixture.sgd),
                accountID: account.id,
                equityAccountID: equity.id,
                accountIsLiability: false
            )
        }
        let model = fixture.model(
            accounts: [first, second, equity, fixture.food],
            entries: entries
        )

        guard case .unavailable(.amountCalculationFailed) =
            model.restrictedAllowanceValueByCurrencyResult() else {
            return XCTFail("A subtotal overflow must remain explicitly unavailable")
        }
        XCTAssertTrue(try XCTUnwrap(model.netWorthByCurrencyResult().value).isEmpty)
    }

    @MainActor
    func testRestrictedStoredValueIsUnavailableForNegativeAccountBalance() throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let restricted = LedgerAccount(
            name: "Malformed card",
            kind: .asset,
            currency: fixture.sgd,
            accountType: .restrictedAllowance
        )
        let equity = LedgerAccount(
            name: "Opening balances",
            kind: .equity,
            systemRole: .openingBalances
        )
        let malformed = try TransactionFactory.balanceAdjustment(
            displayBalanceDelta: Money(-1, currency: fixture.sgd),
            accountID: restricted.id,
            equityAccountID: equity.id,
            accountIsLiability: false
        )
        let model = fixture.model(
            accounts: [restricted, equity, fixture.food],
            entries: [malformed]
        )

        guard case .unavailable(.ledgerCalculationFailed) =
            model.restrictedAllowanceValueByCurrencyResult() else {
            return XCTFail("Negative restricted value must fail closed")
        }
    }

    func testRestrictedTypeIsTextualForActiveAndArchivedAccountRows() throws {
        let currency = try CurrencyCode("SGD")
        let active = LedgerAccount(
            name: "Meal card",
            kind: .asset,
            currency: currency,
            accountType: .restrictedAllowance
        )
        var archived = active
        archived.isArchived = true
        let cash = LedgerAccount(
            name: "Wallet",
            kind: .asset,
            currency: currency,
            accountType: .cash
        )

        XCTAssertEqual(
            AssetAccountRowPresentation.visibleAccountTypeKey(for: active),
            "account.type.restricted_allowance"
        )
        XCTAssertEqual(
            AssetAccountRowPresentation.visibleAccountTypeKey(for: archived),
            "account.type.restricted_allowance"
        )
        XCTAssertNil(
            AssetAccountRowPresentation.visibleAccountTypeKey(for: cash)
        )
    }

    func testRestrictedStoredValueCopyIsBilingualAndExplicitlyExcluded() {
        XCTAssertEqual(
            AppLocalization.string(
                "assets.restricted_stored_value",
                language: .english
            ),
            "Restricted stored value"
        )
        XCTAssertTrue(
            AppLocalization.string(
                "assets.restricted_stored_value_note",
                language: .english
            )
                .contains("excluded from headline net worth")
        )
        XCTAssertTrue(
            AppLocalization.string(
                "assets.account_net_worth_note",
                language: .english
            )
                .contains("headline excludes restricted allowance stored value")
        )

        XCTAssertEqual(
            AppLocalization.string(
                "assets.restricted_stored_value",
                language: .simplifiedChinese
            ),
            "受限储值"
        )
        XCTAssertTrue(
            AppLocalization.string(
                "assets.restricted_stored_value_note",
                language: .simplifiedChinese
            )
                .contains("不计入顶部净资产")
        )
        XCTAssertTrue(
            AppLocalization.string(
                "assets.account_net_worth_note",
                language: .simplifiedChinese
            )
                .contains("顶部净资产不含受限津贴储值")
        )
    }
}
