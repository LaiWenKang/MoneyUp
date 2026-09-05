import Foundation
import MoneyUpCore
import MoneyUpPersistence

struct RestrictedAllowanceProjectionClockIdentity: Equatable, Sendable {
    let logicalBookRevision: UInt64
    let journalProjectionRevision: UInt64
    let projectedAt: Date
    let nextChangeAt: Date?
}

/// Compact, book-bound restricted stored value at one exact instant.
///
/// The ending-balance index is adjusted by only indexed future deltas. Retained
/// state is O(restricted accounts), plus one future-change boundary.
struct RestrictedAllowanceBalanceProjection: Sendable {
    private struct AccountBalance: Sendable {
        let currency: CurrencyCode
        let amount: Decimal
    }

    let logicalBookRevision: UInt64
    let journalProjectionRevision: UInt64
    let projectedAt: Date
    let nextChangeAt: Date?
    private let balancesByAccountID: [UUID: AccountBalance]

    var clockIdentity: RestrictedAllowanceProjectionClockIdentity {
        RestrictedAllowanceProjectionClockIdentity(
            logicalBookRevision: logicalBookRevision,
            journalProjectionRevision: journalProjectionRevision,
            projectedAt: projectedAt,
            nextChangeAt: nextChangeAt
        )
    }

    static func make(
        expectedCurrencies: [UUID: CurrencyCode],
        endingBalances: [UUID: [CurrencyCode: Money]],
        futureEvents: [LedgerPostingEvent],
        projectedAt: Date,
        logicalBookRevision: UInt64,
        journalProjectionRevision: UInt64,
        observesCancellation: Bool
    ) throws -> Self {
        guard projectedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw AppModelError.invalidBook
        }
        let future = try futureDeltas(
            expectedCurrencies: expectedCurrencies,
            events: futureEvents,
            after: projectedAt,
            observesCancellation: observesCancellation
        )
        return Self(
            logicalBookRevision: logicalBookRevision,
            journalProjectionRevision: journalProjectionRevision,
            projectedAt: projectedAt,
            nextChangeAt: future.nextChangeAt,
            balancesByAccountID: try projectedBalances(
                expectedCurrencies: expectedCurrencies,
                endingBalances: endingBalances,
                futureDeltas: future.deltas,
                projectedAt: projectedAt,
                observesCancellation: observesCancellation
            )
        )
    }

    func matches(
        logicalBookRevision: UInt64,
        journalProjectionRevision: UInt64
    ) -> Bool {
        self.logicalBookRevision == logicalBookRevision
            && self.journalProjectionRevision == journalProjectionRevision
    }

    func contains(_ date: Date) -> Bool {
        guard date.timeIntervalSinceReferenceDate.isFinite,
              date >= projectedAt else { return false }
        return nextChangeAt.map { date < $0 } ?? true
    }

    func balance(
        for accountID: UUID,
        currency: CurrencyCode,
        asOf date: Date
    ) throws -> Money? {
        guard contains(date),
              let balance = balancesByAccountID[accountID],
              balance.currency == currency else { return nil }
        return try Money(balance.amount, currency: currency)
    }

    func rebased(logicalBookRevision: UInt64) -> Self {
        Self(
            logicalBookRevision: logicalBookRevision,
            journalProjectionRevision: journalProjectionRevision,
            projectedAt: projectedAt,
            nextChangeAt: nextChangeAt,
            balancesByAccountID: balancesByAccountID
        )
    }

    private static func futureDeltas(
        expectedCurrencies: [UUID: CurrencyCode],
        events: [LedgerPostingEvent],
        after projectedAt: Date,
        observesCancellation: Bool
    ) throws -> (deltas: [UUID: Decimal], nextChangeAt: Date?) {
        var deltas: [UUID: Decimal] = [:]
        var nextChangeAt: Date?
        for (offset, event) in events.enumerated() {
            if observesCancellation, offset.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            guard event.occurredAt > projectedAt else { continue }
            let accountID = event.posting.accountID
            guard let currency = expectedCurrencies[accountID],
                  event.occurredAt.timeIntervalSinceReferenceDate.isFinite,
                  event.posting.money.currency == currency else {
                throw RestrictedAllowanceLedgerInvariantError.currencyMismatch(
                    accountID
                )
            }
            do {
                deltas[accountID] = try CheckedDecimal.adding(
                    deltas[accountID] ?? .zero,
                    event.posting.money.amount
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw RestrictedAllowanceLedgerInvariantError.arithmeticFailure(
                    accountID
                )
            }
            nextChangeAt = min(nextChangeAt ?? event.occurredAt, event.occurredAt)
        }
        return (deltas, nextChangeAt)
    }

    private static func projectedBalances(
        expectedCurrencies: [UUID: CurrencyCode],
        endingBalances: [UUID: [CurrencyCode: Money]],
        futureDeltas: [UUID: Decimal],
        projectedAt: Date,
        observesCancellation: Bool
    ) throws -> [UUID: AccountBalance] {
        var result: [UUID: AccountBalance] = [:]
        for (offset, item) in expectedCurrencies.enumerated() {
            if observesCancellation, offset.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            let ending = endingBalances[item.key]?[item.value]?.amount ?? .zero
            let amount: Decimal
            do {
                amount = try CheckedDecimal.subtracting(
                    ending,
                    futureDeltas[item.key] ?? .zero
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw RestrictedAllowanceLedgerInvariantError.arithmeticFailure(
                    item.key
                )
            }
            guard amount >= .zero else {
                throw RestrictedAllowanceLedgerInvariantError.negativeBalance(
                    item.key,
                    projectedAt
                )
            }
            result[item.key] = AccountBalance(
                currency: item.value,
                amount: amount
            )
        }
        return result
    }

}

extension AppModel {
    func preparedRestrictedAllowanceBalanceProjection(
        from store: EncryptedRecordStore,
        accountSnapshot: [LedgerAccount],
        endingBalances: [UUID: [CurrencyCode: Money]],
        projectedAt: Date,
        excludingEntryIDs: Set<UUID>,
        generation: Int,
        logicalBookRevision: UInt64,
        journalProjectionRevision: UInt64,
        observesCancellation: Bool
    ) async throws -> RestrictedAllowanceBalanceProjection {
        guard projectedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw AppModelError.invalidBook
        }
        let expectedCurrencies = try restrictedAllowanceCurrencies(
            in: accountSnapshot
        )
        let events = try await store.fetchJournalPostingEvents(
            accountIDs: Set(expectedCurrencies.keys),
            startDateInclusive: projectedAt,
            excludingEntryIDs: excludingEntryIDs,
            observesCancellation: observesCancellation
        )
        guard ownsStoreGeneration(generation),
              self.logicalBookRevision == logicalBookRevision,
              self.journalProjectionRevision == journalProjectionRevision else {
            throw AppModelError.locked
        }
        return try await Task.detached(priority: .userInitiated) {
            try RestrictedAllowanceBalanceProjection.make(
                expectedCurrencies: expectedCurrencies,
                endingBalances: endingBalances,
                futureEvents: events,
                projectedAt: projectedAt,
                logicalBookRevision: logicalBookRevision,
                journalProjectionRevision: journalProjectionRevision,
                observesCancellation: observesCancellation
            )
        }.value
    }

    func restrictedAllowanceBalanceResult(
        for account: LedgerAccount,
        asOf date: Date
    ) -> DerivedValue<Money> {
        guard let currency = account.currency else {
            return .unavailable(.missingCurrency)
        }
        guard account.kind == .asset,
              account.accountType == .restrictedAllowance,
              date.timeIntervalSinceReferenceDate.isFinite else {
            return .unavailable(.ledgerCalculationFailed)
        }
        let currentProjection = currentRestrictedAllowanceProjection
        if let currentProjection,
           !currentProjection.contains(date),
           !retainsCompleteJournal {
            // Compact synchronous presentation is deliberately scoped to the
            // frozen reporting instant. Rebuilding at the app's current clock
            // cannot satisfy an arbitrary historical/future request and would
            // otherwise create a permanent refresh loop. Quick Log uses the
            // exact asynchronous store read for transaction-time authority.
            return .unavailable(.appNotReady)
        }
        if let result = cachedRestrictedAllowanceBalance(
            accountID: account.id,
            currency: currency,
            asOf: date
        ) {
            return result
        }
        guard retainsCompleteJournal,
              journalRecentEntriesAreCurrent,
              !isBookReplacementInProgress,
              !isJournalMutationInProgress else {
            if currentProjection == nil { scheduleJournalDerivedRefresh() }
            return .unavailable(.appNotReady)
        }
        return retainedRestrictedAllowanceBalance(
            accountID: account.id,
            currency: currency,
            asOf: date
        )
    }

    func restrictedAllowanceProjectionExpiry(after date: Date) -> Date? {
        guard let projection = currentRestrictedAllowanceProjection,
              projection.contains(date) else { return nil }
        return projection.nextChangeAt
    }

    var restrictedAllowanceProjectionClockIdentity:
        RestrictedAllowanceProjectionClockIdentity? {
        currentRestrictedAllowanceProjection?.clockIdentity
    }

    func refreshRestrictedAllowanceProjectionIfNeeded(asOf date: Date) {
        guard let projection = currentRestrictedAllowanceProjection,
              date >= projection.projectedAt,
              !projection.contains(date) else { return }
        scheduleJournalDerivedRefresh()
    }

    func rebaseRestrictedAllowanceProjection(
        from priorLogicalBookRevision: UInt64
    ) {
        guard let projection = services.ledger.restrictedAllowanceBalanceProjection,
              projection.matches(
                  logicalBookRevision: priorLogicalBookRevision,
                  journalProjectionRevision: journalProjectionRevision
              ) else {
            services.ledger.restrictedAllowanceBalanceProjection = nil
            return
        }
        services.ledger.restrictedAllowanceBalanceProjection = projection.rebased(
            logicalBookRevision: logicalBookRevision
        )
    }

    private var currentRestrictedAllowanceProjection:
        RestrictedAllowanceBalanceProjection? {
        guard let projection = services.ledger.restrictedAllowanceBalanceProjection,
              projection.matches(
                  logicalBookRevision: logicalBookRevision,
                  journalProjectionRevision: journalProjectionRevision
              ) else { return nil }
        return projection
    }

    private func cachedRestrictedAllowanceBalance(
        accountID: UUID,
        currency: CurrencyCode,
        asOf date: Date
    ) -> DerivedValue<Money>? {
        guard let projection = currentRestrictedAllowanceProjection,
              projection.contains(date) else { return nil }
        do {
            guard let balance = try projection.balance(
                for: accountID,
                currency: currency,
                asOf: date
            ) else { return .unavailable(.ledgerCalculationFailed) }
            return .available(balance)
        } catch {
            return .unavailable(.ledgerCalculationFailed)
        }
    }

    private func retainedRestrictedAllowanceBalance(
        accountID: UUID,
        currency: CurrencyCode,
        asOf date: Date
    ) -> DerivedValue<Money> {
        do {
            let expectedCurrencies = try restrictedAllowanceCurrencies(
                in: allUserAccounts
            )
            let accountIDs = Set(expectedCurrencies.keys)
            let liveEntries = entries.filter {
                !invalidJournalEntryIDs.contains($0.id)
            }
            let events = try RestrictedAllowanceLedgerInvariant.events(
                for: liveEntries,
                restrictedAccountIDs: accountIDs,
                observesCancellation: false
            )
            let endingBalances = try FinanceCalculator.balancesByAccount(
                entries: liveEntries
            )
            let projection = try RestrictedAllowanceBalanceProjection.make(
                expectedCurrencies: expectedCurrencies,
                endingBalances: endingBalances,
                futureEvents: events,
                projectedAt: date,
                logicalBookRevision: logicalBookRevision,
                journalProjectionRevision: journalProjectionRevision,
                observesCancellation: false
            )
            services.ledger.restrictedAllowanceBalanceProjection = projection
            guard let balance = try projection.balance(
                for: accountID,
                currency: currency,
                asOf: date
            ) else { return .unavailable(.ledgerCalculationFailed) }
            return .available(balance)
        } catch {
            DerivedValueDiagnostics.record(
                .ledgerCalculationFailed,
                operation: "restricted-allowance-balance-as-of",
                error: error
            )
            return .unavailable(.ledgerCalculationFailed)
        }
    }

    private func restrictedAllowanceCurrencies(
        in accountSnapshot: [LedgerAccount]
    ) throws -> [UUID: CurrencyCode] {
        var result: [UUID: CurrencyCode] = [:]
        for account in accountSnapshot
        where account.accountType == .restrictedAllowance {
            guard account.kind == .asset, let currency = account.currency else {
                throw AppModelError.invalidBook
            }
            result[account.id] = currency
        }
        return result
    }
}
