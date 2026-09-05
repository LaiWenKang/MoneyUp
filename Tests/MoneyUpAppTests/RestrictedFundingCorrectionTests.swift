@testable import MoneyUp
import Foundation
import MoneyUpCore
import MoneyUpPersistence
import XCTest

final class RestrictedFundingCorrectionTests: XCTestCase {
    func testCorrectionEditorPreservesExistingFundingNoteByDefault() throws {
        let currency = try CurrencyCode("SGD")
        let record = RestrictedAllowanceFundingRecord(
            entryID: UUID(),
            accountID: UUID(),
            amount: try Money(20, currency: currency),
            occurredAt: Date(timeIntervalSince1970: 1_780_000_000),
            note: "Employer top-up"
        )

        XCTAssertEqual(
            RestrictedFundingCorrectionEditorPolicy.initialNote(for: record),
            "Employer top-up"
        )
    }

    @MainActor
    func testOpeningFundingReductionRetainsEncryptedAuditRevision() async throws {
        let setup = try await makeSetup(opening: 100, topUp: 20)
        defer { setup.fixture.removeFiles() }
        let records = try await setup.model.restrictedAllowanceFundingRecords(
            accountID: setup.restricted.id
        )
        let opening = try XCTUnwrap(records.first {
            $0.entryID == setup.openingEntry.id
        })

        let replacementID = try await setup.model.correctRestrictedAllowanceFunding(
            expected: opening,
            correctedAmount: 90,
            note: "Corrected opening typo"
        )
        let unwrappedReplacementID = try XCTUnwrap(replacementID)
        let fetchedReplacement = try await setup.fixture.store.fetch(
            JournalEntry.self,
            id: unwrappedReplacementID.uuidString,
            from: .journalEntries
        )
        let replacement = try XCTUnwrap(fetchedReplacement)
        let original = try await setup.fixture.store.fetch(
            JournalEntry.self,
            id: setup.openingEntry.id.uuidString,
            from: .journalEntries
        )
        let revisionCount = try await setup.fixture.store.count(
            in: .journalEntryRevisions
        )

        XCTAssertNil(original)
        XCTAssertEqual(replacement.supersedesID, setup.openingEntry.id)
        XCTAssertEqual(
            replacement.postings.first {
                $0.accountID == setup.restricted.id
            }?.money.amount,
            90
        )
        XCTAssertEqual(revisionCount, 1)
        await setup.fixture.store.close()
    }

    @MainActor
    func testLaterTopUpCanBeReducedThenVoidedWithAuditTrail() async throws {
        let setup = try await makeSetup(opening: 100)
        defer { setup.fixture.removeFiles() }
        try await setup.model.setAccountBalance(
            accountID: setup.restricted.id,
            displayBalance: 120
        )
        let initialRecords = try await setup.model
            .restrictedAllowanceFundingRecords(accountID: setup.restricted.id)
        var topUp = try XCTUnwrap(initialRecords.first {
            $0.entryID != setup.openingEntry.id
        })
        XCTAssertEqual(topUp.amount.amount, 20)
        let originalTopUp = topUp

        let optionalReducedID = try await setup.model
            .correctRestrictedAllowanceFunding(
                expected: topUp,
                correctedAmount: 10,
                note: topUp.note
            )
        let reducedID = try XCTUnwrap(optionalReducedID)
        let reducedRecords = try await setup.model
            .restrictedAllowanceFundingRecords(accountID: setup.restricted.id)
        topUp = try XCTUnwrap(
            reducedRecords.first { $0.entryID == reducedID }
        )
        XCTAssertEqual(topUp.note, originalTopUp.note)
        let fetchedReduced = try await setup.fixture.store.fetch(
            JournalEntry.self,
            id: reducedID.uuidString,
            from: .journalEntries
        )
        let reducedEntry = try XCTUnwrap(fetchedReduced)
        do {
            try await setup.model.correctRestrictedAllowanceFunding(
                expected: originalTopUp,
                correctedAmount: 5,
                note: originalTopUp.note
            )
            XCTFail("A superseded funding row must fail its stale precondition")
        } catch {
            XCTAssertTrue(error is AppModelError)
        }
        let voidID = try await setup.model.correctRestrictedAllowanceFunding(
            expected: topUp,
            correctedAmount: .zero,
            note: "Void duplicate top-up"
        )
        let remaining = try await setup.model.restrictedAllowanceFundingRecords(
            accountID: setup.restricted.id
        )

        XCTAssertNil(voidID)
        XCTAssertEqual(remaining.map(\.entryID), [setup.openingEntry.id])
        try await assertValidVoidAudit(
            setup: setup,
            exactVoidedEntry: reducedEntry,
            reason: "Void duplicate top-up"
        )
        await setup.fixture.store.close()
    }

    @MainActor
    func testCorrectionRejectsWhenLaterAuthorizedSpendWouldOverdrawHistory()
        async throws {
        let setup = try await makeSetup(opening: 100, topUp: 50, laterSpend: 120)
        defer { setup.fixture.removeFiles() }
        let records = try await setup.model.restrictedAllowanceFundingRecords(
            accountID: setup.restricted.id
        )
        let topUp = try XCTUnwrap(records.first {
            $0.entryID == setup.topUpEntry?.id
        })
        let beforeEntries = setup.model.entries

        do {
            try await setup.model.correctRestrictedAllowanceFunding(
                expected: topUp,
                correctedAmount: 10,
                note: nil
            )
            XCTFail("Funding correction must replay all later restricted history")
        } catch {
            XCTAssertTrue(error is AppModelError)
        }
        let storedTopUp = try await setup.fixture.store.fetch(
            JournalEntry.self,
            id: try XCTUnwrap(setup.topUpEntry).id.uuidString,
            from: .journalEntries
        )
        let revisionCount = try await setup.fixture.store.count(
            in: .journalEntryRevisions
        )

        XCTAssertEqual(storedTopUp, setup.topUpEntry)
        XCTAssertEqual(revisionCount, 0)
        XCTAssertEqual(setup.model.entries, beforeEntries)
        XCTAssertEqual(
            setup.model.allowancePlans.first?.usages.first?.linkedJournalEntryID,
            setup.spendEntry?.id
        )
        await setup.fixture.store.close()
    }

    @MainActor
    func testCorrectionPersistenceFailureLeavesMemoryUnchanged() async throws {
        let setup = try await makeSetup(opening: 100)
        defer { setup.fixture.removeFiles() }
        let records = try await setup.model.restrictedAllowanceFundingRecords(
            accountID: setup.restricted.id
        )
        let record = try XCTUnwrap(records.first)
        let beforeEntries = setup.model.entries
        await setup.fixture.store.close()

        do {
            try await setup.model.correctRestrictedAllowanceFunding(
                expected: record,
                correctedAmount: 90,
                note: record.note
            )
            XCTFail("A failed encrypted write must not publish a correction")
        } catch {
            // Persistence errors are deliberately not a stable UI contract.
        }
        XCTAssertEqual(setup.model.entries, beforeEntries)
    }

    @MainActor
    func testCorrectionGenerationRaceDoesNotPublishToReplacementBook()
        async throws {
        let gate = RestrictedFundingMutationGate()
        let hooks = AppModelLifecycleHooks { checkpoint in
            guard checkpoint == .afterJournalProjectionInvalidationBeforeCommit
            else { return }
            await gate.suspend()
        }
        let setup = try await makeSetup(opening: 100, hooks: hooks)
        defer { setup.fixture.removeFiles() }
        let records = try await setup.model.restrictedAllowanceFundingRecords(
            accountID: setup.restricted.id
        )
        let record = try XCTUnwrap(records.first)
        let beforeEntries = setup.model.entries

        let mutation = Task { @MainActor in
            try await setup.model.correctRestrictedAllowanceFunding(
                expected: record,
                correctedAmount: 90,
                note: record.note
            )
        }
        await gate.waitUntilSuspended()
        setup.model.storeGeneration &+= 1
        await gate.release()
        do {
            _ = try await mutation.value
            XCTFail("A stale store generation must not publish")
        } catch {
            XCTAssertTrue(error is AppModelError)
        }
        XCTAssertEqual(setup.model.entries, beforeEntries)
        await setup.fixture.store.close()
    }
}

private extension RestrictedFundingCorrectionTests {
    struct Setup {
        let fixture: AppModelFixture
        let model: AppModel
        let restricted: LedgerAccount
        let openingEntry: JournalEntry
        let topUpEntry: JournalEntry?
        let spendEntry: JournalEntry?
    }

    @MainActor
    func assertValidVoidAudit(
        setup: Setup,
        exactVoidedEntry: JournalEntry,
        reason: String
    ) async throws {
        let revisions = try await setup.fixture.store.fetchAll(
            JournalEntry.self,
            from: .journalEntryRevisions
        )
        let marker = try XCTUnwrap(revisions.first {
            $0.sourceSystem == AppModel.restrictedFundingVoidSourceSystem
        })
        let liveEntries = try await setup.fixture.store.fetchAll(
            JournalEntry.self,
            from: .journalEntries
        )
        let snapshot = try await setup.fixture.store.snapshot()

        XCTAssertEqual(revisions.count, 3)
        XCTAssertEqual(
            revisions.filter { $0.id == exactVoidedEntry.id },
            [exactVoidedEntry]
        )
        XCTAssertEqual(Set(revisions.map(\.id)).count, revisions.count)
        XCTAssertEqual(marker.note, reason)
        XCTAssertEqual(marker.supersedesID, exactVoidedEntry.id)
        XCTAssertEqual(marker.sourceFingerprint, exactVoidedEntry.id.uuidString)
        XCTAssertNotEqual(marker.id, exactVoidedEntry.id)
        XCTAssertFalse(liveEntries.contains { $0.id == marker.id })
        XCTAssertNoThrow(
            try RestoreCandidateValidator.validateSnapshotWorkLimits(snapshot)
        )
        XCTAssertNoThrow(
            try RestoreCandidateValidator.validateSnapshotIdentities(snapshot)
        )
        _ = try await RestoreCandidateValidator.validateRelationships(
            profile: try XCTUnwrap(setup.model.profile),
            accounts: setup.model.accounts,
            budgetNodes: [],
            scheduledTransactions: [],
            investmentHoldings: [],
            netWorthSnapshots: [],
            quickLogDraft: nil,
            allowancePlans: setup.model.allowancePlans,
            in: setup.fixture.store
        )
    }

    @MainActor
    func makeSetup(
        opening: Decimal,
        topUp: Decimal? = nil,
        laterSpend: Decimal? = nil,
        hooks: AppModelLifecycleHooks = .none
    ) async throws -> Setup {
        let fixture = try AppModelFixture()
        let restricted = LedgerAccount(
            name: "Meal card",
            kind: .asset,
            currency: fixture.sgd,
            accountType: .restrictedAllowance
        )
        let equity = LedgerAccount(
            name: "Opening balances",
            kind: .equity,
            systemRole: .openingBalances
        )
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let openingEntry = try TransactionFactory.balanceAdjustment(
            displayBalanceDelta: Money(opening, currency: fixture.sgd),
            accountID: restricted.id,
            equityAccountID: equity.id,
            accountIsLiability: false,
            occurredAt: start,
            note: "Opening balance"
        )
        let topUpEntry = try topUp.map {
            try TransactionFactory.balanceAdjustment(
                displayBalanceDelta: Money($0, currency: fixture.sgd),
                accountID: restricted.id,
                equityAccountID: equity.id,
                accountIsLiability: false,
                occurredAt: start.addingTimeInterval(3_600),
                note: "Top-up"
            )
        }
        let basePlan = try AllowancePlan(
            name: "Meals",
            amount: Money(200, currency: fixture.sgd),
            cadence: .daily,
            fundingMode: .prepaidAsset,
            linkedAccountID: restricted.id,
            startsAt: start,
            timeZoneIdentifier: "UTC",
            eligibleCategoryIDs: [fixture.food.id]
        )
        let spendEntry = try laterSpend.map {
            try TransactionFactory.expense(
                amount: Money($0, currency: fixture.sgd),
                paidFrom: restricted.id,
                category: fixture.food.id,
                occurredAt: start.addingTimeInterval(7_200),
                payee: "Lunch"
            )
        }
        let plan: AllowancePlan
        if let spendEntry, let laterSpend {
            let usage = try AllowanceUsage(
                amount: Money(laterSpend, currency: fixture.sgd),
                occurredAt: spendEntry.occurredAt,
                categoryID: fixture.food.id,
                linkedJournalEntryID: spendEntry.id,
                policyRevisionID: basePlan.policyRevisions[0].id
            )
            plan = try basePlan.addingUsage(usage)
        } else {
            plan = basePlan
        }
        let entries = [openingEntry] + [topUpEntry, spendEntry].compactMap { $0 }
        let accounts = [restricted, equity, fixture.food, fixture.wallet]
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            reportingTimeZoneIdentifier: "UTC"
        )
        try await fixture.seed(
            profile: profile,
            accounts: accounts,
            entries: entries,
            allowancePlans: [plan]
        )
        let model = fixture.model(
            profile: profile,
            accounts: accounts,
            entries: entries,
            allowancePlans: [plan],
            lifecycleHooks: hooks,
            currentDate: { start.addingTimeInterval(10_800) }
        )
        return Setup(
            fixture: fixture,
            model: model,
            restricted: restricted,
            openingEntry: openingEntry,
            topUpEntry: topUpEntry,
            spendEntry: spendEntry
        )
    }
}

private actor RestrictedFundingMutationGate {
    private var suspended = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        suspended = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        guard !suspended else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
