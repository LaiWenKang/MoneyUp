import Foundation

public enum JournalEntryKind: String, Codable, CaseIterable, Sendable {
    case expense
    case income
    case transfer
    case adjustment
    case investment
}

public enum JournalEntryValidationError: Error, Equatable {
    case tooFewPostings
    case duplicatePostingID(UUID)
    case zeroPosting(UUID)
    case unbalanced(currency: CurrencyCode, residual: Decimal)
    case arithmeticOverflow(currency: CurrencyCode)
    case invalidEventDate
    case originContextMismatch
}

/// An immutable, balanced financial event.
///
/// Edits should be implemented by replacing an entry through the persistence
/// layer while retaining revision metadata. Mutating postings directly would
/// make audit and reconciliation behavior ambiguous.
public struct JournalEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: JournalEntryKind
    public let occurredAt: Date
    public let createdAt: Date
    public let payee: String?
    public let note: String?
    public let postings: [Posting]
    public let supersedesID: UUID?
    public let revisedAt: Date?
    public let sourceSystem: String?
    public let sourceFingerprint: String?
    public let originContext: TransactionOriginContext

    public init(
        id: UUID = UUID(),
        kind: JournalEntryKind,
        occurredAt: Date = Date(),
        createdAt: Date = Date(),
        payee: String? = nil,
        note: String? = nil,
        postings: [Posting],
        supersedesID: UUID? = nil,
        revisedAt: Date? = nil,
        sourceSystem: String? = nil,
        sourceFingerprint: String? = nil,
        originContext: TransactionOriginContext? = nil
    ) throws {
        try Self.validate(postings)
        guard occurredAt.timeIntervalSinceReferenceDate.isFinite,
              createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw JournalEntryValidationError.invalidEventDate
        }
        if let revisedAt,
           !revisedAt.timeIntervalSinceReferenceDate.isFinite {
            throw JournalEntryValidationError.invalidEventDate
        }
        let capturedOrigin = originContext ?? .capture(for: occurredAt)
        do {
            try capturedOrigin.validate(eventDate: occurredAt)
        } catch {
            throw JournalEntryValidationError.originContextMismatch
        }

        self.id = id
        self.kind = kind
        self.occurredAt = occurredAt
        self.createdAt = createdAt
        self.payee = payee
        self.note = note
        self.postings = postings
        self.supersedesID = supersedesID
        self.revisedAt = revisedAt
        self.sourceSystem = sourceSystem
        self.sourceFingerprint = sourceFingerprint
        self.originContext = capturedOrigin
    }

    /// Residual balance per currency. A valid entry always contains only zero
    /// values, but this remains useful for diagnostics and export validation.
    public var balanceByCurrency: [CurrencyCode: Decimal] {
        do {
            return try Self.checkedBalanceByCurrency(
                for: postings,
                checkingCancellation: false
            )
        } catch {
            // Construction and decoding both run the same checked aggregation,
            // so reaching this branch would mean the immutable value's memory
            // no longer matches the validated instance.
            preconditionFailure("Validated journal balance became unrepresentable")
        }
    }

    private static func validate(_ postings: [Posting]) throws {
        guard postings.count >= 2 else {
            throw JournalEntryValidationError.tooFewPostings
        }

        var postingIDs = Set<UUID>()
        for posting in postings {
            guard postingIDs.insert(posting.id).inserted else {
                throw JournalEntryValidationError.duplicatePostingID(posting.id)
            }
            guard !posting.money.isZero else {
                throw JournalEntryValidationError.zeroPosting(posting.id)
            }
        }

        let balances = try checkedBalanceByCurrency(
            for: postings,
            checkingCancellation: true
        )
        for currency in balances.keys.sorted() {
            let residual = balances[currency, default: .zero]
            if residual != .zero {
                throw JournalEntryValidationError.unbalanced(
                    currency: currency,
                    residual: residual
                )
            }
        }
    }

    private static func checkedBalanceByCurrency(
        for postings: [Posting],
        checkingCancellation: Bool
    ) throws -> [CurrencyCode: Decimal] {
        var balances: [CurrencyCode: Decimal] = [:]
        for posting in postings {
            let currency = posting.money.currency
            do {
                if checkingCancellation {
                    balances[currency] = try CheckedDecimal.adding(
                        balances[currency] ?? .zero,
                        posting.money.amount
                    )
                } else {
                    balances[currency] = try CheckedDecimal.addingUninterruptibly(
                        balances[currency] ?? .zero,
                        posting.money.amount
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw JournalEntryValidationError.arithmeticOverflow(
                    currency: currency
                )
            }
        }
        return balances
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case occurredAt
        case createdAt
        case payee
        case note
        case postings
        case supersedesID
        case revisedAt
        case sourceSystem
        case sourceFingerprint
        case originContext
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let kind = try container.decode(JournalEntryKind.self, forKey: .kind)
        let occurredAt = try container.decode(Date.self, forKey: .occurredAt)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        let payee = try container.decodeIfPresent(String.self, forKey: .payee)
        let note = try container.decodeIfPresent(String.self, forKey: .note)
        let postings = try container.decode([Posting].self, forKey: .postings)
        let supersedesID = try container.decodeIfPresent(UUID.self, forKey: .supersedesID)
        let revisedAt = try container.decodeIfPresent(Date.self, forKey: .revisedAt)
        let sourceSystem = try container.decodeIfPresent(String.self, forKey: .sourceSystem)
        let sourceFingerprint = try container.decodeIfPresent(
            String.self,
            forKey: .sourceFingerprint
        )
        let originContext = try container.decodeIfPresent(
            TransactionOriginContext.self,
            forKey: .originContext
        ) ?? .inferredUTC(for: occurredAt)

        do {
            try self.init(
                id: id,
                kind: kind,
                occurredAt: occurredAt,
                createdAt: createdAt,
                payee: payee,
                note: note,
                postings: postings,
                supersedesID: supersedesID,
                revisedAt: revisedAt,
                sourceSystem: sourceSystem,
                sourceFingerprint: sourceFingerprint,
                originContext: originContext
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .postings,
                in: container,
                debugDescription: "Decoded journal entry violates ledger invariants: \(error)"
            )
        }
    }
}
