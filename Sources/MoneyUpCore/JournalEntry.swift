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
        sourceFingerprint: String? = nil
    ) throws {
        try Self.validate(postings)

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
    }

    /// Residual balance per currency. A valid entry always contains only zero
    /// values, but this remains useful for diagnostics and export validation.
    public var balanceByCurrency: [CurrencyCode: Decimal] {
        Self.balanceByCurrency(for: postings)
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

        let balances = balanceByCurrency(for: postings)
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

    private static func balanceByCurrency(
        for postings: [Posting]
    ) -> [CurrencyCode: Decimal] {
        postings.reduce(into: [:]) { balances, posting in
            balances[posting.money.currency, default: .zero] += posting.money.amount
        }
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
                sourceFingerprint: sourceFingerprint
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
