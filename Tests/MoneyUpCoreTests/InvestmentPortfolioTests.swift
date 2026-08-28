import Foundation
@testable import MoneyUpCore
import XCTest

final class InvestmentPortfolioTests: XCTestCase {
    func testLegacyHoldingDecodesWithMigrationDefaults() throws {
        let accountID = UUID()
        let id = UUID()
        let json = """
        {
          "id":"\(id.uuidString)",
          "accountID":"\(accountID.uuidString)",
          "symbol":"MU",
          "name":"Micron",
          "quantity":2,
          "price":{"amount":100,"currency":"USD"},
          "priceAsOf":0
        }
        """
        let holding = try JSONDecoder().decode(
            InvestmentHolding.self,
            from: Data(json.utf8)
        )

        XCTAssertTrue(holding.needsLedgerConnection)
        XCTAssertNil(holding.positionAccountID)
        XCTAssertTrue(holding.lots.isEmpty)
        XCTAssertTrue(holding.disposals.isEmpty)
        XCTAssertEqual(holding.priceHistory.count, 1)
        XCTAssertFalse(holding.isArchived)
    }

    func testPriceBecomesStaleOnlyWhenOlderThanSevenDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let exactlySevenDays = try XCTUnwrap(
            calendar.date(byAdding: .day, value: -7, to: now)
        )
        let older = exactlySevenDays.addingTimeInterval(-1)
        let accountID = UUID()
        let usd = try CurrencyCode("USD")

        let fresh = try InvestmentHolding(
            accountID: accountID,
            symbol: "MU",
            name: "Micron",
            quantity: 1,
            price: try Money(100, currency: usd),
            priceAsOf: exactlySevenDays
        )
        let stale = try InvestmentHolding(
            accountID: accountID,
            symbol: "MU",
            name: "Micron",
            quantity: 1,
            price: try Money(100, currency: usd),
            priceAsOf: older
        )

        XCTAssertFalse(fresh.isPriceStale(relativeTo: now, calendar: calendar))
        XCTAssertTrue(stale.isPriceStale(relativeTo: now, calendar: calendar))
    }

    func testInvestmentLifecycleRejectsNonFiniteDatesWithoutMutation() throws {
        let usd = try CurrencyCode("USD")
        let invalid = Date(timeIntervalSinceReferenceDate: .infinity)
        XCTAssertThrowsError(
            try InvestmentHolding(
                accountID: UUID(),
                symbol: "MU",
                name: "Micron",
                quantity: 1,
                price: try Money(10, currency: usd),
                priceAsOf: invalid
            )
        ) { error in
            XCTAssertEqual(error as? InvestmentHoldingError, .historyMismatch)
        }
        XCTAssertThrowsError(
            try InvestmentDisposal(
                occurredAt: invalid,
                quantity: 1,
                costBasis: try Money(10, currency: usd),
                proceeds: try Money(11, currency: usd),
                realizedGainLoss: try Money(1, currency: usd),
                saleEntryID: UUID()
            )
        ) { error in
            XCTAssertEqual(error as? InvestmentHoldingError, .invalidDisposal)
        }

        var holding = try InvestmentHolding(
            accountID: UUID(),
            symbol: "MU",
            name: "Micron",
            quantity: .zero,
            positionAccountID: UUID()
        )
        let before = holding
        XCTAssertThrowsError(
            try holding.recordPurchase(
                quantity: 1,
                unitCost: try Money(10, currency: usd),
                occurredAt: invalid,
                entryID: UUID()
            )
        ) { error in
            XCTAssertEqual(error as? InvestmentHoldingError, .historyMismatch)
        }
        XCTAssertThrowsError(
            try holding.recordPrice(
                try Money(10, currency: usd),
                asOf: invalid
            )
        ) { error in
            XCTAssertEqual(error as? InvestmentHoldingError, .historyMismatch)
        }
        XCTAssertEqual(holding, before)
        XCTAssertTrue(holding.isPriceStale(relativeTo: invalid))
    }

    func testFIFOIsDeterministicAndRecordsRealizedBookkeeping() throws {
        let usd = try CurrencyCode("USD")
        let accountID = UUID()
        let positionID = UUID()
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = Date(timeIntervalSince1970: 200)
        var holding = try InvestmentHolding(
            accountID: accountID,
            symbol: "MU",
            name: "Micron",
            quantity: 0,
            positionAccountID: positionID
        )
        try holding.recordPurchase(
            quantity: 2,
            unitCost: try Money(10, currency: usd),
            occurredAt: firstDate,
            entryID: UUID()
        )
        try holding.recordPurchase(
            quantity: 2,
            unitCost: try Money(20, currency: usd),
            occurredAt: secondDate,
            entryID: UUID()
        )

        let breakdown = try holding.recordSale(
            quantity: 3,
            unitPrice: try Money(30, currency: usd),
            occurredAt: Date(timeIntervalSince1970: 300),
            entryID: UUID()
        )

        XCTAssertEqual(breakdown.costBasis.amount, 40)
        XCTAssertEqual(breakdown.proceeds.amount, 90)
        XCTAssertEqual(breakdown.realizedGainLoss.amount, 50)
        XCTAssertEqual(holding.quantity, 1)
        XCTAssertEqual(holding.lots[0].remainingQuantity, 0)
        XCTAssertEqual(holding.lots[1].remainingQuantity, 1)
        XCTAssertEqual(holding.disposals.last?.realizedGainLoss.amount, 50)
    }

    func testOutOfOrderPriceAndPurchaseAreRejectedWithoutMutation() throws {
        let usd = try CurrencyCode("USD")
        let later = Date(timeIntervalSinceReferenceDate: 2_000)
        var holding = try InvestmentHolding(
            accountID: UUID(),
            symbol: "MU",
            name: "Micron",
            quantity: 0,
            positionAccountID: UUID()
        )
        try holding.recordPurchase(
            quantity: 1,
            unitCost: try Money(100, currency: usd),
            occurredAt: later,
            entryID: UUID()
        )
        let before = holding

        XCTAssertThrowsError(try holding.recordPrice(
            try Money(90, currency: usd),
            asOf: later.addingTimeInterval(-1)
        )) { error in
            XCTAssertEqual(error as? InvestmentHoldingError, .activityOutOfOrder)
        }
        XCTAssertThrowsError(try holding.recordPurchase(
            quantity: 1,
            unitCost: try Money(90, currency: usd),
            occurredAt: later.addingTimeInterval(-1),
            entryID: UUID()
        )) { error in
            XCTAssertEqual(error as? InvestmentHoldingError, .activityOutOfOrder)
        }
        XCTAssertEqual(holding, before)
    }

    func testSaleBeforeAcquisitionIsRejectedWithoutConsumingLots() throws {
        let usd = try CurrencyCode("USD")
        let acquisition = Date(timeIntervalSinceReferenceDate: 2_000)
        var holding = try InvestmentHolding(
            accountID: UUID(),
            symbol: "MU",
            name: "Micron",
            quantity: 0,
            positionAccountID: UUID()
        )
        try holding.recordPurchase(
            quantity: 2,
            unitCost: try Money(100, currency: usd),
            occurredAt: acquisition,
            entryID: UUID()
        )

        XCTAssertThrowsError(try holding.recordSale(
            quantity: 1,
            unitPrice: try Money(110, currency: usd),
            occurredAt: acquisition.addingTimeInterval(-1),
            entryID: UUID()
        )) { error in
            XCTAssertEqual(error as? InvestmentHoldingError, .activityOutOfOrder)
        }
        XCTAssertEqual(holding.quantity, 2)
        XCTAssertEqual(holding.lots.first?.remainingQuantity, 2)
        XCTAssertTrue(holding.disposals.isEmpty)
    }

    func testPositionValueRejectsQuantityTimesPriceOverflow() throws {
        let usd = try CurrencyCode("USD")
        let huge = try XCTUnwrap(
            Decimal(string: "9e127", locale: Locale(identifier: "en_US_POSIX"))
        )

        XCTAssertThrowsError(try InvestmentHolding.positionValue(
            quantity: 2,
            unitPrice: try Money(huge, currency: usd)
        )) { error in
            XCTAssertEqual(error as? InvestmentHoldingError, .arithmeticOverflow)
        }
    }

    func testOverflowingSaleProceedsDoNotConsumeLots() throws {
        let usd = try CurrencyCode("USD")
        let huge = try XCTUnwrap(
            Decimal(string: "9e127", locale: Locale(identifier: "en_US_POSIX"))
        )
        let acquiredAt = Date(timeIntervalSinceReferenceDate: 1_000)
        var holding = try InvestmentHolding(
            accountID: UUID(),
            symbol: "MU",
            name: "Micron",
            quantity: 0,
            positionAccountID: UUID()
        )
        try holding.recordPurchase(
            quantity: 2,
            unitCost: try Money(1, currency: usd),
            occurredAt: acquiredAt,
            entryID: UUID()
        )
        let before = holding

        XCTAssertThrowsError(try holding.recordSale(
            quantity: 2,
            unitPrice: try Money(huge, currency: usd),
            occurredAt: acquiredAt.addingTimeInterval(1),
            entryID: UUID()
        )) { error in
            XCTAssertEqual(error as? InvestmentHoldingError, .arithmeticOverflow)
        }
        XCTAssertEqual(holding, before)
    }

    func testOverflowingCostBasisDoesNotConsumeLots() throws {
        let usd = try CurrencyCode("USD")
        let huge = try XCTUnwrap(
            Decimal(string: "9e127", locale: Locale(identifier: "en_US_POSIX"))
        )
        let firstDate = Date(timeIntervalSinceReferenceDate: 1_000)
        var holding = try InvestmentHolding(
            accountID: UUID(),
            symbol: "MU",
            name: "Micron",
            quantity: 0,
            positionAccountID: UUID()
        )
        try holding.recordPurchase(
            quantity: 1,
            unitCost: try Money(huge, currency: usd),
            occurredAt: firstDate,
            entryID: UUID()
        )
        try holding.recordPurchase(
            quantity: 1,
            unitCost: try Money(huge, currency: usd),
            occurredAt: firstDate.addingTimeInterval(1),
            entryID: UUID()
        )
        let before = holding

        XCTAssertThrowsError(try holding.recordSale(
            quantity: 2,
            unitPrice: try Money(1, currency: usd),
            occurredAt: firstDate.addingTimeInterval(2),
            entryID: UUID()
        )) { error in
            XCTAssertEqual(error as? InvestmentHoldingError, .arithmeticOverflow)
        }
        XCTAssertEqual(holding, before)
    }

    func testSameTimestampSalesKeepPersistedFIFOOrderAcrossRoundTrip() throws {
        let usd = try CurrencyCode("USD")
        let acquiredAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let soldAt = Date(timeIntervalSinceReferenceDate: 2_000)
        var holding = try InvestmentHolding(
            accountID: UUID(),
            symbol: "MU",
            name: "Micron",
            quantity: 0,
            positionAccountID: UUID()
        )
        try holding.recordPurchase(
            quantity: 1,
            unitCost: try Money(10, currency: usd),
            occurredAt: acquiredAt,
            entryID: UUID()
        )
        try holding.recordPurchase(
            quantity: 2,
            unitCost: try Money(100, currency: usd),
            occurredAt: acquiredAt,
            entryID: UUID()
        )
        let first = try holding.recordSale(
            quantity: Decimal(string: "1.5")!,
            unitPrice: try Money(120, currency: usd),
            occurredAt: soldAt,
            entryID: UUID()
        )
        let second = try holding.recordSale(
            quantity: Decimal(string: "0.5")!,
            unitPrice: try Money(120, currency: usd),
            occurredAt: soldAt,
            entryID: UUID()
        )

        let restored = try JSONDecoder().decode(
            InvestmentHolding.self,
            from: JSONEncoder().encode(holding)
        )

        XCTAssertEqual(first.costBasis.amount, 60)
        XCTAssertEqual(second.costBasis.amount, 50)
        XCTAssertEqual(restored, holding)
        XCTAssertEqual(restored.disposals.map(\.costBasis.amount), [60, 50])
        XCTAssertEqual(Set(restored.disposals.map(\.activitySequence)).count, 2)
    }

    func testPurchaseAfterSaleAtSameInstantDoesNotRewritePriorFIFO() throws {
        let usd = try CurrencyCode("USD")
        let instant = Date(timeIntervalSinceReferenceDate: 1_000)
        var holding = try InvestmentHolding(
            accountID: UUID(),
            symbol: "MU",
            name: "Micron",
            quantity: 0,
            positionAccountID: UUID()
        )
        try holding.recordPurchase(
            quantity: 1,
            unitCost: try Money(10, currency: usd),
            occurredAt: instant,
            entryID: UUID()
        )
        let firstSale = try holding.recordSale(
            quantity: 1,
            unitPrice: try Money(20, currency: usd),
            occurredAt: instant,
            entryID: UUID()
        )
        try holding.recordPurchase(
            quantity: 1,
            unitCost: try Money(50, currency: usd),
            occurredAt: instant,
            entryID: UUID()
        )
        var restored = try JSONDecoder().decode(
            InvestmentHolding.self,
            from: JSONEncoder().encode(holding)
        )
        let secondSale = try restored.recordSale(
            quantity: 1,
            unitPrice: try Money(60, currency: usd),
            occurredAt: instant,
            entryID: UUID()
        )

        XCTAssertEqual(firstSale.costBasis.amount, 10)
        XCTAssertEqual(secondSale.costBasis.amount, 50)
        XCTAssertEqual(restored.quantity, 0)
    }

    func testPriceCurrencyChangeIsRejectedWithoutMutation() throws {
        let usd = try CurrencyCode("USD")
        let eur = try CurrencyCode("EUR")
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        var holding = try InvestmentHolding(
            accountID: UUID(),
            symbol: "MU",
            name: "Micron",
            quantity: 1,
            price: try Money(10, currency: usd),
            priceAsOf: date,
            positionAccountID: nil
        )
        let before = holding

        XCTAssertThrowsError(try holding.recordPrice(
            try Money(12, currency: eur),
            asOf: date.addingTimeInterval(1)
        )) { error in
            XCTAssertEqual(error as? InvestmentHoldingError, .valuationCurrencyMismatch)
        }
        XCTAssertEqual(holding, before)
    }

    func testCorruptDuplicateLotAndDisposalArithmeticFailDecode() throws {
        let usd = try CurrencyCode("USD")
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        var holding = try InvestmentHolding(
            accountID: UUID(),
            symbol: "MU",
            name: "Micron",
            quantity: 0,
            positionAccountID: UUID()
        )
        try holding.recordPurchase(
            quantity: 1,
            unitCost: try Money(10, currency: usd),
            occurredAt: date,
            entryID: UUID()
        )
        try holding.recordPurchase(
            quantity: 1,
            unitCost: try Money(20, currency: usd),
            occurredAt: date.addingTimeInterval(1),
            entryID: UUID()
        )
        _ = try holding.recordSale(
            quantity: 1,
            unitPrice: try Money(30, currency: usd),
            occurredAt: date.addingTimeInterval(2),
            entryID: UUID()
        )
        let encoded = try JSONEncoder().encode(holding)

        var duplicateObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var duplicateLots = try XCTUnwrap(duplicateObject["lots"] as? [[String: Any]])
        duplicateLots[1]["id"] = duplicateLots[0]["id"]
        duplicateObject["lots"] = duplicateLots
        XCTAssertThrowsError(try JSONDecoder().decode(
            InvestmentHolding.self,
            from: JSONSerialization.data(withJSONObject: duplicateObject)
        ))

        var arithmeticObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var disposals = try XCTUnwrap(arithmeticObject["disposals"] as? [[String: Any]])
        var realized = try XCTUnwrap(disposals[0]["realizedGainLoss"] as? [String: Any])
        realized["amount"] = 999
        disposals[0]["realizedGainLoss"] = realized
        arithmeticObject["disposals"] = disposals
        XCTAssertThrowsError(try JSONDecoder().decode(
            InvestmentHolding.self,
            from: JSONSerialization.data(withJSONObject: arithmeticObject)
        ))
    }

    func testPriceJournalLinkRoundTripsAndCannotBeReusedForTwoPrices() throws {
        let usd = try CurrencyCode("USD")
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        let entryID = UUID()
        var holding = try InvestmentHolding(
            accountID: UUID(),
            symbol: "MU",
            name: "Micron",
            quantity: 0,
            positionAccountID: UUID()
        )
        try holding.recordPurchase(
            quantity: 1,
            unitCost: try Money(10, currency: usd),
            occurredAt: date,
            entryID: entryID
        )
        try holding.recordPrice(
            try Money(10, currency: usd),
            asOf: date,
            entryID: entryID
        )

        let encoded = try JSONEncoder().encode(holding)
        let restored = try JSONDecoder().decode(InvestmentHolding.self, from: encoded)
        XCTAssertEqual(restored.priceHistory.first?.priceEntryID, entryID)
        XCTAssertEqual(restored.linkedEntryIDs, Set([entryID]))

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var history = try XCTUnwrap(object["priceHistory"] as? [[String: Any]])
        var duplicate = history[0]
        duplicate["id"] = UUID().uuidString
        duplicate["activitySequence"] = 3
        history.append(duplicate)
        object["priceHistory"] = history
        XCTAssertThrowsError(try JSONDecoder().decode(
            InvestmentHolding.self,
            from: JSONSerialization.data(withJSONObject: object)
        ))
    }

    func testArchivingZeroQuantityPreservesInvestmentHistory() throws {
        let usd = try CurrencyCode("USD")
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        var holding = try InvestmentHolding(
            accountID: UUID(),
            symbol: "MU",
            name: "Micron",
            quantity: 0,
            positionAccountID: UUID()
        )
        try holding.recordPurchase(
            quantity: 1,
            unitCost: try Money(10, currency: usd),
            occurredAt: date,
            entryID: UUID()
        )
        _ = try holding.recordSale(
            quantity: 1,
            unitPrice: try Money(12, currency: usd),
            occurredAt: date.addingTimeInterval(1),
            entryID: UUID()
        )
        try holding.archive()

        let restored = try JSONDecoder().decode(
            InvestmentHolding.self,
            from: JSONEncoder().encode(holding)
        )
        XCTAssertTrue(restored.isArchived)
        XCTAssertEqual(restored.lots.count, 1)
        XCTAssertEqual(restored.disposals.count, 1)
    }

    func testCorruptExtremeLotAggregationFailsWithoutMutation() throws {
        let usd = try CurrencyCode("USD")
        let huge = try XCTUnwrap(
            Decimal(string: "9e127", locale: Locale(identifier: "en_US_POSIX"))
        )
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        var holding = try InvestmentHolding(
            accountID: UUID(),
            symbol: "MU",
            name: "Micron",
            quantity: 0,
            positionAccountID: UUID()
        )
        try holding.recordPurchase(
            quantity: 1,
            unitCost: try Money(1, currency: usd),
            occurredAt: date,
            entryID: UUID()
        )
        try holding.recordPurchase(
            quantity: 1,
            unitCost: try Money(1, currency: usd),
            occurredAt: date,
            entryID: UUID()
        )
        holding.lots[0].remainingQuantity = huge
        holding.lots[1].remainingQuantity = huge
        let before = holding

        XCTAssertThrowsError(try holding.recordSale(
            quantity: 1,
            unitPrice: try Money(1, currency: usd),
            occurredAt: date.addingTimeInterval(1),
            entryID: UUID()
        )) { error in
            XCTAssertEqual(error as? InvestmentHoldingError, .arithmeticOverflow)
        }
        XCTAssertEqual(holding, before)
    }

    func testPurchaseMovesCashToPositionWithoutInflatingNetWorth() throws {
        let sgd = try CurrencyCode("SGD")
        let cash = LedgerAccount(name: "Brokerage cash", kind: .asset, currency: sgd)
        let position = LedgerAccount(
            name: "MU position",
            kind: .asset,
            currency: sgd,
            systemRole: .investmentPosition
        )
        let equity = LedgerAccount(
            name: "Opening balances",
            kind: .equity,
            systemRole: .openingBalances
        )
        let gain = LedgerAccount(
            name: "Investment gain/loss",
            kind: .trading,
            currency: sgd,
            systemRole: .investmentGainLoss
        )
        let opening = try TransactionFactory.balanceAdjustment(
            displayBalanceDelta: try Money(10_000, currency: sgd),
            accountID: cash.id,
            equityAccountID: equity.id,
            accountIsLiability: false
        )
        let purchase = try TransactionFactory.investmentPurchase(
            cashCost: try Money(4_000, currency: sgd),
            resultingPositionValue: try Money(4_000, currency: sgd),
            previousPositionValue: .zero(currency: sgd),
            cashAccountID: cash.id,
            positionAccountID: position.id,
            gainLossAccountID: gain.id
        )

        let entries = [opening, purchase]
        let cashBalance = try FinanceCalculator.displayBalance(for: cash, entries: entries)
        let positionBalance = try FinanceCalculator.displayBalance(for: position, entries: entries)

        XCTAssertEqual(cashBalance?.amount, 6_000)
        XCTAssertEqual(positionBalance?.amount, 4_000)
        XCTAssertEqual((cashBalance?.amount ?? 0) + (positionBalance?.amount ?? 0), 10_000)
        XCTAssertTrue(purchase.balanceByCurrency.values.allSatisfy { $0 == .zero })
    }

    func testNetWorthSnapshotRoundTripsAsFrozenCurrencyAmounts() throws {
        let sgd = try CurrencyCode("SGD")
        let usd = try CurrencyCode("USD")
        let rateDate = Date(timeIntervalSince1970: 10_000)
        let converted = try Money(135, currency: sgd)
        let evidence = try NetWorthConversionEvidence(
            source: try Money(100, currency: usd),
            appliedRate: Decimal(string: "1.35")!,
            rateID: UUID(),
            effectiveDayKey: 19700101,
            usedInverseRate: false,
            converted: converted
        )
        let snapshot = try NetWorthSnapshot(
            capturedAt: Date(timeIntervalSince1970: 20_000),
            amounts: [try Money(100, currency: usd)],
            estimatedBaseTotal: converted,
            conversionAsOf: rateDate,
            conversionAsOfDayKey: 19700101,
            conversionEvidence: [evidence]
        )
        let restored = try JSONDecoder().decode(
            NetWorthSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )

        XCTAssertEqual(restored, snapshot)
        XCTAssertEqual(restored.conversionAsOf, rateDate)
        XCTAssertEqual(restored.conversionEvidence, [evidence])
    }

    func testLatestPurchaseCorrectionRetainsSourceAndClearsProjection() throws {
        let usd = try CurrencyCode("USD")
        let purchasedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let correctedAt = purchasedAt.addingTimeInterval(60)
        let purchaseEntryID = UUID()
        let correctionEntryID = UUID()
        var holding = try InvestmentHolding(
            accountID: UUID(),
            symbol: "MU",
            name: "Micron",
            quantity: .zero,
            positionAccountID: UUID()
        )
        try holding.recordPurchase(
            quantity: 2,
            unitCost: try Money(10, currency: usd),
            occurredAt: purchasedAt,
            entryID: purchaseEntryID
        )
        try holding.recordPrice(
            try Money(10, currency: usd),
            asOf: purchasedAt,
            entryID: purchaseEntryID
        )
        let sourceLotID = try XCTUnwrap(holding.lots.first?.id)
        let sourcePriceID = try XCTUnwrap(holding.priceHistory.first?.id)

        let outcome = try holding.correctLatestActivity(
            targetActivityID: sourceLotID,
            correctionEntryID: correctionEntryID,
            occurredAt: correctedAt
        )

        XCTAssertEqual(outcome.kind, .purchase)
        XCTAssertEqual(holding.quantity, .zero)
        XCTAssertNil(holding.price)
        XCTAssertNil(holding.priceAsOf)
        XCTAssertEqual(holding.lots.map(\.id), [sourceLotID])
        XCTAssertEqual(holding.lots.first?.remainingQuantity, .zero)
        XCTAssertEqual(holding.priceHistory.map(\.id), [sourcePriceID])
        XCTAssertEqual(holding.corrections.count, 1)
        XCTAssertEqual(holding.corrections.first?.targetEntryID, purchaseEntryID)
        XCTAssertEqual(
            holding.linkedEntryIDs,
            Set([purchaseEntryID, correctionEntryID])
        )

        let restored = try JSONDecoder().decode(
            InvestmentHolding.self,
            from: JSONEncoder().encode(holding)
        )
        XCTAssertEqual(restored, holding)
    }

    func testSaleCorrectionRestoresFIFOProjectionWithoutDeletingDisposal() throws {
        let usd = try CurrencyCode("USD")
        let purchasedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let soldAt = purchasedAt.addingTimeInterval(60)
        let correctedAt = soldAt.addingTimeInterval(60)
        let purchaseEntryID = UUID()
        let saleEntryID = UUID()
        let correctionEntryID = UUID()
        var holding = try InvestmentHolding(
            accountID: UUID(),
            symbol: "MU",
            name: "Micron",
            quantity: .zero,
            positionAccountID: UUID()
        )
        try holding.recordPurchase(
            quantity: 2,
            unitCost: try Money(10, currency: usd),
            occurredAt: purchasedAt,
            entryID: purchaseEntryID
        )
        try holding.recordPrice(
            try Money(10, currency: usd),
            asOf: purchasedAt,
            entryID: purchaseEntryID
        )
        _ = try holding.recordSale(
            quantity: 1,
            unitPrice: try Money(15, currency: usd),
            occurredAt: soldAt,
            entryID: saleEntryID
        )
        try holding.recordPrice(
            try Money(15, currency: usd),
            asOf: soldAt,
            entryID: saleEntryID
        )
        let disposalID = try XCTUnwrap(holding.disposals.first?.id)

        XCTAssertThrowsError(try holding.correctLatestActivity(
            targetActivityID: try XCTUnwrap(holding.lots.first?.id),
            correctionEntryID: correctionEntryID,
            occurredAt: correctedAt
        )) { error in
            XCTAssertEqual(error as? InvestmentHoldingError, .correctionUnavailable)
        }
        let outcome = try holding.correctLatestActivity(
            targetActivityID: disposalID,
            correctionEntryID: correctionEntryID,
            occurredAt: correctedAt
        )

        XCTAssertEqual(outcome.kind, .sale)
        XCTAssertEqual(holding.quantity, 2)
        XCTAssertEqual(holding.lots.first?.remainingQuantity, 2)
        XCTAssertEqual(holding.disposals.map(\.id), [disposalID])
        XCTAssertEqual(holding.disposals.first?.saleEntryID, saleEntryID)
        XCTAssertEqual(holding.price?.amount, 10)
        XCTAssertEqual(holding.priceAsOf, correctedAt)
        XCTAssertEqual(holding.priceHistory.count, 3)
        XCTAssertEqual(
            holding.priceHistory.last?.priceEntryID,
            correctionEntryID
        )
        XCTAssertEqual(holding.latestCorrectableActivity?.kind, .purchase)
    }

    func testValuationCorrectionRestoresPriorPriceAndSupportsZeroDeltaSource() throws {
        let usd = try CurrencyCode("USD")
        let purchasedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let valuedAt = purchasedAt.addingTimeInterval(60)
        let correctedAt = valuedAt.addingTimeInterval(60)
        let purchaseEntryID = UUID()
        let valuationEntryID = UUID()
        var holding = try InvestmentHolding(
            accountID: UUID(),
            symbol: "MU",
            name: "Micron",
            quantity: .zero,
            positionAccountID: UUID()
        )
        try holding.recordPurchase(
            quantity: 1,
            unitCost: try Money(10, currency: usd),
            occurredAt: purchasedAt,
            entryID: purchaseEntryID
        )
        try holding.recordPrice(
            try Money(10, currency: usd),
            asOf: purchasedAt,
            entryID: purchaseEntryID
        )
        try holding.recordPrice(
            try Money(20, currency: usd),
            asOf: valuedAt,
            entryID: valuationEntryID
        )
        let target = try XCTUnwrap(holding.latestCorrectableActivity)
        XCTAssertEqual(target.kind, .valuation)

        _ = try holding.correctLatestActivity(
            targetActivityID: target.id,
            correctionEntryID: UUID(),
            occurredAt: correctedAt
        )
        XCTAssertEqual(holding.price?.amount, 10)
        XCTAssertEqual(holding.priceAsOf, correctedAt)
        XCTAssertTrue(holding.priceHistory.contains { $0.id == target.id })

        let zeroDeltaAt = correctedAt.addingTimeInterval(60)
        try holding.recordPrice(
            try Money(10, currency: usd),
            asOf: zeroDeltaAt,
            entryID: nil
        )
        let zeroDeltaTarget = try XCTUnwrap(holding.latestCorrectableActivity)
        XCTAssertNil(zeroDeltaTarget.linkedEntryID)
        _ = try holding.correctLatestActivity(
            targetActivityID: zeroDeltaTarget.id,
            correctionEntryID: nil,
            occurredAt: zeroDeltaAt.addingTimeInterval(60)
        )
        XCTAssertEqual(holding.price?.amount, 10)
        XCTAssertNil(holding.corrections.last?.correctionEntryID)
    }
}
