import Foundation
import MoneyUpCore

extension AppModel {
    /// Widgets open the normal Log after unlock, so no favourite is shown
    /// while locked any more. An earlier build may have left favourite labels
    /// in the separate locked store; opening a book deletes them.
    func scheduleRetiredLockedFavouritesErase() {
        let store = lockedFavouriteStore
        Task { try? await store.eraseAll() }
    }

    /// The favourite a capture saved by an earlier build came from: the same
    /// kind and the exact title its locked screen recorded (the favourite's
    /// title, or its name without one). Only still-usable references apply.
    func lockedFavouriteRouting(
        for capture: LockedCapture
    ) -> (accountID: UUID?, categoryID: UUID?)? {
        guard let profile, profile.showsFavouritesWhileLocked,
              capture.kind == .expense || capture.kind == .income else { return nil }
        let kind: QuickLogFavourite.Kind = capture.kind == .income ? .income : .expense
        guard let favourite = profile.quickLogFavourites.first(where: {
            $0.kind == kind && ($0.payee.isEmpty ? $0.name : $0.payee) == capture.payee
        }) else { return nil }
        let categories = kind == .income ? incomeCategories : expenseCategories
        let accountID = favourite.accountID.flatMap { id in userAccounts.contains { $0.id == id } ? id : nil }
        let categoryID = favourite.categoryID.flatMap { id in categories.contains { $0.id == id } ? id : nil }
        guard accountID != nil || categoryID != nil else { return nil }
        return (accountID, categoryID)
    }
}
