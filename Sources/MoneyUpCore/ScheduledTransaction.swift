import Foundation

public enum RecurrenceFrequency: String, Codable, CaseIterable, Sendable {
    case weekly
    case monthly
    case yearly
}

public enum ScheduledTransactionError: Error, Equatable, Sendable {
    case unsupportedKind
    case amountMustBePositive
    case nameCannotBeEmpty
}

public struct ScheduledTransaction: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var kind: JournalEntryKind
    public var name: String
    public var amount: Money
    public var accountID: UUID
    public var categoryAccountID: UUID
    public var nextOccurrence: Date
    public var frequency: RecurrenceFrequency
    public var isActive: Bool

    public init(
        id: UUID = UUID(),
        kind: JournalEntryKind,
        name: String,
        amount: Money,
        accountID: UUID,
        categoryAccountID: UUID,
        nextOccurrence: Date,
        frequency: RecurrenceFrequency,
        isActive: Bool = true
    ) throws {
        guard kind == .expense || kind == .income else {
            throw ScheduledTransactionError.unsupportedKind
        }
        guard amount.amount > .zero else {
            throw ScheduledTransactionError.amountMustBePositive
        }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw ScheduledTransactionError.nameCannotBeEmpty
        }

        self.id = id
        self.kind = kind
        self.name = normalizedName
        self.amount = amount
        self.accountID = accountID
        self.categoryAccountID = categoryAccountID
        self.nextOccurrence = nextOccurrence
        self.frequency = frequency
        self.isActive = isActive
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case name
        case amount
        case accountID
        case categoryAccountID
        case nextOccurrence
        case frequency
        case isActive
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(UUID.self, forKey: .id),
                kind: container.decode(JournalEntryKind.self, forKey: .kind),
                name: container.decode(String.self, forKey: .name),
                amount: container.decode(Money.self, forKey: .amount),
                accountID: container.decode(UUID.self, forKey: .accountID),
                categoryAccountID: container.decode(UUID.self, forKey: .categoryAccountID),
                nextOccurrence: container.decode(Date.self, forKey: .nextOccurrence),
                frequency: container.decode(RecurrenceFrequency.self, forKey: .frequency),
                isActive: container.decode(Bool.self, forKey: .isActive)
            )
        } catch let error as ScheduledTransactionError {
            throw DecodingError.dataCorruptedError(
                forKey: .amount,
                in: container,
                debugDescription: "Invalid scheduled transaction: \(error)"
            )
        }
    }

    public func occurrences(
        through endDate: Date,
        calendar: Calendar = .current,
        maximumCount: Int = 120
    ) -> [Date] {
        guard isActive, maximumCount > 0, nextOccurrence <= endDate else {
            return []
        }

        var dates: [Date] = []
        var candidate = nextOccurrence

        while candidate <= endDate, dates.count < maximumCount {
            dates.append(candidate)
            let component: Calendar.Component
            switch frequency {
            case .weekly: component = .weekOfYear
            case .monthly: component = .month
            case .yearly: component = .year
            }
            guard let next = calendar.date(byAdding: component, value: 1, to: candidate),
                  next > candidate else {
                break
            }
            candidate = next
        }

        return dates
    }
}
