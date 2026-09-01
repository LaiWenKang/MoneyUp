import Foundation
import MoneyUpCore
import MoneyUpIntelligence
import MoneyUpPersistence

struct PerformanceLoadResult: Equatable, Sendable {
    let accountCount: Int
    let scheduleCount: Int
    let ledgerEntryCount: Int
    let receiptAttachmentCount: Int
    let budgetAttributionCount: Int

    var checksum: Int {
        accountCount + scheduleCount + ledgerEntryCount
            + receiptAttachmentCount + budgetAttributionCount
    }
}

struct PerformanceHistoryResult: Equatable, Sendable {
    let matchCount: Int
    let pageCount: Int
    let issueCount: Int

    var checksum: Int { matchCount + pageCount + issueCount }
}

struct PerformanceExportResult: Equatable, Sendable {
    let csvByteCount: Int
    let xlsxByteCount: Int

    var checksum: Int { csvByteCount + xlsxByteCount }
}

struct PerformanceProjectionResult: Equatable, Sendable {
    let postingEventCount: Int
    let baseCurrencyCategoryEventCount: Int
    let scheduleCount: Int
    let scheduleIssueCount: Int
    let occurrenceCount: Int
    let projectedTotal: Money

    var checksum: Int {
        postingEventCount + baseCurrencyCategoryEventCount + scheduleCount
            + scheduleIssueCount + occurrenceCount
            + NSDecimalNumber(decimal: projectedTotal.amount).intValue
    }
}

struct PerformanceIntelligenceResult: Equatable, Sendable {
    let observationCount: Int
    let currencies: Set<String>
    let findings: [PerformanceFindingSignature]
    let excludedEntryCount: Int

    var checksum: Int {
        observationCount + currencies.count + findings.reduce(0) {
            $0 + $1.id.utf8.count + $1.kind.utf8.count + $1.ruleID.utf8.count
        } + excludedEntryCount
    }
}

enum PerformanceOperations {
    static func loadBook(
        store: EncryptedRecordStore,
        accounts: [LedgerAccount]
    ) async throws -> PerformanceLoadResult {
        let recoveredAccounts = try await store.fetchAllIdentifiedRecovering(
            LedgerAccount.self,
            from: .accounts
        )
        let recoveredSchedules = try await store.fetchAllIdentifiedRecovering(
            ScheduledTransaction.self,
            from: .scheduledTransactions
        )
        let ledger = try await store.journalLedgerIndex(
            validAccountIDs: Set(accounts.map(\.id)),
            expectedAccountCurrencies: Dictionary(
                uniqueKeysWithValues: accounts.compactMap { account in
                    account.currency.map { (account.id, $0) }
                }
            )
        )
        let attachments = try await store.receiptAttachmentIndexSnapshot()
        let attribution = try await store.budgetAttributionIndexSnapshot()
        return PerformanceLoadResult(
            accountCount: recoveredAccounts.values.count,
            scheduleCount: recoveredSchedules.values.count,
            ledgerEntryCount: ledger.entryCount,
            receiptAttachmentCount: attachments.metadata.count,
            budgetAttributionCount: attribution.recordCount
        )
    }

    static func historyPageAndQuery(
        store: EncryptedRecordStore,
        accounts: [LedgerAccount],
        calendar: Calendar
    ) async throws -> PerformanceHistoryResult {
        let query = HistoryQuery(
            searchText: "filler merchant 009",
            kind: .expense
        )
        var cursor: JournalEntryPageCursor?
        var matches: [JournalEntry] = []
        var pageCount = 0
        var issueCount = 0
        repeat {
            let page = try await store.fetchJournalEntryPage(
                after: cursor,
                limit: 160
            )
            pageCount += 1
            issueCount += page.issues.count
            matches.append(contentsOf: query.filteredEntries(
                page.entries,
                accounts: accounts,
                locale: Locale(identifier: "en_US_POSIX"),
                calendar: calendar
            ).prefix(80 - matches.count))
            cursor = page.nextCursor
        } while matches.count < 80 && cursor != nil
        return PerformanceHistoryResult(
            matchCount: matches.count,
            pageCount: pageCount,
            issueCount: issueCount
        )
    }

    static func export(
        entries: [JournalEntry],
        accounts: [LedgerAccount]
    ) -> PerformanceExportResult {
        let csv = LedgerCSVExporter.export(entries, accounts: accounts)
        let xlsx = LedgerXLSXExporter.export(
            entries: entries,
            accounts: accounts
        )
        return PerformanceExportResult(
            csvByteCount: csv.utf8.count,
            xlsxByteCount: xlsx.count
        )
    }

    static func projection(
        store: EncryptedRecordStore,
        fixture: MoneyUpPerformanceFixture
    ) async throws -> PerformanceProjectionResult {
        let events = try await store.fetchJournalPostingEvents(
            originDayKeyRange: MoneyUpPerformanceFixture.firstDayKey
                ..< MoneyUpPerformanceFixture.finalDayKey + 1
        )
        let recoveredSchedules = try await store.fetchAllIdentifiedRecovering(
            ScheduledTransaction.self,
            from: .scheduledTransactions
        )
        let schedules = recoveredSchedules.values
        let categoryIDs = Set(fixture.accounts.compactMap { account in
            account.kind == .expense ? account.id : nil
        })
        let baseCurrencyEvents = events.filter {
            categoryIDs.contains($0.posting.accountID)
                && $0.posting.money.currency == fixture.currency
        }
        var actual = Decimal.zero
        for event in baseCurrencyEvents {
            actual = try CheckedDecimal.adding(actual, event.posting.money.amount)
        }
        let scheduleMoney = schedules.map(\.amount)
        let occurrenceCount = schedules.reduce(0) { partial, schedule in
            partial + schedule.occurrences(
                through: Date(timeIntervalSince1970: 1_830_297_600),
                calendar: fixture.calendar
            ).count
        }
        let output = try MonthEndProjectionEngine.project(
            MonthEndProjectionInput(
                committedActuals: try Money(actual, currency: fixture.currency),
                remainingSchedules: scheduleMoney,
                flexibleActuals: [try Money(actual, currency: fixture.currency)],
                elapsedDayCount: 15,
                remainingDayCount: 15
            )
        )
        return PerformanceProjectionResult(
            postingEventCount: events.count,
            baseCurrencyCategoryEventCount: baseCurrencyEvents.count,
            scheduleCount: schedules.count,
            scheduleIssueCount: recoveredSchedules.issues.count,
            occurrenceCount: occurrenceCount,
            projectedTotal: output.projectedTotal
        )
    }

    static func intelligence(
        store: EncryptedRecordStore,
        corpus: PerformanceIntelligenceCorpus
    ) async throws -> PerformanceIntelligenceResult {
        let observations = try await store.intelligenceObservations(
            originDayKeyRange: MoneyUpPerformanceFixture.firstDayKey
                ...MoneyUpPerformanceFixture.finalDayKey,
            limit: EncryptedRecordStore.maximumIntelligenceObservationCount
        )
        var findings = try RecurrenceDetector.findings(
            in: observations,
            asOfDay: corpus.oracle.asOfDay
        )
        findings += DuplicateDetector.findings(in: observations)
        findings += try CategoryAnomalyDetector.findings(
            in: observations,
            asOfDay: corpus.oracle.asOfDay
        )
        let signatures = findings.map {
            PerformanceFindingSignature(
                id: $0.id,
                kind: $0.kind.rawValue,
                ruleID: $0.ruleID
            )
        }.sorted { $0.id < $1.id }
        let excludedEntryCount = observations.reduce(0) { count, observation in
            count + (corpus.excludedEntryIDs.contains(observation.entryID) ? 1 : 0)
        }
        return PerformanceIntelligenceResult(
            observationCount: observations.count,
            currencies: Set(observations.map { $0.amount.currency.value }),
            findings: signatures,
            excludedEntryCount: excludedEntryCount
        )
    }
}
