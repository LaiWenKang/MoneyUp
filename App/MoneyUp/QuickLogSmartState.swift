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

    /// "Several transactions" and "too long" describe the Smart Entry text: a
    /// reading refused for them fills no field, so the form holds only what
    /// the person entered and no field edit could ever clear them.
    var isRefusedReading: Bool {
        issues.contains { $0 == .multiple || $0 == .inputLimit }
    }

    /// Save waits only on issues that name a field to resolve. A refused
    /// reading names none; its notice stays while the text is unchanged.
    var blocksSave: Bool {
        !issues.isEmpty && !isRefusedReading
    }

    /// Changing the Smart Entry text retires a refused reading's notice.
    /// Issues from a reading that did fill fields stay until those fields
    /// are resolved or the text is read again.
    mutating func smartTextChanged() {
        guard isRefusedReading else { return }
        issues = []
        hasPreview = false
    }
}

struct QuickLogClearRecovery: Codable, Equatable, Sendable {
    static let maximumBytes = 262_144
    let draftData: Data

    init(draft: QuickLogDraft) throws {
        var original = draft
        original.clearRecovery = nil
        original.batch = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        draftData = try encoder.encode(original)
        guard draftData.count <= Self.maximumBytes else { throw AppModelError.invalidBook }
    }

    func restoredDraft() throws -> QuickLogDraft {
        guard draftData.count <= Self.maximumBytes else { throw AppModelError.invalidBook }
        let draft = try JSONDecoder().decode(QuickLogDraft.self, from: draftData)
        guard draft.clearRecovery == nil, draft.batch == nil else { throw AppModelError.invalidBook }
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
