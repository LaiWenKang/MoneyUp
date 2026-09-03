import Foundation
import MoneyUpCore

extension TransactionSplitError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .tooFewLines:
            AppLocalization.string("split.error.too_few")
        case .nonPositiveAmount:
            AppLocalization.string("split.error.positive")
        case .currencyMismatch:
            AppLocalization.string("split.error.currency")
        case .totalMismatch:
            AppLocalization.string("split.error.balance")
        case .invalidAllocation:
            AppLocalization.string("split.error.allocation")
        }
    }
}

extension ReceiptAttachmentError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyData: AppLocalization.string("receipt.error.empty")
        case .tooLarge: AppLocalization.string("receipt.error.too_large")
        case .invalidMetadata: AppLocalization.string("receipt.error.empty")
        }
    }
}

extension ExchangeRateError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .identicalCurrencies: AppLocalization.string("fx.error.identical")
        case .invalidRate: AppLocalization.string("fx.error.invalid_rate")
        case .invalidEffectiveDate: AppLocalization.string("fx.error.invalid_date")
        case .originContextMismatch: AppLocalization.string("fx.error.invalid_date")
        case .conversionOutOfRange: AppLocalization.string("fx.error.conversion_out_of_range")
        case .conversionUnderflow: AppLocalization.string("fx.error.conversion_underflow")
        }
    }
}
