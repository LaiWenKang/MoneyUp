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
        guard quickLogDraft != draft else { return }
        quickLogDraft = draft
        scheduleQuickLogDraftWrite(draft)
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
    }

    private func makeOnboardingBook(
        baseCurrencyCode: String,
        accountName: String,
        accountType: FinancialAccountType,
        startingBalance: Decimal
    ) throws -> OnboardingBook {
        let currency = try CurrencyCode(baseCurrencyCode)
        if accountType.isLiabilityAccount, startingBalance < .zero {
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
            note: AppLocalization.string("account.opening_balance_note")
        )
        return try appAuthoredEntry(
            candidate,
            reportingTimeZoneIdentifier: profile.reportingTimeZoneIdentifier
        )
    }
}
