import Foundation
import MoneyUpCore
import MoneyUpPersistence

extension RestoreCandidateValidator {
    static func validateRelationships(
        profile: UserProfile?,
        accounts: [LedgerAccount],
        budgetNodes: [BudgetNode],
        scheduledTransactions: [ScheduledTransaction],
        investmentHoldings: [InvestmentHolding],
        netWorthSnapshots: [NetWorthSnapshot],
        quickLogDraft: QuickLogDraft?,
        in store: EncryptedRecordStore
    ) async throws {
        guard let profile,
              Set(accounts.map(\.id)).count == accounts.count,
              Set(scheduledTransactions.map(\.id)).count
                == scheduledTransactions.count,
              Set(investmentHoldings.map(\.id)).count
                == investmentHoldings.count,
              Set(netWorthSnapshots.map(\.id)).count
                == netWorthSnapshots.count,
              netWorthSnapshots.allSatisfy({
                  $0.capturedAt.timeIntervalSinceReferenceDate.isFinite
              }) else { throw AppModelError.invalidBook }
        let accountByID = Dictionary(
            uniqueKeysWithValues: accounts.map { ($0.id, $0) }
        )
        let reportingCalendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: profile.reportingTimeZoneIdentifier
        )
        let journalEntries = try await store.fetchAll(
            JournalEntry.self,
            from: .journalEntries
        )
        guard journalEntries.count <= maximumJournalEntryCount,
              Set(journalEntries.map(\.id)).count == journalEntries.count else {
            throw AppModelError.invalidBook
        }
        var journalPostingCount = 0
        for (entryIndex, entry) in journalEntries.enumerated() {
            if entryIndex.isMultiple(of: 256) { try Task.checkCancellation() }
            let (nextPostingCount, overflow) = journalPostingCount
                .addingReportingOverflow(entry.postings.count)
            guard entry.postings.count <= maximumJournalPostingsPerEntry,
                  !overflow,
                  nextPostingCount <= maximumJournalPostingCount else {
                throw AppModelError.invalidBook
            }
            journalPostingCount = nextPostingCount
        }
        let journalByID = Dictionary(
            uniqueKeysWithValues: journalEntries.map { ($0.id, $0) }
        )

        for (index, account) in accounts.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            if account.kind == .asset || account.kind == .liability {
                guard account.currency != nil else {
                    throw AppModelError.invalidBook
                }
            }
            if let parentID = account.parentID {
                guard let parent = accountByID[parentID],
                      parent.kind == account.kind else {
                    throw AppModelError.invalidBook
                }
            }
        }
        // Parent pointers are functional. Tri-color each path once instead of
        // walking every account to the root (quadratic for a crafted chain).
        var accountVisitState: [UUID: UInt8] = [:]
        var accountVisitCount = 0
        for start in accountByID.keys where accountVisitState[start] != 2 {
            var path: [UUID] = []
            var current: UUID? = start
            while let candidate = current {
                if accountVisitCount.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                accountVisitCount += 1
                if accountVisitState[candidate] == 1 {
                    throw AppModelError.invalidBook
                }
                if accountVisitState[candidate] == 2 { break }
                accountVisitState[candidate] = 1
                path.append(candidate)
                current = accountByID[candidate]?.parentID
            }
            for candidate in path { accountVisitState[candidate] = 2 }
        }

        var openingBalancesID: UUID?
        var currencyScopedSystemRoles = Set<String>()
        for account in accounts {
            guard let role = account.systemRole else { continue }
            guard account.parentID == nil,
                  account.accountType == nil else {
                throw AppModelError.invalidBook
            }
            switch role {
            case .openingBalances:
                guard account.kind == .equity,
                      account.currency == nil,
                      !account.isArchived,
                      openingBalancesID == nil else {
                    throw AppModelError.invalidBook
                }
                openingBalancesID = account.id
            case .foreignExchange, .investmentGainLoss:
                guard account.kind == .trading,
                      let currency = account.currency,
                      !account.isArchived else {
                    throw AppModelError.invalidBook
                }
                let identity = role.rawValue + "\u{1f}" + currency.value
                guard currencyScopedSystemRoles.insert(identity).inserted else {
                    throw AppModelError.invalidBook
                }
            case .investmentPosition:
                guard account.kind == .asset,
                      account.currency != nil else {
                    throw AppModelError.invalidBook
                }
            }
        }

        var validatedPostingCount = 0
        for entry in journalEntries {
            for posting in entry.postings {
                if validatedPostingCount.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                validatedPostingCount += 1
                guard let role = accountByID[posting.accountID]?.systemRole else {
                    continue
                }
                let hasValidOwner: Bool
                switch role {
                case .openingBalances:
                    hasValidOwner = entry.kind == .adjustment
                        || entry.kind == .investment
                case .foreignExchange:
                    hasValidOwner = entry.kind == .transfer
                case .investmentPosition, .investmentGainLoss:
                    hasValidOwner = entry.kind == .investment
                }
                guard hasValidOwner else { throw AppModelError.invalidBook }
            }
        }

        for node in budgetNodes {
            guard let account = accountByID[node.id],
                  account.kind == .expense,
                  node.parentID == account.parentID else {
                throw AppModelError.invalidBook
            }
        }

        func requirePreference(
            _ id: UUID?,
            kinds: [LedgerAccountKind]
        ) throws {
            guard let id else { return }
            guard let account = accountByID[id], kinds.contains(account.kind) else {
                throw AppModelError.invalidBook
            }
        }
        try requirePreference(
            profile.preferredAccountID,
            kinds: [.asset, .liability]
        )
        try requirePreference(
            profile.preferredExpenseCategoryID,
            kinds: [.expense]
        )
        try requirePreference(
            profile.preferredIncomeCategoryID,
            kinds: [.income]
        )

        var scheduleEntryOwners: [UUID: UUID] = [:]
        for schedule in scheduledTransactions {
            guard let account = accountByID[schedule.accountID],
                  let category = accountByID[schedule.categoryAccountID],
                  !account.isArchived,
                  !category.isArchived,
                  let currency = account.currency,
                  currency == schedule.amount.currency,
                  account.kind == .asset || account.kind == .liability,
                  account.systemRole == nil,
                  category.systemRole == nil,
                  ((schedule.kind == .expense && category.kind == .expense)
                    || (schedule.kind == .income && category.kind == .income)) else {
                throw AppModelError.invalidBook
            }
            do {
                try schedule.validateLifecycle(calendar: reportingCalendar)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AppModelError.invalidBook
            }
            for linkedID in schedule.resolutions.compactMap(\.linkedEntryID) {
                guard scheduleEntryOwners.updateValue(
                    schedule.id,
                    forKey: linkedID
                ) == nil,
                let linkedEntry = journalByID[linkedID],
                schedule.matches(linkedEntry) else {
                    throw AppModelError.invalidBook
                }
            }
        }

        var holdingEntryOwners: [UUID: UUID] = [:]
        var positionOwners: [UUID: UUID] = [:]
        var linkedInvestmentEntries: [UUID: JournalEntry] = [:]
        var holdingActivityCount = 0
        for (holdingIndex, holding) in investmentHoldings.enumerated() {
            if holdingIndex.isMultiple(of: 64) { try Task.checkCancellation() }
            let counts = [
                holding.priceHistory.count,
                holding.lots.count,
                holding.disposals.count,
                holding.corrections.count
            ]
            guard counts.allSatisfy({
                $0 <= maximumHoldingActivitiesPerCollection
            }) else {
                throw AppModelError.invalidBook
            }
            let holdingTotal = counts.reduce(0, +)
            holdingActivityCount = try boundedAggregateCount(
                current: holdingActivityCount,
                adding: holdingTotal,
                perRecordLimit: maximumHoldingActivitiesPerHolding,
                aggregateLimit: maximumHoldingActivityCount
            )
            for linkedID in holding.linkedEntryIDs {
                guard holdingEntryOwners.updateValue(
                    holding.id,
                    forKey: linkedID
                ) == nil,
                let entry = journalByID[linkedID] else {
                    throw AppModelError.invalidBook
                }
                linkedInvestmentEntries[linkedID] = entry
            }
        }
        let investmentEntryIDs = Set(
            journalEntries.lazy.filter { $0.kind == .investment }.map(\.id)
        )
        guard Set(holdingEntryOwners.keys) == investmentEntryIDs else {
            throw AppModelError.invalidBook
        }
        let ledger = try await store.journalLedgerIndex(
            validAccountIDs: Set(accountByID.keys),
            expectedAccountCurrencies: Dictionary(
                uniqueKeysWithValues: accounts.compactMap { account in
                    account.currency.map { (account.id, $0) }
                }
            )
        )
        guard ledger.issues.isEmpty,
              ledger.invalidRelationshipEntryIDs.isEmpty else {
            throw AppModelError.invalidBook
        }

        for holding in investmentHoldings {
            guard let funding = accountByID[holding.accountID],
                  funding.kind == .asset,
                  funding.systemRole == nil,
                  funding.accountType == .brokerage
                    || funding.accountType == .investment,
                  let currency = funding.currency,
                  holding.isArchived || !funding.isArchived else {
                throw AppModelError.invalidBook
            }
            let holdingCurrencies = Set(
                [holding.price?.currency]
                    + holding.priceHistory.map { Optional($0.price.currency) }
                    + holding.lots.map { Optional($0.unitCost.currency) }
                    + holding.disposals.flatMap {
                        [Optional($0.costBasis.currency), Optional($0.proceeds.currency),
                         Optional($0.realizedGainLoss.currency)]
                    }
            ).compactMap { $0 }
            guard holdingCurrencies.allSatisfy({ $0 == currency }) else {
                throw AppModelError.invalidBook
            }
            guard let positionID = holding.positionAccountID else {
                guard !holding.isArchived,
                      holding.linkedEntryIDs.isEmpty,
                      holding.quantity == .zero || holding.needsLedgerConnection else {
                    throw AppModelError.invalidBook
                }
                continue
            }
            guard positionID != funding.id,
                  positionOwners.updateValue(holding.id, forKey: positionID) == nil,
                  let position = accountByID[positionID],
                  position.kind == .asset,
                  position.systemRole == .investmentPosition,
                  position.currency == currency,
                  position.isArchived == holding.isArchived else {
                throw AppModelError.invalidBook
            }
            do {
                try InvestmentLedgerIntegrity.validate(
                    holding: holding,
                    accountsByID: accountByID,
                    entriesByID: linkedInvestmentEntries
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AppModelError.invalidBook
            }
            guard holding.linkedEntryIDs.allSatisfy({ linkedID in
                guard let entry = linkedInvestmentEntries[linkedID] else {
                    return false
                }
                return entry.kind == .investment
                    && entry.postings.contains { $0.accountID == positionID }
            }) else { throw AppModelError.invalidBook }
            let expected = try holding.marketValue()
                ?? Money.zero(currency: currency)
            let positionBalances = ledger.balances[positionID] ?? [:]
            guard positionBalances.allSatisfy({ pair in
                pair.key == currency || pair.value.isZero
            }),
            (positionBalances[currency] ?? Money.zero(currency: currency))
                == expected else { throw AppModelError.invalidBook }
        }

        for position in accounts where position.systemRole == .investmentPosition {
            guard positionOwners[position.id] != nil else {
                throw AppModelError.invalidBook
            }
        }

        try await validateBudgetAttributions(
            journalEntries: journalEntries,
            journalByID: journalByID,
            accountByID: accountByID,
            in: store
        )

        if let quickLogDraft {
            guard quickLogDraft.occurredAt.timeIntervalSinceReferenceDate.isFinite,
                  Set(quickLogDraft.splitLines.map(\.id)).count
                    == quickLogDraft.splitLines.count else {
                throw AppModelError.invalidBook
            }
            for id in [
                quickLogDraft.accountID,
                quickLogDraft.destinationAccountID,
                quickLogDraft.categoryID
            ].compactMap({ $0 }) where accountByID[id] == nil {
                throw AppModelError.invalidBook
            }
            let expectedSplitKind: LedgerAccountKind?
            switch quickLogDraft.kind {
            case .expense, .refund:
                expectedSplitKind = .expense
            case .income:
                expectedSplitKind = .income
            case .transfer:
                expectedSplitKind = nil
            }
            guard expectedSplitKind != nil || quickLogDraft.splitLines.isEmpty else {
                throw AppModelError.invalidBook
            }
            for split in quickLogDraft.splitLines {
                if let categoryID = split.categoryID,
                   accountByID[categoryID]?.kind != expectedSplitKind {
                    throw AppModelError.invalidBook
                }
            }
        }

    }
}
