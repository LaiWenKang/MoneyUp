import Foundation

public enum SmartEntryBatchTextError: Error {
    case tooLarge, tooManyEntries, needsSeparateLines, explicitMultilineSplit
}

/// Batch mode is an explicit user choice: each nonempty line is one draft.
/// Notes stay with their line; blanks and list numbering are presentation only.
public enum SmartEntryBatchText {
    public static let maximumEntries = 32
    private static let listPrefix = try? NSRegularExpression(pattern: #"^(?:[-*•]\s+|[0-9]+[.)]\s+|[0-9]+、\s*|\([0-9]+\)\s+)"#)
    private static let splitPrefix = try? NSRegularExpression(pattern: #"(?i)^(?:split\b|拆分|分摊|分攤|分账|分賬)"#)

    public static func lines(from text: String, explicitlySeparate: Bool = false) throws -> [String] {
        guard text.utf8.count <= SmartEntryInterpreter.maximumInputBytes else { throw SmartEntryBatchTextError.tooLarge }
        let lines = text.split(whereSeparator: \.isNewline).map { line in
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            guard let prefix = listPrefix?.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
                  let range = Range(prefix.range, in: trimmed) else { return trimmed }
            return String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        guard lines.count >= 2 else { throw SmartEntryBatchTextError.needsSeparateLines }
        guard lines.count <= maximumEntries else { throw SmartEntryBatchTextError.tooManyEntries }
        if !explicitlySeparate, let first = lines.first,
           splitPrefix?.firstMatch(in: first, range: NSRange(first.startIndex..., in: first)) != nil {
            throw SmartEntryBatchTextError.explicitMultilineSplit
        }
        return lines
    }
}
