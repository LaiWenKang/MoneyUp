import SwiftUI
import MoneyUpCore

enum MoneyUpIllustrationRole {
    case onboarding
    case hero
    case empty
    case inline

    var height: CGFloat {
        switch self {
        case .onboarding: 148
        case .hero: 92
        case .empty: 116
        case .inline: 72
        }
    }

    var maximumWidth: CGFloat {
        switch self {
        case .onboarding: 240
        case .hero: 116
        case .empty: 190
        case .inline: 90
        }
    }
}

/// Generated 3D artwork is decorative only. Financial quantities remain in
/// native text and flat, measurable 2D graphics elsewhere in the interface.
/// Role-based sizing prevents decorative art from consuming the space needed
/// for the screen's decision and primary action.
struct MoneyUpIllustration: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let assetName: String
    let role: MoneyUpIllustrationRole

    init(_ assetName: String, role: MoneyUpIllustrationRole = .empty) {
        self.assetName = assetName
        self.role = role
    }

    @ViewBuilder
    var body: some View {
        if !(dynamicTypeSize.isAccessibilitySize && role == .inline) {
            Image(assetName)
                .resizable()
                .scaledToFit()
                .frame(
                    maxWidth: role.maximumWidth,
                    maxHeight: dynamicTypeSize.isAccessibilitySize
                        ? min(role.height, 84)
                        : role.height
                )
                .accessibilityHidden(true)
        }
    }
}

/// Spending versus limit with the elapsed-month marker used across Today,
/// Plan, and the simulator. Overspend gets a warning glyph as well as color.
struct MoneyUpPaceBar: View {
    let ratio: Double
    let elapsed: Double

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let clampedRatio = min(max(ratio, 0), 1)
            let clampedElapsed = min(max(elapsed, 0), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.tertiarySystemFill))

                Capsule()
                    .fill(ratio > 1 ? Color.red : Color.accentColor)
                    .frame(width: width * clampedRatio)

                Rectangle()
                    .fill(Color.primary.opacity(0.60))
                    .frame(width: 2, height: 14)
                    .offset(x: width * clampedElapsed - 1)

                if ratio > 1 {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                        .frame(width: 16, height: 16)
                        .background(Color.moneyUpSurfaceElevated, in: Circle())
                        .offset(x: max(0, width - 16))
                }
            }
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }
}

struct MoneyUpPositionDiagram: View {
    let cashAmount: Decimal
    let debtAmount: Decimal

    private var scale: Decimal {
        max(max(abs(cashAmount), abs(debtAmount)), 1)
    }

    var body: some View {
        VStack(spacing: 10) {
            positionBar(
                amount: cashAmount,
                symbol: "banknote.fill",
                color: .accentColor
            )
            positionBar(
                amount: debtAmount,
                symbol: "creditcard.fill",
                color: .orange
            )
        }
        .accessibilityHidden(true)
    }

    private func positionBar(
        amount: Decimal,
        symbol: String,
        color: Color
    ) -> some View {
        let fraction: DerivedValue<Double>
        do {
            fraction = .available(
                NSDecimalNumber(
                    decimal: try CheckedDecimal.ratio(abs(amount), scale)
                ).doubleValue
            )
        } catch {
            DerivedValueDiagnostics.record(
                .amountCalculationFailed,
                operation: "position-diagram-ratio",
                error: error
            )
            fraction = .unavailable(.amountCalculationFailed)
        }

        return HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 24)

            switch fraction {
            case let .available(value):
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color(.tertiarySystemFill))
                        Capsule()
                            .fill(color.opacity(0.78))
                            .frame(width: proxy.size.width * min(max(value, 0), 1))
                    }
                }
                .frame(height: 10)
            case let .unavailable(issue):
                DerivedValueUnavailableView(issue: issue)
            }
        }
    }
}

struct MoneyUpSymbolBadge: View {
    let systemImage: String
    var color: Color = .accentColor

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(color.opacity(0.12))
            Circle()
                .stroke(color.opacity(0.22), lineWidth: 1)
                .padding(7)
            Image(systemName: systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(color)
        }
        .frame(width: 44, height: 44)
        .accessibilityHidden(true)
    }
}
