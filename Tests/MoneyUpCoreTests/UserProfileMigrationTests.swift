import Foundation
@testable import MoneyUpCore
import XCTest

final class UserProfileMigrationTests: XCTestCase {
    func testLegacyProfileKeepsBudgetWidgetOptedOutAndGetsValidReportingZone() throws {
        let sgd = try CurrencyCode("SGD")
        let profile = UserProfile(
            baseCurrency: sgd,
            showsBudgetStatusWidget: true,
            reportingTimeZoneIdentifier: "Asia/Singapore"
        )
        let encoded = try JSONEncoder().encode(profile)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "showsBudgetStatusWidget")
        object.removeValue(forKey: "reportingTimeZoneIdentifier")

        let decoded = try JSONDecoder().decode(
            UserProfile.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertFalse(decoded.showsBudgetStatusWidget)
        XCTAssertEqual(decoded.reportingTimeZoneIdentifier, "GMT")
        XCTAssertEqual(
            FinancialPeriodBoundary.gregorianCalendar(
                timeZoneIdentifier: decoded.reportingTimeZoneIdentifier
            ).identifier,
            .gregorian
        )
    }

    func testPresentInvalidReportingZoneAndAutoLockAreRejected() throws {
        let sgd = try CurrencyCode("SGD")
        let profile = UserProfile(
            baseCurrency: sgd,
            autoLockDelay: 60,
            reportingTimeZoneIdentifier: "Asia/Singapore"
        )
        let encoded = try JSONEncoder().encode(profile)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["reportingTimeZoneIdentifier"] = "Not/AZone"
        XCTAssertThrowsError(try JSONDecoder().decode(
            UserProfile.self,
            from: try JSONSerialization.data(withJSONObject: object)
        ))

        object["reportingTimeZoneIdentifier"] = "Asia/Singapore"
        for invalid in [-1, 30, 3_599] {
            object["autoLockDelay"] = invalid
            XCTAssertThrowsError(try JSONDecoder().decode(
                UserProfile.self,
                from: try JSONSerialization.data(withJSONObject: object)
            ))
        }
    }

    func testLegacyProfileDefaultsAssistanceOnAndRetiresSwipeNavigation() throws {
        let profile = UserProfile(
            baseCurrency: try CurrencyCode("SGD"),
            foundationModelAssistanceEnabled: true
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(profile)
            ) as? [String: Any]
        )
        object.removeValue(forKey: "foundationModelAssistanceEnabled")
        object["enablesTabSwipeNavigation"] = true

        let decoded = try JSONDecoder().decode(
            UserProfile.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertTrue(decoded.foundationModelAssistanceEnabled)
        XCTAssertFalse(decoded.enablesTabSwipeNavigation)
        let rewritten = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(decoded)
            ) as? [String: Any]
        )
        XCTAssertNil(rewritten["enablesTabSwipeNavigation"])
        XCTAssertFalse(UserProfile(
            baseCurrency: try CurrencyCode("SGD"),
            enablesTabSwipeNavigation: true
        ).enablesTabSwipeNavigation)
    }

    func testFoundationModelAssistanceDefaultsOnAndExplicitOptOutRoundTrips() throws {
        let currency = try CurrencyCode("SGD")
        XCTAssertTrue(
            UserProfile(baseCurrency: currency)
                .foundationModelAssistanceEnabled
        )

        let optedOut = UserProfile(
            baseCurrency: currency,
            foundationModelAssistanceEnabled: false
        )
        let decoded = try JSONDecoder().decode(
            UserProfile.self,
            from: JSONEncoder().encode(optedOut)
        )

        XCTAssertFalse(decoded.foundationModelAssistanceEnabled)
    }

    func testLegacyProfileDefaultsAutomaticCurrencyDisplayAndNoPinnedCategories() throws {
        let profile = UserProfile(
            baseCurrency: try CurrencyCode("SGD"),
            currencyDisplay: .code,
            pinnedBudgetNodeIDs: [UUID()]
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(profile)
            ) as? [String: Any]
        )
        object.removeValue(forKey: "currencyDisplay")
        object.removeValue(forKey: "pinnedBudgetNodeIDs")

        let decoded = try JSONDecoder().decode(
            UserProfile.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.currencyDisplay, .automatic)
        XCTAssertTrue(decoded.pinnedBudgetNodeIDs.isEmpty)
    }

    func testCurrencyDisplayAndPinnedCategoriesRoundTrip() throws {
        let pins = [UUID(), UUID(), UUID()]
        let profile = UserProfile(
            baseCurrency: try CurrencyCode("SGD"),
            currencyDisplay: .code,
            pinnedBudgetNodeIDs: pins
        )

        let decoded = try JSONDecoder().decode(
            UserProfile.self,
            from: try JSONEncoder().encode(profile)
        )

        XCTAssertEqual(decoded.currencyDisplay, .code)
        XCTAssertEqual(decoded.pinnedBudgetNodeIDs, pins)
    }

    func testPinnedCategoriesKeepChosenOrderWhileDroppingRepeatsAndOverflow() throws {
        let unique = (0..<UserProfile.maximumPinnedBudgetNodes).map { _ in UUID() }
        let overflowing = [unique[0]] + unique + [UUID()]

        let normalized = UserProfile.normalizedPins(overflowing)

        XCTAssertEqual(normalized.count, UserProfile.maximumPinnedBudgetNodes)
        XCTAssertEqual(normalized.first, unique[0])
        XCTAssertEqual(Set(normalized).count, normalized.count)
        // The repeat is folded into its first position rather than pushing a
        // later choice out of the bounded list.
        XCTAssertEqual(
            normalized,
            Array(unique.prefix(UserProfile.maximumPinnedBudgetNodes))
        )
    }

    /// A stored list that predates the cap, or that a restored archive carries,
    /// is repaired on decode rather than trusted.
    func testDecodedPinnedCategoriesAreNormalizedNotTrusted() throws {
        let duplicate = UUID().uuidString
        let profile = UserProfile(baseCurrency: try CurrencyCode("SGD"))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(profile)
            ) as? [String: Any]
        )
        object["pinnedBudgetNodeIDs"] = [duplicate, duplicate]
            + (0...UserProfile.maximumPinnedBudgetNodes).map { _ in UUID().uuidString }

        let decoded = try JSONDecoder().decode(
            UserProfile.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(
            decoded.pinnedBudgetNodeIDs.count,
            UserProfile.maximumPinnedBudgetNodes
        )
        XCTAssertEqual(
            Set(decoded.pinnedBudgetNodeIDs).count,
            decoded.pinnedBudgetNodeIDs.count
        )
        XCTAssertEqual(decoded.pinnedBudgetNodeIDs.first?.uuidString, duplicate)
    }
}
