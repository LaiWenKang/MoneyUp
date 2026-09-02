import AppIntents
import Foundation
import Observation
import SwiftUI

/// The complete, data-free set of routes exposed outside the app.
///
/// Raw values are persisted by existing widget configurations. Keep them
/// stable even though the two multiword URL path components use hyphens.
enum MoneyUpQuickAction: String, AppEnum, CaseIterable, Identifiable, Sendable {
    case expense = "expense"
    case income = "income"
    case transfer = "transfer"
    case refund = "refund"
    case smartEntry = "smartEntry"
    case scanReceipt = "scanReceipt"

    static let typeDisplayRepresentation: TypeDisplayRepresentation =
        "platform_action.type"

    static let caseDisplayRepresentations: [MoneyUpQuickAction: DisplayRepresentation] = [
        .expense: "platform_action.expense",
        .income: "platform_action.income",
        .transfer: "platform_action.transfer",
        .refund: "platform_action.refund",
        .smartEntry: "platform_action.smart_entry",
        .scanReceipt: "platform_action.scan_receipt"
    ]

    var id: String { rawValue }

    /// Exhaustive literal mappings make the external route an allowlist. No
    /// caller can append a query, fragment, identifier, or user-authored text.
    var deepLink: URL {
        switch self {
        case .expense:
            URL(string: "moneyup://quick-log/expense")!
        case .income:
            URL(string: "moneyup://quick-log/income")!
        case .transfer:
            URL(string: "moneyup://quick-log/transfer")!
        case .refund:
            URL(string: "moneyup://quick-log/refund")!
        case .smartEntry:
            URL(string: "moneyup://quick-log/smart-entry")!
        case .scanReceipt:
            URL(string: "moneyup://quick-log/scan-receipt")!
        }
    }

    /// Accepts only the six canonical external spellings byte for byte.
    /// Foundation URL component normalization is intentionally not used here:
    /// case variants, escapes, credentials, ports, suffixes, queries, and
    /// fragments must all fail closed before an action reaches the broker.
    init?(exactDeepLink url: URL) {
        guard url.baseURL == nil else { return nil }
        let literal = url.relativeString
        guard literal == url.absoluteString else { return nil }
        guard let action = Self.allCases.first(where: {
            $0.deepLink.absoluteString == literal
        }) else {
            return nil
        }
        self = action
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .expense:
            "platform_action.expense"
        case .income:
            "platform_action.income"
        case .transfer:
            "platform_action.transfer"
        case .refund:
            "platform_action.refund"
        case .smartEntry:
            "platform_action.smart_entry"
        case .scanReceipt:
            "platform_action.scan_receipt"
        }
    }

    var systemImage: String {
        switch self {
        case .expense:
            "arrow.up.right"
        case .income:
            "arrow.down.left"
        case .transfer:
            "arrow.left.arrow.right"
        case .refund:
            "arrow.uturn.backward.circle"
        case .smartEntry:
            "sparkles"
        case .scanReceipt:
            "doc.text.viewfinder"
        }
    }

    var requiresUnlock: Bool {
        self == .smartEntry || self == .scanReceipt
    }

    var accessibilityHintKey: LocalizedStringKey {
        requiresUnlock
            ? "platform_action.unlock_required"
            : "platform_action.capture_without_unlock"
    }

    static func mediumActions(
        preferred: MoneyUpQuickAction
    ) -> [MoneyUpQuickAction] {
        let fallback: [MoneyUpQuickAction] = [
            .expense,
            .income,
            .transfer,
            .refund,
            .scanReceipt,
            .smartEntry
        ]
        return [preferred] + Array(fallback.filter { $0 != preferred }.prefix(3))
    }
}

/// A bounded, process-local FIFO handoff from App Intents to the app.
/// It deliberately stores only the closed action enum and never persists it.
@MainActor
@Observable
final class MoneyUpQuickActionRouteBroker {
    static let shared = MoneyUpQuickActionRouteBroker()
    static let maximumPendingActionCount = 16

    private var pendingActions: [MoneyUpQuickAction] = []
    private var nextBoundaryEpoch: UInt64 = 0
    private var activeBoundaryEpochs: Set<UInt64> = []
    private(set) var revision: UInt64 = 0
    private(set) var handoffGeneration: UInt64 = 0

    var pendingAction: MoneyUpQuickAction? { pendingActions.first }
    var pendingCount: Int { pendingActions.count }
    var isAuthoritativeBoundaryActive: Bool {
        !activeBoundaryEpochs.isEmpty
    }

    /// Preserve accepted FIFO work at capacity. The newest invocation is
    /// rejected in memory instead of evicting or reordering an older action.
    /// Advancing the observation revision still wakes the app so it can route
    /// accepted work or synchronously discard it if erase authority changed.
    @discardableResult
    func submit(_ action: MoneyUpQuickAction) -> Bool {
        guard !isAuthoritativeBoundaryActive else { return false }
        guard pendingActions.count < Self.maximumPendingActionCount else {
            revision &+= 1
            return false
        }
        pendingActions.append(action)
        revision &+= 1
        return true
    }

    func takePendingAction() -> MoneyUpQuickAction? {
        guard !isAuthoritativeBoundaryActive,
              !pendingActions.isEmpty else { return nil }
        let action = pendingActions.removeFirst()
        revision &+= 1
        return action
    }

    /// An authoritative erase or book-replacement boundary invalidates every
    /// action accepted for the previous book. This remains process-local.
    func discardAllPendingActions() {
        guard !pendingActions.isEmpty else { return }
        pendingActions.removeAll(keepingCapacity: false)
        revision &+= 1
    }

    /// Starts a process-local book boundary before any asynchronous lifecycle
    /// work. Every old-book action is synchronously invalidated.
    @discardableResult
    func beginAuthoritativeBoundary() -> UInt64 {
        nextBoundaryEpoch &+= 1
        let epoch = nextBoundaryEpoch
        activeBoundaryEpochs.insert(epoch)
        handoffGeneration &+= 1
        pendingActions.removeAll(keepingCapacity: false)
        revision &+= 1
        return epoch
    }

    /// Tokens make overlapping boundaries fail closed: ending one lifecycle
    /// cannot accidentally reopen submissions while another remains active.
    func endAuthoritativeBoundary(_ epoch: UInt64) {
        guard activeBoundaryEpochs.remove(epoch) != nil else { return }
        revision &+= 1
    }
}

/// Opens the app and hands off one allowlisted action in memory. The action
/// enum is the intent's only input; there is no dialog, result payload, or
/// persistence at this boundary.
struct OpenQuickLogIntent: AppIntent {
    static let title: LocalizedStringResource = "platform_intent.open_quick_log.title"
    static let description = IntentDescription(
        "platform_intent.open_quick_log.description"
    )
    @available(iOS, obsoleted: 26.0, message: "Replaced by supportedModes")
    static var openAppWhenRun: Bool { true }

#if compiler(>=6.2)
    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = [.foreground(.immediate)]
#endif

    @Parameter(title: "platform_intent.open_quick_log.action", default: .expense)
    var action: MoneyUpQuickAction

    init() {
        action = .expense
    }

    init(action: MoneyUpQuickAction) {
        self.action = action
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        MoneyUpQuickActionRouteBroker.shared.submit(action)
        return .result()
    }
}

// Keep the configuration conformance with the intent in both the app and
// widget-extension targets so the system can resolve it on every surface.
extension OpenQuickLogIntent: ControlConfigurationIntent {}
