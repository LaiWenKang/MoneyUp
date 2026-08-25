enum QuickLogLaunchMode: String, Equatable, Sendable {
    case expense
    case income
    case transfer
    case refund
    case smartEntry = "smart-entry"
    case scanReceipt = "scan-receipt"

    var kind: QuickLogKind {
        switch self {
        case .income: .income
        case .transfer: .transfer
        case .refund: .refund
        case .expense, .smartEntry, .scanReceipt: .expense
        }
    }
}
