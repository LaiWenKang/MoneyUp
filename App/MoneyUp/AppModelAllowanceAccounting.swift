import Foundation
import MoneyUpCore
import MoneyUpPersistence

struct PreparedAllowanceApplication {
    let entry: JournalEntry
    let plan: AllowancePlan
}

struct PreparedAllowanceReplacement {
    let entry: JournalEntry
    let plans: [AllowancePlan]
}

private struct PreparedAllowanceReconciliation {
    let planIndex: Int
    let plan: AllowancePlan
    let entry: JournalEntry?
    let equity: LedgerAccount
    let writes: [RecordWrite]
}

extension AppModel {
    static let allowanceExpirySourceSystem =
        AllowanceJournalIntegrity.expirySourceSystem

    /// Returns prepaid value spendable at one exact journal instant. This
    /// never substitutes the current display balance for historical ledger
    /// truth, and no value may escape after the logical book changes.
    func prepaidAllowanceSpendable(
        planID: UUID,
        asOf: Date
    ) async throws -> Money {
        try Task.checkCancellation()
        guard asOf.timeIntervalSinceReferenceDate.isFinite else {
            throw AppModelError.invalidAllowance
        }
        let read = try beginLogicalBookRead()
        guard let plan = allowancePlans.first(where: { $0.id == planID }) else {
            throw AppModelError.missingRecord
        }
        try validateAllowanceFunding(plan)
        guard plan.fundingMode == .prepaidAsset,
              !plan.isArchived,
              isAllowanceWritable(plan) else {
            throw AppModelError.invalidAllowance
        }
        let summary = try plan.summary(asOf: asOf)
        guard summary.isAvailableToday else {
            throw AppModelError.invalidAllowance
        }
        let balance = try await restrictedAllowanceBalance(
            for: plan,
            asOf: asOf,
            in: read.store
        )
        try Task.checkCancellation()
        try requireLogicalBookRead(read.token)
        guard allowancePlans.first(where: { $0.id == planID }) == plan,
              !plan.isArchived,
              isAllowanceWritable(plan) else {
            throw AppModelError.invalidAllowance
        }
        try validateAllowanceFunding(plan)
        let result = try Money(
            min(max(summary.remaining.amount, .zero), balance.amount),
            currency: summary.remaining.currency
        )
        let stable = try await finishLogicalBookRead(result, token: read.token)
        try Task.checkCancellation()
        guard allowancePlans.first(where: { $0.id == planID }) == plan,
              !plan.isArchived,
              isAllowanceWritable(plan) else {
            throw AppModelError.invalidAllowance
        }
        try validateAllowanceFunding(plan)
        return stable
    }

    func prepareAllowanceApplication(
        entry: JournalEntry,
        plan: AllowancePlan,
        usageID: UUID = UUID(),
        excludingPrepaidEntryID: UUID? = nil,
        reimbursementClaimStatus: AllowanceClaimStatus? = nil
    ) async throws -> PreparedAllowanceApplication {
        guard !plan.hasGrandfatheredActivity,
              entry.kind == .expense,
              let policy = plan.policy(at: entry.occurredAt) else {
            throw AppModelError.invalidAllowance
        }
        try rejectUsageInReconciledPeriod(
            entry.occurredAt,
            plan: plan
        )
        let eligible = eligibleAllowancePostings(
            in: entry,
            policy: policy
        )
        guard !eligible.isEmpty else { throw AppModelError.invalidAllowance }
        let eligibleAmount = try totalPositiveAmount(eligible)
        let summary = try plan.summary(asOf: entry.occurredAt)
        var available = max(summary.remaining.amount, .zero)
        if plan.fundingMode == .prepaidAsset {
            let ledgerBalance = try await restrictedAllowanceBalance(
                for: plan,
                asOf: entry.occurredAt,
                excludingEntryID: excludingPrepaidEntryID,
                in: requireStore()
            )
            available = min(
                available,
                ledgerBalance.amount
            )
        }
        let applied = min(eligibleAmount, available)
        guard applied > .zero else { throw AppModelError.invalidAllowance }
        let appliedMoney = try Money(applied, currency: policy.amount.currency)
        let appliedEntry = plan.fundingMode == .prepaidAsset
            ? try entryChargingRestrictedAsset(
                entry,
                plan: plan,
                amount: appliedMoney
            )
            : entry
        try rejectRestrictedAllowanceDebit(
            in: appliedEntry,
            authorizedAccountID: plan.fundingMode == .prepaidAsset
                ? plan.linkedAccountID : nil
        )
        let claimStatus: AllowanceClaimStatus?
        switch plan.fundingMode {
        case .reimbursement:
            claimStatus = reimbursementClaimStatus ?? .pendingApproval
        case .benefitLimit, .prepaidAsset:
            guard reimbursementClaimStatus == nil else {
                throw AppModelError.invalidAllowance
            }
            claimStatus = nil
        }
        let usage = try AllowanceUsage(
            id: usageID,
            amount: appliedMoney,
            occurredAt: entry.occurredAt,
            categoryID: eligible.count == 1 ? eligible[0].accountID : nil,
            linkedJournalEntryID: entry.id,
            note: entry.note,
            policyRevisionID: policy.id,
            claimStatus: claimStatus
        )
        return PreparedAllowanceApplication(
            entry: appliedEntry,
            plan: try plan.addingUsage(usage)
        )
    }

    func prepareAllowanceReplacement(
        original: JournalEntry,
        replacement: JournalEntry,
        confirmsRemovingAllowanceClaim: Bool = false
    ) async throws -> PreparedAllowanceReplacement {
        let linked = allowancePlans.flatMap { plan in
            plan.usages.compactMap { usage in
                usage.linkedJournalEntryID == original.id
                    ? (plan, usage) : nil
            }
        }
        guard linked.count <= 1 else { throw AppModelError.invalidBook }
        guard let (plan, oldUsage) = linked.first else {
            try rejectRestrictedAllowanceDebit(in: replacement)
            return PreparedAllowanceReplacement(entry: replacement, plans: [])
        }
        let preservedClaimStatus: AllowanceClaimStatus?
        switch plan.fundingMode {
        case .reimbursement:
            guard let claimStatus = oldUsage.claimStatus else {
                throw AppModelError.invalidBook
            }
            preservedClaimStatus = claimStatus
        case .benefitLimit, .prepaidAsset:
            guard oldUsage.claimStatus == nil else {
                throw AppModelError.invalidBook
            }
            preservedClaimStatus = nil
        }
        if plan.fundingMode == .prepaidAsset,
           plan.reconciliations.contains(where: {
               FinancialPeriodBoundary.contains(oldUsage.occurredAt, in: DateInterval(
                   start: $0.periodStart,
                   end: $0.periodEnd
               ))
           }) {
            throw AppModelError.invalidAllowance
        }
        guard !plan.hasGrandfatheredActivity else {
            throw AppModelError.invalidAllowance
        }
        let withoutOriginal = try plan.removingUsages(linkedTo: original.id)
        guard replacement.kind == .expense,
              hasEligibleAllowancePosting(in: replacement, plan: withoutOriginal)
        else {
            if plan.fundingMode == .reimbursement,
               !confirmsRemovingAllowanceClaim {
                throw AppModelError.allowanceClaimRemovalConfirmationRequired
            }
            try rejectRestrictedAllowanceDebit(in: replacement)
            return PreparedAllowanceReplacement(
                entry: replacement,
                plans: [withoutOriginal]
            )
        }
        let application = try await prepareAllowanceApplication(
            entry: replacement,
            plan: withoutOriginal,
            usageID: oldUsage.id,
            excludingPrepaidEntryID: plan.fundingMode == .prepaidAsset
                ? original.id : nil,
            reimbursementClaimStatus: preservedClaimStatus
        )
        if plan.fundingMode != .prepaidAsset {
            try rejectRestrictedAllowanceDebit(in: application.entry)
        }
        return PreparedAllowanceReplacement(
            entry: application.entry,
            plans: [application.plan]
        )
    }

    func requireAllowanceGovernedExpenseSource(
        _ accountID: UUID,
        allowancePlanID: UUID?
    ) throws {
        guard accountsByID[accountID]?.accountType == .restrictedAllowance else {
            return
        }
        guard let allowancePlanID,
              allowancePlans.contains(where: {
                  $0.id == allowancePlanID
                      && $0.fundingMode == .prepaidAsset
                      && $0.linkedAccountID == accountID
              }) else {
            throw AppModelError.invalidAllowance
        }
    }

    /// Records one user-confirmed provider expiry. `requirement.amount` is a
    /// policy-derived ceiling, never evidence that value was funded or
    /// removed. In particular, this method must not distribute the account's
    /// aggregate current balance across historical periods.
    func confirmExpiredPrepaidAllowance(
        planID: UUID,
        requirement: AllowanceExpiryRequirement,
        confirmedExpiredAmount: Decimal,
        asOf: Date
    ) async throws {
        try beginJournalMutation()
        defer { endJournalMutation() }
        guard let prepared = try await prepareConfirmedExpiry(
            planID: planID,
            requirement: requirement,
            confirmedExpiredAmount: confirmedExpiredAmount,
            asOf: asOf
        ) else { return }
        try await commitConfirmedExpiry(prepared)
    }

    private func commitConfirmedExpiry(
        _ prepared: PreparedAllowanceReconciliation
    ) async throws {
        let generation = storeGeneration
        if prepared.entry != nil { invalidateCommittedJournalProjection() }
        try await requireStore().write(prepared.writes)
        guard isCurrentStoreGeneration(generation) else { return }
        if prepared.entry != nil,
           !accounts.contains(where: { $0.id == prepared.equity.id }) {
            accounts.append(prepared.equity)
        }
        allowancePlans[prepared.planIndex] = prepared.plan
        if let entry = prepared.entry, retainsCompleteJournal {
            entries.append(entry)
            entries.sort {
                if $0.occurredAt == $1.occurredAt {
                    return $0.createdAt > $1.createdAt
                }
                return $0.occurredAt > $1.occurredAt
            }
        }
        if prepared.entry != nil {
            await refreshJournalAfterMutation()
        }
    }
}

extension AppModel {
    private func rejectUsageInReconciledPeriod(
        _ occurredAt: Date,
        plan: AllowancePlan
    ) throws {
        guard plan.fundingMode == .prepaidAsset,
              plan.reconciliations.contains(where: {
                  FinancialPeriodBoundary.contains(
                      occurredAt,
                      in: DateInterval(start: $0.periodStart, end: $0.periodEnd)
                  )
              }) else { return }
        throw AppModelError.invalidAllowance
    }

    private func prepareConfirmedExpiry(
        planID: UUID,
        requirement: AllowanceExpiryRequirement,
        confirmedExpiredAmount: Decimal,
        asOf: Date
    ) async throws -> PreparedAllowanceReconciliation? {
        guard let planIndex = allowancePlans.firstIndex(where: { $0.id == planID }) else {
            throw AppModelError.missingRecord
        }
        var plan = allowancePlans[planIndex]
        try validateAllowanceFunding(plan)
        guard plan.fundingMode == .prepaidAsset,
              let accountID = plan.linkedAccountID,
              let account = accountsByID[accountID] else {
            throw AppModelError.invalidAllowance
        }
        if let recorded = matchingReconciliation(in: plan, requirement: requirement) {
            guard recorded.expired.amount == confirmedExpiredAmount else {
                throw AppModelError.invalidAllowance
            }
            return nil
        }
        let pending = try plan.expiryRequirements(asOf: asOf)
        guard pending.first == requirement,
              confirmedExpiredAmount >= .zero,
              confirmedExpiredAmount <= requirement.amount.amount else {
            throw AppModelError.invalidAllowance
        }
        let balanceStore = try requireStore()
        let balance = try await restrictedAllowanceBalance(
            for: plan,
            asOf: requirement.interval.end,
            includingBoundary: false,
            in: balanceStore
        )
        guard confirmedExpiredAmount <= balance.amount else {
            throw AppModelError.invalidAllowance
        }
        let equity = openingBalancesAccount()
        let entry = try expiredAllowanceEntry(
            amount: confirmedExpiredAmount,
            requirement: requirement,
            account: account,
            equity: equity,
            plan: plan
        )
        if let entry {
            try await requireNonnegativeRestrictedBalances(
                afterRemoving: nil,
                adding: entry,
                in: balanceStore
            )
        }
        var writes = try expiryJournalWrites(entry: entry, equity: equity)
        let evidence = try AllowanceReconciliation(
            policyRevisionID: requirement.policyRevisionID,
            periodStart: requirement.interval.start,
            periodEnd: requirement.interval.end,
            expired: try Money(
                confirmedExpiredAmount,
                currency: plan.amount.currency
            ),
            recordedAt: asOf,
            linkedJournalEntryID: entry?.id
        )
        plan = try plan.recordingReconciliation(evidence)
        writes.append(try RecordWrite(
            plan,
            id: plan.id.uuidString,
            in: .allowancePlans
        ))
        return PreparedAllowanceReconciliation(
            planIndex: planIndex,
            plan: plan,
            entry: entry,
            equity: equity,
            writes: writes
        )
    }

    private func expiryJournalWrites(
        entry: JournalEntry?,
        equity: LedgerAccount
    ) throws -> [RecordWrite] {
        guard let entry else { return [] }
        var writes: [RecordWrite] = []
        if !accounts.contains(where: { $0.id == equity.id }) {
            writes.append(try RecordWrite(
                equity,
                id: equity.id.uuidString,
                in: .accounts
            ))
        }
        writes.append(try RecordWrite(
            entry,
            id: entry.id.uuidString,
            in: .journalEntries
        ))
        return writes
    }

    /// Restricted allowance value may enter through ordinary income or a
    /// transfer top-up. It may leave only after an allowance application has
    /// authorized the debit, or through the separate confirmed-expiry path.
    func rejectRestrictedAllowanceDebit(
        in entry: JournalEntry,
        authorizedAccountID: UUID? = nil
    ) throws {
        guard entry.postings.contains(where: { posting in
            posting.money.amount < .zero
                && accountsByID[posting.accountID]?.accountType
                    == .restrictedAllowance
                && posting.accountID != authorizedAccountID
        }) else { return }
        throw AppModelError.invalidAllowance
    }

    func requireGenericOutgoingSource(_ accountID: UUID) throws {
        guard accountsByID[accountID]?.accountType != .restrictedAllowance else {
            throw AppModelError.invalidAllowance
        }
    }

    func quarantineMalformedRestrictedAllowanceAccounts() {
        let malformedShapeIDs = Set(accounts.compactMap { account -> UUID? in
            guard account.accountType == .restrictedAllowance else { return nil }
            guard account.kind == .asset,
                  account.currency != nil,
                  account.systemRole == nil,
                  account.parentID == nil else { return account.id }
            return nil
        })
        quarantineRestrictedAllowanceAccounts(
            malformedShapeIDs,
            issue: "invalid-shape"
        )
    }

    /// Keeps malformed restricted histories out of the live book without
    /// deleting their encrypted account, journal, or allowance records.
    /// `excludingEntryIDs` must come from a ledger snapshot for the same current
    /// account set so a quarantined counter-account cannot provide phantom
    /// funding. Recovery repeats this after every account removal.
    func quarantineInvalidRestrictedAllowanceLedgers(
        in store: EncryptedRecordStore,
        excludingEntryIDs: Set<UUID>,
        observesCancellation: Bool
    ) async throws {
        let restrictedCurrencies = Dictionary(
            uniqueKeysWithValues: accounts.compactMap { account in
                guard account.accountType == .restrictedAllowance,
                      let currency = account.currency else { return nil }
                return (account.id, currency)
            }
        )
        guard !restrictedCurrencies.isEmpty else { return }

        let events = try await store.fetchJournalPostingEvents(
            accountIDs: Set(restrictedCurrencies.keys),
            excludingEntryIDs: excludingEntryIDs,
            observesCancellation: observesCancellation
        )
        quarantineRestrictedAllowanceAccounts(
            try RestrictedAllowanceLedgerInvariant.invalidAccountIDs(
                expectedCurrencies: restrictedCurrencies,
                events: events,
                observesCancellation: observesCancellation
            ),
            issue: "invalid-history"
        )
    }

    private func quarantineRestrictedAllowanceAccounts(
        _ accountIDs: Set<UUID>,
        issue: String
    ) {
        guard !accountIDs.isEmpty else { return }
        recoveryIssues.append(contentsOf: accountIDs.sorted {
            $0.uuidString < $1.uuidString
        }.map {
            "accounts/restricted-\(issue)-\($0)"
        })
        accounts.removeAll { accountIDs.contains($0.id) }
    }

    func requireNonnegativeRestrictedBalances(
        afterRemoving original: JournalEntry?,
        adding replacement: JournalEntry?,
        in store: EncryptedRecordStore
    ) async throws {
        let restrictedByID = Dictionary(
            uniqueKeysWithValues: accounts.compactMap { account in
                guard account.accountType == .restrictedAllowance,
                      let currency = account.currency else { return nil }
                return (account.id, currency)
            }
        )
        let touchedAccountIDs = Set(
            [original, replacement]
                .compactMap { $0 }
                .flatMap(\.postings)
                .compactMap { posting in
                    restrictedByID[posting.accountID] == nil
                        ? nil : posting.accountID
                }
        )
        guard !touchedAccountIDs.isEmpty else { return }
        let expectedRestrictedCurrencies = Dictionary(
            uniqueKeysWithValues: touchedAccountIDs.compactMap { accountID in
                restrictedByID[accountID].map { (accountID, $0) }
            }
        )
        guard expectedRestrictedCurrencies.count == touchedAccountIDs.count else {
            throw AppModelError.invalidAllowance
        }
        let validAccountIDs = Set(accounts.map(\.id))
        let expectedCurrencies = Dictionary(
            uniqueKeysWithValues: accounts.compactMap { account in
                account.currency.map { (account.id, $0) }
            }
        )
        let ledger = try await store.journalLedgerIndex(
            validAccountIDs: validAccountIDs,
            expectedAccountCurrencies: expectedCurrencies,
            excludingEntryIDs: invalidJournalEntryIDs
        )
        var excludedEntryIDs = invalidJournalEntryIDs.union(
            ledger.invalidRelationshipEntryIDs
        ).union(ledger.issues.compactMap {
            UUID(uuidString: $0.recordID)
        })
        if let original { excludedEntryIDs.insert(original.id) }
        var events = try await store.fetchJournalPostingEvents(
            accountIDs: touchedAccountIDs,
            excludingEntryIDs: excludedEntryIDs
        )
        if let replacement {
            events.append(contentsOf: RestrictedAllowanceLedgerInvariant.events(
                for: replacement,
                restrictedAccountIDs: touchedAccountIDs
            ))
        }
        do {
            try RestrictedAllowanceLedgerInvariant.requireValid(
                expectedCurrencies: expectedRestrictedCurrencies,
                events: events
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AppModelError.invalidAllowance
        }
    }

    private func hasEligibleAllowancePosting(
        in entry: JournalEntry,
        plan: AllowancePlan
    ) -> Bool {
        guard let policy = plan.policy(at: entry.occurredAt) else { return false }
        let postings = eligibleAllowancePostings(in: entry, policy: policy)
        return !postings.isEmpty
    }

    private func eligibleAllowancePostings(
        in entry: JournalEntry,
        policy: AllowancePolicyRevision
    ) -> [Posting] {
        entry.postings.filter { posting in
            guard accountsByID[posting.accountID]?.kind == .expense,
                  posting.money.amount > .zero,
                  posting.money.currency == policy.amount.currency else {
                return false
            }
            return policy.accepts(categoryID: posting.accountID)
        }
    }

    private func totalPositiveAmount(_ postings: [Posting]) throws -> Decimal {
        var result = Decimal.zero
        for posting in postings {
            result = try CheckedDecimal.adding(result, posting.money.amount)
        }
        return result
    }

    private func matchingReconciliation(
        in plan: AllowancePlan,
        requirement: AllowanceExpiryRequirement
    ) -> AllowanceReconciliation? {
        plan.reconciliations.first {
            $0.policyRevisionID == requirement.policyRevisionID
                && $0.periodStart == requirement.interval.start
                && $0.periodEnd == requirement.interval.end
        }
    }

    private func restrictedAllowanceBalance(
        for plan: AllowancePlan,
        asOf: Date,
        includingBoundary: Bool = true,
        excludingEntryID: UUID? = nil,
        in store: EncryptedRecordStore
    ) async throws -> Money {
        guard let accountID = plan.linkedAccountID,
              let account = accountsByID[accountID],
              account.kind == .asset,
              account.accountType == .restrictedAllowance,
              account.currency == plan.amount.currency else {
            throw AppModelError.invalidAllowance
        }
        return try await restrictedAllowanceBalance(
            for: account,
            asOf: asOf,
            includingBoundary: includingBoundary,
            excludingEntryID: excludingEntryID,
            in: store
        )
    }

    func restrictedAllowanceBalance(
        for account: LedgerAccount,
        asOf: Date,
        includingBoundary: Bool = true,
        excludingEntryID: UUID? = nil,
        in store: EncryptedRecordStore
    ) async throws -> Money {
        guard account.kind == .asset,
              account.accountType == .restrictedAllowance,
              let currency = account.currency,
              asOf.timeIntervalSinceReferenceDate.isFinite else {
            throw AppModelError.invalidAllowance
        }
        let accountID = account.id
        let validAccountIDs = Set(accounts.map(\.id))
        let expectedCurrencies = Dictionary(
            uniqueKeysWithValues: accounts.compactMap { item in
                item.currency.map { (item.id, $0) }
            }
        )
        let ledger = try await store.journalLedgerIndex(
            validAccountIDs: validAccountIDs,
            expectedAccountCurrencies: expectedCurrencies,
            excludingEntryIDs: invalidJournalEntryIDs
        )
        var excludedEntryIDs = invalidJournalEntryIDs.union(
            ledger.invalidRelationshipEntryIDs
        ).union(ledger.issues.compactMap {
            UUID(uuidString: $0.recordID)
        })
        if let excludingEntryID { excludedEntryIDs.insert(excludingEntryID) }
        let events = try await store.fetchJournalPostingEvents(
            accountIDs: [accountID],
            excludingEntryIDs: excludedEntryIDs
        )
        do {
            let amount = if includingBoundary {
                try RestrictedAllowanceLedgerInvariant.balance(
                    for: accountID,
                    currency: currency,
                    through: asOf,
                    events: events
                )
            } else {
                try RestrictedAllowanceLedgerInvariant.balance(
                    for: accountID,
                    currency: currency,
                    before: asOf,
                    events: events
                )
            }
            return try Money(
                amount,
                currency: currency
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AppModelError.invalidBook
        }
    }

    private func entryChargingRestrictedAsset(
        _ entry: JournalEntry,
        plan: AllowancePlan,
        amount: Money
    ) throws -> JournalEntry {
        guard let restrictedID = plan.linkedAccountID else {
            throw AppModelError.invalidAllowance
        }
        let sourcePostings = entry.postings.filter { posting in
            guard posting.money.currency == amount.currency,
                  posting.money.amount < .zero,
                  let account = accountsByID[posting.accountID] else { return false }
            return account.kind == .asset || account.kind == .liability
        }
        guard sourcePostings.count == 1, let source = sourcePostings.first else {
            throw AppModelError.invalidAllowance
        }
        if source.accountID == restrictedID {
            guard abs(source.money.amount) == amount.amount else {
                throw AppModelError.invalidAllowance
            }
            return entry
        }
        let remainder = try CheckedDecimal.subtracting(
            abs(source.money.amount),
            amount.amount
        )
        guard remainder >= .zero else { throw AppModelError.invalidAllowance }
        var postings = entry.postings.filter { $0.id != source.id }
        if remainder > .zero {
            postings.append(Posting(
                id: source.id,
                accountID: source.accountID,
                money: try Money(-remainder, currency: amount.currency),
                memo: source.memo
            ))
        }
        postings.append(Posting(
            accountID: restrictedID,
            money: amount.negated
        ))
        return try copying(entry, postings: postings)
    }

    private func copying(
        _ entry: JournalEntry,
        postings: [Posting]
    ) throws -> JournalEntry {
        try JournalEntry(
            id: entry.id,
            kind: entry.kind,
            occurredAt: entry.occurredAt,
            createdAt: entry.createdAt,
            payee: entry.payee,
            note: entry.note,
            postings: postings,
            supersedesID: entry.supersedesID,
            revisedAt: entry.revisedAt,
            sourceSystem: entry.sourceSystem,
            sourceFingerprint: entry.sourceFingerprint,
            originContext: entry.originContext
        )
    }

    private func expiredAllowanceEntry(
        amount: Decimal,
        requirement: AllowanceExpiryRequirement,
        account: LedgerAccount,
        equity: LedgerAccount,
        plan: AllowancePlan
    ) throws -> JournalEntry? {
        guard amount > .zero else { return nil }
        let candidate = try TransactionFactory.balanceAdjustment(
            displayBalanceDelta: try Money(-amount, currency: plan.amount.currency),
            accountID: account.id,
            equityAccountID: equity.id,
            accountIsLiability: false,
            occurredAt: requirement.interval.end,
            note: AppLocalization.string("allowance.expiry_adjustment_note"),
            originContext: AllowanceJournalIntegrity.expiryOriginContext(
                plan: plan,
                periodStart: requirement.interval.start,
                periodEnd: requirement.interval.end
            )
        )
        return try appAuthoredEntry(
            candidate,
            reportingTimeZoneIdentifier: plan.policy(
                at: requirement.interval.start
            )?.timeZoneIdentifier,
            sourceSystemOverride: Self.allowanceExpirySourceSystem,
            sourceFingerprintOverride: AllowanceJournalIntegrity.expiryFingerprint(
                planID: plan.id,
                policyRevisionID: requirement.policyRevisionID,
                periodEnd: requirement.interval.end
            )
        )
    }
}
