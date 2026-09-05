@testable import MoneyUp
import Foundation
import MoneyUpCore
import MoneyUpPersistence
import XCTest

final class AllowanceClaimLifecycleTests: XCTestCase {
    @MainActor
    func testPendingClaimPersistsApprovedThenReimbursedWithoutJournalMutation()
        async throws {
        let setup = try await makePendingClaimSetup()
        defer { setup.fixture.removeFiles() }
        let initialJournalCount = try await setup.fixture.store.count(
            in: .journalEntries
        )
        let initialAccountCount = try await setup.fixture.store.count(
            in: .accounts
        )
        let initialEntry = try await setup.fixture.store.fetch(
            JournalEntry.self,
            id: setup.entryID.uuidString,
            from: .journalEntries
        )

        do {
            try await setup.model.updateAllowanceClaimStatus(
                planID: setup.planID,
                usageID: setup.usageID,
                expectedCurrentStatus: .pendingApproval,
                to: .reimbursed
            )
            XCTFail("Pending claims must not skip approval")
        } catch {
            XCTAssertTrue(error is AppModelError)
        }
        XCTAssertEqual(
            setup.model.allowancePlans.first?.usages.first?.claimStatus,
            .pendingApproval
        )

        try await setup.model.updateAllowanceClaimStatus(
            planID: setup.planID,
            usageID: setup.usageID,
            expectedCurrentStatus: .pendingApproval,
            to: .approved
        )
        XCTAssertEqual(
            setup.model.allowancePlans.first?.usages.first?.claimStatus,
            .approved
        )
        let persistedApproved = try await setup.fixture.store.fetch(
            AllowancePlan.self,
            id: setup.planID.uuidString,
            from: .allowancePlans
        )
        XCTAssertEqual(persistedApproved?.usages.first?.claimStatus, .approved)

        try await setup.model.updateAllowanceClaimStatus(
            planID: setup.planID,
            usageID: setup.usageID,
            expectedCurrentStatus: .approved,
            to: .reimbursed
        )
        XCTAssertEqual(
            setup.model.allowancePlans.first?.usages.first?.claimStatus,
            .reimbursed
        )
        let persistedReimbursed = try await setup.fixture.store.fetch(
            AllowancePlan.self,
            id: setup.planID.uuidString,
            from: .allowancePlans
        )
        XCTAssertEqual(
            persistedReimbursed?.usages.first?.claimStatus,
            .reimbursed
        )
        let finalJournalCount = try await setup.fixture.store.count(
            in: .journalEntries
        )
        let finalAccountCount = try await setup.fixture.store.count(
            in: .accounts
        )
        let finalEntry = try await setup.fixture.store.fetch(
            JournalEntry.self,
            id: setup.entryID.uuidString,
            from: .journalEntries
        )
        XCTAssertEqual(finalJournalCount, initialJournalCount)
        XCTAssertEqual(finalAccountCount, initialAccountCount)
        XCTAssertEqual(finalEntry, initialEntry)
        XCTAssertNil(persistedReimbursed?.linkedAccountID)
        await setup.fixture.store.close()
    }

    @MainActor
    func testRejectingClaimRestoresCapacityAndTerminalStateFailsClosed()
        async throws {
        let setup = try await makePendingClaimSetup()
        defer { setup.fixture.removeFiles() }
        let before = try XCTUnwrap(setup.model.allowancePlans.first)
        XCTAssertEqual(
            try before.summary(asOf: setup.asOf).remaining.amount,
            80
        )

        try await setup.model.updateAllowanceClaimStatus(
            planID: setup.planID,
            usageID: setup.usageID,
            expectedCurrentStatus: .pendingApproval,
            to: .rejected
        )
        let rejected = try XCTUnwrap(setup.model.allowancePlans.first)
        XCTAssertEqual(rejected.usages.first?.claimStatus, .rejected)
        XCTAssertEqual(
            try rejected.summary(asOf: setup.asOf).remaining.amount,
            100
        )

        do {
            try await setup.model.updateAllowanceClaimStatus(
                planID: setup.planID,
                usageID: setup.usageID,
                expectedCurrentStatus: .rejected,
                to: .approved
            )
            XCTFail("Rejected claims must remain terminal")
        } catch {
            XCTAssertTrue(error is AppModelError)
        }
        let persisted = try await setup.fixture.store.fetch(
            AllowancePlan.self,
            id: setup.planID.uuidString,
            from: .allowancePlans
        )
        XCTAssertEqual(persisted?.usages.first?.claimStatus, .rejected)
        XCTAssertEqual(
            try XCTUnwrap(persisted).summary(asOf: setup.asOf).remaining.amount,
            100
        )
        await setup.fixture.store.close()
    }

    @MainActor
    func testClaimMutationRejectsStaleMissingArchivedAndFailedPersistence()
        async throws {
        let setup = try await makePendingClaimSetup()
        defer { setup.fixture.removeFiles() }

        for (usageID, expectedStatus, targetStatus) in [
            (
                UUID(),
                AllowanceClaimStatus.pendingApproval,
                AllowanceClaimStatus.rejected
            ),
            (setup.usageID, .approved, .rejected),
            (setup.usageID, .pendingApproval, .pendingApproval)
        ] {
            do {
                try await setup.model.updateAllowanceClaimStatus(
                    planID: setup.planID,
                    usageID: usageID,
                    expectedCurrentStatus: expectedStatus,
                    to: targetStatus
                )
                XCTFail("Missing, stale, or no-op claim transitions must fail")
            } catch {
                XCTAssertTrue(error is AppModelError)
            }
        }

        let current = try XCTUnwrap(setup.model.allowancePlans.first)
        let archiveCandidate = try AllowancePlan(
            id: current.id,
            name: current.name,
            amount: current.amount,
            cadence: current.cadence,
            fundingMode: current.fundingMode,
            linkedAccountID: current.linkedAccountID,
            startsAt: current.startsAt,
            endsAt: current.endsAt,
            timeZoneIdentifier: current.timeZoneIdentifier,
            eligibleCategoryIDs: current.eligibleCategoryIDs,
            rolloverRule: current.rolloverRule,
            rolloverCap: current.rolloverCap,
            isArchived: true
        )
        try await setup.model.updateAllowancePlan(archiveCandidate)
        do {
            try await setup.model.updateAllowanceClaimStatus(
                planID: setup.planID,
                usageID: setup.usageID,
                expectedCurrentStatus: .pendingApproval,
                to: .approved
            )
            XCTFail("Archived claims must be read-only")
        } catch {
            XCTAssertTrue(error is AppModelError)
        }
        XCTAssertEqual(
            setup.model.allowancePlans.first?.usages.first?.claimStatus,
            .pendingApproval
        )
        await setup.fixture.store.close()

        let failedSetup = try await makePendingClaimSetup()
        defer { failedSetup.fixture.removeFiles() }
        await failedSetup.fixture.store.close()
        do {
            try await failedSetup.model.updateAllowanceClaimStatus(
                planID: failedSetup.planID,
                usageID: failedSetup.usageID,
                expectedCurrentStatus: .pendingApproval,
                to: .approved
            )
            XCTFail("A failed durable write must not publish in-memory state")
        } catch {
            // The exact persistence error is intentionally not a UI contract.
        }
        XCTAssertEqual(
            failedSetup.model.allowancePlans.first?.usages.first?.claimStatus,
            .pendingApproval
        )
    }

    func testClaimActionPolicyExposesOnlyForwardLocalizedActions() {
        XCTAssertEqual(
            AllowanceClaimActionPolicy.targets(from: .pendingApproval),
            [.approved, .rejected]
        )
        XCTAssertEqual(
            AllowanceClaimActionPolicy.targets(from: .approved),
            [.reimbursed]
        )
        XCTAssertTrue(
            AllowanceClaimActionPolicy.targets(from: .reimbursed).isEmpty
        )
        XCTAssertTrue(
            AllowanceClaimActionPolicy.targets(from: .rejected).isEmpty
        )

        for target in [
            AllowanceClaimStatus.approved,
            .rejected,
            .reimbursed
        ] {
            XCTAssertTrue(
                AllowanceClaimActionPolicy.titleKeyString(for: target)
                    .hasPrefix("allowance.claim.action.")
            )
            XCTAssertTrue(
                AllowanceClaimActionPolicy.hintKeyString(for: target)
                    .hasSuffix("_hint")
            )
            XCTAssertFalse(
                AllowanceClaimActionPolicy.systemImage(for: target).isEmpty
            )
        }
    }

    @MainActor
    func testClaimMutationRequiresUniqueWritableCurrentPlan() async throws {
        let setup = try await makePendingClaimSetup()
        defer { setup.fixture.removeFiles() }
        let current = try XCTUnwrap(setup.model.allowancePlans.first)
        let profile = UserProfile(baseCurrency: setup.fixture.sgd)
        let accounts = [setup.fixture.wallet, setup.fixture.food]
        let asOf = setup.asOf

        let duplicateModel = setup.fixture.model(
            profile: profile,
            accounts: accounts,
            allowancePlans: [current, current],
            currentDate: { asOf }
        )
        do {
            try await duplicateModel.updateAllowanceClaimStatus(
                planID: setup.planID,
                usageID: setup.usageID,
                expectedCurrentStatus: .pendingApproval,
                to: .approved
            )
            XCTFail("Ambiguous plan identity must fail closed")
        } catch AppModelError.invalidAllowance {
            // Expected.
        }

        var legacyLinkedPlan = current
        legacyLinkedPlan.linkedAccountID = setup.fixture.wallet.id
        let legacyModel = setup.fixture.model(
            profile: profile,
            accounts: accounts,
            allowancePlans: [legacyLinkedPlan],
            currentDate: { asOf }
        )
        XCTAssertFalse(legacyModel.isAllowanceWritable(legacyLinkedPlan))
        do {
            try await legacyModel.updateAllowanceClaimStatus(
                planID: setup.planID,
                usageID: setup.usageID,
                expectedCurrentStatus: .pendingApproval,
                to: .approved
            )
            XCTFail("Legacy reimbursement links must remain read-only")
        } catch AppModelError.invalidAllowance {
            // Expected.
        }

        let persisted = try await setup.fixture.store.fetch(
            AllowancePlan.self,
            id: setup.planID.uuidString,
            from: .allowancePlans
        )
        XCTAssertEqual(persisted?.usages.first?.claimStatus, .pendingApproval)
        await setup.fixture.store.close()
    }

    @MainActor
    func testEditingClaimExpensePreservesEveryAdvancedStatus() async throws {
        for status in [
            AllowanceClaimStatus.approved,
            .rejected,
            .reimbursed
        ] {
            let setup = try await makePendingClaimSetup()
            try await advanceClaim(in: setup, to: status)

            try await setup.model.replaceEntry(
                id: setup.entryID,
                kind: .expense,
                amount: 15,
                destinationAmount: nil,
                accountID: setup.fixture.wallet.id,
                destinationAccountID: nil,
                categoryID: setup.fixture.food.id,
                occurredAt: setup.occurredAt,
                payee: "Corrected client lunch",
                note: "Corrected"
            )

            let replacement = try XCTUnwrap(
                setup.model.entries.first { $0.supersedesID == setup.entryID }
            )
            let updatedPlan = try XCTUnwrap(setup.model.allowancePlans.first)
            let usage = try XCTUnwrap(updatedPlan.usages.first)
            XCTAssertEqual(usage.id, setup.usageID)
            XCTAssertEqual(usage.linkedJournalEntryID, replacement.id)
            XCTAssertEqual(usage.amount.amount, 15)
            XCTAssertEqual(usage.claimStatus, status)
            XCTAssertEqual(
                try updatedPlan.summary(asOf: setup.asOf).remaining.amount,
                status == .rejected ? 100 : 85
            )
            let persisted = try await setup.fixture.store.fetch(
                AllowancePlan.self,
                id: setup.planID.uuidString,
                from: .allowancePlans
            )
            XCTAssertEqual(persisted?.usages.first?.claimStatus, status)
            XCTAssertEqual(
                persisted?.usages.first?.linkedJournalEntryID,
                replacement.id
            )
            await setup.fixture.store.close()
            setup.fixture.removeFiles()
        }
    }

    @MainActor
    func testDeletingClaimExpenseRemovesEveryAdvancedStatus() async throws {
        for status in [
            AllowanceClaimStatus.approved,
            .rejected,
            .reimbursed
        ] {
            let setup = try await makePendingClaimSetup()
            try await advanceClaim(in: setup, to: status)

            try await setup.model.deleteEntry(id: setup.entryID)

            XCTAssertTrue(
                try XCTUnwrap(setup.model.allowancePlans.first).usages.isEmpty
            )
            let persistedPlan = try await setup.fixture.store.fetch(
                AllowancePlan.self,
                id: setup.planID.uuidString,
                from: .allowancePlans
            )
            XCTAssertTrue(try XCTUnwrap(persistedPlan).usages.isEmpty)
            let persistedEntry = try await setup.fixture.store.fetch(
                JournalEntry.self,
                id: setup.entryID.uuidString,
                from: .journalEntries
            )
            XCTAssertNil(persistedEntry)
            await setup.fixture.store.close()
            setup.fixture.removeFiles()
        }
    }

    @MainActor
    func testEditingAdvancedClaimOutOfEligibilityRequiresConfirmation()
        async throws {
        let setup = try await makePendingClaimSetup()
        defer { setup.fixture.removeFiles() }
        try await advanceClaim(in: setup, to: .approved)
        let ineligibleDate = setup.occurredAt.addingTimeInterval(-7_200)

        do {
            try await setup.model.replaceEntry(
                id: setup.entryID,
                kind: .expense,
                amount: 15,
                destinationAmount: nil,
                accountID: setup.fixture.wallet.id,
                destinationAccountID: nil,
                categoryID: setup.fixture.food.id,
                occurredAt: ineligibleDate,
                payee: "Earlier client lunch",
                note: nil
            )
            XCTFail("Advanced claim removal must require confirmation")
        } catch AppModelError.allowanceClaimRemovalConfirmationRequired {
            // The original transaction and claim remain authoritative.
        }
        XCTAssertNotNil(setup.model.entries.first { $0.id == setup.entryID })
        XCTAssertEqual(
            setup.model.allowancePlans.first?.usages.first?.claimStatus,
            .approved
        )

        try await setup.model.replaceEntry(
            id: setup.entryID,
            kind: .expense,
            amount: 15,
            destinationAmount: nil,
            accountID: setup.fixture.wallet.id,
            destinationAccountID: nil,
            categoryID: setup.fixture.food.id,
            occurredAt: ineligibleDate,
            payee: "Earlier client lunch",
            note: nil,
            confirmsRemovingAllowanceClaim: true
        )

        XCTAssertTrue(
            try XCTUnwrap(setup.model.allowancePlans.first).usages.isEmpty
        )
        XCTAssertNotNil(
            setup.model.entries.first { $0.supersedesID == setup.entryID }
        )
        await setup.fixture.store.close()
    }

    @MainActor
    private func advanceClaim(
        in setup: (
            fixture: AppModelFixture,
            model: AppModel,
            planID: UUID,
            usageID: UUID,
            entryID: UUID,
            occurredAt: Date,
            asOf: Date
        ),
        to target: AllowanceClaimStatus
    ) async throws {
        if target == .rejected {
            try await setup.model.updateAllowanceClaimStatus(
                planID: setup.planID,
                usageID: setup.usageID,
                expectedCurrentStatus: .pendingApproval,
                to: .rejected
            )
            return
        }
        try await setup.model.updateAllowanceClaimStatus(
            planID: setup.planID,
            usageID: setup.usageID,
            expectedCurrentStatus: .pendingApproval,
            to: .approved
        )
        if target == .reimbursed {
            try await setup.model.updateAllowanceClaimStatus(
                planID: setup.planID,
                usageID: setup.usageID,
                expectedCurrentStatus: .approved,
                to: .reimbursed
            )
        }
    }

    @MainActor
    private func makePendingClaimSetup() async throws -> (
        fixture: AppModelFixture,
        model: AppModel,
        planID: UUID,
        usageID: UUID,
        entryID: UUID,
        occurredAt: Date,
        asOf: Date
    ) {
        let fixture = try AppModelFixture()
        let occurredAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let asOf = occurredAt.addingTimeInterval(120)
        let plan = try AllowancePlan(
            name: "Travel claim",
            amount: Money(100, currency: fixture.sgd),
            cadence: .monthly,
            fundingMode: .reimbursement,
            startsAt: occurredAt.addingTimeInterval(-3_600),
            timeZoneIdentifier: "UTC",
            eligibleCategoryIDs: [fixture.food.id]
        )
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await fixture.seed(
            profile: profile,
            accounts: [fixture.wallet, fixture.food],
            allowancePlans: [plan]
        )
        let model = fixture.model(
            profile: profile,
            accounts: [fixture.wallet, fixture.food],
            allowancePlans: [plan],
            currentDate: { asOf }
        )
        let loggedEntryID = try await model.logExpense(
            amount: 20,
            accountID: fixture.wallet.id,
            categoryID: fixture.food.id,
            occurredAt: occurredAt,
            payee: "Client lunch",
            note: nil,
            allowancePlanID: plan.id
        )
        let entryID = try XCTUnwrap(loggedEntryID)
        let usageID = try XCTUnwrap(
            model.allowancePlans.first?.usages.first?.id
        )
        return (
            fixture,
            model,
            plan.id,
            usageID,
            entryID,
            occurredAt,
            asOf
        )
    }
}
