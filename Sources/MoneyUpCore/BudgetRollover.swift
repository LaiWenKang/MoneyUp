import Foundation

/// Direct category spending for one whole Gregorian reporting month.
public struct MonthlyBudgetSpending: Equatable, Sendable {
    public let monthStart: Date
    public let directSpending: [UUID: Money]

    public init(monthStart: Date, directSpending: [UUID: Money]) {
        self.monthStart = monthStart
        self.directSpending = directSpending
    }
}

/// Preserves the original budget-category attribution when lifecycle work
/// rewrites a journal posting to a replacement account ID. It contains no
/// payee, note, or attachment data and remains inside SQLCipher.
public struct BudgetEntryAttribution: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let occurredAt: Date
    /// Stable civil day at which the user authored the transaction. This is
    /// deliberately independent of a later profile/device time-zone change.
    public let originDayKey: String
    public let originTimeZoneIdentifier: String
    public let originUTCOffsetSeconds: Int
    public let postings: [Posting]

    private init(
        id: UUID,
        occurredAt: Date,
        originDayKey: String,
        originTimeZoneIdentifier: String,
        originUTCOffsetSeconds: Int,
        postings: [Posting]
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.originDayKey = originDayKey
        self.originTimeZoneIdentifier = originTimeZoneIdentifier
        self.originUTCOffsetSeconds = originUTCOffsetSeconds
        self.postings = postings
    }

    public init(
        id: UUID,
        occurredAt: Date,
        originTimeZoneIdentifier: String,
        postings: [Posting]
    ) throws {
        guard let normalizedZone = TimeZone(
            identifier: originTimeZoneIdentifier
        )?.identifier else {
            throw BudgetRolloverError.invalidOriginContext
        }
        let offset = TimeZone(identifier: normalizedZone)?.secondsFromGMT(
            for: occurredAt
        ) ?? 0
        self.id = id
        self.occurredAt = occurredAt
        self.originTimeZoneIdentifier = normalizedZone
        self.originUTCOffsetSeconds = offset
        self.originDayKey = Self.dayKey(
            for: occurredAt,
            utcOffsetSeconds: offset
        )
        self.postings = postings
    }

    public init(
        entry: JournalEntry,
        originTimeZoneIdentifier: String
    ) throws {
        if entry.originContext.wasInferred {
            // A legacy row had no persisted origin context. Attribute it in
            // the explicit reporting zone supplied by the caller.
            try self.init(
                id: entry.id,
                occurredAt: entry.occurredAt,
                originTimeZoneIdentifier: originTimeZoneIdentifier,
                postings: entry.postings
            )
        } else {
            // CSV offsets and scheduled recurrence zones are authoring facts.
            // Recomputing them in the profile zone can cross a month boundary.
            let dayKey = entry.originContext.dayKey
            self.init(
                id: entry.id,
                occurredAt: entry.occurredAt,
                originDayKey: String(
                    format: "%04d-%02d-%02d",
                    dayKey / 10_000,
                    dayKey / 100 % 100,
                    dayKey % 100
                ),
                originTimeZoneIdentifier: entry.originContext.timeZoneIdentifier,
                originUTCOffsetSeconds: entry.originContext.utcOffsetSeconds,
                postings: entry.postings
            )
        }
    }

    /// Rebuilds an attribution for an edited immutable journal entry. An
    /// amount/category-only edit preserves its original civil day; an edit of
    /// the occurrence instant intentionally reattributes it in the active
    /// reporting zone supplied by the app layer.
    public init(
        replacing entry: JournalEntry,
        prior: BudgetEntryAttribution,
        reportingTimeZoneIdentifier: String
    ) throws {
        if entry.occurredAt == prior.occurredAt {
            self.init(
                id: entry.id,
                occurredAt: entry.occurredAt,
                originDayKey: prior.originDayKey,
                originTimeZoneIdentifier: prior.originTimeZoneIdentifier,
                originUTCOffsetSeconds: prior.originUTCOffsetSeconds,
                postings: entry.postings
            )
        } else {
            try self.init(
                entry: entry,
                originTimeZoneIdentifier: reportingTimeZoneIdentifier
            )
        }
    }

    /// Returns the stable civil day represented in the caller's reporting
    /// calendar. The absolute `occurredAt` remains audit metadata only.
    public func attributedDate(in calendar: Calendar) -> Date? {
        let values = originDayKey.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3 else { return nil }
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: values[0],
            month: values[1],
            day: values[2],
            hour: 12
        ))
    }

    private enum CodingKeys: String, CodingKey {
        case id, occurredAt, originDayKey, originTimeZoneIdentifier
        case originUTCOffsetSeconds, postings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let occurredAt = try container.decode(Date.self, forKey: .occurredAt)
        let decodedZone = try container.decode(
            String.self,
            forKey: .originTimeZoneIdentifier
        )
        guard let originTimeZone = TimeZone(identifier: decodedZone) else {
            throw DecodingError.dataCorruptedError(
                forKey: .originTimeZoneIdentifier,
                in: container,
                debugDescription: "Invalid budget-attribution origin time zone"
            )
        }
        let zone = originTimeZone.identifier
        let offset = try container.decode(
            Int.self,
            forKey: .originUTCOffsetSeconds
        )
        guard TimeZone(secondsFromGMT: offset) != nil,
              originTimeZone.secondsFromGMT(for: occurredAt) == offset else {
            throw DecodingError.dataCorruptedError(
                forKey: .originUTCOffsetSeconds,
                in: container,
                debugDescription: "Budget-attribution zone and offset disagree"
            )
        }
        let day = try container.decode(
            String.self,
            forKey: .originDayKey
        )
        guard Self.isValidDayKey(day),
              day == Self.dayKey(
                  for: occurredAt,
                  utcOffsetSeconds: offset
              ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .originDayKey,
                in: container,
                debugDescription: "Invalid budget-attribution origin day"
            )
        }
        self.id = id
        self.occurredAt = occurredAt
        self.originDayKey = day
        self.originTimeZoneIdentifier = zone
        self.originUTCOffsetSeconds = offset
        let postings = try container.decode([Posting].self, forKey: .postings)
        do {
            _ = try JournalEntry(
                id: id,
                kind: .adjustment,
                occurredAt: occurredAt,
                createdAt: occurredAt,
                postings: postings
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .postings,
                in: container,
                debugDescription: "Invalid budget-attribution postings"
            )
        }
        self.postings = postings
    }

    private static func dayKey(
        for date: Date,
        utcOffsetSeconds: Int
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: utcOffsetSeconds) ?? .gmt
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private static func isValidDayKey(_ key: String) -> Bool {
        let values = key.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3,
              key.count == 10,
              let date = FinancialPeriodBoundary.gregorianCalendar(
                  timeZoneIdentifier: "GMT"
              ).date(from: DateComponents(
                  year: values[0],
                  month: values[1],
                  day: values[2]
              )) else { return false }
        return dayKey(for: date, utcOffsetSeconds: 0) == key
    }
}

/// Effective limits at the opening of a reporting month.
public struct BudgetRolloverSnapshot: Equatable, Sendable {
    public let month: DateInterval
    public let effectiveLimits: [UUID: Money]
    public let carryIn: [UUID: Money]

    public init(
        month: DateInterval,
        effectiveLimits: [UUID: Money],
        carryIn: [UUID: Money]
    ) {
        self.month = month
        self.effectiveLimits = effectiveLimits
        self.carryIn = carryIn
    }
}

public enum BudgetRolloverError: Error, Equatable {
    case invalidMonth
    case duplicateMonth(Date)
    case emptyConfigurationTimeline
    case duplicateConfigurationMonth(Date)
    case duplicateConfigurationID(UUID)
    case configurationCurrencyMismatch
    case invalidCarryMapping
    case invalidOriginContext
}

/// Transfers a closed-month carry when a category ID is merged. Reparenting
/// keeps IDs and needs no mapping; a merge must not silently discard carry.
public struct BudgetCarryMapping: Codable, Equatable, Sendable {
    public let sourceID: UUID
    public let targetID: UUID

    public init(sourceID: UUID, targetID: UUID) {
        self.sourceID = sourceID
        self.targetID = targetID
    }
}

public struct BudgetCarryBalance: Codable, Equatable, Sendable {
    public let nodeID: UUID
    public let money: Money

    public init(nodeID: UUID, money: Money) {
        self.nodeID = nodeID
        self.money = money
    }
}

/// An immutable view of the budget configuration beginning with one reporting
/// month. Keeping the complete tree makes limit, rollover-rule, and hierarchy
/// changes prospective without trying to infer old settings from today's
/// mutable categories.
public struct BudgetConfigurationRevision: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let effectiveMonth: Date
    public let nodes: [BudgetNode]
    public let carryMappings: [BudgetCarryMapping]
    /// Exact carry entering this month before `carryMappings` are applied.
    /// `nil` means replay prior months; an empty array is an authoritative
    /// zero-carry checkpoint.
    public let openingCarry: [BudgetCarryBalance]?

    public init(
        id: UUID = UUID(),
        effectiveMonth: Date,
        nodes: [BudgetNode],
        carryMappings: [BudgetCarryMapping] = [],
        openingCarry: [UUID: Money]? = nil
    ) {
        self.id = id
        self.effectiveMonth = effectiveMonth
        self.nodes = nodes
        self.carryMappings = carryMappings.sorted {
            if $0.sourceID == $1.sourceID {
                return $0.targetID.uuidString < $1.targetID.uuidString
            }
            return $0.sourceID.uuidString < $1.sourceID.uuidString
        }
        self.openingCarry = openingCarry.map { values in
            values.map { BudgetCarryBalance(nodeID: $0.key, money: $0.value) }
                .sorted { $0.nodeID.uuidString < $1.nodeID.uuidString }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case effectiveMonth
        case nodes
        case carryMappings
        case openingCarry
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedBalances = try container.decodeIfPresent(
            [BudgetCarryBalance].self,
            forKey: .openingCarry
        )
        var decodedOpeningCarry: [UUID: Money]?
        if let decodedBalances {
            var values: [UUID: Money] = [:]
            for balance in decodedBalances {
                guard values.updateValue(
                    balance.money,
                    forKey: balance.nodeID
                ) == nil else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .openingCarry,
                        in: container,
                        debugDescription: "Duplicate opening-carry node"
                    )
                }
            }
            decodedOpeningCarry = values
        } else {
            decodedOpeningCarry = nil
        }
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            effectiveMonth: try container.decode(Date.self, forKey: .effectiveMonth),
            nodes: try container.decode([BudgetNode].self, forKey: .nodes),
            carryMappings: try container.decodeIfPresent(
                [BudgetCarryMapping].self,
                forKey: .carryMappings
            ) ?? [],
            openingCarry: decodedOpeningCarry
        )
    }

    public var openingCarryByID: [UUID: Money]? {
        openingCarry.map { balances in
            Dictionary(uniqueKeysWithValues: balances.map { ($0.nodeID, $0.money) })
        }
    }
}

/// The encrypted, prospective history used to calculate exact rollover.
///
/// Legacy books receive one baseline revision on upgrade. Subsequent changes
/// replace only the current reporting month's revision, leaving every closed
/// month immutable.
public struct BudgetConfigurationTimeline: Codable, Equatable, Sendable {
    public static let primaryRecordID = "primary"
    public static let maximumRevisionCount = 1_200
    public static let maximumNodesPerRevision = 10_000
    public static let maximumNodeCount = 100_000

    public let currency: CurrencyCode
    public let revisions: [BudgetConfigurationRevision]

    public init(
        currency: CurrencyCode,
        revisions: [BudgetConfigurationRevision]
    ) throws {
        guard !revisions.isEmpty else {
            throw BudgetRolloverError.emptyConfigurationTimeline
        }
        guard revisions.count <= Self.maximumRevisionCount,
              revisions.allSatisfy({
                  $0.nodes.count <= Self.maximumNodesPerRevision
              }),
              revisions.reduce(0, { $0 + $1.nodes.count })
                <= Self.maximumNodeCount else {
            throw BudgetRolloverError.invalidCarryMapping
        }
        let normalized = revisions.map { revision in
            BudgetConfigurationRevision(
                id: revision.id,
                effectiveMonth: revision.effectiveMonth,
                nodes: revision.nodes.sorted {
                    $0.id.uuidString < $1.id.uuidString
                },
                carryMappings: revision.carryMappings,
                openingCarry: revision.openingCarryByID
            )
        }
        let sorted = normalized.sorted { $0.effectiveMonth < $1.effectiveMonth }
        var revisionIDs = Set<UUID>()
        for (index, revision) in sorted.enumerated() {
            guard revisionIDs.insert(revision.id).inserted else {
                throw BudgetRolloverError.duplicateConfigurationID(revision.id)
            }
            let tree = try BudgetTree(currency: currency, nodes: revision.nodes)
            let nodeIDs = Set(tree.nodes.map(\.id))
            var mappedSources = Set<UUID>()
            for mapping in revision.carryMappings {
                guard mapping.sourceID != mapping.targetID,
                      mappedSources.insert(mapping.sourceID).inserted,
                      !nodeIDs.contains(mapping.sourceID),
                      nodeIDs.contains(mapping.targetID) else {
                    throw BudgetRolloverError.invalidCarryMapping
                }
            }
            var openingIDs = Set<UUID>()
            for balance in revision.openingCarry ?? [] {
                guard openingIDs.insert(balance.nodeID).inserted,
                      balance.money.currency == currency,
                      nodeIDs.contains(balance.nodeID)
                        || mappedSources.contains(balance.nodeID) else {
                    throw BudgetRolloverError.invalidCarryMapping
                }
            }
            if index > 0,
               sorted[index - 1].effectiveMonth == revision.effectiveMonth {
                throw BudgetRolloverError.duplicateConfigurationMonth(
                    revision.effectiveMonth
                )
            }
        }
        self.currency = currency
        self.revisions = sorted
    }

    /// Returns the last configuration that had become effective by `month`.
    /// A migrated baseline is also the conservative fallback for an earlier
    /// query; callers create that baseline at the earliest known activation.
    public func tree(effectiveAt month: Date) throws -> BudgetTree {
        let revision = revision(effectiveAt: month)
        return try BudgetTree(currency: currency, nodes: revision.nodes)
    }

    public func revision(effectiveAt month: Date) -> BudgetConfigurationRevision {
        revisions.last { $0.effectiveMonth <= month } ?? revisions[0]
    }

    public func recording(
        nodes: [BudgetNode],
        effectiveMonth: Date,
        carryMappings: [BudgetCarryMapping] = [],
        openingCarry: [UUID: Money]? = nil
    ) throws -> BudgetConfigurationTimeline {
        _ = try BudgetTree(currency: currency, nodes: nodes)
        var mergedMappings = revisions.first {
            $0.effectiveMonth == effectiveMonth
        }?.carryMappings ?? []
        for newMapping in carryMappings {
            mergedMappings = mergedMappings.map { existing in
                guard existing.targetID == newMapping.sourceID else {
                    return existing
                }
                return BudgetCarryMapping(
                    sourceID: existing.sourceID,
                    targetID: newMapping.targetID
                )
            }
            mergedMappings.removeAll { $0.sourceID == newMapping.sourceID }
            mergedMappings.append(newMapping)
        }
        mergedMappings.removeAll { $0.sourceID == $0.targetID }
        let preservedOpeningCarry = revisions.first {
            $0.effectiveMonth == effectiveMonth
        }?.openingCarryByID ?? openingCarry
        var candidate = revisions.filter { $0.effectiveMonth != effectiveMonth }
        candidate.append(BudgetConfigurationRevision(
            effectiveMonth: effectiveMonth,
            nodes: nodes,
            carryMappings: mergedMappings,
            openingCarry: preservedOpeningCarry
        ))
        return try BudgetConfigurationTimeline(
            currency: currency,
            revisions: candidate
        )
    }

    private enum CodingKeys: String, CodingKey {
        case currency
        case revisions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let currency = try container.decode(CurrencyCode.self, forKey: .currency)
        let revisions = try container.decode(
            [BudgetConfigurationRevision].self,
            forKey: .revisions
        )
        do {
            try self.init(currency: currency, revisions: revisions)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .revisions,
                in: container,
                debugDescription: "Budget configuration timeline is invalid"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(currency, forKey: .currency)
        try container.encode(
            revisions.sorted { $0.effectiveMonth < $1.effectiveMonth },
            forKey: .revisions
        )
    }
}

/// Applies rollover exactly once at each half-open month boundary.
///
/// The engine accepts Decimal-backed `Money` only, performs no conversion, and
/// asks `BudgetTree` to roll direct spending through the hierarchy. A missing
/// month is an explicit zero-spending month; an existing budget never becomes
/// a false zero merely because there were no journal entries.
public enum BudgetRolloverEngine {
    public static func snapshot(
        tree: BudgetTree,
        monthlySpending: [MonthlyBudgetSpending],
        asOf: Date,
        calendar: Calendar = FinancialPeriodBoundary.gregorianCalendar()
    ) throws -> BudgetRolloverSnapshot {
        try snapshot(
            currency: tree.currency,
            revisionForMonth: { month in
                BudgetConfigurationRevision(
                    effectiveMonth: month,
                    nodes: tree.nodes
                )
            },
            latestCheckpoint: { _ in nil },
            allConfigurationNodes: tree.nodes,
            monthlySpending: monthlySpending,
            asOf: asOf,
            calendar: calendar
        )
    }

    public static func snapshot(
        timeline: BudgetConfigurationTimeline,
        monthlySpending: [MonthlyBudgetSpending],
        asOf: Date,
        calendar: Calendar = FinancialPeriodBoundary.gregorianCalendar()
    ) throws -> BudgetRolloverSnapshot {
        try snapshot(
            currency: timeline.currency,
            revisionForMonth: { timeline.revision(effectiveAt: $0) },
            latestCheckpoint: { month in
                timeline.revisions.last {
                    $0.effectiveMonth <= month && $0.openingCarry != nil
                }
            },
            allConfigurationNodes: timeline.revisions.flatMap(\.nodes),
            monthlySpending: monthlySpending,
            asOf: asOf,
            calendar: calendar
        )
    }

    private static func snapshot(
        currency: CurrencyCode,
        revisionForMonth: (Date) throws -> BudgetConfigurationRevision,
        latestCheckpoint: (Date) -> BudgetConfigurationRevision?,
        allConfigurationNodes: [BudgetNode],
        monthlySpending: [MonthlyBudgetSpending],
        asOf: Date,
        calendar: Calendar
    ) throws -> BudgetRolloverSnapshot {
        guard let currentMonth = calendar.dateInterval(of: .month, for: asOf) else {
            throw BudgetRolloverError.invalidMonth
        }

        var spendingByMonth: [Date: [UUID: Money]] = [:]
        for period in monthlySpending {
            guard let normalized = calendar.dateInterval(
                of: .month,
                for: period.monthStart
            )?.start else {
                throw BudgetRolloverError.invalidMonth
            }
            guard spendingByMonth.updateValue(
                period.directSpending,
                forKey: normalized
            ) == nil else {
                throw BudgetRolloverError.duplicateMonth(normalized)
            }
        }

        let currentTree = try BudgetTree(
            currency: currency,
            nodes: revisionForMonth(currentMonth.start).nodes
        )
        guard currentTree.currency == currency else {
            throw BudgetRolloverError.configurationCurrencyMismatch
        }
        let currentConfiguredLimits = configuredLimits(in: currentTree)
        let activationMonths = allConfigurationNodes.compactMap { node -> Date? in
            guard node.limit != nil,
                  node.rolloverRule != .none,
                  let startedAt = node.rolloverStartedAt else { return nil }
            return calendar.dateInterval(of: .month, for: startedAt)?.start
        }
        let checkpoint = latestCheckpoint(currentMonth.start)
        var monthStart: Date
        var carry: [UUID: Money]
        if let checkpoint,
           let openingCarry = checkpoint.openingCarryByID {
            monthStart = checkpoint.effectiveMonth
            carry = openingCarry
        } else {
            guard let activation = activationMonths.min(),
                  activation <= currentMonth.start else {
                return BudgetRolloverSnapshot(
                    month: currentMonth,
                    effectiveLimits: currentConfiguredLimits,
                    carryIn: [:]
                )
            }
            monthStart = activation
            carry = [:]
        }

        while monthStart <= currentMonth.start {
            let revision = try revisionForMonth(monthStart)
            if revision.effectiveMonth == monthStart {
                carry = try remapCarry(
                    carry,
                    using: revision.carryMappings,
                    currency: currency
                )
            }
            let tree = try BudgetTree(currency: currency, nodes: revision.nodes)
            guard tree.currency == currency else {
                throw BudgetRolloverError.configurationCurrencyMismatch
            }
            var effective = configuredLimits(in: tree)
            for node in tree.nodes {
                guard let base = node.limit,
                      node.rolloverRule != .none,
                      let startedAt = node.rolloverStartedAt,
                      let activation = calendar.dateInterval(
                          of: .month,
                          for: startedAt
                      )?.start,
                      activation <= monthStart else { continue }
                effective[node.id] = try base.adding(
                    carry[node.id] ?? Money.zero(currency: tree.currency)
                )
            }

            if monthStart == currentMonth.start {
                return BudgetRolloverSnapshot(
                    month: currentMonth,
                    effectiveLimits: effective,
                    carryIn: carry.filter { !$0.value.isZero }
                )
            }

            let rolled = try tree.rolledUpSpending(
                directSpending: spendingByMonth[monthStart] ?? [:]
            )
            var nextCarry: [UUID: Money] = [:]
            for node in tree.nodes {
                guard let limit = effective[node.id],
                      node.rolloverRule != .none,
                      let startedAt = node.rolloverStartedAt,
                      let activation = calendar.dateInterval(
                          of: .month,
                          for: startedAt
                      )?.start,
                      activation <= monthStart else { continue }
                let spent = rolled[node.id] ?? Money.zero(currency: tree.currency)
                let balance = try limit.subtracting(spent)
                switch node.rolloverRule {
                case .none:
                    break
                case .positiveOnly:
                    if balance.amount > .zero { nextCarry[node.id] = balance }
                case .fullBalance:
                    if !balance.isZero { nextCarry[node.id] = balance }
                }
            }
            carry = nextCarry

            guard let next = calendar.date(
                byAdding: .month,
                value: 1,
                to: monthStart
            ) else {
                throw BudgetRolloverError.invalidMonth
            }
            monthStart = next
        }

        throw BudgetRolloverError.invalidMonth
    }

    private static func configuredLimits(in tree: BudgetTree) -> [UUID: Money] {
        Dictionary(
            uniqueKeysWithValues: tree.nodes.compactMap { node in
                node.limit.map { (node.id, $0) }
            }
        )
    }

    private static func remapCarry(
        _ original: [UUID: Money],
        using mappings: [BudgetCarryMapping],
        currency: CurrencyCode
    ) throws -> [UUID: Money] {
        var result = original
        for mapping in mappings {
            guard let source = result.removeValue(forKey: mapping.sourceID) else {
                continue
            }
            result[mapping.targetID] = try (
                result[mapping.targetID] ?? Money.zero(currency: currency)
            ).adding(source)
        }
        return result
    }
}
