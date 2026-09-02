import Foundation
import MoneyUpCore

struct QuickLogPromptComponent: Equatable, Sendable {
    let text: String

    private init(text: String) {
        self.text = text
    }

    static func context(_ value: String) -> QuickLogPromptComponent? {
        QuickLogPromptBoundary.normalized(
            value,
            maximumScalarCount: QuickLogPromptBoundary.maximumContextScalarCount,
            maximumUTF8Count: QuickLogPromptBoundary.maximumContextUTF8Count
        ).map { QuickLogPromptComponent(text: $0) }
    }

    static func choice(_ value: String) -> QuickLogPromptComponent? {
        QuickLogPromptBoundary.normalized(
            value,
            maximumScalarCount: QuickLogPromptBoundary.maximumChoiceScalarCount,
            maximumUTF8Count: QuickLogPromptBoundary.maximumChoiceUTF8Count
        ).map { QuickLogPromptComponent(text: $0) }
    }
}

enum QuickLogPromptBoundary {
    static let maximumContextScalarCount = 128
    static let maximumContextUTF8Count = 256
    static let maximumChoiceScalarCount = 48
    static let maximumChoiceUTF8Count = 96
    static let maximumPromptScalarCount = 3_072
    static let maximumPromptUTF8Count = 4_096

    static func normalized(
        _ value: String,
        maximumScalarCount: Int,
        maximumUTF8Count: Int
    ) -> String? {
        let canonical = value.precomposedStringWithCompatibilityMapping
        var collapsed = ""
        var pendingSpace = false
        for scalar in canonical.unicodeScalars {
            let properties = scalar.properties
            if properties.isDefaultIgnorableCodePoint
                || properties.generalCategory == .format {
                continue
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                pendingSpace = !collapsed.isEmpty
                continue
            }
            guard properties.generalCategory != .control else {
                continue
            }
            if pendingSpace {
                collapsed.append(" ")
                pendingSpace = false
            }
            collapsed.unicodeScalars.append(scalar)
        }

        let normalized = collapsed.precomposedStringWithCanonicalMapping
        var result = ""
        var scalarCount = 0
        var utf8Count = 0
        for character in normalized {
            let fragment = String(character)
            let fragmentScalarCount = fragment.unicodeScalars.count
            let fragmentUTF8Count = fragment.utf8.count
            guard scalarCount + fragmentScalarCount <= maximumScalarCount,
                  utf8Count + fragmentUTF8Count <= maximumUTF8Count else {
                break
            }
            result.append(character)
            scalarCount += fragmentScalarCount
            utf8Count += fragmentUTF8Count
        }
        return result.isEmpty ? nil : result
    }

    static func contains(_ prompt: String) -> Bool {
        prompt.unicodeScalars.count <= maximumPromptScalarCount
            && prompt.utf8.count <= maximumPromptUTF8Count
    }
}

struct QuickLogOrdinalRequest: Equatable, Sendable {
    let context: QuickLogPromptComponent
    let firstChoices: [QuickLogPromptComponent]
    let secondChoices: [QuickLogPromptComponent]

    private init(
        context: QuickLogPromptComponent,
        firstChoices: [QuickLogPromptComponent],
        secondChoices: [QuickLogPromptComponent]
    ) {
        self.context = context
        self.firstChoices = firstChoices
        self.secondChoices = secondChoices
    }

    static func make(plan: QuickLogAssistancePlan) -> QuickLogOrdinalRequest? {
        guard let context = QuickLogPromptComponent.context(plan.context) else {
            return nil
        }
        let requestedAccounts = plan.accountChoices.count > 1
            ? plan.accountChoices : []
        let requestedCategories = plan.categoryChoices.count > 1
            ? plan.categoryChoices : []
        let firstChoices = requestedAccounts.compactMap {
            QuickLogPromptComponent.choice($0.label)
        }
        let secondChoices = requestedCategories.compactMap {
            QuickLogPromptComponent.choice($0.label)
        }
        guard firstChoices.count == requestedAccounts.count,
              secondChoices.count == requestedCategories.count,
              Set(firstChoices.map(\.text)).count == firstChoices.count,
              Set(secondChoices.map(\.text)).count == secondChoices.count else {
            return nil
        }
        let request = QuickLogOrdinalRequest(
            context: context,
            firstChoices: firstChoices,
            secondChoices: secondChoices
        )
        return request
    }
}

struct QuickLogOrdinalPair: Equatable, Sendable {
    let firstOrdinal: Int
    let secondOrdinal: Int
}

struct QuickLogAssistanceChoice: Equatable, Sendable {
    let id: UUID
    let label: String
}

struct QuickLogAssistancePlan: Equatable, Sendable {
    static let maximumChoiceCount = 16

    let context: String
    let accountChoices: [QuickLogAssistanceChoice]
    let categoryChoices: [QuickLogAssistanceChoice]

    var isEmpty: Bool {
        accountChoices.count < 2 && categoryChoices.count < 2
    }

    init?(
        context: String,
        accountChoices: [QuickLogAssistanceChoice],
        categoryChoices: [QuickLogAssistanceChoice]
    ) {
        guard accountChoices.count <= Self.maximumChoiceCount,
              categoryChoices.count <= Self.maximumChoiceCount,
              Set(accountChoices.map(\.id)).count == accountChoices.count,
              Set(categoryChoices.map(\.id)).count == categoryChoices.count,
              let normalizedContext = QuickLogPromptComponent.context(context)?.text
        else { return nil }
        // A prompt ordinal is only safe when it names one stable local ID.
        // If normalization or truncation makes two labels identical, close
        // that field instead of asking the model to distinguish an ambiguity.
        let normalizedAccounts = Self.normalizedChoices(accountChoices) ?? []
        let normalizedCategories = Self.normalizedChoices(categoryChoices) ?? []
        guard normalizedAccounts.count >= 2 || normalizedCategories.count >= 2
        else { return nil }
        self.context = normalizedContext
        self.accountChoices = normalizedAccounts
        self.categoryChoices = normalizedCategories
    }

    static func make(
        parsed: ParsedNaturalLanguageEntry,
        accounts: [LedgerAccount],
        categories: [LedgerAccount],
        accountFieldWasEdited: Bool,
        categoryFieldWasEdited: Bool
    ) -> QuickLogAssistancePlan? {
        guard let context = parsed.context else { return nil }
        let accountChoices = parsed.draft.accountID == nil
            && !accountFieldWasEdited
            ? boundedChoices(accounts) : []
        let categoryChoices = parsed.draft.categoryID == nil
            && !categoryFieldWasEdited
            ? boundedChoices(categories) : []
        return QuickLogAssistancePlan(
            context: context,
            accountChoices: accountChoices,
            categoryChoices: categoryChoices
        )
    }

    private static func boundedChoices(
        _ accounts: [LedgerAccount]
    ) -> [QuickLogAssistanceChoice] {
        let bounded = accounts
            .filter { !$0.isArchived && $0.systemRole == nil }
            .compactMap { account in
                QuickLogPromptComponent.choice(account.name).map {
                    QuickLogAssistanceChoice(id: account.id, label: $0.text)
                }
            }
            .sorted { first, second in
                let firstKey = stableKey(first.label)
                let secondKey = stableKey(second.label)
                if firstKey == secondKey {
                    return first.id.uuidString < second.id.uuidString
                }
                return firstKey < secondKey
            }
            .prefix(maximumChoiceCount)
            .map { $0 }
        return normalizedChoices(bounded) ?? []
    }

    private static func normalizedChoices(
        _ choices: [QuickLogAssistanceChoice]
    ) -> [QuickLogAssistanceChoice]? {
        let normalized = choices.compactMap { choice in
            QuickLogPromptComponent.choice(choice.label).map {
                QuickLogAssistanceChoice(id: choice.id, label: $0.text)
            }
        }
        guard normalized.count == choices.count,
              Set(normalized.map(\.label)).count == normalized.count else {
            return nil
        }
        return normalized
    }

    private static func stableKey(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

}

struct QuickLogAssistanceResolution: Equatable, Sendable {
    let suggestedAccountID: UUID?
    let suggestedCategoryID: UUID?

    var isEmpty: Bool {
        suggestedAccountID == nil && suggestedCategoryID == nil
    }
}

struct QuickLogOrdinalSelector: Sendable {
    private let implementation: @Sendable (
        QuickLogOrdinalRequest
    ) async throws -> QuickLogOrdinalPair?

    init(
        _ implementation: @escaping @Sendable (
            QuickLogOrdinalRequest
        ) async throws -> QuickLogOrdinalPair?
    ) {
        self.implementation = implementation
    }

    func select(
        _ request: QuickLogOrdinalRequest
    ) async throws -> QuickLogOrdinalPair? {
        try await implementation(request)
    }

    static let live = QuickLogOrdinalSelector { request in
#if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return try await QuickLogOnDeviceOrdinalModel.select(
                request: request
            )
        }
#endif
        return nil
    }
}

enum QuickLogAssistancePrompt {
    static func text(for request: QuickLogOrdinalRequest) -> String? {
        let firstChoices = numbered(request.firstChoices)
        let secondChoices = numbered(request.secondChoices)
        let prompt = """
        Choose ordinals only from the two closed local lists.
        First ordinal: where the entry belongs.
        Second ordinal: why the entry happened.
        Use zero when a list says Not requested; that output will be ignored.
        Nonfinancial context: \(request.context.text)
        First closed list:
        \(firstChoices)
        Second closed list:
        \(secondChoices)
        """
        return QuickLogPromptBoundary.contains(prompt) ? prompt : nil
    }

    private static func numbered(_ choices: [QuickLogPromptComponent]) -> String {
        guard !choices.isEmpty else { return "Not requested" }
        return choices.enumerated().map { index, choice in
            "\(index): \(choice.text)"
        }.joined(separator: "\n")
    }
}

enum QuickLogAssistanceResolver {
    static func resolve(
        plan: QuickLogAssistancePlan,
        selector: QuickLogOrdinalSelector
    ) async -> QuickLogAssistanceResolution? {
        let requestsAccount = plan.accountChoices.count > 1
        let requestsCategory = plan.categoryChoices.count > 1
        guard requestsAccount || requestsCategory else { return nil }
        guard let request = QuickLogOrdinalRequest.make(plan: plan) else {
            return nil
        }
        let selection: QuickLogOrdinalPair
        do {
            guard let result = try await selector.select(request),
                  !Task.isCancelled else { return nil }
            selection = result
        } catch {
            return nil
        }
        guard (!requestsAccount
                || plan.accountChoices.indices.contains(selection.firstOrdinal)),
              (!requestsCategory
                || plan.categoryChoices.indices.contains(selection.secondOrdinal))
        else { return nil }
        let resolution = QuickLogAssistanceResolution(
            suggestedAccountID: requestsAccount
                ? plan.accountChoices[selection.firstOrdinal].id : nil,
            suggestedCategoryID: requestsCategory
                ? plan.categoryChoices[selection.secondOrdinal].id : nil
        )
        return resolution.isEmpty ? nil : resolution
    }
}

@MainActor
final class QuickLogAssistanceCoordinator {
    private let selector: QuickLogOrdinalSelector
    private var generation = 0

    init(selector: QuickLogOrdinalSelector = .live) {
        self.selector = selector
    }

    func cancel() {
        generation &+= 1
    }

    func resolve(
        enabled: Bool,
        planner: () -> QuickLogAssistancePlan?
    ) async -> QuickLogAssistanceResolution? {
        guard !Task.isCancelled else { return nil }
        generation &+= 1
        let startedGeneration = generation
        guard enabled else { return nil }
        guard let plan = planner() else { return nil }
        let result = await QuickLogAssistanceResolver.resolve(
            plan: plan,
            selector: selector
        )
        guard !Task.isCancelled,
              startedGeneration == generation else { return nil }
        return result
    }
}
