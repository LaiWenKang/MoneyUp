import Foundation
import MoneyUpCore
import MoneyUpPersistence

struct PerformanceFixtureManifest: Codable, Equatable, Sendable {
    let harnessProfile: String
    let corpusProfile: String
    let oracleSHA256: String
    let logicalCSVPayloadSHA256: String
    let currencies: [String]
    let journalEntryCount: Int
    let budgetAttributionCount: Int
    let scheduledTransactionCount: Int
    let expectedFindingCount: Int
    let excludedIntelligenceEntryCount: Int
    let measuredIterationCount: Int
    let totalInvocationCount: Int
    let firstEntryID: String
    let lastEntryID: String
    let firstScheduleName: String
    let lastScheduleName: String
}

final class MoneyUpPerformanceFixture: @unchecked Sendable {
    static let journalEntryCount = 10_000
    static let scheduledTransactionCount = 20
    static let measurementIterationCount = 3
    static let measurementInvocationCount = measurementIterationCount + 1
    static let archivePassword = "MoneyUp logical performance baseline"
    static let firstDayKey = 20190101
    static let finalDayKey = 20260831

    let directoryURL: URL
    let databaseURL: URL
    let key: Data
    let currency: CurrencyCode
    let corpus: PerformanceIntelligenceCorpus
    let accounts: [LedgerAccount]
    let schedules: [ScheduledTransaction]
    let calendar: Calendar
    let preferredAccountID: UUID
    let preferredExpenseCategoryID: UUID

    private init(
        directoryURL: URL,
        databaseURL: URL,
        key: Data,
        currency: CurrencyCode,
        corpus: PerformanceIntelligenceCorpus,
        accounts: [LedgerAccount],
        schedules: [ScheduledTransaction],
        calendar: Calendar,
        preferredAccountID: UUID,
        preferredExpenseCategoryID: UUID
    ) {
        self.directoryURL = directoryURL
        self.databaseURL = databaseURL
        self.key = key
        self.currency = currency
        self.corpus = corpus
        self.accounts = accounts
        self.schedules = schedules
        self.calendar = calendar
        self.preferredAccountID = preferredAccountID
        self.preferredExpenseCategoryID = preferredExpenseCategoryID
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    static func makeSeeded() throws -> MoneyUpPerformanceFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MoneyUp-Performance-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let corpus = try PerformanceIntelligenceCorpus.load()
        let currency = try CurrencyCode("SGD")
        let calendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: "UTC"
        )
        let accounts = try corpus.makeAccounts()
        let monthlyRow = try corpus.row(scenario: "monthly_recurrence")
        let preferredAccountID = try requiredUUID(monthlyRow.accountId)
        let preferredExpenseCategoryID = try requiredUUID(monthlyRow.categoryId)
        let schedules = try makeSchedules(
            currency: currency,
            accountID: preferredAccountID,
            categoryID: preferredExpenseCategoryID,
            calendar: calendar
        )
        let fixture = MoneyUpPerformanceFixture(
            directoryURL: root,
            databaseURL: root.appendingPathComponent("master.sqlite"),
            key: Data((0..<32).map { UInt8($0) }),
            currency: currency,
            corpus: corpus,
            accounts: accounts,
            schedules: schedules,
            calendar: calendar,
            preferredAccountID: preferredAccountID,
            preferredExpenseCategoryID: preferredExpenseCategoryID
        )
        try fixture.seed()
        return fixture
    }

    var manifest: PerformanceFixtureManifest {
        PerformanceFixtureManifest(
            harnessProfile: "moneyup-performance-v2",
            corpusProfile: corpus.oracle.profile,
            oracleSHA256: PerformanceIntelligenceCorpus.oracleSHA256,
            logicalCSVPayloadSHA256:
                PerformanceIntelligenceCorpus.logicalCSVPayloadSHA256,
            currencies: corpus.oracle.currencies.sorted(),
            journalEntryCount: Self.journalEntryCount,
            budgetAttributionCount: Self.journalEntryCount,
            scheduledTransactionCount: Self.scheduledTransactionCount,
            expectedFindingCount: corpus.expectedFindingSignatures.count,
            excludedIntelligenceEntryCount: corpus.excludedEntryIDs.count,
            measuredIterationCount: Self.measurementIterationCount,
            totalInvocationCount: Self.measurementInvocationCount,
            firstEntryID: corpus.rows.first?.id ?? "",
            lastEntryID: corpus.rows.last?.id ?? "",
            firstScheduleName: schedules.first?.name ?? "",
            lastScheduleName: schedules.last?.name ?? ""
        )
    }

    func databaseCopy(named name: String) throws -> URL {
        let destination = directoryURL.appendingPathComponent("\(name).sqlite")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: databaseURL, to: destination)
        return destination
    }

    func emptyStore(named name: String) throws -> EncryptedRecordStore {
        let url = directoryURL.appendingPathComponent("\(name).sqlite")
        return try EncryptedRecordStore(databaseURL: url, key: key)
    }

    func openStore(at url: URL? = nil) throws -> EncryptedRecordStore {
        try EncryptedRecordStore(databaseURL: url ?? databaseURL, key: key)
    }

    func makeAdditionalEntry(offset: Int) throws -> JournalEntry {
        let occurredAt = Self.additionalEntryDate.addingTimeInterval(
            TimeInterval(offset * 3_600)
        )
        let money = try Money(Decimal(offset + 1), currency: currency)
        return try JournalEntry(
            id: Self.additionalEntryID(offset),
            kind: .expense,
            occurredAt: occurredAt,
            createdAt: occurredAt,
            payee: "Performance save baseline",
            note: "Post-seed logical write \(offset + 1)",
            postings: [
                Posting(
                    id: Self.additionalPostingID(offset * 2),
                    accountID: preferredExpenseCategoryID,
                    money: money
                ),
                Posting(
                    id: Self.additionalPostingID(offset * 2 + 1),
                    accountID: preferredAccountID,
                    money: money.negated
                )
            ],
            sourceSystem: "moneyup-performance-v2",
            sourceFingerprint: "performance-save-\(offset)",
            originContext: .capture(
                for: occurredAt,
                calendar: calendar,
                timeZone: calendar.timeZone
            )
        )
    }

    private func seed() throws {
        let store = try openStore()
        do {
            try seedBookMetadata(into: store)
            try seedJournal(into: store)
            try seedSchedules(into: store)
            try validateSeed(in: store)
            try waitForPerformanceOperation { await store.close() }
        } catch {
            _ = try? waitForPerformanceOperation { await store.close() }
            throw error
        }
    }

    private func seedBookMetadata(into store: EncryptedRecordStore) throws {
        let profile = UserProfile(
            baseCurrency: currency,
            createdAt: Self.additionalEntryDate,
            preferredAccountID: preferredAccountID,
            preferredExpenseCategoryID: preferredExpenseCategoryID,
            intelligenceEnabled: true,
            reportingTimeZoneIdentifier: "UTC"
        )
        let writes = try accounts.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .accounts)
        } + [try RecordWrite(
            profile,
            id: UserProfile.primaryRecordID,
            in: .profile
        )]
        try waitForPerformanceOperation { try await store.write(writes) }
    }

    private func seedJournal(into store: EncryptedRecordStore) throws {
        let batchSize = 200
        for lowerBound in stride(
            from: 0,
            to: corpus.rows.count,
            by: batchSize
        ) {
            let upperBound = min(lowerBound + batchSize, corpus.rows.count)
            var writes: [RecordWrite] = []
            writes.reserveCapacity((upperBound - lowerBound) * 2)
            for index in lowerBound..<upperBound {
                let entry = try corpus.makeEntry(
                    row: corpus.rows[index],
                    index: index,
                    calendar: calendar
                )
                let attribution = try BudgetEntryAttribution(
                    entry: entry,
                    originTimeZoneIdentifier: "UTC"
                )
                writes.append(try RecordWrite(
                    entry,
                    id: entry.id.uuidString,
                    in: .journalEntries
                ))
                writes.append(try RecordWrite(
                    attribution,
                    id: attribution.id.uuidString,
                    in: .budgetEntryAttributions
                ))
            }
            let committedWrites = writes
            try waitForPerformanceOperation {
                try await store.write(committedWrites)
            }
        }
    }

    private func seedSchedules(into store: EncryptedRecordStore) throws {
        let writes = try schedules.map {
            try RecordWrite(
                $0,
                id: $0.id.uuidString,
                in: .scheduledTransactions
            )
        }
        try waitForPerformanceOperation { try await store.write(writes) }
    }

    private func validateSeed(in store: EncryptedRecordStore) throws {
        let counts = try waitForPerformanceOperation {
            try await store.recordCountSnapshot()
        }
        guard counts.count(in: .journalEntries) == Self.journalEntryCount,
              counts.count(in: .budgetEntryAttributions) == Self.journalEntryCount,
              counts.count(in: .scheduledTransactions)
                == Self.scheduledTransactionCount else {
            throw PerformanceFixtureError.invalidSeedCounts
        }

        let validAccountIDs = Set(accounts.map(\.id))
        let ledger = try waitForPerformanceOperation {
            try await store.journalLedgerIndex(
                validAccountIDs: validAccountIDs,
                expectedAccountCurrencies: [:]
            )
        }
        guard ledger.entryCount == Self.journalEntryCount,
              ledger.issues.isEmpty,
              ledger.invalidRelationshipEntryIDs.isEmpty else {
            throw PerformanceFixtureError.invalidLedger
        }

        let intelligenceCorpus = corpus
        let intelligence = try waitForPerformanceOperation {
            try await PerformanceOperations.intelligence(
                store: store,
                corpus: intelligenceCorpus
            )
        }
        guard intelligence.observationCount
                == EncryptedRecordStore.maximumIntelligenceObservationCount,
              intelligence.currencies == Set(corpus.oracle.currencies),
              intelligence.findings == corpus.expectedFindingSignatures,
              intelligence.excludedEntryCount == 0 else {
            throw PerformanceFixtureError.invalidIntelligenceOracle
        }
        try validatePersistedOperationShapes(in: store)
    }

    private func validatePersistedOperationShapes(
        in store: EncryptedRecordStore
    ) throws {
        let refundRow = try corpus.row(scenario: "refund")
        let transferRow = try corpus.row(scenario: "transfer")
        let splitRow = try corpus.row(scenario: "split")
        let operationIDs = try Set([refundRow, transferRow, splitRow].map {
            try Self.requiredUUID($0.id)
        })
        let recovered = try waitForPerformanceOperation {
            try await store.fetchJournalEntriesRecovering(ids: operationIDs)
        }
        let entries = Dictionary(uniqueKeysWithValues: recovered.values.map {
            ($0.id, $0)
        })
        guard recovered.issues.isEmpty,
              entries.count == operationIDs.count,
              let refund = entries[try Self.requiredUUID(refundRow.id)],
              let refundCategoryID = UUID(uuidString: refundRow.categoryId),
              refund.kind == .expense,
              refund.postings.contains(where: {
                  $0.accountID == refundCategoryID && $0.money.amount < .zero
              }),
              let transfer = entries[try Self.requiredUUID(transferRow.id)],
              transfer.kind == .transfer,
              transfer.postings.count == 2,
              let split = entries[try Self.requiredUUID(splitRow.id)],
              split.kind == .expense,
              split.postings.count == 3 else {
            throw PerformanceFixtureError.invalidOperationShapes
        }
    }
}

private extension MoneyUpPerformanceFixture {
    static let additionalEntryDate = Date(timeIntervalSince1970: 1_788_264_000)

    static func makeSchedules(
        currency: CurrencyCode,
        accountID: UUID,
        categoryID: UUID,
        calendar: Calendar
    ) throws -> [ScheduledTransaction] {
        let start = calendar.date(
            from: DateComponents(year: 2026, month: 9, day: 5, hour: 12)
        )!
        return try (0..<scheduledTransactionCount).map { index in
            try ScheduledTransaction(
                id: scheduleID(index),
                kind: .expense,
                name: String(format: "Fixture Schedule %02d", index + 1),
                amount: try Money(Decimal(index + 1), currency: currency),
                accountID: accountID,
                categoryAccountID: categoryID,
                nextOccurrence: calendar.date(
                    byAdding: .day,
                    value: index,
                    to: start
                )!,
                frequency: .monthly,
                recurrenceTimeZoneIdentifier: "UTC"
            )
        }
    }

    static func additionalEntryID(_ index: Int) -> UUID {
        deterministicUUID(namespace: 0x6000, index: index)
    }

    static func additionalPostingID(_ index: Int) -> UUID {
        deterministicUUID(namespace: 0x7000, index: index)
    }

    static func scheduleID(_ index: Int) -> UUID {
        deterministicUUID(namespace: 0x8000, index: index)
    }

    static func deterministicUUID(namespace: Int, index: Int) -> UUID {
        UUID(uuidString: String(
            format: "00000000-0000-4000-8000-%04X%08X",
            namespace,
            index
        ))!
    }

    static func requiredUUID(_ string: String) throws -> UUID {
        guard let result = UUID(uuidString: string) else {
            throw PerformanceFixtureError.invalidOperationShapes
        }
        return result
    }
}

enum PerformanceFixtureError: Error {
    case invalidSeedCounts
    case invalidLedger
    case invalidIntelligenceOracle
    case invalidOperationShapes
}
