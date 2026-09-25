import Foundation
import MoneyUpCore
@testable import MoneyUp
import XCTest

/// Cross-feature combinations and bounded stress, all through AppModel's real
/// write paths. After every step the ledger must still balance per currency,
/// balances must move by exactly the logged amount, and undo must restore them.
@MainActor
final class CrossFeatureAndStressTests: XCTestCase {
    private struct Book {
        let accounts: [LedgerAccount]
        let wallet: LedgerAccount
        let usd: LedgerAccount
        let food: LedgerAccount
        let transport: LedgerAccount
        let salary: LedgerAccount
    }

    private func book(_ fixture: AppModelFixture) throws -> Book {
        let base = AppModel.defaultBook(mainAccount: fixture.wallet)
        let expenses = base.accounts.filter { $0.kind == .expense && $0.systemRole == nil }
        let food = try XCTUnwrap(expenses.first)
        let transport = try XCTUnwrap(expenses.dropFirst().first)
        let salary = base.accounts.first { $0.kind == .income && $0.systemRole == nil }
            ?? LedgerAccount(name: "Salary", kind: .income)
        var accounts = base.accounts + [fixture.usAccount]
        if !accounts.contains(where: { $0.id == salary.id }) { accounts.append(salary) }
        return Book(accounts: accounts, wallet: fixture.wallet, usd: fixture.usAccount,
                    food: food, transport: transport, salary: salary)
    }

    private func model(_ fixture: AppModelFixture, _ book: Book, entries: [JournalEntry] = [],
                       profile: UserProfile? = nil) async throws -> AppModel {
        let profile = profile ?? UserProfile(baseCurrency: fixture.sgd, reportingTimeZoneIdentifier: "UTC")
        try await fixture.seed(profile: profile, accounts: book.accounts, entries: entries)
        return fixture.model(profile: profile, accounts: book.accounts, entries: entries)
    }

    private func balance(_ model: AppModel, _ account: LedgerAccount) -> Decimal {
        guard let currency = account.currency else { return 0 }
        return model.accountBalancesResult().value?[account.id]?[currency]?.amount ?? 0
    }

    private func assertLedgerBalances(_ model: AppModel, _ step: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        for entry in model.entries {
            var totals: [CurrencyCode: Decimal] = [:]
            for posting in entry.postings { totals[posting.money.currency, default: 0] += posting.money.amount }
            for (currency, total) in totals {
                XCTAssertEqual(total, 0, "\(step): entry \(entry.id) is unbalanced in \(currency)",
                               file: file, line: line)
            }
        }
    }

    // MARK: Cross-feature matrix

    func testEveryKindSplitCurrencyAndFavouriteCombinationBalancesAndUndoes() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let book = try book(fixture)
        let model = try await model(fixture, book)
        let when = Date(timeIntervalSince1970: 1_790_000_000)
        let sgd = fixture.sgd

        typealias Step = (name: String, walletDelta: Decimal, write: () async throws -> UUID?)
        let lunch = QuickLogFavourite(name: "Lunch", kind: .expense, amount: 7,
                                      accountID: book.wallet.id, categoryID: book.food.id)
        let filled = QuickLogFavouriteFill.fill(
            lunch,
            current: QuickLogDraft(kind: .expense, amountText: "", destinationAmountText: "", accountID: nil,
                                   destinationAccountID: nil, categoryID: nil, occurredAt: when,
                                   dateWasEdited: false, payee: "", note: "", smartText: ""),
            usableAccountIDs: [book.wallet.id], usableCategoryIDs: [book.food.id],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let steps: [Step] = [
            ("expense", -12.5, {
                try await model.logExpense(amount: 12.5, accountID: book.wallet.id, categoryID: book.food.id,
                                           occurredAt: when, payee: "Hawker", note: nil)
            }),
            ("expense split", -30, {
                try await model.logSplitTransaction(kind: .expense, amount: 30, accountID: book.wallet.id, lines: [
                    TransactionSplitLine(categoryAccountID: book.food.id, amount: try Money(18, currency: sgd), memo: nil),
                    TransactionSplitLine(categoryAccountID: book.transport.id, amount: try Money(12, currency: sgd), memo: nil)
                ], occurredAt: when, payee: "Mall", note: nil)
            }),
            ("income", 1_000, {
                try await model.logIncome(amount: 1_000, accountID: book.wallet.id, categoryID: book.salary.id,
                                          occurredAt: when, payee: "Employer", note: nil)
            }),
            ("refund", 4, {
                try await model.logRefund(amount: 4, accountID: book.wallet.id, categoryID: book.food.id,
                                          occurredAt: when, payee: "Hawker", note: nil)
            }),
            ("cross-currency transfer", -135, {
                try await model.logTransfer(amount: 135, destinationAmount: 100, sourceAccountID: book.wallet.id,
                                            destinationAccountID: book.usd.id, occurredAt: when,
                                            payee: nil, note: nil)
            }),
            ("expense from a favourite", -7, {
                let amount = try XCTUnwrap(decimalAmount(from: filled.amountText,
                                                         locale: Locale(identifier: "en_US_POSIX")))
                return try await model.logExpense(
                    amount: amount, accountID: try XCTUnwrap(filled.accountID),
                    categoryID: try XCTUnwrap(filled.categoryID), occurredAt: when,
                    payee: filled.payee, note: nil
                )
            })
        ]

        for step in steps {
            let before = balance(model, book.wallet)
            let count = model.entries.count
            let id = try await step.write()
            XCTAssertEqual(model.entries.count, count + 1, step.name)
            XCTAssertEqual(balance(model, book.wallet) - before, step.walletDelta, step.name)
            assertLedgerBalances(model, step.name)
            try await model.deleteEntry(id: try XCTUnwrap(id, step.name))
            XCTAssertEqual(balance(model, book.wallet), before, "\(step.name): undo must restore the balance")
            XCTAssertEqual(model.entries.count, count, "\(step.name): undo must remove the entry")
        }
        XCTAssertEqual(balance(model, book.usd), 0, "Every transfer was undone")
    }

    func testLockedCaptureRoutingMatrixAcrossKindsOptInAndTitles() throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let book = try book(fixture)
        let lunch = QuickLogFavourite(name: "Lunch", kind: .expense, accountID: book.wallet.id,
                                      categoryID: book.food.id)
        let salary = QuickLogFavourite(name: "Salary", kind: .income, accountID: book.wallet.id,
                                       categoryID: book.salary.id)
        let kinds: [LockedCaptureKind] = [.expense, .income, .transfer, .refund]
        for optIn in [true, false] {
            let profile = UserProfile(baseCurrency: fixture.sgd, quickLogFavourites: [lunch, salary],
                                      showsFavouritesWhileLocked: optIn)
            let model = fixture.model(profile: profile, accounts: book.accounts)
            for kind in kinds {
                for title in ["Lunch", "Salary", "Other", ""] {
                    let routing = model.lockedFavouriteRouting(
                        for: LockedCapture(kind: kind, amountText: "5", payee: title)
                    )
                    let expected = optIn && ((kind == .expense && title == "Lunch")
                        || (kind == .income && title == "Salary"))
                    XCTAssertEqual(routing != nil, expected, "optIn \(optIn) kind \(kind) title \(title)")
                }
            }
        }
    }

    // MARK: Stress

    func testRapidSequentialSavesAndDeletesKeepTheLedgerExact() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let book = try book(fixture)
        let model = try await model(fixture, book)
        var generator = SystemRandomNumberGenerator()
        var expected: Decimal = 0
        var ids: [UUID] = []
        for index in 0..<300 {
            let cents = Decimal(Int.random(in: 1...50_000, using: &generator)) / 100
            let id = try await model.logExpense(
                amount: cents, accountID: book.wallet.id,
                categoryID: index.isMultiple(of: 2) ? book.food.id : book.transport.id,
                occurredAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(index)),
                payee: "Stress \(index)", note: nil
            )
            ids.append(try XCTUnwrap(id))
            expected -= cents
        }
        XCTAssertEqual(model.entries.count, 300)
        XCTAssertEqual(balance(model, book.wallet), expected, "300 rapid saves must sum exactly")
        for id in ids.prefix(150) { try await model.deleteEntry(id: id) }
        XCTAssertEqual(model.entries.count, 150)
        assertLedgerBalances(model, "after churn")
    }

    func testFavouritesChurnStaysBoundedUniqueAndPersisted() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let book = try book(fixture)
        let model = try await model(fixture, book)
        var generator = SystemRandomNumberGenerator()
        for step in 0..<200 {
            let favourites = model.quickLogFavourites
            switch Int.random(in: 0..<4, using: &generator) {
            case 0 where model.canAddQuickLogFavourite:
                try await model.saveQuickLogFavourite(
                    QuickLogFavourite(name: "F\(step)", kind: .expense, categoryID: book.food.id)
                )
            case 1 where !favourites.isEmpty:
                var renamed = favourites[Int.random(in: 0..<favourites.count, using: &generator)]
                renamed.name = "R\(step)"
                try await model.saveQuickLogFavourite(renamed)
            case 2 where favourites.count > 1:
                try await model.moveQuickLogFavourites(
                    fromOffsets: IndexSet(integer: favourites.count - 1), toOffset: 0
                )
            case 3 where !favourites.isEmpty:
                try await model.deleteQuickLogFavourite(id: favourites[0].id)
            default:
                continue
            }
            XCTAssertLessThanOrEqual(model.quickLogFavourites.count, QuickLogFavourite.maximumCount)
            XCTAssertEqual(Set(model.quickLogFavourites.map(\.id)).count, model.quickLogFavourites.count)
        }
        XCTAssertTrue(model.entries.isEmpty, "Favourite churn must never post")
        await fixture.store.close()
        let reopened = try fixture.reopenStore()
        let saved = try await reopened.fetch(UserProfile.self, id: UserProfile.primaryRecordID, from: .profile)
        XCTAssertEqual(saved?.quickLogFavourites, model.quickLogFavourites)
        await reopened.close()
    }

    func testLargeBookProjectionsStayResponsive() throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let book = try book(fixture)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = try (0..<5_000).map { index in
            try TransactionFactory.expense(
                amount: Money(Decimal(index % 97 + 1) / 4, currency: fixture.sgd),
                paidFrom: book.wallet.id,
                category: index.isMultiple(of: 3) ? book.transport.id : book.food.id,
                occurredAt: start.addingTimeInterval(Double(index) * 3_600),
                payee: "Merchant \(index % 50)"
            )
        }
        let model = fixture.model(accounts: book.accounts, entries: entries)
        let began = Date()
        let balances = model.accountBalancesResult()
        let elapsed = Date().timeIntervalSince(began)
        let expected = (0..<5_000).reduce(Decimal.zero) { $0 - Decimal($1 % 97 + 1) / 4 }
        XCTAssertNotNil(balances.value, "A 5,000-entry book must project balances")
        XCTAssertEqual(balances.value?[book.wallet.id]?[fixture.sgd]?.amount, expected)
        XCTAssertLessThan(elapsed, 10, "Balance projection took \(elapsed)s for 5,000 entries")
        assertLedgerBalances(model, "large book")
    }

    // MARK: Error injection and extremes

    func testFavouriteSaveFailsCleanlyWhenTheStoreIsGone() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let book = try book(fixture)
        let model = try await model(fixture, book)
        try await model.saveQuickLogFavourite(QuickLogFavourite(name: "Kept", kind: .expense))
        await fixture.store.close()
        do {
            try await model.saveQuickLogFavourite(QuickLogFavourite(name: "Lost", kind: .expense))
            XCTFail("A closed store must reject the write")
        } catch {
            XCTAssertEqual(model.quickLogFavourites.map(\.name), ["Kept"],
                           "A failed write must leave the visible favourites unchanged")
        }
        do {
            try await model.deleteQuickLogFavourite(id: model.quickLogFavourites[0].id)
            XCTFail("A closed store must reject the delete")
        } catch {
            XCTAssertEqual(model.quickLogFavourites.count, 1)
        }
    }

    func testFavouriteSaveInterruptedAtTheProfileWriteChangesNothing() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let book = try book(fixture)
        let profile = UserProfile(baseCurrency: fixture.sgd, reportingTimeZoneIdentifier: "UTC")
        try await fixture.seed(profile: profile, accounts: book.accounts)
        let store = fixture.store
        let model = fixture.model(
            profile: profile, accounts: book.accounts,
            lifecycleHooks: AppModelLifecycleHooks { checkpoint in
                if checkpoint == .beforeProfileWrite { await store.close() }
            }
        )
        do {
            try await model.saveQuickLogFavourite(QuickLogFavourite(name: "Midway", kind: .expense))
            XCTFail("Losing the store at the write boundary must fail the save")
        } catch {
            XCTAssertTrue(model.quickLogFavourites.isEmpty, "Nothing half-applied")
        }
        let reopened = try fixture.reopenStore()
        let saved = try await reopened.fetch(UserProfile.self, id: UserProfile.primaryRecordID, from: .profile)
        XCTAssertEqual(saved?.quickLogFavourites ?? [], [], "Nothing half-persisted")
        await reopened.close()
    }

    func testExtremeFavouriteValuesStayBoundedAndRoundTrip() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let book = try book(fixture)
        let model = try await model(fixture, book)
        let extremes = [
            QuickLogFavourite(name: String(repeating: "🍜", count: 60), kind: .expense,
                              amount: QuickLogFavourite.maximumAmount, payee: String(repeating: "长", count: 400)),
            QuickLogFavourite(name: "午饭 · ランチ · Lunch", kind: .income, amount: Decimal(string: "0.01")),
            QuickLogFavourite(name: " \u{202E}rtl ", kind: .expense, note: String(repeating: "n", count: 5_000))
        ]
        for favourite in extremes { try await model.saveQuickLogFavourite(favourite) }
        XCTAssertEqual(model.quickLogFavourites.count, 3)
        for favourite in model.quickLogFavourites {
            XCTAssertLessThanOrEqual(favourite.name.count, QuickLogFavourite.maximumNameLength)
            XCTAssertLessThanOrEqual(favourite.payee.count, QuickLogFavourite.maximumPayeeLength)
            XCTAssertLessThanOrEqual(favourite.note.count, QuickLogFavourite.maximumNoteLength)
        }
        let beyond = QuickLogFavourite(name: "Too much", kind: .expense, amount: QuickLogFavourite.maximumAmount + 1)
        XCTAssertNil(beyond.amount, "Amounts past the ceiling are rejected, not truncated")
    }

    func testZeroDecimalCurrencyRejectsAFractionalFavouriteAmountAtEntry() throws {
        let jpy = try CurrencyCode("JPY")
        let yenWallet = LedgerAccount(name: "Yen", kind: .asset, currency: jpy)
        let snack = QuickLogFavourite(name: "Snack", kind: .expense, amount: Decimal(string: "3.5"),
                                      accountID: yenWallet.id)
        let filled = QuickLogFavouriteFill.fill(
            snack,
            current: QuickLogDraft(kind: .expense, amountText: "", destinationAmountText: "", accountID: nil,
                                   destinationAccountID: nil, categoryID: nil, occurredAt: Date(),
                                   dateWasEdited: false, payee: "", note: "", smartText: ""),
            usableAccountIDs: [yenWallet.id], usableCategoryIDs: [],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let amount = try XCTUnwrap(decimalAmount(from: filled.amountText, locale: Locale(identifier: "en_US_POSIX")))
        XCTAssertFalse(MonetaryInputPolicy.accepts(amount, currency: jpy),
                       "A fractional yen amount must be caught by entry validation, not saved")
        XCTAssertTrue(MonetaryInputPolicy.accepts(4, currency: jpy))
    }
}
