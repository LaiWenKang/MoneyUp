import Foundation
@testable import MoneyUpCore
import XCTest

final class QuickLogFavouriteTests: XCTestCase {
    func testTextIsTrimmedAndBounded() {
        let favourite = QuickLogFavourite(
            name: "  " + String(repeating: "L", count: 80) + " ",
            kind: .expense,
            payee: String(repeating: "p", count: 500),
            note: "  lunch  "
        )
        XCTAssertEqual(favourite.name.count, QuickLogFavourite.maximumNameLength)
        XCTAssertEqual(favourite.payee.count, QuickLogFavourite.maximumPayeeLength)
        XCTAssertEqual(favourite.note, "lunch")
    }

    func testOnlyPositiveFiniteAmountsAreKept() {
        XCTAssertNil(QuickLogFavourite(name: "A", kind: .expense, amount: 0).amount)
        XCTAssertNil(QuickLogFavourite(name: "A", kind: .expense, amount: -3).amount)
        XCTAssertNil(QuickLogFavourite(name: "A", kind: .expense, amount: .nan).amount)
        XCTAssertNil(QuickLogFavourite(
            name: "A", kind: .expense, amount: QuickLogFavourite.maximumAmount + 1
        ).amount)
        let coffee = QuickLogFavourite(name: "Coffee", kind: .expense, amount: Decimal(string: "3.20"))
        XCTAssertEqual(coffee.amount, Decimal(string: "3.2"))
        XCTAssertTrue(coffee.hasFixedAmount)
        XCTAssertFalse(QuickLogFavourite(name: "Lunch", kind: .expense).hasFixedAmount)
    }

    func testNormalizationKeepsOrderDropsBlanksAndRepeatsAndCaps() {
        let repeated = QuickLogFavourite(name: "Lunch", kind: .expense)
        var candidates = [repeated, QuickLogFavourite(name: "   ", kind: .expense), repeated]
        candidates += (0..<20).map { QuickLogFavourite(name: "F\($0)", kind: .income) }
        let normalized = QuickLogFavourite.normalized(candidates)
        XCTAssertEqual(normalized.count, QuickLogFavourite.maximumCount)
        XCTAssertEqual(normalized.first, repeated)
        XCTAssertEqual(normalized[1].name, "F0")
        XCTAssertEqual(Set(normalized.map(\.id)).count, normalized.count)
    }

    func testRemappingRepointsMergedAccountAndCategory() {
        let source = UUID(), target = UUID(), other = UUID()
        let favourites = [
            QuickLogFavourite(name: "A", kind: .expense, accountID: source, categoryID: other),
            QuickLogFavourite(name: "B", kind: .expense, accountID: other, categoryID: source)
        ]
        let remapped = QuickLogFavourite.remapping(favourites, from: source, to: target)
        XCTAssertEqual(remapped[0].accountID, target)
        XCTAssertEqual(remapped[0].categoryID, other)
        XCTAssertEqual(remapped[1].accountID, other)
        XCTAssertEqual(remapped[1].categoryID, target)
    }

    func testProfileRoundTripsFavouritesAndLegacyProfilesDecodeEmpty() throws {
        let sgd = try CurrencyCode("SGD")
        let coffee = QuickLogFavourite(
            name: "Coffee", kind: .expense, amount: Decimal(string: "3.2"),
            accountID: UUID(), categoryID: UUID(), payee: "Kopi", note: "Less sugar"
        )
        let lunch = QuickLogFavourite(name: "Lunch", kind: .expense)
        let profile = UserProfile(baseCurrency: sgd, quickLogFavourites: [coffee, lunch])
        let decoded = try JSONDecoder().decode(
            UserProfile.self, from: JSONEncoder().encode(profile)
        )
        XCTAssertEqual(decoded.quickLogFavourites, [coffee, lunch])

        // An empty list is not written, so existing profile payloads stay
        // byte-identical and older builds never meet an unknown key.
        let empty = try JSONEncoder().encode(UserProfile(baseCurrency: sgd))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: empty) as? [String: Any])
        XCTAssertNil(object["quickLogFavourites"])
        XCTAssertEqual(try JSONDecoder().decode(UserProfile.self, from: empty).quickLogFavourites, [])
        XCTAssertFalse(try JSONDecoder().decode(UserProfile.self, from: empty).showsFavouritesWhileLocked)
        XCTAssertNil(object["showsFavouritesWhileLocked"])
        let optedIn = UserProfile(baseCurrency: sgd, showsFavouritesWhileLocked: true)
        XCTAssertTrue(try JSONDecoder().decode(
            UserProfile.self, from: JSONEncoder().encode(optedIn)
        ).showsFavouritesWhileLocked)
    }

    func testDecodingRejectsNothingButRepairsOversizedOrDuplicateLists() throws {
        let sgd = try CurrencyCode("SGD")
        let one = QuickLogFavourite(name: "Lunch", kind: .expense)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(UserProfile(baseCurrency: sgd))
        ) as? [String: Any])
        let entry = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(one)))
        object["quickLogFavourites"] = [entry, entry]
        let decoded = try JSONDecoder().decode(
            UserProfile.self, from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(decoded.quickLogFavourites, [one])
    }
}
