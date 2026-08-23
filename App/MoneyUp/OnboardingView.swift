import MoneyUpCore
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var currencyCode = "SGD"
    @State private var accountName = ""
    @State private var accountType: FinancialAccountType = .bank
    @State private var errorMessage: String?
    @FocusState private var isNameFocused: Bool

    private let supportedCurrencies = [
        "SGD", "CNY", "USD", "EUR", "GBP", "JPY", "HKD", "AUD", "CAD"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("onboarding.local_only", systemImage: "iphone.and.arrow.forward")
                    Label("onboarding.encrypted", systemImage: "lock.shield")
                    Label("onboarding.no_account", systemImage: "person.crop.circle.badge.xmark")
                } header: {
                    Text("onboarding.privacy_title")
                } footer: {
                    Text("onboarding.privacy_detail")
                }

                Section("onboarding.currency_title") {
                    Picker("onboarding.base_currency", selection: $currencyCode) {
                        ForEach(supportedCurrencies, id: \.self) { code in
                            Text(code).tag(code)
                        }
                    }
                }

                Section("onboarding.first_account") {
                    TextField("account.name", text: $accountName)
                        .textContentType(.organizationName)
                        .focused($isNameFocused)
                    Picker("account.type", selection: $accountType) {
                        ForEach(FinancialAccountType.allCases, id: \.self) { type in
                            Text(type.localizedTitle).tag(type)
                        }
                    }
                } footer: {
                    Text("onboarding.account_detail")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await completeOnboarding() }
                    } label: {
                        HStack {
                            Spacer()
                            if model.isWorking {
                                ProgressView()
                            } else {
                                Text("onboarding.start")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("onboarding.title")
            .onAppear { isNameFocused = true }
        }
    }

    private func completeOnboarding() async {
        errorMessage = nil
        do {
            try await model.completeOnboarding(
                baseCurrencyCode: currencyCode,
                accountName: accountName,
                accountType: accountType
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
