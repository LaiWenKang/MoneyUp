import Foundation
import MoneyUpCore

extension AppModel {
    func updateFavouritesWhileLocked(_ enabled: Bool) async throws {
        try await mutateProfile { $0.showsFavouritesWhileLocked = enabled }
    }

    /// Mirrors favourites to the locked store only while the owner has opted
    /// in and Locked Quick Capture is allowed; otherwise the store is erased.
    /// It runs only with an open book, so a locked app never rewrites it.
    func syncLockedFavourites() async {
        let store = lockedFavouriteStore
        guard let profile,
              profile.showsFavouritesWhileLocked,
              profile.allowLockedQuickCapture else {
            try? await store.eraseAll()
            return
        }
        try? await store.replace(with: profile.quickLogFavourites.map { LockedFavouriteShortcut($0) })
    }

    func scheduleLockedFavouriteSync() {
        Task { @MainActor in await syncLockedFavourites() }
    }

    /// The favourite a locked capture came from: the same kind and the exact
    /// title the locked screen recorded. Only still-usable references apply.
    func lockedFavouriteRouting(
        for capture: LockedCapture
    ) -> (accountID: UUID?, categoryID: UUID?)? {
        guard let profile, profile.showsFavouritesWhileLocked,
              capture.kind == .expense || capture.kind == .income else { return nil }
        let kind: QuickLogFavourite.Kind = capture.kind == .income ? .income : .expense
        guard let favourite = profile.quickLogFavourites.first(where: {
            $0.kind == kind && LockedFavouriteShortcut($0).capturePayee == capture.payee
        }) else { return nil }
        let categories = kind == .income ? incomeCategories : expenseCategories
        let accountID = favourite.accountID.flatMap { id in userAccounts.contains { $0.id == id } ? id : nil }
        let categoryID = favourite.categoryID.flatMap { id in categories.contains { $0.id == id } ? id : nil }
        guard accountID != nil || categoryID != nil else { return nil }
        return (accountID, categoryID)
    }
}
