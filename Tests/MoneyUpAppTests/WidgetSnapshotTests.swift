import Foundation
@testable import MoneyUp
import MoneyUpCore
import XCTest

final class WidgetSnapshotTests: XCTestCase {
    func testSmartOverviewMapsEveryBudgetStateWithoutInventingZero() {
        let expiry = Date(timeIntervalSinceReferenceDate: 800_003_600)
        let expectedComponents: [
            SmartOverviewWidgetPresentation.Family:
                [SmartOverviewWidgetPresentation.Component]
        ] = [
            .systemSmall: [.budget, .review, .allowance, .commitment],
            .systemMedium: [.budget, .review, .allowance, .commitment],
            .accessoryInline: [.budget, .review],
            .accessoryCircular: [.budget],
            .accessoryRectangular: [.budget, .review, .commitment]
        ]
        let cases: [(
            BudgetWidgetSnapshot,
            SmartOverviewWidgetPresentation.BudgetStatus,
            Bool,
            Bool
        )] = [
            (.disabled, .disabled, false, true),
            (.needsBudget(validUntil: expiry), .needsBudget, false, false),
            (.zeroBudget(validUntil: expiry), .zeroBudget, false, false),
            (.negativeBudget(validUntil: expiry), .negativeBudget, false, false),
            (.stale, .stale, true, false),
            (
                .available(percentUsed: 0, validUntil: expiry),
                .available(percentUsed: 0),
                false,
                false
            ),
            (
                .available(percentUsed: 125, validUntil: expiry),
                .available(percentUsed: 125),
                false,
                false
            )
        ]

        XCTAssertEqual(
            Set(expectedComponents.keys),
            Set(SmartOverviewWidgetPresentation.Family.allCases)
        )
        for (snapshot, expected, refreshesOnOpen, requiresSettings) in cases {
            for family in SmartOverviewWidgetPresentation.Family.allCases {
                let presentation = SmartOverviewWidgetPresentation.make(
                    budget: snapshot,
                    insights: nil,
                    family: family
                )

                XCTAssertEqual(presentation.family, family)
                XCTAssertEqual(presentation.budget, expected)
                XCTAssertEqual(
                    presentation.budget.canRefreshByOpeningApp,
                    refreshesOnOpen
                )
                XCTAssertEqual(
                    presentation.budget.requiresSettingsEnablement,
                    requiresSettings
                )
                XCTAssertEqual(
                    presentation.components,
                    refreshesOnOpen || requiresSettings
                        ? [.budget]
                        : expectedComponents[family]
                )
            }
        }
    }

    func testSmartOverviewKeepsCurrentBudgetWhenInsightsAreUnavailableOrPartial() {
        let expiry = Date(timeIntervalSinceReferenceDate: 800_003_600)
        let partialInsights = MoneyUpWidgetInsights(
            reviewCount: nil,
            allowancePercentRemaining: 63,
            activeCommitmentCount: 0,
            daysUntilNextCommitment: nil,
            validUntil: expiry
        )

        for family in SmartOverviewWidgetPresentation.Family.allCases {
            let withoutInsights = SmartOverviewWidgetPresentation.make(
                budget: .available(percentUsed: 42, validUntil: expiry),
                insights: nil,
                family: family
            )

            XCTAssertEqual(withoutInsights.family, family)
            XCTAssertEqual(withoutInsights.budget, .available(percentUsed: 42))
            XCTAssertNil(withoutInsights.reviewCount)
            XCTAssertNil(withoutInsights.allowancePercentRemaining)
            XCTAssertNil(withoutInsights.activeCommitmentCount)
            XCTAssertNil(withoutInsights.daysUntilNextCommitment)
            XCTAssertEqual(withoutInsights.commitment, .unavailable)

            let partial = SmartOverviewWidgetPresentation.make(
                budget: .available(percentUsed: 42, validUntil: expiry),
                insights: partialInsights,
                family: family
            )

            XCTAssertEqual(partial.family, family)
            XCTAssertEqual(partial.budget, .available(percentUsed: 42))
            XCTAssertNil(partial.reviewCount)
            XCTAssertEqual(partial.allowancePercentRemaining, 63)
            XCTAssertEqual(partial.activeCommitmentCount, 0)
            XCTAssertNil(partial.daysUntilNextCommitment)
            XCTAssertEqual(partial.commitment, .none)
        }

        let unknownDueDay = SmartOverviewWidgetPresentation.make(
            budget: .needsBudget(validUntil: expiry),
            insights: MoneyUpWidgetInsights(
                reviewCount: 0,
                allowancePercentRemaining: nil,
                activeCommitmentCount: 2,
                daysUntilNextCommitment: nil,
                validUntil: expiry
            ),
            family: .accessoryRectangular
        )
        XCTAssertEqual(
            unknownDueDay.commitment,
            .active(count: 2, daysUntilNext: nil)
        )
    }

    func testSmartOverviewSeparatesOneDayForAccessibleGrammar() {
        let expiry = Date(timeIntervalSinceReferenceDate: 800_003_600)
        let expected: [(
            days: Int?,
            distance: SmartOverviewWidgetPresentation.DayDistance
        )] = [
            (nil, .unavailable),
            (0, .today),
            (1, .oneDay),
            (2, .days(2))
        ]

        for (days, distance) in expected {
            let presentation = SmartOverviewWidgetPresentation.make(
                budget: .available(percentUsed: 42, validUntil: expiry),
                insights: MoneyUpWidgetInsights(
                    reviewCount: 0,
                    allowancePercentRemaining: nil,
                    activeCommitmentCount: 1,
                    daysUntilNextCommitment: days,
                    validUntil: expiry
                ),
                family: .systemMedium
            )
            XCTAssertEqual(presentation.commitmentDayDistance, distance)
        }
    }

    func testSmartOverviewEveryFamilyConsumesBudgetWithNativeInsightDensity() {
        let expected: [
            SmartOverviewWidgetPresentation.Family:
                [SmartOverviewWidgetPresentation.Component]
        ] = [
            .systemSmall: [.budget, .review, .allowance, .commitment],
            .systemMedium: [.budget, .review, .allowance, .commitment],
            .accessoryInline: [.budget, .review],
            .accessoryCircular: [.budget],
            .accessoryRectangular: [.budget, .review, .commitment]
        ]

        XCTAssertEqual(
            Set(expected.keys),
            Set(SmartOverviewWidgetPresentation.Family.allCases)
        )
        for family in SmartOverviewWidgetPresentation.Family.allCases {
            let presentation = SmartOverviewWidgetPresentation.make(
                budget: .available(
                    percentUsed: 42,
                    validUntil: Date(timeIntervalSinceReferenceDate: 800_003_600)
                ),
                insights: nil,
                family: family
            )
            XCTAssertEqual(presentation.components, expected[family])
            XCTAssertEqual(presentation.components.first, .budget)
        }
    }

    func testAccessibilityHomeDensityReducesVisibleWidgetWork() {
        XCTAssertEqual(MoneyUpWidgetHomeDensity.standard.mediumQuickActionLimit, 4)
        XCTAssertFalse(
            MoneyUpWidgetHomeDensity.standard.usesReducedBudgetStatus
        )
        XCTAssertEqual(
            MoneyUpWidgetHomeDensity.accessibility.mediumQuickActionLimit,
            1
        )
        XCTAssertTrue(
            MoneyUpWidgetHomeDensity.accessibility.usesReducedBudgetStatus
        )

        let expected: [
            SmartOverviewWidgetPresentation.Family:
                [SmartOverviewWidgetPresentation.Component]
        ] = [
            .systemSmall: [.budget],
            .systemMedium: [.budget, .review],
            .accessoryInline: [.budget, .review],
            .accessoryCircular: [.budget],
            .accessoryRectangular: [.budget, .review, .commitment]
        ]
        for family in SmartOverviewWidgetPresentation.Family.allCases {
            let presentation = SmartOverviewWidgetPresentation.make(
                budget: .available(
                    percentUsed: 42,
                    validUntil: Date(timeIntervalSinceReferenceDate: 800_003_600)
                ),
                insights: nil,
                family: family,
                homeDensity: .accessibility
            )

            XCTAssertEqual(presentation.homeDensity, .accessibility)
            XCTAssertEqual(presentation.components, expected[family])
        }
    }

    func testWidgetTimelinePublishesStaleEntryAtFirstDisplayedExpiry() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let insightExpiry = now.addingTimeInterval(60)
        let budgetExpiry = now.addingTimeInterval(120)
        let snapshot = MoneyUpWidgetPublishedSnapshot(
            budget: .available(percentUsed: 42, validUntil: budgetExpiry),
            insights: MoneyUpWidgetInsights(
                reviewCount: 1,
                allowancePercentRemaining: 60,
                activeCommitmentCount: 2,
                daysUntilNextCommitment: 3,
                validUntil: insightExpiry
            )
        )

        let smart = MoneyUpWidgetTimelinePlanner.generations(
            startingAt: now,
            snapshot: snapshot,
            surface: .smartOverview
        )
        XCTAssertEqual(smart.map(\.date), [now, insightExpiry])
        XCTAssertEqual(smart.first?.snapshot, snapshot)
        XCTAssertEqual(
            smart.last?.snapshot,
            MoneyUpWidgetPublishedSnapshot(budget: .stale, insights: nil)
        )

        let budget = MoneyUpWidgetTimelinePlanner.generations(
            startingAt: now,
            snapshot: snapshot,
            surface: .budgetStatus
        )
        XCTAssertEqual(budget.map(\.date), [now, budgetExpiry])
        XCTAssertEqual(budget.last?.snapshot.budget, .stale)

        let quickAction = MoneyUpWidgetTimelinePlanner.generations(
            startingAt: now,
            snapshot: snapshot,
            surface: .quickAction
        )
        XCTAssertEqual(quickAction.count, 1)
        XCTAssertEqual(quickAction.first?.snapshot, snapshot)
    }

    func testVersionFourPublishesOneAtomicBoundedRecord() throws {
        let suiteName = "MoneyUpWidgetAtomic-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BudgetWidgetSnapshotStore(defaults: defaults)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let dayEnd = now.addingTimeInterval(3_600)
        let monthEnd = now.addingTimeInterval(86_400)

        store.publish(
            .available(percentUsed: Int.max, validUntil: monthEnd),
            periodToken: "2026-05",
            insights: MoneyUpWidgetInsights(
                reviewCount: Int.max,
                allowancePercentRemaining: 150,
                activeCommitmentCount: Int.max,
                daysUntilNextCommitment: Int.max,
                validUntil: dayEnd
            )
        )

        let persistedDomain = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertEqual(
            Set(persistedDomain.keys),
            BudgetWidgetSnapshotStore.allowedPersistedKeys
        )
        XCTAssertEqual(
            store.read(now: now),
            .available(percentUsed: 9_999, validUntil: monthEnd)
        )
        let insights = try XCTUnwrap(store.readInsights(now: now))
        XCTAssertEqual(insights.reviewCount, 9_999)
        XCTAssertEqual(insights.allowancePercentRemaining, 100)
        XCTAssertEqual(insights.activeCommitmentCount, 9_999)
        XCTAssertEqual(insights.daysUntilNextCommitment, 9_999)
        let generation = store.readPublishedSnapshot(now: now)
        XCTAssertEqual(
            generation.budget,
            .available(percentUsed: 9_999, validUntil: monthEnd)
        )
        XCTAssertEqual(generation.insights, insights)

        let payload = try XCTUnwrap(defaults.data(
            forKey: BudgetWidgetSnapshotStore.payloadKey
        ))
        XCTAssertLessThanOrEqual(
            payload.count,
            BudgetWidgetSnapshotStore.maximumPayloadByteCount
        )
        let json = try XCTUnwrap(String(data: payload, encoding: .utf8))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), [
            "schemaVersion", "enabled", "budgetState", "percentUsed",
            "periodToken", "budgetValidUntil", "insights"
        ])
        let insightObject = try XCTUnwrap(object["insights"] as? [String: Any])
        XCTAssertEqual(Set(insightObject.keys), [
            "reviewCount", "allowancePercentRemaining", "activeCommitmentCount",
            "daysUntilNextCommitment", "validUntil"
        ])
        XCTAssertFalse(json.contains("nextCommitment\""))
        XCTAssertFalse(json.contains("activeAllowanceCount"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("payee"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("account"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("balance"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("holding"))
    }

    func testVersionFourNegativeValuesInvalidateTheAtomicGeneration() throws {
        let suiteName = "MoneyUpWidgetNegativeV4-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BudgetWidgetSnapshotStore(defaults: defaults)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let expiry = now.addingTimeInterval(3_600)
        let validInsights = MoneyUpWidgetInsights(
            reviewCount: 3,
            allowancePercentRemaining: 60,
            activeCommitmentCount: 2,
            daysUntilNextCommitment: 1,
            validUntil: expiry
        )
        let stale = MoneyUpWidgetPublishedSnapshot(
            budget: .stale,
            insights: nil
        )

        func publishValidGeneration() {
            store.publish(
                .available(percentUsed: 42, validUntil: expiry),
                periodToken: "2026-05",
                insights: validInsights
            )
        }

        func replaceWithNegative(
            _ key: String,
            inInsights: Bool
        ) throws {
            let payload = try XCTUnwrap(defaults.data(
                forKey: BudgetWidgetSnapshotStore.payloadKey
            ))
            var object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: payload) as? [String: Any]
            )
            if inInsights {
                var insights = try XCTUnwrap(object["insights"] as? [String: Any])
                insights[key] = -1
                object["insights"] = insights
            } else {
                object[key] = -1
            }
            defaults.set(
                try JSONSerialization.data(withJSONObject: object),
                forKey: BudgetWidgetSnapshotStore.payloadKey
            )
        }

        let mutations = [
            ("percentUsed", false),
            ("reviewCount", true),
            ("allowancePercentRemaining", true),
            ("activeCommitmentCount", true),
            ("daysUntilNextCommitment", true)
        ]
        for (key, inInsights) in mutations {
            publishValidGeneration()
            try replaceWithNegative(key, inInsights: inInsights)

            XCTAssertEqual(store.readPublishedSnapshot(now: now), stale, key)
            let scrubbed = try XCTUnwrap(defaults.data(
                forKey: BudgetWidgetSnapshotStore.payloadKey
            ))
            let scrubbedObject = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: scrubbed) as? [String: Any]
            )
            XCTAssertEqual(
                Set(scrubbedObject.keys),
                ["schemaVersion", "enabled", "budgetState"],
                key
            )
        }

        store.publish(
            .available(percentUsed: -1, validUntil: expiry),
            periodToken: "2026-05",
            insights: validInsights
        )
        XCTAssertEqual(store.readPublishedSnapshot(now: now), stale)

        store.publish(
            .available(percentUsed: 42, validUntil: expiry),
            periodToken: "2026-05",
            insights: MoneyUpWidgetInsights(
                reviewCount: -1,
                allowancePercentRemaining: 60,
                activeCommitmentCount: 2,
                daysUntilNextCommitment: 1,
                validUntil: expiry
            )
        )
        XCTAssertEqual(store.readPublishedSnapshot(now: now), stale)
    }

    func testNonPercentageBudgetStatesAreStableAndExpireAtTheirBoundaries() throws {
        let suiteName = "MoneyUpWidgetZeroBudget-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BudgetWidgetSnapshotStore(defaults: defaults)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let expiry = now.addingTimeInterval(3_600)

        store.publish(
            .zeroBudget(validUntil: expiry),
            periodToken: "2026-05"
        )

        XCTAssertEqual(
            store.read(now: now),
            .zeroBudget(validUntil: expiry)
        )
        let payload = try XCTUnwrap(defaults.data(
            forKey: BudgetWidgetSnapshotStore.payloadKey
        ))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )
        XCTAssertEqual(object["budgetState"] as? String, "zeroBudget")
        XCTAssertNil(object["percentUsed"])
        XCTAssertEqual(store.read(now: expiry), .stale)

        let negativeExpiry = expiry.addingTimeInterval(3_600)
        store.publish(
            .negativeBudget(validUntil: negativeExpiry),
            periodToken: "2026-05"
        )
        XCTAssertEqual(
            store.read(now: expiry),
            .negativeBudget(validUntil: negativeExpiry)
        )
        XCTAssertEqual(store.read(now: negativeExpiry), .stale)
    }

    func testPeriodTokenRequiresBoundedCanonicalYYYYMM() throws {
        let suiteName = "MoneyUpWidgetPeriodToken-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BudgetWidgetSnapshotStore(defaults: defaults)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let expiry = now.addingTimeInterval(3_600)
        let invalidTokens = [
            "0000-01",
            "10000-01",
            "2026-5",
            "2026-13",
            String(repeating: "2", count: 64) + "-05"
        ]

        for token in invalidTokens {
            store.publish(
                .available(percentUsed: 42, validUntil: expiry),
                periodToken: token
            )
            XCTAssertEqual(store.read(now: now), .stale, token)
        }

        store.publish(
            .available(percentUsed: 42, validUntil: expiry),
            periodToken: "2026-05"
        )
        let payload = try XCTUnwrap(defaults.data(
            forKey: BudgetWidgetSnapshotStore.payloadKey
        ))
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )
        object["periodToken"] = String(repeating: "2", count: 64) + "-05"
        defaults.set(
            try JSONSerialization.data(withJSONObject: object),
            forKey: BudgetWidgetSnapshotStore.payloadKey
        )

        XCTAssertEqual(store.read(now: now), .stale)
    }

    func testExpiredInsightAndBudgetPayloadsAreScrubbed() throws {
        let suiteName = "MoneyUpWidgetExpiry-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BudgetWidgetSnapshotStore(defaults: defaults)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let insightFirstEnd = now.addingTimeInterval(10)
        let budgetLaterEnd = now.addingTimeInterval(20)
        store.publish(
            .available(percentUsed: 42, validUntil: budgetLaterEnd),
            periodToken: "2026-05",
            insights: MoneyUpWidgetInsights(
                reviewCount: 3,
                allowancePercentRemaining: 40,
                activeCommitmentCount: 2,
                daysUntilNextCommitment: 1,
                validUntil: insightFirstEnd
            )
        )

        XCTAssertEqual(
            store.readPublishedSnapshot(now: insightFirstEnd),
            MoneyUpWidgetPublishedSnapshot(budget: .stale, insights: nil)
        )
        let insightFirstPayload = try XCTUnwrap(defaults.data(
            forKey: BudgetWidgetSnapshotStore.payloadKey
        ))
        let insightFirstObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: insightFirstPayload
            ) as? [String: Any]
        )
        XCTAssertEqual(
            Set(insightFirstObject.keys),
            ["schemaVersion", "enabled", "budgetState"]
        )

        let budgetFirstEnd = now.addingTimeInterval(30)
        let insightLaterEnd = now.addingTimeInterval(40)
        store.publish(
            .available(percentUsed: 17, validUntil: budgetFirstEnd),
            periodToken: "2026-05",
            insights: MoneyUpWidgetInsights(
                reviewCount: 1,
                allowancePercentRemaining: 75,
                activeCommitmentCount: 1,
                daysUntilNextCommitment: 2,
                validUntil: insightLaterEnd
            )
        )
        XCTAssertEqual(
            store.readPublishedSnapshot(now: budgetFirstEnd),
            MoneyUpWidgetPublishedSnapshot(budget: .stale, insights: nil)
        )
        let budgetFirstPayload = try XCTUnwrap(defaults.data(
            forKey: BudgetWidgetSnapshotStore.payloadKey
        ))
        let budgetFirstObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: budgetFirstPayload
            ) as? [String: Any]
        )
        XCTAssertEqual(
            Set(budgetFirstObject.keys),
            ["schemaVersion", "enabled", "budgetState"]
        )
    }

    func testVersionThreeMigratesStatusAndDropsUnzonedExactDueDate() throws {
        let suiteName = "MoneyUpWidgetV3Migration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let expiry = now.addingTimeInterval(3_600)
        defaults.set(3, forKey: "budgetStatus.schemaVersion")
        defaults.set(true, forKey: "budgetStatus.enabled")
        defaults.set("available", forKey: "budgetStatus.state")
        defaults.set(64, forKey: "budgetStatus.percentUsed")
        defaults.set("2026-05", forKey: "budgetStatus.periodToken")
        defaults.set(expiry, forKey: "budgetStatus.validUntil")
        defaults.set(7, forKey: "budgetStatus.insight.reviewCount")
        defaults.set(2, forKey: "budgetStatus.insight.commitmentCount")
        defaults.set(
            now.addingTimeInterval(600),
            forKey: "budgetStatus.insight.nextCommitment"
        )
        defaults.set(expiry, forKey: "budgetStatus.insight.validUntil")

        let store = BudgetWidgetSnapshotStore(defaults: defaults)

        XCTAssertEqual(
            store.read(now: now),
            .available(percentUsed: 64, validUntil: expiry)
        )
        let insights = try XCTUnwrap(store.readInsights(now: now))
        XCTAssertEqual(insights.reviewCount, 7)
        XCTAssertEqual(insights.activeCommitmentCount, 2)
        XCTAssertNil(insights.daysUntilNextCommitment)
        let persistedDomain = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertEqual(
            Set(persistedDomain.keys),
            BudgetWidgetSnapshotStore.allowedPersistedKeys
        )

        let ambiguousSuite = "MoneyUpWidgetV3NeedsBudget-\(UUID().uuidString)"
        let ambiguousDefaults = try XCTUnwrap(UserDefaults(suiteName: ambiguousSuite))
        defer { ambiguousDefaults.removePersistentDomain(forName: ambiguousSuite) }
        ambiguousDefaults.set(3, forKey: "budgetStatus.schemaVersion")
        ambiguousDefaults.set(true, forKey: "budgetStatus.enabled")
        ambiguousDefaults.set("needsBudget", forKey: "budgetStatus.state")
        ambiguousDefaults.set("2026-05", forKey: "budgetStatus.periodToken")
        ambiguousDefaults.set(expiry, forKey: "budgetStatus.validUntil")

        let ambiguousStore = BudgetWidgetSnapshotStore(defaults: ambiguousDefaults)
        XCTAssertEqual(ambiguousStore.read(now: now), .stale)
    }

    func testVersionThreeNegativeValuesMigrateToStale() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let expiry = now.addingTimeInterval(3_600)
        let mutations = [
            "budgetStatus.percentUsed",
            "budgetStatus.insight.reviewCount",
            "budgetStatus.insight.allowancePercent",
            "budgetStatus.insight.commitmentCount"
        ]

        for key in mutations {
            let suiteName = "MoneyUpWidgetNegativeV3-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(3, forKey: "budgetStatus.schemaVersion")
            defaults.set(true, forKey: "budgetStatus.enabled")
            defaults.set("available", forKey: "budgetStatus.state")
            defaults.set(42, forKey: "budgetStatus.percentUsed")
            defaults.set("2026-05", forKey: "budgetStatus.periodToken")
            defaults.set(expiry, forKey: "budgetStatus.validUntil")
            defaults.set(3, forKey: "budgetStatus.insight.reviewCount")
            defaults.set(60, forKey: "budgetStatus.insight.allowancePercent")
            defaults.set(2, forKey: "budgetStatus.insight.commitmentCount")
            defaults.set(expiry, forKey: "budgetStatus.insight.validUntil")
            defaults.set(-1, forKey: key)

            let store = BudgetWidgetSnapshotStore(defaults: defaults)

            XCTAssertEqual(store.read(now: now), .stale, key)
            XCTAssertNil(store.readInsights(now: now), key)
        }
    }

    func testReadOnlyWidgetStoreNeverWritesAnOlderSanitizedGenerationBack() throws {
        let suiteName = "MoneyUpWidgetReadOnly-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let writer = BudgetWidgetSnapshotStore(defaults: defaults)
        let expiry = Date(timeIntervalSinceReferenceDate: 800_000_000)
        writer.publish(
            .available(percentUsed: 42, validUntil: expiry),
            periodToken: "2026-05"
        )
        let published = try XCTUnwrap(defaults.data(
            forKey: BudgetWidgetSnapshotStore.payloadKey
        ))
        let reader = BudgetWidgetSnapshotStore(
            defaults: defaults,
            allowsMaintenanceWrites: false
        )

        XCTAssertEqual(reader.read(now: expiry), .stale)
        XCTAssertEqual(
            defaults.data(forKey: BudgetWidgetSnapshotStore.payloadKey),
            published
        )
    }

    func testReadOnlyWidgetTreatsAbsentPayloadAsDisabledWithoutWriting() throws {
        let suiteName = "MoneyUpWidgetAbsentReadOnly-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let reader = BudgetWidgetSnapshotStore(
            defaults: defaults,
            allowsMaintenanceWrites: false
        )

        XCTAssertEqual(reader.read(), .disabled)
        XCTAssertNil(defaults.data(forKey: BudgetWidgetSnapshotStore.payloadKey))
    }

    func testReadOnlyWidgetTreatsPresentCorruptOrFuturePayloadAsStale() throws {
        let payloads: [(String, Data)] = [
            ("corrupt", Data("not-json".utf8)),
            (
                "oversized",
                Data(
                    repeating: 0x41,
                    count: BudgetWidgetSnapshotStore.maximumPayloadByteCount + 1
                )
            ),
            (
                "future-schema",
                try JSONSerialization.data(withJSONObject: [
                    "schemaVersion": 5,
                    "enabled": true,
                    "budgetState": "available"
                ])
            ),
            (
                "disabled-with-fields",
                try JSONSerialization.data(withJSONObject: [
                    "schemaVersion": 4,
                    "enabled": false,
                    "budgetState": "disabled",
                    "percentUsed": 0
                ])
            ),
            (
                "enabled-disabled-state",
                try JSONSerialization.data(withJSONObject: [
                    "schemaVersion": 4,
                    "enabled": true,
                    "budgetState": "disabled"
                ])
            )
        ]

        for (label, payload) in payloads {
            let suiteName = "MoneyUpWidgetInvalidReadOnly-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(payload, forKey: BudgetWidgetSnapshotStore.payloadKey)
            let reader = BudgetWidgetSnapshotStore(
                defaults: defaults,
                allowsMaintenanceWrites: false
            )

            XCTAssertEqual(reader.read(), .stale, label)
            XCTAssertEqual(
                defaults.data(forKey: BudgetWidgetSnapshotStore.payloadKey),
                payload,
                label
            )
        }
    }

    func testWriterScrubsPresentCorruptOrFuturePayloadToStale() throws {
        let payloads: [(String, Data)] = [
            ("corrupt", Data("not-json".utf8)),
            (
                "oversized",
                Data(
                    repeating: 0x41,
                    count: BudgetWidgetSnapshotStore.maximumPayloadByteCount + 1
                )
            ),
            (
                "future-schema",
                try JSONSerialization.data(withJSONObject: [
                    "schemaVersion": 5,
                    "enabled": true,
                    "budgetState": "available"
                ])
            ),
            (
                "disabled-with-fields",
                try JSONSerialization.data(withJSONObject: [
                    "schemaVersion": 4,
                    "enabled": false,
                    "budgetState": "disabled",
                    "percentUsed": 0
                ])
            ),
            (
                "enabled-disabled-state",
                try JSONSerialization.data(withJSONObject: [
                    "schemaVersion": 4,
                    "enabled": true,
                    "budgetState": "disabled"
                ])
            )
        ]

        for (label, payload) in payloads {
            let suiteName = "MoneyUpWidgetInvalidWriter-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(payload, forKey: BudgetWidgetSnapshotStore.payloadKey)
            let writer = BudgetWidgetSnapshotStore(defaults: defaults)

            XCTAssertEqual(writer.read(), .stale, label)
            let scrubbed = try XCTUnwrap(defaults.data(
                forKey: BudgetWidgetSnapshotStore.payloadKey
            ))
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: scrubbed) as? [String: Any]
            )
            XCTAssertEqual(
                Set(object.keys),
                ["schemaVersion", "enabled", "budgetState"],
                label
            )
            XCTAssertEqual(object["budgetState"] as? String, "stale", label)
        }
    }

    @MainActor
    func testSmartReviewZeroPublishesOnlyAfterCurrentRefreshCompletes() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let suiteName = "MoneyUpWidgetIntelligence-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let widgetStore = BudgetWidgetSnapshotStore(defaults: defaults)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let model = fixture.model(
            profile: UserProfile(
                baseCurrency: fixture.sgd,
                showsBudgetStatusWidget: true,
                intelligenceEnabled: true,
                reportingTimeZoneIdentifier: "Asia/Singapore"
            ),
            budgetWidgetSnapshotStore: widgetStore,
            currentDate: { now }
        )

        XCTAssertNil(widgetStore.readInsights(now: now)?.reviewCount)
        model.refreshIntelligence()
        XCTAssertNil(widgetStore.readInsights(now: now)?.reviewCount)
        await model.waitForCurrentIntelligenceRefresh()
        XCTAssertEqual(widgetStore.readInsights(now: now)?.reviewCount, 0)
        await fixture.store.close()
    }

    @MainActor
    func testCommitmentSummaryUsesOutflowsAndReportingCalendarDays() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let suiteName = "MoneyUpWidgetCommitments-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let widgetStore = BudgetWidgetSnapshotStore(defaults: defaults)
        let calendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: "Asia/Singapore"
        )
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 4,
            hour: 23,
            minute: 30
        )))
        let expenseDate = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 6,
            hour: 0,
            minute: 15
        )))
        let incomeDate = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 5,
            hour: 0,
            minute: 15
        )))
        let salary = LedgerAccount(name: "Salary", kind: .income)
        let expense = try ScheduledTransaction(
            kind: .expense,
            name: "Rent",
            amount: Money(500, currency: fixture.sgd),
            accountID: fixture.wallet.id,
            categoryAccountID: fixture.food.id,
            nextOccurrence: expenseDate,
            frequency: .monthly,
            recurrenceTimeZoneIdentifier: "Asia/Singapore"
        )
        let income = try ScheduledTransaction(
            kind: .income,
            name: "Salary",
            amount: Money(2_000, currency: fixture.sgd),
            accountID: fixture.wallet.id,
            categoryAccountID: salary.id,
            nextOccurrence: incomeDate,
            frequency: .monthly,
            recurrenceTimeZoneIdentifier: "Asia/Singapore"
        )

        _ = fixture.model(
            profile: UserProfile(
                baseCurrency: fixture.sgd,
                showsBudgetStatusWidget: true,
                reportingTimeZoneIdentifier: "Asia/Singapore"
            ),
            accounts: [fixture.wallet, fixture.food, salary],
            scheduledTransactions: [income, expense],
            budgetWidgetSnapshotStore: widgetStore,
            currentDate: { now }
        )

        let insights = try XCTUnwrap(widgetStore.readInsights(now: now))
        XCTAssertEqual(insights.activeCommitmentCount, 1)
        XCTAssertEqual(insights.daysUntilNextCommitment, 2)
        await fixture.store.close()
    }

    @MainActor
    func testUnavailableAllowanceSummaryWithholdsOnlyAllowanceWidgetComponent()
    async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let suiteName = "MoneyUpWidgetAllowanceFailure-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let widgetStore = BudgetWidgetSnapshotStore(defaults: defaults)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 4))
        )
        let now = day.addingTimeInterval(12 * 3_600)
        let huge = try XCTUnwrap(
            Decimal(string: "9e127", locale: Locale(identifier: "en_US_POSIX"))
        )
        let valid = try AllowancePlan(
            name: "Current meals",
            amount: Money(10, currency: fixture.sgd),
            cadence: .daily,
            startsAt: day,
            timeZoneIdentifier: "UTC"
        )
        let previousDay = try XCTUnwrap(
            calendar.date(byAdding: .day, value: -1, to: day)
        )
        let unavailable = try AllowancePlan(
            name: "Overflowing carry",
            amount: Money(huge, currency: fixture.sgd),
            cadence: .daily,
            startsAt: previousDay,
            timeZoneIdentifier: "UTC",
            rolloverRule: .full
        )
        let commitment = try ScheduledTransaction(
            kind: .expense,
            name: "Rent",
            amount: Money(500, currency: fixture.sgd),
            accountID: fixture.wallet.id,
            categoryAccountID: fixture.food.id,
            nextOccurrence: now.addingTimeInterval(86_400),
            frequency: .monthly,
            recurrenceTimeZoneIdentifier: "UTC"
        )
        let model = fixture.model(
            profile: UserProfile(
                baseCurrency: fixture.sgd,
                showsBudgetStatusWidget: true,
                reportingTimeZoneIdentifier: "UTC"
            ),
            scheduledTransactions: [commitment],
            allowancePlans: [valid, unavailable],
            budgetWidgetSnapshotStore: widgetStore,
            currentDate: { now }
        )

        guard case .available = model.allowanceSummary(valid, asOf: now),
              case .unavailable(.amountCalculationFailed) = model.allowanceSummary(
                  unavailable,
                  asOf: now
              ) else {
            await fixture.store.close()
            return XCTFail("Expected one valid and one unavailable allowance summary")
        }
        let generation = widgetStore.readPublishedSnapshot(now: now)
        guard case .needsBudget = generation.budget else {
            await fixture.store.close()
            return XCTFail("Expected a current atomic widget generation")
        }
        let insights = try XCTUnwrap(generation.insights)
        XCTAssertNil(insights.allowancePercentRemaining)
        XCTAssertEqual(insights.activeCommitmentCount, 1)
        XCTAssertEqual(insights.daysUntilNextCommitment, 1)
        await fixture.store.close()
    }

    @MainActor
    func testReadySceneActivationRepublishesAndKeepsOneBoundaryWait()
    async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let suiteName = "MoneyUpWidgetActivation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let widgetStore = BudgetWidgetSnapshotStore(defaults: defaults)
        let calendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: "UTC"
        )
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 4,
            hour: 12
        )))
        let clock = WidgetLifecycleTestClock(now)
        let sleeper = WidgetReportingDaySleeperProbe()
        let model = fixture.model(
            profile: UserProfile(
                baseCurrency: fixture.sgd,
                showsBudgetStatusWidget: true,
                intelligenceEnabled: false,
                reportingTimeZoneIdentifier: "UTC"
            ),
            budgetWidgetSnapshotStore: widgetStore,
            currentDate: { clock.value() }
        )
        model.widgetLifecycleRefresh.sleep = { boundary in
            try await sleeper.sleep(until: boundary)
        }

        widgetStore.publish(.stale)
        model.sceneDidBecomeActive(at: now)

        let published = widgetStore.readPublishedSnapshot(now: now)
        guard case .needsBudget = published.budget else {
            await fixture.store.close()
            return XCTFail("Expected activation to replace the stale generation")
        }
        let expectedBoundary = try XCTUnwrap(
            calendar.dateInterval(of: .day, for: now)?.end
        )
        XCTAssertEqual(published.insights?.validUntil, expectedBoundary)
        await sleeper.waitForScheduleCount(1)
        let firstScheduledBoundaries = await sleeper.boundaries()
        XCTAssertEqual(firstScheduledBoundaries, [expectedBoundary])

        // Ordinary same-day publications and a duplicate active callback must
        // reuse the already-authoritative wait rather than start parallel loops.
        model.refreshBudgetWidgetSnapshot()
        model.sceneDidBecomeActive(at: now.addingTimeInterval(1))
        await Task.yield()
        let reusedScheduledBoundaries = await sleeper.boundaries()
        XCTAssertEqual(reusedScheduledBoundaries.count, 1)
        XCTAssertNotNil(model.widgetLifecycleRefresh.task)

        model.sceneDidBecomeInactive(at: now.addingTimeInterval(2))
        XCTAssertNil(model.widgetLifecycleRefresh.task)
        XCTAssertNil(model.widgetLifecycleRefresh.schedule)
        await fixture.store.close()
    }

    @MainActor
    func testReportingDayBoundaryRepublishesCurrentAtomicGenerationAndRearms()
    async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let suiteName = "MoneyUpWidgetDayBoundary-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let widgetStore = BudgetWidgetSnapshotStore(defaults: defaults)
        let calendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: "UTC"
        )
        let firstNow = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 4,
            hour: 23,
            minute: 30
        )))
        let commitmentDate = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 6,
            hour: 0,
            minute: 15
        )))
        let commitment = try ScheduledTransaction(
            kind: .expense,
            name: "Rent",
            amount: Money(500, currency: fixture.sgd),
            accountID: fixture.wallet.id,
            categoryAccountID: fixture.food.id,
            nextOccurrence: commitmentDate,
            frequency: .monthly,
            recurrenceTimeZoneIdentifier: "UTC"
        )
        let clock = WidgetLifecycleTestClock(firstNow)
        let sleeper = WidgetReportingDaySleeperProbe()
        let model = fixture.model(
            profile: UserProfile(
                baseCurrency: fixture.sgd,
                showsBudgetStatusWidget: true,
                reportingTimeZoneIdentifier: "UTC"
            ),
            scheduledTransactions: [commitment],
            budgetWidgetSnapshotStore: widgetStore,
            currentDate: { clock.value() }
        )
        model.widgetLifecycleRefresh.sleep = { boundary in
            try await sleeper.sleep(until: boundary)
        }
        model.sceneDidBecomeActive(at: firstNow)
        await sleeper.waitForScheduleCount(1)
        let firstTask = try XCTUnwrap(model.widgetLifecycleRefresh.task)
        XCTAssertEqual(
            widgetStore.readInsights(now: firstNow)?.daysUntilNextCommitment,
            2
        )

        let secondNow = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 5,
            minute: 1
        )))
        clock.set(secondNow)
        widgetStore.publish(.stale)
        await sleeper.fireNext()
        await firstTask.value
        await model.waitForCurrentIntelligenceRefresh()
        await sleeper.waitForScheduleCount(2)

        let published = widgetStore.readPublishedSnapshot(now: secondNow)
        guard case .needsBudget = published.budget else {
            model.sceneDidBecomeInactive(at: secondNow)
            await fixture.store.close()
            return XCTFail("Expected the new reporting day to be republished")
        }
        XCTAssertEqual(published.insights?.activeCommitmentCount, 1)
        XCTAssertEqual(published.insights?.daysUntilNextCommitment, 1)
        XCTAssertEqual(published.insights?.reviewCount, 0)
        let secondBoundary = try XCTUnwrap(
            calendar.dateInterval(of: .day, for: secondNow)?.end
        )
        XCTAssertEqual(published.insights?.validUntil, secondBoundary)
        let scheduledBoundaries = await sleeper.boundaries()
        XCTAssertEqual(
            scheduledBoundaries,
            [
                try XCTUnwrap(
                    calendar.dateInterval(of: .day, for: firstNow)?.end
                ),
                secondBoundary
            ]
        )
        XCTAssertNotNil(model.widgetLifecycleRefresh.task)

        model.sceneDidBecomeInactive(at: secondNow)
        await fixture.store.close()
    }

    @MainActor
    func testLifecycleWidgetRefreshHonorsReplacementAndDeferredLockBoundaries()
    async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let suiteName = "MoneyUpWidgetLifecycleGuards-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let widgetStore = BudgetWidgetSnapshotStore(defaults: defaults)
        let now = Date(timeIntervalSinceReferenceDate: 810_000_000)
        let clock = WidgetLifecycleTestClock(now)
        let sleeper = WidgetReportingDaySleeperProbe()
        let model = fixture.model(
            profile: UserProfile(
                baseCurrency: fixture.sgd,
                autoLockDelay: 60,
                showsBudgetStatusWidget: true,
                intelligenceEnabled: false,
                reportingTimeZoneIdentifier: "UTC"
            ),
            budgetWidgetSnapshotStore: widgetStore,
            currentDate: { clock.value() }
        )
        model.widgetLifecycleRefresh.sleep = { boundary in
            try await sleeper.sleep(until: boundary)
        }

        model.isBookReplacementInProgress = true
        widgetStore.publish(.stale)
        model.sceneDidBecomeActive(at: now)
        XCTAssertEqual(widgetStore.read(now: now), .stale)
        XCTAssertNil(model.widgetLifecycleRefresh.task)

        model.isBookReplacementInProgress = false
        let reactivatedAt = now.addingTimeInterval(2)
        model.sceneDidBecomeInactive(at: now.addingTimeInterval(1))
        clock.set(reactivatedAt)
        model.sceneDidBecomeActive(at: reactivatedAt)
        guard case .needsBudget = widgetStore.read(now: reactivatedAt) else {
            await fixture.store.close()
            return XCTFail("Expected refresh after replacement boundary released")
        }
        XCTAssertNotNil(model.widgetLifecycleRefresh.task)

        model.isLifecycleMutationInProgress = true
        let inactiveAt = now.addingTimeInterval(3)
        let expiredAt = inactiveAt.addingTimeInterval(60)
        clock.set(inactiveAt)
        model.sceneDidBecomeInactive(at: inactiveAt)
        widgetStore.publish(.stale)
        clock.set(expiredAt)
        model.sceneDidBecomeActive(at: expiredAt)
        XCTAssertTrue(model.requiresAuthenticationPrivacyCover)
        XCTAssertTrue(model.hasDeferredAuthenticationLock)
        XCTAssertEqual(widgetStore.read(now: expiredAt), .stale)
        XCTAssertNil(model.widgetLifecycleRefresh.task)

        model.isLifecycleMutationInProgress = false
        model.applyDeferredLockIfPossible()
        await model.waitForPendingStoreClose()
        XCTAssertEqual(model.state, .locked)
        XCTAssertNil(model.widgetLifecycleRefresh.task)
        await fixture.store.close()
    }

    @MainActor
    func testOnboardingReadyTransitionRunsPostReadyWidgetPublicationPath()
    async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let suiteName = "MoneyUpWidgetOnboarding-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let widgetStore = BudgetWidgetSnapshotStore(defaults: defaults)
        let now = Date(timeIntervalSinceReferenceDate: 810_100_000)
        let model = AppModel(
            store: fixture.store,
            profile: nil,
            accounts: [],
            budgetWidgetSnapshotStore: widgetStore,
            currentDate: { now }
        )
        XCTAssertEqual(model.state, .onboarding)
        XCTAssertEqual(model.intelligenceService.refreshInvocationCount, 0)
        model.sceneDidBecomeActive(at: now)
        widgetStore.publish(.stale)

        try await model.completeOnboarding(
            baseCurrencyCode: fixture.sgd.value,
            accountName: "First wallet",
            accountType: .cash,
            startingBalance: .zero
        )

        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.intelligenceService.refreshInvocationCount, 1)
        await model.waitForCurrentIntelligenceRefresh()
        // First-run widget sharing remains explicitly opt-in even though the
        // post-ready publication path now runs.
        XCTAssertEqual(widgetStore.read(now: now), .disabled)
        XCTAssertNil(model.widgetLifecycleRefresh.task)
        await fixture.store.close()
    }
}

private final class WidgetLifecycleTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    func value() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func set(_ date: Date) {
        lock.lock()
        self.date = date
        lock.unlock()
    }
}

private actor WidgetReportingDaySleeperProbe {
    private struct Waiter {
        let continuation: CheckedContinuation<Void, Error>
    }

    private var scheduledBoundaries: [Date] = []
    private var waiters: [UUID: Waiter] = [:]
    private var permits = 0
    private var scheduleObservers: [(
        target: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []

    func sleep(until boundary: Date) async throws {
        let id = UUID()
        scheduledBoundaries.append(boundary)
        resumeSatisfiedScheduleObservers()
        if permits > 0 {
            permits -= 1
            return
        }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = Waiter(continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func fireNext() {
        guard let id = waiters.keys.first,
              let waiter = waiters.removeValue(forKey: id) else {
            permits += 1
            return
        }
        waiter.continuation.resume()
    }

    func waitForScheduleCount(_ target: Int) async {
        guard scheduledBoundaries.count < target else { return }
        await withCheckedContinuation { continuation in
            scheduleObservers.append((target, continuation))
        }
    }

    func boundaries() -> [Date] {
        scheduledBoundaries
    }

    private func cancelWaiter(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func resumeSatisfiedScheduleObservers() {
        var pending: [(
            target: Int,
            continuation: CheckedContinuation<Void, Never>
        )] = []
        for observer in scheduleObservers {
            if scheduledBoundaries.count >= observer.target {
                observer.continuation.resume()
            } else {
                pending.append(observer)
            }
        }
        scheduleObservers = pending
    }
}
