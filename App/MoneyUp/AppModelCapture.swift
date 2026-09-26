import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

private struct OnboardingBook {
    let profile: UserProfile
    let accounts: [LedgerAccount]
    let budgetTimeline: BudgetConfigurationTimeline
    let budgetNodes: [BudgetNode]
    let writes: [RecordWrite]
    let openingEntry: JournalEntry?
}

extension AppModel {
    func updateQuickLogDraft(_ draft: QuickLogDraft) {
        guard state == .ready else { return }
        // Save removes the draft in the same SQLCipher transaction as the
        // journal write. Refuse form callbacks while that transaction is
        // suspended so a later debounce cannot resurrect the committed draft.
        guard !isLifecycleMutationInProgress,
              !isWorking,
              !isJournalMutationInProgress,
              quickLogCommit == nil,
              goalMutationsInProgress == 0,
              !goalMutationBarrierClosed else { return }
        if let active = quickLogDraft?.batch {
            guard draft.batch?.id == active.id, draft.batch?.selectedID == active.selectedID,
                  draft.batch?.revision == active.revision else { return }
        } else if draft.batch != nil { return }
        // A promoted capture's draft is its only durable copy. A form that has
        // not adopted it yet (a launch racing the promotion) must not replace
        // it; the form re-syncs instead.
        if let pinned = quickLogDraft?.sourceCaptureID, draft.sourceCaptureID != pinned {
            quickLogPreparationRevision &+= 1
            return
        }
        let sanitized = sanitizedQuickLogDraft(draft)
        if sanitized != draft { quickLogPreparationRevision &+= 1 }
        guard quickLogDraft != sanitized else { return }
        quickLogDraft = sanitized
        scheduleQuickLogDraftWrite(sanitized)
    }

    /// Publishes a draft the model itself rewrote (lifecycle repair, capture
    /// promotion) and has a visible Log form adopt it, so the form's next
    /// edit cannot write its stale copy back.
    func publishModelQuickLogDraft(_ draft: QuickLogDraft?) {
        guard quickLogDraft != draft else { return }
        quickLogDraft = draft
        quickLogPreparationRevision &+= 1
    }

    /// Clears references that lifecycle work merged or deleted, and split
    /// categories of the wrong kind. Restore rejects a whole book over such a
    /// draft, so a stale form must never persist one into a backup.
    func sanitizedQuickLogDraft(_ draft: QuickLogDraft) -> QuickLogDraft {
        var draft = draft
        func known(_ id: UUID?) -> UUID? { id.flatMap { accountsByID[$0] == nil ? nil : $0 } }
        draft.accountID = known(draft.accountID)
        draft.destinationAccountID = known(draft.destinationAccountID)
        draft.categoryID = known(draft.categoryID)
        let splitKind: LedgerAccountKind? = switch draft.kind {
        case .expense, .refund: .expense
        case .income: .income
        case .transfer: nil
        }
        if splitKind == nil { draft.splitLines = [] }
        for index in draft.splitLines.indices
        where draft.splitLines[index].categoryID.flatMap({ accountsByID[$0]?.kind }) != splitKind {
            draft.splitLines[index].categoryID = nil
        }
        return draft
    }

    func completeOnboarding(
        baseCurrencyCode: String,
        accountName: String,
        accountType: FinancialAccountType,
        startingBalance: Decimal
    ) async throws {
        guard !isWorking else { return }
        isWorking = true
        invalidateInFlightJournalProjection()
        defer {
            isWorking = false
            resumeDeferredJournalDerivedRefreshIfPossible()
        }

        let generation = storeGeneration
        let store = try requireStore()
        let book = try makeOnboardingBook(
            baseCurrencyCode: baseCurrencyCode,
            accountName: accountName,
            accountType: accountType,
            startingBalance: startingBalance
        )

        invalidateCommittedJournalProjection()
        await lifecycleHooks.checkpoint(
            .afterJournalProjectionInvalidationBeforeCommit
        )
        try await store.write(book.writes)
        guard isCurrentStoreGeneration(generation) else { return }

        profile = book.profile
        accounts = book.accounts
        budgetConfigurationTimeline = book.budgetTimeline
        budgetNodes = book.budgetNodes
        if retainsCompleteJournal {
            entries = book.openingEntry.map { [$0] } ?? []
        }
        await refreshJournalAfterMutation()
        state = .ready
        UserDefaults.standard.set(
            false,
            forKey: PortableBackupReminder.storageKey
        )
        do {
            try await promoteLockedCaptureIfPossible(
                to: store,
                generation: generation
            )
        } catch let error as LockedCaptureStoreError {
            recordLockedCaptureStoreIssue(error)
        } catch {
            // Onboarding is already durable. Keep the new book usable and
            // expose a redacted recovery signal instead of stranding setup on
            // an inbox handoff failure.
            recordRecoveryIssue("locked_captures/promotion-unavailable")
        }
        // Model setters above run while state is still `.onboarding`, where
        // active-scene widget scheduling must fail closed. Mirror normal
        // startup only after the durable book is ready so the atomic snapshot
        // is republished and an opted-in profile can arm its day boundary.
        refreshIntelligence()
    }

    private func makeOnboardingBook(
        baseCurrencyCode: String,
        accountName: String,
        accountType: FinancialAccountType,
        startingBalance: Decimal
    ) throws -> OnboardingBook {
        let currency = try CurrencyCode(baseCurrencyCode)
        if (accountType.isLiabilityAccount || accountType == .restrictedAllowance),
           startingBalance < .zero {
            throw AppModelError.negativeAmount
        }
        try requireValidNewWriteAmount(startingBalance, currency: currency)
        let normalizedName = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw AppModelError.emptyName
        }

        let mainAccount = LedgerAccount(
            name: normalizedName,
            kind: accountType.isLiabilityAccount ? .liability : .asset,
            currency: currency,
            accountType: accountType
        )
        let defaults = Self.defaultBook(mainAccount: mainAccount)
        let newProfile = UserProfile(baseCurrency: currency)
        let onboardingCalendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: newProfile.reportingTimeZoneIdentifier
        )
        guard let onboardingMonth = onboardingCalendar.dateInterval(
            of: .month,
            for: currentDate()
        )?.start else { throw AppModelError.invalidBook }
        let onboardingTimeline = try BudgetConfigurationTimeline(
            currency: currency,
            revisions: [BudgetConfigurationRevision(
                effectiveMonth: onboardingMonth,
                nodes: defaults.budgetNodes
            )]
        )
        var writes = try defaults.accounts.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .accounts)
        }
        writes += try defaults.budgetNodes.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .budgetNodes)
        }
        writes.append(
            try RecordWrite(
                newProfile,
                id: UserProfile.primaryRecordID,
                in: .profile
            )
        )
        writes.append(try budgetConfigurationTimelineWrite(onboardingTimeline))

        let openingEntry = try makeOpeningBalanceEntry(
            startingBalance: startingBalance,
            currency: currency,
            mainAccount: mainAccount,
            accounts: defaults.accounts,
            profile: newProfile
        )
        if let openingEntry {
            writes.append(
                try RecordWrite(
                    openingEntry,
                    id: openingEntry.id.uuidString,
                    in: .journalEntries
                )
            )
        }

        return OnboardingBook(
            profile: newProfile,
            accounts: defaults.accounts,
            budgetTimeline: onboardingTimeline,
            budgetNodes: defaults.budgetNodes,
            writes: writes,
            openingEntry: openingEntry
        )
    }

    private func makeOpeningBalanceEntry(
        startingBalance: Decimal,
        currency: CurrencyCode,
        mainAccount: LedgerAccount,
        accounts: [LedgerAccount],
        profile: UserProfile
    ) throws -> JournalEntry? {
        guard startingBalance != .zero,
              let equity = accounts.first(where: {
                  $0.systemRole == .openingBalances
              }) else { return nil }
        let candidate = try TransactionFactory.balanceAdjustment(
            displayBalanceDelta: try Money(startingBalance, currency: currency),
            accountID: mainAccount.id,
            equityAccountID: equity.id,
            accountIsLiability: mainAccount.kind == .liability,
            occurredAt: currentDate(),
            note: AppLocalization.string("account.opening_balance_note")
        )
        return try appAuthoredEntry(
            candidate,
            reportingTimeZoneIdentifier: profile.reportingTimeZoneIdentifier
        )
    }
}
