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
    /// Positive expense-category postings only.
    public let spendingByCurrency: [CurrencyCode: Decimal]
    /// Absolute value of negative income-category postings.
    public let incomeByCurrency: [CurrencyCode: Decimal]
    /// Absolute value of negative expense-category postings.
    public let refundsByCurrency: [CurrencyCode: Decimal]

    public init(
        transactionCount: Int,
        amountsByCurrency: [CurrencyCode: Decimal],
        spendingByCurrency: [CurrencyCode: Decimal] = [:],
        incomeByCurrency: [CurrencyCode: Decimal] = [:],
        refundsByCurrency: [CurrencyCode: Decimal] = [:]
    ) {
        self.transactionCount = transactionCount
        self.amountsByCurrency = amountsByCurrency
        self.spendingByCurrency = spendingByCurrency
        self.incomeByCurrency = incomeByCurrency
        self.refundsByCurrency = refundsByCurrency
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
    /// Optional exact-entry scope used by local review, recurring, and
    /// allowance chips. An empty set deliberately matches nothing.
    public var requiredEntryIDs: Set<UUID>?
    /// Entry identities whose encrypted attachment index matched `searchText`.
    /// This supplements structured transaction fields; it never replaces them.
    public var attachmentMatchedEntryIDs: Set<UUID>?
    public var requiresSplitTransaction: Bool
    public var requiresNote: Bool

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
        maximumAmount: Decimal? = nil,
        requiredEntryIDs: Set<UUID>? = nil,
        attachmentMatchedEntryIDs: Set<UUID>? = nil,
        requiresSplitTransaction: Bool = false,
        requiresNote: Bool = false
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
        self.requiredEntryIDs = requiredEntryIDs
        self.attachmentMatchedEntryIDs = attachmentMatchedEntryIDs
        self.requiresSplitTransaction = requiresSplitTransaction
        self.requiresNote = requiresNote
    }

    public func filteredEntries(
        _ entries: [JournalEntry],
        accounts: [LedgerAccount],
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> [JournalEntry] {
        let performanceInterval = MoneyUpPerformanceSignposts.begin(.historyQuery)
        defer { MoneyUpPerformanceSignposts.end(performanceInterval) }
        let accountsByID = Dictionary(
            accounts.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let search = HistorySearchPass(searchText: searchText, locale: locale)
        return entries.filter {
            matches(
                $0,
                accountsByID: accountsByID,
                locale: locale,
                search: search,
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
        var spending: [CurrencyCode: Decimal] = [:]
        var income: [CurrencyCode: Decimal] = [:]
        var refunds: [CurrencyCode: Decimal] = [:]

        for entry in entries {
            for posting in entry.postings {
                let currency = posting.money.currency
                switch accountsByID[posting.accountID]?.kind {
                case .expense where posting.money.amount > .zero:
                    spending[currency] = try CheckedDecimal.adding(
                        spending[currency] ?? .zero,
                        posting.money.amount
                    )
                case .expense where posting.money.amount < .zero:
                    refunds[currency] = try CheckedDecimal.adding(
                        refunds[currency] ?? .zero,
                        -posting.money.amount
                    )
                case .income where posting.money.amount < .zero:
                    income[currency] = try CheckedDecimal.adding(
                        income[currency] ?? .zero,
                        -posting.money.amount
                    )
                default:
                    break
                }
            }
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
            amountsByCurrency: totals,
            spendingByCurrency: spending,
            incomeByCurrency: income,
            refundsByCurrency: refunds
        )
    }

    private func matches(
        _ entry: JournalEntry,
        accountsByID: [UUID: LedgerAccount],
        locale: Locale,
        search: HistorySearchPass,
        calendar: Calendar
    ) -> Bool {
        if let requiredEntryIDs, !requiredEntryIDs.contains(entry.id) {
            return false
        }
        guard kind == .all || classifiedKind(of: entry, accountsByID: accountsByID) == kind
        else { return false }
        if requiresSplitTransaction {
            let categoryPostingCount = entry.postings.reduce(into: 0) { count, posting in
                guard let account = accountsByID[posting.accountID],
                      account.kind == .expense || account.kind == .income else { return }
                count += 1
            }
            guard categoryPostingCount >= 2 else { return false }
        }
        if requiresNote {
            guard entry.note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            else { return false }
        }
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

        guard !search.textQuery.isEmpty else { return true }
        func includes(_ value: String, _ text: String) -> Bool {
            value.range(
                of: text,
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: locale
            ) != nil
        }
        let textValues = [entry.payee, entry.note].compactMap { $0 }
            + entry.postings.flatMap { pathNames(of: $0.accountID, accountsByID: accountsByID) }
        let structuredMatch = textValues.contains { includes($0, search.textQuery) }
            || search.amountForms(of: entry).contains { includes($0, search.amountQuery) }
        return structuredMatch || attachmentMatchedEntryIDs?.contains(entry.id) == true
    }

    /// An account's name and its parents' ("Groceries", "Food"): rows show a
    /// category's full path, so a parent's name finds its children's rows.
    private func pathNames(
        of accountID: UUID,
        accountsByID: [UUID: LedgerAccount]
    ) -> [String] {
        var names: [String] = []
        var visited: Set<UUID> = []
        var next: UUID? = accountID
        while let id = next, visited.insert(id).inserted, let account = accountsByID[id] {
            names.append(account.name)
            next = account.parentID
        }
        return names
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

/// One search over History: the query prepared once, and the ways each
/// amount can be written, so an entry is found by the figure its row shows
/// ("$28.80", "SGD 1,234.50", "1234.50") as well as by the plain number with
/// its code ("28.8 SGD"). Built per pass and never shared across threads.
final class HistorySearchPass {
    private struct Key: Hashable {
        let amount: Decimal
        let currency: CurrencyCode
    }

    /// The trimmed query, with no-break spaces read as spaces.
    let textQuery: String
    /// The query without one leading sign: amounts are stored unsigned, and a
    /// row shows "−$28.80" for spending.
    let amountQuery: String
    /// The query's digits. The forms a row displays are built only when these
    /// occur in the amount's own digits, the only case in which a displayed
    /// form can match: a search scans the whole book for its totals.
    private let queryDigits: String
    private let locale: Locale
    private let flexibleFormatter: NumberFormatter
    private var displayFormatters: [CurrencyCode: [NumberFormatter]] = [:]
    private var formsByKey: [Key: [String]] = [:]

    init(searchText: String, locale: Locale) {
        textQuery = Self.normalizedSpaces(searchText.trimmingCharacters(in: .whitespacesAndNewlines))
        amountQuery = Self.unsigned(textQuery)
        queryDigits = String(amountQuery.filter(\.isNumber))
        self.locale = locale
        flexibleFormatter = NumberFormatter()
        flexibleFormatter.locale = locale
        flexibleFormatter.numberStyle = .decimal
        flexibleFormatter.minimumFractionDigits = 0
        flexibleFormatter.maximumFractionDigits = 16
    }

    /// Every written form of the entry's amounts, each amount once.
    func amountForms(of entry: JournalEntry) -> [String] {
        var forms: [String] = []
        var seen: Set<Key> = []
        for posting in entry.postings {
            let key = Key(amount: abs(posting.money.amount), currency: posting.money.currency)
            guard seen.insert(key).inserted else { continue }
            forms += self.forms(for: key)
        }
        return forms
    }

    private func forms(for key: Key) -> [String] {
        if let cached = formsByKey[key] { return cached }
        let number = NSDecimalNumber(decimal: key.amount)
        let code = key.currency.value
        var forms = [number.stringValue + " " + code]
        if let flexible = flexibleFormatter.string(from: number) {
            forms.append(flexible + " " + code)
        }
        if !queryDigits.isEmpty {
            let formatters = displayFormatters(for: key.currency)
            // Every displayed form carries the same digits as the plain one.
            if let plain = formatters[1].string(from: number),
               plain.filter(\.isNumber).contains(queryDigits) {
                forms += formatters.compactMap { $0.string(from: number) }
                if let grouped = formatters[0].string(from: number) {
                    forms.append(grouped + " " + code)
                }
            }
        }
        let normalized = forms.map(Self.normalizedSpaces)
        formsByKey[key] = normalized
        return normalized
    }

    /// Grouped and plain numbers (in that order), then the currency forms a
    /// row uses, symbol or ISO code, all at the currency's minor units.
    private func displayFormatters(for currency: CurrencyCode) -> [NumberFormatter] {
        if let cached = displayFormatters[currency] { return cached }
        let styles: [(style: NumberFormatter.Style, groups: Bool)] = [
            (.decimal, true), (.decimal, false), (.currency, true), (.currencyISOCode, true)
        ]
        let formatters = styles.map { variant -> NumberFormatter in
            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = variant.style
            formatter.currencyCode = currency.value
            formatter.usesGroupingSeparator = variant.groups
            formatter.minimumFractionDigits = currency.minorUnits <= 3 ? currency.minorUnits : 0
            formatter.maximumFractionDigits = currency.minorUnits
            return formatter
        }
        displayFormatters[currency] = formatters
        return formatters
    }

    /// Formatters write no-break spaces ("SGD\u{00A0}12.00"); people type
    /// ordinary ones.
    static func normalizedSpaces(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }

    /// The query without one leading sign, so "-28.80" or "−28.80" finds the
    /// unsigned stored amount 28.80.
    static func unsigned(_ query: String) -> String {
        guard let first = query.first, "+-−".contains(first) else { return query }
        return String(query.dropFirst()).trimmingCharacters(in: .whitespaces)
    }
}
