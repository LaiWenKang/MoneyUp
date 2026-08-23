import Foundation

/// Suggests a category for a payee from the user's own logging history.
///
/// This is the whole of MoneyUp's "learning": counting what the person
/// themselves chose last time. It needs no model, no training data from
/// anyone else, and it can always be explained in one sentence — which is
/// what makes the suggestion safe to accept without checking.
public enum CategorySuggester {
    public static func suggestedCategory(
        forPayee payee: String,
        kind: LedgerAccountKind = .expense,
        entries: [JournalEntry],
        accounts: [LedgerAccount]
    ) -> UUID? {
        let needle = TextScanner.normalized(payee).lowercased()
        guard needle.count >= 2 else { return nil }

        let relevantIDs = Set(
            accounts.lazy.filter { $0.kind == kind && !$0.isArchived }.map(\.id)
        )
        guard !relevantIDs.isEmpty else { return nil }

        var counts: [UUID: Int] = [:]
        var mostRecent: [UUID: Date] = [:]

        for entry in entries {
            guard let entryPayee = entry.payee else { continue }
            guard matches(TextScanner.normalized(entryPayee).lowercased(), needle) else {
                continue
            }
            for posting in entry.postings where relevantIDs.contains(posting.accountID) {
                counts[posting.accountID, default: 0] += 1
                let previous = mostRecent[posting.accountID] ?? .distantPast
                mostRecent[posting.accountID] = max(previous, entry.occurredAt)
            }
        }

        return counts
            .max { first, second in
                if first.value != second.value { return first.value < second.value }
                let firstDate = mostRecent[first.key] ?? .distantPast
                let secondDate = mostRecent[second.key] ?? .distantPast
                return firstDate < secondDate
            }?
            .key
    }

    /// Exact match, or one name contained in the other once both are long
    /// enough that the overlap means something. "Starbucks" should match
    /// "Starbucks Orchard"; "A" should match nothing.
    private static func matches(_ stored: String, _ needle: String) -> Bool {
        if stored == needle { return true }
        guard stored.count >= 3, needle.count >= 3 else { return false }
        return stored.contains(needle) || needle.contains(stored)
    }
}
