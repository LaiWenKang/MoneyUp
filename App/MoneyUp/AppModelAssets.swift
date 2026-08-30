import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

extension AppModel {
    func addInvestmentHolding(
        _ holding: InvestmentHolding,
        treatment: InvestmentOpeningTreatment
    ) async throws {
        try beginJournalMutation()
        defer { endJournalMutation() }
        try beginInvestmentMutation(id: holding.id)
        defer { investmentMutationsInProgress.remove(holding.id) }
        guard !investmentHoldings.contains(where: { $0.id == holding.id }) else {
            throw AppModelError.transactionInProgress
        }
        guard !holding.isArchived else { throw AppModelError.ledgerItemArchived }
        guard !holding.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppModelError.emptyName
        }
        guard let fundingAccount = accounts.first(where: { $0.id == holding.accountID }),
              isEligibleInvestmentFundingAccount(fundingAccount),
              let currency = fundingAccount.currency else {
            throw AppModelError.missingRecord
        }
        if let price = holding.price {
            guard price.currency == currency else {
                throw AppModelError.investmentCurrencyMismatch
            }
            try requireValidNewWriteAmount(price.amount, currency: price.currency)
            if holding.quantity > .zero, price.amount <= .zero {
                throw AppModelError.invalidInvestmentTrade
            }
        }
        guard holding.quantity == .zero || holding.price != nil else {
            throw AppModelError.missingInvestmentPrice
        }
        let activityDate = holding.priceAsOf ?? Date()
        try validateInvestmentActivityDate(activityDate, after: nil)

        let positionAccount = LedgerAccount(
            name: "\(holding.symbol.isEmpty ? holding.name : holding.symbol) · \(String(localized: "holding.position_value"))",
            kind: .asset,
            currency: currency,
            systemRole: .investmentPosition
        )
        var candidate = try InvestmentHolding(
            id: holding.id,
            accountID: holding.accountID,
            symbol: holding.symbol,
            name: holding.name,
            quantity: .zero,
            positionAccountID: positionAccount.id
        )
        var writes = [
            try RecordWrite(positionAccount, id: positionAccount.id.uuidString, in: .accounts)
        ]
        var addedAccounts = [positionAccount]
        var openingEntry: JournalEntry?
        if holding.quantity > .zero, let price = holding.price {
            let entryID = UUID()
            try performInvestmentDomainOperation {
                try candidate.recordPurchase(
                    quantity: holding.quantity,
                    unitCost: price,
                    occurredAt: activityDate,
                    entryID: entryID
                )
                try candidate.recordPrice(
                    price,
                    asOf: activityDate,
                    entryID: entryID
                )
            }
            guard let total = try validatedInvestmentMarketValue(candidate) else {
                throw AppModelError.missingInvestmentPrice
            }
            guard total.amount > .zero else {
                throw AppModelError.invalidInvestmentTrade
            }
            let entry: JournalEntry
            switch treatment {
            case .deductFromCash:
                entry = try TransactionFactory.investmentPurchase(
                    cashCost: total,
                    resultingPositionValue: total,
                    previousPositionValue: .zero(currency: currency),
                    cashAccountID: holding.accountID,
                    positionAccountID: positionAccount.id,
                    gainLossAccountID: UUID(),
                    occurredAt: activityDate,
                    payee: holding.name,
                    note: String(localized: "holding.purchase_note"),
                    id: entryID,
                    originContext: investmentOriginContext(for: activityDate)
                )
            case .cashAlreadyExcludesPosition:
                let equity = openingBalancesAccount()
                if !accounts.contains(where: { $0.id == equity.id }) {
                    writes.append(try RecordWrite(
                        equity,
                        id: equity.id.uuidString,
                        in: .accounts
                    ))
                    addedAccounts.append(equity)
                }
                entry = try TransactionFactory.investmentOpening(
                    positionValue: total,
                    positionAccountID: positionAccount.id,
                    equityAccountID: equity.id,
                    occurredAt: activityDate,
                    note: String(localized: "holding.opening_position_note"),
                    id: entryID,
                    originContext: investmentOriginContext(for: activityDate)
                )
            }
            writes.append(try RecordWrite(entry, id: entry.id.uuidString, in: .journalEntries))
            openingEntry = entry
        }
        writes.append(try RecordWrite(
            candidate,
            id: candidate.id.uuidString,
            in: .investmentHoldings
        ))
        let generation = storeGeneration
        let holdingStore = try requireStore()
        if openingEntry != nil {
            invalidateCommittedJournalProjection()
            await lifecycleHooks.checkpoint(
                .afterJournalProjectionInvalidationBeforeCommit
            )
        }
        try await holdingStore.write(writes)
        guard isCurrentStoreGeneration(generation) else { return }
        accounts.append(contentsOf: addedAccounts)
        investmentHoldings.append(candidate)
        if retainsCompleteJournal, let openingEntry {
            entries.insert(openingEntry, at: 0)
        }
        if let openingEntry {
            investmentLinkedEntriesByID[openingEntry.id] = openingEntry
        }
        if openingEntry != nil { await refreshJournalAfterMutation() }
    }

    func repriceInvestmentHolding(
        id: UUID,
        unitPrice: Decimal,
        asOf: Date
    ) async throws {
        try beginJournalMutation()
        defer { endJournalMutation() }
        try beginInvestmentMutation(id: id)
        defer { investmentMutationsInProgress.remove(id) }
        guard let index = investmentHoldings.firstIndex(where: { $0.id == id }) else {
            throw AppModelError.missingRecord
        }
        var holding = investmentHoldings[index]
        guard !holding.isArchived else { throw AppModelError.ledgerItemArchived }
        try validateInvestmentActivityDate(
            asOf,
            after: holding.latestActivityDate
        )
        guard let linkedAccounts = linkedInvestmentAccounts(for: holding) else {
            throw AppModelError.investmentNeedsLedgerConnection
        }
        let positionID = linkedAccounts.position.id
        let currency = linkedAccounts.currency
        try requireValidNewWriteAmount(unitPrice, currency: currency)
        guard unitPrice >= .zero else { throw AppModelError.invalidInvestmentTrade }
        let price = try Money(unitPrice, currency: currency)
        let previous = try positionLedgerValue(id: positionID, currency: currency)
        let desired = try validatedInvestmentPositionValue(
            quantity: holding.quantity,
            unitPrice: price
        )
        let delta = try checkedInvestmentDifference(
            desired.amount,
            previous.amount
        )
        let priceEntryID = delta == .zero ? nil : UUID()
        try performInvestmentDomainOperation {
            try holding.recordPrice(price, asOf: asOf, entryID: priceEntryID)
        }

        var writes = [try RecordWrite(
            holding,
            id: holding.id.uuidString,
            in: .investmentHoldings
        )]
        var newEntry: JournalEntry?
        var newlyCreatedGainAccount: LedgerAccount?
        if delta != .zero {
            guard let priceEntryID else { throw AppModelError.invalidBook }
            try requireValidNewWriteAmount(delta, currency: currency)
            let gain = investmentGainLossAccount(for: currency)
            if !accounts.contains(where: { $0.id == gain.id }) {
                writes.append(try RecordWrite(gain, id: gain.id.uuidString, in: .accounts))
                newlyCreatedGainAccount = gain
            }
            let entry = try TransactionFactory.investmentValuation(
                delta: try Money(delta, currency: currency),
                positionAccountID: positionID,
                gainLossAccountID: gain.id,
                occurredAt: asOf,
                note: String(localized: "holding.reprice_note"),
                id: priceEntryID,
                originContext: investmentOriginContext(for: asOf)
            )
            writes.append(try RecordWrite(entry, id: entry.id.uuidString, in: .journalEntries))
            newEntry = entry
        }
        let generation = storeGeneration
        let store = try requireStore()
        if newEntry != nil {
            invalidateCommittedJournalProjection()
            await lifecycleHooks.checkpoint(
                .afterJournalProjectionInvalidationBeforeCommit
            )
        }
        try await store.write(writes)
        guard isCurrentStoreGeneration(generation) else { return }
        if let newEntry {
            if let newlyCreatedGainAccount { accounts.append(newlyCreatedGainAccount) }
            if retainsCompleteJournal { entries.insert(newEntry, at: 0) }
            investmentLinkedEntriesByID[newEntry.id] = newEntry
        }
        investmentHoldings[index] = holding
        if newEntry != nil { await refreshJournalAfterMutation() }
    }

    /// Explicit one-time migration for beta holdings that predate ledger-linked
    /// positions. The caller must choose whether the recorded cash balance
    /// still includes the investment; MoneyUp never guesses this material fact.
    func connectLegacyInvestmentHolding(
        id: UUID,
        fundingAccountID: UUID? = nil,
        deductFromCash: Bool,
        occurredAt: Date = Date()
    ) async throws {
        try beginJournalMutation()
        defer { endJournalMutation() }
        try beginInvestmentMutation(id: id)
        defer { investmentMutationsInProgress.remove(id) }
        guard let index = investmentHoldings.firstIndex(where: { $0.id == id }) else {
            throw AppModelError.missingRecord
        }
        var holding = investmentHoldings[index]
        guard !holding.isArchived else { throw AppModelError.ledgerItemArchived }
        try validateInvestmentActivityDate(
            occurredAt,
            after: holding.latestActivityDate
        )
        let selectedFundingID = fundingAccountID ?? holding.accountID
        guard holding.positionAccountID == nil,
              holding.quantity > .zero,
              let price = holding.price,
              let funding = accounts.first(where: { $0.id == selectedFundingID }),
              isEligibleInvestmentFundingAccount(funding),
              let currency = funding.currency,
              price.currency == currency,
              price.amount > .zero else {
            throw AppModelError.investmentCurrencyMismatch
        }
        try requireValidNewWriteAmount(price.amount, currency: currency)
        holding.accountID = funding.id
        let position = LedgerAccount(
            name: "\(holding.symbol.isEmpty ? holding.name : holding.symbol) · \(String(localized: "holding.position_value"))",
            kind: .asset,
            currency: currency,
            systemRole: .investmentPosition
        )
        let entryID = UUID()
        let originalQuantity = holding.quantity
        holding.quantity = .zero
        holding.positionAccountID = position.id
        try performInvestmentDomainOperation {
            try holding.recordPurchase(
                quantity: originalQuantity,
                unitCost: price,
                occurredAt: occurredAt,
                entryID: entryID
            )
        }
        guard let value = try validatedInvestmentMarketValue(holding) else {
            throw AppModelError.missingInvestmentPrice
        }
        guard value.amount > .zero else {
            throw AppModelError.invalidInvestmentTrade
        }
        let entry: JournalEntry
        var addedAccounts = [position]
        if deductFromCash {
            let gain = investmentGainLossAccount(for: currency)
            entry = try TransactionFactory.investmentPurchase(
                cashCost: value,
                resultingPositionValue: value,
                previousPositionValue: .zero(currency: currency),
                cashAccountID: funding.id,
                positionAccountID: position.id,
                gainLossAccountID: gain.id,
                occurredAt: occurredAt,
                payee: holding.name,
                note: String(localized: "holding.migration_note"),
                id: entryID,
                originContext: investmentOriginContext(for: occurredAt)
            )
        } else {
            let equity = openingBalancesAccount()
            entry = try TransactionFactory.investmentOpening(
                positionValue: value,
                positionAccountID: position.id,
                equityAccountID: equity.id,
                occurredAt: occurredAt,
                note: String(localized: "holding.migration_note"),
                id: entryID,
                originContext: investmentOriginContext(for: occurredAt)
            )
            if !accounts.contains(where: { $0.id == equity.id }) { addedAccounts.append(equity) }
        }
        var writes = try addedAccounts.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .accounts)
        }
        writes += [
            try RecordWrite(holding, id: holding.id.uuidString, in: .investmentHoldings),
            try RecordWrite(entry, id: entry.id.uuidString, in: .journalEntries)
        ]
        let generation = storeGeneration
        let store = try requireStore()
        invalidateCommittedJournalProjection()
        await lifecycleHooks.checkpoint(
            .afterJournalProjectionInvalidationBeforeCommit
        )
        try await store.write(writes)
        guard isCurrentStoreGeneration(generation) else { return }
        accounts.append(contentsOf: addedAccounts.filter { account in
            !accounts.contains(where: { $0.id == account.id })
        })
        investmentHoldings[index] = holding
        if retainsCompleteJournal { entries.insert(entry, at: 0) }
        investmentLinkedEntriesByID[entry.id] = entry
        await refreshJournalAfterMutation()
    }
}
