import Foundation
import MoneyUpCore
import MoneyUpPersistence

struct RestoreInvestmentRelationshipState: Sendable {
    let linkedEntries: [UUID: JournalEntry]
    var positionOwners: [UUID: UUID] = [:]
}

extension RestoreCandidateValidator {
    @discardableResult
    static func validateRelationships(
        profile: UserProfile?,
        accounts: [LedgerAccount],
        budgetNodes: [BudgetNode],
        scheduledTransactions: [ScheduledTransaction],
        investmentHoldings: [InvestmentHolding],
        netWorthSnapshots: [NetWorthSnapshot],
        quickLogDraft: QuickLogDraft?,
        in store: EncryptedRecordStore
    ) async throws -> RestoreEntryPreviewMetadata {
        let profile = try validatedRelationshipProfile(
            profile,
            accounts: accounts,
            schedules: scheduledTransactions,
            holdings: investmentHoldings,
            snapshots: netWorthSnapshots
        )
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
        try validateRelationshipJournal(journalEntries)
        let journalByID = Dictionary(
            uniqueKeysWithValues: journalEntries.map { ($0.id, $0) }
        )
        try validateRelationshipAccounts(accounts, accountByID: accountByID)
        try validateAccountParentCycles(accountByID)
        try validateRelationshipSystemAccounts(accounts)
        try validateSystemPostingOwners(journalEntries, accountByID: accountByID)
        try validateRelationshipBudgetNodes(budgetNodes, accountByID: accountByID)
        try validateRelationshipPreferences(profile, accountByID: accountByID)
        try validateRelationshipSchedules(
            scheduledTransactions,
            calendar: reportingCalendar,
            accountByID: accountByID,
            journalByID: journalByID
        )
        var investmentState = try validateInvestmentOwnership(
            investmentHoldings,
            journalEntries: journalEntries,
            journalByID: journalByID
        )
        let ledger = try await validatedRelationshipLedger(
            accounts: accounts,
            accountByID: accountByID,
            store: store
        )
        try validateRelationshipHoldings(
            investmentHoldings,
            accounts: accounts,
            accountByID: accountByID,
            ledger: ledger,
            state: &investmentState
        )
        try await validateBudgetAttributions(
            journalEntries: journalEntries,
            journalByID: journalByID,
            accountByID: accountByID,
            in: store
        )
        try validateRelationshipDraft(quickLogDraft, accountByID: accountByID)
        return try RestoreEntryPreviewMetadata.make(from: journalEntries)
    }
}

extension RestoreCandidateValidator {
    static func validatedRelationshipProfile(
        _ profile: UserProfile?,
        accounts: [LedgerAccount],
        schedules: [ScheduledTransaction],
        holdings: [InvestmentHolding],
        snapshots: [NetWorthSnapshot]
    ) throws -> UserProfile {
        guard let profile,
              Set(accounts.map(\.id)).count == accounts.count,
              Set(schedules.map(\.id)).count == schedules.count,
              Set(holdings.map(\.id)).count == holdings.count,
              Set(snapshots.map(\.id)).count == snapshots.count,
              snapshots.allSatisfy({
                  $0.capturedAt.timeIntervalSinceReferenceDate.isFinite
              }) else { throw AppModelError.invalidBook }
        return profile
    }

    static func validateRelationshipJournal(
        _ entries: [JournalEntry]
    ) throws {
        guard entries.count <= maximumJournalEntryCount,
              Set(entries.map(\.id)).count == entries.count else {
            throw AppModelError.invalidBook
        }
        var postingCount = 0
        for (index, entry) in entries.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            let (nextCount, overflow) = postingCount
                .addingReportingOverflow(entry.postings.count)
            guard entry.postings.count <= maximumJournalPostingsPerEntry,
                  !overflow,
                  nextCount <= maximumJournalPostingCount else {
                throw AppModelError.invalidBook
            }
            postingCount = nextCount
        }
    }

    static func validateRelationshipAccounts(
        _ accounts: [LedgerAccount],
        accountByID: [UUID: LedgerAccount]
    ) throws {
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
    }

    static func validateAccountParentCycles(
        _ accountByID: [UUID: LedgerAccount]
    ) throws {
        // Parent pointers are functional. Tri-color each path once instead of
        // walking every account to the root (quadratic for a crafted chain).
        var visitState: [UUID: UInt8] = [:]
        var visitCount = 0
        for start in accountByID.keys where visitState[start] != 2 {
            var path: [UUID] = []
            var current: UUID? = start
            while let candidate = current {
                if visitCount.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                visitCount += 1
                if visitState[candidate] == 1 {
                    throw AppModelError.invalidBook
                }
                if visitState[candidate] == 2 { break }
                visitState[candidate] = 1
                path.append(candidate)
                current = accountByID[candidate]?.parentID
            }
            for candidate in path { visitState[candidate] = 2 }
        }
    }

    static func validateRelationshipSystemAccounts(
        _ accounts: [LedgerAccount]
    ) throws {
        var openingBalancesID: UUID?
        var currencyScopedRoles = Set<String>()
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
                guard currencyScopedRoles.insert(identity).inserted else {
                    throw AppModelError.invalidBook
                }
            case .investmentPosition:
                guard account.kind == .asset,
                      account.currency != nil else {
                    throw AppModelError.invalidBook
                }
            }
        }
    }

    static func validateSystemPostingOwners(
        _ entries: [JournalEntry],
        accountByID: [UUID: LedgerAccount]
    ) throws {
        var postingCount = 0
        for entry in entries {
            for posting in entry.postings {
                if postingCount.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                postingCount += 1
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
    }

    static func validateRelationshipBudgetNodes(
        _ nodes: [BudgetNode],
        accountByID: [UUID: LedgerAccount]
    ) throws {
        for node in nodes {
            guard let account = accountByID[node.id],
                  account.kind == .expense,
                  node.parentID == account.parentID else {
                throw AppModelError.invalidBook
            }
        }
    }

    static func validateRelationshipPreferences(
        _ profile: UserProfile,
        accountByID: [UUID: LedgerAccount]
    ) throws {
        func requirePreference(
            _ id: UUID?,
            kinds: [LedgerAccountKind]
        ) throws {
            guard let id else { return }
            guard let account = accountByID[id],
                  kinds.contains(account.kind) else {
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
    }

    static func validateRelationshipSchedules(
        _ schedules: [ScheduledTransaction],
        calendar: Calendar,
        accountByID: [UUID: LedgerAccount],
        journalByID: [UUID: JournalEntry]
    ) throws {
        var entryOwners: [UUID: UUID] = [:]
        for schedule in schedules {
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
                try schedule.validateLifecycle(calendar: calendar)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AppModelError.invalidBook
            }
            for linkedID in schedule.resolutions.compactMap(\.linkedEntryID) {
                guard entryOwners.updateValue(schedule.id, forKey: linkedID) == nil,
                      let linkedEntry = journalByID[linkedID],
                      schedule.matches(linkedEntry) else {
                    throw AppModelError.invalidBook
                }
            }
        }
    }
}

extension RestoreCandidateValidator {
    static func validateInvestmentOwnership(
        _ holdings: [InvestmentHolding],
        journalEntries: [JournalEntry],
        journalByID: [UUID: JournalEntry]
    ) throws -> RestoreInvestmentRelationshipState {
        var entryOwners: [UUID: UUID] = [:]
        var linkedEntries: [UUID: JournalEntry] = [:]
        var activityCount = 0
        for (index, holding) in holdings.enumerated() {
            if index.isMultiple(of: 64) { try Task.checkCancellation() }
            let counts = [
                holding.priceHistory.count,
                holding.lots.count,
                holding.disposals.count,
                holding.corrections.count
            ]
            guard counts.allSatisfy({
                $0 <= maximumHoldingActivitiesPerCollection
            }) else { throw AppModelError.invalidBook }
            activityCount = try boundedAggregateCount(
                current: activityCount,
                adding: counts.reduce(0, +),
                perRecordLimit: maximumHoldingActivitiesPerHolding,
                aggregateLimit: maximumHoldingActivityCount
            )
            for linkedID in holding.linkedEntryIDs {
                guard entryOwners.updateValue(
                    holding.id,
                    forKey: linkedID
                ) == nil,
                let entry = journalByID[linkedID] else {
                    throw AppModelError.invalidBook
                }
                linkedEntries[linkedID] = entry
            }
        }
        let investmentEntryIDs = Set(
            journalEntries.lazy.filter { $0.kind == .investment }.map(\.id)
        )
        guard Set(entryOwners.keys) == investmentEntryIDs else {
            throw AppModelError.invalidBook
        }
        return RestoreInvestmentRelationshipState(linkedEntries: linkedEntries)
    }

    static func validatedRelationshipLedger(
        accounts: [LedgerAccount],
        accountByID: [UUID: LedgerAccount],
        store: EncryptedRecordStore
    ) async throws -> JournalLedgerIndexSnapshot {
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
        return ledger
    }

    static func validateRelationshipHoldings(
        _ holdings: [InvestmentHolding],
        accounts: [LedgerAccount],
        accountByID: [UUID: LedgerAccount],
        ledger: JournalLedgerIndexSnapshot,
        state: inout RestoreInvestmentRelationshipState
    ) throws {
        for holding in holdings {
            try validateRelationshipHolding(
                holding,
                accountByID: accountByID,
                ledger: ledger,
                state: &state
            )
        }
        for position in accounts where position.systemRole == .investmentPosition {
            guard state.positionOwners[position.id] != nil else {
                throw AppModelError.invalidBook
            }
        }
    }

    static func validateRelationshipHolding(
        _ holding: InvestmentHolding,
        accountByID: [UUID: LedgerAccount],
        ledger: JournalLedgerIndexSnapshot,
        state: inout RestoreInvestmentRelationshipState
    ) throws {
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
            return
        }
        guard positionID != funding.id,
              state.positionOwners.updateValue(
                  holding.id,
                  forKey: positionID
              ) == nil,
              let position = accountByID[positionID],
              position.kind == .asset,
              position.systemRole == .investmentPosition,
              position.currency == currency,
              position.isArchived == holding.isArchived else {
            throw AppModelError.invalidBook
        }
        try validateInvestmentLedgerIntegrity(
            holding,
            accountByID: accountByID,
            linkedEntries: state.linkedEntries
        )
        guard holding.linkedEntryIDs.allSatisfy({ linkedID in
            guard let entry = state.linkedEntries[linkedID] else { return false }
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

    static func validateInvestmentLedgerIntegrity(
        _ holding: InvestmentHolding,
        accountByID: [UUID: LedgerAccount],
        linkedEntries: [UUID: JournalEntry]
    ) throws {
        do {
            try InvestmentLedgerIntegrity.validate(
                holding: holding,
                accountsByID: accountByID,
                entriesByID: linkedEntries
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AppModelError.invalidBook
        }
    }

    static func validateRelationshipDraft(
        _ draft: QuickLogDraft?,
        accountByID: [UUID: LedgerAccount]
    ) throws {
        guard let draft else { return }
        guard draft.occurredAt.timeIntervalSinceReferenceDate.isFinite,
              Set(draft.splitLines.map(\.id)).count == draft.splitLines.count else {
            throw AppModelError.invalidBook
        }
        for id in [
            draft.accountID,
            draft.destinationAccountID,
            draft.categoryID
        ].compactMap({ $0 }) where accountByID[id] == nil {
            throw AppModelError.invalidBook
        }
        let expectedSplitKind: LedgerAccountKind?
        switch draft.kind {
        case .expense, .refund:
            expectedSplitKind = .expense
        case .income:
            expectedSplitKind = .income
        case .transfer:
            expectedSplitKind = nil
        }
        guard expectedSplitKind != nil || draft.splitLines.isEmpty else {
            throw AppModelError.invalidBook
        }
        for split in draft.splitLines {
            if let categoryID = split.categoryID,
               accountByID[categoryID]?.kind != expectedSplitKind {
                throw AppModelError.invalidBook
            }
        }
    }
}
