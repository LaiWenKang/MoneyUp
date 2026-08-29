import Foundation

/// Consumer transaction shapes understood by the capture intelligence core.
///
/// These cases describe an uncommitted capture. They do not add a persisted
/// ledger kind: refunds remain expense journal entries with reversed postings,
/// while both transfer cases remain transfer journal entries.
public enum CaptureIntelligenceKind: String, CaseIterable, Sendable {
    case expense
    case income
    case refund
    case transfer
    case foreignCurrencyTransfer
}

/// A small, deliberately non-numeric confidence vocabulary for user-facing
/// suggestions and advisories. The evidence alongside it remains the source of
/// truth; callers should never treat confidence as permission to auto-commit.
public enum CaptureConfidence: String, CaseIterable, Comparable, Sendable {
    case low
    case medium
    case high

    public static func < (lhs: CaptureConfidence, rhs: CaptureConfidence) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }
}

/// The immutable inputs used to derive account and category suggestions.
///
/// `occurredAt` is both an as-of boundary and part of the fingerprint. History
/// after that instant is ignored, which makes a result reproducible when an old
/// transaction is edited or recreated.
public struct CaptureSuggestionQuery: Equatable, Sendable {
    public let kind: CaptureIntelligenceKind
    public let payee: String?
    public let currency: CurrencyCode
    public let occurredAt: Date

    public init(
        kind: CaptureIntelligenceKind,
        payee: String? = nil,
        currency: CurrencyCode,
        occurredAt: Date = Date()
    ) {
        self.kind = kind
        self.payee = CaptureCanonicalText.nonEmptyOriginal(payee)
        self.currency = currency
        self.occurredAt = occurredAt
    }

    /// A stable, non-cryptographic token for detecting a stale UI result.
    /// Financial or payee data must not be logged alongside this token.
    public var fingerprint: String {
        CaptureFingerprint.make(fields: [
            "suggestion-v1",
            kind.rawValue,
            CaptureCanonicalText.key(payee),
            currency.value,
            CaptureFingerprint.dateKey(occurredAt)
        ])
    }
}

/// Inspectable facts supporting one suggested ledger account.
public struct CaptureSuggestionEvidence: Equatable, Sendable {
    /// Entries in which the suggested account was used for this query.
    public let supportingEntryCount: Int
    /// Entries eligible to vote for this field after kind/currency/payee
    /// filtering. Counts, rather than a rounded percentage, remain exact.
    public let eligibleEntryCount: Int
    /// Supporting entries whose normalized payee exactly matched the query.
    public let exactPayeeEntryCount: Int
    public let mostRecentUse: Date
    /// False means the query had no payee and used kind/currency history only.
    public let usedPayeeHistory: Bool

    public init(
        supportingEntryCount: Int,
        eligibleEntryCount: Int,
        exactPayeeEntryCount: Int,
        mostRecentUse: Date,
        usedPayeeHistory: Bool
    ) {
        self.supportingEntryCount = supportingEntryCount
        self.eligibleEntryCount = eligibleEntryCount
        self.exactPayeeEntryCount = exactPayeeEntryCount
        self.mostRecentUse = mostRecentUse
        self.usedPayeeHistory = usedPayeeHistory
    }

    public var competingEntryCount: Int {
        max(0, eligibleEntryCount - supportingEntryCount)
    }
}

/// One editable suggestion for an existing ledger account or category.
public struct CaptureFieldSuggestion: Equatable, Sendable {
    public let ledgerAccountID: UUID
    public let confidence: CaptureConfidence
    public let evidence: CaptureSuggestionEvidence

    public init(
        ledgerAccountID: UUID,
        confidence: CaptureConfidence,
        evidence: CaptureSuggestionEvidence
    ) {
        self.ledgerAccountID = ledgerAccountID
        self.confidence = confidence
        self.evidence = evidence
    }
}

/// Account/category suggestions derived from an immutable ledger snapshot.
public struct CaptureSuggestionResult: Equatable, Sendable {
    public let queryFingerprint: String
    public let accountSuggestion: CaptureFieldSuggestion?
    public let categorySuggestion: CaptureFieldSuggestion?

    public init(
        queryFingerprint: String,
        accountSuggestion: CaptureFieldSuggestion?,
        categorySuggestion: CaptureFieldSuggestion?
    ) {
        self.queryFingerprint = queryFingerprint
        self.accountSuggestion = accountSuggestion
        self.categorySuggestion = categorySuggestion
    }
}

/// Pure, bounded-by-input account and category suggestions.
///
/// Scoring is intentionally transparent: frequency, then exact-payee support,
/// then recency, then the lexicographically lower UUID. The same inputs always
/// return the same result regardless of array or dictionary iteration order.
/// High confidence requires at least three supporting entries and 75% support;
/// medium requires at least two and 50%. A payee containment match without any
/// exact normalized-payee support is capped at medium.
public enum CaptureSuggestionEngine {
    public static func suggestions(
        for query: CaptureSuggestionQuery,
        entries: [JournalEntry],
        accounts: [LedgerAccount]
    ) -> CaptureSuggestionResult {
        let empty = CaptureSuggestionResult(
            queryFingerprint: query.fingerprint,
            accountSuggestion: nil,
            categorySuggestion: nil
        )
        guard query.occurredAt.timeIntervalSinceReferenceDate.isFinite,
              let directions = directions(for: query.kind) else {
            return empty
        }

        let suppliedPayee = CaptureCanonicalText.nonEmptyOriginal(query.payee)
        let payeeKey = CaptureCanonicalText.key(suppliedPayee)
        let usesPayeeHistory = payeeKey != nil
        if suppliedPayee != nil,
           !CaptureCanonicalText.isMeaningfulPayeeKey(payeeKey) {
            return empty
        }

        let accountsByID = unambiguousAccounts(accounts)
        let financialAccountIDs = Set(accountsByID.values.lazy.filter { account in
            !account.isArchived
                && account.systemRole == nil
                && (account.kind == .asset || account.kind == .liability)
                && account.currency == query.currency
        }.map(\.id))
        let categoryAccountIDs = Set(accountsByID.values.lazy.filter { account in
            !account.isArchived
                && account.systemRole == nil
                && account.kind == directions.categoryKind
                && (account.currency == nil || account.currency == query.currency)
        }.map(\.id))

        var accountStats: [UUID: SuggestionStats] = [:]
        var categoryStats: [UUID: SuggestionStats] = [:]
        var accountEligibleEntryCount = 0
        var categoryEligibleEntryCount = 0

        for entry in entries {
            guard entry.occurredAt <= query.occurredAt,
                  entry.kind == directions.journalKind else {
                continue
            }

            let storedPayeeKey = CaptureCanonicalText.key(entry.payee)
            if let payeeKey,
               !CaptureCanonicalText.payeeMatches(storedPayeeKey, payeeKey) {
                continue
            }
            let exactPayeeMatch = payeeKey != nil && storedPayeeKey == payeeKey

            let matchingFinancialAccounts: Set<UUID> = Set(
                entry.postings.lazy.compactMap { posting -> UUID? in
                    guard posting.money.currency == query.currency,
                          directions.accountSign.matches(posting.money.amount),
                          financialAccountIDs.contains(posting.accountID) else {
                        return nil
                    }
                    return posting.accountID
                }
            )
            if !matchingFinancialAccounts.isEmpty {
                accountEligibleEntryCount += 1
                for accountID in matchingFinancialAccounts {
                    accountStats[accountID, default: SuggestionStats()].record(
                        occurredAt: entry.occurredAt,
                        exactPayeeMatch: exactPayeeMatch
                    )
                }
            }

            let categoryLegIDs: Set<UUID> = Set(
                entry.postings.lazy.compactMap { posting -> UUID? in
                    guard posting.money.currency == query.currency,
                          directions.categorySign.matches(posting.money.amount) else {
                        return nil
                    }
                    return posting.accountID
                }
            )
            // A transaction split across multiple categories is evidence for
            // the split itself, not for choosing one category for a future
            // unsplit capture. Exclude that ambiguous vote so repeated A+B
            // splits can never manufacture a high-confidence A or B default.
            if categoryLegIDs.count == 1,
               let categoryID = categoryLegIDs.first,
               categoryAccountIDs.contains(categoryID) {
                categoryEligibleEntryCount += 1
                categoryStats[categoryID, default: SuggestionStats()].record(
                    occurredAt: entry.occurredAt,
                    exactPayeeMatch: exactPayeeMatch
                )
            }
        }

        return CaptureSuggestionResult(
            queryFingerprint: query.fingerprint,
            accountSuggestion: bestSuggestion(
                from: accountStats,
                eligibleEntryCount: accountEligibleEntryCount,
                usedPayeeHistory: usesPayeeHistory
            ),
            categorySuggestion: bestSuggestion(
                from: categoryStats,
                eligibleEntryCount: categoryEligibleEntryCount,
                usedPayeeHistory: usesPayeeHistory
            )
        )
    }

    private static func directions(
        for kind: CaptureIntelligenceKind
    ) -> SuggestionDirections? {
        switch kind {
        case .expense:
            SuggestionDirections(
                journalKind: .expense,
                categoryKind: .expense,
                accountSign: .negative,
                categorySign: .positive
            )
        case .income:
            SuggestionDirections(
                journalKind: .income,
                categoryKind: .income,
                accountSign: .positive,
                categorySign: .negative
            )
        case .refund:
            SuggestionDirections(
                journalKind: .expense,
                categoryKind: .expense,
                accountSign: .positive,
                categorySign: .negative
            )
        case .transfer, .foreignCurrencyTransfer:
            nil
        }
    }

    private static func unambiguousAccounts(
        _ accounts: [LedgerAccount]
    ) -> [UUID: LedgerAccount] {
        let grouped = Dictionary(grouping: accounts, by: \.id)
        return grouped.reduce(into: [:]) { result, pair in
            guard pair.value.count == 1, let account = pair.value.first else { return }
            result[pair.key] = account
        }
    }

    private static func bestSuggestion(
        from stats: [UUID: SuggestionStats],
        eligibleEntryCount: Int,
        usedPayeeHistory: Bool
    ) -> CaptureFieldSuggestion? {
        guard eligibleEntryCount > 0 else { return nil }
        let best = stats.sorted { first, second in
            if first.value.supportingEntryCount != second.value.supportingEntryCount {
                return first.value.supportingEntryCount > second.value.supportingEntryCount
            }
            if first.value.exactPayeeEntryCount != second.value.exactPayeeEntryCount {
                return first.value.exactPayeeEntryCount > second.value.exactPayeeEntryCount
            }
            if first.value.mostRecentUse != second.value.mostRecentUse {
                return first.value.mostRecentUse > second.value.mostRecentUse
            }
            return first.key.uuidString < second.key.uuidString
        }.first
        guard let best else { return nil }

        let evidence = CaptureSuggestionEvidence(
            supportingEntryCount: best.value.supportingEntryCount,
            eligibleEntryCount: eligibleEntryCount,
            exactPayeeEntryCount: best.value.exactPayeeEntryCount,
            mostRecentUse: best.value.mostRecentUse,
            usedPayeeHistory: usedPayeeHistory
        )
        return CaptureFieldSuggestion(
            ledgerAccountID: best.key,
            confidence: confidence(
                support: evidence.supportingEntryCount,
                total: evidence.eligibleEntryCount,
                exactPayeeSupport: evidence.exactPayeeEntryCount,
                usedPayeeHistory: evidence.usedPayeeHistory
            ),
            evidence: evidence
        )
    }

    private static func confidence(
        support: Int,
        total: Int,
        exactPayeeSupport: Int,
        usedPayeeHistory: Bool
    ) -> CaptureConfidence {
        guard support > 0, total > 0 else { return .low }
        let frequencyConfidence: CaptureConfidence
        if support >= 3, support >= roundedUpFraction(total, numerator: 3, denominator: 4) {
            frequencyConfidence = .high
        } else if support >= 2,
                  support >= roundedUpFraction(total, numerator: 1, denominator: 2) {
            frequencyConfidence = .medium
        } else {
            frequencyConfidence = .low
        }
        // A containment/token match is useful evidence but is not an exact
        // merchant identity. Cap it below the UI's auto-prefill threshold
        // unless at least one supporting entry exactly matches the payee.
        if usedPayeeHistory, exactPayeeSupport == 0 {
            return min(frequencyConfidence, .medium)
        }
        return frequencyConfidence
    }

    /// Computes ceil(value * numerator / denominator) without multiplying the
    /// potentially large input before division.
    private static func roundedUpFraction(
        _ value: Int,
        numerator: Int,
        denominator: Int
    ) -> Int {
        let quotient = value / denominator
        let remainder = value % denominator
        return quotient * numerator
            + (remainder * numerator + denominator - 1) / denominator
    }
}

/// Optional persisted-source identity supplied by an existing capture path.
/// It is evidence only; duplicate detection never creates or stores one.
public struct CaptureSourceReference: Equatable, Sendable {
    public let system: String
    public let fingerprint: String

    public init(system: String, fingerprint: String) {
        self.system = system.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fingerprint = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate var isUsable: Bool {
        !system.isEmpty && !fingerprint.isEmpty
    }
}

public enum CaptureDuplicateQueryError: Error, Equatable, Sendable {
    case accountsMustDiffer
    case foreignTransferCurrenciesMustDiffer
    case tradingAccountsMustDiffer
    case invalidEventDate
}

/// A validated, immutable description of an uncommitted capture.
///
/// Static factories prevent impossible combinations while the public fields
/// let the UI recheck exactly what an advisory was based on. All amounts are
/// positive, new-write-policy-compliant `Money` values.
public struct CaptureDuplicateQuery: Equatable, Sendable {
    public let kind: CaptureIntelligenceKind
    public let occurredAt: Date
    /// Payee for expense/income/refund; note for transfers.
    public let descriptor: String?
    public let sourceReference: CaptureSourceReference?
    public let sourceAmount: Money
    public let sourceAccountID: UUID
    public let categoryID: UUID?
    public let destinationAmount: Money?
    public let destinationAccountID: UUID?
    public let sourceTradingAccountID: UUID?
    public let destinationTradingAccountID: UUID?

    private init(
        kind: CaptureIntelligenceKind,
        occurredAt: Date,
        descriptor: String?,
        sourceReference: CaptureSourceReference?,
        sourceAmount: Money,
        sourceAccountID: UUID,
        categoryID: UUID?,
        destinationAmount: Money?,
        destinationAccountID: UUID?,
        sourceTradingAccountID: UUID?,
        destinationTradingAccountID: UUID?
    ) {
        self.kind = kind
        self.occurredAt = occurredAt
        self.descriptor = CaptureCanonicalText.nonEmptyOriginal(descriptor)
        self.sourceReference = sourceReference?.isUsable == true ? sourceReference : nil
        self.sourceAmount = sourceAmount
        self.sourceAccountID = sourceAccountID
        self.categoryID = categoryID
        self.destinationAmount = destinationAmount
        self.destinationAccountID = destinationAccountID
        self.sourceTradingAccountID = sourceTradingAccountID
        self.destinationTradingAccountID = destinationTradingAccountID
    }

    public static func expense(
        amount: Money,
        paidFrom accountID: UUID,
        category categoryID: UUID? = nil,
        occurredAt: Date = Date(),
        payee: String? = nil,
        sourceReference: CaptureSourceReference? = nil
    ) throws -> CaptureDuplicateQuery {
        try validatePositiveNewWrite(amount)
        try validateOccurredAt(occurredAt)
        return CaptureDuplicateQuery(
            kind: .expense,
            occurredAt: occurredAt,
            descriptor: payee,
            sourceReference: sourceReference,
            sourceAmount: amount,
            sourceAccountID: accountID,
            categoryID: categoryID,
            destinationAmount: nil,
            destinationAccountID: nil,
            sourceTradingAccountID: nil,
            destinationTradingAccountID: nil
        )
    }

    public static func income(
        amount: Money,
        depositedInto accountID: UUID,
        category categoryID: UUID? = nil,
        occurredAt: Date = Date(),
        payee: String? = nil,
        sourceReference: CaptureSourceReference? = nil
    ) throws -> CaptureDuplicateQuery {
        try validatePositiveNewWrite(amount)
        try validateOccurredAt(occurredAt)
        return CaptureDuplicateQuery(
            kind: .income,
            occurredAt: occurredAt,
            descriptor: payee,
            sourceReference: sourceReference,
            sourceAmount: amount,
            sourceAccountID: accountID,
            categoryID: categoryID,
            destinationAmount: nil,
            destinationAccountID: nil,
            sourceTradingAccountID: nil,
            destinationTradingAccountID: nil
        )
    }

    public static func refund(
        amount: Money,
        returnedTo accountID: UUID,
        category categoryID: UUID? = nil,
        occurredAt: Date = Date(),
        payee: String? = nil,
        sourceReference: CaptureSourceReference? = nil
    ) throws -> CaptureDuplicateQuery {
        try validatePositiveNewWrite(amount)
        try validateOccurredAt(occurredAt)
        return CaptureDuplicateQuery(
            kind: .refund,
            occurredAt: occurredAt,
            descriptor: payee,
            sourceReference: sourceReference,
            sourceAmount: amount,
            sourceAccountID: accountID,
            categoryID: categoryID,
            destinationAmount: nil,
            destinationAccountID: nil,
            sourceTradingAccountID: nil,
            destinationTradingAccountID: nil
        )
    }

    public static func transfer(
        amount: Money,
        from sourceAccountID: UUID,
        to destinationAccountID: UUID,
        occurredAt: Date = Date(),
        note: String? = nil,
        sourceReference: CaptureSourceReference? = nil
    ) throws -> CaptureDuplicateQuery {
        try validatePositiveNewWrite(amount)
        try validateOccurredAt(occurredAt)
        guard sourceAccountID != destinationAccountID else {
            throw CaptureDuplicateQueryError.accountsMustDiffer
        }
        return CaptureDuplicateQuery(
            kind: .transfer,
            occurredAt: occurredAt,
            descriptor: note,
            sourceReference: sourceReference,
            sourceAmount: amount,
            sourceAccountID: sourceAccountID,
            categoryID: nil,
            destinationAmount: amount,
            destinationAccountID: destinationAccountID,
            sourceTradingAccountID: nil,
            destinationTradingAccountID: nil
        )
    }

    public static func foreignCurrencyTransfer(
        sourceAmount: Money,
        destinationAmount: Money,
        from sourceAccountID: UUID,
        to destinationAccountID: UUID,
        sourceTradingAccountID: UUID,
        destinationTradingAccountID: UUID,
        occurredAt: Date = Date(),
        note: String? = nil,
        sourceReference: CaptureSourceReference? = nil
    ) throws -> CaptureDuplicateQuery {
        try validatePositiveNewWrite(sourceAmount)
        try validatePositiveNewWrite(destinationAmount)
        try validateOccurredAt(occurredAt)
        guard sourceAccountID != destinationAccountID else {
            throw CaptureDuplicateQueryError.accountsMustDiffer
        }
        guard sourceAmount.currency != destinationAmount.currency else {
            throw CaptureDuplicateQueryError.foreignTransferCurrenciesMustDiffer
        }
        guard sourceTradingAccountID != destinationTradingAccountID else {
            throw CaptureDuplicateQueryError.tradingAccountsMustDiffer
        }
        return CaptureDuplicateQuery(
            kind: .foreignCurrencyTransfer,
            occurredAt: occurredAt,
            descriptor: note,
            sourceReference: sourceReference,
            sourceAmount: sourceAmount,
            sourceAccountID: sourceAccountID,
            categoryID: nil,
            destinationAmount: destinationAmount,
            destinationAccountID: destinationAccountID,
            sourceTradingAccountID: sourceTradingAccountID,
            destinationTradingAccountID: destinationTradingAccountID
        )
    }

    /// A stable, non-cryptographic token for stale-result checks. It contains
    /// every field that affects matching but exposes none of those fields.
    public var fingerprint: String {
        CaptureFingerprint.make(fields: [
            "duplicate-v1",
            kind.rawValue,
            CaptureFingerprint.dateKey(occurredAt),
            CaptureCanonicalText.key(descriptor),
            sourceReference.flatMap { CaptureCanonicalText.key($0.system) },
            sourceReference?.fingerprint,
            CaptureFingerprint.moneyKey(sourceAmount),
            sourceAccountID.uuidString.lowercased(),
            categoryID?.uuidString.lowercased(),
            destinationAmount.map(CaptureFingerprint.moneyKey),
            destinationAccountID?.uuidString.lowercased(),
            sourceTradingAccountID?.uuidString.lowercased(),
            destinationTradingAccountID?.uuidString.lowercased()
        ])
    }

    private static func validatePositiveNewWrite(_ money: Money) throws {
        guard money.amount > .zero else {
            throw TransactionFactoryError.amountMustBePositive
        }
        try MonetaryInputPolicy.validate(money.amount, currency: money.currency)
    }

    private static func validateOccurredAt(_ occurredAt: Date) throws {
        guard occurredAt.timeIntervalSinceReferenceDate.isFinite else {
            throw CaptureDuplicateQueryError.invalidEventDate
        }
    }
}

/// Inspectable facts explaining why an existing entry was surfaced.
public struct CaptureDuplicateEvidence: Equatable, Sendable {
    public let timeDifference: TimeInterval
    /// Exact amount, currency, direction, and required account legs matched.
    public let movementMatched: Bool
    /// Applicable to expense, income, and refund; false for transfers.
    public let categoryMatched: Bool
    /// Normalized payee or transfer note matched exactly.
    public let descriptorMatched: Bool
    /// Existing source system and fingerprint matched the supplied reference.
    public let sourceMatched: Bool

    public init(
        timeDifference: TimeInterval,
        movementMatched: Bool,
        categoryMatched: Bool,
        descriptorMatched: Bool,
        sourceMatched: Bool
    ) {
        self.timeDifference = timeDifference
        self.movementMatched = movementMatched
        self.categoryMatched = categoryMatched
        self.descriptorMatched = descriptorMatched
        self.sourceMatched = sourceMatched
    }
}

public struct CaptureDuplicateMatch: Equatable, Sendable {
    public let entryID: UUID
    public let confidence: CaptureConfidence
    public let evidence: CaptureDuplicateEvidence

    public init(
        entryID: UUID,
        confidence: CaptureConfidence,
        evidence: CaptureDuplicateEvidence
    ) {
        self.entryID = entryID
        self.confidence = confidence
        self.evidence = evidence
    }
}

public struct CaptureDuplicateResult: Equatable, Sendable {
    public let queryFingerprint: String
    public let matches: [CaptureDuplicateMatch]

    public init(queryFingerprint: String, matches: [CaptureDuplicateMatch]) {
        self.queryFingerprint = queryFingerprint
        self.matches = matches
    }

    public var hasAdvisory: Bool { !matches.isEmpty }
}

/// Pure advisory duplicate detection over the caller's bounded ledger view.
///
/// A match never blocks saving. Amounts and currencies must match exactly;
/// there is no conversion, rounding, or inferred exchange rate. Ordinary
/// history is bounded by `maximumTimeInterval`; an explicit source fingerprint
/// can still identify a replay outside that window.
public enum CaptureDuplicateDetector {
    public static let defaultMaximumTimeInterval: TimeInterval = 86_400
    public static let shortTimeInterval: TimeInterval = 600

    public static func matches(
        for query: CaptureDuplicateQuery,
        in entries: [JournalEntry],
        excludingEntryID: UUID? = nil,
        maximumTimeInterval: TimeInterval = 86_400
    ) -> CaptureDuplicateResult {
        guard maximumTimeInterval.isFinite, maximumTimeInterval >= 0 else {
            return CaptureDuplicateResult(
                queryFingerprint: query.fingerprint,
                matches: []
            )
        }

        let matches = entries.compactMap { entry -> CaptureDuplicateMatch? in
            guard entry.id != excludingEntryID else { return nil }
            return match(
                query: query,
                entry: entry,
                maximumTimeInterval: maximumTimeInterval
            )
        }.sorted { first, second in
            if first.confidence != second.confidence {
                return first.confidence > second.confidence
            }
            if first.evidence.timeDifference != second.evidence.timeDifference {
                return first.evidence.timeDifference < second.evidence.timeDifference
            }
            return first.entryID.uuidString < second.entryID.uuidString
        }

        return CaptureDuplicateResult(
            queryFingerprint: query.fingerprint,
            matches: matches
        )
    }

    private static func match(
        query: CaptureDuplicateQuery,
        entry: JournalEntry,
        maximumTimeInterval: TimeInterval
    ) -> CaptureDuplicateMatch? {
        let timeDifference = abs(entry.occurredAt.timeIntervalSince(query.occurredAt))
        let sourceMatched = sourceMatches(query.sourceReference, entry: entry)
        guard sourceMatched || timeDifference <= maximumTimeInterval else { return nil }
        guard movementMatches(query: query, entry: entry) else { return nil }

        let categoryMatched = categoryMatches(query: query, entry: entry)
        let entryDescriptor = query.kind == .expense
            || query.kind == .income
            || query.kind == .refund
            ? entry.payee
            : entry.note
        let descriptorMatched = CaptureCanonicalText.key(query.descriptor) != nil
            && CaptureCanonicalText.key(query.descriptor)
                == CaptureCanonicalText.key(entryDescriptor)

        let confidence: CaptureConfidence?
        if sourceMatched {
            confidence = .high
        } else {
            switch query.kind {
            case .expense, .income, .refund:
                if categoryMatched && descriptorMatched {
                    confidence = timeDifference <= shortTimeInterval ? .high : .medium
                } else if descriptorMatched {
                    confidence = .medium
                } else if timeDifference <= shortTimeInterval,
                          categoryMatched || query.categoryID == nil {
                    confidence = .low
                } else {
                    confidence = nil
                }
            case .transfer, .foreignCurrencyTransfer:
                if descriptorMatched {
                    confidence = timeDifference <= shortTimeInterval ? .high : .medium
                } else if timeDifference <= shortTimeInterval {
                    confidence = .low
                } else {
                    confidence = nil
                }
            }
        }
        guard let confidence else { return nil }

        return CaptureDuplicateMatch(
            entryID: entry.id,
            confidence: confidence,
            evidence: CaptureDuplicateEvidence(
                timeDifference: timeDifference,
                movementMatched: true,
                categoryMatched: categoryMatched,
                descriptorMatched: descriptorMatched,
                sourceMatched: sourceMatched
            )
        )
    }

    private static func movementMatches(
        query: CaptureDuplicateQuery,
        entry: JournalEntry
    ) -> Bool {
        switch query.kind {
        case .expense:
            return entry.kind == .expense
                && hasPosting(
                    in: entry,
                    accountID: query.sourceAccountID,
                    money: query.sourceAmount.negated
                )
        case .income:
            return entry.kind == .income
                && hasPosting(
                    in: entry,
                    accountID: query.sourceAccountID,
                    money: query.sourceAmount
                )
        case .refund:
            return entry.kind == .expense
                && hasPosting(
                    in: entry,
                    accountID: query.sourceAccountID,
                    money: query.sourceAmount
                )
        case .transfer:
            guard entry.kind == .transfer,
                  entry.postings.count == 2,
                  let destinationAccountID = query.destinationAccountID else {
                return false
            }
            return hasPosting(
                in: entry,
                accountID: query.sourceAccountID,
                money: query.sourceAmount.negated
            ) && hasPosting(
                in: entry,
                accountID: destinationAccountID,
                money: query.sourceAmount
            )
        case .foreignCurrencyTransfer:
            guard entry.kind == .transfer,
                  entry.postings.count == 4,
                  let destinationAmount = query.destinationAmount,
                  let destinationAccountID = query.destinationAccountID,
                  let sourceTradingAccountID = query.sourceTradingAccountID,
                  let destinationTradingAccountID = query.destinationTradingAccountID else {
                return false
            }
            return hasPosting(
                in: entry,
                accountID: query.sourceAccountID,
                money: query.sourceAmount.negated
            ) && hasPosting(
                in: entry,
                accountID: sourceTradingAccountID,
                money: query.sourceAmount
            ) && hasPosting(
                in: entry,
                accountID: destinationTradingAccountID,
                money: destinationAmount.negated
            ) && hasPosting(
                in: entry,
                accountID: destinationAccountID,
                money: destinationAmount
            )
        }
    }

    private static func categoryMatches(
        query: CaptureDuplicateQuery,
        entry: JournalEntry
    ) -> Bool {
        guard let categoryID = query.categoryID else { return false }
        switch query.kind {
        case .expense:
            return entry.postings.contains { posting in
                posting.accountID == categoryID
                    && posting.money.currency == query.sourceAmount.currency
                    && posting.money.amount > .zero
            }
        case .income, .refund:
            return entry.postings.contains { posting in
                posting.accountID == categoryID
                    && posting.money.currency == query.sourceAmount.currency
                    && posting.money.amount < .zero
            }
        case .transfer, .foreignCurrencyTransfer:
            return false
        }
    }

    private static func hasPosting(
        in entry: JournalEntry,
        accountID: UUID,
        money: Money
    ) -> Bool {
        entry.postings.contains { posting in
            posting.accountID == accountID && posting.money == money
        }
    }

    private static func sourceMatches(
        _ sourceReference: CaptureSourceReference?,
        entry: JournalEntry
    ) -> Bool {
        guard let sourceReference,
              sourceReference.isUsable,
              let entrySystem = entry.sourceSystem,
              let entryFingerprint = entry.sourceFingerprint else {
            return false
        }
        return CaptureCanonicalText.key(sourceReference.system)
                == CaptureCanonicalText.key(entrySystem)
            && sourceReference.fingerprint == entryFingerprint
    }
}

private struct SuggestionStats {
    var supportingEntryCount = 0
    var exactPayeeEntryCount = 0
    var mostRecentUse = Date.distantPast

    mutating func record(occurredAt: Date, exactPayeeMatch: Bool) {
        supportingEntryCount += 1
        if exactPayeeMatch { exactPayeeEntryCount += 1 }
        mostRecentUse = max(mostRecentUse, occurredAt)
    }
}

private struct SuggestionDirections {
    let journalKind: JournalEntryKind
    let categoryKind: LedgerAccountKind
    let accountSign: CaptureAmountSign
    let categorySign: CaptureAmountSign
}

private enum CaptureAmountSign {
    case positive
    case negative

    func matches(_ amount: Decimal) -> Bool {
        switch self {
        case .positive: amount > .zero
        case .negative: amount < .zero
        }
    }
}

private enum CaptureCanonicalText {
    private static let cjkRanges: [ClosedRange<UInt32>] = [
        0x3400...0x4DBF,
        0x4E00...0x9FFF,
        0xF900...0xFAFF
    ]

    static func nonEmptyOriginal(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func key(_ text: String?) -> String? {
        guard let text = nonEmptyOriginal(text) else { return nil }
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        var pieces: [String] = []
        var current = ""
        for character in folded.lowercased(with: Locale(identifier: "en_US_POSIX")) {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                pieces.append(current)
                current = ""
            }
        }
        if !current.isEmpty { pieces.append(current) }
        let result = pieces.joined(separator: " ")
        return result.isEmpty ? nil : result
    }

    static func isMeaningfulPayeeKey(_ key: String?) -> Bool {
        guard let key else { return false }
        if containsCJK(key) { return true }
        return key.filter { $0.isLetter || $0.isNumber }.count >= 2
    }

    static func payeeMatches(_ stored: String?, _ query: String) -> Bool {
        guard let stored else { return false }
        if stored == query { return true }
        if containsCJK(stored) || containsCJK(query) {
            return stored.contains(query) || query.contains(stored)
        }
        guard stored.count >= 3, query.count >= 3 else { return false }
        return tokenSequence(query, appearsIn: stored)
            || tokenSequence(stored, appearsIn: query)
    }

    private static func tokenSequence(_ needle: String, appearsIn haystack: String) -> Bool {
        haystack == needle
            || haystack.hasPrefix(needle + " ")
            || haystack.hasSuffix(" " + needle)
            || haystack.contains(" " + needle + " ")
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            cjkRanges.contains { $0.contains(scalar.value) }
        }
    }
}

private enum CaptureFingerprint {
    private static let offsetBasis: UInt64 = 14_695_981_039_346_656_037
    private static let prime: UInt64 = 1_099_511_628_211

    static func make(fields: [String?]) -> String {
        var hash = offsetBasis
        for field in fields {
            let bytes = Array((field ?? "<nil>").utf8)
            for byte in String(bytes.count).utf8 {
                hash ^= UInt64(byte)
                hash = hash &* prime
            }
            hash ^= 0x3A
            hash = hash &* prime
            for byte in bytes {
                hash ^= UInt64(byte)
                hash = hash &* prime
            }
            hash ^= 0x7C
            hash = hash &* prime
        }
        return "moneyup-capture-v1-" + String(format: "%016llx", hash)
    }

    static func dateKey(_ date: Date) -> String {
        String(date.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
    }

    static func moneyKey(_ money: Money) -> String {
        money.currency.value + ":" + NSDecimalNumber(decimal: money.amount).stringValue
    }
}
