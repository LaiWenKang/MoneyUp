import Foundation

public enum LedgerPresetScope: String, CaseIterable, Sendable {
    case accounts
    case expenses
}

/// Optional manual-entry templates. Merely listing a preset never creates data.
public struct LedgerPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let scope: LedgerPresetScope
    public let labelKey: String
    public let groupLabelKey: String
    public let symbol: String
    public let accountType: FinancialAccountType?
}

public enum LedgerPresetCatalog {
    public static let accounts: [LedgerPreset] = [
        account("cash", .cash, "bank", "banknote.fill"),
        account("current", .bank, "bank", "building.columns.fill"),
        account("savings", .bank, "bank", "banknote"),
        account("wallet", .eWallet, "wallet", "wallet.pass.fill"),
        account("wechat", .eWallet, "wallet", "message.fill"),
        account("alipay", .eWallet, "wallet", "creditcard.fill"),
        account("paypal", .eWallet, "wallet", "wallet.pass"),
        account("grabpay", .eWallet, "wallet", "wallet.pass.fill"),
        account("touchngo", .eWallet, "wallet", "wallet.pass.fill"),
        account("brokerage", .brokerage, "investment", "chart.line.uptrend.xyaxis"),
        account("investment", .investment, "investment", "chart.pie.fill"),
        account("other_asset", .other, "bank", "banknote"),
        account("retirement", .investment, "investment", "building.columns"),
        account("credit_card", .creditCard, "credit", "creditcard.fill"),
        account("mortgage", .loan, "credit", "house.fill"),
        account("vehicle_loan", .loan, "credit", "car.fill"),
        account("personal_loan", .loan, "credit", "person.fill"),
        account("other_loan", .loan, "credit", "doc.text.fill")
    ]

    public static let expenses: [LedgerPreset] = [
        expense("dining", "daily", "fork.knife"),
        expense("groceries", "daily", "basket.fill"),
        expense("coffee", "daily", "cup.and.saucer.fill"),
        expense("public_transport", "transport", "bus.fill"),
        expense("taxi", "transport", "car.fill"),
        expense("fuel", "transport", "fuelpump.fill"),
        expense("parking", "transport", "parkingsign.circle.fill"),
        expense("car_maintenance", "transport", "wrench.and.screwdriver.fill"),
        expense("rent", "home", "house.fill"),
        expense("electricity", "home", "bolt.fill"),
        expense("water", "home", "drop.fill"),
        expense("internet", "home", "wifi"),
        expense("phone", "home", "iphone"),
        expense("household", "home", "sofa.fill"),
        expense("home_repairs", "home", "hammer.fill"),
        expense("medical", "health", "cross.case.fill"),
        expense("dental", "health", "cross.case"),
        expense("insurance", "health", "shield.fill"),
        expense("fitness", "health", "figure.walk"),
        expense("clothing", "lifestyle", "tshirt.fill"),
        expense("electronics", "lifestyle", "laptopcomputer"),
        expense("entertainment", "lifestyle", "film.fill"),
        expense("subscriptions", "lifestyle", "repeat.circle.fill"),
        expense("travel", "lifestyle", "airplane"),
        expense("personal_care", "lifestyle", "sparkles"),
        expense("education", "family", "graduationcap.fill"),
        expense("books", "family", "books.vertical.fill"),
        expense("childcare", "family", "figure.and.child.holdinghands"),
        expense("pets", "family", "pawprint.fill"),
        expense("gifts", "other", "gift.fill"),
        expense("donations", "other", "heart.fill"),
        expense("taxes", "other", "doc.text.fill"),
        expense("fees", "other", "doc.plaintext"),
        expense("loan_interest", "other", "percent"),
        expense("other_expense", "other", "ellipsis.circle")
    ]

    public static func presets(for scope: LedgerPresetScope) -> [LedgerPreset] {
        scope == .accounts ? accounts : expenses
    }

    public static func preset(id: String) -> LedgerPreset? {
        (accounts + expenses).first { $0.id == id }
    }

    private static func account(
        _ id: String, _ type: FinancialAccountType, _ group: String, _ symbol: String
    ) -> LedgerPreset {
        LedgerPreset(id: "account.\(id)", scope: .accounts,
            labelKey: "catalog.account.\(id)", groupLabelKey: "catalog.group.\(group)",
            symbol: symbol, accountType: type)
    }

    private static func expense(_ id: String, _ group: String, _ symbol: String) -> LedgerPreset {
        LedgerPreset(id: "expense.\(id)", scope: .expenses,
            labelKey: "catalog.expense.\(id)", groupLabelKey: "catalog.group.\(group)",
            symbol: symbol, accountType: nil)
    }
}
