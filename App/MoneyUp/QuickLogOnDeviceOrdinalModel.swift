#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
@Generable
private struct LocalOrdinalSelection {
    @Guide(.range(0...15))
    var firstChoiceOrdinal: Int
    @Guide(.range(0...15))
    var secondChoiceOrdinal: Int
}

@available(iOS 26.0, *)
enum QuickLogOnDeviceOrdinalModel {
    static func select(
        request: QuickLogOrdinalRequest
    ) async throws -> QuickLogOrdinalPair? {
        guard SystemLanguageModel.default.availability == .available else {
            return nil
        }
        guard let reviewedPrompt = QuickLogAssistancePrompt.text(
            for: request
        ) else { return nil }
        let session = LanguageModelSession()
        let response = try await session.respond(
            to: reviewedPrompt,
            generating: LocalOrdinalSelection.self
        )
        return QuickLogOrdinalPair(
            firstOrdinal: response.content.firstChoiceOrdinal,
            secondOrdinal: response.content.secondChoiceOrdinal
        )
    }
}
#endif
