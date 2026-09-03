import Foundation

public enum LoanActivityKind: String, Codable, Sendable {
    case drawdown
    case repayment
    case reconciliation
}

/// User-facing purpose only. It changes presentation and planning context,
/// never the authoritative liability balance or repayment postings.
public enum LoanPurpose: String, Codable, CaseIterable, Hashable, Sendable {
    case home
    case vehicle
    case education
    case medical
    case personal
    case business
    case installment
    case creditLine = "credit_line"
    case other
}

public enum LoanPlanError: Error, Equatable, Sendable {
    case emptyName
    case principalMustBePositive
    case invalidDate
    case invalidAPR
    case invalidTerm
    case currencyMismatch
    case invalidActivity
    case tooManyActivities
}

public struct LoanActivity: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: LoanActivityKind
    public let occurredAt: Date
    public let principal: Money
    public let interest: Money
    public let fees: Money
    public let journalEntryID: UUID
    public let note: String?

    public init(
        id: UUID = UUID(),
        kind: LoanActivityKind,
        occurredAt: Date,
        principal: Money,
        interest: Money,
        fees: Money,
        journalEntryID: UUID,
        note: String? = nil
    ) throws {
        guard occurredAt.timeIntervalSinceReferenceDate.isFinite else {
            throw LoanPlanError.invalidDate
        }
        guard principal.currency == interest.currency,
              principal.currency == fees.currency else {
            throw LoanPlanError.currencyMismatch
        }
        guard principal.amount >= .zero,
              interest.amount >= .zero,
              fees.amount >= .zero else {
            throw LoanPlanError.invalidActivity
        }
        switch kind {
        case .drawdown:
            guard principal.amount > .zero,
                  interest.isZero,
                  fees.isZero else { throw LoanPlanError.invalidActivity }
        case .repayment:
            guard principal.amount > .zero || interest.amount > .zero || fees.amount > .zero
            else { throw LoanPlanError.invalidActivity }
        case .reconciliation:
            guard principal.amount > .zero,
                  interest.isZero,
                  fees.isZero else { throw LoanPlanError.invalidActivity }
        }
        self.id = id
        self.kind = kind
        self.occurredAt = occurredAt
        self.principal = principal
        self.interest = interest
        self.fees = fees
        self.journalEntryID = journalEntryID
        let normalizedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.note = normalizedNote?.isEmpty == false ? normalizedNote : nil
    }
}

public struct LoanSummary: Equatable, Sendable {
    public let remainingPrincipal: Money
    public let totalPrincipalAdvanced: Money
    public let principalPaid: Money
    public let totalInterestPaid: Money
    public let totalFeesPaid: Money

    public init(
        remainingPrincipal: Money,
        totalPrincipalAdvanced: Money,
        principalPaid: Money,
        totalInterestPaid: Money,
        totalFeesPaid: Money
    ) {
        self.remainingPrincipal = remainingPrincipal
        self.totalPrincipalAdvanced = totalPrincipalAdvanced
        self.principalPaid = principalPaid
        self.totalInterestPaid = totalInterestPaid
        self.totalFeesPaid = totalFeesPaid
    }
}

/// Metadata and immutable activity links for one liability account. Every
/// financial movement still lives in the balanced journal; this record adds
/// loan-specific explanation without creating a second balance source.
public struct LoanPlan: Codable, Equatable, Identifiable, Sendable {
    public static let maximumActivityCount = 4_096

    public let id: UUID
    public let accountID: UUID
    public var name: String
    public var purpose: LoanPurpose
    public var originalPrincipal: Money
    public var openedAt: Date
    public var annualPercentageRate: Decimal?
    public var termMonths: Int?
    public var includeInTotalDebt: Bool
    public var interestExpenseAccountID: UUID?
    public var feeExpenseAccountID: UUID?
    public private(set) var activities: [LoanActivity]
    public var closedAt: Date?

    public init(
        id: UUID = UUID(),
        accountID: UUID,
        name: String,
        purpose: LoanPurpose = .other,
        originalPrincipal: Money,
        openedAt: Date,
        annualPercentageRate: Decimal? = nil,
        termMonths: Int? = nil,
        includeInTotalDebt: Bool = true,
        interestExpenseAccountID: UUID? = nil,
        feeExpenseAccountID: UUID? = nil,
        activities: [LoanActivity] = [],
        closedAt: Date? = nil
    ) throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { throw LoanPlanError.emptyName }
        guard originalPrincipal.amount > .zero else {
            throw LoanPlanError.principalMustBePositive
        }
        guard openedAt.timeIntervalSinceReferenceDate.isFinite,
              closedAt?.timeIntervalSinceReferenceDate.isFinite != false,
              closedAt.map({ $0 >= openedAt }) ?? true else {
            throw LoanPlanError.invalidDate
        }
        if let annualPercentageRate {
            guard annualPercentageRate >= .zero,
                  annualPercentageRate <= 100 else {
                throw LoanPlanError.invalidAPR
            }
        }
        if let termMonths, !(1...1_200).contains(termMonths) {
            throw LoanPlanError.invalidTerm
        }
        guard activities.count <= Self.maximumActivityCount else {
            throw LoanPlanError.tooManyActivities
        }
        guard activities.allSatisfy({
            $0.principal.currency == originalPrincipal.currency
                && $0.occurredAt >= openedAt
        }) else { throw LoanPlanError.currencyMismatch }

        self.id = id
        self.accountID = accountID
        self.name = normalizedName
        self.purpose = purpose
        self.originalPrincipal = originalPrincipal
        self.openedAt = openedAt
        self.annualPercentageRate = annualPercentageRate
        self.termMonths = termMonths
        self.includeInTotalDebt = includeInTotalDebt
        self.interestExpenseAccountID = interestExpenseAccountID
        self.feeExpenseAccountID = feeExpenseAccountID
        self.activities = activities.sorted { $0.occurredAt < $1.occurredAt }
        self.closedAt = closedAt
    }

    public func adding(_ activity: LoanActivity) throws -> LoanPlan {
        guard activities.count < Self.maximumActivityCount else {
            throw LoanPlanError.tooManyActivities
        }
        guard activity.principal.currency == originalPrincipal.currency else {
            throw LoanPlanError.currencyMismatch
        }
        guard activity.occurredAt >= openedAt else {
            throw LoanPlanError.invalidDate
        }
        var copy = self
        copy.activities.append(activity)
        copy.activities.sort { $0.occurredAt < $1.occurredAt }
        return copy
    }

    public func summary(currentPrincipal: Money) throws -> LoanSummary {
        guard currentPrincipal.currency == originalPrincipal.currency else {
            throw LoanPlanError.currencyMismatch
        }
        guard currentPrincipal.amount >= .zero else {
            throw LoanPlanError.invalidActivity
        }
        var advanced = originalPrincipal.amount
        var interest = Decimal.zero
        var fees = Decimal.zero
        for activity in activities {
            switch activity.kind {
            case .drawdown:
                advanced = try CheckedDecimal.adding(
                    advanced,
                    activity.principal.amount
                )
            case .repayment, .reconciliation:
                break
            }
            interest = try CheckedDecimal.adding(interest, activity.interest.amount)
            fees = try CheckedDecimal.adding(fees, activity.fees.amount)
        }
        let paid = max(
            .zero,
            try CheckedDecimal.subtracting(advanced, currentPrincipal.amount)
        )
        let currency = originalPrincipal.currency
        return LoanSummary(
            remainingPrincipal: currentPrincipal,
            totalPrincipalAdvanced: try Money(advanced, currency: currency),
            principalPaid: try Money(paid, currency: currency),
            totalInterestPaid: try Money(interest, currency: currency),
            totalFeesPaid: try Money(fees, currency: currency)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, accountID, name, purpose, originalPrincipal, openedAt
        case annualPercentageRate, termMonths, includeInTotalDebt
        case interestExpenseAccountID, feeExpenseAccountID, activities, closedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(UUID.self, forKey: .id),
                accountID: container.decode(UUID.self, forKey: .accountID),
                name: container.decode(String.self, forKey: .name),
                purpose: container.decodeIfPresent(
                    LoanPurpose.self,
                    forKey: .purpose
                ) ?? .other,
                originalPrincipal: container.decode(
                    Money.self,
                    forKey: .originalPrincipal
                ),
                openedAt: container.decode(Date.self, forKey: .openedAt),
                annualPercentageRate: container.decodeIfPresent(
                    Decimal.self,
                    forKey: .annualPercentageRate
                ),
                termMonths: container.decodeIfPresent(Int.self, forKey: .termMonths),
                includeInTotalDebt: container.decodeIfPresent(
                    Bool.self,
                    forKey: .includeInTotalDebt
                ) ?? true,
                interestExpenseAccountID: container.decodeIfPresent(
                    UUID.self,
                    forKey: .interestExpenseAccountID
                ),
                feeExpenseAccountID: container.decodeIfPresent(
                    UUID.self,
                    forKey: .feeExpenseAccountID
                ),
                activities: container.decodeIfPresent(
                    [LoanActivity].self,
                    forKey: .activities
                ) ?? [],
                closedAt: container.decodeIfPresent(Date.self, forKey: .closedAt)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .originalPrincipal,
                in: container,
                debugDescription: "Invalid loan plan."
            )
        }
    }
}
