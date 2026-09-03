import Foundation
import MoneyUpCore
import MoneyUpPersistence

extension AppModel {
    func addLoanPlan(
        accountID: UUID,
        name: String,
        originalPrincipal: Decimal,
        openedAt: Date,
        annualPercentageRate: Decimal?,
        termMonths: Int?,
        includeInTotalDebt: Bool,
        interestExpenseAccountID: UUID?,
        feeExpenseAccountID: UUID?,
        purpose: LoanPurpose = .other
    ) async throws -> UUID {
        try beginJournalMutation()
        defer { endJournalMutation() }
        guard !loanPlans.contains(where: { $0.accountID == accountID }),
              let account = accountsByID[accountID],
              account.kind == .liability,
              account.accountType == .loan,
              !account.isArchived,
              let currency = account.currency else {
            throw AppModelError.invalidLoan
        }
        try requireValidNewWriteAmount(originalPrincipal, currency: currency)
        try validateLoanExpenseCategory(interestExpenseAccountID)
        try validateLoanExpenseCategory(feeExpenseAccountID)
        let plan = try LoanPlan(
            accountID: accountID,
            name: name,
            purpose: purpose,
            originalPrincipal: try Money(originalPrincipal, currency: currency),
            openedAt: openedAt,
            annualPercentageRate: annualPercentageRate,
            termMonths: termMonths,
            includeInTotalDebt: includeInTotalDebt,
            interestExpenseAccountID: interestExpenseAccountID,
            feeExpenseAccountID: feeExpenseAccountID
        )
        let generation = storeGeneration
        try await requireStore().upsert(
            plan,
            id: plan.id.uuidString,
            in: .loanPlans
        )
        guard isCurrentStoreGeneration(generation) else { return plan.id }
        loanPlans.append(plan)
        loanPlans.sort { $0.openedAt > $1.openedAt }
        return plan.id
    }

    func updateLoanPlan(
        id: UUID,
        name: String,
        annualPercentageRate: Decimal?,
        termMonths: Int?,
        includeInTotalDebt: Bool,
        interestExpenseAccountID: UUID?,
        feeExpenseAccountID: UUID?,
        purpose: LoanPurpose? = nil
    ) async throws {
        try beginJournalMutation()
        defer { endJournalMutation() }
        guard let index = loanPlans.firstIndex(where: { $0.id == id }) else {
            throw AppModelError.missingRecord
        }
        try validateLoanExpenseCategory(interestExpenseAccountID)
        try validateLoanExpenseCategory(feeExpenseAccountID)
        let current = loanPlans[index]
        let updated = try LoanPlan(
            id: current.id,
            accountID: current.accountID,
            name: name,
            purpose: purpose ?? current.purpose,
            originalPrincipal: current.originalPrincipal,
            openedAt: current.openedAt,
            annualPercentageRate: annualPercentageRate,
            termMonths: termMonths,
            includeInTotalDebt: includeInTotalDebt,
            interestExpenseAccountID: interestExpenseAccountID,
            feeExpenseAccountID: feeExpenseAccountID,
            activities: current.activities,
            closedAt: current.closedAt
        )
        let generation = storeGeneration
        try await requireStore().upsert(
            updated,
            id: updated.id.uuidString,
            in: .loanPlans
        )
        guard isCurrentStoreGeneration(generation) else { return }
        loanPlans[index] = updated
    }

    func recordLoanPayment(
        loanID: UUID,
        paidFrom accountID: UUID,
        principal: Decimal,
        interest: Decimal,
        fees: Decimal,
        occurredAt: Date,
        note: String?
    ) async throws {
        try beginJournalMutation()
        defer { endJournalMutation() }
        guard let index = loanPlans.firstIndex(where: { $0.id == loanID }),
              loanPlans[index].closedAt == nil,
              let loanAccount = accountsByID[loanPlans[index].accountID],
              let currency = loanAccount.currency,
              let cashAccount = accountsByID[accountID],
              !cashAccount.isArchived,
              cashAccount.kind == .asset,
              cashAccount.currency == currency else {
            throw AppModelError.invalidLoan
        }
        for amount in [principal, interest, fees] {
            try requireValidNewWriteAmount(amount, currency: currency)
        }
        let plan = loanPlans[index]
        let principalMoney = try Money(principal, currency: currency)
        let interestMoney = try Money(interest, currency: currency)
        let feeMoney = try Money(fees, currency: currency)
        let currentPrincipal = try currentLoanPrincipal(plan)
        guard principal <= currentPrincipal.amount else {
            throw AppModelError.loanOverpayment
        }
        try validateLoanExpenseCategory(
            interestMoney.isZero ? nil : plan.interestExpenseAccountID
        )
        try validateLoanExpenseCategory(
            feeMoney.isZero ? nil : plan.feeExpenseAccountID
        )
        let entry = try appAuthoredEntry(
            TransactionFactory.loanPayment(
                principal: principalMoney,
                interest: interestMoney,
                fees: feeMoney,
                paidFrom: cashAccount.id,
                loanAccountID: loanAccount.id,
                interestCategoryID: plan.interestExpenseAccountID,
                feeCategoryID: plan.feeExpenseAccountID,
                occurredAt: occurredAt,
                note: note
            )
        )
        let activity = try LoanActivity(
            kind: .repayment,
            occurredAt: occurredAt,
            principal: principalMoney,
            interest: interestMoney,
            fees: feeMoney,
            journalEntryID: entry.id,
            note: note
        )
        let updated = try plan.adding(activity)
        try await commitLoanActivity(updated, entry: entry, at: index)
    }

    func recordLoanDrawdown(
        loanID: UUID,
        depositedInto accountID: UUID,
        principal: Decimal,
        occurredAt: Date,
        note: String?
    ) async throws {
        try beginJournalMutation()
        defer { endJournalMutation() }
        guard let index = loanPlans.firstIndex(where: { $0.id == loanID }),
              loanPlans[index].closedAt == nil,
              let loanAccount = accountsByID[loanPlans[index].accountID],
              let currency = loanAccount.currency,
              let cashAccount = accountsByID[accountID],
              !cashAccount.isArchived,
              cashAccount.kind == .asset,
              cashAccount.currency == currency else {
            throw AppModelError.invalidLoan
        }
        try requireValidNewWriteAmount(principal, currency: currency)
        let principalMoney = try Money(principal, currency: currency)
        let entry = try appAuthoredEntry(
            TransactionFactory.loanDrawdown(
                amount: principalMoney,
                loanAccountID: loanAccount.id,
                depositedInto: cashAccount.id,
                occurredAt: occurredAt,
                note: note
            )
        )
        let zero = Money.zero(currency: currency)
        let activity = try LoanActivity(
            kind: .drawdown,
            occurredAt: occurredAt,
            principal: principalMoney,
            interest: zero,
            fees: zero,
            journalEntryID: entry.id,
            note: note
        )
        let updated = try loanPlans[index].adding(activity)
        try await commitLoanActivity(updated, entry: entry, at: index)
    }

    func finishLoan(id: UUID, at date: Date) async throws {
        try beginJournalMutation()
        defer { endJournalMutation() }
        guard let index = loanPlans.firstIndex(where: { $0.id == id }) else {
            throw AppModelError.missingRecord
        }
        let plan = loanPlans[index]
        let currentPrincipal = try currentLoanPrincipal(plan)
        guard currentPrincipal.isZero else {
            throw AppModelError.loanNotPaidOff
        }
        var updated = plan
        updated.closedAt = date
        let generation = storeGeneration
        try await requireStore().upsert(
            updated,
            id: updated.id.uuidString,
            in: .loanPlans
        )
        guard isCurrentStoreGeneration(generation) else { return }
        loanPlans[index] = updated
    }

    func loanSummary(_ plan: LoanPlan) -> DerivedValue<LoanSummary> {
        do {
            return .available(try plan.summary(currentPrincipal: currentLoanPrincipal(plan)))
        } catch {
            return .unavailable(.amountCalculationFailed)
        }
    }

    func addAllowancePlan(_ plan: AllowancePlan) async throws {
        try beginJournalMutation()
        defer { endJournalMutation() }
        guard !allowancePlans.contains(where: { $0.id == plan.id }),
              plan.eligibleCategoryIDs.allSatisfy({ id in
                  accountsByID[id]?.kind == .expense
              }) else { throw AppModelError.invalidAllowance }
        try validateAllowanceFunding(plan)
        let generation = storeGeneration
        try await requireStore().upsert(
            plan,
            id: plan.id.uuidString,
            in: .allowancePlans
        )
        guard isCurrentStoreGeneration(generation) else { return }
        allowancePlans.append(plan)
        allowancePlans.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func updateAllowancePlan(_ plan: AllowancePlan) async throws {
        try beginJournalMutation()
        defer { endJournalMutation() }
        guard let index = allowancePlans.firstIndex(where: { $0.id == plan.id }),
              plan.eligibleCategoryIDs.allSatisfy({ id in
                  accountsByID[id]?.kind == .expense
              }) else { throw AppModelError.invalidAllowance }
        try validateAllowanceFunding(plan)
        let generation = storeGeneration
        try await requireStore().upsert(
            plan,
            id: plan.id.uuidString,
            in: .allowancePlans
        )
        guard isCurrentStoreGeneration(generation) else { return }
        allowancePlans[index] = plan
        allowancePlans.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func recordAllowanceUsage(
        planID: UUID,
        amount: Decimal,
        categoryID: UUID?,
        linkedJournalEntryID: UUID? = nil,
        occurredAt: Date,
        note: String?
    ) async throws {
        try beginJournalMutation()
        defer { endJournalMutation() }
        guard let index = allowancePlans.firstIndex(where: { $0.id == planID }),
              !allowancePlans[index].isArchived else {
            throw AppModelError.missingRecord
        }
        let plan = allowancePlans[index]
        if let categoryID {
            guard accountsByID[categoryID]?.kind == .expense,
                  plan.eligibleCategoryIDs.isEmpty
                    || plan.eligibleCategoryIDs.contains(categoryID) else {
                throw AppModelError.invalidAllowance
            }
        }
        try requireValidNewWriteAmount(amount, currency: plan.amount.currency)
        let usage = try AllowanceUsage(
            amount: try Money(amount, currency: plan.amount.currency),
            occurredAt: occurredAt,
            categoryID: categoryID,
            linkedJournalEntryID: linkedJournalEntryID,
            note: note
        )
        let updated = try plan.addingUsage(usage)
        let generation = storeGeneration
        try await requireStore().upsert(
            updated,
            id: updated.id.uuidString,
            in: .allowancePlans
        )
        guard isCurrentStoreGeneration(generation) else { return }
        allowancePlans[index] = updated
    }

    /// Persists a journal entry and its allowance evidence in one SQLCipher
    /// transaction. The allowance is capped to eligible spending and the
    /// current entitlement, so Quick Log can never create phantom value or
    /// over-consume a daily benefit.
    func save(
        _ entry: JournalEntry,
        applyingAllowance planID: UUID?,
        receiptData: Data? = nil
    ) async throws -> UUID? {
        guard let planID else {
            return try await save(entry, receiptData: receiptData)
        }
        guard entry.kind == .expense,
              let index = allowancePlans.firstIndex(where: { $0.id == planID }),
              !allowancePlans[index].isArchived else {
            throw AppModelError.invalidAllowance
        }
        let plan = allowancePlans[index]
        try validateAllowanceFunding(plan)
        let eligiblePostings = entry.postings.filter { posting in
            guard accountsByID[posting.accountID]?.kind == .expense,
                  posting.money.amount > .zero else { return false }
            return plan.eligibleCategoryIDs.isEmpty
                || plan.eligibleCategoryIDs.contains(posting.accountID)
        }
        guard !eligiblePostings.isEmpty else {
            throw AppModelError.invalidAllowance
        }
        var eligibleAmount = Decimal.zero
        for posting in eligiblePostings {
            guard posting.money.currency == plan.amount.currency else {
                throw AppModelError.invalidAllowance
            }
            eligibleAmount = try CheckedDecimal.adding(
                eligibleAmount,
                posting.money.amount
            )
        }
        let summary = try plan.summary(asOf: entry.occurredAt)
        let appliedAmount = min(eligibleAmount, max(summary.remaining.amount, .zero))
        guard appliedAmount > .zero else {
            throw AppModelError.invalidAllowance
        }
        let categoryID = eligiblePostings.count == 1
            ? eligiblePostings[0].accountID
            : nil
        let usage = try AllowanceUsage(
            amount: try Money(appliedAmount, currency: plan.amount.currency),
            occurredAt: entry.occurredAt,
            categoryID: categoryID,
            linkedJournalEntryID: entry.id,
            note: entry.note
        )
        let updated = try plan.addingUsage(usage)
        let planWrite = try RecordWrite(
            updated,
            id: updated.id.uuidString,
            in: .allowancePlans
        )
        let savedID = try await save(
            entry,
            additionalWrites: [planWrite],
            receiptData: receiptData
        )
        if savedID == entry.id,
           let currentIndex = allowancePlans.firstIndex(where: { $0.id == planID }) {
            allowancePlans[currentIndex] = updated
            refreshBudgetWidgetSnapshot()
        }
        return savedID
    }

    func allowanceSummary(_ plan: AllowancePlan, asOf: Date? = nil)
    -> DerivedValue<AllowanceSummary> {
        do {
            return .available(try plan.summary(asOf: asOf ?? currentDateForUserAction()))
        } catch {
            return .unavailable(.amountCalculationFailed)
        }
    }

    func budgetPace(
        for progress: BudgetProgress,
        asOf: Date? = nil
    ) -> DerivedValue<BudgetPace?> {
        budgetPace(
            for: progress,
            cadence: progress.node.pacingCadence,
            asOf: asOf
        )
    }

    func budgetPace(
        for progress: BudgetProgress,
        cadence: BudgetPacingCadence,
        asOf: Date? = nil
    ) -> DerivedValue<BudgetPace?> {
        guard progress.node.purpose == .flexible,
              let remaining = progress.remaining,
              remaining.amount > .zero else { return .available(nil) }
        do {
            return .available(
                try BudgetPaceCalculator.pace(
                    remaining: remaining,
                    cadence: cadence,
                    asOf: asOf ?? currentDateForUserAction(),
                    calendar: reportingCalendar
                )
            )
        } catch {
            return .unavailable(.amountCalculationFailed)
        }
    }

    private func currentLoanPrincipal(_ plan: LoanPlan) throws -> Money {
        guard let account = accountsByID[plan.accountID] else {
            throw AppModelError.missingRecord
        }
        switch displayBalanceResult(for: account) {
        case let .available(balance):
            return balance
        case .unavailable:
            throw AppModelError.invalidBook
        }
    }

    private func validateLoanExpenseCategory(_ id: UUID?) throws {
        guard let id else { return }
        guard let category = accountsByID[id],
              category.kind == .expense,
              !category.isArchived else {
            throw AppModelError.invalidCategoryKind
        }
    }

    private func validateAllowanceFunding(_ plan: AllowancePlan) throws {
        switch plan.fundingMode {
        case .benefitLimit:
            guard plan.linkedAccountID == nil else {
                throw AppModelError.invalidAllowance
            }
        case .prepaidAsset, .reimbursement:
            guard let accountID = plan.linkedAccountID,
                  let account = accountsByID[accountID],
                  account.kind == .asset,
                  !account.isArchived,
                  account.currency == plan.amount.currency else {
                throw AppModelError.invalidAllowance
            }
        }
    }

    private func commitLoanActivity(
        _ plan: LoanPlan,
        entry: JournalEntry,
        at index: Int
    ) async throws {
        let generation = storeGeneration
        let loanStore = try requireStore()
        invalidateCommittedJournalProjection()
        await lifecycleHooks.checkpoint(
            .afterJournalProjectionInvalidationBeforeCommit
        )
        try await loanStore.write([
            try RecordWrite(entry, id: entry.id.uuidString, in: .journalEntries),
            try RecordWrite(plan, id: plan.id.uuidString, in: .loanPlans)
        ])
        guard isCurrentStoreGeneration(generation) else { return }
        loanPlans[index] = plan
        if retainsCompleteJournal { entries.insert(entry, at: 0) }
        await refreshJournalAfterMutation()
    }
}
