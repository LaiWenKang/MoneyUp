import Foundation

/// Exact local names, longest non-overlapping spans first. Latin boundaries
/// remain Unicode-safe; adjacent Chinese prose may delimit a Latin name.
struct SmartEntryNames {
    struct Match {
        let account: LedgerAccount
        let range: Range<String.Index>
    }
    let matches: [Match]
    var uniqueID: UUID? { matches.count == 1 ? matches.first?.account.id : nil }
    var isAmbiguous: Bool { matches.count > 1 }

    init(text: String, accounts: [LedgerAccount], allowJoinedAmount: Bool = false) {
        let candidates = accounts.filter { !$0.isArchived && $0.systemRole == nil }.compactMap { account -> Match? in
            guard !Task.isCancelled else { return nil }
            let name = account.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            var start = text.startIndex
            while start < text.endIndex,
                  let range = text.range(of: name, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], range: start..<text.endIndex) {
                let cjkName = name.unicodeScalars.contains(where: Self.isCJK)
                if cjkName || (!Self.touchesWord(text[..<range.lowerBound].unicodeScalars.reversed())
                    && (allowJoinedAmount && text[range.upperBound...].first?.isNumber == true
                        || !Self.touchesWord(text[range.upperBound...].unicodeScalars))) {
                    return Match(account: account, range: range)
                }
                start = range.upperBound
            }
            return nil
        }.sorted {
            if $0.account.name.count != $1.account.name.count { return $0.account.name.count > $1.account.name.count }
            return $0.account.id.uuidString < $1.account.id.uuidString
        }
        var chosen: [Match] = []
        for candidate in candidates {
            // Equal spans with different IDs stay ambiguous, never UUID-picked.
            if chosen.contains(where: { $0.range != candidate.range && $0.range.overlaps(candidate.range) }) { continue }
            chosen.append(candidate)
        }
        matches = chosen.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    func removingNames(from text: String) -> String {
        var result = text
        let ranges = Set(matches.map(\.range)).sorted { $0.lowerBound > $1.lowerBound }
        for range in ranges { result.replaceSubrange(range, with: " ") }
        return result
    }

    private static func touchesWord<S: Sequence>(_ scalars: S) -> Bool where S.Element == Unicode.Scalar {
        for scalar in scalars {
            if scalar.properties.isDefaultIgnorableCodePoint { continue }
            switch scalar.properties.generalCategory {
            case .format, .nonspacingMark, .spacingMark, .enclosingMark: continue
            default: return CharacterSet.alphanumerics.contains(scalar) && !isCJK(scalar)
            }
        }
        return false
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
            || (0xF900...0xFAFF).contains(scalar.value)
    }
}
