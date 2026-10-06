import AppIntents

/// Opens Smart Entry in Log with the words a person says or types already in
/// the field. Nothing is saved: the words wait in memory for this one request,
/// Log shows what they mean, and only the person's own tap on Save writes an
/// entry. A locked book still asks to unlock first.
struct LogWithWordsIntent: AppIntent {
    static let title: LocalizedStringResource = "platform_intent.log_with_words.title"
    static let description = IntentDescription("platform_intent.log_with_words.description")
    @available(iOS, obsoleted: 26.0, message: "Replaced by supportedModes")
    static var openAppWhenRun: Bool { true }

#if compiler(>=6.2)
    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = [.foreground(.immediate)]
#endif

    @Parameter(
        title: "platform_intent.log_with_words.words",
        requestValueDialog: IntentDialog("platform_intent.log_with_words.prompt")
    )
    var words: String

    init() {}

    init(words: String) {
        self.words = words
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let token = UUID()
        guard QuickLogTextPrefill.shared.hold(words, for: token) else {
            throw LogWithWordsError.noWords
        }
        guard MoneyUpQuickActionRouteBroker.shared.submit(.smartEntry, token: token) else {
            QuickLogTextPrefill.shared.discard(for: token)
            throw MoneyUpQuickActionIngressError.unavailable
        }
        return .result()
    }
}

enum LogWithWordsError: Error, CustomLocalizedStringResourceConvertible {
    case noWords

    var localizedStringResource: LocalizedStringResource {
        "platform_intent.log_with_words.empty"
    }
}
