import Foundation

public struct HistoryPreloadSuggestion: Equatable, Sendable, Identifiable {
    public var id: String { PayeeNormalization.key(payee) ?? payee }
    public let payee: String
    public let kind: CaptureIntelligenceKind
    public let currency: CurrencyCode
    public let amount: Money?
    public let fields: CaptureSuggestionResult
    public let supportingCount: Int
}

/// Context weights rank observed transactions, never probabilities or invented
/// monetary values. Account/category are learned together; amount is an exact
/// repeated value within that same route. Ambiguous amounts remain absent.
public enum HistoryPreload {
    private struct Route: Hashable {
        let account: UUID
        let category: UUID
        var key: String { account.uuidString + category.uuidString }
    }

    private struct Sample {
        let entry: JournalEntry
        let route: Route
        let amount: Decimal
        let weight: Double
    }

    public static func suggestions(
        for query: CaptureSuggestionQuery,
        entries: [JournalEntry],
        accounts: [LedgerAccount],
        calendar: Calendar,
        accountID: UUID? = nil,
        categoryID: UUID? = nil
    ) -> [HistoryPreloadSuggestion] {
        guard query.occurredAt.timeIntervalSinceReferenceDate.isFinite,
              [.expense, .income, .refund].contains(query.kind) else { return [] }
        let cutoff = query.occurredAt.addingTimeInterval(-180 * 86_400)
        var grouped: [String: [JournalEntry]] = [:]
        for entry in entries where entry.occurredAt >= cutoff && entry.occurredAt <= query.occurredAt {
            guard let key = PayeeNormalization.key(entry.payee) else { continue }
            grouped[key, default: []].append(entry)
        }
        var ranked: [(suggestion: HistoryPreloadSuggestion, score: Double, last: Date)] = []
        for (key, history) in grouped {
            if let typed = PayeeNormalization.key(query.payee), !key.contains(typed) { continue }
            var samples: [Sample] = []
            for entry in history.sorted(by: {
                if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
                return $0.id.uuidString < $1.id.uuidString
            }) {
                // Complex splits, transfers and multi-account movements must
                // not be flattened into a made-up simple transaction.
                guard entry.postings.count == 2 else { continue }
                let exactQuery = CaptureSuggestionQuery(kind: query.kind, payee: entry.payee,
                    currency: query.currency, occurredAt: query.occurredAt)
                let fields = CaptureSuggestionEngine.suggestions(for: exactQuery,
                    entries: [entry], accounts: accounts)
                guard let account = fields.accountSuggestion?.ledgerAccountID,
                      let category = fields.categorySuggestion?.ledgerAccountID,
                      accountID == nil || accountID == account,
                      categoryID == nil || categoryID == category,
                      let posting = entry.postings.first(where: { $0.accountID == account }),
                      let positive = try? CheckedDecimal.multiplying(posting.money.amount,
                          query.kind == .expense ? -1 : 1),
                      positive > .zero,
                      MonetaryInputPolicy.accepts(positive, currency: query.currency) else { continue }
                samples.append(Sample(entry: entry, route: Route(account: account, category: category),
                    amount: positive, weight: contextWeight(entry.occurredAt, query.occurredAt, calendar)))
            }
            let routes = Dictionary(grouping: samples, by: \.route)
                .filter { $0.value.count >= 2 }
                .sorted {
                    let left = $0.value.reduce(0) { $0 + $1.weight }
                    let right = $1.value.reduce(0) { $0 + $1.weight }
                    if left != right { return left > right }
                    return $0.key.key < $1.key.key
                }
            guard let route = routes.first else { continue }
            let matching = route.value
            guard let latest = matching.map(\.entry).sorted(by: {
                if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
                return $0.id.uuidString < $1.id.uuidString
            }).first, let payee = latest.payee else { continue }
            let merchantQuery = CaptureSuggestionQuery(kind: query.kind, payee: payee,
                currency: query.currency, occurredAt: query.occurredAt)
            let evidence = CaptureSuggestionEvidence(supportingEntryCount: matching.count,
                eligibleEntryCount: samples.count, exactPayeeEntryCount: matching.count,
                mostRecentUse: latest.occurredAt, usedPayeeHistory: true)
            let confidence: CaptureConfidence = matching.count >= 3 && matching.count * 4 >= samples.count * 3
                ? .high : (matching.count * 2 >= samples.count ? .medium : .low)
            let fields = CaptureSuggestionResult(queryFingerprint: merchantQuery.fingerprint,
                accountSuggestion: CaptureFieldSuggestion(ledgerAccountID: route.key.account,
                    confidence: confidence, evidence: evidence),
                categorySuggestion: CaptureFieldSuggestion(ledgerAccountID: route.key.category,
                    confidence: confidence, evidence: evidence))
            let score = matching.reduce(0) { $0 + $1.weight }
            let amount = suggestedAmount(matching, currency: query.currency)
            ranked.append((HistoryPreloadSuggestion(payee: payee, kind: query.kind,
                currency: query.currency, amount: amount, fields: fields,
                supportingCount: matching.count), score, latest.occurredAt))
        }
        return ranked.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.last != $1.last { return $0.last > $1.last }
            return $0.suggestion.id < $1.suggestion.id
        }.prefix(3).map(\.suggestion)
    }

    private static func suggestedAmount(_ matching: [Sample], currency: CurrencyCode) -> Money? {
        let score = matching.reduce(0) { $0 + $1.weight }
        let amounts = Dictionary(grouping: matching, by: \.amount).sorted {
            let left = $0.value.reduce(0) { $0 + $1.weight }
            let right = $1.value.reduce(0) { $0 + $1.weight }
            if left != right { return left > right }
            return $0.key < $1.key
        }
        var amount: Money?
        if let best = amounts.first, best.value.count >= 2,
           best.value.reduce(0, { $0 + $1.weight }) >= score * 0.65 {
            amount = try? Money.newWrite(best.key, currency: currency)
        }
        return amount
    }

    private static func contextWeight(_ past: Date, _ current: Date, _ calendar: Calendar) -> Double {
        let ageDays = current.timeIntervalSince(past) / 86_400
        let sameWeekday = calendar.component(.weekday, from: past) == calendar.component(.weekday, from: current)
        let sameMonthDay = calendar.component(.day, from: past) == calendar.component(.day, from: current)
        let bothMonthEnd = calendar.component(.day, from: past) == calendar.range(of: .day, in: .month, for: past)?.count
            && calendar.component(.day, from: current) == calendar.range(of: .day, in: .month, for: current)?.count
        let hourDistance = abs(calendar.component(.hour, from: past) - calendar.component(.hour, from: current))
        let nearbyHour = min(hourDistance, 24 - hourDistance) <= 2
        return pow(0.5, ageDays / 30) * (sameWeekday ? 1.3 : 1)
            * (sameMonthDay || bothMonthEnd ? 1.8 : 1) * (nearbyHour ? 2.5 : 0.5)
    }
}
