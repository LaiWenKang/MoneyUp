import Foundation

/// Words said to Siri or typed into a shortcut, kept in memory until the Log
/// screen asks for them. They are never written to disk, and only the request
/// that brought them can collect them, so a later Smart Entry from a widget or
/// the Home Screen never picks them up.
@MainActor
final class QuickLogTextPrefill {
    static let shared = QuickLogTextPrefill()
    static let maximumCharacterCount = 500
    /// Long enough to unlock with Face ID or a passcode; short enough that
    /// words nobody collected do not linger.
    static let lifetime: TimeInterval = 300

    private var held: (token: UUID, text: String, expires: Date)?

    /// Returns false when there is nothing to hold. A newer request replaces
    /// an older one that was never collected.
    @discardableResult
    func hold(_ words: String, for token: UUID, now: Date = Date()) -> Bool {
        let text = String(words.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumCharacterCount))
        guard !text.isEmpty else { return false }
        held = (token, text, now.addingTimeInterval(Self.lifetime))
        return true
    }

    /// Hands the words over once, to the request they were held for.
    func take(for token: UUID, now: Date = Date()) -> String? {
        guard let current = held else { return nil }
        if current.expires <= now {
            held = nil
            return nil
        }
        guard current.token == token else { return nil }
        held = nil
        return current.text
    }

    func discard(for token: UUID) {
        if held?.token == token { held = nil }
    }
}
