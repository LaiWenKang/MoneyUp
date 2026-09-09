import Foundation
import MoneyUpCore

enum QuickLogSmartField: String, Codable, CaseIterable, Sendable {
    case kind, amount, receivedAmount, account, destination, category, date, payee, note, splits

    static func field(for path: PartialKeyPath<QuickLogDraft>) -> Self? {
        switch path {
        case \QuickLogDraft.kind: .kind
        case \QuickLogDraft.amountText: .amount
        case \QuickLogDraft.destinationAmountText: .receivedAmount
        case \QuickLogDraft.accountID: .account
        case \QuickLogDraft.destinationAccountID: .destination
        case \QuickLogDraft.categoryID: .category
        case \QuickLogDraft.occurredAt: .date
        case \QuickLogDraft.payee: .payee
        case \QuickLogDraft.note: .note
        case \QuickLogDraft.splitLines: .splits
        default: nil
        }
    }
}

struct QuickLogSmartState: Codable, Equatable, Sendable {
    var referenceDate: Date?
    var hasPreview = false
    var issues: [SmartEntryIssue] = []
    var automaticFields: Set<QuickLogSmartField> = []
    var manualFields: Set<QuickLogSmartField> = []

    mutating func edited(_ field: QuickLogSmartField) {
        manualFields.insert(field)
        automaticFields.remove(field)
        let resolved: Set<SmartEntryIssue> = switch field {
        case .kind: [.kind]
        case .amount: [.amount, .currency]
        case .receivedAmount: [.receivedAmount, .currency]
        case .account: [.account, .currency]
        case .destination: [.destination, .currency]
        case .category: [.category]
        case .date: [.date]
        case .splits: [.split, .category]
        case .payee, .note: []
        }
        issues.removeAll { resolved.contains($0) }
    }
}

struct QuickLogClearRecovery: Codable, Equatable, Sendable {
    static let maximumBytes = 262_144
    let draftData: Data

    init(draft: QuickLogDraft) throws {
        var original = draft
        original.clearRecovery = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        draftData = try encoder.encode(original)
        guard draftData.count <= Self.maximumBytes else { throw AppModelError.invalidBook }
    }

    func restoredDraft() throws -> QuickLogDraft {
        guard draftData.count <= Self.maximumBytes else { throw AppModelError.invalidBook }
        let draft = try JSONDecoder().decode(QuickLogDraft.self, from: draftData)
        guard draft.clearRecovery == nil else { throw AppModelError.invalidBook }
        return draft
    }
}

/// One serialized worker chain. Cancellation retires authority immediately,
/// even when an underlying synchronous reader cannot stop at that instant.
@MainActor
final class QuickLogParseCoordinator {
    private var generation: UInt64 = 0
    private var task: Task<SmartEntryInterpretation?, Never>?

    func cancel() {
        generation &+= 1
        task?.cancel()
    }

    func resolve(_ operation: @escaping @Sendable () async -> SmartEntryInterpretation) async -> SmartEntryInterpretation? {
        cancel()
        let request = generation
        let previous = task
        let worker = Task.detached(priority: .userInitiated) {
            _ = await previous?.value
            guard !Task.isCancelled else { return Optional<SmartEntryInterpretation>.none }
            let result = await operation()
            return Task.isCancelled ? nil : result
        }
        task = worker
        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: { worker.cancel() }
        guard generation == request, !Task.isCancelled else { return nil }
        task = nil
        return result
    }
}
