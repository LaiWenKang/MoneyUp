import MoneyUpCore
import SwiftUI

struct OnboardingView: View {
    private enum Step: Int, CaseIterable {
        case welcome
        case currency
        case account
        case review

        var number: Int { rawValue + 1 }

        var title: LocalizedStringKey {
            switch self {
            case .welcome: "onboarding.welcome_title"
            case .currency: "onboarding.currency_step_title"
            case .account: "onboarding.account_step_title"
            case .review: "onboarding.review_title"
            }
        }
    }

    private enum FocusedField: Hashable {
        case accountName
        case openingBalance
    }

    @EnvironmentObject private var model: AppModel
    @State private var step: Step = .welcome
    @State private var currencyCode = "SGD"
    @State private var accountName = ""
    @State private var accountType: FinancialAccountType = .bank
    @State private var startingBalanceText = ""
    @State private var showsAccountErrors = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: FocusedField?

    private var startingBalance: Decimal? {
        parsedOpeningBalance(from: startingBalanceText, accountType: accountType)
    }

    private var normalizedAccountName: String {
        accountName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var openingBalanceSummary: String {
        guard let startingBalance,
              let currency = try? CurrencyCode(currencyCode),
              let money = try? Money(startingBalance, currency: currency) else {
            return String(localized: "onboarding.not_set")
        }
        return formattedMoney(money)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                MoneyUpBackdrop()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        progressHeader
                        stepContent
                    }
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .safeAreaInset(edge: .bottom) {
                navigationBar
            }
            .navigationBarHidden(true)
            .onChange(of: accountType) { _, _ in
                errorMessage = nil
            }
        }
    }

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(
                    String(
                        format: String(localized: "onboarding.step_progress"),
                        step.number,
                        Step.allCases.count
                    )
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

                Spacer()

                Text(step.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
            }

            ProgressView(value: Double(step.number), total: Double(Step.allCases.count))
                .tint(.accentColor)
                .accessibilityLabel("onboarding.progress_accessibility")
                .accessibilityValue(
                    String(
                        format: String(localized: "onboarding.step_progress"),
                        step.number,
                        Step.allCases.count
                    )
                )
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:
            welcomeStep
        case .currency:
            currencyStep
        case .account:
            accountStep
        case .review:
            reviewStep
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 18) {
            MoneyUpGrowthMark()
                .frame(width: 104, height: 104)
                .padding(16)
                .background(Color.moneyUpSurface)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

            VStack(spacing: 8) {
                Text("onboarding.welcome_eyebrow")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
                Text("onboarding.welcome_title")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text("onboarding.welcome_detail")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            MoneyUpCard {
                VStack(alignment: .leading, spacing: 16) {
                    onboardingFeature(
                        icon: "person.crop.circle.badge.xmark",
                        title: "onboarding.no_signup_title",
                        detail: "onboarding.no_signup_detail"
                    )
                    onboardingFeature(
                        icon: "lock.shield.fill",
                        title: "onboarding.encrypted_title",
                        detail: "onboarding.encrypted_detail"
                    )
                    onboardingFeature(
                        icon: "arrow.triangle.2.circlepath",
                        title: "onboarding.recovery_title",
                        detail: "onboarding.recovery_detail"
                    )
                }
            }
        }
    }

    private var currencyStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepIntroduction(
                icon: "dollarsign.arrow.circlepath",
                title: "onboarding.currency_step_title",
                detail: "onboarding.currency_step_detail"
            )

            MoneyUpCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text("onboarding.base_currency")
                        .font(.headline)

                    Picker("onboarding.base_currency", selection: $currencyCode) {
                        ForEach(SupportedCurrencies.codes, id: \.self) { code in
                            Text(code).tag(code)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.accentColor)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Divider()

                    Label {
                        Text("onboarding.currency_no_conversion")
                    } icon: {
                        Image(systemName: "equal.circle.fill")
                            .foregroundStyle(.tint)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var accountStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepIntroduction(
                icon: "wallet.bifold.fill",
                title: "onboarding.account_step_title",
                detail: "onboarding.account_step_detail"
            )

            MoneyUpCard {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("account.name")
                            .font(.headline)
                        TextField("onboarding.account_name_example", text: $accountName)
                            .textContentType(.organizationName)
                            .focused($focusedField, equals: .accountName)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .openingBalance }

                        if showsAccountErrors && normalizedAccountName.isEmpty {
                            validationMessage("onboarding.account_name_error")
                        }
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("account.type")
                            .font(.headline)
                        Picker("account.type", selection: $accountType) {
                            ForEach(FinancialAccountType.allCases, id: \.self) { type in
                                Label(type.localizedTitle, systemImage: type.systemImage)
                                    .tag(type)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.accentColor)
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text(accountType.openingBalanceLabel)
                            .font(.headline)
                        TextField(accountType.openingBalanceLabel, text: $startingBalanceText)
                            .keyboardType(.numbersAndPunctuation)
                            .focused($focusedField, equals: .openingBalance)
                            .textFieldStyle(.roundedBorder)
                        Text(accountType.openingBalanceGuidance)
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        if showsAccountErrors && startingBalance == nil {
                            validationMessage(
                                accountType.isLiabilityAccount
                                    ? "onboarding.amount_owed_error"
                                    : "onboarding.current_balance_error"
                            )
                        }
                    }
                }
            }
        }
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepIntroduction(
                icon: "checkmark.seal.fill",
                title: "onboarding.review_title",
                detail: "onboarding.review_detail"
            )

            MoneyUpCard {
                VStack(spacing: 0) {
                    reviewRow("onboarding.review_currency", value: currencyCode)
                    Divider().padding(.vertical, 12)
                    reviewRow("onboarding.review_account", value: normalizedAccountName)
                    Divider().padding(.vertical, 12)
                    reviewRow(
                        "onboarding.review_account_type",
                        value: String(localized: accountType.localizedResource)
                    )
                    Divider().padding(.vertical, 12)
                    reviewRow(
                        accountType.isLiabilityAccount
                            ? "onboarding.review_amount_owed"
                            : "onboarding.review_balance",
                        value: openingBalanceSummary
                    )
                }
            }

            MoneyUpCard {
                HStack(alignment: .top, spacing: 13) {
                    Image(systemName: "arrow.up.right.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("onboarding.after_setup_title")
                            .font(.headline)
                        Text("onboarding.after_setup_detail")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var navigationBar: some View {
        VStack(spacing: 10) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLiveRegion(.assertive)
            }

            HStack(spacing: 12) {
                if step != .welcome {
                    Button("action.back") {
                        moveBack()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(model.isWorking)
                }

                Button {
                    advance()
                } label: {
                    HStack {
                        if model.isWorking {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(primaryActionTitle)
                            .fontWeight(.semibold)
                        if !model.isWorking && step != .review {
                            Image(systemName: "arrow.right")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.moneyUpAction)
                .disabled(model.isWorking)
            }
            .frame(maxWidth: 560)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(Color.moneyUpSurfaceElevated)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var primaryActionTitle: LocalizedStringKey {
        switch step {
        case .welcome: "onboarding.begin_setup"
        case .currency, .account: "action.continue"
        case .review: "onboarding.start"
        }
    }

    private func advance() {
        errorMessage = nil
        switch step {
        case .welcome:
            step = .currency
        case .currency:
            step = .account
        case .account:
            showsAccountErrors = true
            guard !normalizedAccountName.isEmpty else {
                focusedField = .accountName
                return
            }
            guard startingBalance != nil else {
                focusedField = .openingBalance
                return
            }
            focusedField = nil
            step = .review
        case .review:
            Task { await completeOnboarding() }
        }
    }

    private func moveBack() {
        errorMessage = nil
        focusedField = nil
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    private func completeOnboarding() async {
        guard let startingBalance else {
            step = .account
            showsAccountErrors = true
            focusedField = .openingBalance
            return
        }
        do {
            try await model.completeOnboarding(
                baseCurrencyCode: currencyCode,
                accountName: normalizedAccountName,
                accountType: accountType,
                startingBalance: startingBalance
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func onboardingFeature(
        icon: String,
        title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func stepIntroduction(
        icon: String,
        title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.title.bold())
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.largeTitle.bold())
            Text(detail)
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private func validationMessage(_ key: LocalizedStringKey) -> some View {
        Label(key, systemImage: "exclamationmark.circle.fill")
            .font(.footnote)
            .foregroundStyle(.red)
            .accessibilityLiveRegion(.assertive)
    }

    private func reviewRow(_ title: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .fontWeight(.semibold)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

private extension FinancialAccountType {
    var localizedResource: String.LocalizationValue {
        switch self {
        case .cash: "account.type.cash"
        case .bank: "account.type.bank"
        case .eWallet: "account.type.e_wallet"
        case .creditCard: "account.type.credit_card"
        case .loan: "account.type.loan"
        case .brokerage: "account.type.brokerage"
        case .investment: "account.type.investment"
        case .other: "account.type.other"
        }
    }
}
