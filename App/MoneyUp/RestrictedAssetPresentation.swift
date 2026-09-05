import MoneyUpCore
import SwiftUI

enum AssetAccountRowPresentation {
    /// Restricted accounts need a visible textual classification. The symbol
    /// is decorative and cannot carry this material financial distinction.
    static func visibleAccountTypeKey(for account: LedgerAccount) -> String? {
        account.accountType == .restrictedAllowance
            ? "account.type.restricted_allowance" : nil
    }
}

struct RestrictedAccountTypeLabel: View {
    let account: LedgerAccount

    @ViewBuilder
    var body: some View {
        if let key = AssetAccountRowPresentation.visibleAccountTypeKey(
            for: account
        ) {
            Text(LocalizedStringKey(key))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

struct RestrictedStoredValueSummary: View {
    let result: DerivedValue<[Money]>

    var body: some View {
        switch result {
        case let .available(amounts):
            if !amounts.isEmpty {
                Divider().padding(.vertical, 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text("assets.restricted_stored_value")
                        .font(.subheadline.weight(.semibold))
                    ForEach(amounts, id: \.currency) { amount in
                        Text(formattedMoney(amount))
                            .font(.headline.monospacedDigit())
                    }
                    Text("assets.restricted_stored_value_note")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        case let .unavailable(issue):
            Divider().padding(.vertical, 3)
            VStack(alignment: .leading, spacing: 3) {
                Text("assets.restricted_stored_value")
                    .font(.subheadline.weight(.semibold))
                DerivedValueUnavailableView(issue: issue)
            }
        }
    }
}
