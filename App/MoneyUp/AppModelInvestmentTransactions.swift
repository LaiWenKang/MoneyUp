import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

extension AppModel {
    func recordInvestmentPurchase(
        holdingID: UUID,
        quantity: Decimal,
        unitPrice: Decimal,
        occurredAt: Date
    ) async throws {
        try beginJournalMutation()
        defer { endJournalMutation() }
        try beginInvestmentMutation(id: holdingID)
        defer { investmentMutationsInProgress.remove(holdingID) }
        guard let index = investmentHoldings.firstIndex(where: { $0.id == holdingID }) else {
            throw AppModelError.missingRecord
        }
        var holding = investmentHoldings[index]
        guard !holding.isArchived else { throw AppModelError.ledgerItemArchived }
        try validateInvestmentActivityDate(
            occurredAt,
            after: holding.latestActivityDate
        )
        guard let linkedAccounts = linkedInvestmentAccounts(for: holding) else {
            throw AppModelError.investmentNeedsLedgerConnection
        }
        let funding = linkedAccounts.funding
        let positionID = linkedAccounts.position.id
        let currency = linkedAccounts.currency
        guard quantity > .zero, unitPrice > .zero else {
            throw AppModelError.invalidInvestmentTrade
        }
        try requireValidNewWriteAmount(unitPrice, currency: currency)
        let price = try Money(unitPrice, currency: currency)
        let previous = try positionLedgerValue(id: positionID, currency: currency)
        let entryID = UUID()
        try performInvestmentDomainOperation {
            try holding.recordPurchase(
                quantity: quantity,
                unitCost: price,
                occurredAt: occurredAt,
                entryID: entryID
            )
            try holding.recordPrice(price, asOf: occurredAt, entryID: entryID)
        }
        let cashCost = try validatedInvestmentPositionValue(
            quantity: quantity,
            unitPrice: price
        )
        guard cashCost.amount > .zero else {
            throw AppModelError.invalidInvestmentTrade
        }
        guard let desired = try validatedInvestmentMarketValue(holding) else {
            throw AppModelError.missingInvestmentPrice
        }
        let gain = investmentGainLossAccount(for: currency)
        let entry = try TransactionFactory.investmentPurchase(
            cashCost: cashCost,
            resultingPositionValue: desired,
            previousPositionValue: previous,
            cashAccountID: funding.id,
            positionAccountID: positionID,
            gainLossAccountID: gain.id,
            occurredAt: occurredAt,
            payee: holding.name,
            note: String(localized: "holding.purchase_note"),
            id: entryID,
            originContext: investmentOriginContext(for: occurredAt)
        )
        var writes = [
            try RecordWrite(holding, id: holding.id.uuidString, in: .investmentHoldings),
            try RecordWrite(entry, id: entry.id.uuidString, in: .journalEntries)
        ]
        if !accounts.contains(where: { $0.id == gain.id }) {
            writes.append(try RecordWrite(gain, id: gain.id.uuidString, in: .accounts))
        }
        let generation = storeGeneration
        let store = try requireStore()
        invalidateCommittedJournalProjection()
        await lifecycleHooks.checkpoint(
            .afterJournalProjectionInvalidationBeforeCommit
        )
        try await store.write(writes)
        guard isCurrentStoreGeneration(generation) else { return }
        if !accounts.contains(where: { $0.id == gain.id }) { accounts.append(gain) }
        investmentHoldings[index] = holding
        if retainsCompleteJournal { entries.insert(entry, at: 0) }
        investmentLinkedEntriesByID[entry.id] = entry
        await refreshJournalAfterMutation()
    }

    @discardableResult
    func recordInvestmentSale(
        holdingID: UUID,
        quantity: Decimal,
        unitPrice: Decimal,
        occurredAt: Date
    ) async throws -> InvestmentSaleBreakdown {
        try beginJournalMutation()
        defer { endJournalMutation() }
        try beginInvestmentMutation(id: holdingID)
        defer { investmentMutationsInProgress.remove(holdingID) }
        guard let index = investmentHoldings.firstIndex(where: { $0.id == holdingID }) else {
            throw AppModelError.missingRecord
        }
        var holding = investmentHoldings[index]
        guard !holding.isArchived else { throw AppModelError.ledgerItemArchived }
        try validateInvestmentActivityDate(
            occurredAt,
            after: holding.latestActivityDate
        )
        guard let linkedAccounts = linkedInvestmentAccounts(for: holding) else {
            throw AppModelError.investmentNeedsLedgerConnection
        }
        let funding = linkedAccounts.funding
        let positionID = linkedAccounts.position.id
        let currency = linkedAccounts.currency
        guard quantity > .zero,
              quantity <= holding.quantity,
              unitPrice > .zero else {
            throw AppModelError.insufficientInvestmentQuantity
        }
        try requireValidNewWriteAmount(unitPrice, currency: currency)
        let price = try Money(unitPrice, currency: currency)
        let previous = try positionLedgerValue(id: positionID, currency: currency)
        let entryID = UUID()
        let breakdown = try performInvestmentDomainOperation {
            try holding.recordSale(
                quantity: quantity,
                unitPrice: price,
                occurredAt: occurredAt,
                entryID: entryID
            )
        }
        guard breakdown.proceeds.amount > .zero else {
            throw AppModelError.invalidInvestmentTrade
        }
        try requireValidNewWriteAmount(breakdown.proceeds.amount, currency: currency)
        try requireValidNewWriteAmount(breakdown.costBasis.amount, currency: currency)
        try requireValidNewWriteAmount(breakdown.realizedGainLoss.amount, currency: currency)
        try performInvestmentDomainOperation {
            try holding.recordPrice(price, asOf: occurredAt, entryID: entryID)
        }
        guard let desired = try validatedInvestmentMarketValue(holding) else {
            throw AppModelError.missingInvestmentPrice
        }
        let gain = investmentGainLossAccount(for: currency)
        let entry = try TransactionFactory.investmentSale(
            proceeds: breakdown.proceeds,
            resultingPositionValue: desired,
            previousPositionValue: previous,
            cashAccountID: funding.id,
            positionAccountID: positionID,
            gainLossAccountID: gain.id,
            occurredAt: occurredAt,
            payee: holding.name,
            note: String(localized: "holding.sale_note"),
            id: entryID,
            originContext: investmentOriginContext(for: occurredAt)
        )
        var writes = [
            try RecordWrite(holding, id: holding.id.uuidString, in: .investmentHoldings),
            try RecordWrite(entry, id: entry.id.uuidString, in: .journalEntries)
        ]
        if !accounts.contains(where: { $0.id == gain.id }) {
            writes.append(try RecordWrite(gain, id: gain.id.uuidString, in: .accounts))
        }
        let generation = storeGeneration
        let store = try requireStore()
        invalidateCommittedJournalProjection()
        await lifecycleHooks.checkpoint(
            .afterJournalProjectionInvalidationBeforeCommit
        )
        try await store.write(writes)
        guard isCurrentStoreGeneration(generation) else { return breakdown }
        if !accounts.contains(where: { $0.id == gain.id }) { accounts.append(gain) }
        investmentHoldings[index] = holding
        if retainsCompleteJournal { entries.insert(entry, at: 0) }
        investmentLinkedEntriesByID[entry.id] = entry
        await refreshJournalAfterMutation()
        return breakdown
    }

    func captureNetWorthSnapshot(at date: Date = Date()) async throws {
        try beginJournalMutation(invalidatesJournalProjection: false)
        defer { endJournalMutation() }
        guard !investmentHoldings.contains(where: { $0.needsLedgerConnection }) else {
            throw AppModelError.legacyInvestmentSnapshotForbidden
        }
        guard case let .available(amounts) = netWorthByCurrencyResult() else {
            throw AppModelError.invalidBook
        }
        let estimate: EstimatedNetWorth?
        switch estimatedNetWorthResult(at: date) {
        case let .available(value):
            estimate = value
        case .unavailable:
            throw AppModelError.invalidBook
        }
        let snapshot = try NetWorthSnapshot(
            capturedAt: date,
            amounts: amounts,
            estimatedBaseTotal: estimate?.total,
            conversionAsOf: estimate?.conversionAsOf,
            conversionAsOfDayKey: estimate?.conversionAsOfDayKey,
            conversionEvidence: estimate?.evidence ?? []
        )
        let generation = storeGeneration
        let store = try requireStore()
        await lifecycleHooks.checkpoint(.beforeNetWorthSnapshotCommit)
        try await store.upsert(
            snapshot,
            id: snapshot.id.uuidString,
            in: .netWorthSnapshots
        )
        guard isCurrentStoreGeneration(generation) else { return }
        netWorthSnapshots.insert(snapshot, at: 0)
    }

    func deleteInvestmentHolding(id: UUID) async throws {
        try beginJournalMutation()
        defer { endJournalMutation() }
        try beginInvestmentMutation(id: id)
        defer { investmentMutationsInProgress.remove(id) }
        guard let holdingIndex = investmentHoldings.firstIndex(where: { $0.id == id }) else {
            throw AppModelError.missingRecord
        }
        var holding = investmentHoldings[holdingIndex]
        guard !holding.isArchived else { throw AppModelError.ledgerItemArchived }
        guard holding.quantity == .zero else {
            throw AppModelError.investmentHoldingNotEmpty
        }
        try performInvestmentDomainOperation { try holding.archive() }
        var writes: [RecordWrite] = [try RecordWrite(
            holding,
            id: holding.id.uuidString,
            in: .investmentHoldings
        )]
        var archivedPosition: LedgerAccount?
        if let positionID = holding.positionAccountID {
            guard let linkedAccounts = linkedInvestmentAccounts(for: holding),
                  linkedAccounts.position.id == positionID,
                  try positionLedgerValue(
                    id: positionID,
                    currency: linkedAccounts.currency
                  ).isZero else {
                throw AppModelError.invalidBook
            }
            var position = linkedAccounts.position
            position.isArchived = true
            writes.append(try RecordWrite(
                position,
                id: position.id.uuidString,
                in: .accounts
            ))
            archivedPosition = position
        }
        let generation = storeGeneration
        let holdingStore = try requireStore()
        try await holdingStore.write(writes)
        guard isCurrentStoreGeneration(generation) else { return }
        if let archivedPosition,
           let positionIndex = accounts.firstIndex(where: {
               $0.id == archivedPosition.id
           }) {
            accounts[positionIndex] = archivedPosition
        }
        investmentHoldings[holdingIndex] = holding
    }

    func saveExchangeRate(
        baseCurrency: CurrencyCode,
        quoteCurrency: CurrencyCode,
        rate: Decimal,
        effectiveAt: Date,
        calendar: Calendar? = nil,
        timeZone: TimeZone? = nil
    ) async throws {
        await beginExchangeRateMutation()
        defer { endExchangeRateMutation() }
        try Task.checkCancellation()
        try beginJournalMutation(invalidatesJournalProjection: false)
        defer { endJournalMutation() }
        let effectiveCalendar = calendar ?? reportingCalendar
        let effectiveTimeZone = timeZone ?? effectiveCalendar.timeZone
        let candidate = try DatedExchangeRate(
            baseCurrency: baseCurrency,
            quoteCurrency: quoteCurrency,
            rate: rate,
            effectiveAt: effectiveAt,
            calendar: effectiveCalendar,
            timeZone: effectiveTimeZone
        )
        let replaced = exchangeRates.filter { existing in
            existing.effectiveContext.dayKey == candidate.effectiveContext.dayKey
                && ((existing.baseCurrency == baseCurrency
                        && existing.quoteCurrency == quoteCurrency)
                    || (existing.baseCurrency == quoteCurrency
                        && existing.quoteCurrency == baseCurrency))
        }
        let generation = storeGeneration
        let rateStore = try requireStore()
        try await rateStore.write(
            [try RecordWrite(candidate, id: candidate.id.uuidString, in: .exchangeRates)],
            removing: replaced.map {
                RecordDeletion(id: $0.id.uuidString, from: .exchangeRates)
            }
        )
        guard isCurrentStoreGeneration(generation) else { return }
        let replacedIDs = Set(replaced.map(\.id))
        exchangeRates.removeAll { replacedIDs.contains($0.id) }
        exchangeRates.append(candidate)
        exchangeRates.sort {
            if $0.effectiveContext.dayKey == $1.effectiveContext.dayKey {
                return $0.createdAt > $1.createdAt
            }
            return $0.effectiveContext.dayKey > $1.effectiveContext.dayKey
        }
    }

    func deleteExchangeRate(id: UUID) async throws {
        await beginExchangeRateMutation()
        defer { endExchangeRateMutation() }
        try Task.checkCancellation()
        try beginJournalMutation(invalidatesJournalProjection: false)
        defer { endJournalMutation() }
        let generation = storeGeneration
        let rateStore = try requireStore()
        try await rateStore.remove(id: id.uuidString, from: .exchangeRates)
        guard isCurrentStoreGeneration(generation) else { return }
        exchangeRates.removeAll { $0.id == id }
    }

    func beginExchangeRateMutation() async {
        guard exchangeRateMutationIsActive else {
            exchangeRateMutationIsActive = true
            return
        }
        await withCheckedContinuation { continuation in
            exchangeRateMutationWaiters.append(continuation)
        }
    }

    func endExchangeRateMutation() {
        guard !exchangeRateMutationWaiters.isEmpty else {
            exchangeRateMutationIsActive = false
            return
        }
        exchangeRateMutationWaiters.removeFirst().resume()
    }

    func historicalConversion(
        amount: Decimal,
        from sourceCurrency: CurrencyCode,
        to destinationCurrency: CurrencyCode,
        occurredAt: Date
    ) throws -> HistoricalCurrencyConversion? {
        try HistoricalExchangeRateLookup.conversion(
            of: Money(amount, currency: sourceCurrency),
            to: destinationCurrency,
            on: reportingOriginContext(for: occurredAt),
            rates: exchangeRates
        )
    }
}
