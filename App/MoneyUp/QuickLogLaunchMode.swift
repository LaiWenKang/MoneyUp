import Foundation

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

/// One UI delivery from durable, data-free platform ingress into Log. The
/// opaque ingress token is acknowledged only after this exact request is
/// applied; the generation prevents it from crossing a logical-book boundary.
struct QuickLogRouteRequest: Equatable, Identifiable, Sendable {
    let id: UInt64
    let ingressToken: UUID
    let requiresIngressAcknowledgement: Bool
    let generation: UInt64
    let mode: QuickLogLaunchMode
}
