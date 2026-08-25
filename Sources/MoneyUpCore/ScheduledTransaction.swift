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
        var offset = 0

        while dates.count < maximumCount,
              let candidate = occurrence(offset: offset, calendar: calendar),
              candidate <= endDate {
            dates.append(candidate)
            offset += 1
        }

        return dates
    }

    /// Returns the first active occurrence that has not already passed.
    ///
    /// `nextOccurrence` is the recurrence anchor stored in the book. It may be
    /// in the past when a schedule has not been advanced after each occurrence,
    /// so presentation code should use this helper instead of displaying the
    /// anchor as though it were still upcoming.
    public func occurrence(
        onOrAfter referenceDate: Date,
        calendar: Calendar = .current
    ) -> Date? {
        guard isActive else { return nil }
        guard referenceDate > nextOccurrence else { return nextOccurrence }

        let offset: Int
        switch frequency {
        case .weekly:
            let days = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: nextOccurrence),
                to: calendar.startOfDay(for: referenceDate)
            ).day ?? 0
            offset = max(0, days / 7)
        case .monthly, .yearly:
            guard let anchorMonth = calendar.dateInterval(
                of: .month,
                for: nextOccurrence
            )?.start,
            let referenceMonth = calendar.dateInterval(
                of: .month,
                for: referenceDate
            )?.start else { return nil }
            let months = calendar.dateComponents(
                [.month],
                from: anchorMonth,
                to: referenceMonth
            ).month ?? 0
            offset = frequency == .monthly ? max(0, months) : max(0, months / 12)
        }

        guard let candidate = occurrence(offset: offset, calendar: calendar) else {
            return nil
        }
        if candidate >= referenceDate { return candidate }
        return occurrence(offset: offset + 1, calendar: calendar)
    }

    /// Direct day predicate used by the interactive calendar. It performs at
    /// most one anchored date calculation instead of generating thousands of
    /// historical occurrences for every SwiftUI render.
    public func occurs(on date: Date, calendar: Calendar = .current) -> Bool {
        guard isActive,
              calendar.startOfDay(for: date) >= calendar.startOfDay(for: nextOccurrence)
        else { return false }

        let offset: Int
        switch frequency {
        case .weekly:
            let days = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: nextOccurrence),
                to: calendar.startOfDay(for: date)
            ).day ?? -1
            guard days >= 0, days.isMultiple(of: 7) else { return false }
            offset = days / 7
        case .monthly, .yearly:
            guard let anchorMonth = calendar.dateInterval(
                of: .month,
                for: nextOccurrence
            )?.start,
            let targetMonth = calendar.dateInterval(of: .month, for: date)?.start else {
                return false
            }
            let months = calendar.dateComponents(
                [.month],
                from: anchorMonth,
                to: targetMonth
            ).month ?? -1
            guard months >= 0 else { return false }
            if frequency == .yearly {
                guard months.isMultiple(of: 12) else { return false }
                offset = months / 12
            } else {
                offset = months
            }
        }
        guard let candidate = occurrence(offset: offset, calendar: calendar) else {
            return false
        }
        return calendar.isDate(candidate, inSameDayAs: date)
    }

    /// Every recurrence is calculated from the original anchor, not from the
    /// prior shortened month. A schedule anchored on 31 January therefore uses
    /// February's last valid day and returns to the 31st in March.
    private func occurrence(offset: Int, calendar: Calendar) -> Date? {
        guard offset >= 0 else { return nil }
        if offset == 0 { return nextOccurrence }
        switch frequency {
        case .weekly:
            return calendar.date(
                byAdding: .weekOfYear,
                value: offset,
                to: nextOccurrence
            )
        case .monthly:
            return monthAnchoredOccurrence(
                monthOffset: offset,
                calendar: calendar
            )
        case .yearly:
            let multiplication = offset.multipliedReportingOverflow(by: 12)
            guard !multiplication.overflow else { return nil }
            return monthAnchoredOccurrence(
                monthOffset: multiplication.partialValue,
                calendar: calendar
            )
        }
    }

    private func monthAnchoredOccurrence(
        monthOffset: Int,
        calendar: Calendar
    ) -> Date? {
        guard let anchorMonth = calendar.dateInterval(
            of: .month,
            for: nextOccurrence
        )?.start,
        let targetMonth = calendar.date(
            byAdding: .month,
            value: monthOffset,
            to: anchorMonth
        ),
        let validDays = calendar.range(of: .day, in: .month, for: targetMonth),
        let lastDay = validDays.last else { return nil }

        let anchor = calendar.dateComponents(
            [.day, .hour, .minute, .second, .nanosecond],
            from: nextOccurrence
        )
        guard let anchorDay = anchor.day else { return nil }

        var target = calendar.dateComponents(
            [.era, .year, .month],
            from: targetMonth
        )
        target.day = min(anchorDay, lastDay)
        target.hour = anchor.hour
        target.minute = anchor.minute
        target.second = anchor.second
        target.nanosecond = anchor.nanosecond
        return calendar.date(from: target)
    }
}
