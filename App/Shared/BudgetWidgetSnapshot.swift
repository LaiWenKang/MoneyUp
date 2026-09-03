import Foundation

enum BudgetWidgetSnapshot: Equatable, Sendable {
    case disabled
    case needsBudget(validUntil: Date)
    case stale
    case available(percentUsed: Int, validUntil: Date)
}

struct MoneyUpWidgetInsights: Equatable, Sendable {
    let reviewCount: Int
    let activeAllowanceCount: Int
    let allowancePercentRemaining: Int?
    let activeCommitmentCount: Int
    let nextCommitment: Date?
    let validUntil: Date
}

/// The only cross-process financial derivative MoneyUp permits.
///
/// This store cannot represent an amount, account/payee name, holding, balance,
/// or ledger identifier. The protected app publishes bounded counts, rounded
/// percentages, and an optional next-due time. All source records remain
/// inside SQLCipher.
final class BudgetWidgetSnapshotStore {
    static let appGroupIdentifier = "group.com.laiwenkang.MoneyUp"
    static let currentSchemaVersion = 3

    private enum Key {
        static let schemaVersion = "budgetStatus.schemaVersion"
        static let enabled = "budgetStatus.enabled"
        static let state = "budgetStatus.state"
        static let percentUsed = "budgetStatus.percentUsed"
        static let periodToken = "budgetStatus.periodToken"
        static let validUntil = "budgetStatus.validUntil"
        static let insightReviewCount = "budgetStatus.insight.reviewCount"
        static let insightAllowanceCount = "budgetStatus.insight.allowanceCount"
        static let insightAllowancePercent = "budgetStatus.insight.allowancePercent"
        static let insightCommitmentCount = "budgetStatus.insight.commitmentCount"
        static let insightNextCommitment = "budgetStatus.insight.nextCommitment"
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

    init(defaults: UserDefaults? = UserDefaults(
        suiteName: BudgetWidgetSnapshotStore.appGroupIdentifier
    )) {
        self.defaults = defaults
        migrateIfNeeded()
    }

    func publish(
        enabled: Bool,
        percentUsed: Int?,
        periodToken: String? = nil,
        validUntil: Date? = nil
    ) {
        guard let defaults else { return }
        migrateIfNeeded()
        defaults.set(enabled, forKey: Key.enabled)
        guard enabled else {
            defaults.set("disabled", forKey: Key.state)
            defaults.removeObject(forKey: Key.percentUsed)
            defaults.removeObject(forKey: Key.periodToken)
            defaults.removeObject(forKey: Key.validUntil)
            scrubInsightPayload(defaults)
            return
        }
        guard let periodToken,
              Self.isValidPeriodToken(periodToken),
              let validUntil,
              validUntil.timeIntervalSinceReferenceDate.isFinite else {
            defaults.set("stale", forKey: Key.state)
            defaults.removeObject(forKey: Key.percentUsed)
            defaults.removeObject(forKey: Key.periodToken)
            defaults.removeObject(forKey: Key.validUntil)
            return
        }
        defaults.set(periodToken, forKey: Key.periodToken)
        defaults.set(validUntil, forKey: Key.validUntil)
        guard let percentUsed else {
            defaults.set("needsBudget", forKey: Key.state)
            defaults.removeObject(forKey: Key.percentUsed)
            return
        }
        // Keep the UI useful under extreme imports without allowing an
        // unbounded integer to break a Lock Screen layout.
        defaults.set("available", forKey: Key.state)
        defaults.set(min(max(percentUsed, 0), 9_999), forKey: Key.percentUsed)
    }

    func read(now: Date = Date()) -> BudgetWidgetSnapshot {
        guard let defaults else { return .disabled }
        migrateIfNeeded()
        guard defaults.bool(forKey: Key.enabled) else { return .disabled }
        guard let periodToken = defaults.string(forKey: Key.periodToken),
              Self.isValidPeriodToken(periodToken),
              let validUntil = defaults.object(forKey: Key.validUntil) as? Date,
              validUntil.timeIntervalSinceReferenceDate.isFinite,
              now < validUntil else {
            scrubExpiredSnapshot(defaults)
            return .stale
        }
        switch defaults.string(forKey: Key.state) {
        case "available":
            guard let stored = defaults.object(forKey: Key.percentUsed)
                as? NSNumber else {
                scrubExpiredSnapshot(defaults)
                return .stale
            }
            let decimal = stored.decimalValue
            let clamped = min(max(decimal, .zero), Decimal(9_999))
            return .available(
                percentUsed: NSDecimalNumber(decimal: clamped).intValue,
                validUntil: validUntil
            )
        case "needsBudget":
            defaults.removeObject(forKey: Key.percentUsed)
            return .needsBudget(validUntil: validUntil)
        default:
            scrubExpiredSnapshot(defaults)
            return .stale
        }
    }

    func publishInsights(
        enabled: Bool,
        reviewCount: Int = 0,
        activeAllowanceCount: Int = 0,
        allowancePercentRemaining: Int? = nil,
        activeCommitmentCount: Int = 0,
        nextCommitment: Date? = nil,
        validUntil: Date? = nil
    ) {
        guard let defaults else { return }
        guard enabled,
              let validUntil,
              validUntil.timeIntervalSinceReferenceDate.isFinite else {
            scrubInsightPayload(defaults)
            return
        }
        defaults.set(min(max(reviewCount, 0), 9_999), forKey: Key.insightReviewCount)
        defaults.set(
            min(max(activeAllowanceCount, 0), 9_999),
            forKey: Key.insightAllowanceCount
        )
        defaults.set(
            min(max(activeCommitmentCount, 0), 9_999),
            forKey: Key.insightCommitmentCount
        )
        if let allowancePercentRemaining {
            defaults.set(
                min(max(allowancePercentRemaining, 0), 100),
                forKey: Key.insightAllowancePercent
            )
        } else {
            defaults.removeObject(forKey: Key.insightAllowancePercent)
        }
        if let nextCommitment,
           nextCommitment.timeIntervalSinceReferenceDate.isFinite {
            defaults.set(nextCommitment, forKey: Key.insightNextCommitment)
        } else {
            defaults.removeObject(forKey: Key.insightNextCommitment)
        }
        defaults.set(validUntil, forKey: Key.insightValidUntil)
    }

    func readInsights(now: Date = Date()) -> MoneyUpWidgetInsights? {
        guard let defaults,
              defaults.bool(forKey: Key.enabled),
              let validUntil = defaults.object(forKey: Key.insightValidUntil) as? Date,
              validUntil.timeIntervalSinceReferenceDate.isFinite,
              now < validUntil else { return nil }
        let allowancePercent = (defaults.object(forKey: Key.insightAllowancePercent)
            as? NSNumber)?.intValue
        return MoneyUpWidgetInsights(
            reviewCount: max(defaults.integer(forKey: Key.insightReviewCount), 0),
            activeAllowanceCount: max(
                defaults.integer(forKey: Key.insightAllowanceCount),
                0
            ),
            allowancePercentRemaining: allowancePercent.map { min(max($0, 0), 100) },
            activeCommitmentCount: max(
                defaults.integer(forKey: Key.insightCommitmentCount),
                0
            ),
            nextCommitment: defaults.object(forKey: Key.insightNextCommitment) as? Date,
            validUntil: validUntil
        )
    }

    func migrateIfNeeded() {
        guard let defaults else { return }
        for key in Self.forbiddenLegacyKeys {
            defaults.removeObject(forKey: key)
        }
        let storedVersion = defaults.integer(forKey: Key.schemaVersion)
        if storedVersion > Self.currentSchemaVersion {
            // A newer writer may have changed the meaning or sensitivity of
            // every key. Do not interpret it with this older reader.
            scrubAllWidgetPayload(defaults)
            defaults.set(false, forKey: Key.enabled)
            defaults.set("disabled", forKey: Key.state)
            defaults.set(Self.currentSchemaVersion, forKey: Key.schemaVersion)
            return
        }
        guard storedVersion < Self.currentSchemaVersion else {
            return
        }
        if storedVersion == 2 {
            // Version 2 already bounded the budget status by reporting period.
            // Keep that safe opt-in while clearing any unreviewed insight keys;
            // the authenticated app will publish the new record-free summary.
            scrubInsightPayload(defaults)
            defaults.set(Self.currentSchemaVersion, forKey: Key.schemaVersion)
            return
        }
        if storedVersion == 1, defaults.bool(forKey: Key.enabled) {
            // Version 1 carried no reporting-period boundary. Preserve the
            // user's opt-in, but never display its possibly prior-month value.
            defaults.set(true, forKey: Key.enabled)
            defaults.set("stale", forKey: Key.state)
        } else {
            // Prototype/version-zero payloads are not trusted as an opt-in.
            defaults.set(false, forKey: Key.enabled)
            defaults.set("disabled", forKey: Key.state)
        }
        defaults.removeObject(forKey: Key.percentUsed)
        defaults.removeObject(forKey: Key.periodToken)
        defaults.removeObject(forKey: Key.validUntil)
        defaults.set(Self.currentSchemaVersion, forKey: Key.schemaVersion)
    }

    static var allowedPersistedKeys: Set<String> {
        [
            Key.schemaVersion,
            Key.enabled,
            Key.state,
            Key.percentUsed,
            Key.periodToken,
            Key.validUntil,
            Key.insightReviewCount,
            Key.insightAllowanceCount,
            Key.insightAllowancePercent,
            Key.insightCommitmentCount,
            Key.insightNextCommitment,
            Key.insightValidUntil
        ]
    }

    static func periodToken(for date: Date, calendar: Calendar) -> String? {
        let components = calendar.dateComponents([.year, .month], from: date)
        guard let year = components.year, let month = components.month else {
            return nil
        }
        return String(format: "%04d-%02d", year, month)
    }

    private static func isValidPeriodToken(_ token: String) -> Bool {
        token.range(
            of: #"^[0-9]{4,}-((0[1-9])|(1[0-2]))$"#,
            options: .regularExpression
        ) != nil
    }

    private func scrubExpiredSnapshot(_ defaults: UserDefaults) {
        defaults.set("stale", forKey: Key.state)
        defaults.removeObject(forKey: Key.percentUsed)
    }

    private func scrubInsightPayload(_ defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("budgetStatus.insight.") {
            defaults.removeObject(forKey: key)
        }
    }

    private func scrubAllWidgetPayload(_ defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("budgetStatus.") || key.hasPrefix("widget.") {
            defaults.removeObject(forKey: key)
        }
    }
}
