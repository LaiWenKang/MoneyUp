import Foundation
import MoneyUpCore
import MoneyUpPersistence

/// Strict, side-effect-free checks used only after an archive has been loaded
/// into a disposable encrypted store. Normal unlock recovery remains tolerant
/// so one damaged row cannot hide the rest of a readable book.
enum RestoreCandidateValidator {
    static func validateSnapshotIdentities(
        _ snapshot: DatabaseSnapshot
    ) throws {
        let decoder = JSONDecoder()
        var logicalIDsByCollection: [String: Set<UUID>] = [:]
        var exchangeRatePairDays = Set<String>()

        do {
            for record in snapshot.records {
                guard let collection = RecordCollection(
                    rawValue: record.collection
                ) else {
                    throw AppModelError.invalidBook
                }

                let logicalID: UUID?
                switch collection {
                case .profile:
                    guard record.recordID == UserProfile.primaryRecordID else {
                        throw AppModelError.invalidBook
                    }
                    _ = try decoder.decode(UserProfile.self, from: record.payload)
                    logicalID = nil
                case .accounts:
                    logicalID = try decoder.decode(
                        LedgerAccount.self,
                        from: record.payload
                    ).id
                case .journalEntries:
                    logicalID = try decoder.decode(
                        JournalEntry.self,
                        from: record.payload
                    ).id
                case .journalEntryRevisions:
                    let entry = try decoder.decode(
                        JournalEntry.self,
                        from: record.payload
                    )
                    guard isValidJournalRevisionRecordID(
                        record.recordID,
                        entryID: entry.id
                    ) else {
                        throw AppModelError.invalidBook
                    }
                    logicalID = nil
                case .budgetNodes:
                    logicalID = try decoder.decode(
                        BudgetNode.self,
                        from: record.payload
                    ).id
                case .scheduledTransactions:
                    logicalID = try decoder.decode(
                        ScheduledTransaction.self,
                        from: record.payload
                    ).id
                case .investmentHoldings:
                    logicalID = try decoder.decode(
                        InvestmentHolding.self,
                        from: record.payload
                    ).id
                case .netWorthSnapshots:
                    logicalID = try decoder.decode(
                        NetWorthSnapshot.self,
                        from: record.payload
                    ).id
                case .quickLogDrafts:
                    guard record.recordID == QuickLogDraft.primaryRecordID else {
                        throw AppModelError.invalidBook
                    }
                    _ = try decoder.decode(QuickLogDraft.self, from: record.payload)
                    logicalID = nil
                case .accountLifecycleAudit:
                    logicalID = try decoder.decode(
                        LedgerAccountLifecycleAudit.self,
                        from: record.payload
                    ).id
                case .receiptAttachments:
                    logicalID = try decoder.decode(
                        ReceiptAttachment.self,
                        from: record.payload
                    ).id
                case .exchangeRates:
                    let rate = try decoder.decode(
                        DatedExchangeRate.self,
                        from: record.payload
                    )
                    let pair = [
                        rate.baseCurrency.value,
                        rate.quoteCurrency.value
                    ].sorted()
                    let pairDay = pair.joined(separator: "\u{1f}")
                        + "\u{1f}\(rate.effectiveContext.dayKey)"
                    guard exchangeRatePairDays.insert(pairDay).inserted else {
                        throw AppModelError.invalidBook
                    }
                    logicalID = rate.id
                case .savingsGoals:
                    logicalID = try decoder.decode(
                        SavingsGoal.self,
                        from: record.payload
                    ).id
                case .budgetConfigurationTimelines:
                    guard record.recordID
                        == BudgetConfigurationTimeline.primaryRecordID else {
                        throw AppModelError.invalidBook
                    }
                    _ = try decoder.decode(
                        BudgetConfigurationTimeline.self,
                        from: record.payload
                    )
                    logicalID = nil
                case .budgetEntryAttributions:
                    logicalID = try decoder.decode(
                        BudgetEntryAttribution.self,
                        from: record.payload
                    ).id
                }

                guard let logicalID else { continue }
                guard logicalID.uuidString.caseInsensitiveCompare(
                    record.recordID
                ) == .orderedSame else {
                    throw AppModelError.invalidBook
                }
                let inserted = logicalIDsByCollection[
                    collection.rawValue,
                    default: []
                ].insert(logicalID).inserted
                guard inserted else { throw AppModelError.invalidBook }
            }
        } catch is AppModelError {
            throw AppModelError.invalidBook
        } catch {
            // Decoding diagnostics can contain private payload details. The
            // restore boundary exposes only a generic integrity failure.
            throw AppModelError.invalidBook
        }
    }

    private static func isValidJournalRevisionRecordID(
        _ recordID: String,
        entryID: UUID
    ) -> Bool {
        let expectedPrefix = entryID.uuidString + "-"
        guard recordID.count > expectedPrefix.count,
              String(recordID.prefix(expectedPrefix.count))
                .caseInsensitiveCompare(expectedPrefix) == .orderedSame else {
            return false
        }

        let suffix = String(recordID.dropFirst(expectedPrefix.count))
        if UUID(uuidString: suffix) != nil {
            return true
        }
        let lifecyclePrefix = "lifecycle-"
        guard suffix.lowercased().hasPrefix(lifecyclePrefix) else {
            return false
        }
        return UUID(uuidString: String(suffix.dropFirst(lifecyclePrefix.count))) != nil
    }

    static func validateRelationships(
        profile: UserProfile?,
        accounts: [LedgerAccount],
        budgetNodes: [BudgetNode],
        scheduledTransactions: [ScheduledTransaction],
        investmentHoldings: [InvestmentHolding],
        netWorthSnapshots: [NetWorthSnapshot],
        quickLogDraft: QuickLogDraft?,
        in store: EncryptedRecordStore
    ) async throws {
        guard let profile,
              Set(accounts.map(\.id)).count == accounts.count,
              Set(scheduledTransactions.map(\.id)).count
                == scheduledTransactions.count,
              Set(investmentHoldings.map(\.id)).count
                == investmentHoldings.count,
              Set(netWorthSnapshots.map(\.id)).count
                == netWorthSnapshots.count,
              netWorthSnapshots.allSatisfy({
                  $0.capturedAt.timeIntervalSinceReferenceDate.isFinite
              }) else { throw AppModelError.invalidBook }
        let accountByID = Dictionary(
            uniqueKeysWithValues: accounts.map { ($0.id, $0) }
        )
        let reportingCalendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: profile.reportingTimeZoneIdentifier
        )

        for account in accounts {
            if account.kind == .asset || account.kind == .liability {
                guard account.currency != nil else {
                    throw AppModelError.invalidBook
                }
            }
            var currentID: UUID? = account.id
            var visited = Set<UUID>()
            while let id = currentID {
                guard visited.insert(id).inserted,
                      let current = accountByID[id] else {
                    throw AppModelError.invalidBook
                }
                if let parentID = current.parentID {
                    guard let parent = accountByID[parentID],
                          parent.kind == current.kind else {
                        throw AppModelError.invalidBook
                    }
                }
                currentID = current.parentID
            }
        }

        for node in budgetNodes {
            guard let account = accountByID[node.id],
                  account.kind == .expense,
                  node.parentID == account.parentID else {
                throw AppModelError.invalidBook
            }
        }

        func requirePreference(
            _ id: UUID?,
            kinds: [LedgerAccountKind]
        ) throws {
            guard let id else { return }
            guard let account = accountByID[id], kinds.contains(account.kind) else {
                throw AppModelError.invalidBook
            }
        }
        try requirePreference(
            profile.preferredAccountID,
            kinds: [.asset, .liability]
        )
        try requirePreference(
            profile.preferredExpenseCategoryID,
            kinds: [.expense]
        )
        try requirePreference(
            profile.preferredIncomeCategoryID,
            kinds: [.income]
        )

        var scheduleEntryOwners: [UUID: UUID] = [:]
        for schedule in scheduledTransactions {
            guard let account = accountByID[schedule.accountID],
                  let category = accountByID[schedule.categoryAccountID],
                  !account.isArchived,
                  !category.isArchived,
                  let currency = account.currency,
                  currency == schedule.amount.currency,
                  account.kind == .asset || account.kind == .liability,
                  ((schedule.kind == .expense && category.kind == .expense)
                    || (schedule.kind == .income && category.kind == .income)),
                  (try? schedule.validateLifecycle(calendar: reportingCalendar)) != nil else {
                throw AppModelError.invalidBook
            }
            for linkedID in schedule.resolutions.compactMap(\.linkedEntryID) {
                guard scheduleEntryOwners.updateValue(
                    schedule.id,
                    forKey: linkedID
                ) == nil else { throw AppModelError.invalidBook }
            }
        }

        let scheduledLinkedEntryIDs = Set(scheduleEntryOwners.keys)
        if !scheduledLinkedEntryIDs.isEmpty {
            let existing = try await store.existingJournalEntryIDs(
                in: scheduledLinkedEntryIDs
            )
            guard existing == scheduledLinkedEntryIDs else {
                throw AppModelError.invalidBook
            }
        }

        var holdingEntryOwners: [UUID: UUID] = [:]
        var positionOwners: [UUID: UUID] = [:]
        var linkedInvestmentEntries: [UUID: JournalEntry] = [:]
        for holding in investmentHoldings {
            for linkedID in holding.linkedEntryIDs {
                guard holdingEntryOwners.updateValue(
                    holding.id,
                    forKey: linkedID
                ) == nil,
                let entry = try await store.fetch(
                    JournalEntry.self,
                    id: linkedID.uuidString,
                    from: .journalEntries
                ) else { throw AppModelError.invalidBook }
                linkedInvestmentEntries[linkedID] = entry
            }
        }
        let ledger = try await store.journalLedgerIndex(
            validAccountIDs: Set(accountByID.keys)
        )
        guard ledger.issues.isEmpty,
              ledger.invalidRelationshipEntryIDs.isEmpty else {
            throw AppModelError.invalidBook
        }

        for holding in investmentHoldings {
            guard let funding = accountByID[holding.accountID],
                  funding.kind == .asset,
                  funding.systemRole == nil,
                  funding.accountType == .brokerage
                    || funding.accountType == .investment,
                  let currency = funding.currency,
                  holding.isArchived || !funding.isArchived else {
                throw AppModelError.invalidBook
            }
            let holdingCurrencies = Set(
                [holding.price?.currency]
                    + holding.priceHistory.map { Optional($0.price.currency) }
                    + holding.lots.map { Optional($0.unitCost.currency) }
                    + holding.disposals.flatMap {
                        [Optional($0.costBasis.currency), Optional($0.proceeds.currency),
                         Optional($0.realizedGainLoss.currency)]
                    }
            ).compactMap { $0 }
            guard holdingCurrencies.allSatisfy({ $0 == currency }) else {
                throw AppModelError.invalidBook
            }
            guard let positionID = holding.positionAccountID else {
                guard !holding.isArchived,
                      holding.linkedEntryIDs.isEmpty,
                      holding.quantity == .zero || holding.needsLedgerConnection else {
                    throw AppModelError.invalidBook
                }
                continue
            }
            guard positionID != funding.id,
                  positionOwners.updateValue(holding.id, forKey: positionID) == nil,
                  let position = accountByID[positionID],
                  position.kind == .asset,
                  position.systemRole == .investmentPosition,
                  position.currency == currency,
                  position.isArchived == holding.isArchived,
                  holding.linkedEntryIDs.allSatisfy({ linkedID in
                      guard let entry = linkedInvestmentEntries[linkedID] else {
                          return false
                      }
                      return entry.kind == .investment
                          && entry.postings.contains { $0.accountID == positionID }
                  }) else { throw AppModelError.invalidBook }
            let expected = try holding.marketValue()
                ?? Money.zero(currency: currency)
            let positionBalances = ledger.balances[positionID] ?? [:]
            guard positionBalances.allSatisfy({ pair in
                pair.key == currency || pair.value.isZero
            }),
            (positionBalances[currency] ?? Money.zero(currency: currency))
                == expected else { throw AppModelError.invalidBook }
        }

        for position in accounts where position.systemRole == .investmentPosition {
            if positionOwners[position.id] != nil { continue }
            guard position.isArchived, let currency = position.currency else {
                throw AppModelError.invalidBook
            }
            let balances = ledger.balances[position.id] ?? [:]
            guard balances.allSatisfy({ pair in
                (pair.key == currency || pair.value.isZero) && pair.value.isZero
            }) else { throw AppModelError.invalidBook }
        }

        if let quickLogDraft {
            guard quickLogDraft.occurredAt.timeIntervalSinceReferenceDate.isFinite,
                  Set(quickLogDraft.splitLines.map(\.id)).count
                    == quickLogDraft.splitLines.count else {
                throw AppModelError.invalidBook
            }
            for id in [
                quickLogDraft.accountID,
                quickLogDraft.destinationAccountID,
                quickLogDraft.categoryID
            ].compactMap({ $0 }) where accountByID[id] == nil {
                throw AppModelError.invalidBook
            }
            let expectedSplitKind: LedgerAccountKind?
            switch quickLogDraft.kind {
            case .expense, .refund:
                expectedSplitKind = .expense
            case .income:
                expectedSplitKind = .income
            case .transfer:
                expectedSplitKind = nil
            }
            guard expectedSplitKind != nil || quickLogDraft.splitLines.isEmpty else {
                throw AppModelError.invalidBook
            }
            for split in quickLogDraft.splitLines {
                if let categoryID = split.categoryID,
                   accountByID[categoryID]?.kind != expectedSplitKind {
                    throw AppModelError.invalidBook
                }
            }
        }

    }
}
