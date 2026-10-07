#if DEBUG
import Foundation
import MoneyUpCore
import MoneyUpPersistence

/// Debug-only launch harness for end-to-end UI journeys. It is compiled out of
/// Release builds entirely. When the process is launched with `-MoneyUpUITest`
/// it replaces only the key and database location: a fixed test key opens a
/// temporary, seeded SQLCipher book through the normal startup path, so lock,
/// unlock, Quick Log, and widget routes all run production code.
@MainActor
enum MoneyUpUITestHarness {
    static let enableArgument = "-MoneyUpUITest"
    /// Wipe the harness book and any widget route an earlier journey left
    /// queued before launch; without it state survives relaunch.
    static let resetArgument = "-MoneyUpUITestReset"
    static let favouritesArgument = "-MoneyUpUITestFavourites"
    static let startLockedArgument = "-MoneyUpUITestStartLocked"
    /// Starts with the auto-lock cover over an open book, as after the delay.
    static let startCoveredArgument = "-MoneyUpUITestStartCovered"
    /// Makes the simulated device-owner prompt fail, as if cancelled.
    static let denyScreenUnlockArgument = "-MoneyUpUITestDenyScreenUnlock"
    /// Runs the words intent once the book is open, with the words that follow
    /// this argument: what Siri would pass after the person said them.
    static let wordsArgument = "-MoneyUpUITestWords"

    private static var arguments: [String] { ProcessInfo.processInfo.arguments }

    static func makeModelIfRequested() -> AppModel? {
        guard arguments.contains(enableArgument) else { return nil }
        // Not the temporary folder: iOS 27 does not keep it across a relaunch,
        // and journeys relaunch over the same book.
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MoneyUpUITestBook", isDirectory: true)
        if arguments.contains(resetArgument) {
            try? FileManager.default.removeItem(at: directory)
            // Journeys run with the shipped default (amounts hidden), never
            // with whatever an earlier session left on this simulator.
            UserDefaults.standard.removeObject(forKey: MoneyAmountPrivacy.storageKey)
            UserDefaults.standard.removeObject(forKey: ReminderPreferences.storageKey)
            removeQueuedWidgetRoutes()
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("book.sqlite3")
        let seeded = directory.appendingPathComponent("seeded.flag")
        let key = Data(repeating: 0x2a, count: 32)
        let withFavourites = arguments.contains(favouritesArgument)
        let opener: DatabaseStoreOpener = { _ in
            let store = try EncryptedRecordStore(databaseURL: databaseURL, key: key)
            if !FileManager.default.fileExists(atPath: seeded.path) {
                try await store.write(try seedWrites(withFavourites: withFavourites))
                FileManager.default.createFile(atPath: seeded.path, contents: Data())
            }
            return OpenedDatabaseStore(store: store, unlockToFirstUsefulContentInterval: nil)
        }
        guard let bootstrap = try? EncryptedRecordStore(databaseURL: databaseURL, key: key) else {
            return nil
        }
        let model = AppModel(
            store: bootstrap,
            profile: nil,
            accounts: [],
            lockedCaptureStore: HarnessLockedCaptureStore(),
            lockedFavouriteStore: InMemoryLockedFavouriteShortcutStore(),
            databaseURLForErase: databaseURL,
            quickActionRouteBroker: .shared,
            openDatabaseStore: opener
        )
        let startsLocked = arguments.contains(startLockedArgument)
        let startsCovered = arguments.contains(startCoveredArgument)
        // The simulator has no Face ID; the device-owner prompt is simulated.
        model.screenAuthenticator = HarnessScreenAuthenticator(
            succeeds: !arguments.contains(denyScreenUnlockArgument)
        )
        Task { @MainActor in
            // Open the seeded book through the normal startup path.
            _ = await model.start()
            guard model.state == .ready else { return }
            if startsLocked {
                model.lock()
            } else if startsCovered {
                // As after an expired return whose automatic prompt was cancelled.
                model.lockScreen()
                model.automaticUnlockIsPending = false
            }
            if let index = arguments.firstIndex(of: wordsArgument), arguments.indices.contains(index + 1) {
                _ = try? await LogWithWordsIntent(words: arguments[index + 1]).perform()
            }
        }
        return model
    }

    /// A widget tap is durable until Log consumes it, so a journey that ends
    /// before unlocking would otherwise open Log in the next journey. This runs
    /// before the shared broker first reads its queue.
    private static func removeQueuedWidgetRoutes() {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: BudgetWidgetSnapshotStore.appGroupIdentifier
        ) else { return }
        try? FileManager.default.removeItem(at: container
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(MoneyUpQuickActionIngressFileStore.storageDirectoryName, isDirectory: true))
    }

    static func seedWrites(withFavourites: Bool) throws -> [RecordWrite] {
        let sgd = try CurrencyCode("SGD")
        let wallet = LedgerAccount(name: "Wallet", kind: .asset, currency: sgd)
        let book = AppModel.defaultBook(mainAccount: wallet)
        let food = book.accounts.first { $0.kind == .expense && $0.systemRole == nil }
        let favourites = withFavourites ? [
            QuickLogFavourite(name: "Lunch", kind: .expense, accountID: wallet.id, categoryID: food?.id),
            QuickLogFavourite(name: "Coffee", kind: .expense, amount: Decimal(string: "3.2"),
                              accountID: wallet.id, categoryID: food?.id)
        ] : []
        let profile = UserProfile(baseCurrency: sgd, quickLogFavourites: favourites)
        var writes = [try RecordWrite(profile, id: UserProfile.primaryRecordID, in: .profile)]
        writes += try book.accounts.map { try RecordWrite($0, id: $0.id.uuidString, in: .accounts) }
        writes += try book.budgetNodes.map { try RecordWrite($0, id: $0.id.uuidString, in: .budgetNodes) }
        return writes
    }
}

/// Stands in for Face ID, which the simulator cannot perform.
@MainActor
final class HarnessScreenAuthenticator: ScreenAuthenticating {
    private let succeeds: Bool
    init(succeeds: Bool) { self.succeeds = succeeds }
    func authenticate() async -> Bool { succeeds }
    func cancel() {}
}

/// The harness keeps locked captures in memory: a UI-test build is unsigned
/// and must not depend on, or write to, the device Keychain.
actor HarnessLockedCaptureStore: LockedCaptureStoring {
    private var captures: [LockedCapture] = []

    func all() async throws -> [LockedCapture] { captures }

    @discardableResult
    func append(_ capture: LockedCapture) async throws -> Int {
        captures = try LockedCaptureStore.queueByAppending(capture, to: captures)
        return captures.count
    }

    @discardableResult
    func remove(id: UUID) async throws -> Int {
        captures.removeAll { $0.id == id }
        return captures.count
    }

    func eraseAll() async throws { captures = [] }
}
#endif
