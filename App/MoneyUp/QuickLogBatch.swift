import Foundation
import MoneyUpCore

struct QuickLogBatchToken: Equatable, Sendable {
    let batchID: UUID
    let itemID: UUID
    let revision: UInt64
}

/// Only item-local drafts are nested. Queue ownership never enters an item's
/// payload or its Clear recovery, preventing restored items resurrecting peers.
struct QuickLogBatchItem: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let ordinal: Int
    var draftData: Data

    init(id: UUID = UUID(), ordinal: Int, draft: QuickLogDraft) throws {
        self.id = id
        self.ordinal = ordinal
        var local = draft
        local.batch = nil
        guard local.sourceCaptureID == nil else { throw AppModelError.invalidBook }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        draftData = try encoder.encode(local)
        guard draftData.count <= QuickLogClearRecovery.maximumBytes else { throw AppModelError.invalidBook }
    }

    func draft() throws -> QuickLogDraft {
        guard !draftData.isEmpty, draftData.count <= QuickLogClearRecovery.maximumBytes else { throw AppModelError.invalidBook }
        let value = try JSONDecoder().decode(QuickLogDraft.self, from: draftData)
        guard value.batch == nil, value.sourceCaptureID == nil,
              value.occurredAt.timeIntervalSinceReferenceDate.isFinite else { throw AppModelError.invalidBook }
        return value
    }
}

struct QuickLogBatch: Codable, Equatable, Sendable {
    static let maximumStoredBytes = 1_048_576
    let id: UUID
    let totalCount: Int
    var revision: UInt64 = 0
    var selectedID: UUID
    var items: [QuickLogBatchItem]

    init(drafts: [QuickLogDraft]) throws {
        guard (2...SmartEntryBatchText.maximumEntries).contains(drafts.count) else { throw AppModelError.invalidBook }
        id = UUID()
        totalCount = drafts.count
        items = try drafts.enumerated().map { try QuickLogBatchItem(ordinal: $0.offset + 1, draft: $0.element) }
        selectedID = items[0].id
        try validate()
    }

    var token: QuickLogBatchToken { QuickLogBatchToken(batchID: id, itemID: selectedID, revision: revision) }
    var selectedIndex: Int? { items.firstIndex { $0.id == selectedID } }
    var selectedOrdinal: Int { items.first { $0.id == selectedID }?.ordinal ?? 0 }

    func validate() throws {
        guard (1...SmartEntryBatchText.maximumEntries).contains(items.count),
              (items.count...SmartEntryBatchText.maximumEntries).contains(totalCount),
              selectedIndex != nil, Set(items.map(\.id)).count == items.count,
              Set(items.map(\.ordinal)).count == items.count,
              items.allSatisfy({ (1...totalCount).contains($0.ordinal) && !$0.draftData.isEmpty
                  && $0.draftData.count <= QuickLogClearRecovery.maximumBytes }),
              items.reduce(0, { $0 + $1.draftData.count }) <= Self.maximumStoredBytes else {
            throw AppModelError.invalidBook
        }
    }

    func selectedDraft() throws -> QuickLogDraft {
        try validate()
        guard let index = selectedIndex else { throw AppModelError.invalidBook }
        var draft = try items[index].draft()
        draft.batch = self
        return draft
    }

    func selecting(_ itemID: UUID, current: QuickLogDraft) throws -> QuickLogDraft {
        var updated = try synchronizing(current)
        guard updated.items.contains(where: { $0.id == itemID }) else { throw AppModelError.missingRecord }
        updated.revision &+= 1
        updated.selectedID = itemID
        return try updated.selectedDraft()
    }

    func removingCurrent(_ current: QuickLogDraft) throws -> QuickLogDraft? {
        var updated = try synchronizing(current)
        guard let index = updated.selectedIndex else { throw AppModelError.invalidBook }
        updated.revision &+= 1
        updated.items.remove(at: index)
        guard !updated.items.isEmpty else { return nil }
        updated.selectedID = updated.items[min(index, updated.items.count - 1)].id
        return try updated.selectedDraft()
    }

    private func synchronizing(_ current: QuickLogDraft) throws -> QuickLogBatch {
        guard current.batch?.id == id, current.batch?.selectedID == selectedID,
              current.batch?.revision == revision,
              let index = selectedIndex else { throw AppModelError.transactionInProgress }
        var updated = self
        updated.items[index] = try QuickLogBatchItem(id: selectedID, ordinal: items[index].ordinal, draft: current)
        try updated.validate()
        return updated
    }
}

enum QuickLogBatchPreparation {
    static func canReplaceTextOnlyDraft(_ draft: QuickLogDraft) -> Bool {
        draft.batch == nil && draft.sourceCaptureID == nil && draft.amountText.isEmpty
            && draft.destinationAmountText.isEmpty && draft.payee.isEmpty && draft.note.isEmpty
            && draft.splitLines.isEmpty && draft.selectedAllowanceID == nil && !draft.dateWasEdited
    }

    static func prepare(_ original: QuickLogDraft, accounts: [LedgerAccount], now: Date,
                        calendar: Calendar, locale: Locale, dayFirst: Bool) throws -> QuickLogDraft {
        guard canReplaceTextOnlyDraft(original) else { throw AppModelError.transactionInProgress }
        let lines = try SmartEntryBatchText.lines(from: original.smartText, explicitlySeparate: true)
        let drafts = try lines.map { text in
            try Task.checkCancellation()
            let blank = QuickLogDraft(kind: .expense, amountText: "", destinationAmountText: "",
                accountID: original.accountID, destinationAccountID: nil, categoryID: nil,
                occurredAt: now, dateWasEdited: false, payee: "", note: "", smartText: text)
            let parsed = SmartEntryInterpreter.interpret(text, accounts: accounts, now: now,
                calendar: calendar, prefersDayFirst: dayFirst, locale: locale)
            return QuickLogUnderstandingFill.fill(parsed, current: blank, accounts: accounts, now: now)
        }
        return try QuickLogBatch(drafts: drafts).selectedDraft()
    }
}
