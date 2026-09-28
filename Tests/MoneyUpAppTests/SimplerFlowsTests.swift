import Foundation
@testable import MoneyUp
import XCTest

/// Plain-language presentation fixes from the 2026-09-28 UX audit.
final class SimplerFlowsTests: XCTestCase {
    /// Exchange-rate rows showed the stored key ("rate day 20260928"). A day
    /// key is a calendar day, so it renders as that date in any zone.
    func testDayKeysRenderAsReadableDates() {
        let english = ReportingDayKeyFormatting.string(forDayKey: 20260928, locale: Locale(identifier: "en"))
        XCTAssertTrue(english.contains("Sep") && english.contains("28") && english.contains("2026"), english)
        XCTAssertFalse(english.contains("20260928"))
        let chinese = ReportingDayKeyFormatting.string(forDayKey: 20260928, locale: Locale(identifier: "zh-Hans"))
        XCTAssertTrue(chinese.contains("2026") && chinese.contains("9") && chinese.contains("28"), chinese)
        // Year boundaries and leap days keep their own calendar day.
        XCTAssertTrue(ReportingDayKeyFormatting.string(forDayKey: 20240229, locale: Locale(identifier: "en")).contains("29"))
        XCTAssertTrue(ReportingDayKeyFormatting.string(forDayKey: 20261231, locale: Locale(identifier: "en")).contains("31"))
        // An impossible key is shown as stored rather than as a wrong date.
        XCTAssertEqual(ReportingDayKeyFormatting.string(forDayKey: 20260231, locale: Locale(identifier: "en")), "20260231")
    }
}
