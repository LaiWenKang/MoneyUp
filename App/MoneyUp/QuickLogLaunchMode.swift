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

    init(_ action: MoneyUpQuickAction) {
        switch action {
        case .expense:
            self = .expense
        case .income:
            self = .income
        case .transfer:
            self = .transfer
        case .refund:
            self = .refund
        case .smartEntry:
            self = .smartEntry
        case .scanReceipt:
            self = .scanReceipt
        }
    }
}

/// One process-local delivery from a platform action or deep link into Log.
/// The generation binds the request to the current logical book, while the
/// monotonic identifier keeps identical consecutive actions distinct.
struct QuickLogRouteRequest: Equatable, Identifiable, Sendable {
    let id: UInt64
    let generation: UInt64
    let mode: QuickLogLaunchMode
}
