import Foundation

enum BudgetWidgetSnapshot: Equatable, Sendable {
    case disabled
    case needsBudget(validUntil: Date)
    case stale
    case available(percentUsed: Int, validUntil: Date)
}

/// The only cross-process financial derivative MoneyUp permits.
///
/// This store cannot represent an amount, account, payee, holding, or balance.
/// The protected app computes one rounded integer percentage and the widget
/// reads it. All source records remain inside SQLCipher.
final class BudgetWidgetSnapshotStore {
    static let appGroupIdentifier = "group.com.laiwenkang.MoneyUp"
    static let currentSchemaVersion = 2

    private enum Key {
        static let schemaVersion = "budgetStatus.schemaVersion"
        static let enabled = "budgetStatus.enabled"
        static let state = "budgetStatus.state"
        static let percentUsed = "budgetStatus.percentUsed"
        static let periodToken = "budgetStatus.periodToken"
        static let validUntil = "budgetStatus.validUntil"
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
            Key.validUntil
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

    private func scrubAllWidgetPayload(_ defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("budgetStatus.") || key.hasPrefix("widget.") {
            defaults.removeObject(forKey: key)
        }
    }
}
