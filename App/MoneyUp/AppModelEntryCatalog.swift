import Foundation
import MoneyUpCore
import MoneyUpPersistence

extension AppModel {
    func entryPresetMatches(_ preset: LedgerPreset, currency: CurrencyCode) -> [LedgerAccount] {
        accounts.filter {
            $0.systemRole == nil && $0.presetID == preset.id
                && (preset.scope == .expenses
                    ? $0.kind == .expense
                    : (($0.kind == .asset || $0.kind == .liability) && $0.currency == currency))
        }
    }

    func setEntryPresetEnabled(_ id: String, enabled: Bool, currencyCode: String) async throws {
        guard state == .ready, !requiresAuthenticationPrivacyCover,
              let preset = LedgerPresetCatalog.preset(id: id) else { throw AppModelError.locked }
        let currency = try CurrencyCode(currencyCode)
        let matches = entryPresetMatches(preset, currency: currency)
        guard matches.count <= 1 else { throw AppModelError.missingRecord }
        if let existing = matches.first {
            try await setEntryOptionEnabled(id: existing.id, enabled: enabled)
        } else if enabled {
            let name = AppLocalization.string(preset.labelKey)
            switch preset.scope {
            case .accounts:
                guard let type = preset.accountType else { throw AppModelError.missingRecord }
                try await addAccount(name: name, type: type, currencyCode: currency.value, presetID: id)
            case .expenses:
                try await addCategory(name: name, kind: .expense, presetID: id)
            }
        }
    }

    /// One metadata write; never archive, delete, reclassify or rewrite money.
    func setEntryOptionEnabled(id: UUID, enabled: Bool) async throws {
        guard !requiresAuthenticationPrivacyCover else { throw AppModelError.locked }
        try beginJournalMutation(invalidatesJournalProjection: false)
        defer { endJournalMutation() }
        guard let index = accounts.firstIndex(where: { $0.id == id }),
              accounts[index].systemRole == nil,
              !accounts[index].isArchived,
              [.asset, .liability, .expense, .income].contains(accounts[index].kind) else {
            throw AppModelError.missingRecord
        }
        var updated = accounts[index]
        let hidden = !enabled
        guard updated.isHiddenFromEntry != hidden else { return }
        updated.isHiddenFromEntry = hidden
        let generation = storeGeneration
        let revision = logicalBookRevision
        let optionStore = try requireStore()
        try await optionStore.upsert(updated, id: id.uuidString, in: .accounts)
        await lifecycleHooks.checkpoint(.afterAccountWriteBeforeApply)
        guard isCurrentStoreGeneration(generation), revision == logicalBookRevision,
              let currentIndex = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[currentIndex] = updated
    }
}
