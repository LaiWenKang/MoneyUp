import Foundation
import MoneyUpCore
import MoneyUpPersistence
import Observation
import SwiftUI
import UIKit
import WidgetKit

extension AppModel {
    func csvExport() async throws -> String {
        try beginJournalMutation(invalidatesJournalProjection: false)
        defer { endJournalMutation() }
        let exportEntries: [JournalEntry]
        if retainsCompleteJournal {
            exportEntries = entries
        } else {
            exportEntries = try await journalSnapshot(
                includeInvalidRelationships: false
            )
        }
        return LedgerCSVExporter.export(
            exportEntries.sorted { $0.occurredAt < $1.occurredAt },
            accounts: accounts
        )
    }

    func xlsxExport() async throws -> Data {
        try beginJournalMutation(invalidatesJournalProjection: false)
        defer { endJournalMutation() }
        let exportEntries: [JournalEntry]
        if retainsCompleteJournal {
            exportEntries = entries
        } else {
            exportEntries = try await journalSnapshot(
                includeInvalidRelationships: false
            )
        }
        return LedgerXLSXExporter.export(
            entries: exportEntries,
            accounts: accounts,
            rates: exchangeRates,
            attachmentMetadata: receiptAttachmentMetadata
        )
    }

    /// Produces a coherent, metadata-only manifest for upgrade and restore drills.
    /// The exclusive lifecycle guard prevents a write from crossing the single
    /// payload-free count snapshot used by the inventory.
    func privacySafeDataInventory(
        generatedAt: Date? = nil,
        appVersion: String = AppVersion.marketing,
        buildNumber: String = AppVersion.build
    ) async throws -> PrivacySafeDataInventory {
        guard state == .ready else { throw AppModelError.locked }
        try beginLifecycleMutation(invalidatesJournalProjection: false)
        isWorking = true
        defer {
            isWorking = false
            endLifecycleMutation()
        }

        await finishPendingQuickLogDraftWrite()
        try Task.checkCancellation()
        let inventoryStore = try requireStore()
        let snapshot = try await inventoryStore.recordCountSnapshot()
        try Task.checkCancellation()
        let pendingLockedCaptures = try await lockedCaptureStore.all()
        let currentPendingLockedCaptureCount = pendingLockedCaptures.count
        pendingLockedCaptureCount = currentPendingLockedCaptureCount
        try Task.checkCancellation()
        return PrivacySafeDataInventory(
            snapshot: snapshot,
            investmentHoldings: investmentHoldings,
            savingsGoals: savingsGoals,
            generatedAt: generatedAt,
            appVersion: appVersion,
            buildNumber: buildNumber,
            pendingLockedCaptureCount: currentPendingLockedCaptureCount,
            quarantinedRecordCount: recoveryIssueCount,
            budgetStatusWidgetEnabled: profile?.showsBudgetStatusWidget ?? false
        )
    }

    /// Resolves a parsed CSV preview against the current book, then commits
    /// every new category, FX helper, and journal entry together. A failure
    /// therefore imports either all accepted rows or none of them.
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

    func encryptedBackup(password: String) async throws -> Data {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MoneyUp-Backup-\(UUID().uuidString).moneyup",
                isDirectory: false
            )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try await encryptedBackup(to: temporaryURL, password: password)
        return try Data(contentsOf: temporaryURL)
    }

    /// Production backup entry point. The returned artifact stays file-backed
    /// from the SQL cursor through SwiftUI's export handoff.
    func encryptedBackup(
        to destinationURL: URL,
        password: String
    ) async throws {
        try beginLifecycleMutation(invalidatesJournalProjection: false)
        isWorking = true
        defer {
            isWorking = false
            endLifecycleMutation()
        }

        // A portable archive contains the SQLCipher snapshot but not the
        // separately encrypted, book-agnostic locked-capture inbox. Refuse to
        // label an incomplete recovery point as ready.
        let backupStore = try requireStore()
        try await flushQuickLogDraftForBackup(to: backupStore)
        try await requireEmptyLockedCaptureInbox()
        try Task.checkCancellation()
        let metrics = try await backupStore.storageMetrics()
        guard metrics.recordCount
                <= RestoreCandidateValidator.maximumCandidateRecordCount,
              metrics.payloadByteCount
                <= RestoreCandidateValidator.maximumBackupStoredPayloadByteCount,
              metrics.recordIDByteCount
                <= RestoreCandidateValidator.maximumAggregateRecordIDByteCount,
              metrics.collectionByteCount
                <= RestoreCandidateValidator.maximumAggregateCollectionByteCount else {
            throw PortableArchiveError.archiveTooLarge
        }
        try Task.checkCancellation()
        try await backupStore.exportPortableArchive(
            to: destinationURL,
            password: password
        )
    }

    /// Restores only after the candidate has passed the exact encrypted-store
    /// and domain load used by the app in an isolated temporary database.
    /// Cancellation and deterministic lifecycle interruption remain entirely
    /// before the one live replacement transaction.
    func restoreEncryptedBackup(_ data: Data, password: String) async throws {
        guard PortableArchive.isWithinArchiveByteLimit(data.count) else {
            throw PortableArchiveError.archiveTooLarge
        }
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MoneyUp-Imported-\(UUID().uuidString).moneyup",
                isDirectory: false
            )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL, options: [.atomic])
        try await restoreEncryptedBackup(
            from: temporaryURL,
            password: password
        )
    }

    func restoreEncryptedBackup(
        from archiveURL: URL,
        password: String
    ) async throws {
        guard !isWorking,
              !isLifecycleMutationInProgress,
              !goalMutationBarrierClosed,
              !isJournalMutationInProgress else {
            throw AppModelError.transactionInProgress
        }
        isWorking = true
        goalMutationBarrierClosed = true
        await waitForGoalMutationDrain()
        isLifecycleMutationInProgress = true
        invalidateInFlightJournalProjection()
        defer { finishExclusiveDataLifecycleMutation() }

        // A cancelled debounce can already be inside its store operation.
        // Drain it before taking the rollback snapshot so no pre-restore draft
        // can wake and overwrite the restored logical book afterward.
        await finishPendingQuickLogDraftWrite()
        let restoreStore = try requireStore()
        // A wrong password, malformed archive, or failed candidate validation
        // leaves the old book authoritative. Persist the newest in-memory form
        // before parsing untrusted input so cancelling its debounce cannot turn
        // a harmless failed restore into later power-loss data loss.
        try await flushQuickLogDraftForBackup(to: restoreStore)

        // The redacted inbox is outside the portable archive and has no book
        // identity. Keeping it across replacement could apply old-book input
        // to the restored book; dropping it would lose user input.
        try await requireEmptyLockedCaptureInbox()
        do {
            try Self.removeRestoreValidationDirectory(
                restoreValidationDirectoryURL
            )
            try Self.removeLegacyRestoreValidationDirectories()
        } catch {
            throw AppModelError.invalidBook
        }
        try Task.checkCancellation()

        let generation = storeGeneration
        let stateBeforeRestore = state
        try await validateRestoreCandidateInIsolation(
            from: archiveURL,
            password: password
        )
        try Task.checkCancellation()

        let rollbackURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MoneyUp-Rollback-\(UUID().uuidString).moneyup",
                isDirectory: false
            )
        let rollbackPassword = UUID().uuidString + UUID().uuidString
        defer { try? FileManager.default.removeItem(at: rollbackURL) }
        try await restoreStore.exportPortableArchive(
            to: rollbackURL,
            password: rollbackPassword
        )
        guard ownsStoreGeneration(generation) else { throw AppModelError.locked }

        await lifecycleHooks.checkpoint(.beforeRestoreCommit)
        try Task.checkCancellation()
        guard ownsStoreGeneration(generation) else { throw AppModelError.locked }

        let retainedEntriesBeforeRestore = retainsCompleteJournal ? entries : nil
        var liveStoreWasReplaced = false
        // The actor can finish its replacement transaction while this main-
        // actor task is suspended. Make every old-book derived value and
        // destructive reference decision fail closed before that handoff.
        invalidateCommittedJournalProjection(invalidateRecentEntries: true)
        await lifecycleHooks.checkpoint(
            .afterJournalProjectionInvalidationBeforeCommit
        )
        do {
            try await restoreStore.restorePortableArchive(
                from: archiveURL,
                password: password
            )
            liveStoreWasReplaced = true
            await lifecycleHooks.checkpoint(
                .afterRestoreCommitBeforeCandidateLoad
            )
            try Task.checkCancellation()
            guard ownsStoreGeneration(generation) else {
                throw AppModelError.locked
            }
            try await load(from: restoreStore, mode: .restoreValidation)
            try Task.checkCancellation()
            guard ownsStoreGeneration(generation) else {
                throw AppModelError.locked
            }
            guard profile != nil else { throw AppModelError.invalidBook }
            try validateLoadedBook()
            try await RestoreCandidateValidator.validateRelationships(
                profile: profile,
                accounts: accounts,
                budgetNodes: budgetNodes,
                scheduledTransactions: scheduledTransactions,
                investmentHoldings: investmentHoldings,
                netWorthSnapshots: netWorthSnapshots,
                quickLogDraft: quickLogDraft,
                in: restoreStore
            )
            if let profile {
                UserDefaults.standard.set(
                    profile.allowLockedQuickCapture,
                    forKey: Self.lockedQuickCapturePreferenceKey
                )
            }
            state = .ready
        } catch {
            if case PersistenceError.restoreTransactionStateIndeterminate = error {
                // A failed SQLite rollback means neither the old nor candidate
                // state may be trusted. Force the same authoritative recovery
                // used after a committed candidate before republishing data.
                liveStoreWasReplaced = true
            }
            guard liveStoreWasReplaced else {
                // A failed/rolled-back store replacement leaves the old durable
                // book intact. Restore the deliberately cleared complete test/
                // preview journal so the normal idle-end republish cannot mark
                // a false empty cache as current.
                if let retainedEntriesBeforeRestore {
                    entries = retainedEntriesBeforeRestore
                }
                throw error
            }
            do {
                // `Task.init` creates a fresh unstructured task, so cancellation
                // of the failed restore is not inherited. Recovery must remain
                // uncancelled through both index rebuilding and domain decode:
                // those paths deliberately observe their current task's state.
                let rollbackRecoveryTask = Task { @MainActor [self] in
                    guard ownsStoreGeneration(generation) else {
                        throw AppModelError.locked
                    }
                    // Candidate loading may have partially assigned decoded
                    // state. Keep every projection unavailable across the
                    // rollback transaction; `load` republishes only a coherent
                    // book.
                    invalidateCommittedJournalProjection(
                        invalidateRecentEntries: true
                    )
                    try await restoreStore.restorePortableArchive(
                        from: rollbackURL,
                        password: rollbackPassword,
                        observesCancellation: false
                    )
                    guard ownsStoreGeneration(generation) else {
                        throw AppModelError.locked
                    }
                    try await load(from: restoreStore, mode: .rollbackRecovery)
                    guard ownsStoreGeneration(generation) else {
                        throw AppModelError.locked
                    }
                    if profile != nil { try validateLoadedBook() }
                }
                try await rollbackRecoveryTask.value
                guard ownsStoreGeneration(generation) else {
                    throw AppModelError.locked
                }
                state = stateBeforeRestore
            } catch {
                clearDecodedState()
                state = .failed(
                    AppModelError.restoreRecoveryFailed.localizedDescription
                )
                throw AppModelError.restoreRecoveryFailed
            }
            throw error
        }
    }

    /// A restore candidate is never trial-applied to the live database. The
    /// temporary key exists only long enough to open a disposable SQLCipher
    /// file and is explicitly overwritten on every exit path.
    func validateRestoreCandidateInIsolation(
        from archiveURL: URL,
        password: String
    ) async throws {
        try Task.checkCancellation()
        let directoryURL = restoreValidationDirectoryURL
        let databaseURL = directoryURL.appendingPathComponent(
            "candidate.sqlite3",
            isDirectory: false
        )
        do {
            // Reuse one exact owned directory. A crash can leave it behind,
            // but the next validation removes it before any untrusted row is
            // copied, preventing unbounded UUID-directory accumulation.
            try Self.removeRestoreValidationDirectory(directoryURL)
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw AppModelError.invalidBook
        }
        var validationKey = Self.temporaryRestoreValidationKey()
        defer { validationKey.resetBytes(in: 0..<validationKey.count) }

        let validationStore: EncryptedRecordStore
        do {
            validationStore = try EncryptedRecordStore(
                databaseURL: databaseURL,
                key: validationKey
            )
        } catch {
            let creationFailure = error
            do {
                try Self.removeRestoreValidationDirectory(directoryURL)
            } catch {
                throw AppModelError.invalidBook
            }
            throw creationFailure
        }
        validationKey.resetBytes(in: 0..<validationKey.count)

        var validationFailure: (any Error)?
        do {
            try await validationStore.restorePortableArchive(
                from: archiveURL,
                password: password
            )
            try Task.checkCancellation()

            let metrics = try await validationStore.storageMetrics()
            guard metrics.recordCount
                    <= RestoreCandidateValidator.maximumCandidateRecordCount,
                  metrics.payloadByteCount
                    <= RestoreCandidateValidator
                        .maximumBackupStoredPayloadByteCount,
                  metrics.recordIDByteCount
                    <= RestoreCandidateValidator
                        .maximumAggregateRecordIDByteCount,
                  metrics.collectionByteCount
                    <= RestoreCandidateValidator
                        .maximumAggregateCollectionByteCount else {
                throw AppModelError.invalidBook
            }

            let validationModel = AppModel(
                restoreValidationStore: validationStore,
                lockedCaptureStore: lockedCaptureStore,
                receiptRecognizer: receiptRecognizer
            )
            try await validationModel.load(
                from: validationStore,
                mode: .restoreValidation
            )
            guard validationModel.profile != nil else {
                throw AppModelError.invalidBook
            }
            try validationModel.validateLoadedBook()
            try await RestoreCandidateValidator.validateRelationships(
                profile: validationModel.profile,
                accounts: validationModel.accounts,
                budgetNodes: validationModel.budgetNodes,
                scheduledTransactions: validationModel.scheduledTransactions,
                investmentHoldings: validationModel.investmentHoldings,
                netWorthSnapshots: validationModel.netWorthSnapshots,
                quickLogDraft: validationModel.quickLogDraft,
                in: validationStore
            )
            try Task.checkCancellation()
        } catch {
            validationFailure = error
        }

        await validationStore.close()
        do {
            try Self.removeRestoreValidationDirectory(directoryURL)
        } catch {
            // A disposable plaintext path must not be left behind even though
            // its contents are encrypted. Treat cleanup failure as a failed
            // validation and keep the live book untouched.
            validationFailure = AppModelError.invalidBook
        }
        if let validationFailure { throw validationFailure }
    }

    static func temporaryRestoreValidationKey() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        })
    }

    var restoreValidationDirectoryURL: URL {
        // Dependency-injected test/preview models share the host temporary
        // directory, so isolate them by their already-unique database parent.
        // Production has no injected URL and always uses the single `primary`
        // location scavenged by `start()` and before every restore.
        let discriminator = databaseURLForErase?
            .deletingLastPathComponent()
            .lastPathComponent ?? "primary"
        return FileManager.default.temporaryDirectory.appendingPathComponent(
            "MoneyUp-RestoreValidation-\(discriminator)",
            isDirectory: true
        )
    }

    static func removeRestoreValidationDirectory(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    static func removeLegacyRestoreValidationDirectories() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let prefix = "MoneyUp-RestoreValidation-"
        let children = try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for child in children {
            let name = child.lastPathComponent
            guard name.hasPrefix(prefix) else { continue }
            let suffix = String(name.dropFirst(prefix.count))
            // Old builds used UUID.uuidString verbatim. Restrict cleanup to
            // that exact canonical shape so no unrelated temporary directory
            // sharing the human-readable prefix can ever be removed.
            guard let id = UUID(uuidString: suffix),
                  id.uuidString == suffix,
                  try child.resourceValues(forKeys: [.isDirectoryKey])
                      .isDirectory == true else {
                continue
            }
            try FileManager.default.removeItem(at: child)
        }
    }
}
