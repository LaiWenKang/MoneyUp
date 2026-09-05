import Foundation
import MoneyUpCore
import SwiftUI

enum SupportedCurrencies {
    /// The complete ISO catalog supplied by Foundation plus MoneyUp's supported
    /// digital assets. Every value is validated through the domain type before
    /// it can appear as a selectable row.
    static let codes: [String] = validatedCodes(
        Locale.Currency.isoCurrencies.map(\.identifier) + ["BTC", "ETH"]
    )

    static var regionalDefault: String {
        let candidate = Locale.current.currency?.identifier.uppercased()
        return candidate.flatMap { codes.contains($0) ? $0 : nil } ?? "SGD"
    }

    static func searchableCodes(
        query: String,
        existing: [CurrencyCode] = [],
        locale: Locale = .current
    ) -> [String] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return validatedCodes(codes + existing.map(\.value)).filter { code in
            normalized.isEmpty
                || code.localizedStandardContains(normalized)
                || localizedName(for: code, locale: locale)?
                    .localizedStandardContains(normalized) == true
        }
    }

    static func localizedName(
        for code: String,
        locale: Locale = .current
    ) -> String? {
        locale.localizedString(forCurrencyCode: code)
    }

    static func isSelectable(
        _ code: String,
        existing: [CurrencyCode] = []
    ) -> Bool {
        guard let validated = try? CurrencyCode(code) else { return false }
        return codes.contains(validated.value)
            || existing.contains(validated)
    }

    private static func validatedCodes(_ candidates: [String]) -> [String] {
        Set(candidates.compactMap { (try? CurrencyCode($0))?.value }).sorted()
    }
}

/// The single, non-free-text currency control used across setup and asset
/// workflows. A user can search, but can only commit a validated catalog item.
struct SearchableCurrencyPicker: View {
    let title: LocalizedStringKey
    @Binding var selection: String
    var existing: [CurrencyCode] = []
    var compact = false

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            if compact {
                HStack(spacing: 4) {
                    Text(selection).font(.subheadline.monospaced().weight(.semibold))
                    Image(systemName: "chevron.down").font(.caption2).accessibilityHidden(true)
                }
                .frame(minHeight: 44)
            } else {
                LabeledContent {
                    Text(selection).monospaced().foregroundStyle(.primary)
                } label: { Text(title) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(selection))
        .sheet(isPresented: $isPresented) {
            CurrencySelectionSheet(
                title: title,
                selection: $selection,
                existing: existing
            )
        }
    }
}

private struct CurrencySelectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: LocalizedStringKey
    @Binding var selection: String
    let existing: [CurrencyCode]
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(SupportedCurrencies.searchableCodes(query: query, existing: existing), id: \.self) { code in
                Button {
                    guard SupportedCurrencies.isSelectable(
                        code,
                        existing: existing
                    ) else { return }
                    selection = code
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(code).monospaced()
                            if let name = SupportedCurrencies.localizedName(for: code) {
                                Text(name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if code == selection {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .moneyUpAccessibilitySelected(code == selection)
            }
            .searchable(text: $query, prompt: "currency.search")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func moneyUpAccessibilitySelected(_ isSelected: Bool) -> some View {
        if isSelected {
            accessibilityAddTraits(.isSelected)
        } else {
            self
        }
    }
}
