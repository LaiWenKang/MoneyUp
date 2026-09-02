import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

extension AppModel {
    struct LogicalBookReadToken: Equatable, Sendable {
        let storeGeneration: Int
        let logicalBookRevision: UInt64
    }

    /// Opens a read only while one stable, published book owns the live store.
    /// Normal restore intentionally keeps the same actor, so callers must use
    /// both halves of the returned authority token across every suspension.
    func beginLogicalBookRead()
    throws -> (store: EncryptedRecordStore, token: LogicalBookReadToken) {
        guard !isBookReplacementInProgress,
              let store else { throw AppModelError.locked }
        return (
            store,
            LogicalBookReadToken(
                storeGeneration: storeGeneration,
                logicalBookRevision: logicalBookRevision
            )
        )
    }

    func ownsLogicalBookRead(_ token: LogicalBookReadToken) -> Bool {
        !isBookReplacementInProgress
            && token.storeGeneration == storeGeneration
            && token.logicalBookRevision == logicalBookRevision
            && store != nil
    }

    func requireLogicalBookRead(_ token: LogicalBookReadToken) throws {
        guard ownsLogicalBookRead(token) else { throw AppModelError.locked }
    }

    func finishLogicalBookRead<Value>(
        _ value: Value,
        token: LogicalBookReadToken
    ) async throws -> Value {
        await lifecycleHooks.checkpoint(.afterBookScopedReadBeforeReturn)
        try requireLogicalBookRead(token)
        return value
    }

    func requireStore() throws -> EncryptedRecordStore {
        guard let store else { throw AppModelError.locked }
        return store
    }

    /// A missing profile is onboarding only when every durable book
    /// collection is truly empty. Decode quarantine must not turn an orphaned
    /// journal, audit, goal, or derived-accounting record into a fresh book.
    static func containsPersistedBookData(
        in store: EncryptedRecordStore
    ) async throws -> Bool {
        for collection in RecordCollection.allCases
        where collection != .profile && collection != .quickLogDrafts {
            if try await store.count(in: collection) > 0 { return true }
        }
        return false
    }

    func isCurrentStoreGeneration(_ generation: Int) -> Bool {
        ownsStoreGeneration(generation)
            && (state == .ready || state == .onboarding)
    }

    func ownsStoreGeneration(_ generation: Int) -> Bool {
        generation == storeGeneration && store != nil
    }

    func currency(for accountID: UUID) throws -> CurrencyCode {
        guard let account = accounts.first(where: { $0.id == accountID }),
              !account.isArchived else {
            throw AppModelError.ledgerItemArchived
        }
        guard account.systemRole == nil else {
            throw AppModelError.systemAccountLifecycleForbidden
        }
        guard account.kind == .asset || account.kind == .liability,
              let currency = account.currency else {
            throw AppModelError.accountHasNoCurrency
        }
        return currency
    }

    /// History corrections may keep an archived user account already present
    /// on the source entry. They must not make an archived account newly
    /// spendable, and hidden system accounts are never valid editor choices.
    func replacementCurrency(
        for accountID: UUID,
        preservingFrom original: JournalEntry
    ) throws -> CurrencyCode {
        guard let account = accounts.first(where: { $0.id == accountID }) else {
            throw AppModelError.missingRecord
        }
        guard account.systemRole == nil else {
            throw AppModelError.systemAccountLifecycleForbidden
        }
        guard account.kind == .asset || account.kind == .liability,
              let currency = account.currency else {
            throw AppModelError.accountHasNoCurrency
        }
        guard !account.isArchived || original.postings.contains(where: {
            $0.accountID == accountID
        }) else {
            throw AppModelError.ledgerItemArchived
        }
        return currency
    }

    func requireActiveCategory(
        _ id: UUID,
        kind: LedgerAccountKind
    ) throws {
        guard let category = accounts.first(where: { $0.id == id }) else {
            throw AppModelError.missingRecord
        }
        guard !category.isArchived else { throw AppModelError.ledgerItemArchived }
        guard category.systemRole == nil else {
            throw AppModelError.systemAccountLifecycleForbidden
        }
        guard category.kind == kind else {
            throw AppModelError.invalidCategoryKind
        }
    }

    /// Mirrors `replacementCurrency`: an archived category is valid only when
    /// it is part of the historical transaction being corrected.
    func requireReplacementCategory(
        _ id: UUID,
        kind: LedgerAccountKind,
        preservingFrom original: JournalEntry
    ) throws {
        guard let category = accounts.first(where: { $0.id == id }) else {
            throw AppModelError.missingRecord
        }
        guard category.systemRole == nil else {
            throw AppModelError.systemAccountLifecycleForbidden
        }
        guard category.kind == kind else {
            throw AppModelError.invalidCategoryKind
        }
        guard !category.isArchived || original.postings.contains(where: {
            $0.accountID == id
        }) else {
            throw AppModelError.ledgerItemArchived
        }
    }

    func editableMoneySnapshot(
        for entry: JournalEntry
    ) throws -> EditableMoneySnapshot? {
        let accountKinds = Dictionary(
            uniqueKeysWithValues: accounts.map { ($0.id, $0.kind) }
        )

        func positiveMoney(from posting: Posting) throws -> Money {
            do {
                return try Money(
                    abs(posting.money.amount),
                    currency: posting.money.currency
                )
            } catch {
                DerivedValueDiagnostics.record(
                    .amountCalculationFailed,
                    operation: "editable-money-snapshot",
                    error: error
                )
                throw DerivedValueIssue.amountCalculationFailed
            }
        }

        switch entry.kind {
        case .expense:
            guard let posting = entry.postings.first(where: {
                accountKinds[$0.accountID] == .asset
                    || accountKinds[$0.accountID] == .liability
            }) ?? entry.postings.first(where: {
                accountKinds[$0.accountID] == .expense
            }) else { return nil }
            let source = try positiveMoney(from: posting)
            return EditableMoneySnapshot(source: source, destination: nil)
        case .income:
            guard let posting = entry.postings.first(where: {
                accountKinds[$0.accountID] == .asset
                    || accountKinds[$0.accountID] == .liability
            }) ?? entry.postings.first(where: {
                accountKinds[$0.accountID] == .income
            }) else { return nil }
            let source = try positiveMoney(from: posting)
            return EditableMoneySnapshot(source: source, destination: nil)
        case .transfer:
            let userPostings = entry.postings.filter {
                accountKinds[$0.accountID] == .asset
                    || accountKinds[$0.accountID] == .liability
            }
            guard let sourcePosting = userPostings.first(where: {
                $0.money.amount < .zero
            }), let destinationPosting = userPostings.first(where: {
                $0.money.amount > .zero
            }) else { return nil }
            let source = try positiveMoney(from: sourcePosting)
            let destination = try positiveMoney(from: destinationPosting)
            return EditableMoneySnapshot(source: source, destination: destination)
        case .adjustment, .investment:
            return nil
        }
    }

    func reportingOriginContext(
        for occurredAt: Date,
        reportingTimeZoneIdentifier: String? = nil
    ) -> TransactionOriginContext {
        let calendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: reportingTimeZoneIdentifier
                ?? profile?.reportingTimeZoneIdentifier
                ?? TimeZone.current.identifier
        )
        return .capture(
            for: occurredAt,
            calendar: calendar,
            timeZone: calendar.timeZone
        )
    }

    /// All entries authored by MoneyUp use the encrypted profile's fixed
    /// reporting zone. Device travel must not move a DatePicker selection to
    /// an adjacent financial day before it reaches the normalized index.
    func appAuthoredEntry(
        _ entry: JournalEntry,
        reportingTimeZoneIdentifier: String? = nil,
        sourceSystemOverride: String? = nil,
        sourceFingerprintOverride: String? = nil
    ) throws -> JournalEntry {
        try JournalEntry(
            id: entry.id,
            kind: entry.kind,
            occurredAt: entry.occurredAt,
            createdAt: entry.createdAt,
            payee: entry.payee,
            note: entry.note,
            postings: entry.postings,
            supersedesID: entry.supersedesID,
            revisedAt: entry.revisedAt,
            sourceSystem: sourceSystemOverride ?? entry.sourceSystem,
            sourceFingerprint: sourceFingerprintOverride ?? entry.sourceFingerprint,
            originContext: reportingOriginContext(
                for: entry.occurredAt,
                reportingTimeZoneIdentifier: reportingTimeZoneIdentifier
            )
        )
    }

    func openingBalancesAccount() -> LedgerAccount {
        accounts.first(where: { $0.systemRole == .openingBalances })
            ?? LedgerAccount(
                name: AppLocalization.string("account.opening_balances"),
                kind: .equity,
                systemRole: .openingBalances
            )
    }

    func requireValidNewWriteAmount(
        _ amount: Decimal,
        currency: CurrencyCode,
        preserving originalAmount: Decimal? = nil
    ) throws {
        do {
            try MonetaryInputPolicy.validate(
                amount,
                currency: currency,
                preserving: originalAmount
            )
        } catch MoneyError.unsupportedPrecision(_) {
            throw AppModelError.unsupportedPrecision(currency)
        } catch MoneyError.exceedsNewWriteMaximum(_) {
            throw AppModelError.amountTooLarge
        } catch {
            throw error
        }
    }

    func foreignExchangeAccount(for currency: CurrencyCode) -> LedgerAccount {
        accounts.first {
            $0.systemRole == .foreignExchange && $0.currency == currency
        } ?? LedgerAccount(
            name: "\(AppLocalization.string("account.fx_clearing")) \(currency.value)",
            kind: .trading,
            currency: currency,
            systemRole: .foreignExchange
        )
    }

    func investmentGainLossAccount(for currency: CurrencyCode) -> LedgerAccount {
        accounts.first {
            $0.systemRole == .investmentGainLoss && $0.currency == currency
        } ?? LedgerAccount(
            name: "\(AppLocalization.string("holding.gain_loss")) \(currency.value)",
            kind: .trading,
            currency: currency,
            systemRole: .investmentGainLoss
        )
    }

    /// System adjustments and investment events require dedicated compensating
    /// workflows. Generic mutation would either erase reconciliation evidence
    /// or split persisted holding metadata from the authoritative journal.
    func isProtectedJournalEntry(_ entry: JournalEntry) -> Bool {
        entry.kind == .adjustment
            || entry.kind == .investment
            || loanPlans.contains { plan in
                plan.activities.contains { $0.journalEntryID == entry.id }
            }
            || entry.postings.contains {
                accountsByID[$0.accountID]?.systemRole == .investmentPosition
            }
    }

    func isEligibleInvestmentFundingAccount(
        _ account: LedgerAccount
    ) -> Bool {
        !account.isArchived && isInvestmentFundingAccountShape(account)
    }

    func isInvestmentFundingAccountShape(
        _ account: LedgerAccount
    ) -> Bool {
        account.kind == .asset
            && account.systemRole == nil
            && (account.accountType == .brokerage
                || account.accountType == .investment)
            && account.currency != nil
    }

    func linkedInvestmentAccounts(
        for holding: InvestmentHolding
    ) -> (
        funding: LedgerAccount,
        position: LedgerAccount,
        currency: CurrencyCode
    )? {
        guard let positionID = holding.positionAccountID,
              positionID != holding.accountID,
              let funding = accountsByID[holding.accountID],
              isEligibleInvestmentFundingAccount(funding),
              let currency = funding.currency,
              let position = accountsByID[positionID],
              !position.isArchived,
              position.kind == .asset,
              position.systemRole == .investmentPosition,
              position.currency == currency else {
            return nil
        }
        return (funding, position, currency)
    }

    func investmentOriginContext(for date: Date) -> TransactionOriginContext {
        reportingOriginContext(for: date)
    }

    func validatedInvestmentPositionValue(
        quantity: Decimal,
        unitPrice: Money
    ) throws -> Money {
        let value: Money
        do {
            value = try InvestmentHolding.positionValue(
                quantity: quantity,
                unitPrice: unitPrice
            )
        } catch InvestmentHoldingError.arithmeticOverflow {
            throw AppModelError.amountTooLarge
        }
        try requireValidNewWriteAmount(value.amount, currency: value.currency)
        return value
    }

    func validatedInvestmentMarketValue(
        _ holding: InvestmentHolding
    ) throws -> Money? {
        guard let price = holding.price else { return nil }
        return try validatedInvestmentPositionValue(
            quantity: holding.quantity,
            unitPrice: price
        )
    }

    func checkedInvestmentDifference(
        _ left: Decimal,
        _ right: Decimal
    ) throws -> Decimal {
        do {
            return try CheckedDecimal.subtracting(left, right)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AppModelError.amountTooLarge
        }
    }

    func checkedEstimatedSum(
        _ left: Decimal,
        _ right: Decimal
    ) throws -> Decimal {
        do {
            return try CheckedDecimal.adding(left, right)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AppModelError.amountTooLarge
        }
    }

    func performInvestmentDomainOperation<Value>(
        _ operation: () throws -> Value
    ) throws -> Value {
        do {
            return try operation()
        } catch let error as InvestmentHoldingError {
            switch error {
            case .arithmeticOverflow:
                throw AppModelError.amountTooLarge
            case .activityOutOfOrder:
                throw AppModelError.investmentDateOutOfOrder
            case .insufficientQuantity:
                throw AppModelError.insufficientInvestmentQuantity
            case .lotCurrencyMismatch, .valuationCurrencyMismatch:
                throw AppModelError.investmentCurrencyMismatch
            case .quantityCannotBeNegative, .priceCannotBeNegative,
                 .lotQuantityMustBePositive, .lotRemainingQuantityInvalid:
                throw AppModelError.invalidInvestmentTrade
            case .lotQuantityMismatch, .duplicateIdentifier,
                 .duplicateLinkedEntry, .invalidDisposal, .historyMismatch:
                throw AppModelError.invalidBook
            case .correctionUnavailable:
                throw AppModelError.invalidInvestmentTrade
            }
        }
    }

    func beginInvestmentMutation(id: UUID) throws {
        guard investmentMutationsInProgress.insert(id).inserted else {
            throw AppModelError.transactionInProgress
        }
    }

    func validateInvestmentActivityDate(
        _ date: Date,
        after latestDate: Date?
    ) throws {
        // A one-second tolerance avoids rejecting a Date captured immediately
        // before this main-actor validation executes.
        guard date <= Date().addingTimeInterval(1) else {
            throw AppModelError.investmentDateInFuture
        }
        if let latestDate, date < latestDate {
            throw AppModelError.investmentDateOutOfOrder
        }
    }

    func positionLedgerValue(
        id: UUID,
        currency: CurrencyCode
    ) throws -> Money {
        switch accountBalancesResult() {
        case let .available(balances):
            return balances[id]?[currency] ?? Money.zero(currency: currency)
        case .unavailable:
            throw AppModelError.invalidBook
        }
    }
}
