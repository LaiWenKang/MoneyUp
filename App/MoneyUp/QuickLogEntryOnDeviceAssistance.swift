import Foundation
import MoneyUpCore
import SwiftUI

struct QuickLogAssistanceFieldState: Equatable {
    var id: UUID?
    var wasEdited: Bool
    var automaticHistorySuggestionID: UUID?
}

struct QuickLogAssistancePublicationBaseline: Equatable {
    let kind: QuickLogKind
    let profile: UserProfile
    let splitLines: [QuickLogSplitDraftLine]
    let account: QuickLogAssistanceFieldState
    let category: QuickLogAssistanceFieldState
}

enum QuickLogAssistancePublicationPolicy {
    static func currentResolution(
        _ resolution: QuickLogAssistanceResolution,
        plan: QuickLogAssistancePlan,
        baseline: QuickLogAssistancePublicationBaseline,
        currentKind: QuickLogKind,
        currentProfile: UserProfile?,
        currentSplitLines: [QuickLogSplitDraftLine],
        currentAccount: QuickLogAssistanceFieldState,
        currentCategory: QuickLogAssistanceFieldState,
        currentAccountIDs: Set<UUID>,
        currentCategoryIDs: Set<UUID>
    ) -> QuickLogAssistanceResolution? {
        guard currentKind == baseline.kind,
              currentProfile == baseline.profile,
              currentProfile?.foundationModelAssistanceEnabled == true,
              currentSplitLines == baseline.splitLines else { return nil }
        let accountID = currentSuggestion(
            resolution.suggestedAccountID,
            candidates: Set(plan.accountChoices.map(\.id)),
            currentIDs: currentAccountIDs,
            baseline: baseline.account,
            current: currentAccount
        )
        let categoryID = currentSplitLines.isEmpty ? currentSuggestion(
            resolution.suggestedCategoryID,
            candidates: Set(plan.categoryChoices.map(\.id)),
            currentIDs: currentCategoryIDs,
            baseline: baseline.category,
            current: currentCategory
        ) : nil
        let filtered = QuickLogAssistanceResolution(
            suggestedAccountID: accountID,
            suggestedCategoryID: categoryID
        )
        return filtered.isEmpty ? nil : filtered
    }

    private static func currentSuggestion(
        _ suggestionID: UUID?,
        candidates: Set<UUID>,
        currentIDs: Set<UUID>,
        baseline: QuickLogAssistanceFieldState,
        current: QuickLogAssistanceFieldState
    ) -> UUID? {
        guard let suggestionID,
              suggestionID != baseline.id,
              candidates.contains(suggestionID),
              currentIDs.contains(suggestionID),
              current == baseline else { return nil }
        return suggestionID
    }
}

struct QuickLogAssistancePresentation: Equatable {
    private(set) var resolution: QuickLogAssistanceResolution
    private(set) var appliedAccountID: UUID?
    private(set) var appliedCategoryID: UUID?
    private var accountRestoreState: QuickLogAssistanceFieldState?
    private var categoryRestoreState: QuickLogAssistanceFieldState?
    private var modelAppliedAccountState: QuickLogAssistanceFieldState?
    private var modelAppliedCategoryState: QuickLogAssistanceFieldState?

    init(resolution: QuickLogAssistanceResolution) {
        self.resolution = resolution
    }

    mutating func applyAccount(
        _ id: UUID,
        current: QuickLogAssistanceFieldState
    ) -> QuickLogAssistanceFieldState? {
        guard resolution.suggestedAccountID == id else { return nil }
        if accountRestoreState == nil { accountRestoreState = current }
        appliedAccountID = id
        let applied = QuickLogAssistanceFieldState(
            id: id,
            wasEdited: true,
            automaticHistorySuggestionID: nil
        )
        modelAppliedAccountState = applied
        return applied
    }

    mutating func applyCategory(
        _ id: UUID,
        current: QuickLogAssistanceFieldState
    ) -> QuickLogAssistanceFieldState? {
        guard resolution.suggestedCategoryID == id else { return nil }
        if categoryRestoreState == nil { categoryRestoreState = current }
        appliedCategoryID = id
        let applied = QuickLogAssistanceFieldState(
            id: id,
            wasEdited: true,
            automaticHistorySuggestionID: nil
        )
        modelAppliedCategoryState = applied
        return applied
    }

    func rejectingAccount(
        current: QuickLogAssistanceFieldState
    ) -> QuickLogAssistanceFieldState {
        guard current == modelAppliedAccountState,
              let accountRestoreState else { return current }
        return accountRestoreState
    }

    func rejectingCategory(
        current: QuickLogAssistanceFieldState
    ) -> QuickLogAssistanceFieldState {
        guard current == modelAppliedCategoryState,
              let categoryRestoreState else { return current }
        return categoryRestoreState
    }

    mutating func removeDeterministicAccountConflict() {
        resolution = QuickLogAssistanceResolution(
            suggestedAccountID: nil,
            suggestedCategoryID: resolution.suggestedCategoryID
        )
        appliedAccountID = nil
        accountRestoreState = nil
        modelAppliedAccountState = nil
    }

    mutating func removeDeterministicCategoryConflict() {
        resolution = QuickLogAssistanceResolution(
            suggestedAccountID: resolution.suggestedAccountID,
            suggestedCategoryID: nil
        )
        appliedCategoryID = nil
        categoryRestoreState = nil
        modelAppliedCategoryState = nil
    }
}

@MainActor
extension QuickLogEntryView {
    func startOnDeviceAssistance(
        for parsed: ParsedNaturalLanguageEntry
    ) {
        cancelOnDeviceAssistance()
        let enabled = model.profile?.foundationModelAssistanceEnabled == true
        guard enabled, let profile = model.profile else { return }
        let accounts = model.userAccounts
        let categorySnapshot = categories
        let baseline = QuickLogAssistancePublicationBaseline(
            kind: kind,
            profile: profile,
            splitLines: splitLines,
            account: onDeviceAccountFieldState,
            category: onDeviceCategoryFieldState
        )

        onDeviceAssistanceTask = Task { @MainActor in
            var requestPlan: QuickLogAssistancePlan?
            let resolution = await onDeviceAssistanceCoordinator.resolve(
                enabled: enabled
            ) {
                requestPlan = QuickLogAssistancePlan.make(
                    parsed: parsed,
                    accounts: accounts,
                    categories: categorySnapshot,
                    accountFieldWasEdited: baseline.account.wasEdited,
                    categoryFieldWasEdited: baseline.category.wasEdited
                )
                return requestPlan
            }
            guard !Task.isCancelled,
                  let plan = requestPlan,
                  let resolution else {
                return
            }
            guard let currentResolution = QuickLogAssistancePublicationPolicy
                .currentResolution(
                    resolution,
                    plan: plan,
                    baseline: baseline,
                    currentKind: kind,
                    currentProfile: model.profile,
                    currentSplitLines: splitLines,
                    currentAccount: onDeviceAccountFieldState,
                    currentCategory: onDeviceCategoryFieldState,
                    currentAccountIDs: Set(model.userAccounts.map(\.id)),
                    currentCategoryIDs: Set(categories.map(\.id))
                ) else { return }
            onDeviceAssistance = QuickLogAssistancePresentation(
                resolution: currentResolution
            )
        }
    }

    func cancelOnDeviceAssistance() {
        onDeviceAssistanceCoordinator.cancel()
        onDeviceAssistanceTask?.cancel()
        onDeviceAssistanceTask = nil
        onDeviceAssistance = nil
    }

    func rejectOnDeviceAssistance() {
        guard let presentation = onDeviceAssistance else { return }
        applyOnDeviceAccountFieldState(
            presentation.rejectingAccount(current: onDeviceAccountFieldState)
        )
        applyOnDeviceCategoryFieldState(
            presentation.rejectingCategory(current: onDeviceCategoryFieldState)
        )
        cancelOnDeviceAssistance()
        if !dismissAfterSave { model.updateQuickLogDraft(draftSnapshot) }
    }

    func useOnDeviceAccountSuggestion(_ id: UUID) {
        guard model.userAccounts.contains(where: { $0.id == id }),
              var presentation = onDeviceAssistance else { return }
        guard let state = presentation.applyAccount(
            id,
            current: onDeviceAccountFieldState
        ) else { return }
        applyOnDeviceAccountFieldState(state)
        onDeviceAssistance = presentation
        persistUserDraftChange { $0.accountID = id }
    }

    func useOnDeviceCategorySuggestion(_ id: UUID) {
        guard splitLines.isEmpty,
              categories.contains(where: { $0.id == id }),
              var presentation = onDeviceAssistance else { return }
        guard let state = presentation.applyCategory(
            id,
            current: onDeviceCategoryFieldState
        ) else { return }
        applyOnDeviceCategoryFieldState(state)
        onDeviceAssistance = presentation
        persistUserDraftChange { $0.categoryID = id }
    }

    var onDeviceAccountFieldState: QuickLogAssistanceFieldState {
        QuickLogAssistanceFieldState(
            id: accountID,
            wasEdited: accountWasEdited,
            automaticHistorySuggestionID: autoAppliedAccountSuggestionID
        )
    }

    var onDeviceCategoryFieldState: QuickLogAssistanceFieldState {
        QuickLogAssistanceFieldState(
            id: categoryID,
            wasEdited: categoryWasEdited,
            automaticHistorySuggestionID: autoAppliedCategorySuggestionID
        )
    }

    func applyOnDeviceAccountFieldState(
        _ state: QuickLogAssistanceFieldState
    ) {
        accountID = state.id
        accountWasEdited = state.wasEdited
        autoAppliedAccountSuggestionID = state.automaticHistorySuggestionID
    }

    func applyOnDeviceCategoryFieldState(
        _ state: QuickLogAssistanceFieldState
    ) {
        categoryID = state.id
        categoryWasEdited = state.wasEdited
        autoAppliedCategorySuggestionID = state.automaticHistorySuggestionID
    }

    func invalidateOnDeviceAccountForDeterministicChange() {
        guard var presentation = onDeviceAssistance else { return }
        presentation.removeDeterministicAccountConflict()
        onDeviceAssistance = presentation.resolution.isEmpty ? nil : presentation
    }

    func invalidateOnDeviceCategoryForDeterministicChange() {
        guard var presentation = onDeviceAssistance else { return }
        presentation.removeDeterministicCategoryConflict()
        onDeviceAssistance = presentation.resolution.isEmpty ? nil : presentation
    }

    @ViewBuilder
    func onDeviceAssistanceCard(
        _ presentation: QuickLogAssistancePresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                "quick_log.on_device.title",
                systemImage: "sparkles"
            )
            .font(.subheadline.weight(.semibold))

            if let id = presentation.resolution.suggestedAccountID,
               let item = model.accountsByID[id] {
                onDeviceAssistanceRow(
                    title: AppLocalization.string(
                        "quick_log.suggested_account"
                    ),
                    value: item.name,
                    isApplied: presentation.appliedAccountID == id,
                    useAccessibilityLabel: String(
                        format: AppLocalization.string(
                            "quick_log.use_account_accessibility_format"
                        ),
                        item.name
                    )
                ) {
                    useOnDeviceAccountSuggestion(id)
                }
            }
            if let id = presentation.resolution.suggestedCategoryID,
               let item = model.accountsByID[id] {
                onDeviceAssistanceRow(
                    title: AppLocalization.string(
                        "quick_log.suggested_category"
                    ),
                    value: item.name,
                    isApplied: presentation.appliedCategoryID == id,
                    useAccessibilityLabel: String(
                        format: AppLocalization.string(
                            "quick_log.use_category_accessibility_format"
                        ),
                        item.name
                    )
                ) {
                    useOnDeviceCategorySuggestion(id)
                }
            }

            Text("quick_log.on_device.detail")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("quick_log.on_device.reject") {
                rejectOnDeviceAssistance()
            }
            .buttonStyle(.borderless)
        }
        .accessibilityElement(children: .contain)
    }

    private func onDeviceAssistanceRow(
        title: String,
        value: String,
        isApplied: Bool,
        useAccessibilityLabel: String,
        apply: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value).font(.body.weight(.medium))
                Spacer(minLength: 8)
                if isApplied {
                    Label(
                        "quick_log.suggestion_applied",
                        systemImage: "checkmark"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                } else {
                    Button("quick_log.use_suggestion", action: apply)
                        .buttonStyle(.borderless)
                        .accessibilityLabel(
                            Text(useAccessibilityLabel)
                        )
                }
            }
        }
    }
}
