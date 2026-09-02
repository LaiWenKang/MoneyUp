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

    func testLegacyProfileDefaultsFoundationModelAssistanceOff() throws {
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

        let decoded = try JSONDecoder().decode(
            UserProfile.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertFalse(decoded.foundationModelAssistanceEnabled)
    }

    func testFoundationModelAssistanceRoundTripsOnlyAfterExplicitOptIn() throws {
        let currency = try CurrencyCode("SGD")
        XCTAssertFalse(
            UserProfile(baseCurrency: currency)
                .foundationModelAssistanceEnabled
        )

        let optedIn = UserProfile(
            baseCurrency: currency,
            foundationModelAssistanceEnabled: true
        )
        let decoded = try JSONDecoder().decode(
            UserProfile.self,
            from: JSONEncoder().encode(optedIn)
        )

        XCTAssertTrue(decoded.foundationModelAssistanceEnabled)
    }
}
