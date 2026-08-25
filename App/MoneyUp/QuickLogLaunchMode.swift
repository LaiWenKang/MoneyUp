enum QuickLogLaunchMode: String, Equatable, Sendable {
    case expense
    case income
    case transfer
    case smartEntry = "smart-entry"
    case scanReceipt = "scan-receipt"

    var kind: QuickLogKind {
        switch self {
        case .income: .income
        case .transfer: .transfer
        case .expense, .smartEntry, .scanReceipt: .expense
        }
    }
}
