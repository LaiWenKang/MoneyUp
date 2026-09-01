import CryptoKit
import Foundation
import MoneyUpCore
import MoneyUpIntelligence

struct PerformanceFindingSignature: Codable, Equatable, Hashable, Sendable {
    let id: String
    let kind: String
    let ruleID: String
}

struct PerformanceIntelligenceCorpus: Sendable {
    static let oracleSHA256 =
        "4c33ed9e0b8082a6c5af936fe7399195c30f4045a01583bad5c6eaccd6945fa5"
    static let logicalCSVPayloadSHA256 =
        "92fe646bbcc7e52fc11a340266a194d3d18b1b147ef70ff53ffab1026a495df5"

    let oracle: PerformanceIntelligenceOracle
    let rows: [PerformanceIntelligenceRow]

    var expectedFindingSignatures: [PerformanceFindingSignature] {
        oracle.expectedFindings.map {
            PerformanceFindingSignature(
                id: $0.id,
                kind: $0.kind,
                ruleID: $0.ruleId
            )
        }.sorted(by: Self.findingSignatureOrder)
    }

    var excludedEntryIDs: Set<UUID> {
        Set(oracle.excludedEntryIds.compactMap { UUID(uuidString: $0) })
    }

    static func load() throws -> PerformanceIntelligenceCorpus {
        let bundle = Bundle(for: MoneyUpPerformanceFixture.self)
        guard let oracleURL = bundle.url(
            forResource: "MoneyUp-Intelligence-Oracle",
            withExtension: "json"
        ) else {
            throw PerformanceCorpusError.missingOracleResource
        }
        let oracleData = try Data(contentsOf: oracleURL)
        guard sha256(oracleData) == oracleSHA256 else {
            throw PerformanceCorpusError.oracleDigestMismatch
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let oracle = try decoder.decode(
            PerformanceIntelligenceOracle.self,
            from: oracleData
        )
        guard oracle.profile == "intelligence-v1",
              oracle.schemaVersion == 1,
              oracle.profileEntryCount == MoneyUpPerformanceFixture.journalEntryCount,
              Set(oracle.currencies) == Set(["KWD", "SGD", "USD"]),
              Set(oracle.negativeScenarios) == Set([
                  "different_account_near_duplicate",
                  "insufficient_anomaly_history",
                  "irregular_cadence"
              ]) else {
            throw PerformanceCorpusError.invalidOracleContract
        }

        var rows = oracle.plantedRows
        rows.append(contentsOf: try scaleFillerRows(
            count: oracle.profileEntryCount - oracle.plantedRows.count
        ))
        guard rows.count == oracle.profileEntryCount,
              Set(rows.map(\.currency)) == Set(oracle.currencies),
              rows.filter({ $0.kind == "refund" }).count == 1,
              rows.filter({ $0.kind == "transfer" }).count == 1,
              rows.filter({ $0.shape == "split" }).count == 1 else {
            throw PerformanceCorpusError.invalidCorpusContract
        }

        let excludedByShape = Set(
            rows.filter { $0.shape == "split" || $0.shape == "transfer" }
                .map(\.id)
        )
        guard excludedByShape == Set(oracle.excludedEntryIds),
              Set(oracle.expectedFindings.map(\.kind)) == Set([
                  "recurrence",
                  "lapsed_subscription",
                  "price_increase",
                  "possible_duplicate",
                  "category_anomaly"
              ]) else {
            throw PerformanceCorpusError.invalidOracleContract
        }

        let csvData = canonicalCSVData(rows: rows)
        guard sha256(csvData) == logicalCSVPayloadSHA256 else {
            throw PerformanceCorpusError.logicalCorpusDigestMismatch
        }
        return PerformanceIntelligenceCorpus(oracle: oracle, rows: rows)
    }

    func makeAccounts() throws -> [LedgerAccount] {
        var financialIDs = Set<String>()
        var categoryKinds: [String: LedgerAccountKind] = [:]
        for row in rows {
            financialIDs.insert(row.accountId)
            if !row.destinationAccountId.isEmpty {
                financialIDs.insert(row.destinationAccountId)
            }
            let categoryKind: LedgerAccountKind = row.kind == "income"
                ? .income
                : .expense
            if !row.categoryId.isEmpty {
                categoryKinds[row.categoryId] = categoryKind
            }
            if !row.secondaryCategoryId.isEmpty {
                categoryKinds[row.secondaryCategoryId] = categoryKind
            }
        }

        let financial = try financialIDs.sorted().map { rawID in
            LedgerAccount(
                id: try Self.uuid(rawID),
                name: "Corpus Account \(rawID.suffix(6))",
                kind: .asset,
                // Filler account IDs intentionally span all three currencies.
                currency: nil,
                accountType: .bank
            )
        }
        let categories = try categoryKinds.keys.sorted().map { rawID in
            LedgerAccount(
                id: try Self.uuid(rawID),
                name: "Corpus Category \(rawID.suffix(6))",
                kind: categoryKinds[rawID] ?? .expense,
                currency: nil
            )
        }
        return financial + categories
    }

    func makeEntry(
        row: PerformanceIntelligenceRow,
        index: Int,
        calendar: Calendar
    ) throws -> JournalEntry {
        guard let day = Int(row.day),
              let occurredAt = Self.date(day: day, calendar: calendar),
              let amount = Decimal(
                  string: row.amount,
                  locale: Locale(identifier: "en_US_POSIX")
              ) else {
            throw PerformanceCorpusError.invalidCorpusRow
        }
        let currency = try CurrencyCode(row.currency)
        let money = try Money(amount, currency: currency)
        let sourceAccountID = try Self.uuid(row.accountId)
        let postings: [Posting]
        let entryKind: JournalEntryKind

        switch row.shape {
        case "transfer":
            guard !row.destinationAccountId.isEmpty else {
                throw PerformanceCorpusError.invalidCorpusRow
            }
            entryKind = .transfer
            postings = [
                Posting(
                    id: Self.postingID(index: index, slot: 0),
                    accountID: sourceAccountID,
                    money: money.negated
                ),
                Posting(
                    id: Self.postingID(index: index, slot: 1),
                    accountID: try Self.uuid(row.destinationAccountId),
                    money: money
                )
            ]
        case "split":
            guard !row.categoryId.isEmpty,
                  !row.secondaryCategoryId.isEmpty else {
                throw PerformanceCorpusError.invalidCorpusRow
            }
            entryKind = .expense
            let firstAmount = try CheckedDecimal.dividing(amount, 2)
            let secondAmount = try CheckedDecimal.subtracting(amount, firstAmount)
            postings = [
                Posting(
                    id: Self.postingID(index: index, slot: 0),
                    accountID: try Self.uuid(row.categoryId),
                    money: try Money(firstAmount, currency: currency)
                ),
                Posting(
                    id: Self.postingID(index: index, slot: 1),
                    accountID: try Self.uuid(row.secondaryCategoryId),
                    money: try Money(secondAmount, currency: currency)
                ),
                Posting(
                    id: Self.postingID(index: index, slot: 2),
                    accountID: sourceAccountID,
                    money: money.negated
                )
            ]
        case "single":
            guard !row.categoryId.isEmpty else {
                throw PerformanceCorpusError.invalidCorpusRow
            }
            entryKind = row.kind == "income" ? .income : .expense
            let categoryMoney = row.kind == "refund" || row.kind == "income"
                ? money.negated
                : money
            postings = [
                Posting(
                    id: Self.postingID(index: index, slot: 0),
                    accountID: try Self.uuid(row.categoryId),
                    money: categoryMoney
                ),
                Posting(
                    id: Self.postingID(index: index, slot: 1),
                    accountID: sourceAccountID,
                    money: categoryMoney.negated
                )
            ]
        default:
            throw PerformanceCorpusError.invalidCorpusRow
        }

        return try JournalEntry(
            id: Self.uuid(row.id),
            kind: entryKind,
            occurredAt: occurredAt,
            createdAt: occurredAt,
            payee: row.payeeKey,
            note: "Authoritative intelligence-v1 scenario: \(row.scenario)",
            postings: postings,
            sourceSystem: "intelligence-v1",
            sourceFingerprint: row.id,
            originContext: .capture(
                for: occurredAt,
                calendar: calendar,
                timeZone: calendar.timeZone
            )
        )
    }

    func row(scenario: String) throws -> PerformanceIntelligenceRow {
        guard let row = rows.first(where: { $0.scenario == scenario }) else {
            throw PerformanceCorpusError.invalidCorpusContract
        }
        return row
    }
}

struct PerformanceIntelligenceOracle: Decodable, Sendable {
    let asOfDay: Int
    let currencies: [String]
    let excludedEntryIds: [String]
    let expectedFindings: [PerformanceExpectedFinding]
    let negativeScenarios: [String]
    let plantedRows: [PerformanceIntelligenceRow]
    let profile: String
    let profileEntryCount: Int
    let schemaVersion: Int
}

struct PerformanceExpectedFinding: Decodable, Equatable, Sendable {
    let id: String
    let kind: String
    let ruleId: String
}

struct PerformanceIntelligenceRow: Decodable, Equatable, Sendable {
    let id: String
    let day: String
    let kind: String
    let amount: String
    let currency: String
    let payeeKey: String
    let accountId: String
    let categoryId: String
    let secondaryCategoryId: String
    let destinationAccountId: String
    let shape: String
    let scenario: String

    var canonicalCSVLine: String {
        [
            id, day, kind, amount, currency, payeeKey, accountId, categoryId,
            secondaryCategoryId, destinationAccountId, shape, scenario
        ].joined(separator: ",")
    }
}

private extension PerformanceIntelligenceCorpus {
    static let csvHeader = [
        "id", "day", "kind", "amount", "currency", "payee_key",
        "account_id", "category_id", "secondary_category_id",
        "destination_account_id", "shape", "scenario"
    ].joined(separator: ",")

    static func scaleFillerRows(
        count: Int
    ) throws -> [PerformanceIntelligenceRow] {
        guard count >= 0 else { throw PerformanceCorpusError.invalidCorpusContract }
        let calendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: "UTC"
        )
        guard let start = calendar.date(from: DateComponents(
            year: 2019,
            month: 1,
            day: 1
        )) else {
            throw PerformanceCorpusError.invalidCorpusContract
        }
        let currencies = ["SGD", "USD", "KWD"]
        return try (0..<count).map { index in
            guard let date = calendar.date(
                byAdding: .hour,
                value: index * 4,
                to: start
            ) else {
                throw PerformanceCorpusError.invalidCorpusRow
            }
            let components = calendar.dateComponents(
                [.year, .month, .day],
                from: date
            )
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day else {
                throw PerformanceCorpusError.invalidCorpusRow
            }
            let currency = currencies[index % currencies.count]
            return PerformanceIntelligenceRow(
                id: deterministicUUIDString(1_000_000 + index),
                day: String(format: "%04d%02d%02d", year, month, day),
                kind: "expense",
                amount: currency == "KWD" ? "50.000" : "50.00",
                currency: currency,
                payeeKey: String(format: "filler merchant %05d", index + 1),
                accountId: deterministicUUIDString(800_001 + index % 9),
                categoryId: deterministicUUIDString(900_001 + index % 17),
                secondaryCategoryId: "",
                destinationAccountId: "",
                shape: "single",
                scenario: "scale_filler"
            )
        }
    }

    static func canonicalCSVData(
        rows: [PerformanceIntelligenceRow]
    ) -> Data {
        let text = ([csvHeader] + rows.map(\.canonicalCSVLine))
            .joined(separator: "\n") + "\n"
        return Data(text.utf8)
    }

    static func deterministicUUIDString(_ value: Int) -> String {
        String(format: "00000000-0000-0000-0000-%012d", value)
    }

    static func uuid(_ string: String) throws -> UUID {
        guard let result = UUID(uuidString: string) else {
            throw PerformanceCorpusError.invalidCorpusRow
        }
        return result
    }

    static func date(day: Int, calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: day / 10_000,
            month: day / 100 % 100,
            day: day % 100,
            hour: 12
        ))
    }

    static func postingID(index: Int, slot: Int) -> UUID {
        UUID(uuidString: String(
            format: "00000000-0000-4000-8000-%04X%08X",
            0x5000,
            index * 3 + slot
        ))!
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func findingSignatureOrder(
        _ lhs: PerformanceFindingSignature,
        _ rhs: PerformanceFindingSignature
    ) -> Bool {
        if lhs.id != rhs.id { return lhs.id < rhs.id }
        if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
        return lhs.ruleID < rhs.ruleID
    }
}

enum PerformanceCorpusError: Error {
    case missingOracleResource
    case oracleDigestMismatch
    case logicalCorpusDigestMismatch
    case invalidOracleContract
    case invalidCorpusContract
    case invalidCorpusRow
}
