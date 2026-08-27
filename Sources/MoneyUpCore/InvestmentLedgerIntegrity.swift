import Foundation

public enum InvestmentLedgerIntegrityError: Error, Equatable, Sendable {
    case invalidHoldingRelationship
    case missingLinkedEntry(UUID)
    case invalidLinkedEntry(UUID)
    case arithmeticFailure
}

/// Replays a holding's persisted activity evidence and proves that every
/// linked journal event has the exact ledger effect represented by that
/// evidence. A purchase or sale may legitimately omit a position posting when
/// its simultaneous price change leaves total market value unchanged.
public enum InvestmentLedgerIntegrity {
    public static func validate(
        holding: InvestmentHolding,
        accountsByID: [UUID: LedgerAccount],
        entriesByID: [UUID: JournalEntry]
    ) throws {
        guard let positionID = holding.positionAccountID,
              positionID != holding.accountID,
              let funding = accountsByID[holding.accountID],
              funding.kind == .asset,
              funding.systemRole == nil,
              funding.accountType == .brokerage
                || funding.accountType == .investment,
              let currency = funding.currency,
              let position = accountsByID[positionID],
              position.kind == .asset,
              position.systemRole == .investmentPosition,
              position.currency == currency else {
            throw InvestmentLedgerIntegrityError.invalidHoldingRelationship
        }

        let activities = try activities(for: holding, currency: currency)
        var quantity = Decimal.zero
        var price: Money?
        var processedEntryIDs = Set<UUID>()
        var hasLinkedLedgerEvent = false

        for activity in activities {
            if let entryID = activity.entryID {
                guard processedEntryIDs.insert(entryID).inserted else { continue }
                let grouped = activities.filter { $0.entryID == entryID }.sorted {
                    $0.sequence < $1.sequence
                }
                guard let first = grouped.first,
                      grouped.allSatisfy({ $0.date == first.date }),
                      let entry = entriesByID[entryID] else {
                    throw InvestmentLedgerIntegrityError.missingLinkedEntry(entryID)
                }
                let before = try positionValue(
                    quantity: quantity,
                    price: price,
                    currency: currency
                )
                for groupedActivity in grouped {
                    try apply(
                        groupedActivity,
                        quantity: &quantity,
                        price: &price
                    )
                }
                let after = try positionValue(
                    quantity: quantity,
                    price: price,
                    currency: currency
                )
                try validate(
                    entry: entry,
                    activities: grouped,
                    beforePositionValue: before,
                    afterPositionValue: after,
                    fundingAccountID: funding.id,
                    positionAccountID: position.id,
                    currency: currency,
                    accountsByID: accountsByID,
                    mayBeOpening: !hasLinkedLedgerEvent
                )
                hasLinkedLedgerEvent = true
            } else {
                // Only a price observation whose market value is unchanged may
                // lack a journal identity. Acquisitions always require ledger
                // evidence once a holding has a connected position account.
                guard case .price = activity else {
                    throw InvestmentLedgerIntegrityError.invalidHoldingRelationship
                }
                let before = try positionValue(
                    quantity: quantity,
                    price: price,
                    currency: currency
                )
                try apply(activity, quantity: &quantity, price: &price)
                let after = try positionValue(
                    quantity: quantity,
                    price: price,
                    currency: currency
                )
                guard before == after else {
                    throw InvestmentLedgerIntegrityError.invalidHoldingRelationship
                }
            }
        }

        guard quantity == holding.quantity,
              price == holding.price else {
            throw InvestmentLedgerIntegrityError.invalidHoldingRelationship
        }
    }

    private enum Activity {
        case purchase(InvestmentLot)
        case sale(InvestmentDisposal)
        case price(HoldingPricePoint)

        var sequence: Int64 {
            switch self {
            case let .purchase(lot): lot.activitySequence
            case let .sale(disposal): disposal.activitySequence
            case let .price(point): point.activitySequence
            }
        }

        var date: Date {
            switch self {
            case let .purchase(lot): lot.acquiredAt
            case let .sale(disposal): disposal.occurredAt
            case let .price(point): point.asOf
            }
        }

        var entryID: UUID? {
            switch self {
            case let .purchase(lot): lot.purchaseEntryID
            case let .sale(disposal): disposal.saleEntryID
            case let .price(point): point.priceEntryID
            }
        }
    }

    private static func activities(
        for holding: InvestmentHolding,
        currency: CurrencyCode
    ) throws -> [Activity] {
        let activities = holding.lots.map(Activity.purchase)
            + holding.disposals.map(Activity.sale)
            + holding.priceHistory.map(Activity.price)
        guard Set(activities.map(\.sequence)).count == activities.count,
              activities.allSatisfy({ activity in
                  switch activity {
                  case let .purchase(lot):
                      lot.unitCost.currency == currency
                  case let .sale(disposal):
                      disposal.costBasis.currency == currency
                        && disposal.proceeds.currency == currency
                        && disposal.realizedGainLoss.currency == currency
                  case let .price(point):
                      point.price.currency == currency
                  }
              }) else {
            throw InvestmentLedgerIntegrityError.invalidHoldingRelationship
        }
        let ordered = activities.sorted { $0.sequence < $1.sequence }
        guard zip(ordered, ordered.dropFirst()).allSatisfy({ pair in
            pair.0.date <= pair.1.date
        }) else {
            throw InvestmentLedgerIntegrityError.invalidHoldingRelationship
        }
        return ordered
    }

    private static func apply(
        _ activity: Activity,
        quantity: inout Decimal,
        price: inout Money?
    ) throws {
        do {
            switch activity {
            case let .purchase(lot):
                quantity = try CheckedDecimal.adding(
                    quantity,
                    lot.originalQuantity
                )
            case let .sale(disposal):
                guard disposal.quantity <= quantity else {
                    throw InvestmentLedgerIntegrityError.invalidHoldingRelationship
                }
                quantity = try CheckedDecimal.subtracting(
                    quantity,
                    disposal.quantity
                )
            case let .price(point):
                price = point.price
            }
        } catch let error as InvestmentLedgerIntegrityError {
            throw error
        } catch {
            throw InvestmentLedgerIntegrityError.arithmeticFailure
        }
    }

    private static func positionValue(
        quantity: Decimal,
        price: Money?,
        currency: CurrencyCode
    ) throws -> Money {
        guard let price else { return .zero(currency: currency) }
        do {
            return try InvestmentHolding.positionValue(
                quantity: quantity,
                unitPrice: price
            )
        } catch {
            throw InvestmentLedgerIntegrityError.arithmeticFailure
        }
    }

    private static func validate(
        entry: JournalEntry,
        activities: [Activity],
        beforePositionValue: Money,
        afterPositionValue: Money,
        fundingAccountID: UUID,
        positionAccountID: UUID,
        currency: CurrencyCode,
        accountsByID: [UUID: LedgerAccount],
        mayBeOpening: Bool
    ) throws {
        guard entry.kind == .investment,
              let eventDate = activities.first?.date,
              entry.occurredAt == eventDate,
              entry.postings.allSatisfy({ posting in
                  posting.money.currency == currency
                    && accountsByID[posting.accountID] != nil
              }),
              Set(entry.postings.map(\.accountID)).count == entry.postings.count else {
            throw InvestmentLedgerIntegrityError.invalidLinkedEntry(entry.id)
        }

        let purchases = activities.compactMap { activity -> InvestmentLot? in
            guard case let .purchase(lot) = activity else { return nil }
            return lot
        }
        let sales = activities.compactMap { activity -> InvestmentDisposal? in
            guard case let .sale(disposal) = activity else { return nil }
            return disposal
        }
        guard purchases.count <= 1,
              sales.count <= 1,
              purchases.isEmpty || sales.isEmpty else {
            throw InvestmentLedgerIntegrityError.invalidLinkedEntry(entry.id)
        }

        do {
            let positionDelta = try CheckedDecimal.subtracting(
                afterPositionValue.amount,
                beforePositionValue.amount
            )
            var expected: [UUID: Decimal] = [:]
            if let purchase = purchases.first {
                let cashCost = try CheckedDecimal.productForCurrencyRounding(
                    purchase.originalQuantity,
                    purchase.unitCost.amount,
                    currency: currency
                )
                let fundingPosting = entry.postings.first {
                    $0.accountID == fundingAccountID
                }
                if fundingPosting != nil {
                    try addExpected(-cashCost, to: fundingAccountID, in: &expected)
                    try addExpected(positionDelta, to: positionAccountID, in: &expected)
                    let residual = try CheckedDecimal.subtracting(
                        cashCost,
                        positionDelta
                    )
                    if residual != .zero {
                        let gainID = try uniqueSystemPostingAccount(
                            role: .investmentGainLoss,
                            in: entry,
                            accountsByID: accountsByID
                        )
                        try addExpected(residual, to: gainID, in: &expected)
                    }
                } else {
                    guard mayBeOpening,
                          beforePositionValue.isZero,
                          positionDelta == afterPositionValue.amount,
                          positionDelta > .zero else {
                        throw InvestmentLedgerIntegrityError.invalidLinkedEntry(entry.id)
                    }
                    try addExpected(positionDelta, to: positionAccountID, in: &expected)
                    let equityID = try uniqueSystemPostingAccount(
                        role: .openingBalances,
                        in: entry,
                        accountsByID: accountsByID
                    )
                    try addExpected(-positionDelta, to: equityID, in: &expected)
                }
            } else if let sale = sales.first {
                try addExpected(
                    sale.proceeds.amount,
                    to: fundingAccountID,
                    in: &expected
                )
                try addExpected(positionDelta, to: positionAccountID, in: &expected)
                let proceedsAndPosition = try CheckedDecimal.adding(
                    sale.proceeds.amount,
                    positionDelta
                )
                let counter = try CheckedDecimal.subtracting(
                    .zero,
                    proceedsAndPosition
                )
                if counter != .zero {
                    let gainID = try uniqueSystemPostingAccount(
                        role: .investmentGainLoss,
                        in: entry,
                        accountsByID: accountsByID
                    )
                    try addExpected(counter, to: gainID, in: &expected)
                }
            } else {
                guard activities.count == 1,
                      case .price = activities[0],
                      positionDelta != .zero else {
                    throw InvestmentLedgerIntegrityError.invalidLinkedEntry(entry.id)
                }
                try addExpected(positionDelta, to: positionAccountID, in: &expected)
                let gainID = try uniqueSystemPostingAccount(
                    role: .investmentGainLoss,
                    in: entry,
                    accountsByID: accountsByID
                )
                try addExpected(-positionDelta, to: gainID, in: &expected)
            }

            let actual = Dictionary(
                uniqueKeysWithValues: entry.postings.map {
                    ($0.accountID, $0.money.amount)
                }
            )
            guard actual == expected else {
                throw InvestmentLedgerIntegrityError.invalidLinkedEntry(entry.id)
            }
        } catch let error as InvestmentLedgerIntegrityError {
            throw error
        } catch {
            throw InvestmentLedgerIntegrityError.arithmeticFailure
        }
    }

    private static func uniqueSystemPostingAccount(
        role: SystemAccountRole,
        in entry: JournalEntry,
        accountsByID: [UUID: LedgerAccount]
    ) throws -> UUID {
        let matching = entry.postings.compactMap { posting -> UUID? in
            accountsByID[posting.accountID]?.systemRole == role
                ? posting.accountID
                : nil
        }
        guard matching.count == 1, let id = matching.first else {
            throw InvestmentLedgerIntegrityError.invalidLinkedEntry(entry.id)
        }
        return id
    }

    private static func addExpected(
        _ amount: Decimal,
        to accountID: UUID,
        in expected: inout [UUID: Decimal]
    ) throws {
        guard amount != .zero else { return }
        do {
            expected[accountID] = try CheckedDecimal.adding(
                expected[accountID] ?? .zero,
                amount
            )
            if expected[accountID] == .zero { expected.removeValue(forKey: accountID) }
        } catch {
            throw InvestmentLedgerIntegrityError.arithmeticFailure
        }
    }
}
