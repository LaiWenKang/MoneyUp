import Foundation

public enum TransactionOriginContextError: Error, Equatable, Sendable {
    case unsupportedCalendar
    case invalidTimeZone
    case invalidUTCOffset
    case invalidDayKey
    case eventDateMismatch
}

/// Calendar and time-zone facts captured when a transaction is created.
///
/// `dayKey` is persisted rather than recomputed so travel, daylight-saving
/// changes, or a later device time-zone change cannot move a transaction to a
/// different budget/reporting day.
public struct TransactionOriginContext: Codable, Equatable, Sendable {
    public let calendarIdentifier: String
    public let timeZoneIdentifier: String
    public let utcOffsetSeconds: Int
    public let dayKey: Int
    public let wasInferred: Bool

    public init(
        calendarIdentifier: String,
        timeZoneIdentifier: String,
        utcOffsetSeconds: Int,
        dayKey: Int,
        wasInferred: Bool = false
    ) throws {
        try Self.validate(
            calendarIdentifier: calendarIdentifier,
            timeZoneIdentifier: timeZoneIdentifier,
            utcOffsetSeconds: utcOffsetSeconds,
            dayKey: dayKey,
            wasInferred: wasInferred
        )
        self.init(
            validatedCalendarIdentifier: calendarIdentifier,
            timeZoneIdentifier: timeZoneIdentifier,
            utcOffsetSeconds: utcOffsetSeconds,
            dayKey: dayKey,
            wasInferred: wasInferred
        )
    }

    private init(
        validatedCalendarIdentifier calendarIdentifier: String,
        timeZoneIdentifier: String,
        utcOffsetSeconds: Int,
        dayKey: Int,
        wasInferred: Bool
    ) {
        self.calendarIdentifier = calendarIdentifier
        self.timeZoneIdentifier = timeZoneIdentifier
        self.utcOffsetSeconds = utcOffsetSeconds
        self.dayKey = dayKey
        self.wasInferred = wasInferred
    }

    public static func capture(
        for date: Date,
        calendar sourceCalendar: Calendar = Calendar(identifier: .gregorian),
        timeZone: TimeZone = .current
    ) -> TransactionOriginContext {
        var calendar = sourceCalendar.identifier == .gregorian
            ? sourceCalendar
            : Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return TransactionOriginContext(
            validatedCalendarIdentifier: "gregorian",
            timeZoneIdentifier: timeZone.identifier,
            utcOffsetSeconds: timeZone.secondsFromGMT(for: date),
            dayKey: makeDayKey(components),
            wasInferred: false
        )
    }

    /// Legacy records did not include origin context. UTC is deterministic and
    /// therefore preferable to silently re-attributing them whenever the user
    /// travels; `wasInferred` keeps that limitation auditable.
    public static func inferredUTC(for date: Date) -> TransactionOriginContext {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return TransactionOriginContext(
            validatedCalendarIdentifier: "gregorian",
            timeZoneIdentifier: "UTC",
            utcOffsetSeconds: 0,
            dayKey: makeDayKey(components),
            wasInferred: true
        )
    }

    private static func makeDayKey(_ components: DateComponents) -> Int {
        (components.year ?? 0) * 10_000
            + (components.month ?? 0) * 100
            + (components.day ?? 0)
    }

    private enum CodingKeys: String, CodingKey {
        case calendarIdentifier, timeZoneIdentifier, utcOffsetSeconds, dayKey
        case wasInferred
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                calendarIdentifier: container.decode(
                    String.self,
                    forKey: .calendarIdentifier
                ),
                timeZoneIdentifier: container.decode(
                    String.self,
                    forKey: .timeZoneIdentifier
                ),
                utcOffsetSeconds: container.decode(
                    Int.self,
                    forKey: .utcOffsetSeconds
                ),
                dayKey: container.decode(Int.self, forKey: .dayKey),
                wasInferred: container.decodeIfPresent(
                    Bool.self,
                    forKey: .wasInferred
                ) ?? false
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .dayKey,
                in: container,
                debugDescription: "Invalid transaction origin context."
            )
        }
    }

    private static func validate(
        calendarIdentifier: String,
        timeZoneIdentifier: String,
        utcOffsetSeconds: Int,
        dayKey: Int,
        wasInferred: Bool
    ) throws {
        guard calendarIdentifier.lowercased() == "gregorian" else {
            throw TransactionOriginContextError.unsupportedCalendar
        }
        let maximumOffset = 14 * 60 * 60
        guard (-maximumOffset...maximumOffset).contains(utcOffsetSeconds) else {
            throw TransactionOriginContextError.invalidUTCOffset
        }
        if wasInferred {
            guard timeZoneIdentifier == "UTC", utcOffsetSeconds == 0 else {
                throw TransactionOriginContextError.invalidTimeZone
            }
        } else {
            guard TimeZone(identifier: timeZoneIdentifier) != nil else {
                throw TransactionOriginContextError.invalidTimeZone
            }
        }

        let year = dayKey / 10_000
        let month = dayKey / 100 % 100
        let day = dayKey % 100
        guard (1...9_999).contains(year), (1...12).contains(month),
              (1...31).contains(day) else {
            throw TransactionOriginContextError.invalidDayKey
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else {
            throw TransactionOriginContextError.invalidDayKey
        }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == year,
              roundTrip.month == month,
              roundTrip.day == day else {
            throw TransactionOriginContextError.invalidDayKey
        }
    }

    public func attributedDate(
        in reportingCalendar: Calendar = Calendar(identifier: .gregorian)
    ) -> Date? {
        let calendar = reportingCalendar
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = dayKey / 10_000
        components.month = dayKey / 100 % 100
        components.day = dayKey % 100
        return calendar.date(from: components)
    }

    /// Proves that the captured civil day and offset describe the supplied
    /// event instant. This is deliberately separate from basic decoding so a
    /// standalone historical context can retain audited facts even when the
    /// operating system's time-zone database is updated later.
    public func validate(eventDate: Date) throws {
        guard eventDate.timeIntervalSinceReferenceDate.isFinite else {
            throw TransactionOriginContextError.eventDateMismatch
        }
        if wasInferred {
            guard timeZoneIdentifier == "UTC", utcOffsetSeconds == 0 else {
                throw TransactionOriginContextError.eventDateMismatch
            }
        }
        // The captured offset is immutable evidence. Requiring today's OS
        // time-zone database to reproduce it would make sound historical rows
        // fail after governments revise zone rules. The named zone is checked
        // for validity during decoding; event/day validation uses the frozen
        // offset that was captured with the transaction.
        guard let timeZone = TimeZone(secondsFromGMT: utcOffsetSeconds) else {
            throw TransactionOriginContextError.eventDateMismatch
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: eventDate)
        guard Self.makeDayKey(components) == dayKey else {
            throw TransactionOriginContextError.eventDateMismatch
        }
    }
}

public struct TransactionSplitLine: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let categoryAccountID: UUID
    public let amount: Money
    public let memo: String?

    public init(
        id: UUID = UUID(),
        categoryAccountID: UUID,
        amount: Money,
        memo: String? = nil
    ) {
        self.id = id
        self.categoryAccountID = categoryAccountID
        self.amount = amount
        self.memo = memo?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

public enum TransactionSplitError: Error, Equatable, Sendable {
    case tooFewLines
    case nonPositiveAmount(UUID)
    case currencyMismatch(UUID)
    case totalMismatch(expected: Decimal, actual: Decimal)
}

public enum TransactionSplitCalculator {
    public static func remainder(total: Money, lines: [TransactionSplitLine]) throws -> Money {
        var allocated = Decimal.zero
        for line in lines {
            guard line.amount.currency == total.currency else {
                throw TransactionSplitError.currencyMismatch(line.id)
            }
            allocated = try CheckedDecimal.adding(
                allocated,
                line.amount.amount
            )
        }
        return try Money(
            CheckedDecimal.subtracting(total.amount, allocated),
            currency: total.currency
        )
    }

    public static func validate(total: Money, lines: [TransactionSplitLine]) throws {
        guard lines.count >= 2 else { throw TransactionSplitError.tooFewLines }
        for line in lines {
            guard line.amount.amount > .zero else {
                throw TransactionSplitError.nonPositiveAmount(line.id)
            }
            guard line.amount.currency == total.currency else {
                throw TransactionSplitError.currencyMismatch(line.id)
            }
        }
        var actual = Decimal.zero
        for line in lines {
            actual = try CheckedDecimal.adding(actual, line.amount.amount)
        }
        guard actual == total.amount else {
            throw TransactionSplitError.totalMismatch(expected: total.amount, actual: actual)
        }
    }
}

public struct DatedExchangeRate: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let baseCurrency: CurrencyCode
    public let quoteCurrency: CurrencyCode
    /// Units of quote currency for one unit of base currency.
    public let rate: Decimal
    public let effectiveContext: TransactionOriginContext
    /// Present for every new write. Nil identifies a legacy rate whose schema
    /// retained only a civil effective day and cannot honestly reconstruct the
    /// user's original instant.
    public let effectiveAt: Date?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        baseCurrency: CurrencyCode,
        quoteCurrency: CurrencyCode,
        rate: Decimal,
        effectiveAt: Date,
        calendar: Calendar = Calendar(identifier: .gregorian),
        timeZone: TimeZone = .current,
        createdAt: Date = Date()
    ) throws {
        guard baseCurrency != quoteCurrency else { throw ExchangeRateError.identicalCurrencies }
        try Self.validate(rate: rate)
        guard effectiveAt.timeIntervalSinceReferenceDate.isFinite,
              createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ExchangeRateError.invalidEffectiveDate
        }
        let context = TransactionOriginContext.capture(
            for: effectiveAt,
            calendar: calendar,
            timeZone: timeZone
        )
        do {
            try context.validate(eventDate: effectiveAt)
        } catch {
            throw ExchangeRateError.originContextMismatch
        }
        self.id = id
        self.baseCurrency = baseCurrency
        self.quoteCurrency = quoteCurrency
        self.rate = rate
        effectiveContext = context
        self.effectiveAt = effectiveAt
        self.createdAt = createdAt
    }

    public init(
        id: UUID,
        baseCurrency: CurrencyCode,
        quoteCurrency: CurrencyCode,
        rate: Decimal,
        effectiveContext: TransactionOriginContext,
        createdAt: Date,
        effectiveAt: Date? = nil
    ) throws {
        guard baseCurrency != quoteCurrency else { throw ExchangeRateError.identicalCurrencies }
        try Self.validate(rate: rate)
        guard createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ExchangeRateError.invalidEffectiveDate
        }
        if let effectiveAt {
            guard effectiveAt.timeIntervalSinceReferenceDate.isFinite else {
                throw ExchangeRateError.invalidEffectiveDate
            }
            do {
                try effectiveContext.validate(eventDate: effectiveAt)
            } catch {
                throw ExchangeRateError.originContextMismatch
            }
        }
        self.id = id
        self.baseCurrency = baseCurrency
        self.quoteCurrency = quoteCurrency
        self.rate = rate
        self.effectiveContext = effectiveContext
        self.effectiveAt = effectiveAt
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, baseCurrency, quoteCurrency, rate, effectiveContext, effectiveAt
        case createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(UUID.self, forKey: .id),
                baseCurrency: container.decode(CurrencyCode.self, forKey: .baseCurrency),
                quoteCurrency: container.decode(CurrencyCode.self, forKey: .quoteCurrency),
                rate: container.decode(Decimal.self, forKey: .rate),
                effectiveContext: container.decode(
                    TransactionOriginContext.self,
                    forKey: .effectiveContext
                ),
                createdAt: container.decode(Date.self, forKey: .createdAt),
                effectiveAt: container.decodeIfPresent(Date.self, forKey: .effectiveAt)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .rate,
                in: container,
                debugDescription: "Exchange rate failed validation."
            )
        }
    }

    /// A saved rate is bidirectional in MoneyUp, so both the entered value and
    /// its reciprocal must remain representable. Repeating reciprocals are
    /// expected for real FX rates and are deliberately accepted here; they are
    /// rounded exactly once when a destination-currency amount is produced.
    private static func validate(rate: Decimal) throws {
        guard rate > .zero, !rate.isNaN else { throw ExchangeRateError.invalidRate }
        var numerator = Decimal(1)
        var denominator = rate
        var reciprocal = Decimal.zero
        let error = NSDecimalDivide(
            &reciprocal,
            &numerator,
            &denominator,
            .bankers
        )
        guard (error == .noError || error == .lossOfPrecision),
              reciprocal > .zero,
              !reciprocal.isNaN else {
            throw ExchangeRateError.invalidRate
        }
    }
}

public enum ExchangeRateError: Error, Equatable, Sendable {
    case identicalCurrencies
    case invalidRate
    case invalidEffectiveDate
    case originContextMismatch
    case conversionOutOfRange
    case conversionUnderflow
}

public struct HistoricalCurrencyConversion: Equatable, Sendable {
    public let source: Money
    public let converted: Money
    public let appliedRate: Decimal
    public let rateID: UUID
    public let effectiveDayKey: Int
    public let usedInverseRate: Bool
    /// User-entered historical rates are always estimates, never live quotes.
    public let isEstimated: Bool
}

public enum HistoricalExchangeRateLookup {
    private static let identityRateID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )

    public static func conversion(
        of source: Money,
        to destinationCurrency: CurrencyCode,
        on origin: TransactionOriginContext,
        rates: [DatedExchangeRate]
    ) throws -> HistoricalCurrencyConversion? {
        if source.currency == destinationCurrency {
            return HistoricalCurrencyConversion(
                source: source,
                converted: source,
                appliedRate: 1,
                rateID: identityRateID,
                effectiveDayKey: origin.dayKey,
                usedInverseRate: false,
                isEstimated: false
            )
        }

        let candidate = rates
            .filter { rate in
                rate.effectiveContext.dayKey <= origin.dayKey
                    && ((rate.baseCurrency == source.currency
                            && rate.quoteCurrency == destinationCurrency)
                        || (rate.baseCurrency == destinationCurrency
                            && rate.quoteCurrency == source.currency))
            }
            .max { left, right in
                if left.effectiveContext.dayKey == right.effectiveContext.dayKey {
                    return left.createdAt < right.createdAt
                }
                return left.effectiveContext.dayKey < right.effectiveContext.dayKey
            }
        guard let candidate else { return nil }

        let inverse = candidate.baseCurrency == destinationCurrency
        let applied: Decimal
        let roundedAmount: Decimal
        do {
            applied = inverse
                ? try CheckedDecimal.ratio(1, candidate.rate)
                : candidate.rate
            if inverse {
                roundedAmount = try CheckedDecimal.divideForCurrencyRounding(
                    source.amount,
                    candidate.rate,
                    currency: destinationCurrency
                )
            } else {
                roundedAmount = try CheckedDecimal.productForCurrencyRounding(
                    source.amount,
                    candidate.rate,
                    currency: destinationCurrency
                )
            }
        } catch is DecimalCalculationError {
            throw ExchangeRateError.conversionOutOfRange
        }
        guard source.amount == .zero || roundedAmount != .zero else {
            throw ExchangeRateError.conversionUnderflow
        }
        do {
            try MonetaryInputPolicy.validate(
                roundedAmount,
                currency: destinationCurrency
            )
        } catch {
            throw ExchangeRateError.conversionOutOfRange
        }
        return HistoricalCurrencyConversion(
            source: source,
            converted: try Money(roundedAmount, currency: destinationCurrency),
            appliedRate: applied,
            rateID: candidate.id,
            effectiveDayKey: candidate.effectiveContext.dayKey,
            usedInverseRate: inverse,
            isEstimated: true
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
