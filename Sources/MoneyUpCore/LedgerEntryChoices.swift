import Foundation

/// Hiding is a picker preference, never an accounting or budget filter.
public enum LedgerEntryChoices {
    public static func visible(
        _ accounts: [LedgerAccount],
        preserving selectedIDs: Set<UUID> = []
    ) -> [LedgerAccount] {
        let byID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var preserved = selectedIDs
        for id in selectedIDs {
            var parent = byID[id]?.parentID
            var visited = Set<UUID>()
            while let id = parent, visited.insert(id).inserted {
                preserved.insert(id)
                parent = byID[id]?.parentID
            }
        }
        var hidden: [UUID: Bool] = [:]
        for account in accounts where hidden[account.id] == nil {
            var current: LedgerAccount? = account
            var visited = Set<UUID>()
            var path: [UUID] = []
            var isHidden = false
            while let item = current {
                if let cached = hidden[item.id] { isHidden = cached; break }
                guard visited.insert(item.id).inserted else { isHidden = true; break }
                path.append(item.id)
                if item.isHiddenFromEntry { isHidden = true; break }
                current = item.parentID.flatMap { byID[$0] }
            }
            for id in path { hidden[id] = isHidden }
        }
        return accounts.filter { preserved.contains($0.id) || hidden[$0.id] != true }
    }
}
