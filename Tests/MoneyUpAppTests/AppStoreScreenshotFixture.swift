import Foundation
import MoneyUpCore
@testable import MoneyUp
import XCTest

/// Fictional, balanced journals used only by the screenshot test target.
/// Each locale gets its own database; no production or installed book is read.
enum AppStoreScreenshotFixture {
    @MainActor
    static func make(chinese: Bool) async throws -> (AppModelFixture, AppModel, AppReportingSnapshot) {
        let fixture = try AppModelFixture()
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-18T04:00:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Singapore"))
        func label(_ en: String, _ zh: String) -> String { chinese ? zh : en }
        let daily = LedgerAccount(name: label("Everyday", "日常账户"), kind: .asset, currency: fixture.sgd, accountType: .bank)
        let savings = LedgerAccount(name: label("Savings", "储蓄账户"), kind: .asset, currency: fixture.sgd, accountType: .bank)
        let travel = LedgerAccount(name: label("Travel wallet", "旅行钱包"), kind: .asset, currency: fixture.usd, accountType: .cash)
        let equity = LedgerAccount(name: "Opening balances", kind: .equity, systemRole: .openingBalances)
        let salary = LedgerAccount(name: label("Salary", "工资"), kind: .income)
        let names = [("Food & coffee", "餐饮咖啡"), ("Groceries", "日常采购"), ("Transport", "交通出行"),
                     ("Shopping", "购物"), ("Home", "居家生活"), ("Leisure", "休闲娱乐")]
        let categories = names.map { LedgerAccount(name: label($0.0, $0.1), kind: .expense) }
        let accounts = [daily, savings, travel, equity, salary] + categories
        let entries = try makeEntries(now: now, calendar: calendar, daily: daily, savings: savings,
                                      travel: travel, equity: equity, salary: salary,
                                      categories: categories, chinese: chinese, fixture: fixture)
        let limits: [Decimal] = [900, 650, 300, 500, 1800, 350]
        let nodes = try zip(categories, limits).map { category, limit in
            BudgetNode(id: category.id, name: category.name, limit: try Money(limit, currency: fixture.sgd),
                       purpose: category.id == categories[4].id ? .commitment : .flexible)
        }
        let goals = try makeGoals(now: now, calendar: calendar, currency: fixture.sgd, chinese: chinese)
        let draft = QuickLogDraft(kind: .expense, amountText: "18.60", destinationAmountText: "",
                                 accountID: daily.id, destinationAccountID: nil, categoryID: categories[0].id,
                                 occurredAt: now, dateWasEdited: false, payee: label("Corner café", "街角咖啡"),
                                 note: "", smartText: "")
        let profile = UserProfile(baseCurrency: fixture.sgd, createdAt: now.addingTimeInterval(-86_400 * 180),
                                  preferredAccountID: daily.id, preferredExpenseCategoryID: categories[0].id,
                                  preferredIncomeCategoryID: salary.id, reportingTimeZoneIdentifier: calendar.timeZone.identifier,
                                  pinnedBudgetNodeIDs: Array(categories.prefix(4).map(\.id)))
        try await fixture.seed(profile: profile, accounts: accounts, entries: entries, budgetNodes: nodes,
                               savingsGoals: goals, quickLogDraft: draft)
        let model = fixture.model(profile: profile, accounts: accounts, entries: entries, budgetNodes: nodes,
                                  savingsGoals: goals, quickLogDraft: draft, currentDate: { now })
        return (fixture, model, AppReportingSnapshot(instant: now, calendar: calendar))
    }

    private static func makeEntries(now: Date, calendar: Calendar, daily: LedgerAccount,
                                    savings: LedgerAccount, travel: LedgerAccount, equity: LedgerAccount,
                                    salary: LedgerAccount, categories: [LedgerAccount], chinese: Bool,
                                    fixture: AppModelFixture) throws -> [JournalEntry] {
        let opening = try XCTUnwrap(calendar.date(byAdding: .month, value: -3, to: now))
        var entries = try [(daily, Decimal(12_450), fixture.sgd), (savings, 18_600, fixture.sgd),
                           (travel, 1250, fixture.usd)].map { account, amount, currency in
            try TransactionFactory.balanceAdjustment(displayBalanceDelta: Money(amount, currency: currency),
                accountID: account.id, equityAccountID: equity.id, accountIsLiability: false, occurredAt: opening)
        }
        let payees = [("Corner café", "街角咖啡"), ("Fresh market", "生鲜市集"), ("City transit", "城市交通"),
                      ("Everyday essentials", "生活好物"), ("Home & utilities", "住房水电"), ("Cinema tickets", "电影票")]
        let amounts: [Decimal] = [Decimal(string: "18.60")!, Decimal(string: "68.40")!, Decimal(string: "9.80")!,
                                  Decimal(string: "78.90")!, 1450, Decimal(string: "32.50")!]
        // Plausible local times per category; an entry on the preview day stays before `now`.
        let minutesAfterMidnight = [8 * 60 + 15, 18 * 60 + 30, 7 * 60 + 40, 13 * 60 + 10, 9 * 60, 19 * 60 + 45]
        for monthOffset in -2...0 {
            let month = try XCTUnwrap(calendar.date(byAdding: .month, value: monthOffset, to: now))
            let start = try XCTUnwrap(calendar.dateInterval(of: .month, for: month)?.start)
            entries.append(try TransactionFactory.income(amount: Money(6850, currency: fixture.sgd),
                depositedInto: daily.id, category: salary.id, occurredAt: start.addingTimeInterval(9 * 3600),
                payee: chinese ? "月度工资" : "Monthly salary"))
            let lastDay = monthOffset == 0 ? 18 : 28
            for day in 1...lastDay {
                let index = (day - 1) % categories.count
                let dayStart = try XCTUnwrap(calendar.date(byAdding: .day, value: day - 1, to: start))
                let planned = dayStart.addingTimeInterval(TimeInterval(minutesAfterMidnight[index] * 60))
                let date = planned < now ? planned : dayStart.addingTimeInterval(11.5 * 3600)
                // Housing occurs once per month; other categories build a natural history.
                if index == 4 && day > 6 { continue }
                entries.append(try TransactionFactory.expense(amount: Money(amounts[index], currency: fixture.sgd),
                    paidFrom: daily.id, category: categories[index].id, occurredAt: date,
                    payee: chinese ? payees[index].1 : payees[index].0))
            }
        }
        // A realistic busy day makes the default Today history useful in the
        // store preview without changing the production filter behavior.
        for (index, amount, hour) in [(0, "12.80", 8), (2, "3.20", 7), (1, "46.70", 10), (3, "29.90", 11)] {
            let date = calendar.startOfDay(for: now).addingTimeInterval(TimeInterval(hour * 3600))
            entries.append(try TransactionFactory.expense(
                amount: Money(XCTUnwrap(Decimal(string: amount)), currency: fixture.sgd),
                paidFrom: daily.id, category: categories[index].id, occurredAt: date,
                payee: chinese ? payees[index].1 : payees[index].0))
        }
        return entries
    }

    private static func makeGoals(now: Date, calendar: Calendar, currency: CurrencyCode,
                                  chinese: Bool) throws -> [SavingsGoal] {
        let targets: [(String, String, Decimal, Decimal, Int)] = [
            ("Emergency fund", "安心储备金", 15_000, 10_800, 9),
            ("Next adventure", "下一站旅行", 6000, 3450, 6),
            ("A place of our own", "理想的小家", 40_000, 12_600, 24)
        ]
        return try targets.map { en, zh, target, saved, months in
            try SavingsGoal(name: chinese ? zh : en, kind: .savingsGoal, target: Money(target, currency: currency),
                targetDate: XCTUnwrap(calendar.date(byAdding: .month, value: months, to: now)),
                createdAt: now.addingTimeInterval(-86_400 * 120),
                movements: [SavingsGoalMovement(kind: .contribution, money: Money(saved, currency: currency),
                    occurredAt: now.addingTimeInterval(-86_400), originTimeZoneIdentifier: calendar.timeZone.identifier)],
                reportingTimeZoneIdentifier: calendar.timeZone.identifier)
        }
    }
}
