import Foundation
@testable import MoneyUpCore
import XCTest

final class SavingsGoalTests: XCTestCase {
    private let calendar = FinancialPeriodBoundary.gregorianCalendar(
        timeZoneIdentifier: "Asia/Singapore"
    )

    func testContributionWithdrawalAndProgressRemainExactDecimals() throws {
        let sgd = try CurrencyCode("SGD")
        var goal = try SavingsGoal(
            name: "Emergency fund",
            kind: .savingsGoal,
            target: try Money(1_000, currency: sgd),
            targetDate: date(2027, 1, 1),
            createdAt: date(2026, 1, 1)
        )
        goal = try goal.adding(try movement(
            .contribution,
            "100.10",
            sgd,
            date(2026, 1, 2)
        ), calendar: calendar)
        goal = try goal.adding(try movement(
            .contribution,
            "0.20",
            sgd,
            date(2026, 1, 3)
        ), calendar: calendar)
        goal = try goal.adding(try movement(
            .withdrawal,
            "0.10",
            sgd,
            date(2026, 1, 4)
        ), calendar: calendar)

        let summary = try goal.summary(
            asOf: date(2026, 1, 5),
            calendar: calendar
        )

        XCTAssertEqual(summary.contributed.amount, Decimal(string: "100.30"))
        XCTAssertEqual(summary.withdrawn.amount, Decimal(string: "0.10"))
        XCTAssertEqual(summary.balance.amount, Decimal(string: "100.20"))
        XCTAssertEqual(summary.remaining.amount, Decimal(string: "899.80"))
        XCTAssertEqual(summary.progress, Decimal(string: "0.1002"))
    }

    func testRepeatingOneThirdProgressProducesFiniteDecimal() throws {
        let sgd = try CurrencyCode("SGD")
        let goal = try SavingsGoal(
            name: "Third",
            kind: .savingsGoal,
            target: try Money(3, currency: sgd),
            targetDate: date(2027, 1, 1),
            createdAt: date(2026, 1, 1),
            movements: [try movement(
                .contribution,
                "1",
                sgd,
                date(2026, 1, 2)
            )]
        )

        let progress = try goal.summary(
            asOf: date(2026, 1, 3),
            calendar: calendar
        ).progress
        XCTAssertGreaterThan(progress, Decimal(string: "0.333333333333")!)
        XCTAssertLessThan(progress, Decimal(string: "0.333333333334")!)
    }

    func testTargetDateCannotPrecedeCreation() throws {
        let sgd = try CurrencyCode("SGD")

        XCTAssertThrowsError(try SavingsGoal(
            name: "Impossible",
            kind: .savingsGoal,
            target: try Money(100, currency: sgd),
            targetDate: date(2026, 1, 1),
            createdAt: date(2026, 1, 2)
        )) {
            XCTAssertEqual($0 as? SavingsGoalError, .targetBeforeCreation)
        }
    }

    func testGoalRejectsNonFiniteDatesAtCreationMovementResetAndSummary() throws {
        let sgd = try CurrencyCode("SGD")
        let invalid = Date(timeIntervalSinceReferenceDate: .infinity)
        XCTAssertThrowsError(
            try SavingsGoal(
                name: "Invalid",
                kind: .savingsGoal,
                target: try Money(100, currency: sgd),
                targetDate: invalid,
                createdAt: date(2026, 1, 1)
            )
        ) { error in
            XCTAssertEqual(error as? SavingsGoalError, .invalidDate)
        }
        XCTAssertThrowsError(
            try SavingsGoalMovement(
                kind: .contribution,
                money: try Money(1, currency: sgd),
                occurredAt: invalid
            )
        ) { error in
            XCTAssertEqual(error as? SavingsGoalError, .invalidDate)
        }
        XCTAssertThrowsError(
            try SavingsGoalReset(occurredAt: invalid)
        ) { error in
            XCTAssertEqual(error as? SavingsGoalError, .invalidDate)
        }

        let goal = try SavingsGoal(
            name: "Valid",
            kind: .savingsGoal,
            target: try Money(100, currency: sgd),
            targetDate: date(2027, 1, 1),
            createdAt: date(2026, 1, 1)
        )
        XCTAssertThrowsError(try goal.summary(asOf: invalid)) { error in
            XCTAssertEqual(error as? SavingsGoalError, .invalidDate)
        }
    }

    func testPastDueUsesTheRequestedAsOfInstantNotWallClockTime() throws {
        let sgd = try CurrencyCode("SGD")
        let goal = try SavingsGoal(
            name: "Laptop",
            kind: .savingsGoal,
            target: try Money(1_000, currency: sgd),
            targetDate: date(2026, 6, 15),
            createdAt: date(2026, 1, 1)
        )

        XCTAssertFalse(try goal.summary(
            asOf: date(2026, 6, 14),
            calendar: calendar
        ).isPastDue)
        XCTAssertTrue(try goal.summary(
            asOf: date(2026, 6, 16),
            calendar: calendar
        ).isPastDue)
    }

    func testMovementCurrencyMustMatchGoalCurrency() throws {
        let sgd = try CurrencyCode("SGD")
        let usd = try CurrencyCode("USD")
        let goal = try SavingsGoal(
            name: "Trip",
            kind: .sinkingFund,
            target: try Money(500, currency: sgd),
            targetDate: date(2027, 1, 1),
            createdAt: date(2026, 1, 1)
        )
        let movement = try SavingsGoalMovement(
            kind: .contribution,
            money: try Money(10, currency: usd),
            occurredAt: date(2026, 1, 2)
        )

        XCTAssertThrowsError(try goal.adding(movement, calendar: calendar)) {
            XCTAssertEqual(
                $0 as? SavingsGoalError,
                .currencyMismatch(expected: sgd, actual: usd)
            )
        }
    }

    func testWithdrawalCannotExceedCurrentResetPeriodBalance() throws {
        let sgd = try CurrencyCode("SGD")
        var goal = try SavingsGoal(
            name: "Repairs",
            kind: .sinkingFund,
            target: try Money(500, currency: sgd),
            targetDate: date(2027, 1, 1),
            createdAt: date(2026, 1, 1)
        )
        goal = try goal.adding(try movement(
            .contribution,
            "20",
            sgd,
            date(2026, 1, 2)
        ), calendar: calendar)

        XCTAssertThrowsError(try goal.adding(try movement(
            .withdrawal,
            "20.01",
            sgd,
            date(2026, 1, 3)
        ), calendar: calendar)) {
            XCTAssertEqual($0 as? SavingsGoalError, .withdrawalExceedsBalance)
        }
    }

    func testMonthlyAndManualResetKeepHistoryButRestartDisplayedProgress() throws {
        let sgd = try CurrencyCode("SGD")
        var goal = try SavingsGoal(
            name: "Annual insurance",
            kind: .sinkingFund,
            target: try Money(1_200, currency: sgd),
            targetDate: date(2027, 1, 1),
            resetRule: .monthly,
            createdAt: date(2026, 1, 1)
        )
        goal = try goal.adding(try movement(
            .contribution,
            "100",
            sgd,
            date(2026, 1, 15)
        ), calendar: calendar)
        goal = try goal.adding(try movement(
            .contribution,
            "50",
            sgd,
            date(2026, 2, 2)
        ), calendar: calendar)

        XCTAssertEqual(
            try goal.summary(asOf: date(2026, 2, 3), calendar: calendar).balance.amount,
            50
        )

        goal = try goal.resetting(at: date(2026, 2, 4))
        let resetSummary = try goal.summary(
            asOf: date(2026, 2, 5),
            calendar: calendar
        )
        XCTAssertEqual(resetSummary.balance.amount, 0)
        XCTAssertEqual(goal.movements.count, 2)
        XCTAssertEqual(goal.resets.count, 1)
    }

    func testInitializerRejectsWithdrawalThatUsesBalanceBeforeManualReset() throws {
        let sgd = try CurrencyCode("SGD")
        let contribution = try movement(
            .contribution,
            "100",
            sgd,
            date(2026, 1, 2)
        )
        let withdrawal = try movement(
            .withdrawal,
            "1",
            sgd,
            date(2026, 1, 4)
        )

        XCTAssertThrowsError(try SavingsGoal(
            name: "Reset goal",
            kind: .savingsGoal,
            target: try Money(200, currency: sgd),
            targetDate: date(2027, 1, 1),
            createdAt: date(2026, 1, 1),
            movements: [contribution, withdrawal],
            resets: [try SavingsGoalReset(occurredAt: date(2026, 1, 3))],
            reportingTimeZoneIdentifier: "Asia/Singapore"
        )) {
            XCTAssertEqual($0 as? SavingsGoalError, .withdrawalExceedsBalance)
        }
    }

    func testInitializerRejectsWithdrawalUsingPriorAutomaticPeriodBalance() throws {
        let sgd = try CurrencyCode("SGD")

        XCTAssertThrowsError(try SavingsGoal(
            name: "Monthly allowance",
            kind: .sinkingFund,
            target: try Money(200, currency: sgd),
            targetDate: date(2027, 1, 1),
            resetRule: .monthly,
            createdAt: date(2026, 1, 1),
            movements: [
                try movement(.contribution, "100", sgd, date(2026, 1, 20)),
                try movement(.withdrawal, "1", sgd, date(2026, 2, 2))
            ],
            reportingTimeZoneIdentifier: "Asia/Singapore"
        )) {
            XCTAssertEqual($0 as? SavingsGoalError, .withdrawalExceedsBalance)
        }
    }

    func testLegacyGoalDefaultsResetHistoryAndArchiveSafely() throws {
        let sgd = try CurrencyCode("SGD")
        let goal = try SavingsGoal(
            name: "Legacy goal",
            kind: .savingsGoal,
            target: try Money(100, currency: sgd),
            targetDate: date(2027, 1, 1),
            createdAt: date(2026, 1, 1)
        )
        let encoded = try JSONEncoder().encode(goal)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "resetRule")
        object.removeValue(forKey: "movements")
        object.removeValue(forKey: "resets")
        object.removeValue(forKey: "isArchived")

        let decoded = try JSONDecoder().decode(
            SavingsGoal.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.resetRule, .never)
        XCTAssertTrue(decoded.movements.isEmpty)
        XCTAssertTrue(decoded.resets.isEmpty)
        XCTAssertFalse(decoded.isArchived)
        XCTAssertEqual(decoded.reportingTimeZoneIdentifier, goal.reportingTimeZoneIdentifier)
    }

    func testOriginDayKeepsUTCPlus14ContributionInAttributedAugust() throws {
        let sgd = try CurrencyCode("SGD")
        let utc = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: "GMT"
        )
        let instant = try XCTUnwrap(utc.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 31,
            hour: 10,
            minute: 30
        )))
        let movement = try SavingsGoalMovement(
            kind: .contribution,
            money: try Money(25, currency: sgd),
            occurredAt: instant,
            originTimeZoneIdentifier: "Pacific/Kiritimati"
        )
        XCTAssertEqual(movement.originDayKey, "2026-08-01")
        XCTAssertEqual(movement.originUTCOffsetSeconds, 14 * 60 * 60)
        let goal = try SavingsGoal(
            name: "Travel",
            kind: .sinkingFund,
            target: try Money(100, currency: sgd),
            targetDate: date(2027, 1, 1),
            resetRule: .monthly,
            createdAt: date(2026, 1, 1),
            movements: [movement],
            reportingTimeZoneIdentifier: "Asia/Singapore"
        )

        XCTAssertEqual(
            try goal.summary(
                asOf: date(2026, 8, 2),
                calendar: calendar
            ).balance.amount,
            25
        )
    }

    func testOriginDayKeepsUTCMinus12ContributionOutOfAttributedAugust() throws {
        let sgd = try CurrencyCode("SGD")
        let utc = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: "GMT"
        )
        let instant = try XCTUnwrap(utc.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 1,
            hour: 1
        )))
        let movement = try SavingsGoalMovement(
            kind: .contribution,
            money: try Money(25, currency: sgd),
            occurredAt: instant,
            originTimeZoneIdentifier: "Etc/GMT+12"
        )
        XCTAssertEqual(movement.originDayKey, "2026-07-31")
        XCTAssertEqual(movement.originUTCOffsetSeconds, -12 * 60 * 60)
        let goal = try SavingsGoal(
            name: "Travel",
            kind: .sinkingFund,
            target: try Money(100, currency: sgd),
            targetDate: date(2027, 1, 1),
            resetRule: .monthly,
            createdAt: date(2026, 1, 1),
            movements: [movement],
            reportingTimeZoneIdentifier: "Asia/Singapore"
        )

        XCTAssertEqual(
            try goal.summary(
                asOf: date(2026, 8, 2),
                calendar: calendar
            ).balance.amount,
            0
        )
    }

    func testDuplicateMovementAndResetIDsAreRejected() throws {
        let sgd = try CurrencyCode("SGD")
        let duplicateID = UUID()
        let first = try SavingsGoalMovement(
            id: duplicateID,
            kind: .contribution,
            money: try Money(10, currency: sgd),
            occurredAt: date(2026, 1, 2)
        )
        let second = try SavingsGoalMovement(
            id: duplicateID,
            kind: .contribution,
            money: try Money(20, currency: sgd),
            occurredAt: date(2026, 1, 3)
        )
        XCTAssertThrowsError(try SavingsGoal(
            name: "Duplicate movement",
            kind: .savingsGoal,
            target: try Money(100, currency: sgd),
            targetDate: date(2027, 1, 1),
            createdAt: date(2026, 1, 1),
            movements: [first, second]
        )) {
            XCTAssertEqual($0 as? SavingsGoalError, .duplicateMovementID)
        }

        let resetID = UUID()
        XCTAssertThrowsError(try SavingsGoal(
            name: "Duplicate reset",
            kind: .savingsGoal,
            target: try Money(100, currency: sgd),
            targetDate: date(2027, 1, 1),
            createdAt: date(2026, 1, 1),
            resets: [
                try SavingsGoalReset(id: resetID, occurredAt: date(2026, 1, 2)),
                try SavingsGoalReset(id: resetID, occurredAt: date(2026, 1, 3))
            ]
        )) {
            XCTAssertEqual($0 as? SavingsGoalError, .duplicateResetID)
        }
    }

    func testSummaryRejectsDecimalOverflowInsteadOfReturningBadBalance() throws {
        let sgd = try CurrencyCode("SGD")
        let huge = Decimal(sign: .plus, exponent: 127, significand: 9)
        let goal = try SavingsGoal(
            name: "Overflow",
            kind: .savingsGoal,
            target: try Money(huge, currency: sgd),
            targetDate: date(2027, 1, 1),
            createdAt: date(2026, 1, 1),
            movements: [
                try SavingsGoalMovement(
                    kind: .contribution,
                    money: try Money(huge, currency: sgd),
                    occurredAt: date(2026, 1, 2)
                ),
                try SavingsGoalMovement(
                    kind: .contribution,
                    money: try Money(huge, currency: sgd),
                    occurredAt: date(2026, 1, 3)
                )
            ]
        )

        XCTAssertThrowsError(try goal.summary(
            asOf: date(2026, 1, 4),
            calendar: calendar
        )) {
            XCTAssertEqual($0 as? SavingsGoalError, .calculationFailed)
        }
    }

    func testMovementDecodeRejectsInvalidZoneDayMismatchAndPrecision() throws {
        let sgd = try CurrencyCode("SGD")
        let movement = try SavingsGoalMovement(
            kind: .contribution,
            money: try Money(1, currency: sgd),
            occurredAt: date(2026, 2, 1),
            originTimeZoneIdentifier: "Asia/Singapore"
        )
        let encoded = try JSONEncoder().encode(movement)
        let original = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        for (key, value) in [
            ("originDayKey", "2026-02-31"),
            ("originDayKey", "2026-01-31"),
            ("originTimeZoneIdentifier", "Not/AZone")
        ] {
            var object = original
            object[key] = value
            XCTAssertThrowsError(try JSONDecoder().decode(
                SavingsGoalMovement.self,
                from: try JSONSerialization.data(withJSONObject: object)
            ))
        }

        var excessive = original
        var money = try XCTUnwrap(excessive["money"] as? [String: Any])
        money["amount"] = 1.001
        excessive["money"] = money
        XCTAssertThrowsError(try JSONDecoder().decode(
            SavingsGoalMovement.self,
            from: try JSONSerialization.data(withJSONObject: excessive)
        ))
    }

    func testGoalDecodeRejectsInvalidZoneExcessPrecisionAndDuplicateIDs() throws {
        let sgd = try CurrencyCode("SGD")
        let movement = try SavingsGoalMovement(
            kind: .contribution,
            money: try Money(1, currency: sgd),
            occurredAt: date(2026, 1, 2),
            originTimeZoneIdentifier: "Asia/Singapore"
        )
        let goal = try SavingsGoal(
            name: "Decode",
            kind: .savingsGoal,
            target: try Money(100, currency: sgd),
            targetDate: date(2027, 1, 1),
            createdAt: date(2026, 1, 1),
            movements: [movement],
            reportingTimeZoneIdentifier: "Asia/Singapore"
        )
        let encoded = try JSONEncoder().encode(goal)
        let original = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        var invalidZone = original
        invalidZone["reportingTimeZoneIdentifier"] = "Not/AZone"
        XCTAssertThrowsError(try JSONDecoder().decode(
            SavingsGoal.self,
            from: try JSONSerialization.data(withJSONObject: invalidZone)
        ))

        var excessiveTarget = original
        var target = try XCTUnwrap(excessiveTarget["target"] as? [String: Any])
        target["amount"] = 100.001
        excessiveTarget["target"] = target
        XCTAssertThrowsError(try JSONDecoder().decode(
            SavingsGoal.self,
            from: try JSONSerialization.data(withJSONObject: excessiveTarget)
        ))

        var duplicate = original
        let movements = try XCTUnwrap(duplicate["movements"] as? [[String: Any]])
        duplicate["movements"] = movements + movements
        XCTAssertThrowsError(try JSONDecoder().decode(
            SavingsGoal.self,
            from: try JSONSerialization.data(withJSONObject: duplicate)
        ))
    }

    private func movement(
        _ kind: SavingsGoalMovementKind,
        _ amount: String,
        _ currency: CurrencyCode,
        _ occurredAt: Date
    ) throws -> SavingsGoalMovement {
        try SavingsGoalMovement(
            kind: kind,
            money: try Money(Decimal(string: amount)!, currency: currency),
            occurredAt: occurredAt,
            originTimeZoneIdentifier: "Asia/Singapore"
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: 12
        ))!
    }
}
