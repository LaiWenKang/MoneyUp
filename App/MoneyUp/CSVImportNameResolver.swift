import Foundation
import MoneyUpCore

enum CSVImportReviewedNameDomain {
    case account
    case expenseCategory
    case incomeCategory
}

/// Keeps the import review UI and the commit resolver on one exact notion of
/// name identity. Vendor exports commonly vary only by case or accents; those
/// variants must produce one stable picker and never duplicate dictionary keys.
enum CSVImportNameResolver {
    static func normalizedKey(
        for value: String,
        locale: Locale = .current
    ) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: locale
            )
    }

    static func sourceNames(
        in preview: CSVImportPreview,
        domain: CSVImportReviewedNameDomain,
        locale: Locale = .current
    ) -> [String] {
        let candidates: [String]
        switch domain {
        case .account:
            candidates = preview.rows.flatMap {
                [$0.accountName, $0.destinationAccountName].compactMap { $0 }
            }
        case .expenseCategory:
            candidates = preview.rows.compactMap { row in
                row.kind == .expense || row.kind == .refund
                    ? row.categoryName : nil
            }
        case .incomeCategory:
            candidates = preview.rows.compactMap { row in
                row.kind == .income ? row.categoryName : nil
            }
        }
        return uniqueDisplayNames(candidates, locale: locale)
    }

    static func reviewedMappings(
        for names: [String],
        locale: Locale = .current,
        selectedID: (String) -> UUID?
    ) -> [String: UUID] {
        var result: [String: UUID] = [:]
        for name in uniqueDisplayNames(names, locale: locale) {
            guard let id = selectedID(name) else { continue }
            result[normalizedKey(for: name, locale: locale)] = id
        }
        return result
    }

    private static func uniqueDisplayNames(
        _ names: [String],
        locale: Locale
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(names.count)
        for name in names {
            let key = normalizedKey(for: name, locale: locale)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(name)
        }
        return result.sorted { first, second in
            let comparison = first.localizedStandardCompare(second)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return first < second
        }
    }
}
