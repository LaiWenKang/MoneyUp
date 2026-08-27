import Foundation
import MoneyUpCore

extension TransactionSplitError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .tooFewLines:
            String(localized: "split.error.too_few")
        case .nonPositiveAmount:
            String(localized: "split.error.positive")
        case .currencyMismatch:
            String(localized: "split.error.currency")
        case .totalMismatch:
            String(localized: "split.error.balance")
        }
    }
}

extension ReceiptAttachmentError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyData: String(localized: "receipt.error.empty")
        case .tooLarge: String(localized: "receipt.error.too_large")
        case .invalidMetadata: String(localized: "receipt.error.empty")
        }
    }
}

extension ExchangeRateError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .identicalCurrencies: String(localized: "fx.error.identical")
        case .invalidRate: String(localized: "fx.error.invalid_rate")
        case .invalidEffectiveDate: String(localized: "fx.error.invalid_date")
        case .originContextMismatch: String(localized: "fx.error.invalid_date")
        case .conversionOutOfRange: String(localized: "fx.error.conversion_out_of_range")
        case .conversionUnderflow: String(localized: "fx.error.conversion_underflow")
        }
    }
}
