import Foundation

public enum HistoryKindFilter: String, CaseIterable, Hashable, Sendable {
    case all
    case expense
    case income
    case transfer
    case refund
    case adjustment
}

public struct HistorySummary: Equatable, Sendable {
    public let transactionCount: Int
    /// Signed movement for matching entries, kept separate by currency.
    /// Consumer income/refund values are positive and spending is negative.
    /// Transfers use only asset/liability postings, so same-currency transfers
    /// offset to zero while foreign-currency sides remain separate.
    public let amountsByCurrency: [CurrencyCode: Decimal]

    public init(
        transactionCount: Int,
        amountsByCurrency: [CurrencyCode: Decimal]
    ) {
        self.transactionCount = transactionCount
        self.amountsByCurrency = amountsByCurrency
    }
}

/// A composable, deterministic query for the transaction History screen.
///
/// `startDate` is inclusive and `endDateExclusive` is exclusive. The UI can
/// therefore represent an inclusive end day without making 23:59:59 or
/// daylight-saving assumptions by passing the start of the following day.
public struct HistoryQuery: Equatable, Sendable {
    public var searchText: String
    public var kind: HistoryKindFilter
    public var accountID: UUID?
    /// Exact category accounts that may satisfy this query. `nil` means no
    /// category filter, while an empty set deliberately matches nothing.
    /// The latter is fail-closed so an empty aggregate chart bucket can never
    /// accidentally expand into all History transactions.
    public var categoryIDs: Set<UUID>? {
        didSet {
            // The currency boundary describes the category scope that was
            // selected with it. Never carry it into a different scope: doing
            // so can silently hide otherwise matching postings when a caller
            // reuses and edits a query.
            if categoryIDs != oldValue {
                categoryPostingCurrency = nil
            }
        }
    }
    /// Optional posting-currency boundary for a category query. Insights uses
    /// this to keep a base-currency chart drill-through from including foreign
    /// postings made against the same category account.
    public var categoryPostingCurrency: CurrencyCode?
    public var startDate: Date?
    public var endDateExclusive: Date?
    public var minimumAmount: Decimal?
    public var maximumAmount: Decimal?

    /// Source-compatible convenience for callers that filter one category.
    /// Assigning this property replaces any existing multi-category scope and
    /// clears a currency boundary that belonged to that previous scope.
    public var categoryID: UUID? {
        get {
            guard categoryIDs?.count == 1 else { return nil }
            return categoryIDs?.first
        }
        set {
            categoryIDs = newValue.map { Set([$0]) }
        }
    }

    public init(
        searchText: String = "",
        kind: HistoryKindFilter = .all,
        accountID: UUID? = nil,
        categoryID: UUID? = nil,
        categoryIDs: Set<UUID>? = nil,
        categoryPostingCurrency: CurrencyCode? = nil,
        startDate: Date? = nil,
        endDateExclusive: Date? = nil,
        minimumAmount: Decimal? = nil,
        maximumAmount: Decimal? = nil
    ) {
        self.searchText = searchText
        self.kind = kind
        self.accountID = accountID
        let resolvedCategoryIDs = categoryIDs ?? categoryID.map { Set([$0]) }
        self.categoryIDs = resolvedCategoryIDs
        // A posting-currency boundary without a category scope has no meaning
        // and would otherwise become a latent filter if the query is mutated.
        self.categoryPostingCurrency = resolvedCategoryIDs == nil
            ? nil
            : categoryPostingCurrency
        self.startDate = startDate
        self.endDateExclusive = endDateExclusive
        self.minimumAmount = minimumAmount
        self.maximumAmount = maximumAmount
    }

    public func filteredEntries(
        _ entries: [JournalEntry],
        accounts: [LedgerAccount],
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> [JournalEntry] {
        let accountsByID = Dictionary(
            accounts.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let amountFormatter = NumberFormatter()
        amountFormatter.locale = locale
        amountFormatter.numberStyle = .decimal
        amountFormatter.minimumFractionDigits = 0
        amountFormatter.maximumFractionDigits = 16
        return entries.filter {
            matches(
                $0,
                accountsByID: accountsByID,
                locale: locale,
                amountFormatter: amountFormatter,
                calendar: calendar
            )
        }
    }

    public func summary(
        for entries: [JournalEntry],
        accounts: [LedgerAccount]
    ) throws -> HistorySummary {
        let accountsByID = Dictionary(
            accounts.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var totals: [CurrencyCode: Decimal] = [:]

        for entry in entries {
            switch classifiedKind(of: entry, accountsByID: accountsByID) {
            case .expense, .refund:
                for posting in entry.postings
                where accountsByID[posting.accountID]?.kind == .expense {
                    let currency = posting.money.currency
                    totals[currency] = try CheckedDecimal.subtracting(
                        totals[currency] ?? .zero,
                        posting.money.amount
                    )
                }
            case .income:
                for posting in entry.postings
                where accountsByID[posting.accountID]?.kind == .income {
                    let currency = posting.money.currency
                    totals[currency] = try CheckedDecimal.subtracting(
                        totals[currency] ?? .zero,
                        posting.money.amount
                    )
                }
            case .transfer, .adjustment:
                for posting in entry.postings {
                    guard let kind = accountsByID[posting.accountID]?.kind,
                          kind == .asset || kind == .liability else { continue }
                    let currency = posting.money.currency
                    totals[currency] = try CheckedDecimal.adding(
                        totals[currency] ?? .zero,
                        posting.money.amount
                    )
                }
            case .all:
                continue
            }
        }

        return HistorySummary(
            transactionCount: entries.count,
            amountsByCurrency: totals
        )
    }

    private func matches(
        _ entry: JournalEntry,
        accountsByID: [UUID: LedgerAccount],
        locale: Locale,
        amountFormatter: NumberFormatter,
        calendar: Calendar
    ) -> Bool {
        guard kind == .all || classifiedKind(of: entry, accountsByID: accountsByID) == kind
        else { return false }
        if let accountID, !entry.postings.contains(where: { $0.accountID == accountID }) {
            return false
        }
        if let allowedCategoryIDs = categoryIDs {
            let requiredCurrency = categoryPostingCurrency
            let hasMatchingCategoryPosting = entry.postings.contains { posting in
                allowedCategoryIDs.contains(posting.accountID)
                    && (requiredCurrency == nil
                        || posting.money.currency == requiredCurrency)
            }
            if !hasMatchingCategoryPosting { return false }
        }
        guard FinancialPeriodBoundary.contains(
            entry.originContext.attributedDate(in: calendar) ?? entry.occurredAt,
            start: startDate,
            endExclusive: endDateExclusive
        ) else { return false }

        if minimumAmount != nil || maximumAmount != nil {
            let amounts = userFacingAmounts(in: entry, accountsByID: accountsByID)
            let hasAmountInRange = amounts.contains { amount in
                let meetsMinimum = minimumAmount.map { amount >= $0 } ?? true
                let meetsMaximum = maximumAmount.map { amount <= $0 } ?? true
                return meetsMinimum && meetsMaximum
            }
            guard hasAmountInRange else { return false }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let values = [entry.payee, entry.note].compactMap { $0 }
            + entry.postings.compactMap { accountsByID[$0.accountID]?.name }
            + entry.postings.map {
                NSDecimalNumber(decimal: abs($0.money.amount)).stringValue
                    + " " + $0.money.currency.value
            }
            + entry.postings.compactMap { posting in
                amountFormatter.string(
                    from: NSDecimalNumber(decimal: abs(posting.money.amount))
                ).map { formattedAmount in
                    formattedAmount + " " + posting.money.currency.value
                }
            }
        return values.contains {
            $0.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: locale
            ) != nil
        }
    }

    private func classifiedKind(
        of entry: JournalEntry,
        accountsByID: [UUID: LedgerAccount]
    ) -> HistoryKindFilter {
        switch entry.kind {
        case .expense:
            let isRefund = entry.postings.contains {
                accountsByID[$0.accountID]?.kind == .expense
                    && $0.money.amount < .zero
            }
            return isRefund ? .refund : .expense
        case .income: return .income
        case .transfer: return .transfer
        case .adjustment, .investment: return .adjustment
        }
    }

    private func userFacingAmounts(
        in entry: JournalEntry,
        accountsByID: [UUID: LedgerAccount]
    ) -> [Decimal] {
        let preferredKinds: Set<LedgerAccountKind>
        switch entry.kind {
        // Split transactions must match both their total movement on the user
        // account and each individual category allocation.
        case .expense: preferredKinds = [.expense, .asset, .liability]
        case .income: preferredKinds = [.income, .asset, .liability]
        case .transfer: preferredKinds = [.asset, .liability]
        case .adjustment, .investment: preferredKinds = [.asset, .liability]
        }
        let preferred = entry.postings.compactMap { posting -> Decimal? in
            guard let account = accountsByID[posting.accountID],
                  preferredKinds.contains(account.kind) else { return nil }
            return abs(posting.money.amount)
        }
        let values = preferred.isEmpty
            ? entry.postings.map { abs($0.money.amount) }
            : preferred
        return values.reduce(into: [Decimal]()) { unique, amount in
            if !unique.contains(amount) { unique.append(amount) }
        }
    }
}
