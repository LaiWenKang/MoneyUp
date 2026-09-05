import Foundation
import MoneyUpCore

extension RestoreCandidateValidator.AllowancePlanWorkShape {
    private struct UsageDateShape: Decodable {
        let occurredAt: Date?
        enum CodingKeys: String, CodingKey { case occurredAt }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            occurredAt = try container.decodeIfPresent(Date.self, forKey: .occurredAt)
        }
    }

    private struct ReconciliationDateShape: Decodable {
        let periodEnd: Date?
        enum CodingKeys: String, CodingKey { case periodEnd }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            periodEnd = try container.decodeIfPresent(Date.self, forKey: .periodEnd)
        }
    }

    private struct PolicyPeriodShape: Decodable {
        let effectiveAt: Date?
        let cadence: AllowanceCadence?
        let timeZoneIdentifier: String?
    }

    static func periodWorkCount(
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Int {
        guard let lastActivity = try lastActivityDate(in: container) else {
            return 0
        }
        guard lastActivity.timeIntervalSinceReferenceDate.isFinite else {
            throw AppModelError.invalidBook
        }
        let policies = try policyPeriods(in: container)
        guard !policies.isEmpty else { throw AppModelError.invalidBook }
        var result = 0
        for index in policies.indices {
            let policy = policies[index]
            guard let effectiveAt = policy.effectiveAt,
                  let cadence = policy.cadence,
                  let zoneID = policy.timeZoneIdentifier else {
                throw AppModelError.invalidBook
            }
            guard effectiveAt <= lastActivity else { break }
            let nextStart = policies.indices.contains(index + 1)
                ? policies[index + 1].effectiveAt : nil
            let upperBound = min(nextStart ?? lastActivity, lastActivity)
            let count = try estimatedPeriodCount(
                from: effectiveAt,
                through: upperBound,
                cadence: cadence,
                timeZoneIdentifier: zoneID
            )
            let (next, overflow) = result.addingReportingOverflow(count)
            guard !overflow else { throw AppModelError.invalidBook }
            result = next
        }
        return result
    }

    private static func lastActivityDate(
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Date? {
        let usages = try container.decodeIfPresent(
            [UsageDateShape].self,
            forKey: .usages
        ) ?? []
        let reconciliations = try container.decodeIfPresent(
            [ReconciliationDateShape].self,
            forKey: .reconciliations
        ) ?? []
        return (usages.compactMap(\.occurredAt)
            + reconciliations.compactMap(\.periodEnd)).max()
    }

    private static func policyPeriods(
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [PolicyPeriodShape] {
        let supplied = try container.decodeIfPresent(
            [PolicyPeriodShape].self,
            forKey: .policyRevisions
        ) ?? []
        guard supplied.count <= AllowancePlan.maximumPolicyRevisionCount else {
            throw AppModelError.invalidBook
        }
        if !supplied.isEmpty {
            return supplied.sorted {
                ($0.effectiveAt ?? .distantFuture)
                    < ($1.effectiveAt ?? .distantFuture)
            }
        }
        return [PolicyPeriodShape(
            effectiveAt: try container.decodeIfPresent(
                Date.self,
                forKey: .startsAt
            ),
            cadence: try container.decodeIfPresent(
                AllowanceCadence.self,
                forKey: .cadence
            ),
            timeZoneIdentifier: try container.decodeIfPresent(
                String.self,
                forKey: .timeZoneIdentifier
            )
        )]
    }

    private static func estimatedPeriodCount(
        from start: Date,
        through end: Date,
        cadence: AllowanceCadence,
        timeZoneIdentifier: String
    ) throws -> Int {
        guard start.timeIntervalSinceReferenceDate.isFinite,
              end.timeIntervalSinceReferenceDate.isFinite,
              start <= end,
              let zone = TimeZone(identifier: timeZoneIdentifier) else {
            throw AppModelError.invalidBook
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = zone
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        guard let days = calendar.dateComponents(
            [.day],
            from: startDay,
            to: endDay
        ).day, days >= 0 else { throw AppModelError.invalidBook }
        switch cadence {
        case .daily:
            return try addingHeadroom(days, 2)
        case .weekdays:
            let inclusiveDays = try addingHeadroom(days, 1)
            let fullWeeks = inclusiveDays / 7
            let (baseWeekdays, overflow) = fullWeeks
                .multipliedReportingOverflow(by: 5)
            guard !overflow else { throw AppModelError.invalidBook }
            var weekdays = baseWeekdays
            let firstWeekday = calendar.component(.weekday, from: startDay)
            for offset in 0..<(inclusiveDays % 7) {
                let weekday = ((firstWeekday - 1 + offset) % 7) + 1
                if (2...6).contains(weekday) {
                    weekdays = try addingHeadroom(weekdays, 1)
                }
            }
            // One period of headroom covers an activity within its final day.
            return try addingHeadroom(weekdays, 1)
        case .weekly:
            return try addingHeadroom(days / 7, 2)
        case .monthly:
            let startParts = calendar.dateComponents([.year, .month], from: start)
            let endParts = calendar.dateComponents([.year, .month], from: end)
            guard let startYear = startParts.year,
                  let startMonth = startParts.month,
                  let endYear = endParts.year,
                  let endMonth = endParts.month else {
                throw AppModelError.invalidBook
            }
            let (years, yearOverflow) = endYear.subtractingReportingOverflow(
                startYear
            )
            guard !yearOverflow else { throw AppModelError.invalidBook }
            let (scaledYears, overflow) = years.multipliedReportingOverflow(by: 12)
            guard !overflow else { throw AppModelError.invalidBook }
            let (months, monthOverflow) = scaledYears.addingReportingOverflow(
                endMonth - startMonth
            )
            guard !monthOverflow else { throw AppModelError.invalidBook }
            return try addingHeadroom(months, 2)
        }
    }

    private static func addingHeadroom(
        _ value: Int,
        _ headroom: Int
    ) throws -> Int {
        let (result, overflow) = value.addingReportingOverflow(headroom)
        guard !overflow, result >= 0 else { throw AppModelError.invalidBook }
        return result
    }
}
