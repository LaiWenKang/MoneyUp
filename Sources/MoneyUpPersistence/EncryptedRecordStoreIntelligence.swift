import Foundation
import MoneyUpCore
import MoneyUpIntelligence
import SQLCipher

public struct IntelligenceReadDiagnostics: Equatable, Sendable {
    public let affinityRowsRead: Int
    public let observationRowsRead: Int
    public let journalPayloadsDecoded: Int

    public init(
        affinityRowsRead: Int,
        observationRowsRead: Int,
        journalPayloadsDecoded: Int
    ) {
        self.affinityRowsRead = affinityRowsRead
        self.observationRowsRead = observationRowsRead
        self.journalPayloadsDecoded = journalPayloadsDecoded
    }
}

extension EncryptedRecordStore {
    public static let maximumIntelligenceObservationCount = 5_000

    public func payeeAffinityCandidates(
        payee: String?,
        currency: CurrencyCode
    ) throws -> [PayeeAffinityCandidate] {
        guard let payeeKey = PayeeNormalization.boundedIndexKey(payee) else {
            return []
        }
        return try connection.payeeAffinityCandidates(
            payeeKey: payeeKey,
            currency: currency.value
        )
    }

    public func intelligenceObservations(
        originDayKeyRange: ClosedRange<Int>,
        limit: Int = maximumIntelligenceObservationCount
    ) throws -> [IntelligenceObservation] {
        guard IntelligenceDay.isValid(originDayKeyRange.lowerBound),
              IntelligenceDay.isValid(originDayKeyRange.upperBound),
              originDayKeyRange.lowerBound <= originDayKeyRange.upperBound,
              (1...Self.maximumIntelligenceObservationCount).contains(limit) else {
            throw PersistenceError.invalidQuery
        }
        return try connection.intelligenceObservations(
            startDayKey: originDayKeyRange.lowerBound,
            endDayKey: originDayKeyRange.upperBound,
            limit: limit
        )
    }

    public func lastIntelligenceReadDiagnostics()
        -> IntelligenceReadDiagnostics {
        connection.lastIntelligenceReadDiagnostics
    }
}

extension SQLCipherConnection {
    func intelligenceObservations(
        startDayKey: Int,
        endDayKey: Int,
        limit: Int
    ) throws -> [IntelligenceObservation] {
        let rows = try intelligenceObservationRows(
            startDayKey: startDayKey,
            endDayKey: endDayKey,
            limit: limit
        )
        let observations = try rows.map(makeIntelligenceObservation)
        lastIntelligenceReadDiagnostics = IntelligenceReadDiagnostics(
            affinityRowsRead: lastIntelligenceReadDiagnostics.affinityRowsRead,
            observationRowsRead: rows.count,
            journalPayloadsDecoded: 0
        )
        return observations
    }

    private func intelligenceObservationRows(
        startDayKey: Int,
        endDayKey: Int,
        limit: Int
    ) throws -> [IntelligenceObservationRow] {
        try withStatement(Self.intelligenceObservationSQL) { statement in
            guard sqlite3_bind_int64(
                statement,
                1,
                Int64(startDayKey)
            ) == SQLITE_OK,
                sqlite3_bind_int64(
                    statement,
                    2,
                    Int64(endDayKey)
                ) == SQLITE_OK,
                sqlite3_bind_int64(statement, 3, Int64(limit)) == SQLITE_OK else {
                throw makeError()
            }
            return try readIntelligenceObservationRows(statement)
        }
    }

    private func readIntelligenceObservationRows(
        _ statement: OpaquePointer
    ) throws -> [IntelligenceObservationRow] {
        var rows: [IntelligenceObservationRow] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW,
                  let entryID = text(statement, column: 0),
                  let payeeKey = text(statement, column: 2),
                  let entryKind = text(statement, column: 3),
                  let currency = text(statement, column: 4),
                  let categoryID = text(statement, column: 5),
                  let amount = text(statement, column: 6),
                  let accountID = text(statement, column: 7) else {
                throw makeError(code: step == SQLITE_ROW ? SQLITE_CORRUPT : step)
            }
            rows.append(IntelligenceObservationRow(
                entryID: entryID,
                day: Int(sqlite3_column_int64(statement, 1)),
                payeeKey: payeeKey,
                entryKind: entryKind,
                currency: currency,
                categoryID: categoryID,
                amount: amount,
                accountID: accountID
            ))
        }
        return rows
    }

    private func makeIntelligenceObservation(
        _ row: IntelligenceObservationRow
    ) throws -> IntelligenceObservation {
        let locale = Locale(identifier: "en_US_POSIX")
        guard let entryID = UUID(uuidString: row.entryID),
              let categoryID = UUID(uuidString: row.categoryID),
              let accountID = UUID(uuidString: row.accountID),
              let rawAmount = Decimal(string: row.amount, locale: locale),
              rawAmount != .zero else {
            throw makeError(code: SQLITE_CORRUPT)
        }
        let amount = rawAmount < .zero
            ? try CheckedDecimal.subtracting(.zero, rawAmount)
            : rawAmount
        let currency = try CurrencyCode(row.currency)
        return try IntelligenceObservation(
            entryID: entryID,
            day: row.day,
            payeeKey: row.payeeKey,
            kind: try observationKind(entryKind: row.entryKind, amount: rawAmount),
            amount: try Money(amount, currency: currency),
            accountID: accountID,
            categoryID: categoryID
        )
    }

    private func observationKind(
        entryKind: String,
        amount: Decimal
    ) throws -> IntelligenceObservationKind {
        if entryKind == JournalEntryKind.income.rawValue { return .income }
        guard entryKind == JournalEntryKind.expense.rawValue else {
            throw makeError(code: SQLITE_CORRUPT)
        }
        return amount < .zero ? .refund : .expense
    }

    private func text(
        _ statement: OpaquePointer,
        column: Int32
    ) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    private static let intelligenceObservationSQL = """
        SELECT source.entry_id, entry.origin_day_key,
               source.normalized_payee_key, source.entry_kind,
               category_posting.currency, category.account_id,
               category_posting.amount_text, financial.account_id
        FROM journal_entry_index AS entry
        JOIN journal_intelligence_source_index AS source
          ON source.entry_id = entry.entry_id
        JOIN journal_posting_index AS category_posting
          ON category_posting.entry_id = entry.entry_id
        JOIN ledger_account_intelligence_index AS category
          ON category.account_id = category_posting.account_id
         AND category.kind = source.entry_kind
         AND category.system_role IS NULL
         AND category.is_archived = 0
        JOIN journal_posting_index AS financial_posting
          ON financial_posting.entry_id = entry.entry_id
         AND financial_posting.currency = category_posting.currency
        JOIN ledger_account_intelligence_index AS financial
          ON financial.account_id = financial_posting.account_id
         AND financial.kind IN ('asset', 'liability')
         AND financial.system_role IS NULL
        WHERE entry.origin_day_key BETWEEN ? AND ?
          AND source.normalized_payee_key IS NOT NULL
          AND source.entry_kind IN ('expense', 'income')
          AND NOT EXISTS (
              SELECT 1 FROM journal_posting_index AS sibling
              JOIN ledger_account_intelligence_index AS sibling_account
                ON sibling_account.account_id = sibling.account_id
              WHERE sibling.entry_id = entry.entry_id
                AND sibling.currency = category_posting.currency
                AND sibling.posting_id <> category_posting.posting_id
                AND sibling_account.kind = source.entry_kind
          )
          AND NOT EXISTS (
              SELECT 1 FROM journal_posting_index AS sibling
              JOIN ledger_account_intelligence_index AS sibling_account
                ON sibling_account.account_id = sibling.account_id
              WHERE sibling.entry_id = entry.entry_id
                AND sibling.currency = category_posting.currency
                AND sibling.posting_id <> financial_posting.posting_id
                AND sibling_account.kind IN ('asset', 'liability')
          )
        ORDER BY entry.origin_day_key DESC, source.entry_id DESC
        LIMIT ?;
        """
}

private struct IntelligenceObservationRow {
    let entryID: String
    let day: Int
    let payeeKey: String
    let entryKind: String
    let currency: String
    let categoryID: String
    let amount: String
    let accountID: String
}
