import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

struct AppModelTransactionImportExisting: Sendable {
    let entries: [JournalEntry]
    let fingerprints: Set<String>
}

struct AppModelTransactionImportContext: Sendable {
    let fallbackAccount: LedgerAccount
    let fallbackExpenseCategoryID: UUID
    let fallbackIncomeCategoryID: UUID
    let accountMappings: [String: UUID]
    let expenseCategoryMappings: [String: UUID]
    let incomeCategoryMappings: [String: UUID]
    let sourceSystem: String
    let canonicalSource: String
    let sameSourceLegacyFingerprints: Set<String>
    let initialAccountKinds: [UUID: LedgerAccountKind]
}

struct AppModelTransactionImportState: Sendable {
    var candidateAccounts: [LedgerAccount]
    var newAccounts: [LedgerAccount] = []
    var newBudgetNodes: [BudgetNode] = []
    var importedEntries: [JournalEntry] = []
    var fingerprints: Set<String>
    var duplicateKeys: Set<String>
    var duplicates = 0
    var skipped = 0
}

struct AppModelTransactionImportIdentity: Sendable {
    let persistedFingerprint: String
    let matchesLegacyCandidate: Bool
}

struct AppModelTransactionImportSemantics: Sendable {
    let source: LedgerAccount
    let sourceCurrency: CurrencyCode
    let destination: LedgerAccount?
    let destinationAmount: Decimal?
    let duplicateKey: String
    let insertedDuplicateKey: Bool
}

struct AppModelTransactionImportBudgetPlan: Sendable {
    let candidateNodes: [BudgetNode]
    let recordedTimeline: BudgetConfigurationTimeline?
    let attributions: [BudgetEntryAttribution]
}

struct AppModelTransactionImportCommitPlan: Sendable {
    let store: EncryptedRecordStore
    let writes: [RecordWrite]
    let newAccounts: [LedgerAccount]
    let newBudgetNodes: [BudgetNode]
    let importedEntries: [JournalEntry]
    let candidateBudgetNodes: [BudgetNode]
    let candidateTimeline: BudgetConfigurationTimeline?
    let candidateAttributions: [UUID: BudgetEntryAttribution]
    let candidateEntries: [JournalEntry]
}

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
        let fallbackAccount = try validatedTransactionImportFallbacks(
            accountID: fallbackAccountID,
            expenseCategoryID: fallbackExpenseCategoryID,
            incomeCategoryID: fallbackIncomeCategoryID
        )
        let canonicalSource = TransactionCSVImporter.canonicalSourceSystem(
            sourceSystem
        )
        let existing = try await transactionImportExistingJournal()
        let context = transactionImportContext(
            fallbackAccount: fallbackAccount,
            fallbackExpenseCategoryID: fallbackExpenseCategoryID,
            fallbackIncomeCategoryID: fallbackIncomeCategoryID,
            accountMappings: accountMappings,
            expenseCategoryMappings: expenseCategoryMappings,
            incomeCategoryMappings: incomeCategoryMappings,
            sourceSystem: sourceSystem,
            canonicalSource: canonicalSource,
            existingEntries: existing.entries
        )
        var importState = transactionImportState(
            existing: existing,
            context: context
        )
        for row in rows {
            planTransactionImportRow(
                row,
                context: context,
                state: &importState
            )
        }
        guard !importState.importedEntries.isEmpty else {
            return transactionImportResult(
                imported: 0,
                state: importState,
                categoriesCreated: 0
            )
        }
        let plan = try await transactionImportCommitPlan(
            state: importState,
            existingEntries: existing.entries
        )
        let generation = storeGeneration
        await lifecycleHooks.checkpoint(.beforeJournalCommit)
        invalidateCommittedJournalProjection()
        await lifecycleHooks.checkpoint(
            .afterJournalProjectionInvalidationBeforeCommit
        )
        try await plan.store.write(plan.writes)
        guard isCurrentStoreGeneration(generation) else {
            return transactionImportResult(
                imported: 0,
                state: importState,
                categoriesCreated: 0
            )
        }
        applyTransactionImportCommit(plan)
        await refreshJournalAfterMutation()
        return transactionImportResult(
            imported: plan.importedEntries.count,
            state: importState,
            categoriesCreated: plan.newBudgetNodes.count
                + plan.newAccounts.filter { $0.kind == .income }.count
        )
    }
}

extension AppModel {
    func validatedTransactionImportFallbacks(
        accountID: UUID,
        expenseCategoryID: UUID,
        incomeCategoryID: UUID
    ) throws -> LedgerAccount {
        guard let fallbackAccount = userAccounts.first(where: {
            $0.id == accountID && $0.accountType != .restrictedAllowance
        }), expenseCategories.contains(where: {
            $0.id == expenseCategoryID && $0.systemRole == nil
        }), incomeCategories.contains(where: {
            $0.id == incomeCategoryID && $0.systemRole == nil
        }) else { throw AppModelError.missingRecord }
        return fallbackAccount
    }

    func transactionImportExistingJournal()
        async throws -> AppModelTransactionImportExisting {
        if retainsCompleteJournal {
            return AppModelTransactionImportExisting(
                entries: entries,
                fingerprints: Set(entries.compactMap(\.sourceFingerprint))
            )
        }
        // Import is an explicit heavy operation. Fetch one encrypted snapshot
        // for semantic keys and the compact source index so even quarantined
        // valid JSON remains a global fingerprint duplicate.
        let existingEntries = try await journalSnapshot(
            includeInvalidRelationships: true
        )
        let fingerprints = try await requireStore().journalSourceFingerprints()
        return AppModelTransactionImportExisting(
            entries: existingEntries,
            fingerprints: fingerprints
        )
    }

    func transactionImportContext(
        fallbackAccount: LedgerAccount,
        fallbackExpenseCategoryID: UUID,
        fallbackIncomeCategoryID: UUID,
        accountMappings: [String: UUID],
        expenseCategoryMappings: [String: UUID],
        incomeCategoryMappings: [String: UUID],
        sourceSystem: String,
        canonicalSource: String,
        existingEntries: [JournalEntry]
    ) -> AppModelTransactionImportContext {
        let sameSourceLegacyFingerprints = Set(
            existingEntries.compactMap { entry -> String? in
                guard TransactionCSVImporter.canonicalSourceSystem(
                    entry.sourceSystem ?? ""
                ) == canonicalSource else { return nil }
                return entry.sourceFingerprint
            }
        )
        return AppModelTransactionImportContext(
            fallbackAccount: fallbackAccount,
            fallbackExpenseCategoryID: fallbackExpenseCategoryID,
            fallbackIncomeCategoryID: fallbackIncomeCategoryID,
            accountMappings: accountMappings,
            expenseCategoryMappings: expenseCategoryMappings,
            incomeCategoryMappings: incomeCategoryMappings,
            sourceSystem: sourceSystem,
            canonicalSource: canonicalSource,
            sameSourceLegacyFingerprints: sameSourceLegacyFingerprints,
            initialAccountKinds: Dictionary(
                uniqueKeysWithValues: accounts.map { ($0.id, $0.kind) }
            )
        )
    }

    func transactionImportState(
        existing: AppModelTransactionImportExisting,
        context: AppModelTransactionImportContext
    ) -> AppModelTransactionImportState {
        AppModelTransactionImportState(
            candidateAccounts: accounts,
            fingerprints: existing.fingerprints,
            duplicateKeys: Set(existing.entries.compactMap {
                transactionImportDuplicateKey(
                    for: $0,
                    accountKinds: context.initialAccountKinds
                )
            })
        )
    }

    func normalizedTransactionImportName(_ value: String) -> String {
        CSVImportNameResolver.normalizedKey(for: value)
    }

    func transactionImportDuplicateKey(
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
            normalizedTransactionImportName(payee ?? "")
        ]
        return components.map { "\($0.utf8.count):\($0)" }.joined()
    }
}

extension AppModel {
    func transactionImportDuplicateKey(
        for entry: JournalEntry,
        accountKinds: [UUID: LedgerAccountKind]
    ) -> String? {
        let userPosting: Posting?
        let amountPosting: Posting?
        let destinationPosting: Posting?
        let kind: ImportedTransactionKind?
        switch entry.kind {
        case .expense:
            userPosting = entry.postings.first {
                accountKinds[$0.accountID] == .asset
                    || accountKinds[$0.accountID] == .liability
            }
            amountPosting = entry.postings.first {
                accountKinds[$0.accountID] == .expense
            } ?? entry.postings.first { $0.id != userPosting?.id }
            destinationPosting = nil
            kind = (amountPosting?.money.amount ?? .zero) < .zero
                ? .refund : .expense
        case .income:
            userPosting = entry.postings.first {
                accountKinds[$0.accountID] == .asset
                    || accountKinds[$0.accountID] == .liability
            }
            amountPosting = entry.postings.first {
                accountKinds[$0.accountID] == .income
            } ?? entry.postings.first { $0.id != userPosting?.id }
            destinationPosting = nil
            kind = .income
        case .transfer:
            let userPostings = entry.postings.filter {
                accountKinds[$0.accountID] == .asset
                    || accountKinds[$0.accountID] == .liability
            }
            let sourcePostings = userPostings.filter {
                $0.money.amount < .zero
            }
            let destinationPostings = userPostings.filter {
                $0.money.amount > .zero
            }
            guard sourcePostings.count == 1,
                  destinationPostings.count == 1 else { return nil }
            userPosting = sourcePostings[0]
            amountPosting = userPosting
            destinationPosting = destinationPostings[0]
            kind = .transfer
        case .adjustment, .investment:
            return nil
        }
        guard let userPosting, let amountPosting, let kind else { return nil }
        if kind == .transfer, destinationPosting == nil { return nil }
        return transactionImportDuplicateKey(
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
}

extension AppModel {
    func isEligibleTransactionImportAccount(
        _ account: LedgerAccount,
        currency: CurrencyCode?
    ) -> Bool {
        (account.kind == .asset || account.kind == .liability)
            && account.systemRole == nil
            && !account.isArchived
            && account.accountType != .restrictedAllowance
            && (currency == nil || account.currency == currency)
    }

    func isEligibleTransactionImportCategory(
        _ account: LedgerAccount,
        kind: LedgerAccountKind
    ) -> Bool {
        account.kind == kind
            && account.systemRole == nil
            && !account.isArchived
    }

    func transactionImportAccount(
        named name: String?,
        currency: CurrencyCode?,
        context: AppModelTransactionImportContext,
        state: AppModelTransactionImportState
    ) -> LedgerAccount? {
        guard let name else { return nil }
        let normalized = normalizedTransactionImportName(name)
        if let mappedID = context.accountMappings[normalized],
           let mapped = state.candidateAccounts.first(where: {
               $0.id == mappedID
                   && isEligibleTransactionImportAccount($0, currency: currency)
           }) {
            return mapped
        }
        return state.candidateAccounts.first {
            isEligibleTransactionImportAccount($0, currency: currency)
                && normalizedTransactionImportName($0.name) == normalized
        }
    }

    func transactionImportCategory(
        named name: String?,
        kind: LedgerAccountKind,
        fallbackID: UUID,
        context: AppModelTransactionImportContext,
        state: inout AppModelTransactionImportState
    ) -> LedgerAccount? {
        guard let name,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return state.candidateAccounts.first {
                $0.id == fallbackID
                    && isEligibleTransactionImportCategory($0, kind: kind)
            }
        }
        let normalized = normalizedTransactionImportName(name)
        let reviewedMappings = kind == .income
            ? context.incomeCategoryMappings
            : context.expenseCategoryMappings
        if let mappedID = reviewedMappings[normalized],
           let mapped = state.candidateAccounts.first(where: {
               $0.id == mappedID
                   && isEligibleTransactionImportCategory($0, kind: kind)
           }) {
            return mapped
        }
        if let existing = state.candidateAccounts.first(where: {
            isEligibleTransactionImportCategory($0, kind: kind)
                && normalizedTransactionImportName($0.name) == normalized
        }) {
            return existing
        }
        let created = LedgerAccount(name: name, kind: kind)
        state.candidateAccounts.append(created)
        state.newAccounts.append(created)
        if kind == .expense {
            state.newBudgetNodes.append(
                BudgetNode(id: created.id, name: created.name)
            )
        }
        return created
    }

    func transactionImportForeignExchangeAccount(
        for currency: CurrencyCode,
        state: AppModelTransactionImportState
    ) -> LedgerAccount {
        state.candidateAccounts.first {
            $0.systemRole == .foreignExchange && $0.currency == currency
        } ?? LedgerAccount(
            name: "\(AppLocalization.string("account.fx_clearing")) \(currency.value)",
            kind: .trading,
            currency: currency,
            systemRole: .foreignExchange
        )
    }
}

extension AppModel {
    func planTransactionImportRow(
        _ row: ImportedTransaction,
        context: AppModelTransactionImportContext,
        state: inout AppModelTransactionImportState
    ) {
        guard let identity = acceptTransactionImportIdentity(
            row,
            context: context,
            state: &state
        ), let semantics = resolveTransactionImportSemantics(
            row,
            identity: identity,
            context: context,
            state: &state
        ) else { return }
        let accountCheckpoint = state.candidateAccounts.count
        let newAccountCheckpoint = state.newAccounts.count
        let budgetCheckpoint = state.newBudgetNodes.count
        do {
            let baseEntry = try transactionImportBaseEntry(
                row,
                semantics: semantics,
                context: context,
                state: &state
            )
            try rejectRestrictedAllowanceDebit(in: baseEntry)
            state.importedEntries.append(
                try JournalEntry(
                    kind: baseEntry.kind,
                    occurredAt: baseEntry.occurredAt,
                    createdAt: baseEntry.createdAt,
                    payee: baseEntry.payee,
                    note: baseEntry.note,
                    postings: baseEntry.postings,
                    sourceSystem: context.sourceSystem,
                    sourceFingerprint: identity.persistedFingerprint,
                    originContext: row.originContext
                        ?? reportingOriginContext(for: baseEntry.occurredAt)
                )
            )
        } catch {
            state.candidateAccounts.removeSubrange(accountCheckpoint...)
            state.newAccounts.removeSubrange(newAccountCheckpoint...)
            state.newBudgetNodes.removeSubrange(budgetCheckpoint...)
            state.fingerprints.remove(identity.persistedFingerprint)
            if semantics.insertedDuplicateKey {
                state.duplicateKeys.remove(semantics.duplicateKey)
            }
            state.skipped += 1
        }
    }

    func acceptTransactionImportIdentity(
        _ row: ImportedTransaction,
        context: AppModelTransactionImportContext,
        state: inout AppModelTransactionImportState
    ) -> AppModelTransactionImportIdentity? {
        let persistedFingerprint = TransactionCSVImporter.persistenceFingerprint(
            for: row.id,
            sourceSystem: context.sourceSystem
        )
        let inserted = state.fingerprints.insert(persistedFingerprint).inserted
        let matchesUnscopedIdentity = context.sameSourceLegacyFingerprints
            .contains(row.id)
        let matchesLegacyCandidate = !row.legacyFingerprintCandidates
            .isDisjoint(with: context.sameSourceLegacyFingerprints)
        guard inserted, !matchesUnscopedIdentity else {
            if inserted { state.fingerprints.remove(persistedFingerprint) }
            state.duplicates += 1
            return nil
        }
        return AppModelTransactionImportIdentity(
            persistedFingerprint: persistedFingerprint,
            matchesLegacyCandidate: matchesLegacyCandidate
        )
    }

    func resolveTransactionImportSemantics(
        _ row: ImportedTransaction,
        identity: AppModelTransactionImportIdentity,
        context: AppModelTransactionImportContext,
        state: inout AppModelTransactionImportState
    ) -> AppModelTransactionImportSemantics? {
        let declaredCurrency = row.currencyCode.flatMap { try? CurrencyCode($0) }
        guard row.currencyCode == nil || declaredCurrency != nil else {
            skipTransactionImportIdentity(identity, state: &state)
            return nil
        }
        let source = transactionImportAccount(
            named: row.accountName,
            currency: declaredCurrency,
            context: context,
            state: state
        ) ?? (declaredCurrency == nil
            || declaredCurrency == context.fallbackAccount.currency
            ? context.fallbackAccount : nil)
        guard let source,
              let sourceCurrency = source.currency,
              MonetaryInputPolicy.accepts(
                  row.amount,
                  currency: sourceCurrency
              ),
              let transfer = transactionImportTransferDestination(
                  row,
                  source: source,
                  sourceCurrency: sourceCurrency,
                  context: context,
                  state: state
              ) else {
            skipTransactionImportIdentity(identity, state: &state)
            return nil
        }
        return acceptedTransactionImportSemantics(
            row,
            identity: identity,
            source: source,
            sourceCurrency: sourceCurrency,
            destination: transfer.destination,
            destinationAmount: transfer.amount,
            state: &state
        )
    }

    func skipTransactionImportIdentity(
        _ identity: AppModelTransactionImportIdentity,
        state: inout AppModelTransactionImportState
    ) {
        state.fingerprints.remove(identity.persistedFingerprint)
        state.skipped += 1
    }
}

extension AppModel {
    func transactionImportTransferDestination(
        _ row: ImportedTransaction,
        source: LedgerAccount,
        sourceCurrency: CurrencyCode,
        context: AppModelTransactionImportContext,
        state: AppModelTransactionImportState
    ) -> (destination: LedgerAccount?, amount: Decimal?)? {
        guard row.kind == .transfer else { return (nil, nil) }
        guard let destination = transactionImportAccount(
            named: row.destinationAccountName,
            currency: nil,
            context: context,
            state: state
        ), destination.id != source.id,
        let destinationCurrency = destination.currency else { return nil }
        let destinationAmount: Decimal? = sourceCurrency == destinationCurrency
            ? row.amount
            : row.destinationAmount
        guard let destinationAmount,
              MonetaryInputPolicy.accepts(
                  destinationAmount,
                  currency: destinationCurrency
              ) else { return nil }
        return (destination, destinationAmount)
    }

    func acceptedTransactionImportSemantics(
        _ row: ImportedTransaction,
        identity: AppModelTransactionImportIdentity,
        source: LedgerAccount,
        sourceCurrency: CurrencyCode,
        destination: LedgerAccount?,
        destinationAmount: Decimal?,
        state: inout AppModelTransactionImportState
    ) -> AppModelTransactionImportSemantics? {
        let duplicateKey = transactionImportDuplicateKey(
            kind: row.kind,
            occurredAt: row.occurredAt,
            amount: row.amount,
            currency: sourceCurrency,
            sourceID: source.id,
            destinationID: destination?.id,
            destinationAmount: destinationAmount,
            destinationCurrency: destination?.currency,
            // Every entry kind now persists its optional title/payee, so the
            // in-batch key must match the key reconstructed after reopening.
            payee: row.payee
        )
        let insertedDuplicateKey = state.duplicateKeys.insert(duplicateKey)
            .inserted
        // FNV-era candidates are collision-prone and interim SHA candidates
        // contain mutable fields. Accept a legacy duplicate only when the
        // reconstructed ledger semantics also match.
        let matchesSafeLegacyDuplicate = identity.matchesLegacyCandidate
            && !insertedDuplicateKey
        guard !matchesSafeLegacyDuplicate,
              row.hasExternalID || insertedDuplicateKey else {
            state.fingerprints.remove(identity.persistedFingerprint)
            state.duplicates += 1
            return nil
        }
        return AppModelTransactionImportSemantics(
            source: source,
            sourceCurrency: sourceCurrency,
            destination: destination,
            destinationAmount: destinationAmount,
            duplicateKey: duplicateKey,
            insertedDuplicateKey: insertedDuplicateKey
        )
    }
}

extension AppModel {
    func transactionImportBaseEntry(
        _ row: ImportedTransaction,
        semantics: AppModelTransactionImportSemantics,
        context: AppModelTransactionImportContext,
        state: inout AppModelTransactionImportState
    ) throws -> JournalEntry {
        switch row.kind {
        case .expense:
            return try transactionImportExpenseEntry(
                row,
                semantics: semantics,
                context: context,
                state: &state
            )
        case .income:
            return try transactionImportIncomeEntry(
                row,
                semantics: semantics,
                context: context,
                state: &state
            )
        case .refund:
            return try transactionImportRefundEntry(
                row,
                semantics: semantics,
                context: context,
                state: &state
            )
        case .transfer:
            return try transactionImportTransferEntry(
                row,
                semantics: semantics,
                state: &state
            )
        }
    }

    func transactionImportExpenseEntry(
        _ row: ImportedTransaction,
        semantics: AppModelTransactionImportSemantics,
        context: AppModelTransactionImportContext,
        state: inout AppModelTransactionImportState
    ) throws -> JournalEntry {
        guard let category = transactionImportCategory(
            named: row.categoryName,
            kind: .expense,
            fallbackID: context.fallbackExpenseCategoryID,
            context: context,
            state: &state
        ) else { throw AppModelError.missingRecord }
        return try TransactionFactory.expense(
            amount: try Money(row.amount, currency: semantics.sourceCurrency),
            paidFrom: semantics.source.id,
            category: category.id,
            occurredAt: row.occurredAt,
            payee: row.payee,
            note: row.note
        )
    }

    func transactionImportIncomeEntry(
        _ row: ImportedTransaction,
        semantics: AppModelTransactionImportSemantics,
        context: AppModelTransactionImportContext,
        state: inout AppModelTransactionImportState
    ) throws -> JournalEntry {
        guard let category = transactionImportCategory(
            named: row.categoryName,
            kind: .income,
            fallbackID: context.fallbackIncomeCategoryID,
            context: context,
            state: &state
        ) else { throw AppModelError.missingRecord }
        return try TransactionFactory.income(
            amount: try Money(row.amount, currency: semantics.sourceCurrency),
            depositedInto: semantics.source.id,
            category: category.id,
            occurredAt: row.occurredAt,
            payee: row.payee,
            note: row.note
        )
    }

    func transactionImportRefundEntry(
        _ row: ImportedTransaction,
        semantics: AppModelTransactionImportSemantics,
        context: AppModelTransactionImportContext,
        state: inout AppModelTransactionImportState
    ) throws -> JournalEntry {
        guard let category = transactionImportCategory(
            named: row.categoryName,
            kind: .expense,
            fallbackID: context.fallbackExpenseCategoryID,
            context: context,
            state: &state
        ) else { throw AppModelError.missingRecord }
        return try TransactionFactory.refund(
            amount: try Money(row.amount, currency: semantics.sourceCurrency),
            returnedTo: semantics.source.id,
            category: category.id,
            occurredAt: row.occurredAt,
            payee: row.payee,
            note: row.note
        )
    }
}

extension AppModel {
    func transactionImportTransferEntry(
        _ row: ImportedTransaction,
        semantics: AppModelTransactionImportSemantics,
        state: inout AppModelTransactionImportState
    ) throws -> JournalEntry {
        guard let destination = semantics.destination,
              let destinationCurrency = destination.currency else {
            throw AppModelError.missingRecord
        }
        if semantics.sourceCurrency == destinationCurrency {
            return try TransactionFactory.transfer(
                amount: try Money(
                    row.amount,
                    currency: semantics.sourceCurrency
                ),
                from: semantics.source.id,
                to: destination.id,
                occurredAt: row.occurredAt,
                payee: row.payee,
                note: row.note
            )
        }
        guard let destinationAmount = semantics.destinationAmount else {
            throw AppModelError.foreignCurrencyTransferRequiresExchangeRate
        }
        let sourceTrading = transactionImportForeignExchangeAccount(
            for: semantics.sourceCurrency,
            state: state
        )
        let destinationTrading = transactionImportForeignExchangeAccount(
            for: destinationCurrency,
            state: state
        )
        for trading in [sourceTrading, destinationTrading]
        where !state.candidateAccounts.contains(where: { $0.id == trading.id }) {
            state.candidateAccounts.append(trading)
            state.newAccounts.append(trading)
        }
        return try TransactionFactory.foreignCurrencyTransfer(
            sourceAmount: try Money(
                row.amount,
                currency: semantics.sourceCurrency
            ),
            destinationAmount: try Money(
                destinationAmount,
                currency: destinationCurrency
            ),
            from: semantics.source.id,
            to: destination.id,
            sourceTradingAccountID: sourceTrading.id,
            destinationTradingAccountID: destinationTrading.id,
            occurredAt: row.occurredAt,
            payee: row.payee,
            note: row.note
        )
    }
}

extension AppModel {
    func transactionImportBudgetPlan(
        state: AppModelTransactionImportState
    ) throws -> AppModelTransactionImportBudgetPlan {
        let candidateNodes = budgetNodes + state.newBudgetNodes
        if let currency = profile?.baseCurrency {
            _ = try BudgetTree(currency: currency, nodes: candidateNodes)
        }
        let recordedTimeline: BudgetConfigurationTimeline?
        if state.newBudgetNodes.isEmpty {
            recordedTimeline = nil
        } else {
            recordedTimeline = try budgetConfigurationTimelineRecording(
                nodes: candidateNodes
            )
        }
        let reportingZone = profile?.reportingTimeZoneIdentifier
            ?? reportingCalendar.timeZone.identifier
        let attributions = try state.importedEntries.map {
            try BudgetEntryAttribution(
                entry: $0,
                originTimeZoneIdentifier: reportingZone
            )
        }
        return AppModelTransactionImportBudgetPlan(
            candidateNodes: candidateNodes,
            recordedTimeline: recordedTimeline,
            attributions: attributions
        )
    }

    func transactionImportCommitPlan(
        state: AppModelTransactionImportState,
        existingEntries: [JournalEntry]
    ) async throws -> AppModelTransactionImportCommitPlan {
        let budgetPlan = try transactionImportBudgetPlan(state: state)
        let importStore = try requireStore()
        try await loadCompleteBudgetAttributionCacheIfNeeded(from: importStore)
        var candidateEntries = existingEntries + state.importedEntries
        candidateEntries.sort {
            if $0.occurredAt == $1.occurredAt {
                return $0.createdAt > $1.createdAt
            }
            return $0.occurredAt > $1.occurredAt
        }
        var candidateAttributions = budgetEntryAttributions
        for attribution in budgetPlan.attributions {
            candidateAttributions[attribution.id] = attribution
        }
        let affectedMonths = try state.importedEntries.compactMap { entry in
            try budgetAffectedMonth(
                for: entry,
                attribution: candidateAttributions[entry.id],
                timeline: budgetPlan.recordedTimeline
            )
        }
        let recomputedTimeline = try budgetTimelineAfterJournalMutation(
            timeline: budgetPlan.recordedTimeline,
            journalEntries: candidateEntries,
            attributions: candidateAttributions,
            affectedReportingMonths: affectedMonths
        )
        let candidateTimeline = recomputedTimeline
            ?? budgetPlan.recordedTimeline
        let writes = try transactionImportWrites(
            state: state,
            budgetPlan: budgetPlan,
            candidateTimeline: candidateTimeline
        )
        return AppModelTransactionImportCommitPlan(
            store: importStore,
            writes: writes,
            newAccounts: state.newAccounts,
            newBudgetNodes: state.newBudgetNodes,
            importedEntries: state.importedEntries,
            candidateBudgetNodes: budgetPlan.candidateNodes,
            candidateTimeline: candidateTimeline,
            candidateAttributions: candidateAttributions,
            candidateEntries: candidateEntries
        )
    }
}

extension AppModel {
    func transactionImportWrites(
        state: AppModelTransactionImportState,
        budgetPlan: AppModelTransactionImportBudgetPlan,
        candidateTimeline: BudgetConfigurationTimeline?
    ) throws -> [RecordWrite] {
        var writes = try state.newAccounts.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .accounts)
        }
        writes += try state.newBudgetNodes.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .budgetNodes)
        }
        writes += try state.importedEntries.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .journalEntries)
        }
        writes += try budgetPlan.attributions.map {
            try RecordWrite(
                $0,
                id: $0.id.uuidString,
                in: .budgetEntryAttributions
            )
        }
        if let candidateTimeline {
            writes.append(try budgetConfigurationTimelineWrite(candidateTimeline))
        }
        return writes
    }

    func applyTransactionImportCommit(
        _ plan: AppModelTransactionImportCommitPlan
    ) {
        accounts.append(contentsOf: plan.newAccounts)
        if let candidateTimeline = plan.candidateTimeline {
            budgetConfigurationTimeline = candidateTimeline
        }
        budgetEntryAttributions = plan.candidateAttributions
        budgetNodes = plan.candidateBudgetNodes
        if retainsCompleteJournal { entries = plan.candidateEntries }
    }

    func transactionImportResult(
        imported: Int,
        state: AppModelTransactionImportState,
        categoriesCreated: Int
    ) -> TransactionImportResult {
        TransactionImportResult(
            imported: imported,
            duplicates: state.duplicates,
            skipped: state.skipped,
            categoriesCreated: categoriesCreated
        )
    }
}
