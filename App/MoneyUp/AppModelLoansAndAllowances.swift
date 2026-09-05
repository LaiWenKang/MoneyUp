import Foundation
import MoneyUpCore
import MoneyUpPersistence

enum AllowanceFundingCompatibility: Equatable {
    case current
    case legacyPrepaidAsset
    case legacyReimbursementLink
    case invalid
}

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
              cashAccount.accountType != .restrictedAllowance,
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
              allowanceCategoriesExist(plan) else {
            throw AppModelError.invalidAllowance
        }
        try validateAllowanceFunding(plan)
        try validateUniquePrepaidFunding(plan)
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
              allowanceCategoriesExist(plan) else {
            throw AppModelError.invalidAllowance
        }
        let updated = try allowancePlans[index].applyingUpdate(
            plan,
            effectiveAt: currentDateForUserAction()
        )
        guard allowanceCategoriesExist(updated) else {
            throw AppModelError.invalidAllowance
        }
        try validateAllowanceFunding(updated)
        try validateUniquePrepaidFunding(updated)
        let generation = storeGeneration
        try await requireStore().upsert(
            updated,
            id: updated.id.uuidString,
            in: .allowancePlans
        )
        guard isCurrentStoreGeneration(generation) else { return }
        allowancePlans[index] = updated
        allowancePlans.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func recordAllowanceUsage(
        planID: UUID,
        expectedPolicyRevisionID: UUID,
        amount: Decimal,
        categoryID: UUID?,
        occurredAt: Date,
        note: String?
    ) async throws {
        try beginAllowanceUsageMutation()
        defer { endJournalMutation() }
        guard let index = allowancePlans.firstIndex(where: { $0.id == planID }),
              !allowancePlans[index].isArchived else {
            throw AppModelError.missingRecord
        }
        let plan = allowancePlans[index]
        let isAvailable = (try? plan.summary(asOf: occurredAt))?.isAvailableToday == true
        guard !plan.hasGrandfatheredActivity,
              plan.fundingMode == .benefitLimit,
              isAllowanceWritable(plan),
              let policy = plan.policy(at: occurredAt),
              policy.id == expectedPolicyRevisionID,
              isAvailable else {
            throw AppModelError.invalidAllowance
        }
        if let categoryID {
            guard let category = accountsByID[categoryID],
                  category.kind == .expense,
                  !category.isArchived,
                  policy.accepts(categoryID: categoryID) else {
                throw AppModelError.invalidAllowance
            }
        } else if !policy.eligibleCategoryIDs.isEmpty {
            throw AppModelError.invalidAllowance
        }
        try requireValidNewWriteAmount(amount, currency: plan.amount.currency)
        let usage = try AllowanceUsage(
            amount: try Money(amount, currency: plan.amount.currency),
            occurredAt: occurredAt,
            categoryID: categoryID,
            note: note,
            policyRevisionID: policy.id
        )
        let updated: AllowancePlan
        do {
            updated = try plan.addingUsage(usage)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AppModelError.invalidAllowance
        }
        let generation = storeGeneration
        try await requireStore().upsert(
            updated,
            id: updated.id.uuidString,
            in: .allowancePlans
        )
        guard isCurrentStoreGeneration(generation) else { return }
        allowancePlans[index] = updated
        refreshBudgetWidgetSnapshot()
    }

    /// Advances one reimbursement claim using an optimistic current-state
    /// precondition. The expected status prevents a stale row or repeated tap
    /// from applying a transition to newer evidence.
    func updateAllowanceClaimStatus(
        planID: UUID,
        usageID: UUID,
        expectedCurrentStatus: AllowanceClaimStatus,
        to newStatus: AllowanceClaimStatus
    ) async throws {
        try beginAllowanceUsageMutation()
        defer { endJournalMutation() }

        let matchingPlanIndices = allowancePlans.indices.filter {
            allowancePlans[$0].id == planID
        }
        guard matchingPlanIndices.count == 1,
              let index = matchingPlanIndices.first else {
            throw AppModelError.invalidAllowance
        }
        let plan = allowancePlans[index]
        let matchingUsages = plan.usages.filter { $0.id == usageID }
        guard !plan.isArchived,
              plan.fundingMode == .reimbursement,
              isAllowanceWritable(plan),
              matchingUsages.count == 1,
              matchingUsages[0].claimStatus == expectedCurrentStatus,
              newStatus != expectedCurrentStatus else {
            throw AppModelError.invalidAllowance
        }

        let updated: AllowancePlan
        do {
            updated = try plan.updatingClaimStatus(
                usageID: usageID,
                to: newStatus
            )
        } catch {
            throw AppModelError.invalidAllowance
        }
        guard updated.usages.first(where: { $0.id == usageID })?.claimStatus
                == newStatus else {
            throw AppModelError.invalidAllowance
        }

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
    /// transaction. A prepaid allowance becomes a real payment source: its
    /// linked restricted asset funds the eligible portion and the originally
    /// selected account funds any remainder.
    func save(
        _ entry: JournalEntry,
        applyingAllowance planID: UUID?,
        receiptData: Data? = nil,
        attachmentDrafts: [ReceiptAttachmentDraft] = []
    ) async throws -> UUID? {
        guard let planID else {
            return try await save(
                entry,
                receiptData: receiptData,
                attachmentDrafts: attachmentDrafts
            )
        }
        try beginJournalMutation()
        defer { endJournalMutation() }
        guard entry.kind == .expense,
              let initialIndex = allowancePlans.firstIndex(where: { $0.id == planID }),
              !allowancePlans[initialIndex].isArchived else {
            throw AppModelError.invalidAllowance
        }
        guard let index = allowancePlans.firstIndex(where: { $0.id == planID }) else {
            throw AppModelError.invalidAllowance
        }
        let plan = allowancePlans[index]
        try validateAllowanceFunding(plan)
        let application = try await prepareAllowanceApplication(
            entry: entry,
            plan: plan
        )
        let planWrite = try RecordWrite(
            application.plan,
            id: application.plan.id.uuidString,
            in: .allowancePlans
        )
        let savedID = try await save(
            application.entry,
            additionalWrites: [planWrite],
            receiptData: receiptData,
            attachmentDrafts: attachmentDrafts,
            authorizedRestrictedAllowanceAccountID:
                plan.fundingMode == .prepaidAsset ? plan.linkedAccountID : nil,
            journalMutationAlreadyBegun: true
        )
        if savedID == application.entry.id {
            await lifecycleHooks.checkpoint(
                .afterAllowanceJournalProjectionBeforePlanApply
            )
            if let currentIndex = allowancePlans.firstIndex(where: {
                $0.id == planID
            }) {
                allowancePlans[currentIndex] = application.plan
                refreshBudgetWidgetSnapshot()
            }
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

    func validateAllowanceFunding(_ plan: AllowancePlan) throws {
        guard Self.allowanceFundingCompatibility(
            for: plan,
            accountsByID: accountsByID
        ) == .current else {
            throw AppModelError.invalidAllowance
        }
    }

    func isAllowanceWritable(_ plan: AllowancePlan) -> Bool {
        !plan.hasGrandfatheredActivity
            && Self.allowanceFundingCompatibility(
                for: plan,
                accountsByID: accountsByID
            ) == .current
    }

    static func allowanceFundingCompatibility(
        for plan: AllowancePlan,
        accountsByID: [UUID: LedgerAccount]
    ) -> AllowanceFundingCompatibility {
        switch plan.fundingMode {
        case .benefitLimit:
            return plan.linkedAccountID == nil ? .current : .invalid
        case .prepaidAsset:
            guard let id = plan.linkedAccountID,
                  let account = accountsByID[id],
                  account.kind == .asset,
                  account.currency == plan.amount.currency else { return .invalid }
            return account.accountType == .restrictedAllowance && !account.isArchived
                ? .current : .legacyPrepaidAsset
        case .reimbursement:
            guard let id = plan.linkedAccountID else { return .current }
            guard let account = accountsByID[id],
                  account.kind == .asset,
                  account.currency == plan.amount.currency else { return .invalid }
            return .legacyReimbursementLink
        }
    }

    private func allowanceCategoriesExist(_ plan: AllowancePlan) -> Bool {
        let categoryIDs = plan.policyRevisions.reduce(
            plan.eligibleCategoryIDs.union(plan.usages.compactMap(\.categoryID))
        ) { $0.union($1.eligibleCategoryIDs) }
        return categoryIDs.allSatisfy { accountsByID[$0]?.kind == .expense }
    }

    private func validateUniquePrepaidFunding(_ plan: AllowancePlan) throws {
        guard !plan.isArchived,
              plan.fundingMode == .prepaidAsset,
              let accountID = plan.linkedAccountID else { return }
        guard !allowancePlans.contains(where: {
            $0.id != plan.id
                && !$0.isArchived
                && $0.fundingMode == .prepaidAsset
                && $0.linkedAccountID == accountID
        }) else { throw AppModelError.invalidAllowance }
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
