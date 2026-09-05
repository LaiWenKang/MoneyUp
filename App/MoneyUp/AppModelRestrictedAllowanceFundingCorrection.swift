import Foundation
import MoneyUpCore
import MoneyUpPersistence

struct RestrictedAllowanceFundingRecord: Equatable, Identifiable, Sendable {
    let entryID: UUID
    let accountID: UUID
    let amount: Money
    let occurredAt: Date
    let note: String?

    var id: UUID { entryID }
}

private struct RestrictedAllowanceFundingEvidence {
    let record: RestrictedAllowanceFundingRecord
    let equityAccountID: UUID
}

extension AppModel {
    static let restrictedFundingVoidSourceSystem =
        "moneyup.allowance.funding.void"

    func restrictedAllowanceFundingRecords(
        accountID: UUID
    ) async throws -> [RestrictedAllowanceFundingRecord] {
        let read = try beginLogicalBookRead()
        let accountSnapshot = accounts
        let invalidEntryIDs = invalidJournalEntryIDs
        guard accountSnapshot.contains(where: {
            $0.id == accountID
                && $0.kind == .asset
                && $0.accountType == .restrictedAllowance
                && $0.currency != nil
        }) else { throw AppModelError.invalidAllowance }
        let events = try await read.store.fetchJournalPostingEvents(
            accountIDs: [accountID],
            excludingEntryIDs: invalidEntryIDs
        )
        try requireLogicalBookRead(read.token)
        let candidateIDs = Set(events.compactMap { event in
            event.posting.accountID == accountID
                && event.posting.money.amount > .zero ? event.entryID : nil
        })
        let recovered = try await read.store.fetchJournalEntriesRecovering(
            ids: candidateIDs
        )
        try requireLogicalBookRead(read.token)
        guard recovered.issues.isEmpty,
              Set(recovered.values.map(\.id)) == candidateIDs,
              accounts == accountSnapshot else {
            throw AppModelError.invalidBook
        }
        let records = recovered.values.compactMap {
            restrictedAllowanceFundingEvidence(
                entry: $0,
                accountID: accountID,
                accounts: accountSnapshot
            )?.record
        }.sorted {
            if $0.occurredAt != $1.occurredAt {
                return $0.occurredAt > $1.occurredAt
            }
            return $0.entryID.uuidString > $1.entryID.uuidString
        }
        return try await finishLogicalBookRead(records, token: read.token)
    }

    /// Replaces or voids one MoneyUp-style restricted funding adjustment while
    /// retaining the prior encrypted row as audit evidence. This path never
    /// creates a restricted debit: a zero correction removes the live funding
    /// and retains its reason in a non-live revision marker; a positive
    /// correction remains a credit to the restricted asset.
    @discardableResult
    func correctRestrictedAllowanceFunding(
        expected: RestrictedAllowanceFundingRecord,
        correctedAmount: Decimal,
        note: String?
    ) async throws -> UUID? {
        try beginJournalMutation()
        defer { endJournalMutation() }
        guard correctedAmount >= .zero,
              correctedAmount < expected.amount.amount,
              !invalidJournalEntryIDs.contains(expected.entryID) else {
            throw AppModelError.invalidAllowance
        }
        try requireValidNewWriteAmount(
            correctedAmount,
            currency: expected.amount.currency,
            preserving: expected.amount.amount
        )
        let correctionStore = try requireStore()
        guard let original = try await correctionStore.fetch(
            JournalEntry.self,
            id: expected.entryID.uuidString,
            from: .journalEntries
        ), let evidence = restrictedAllowanceFundingEvidence(
            entry: original,
            accountID: expected.accountID,
            accounts: accounts
        ), evidence.record == expected else {
            throw AppModelError.invalidAllowance
        }
        try await requireUnlinkedRestrictedFunding(
            original,
            in: correctionStore
        )
        let replacement = try restrictedFundingReplacement(
            original: original,
            evidence: evidence,
            correctedAmount: correctedAmount,
            note: note
        )
        try await requireNonnegativeRestrictedBalances(
            afterRemoving: original,
            adding: replacement,
            in: correctionStore
        )
        let writes = try restrictedFundingCorrectionWrites(
            original: original,
            replacement: replacement,
            note: note
        )
        let generation = storeGeneration
        invalidateCommittedJournalProjection()
        await lifecycleHooks.checkpoint(
            .afterJournalProjectionInvalidationBeforeCommit
        )
        try await correctionStore.write(
            writes,
            removing: [RecordDeletion(
                id: original.id.uuidString,
                from: .journalEntries
            )]
        )
        guard isCurrentStoreGeneration(generation) else {
            throw AppModelError.locked
        }
        if retainsCompleteJournal {
            entries.removeAll { $0.id == original.id }
            if let replacement { entries.append(replacement) }
            entries.sort {
                if $0.occurredAt != $1.occurredAt {
                    return $0.occurredAt > $1.occurredAt
                }
                return $0.id.uuidString > $1.id.uuidString
            }
        }
        await refreshJournalAfterMutation()
        return replacement?.id
    }

    private func restrictedAllowanceFundingEvidence(
        entry: JournalEntry,
        accountID: UUID,
        accounts: [LedgerAccount]
    ) -> RestrictedAllowanceFundingEvidence? {
        let openingBalances = accounts.filter {
            $0.kind == .equity
                && $0.currency == nil
                && $0.accountType == nil
                && $0.systemRole == .openingBalances
                && $0.parentID == nil
                && !$0.isArchived
        }
        guard openingBalances.count == 1,
              accounts.filter({ $0.id == accountID }).count == 1,
              let account = accounts.first(where: { $0.id == accountID }),
              account.kind == .asset,
              account.accountType == .restrictedAllowance,
              account.systemRole == nil,
              account.parentID == nil,
              !account.isArchived,
              let currency = account.currency,
              entry.kind == .adjustment,
              entry.postings.count == 2,
              let funding = entry.postings.first(where: {
                  $0.accountID == accountID
              }),
              funding.money.currency == currency,
              funding.money.amount > .zero,
              let counter = entry.postings.first(where: {
                  $0.accountID == openingBalances[0].id
              }),
              counter.money.currency == currency,
              counter.money.amount == -funding.money.amount else {
            return nil
        }
        return RestrictedAllowanceFundingEvidence(
            record: RestrictedAllowanceFundingRecord(
                entryID: entry.id,
                accountID: accountID,
                amount: funding.money,
                occurredAt: entry.occurredAt,
                note: entry.note
            ),
            equityAccountID: openingBalances[0].id
        )
    }

    private func requireUnlinkedRestrictedFunding(
        _ entry: JournalEntry,
        in store: EncryptedRecordStore
    ) async throws {
        let entryID = entry.id
        guard budgetEntryAttributions[entryID] == nil,
              !scheduledTransactions.contains(where: {
                  $0.resolutions.contains { $0.linkedEntryID == entryID }
              }),
              !investmentHoldings.contains(where: {
                  $0.linkedEntryIDs.contains(entryID)
              }),
              !loanPlans.contains(where: {
                  $0.activities.contains { $0.journalEntryID == entryID }
              }),
              !allowancePlans.contains(where: { plan in
                  plan.usages.contains { $0.linkedJournalEntryID == entryID }
                      || plan.reconciliations.contains {
                          $0.linkedJournalEntryID == entryID
                      }
              }),
              !receiptAttachmentMetadata.contains(where: {
                  $0.entryID == entryID
              }),
              (try await store.receiptAttachmentIDs(entryID: entryID)).isEmpty else {
            throw AppModelError.invalidAllowance
        }
    }

    private func restrictedFundingReplacement(
        original: JournalEntry,
        evidence: RestrictedAllowanceFundingEvidence,
        correctedAmount: Decimal,
        note: String?
    ) throws -> JournalEntry? {
        guard correctedAmount > .zero else { return nil }
        let money = try Money(
            correctedAmount,
            currency: evidence.record.amount.currency
        )
        return try JournalEntry(
            kind: .adjustment,
            occurredAt: original.occurredAt,
            createdAt: original.createdAt,
            note: note,
            postings: [
                Posting(
                    accountID: evidence.record.accountID,
                    money: money
                ),
                Posting(
                    accountID: evidence.equityAccountID,
                    money: money.negated
                )
            ],
            supersedesID: original.id,
            revisedAt: currentDate(),
            sourceSystem: original.sourceSystem,
            sourceFingerprint: original.sourceFingerprint,
            originContext: original.originContext
        )
    }

    private func restrictedFundingCorrectionWrites(
        original: JournalEntry,
        replacement: JournalEntry?,
        note: String?
    ) throws -> [RecordWrite] {
        var writes = [try RecordWrite(
            original,
            id: "\(original.id.uuidString)-\(UUID().uuidString)",
            in: .journalEntryRevisions
        )]
        if let replacement {
            writes.append(try RecordWrite(
                replacement,
                id: replacement.id.uuidString,
                in: .journalEntries
            ))
        } else {
            let marker = try restrictedFundingVoidMarker(
                original: original,
                note: note
            )
            writes.append(try RecordWrite(
                marker,
                id: "\(marker.id.uuidString)-\(UUID().uuidString)",
                in: .journalEntryRevisions
            ))
        }
        return writes
    }

    /// A void has no live zero-value transaction. Its reason and revision time
    /// therefore live in a separate, balanced revision marker. The exact prior
    /// row is retained independently, and revision rows never enter the ledger.
    private func restrictedFundingVoidMarker(
        original: JournalEntry,
        note: String?
    ) throws -> JournalEntry {
        try JournalEntry(
            kind: .adjustment,
            occurredAt: original.occurredAt,
            createdAt: original.createdAt,
            payee: original.payee,
            note: note,
            postings: original.postings,
            supersedesID: original.id,
            revisedAt: currentDate(),
            sourceSystem: Self.restrictedFundingVoidSourceSystem,
            sourceFingerprint: original.id.uuidString,
            originContext: original.originContext
        )
    }
}
