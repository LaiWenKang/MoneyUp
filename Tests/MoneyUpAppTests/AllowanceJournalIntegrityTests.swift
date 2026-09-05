import Foundation
@testable import MoneyUp
import MoneyUpCore
import MoneyUpPersistence
import XCTest

final class AllowanceJournalIntegrityTests: XCTestCase {
    func testSharedExpenseInvalidatesEveryClaimingPlanRegardlessOfOrder()
    throws {
        let fixture = try AllowanceIntegrityFixture()
        let entry = try fixture.expense(amount: 10)
        let first = try fixture.usagePlan(
            name: "First benefit",
            linkedEntryID: entry.id,
            usageAmount: 4
        )
        let second = try fixture.usagePlan(
            name: "Second benefit",
            linkedEntryID: entry.id,
            usageAmount: 4
        )
        let expected: Set<UUID> = [first.id, second.id]

        for plans in [[first, second], [second, first]] {
            XCTAssertEqual(
                try fixture.invalidPlanIDs(plans, entries: [entry]),
                expected
            )
        }
    }

    func testLinkedUsageRejectsWrongJournalFacts() throws {
        let fixture = try AllowanceIntegrityFixture()
        let wrongKind = try fixture.entry(
            kind: .transfer,
            occurredAt: fixture.spendAt,
            categoryID: fixture.food.id,
            amount: 10,
            currency: fixture.sgd,
            paidFrom: fixture.wallet.id
        )
        let wrongDate = try fixture.expense(
            amount: 10,
            occurredAt: fixture.spendAt.addingTimeInterval(1)
        )
        let wrongCategory = try fixture.expense(
            amount: 10,
            categoryID: fixture.transport.id
        )
        let insufficientAmount = try fixture.expense(amount: 3)
        let wrongCurrency = try fixture.entry(
            kind: .expense,
            occurredAt: fixture.spendAt,
            categoryID: fixture.food.id,
            amount: 10,
            currency: fixture.usd,
            paidFrom: fixture.usWallet.id
        )

        for entry in [
            wrongKind, wrongDate, wrongCategory, insufficientAmount, wrongCurrency
        ] {
            let plan = try fixture.usagePlan(
                linkedEntryID: entry.id,
                usageAmount: 4
            )
            XCTAssertEqual(
                try fixture.invalidPlanIDs([plan], entries: [entry]),
                [plan.id]
            )
        }
    }

    func testLinkedUsageRequiresEnoughEvidenceForItsExactCategory() throws {
        let fixture = try AllowanceIntegrityFixture()
        let entry = try JournalEntry(
            kind: .expense,
            occurredAt: fixture.spendAt,
            postings: [
                Posting(
                    accountID: fixture.food.id,
                    money: Money(2, currency: fixture.sgd)
                ),
                Posting(
                    accountID: fixture.transport.id,
                    money: Money(8, currency: fixture.sgd)
                ),
                Posting(
                    accountID: fixture.wallet.id,
                    money: Money(-10, currency: fixture.sgd)
                )
            ]
        )
        let plan = try fixture.usagePlan(
            linkedEntryID: entry.id,
            usageAmount: 4
        )

        XCTAssertEqual(
            try fixture.invalidPlanIDs([plan], entries: [entry]),
            [plan.id]
        )
    }

    func testPartialBenefitAndReimbursementEvidenceIsValid() throws {
        let fixture = try AllowanceIntegrityFixture()

        for mode in [
            AllowanceFundingMode.benefitLimit,
            AllowanceFundingMode.reimbursement
        ] {
            let entry = try fixture.expense(amount: 10)
            let plan = try fixture.usagePlan(
                fundingMode: mode,
                linkedEntryID: entry.id,
                usageAmount: 4
            )

            XCTAssertTrue(
                try fixture.invalidPlanIDs([plan], entries: [entry]).isEmpty
            )
        }
    }

    func testPrepaidUsageRequiresOneExactRestrictedDebit() throws {
        let fixture = try AllowanceIntegrityFixture()
        let valid = try fixture.prepaidExpense(
            eligibleAmount: 10,
            restrictedDebit: 4
        )
        let missing = try fixture.expense(amount: 10)
        let wrong = try fixture.prepaidExpense(
            eligibleAmount: 10,
            restrictedDebit: 3
        )

        let validPlan = try fixture.usagePlan(
            fundingMode: .prepaidAsset,
            linkedEntryID: valid.id,
            usageAmount: 4
        )
        XCTAssertTrue(
            try fixture.invalidPlanIDs([validPlan], entries: [valid]).isEmpty
        )
        for entry in [missing, wrong] {
            let plan = try fixture.usagePlan(
                fundingMode: .prepaidAsset,
                linkedEntryID: entry.id,
                usageAmount: 4
            )
            XCTAssertEqual(
                try fixture.invalidPlanIDs([plan], entries: [entry]),
                [plan.id]
            )
        }
    }

    func testUsageAndReconciliationCannotReuseOneEntry() throws {
        let fixture = try AllowanceIntegrityFixture()
        let entry = try fixture.prepaidExpense(
            eligibleAmount: 10,
            restrictedDebit: 4
        )
        var plan = try fixture.usagePlan(
            fundingMode: .prepaidAsset,
            linkedEntryID: entry.id,
            usageAmount: 4
        )
        plan = try fixture.recordingReconciliation(
            on: plan,
            entryID: entry.id,
            expiredAmount: 5
        )

        XCTAssertEqual(
            try fixture.invalidPlanIDs([plan], entries: [entry]),
            [plan.id]
        )
    }

    func testGrandfatheringCannotBypassJournalSemanticsOrOwnership() throws {
        let fixture = try AllowanceIntegrityFixture()
        let entry = try fixture.entry(
            kind: .transfer,
            occurredAt: fixture.spendAt,
            categoryID: fixture.food.id,
            amount: 10,
            currency: fixture.sgd,
            paidFrom: fixture.wallet.id
        )
        let first = try fixture.grandfatheredPlan(linkedEntryID: entry.id)
        let second = try fixture.grandfatheredPlan(linkedEntryID: entry.id)

        XCTAssertEqual(
            try fixture.invalidPlanIDs([first, second], entries: [entry]),
            [first.id, second.id]
        )
    }

    func testExpiryReconciliationRequiresExactMetadataAndPostings() throws {
        let fixture = try AllowanceIntegrityFixture()
        let funding = try fixture.restrictedFunding(amount: 5)
        let valid = try fixture.expiryEvidence(forgery: nil)
        XCTAssertTrue(
            try fixture.invalidPlanIDs(
                [valid.plan],
                entries: [funding, valid.entry]
            ).isEmpty
        )

        for forgery in ExpiryForgery.allCases {
            let evidence = try fixture.expiryEvidence(forgery: forgery)
            XCTAssertEqual(
                try fixture.invalidPlanIDs(
                    [evidence.plan],
                    entries: [funding, evidence.entry]
                ),
                [evidence.plan.id],
                "Expected \(forgery) expiry evidence to be rejected"
            )
        }
    }

    func testExpiryCannotUseFundingAtItsExactPeriodBoundary() throws {
        let fixture = try AllowanceIntegrityFixture()
        let evidence = try fixture.expiryEvidence(forgery: nil)
        let boundaryFunding = try fixture.restrictedFunding(
            amount: 5,
            occurredAt: fixture.periodEnd
        )

        let result = try AllowanceJournalIntegrity.validationResult(
            plans: [evidence.plan],
            accountsByID: fixture.accountsByID,
            entriesByID: Dictionary(uniqueKeysWithValues:
                [boundaryFunding, evidence.entry].map { ($0.id, $0) }
            )
        )

        XCTAssertEqual(result.invalidPlanIDs, [evidence.plan.id])
        XCTAssertTrue(result.invalidPrepaidEvidenceEntryIDs.contains(
            evidence.entry.id
        ))
        XCTAssertTrue(result.unauthorizedRestrictedDebitEntryIDs.contains(
            evidence.entry.id
        ))
    }

    func testSameBoundaryExpiryClaimsUseOneAggregateFundingCeiling() throws {
        let fixture = try AllowanceIntegrityFixture()
        let first = try fixture.expiryEvidence(forgery: nil)
        let second = try fixture.expiryEvidence(forgery: nil)
        let funding = try fixture.restrictedFunding(amount: 5)
        let entries = [funding, first.entry, second.entry]

        let result = try AllowanceJournalIntegrity.validationResult(
            plans: [first.plan, second.plan],
            accountsByID: fixture.accountsByID,
            entriesByID: Dictionary(uniqueKeysWithValues: entries.map {
                ($0.id, $0)
            })
        )

        XCTAssertEqual(result.invalidPlanIDs, [first.plan.id, second.plan.id])
        XCTAssertEqual(
            result.invalidPrepaidEvidenceEntryIDs,
            [first.entry.id, second.entry.id]
        )
    }

    func testFractionalBoundaryHasStrictAndIndexedRecoveryParity() throws {
        let fixture = try AllowanceIntegrityFixture()
        let boundary = Date(
            timeIntervalSinceReferenceDate:
                fixture.periodEnd.timeIntervalSinceReferenceDate + 0.123_456_7
        )
        let entryID = UUID()
        var plan = try AllowancePlan(
            name: "Partial prepaid period",
            amount: Money(5, currency: fixture.sgd),
            cadence: .daily,
            fundingMode: .prepaidAsset,
            linkedAccountID: fixture.restricted.id,
            startsAt: fixture.day,
            endsAt: boundary,
            timeZoneIdentifier: "UTC"
        )
        let policyID = try XCTUnwrap(plan.policy(at: fixture.day)?.id)
        plan = try plan.recordingReconciliation(AllowanceReconciliation(
            policyRevisionID: policyID,
            periodStart: fixture.day,
            periodEnd: boundary,
            expired: Money(5, currency: fixture.sgd),
            recordedAt: boundary,
            linkedJournalEntryID: entryID
        ))
        let expiry = try JournalEntry(
            id: entryID,
            kind: .adjustment,
            occurredAt: boundary,
            postings: [
                Posting(
                    accountID: fixture.restricted.id,
                    money: Money(-5, currency: fixture.sgd)
                ),
                Posting(
                    accountID: fixture.equity.id,
                    money: Money(5, currency: fixture.sgd)
                )
            ],
            sourceSystem: AllowanceJournalIntegrity.expirySourceSystem,
            sourceFingerprint: AllowanceJournalIntegrity.expiryFingerprint(
                planID: plan.id,
                policyRevisionID: policyID,
                periodEnd: boundary
            ),
            originContext: AllowanceJournalIntegrity.expiryOriginContext(
                plan: plan,
                periodStart: fixture.day,
                periodEnd: boundary
            )
        )
        let funding = try fixture.restrictedFunding(amount: 5)
        let entries = [funding, expiry]
        let entriesByID = Dictionary(uniqueKeysWithValues: entries.map {
            ($0.id, $0)
        })
        let indexedEvents = entries.flatMap { entry in
            entry.postings.compactMap { posting -> LedgerPostingEvent? in
                guard posting.accountID == fixture.restricted.id else {
                    return nil
                }
                return LedgerPostingEvent(
                    entryID: entry.id,
                    occurredAt: Date(
                        timeIntervalSince1970:
                            entry.occurredAt.timeIntervalSince1970
                    ),
                    originDayKey: 0,
                    posting: posting
                )
            }
        }

        let strict = try AllowanceJournalIntegrity.validationResult(
            plans: [plan],
            accountsByID: fixture.accountsByID,
            entriesByID: entriesByID
        )
        let recovered = try AllowanceJournalIntegrity.validationResult(
            plans: [plan],
            accountsByID: fixture.accountsByID,
            entriesByID: entriesByID,
            liveRestrictedDebitEntryIDs: [expiry.id],
            restrictedLedgerEvents: indexedEvents
        )

        XCTAssertEqual(recovered, strict)
        XCTAssertTrue(strict.invalidPlanIDs.isEmpty)
        XCTAssertTrue(strict.unauthorizedRestrictedDebitEntryIDs.isEmpty)
    }

    func testReconciliationCannotExceedPolicyExpiryCeiling() throws {
        let fixture = try AllowanceIntegrityFixture()
        let plan = try AllowancePlan(
            name: "Prepaid benefit",
            amount: Money(10, currency: fixture.sgd),
            cadence: .daily,
            fundingMode: .prepaidAsset,
            linkedAccountID: fixture.restricted.id,
            startsAt: fixture.day,
            timeZoneIdentifier: "UTC"
        )
        let policyID = try XCTUnwrap(plan.policy(at: fixture.day)?.id)
        let ceiling = try AllowanceReconciliation(
            policyRevisionID: policyID,
            periodStart: fixture.day,
            periodEnd: fixture.periodEnd,
            expired: Money(10, currency: fixture.sgd),
            recordedAt: fixture.periodEnd,
            linkedJournalEntryID: UUID()
        )
        XCTAssertNoThrow(try plan.recordingReconciliation(ceiling))

        let excessive = try AllowanceReconciliation(
            policyRevisionID: policyID,
            periodStart: fixture.day,
            periodEnd: fixture.periodEnd,
            expired: Money(10.01, currency: fixture.sgd),
            recordedAt: fixture.periodEnd,
            linkedJournalEntryID: UUID()
        )
        XCTAssertThrowsError(try plan.recordingReconciliation(excessive))
    }

    func testDecodedReconciliationCannotExceedPolicyExpiryCeiling() throws {
        let fixture = try AllowanceIntegrityFixture()
        let evidence = try fixture.expiryEvidence(forgery: nil)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(evidence.plan)
            ) as? [String: Any]
        )
        var reconciliations = try XCTUnwrap(
            object["reconciliations"] as? [[String: Any]]
        )
        var expired = try XCTUnwrap(
            reconciliations[0]["expired"] as? [String: Any]
        )
        expired["amount"] = 21
        reconciliations[0]["expired"] = expired
        object["reconciliations"] = reconciliations
        let payload = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try JSONDecoder().decode(AllowancePlan.self, from: payload)
        )
    }

    func testExpenseEvidenceAggregationFailureInvalidatesPlan() throws {
        let fixture = try AllowanceIntegrityFixture()
        let reserve = LedgerAccount(
            name: "Reserve",
            kind: .asset,
            currency: fixture.sgd
        )
        let huge = Decimal(sign: .plus, exponent: 127, significand: 9)
        let entry = try JournalEntry(
            kind: .expense,
            occurredAt: fixture.spendAt,
            postings: [
                Posting(
                    accountID: fixture.food.id,
                    money: Money(huge, currency: fixture.sgd)
                ),
                Posting(
                    accountID: fixture.wallet.id,
                    money: Money(-huge, currency: fixture.sgd)
                ),
                Posting(
                    accountID: fixture.transport.id,
                    money: Money(huge, currency: fixture.sgd)
                ),
                Posting(
                    accountID: reserve.id,
                    money: Money(-huge, currency: fixture.sgd)
                )
            ]
        )
        var plan = try AllowancePlan(
            name: "Benefit",
            amount: Money(20, currency: fixture.sgd),
            cadence: .daily,
            startsAt: fixture.day,
            timeZoneIdentifier: "UTC",
            eligibleCategoryIDs: [fixture.food.id, fixture.transport.id]
        )
        plan = try plan.addingUsage(AllowanceUsage(
            amount: Money(4, currency: fixture.sgd),
            occurredAt: fixture.spendAt,
            linkedJournalEntryID: entry.id,
            policyRevisionID: plan.policy(at: fixture.spendAt)?.id
        ))
        let accounts = fixture.accounts + [reserve]

        let result = try AllowanceJournalIntegrity.validationResult(
            plans: [plan],
            accountsByID: Dictionary(
                uniqueKeysWithValues: accounts.map { ($0.id, $0) }
            ),
            entriesByID: [entry.id: entry],
            observesCancellation: false
        )

        XCTAssertEqual(result.invalidPlanIDs, [plan.id])
        XCTAssertTrue(result.unauthorizedRestrictedDebitEntryIDs.isEmpty)
    }

    func testExpirySourceLabelAloneHasNoJournalAuthority() throws {
        let fixture = try AllowanceIntegrityFixture()
        let entry = try JournalEntry(
            kind: .adjustment,
            occurredAt: fixture.spendAt,
            postings: [
                Posting(
                    accountID: fixture.wallet.id,
                    money: Money(1, currency: fixture.sgd)
                ),
                Posting(
                    accountID: fixture.equity.id,
                    money: Money(-1, currency: fixture.sgd)
                )
            ],
            sourceSystem: AllowanceJournalIntegrity.expirySourceSystem
        )

        let result = try AllowanceJournalIntegrity.validationResult(
            plans: [],
            accountsByID: fixture.accountsByID,
            entriesByID: [entry.id: entry]
        )

        XCTAssertTrue(result.invalidPlanIDs.isEmpty)
        XCTAssertTrue(result.unauthorizedRestrictedDebitEntryIDs.isEmpty)
        XCTAssertTrue(result.invalidPrepaidEvidenceEntryIDs.isEmpty)
    }

    @MainActor
    func testRecoveryQuarantinesInvalidPrepaidPlanAndCashEvidencePreservingRows()
    async throws {
        let storeFixture = try AppModelFixture()
        defer { storeFixture.removeFiles() }
        let fixture = try AllowanceIntegrityFixture()
        let funding = try TransactionFactory.balanceAdjustment(
            displayBalanceDelta: Money(20, currency: fixture.sgd),
            accountID: fixture.restricted.id,
            equityAccountID: fixture.equity.id,
            accountIsLiability: false,
            occurredAt: fixture.day
        )
        let invalidEvidence = try fixture.expense(amount: 10)
        let plan = try fixture.usagePlan(
            fundingMode: .prepaidAsset,
            linkedEntryID: invalidEvidence.id,
            usageAmount: 4
        )
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await storeFixture.seed(
            profile: profile,
            accounts: fixture.accounts,
            entries: [funding, invalidEvidence],
            allowancePlans: [plan]
        )
        let model = storeFixture.model(
            profile: profile,
            accounts: fixture.accounts
        )

        try await model.reloadPersistedBookForTesting()

        XCTAssertFalse(model.allowancePlans.contains { $0.id == plan.id })
        XCTAssertTrue(model.accounts.contains { $0.id == fixture.restricted.id })
        XCTAssertTrue(model.invalidJournalEntryIDs.contains(invalidEvidence.id))
        XCTAssertFalse(model.entries.contains { $0.id == invalidEvidence.id })
        XCTAssertTrue(model.entries.contains { $0.id == funding.id })
        XCTAssertTrue(model.recoveryIssues.contains {
            $0 == "allowance_plans/journal-\(plan.id)"
        })
        XCTAssertTrue(model.recoveryIssues.contains {
            $0 == "journal_entries/restricted-invalid-evidence-\(invalidEvidence.id)"
        })
        let rawPlan = try await storeFixture.store.fetch(
            AllowancePlan.self,
            id: plan.id.uuidString,
            from: .allowancePlans
        )
        let rawDebit = try await storeFixture.store.fetch(
            JournalEntry.self,
            id: invalidEvidence.id.uuidString,
            from: .journalEntries
        )
        XCTAssertNotNil(rawPlan)
        XCTAssertNotNil(rawDebit)
        await storeFixture.store.close()
    }

    @MainActor
    func testRecoveryRejectsExpiryAuthorizedByAmbiguousOpeningAccountRole()
    async throws {
        let storeFixture = try AppModelFixture()
        defer { storeFixture.removeFiles() }
        let fixture = try AllowanceIntegrityFixture()
        let evidence = try fixture.expiryEvidence(forgery: nil)
        let duplicateOpening = LedgerAccount(
            name: "Forged opening balances",
            kind: .equity,
            systemRole: .openingBalances
        )
        let funding = try TransactionFactory.balanceAdjustment(
            displayBalanceDelta: Money(10, currency: fixture.sgd),
            accountID: fixture.restricted.id,
            equityAccountID: fixture.equity.id,
            accountIsLiability: false,
            occurredAt: fixture.day
        )
        let accounts = fixture.accounts + [duplicateOpening]
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await storeFixture.seed(
            profile: profile,
            accounts: accounts,
            entries: [funding, evidence.entry],
            allowancePlans: [evidence.plan]
        )
        let model = storeFixture.model(profile: profile, accounts: accounts)

        try await model.reloadPersistedBookForTesting()

        XCTAssertFalse(model.allowancePlans.contains {
            $0.id == evidence.plan.id
        })
        XCTAssertTrue(model.accounts.contains { $0.id == fixture.restricted.id })
        XCTAssertTrue(model.invalidJournalEntryIDs.contains(evidence.entry.id))
        XCTAssertFalse(model.entries.contains { $0.id == evidence.entry.id })
        let rawPlan = try await storeFixture.store.fetch(
            AllowancePlan.self,
            id: evidence.plan.id.uuidString,
            from: .allowancePlans
        )
        let rawEntry = try await storeFixture.store.fetch(
            JournalEntry.self,
            id: evidence.entry.id.uuidString,
            from: .journalEntries
        )
        XCTAssertNotNil(rawPlan)
        XCTAssertNotNil(rawEntry)
        await storeFixture.store.close()
    }

    @MainActor
    func testRecoveryQuarantinesExpiryFundedOnlyAtBoundaryPreservingRows()
    async throws {
        let storeFixture = try AppModelFixture()
        defer { storeFixture.removeFiles() }
        let fixture = try AllowanceIntegrityFixture()
        let evidence = try fixture.expiryEvidence(forgery: nil)
        let boundaryFunding = try fixture.restrictedFunding(
            amount: 5,
            occurredAt: fixture.periodEnd
        )
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await storeFixture.seed(
            profile: profile,
            accounts: fixture.accounts,
            entries: [boundaryFunding, evidence.entry],
            allowancePlans: [evidence.plan]
        )
        let now = fixture.periodEnd
        let model = storeFixture.model(
            profile: profile,
            accounts: fixture.accounts,
            currentDate: { now }
        )

        try await model.reloadPersistedBookForTesting()

        XCTAssertFalse(model.allowancePlans.contains {
            $0.id == evidence.plan.id
        })
        XCTAssertTrue(model.accounts.contains { $0.id == fixture.restricted.id })
        XCTAssertTrue(model.entries.contains { $0.id == boundaryFunding.id })
        XCTAssertFalse(model.entries.contains { $0.id == evidence.entry.id })
        XCTAssertTrue(model.invalidJournalEntryIDs.contains(evidence.entry.id))
        let rawPlan = try await storeFixture.store.fetch(
            AllowancePlan.self,
            id: evidence.plan.id.uuidString,
            from: .allowancePlans
        )
        let rawExpiry = try await storeFixture.store.fetch(
            JournalEntry.self,
            id: evidence.entry.id.uuidString,
            from: .journalEntries
        )
        XCTAssertNotNil(rawPlan)
        XCTAssertNotNil(rawExpiry)
        await storeFixture.store.close()
    }

    @MainActor
    func testRecoveryQuarantinesDecodedOverCeilingExpiryPreservingRawRows()
    async throws {
        let storeFixture = try AppModelFixture()
        defer { storeFixture.removeFiles() }
        let fixture = try AllowanceIntegrityFixture()
        let evidence = try fixture.expiryEvidence(forgery: nil)
        let rawPlanPayload = try fixture.planPayload(
            evidence.plan,
            replacingExpiredAmount: 21
        )
        let rawExpiry = try JournalEntry(
            id: evidence.entry.id,
            kind: evidence.entry.kind,
            occurredAt: evidence.entry.occurredAt,
            postings: [
                Posting(
                    accountID: fixture.restricted.id,
                    money: Money(-21, currency: fixture.sgd)
                ),
                Posting(
                    accountID: fixture.equity.id,
                    money: Money(21, currency: fixture.sgd)
                )
            ],
            sourceSystem: evidence.entry.sourceSystem,
            sourceFingerprint: evidence.entry.sourceFingerprint,
            originContext: evidence.entry.originContext
        )
        let funding = try fixture.restrictedFunding(amount: 25)
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await storeFixture.seed(
            profile: profile,
            accounts: fixture.accounts,
            entries: [funding, rawExpiry],
            allowancePlans: [evidence.plan]
        )
        let snapshot = try await storeFixture.store.snapshot()
        let records = snapshot.records.map { record in
            guard record.collection == RecordCollection.allowancePlans.rawValue,
                  record.recordID == evidence.plan.id.uuidString else {
                return record
            }
            return StoredRecordSnapshot(
                collection: record.collection,
                recordID: record.recordID,
                payload: rawPlanPayload,
                updatedAt: record.updatedAt
            )
        }
        try await storeFixture.store.restore(DatabaseSnapshot(
            schemaVersion: snapshot.schemaVersion,
            createdAt: snapshot.createdAt,
            records: records
        ))
        let model = storeFixture.model(
            profile: profile,
            accounts: fixture.accounts
        )

        try await model.reloadPersistedBookForTesting()

        XCTAssertFalse(model.allowancePlans.contains {
            $0.id == evidence.plan.id
        })
        XCTAssertTrue(model.invalidJournalEntryIDs.contains(rawExpiry.id))
        XCTAssertFalse(model.entries.contains { $0.id == rawExpiry.id })
        let preserved = try await storeFixture.store.snapshot()
        XCTAssertTrue(preserved.records.contains {
            $0.collection == RecordCollection.allowancePlans.rawValue
                && $0.recordID == evidence.plan.id.uuidString
                && $0.payload == rawPlanPayload
        })
        XCTAssertTrue(preserved.records.contains {
            $0.collection == RecordCollection.journalEntries.rawValue
                && $0.recordID == rawExpiry.id.uuidString
        })
        await storeFixture.store.close()
    }

    @MainActor
    func testStrictRestoreRejectsExpiryFundedOnlyAtBoundary() async throws {
        let storeFixture = try AppModelFixture()
        defer { storeFixture.removeFiles() }
        let fixture = try AllowanceIntegrityFixture()
        let evidence = try fixture.expiryEvidence(forgery: nil)
        let boundaryFunding = try fixture.restrictedFunding(
            amount: 5,
            occurredAt: fixture.periodEnd
        )
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await storeFixture.seed(
            profile: profile,
            accounts: fixture.accounts,
            entries: [boundaryFunding, evidence.entry],
            allowancePlans: [evidence.plan]
        )

        do {
            try await RestoreCandidateValidator.validateRelationships(
                profile: profile,
                accounts: fixture.accounts,
                budgetNodes: [],
                scheduledTransactions: [],
                investmentHoldings: [],
                netWorthSnapshots: [],
                quickLogDraft: nil,
                allowancePlans: [evidence.plan],
                in: storeFixture.store
            )
            XCTFail("Expected boundary-funded expiry to fail strict restore")
        } catch {
            XCTAssertTrue(error is AppModelError)
        }
        await storeFixture.store.close()
    }

    @MainActor
    func testRecoveryQuarantinesEveryUnlinkedNegativeRestrictedEntry()
    async throws {
        let storeFixture = try AppModelFixture()
        defer { storeFixture.removeFiles() }
        let fixture = try AllowanceIntegrityFixture()
        let funding = try TransactionFactory.balanceAdjustment(
            displayBalanceDelta: Money(100, currency: fixture.sgd),
            accountID: fixture.restricted.id,
            equityAccountID: fixture.equity.id,
            accountIsLiability: false,
            occurredAt: fixture.spendAt.addingTimeInterval(3_600)
        )
        let expense = try fixture.prepaidExpense(
            eligibleAmount: 5,
            restrictedDebit: 5
        )
        let transfer = try JournalEntry(
            kind: .transfer,
            occurredAt: fixture.spendAt.addingTimeInterval(1),
            postings: [
                Posting(
                    accountID: fixture.wallet.id,
                    money: Money(6, currency: fixture.sgd)
                ),
                Posting(
                    accountID: fixture.restricted.id,
                    money: Money(-6, currency: fixture.sgd)
                )
            ]
        )
        let adjustment = try JournalEntry(
            kind: .adjustment,
            occurredAt: fixture.spendAt.addingTimeInterval(2),
            postings: [
                Posting(
                    accountID: fixture.equity.id,
                    money: Money(7, currency: fixture.sgd)
                ),
                Posting(
                    accountID: fixture.restricted.id,
                    money: Money(-7, currency: fixture.sgd)
                )
            ]
        )
        let unauthorized = [expense, transfer, adjustment]
        let unauthorizedIDs = Set(unauthorized.map(\.id))
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await storeFixture.seed(
            profile: profile,
            accounts: fixture.accounts,
            entries: [funding] + unauthorized
        )
        let model = storeFixture.model(
            profile: profile,
            accounts: fixture.accounts
        )

        try await model.reloadPersistedBookForTesting()

        XCTAssertTrue(model.accounts.contains { $0.id == fixture.restricted.id })
        XCTAssertEqual(
            model.invalidJournalEntryIDs.intersection(unauthorizedIDs),
            unauthorizedIDs
        )
        XCTAssertTrue(model.entries.allSatisfy {
            !unauthorizedIDs.contains($0.id)
        })
        XCTAssertTrue(model.entries.contains { $0.id == funding.id })
        for entry in unauthorized {
            let raw = try await storeFixture.store.fetch(
                JournalEntry.self,
                id: entry.id.uuidString,
                from: .journalEntries
            )
            XCTAssertNotNil(raw)
        }
        await storeFixture.store.close()
    }

    @MainActor
    func testValidPrepaidSpendAfterRecoveryIgnoresQuarantinedDebit()
    async throws {
        let storeFixture = try AppModelFixture()
        defer { storeFixture.removeFiles() }
        let fixture = try AllowanceIntegrityFixture()
        let unauthorized = try TransactionFactory.balanceAdjustment(
            displayBalanceDelta: Money(-19, currency: fixture.sgd),
            accountID: fixture.restricted.id,
            equityAccountID: fixture.equity.id,
            accountIsLiability: false,
            occurredAt: fixture.spendAt
        )
        let fundingAt = fixture.spendAt.addingTimeInterval(3_600)
        let funding = try TransactionFactory.balanceAdjustment(
            displayBalanceDelta: Money(20, currency: fixture.sgd),
            accountID: fixture.restricted.id,
            equityAccountID: fixture.equity.id,
            accountIsLiability: false,
            occurredAt: fundingAt
        )
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await storeFixture.seed(
            profile: profile,
            accounts: fixture.accounts,
            entries: [unauthorized, funding]
        )
        let model = storeFixture.model(
            profile: profile,
            accounts: fixture.accounts
        )
        try await model.reloadPersistedBookForTesting()
        XCTAssertTrue(model.invalidJournalEntryIDs.contains(unauthorized.id))
        XCTAssertTrue(model.accounts.contains { $0.id == fixture.restricted.id })

        let plan = try AllowancePlan(
            name: "Recovered meal card",
            amount: Money(20, currency: fixture.sgd),
            cadence: .daily,
            fundingMode: .prepaidAsset,
            linkedAccountID: fixture.restricted.id,
            startsAt: fixture.day,
            timeZoneIdentifier: "UTC",
            eligibleCategoryIDs: [fixture.food.id]
        )
        try await model.addAllowancePlan(plan)
        let purchase = try fixture.expense(
            amount: 10,
            occurredAt: fundingAt.addingTimeInterval(3_600)
        )

        let savedID = try await model.save(purchase, applyingAllowance: plan.id)

        XCTAssertEqual(savedID, purchase.id)
        XCTAssertTrue(model.invalidJournalEntryIDs.contains(unauthorized.id))
        XCTAssertFalse(model.invalidJournalEntryIDs.contains(purchase.id))
        let saved = try XCTUnwrap(model.entries.first { $0.id == purchase.id })
        XCTAssertEqual(
            saved.postings.first {
                $0.accountID == fixture.restricted.id
            }?.money.amount,
            -10
        )
        XCTAssertEqual(
            model.allowancePlans.first { $0.id == plan.id }?
                .usages.first?.amount.amount,
            10
        )
        await storeFixture.store.close()
    }

    @MainActor
    func testPrepaidSpendableUsesLedgerAtRequestedHistoricalInstant()
    async throws {
        let storeFixture = try AppModelFixture()
        defer { storeFixture.removeFiles() }
        let fixture = try AllowanceIntegrityFixture()
        let funding = try fixture.restrictedFunding(amount: 20)
        let laterAt = fixture.periodEnd.addingTimeInterval(3_600)
        let laterExpense = try JournalEntry(
            kind: .expense,
            occurredAt: laterAt,
            postings: [
                Posting(
                    accountID: fixture.food.id,
                    money: Money(15, currency: fixture.sgd)
                ),
                Posting(
                    accountID: fixture.restricted.id,
                    money: Money(-15, currency: fixture.sgd)
                )
            ]
        )
        var plan = try AllowancePlan(
            name: "Historical meal card",
            amount: Money(20, currency: fixture.sgd),
            cadence: .daily,
            fundingMode: .prepaidAsset,
            linkedAccountID: fixture.restricted.id,
            startsAt: fixture.day,
            timeZoneIdentifier: "UTC",
            eligibleCategoryIDs: [fixture.food.id]
        )
        plan = try plan.addingUsage(AllowanceUsage(
            amount: Money(15, currency: fixture.sgd),
            occurredAt: laterAt,
            categoryID: fixture.food.id,
            linkedJournalEntryID: laterExpense.id,
            policyRevisionID: plan.policy(at: laterAt)?.id
        ))
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await storeFixture.seed(
            profile: profile,
            accounts: fixture.accounts,
            entries: [funding, laterExpense],
            allowancePlans: [plan]
        )
        let model = storeFixture.model(
            profile: profile,
            accounts: fixture.accounts,
            entries: [funding, laterExpense],
            allowancePlans: [plan]
        )

        let spendable = try await model.prepaidAllowanceSpendable(
            planID: plan.id,
            asOf: fixture.spendAt
        )

        XCTAssertEqual(spendable, Money(20, currency: fixture.sgd))
        await storeFixture.store.close()
    }

    @MainActor
    func testPrepaidSpendableDoesNotBackfillFromFutureFunding() async throws {
        let storeFixture = try AppModelFixture()
        defer { storeFixture.removeFiles() }
        let fixture = try AllowanceIntegrityFixture()
        let funding = try fixture.restrictedFunding(
            amount: 20,
            occurredAt: fixture.periodEnd
        )
        let plan = try AllowancePlan(
            name: "Future-funded meal card",
            amount: Money(20, currency: fixture.sgd),
            cadence: .daily,
            fundingMode: .prepaidAsset,
            linkedAccountID: fixture.restricted.id,
            startsAt: fixture.day,
            timeZoneIdentifier: "UTC"
        )
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await storeFixture.seed(
            profile: profile,
            accounts: fixture.accounts,
            entries: [funding],
            allowancePlans: [plan]
        )
        let model = storeFixture.model(
            profile: profile,
            accounts: fixture.accounts,
            entries: [funding],
            allowancePlans: [plan]
        )

        let spendable = try await model.prepaidAllowanceSpendable(
            planID: plan.id,
            asOf: fixture.spendAt
        )

        XCTAssertEqual(spendable, .zero(currency: fixture.sgd))
        await storeFixture.store.close()
    }

    @MainActor
    func testRecoveryContainsAllowanceEvidenceAggregationFailure() async throws {
        let storeFixture = try AppModelFixture()
        defer { storeFixture.removeFiles() }
        let fixture = try AllowanceIntegrityFixture()
        let reserve = LedgerAccount(
            name: "Reserve",
            kind: .asset,
            currency: fixture.sgd
        )
        let huge = Decimal(sign: .plus, exponent: 127, significand: 9)
        let entry = try JournalEntry(
            kind: .expense,
            occurredAt: fixture.spendAt,
            postings: [
                Posting(accountID: fixture.food.id,
                        money: Money(huge, currency: fixture.sgd)),
                Posting(accountID: fixture.wallet.id,
                        money: Money(-huge, currency: fixture.sgd)),
                Posting(accountID: fixture.transport.id,
                        money: Money(huge, currency: fixture.sgd)),
                Posting(accountID: reserve.id,
                        money: Money(-huge, currency: fixture.sgd))
            ]
        )
        var plan = try AllowancePlan(
            name: "Benefit",
            amount: Money(20, currency: fixture.sgd),
            cadence: .daily,
            startsAt: fixture.day,
            timeZoneIdentifier: "UTC",
            eligibleCategoryIDs: [fixture.food.id, fixture.transport.id]
        )
        plan = try plan.addingUsage(AllowanceUsage(
            amount: Money(4, currency: fixture.sgd),
            occurredAt: fixture.spendAt,
            linkedJournalEntryID: entry.id,
            policyRevisionID: plan.policy(at: fixture.spendAt)?.id
        ))
        let accounts = fixture.accounts + [reserve]
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await storeFixture.seed(
            profile: profile,
            accounts: accounts,
            entries: [entry],
            allowancePlans: [plan]
        )
        let now = fixture.day.addingTimeInterval(86_400 * 800)
        let model = storeFixture.model(
            profile: profile,
            accounts: accounts,
            currentDate: { now }
        )

        try await model.reloadPersistedBookForTesting()

        XCTAssertFalse(model.allowancePlans.contains { $0.id == plan.id })
        XCTAssertFalse(model.invalidJournalEntryIDs.contains(entry.id))
        XCTAssertTrue(model.entries.contains { $0.id == entry.id })
        XCTAssertTrue(model.recoveryIssues.contains {
            $0 == "allowance_plans/journal-\(plan.id)"
        })
        await storeFixture.store.close()
    }

    @MainActor
    func testRecoveryQuarantinesBothSharedExpensePlansButPreservesRawRecords()
    async throws {
        let storeFixture = try AppModelFixture()
        defer { storeFixture.removeFiles() }
        let fixture = try AllowanceIntegrityFixture()
        let entry = try fixture.expense(amount: 10)
        let first = try fixture.usagePlan(
            name: "First benefit",
            linkedEntryID: entry.id,
            usageAmount: 4
        )
        let second = try fixture.usagePlan(
            name: "Second benefit",
            linkedEntryID: entry.id,
            usageAmount: 4
        )
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await storeFixture.seed(
            profile: profile,
            accounts: fixture.accounts,
            entries: [entry],
            allowancePlans: [first, second]
        )
        let model = storeFixture.model(profile: profile, accounts: fixture.accounts)

        try await model.reloadPersistedBookForTesting()

        XCTAssertFalse(model.allowancePlans.contains { $0.id == first.id })
        XCTAssertFalse(model.allowancePlans.contains { $0.id == second.id })
        XCTAssertTrue(model.entries.contains { $0.id == entry.id })
        XCTAssertFalse(model.invalidJournalEntryIDs.contains(entry.id))
        XCTAssertTrue(model.recoveryIssues.contains {
            $0.hasPrefix("allowance_plans/")
        })
        let rawFirst = try await storeFixture.store.fetch(
            AllowancePlan.self,
            id: first.id.uuidString,
            from: .allowancePlans
        )
        let rawSecond = try await storeFixture.store.fetch(
            AllowancePlan.self,
            id: second.id.uuidString,
            from: .allowancePlans
        )
        let rawEntry = try await storeFixture.store.fetch(
            JournalEntry.self,
            id: entry.id.uuidString,
            from: .journalEntries
        )
        XCTAssertNotNil(rawFirst)
        XCTAssertNotNil(rawSecond)
        XCTAssertNotNil(rawEntry)
        await storeFixture.store.close()
    }

    @MainActor
    func testStrictRestoreRejectsSharedAllowanceJournalOwnership() async throws {
        let storeFixture = try AppModelFixture()
        defer { storeFixture.removeFiles() }
        let fixture = try AllowanceIntegrityFixture()
        let entry = try fixture.expense(amount: 10)
        let first = try fixture.usagePlan(
            linkedEntryID: entry.id,
            usageAmount: 4
        )
        let second = try fixture.usagePlan(
            linkedEntryID: entry.id,
            usageAmount: 4
        )
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await storeFixture.seed(
            profile: profile,
            accounts: fixture.accounts,
            entries: [entry],
            allowancePlans: [first, second]
        )

        do {
            try await RestoreCandidateValidator.validateRelationships(
                profile: profile,
                accounts: fixture.accounts,
                budgetNodes: [],
                scheduledTransactions: [],
                investmentHoldings: [],
                netWorthSnapshots: [],
                quickLogDraft: nil,
                allowancePlans: [first, second],
                in: storeFixture.store
            )
            XCTFail("Expected shared allowance evidence to fail strict restore")
        } catch {
            XCTAssertTrue(error is AppModelError)
        }
        await storeFixture.store.close()
    }
}

private enum ExpiryForgery: CaseIterable, Equatable {
    case source
    case fingerprint
    case origin
    case occurredAt
    case amount
}

private struct AllowanceIntegrityFixture {
    let sgd: CurrencyCode
    let usd: CurrencyCode
    let day: Date
    let periodEnd: Date
    let spendAt: Date
    let wallet: LedgerAccount
    let usWallet: LedgerAccount
    let food: LedgerAccount
    let transport: LedgerAccount
    let restricted: LedgerAccount
    let equity: LedgerAccount

    init() throws {
        sgd = try CurrencyCode("SGD")
        usd = try CurrencyCode("USD")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        day = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 1
        )))
        periodEnd = try XCTUnwrap(
            calendar.date(byAdding: .day, value: 1, to: day)
        )
        spendAt = day.addingTimeInterval(3_600)
        wallet = LedgerAccount(name: "Wallet", kind: .asset, currency: sgd)
        usWallet = LedgerAccount(name: "USD", kind: .asset, currency: usd)
        food = LedgerAccount(name: "Food", kind: .expense)
        transport = LedgerAccount(name: "Transport", kind: .expense)
        restricted = LedgerAccount(
            name: "Meal card",
            kind: .asset,
            currency: sgd,
            accountType: .restrictedAllowance
        )
        equity = LedgerAccount(
            name: "Opening balances",
            kind: .equity,
            systemRole: .openingBalances
        )
    }

    var accounts: [LedgerAccount] {
        [wallet, usWallet, food, transport, restricted, equity]
    }

    var accountsByID: [UUID: LedgerAccount] {
        Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
    }

    func invalidPlanIDs(
        _ plans: [AllowancePlan],
        entries: [JournalEntry]
    ) throws -> Set<UUID> {
        try AllowanceJournalIntegrity.invalidPlanIDs(
            plans: plans,
            accountsByID: accountsByID,
            entriesByID: Dictionary(
                uniqueKeysWithValues: entries.map { ($0.id, $0) }
            )
        )
    }

    func expense(
        amount: Decimal,
        occurredAt: Date? = nil,
        categoryID: UUID? = nil
    ) throws -> JournalEntry {
        try entry(
            kind: .expense,
            occurredAt: occurredAt ?? spendAt,
            categoryID: categoryID ?? food.id,
            amount: amount,
            currency: sgd,
            paidFrom: wallet.id
        )
    }

    func entry(
        kind: JournalEntryKind,
        occurredAt: Date,
        categoryID: UUID,
        amount: Decimal,
        currency: CurrencyCode,
        paidFrom: UUID
    ) throws -> JournalEntry {
        try JournalEntry(
            kind: kind,
            occurredAt: occurredAt,
            postings: [
                Posting(
                    accountID: categoryID,
                    money: Money(amount, currency: currency)
                ),
                Posting(
                    accountID: paidFrom,
                    money: Money(-amount, currency: currency)
                )
            ]
        )
    }

    func usagePlan(
        name: String = "Benefit",
        fundingMode: AllowanceFundingMode = .benefitLimit,
        linkedEntryID: UUID,
        usageAmount: Decimal
    ) throws -> AllowancePlan {
        var plan = try AllowancePlan(
            name: name,
            amount: Money(20, currency: sgd),
            cadence: .daily,
            fundingMode: fundingMode,
            linkedAccountID: fundingMode == .prepaidAsset ? restricted.id : nil,
            startsAt: day,
            timeZoneIdentifier: "UTC",
            eligibleCategoryIDs: [food.id]
        )
        let usage = try AllowanceUsage(
            amount: Money(usageAmount, currency: sgd),
            occurredAt: spendAt,
            categoryID: food.id,
            linkedJournalEntryID: linkedEntryID,
            policyRevisionID: plan.policy(at: spendAt)?.id,
            claimStatus: fundingMode == .reimbursement ? .pendingApproval : nil
        )
        plan = try plan.addingUsage(usage)
        return plan
    }

    func grandfatheredPlan(linkedEntryID: UUID) throws -> AllowancePlan {
        let planID = UUID()
        let usage = try AllowanceUsage(
            amount: Money(4, currency: sgd),
            occurredAt: spendAt,
            categoryID: food.id,
            linkedJournalEntryID: linkedEntryID,
            policyRevisionID: planID
        )
        return try AllowancePlan(
            id: planID,
            name: "Legacy benefit",
            amount: Money(20, currency: sgd),
            cadence: .daily,
            startsAt: day,
            timeZoneIdentifier: "UTC",
            eligibleCategoryIDs: [food.id],
            usages: [usage],
            hasGrandfatheredActivity: true
        )
    }

    func prepaidExpense(
        eligibleAmount: Decimal,
        restrictedDebit: Decimal
    ) throws -> JournalEntry {
        let cashDebit = eligibleAmount - restrictedDebit
        var postings = [
            Posting(
                accountID: food.id,
                money: try Money(eligibleAmount, currency: sgd)
            ),
            Posting(
                accountID: restricted.id,
                money: try Money(-restrictedDebit, currency: sgd)
            )
        ]
        if cashDebit != .zero {
            postings.append(Posting(
                accountID: wallet.id,
                money: try Money(-cashDebit, currency: sgd)
            ))
        }
        return try JournalEntry(
            kind: .expense,
            occurredAt: spendAt,
            postings: postings
        )
    }

    func restrictedFunding(
        amount: Decimal,
        occurredAt: Date? = nil
    ) throws -> JournalEntry {
        try TransactionFactory.balanceAdjustment(
            displayBalanceDelta: Money(amount, currency: sgd),
            accountID: restricted.id,
            equityAccountID: equity.id,
            accountIsLiability: false,
            occurredAt: occurredAt ?? day
        )
    }

    func recordingReconciliation(
        on plan: AllowancePlan,
        entryID: UUID,
        expiredAmount: Decimal
    ) throws -> AllowancePlan {
        try plan.recordingReconciliation(AllowanceReconciliation(
            policyRevisionID: try XCTUnwrap(plan.policy(at: day)?.id),
            periodStart: day,
            periodEnd: periodEnd,
            expired: Money(expiredAmount, currency: sgd),
            recordedAt: periodEnd.addingTimeInterval(60),
            linkedJournalEntryID: entryID
        ))
    }

    func expiryEvidence(
        forgery: ExpiryForgery?
    ) throws -> (plan: AllowancePlan, entry: JournalEntry) {
        let entryID = UUID()
        let base = try AllowancePlan(
            name: "Prepaid benefit",
            amount: Money(20, currency: sgd),
            cadence: .daily,
            fundingMode: .prepaidAsset,
            linkedAccountID: restricted.id,
            startsAt: day,
            timeZoneIdentifier: "UTC"
        )
        let plan = try recordingReconciliation(
            on: base,
            entryID: entryID,
            expiredAmount: 5
        )
        let actualDate = forgery == .occurredAt
            ? periodEnd.addingTimeInterval(1) : periodEnd
        let origin = expiryOrigin(
            plan: plan,
            actualDate: actualDate,
            isForged: forgery == .origin || forgery == .occurredAt
        )
        let postingAmount: Decimal = forgery == .amount ? 4 : 5
        let entry = try JournalEntry(
            id: entryID,
            kind: .adjustment,
            occurredAt: actualDate,
            postings: [
                Posting(
                    accountID: restricted.id,
                    money: Money(-postingAmount, currency: sgd)
                ),
                Posting(
                    accountID: equity.id,
                    money: Money(postingAmount, currency: sgd)
                )
            ],
            sourceSystem: forgery == .source
                ? "forged.expiry" : AllowanceJournalIntegrity.expirySourceSystem,
            sourceFingerprint: forgery == .fingerprint
                ? "forged"
                : AllowanceJournalIntegrity.expiryFingerprint(
                    planID: plan.id,
                    policyRevisionID: try XCTUnwrap(plan.policy(at: day)?.id),
                    periodEnd: periodEnd
                ),
            originContext: origin
        )
        return (plan, entry)
    }

    func planPayload(
        _ plan: AllowancePlan,
        replacingExpiredAmount amount: Decimal
    ) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(plan))
                as? [String: Any]
        )
        var reconciliations = try XCTUnwrap(
            object["reconciliations"] as? [[String: Any]]
        )
        var expired = try XCTUnwrap(
            reconciliations[0]["expired"] as? [String: Any]
        )
        expired["amount"] = NSDecimalNumber(decimal: amount)
        reconciliations[0]["expired"] = expired
        object["reconciliations"] = reconciliations
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func expiryOrigin(
        plan: AllowancePlan,
        actualDate: Date,
        isForged: Bool
    ) -> TransactionOriginContext {
        guard isForged else {
            return AllowanceJournalIntegrity.expiryOriginContext(
                plan: plan,
                periodStart: day,
                periodEnd: periodEnd
            )
        }
        var calendar = Calendar(identifier: .gregorian)
        let zone = TimeZone(identifier: "Asia/Tokyo")!
        calendar.timeZone = zone
        return .capture(for: actualDate, calendar: calendar, timeZone: zone)
    }
}
