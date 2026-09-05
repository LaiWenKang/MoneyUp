import Foundation

enum BudgetWidgetSnapshot: Equatable, Sendable {
    case disabled
    case needsBudget(validUntil: Date)
    case zeroBudget(validUntil: Date)
    case negativeBudget(validUntil: Date)
    case stale
    case available(percentUsed: Int, validUntil: Date)
}

/// A deliberately bounded, record-free summary for Smart Overview.
///
/// A nil review count is materially different from zero: nil means the
/// current logical book has not completed its intelligence refresh, while zero
/// is a completed result with nothing to review.
struct MoneyUpWidgetInsights: Equatable, Sendable {
    let reviewCount: Int?
    let allowancePercentRemaining: Int?
    let activeCommitmentCount: Int
    let daysUntilNextCommitment: Int?
    let validUntil: Date
}

struct MoneyUpWidgetPublishedSnapshot: Equatable, Sendable {
    let budget: BudgetWidgetSnapshot
    let insights: MoneyUpWidgetInsights?
}

/// The only cross-process financial derivative MoneyUp permits.
///
/// The app and extension exchange one versioned Codable value through one
/// UserDefaults key. Replacing that Data value is the publication boundary, so
/// a widget can never combine a budget status from one generation with insight
/// fields from another. The payload cannot represent an amount, name, holding,
/// balance, exact due date, or ledger identifier.
final class BudgetWidgetSnapshotStore {
    static let appGroupIdentifier = "group.com.laiwenkang.MoneyUp"
    static let currentSchemaVersion = 4
    static let payloadKey = "moneyUp.widget.snapshot.v4"
    static let maximumPayloadByteCount = 4_096

    private enum BudgetState: String, Codable {
        case disabled
        case needsBudget
        case zeroBudget
        case negativeBudget
        case stale
        case available
    }

    private struct PersistedInsights: Codable, Equatable {
        var reviewCount: Int?
        var allowancePercentRemaining: Int?
        var activeCommitmentCount: Int
        var daysUntilNextCommitment: Int?
        var validUntil: Date
    }

    private struct PersistedSnapshot: Codable, Equatable {
        var schemaVersion: Int
        var enabled: Bool
        var budgetState: BudgetState
        var percentUsed: Int?
        var periodToken: String?
        var budgetValidUntil: Date?
        var insights: PersistedInsights?

        static let disabled = PersistedSnapshot(
            schemaVersion: BudgetWidgetSnapshotStore.currentSchemaVersion,
            enabled: false,
            budgetState: .disabled,
            percentUsed: nil,
            periodToken: nil,
            budgetValidUntil: nil,
            insights: nil
        )

        static let stale = PersistedSnapshot(
            schemaVersion: BudgetWidgetSnapshotStore.currentSchemaVersion,
            enabled: true,
            budgetState: .stale,
            percentUsed: nil,
            periodToken: nil,
            budgetValidUntil: nil,
            insights: nil
        )
    }

    /// Version 1-3 used independent keys. They are read only during migration
    /// and are deleted before any version-4 value is exposed.
    private enum LegacyKey {
        static let schemaVersion = "budgetStatus.schemaVersion"
        static let enabled = "budgetStatus.enabled"
        static let state = "budgetStatus.state"
        static let percentUsed = "budgetStatus.percentUsed"
        static let periodToken = "budgetStatus.periodToken"
        static let validUntil = "budgetStatus.validUntil"
        static let insightReviewCount = "budgetStatus.insight.reviewCount"
        static let insightAllowancePercent = "budgetStatus.insight.allowancePercent"
        static let insightCommitmentCount = "budgetStatus.insight.commitmentCount"
        static let insightValidUntil = "budgetStatus.insight.validUntil"
    }

    /// Known early-development keys are removed during migration so a future
    /// refactor cannot accidentally resurrect a sensitive prototype payload.
    private static let forbiddenLegacyKeys = [
        "budgetStatus.amount",
        "budgetStatus.payee",
        "budgetStatus.account",
        "budgetStatus.balance",
        "widget.amount",
        "widget.payee",
        "widget.account",
        "widget.balance"
    ]

    private let defaults: UserDefaults?
    private let allowsMaintenanceWrites: Bool
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(defaults: UserDefaults? = UserDefaults(
        suiteName: BudgetWidgetSnapshotStore.appGroupIdentifier
    ), allowsMaintenanceWrites: Bool = true) {
        self.defaults = defaults
        self.allowsMaintenanceWrites = allowsMaintenanceWrites
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder.dateDecodingStrategy = .millisecondsSince1970
        migrateIfNeeded()
    }

    /// Publishes a complete widget generation with one App Group write.
    func publish(
        _ snapshot: BudgetWidgetSnapshot,
        periodToken: String? = nil,
        insights: MoneyUpWidgetInsights? = nil
    ) {
        guard allowsMaintenanceWrites, let defaults else { return }
        guard Self.hasValidInsightShape(insights) else {
            persist(.stale, to: defaults)
            scrubLegacyPayload(defaults)
            return
        }
        let record: PersistedSnapshot
        switch snapshot {
        case .disabled:
            record = .disabled
        case .stale:
            record = .stale
        case let .needsBudget(validUntil):
            if let periodToken,
               Self.isValidPeriodToken(periodToken),
               validUntil.timeIntervalSinceReferenceDate.isFinite {
                record = PersistedSnapshot(
                    schemaVersion: Self.currentSchemaVersion,
                    enabled: true,
                    budgetState: .needsBudget,
                    percentUsed: nil,
                    periodToken: periodToken,
                    budgetValidUntil: validUntil,
                    insights: Self.persistedInsights(insights)
                )
            } else {
                record = .stale
            }
        case let .zeroBudget(validUntil):
            if let periodToken,
               Self.isValidPeriodToken(periodToken),
               validUntil.timeIntervalSinceReferenceDate.isFinite {
                record = PersistedSnapshot(
                    schemaVersion: Self.currentSchemaVersion,
                    enabled: true,
                    budgetState: .zeroBudget,
                    percentUsed: nil,
                    periodToken: periodToken,
                    budgetValidUntil: validUntil,
                    insights: Self.persistedInsights(insights)
                )
            } else {
                record = .stale
            }
        case let .negativeBudget(validUntil):
            if let periodToken,
               Self.isValidPeriodToken(periodToken),
               validUntil.timeIntervalSinceReferenceDate.isFinite {
                record = PersistedSnapshot(
                    schemaVersion: Self.currentSchemaVersion,
                    enabled: true,
                    budgetState: .negativeBudget,
                    percentUsed: nil,
                    periodToken: periodToken,
                    budgetValidUntil: validUntil,
                    insights: Self.persistedInsights(insights)
                )
            } else {
                record = .stale
            }
        case let .available(percentUsed, validUntil):
            if let periodToken,
               Self.isValidPeriodToken(periodToken),
               percentUsed >= 0,
               validUntil.timeIntervalSinceReferenceDate.isFinite {
                record = PersistedSnapshot(
                    schemaVersion: Self.currentSchemaVersion,
                    enabled: true,
                    budgetState: .available,
                    percentUsed: Self.boundedPercentUsed(percentUsed),
                    periodToken: periodToken,
                    budgetValidUntil: validUntil,
                    insights: Self.persistedInsights(insights)
                )
            } else {
                record = .stale
            }
        }
        persist(record, to: defaults)
        scrubLegacyPayload(defaults)
    }

    /// Compatibility helper for tests and narrowly scoped callers. It still
    /// replaces the complete Codable record in one write.
    func publishInsights(
        enabled: Bool,
        reviewCount: Int? = nil,
        allowancePercentRemaining: Int? = nil,
        activeCommitmentCount: Int = 0,
        daysUntilNextCommitment: Int? = nil,
        validUntil: Date? = nil
    ) {
        guard allowsMaintenanceWrites, let defaults else { return }
        guard enabled,
              var record = decodedRecord(from: defaults),
              record.enabled,
              let validUntil,
              validUntil.timeIntervalSinceReferenceDate.isFinite else {
            if var record = decodedRecord(from: defaults) {
                record.insights = nil
                persist(record.enabled ? record : .disabled, to: defaults)
            }
            return
        }
        let insights = MoneyUpWidgetInsights(
            reviewCount: reviewCount,
            allowancePercentRemaining: allowancePercentRemaining,
            activeCommitmentCount: activeCommitmentCount,
            daysUntilNextCommitment: daysUntilNextCommitment,
            validUntil: validUntil
        )
        guard Self.hasValidInsightShape(insights) else {
            persist(.stale, to: defaults)
            return
        }
        record.insights = Self.persistedInsights(insights)
        persist(record, to: defaults)
    }

    func read(now: Date = Date()) -> BudgetWidgetSnapshot {
        readPublishedSnapshot(now: now).budget
    }

    func readInsights(now: Date = Date()) -> MoneyUpWidgetInsights? {
        readPublishedSnapshot(now: now).insights
    }

    /// Decodes exactly one generation for a timeline entry. Reading budget and
    /// insights independently would permit an app publication between calls,
    /// recreating the mixed-generation state the atomic payload prevents.
    func readPublishedSnapshot(
        now: Date = Date()
    ) -> MoneyUpWidgetPublishedSnapshot {
        guard let record = currentRecord(now: now), record.enabled else {
            return MoneyUpWidgetPublishedSnapshot(budget: .disabled, insights: nil)
        }
        let budget: BudgetWidgetSnapshot
        switch record.budgetState {
        case .available:
            guard let percentUsed = record.percentUsed,
                  let validUntil = record.budgetValidUntil else {
                return MoneyUpWidgetPublishedSnapshot(budget: .stale, insights: nil)
            }
            budget = .available(percentUsed: percentUsed, validUntil: validUntil)
        case .needsBudget:
            guard let validUntil = record.budgetValidUntil else {
                return MoneyUpWidgetPublishedSnapshot(budget: .stale, insights: nil)
            }
            budget = .needsBudget(validUntil: validUntil)
        case .zeroBudget:
            guard let validUntil = record.budgetValidUntil else {
                return MoneyUpWidgetPublishedSnapshot(budget: .stale, insights: nil)
            }
            budget = .zeroBudget(validUntil: validUntil)
        case .negativeBudget:
            guard let validUntil = record.budgetValidUntil else {
                return MoneyUpWidgetPublishedSnapshot(budget: .stale, insights: nil)
            }
            budget = .negativeBudget(validUntil: validUntil)
        case .disabled:
            return MoneyUpWidgetPublishedSnapshot(budget: .disabled, insights: nil)
        case .stale:
            budget = .stale
        }
        let insights = record.insights.map {
            MoneyUpWidgetInsights(
                reviewCount: $0.reviewCount,
                allowancePercentRemaining: $0.allowancePercentRemaining,
                activeCommitmentCount: $0.activeCommitmentCount,
                daysUntilNextCommitment: $0.daysUntilNextCommitment,
                validUntil: $0.validUntil
            )
        }
        return MoneyUpWidgetPublishedSnapshot(
            budget: budget,
            insights: insights
        )
    }

    func migrateIfNeeded() {
        guard allowsMaintenanceWrites, let defaults else { return }
        for key in Self.forbiddenLegacyKeys {
            defaults.removeObject(forKey: key)
        }

        if let data = defaults.data(forKey: Self.payloadKey) {
            guard let record = decodedRecord(from: data),
                  record.schemaVersion == Self.currentSchemaVersion else {
                persist(.stale, to: defaults)
                scrubLegacyPayload(defaults)
                return
            }
            // Re-encode a structurally sanitized record so a tampered payload
            // cannot retain fields which its state is not permitted to expose.
            persist(Self.sanitized(record, now: nil), to: defaults)
            scrubLegacyPayload(defaults)
            return
        }

        persist(migratedLegacyRecord(from: defaults), to: defaults)
        scrubLegacyPayload(defaults)
    }

    static var allowedPersistedKeys: Set<String> { [payloadKey] }

    static func periodToken(for date: Date, calendar: Calendar) -> String? {
        let components = calendar.dateComponents([.year, .month], from: date)
        guard let year = components.year, let month = components.month else {
            return nil
        }
        let token = String(format: "%04d-%02d", year, month)
        return Self.isValidPeriodToken(token) ? token : nil
    }

    private func currentRecord(now: Date) -> PersistedSnapshot? {
        guard let defaults,
              let data = defaults.data(forKey: Self.payloadKey) else { return nil }
        guard let decoded = decodedRecord(from: data) else {
            if allowsMaintenanceWrites {
                persist(.stale, to: defaults)
            }
            return .stale
        }
        let sanitized = Self.sanitized(decoded, now: now)
        if allowsMaintenanceWrites, sanitized != decoded {
            persist(sanitized, to: defaults)
        }
        return sanitized
    }

    private func decodedRecord(from defaults: UserDefaults) -> PersistedSnapshot? {
        guard let data = defaults.data(forKey: Self.payloadKey) else { return nil }
        return decodedRecord(from: data)
    }

    private func decodedRecord(from data: Data) -> PersistedSnapshot? {
        guard data.count <= Self.maximumPayloadByteCount,
              let record = try? decoder.decode(PersistedSnapshot.self, from: data),
              record.schemaVersion == Self.currentSchemaVersion else { return nil }
        return record
    }

    private func persist(_ record: PersistedSnapshot, to defaults: UserDefaults) {
        guard let data = try? encoder.encode(record) else {
            defaults.removeObject(forKey: Self.payloadKey)
            return
        }
        // This single replacement is the only version-4 cross-process write.
        defaults.set(data, forKey: Self.payloadKey)
    }

    private func migratedLegacyRecord(from defaults: UserDefaults) -> PersistedSnapshot {
        let version = defaults.integer(forKey: LegacyKey.schemaVersion)
        guard version <= 3, defaults.bool(forKey: LegacyKey.enabled) else {
            return .disabled
        }
        guard version >= 1 else { return .disabled }
        guard version >= 2 else { return .stale }
        guard let periodToken = defaults.string(forKey: LegacyKey.periodToken),
              Self.isValidPeriodToken(periodToken),
              let validUntil = defaults.object(forKey: LegacyKey.validUntil) as? Date,
              validUntil.timeIntervalSinceReferenceDate.isFinite else {
            return .stale
        }

        let state: BudgetState
        let percentUsed: Int?
        switch defaults.string(forKey: LegacyKey.state) {
        case "available":
            guard let stored = defaults.object(forKey: LegacyKey.percentUsed)
                as? NSNumber,
                  stored.intValue >= 0 else { return .stale }
            state = .available
            percentUsed = Self.boundedPercentUsed(stored.intValue)
        case "needsBudget":
            // Legacy writers inferred this state from a nil percentage, which
            // also represented an unavailable calculation. Its provenance is
            // ambiguous, so only a current explicit publication may show the
            // user a no-budget prompt.
            return .stale
        default:
            return .stale
        }

        var insights: PersistedInsights?
        if version == 3,
           let insightValidUntil = defaults.object(
               forKey: LegacyKey.insightValidUntil
           ) as? Date,
           insightValidUntil.timeIntervalSinceReferenceDate.isFinite {
            let reviewCount = (defaults.object(
                forKey: LegacyKey.insightReviewCount
            ) as? NSNumber)?.intValue
            let allowancePercent = (defaults.object(
                forKey: LegacyKey.insightAllowancePercent
            ) as? NSNumber)?.intValue
            let commitmentCount = (defaults.object(
                forKey: LegacyKey.insightCommitmentCount
            ) as? NSNumber)?.intValue ?? 0
            guard Self.hasValidInsightCounts(
                reviewCount: reviewCount,
                allowancePercentRemaining: allowancePercent,
                activeCommitmentCount: commitmentCount,
                daysUntilNextCommitment: nil
            ) else { return .stale }
            insights = PersistedInsights(
                reviewCount: reviewCount.map(Self.boundedCount),
                allowancePercentRemaining: allowancePercent.map(Self.boundedPercentage),
                activeCommitmentCount: Self.boundedCount(commitmentCount),
                // Legacy exact dates carried no reporting-calendar identity.
                // Drop them instead of deriving a potentially wrong day count.
                daysUntilNextCommitment: nil,
                validUntil: insightValidUntil
            )
        }

        return PersistedSnapshot(
            schemaVersion: Self.currentSchemaVersion,
            enabled: true,
            budgetState: state,
            percentUsed: percentUsed,
            periodToken: periodToken,
            budgetValidUntil: validUntil,
            insights: insights
        )
    }

    private static func sanitized(
        _ value: PersistedSnapshot,
        now: Date?
    ) -> PersistedSnapshot {
        guard value.schemaVersion == currentSchemaVersion else { return .stale }
        guard value.enabled else {
            return value == .disabled ? .disabled : .stale
        }
        guard value.budgetState != .disabled else { return .stale }
        var result = sanitizedBudgetState(value, now: now)
        guard result.enabled else { return .disabled }
        guard result.budgetState != .stale else {
            result.insights = nil
            return result
        }

        if var insights = result.insights {
            guard insights.validUntil.timeIntervalSinceReferenceDate.isFinite,
                  hasValidInsightCounts(
                      reviewCount: insights.reviewCount,
                      allowancePercentRemaining: insights
                          .allowancePercentRemaining,
                      activeCommitmentCount: insights.activeCommitmentCount,
                      daysUntilNextCommitment: insights.daysUntilNextCommitment
                  ),
                  now.map({ $0 < insights.validUntil }) ?? true else {
                scrubBudgetFields(&result)
                result.insights = nil
                return result
            }
            insights.reviewCount = insights.reviewCount.map(boundedCount)
            insights.allowancePercentRemaining = insights
                .allowancePercentRemaining.map(boundedPercentage)
            insights.activeCommitmentCount = boundedCount(
                insights.activeCommitmentCount
            )
            insights.daysUntilNextCommitment = insights
                .daysUntilNextCommitment.map(boundedCount)
            result.insights = insights
        }
        return result
    }

    private static func sanitizedBudgetState(
        _ value: PersistedSnapshot,
        now: Date?
    ) -> PersistedSnapshot {
        var result = value
        result.schemaVersion = currentSchemaVersion
        switch result.budgetState {
        case .available:
            guard hasCurrentBudgetPeriod(result, now: now),
                  let percentUsed = result.percentUsed,
                  percentUsed >= 0 else {
                scrubBudgetFields(&result)
                return result
            }
            result.percentUsed = boundedPercentUsed(percentUsed)
        case .needsBudget, .zeroBudget, .negativeBudget:
            guard hasCurrentBudgetPeriod(result, now: now) else {
                scrubBudgetFields(&result)
                return result
            }
            result.percentUsed = nil
        case .stale:
            scrubBudgetFields(&result)
        case .disabled:
            return .disabled
        }
        return result
    }

    private static func hasCurrentBudgetPeriod(
        _ value: PersistedSnapshot,
        now: Date?
    ) -> Bool {
        guard let token = value.periodToken,
              isValidPeriodToken(token),
              let validUntil = value.budgetValidUntil,
              validUntil.timeIntervalSinceReferenceDate.isFinite else {
            return false
        }
        return now.map { $0 < validUntil } ?? true
    }

    private static func scrubBudgetFields(_ value: inout PersistedSnapshot) {
        value.budgetState = .stale
        value.percentUsed = nil
        value.periodToken = nil
        value.budgetValidUntil = nil
    }

    private static func persistedInsights(
        _ value: MoneyUpWidgetInsights?
    ) -> PersistedInsights? {
        guard let value,
              value.validUntil.timeIntervalSinceReferenceDate.isFinite else {
            return nil
        }
        return PersistedInsights(
            reviewCount: value.reviewCount.map(boundedCount),
            allowancePercentRemaining: value.allowancePercentRemaining.map(
                boundedPercentage
            ),
            activeCommitmentCount: boundedCount(value.activeCommitmentCount),
            daysUntilNextCommitment: value.daysUntilNextCommitment.map(boundedCount),
            validUntil: value.validUntil
        )
    }

    private static func hasValidInsightShape(
        _ value: MoneyUpWidgetInsights?
    ) -> Bool {
        guard let value else { return true }
        return value.validUntil.timeIntervalSinceReferenceDate.isFinite
            && hasValidInsightCounts(
                reviewCount: value.reviewCount,
                allowancePercentRemaining: value.allowancePercentRemaining,
                activeCommitmentCount: value.activeCommitmentCount,
                daysUntilNextCommitment: value.daysUntilNextCommitment
            )
    }

    private static func hasValidInsightCounts(
        reviewCount: Int?,
        allowancePercentRemaining: Int?,
        activeCommitmentCount: Int,
        daysUntilNextCommitment: Int?
    ) -> Bool {
        (reviewCount.map { $0 >= 0 } ?? true)
            && (allowancePercentRemaining.map { $0 >= 0 } ?? true)
            && activeCommitmentCount >= 0
            && (daysUntilNextCommitment.map { $0 >= 0 } ?? true)
    }

    private static func boundedPercentUsed(_ value: Int) -> Int {
        min(max(value, 0), 9_999)
    }

    private static func boundedCount(_ value: Int) -> Int {
        min(max(value, 0), 9_999)
    }

    private static func boundedPercentage(_ value: Int) -> Int {
        min(max(value, 0), 100)
    }

    private static func isValidPeriodToken(_ token: String) -> Bool {
        guard token.utf8.count == 7,
              token.dropFirst(4).first == "-",
              let year = Int(token.prefix(4)),
              (1...9_999).contains(year),
              let month = Int(token.suffix(2)),
              (1...12).contains(month) else { return false }
        return token == String(format: "%04d-%02d", year, month)
    }

    private func scrubLegacyPayload(_ defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("budgetStatus.") || key.hasPrefix("widget.") {
            defaults.removeObject(forKey: key)
        }
    }
}
