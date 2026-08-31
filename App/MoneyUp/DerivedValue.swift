import Foundation
import MoneyUpCore
import OSLog
import SwiftUI

enum DerivedValue<Value> {
    case available(Value)
    case unavailable(DerivedValueIssue)

    var value: Value? {
        guard case let .available(value) = self else { return nil }
        return value
    }
}

enum DerivedValueIssue: String, Equatable, Error, Identifiable, Sendable {
    case appNotReady = "DV-001"
    case invalidPeriod = "DV-002"
    case ledgerCalculationFailed = "DV-003"
    case budgetCalculationFailed = "DV-004"
    case amountCalculationFailed = "DV-005"
    case holdingValuationFailed = "DV-006"
    case missingCurrency = "DV-007"
    case goalCalculationFailed = "DV-008"

    var id: String { rawValue }

    var errorDescription: String? {
        switch self {
        case .appNotReady:
            AppLocalization.string("derived.reason.app_not_ready")
        case .invalidPeriod:
            AppLocalization.string("derived.reason.invalid_period")
        case .ledgerCalculationFailed:
            AppLocalization.string("derived.reason.ledger")
        case .budgetCalculationFailed:
            AppLocalization.string("derived.reason.budget")
        case .amountCalculationFailed:
            AppLocalization.string("derived.reason.amount")
        case .holdingValuationFailed:
            AppLocalization.string("derived.reason.holding")
        case .missingCurrency:
            AppLocalization.string("derived.reason.currency")
        case .goalCalculationFailed:
            AppLocalization.string("derived.reason.goal")
        }
    }
}

extension DerivedValueIssue: LocalizedError {}

enum DerivedValueDiagnostics {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.laiwenkang.MoneyUp",
        category: "DerivedValues"
    )

    /// Only stable operation/error identifiers are logged. Payees, notes,
    /// amounts, account names, and other financial content are never included.
    static func record(
        _ issue: DerivedValueIssue,
        operation: String,
        error: Error? = nil
    ) {
        let errorType = error.map { String(reflecting: type(of: $0)) } ?? "none"
        logger.error(
            "Unavailable derived value code=\(issue.rawValue, privacy: .public) operation=\(operation, privacy: .public) errorType=\(errorType, privacy: .public)"
        )
    }
}

extension DerivedValue where Value == Money {
    static func money(
        _ amount: Decimal,
        currency: CurrencyCode,
        operation: String
    ) -> DerivedValue<Money> {
        do {
            return .available(try Money(amount, currency: currency))
        } catch {
            DerivedValueDiagnostics.record(
                .amountCalculationFailed,
                operation: operation,
                error: error
            )
            return .unavailable(.amountCalculationFailed)
        }
    }
}

/// A consistent honest fallback for financial calculations. The alert exposes
/// only a stable diagnostic code, giving support something actionable without
/// copying financial content into diagnostics.
struct DerivedValueUnavailableView: View {
    let issue: DerivedValueIssue
    var prominent = false

    @State private var isShowingDiagnostic = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("—")
                .font(prominent ? .largeTitle.bold() : .headline)
                .monospacedDigit()

            Text(issue.localizedDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button("derived.show_diagnostic") {
                isShowingDiagnostic = true
            }
            .font(.footnote)
        }
        .alert("derived.unavailable_title", isPresented: $isShowingDiagnostic) {
            Button("action.okay", role: .cancel) {}
        } message: {
            Text(
                String(
                    format: AppLocalization.string("derived.diagnostic_format"),
                    issue.rawValue
                )
            )
        }
    }
}
