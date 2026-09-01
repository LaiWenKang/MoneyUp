import Foundation

/// Locale-stable merchant normalization shared by capture and encrypted
/// intelligence indexes. The normalized value remains financial data and must
/// stay inside the encrypted store and unlocked process memory.
public enum PayeeNormalization {
    public static let maximumIndexKeyByteCount = 512
    private static let cjkRanges: [ClosedRange<UInt32>] = [
        0x3400...0x4DBF,
        0x4E00...0x9FFF,
        0xF900...0xFAFF
    ]

    public static func original(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    public static func key(_ text: String?) -> String? {
        guard let text = original(text) else { return nil }
        let locale = Locale(identifier: "en_US_POSIX")
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: locale
        )
        var pieces: [String] = []
        var current = ""
        for character in folded.lowercased(with: locale) {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                pieces.append(current)
                current = ""
            }
        }
        if !current.isEmpty { pieces.append(current) }
        let result = pieces.joined(separator: " ")
        return result.isEmpty ? nil : result
    }

    public static func boundedIndexKey(_ text: String?) -> String? {
        guard let key = key(text),
              key.utf8.count <= maximumIndexKeyByteCount else { return nil }
        return key
    }

    public static func isMeaningful(_ key: String?) -> Bool {
        guard let key else { return false }
        if containsCJK(key) { return true }
        return key.filter { $0.isLetter || $0.isNumber }.count >= 2
    }

    public static func matches(_ stored: String?, query: String) -> Bool {
        guard let stored else { return false }
        if stored == query { return true }
        if containsCJK(stored) || containsCJK(query) {
            return stored.contains(query) || query.contains(stored)
        }
        guard stored.count >= 3, query.count >= 3 else { return false }
        return tokenSequence(query, appearsIn: stored)
            || tokenSequence(stored, appearsIn: query)
    }

    private static func tokenSequence(
        _ needle: String,
        appearsIn haystack: String
    ) -> Bool {
        haystack == needle
            || haystack.hasPrefix(needle + " ")
            || haystack.hasSuffix(" " + needle)
            || haystack.contains(" " + needle + " ")
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            cjkRanges.contains { $0.contains(scalar.value) }
        }
    }
}
