import Foundation

public enum SavingsGoalKind: String, Codable, CaseIterable, Sendable {
    case savingsGoal
    case sinkingFund
}

/// Defines the automatic boundary from which progress is recomputed. Manual
/// resets are retained as dated events and never erase contribution history.
public enum SavingsGoalResetRule: String, Codable, CaseIterable, Sendable {
    case never
    case monthly
    case yearly
}

public enum SavingsGoalMovementKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case contribution
    case withdrawal

    public var id: String { rawValue }
}

public enum SavingsGoalError: Error, Equatable {
    case emptyName
    case nonPositiveTarget
    case targetBeforeCreation
    case nonPositiveMovement
    case currencyMismatch(expected: CurrencyCode, actual: CurrencyCode)
    case movementBeforeCreation
    case withdrawalExceedsBalance
    case resetBeforeCreation
    case duplicateMovementID
    case duplicateResetID
    case invalidOriginContext
    case invalidDate
    case unsupportedPrecision(CurrencyCode)
    case calculationFailed
}

private enum SavingsGoalOriginDay {
    static func key(for date: Date, timeZoneIdentifier: String) -> String {
        let zone = TimeZone(identifier: timeZoneIdentifier) ?? .gmt
        return key(for: date, utcOffsetSeconds: zone.secondsFromGMT(for: date))
    }

    static func key(for date: Date, utcOffsetSeconds: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: utcOffsetSeconds) ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 1,
            parts.month ?? 1,
            parts.day ?? 1
        )
    }

    static func isValid(_ value: String) -> Bool {
        guard value.range(
            of: #"^[0-9]{4}-((0[1-9])|(1[0-2]))-((0[1-9])|([12][0-9])|(3[01]))$"#,
            options: .regularExpression
        ) != nil else { return false }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        let calendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: "GMT"
        )
        guard let date = calendar.date(from: DateComponents(
            year: parts[0],
            month: parts[1],
            day: parts[2]
        )) else { return false }
        return key(for: date, utcOffsetSeconds: 0) == value
    }

    static func date(for key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(
            year: parts[0],
            month: parts[1],
            day: parts[2]
        ))
    }
}

public struct SavingsGoalMovement: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: SavingsGoalMovementKind
    public let money: Money
    public let occurredAt: Date
    /// Captures where the user attributed the event even if the reporting time
    /// zone is later changed.
    public let originTimeZoneIdentifier: String
    /// Offset captured at authoring time. Day validation uses this immutable
    /// value so a future time-zone database rule change cannot move history.
    public let originUTCOffsetSeconds: Int
    /// Stable civil-day attribution. Period calculations use this rather than
    /// reinterpreting `occurredAt` through the device's current time zone.
    public let originDayKey: String

    public init(
        id: UUID = UUID(),
        kind: SavingsGoalMovementKind,
        money: Money,
        occurredAt: Date = Date(),
        originTimeZoneIdentifier: String = TimeZone.current.identifier
    ) throws {
        guard money.amount > .zero else {
            throw SavingsGoalError.nonPositiveMovement
        }
        guard occurredAt.timeIntervalSinceReferenceDate.isFinite else {
            throw SavingsGoalError.invalidDate
        }
        guard money.currency.supports(money.amount) else {
            throw SavingsGoalError.unsupportedPrecision(money.currency)
        }
        guard let zone = TimeZone(identifier: originTimeZoneIdentifier) else {
            throw SavingsGoalError.invalidOriginContext
        }
        let normalizedZone = zone.identifier
        let offset = zone.secondsFromGMT(for: occurredAt)
        self.id = id
        self.kind = kind
        self.money = money
        self.occurredAt = occurredAt
        self.originTimeZoneIdentifier = normalizedZone
        self.originUTCOffsetSeconds = offset
        originDayKey = SavingsGoalOriginDay.key(
            for: occurredAt,
            utcOffsetSeconds: offset
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, money, occurredAt, originTimeZoneIdentifier
        case originUTCOffsetSeconds, originDayKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            let id = try container.decode(UUID.self, forKey: .id)
            let kind = try container.decode(SavingsGoalMovementKind.self, forKey: .kind)
            let money = try container.decode(Money.self, forKey: .money)
            let occurredAt = try container.decode(Date.self, forKey: .occurredAt)
            guard occurredAt.timeIntervalSinceReferenceDate.isFinite else {
                throw SavingsGoalError.invalidDate
            }
            let zone = try container.decode(
                String.self,
                forKey: .originTimeZoneIdentifier
            )
            guard let normalizedZone = TimeZone(identifier: zone)?.identifier else {
                throw SavingsGoalError.invalidOriginContext
            }
            let offset = try container.decode(
                Int.self,
                forKey: .originUTCOffsetSeconds
            )
            guard TimeZone(secondsFromGMT: offset) != nil else {
                throw SavingsGoalError.invalidOriginContext
            }
            let storedDay = try container.decode(
                String.self,
                forKey: .originDayKey
            )
            guard money.amount > .zero,
                  money.currency.supports(money.amount),
                  SavingsGoalOriginDay.isValid(storedDay),
                  storedDay == SavingsGoalOriginDay.key(
                      for: occurredAt,
                      utcOffsetSeconds: offset
                  ) else {
                throw SavingsGoalError.invalidOriginContext
            }
            self = SavingsGoalMovement(
                validatedID: id,
                kind: kind,
                money: money,
                occurredAt: occurredAt,
                originTimeZoneIdentifier: normalizedZone,
                originUTCOffsetSeconds: offset,
                originDayKey: storedDay
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .money,
                in: container,
                debugDescription: "Decoded goal movement is invalid: \(error)"
            )
        }
    }

    private init(
        validatedID id: UUID,
        kind: SavingsGoalMovementKind,
        money: Money,
        occurredAt: Date,
        originTimeZoneIdentifier: String,
        originUTCOffsetSeconds: Int,
        originDayKey: String
    ) {
        self.id = id
        self.kind = kind
        self.money = money
        self.occurredAt = occurredAt
        self.originTimeZoneIdentifier = originTimeZoneIdentifier
        self.originUTCOffsetSeconds = originUTCOffsetSeconds
        self.originDayKey = originDayKey
    }
}

public struct SavingsGoalReset: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let occurredAt: Date
    public let originTimeZoneIdentifier: String
    public let originUTCOffsetSeconds: Int
    public let originDayKey: String

    public init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        originTimeZoneIdentifier: String = TimeZone.current.identifier
    ) throws {
        guard occurredAt.timeIntervalSinceReferenceDate.isFinite else {
            throw SavingsGoalError.invalidDate
        }
        guard let zone = TimeZone(identifier: originTimeZoneIdentifier) else {
            throw SavingsGoalError.invalidOriginContext
        }
        let normalizedZone = zone.identifier
        let offset = zone.secondsFromGMT(for: occurredAt)
        self.id = id
        self.occurredAt = occurredAt
        self.originTimeZoneIdentifier = normalizedZone
        self.originUTCOffsetSeconds = offset
        originDayKey = SavingsGoalOriginDay.key(
            for: occurredAt,
            utcOffsetSeconds: offset
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, occurredAt, originTimeZoneIdentifier
        case originUTCOffsetSeconds, originDayKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let occurredAt = try container.decode(Date.self, forKey: .occurredAt)
        guard occurredAt.timeIntervalSinceReferenceDate.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: .occurredAt,
                in: container,
                debugDescription: "Goal reset date is invalid"
            )
        }
        let zone = try container.decode(
            String.self,
            forKey: .originTimeZoneIdentifier
        )
        guard let normalizedZone = TimeZone(identifier: zone)?.identifier else {
            throw DecodingError.dataCorruptedError(
                forKey: .originTimeZoneIdentifier,
                in: container,
                debugDescription: "Goal reset origin zone is invalid"
            )
        }
        let offset = try container.decode(
            Int.self,
            forKey: .originUTCOffsetSeconds
        )
        let storedDay = try container.decode(
            String.self,
            forKey: .originDayKey
        )
        guard TimeZone(secondsFromGMT: offset) != nil,
              SavingsGoalOriginDay.isValid(storedDay),
              storedDay == SavingsGoalOriginDay.key(
                  for: occurredAt,
                  utcOffsetSeconds: offset
              ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .originDayKey,
                in: container,
                debugDescription: "Goal reset origin context is invalid"
            )
        }
        self = SavingsGoalReset(
            validatedID: id,
            occurredAt: occurredAt,
            originTimeZoneIdentifier: normalizedZone,
            originUTCOffsetSeconds: offset,
            originDayKey: storedDay
        )
    }

    private init(
        validatedID id: UUID,
        occurredAt: Date,
        originTimeZoneIdentifier: String,
        originUTCOffsetSeconds: Int,
        originDayKey: String
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.originTimeZoneIdentifier = originTimeZoneIdentifier
        self.originUTCOffsetSeconds = originUTCOffsetSeconds
        self.originDayKey = originDayKey
    }
}

public struct SavingsGoalSummary: Equatable, Sendable {
    public let target: Money
    public let balance: Money
    public let contributed: Money
    public let withdrawn: Money
    public let remaining: Money
    public let progress: Decimal
    public let periodStart: Date
    public let targetDate: Date
    public let asOf: Date

    public var isComplete: Bool { balance.amount >= target.amount }
    public var isPastDue: Bool { !isComplete && targetDate < asOf }
}

/// A self-contained plan record. Goal movements do not masquerade as ledger
/// transactions: they describe earmarking within the user's plan, retain exact
/// Decimal values, and are encrypted in SQLCipher with the rest of the book.
public struct SavingsGoal: Codable, Equatable, Identifiable, Sendable {
    public static let maximumMovementCount = 1_024
    public static let maximumResetCount = 256
    public static let maximumActivityCount = 1_024
    public let id: UUID
    public var name: String
    public var kind: SavingsGoalKind
    public var target: Money
    public var targetDate: Date
    public var resetRule: SavingsGoalResetRule
    public let createdAt: Date
    public var movements: [SavingsGoalMovement]
    public var resets: [SavingsGoalReset]
    public var isArchived: Bool
    public var reportingTimeZoneIdentifier: String

    public init(
        id: UUID = UUID(),
        name: String,
        kind: SavingsGoalKind,
        target: Money,
        targetDate: Date,
        resetRule: SavingsGoalResetRule = .never,
        createdAt: Date = Date(),
        movements: [SavingsGoalMovement] = [],
        resets: [SavingsGoalReset] = [],
        isArchived: Bool = false,
        reportingTimeZoneIdentifier: String = TimeZone.current.identifier
    ) throws {
        guard movements.count <= Self.maximumMovementCount,
              resets.count <= Self.maximumResetCount,
              movements.count + resets.count <= Self.maximumActivityCount else {
            throw SavingsGoalError.calculationFailed
        }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { throw SavingsGoalError.emptyName }
        guard createdAt.timeIntervalSinceReferenceDate.isFinite,
              targetDate.timeIntervalSinceReferenceDate.isFinite,
              movements.allSatisfy({
                  $0.occurredAt.timeIntervalSinceReferenceDate.isFinite
              }),
              resets.allSatisfy({
                  $0.occurredAt.timeIntervalSinceReferenceDate.isFinite
              }) else {
            throw SavingsGoalError.invalidDate
        }
        guard target.amount > .zero else { throw SavingsGoalError.nonPositiveTarget }
        guard target.currency.supports(target.amount) else {
            throw SavingsGoalError.unsupportedPrecision(target.currency)
        }
        guard targetDate >= createdAt else { throw SavingsGoalError.targetBeforeCreation }
        guard Set(movements.map(\.id)).count == movements.count else {
            throw SavingsGoalError.duplicateMovementID
        }
        guard Set(resets.map(\.id)).count == resets.count else {
            throw SavingsGoalError.duplicateResetID
        }

        self.id = id
        self.name = normalizedName
        self.kind = kind
        self.target = target
        self.targetDate = targetDate
        self.resetRule = resetRule
        self.createdAt = createdAt
        self.movements = movements.sorted(by: Self.movementOrder)
        self.resets = resets.sorted { $0.occurredAt < $1.occurredAt }
        self.isArchived = isArchived
        guard let reportingZone = TimeZone(
            identifier: reportingTimeZoneIdentifier
        )?.identifier else {
            throw SavingsGoalError.invalidOriginContext
        }
        self.reportingTimeZoneIdentifier = reportingZone
        try validateHistory()
    }

    public func summary(
        asOf: Date,
        calendar: Calendar? = nil
    ) throws -> SavingsGoalSummary {
        guard asOf.timeIntervalSinceReferenceDate.isFinite else {
            throw SavingsGoalError.invalidDate
        }
        let calendar = calendar ?? FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: reportingTimeZoneIdentifier
        )
        let asOfDayKey = SavingsGoalOriginDay.key(
            for: asOf,
            timeZoneIdentifier: calendar.timeZone.identifier
        )
        let boundary = activePeriodBoundary(
            asOf: asOf,
            attributedDayKey: asOfDayKey,
            calendar: calendar
        )

        var contributions = Decimal.zero
        var withdrawals = Decimal.zero
        do {
            for movement in movements where movement.occurredAt < asOf
                && movement.originDayKey <= asOfDayKey
                && isInActivePeriod(movement, boundary: boundary) {
                switch movement.kind {
                case .contribution:
                    contributions = try CheckedDecimal.adding(
                        contributions,
                        movement.money.amount
                    )
                case .withdrawal:
                    withdrawals = try CheckedDecimal.adding(
                        withdrawals,
                        movement.money.amount
                    )
                }
            }
            let balance = try CheckedDecimal.subtracting(contributions, withdrawals)
            let unboundedRemaining = try CheckedDecimal.subtracting(
                target.amount,
                balance
            )
            let progress = try CheckedDecimal.ratio(balance, target.amount)
            return SavingsGoalSummary(
                target: target,
                balance: try Money(balance, currency: target.currency),
                contributed: try Money(contributions, currency: target.currency),
                withdrawn: try Money(withdrawals, currency: target.currency),
                remaining: try Money(
                    max(unboundedRemaining, .zero),
                    currency: target.currency
                ),
                progress: progress,
                periodStart: boundary.displayStart,
                targetDate: targetDate,
                asOf: asOf
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SavingsGoalError {
            throw error
        } catch {
            throw SavingsGoalError.calculationFailed
        }
    }

    public func adding(
        _ movement: SavingsGoalMovement,
        calendar: Calendar? = nil
    ) throws -> SavingsGoal {
        guard movement.money.currency == target.currency else {
            throw SavingsGoalError.currencyMismatch(
                expected: target.currency,
                actual: movement.money.currency
            )
        }
        guard movement.occurredAt >= createdAt else {
            throw SavingsGoalError.movementBeforeCreation
        }
        _ = calendar
        return try SavingsGoal(
            id: id,
            name: name,
            kind: kind,
            target: target,
            targetDate: targetDate,
            resetRule: resetRule,
            createdAt: createdAt,
            movements: movements + [movement],
            resets: resets,
            isArchived: isArchived,
            reportingTimeZoneIdentifier: reportingTimeZoneIdentifier
        )
    }

    public func resetting(
        at date: Date = Date(),
        originTimeZoneIdentifier: String = TimeZone.current.identifier
    ) throws -> SavingsGoal {
        guard date >= createdAt else { throw SavingsGoalError.resetBeforeCreation }
        return try SavingsGoal(
            id: id,
            name: name,
            kind: kind,
            target: target,
            targetDate: targetDate,
            resetRule: resetRule,
            createdAt: createdAt,
            movements: movements,
            resets: resets + [try SavingsGoalReset(
                occurredAt: date,
                originTimeZoneIdentifier: originTimeZoneIdentifier
            )],
            isArchived: isArchived,
            reportingTimeZoneIdentifier: reportingTimeZoneIdentifier
        )
    }

    public func updating(
        name: String,
        kind: SavingsGoalKind,
        target: Money,
        targetDate: Date,
        resetRule: SavingsGoalResetRule,
        isArchived: Bool? = nil
    ) throws -> SavingsGoal {
        try SavingsGoal(
            id: id,
            name: name,
            kind: kind,
            target: target,
            targetDate: targetDate,
            resetRule: resetRule,
            createdAt: createdAt,
            movements: movements,
            resets: resets,
            isArchived: isArchived ?? self.isArchived,
            reportingTimeZoneIdentifier: reportingTimeZoneIdentifier
        )
    }

    private func validateHistory() throws {
        guard resets.allSatisfy({ $0.occurredAt >= createdAt }) else {
            throw SavingsGoalError.resetBeforeCreation
        }
        let calendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: reportingTimeZoneIdentifier
        )
        var accepted: [SavingsGoalMovement] = []
        for (movementIndex, movement) in movements.enumerated() {
            if movementIndex.isMultiple(of: 8) {
                try Task.checkCancellation()
            }
            guard movement.money.currency == target.currency else {
                throw SavingsGoalError.currencyMismatch(
                    expected: target.currency,
                    actual: movement.money.currency
                )
            }
            guard movement.occurredAt >= createdAt else {
                throw SavingsGoalError.movementBeforeCreation
            }
            if movement.kind == .withdrawal {
                let boundary = activePeriodBoundary(
                    asOf: movement.occurredAt,
                    attributedDayKey: movement.originDayKey,
                    calendar: calendar
                )
                var balance = Decimal.zero
                do {
                    for prior in accepted where prior.originDayKey <= movement.originDayKey
                        && isInActivePeriod(prior, boundary: boundary) {
                        switch prior.kind {
                        case .contribution:
                            balance = try CheckedDecimal.adding(
                                balance,
                                prior.money.amount
                            )
                        case .withdrawal:
                            balance = try CheckedDecimal.subtracting(
                                balance,
                                prior.money.amount
                            )
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw SavingsGoalError.calculationFailed
                }
                guard movement.money.amount <= balance else {
                    throw SavingsGoalError.withdrawalExceedsBalance
                }
            }
            accepted.append(movement)
        }
    }

    private struct ActivePeriodBoundary {
        let dayKey: String
        let cutoffWithinDay: Date?
        let displayStart: Date
    }

    private func activePeriodBoundary(
        asOf: Date,
        attributedDayKey: String,
        calendar: Calendar
    ) -> ActivePeriodBoundary {
        let createdDayKey = SavingsGoalOriginDay.key(
            for: createdAt,
            timeZoneIdentifier: reportingTimeZoneIdentifier
        )
        var boundary = ActivePeriodBoundary(
            dayKey: createdDayKey,
            cutoffWithinDay: createdAt,
            displayStart: SavingsGoalOriginDay.date(
                for: createdDayKey,
                calendar: calendar
            ) ?? createdAt
        )

        if let automatic = automaticPeriodBoundary(
            asOf: asOf,
            attributedDayKey: attributedDayKey,
            calendar: calendar
        ), automatic.dayKey > boundary.dayKey {
            boundary = automatic
        }
        if let manualReset = latestManualReset(
            asOf: asOf,
            attributedDayKey: attributedDayKey
        ) {
            let isLater = manualReset.originDayKey > boundary.dayKey
                || (manualReset.originDayKey == boundary.dayKey
                    && manualReset.occurredAt
                        > (boundary.cutoffWithinDay ?? .distantPast))
            if isLater {
                boundary = ActivePeriodBoundary(
                    dayKey: manualReset.originDayKey,
                    cutoffWithinDay: manualReset.occurredAt,
                    displayStart: SavingsGoalOriginDay.date(
                        for: manualReset.originDayKey,
                        calendar: calendar
                    ) ?? manualReset.occurredAt
                )
            }
        }
        return boundary
    }

    private func automaticPeriodBoundary(
        asOf: Date,
        attributedDayKey: String,
        calendar: Calendar
    ) -> ActivePeriodBoundary? {
        let attributedDate = SavingsGoalOriginDay.date(
            for: attributedDayKey,
            calendar: calendar
        ) ?? asOf
        let component: Calendar.Component
        switch resetRule {
        case .never: return nil
        case .monthly: component = .month
        case .yearly: component = .year
        }
        guard let start = calendar.dateInterval(
            of: component,
            for: attributedDate
        )?.start else { return nil }
        return ActivePeriodBoundary(
            dayKey: SavingsGoalOriginDay.key(
                for: start,
                timeZoneIdentifier: calendar.timeZone.identifier
            ),
            cutoffWithinDay: nil,
            displayStart: start
        )
    }

    private func latestManualReset(
        asOf: Date,
        attributedDayKey: String
    ) -> SavingsGoalReset? {
        resets
            .filter {
                $0.occurredAt <= asOf && $0.originDayKey <= attributedDayKey
            }
            .max {
                if $0.originDayKey == $1.originDayKey {
                    return $0.occurredAt < $1.occurredAt
                }
                return $0.originDayKey < $1.originDayKey
            }
    }

    private func isInActivePeriod(
        _ movement: SavingsGoalMovement,
        boundary: ActivePeriodBoundary
    ) -> Bool {
        if movement.originDayKey > boundary.dayKey { return true }
        guard movement.originDayKey == boundary.dayKey else { return false }
        guard let cutoff = boundary.cutoffWithinDay else { return true }
        return movement.occurredAt >= cutoff
    }

    private static func movementOrder(
        _ lhs: SavingsGoalMovement,
        _ rhs: SavingsGoalMovement
    ) -> Bool {
        if lhs.occurredAt == rhs.occurredAt {
            // Contributions at one imported timestamp are made available before
            // withdrawals; UUID is the final stable tie-breaker.
            if lhs.kind != rhs.kind { return lhs.kind == .contribution }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.occurredAt < rhs.occurredAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, target, targetDate, resetRule, createdAt
        case movements, resets, isArchived, reportingTimeZoneIdentifier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: try container.decode(UUID.self, forKey: .id),
                name: try container.decode(String.self, forKey: .name),
                kind: try container.decode(SavingsGoalKind.self, forKey: .kind),
                target: try container.decode(Money.self, forKey: .target),
                targetDate: try container.decode(Date.self, forKey: .targetDate),
                resetRule: try container.decodeIfPresent(
                    SavingsGoalResetRule.self,
                    forKey: .resetRule
                ) ?? .never,
                createdAt: try container.decode(Date.self, forKey: .createdAt),
                movements: try container.decodeIfPresent(
                    [SavingsGoalMovement].self,
                    forKey: .movements
                ) ?? [],
                resets: try container.decodeIfPresent(
                    [SavingsGoalReset].self,
                    forKey: .resets
                ) ?? [],
                isArchived: try container.decodeIfPresent(
                    Bool.self,
                    forKey: .isArchived
                ) ?? false,
                reportingTimeZoneIdentifier: try container.decode(
                    String.self,
                    forKey: .reportingTimeZoneIdentifier
                )
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .target,
                in: container,
                debugDescription: "Decoded savings goal is invalid: \(error)"
            )
        }
    }
}
