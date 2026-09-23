import Foundation
import MoneyUpCore

/// Which saved reference of a favourite no longer resolves to something the
/// Log form can record against. The favourite is kept so the user can repair
/// it; it is never silently pointed at another account or category.
enum QuickLogFavouriteRepair: Equatable, Hashable, Sendable {
    case account
    case category
}

extension AppModel {
    var quickLogFavourites: [QuickLogFavourite] {
        profile?.quickLogFavourites ?? []
    }

    var canAddQuickLogFavourite: Bool {
        quickLogFavourites.count < QuickLogFavourite.maximumCount
    }

    func quickLogFavouriteRepairs(_ favourite: QuickLogFavourite) -> Set<QuickLogFavouriteRepair> {
        var repairs = Set<QuickLogFavouriteRepair>()
        if let accountID = favourite.accountID,
           !userAccounts.contains(where: { $0.id == accountID }) {
            repairs.insert(.account)
        }
        if let categoryID = favourite.categoryID {
            let pool = favourite.kind == .income ? incomeCategories : expenseCategories
            if !pool.contains(where: { $0.id == categoryID }) { repairs.insert(.category) }
        }
        return repairs
    }

    /// Adds a new favourite or replaces the one with the same identifier,
    /// keeping its position.
    func saveQuickLogFavourite(_ favourite: QuickLogFavourite) async throws {
        guard favourite.isValid else { throw AppModelError.invalidBook }
        try await mutateProfile { profile in
            var favourites = profile.quickLogFavourites
            if let index = favourites.firstIndex(where: { $0.id == favourite.id }) {
                favourites[index] = favourite
            } else {
                guard favourites.count < QuickLogFavourite.maximumCount else {
                    throw AppModelError.invalidBook
                }
                favourites.append(favourite)
            }
            profile.quickLogFavourites = QuickLogFavourite.normalized(favourites)
        }
    }

    func deleteQuickLogFavourite(id: UUID) async throws {
        guard quickLogFavourites.contains(where: { $0.id == id }) else { return }
        try await mutateProfile { profile in
            profile.quickLogFavourites.removeAll { $0.id == id }
        }
    }

    func moveQuickLogFavourites(fromOffsets source: IndexSet, toOffset destination: Int) async throws {
        var reordered = quickLogFavourites
        reordered.move(fromOffsets: source, toOffset: destination)
        guard reordered != quickLogFavourites else { return }
        try await mutateProfile { profile in
            // Reapply to the persisted list so a concurrent edit is not lost.
            let byID = Dictionary(uniqueKeysWithValues: profile.quickLogFavourites.map { ($0.id, $0) })
            let ordered = reordered.compactMap { byID[$0.id] }
            let remainder = profile.quickLogFavourites.filter { favourite in
                !ordered.contains(where: { $0.id == favourite.id })
            }
            profile.quickLogFavourites = QuickLogFavourite.normalized(ordered + remainder)
        }
    }
}
