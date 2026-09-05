import Foundation
import MoneyUpCore

enum RestrictedAllowanceLedgerInvariantError: Error, Equatable {
    case currencyMismatch(UUID)
    case negativeBalance(UUID, Date)
    case arithmeticFailure(UUID)
}

/// Restricted stored value is governed by event time, not by the current
/// ending balance. Entries sharing one instant form one atomic batch because
/// `JournalEntry` has no durable ordering field within an equal timestamp.
enum RestrictedAllowanceLedgerInvariant {
    static func balance(
        for accountID: UUID,
        currency: CurrencyCode,
        through asOf: Date,
        events: [LedgerPostingEvent]
    ) throws -> Decimal {
        let result = try validationResult(
            expectedCurrencies: [accountID: currency],
            through: asOf,
            includesBoundary: true,
            events: events,
            observesCancellation: true
        )
        if let failure = result.failures[accountID] { throw failure }
        return result.balances[accountID] ?? .zero
    }

    static func balance(
        for accountID: UUID,
        currency: CurrencyCode,
        before endDate: Date,
        events: [LedgerPostingEvent]
    ) throws -> Decimal {
        let result = try validationResult(
            expectedCurrencies: [accountID: currency],
            through: endDate,
            includesBoundary: false,
            events: events,
            observesCancellation: true
        )
        if let failure = result.failures[accountID] { throw failure }
        return result.balances[accountID] ?? .zero
    }

    static func invalidAccountIDs(
        expectedCurrencies: [UUID: CurrencyCode],
        events: [LedgerPostingEvent],
        observesCancellation: Bool = true
    ) throws -> Set<UUID> {
        Set(try validationResult(
            expectedCurrencies: expectedCurrencies,
            through: nil,
            includesBoundary: true,
            events: events,
            observesCancellation: observesCancellation
        ).failures.keys)
    }

    static func requireValid(
        expectedCurrencies: [UUID: CurrencyCode],
        events: [LedgerPostingEvent],
        observesCancellation: Bool = true
    ) throws {
        let failures = try validationResult(
            expectedCurrencies: expectedCurrencies,
            through: nil,
            includesBoundary: true,
            events: events,
            observesCancellation: observesCancellation
        ).failures
        if let accountID = failures.keys.min(by: {
            $0.uuidString < $1.uuidString
        }), let failure = failures[accountID] {
            throw failure
        }
    }

    static func events(
        for entry: JournalEntry,
        restrictedAccountIDs: Set<UUID>
    ) -> [LedgerPostingEvent] {
        entry.postings.compactMap { posting in
            guard restrictedAccountIDs.contains(posting.accountID) else {
                return nil
            }
            return LedgerPostingEvent(
                entryID: entry.id,
                occurredAt: entry.occurredAt,
                originDayKey: 0,
                posting: posting
            )
        }
    }

    static func events(
        for entries: [JournalEntry],
        restrictedAccountIDs: Set<UUID>,
        observesCancellation: Bool
    ) throws -> [LedgerPostingEvent] {
        var result: [LedgerPostingEvent] = []
        var postingCount = 0
        for entry in entries {
            for posting in entry.postings {
                if observesCancellation, postingCount.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                postingCount += 1
                guard restrictedAccountIDs.contains(posting.accountID) else {
                    continue
                }
                result.append(LedgerPostingEvent(
                    entryID: entry.id,
                    occurredAt: entry.occurredAt,
                    originDayKey: 0,
                    posting: posting
                ))
            }
        }
        return result
    }

    private static func validationResult(
        expectedCurrencies: [UUID: CurrencyCode],
        through asOf: Date?,
        includesBoundary: Bool,
        events: [LedgerPostingEvent],
        observesCancellation: Bool
    ) throws -> (
        balances: [UUID: Decimal],
        failures: [UUID: RestrictedAllowanceLedgerInvariantError]
    ) {
        var batches: [UUID: [Date: Decimal]] = [:]
        var failures: [UUID: RestrictedAllowanceLedgerInvariantError] = [:]
        for (offset, event) in events.enumerated() {
            if observesCancellation, offset.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            let accountID = event.posting.accountID
            guard let currency = expectedCurrencies[accountID],
                  failures[accountID] == nil else { continue }
            if let asOf,
               event.occurredAt > asOf
                || (!includesBoundary && event.occurredAt == asOf) {
                continue
            }
            guard event.posting.money.currency == currency else {
                failures[accountID] = .currencyMismatch(accountID)
                continue
            }
            do {
                let batchAmount = try CheckedDecimal.adding(
                    batches[accountID]?[event.occurredAt] ?? .zero,
                    event.posting.money.amount
                )
                // Mutate the nested dictionary through Dictionary's modify
                // accessor. Copying it to a local for every event makes a
                // large single-account journal quadratic under CoW.
                batches[accountID, default: [:]][event.occurredAt] = batchAmount
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures[accountID] = .arithmeticFailure(accountID)
            }
        }

        var balances: [UUID: Decimal] = [:]
        for (offset, accountID) in expectedCurrencies.keys.sorted(by: {
            $0.uuidString < $1.uuidString
        }).enumerated() {
            if observesCancellation, offset.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            guard failures[accountID] == nil else { continue }
            let accountBatches = batches[accountID] ?? [:]
            var running = Decimal.zero
            let orderedDates = accountBatches.keys.sorted()
            if observesCancellation { try Task.checkCancellation() }
            for (dateOffset, occurredAt) in orderedDates.enumerated() {
                if observesCancellation, dateOffset.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                do {
                    running = try CheckedDecimal.adding(
                        running,
                        accountBatches[occurredAt] ?? .zero
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failures[accountID] = .arithmeticFailure(accountID)
                    break
                }
                guard running >= .zero else {
                    failures[accountID] = .negativeBalance(
                        accountID,
                        occurredAt
                    )
                    break
                }
            }
            if failures[accountID] == nil {
                balances[accountID] = running
            }
        }
        return (balances, failures)
    }
}
