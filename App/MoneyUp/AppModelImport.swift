import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

extension AppModel {
    func importTransactions(
        _ rows: [ImportedTransaction],
        fallbackAccountID: UUID,
        fallbackExpenseCategoryID: UUID,
        fallbackIncomeCategoryID: UUID,
        accountMappings: [String: UUID] = [:],
        expenseCategoryMappings: [String: UUID] = [:],
        incomeCategoryMappings: [String: UUID] = [:],
        sourceSystem: String = "CSV/Qianji"
    ) async throws -> TransactionImportResult {
        try beginStandaloneJournalMutation()
        defer { endStandaloneJournalMutation() }
        guard rows.count <= MonetaryInputPolicy.aggregateRecordBudget else {
            throw AppModelError.importTooLarge
        }
        guard let fallbackAccount = userAccounts.first(where: {
            $0.id == fallbackAccountID
        }), expenseCategories.contains(where: {
            $0.id == fallbackExpenseCategoryID && $0.systemRole == nil
        }), incomeCategories.contains(where: {
            $0.id == fallbackIncomeCategoryID && $0.systemRole == nil
        }) else { throw AppModelError.missingRecord }
        let canonicalImportSource = TransactionCSVImporter.canonicalSourceSystem(
            sourceSystem
        )
        let existingEntries: [JournalEntry]
        let existingFingerprints: Set<String>
        if retainsCompleteJournal {
            existingEntries = entries
            existingFingerprints = Set(entries.compactMap(\.sourceFingerprint))
        } else {
            // Import is an explicit heavy operation. Fetch one encrypted
            // snapshot for semantic keys and read the compact source index so even
            // quarantined valid JSON remains a global fingerprint duplicate.
            existingEntries = try await journalSnapshot(
                includeInvalidRelationships: true
            )
            existingFingerprints = try await requireStore().journalSourceFingerprints()
        }

        func normalizedName(_ value: String) -> String {
            CSVImportNameResolver.normalizedKey(for: value)
        }

        let sameSourceLegacyFingerprints: Set<String> = Set(
            existingEntries.compactMap { entry -> String? in
                guard TransactionCSVImporter.canonicalSourceSystem(
                    entry.sourceSystem ?? ""
                ) == canonicalImportSource else {
                    return nil
                }
                return entry.sourceFingerprint
            }
        )

        var candidateAccounts = accounts
        var newAccounts: [LedgerAccount] = []
        var newBudgetNodes: [BudgetNode] = []
        var importedEntries: [JournalEntry] = []
        var fingerprints = existingFingerprints
        var duplicates = 0
        var skipped = 0
        let initialAccountKinds = Dictionary(
            uniqueKeysWithValues: accounts.map { ($0.id, $0.kind) }
        )

        func duplicateKey(
            kind: ImportedTransactionKind,
            occurredAt: Date,
            amount: Decimal,
            currency: CurrencyCode,
            sourceID: UUID,
            destinationID: UUID? = nil,
            destinationAmount: Decimal? = nil,
            destinationCurrency: CurrencyCode? = nil,
            payee: String?
        ) -> String {
            let components = [
                kind.rawValue,
                String(Int64(occurredAt.timeIntervalSince1970.rounded(.down))),
                NSDecimalNumber(decimal: amount).stringValue,
                currency.value,
                sourceID.uuidString.lowercased(),
                destinationID?.uuidString.lowercased() ?? "",
                destinationAmount.map {
                    NSDecimalNumber(decimal: $0).stringValue
                } ?? "",
                destinationCurrency?.value ?? "",
                normalizedName(payee ?? "")
            ]
            return components.map { "\($0.utf8.count):\($0)" }.joined()
        }

        func duplicateKey(for entry: JournalEntry) -> String? {
            let userPosting: Posting?
            let amountPosting: Posting?
            let destinationPosting: Posting?
            let kind: ImportedTransactionKind?
            switch entry.kind {
            case .expense:
                userPosting = entry.postings.first {
                    initialAccountKinds[$0.accountID] == .asset
                        || initialAccountKinds[$0.accountID] == .liability
                }
                amountPosting = entry.postings.first {
                    initialAccountKinds[$0.accountID] == .expense
                } ?? entry.postings.first { $0.id != userPosting?.id }
                destinationPosting = nil
                kind = (amountPosting?.money.amount ?? .zero) < .zero
                    ? .refund : .expense
            case .income:
                userPosting = entry.postings.first {
                    initialAccountKinds[$0.accountID] == .asset
                        || initialAccountKinds[$0.accountID] == .liability
                }
                amountPosting = entry.postings.first {
                    initialAccountKinds[$0.accountID] == .income
                } ?? entry.postings.first { $0.id != userPosting?.id }
                destinationPosting = nil
                kind = .income
            case .transfer:
                let userPostings = entry.postings.filter {
                    initialAccountKinds[$0.accountID] == .asset
                        || initialAccountKinds[$0.accountID] == .liability
                }
                let sourcePostings = userPostings.filter { $0.money.amount < .zero }
                let destinationPostings = userPostings.filter { $0.money.amount > .zero }
                guard sourcePostings.count == 1,
                      destinationPostings.count == 1 else {
                    return nil
                }
                userPosting = sourcePostings[0]
                amountPosting = userPosting
                destinationPosting = destinationPostings[0]
                kind = .transfer
            case .adjustment, .investment:
                return nil
            }
            guard let userPosting, let amountPosting, let kind else { return nil }
            if kind == .transfer, destinationPosting == nil { return nil }
            return duplicateKey(
                kind: kind,
                occurredAt: entry.occurredAt,
                amount: abs(amountPosting.money.amount),
                currency: amountPosting.money.currency,
                sourceID: userPosting.accountID,
                destinationID: destinationPosting?.accountID,
                destinationAmount: destinationPosting.map { abs($0.money.amount) },
                destinationCurrency: destinationPosting?.money.currency,
                payee: entry.payee
            )
        }

        var duplicateKeys = Set(existingEntries.compactMap { duplicateKey(for: $0) })

        func isEligibleImportAccount(
            _ account: LedgerAccount,
            currency: CurrencyCode?
        ) -> Bool {
            (account.kind == .asset || account.kind == .liability)
                && account.systemRole == nil
                && !account.isArchived
                && (currency == nil || account.currency == currency)
        }

        func isEligibleImportCategory(
            _ account: LedgerAccount,
            kind: LedgerAccountKind
        ) -> Bool {
            account.kind == kind
                && account.systemRole == nil
                && !account.isArchived
        }

        func account(named name: String?, currency: CurrencyCode?) -> LedgerAccount? {
            guard let name else { return nil }
            let normalized = normalizedName(name)
            if let mappedID = accountMappings[normalized],
               let mapped = candidateAccounts.first(where: {
                   $0.id == mappedID && isEligibleImportAccount($0, currency: currency)
               }) {
                return mapped
            }
            return candidateAccounts.first {
                isEligibleImportAccount($0, currency: currency)
                    && normalizedName($0.name) == normalized
            }
        }

        func category(
            named name: String?,
            kind: LedgerAccountKind,
            fallbackID: UUID
        ) -> LedgerAccount? {
            guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return candidateAccounts.first {
                    $0.id == fallbackID && isEligibleImportCategory($0, kind: kind)
                }
            }
            let normalized = normalizedName(name)
            let reviewedMappings = kind == .income
                ? incomeCategoryMappings
                : expenseCategoryMappings
            if let mappedID = reviewedMappings[normalized],
               let mapped = candidateAccounts.first(where: {
                   $0.id == mappedID && isEligibleImportCategory($0, kind: kind)
               }) {
                return mapped
            }
            if let existing = candidateAccounts.first(where: {
                isEligibleImportCategory($0, kind: kind)
                    && normalizedName($0.name) == normalized
            }) {
                return existing
            }
            let created = LedgerAccount(name: name, kind: kind)
            candidateAccounts.append(created)
            newAccounts.append(created)
            if kind == .expense {
                newBudgetNodes.append(BudgetNode(id: created.id, name: created.name))
            }
            return created
        }

        func candidateForeignExchangeAccount(
            for currency: CurrencyCode
        ) -> LedgerAccount {
            candidateAccounts.first {
                $0.systemRole == .foreignExchange && $0.currency == currency
            } ?? LedgerAccount(
                name: "\(String(localized: "account.fx_clearing")) \(currency.value)",
                kind: .trading,
                currency: currency,
                systemRole: .foreignExchange
            )
        }

        for row in rows {
            let persistedFingerprint = TransactionCSVImporter.persistenceFingerprint(
                for: row.id,
                sourceSystem: sourceSystem
            )
            let insertedFingerprint = fingerprints.insert(persistedFingerprint).inserted
            let matchesUnscopedIdentity = sameSourceLegacyFingerprints.contains(row.id)
            let matchesLegacyCandidate = !row.legacyFingerprintCandidates.isDisjoint(
                with: sameSourceLegacyFingerprints
            )
            guard insertedFingerprint, !matchesUnscopedIdentity else {
                if insertedFingerprint {
                    fingerprints.remove(persistedFingerprint)
                }
                duplicates += 1
                continue
            }
            let declaredCurrency = row.currencyCode.flatMap { try? CurrencyCode($0) }
            if row.currencyCode != nil, declaredCurrency == nil {
                fingerprints.remove(persistedFingerprint)
                skipped += 1
                continue
            }
            let source = account(named: row.accountName, currency: declaredCurrency)
                ?? (declaredCurrency == nil || declaredCurrency == fallbackAccount.currency
                    ? fallbackAccount
                    : nil)
            guard let source, let sourceCurrency = source.currency,
                  MonetaryInputPolicy.accepts(
                    row.amount,
                    currency: sourceCurrency
                  ) else {
                fingerprints.remove(persistedFingerprint)
                skipped += 1
                continue
            }
            let transferDestination: LedgerAccount?
            let semanticDestinationAmount: Decimal?
            if row.kind == .transfer {
                guard let destination = account(
                    named: row.destinationAccountName,
                    currency: nil
                ), destination.id != source.id,
                let destinationCurrency = destination.currency else {
                    fingerprints.remove(persistedFingerprint)
                    skipped += 1
                    continue
                }
                let destinationAmount: Decimal? = sourceCurrency == destinationCurrency
                    ? row.amount
                    : row.destinationAmount
                guard let destinationAmount,
                      MonetaryInputPolicy.accepts(
                        destinationAmount,
                        currency: destinationCurrency
                      ) else {
                    fingerprints.remove(persistedFingerprint)
                    skipped += 1
                    continue
                }
                transferDestination = destination
                semanticDestinationAmount = destinationAmount
            } else {
                transferDestination = nil
                semanticDestinationAmount = nil
            }
            let rowDuplicateKey = duplicateKey(
                kind: row.kind,
                occurredAt: row.occurredAt,
                amount: row.amount,
                currency: sourceCurrency,
                sourceID: source.id,
                destinationID: transferDestination?.id,
                destinationAmount: semanticDestinationAmount,
                destinationCurrency: transferDestination?.currency,
                // Transfer factories do not persist a payee. Build the key
                // from the shape that can be reconstructed after reopening.
                payee: row.kind == .transfer ? nil : row.payee
            )
            let insertedSemanticKey = duplicateKeys.insert(rowDuplicateKey).inserted
            // FNV-era candidates are collision-prone and interim SHA candidates
            // contain mutable fields. Treat either as a legacy duplicate only
            // when the reconstructed ledger semantics also match. A prior
            // unscoped exact row identity was handled above and needs no
            // heuristic corroboration.
            let matchesSafeLegacyDuplicate = matchesLegacyCandidate
                && !insertedSemanticKey
            guard !matchesSafeLegacyDuplicate,
                  row.hasExternalID || insertedSemanticKey else {
                fingerprints.remove(persistedFingerprint)
                duplicates += 1
                continue
            }

            let candidateAccountsCheckpoint = candidateAccounts.count
            let newAccountsCheckpoint = newAccounts.count
            let newBudgetNodesCheckpoint = newBudgetNodes.count

            let baseEntry: JournalEntry
            do {
                switch row.kind {
                case .expense:
                    guard let category = category(
                        named: row.categoryName,
                        kind: .expense,
                        fallbackID: fallbackExpenseCategoryID
                    ) else { throw AppModelError.missingRecord }
                    baseEntry = try TransactionFactory.expense(
                        amount: try Money(row.amount, currency: sourceCurrency),
                        paidFrom: source.id,
                        category: category.id,
                        occurredAt: row.occurredAt,
                        payee: row.payee,
                        note: row.note
                    )
                case .income:
                    guard let category = category(
                        named: row.categoryName,
                        kind: .income,
                        fallbackID: fallbackIncomeCategoryID
                    ) else { throw AppModelError.missingRecord }
                    baseEntry = try TransactionFactory.income(
                        amount: try Money(row.amount, currency: sourceCurrency),
                        depositedInto: source.id,
                        category: category.id,
                        occurredAt: row.occurredAt,
                        payee: row.payee,
                        note: row.note
                    )
                case .refund:
                    guard let category = category(
                        named: row.categoryName,
                        kind: .expense,
                        fallbackID: fallbackExpenseCategoryID
                    ) else { throw AppModelError.missingRecord }
                    baseEntry = try TransactionFactory.refund(
                        amount: try Money(row.amount, currency: sourceCurrency),
                        returnedTo: source.id,
                        category: category.id,
                        occurredAt: row.occurredAt,
                        payee: row.payee,
                        note: row.note
                    )
                case .transfer:
                    guard let destination = transferDestination,
                    let destinationCurrency = destination.currency else {
                        throw AppModelError.missingRecord
                    }
                    if sourceCurrency == destinationCurrency {
                        baseEntry = try TransactionFactory.transfer(
                            amount: try Money(row.amount, currency: sourceCurrency),
                            from: source.id,
                            to: destination.id,
                            occurredAt: row.occurredAt,
                            note: row.note
                        )
                    } else {
                        guard let destinationAmount = semanticDestinationAmount else {
                            throw AppModelError.foreignCurrencyTransferRequiresExchangeRate
                        }
                        let sourceTrading = candidateForeignExchangeAccount(
                            for: sourceCurrency
                        )
                        let destinationTrading = candidateForeignExchangeAccount(
                            for: destinationCurrency
                        )
                        for trading in [sourceTrading, destinationTrading]
                        where !candidateAccounts.contains(where: { $0.id == trading.id }) {
                            candidateAccounts.append(trading)
                            newAccounts.append(trading)
                        }
                        baseEntry = try TransactionFactory.foreignCurrencyTransfer(
                            sourceAmount: try Money(row.amount, currency: sourceCurrency),
                            destinationAmount: try Money(
                                destinationAmount,
                                currency: destinationCurrency
                            ),
                            from: source.id,
                            to: destination.id,
                            sourceTradingAccountID: sourceTrading.id,
                            destinationTradingAccountID: destinationTrading.id,
                            occurredAt: row.occurredAt,
                            note: row.note
                        )
                    }
                }

                importedEntries.append(
                    try JournalEntry(
                        kind: baseEntry.kind,
                        occurredAt: baseEntry.occurredAt,
                        createdAt: baseEntry.createdAt,
                        payee: baseEntry.payee,
                        note: baseEntry.note,
                        postings: baseEntry.postings,
                        sourceSystem: sourceSystem,
                        sourceFingerprint: persistedFingerprint,
                        originContext: row.originContext
                            ?? reportingOriginContext(for: baseEntry.occurredAt)
                    )
                )
            } catch {
                candidateAccounts.removeSubrange(candidateAccountsCheckpoint...)
                newAccounts.removeSubrange(newAccountsCheckpoint...)
                newBudgetNodes.removeSubrange(newBudgetNodesCheckpoint...)
                fingerprints.remove(persistedFingerprint)
                if insertedSemanticKey {
                    duplicateKeys.remove(rowDuplicateKey)
                }
                skipped += 1
            }
        }

        guard !importedEntries.isEmpty else {
            return TransactionImportResult(
                imported: 0,
                duplicates: duplicates,
                skipped: skipped,
                categoriesCreated: 0
            )
        }
        let candidateBudgetNodes = budgetNodes + newBudgetNodes
        if let currency = profile?.baseCurrency {
            _ = try BudgetTree(currency: currency, nodes: candidateBudgetNodes)
        }
        let recordedTimeline: BudgetConfigurationTimeline?
        if newBudgetNodes.isEmpty {
            recordedTimeline = nil
        } else {
            recordedTimeline = try budgetConfigurationTimelineRecording(
                nodes: candidateBudgetNodes
            )
        }
        let reportingZone = profile?.reportingTimeZoneIdentifier
            ?? reportingCalendar.timeZone.identifier
        let importedAttributions = try importedEntries.map {
            try BudgetEntryAttribution(
                entry: $0,
                originTimeZoneIdentifier: reportingZone
            )
        }
        let importStore = try requireStore()
        try await loadCompleteBudgetAttributionCacheIfNeeded(from: importStore)
        var candidateEntries = existingEntries + importedEntries
        candidateEntries.sort {
            if $0.occurredAt == $1.occurredAt { return $0.createdAt > $1.createdAt }
            return $0.occurredAt > $1.occurredAt
        }
        var candidateAttributions = budgetEntryAttributions
        for attribution in importedAttributions {
            candidateAttributions[attribution.id] = attribution
        }
        let recomputedTimeline = try budgetTimelineAfterJournalMutation(
            timeline: recordedTimeline,
            journalEntries: candidateEntries,
            attributions: candidateAttributions,
            affectedReportingMonths: try importedEntries.compactMap { entry in
                try budgetAffectedMonth(
                    for: entry,
                    attribution: candidateAttributions[entry.id],
                    timeline: recordedTimeline
                )
            }
        )
        let candidateTimeline = recomputedTimeline ?? recordedTimeline

        var writes = try newAccounts.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .accounts)
        }
        writes += try newBudgetNodes.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .budgetNodes)
        }
        writes += try importedEntries.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .journalEntries)
        }
        writes += try importedAttributions.map {
            try RecordWrite(
                $0,
                id: $0.id.uuidString,
                in: .budgetEntryAttributions
            )
        }
        if let candidateTimeline {
            writes.append(try budgetConfigurationTimelineWrite(candidateTimeline))
        }

        let generation = storeGeneration
        await lifecycleHooks.checkpoint(.beforeJournalCommit)
        invalidateCommittedJournalProjection()
        await lifecycleHooks.checkpoint(
            .afterJournalProjectionInvalidationBeforeCommit
        )
        try await importStore.write(writes)
        guard isCurrentStoreGeneration(generation) else {
            return TransactionImportResult(
                imported: 0,
                duplicates: duplicates,
                skipped: skipped,
                categoriesCreated: 0
            )
        }
        accounts.append(contentsOf: newAccounts)
        if let candidateTimeline { budgetConfigurationTimeline = candidateTimeline }
        budgetEntryAttributions = candidateAttributions
        budgetNodes = candidateBudgetNodes
        if retainsCompleteJournal { entries = candidateEntries }
        await refreshJournalAfterMutation()
        return TransactionImportResult(
            imported: importedEntries.count,
            duplicates: duplicates,
            skipped: skipped,
            categoriesCreated: newBudgetNodes.count
                + newAccounts.filter { $0.kind == .income }.count
        )
    }
}
