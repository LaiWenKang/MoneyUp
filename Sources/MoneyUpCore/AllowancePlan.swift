import Foundation

public enum AllowanceCadence: String, Codable, CaseIterable, Hashable, Sendable {
    case daily
    case weekdays
    case weekly
    case monthly
}

public enum AllowanceRolloverRule: String, Codable, CaseIterable, Hashable, Sendable {
    case none
    case capped
    case full
}

public enum AllowancePlanError: Error, Equatable, Sendable {
    case emptyName
    case amountMustBePositive
    case invalidDate
    case invalidTimeZone
    case invalidRolloverCap
    case tooManyCategories
    case tooManyUsages
    case usageAmountMustBePositive
    case currencyMismatch
    case usageBeforeStart
    case usageAfterEnd
}

/// Optional evidence that a non-cash allowance was consumed. A linked journal
/// entry can record the user's actual out-of-pocket expense, while an
/// allowance-only usage deliberately has no effect on cash, income, or net
/// worth.
public struct AllowanceUsage: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let amount: Money
    public let occurredAt: Date
    public let categoryID: UUID?
    public let linkedJournalEntryID: UUID?
    public let note: String?

    public init(
        id: UUID = UUID(),
        amount: Money,
        occurredAt: Date,
        categoryID: UUID? = nil,
        linkedJournalEntryID: UUID? = nil,
        note: String? = nil
    ) throws {
        guard amount.amount > .zero else {
            throw AllowancePlanError.usageAmountMustBePositive
        }
        guard occurredAt.timeIntervalSinceReferenceDate.isFinite else {
            throw AllowancePlanError.invalidDate
        }
        self.id = id
        self.amount = amount
        self.occurredAt = occurredAt
        self.categoryID = categoryID
        self.linkedJournalEntryID = linkedJournalEntryID
        let normalizedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.note = normalizedNote?.isEmpty == false ? normalizedNote : nil
    }
}

public struct AllowanceSummary: Equatable, Sendable {
    public let interval: DateInterval?
    public let entitlement: Money
    public let used: Money
    public let remaining: Money
    public let isAvailableToday: Bool

    public init(
        interval: DateInterval?,
        entitlement: Money,
        used: Money,
        remaining: Money,
        isAvailableToday: Bool
    ) {
        self.interval = interval
        self.entitlement = entitlement
        self.used = used
        self.remaining = remaining
        self.isAvailableToday = isAvailableToday
    }
}

/// A planning-only benefit such as an employer meal allowance. It is never a
/// financial account and therefore cannot silently inflate income or net worth.
public struct AllowancePlan: Codable, Equatable, Identifiable, Sendable {
    public static let maximumEligibleCategoryCount = 1_024
    public static let maximumUsageCount = 4_096

    public let id: UUID
    public var name: String
    public var amount: Money
    public var cadence: AllowanceCadence
    public var startsAt: Date
    public var endsAt: Date?
    public var timeZoneIdentifier: String
    public var eligibleCategoryIDs: Set<UUID>
    public var rolloverRule: AllowanceRolloverRule
    public var rolloverCap: Money?
    public private(set) var usages: [AllowanceUsage]
    public var isArchived: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        amount: Money,
        cadence: AllowanceCadence,
        startsAt: Date,
        endsAt: Date? = nil,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        eligibleCategoryIDs: Set<UUID> = [],
        rolloverRule: AllowanceRolloverRule = .none,
        rolloverCap: Money? = nil,
        usages: [AllowanceUsage] = [],
        isArchived: Bool = false
    ) throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { throw AllowancePlanError.emptyName }
        guard amount.amount > .zero else {
            throw AllowancePlanError.amountMustBePositive
        }
        guard startsAt.timeIntervalSinceReferenceDate.isFinite,
              endsAt?.timeIntervalSinceReferenceDate.isFinite != false,
              endsAt.map({ $0 > startsAt }) ?? true else {
            throw AllowancePlanError.invalidDate
        }
        guard TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw AllowancePlanError.invalidTimeZone
        }
        guard eligibleCategoryIDs.count <= Self.maximumEligibleCategoryCount else {
            throw AllowancePlanError.tooManyCategories
        }
        guard usages.count <= Self.maximumUsageCount else {
            throw AllowancePlanError.tooManyUsages
        }
        if rolloverRule == .capped {
            guard let rolloverCap,
                  rolloverCap.currency == amount.currency,
                  rolloverCap.amount >= .zero else {
                throw AllowancePlanError.invalidRolloverCap
            }
        } else if rolloverCap != nil {
            throw AllowancePlanError.invalidRolloverCap
        }
        guard usages.allSatisfy({ usage in
            usage.amount.currency == amount.currency
                && usage.occurredAt >= startsAt
                && (endsAt.map { usage.occurredAt < $0 } ?? true)
        }) else { throw AllowancePlanError.currencyMismatch }

        self.id = id
        self.name = normalizedName
        self.amount = amount
        self.cadence = cadence
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.eligibleCategoryIDs = eligibleCategoryIDs
        self.rolloverRule = rolloverRule
        self.rolloverCap = rolloverCap
        self.usages = usages.sorted { $0.occurredAt < $1.occurredAt }
        self.isArchived = isArchived
    }

    public func addingUsage(_ usage: AllowanceUsage) throws -> AllowancePlan {
        guard usages.count < Self.maximumUsageCount else {
            throw AllowancePlanError.tooManyUsages
        }
        guard usage.amount.currency == amount.currency else {
            throw AllowancePlanError.currencyMismatch
        }
        guard usage.occurredAt >= startsAt else {
            throw AllowancePlanError.usageBeforeStart
        }
        guard endsAt.map({ usage.occurredAt < $0 }) ?? true else {
            throw AllowancePlanError.usageAfterEnd
        }
        var copy = self
        copy.usages.append(usage)
        copy.usages.sort { $0.occurredAt < $1.occurredAt }
        return copy
    }

    public func summary(asOf: Date) throws -> AllowanceSummary {
        var calendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: timeZoneIdentifier
        )
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let zero = Money.zero(currency: amount.currency)
        guard !isArchived,
              asOf >= startsAt,
              endsAt.map({ asOf < $0 }) ?? true,
              let interval = activeInterval(containing: asOf, calendar: calendar) else {
            return AllowanceSummary(
                interval: nil,
                entitlement: zero,
                used: zero,
                remaining: zero,
                isAvailableToday: false
            )
        }

        let currentUsed = try totalUsage(in: interval)
        let carry = try carryEntering(interval.start, calendar: calendar)
        let entitlement = try amount.adding(carry)
        let remaining = try entitlement.subtracting(currentUsed)
        return AllowanceSummary(
            interval: interval,
            entitlement: entitlement,
            used: currentUsed,
            remaining: remaining,
            isAvailableToday: true
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, amount, cadence, startsAt, endsAt, timeZoneIdentifier
        case eligibleCategoryIDs, rolloverRule, rolloverCap, usages, isArchived
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(UUID.self, forKey: .id),
                name: container.decode(String.self, forKey: .name),
                amount: container.decode(Money.self, forKey: .amount),
                cadence: container.decode(AllowanceCadence.self, forKey: .cadence),
                startsAt: container.decode(Date.self, forKey: .startsAt),
                endsAt: container.decodeIfPresent(Date.self, forKey: .endsAt),
                timeZoneIdentifier: container.decode(
                    String.self,
                    forKey: .timeZoneIdentifier
                ),
                eligibleCategoryIDs: container.decodeIfPresent(
                    Set<UUID>.self,
                    forKey: .eligibleCategoryIDs
                ) ?? [],
                rolloverRule: container.decodeIfPresent(
                    AllowanceRolloverRule.self,
                    forKey: .rolloverRule
                ) ?? .none,
                rolloverCap: container.decodeIfPresent(
                    Money.self,
                    forKey: .rolloverCap
                ),
                usages: container.decodeIfPresent(
                    [AllowanceUsage].self,
                    forKey: .usages
                ) ?? [],
                isArchived: container.decodeIfPresent(
                    Bool.self,
                    forKey: .isArchived
                ) ?? false
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .amount,
                in: container,
                debugDescription: "Invalid allowance plan."
            )
        }
    }

    private func activeInterval(containing date: Date, calendar: Calendar) -> DateInterval? {
        let day = calendar.startOfDay(for: date)
        switch cadence {
        case .daily:
            guard let end = calendar.date(byAdding: .day, value: 1, to: day) else {
                return nil
            }
            return clipped(DateInterval(start: day, end: end))
        case .weekdays:
            let weekday = calendar.component(.weekday, from: day)
            guard weekday != 1 && weekday != 7,
                  let end = calendar.date(byAdding: .day, value: 1, to: day) else {
                return nil
            }
            return clipped(DateInterval(start: day, end: end))
        case .weekly:
            guard let days = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: startsAt),
                to: day
            ).day else { return nil }
            let index = max(days, 0) / 7
            guard let start = calendar.date(
                byAdding: .day,
                value: index * 7,
                to: calendar.startOfDay(for: startsAt)
            ), let end = calendar.date(byAdding: .day, value: 7, to: start) else {
                return nil
            }
            return clipped(DateInterval(start: start, end: end))
        case .monthly:
            return calendar.dateInterval(of: .month, for: date).flatMap(clipped)
        }
    }

    private func clipped(_ interval: DateInterval) -> DateInterval? {
        let start = max(interval.start, startsAt)
        let end = min(interval.end, endsAt ?? interval.end)
        guard start < end else { return nil }
        return DateInterval(start: start, end: end)
    }

    private func totalUsage(in interval: DateInterval) throws -> Money {
        var total = Decimal.zero
        for usage in usages where FinancialPeriodBoundary.contains(
            usage.occurredAt,
            in: interval
        ) {
            total = try CheckedDecimal.adding(total, usage.amount.amount)
        }
        return try Money(total, currency: amount.currency)
    }

    private func carryEntering(_ currentStart: Date, calendar: Calendar) throws -> Money {
        guard rolloverRule != .none else {
            return .zero(currency: amount.currency)
        }
        var entitlement = Decimal.zero
        var cursor = startsAt
        var periods = 0
        while cursor < currentStart {
            guard periods < 10_000,
                  let interval = activeInterval(containing: cursor, calendar: calendar) else {
                // Weekends have no weekday allowance; advance one civil day.
                guard cadence == .weekdays,
                      let next = calendar.date(byAdding: .day, value: 1, to: cursor) else {
                    throw AllowancePlanError.invalidDate
                }
                cursor = next
                continue
            }
            guard interval.start < currentStart else { break }
            entitlement = try CheckedDecimal.adding(entitlement, amount.amount)
            let used = try totalUsage(in: interval)
            entitlement = max(
                .zero,
                try CheckedDecimal.subtracting(entitlement, used.amount)
            )
            if rolloverRule == .capped, let rolloverCap {
                entitlement = min(entitlement, rolloverCap.amount)
            }
            cursor = interval.end
            periods += 1
        }
        return try Money(entitlement, currency: amount.currency)
    }
}
