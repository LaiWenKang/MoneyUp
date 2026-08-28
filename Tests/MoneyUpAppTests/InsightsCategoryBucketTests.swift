@testable import MoneyUp
import MoneyUpCore
import XCTest

final class InsightsCategoryBucketTests: XCTestCase {
    func testDuplicateNamesKeepDistinctSelectionIdentityAndExactOtherMembers() throws {
        let currency = try CurrencyCode("USD")
        let first = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let second = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let third = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
        let fourth = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000004"))
        let zero = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000005"))
        let refundOnly = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000006")
        )
        let spending = [
            CategorySpending(
                accountID: first,
                name: "Food",
                amount: try Money(90, currency: currency)
            ),
            CategorySpending(
                accountID: second,
                name: "Food",
                amount: try Money(80, currency: currency)
            ),
            CategorySpending(
                accountID: third,
                name: "Travel",
                amount: try Money(30, currency: currency)
            ),
            CategorySpending(
                accountID: fourth,
                name: "Bills",
                amount: try Money(20, currency: currency)
            ),
            CategorySpending(
                accountID: zero,
                name: "Zero",
                amount: try Money(0, currency: currency)
            ),
            CategorySpending(
                accountID: refundOnly,
                name: "Refund only",
                amount: try Money(-5, currency: currency)
            )
        ]

        let points = try InsightsCategoryBucketBuilder.points(
            from: spending,
            visibleCategoryCount: 2,
            baseCurrency: currency,
            otherName: "Other"
        )

        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[0].name, points[1].name)
        XCTAssertNotEqual(points[0].selectionKey, points[1].selectionKey)
        XCTAssertEqual(points[0].categoryIDs, [first])
        XCTAssertEqual(points[1].categoryIDs, [second])
        XCTAssertEqual(points[2].selectionKey, InsightsCategoryBucketBuilder.aggregateSelectionKey)
        XCTAssertEqual(points[2].categoryIDs, [third, fourth])
        XCTAssertEqual(points[2].money.amount, 50)
        XCTAssertTrue(points[2].isAggregate)
        XCTAssertEqual(
            points.reduce(into: Set<UUID>()) { $0.formUnion($1.categoryIDs) },
            [first, second, third, fourth]
        )
    }

    func testSelectionKeysAreDeterministicAcrossRebuilds() throws {
        let currency = try CurrencyCode("SGD")
        let categoryID = UUID()
        let spending = [
            CategorySpending(
                accountID: categoryID,
                name: "Same category",
                amount: try Money(1, currency: currency)
            )
        ]

        let first = try InsightsCategoryBucketBuilder.points(
            from: spending,
            visibleCategoryCount: 8,
            baseCurrency: currency,
            otherName: "Other"
        )
        let second = try InsightsCategoryBucketBuilder.points(
            from: spending,
            visibleCategoryCount: 8,
            baseCurrency: currency,
            otherName: "Other"
        )

        XCTAssertEqual(first.map(\.selectionKey), second.map(\.selectionKey))
        XCTAssertEqual(
            first.first?.selectionKey,
            InsightsCategoryBucketBuilder.selectionKey(for: categoryID)
        )
    }
}
