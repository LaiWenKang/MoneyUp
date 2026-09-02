import Foundation
@testable import MoneyUp
import MoneyUpCore
import XCTest

final class QuickLogOnDeviceAssistanceTests: XCTestCase {
    @MainActor
    func testOffGateNeverInvokesInjectedSelector() async throws {
        let calls = AssistanceRequestRecorder()
        var plannerCalls = 0
        let coordinator = QuickLogAssistanceCoordinator(selector: .init {
            request in
            await calls.append(request)
            return QuickLogOrdinalPair(firstOrdinal: 0, secondOrdinal: 0)
        })

        let result = await coordinator.resolve(
            enabled: false
        ) {
            plannerCalls += 1
            return self.plan()
        }

        XCTAssertNil(result)
        XCTAssertEqual(plannerCalls, 0)
        let recorded = await calls.requests()
        XCTAssertEqual(recorded.count, 0)
    }

    @MainActor
    func testUnavailableModelSilentlyKeepsDeterministicResult() async throws {
        let coordinator = QuickLogAssistanceCoordinator(selector: .init { _ in
            nil
        })

        let result = await coordinator.resolve(enabled: true) { self.plan() }

        XCTAssertNil(result)
    }

    @MainActor
    func testGenerationErrorSilentlyKeepsDeterministicResult() async throws {
        let coordinator = QuickLogAssistanceCoordinator(selector: .init { _ in
            throw AssistanceTestError.expected
        })

        let result = await coordinator.resolve(enabled: true) { self.plan() }

        XCTAssertNil(result)
    }

    @MainActor
    func testCancellationSilentlyKeepsDeterministicResult() async throws {
        let coordinator = QuickLogAssistanceCoordinator(selector: .init { _ in
            throw CancellationError()
        })

        let result = await coordinator.resolve(enabled: true) { self.plan() }

        XCTAssertNil(result)
    }

    @MainActor
    func testCancelledBeforeFirstActorTurnDoesNotPlanOrSelect() async {
        let calls = AssistanceRequestRecorder()
        var plannerCalls = 0
        let coordinator = QuickLogAssistanceCoordinator(selector: .init {
            request in
            await calls.append(request)
            return QuickLogOrdinalPair(firstOrdinal: 0, secondOrdinal: 0)
        })
        let task = Task { @MainActor in
            await coordinator.resolve(enabled: true) {
                plannerCalls += 1
                return self.plan()
            }
        }

        task.cancel()
        let result = await task.value
        let recorded = await calls.requests()

        XCTAssertNil(result)
        XCTAssertEqual(plannerCalls, 0)
        XCTAssertEqual(recorded.count, 0)
    }

    @MainActor
    func testCancelledOldRequestCannotInterfereWithFollowingValidRequest() async {
        let calls = AssistanceRequestRecorder()
        var oldPlannerCalls = 0
        var newPlannerCalls = 0
        let coordinator = QuickLogAssistanceCoordinator(selector: .init {
            request in
            await calls.append(request)
            return QuickLogOrdinalPair(firstOrdinal: 0, secondOrdinal: 0)
        })
        let oldTask = Task { @MainActor in
            await coordinator.resolve(enabled: true) {
                oldPlannerCalls += 1
                return self.plan()
            }
        }
        oldTask.cancel()

        let newResult = await coordinator.resolve(enabled: true) {
            newPlannerCalls += 1
            return self.plan()
        }
        let oldResult = await oldTask.value
        let recorded = await calls.requests()

        XCTAssertNil(oldResult)
        XCTAssertNotNil(newResult)
        XCTAssertEqual(oldPlannerCalls, 0)
        XCTAssertEqual(newPlannerCalls, 1)
        XCTAssertEqual(recorded.count, 1)
    }

    @MainActor
    func testStaleGenerationCannotPublishAfterInvalidation() async throws {
        let gate = AssistanceSelectionGate()
        let coordinator = QuickLogAssistanceCoordinator(selector: .init { _ in
            await gate.select()
        })
        let requestPlan = plan()
        let task = Task { @MainActor in
            await coordinator.resolve(enabled: true) { requestPlan }
        }
        await gate.waitUntilReached()

        coordinator.cancel()
        await gate.release(with: QuickLogOrdinalPair(
            firstOrdinal: 0,
            secondOrdinal: 0
        ))

        let result = await task.value
        XCTAssertNil(result)
    }

    @MainActor
    func testReceiptStartCancelsSuspendedAssistanceBeforeItCanPublish() async {
        let gate = AssistanceSelectionGate()
        let coordinator = QuickLogAssistanceCoordinator(selector: .init { _ in
            await gate.select()
        })
        let task = Task { @MainActor in
            await coordinator.resolve(enabled: true) { self.plan() }
        }
        await gate.waitUntilReached()

        let receipt = QuickLogInputAuthority.receiptItemThatMayBegin(
            "receipt",
            isActive: true,
            cancelAssistance: { coordinator.cancel() }
        )
        await gate.release(with: QuickLogOrdinalPair(
            firstOrdinal: 0,
            secondOrdinal: 0
        ))
        let result = await task.value

        XCTAssertEqual(receipt, "receipt")
        XCTAssertNil(result)
    }

    @MainActor
    func testSmartFillCancelsReceiptFirstAndNilTransitionPreservesNewRequest() {
        var events: [String] = []
        QuickLogInputAuthority.beginSmartFill(
            cancelReceipt: { events.append("receipt.cancel") },
            cancelAssistance: { events.append("assistance.cancel") },
            start: { events.append("smart-fill.start") }
        )
        XCTAssertEqual(
            events,
            ["receipt.cancel", "assistance.cancel", "smart-fill.start"]
        )

        let clearedReceipt: String? = QuickLogInputAuthority
            .receiptItemThatMayBegin(
                nil,
                isActive: true,
                cancelAssistance: { events.append("new-assistance.cancel") }
            )

        XCTAssertNil(clearedReceipt)
        XCTAssertEqual(
            events,
            ["receipt.cancel", "assistance.cancel", "smart-fill.start"]
        )
    }

    @MainActor
    func testOutOfRangeOrdinalIsIgnored() async throws {
        let coordinator = QuickLogAssistanceCoordinator(selector: .init { _ in
            QuickLogOrdinalPair(firstOrdinal: 15, secondOrdinal: 15)
        })

        let result = await coordinator.resolve(enabled: true) { self.plan() }

        XCTAssertNil(result)
    }

    func testDeterministicSelectionsWinAndCandidatesStayStableAndBounded() throws {
        let sgd = try CurrencyCode("SGD")
        let accounts = try (0..<20).reversed().map { index in
            LedgerAccount(
                id: XCTUnwrap(UUID(
                    uuidString: String(
                        format: "00000000-0000-0000-0000-%012d",
                        index + 1
                    )
                )),
                name: String(format: "Choice %02d", index),
                kind: .asset,
                currency: sgd
            )
        }
        let category = LedgerAccount(name: "Dining", kind: .expense)
        let parsed = ParsedNaturalLanguageEntry(
            draft: TransactionDraft(
                accountID: accounts[3].id,
                categoryID: category.id,
                source: .naturalLanguage
            ),
            context: "supper"
        )
        XCTAssertNil(QuickLogAssistancePlan.make(
            parsed: parsed,
            accounts: accounts,
            categories: [category],
            accountFieldWasEdited: false,
            categoryFieldWasEdited: false
        ))

        let unmatched = ParsedNaturalLanguageEntry(
            draft: TransactionDraft(source: .naturalLanguage),
            context: "supper"
        )
        let bounded = try XCTUnwrap(QuickLogAssistancePlan.make(
            parsed: unmatched,
            accounts: accounts,
            categories: [],
            accountFieldWasEdited: false,
            categoryFieldWasEdited: false
        ))
        XCTAssertEqual(bounded.accountChoices.count, 16)
        XCTAssertEqual(
            bounded.accountChoices.map(\.label),
            (0..<16).map { String(format: "Choice %02d", $0) }
        )
    }

    func testPromptBoundaryNormalizesAndBoundsCombiningEmojiAndCJK() throws {
        let composed = try XCTUnwrap(QuickLogPromptComponent.context(
            "  cafe\u{301}\n\tmeal\u{0007}  "
        ))
        XCTAssertEqual(composed.text, "café meal")

        let family = "👨‍👩‍👧‍👦"
        let emoji = try XCTUnwrap(QuickLogPromptComponent.choice(
            String(repeating: family, count: 20)
        ))
        XCTAssertLessThanOrEqual(
            emoji.text.unicodeScalars.count,
            QuickLogPromptBoundary.maximumChoiceScalarCount
        )
        XCTAssertLessThanOrEqual(
            emoji.text.utf8.count,
            QuickLogPromptBoundary.maximumChoiceUTF8Count
        )
        let familyMembers: Set<String> = ["👨", "👩", "👧", "👦"]
        XCTAssertFalse(emoji.text.unicodeScalars.contains { $0.value == 0x200D })
        XCTAssertTrue(emoji.text.allSatisfy {
            familyMembers.contains(String($0))
        })

        let cjk = try XCTUnwrap(QuickLogPromptComponent.choice(
            String(repeating: "晚餐分類", count: 100)
        ))
        XCTAssertLessThanOrEqual(
            cjk.text.utf8.count,
            QuickLogPromptBoundary.maximumChoiceUTF8Count
        )
        XCTAssertTrue(cjk.text.hasPrefix("晚餐分類"))

        XCTAssertNil(QuickLogPromptComponent.choice(
            "e" + String(repeating: "\u{301}", count: 200)
        ))
    }

    func testMaximumMultilingualPromptStaysInsideBothTotalCeilings() throws {
        let accountChoices = (0..<16).map { index in
            QuickLogAssistanceChoice(
                id: fixedID(index + 1),
                label: String(repeating: "🥦", count: 40)
            )
        }
        let categoryChoices = (0..<16).map { index in
            QuickLogAssistanceChoice(
                id: fixedID(index + 101),
                label: String(repeating: "餐", count: 80)
            )
        }
        let boundedPlan = try XCTUnwrap(QuickLogAssistancePlan(
            context: String(repeating: "晚", count: 200),
            accountChoices: accountChoices,
            categoryChoices: categoryChoices
        ))
        let request = try XCTUnwrap(QuickLogOrdinalRequest.make(plan: boundedPlan))
        let prompt = try XCTUnwrap(QuickLogAssistancePrompt.text(for: request))

        XCTAssertLessThanOrEqual(
            prompt.unicodeScalars.count,
            QuickLogPromptBoundary.maximumPromptScalarCount
        )
        XCTAssertLessThanOrEqual(
            prompt.utf8.count,
            QuickLogPromptBoundary.maximumPromptUTF8Count
        )
        XCTAssertFalse(prompt.contains("\n\n\n"))
    }

    func testTruncationCollisionClosesOnlyTheAmbiguousField() throws {
        let sharedPrefix = String(repeating: "A", count: 48)
        let plan = try XCTUnwrap(QuickLogAssistancePlan(
            context: "supper",
            accountChoices: [
                QuickLogAssistanceChoice(
                    id: fixedID(1),
                    label: sharedPrefix + " first"
                ),
                QuickLogAssistanceChoice(
                    id: fixedID(2),
                    label: sharedPrefix + " second"
                )
            ],
            categoryChoices: [
                QuickLogAssistanceChoice(id: fixedID(101), label: "Dining"),
                QuickLogAssistanceChoice(id: fixedID(102), label: "Groceries")
            ]
        ))
        let request = try XCTUnwrap(QuickLogOrdinalRequest.make(plan: plan))

        XCTAssertTrue(plan.accountChoices.isEmpty)
        XCTAssertEqual(plan.categoryChoices.count, 2)
        XCTAssertTrue(request.firstChoices.isEmpty)
        XCTAssertEqual(request.secondChoices.map(\.text), ["Dining", "Groceries"])
    }

    func testCanonicalCombiningCollisionClosesOnlyTheAmbiguousField() throws {
        let collisions = [
            ("Cafe\u{301}", "Café"),
            ("Cash", "Ca\u{200B}sh"),
            ("Cash", "Ca\u{FE0F}sh"),
            ("Cash", "Ca\u{202E}sh"),
            ("Cash", "Ca\u{009C}sh"),
            ("Cash", "Ｃａｓｈ"),
            ("Office", "Oﬃce")
        ]

        for (firstLabel, secondLabel) in collisions {
            let plan = try XCTUnwrap(QuickLogAssistancePlan(
                context: "supper",
                accountChoices: [
                    QuickLogAssistanceChoice(id: fixedID(1), label: "Cash"),
                    QuickLogAssistanceChoice(id: fixedID(2), label: "Card")
                ],
                categoryChoices: [
                    QuickLogAssistanceChoice(id: fixedID(101), label: firstLabel),
                    QuickLogAssistanceChoice(id: fixedID(102), label: secondLabel)
                ]
            ))
            let request = try XCTUnwrap(QuickLogOrdinalRequest.make(plan: plan))

            XCTAssertEqual(plan.accountChoices.count, 2, secondLabel)
            XCTAssertTrue(plan.categoryChoices.isEmpty, secondLabel)
            XCTAssertEqual(request.firstChoices.map(\.text), ["Cash", "Card"])
            XCTAssertTrue(request.secondChoices.isEmpty, secondLabel)
        }
    }

    func testLabelCollisionFailsClosedWhenNoOtherFieldIsRequestable() {
        let sharedPrefix = String(repeating: "A", count: 48)

        XCTAssertNil(QuickLogAssistancePlan(
            context: "supper",
            accountChoices: [
                QuickLogAssistanceChoice(
                    id: fixedID(1),
                    label: sharedPrefix + " first"
                ),
                QuickLogAssistanceChoice(
                    id: fixedID(2),
                    label: sharedPrefix + " second"
                )
            ],
            categoryChoices: []
        ))
    }

    func testHistoryMutationBeforeModelReturnFiltersOnlyStaleAccount() throws {
        let fixture = try publicationFixture()
        let historyAccount = QuickLogAssistanceFieldState(
            id: fixedID(50),
            wasEdited: false,
            automaticHistorySuggestionID: fixedID(50)
        )
        let filtered = try XCTUnwrap(
            QuickLogAssistancePublicationPolicy.currentResolution(
                fixture.resolution,
                plan: fixture.plan,
                baseline: fixture.baseline,
                currentKind: .expense,
                currentProfile: fixture.profile,
                currentSplitLines: [],
                currentAccount: historyAccount,
                currentCategory: fixture.baseline.category,
                currentAccountIDs: fixture.accountIDs,
                currentCategoryIDs: fixture.categoryIDs
            )
        )
        XCTAssertNil(filtered.suggestedAccountID)
        XCTAssertEqual(filtered.suggestedCategoryID, fixedID(102))
    }

    func testHistoryMutationBeforeModelReturnFiltersOnlyStaleCategory() throws {
        let fixture = try publicationFixture()
        let historyCategory = QuickLogAssistanceFieldState(
            id: fixedID(150),
            wasEdited: false,
            automaticHistorySuggestionID: fixedID(150)
        )
        let filtered = try XCTUnwrap(
            QuickLogAssistancePublicationPolicy.currentResolution(
                fixture.resolution,
                plan: fixture.plan,
                baseline: fixture.baseline,
                currentKind: .expense,
                currentProfile: fixture.profile,
                currentSplitLines: [],
                currentAccount: fixture.baseline.account,
                currentCategory: historyCategory,
                currentAccountIDs: fixture.accountIDs,
                currentCategoryIDs: fixture.categoryIDs
            )
        )
        XCTAssertEqual(filtered.suggestedAccountID, fixedID(2))
        XCTAssertNil(filtered.suggestedCategoryID)
    }

    func testModelReturnBeforeHistoryMutationPrunesEachUnappliedField() {
        var accountFirst = QuickLogAssistancePresentation(
            resolution: QuickLogAssistanceResolution(
                suggestedAccountID: fixedID(2),
                suggestedCategoryID: fixedID(102)
            )
        )
        accountFirst.removeDeterministicAccountConflict()
        XCTAssertNil(accountFirst.resolution.suggestedAccountID)
        XCTAssertEqual(accountFirst.resolution.suggestedCategoryID, fixedID(102))

        var categoryFirst = QuickLogAssistancePresentation(
            resolution: QuickLogAssistanceResolution(
                suggestedAccountID: fixedID(2),
                suggestedCategoryID: fixedID(102)
            )
        )
        categoryFirst.removeDeterministicCategoryConflict()
        XCTAssertEqual(categoryFirst.resolution.suggestedAccountID, fixedID(2))
        XCTAssertNil(categoryFirst.resolution.suggestedCategoryID)
    }

    func testDeterministicChangeAfterUseInvalidatesBothRejectRestores() throws {
        var presentation = QuickLogAssistancePresentation(
            resolution: QuickLogAssistanceResolution(
                suggestedAccountID: fixedID(2),
                suggestedCategoryID: fixedID(102)
            )
        )
        _ = try XCTUnwrap(presentation.applyAccount(
            fixedID(2),
            current: QuickLogAssistanceFieldState(
                id: fixedID(1),
                wasEdited: false,
                automaticHistorySuggestionID: nil
            )
        ))
        _ = try XCTUnwrap(presentation.applyCategory(
            fixedID(102),
            current: QuickLogAssistanceFieldState(
                id: fixedID(101),
                wasEdited: false,
                automaticHistorySuggestionID: nil
            )
        ))
        let deterministicAccount = QuickLogAssistanceFieldState(
            id: fixedID(50),
            wasEdited: false,
            automaticHistorySuggestionID: fixedID(50)
        )
        let deterministicCategory = QuickLogAssistanceFieldState(
            id: fixedID(150),
            wasEdited: false,
            automaticHistorySuggestionID: fixedID(150)
        )
        presentation.removeDeterministicAccountConflict()
        presentation.removeDeterministicCategoryConflict()

        XCTAssertTrue(presentation.resolution.isEmpty)
        XCTAssertEqual(
            presentation.rejectingAccount(current: deterministicAccount),
            deterministicAccount
        )
        XCTAssertEqual(
            presentation.rejectingCategory(current: deterministicCategory),
            deterministicCategory
        )
    }

    func testSuspendedKindProfileSplitAndMembershipMutationsFailClosed() throws {
        let fixture = try publicationFixture()
        func resolve(
            kind: QuickLogKind = .expense,
            profile: UserProfile?,
            splits: [QuickLogSplitDraftLine] = [],
            accounts: Set<UUID>? = nil,
            categories: Set<UUID>? = nil
        ) -> QuickLogAssistanceResolution? {
            QuickLogAssistancePublicationPolicy.currentResolution(
                fixture.resolution,
                plan: fixture.plan,
                baseline: fixture.baseline,
                currentKind: kind,
                currentProfile: profile,
                currentSplitLines: splits,
                currentAccount: fixture.baseline.account,
                currentCategory: fixture.baseline.category,
                currentAccountIDs: accounts ?? fixture.accountIDs,
                currentCategoryIDs: categories ?? fixture.categoryIDs
            )
        }
        XCTAssertNil(resolve(kind: .income, profile: fixture.profile))
        var disabled = fixture.profile
        disabled.foundationModelAssistanceEnabled = false
        XCTAssertNil(resolve(profile: disabled))
        var changedProfile = fixture.profile
        changedProfile.allowLockedQuickCapture.toggle()
        XCTAssertNil(resolve(profile: changedProfile))
        XCTAssertNil(resolve(
            profile: fixture.profile,
            splits: [QuickLogSplitDraftLine(categoryID: fixedID(101))]
        ))
        XCTAssertNil(resolve(
            profile: fixture.profile,
            accounts: [fixedID(1)],
            categories: [fixedID(101)]
        ))
        XCTAssertNil(QuickLogAssistancePublicationPolicy.currentResolution(
            QuickLogAssistanceResolution(
                suggestedAccountID: fixedID(50),
                suggestedCategoryID: fixedID(150)
            ),
            plan: fixture.plan,
            baseline: fixture.baseline,
            currentKind: .expense,
            currentProfile: fixture.profile,
            currentSplitLines: [],
            currentAccount: fixture.baseline.account,
            currentCategory: fixture.baseline.category,
            currentAccountIDs: fixture.accountIDs,
            currentCategoryIDs: fixture.categoryIDs
        ))
    }

    func testUseRejectRestoresImmediateAccountAndCategoryProvenance() throws {
        let historyAccount = QuickLogAssistanceFieldState(
            id: fixedID(50),
            wasEdited: false,
            automaticHistorySuggestionID: fixedID(50)
        )
        let historyCategory = QuickLogAssistanceFieldState(
            id: fixedID(150),
            wasEdited: false,
            automaticHistorySuggestionID: fixedID(150)
        )
        var presentation = QuickLogAssistancePresentation(
            resolution: QuickLogAssistanceResolution(
                suggestedAccountID: fixedID(2),
                suggestedCategoryID: fixedID(102)
            )
        )
        let appliedAccount = try XCTUnwrap(presentation.applyAccount(
            fixedID(2),
            current: historyAccount
        ))
        let appliedCategory = try XCTUnwrap(presentation.applyCategory(
            fixedID(102),
            current: historyCategory
        ))
        XCTAssertTrue(appliedAccount.wasEdited)
        XCTAssertNil(appliedAccount.automaticHistorySuggestionID)
        XCTAssertTrue(appliedCategory.wasEdited)
        XCTAssertNil(appliedCategory.automaticHistorySuggestionID)
        let restoredAccount = presentation.rejectingAccount(current: appliedAccount)
        let restoredCategory = presentation.rejectingCategory(current: appliedCategory)
        XCTAssertEqual(restoredAccount, historyAccount)
        XCTAssertFalse(restoredAccount.wasEdited)
        XCTAssertEqual(
            restoredAccount.automaticHistorySuggestionID,
            historyAccount.id
        )
        XCTAssertEqual(restoredCategory, historyCategory)
        XCTAssertFalse(restoredCategory.wasEdited)
        XCTAssertEqual(
            restoredCategory.automaticHistorySuggestionID,
            historyCategory.id
        )
        let newerAccountProvenance = QuickLogAssistanceFieldState(
            id: appliedAccount.id,
            wasEdited: false,
            automaticHistorySuggestionID: appliedAccount.id
        )
        let newerCategoryProvenance = QuickLogAssistanceFieldState(
            id: appliedCategory.id,
            wasEdited: false,
            automaticHistorySuggestionID: appliedCategory.id
        )
        XCTAssertEqual(
            presentation.rejectingAccount(current: newerAccountProvenance),
            newerAccountProvenance
        )
        XCTAssertEqual(
            presentation.rejectingCategory(current: newerCategoryProvenance),
            newerCategoryProvenance
        )
    }

    @MainActor
    func testSameIDReceiptCategoryInvalidatesAppliedModelProvenanceBeforeReject() throws {
        let original = QuickLogAssistanceFieldState(
            id: fixedID(101),
            wasEdited: false,
            automaticHistorySuggestionID: fixedID(101)
        )
        let receiptCategoryID = fixedID(102)
        var presentation = QuickLogAssistancePresentation(
            resolution: QuickLogAssistanceResolution(
                suggestedAccountID: nil,
                suggestedCategoryID: receiptCategoryID
            )
        )
        var current = try XCTUnwrap(presentation.applyCategory(
            receiptCategoryID,
            current: original
        ))

        QuickLogInputAuthority.applyReceiptCategory(
            invalidateAssistance: {
                presentation.removeDeterministicCategoryConflict()
            },
            mutation: {
                current = QuickLogAssistanceFieldState(
                    id: receiptCategoryID,
                    wasEdited: true,
                    automaticHistorySuggestionID: nil
                )
            }
        )

        XCTAssertNil(presentation.appliedCategoryID)
        XCTAssertNil(presentation.resolution.suggestedCategoryID)
        XCTAssertEqual(presentation.rejectingCategory(current: current), current)
        XCTAssertNotEqual(
            presentation.rejectingCategory(current: current),
            original
        )
    }

    @MainActor
    func testInjectedBoundaryReceivesNoParsedFinancialSpans() async throws {
        let sgd = try CurrencyCode("SGD")
        let accounts = [
            LedgerAccount(name: "Cash", kind: .asset, currency: sgd),
            LedgerAccount(name: "Card", kind: .liability, currency: sgd)
        ]
        let categories = [
            LedgerAccount(name: "Dining", kind: .expense),
            LedgerAccount(name: "Groceries", kind: .expense)
        ]
        let parsed = NaturalLanguageEntryParser.parse(
            "Supper SGD $1,234.50 on 15/03/2026",
            accounts: accounts + categories,
            prefersDayFirst: true,
            locale: Locale(identifier: "en_SG")
        )
        let requestPlan = try XCTUnwrap(QuickLogAssistancePlan.make(
            parsed: parsed,
            accounts: accounts,
            categories: categories,
            accountFieldWasEdited: false,
            categoryFieldWasEdited: false
        ))
        let recorder = AssistanceRequestRecorder()
        let coordinator = QuickLogAssistanceCoordinator(selector: .init {
            request in
            await recorder.append(request)
            return QuickLogOrdinalPair(firstOrdinal: 0, secondOrdinal: 0)
        })

        let result = await coordinator.resolve(
            enabled: true
        ) { requestPlan }
        XCTAssertNotNil(result)
        let requests = await recorder.requests()
        XCTAssertEqual(requests.count, 1)
        for request in requests {
            let prompt = try XCTUnwrap(QuickLogAssistancePrompt.text(for: request))
            XCTAssertEqual(request.context.text, "Supper")
            XCTAssertFalse(prompt.contains("1,234.50"))
            XCTAssertFalse(prompt.contains("15/03/2026"))
            XCTAssertFalse(prompt.contains("SGD"))
            XCTAssertFalse(prompt.contains("$"))
        }
    }

    private func plan() -> QuickLogAssistancePlan {
        guard let plan = QuickLogAssistancePlan(
            context: "supper",
            accountChoices: [
                QuickLogAssistanceChoice(id: UUID(), label: "Cash"),
                QuickLogAssistanceChoice(id: UUID(), label: "Card")
            ],
            categoryChoices: [
                QuickLogAssistanceChoice(id: UUID(), label: "Dining"),
                QuickLogAssistanceChoice(id: UUID(), label: "Groceries")
            ]
        ) else { fatalError("valid assistance fixture") }
        return plan
    }

    private func publicationFixture() throws -> (
        plan: QuickLogAssistancePlan,
        resolution: QuickLogAssistanceResolution,
        baseline: QuickLogAssistancePublicationBaseline,
        profile: UserProfile,
        accountIDs: Set<UUID>,
        categoryIDs: Set<UUID>
    ) {
        let profile = UserProfile(
            baseCurrency: try CurrencyCode("SGD"),
            foundationModelAssistanceEnabled: true
        )
        let plan = try XCTUnwrap(QuickLogAssistancePlan(
            context: "supper",
            accountChoices: [
                QuickLogAssistanceChoice(id: fixedID(1), label: "Cash"),
                QuickLogAssistanceChoice(id: fixedID(2), label: "Card")
            ],
            categoryChoices: [
                QuickLogAssistanceChoice(id: fixedID(101), label: "Dining"),
                QuickLogAssistanceChoice(id: fixedID(102), label: "Groceries")
            ]
        ))
        let account = QuickLogAssistanceFieldState(
            id: fixedID(1),
            wasEdited: false,
            automaticHistorySuggestionID: nil
        )
        let category = QuickLogAssistanceFieldState(
            id: fixedID(101),
            wasEdited: false,
            automaticHistorySuggestionID: nil
        )
        return (
            plan,
            QuickLogAssistanceResolution(
                suggestedAccountID: fixedID(2),
                suggestedCategoryID: fixedID(102)
            ),
            QuickLogAssistancePublicationBaseline(
                kind: .expense,
                profile: profile,
                splitLines: [],
                account: account,
                category: category
            ),
            profile,
            [fixedID(1), fixedID(2), fixedID(50)],
            [fixedID(101), fixedID(102), fixedID(150)]
        )
    }

    private func fixedID(_ suffix: Int) -> UUID {
        guard let id = UUID(uuidString: String(
            format: "00000000-0000-0000-0000-%012d",
            suffix
        )) else { fatalError("valid deterministic UUID fixture") }
        return id
    }
}

private enum AssistanceTestError: Error {
    case expected
}

private actor AssistanceRequestRecorder {
    private var stored: [QuickLogOrdinalRequest] = []

    func append(_ request: QuickLogOrdinalRequest) {
        stored.append(request)
    }

    func requests() -> [QuickLogOrdinalRequest] {
        stored
    }
}

private actor AssistanceSelectionGate {
    private var reached = false
    private var releasedValue: QuickLogOrdinalPair?
    private var reachWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [
        CheckedContinuation<QuickLogOrdinalPair?, Never>
    ] = []

    func select() async -> QuickLogOrdinalPair? {
        reached = true
        reachWaiters.forEach { $0.resume() }
        reachWaiters.removeAll()
        if let releasedValue { return releasedValue }
        return await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilReached() async {
        guard !reached else { return }
        await withCheckedContinuation { continuation in
            reachWaiters.append(continuation)
        }
    }

    func release(with value: QuickLogOrdinalPair) {
        releasedValue = value
        releaseWaiters.forEach { $0.resume(returning: value) }
        releaseWaiters.removeAll()
    }
}
