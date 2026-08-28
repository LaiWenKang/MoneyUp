import Foundation
@testable import MoneyUp
import MoneyUpCore
import MoneyUpPersistence
import XCTest

final class AppModelTests: XCTestCase {
    private func budgetWidgetPercent(
        _ snapshot: BudgetWidgetSnapshot
    ) -> Int? {
        guard case let .available(percentUsed, _) = snapshot else { return nil }
        return percentUsed
    }

    func testDatabaseKeyCreationRequiresEveryCiphertextArtifactToBeAbsent() {
        for bitmask in 0..<8 {
            let databaseExists = bitmask & 0b001 != 0
            let writeAheadLogExists = bitmask & 0b010 != 0
            let sharedMemoryExists = bitmask & 0b100 != 0

            XCTAssertEqual(
                DatabaseKeyCreationPolicy.mayCreateKey(
                    databaseExists: databaseExists,
                    writeAheadLogExists: writeAheadLogExists,
                    sharedMemoryExists: sharedMemoryExists
                ),
                bitmask == 0,
                "Unexpected key-creation decision for artifact mask \(bitmask)"
            )
        }
    }

    func testDatabaseKeyPolicyChecksMainWALAndSharedMemoryPaths() {
        let databaseURL = URL(fileURLWithPath: "/private/test/moneyup.sqlite")

        XCTAssertEqual(
            DatabaseKeyCreationPolicy.artifactURLs(for: databaseURL).map(\.path),
            [
                "/private/test/moneyup.sqlite",
                "/private/test/moneyup.sqlite-wal",
                "/private/test/moneyup.sqlite-shm"
            ]
        )
    }

    func testBoundedFileReaderConsumesToEOFAndStopsOneBytePastTheLimit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("bounded-read.bin")
        let source = Data(repeating: 0xa5, count: 150_000)
        try source.write(to: url, options: .atomic)

        let completeHandle = try FileHandle(forReadingFrom: url)
        defer { try? completeHandle.close() }
        XCTAssertEqual(
            try BoundedFileReader.read(
                from: completeHandle,
                maximumByteCount: source.count
            ),
            source
        )

        let limitedHandle = try FileHandle(forReadingFrom: url)
        defer { try? limitedHandle.close() }
        XCTAssertEqual(
            try BoundedFileReader.read(
                from: limitedHandle,
                maximumByteCount: 100_000
            ).count,
            100_001
        )

        let copiedURL = directory.appendingPathComponent("bounded-copy.bin")
        let copiedHandle = try FileHandle(forReadingFrom: url)
        defer { try? copiedHandle.close() }
        XCTAssertEqual(
            try BoundedFileReader.copy(
                from: copiedHandle,
                to: copiedURL,
                maximumByteCount: source.count
            ),
            source.count
        )
        XCTAssertEqual(try Data(contentsOf: copiedURL), source)

        let rejectedURL = directory.appendingPathComponent("rejected-copy.bin")
        let rejectedHandle = try FileHandle(forReadingFrom: url)
        defer { try? rejectedHandle.close() }
        XCTAssertThrowsError(
            try BoundedFileReader.copy(
                from: rejectedHandle,
                to: rejectedURL,
                maximumByteCount: 100_000
            )
        ) { error in
            XCTAssertEqual(error as? PortableArchiveError, .archiveTooLarge)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejectedURL.path))
    }

    func testSharedCurrencyCatalogIsSearchableAndOnlyReturnsValidatedCodes() throws {
        let english = Locale(identifier: "en_US")
        let custom = try CurrencyCode("USDT")

        XCTAssertTrue(SupportedCurrencies.codes.contains("KWD"))
        XCTAssertTrue(SupportedCurrencies.codes.contains("BHD"))
        XCTAssertTrue(SupportedCurrencies.codes.contains("CLP"))
        XCTAssertEqual(
            SupportedCurrencies.searchableCodes(
                query: "Kuwaiti",
                locale: english
            ),
            ["KWD"]
        )
        XCTAssertEqual(
            SupportedCurrencies.searchableCodes(
                query: "USDT",
                existing: [custom],
                locale: english
            ),
            ["USDT"]
        )
        XCTAssertTrue(SupportedCurrencies.isSelectable("USDT", existing: [custom]))
        XCTAssertFalse(SupportedCurrencies.isSelectable("USDT"))
        XCTAssertFalse(SupportedCurrencies.isSelectable("BAD!"))
        XCTAssertFalse(SupportedCurrencies.isSelectable("NOTACODE"))
        XCTAssertTrue(SupportedCurrencies.codes.allSatisfy {
            (try? CurrencyCode($0)) != nil
        })
        XCTAssertNotNil(try? CurrencyCode(SupportedCurrencies.regionalDefault))
    }

    func testAmountParserUsesLocaleAndRequiresTheWholeString() {
        let french = Locale(identifier: "fr_FR")

        XCTAssertEqual(
            decimalAmount(from: "12,50", locale: french),
            Decimal(string: "12.50")
        )
        XCTAssertEqual(
            decimalAmount(from: "-0,75", locale: french),
            Decimal(string: "-0.75")
        )
        XCTAssertNil(decimalAmount(from: "12,50 EUR", locale: french))
        XCTAssertNil(decimalAmount(from: "1,2,3", locale: french))
        XCTAssertNil(decimalAmount(from: "NaN", locale: french))
        XCTAssertNil(decimalAmount(from: "1e6", locale: french))
        XCTAssertNil(decimalAmount(from: "1 000,50", locale: french))
        XCTAssertNil(decimalAmount(from: "１２,５０", locale: french))
        XCTAssertNil(decimalAmount(from: String(repeating: "1", count: 129)))
        XCTAssertEqual(
            decimalAmount(from: "+12.50", locale: french),
            Decimal(string: "12.50")
        )
    }

    func testAmountParserPreservesLargeDecimalWithoutBinaryConversion() {
        let text = "9999999999999999999999999999.99"

        XCTAssertEqual(
            decimalAmount(from: text, locale: Locale(identifier: "en_US_POSIX")),
            Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
        )
    }

    func testLockedCaptureRejectsUnboundedOrInvalidEnvelopeFields() {
        XCTAssertTrue(
            LockedCapture(kind: .expense, amountText: "12.50").isStructurallyValid
        )
        XCTAssertFalse(
            LockedCapture(kind: .expense, amountText: "   ").isStructurallyValid
        )
        XCTAssertFalse(
            LockedCapture(
                kind: .expense,
                amountText: String(
                    repeating: "1",
                    count: LockedCapture.maximumAmountByteCount + 1
                )
            ).isStructurallyValid
        )
        XCTAssertFalse(
            LockedCapture(
                kind: .expense,
                amountText: "1",
                note: String(
                    repeating: "x",
                    count: LockedCapture.maximumNoteByteCount + 1
                )
            ).isStructurallyValid
        )
        XCTAssertFalse(
            LockedCapture(
                kind: .expense,
                amountText: "1",
                occurredAt: Date(timeIntervalSinceReferenceDate: .infinity)
            ).isStructurallyValid
        )
    }

    func testLockedCaptureDuplicateRetryRemainsIdempotentAtCapacity() throws {
        let captures = (0..<100).map { offset in
            LockedCapture(
                id: UUID(),
                kind: .expense,
                amountText: String(offset + 1)
            )
        }
        let duplicate = try XCTUnwrap(captures.last)

        XCTAssertEqual(
            try LockedCaptureStore.queueByAppending(duplicate, to: captures),
            captures
        )

        XCTAssertThrowsError(
            try LockedCaptureStore.queueByAppending(
                LockedCapture(kind: .expense, amountText: "101"),
                to: captures
            )
        ) { error in
            guard case LockedCaptureStoreError.queueFull = error else {
                return XCTFail("Expected queueFull, got \(error)")
            }
        }
    }

    func testMoneyKeyboardUsesCurrencyScaleAndRetainsSignedAssetInput() throws {
        XCTAssertEqual(
            moneyAmountKeyboardLayout(currency: try CurrencyCode("JPY")),
            .numberOnly
        )
        XCTAssertEqual(
            moneyAmountKeyboardLayout(currency: try CurrencyCode("KWD")),
            .decimal
        )
        XCTAssertEqual(
            moneyAmountKeyboardLayout(currency: try CurrencyCode("BTC")),
            .decimal
        )
        XCTAssertEqual(
            moneyAmountKeyboardLayout(
                currency: try CurrencyCode("JPY"),
                allowsNegative: true
            ),
            .signed
        )
        XCTAssertEqual(moneyAmountKeyboardLayout(currency: nil), .decimal)
    }

    func testUserFacingErrorsNeverExposeRawDiagnostics() throws {
        let sentinel = "SQLITE_SENTINEL_SECRET_RECORD"
        let recordID = "record-id-that-must-not-appear"
        let postingID = try XCTUnwrap(
            UUID(uuidString: "deadbeef-dead-beef-dead-beefdeadbeef")
        )
        let sgd = try CurrencyCode("SGD")
        let rawErrors: [Error] = [
            PersistenceError.databaseFailure(code: -31_337, message: sentinel),
            PersistenceError.invalidStoredRecord(
                collection: .journalEntries,
                recordID: recordID
            ),
            DatabaseKeyStoreError.unexpectedStatus(-31_337),
            CurrencyCodeError.invalid(sentinel),
            JournalEntryValidationError.duplicatePostingID(postingID),
            JournalEntryValidationError.unbalanced(
                currency: sgd,
                residual: 123
            ),
            BudgetTreeError.missingParent(nodeID: postingID, parentID: postingID),
            SavingsGoalError.currencyMismatch(expected: sgd, actual: try CurrencyCode("USD"))
        ]

        for error in rawErrors {
            let description = error.localizedDescription
            XCTAssertFalse(description.contains(sentinel))
            XCTAssertFalse(description.contains(recordID))
            XCTAssertFalse(description.contains("-31337"))
            XCTAssertFalse(description.localizedCaseInsensitiveContains("sqlite"))
            XCTAssertFalse(description.contains(postingID.uuidString))
            XCTAssertFalse(description.contains("MoneyUpCore."))
            XCTAssertFalse(description.contains("MoneyUpPersistence."))
        }
    }

    func testEverySavingsGoalFailureUsesSafeLocalizedLanguage() throws {
        let sgd = try CurrencyCode("SGD")
        let usd = try CurrencyCode("USD")
        let errors: [SavingsGoalError] = [
            .emptyName,
            .nonPositiveTarget,
            .targetBeforeCreation,
            .nonPositiveMovement,
            .currencyMismatch(expected: sgd, actual: usd),
            .movementBeforeCreation,
            .withdrawalExceedsBalance,
            .resetBeforeCreation,
            .duplicateMovementID,
            .duplicateResetID,
            .invalidOriginContext,
            .invalidDate,
            .unsupportedPrecision(sgd),
            .calculationFailed
        ]

        for error in errors {
            let message = safeUserMessage(for: error, context: .save)
            XCTAssertFalse(message.isEmpty)
            XCTAssertFalse(message.contains("SavingsGoalError"))
            XCTAssertFalse(message.contains("MoneyUpCore."))
            XCTAssertFalse(message.contains("expected:"))
        }
        XCTAssertEqual(
            safeUserMessage(
                for: SavingsGoalError.withdrawalExceedsBalance,
                context: .save
            ),
            SavingsGoalError.withdrawalExceedsBalance.localizedDescription
        )
    }

    func testSafePresentationBoundaryRedactsUnknownFileAndSystemPayloads() {
        let sentinel = "PRIVATE_PATH_AND_SQL_SENTINEL"
        let errors: [(Error, SafeUserMessageContext)] = [
            (
                NSError(
                    domain: NSCocoaErrorDomain,
                    code: CocoaError.Code.fileReadNoSuchFile.rawValue,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Missing \(sentinel)",
                        NSFilePathErrorKey: "/private/\(sentinel)/book.moneyup"
                    ]
                ),
                .read
            ),
            (
                NSError(
                    domain: sentinel,
                    code: -9_999,
                    userInfo: [NSLocalizedDescriptionKey: sentinel]
                ),
                .general
            ),
            (
                PersistenceError.databaseFailure(
                    code: -9_999,
                    message: "SQLCipher \(sentinel)"
                ),
                .save
            ),
            (DatabaseKeyStoreError.unexpectedStatus(-9_999), .unlock)
        ]

        for (error, context) in errors {
            let message = safeUserMessage(for: error, context: context)
            XCTAssertFalse(message.contains(sentinel))
            XCTAssertFalse(message.contains("-9999"))
            XCTAssertFalse(message.localizedCaseInsensitiveContains("sqlcipher"))
            XCTAssertFalse(message.contains("/private/"))
        }
    }

    func testRecoveryPresentationAggregatesAreasWithoutRawIdentifiers() {
        let sentinel = "deadbeef-dead-beef-dead-beefdeadbeef"
        let summaries = safeRecoveryIssueSummaries([
            "journal_entries/\(sentinel)",
            "journal_entries/derived-refresh-unavailable",
            "receipt_attachments/orphan-\(sentinel)",
            "accounts/duplicate-\(sentinel)"
        ])
        let presented = summaries.joined(separator: " ")

        XCTAssertEqual(summaries.count, 3)
        XCTAssertFalse(presented.contains(sentinel))
        XCTAssertFalse(presented.contains("journal_entries"))
        XCTAssertFalse(presented.contains("receipt_attachments"))
    }

    func testEveryScheduleFailureHasSpecificSafeLanguage() {
        let errors: [ScheduledTransactionError] = [
            .unsupportedKind,
            .amountMustBePositive,
            .nameCannotBeEmpty,
            .inactive,
            .ended,
            .staleOccurrence,
            .occurrenceAlreadyResolved,
            .linkedEntryRequired,
            .unexpectedLinkedEntry,
            .cannotAdvance,
            .linkedEntryNotFound,
            .invalidResolutionState,
            .invalidLifecycle
        ]
        let descriptions = errors.map(\.localizedDescription)

        XCTAssertEqual(Set(descriptions).count, errors.count)
        XCTAssertTrue(descriptions.allSatisfy { !$0.contains("ScheduledTransactionError") })
    }

    func testLegacyQuickLogDraftDecodesWithoutSplitState() throws {
        let draft = QuickLogDraft(
            kind: .expense,
            amountText: "12",
            destinationAmountText: "",
            accountID: UUID(),
            destinationAccountID: nil,
            categoryID: UUID(),
            occurredAt: Date(timeIntervalSince1970: 0),
            dateWasEdited: false,
            payee: "Cafe",
            note: "",
            smartText: ""
        )
        let encoded = try JSONEncoder().encode(draft)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "splitLines")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(QuickLogDraft.self, from: legacy)

        XCTAssertTrue(decoded.splitLines.isEmpty)
        XCTAssertEqual(decoded.amountText, "12")
    }

    @MainActor
    func testLockDuringSaveCommitsExactlyOnceWithoutRepopulatingLockedState() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let gate = AsyncGate()
        let model = fixture.model(
            lifecycleHooks: hooks(pausing: .beforeJournalCommit, at: gate)
        )

        let saveTask = Task { @MainActor in
            try await model.logExpense(
                amount: 12,
                accountID: fixture.wallet.id,
                categoryID: fixture.food.id,
                occurredAt: Date(timeIntervalSinceReferenceDate: 200),
                payee: "Cafe",
                note: nil
            )
        }

        await gate.waitUntilReached()
        model.lock()
        await gate.release()

        let savedID = try await saveTask.value
        XCTAssertNotNil(savedID)
        await model.waitForPendingStoreClose()
        XCTAssertEqual(model.state, .locked)
        XCTAssertTrue(model.entries.isEmpty)

        let reopened = try fixture.reopenStore()
        let persisted = try await reopened.fetchAll(
            JournalEntry.self,
            from: .journalEntries
        )
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted.first?.payee, "Cafe")
        let draftCount = try await reopened.count(in: .quickLogDrafts)
        XCTAssertEqual(draftCount, 0)
        await reopened.close()
    }

    @MainActor
    func testDraftCallbackDuringSaveCannotResurrectCommittedDraft() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let gate = AsyncGate()
        let model = fixture.model(
            lifecycleHooks: hooks(pausing: .beforeJournalCommit, at: gate)
        )
        let attemptedDraft = QuickLogDraft(
            kind: .expense,
            amountText: "99",
            destinationAmountText: "",
            accountID: fixture.wallet.id,
            destinationAccountID: nil,
            categoryID: fixture.food.id,
            occurredAt: Date(timeIntervalSinceReferenceDate: 201),
            dateWasEdited: true,
            payee: "Must not return",
            note: "",
            smartText: ""
        )

        let saveTask = Task { @MainActor in
            try await model.logExpense(
                amount: 12,
                accountID: fixture.wallet.id,
                categoryID: fixture.food.id,
                occurredAt: Date(timeIntervalSinceReferenceDate: 200),
                payee: "Cafe",
                note: nil
            )
        }

        await gate.waitUntilReached()
        model.updateQuickLogDraft(attemptedDraft)
        XCTAssertNil(model.quickLogDraft)
        await gate.release()

        let savedID = try await saveTask.value
        try await Task.sleep(for: .milliseconds(350))
        let draftCount = try await fixture.store.count(in: .quickLogDrafts)
        let entryCount = try await fixture.store.count(in: .journalEntries)
        XCTAssertNotNil(savedID)
        XCTAssertNil(model.quickLogDraft)
        XCTAssertEqual(draftCount, 0)
        XCTAssertEqual(entryCount, 1)
        await fixture.store.close()
    }

    @MainActor
    func testFreshBookDetectionChecksEveryPersistedCollection() async throws {
        for collection in RecordCollection.allCases {
            let fixture = try AppModelFixture()
            // This test is intentionally about raw durable-row presence, not
            // domain validity. Install one nonempty row through the snapshot
            // boundary so strict typed-write identity validation cannot make
            // the test accidentally collection-specific.
            try await fixture.store.restore(DatabaseSnapshot(
                schemaVersion: EncryptedRecordStore.currentSchemaVersion,
                records: [StoredRecordSnapshot(
                    collection: collection.rawValue,
                    recordID: "fresh-book-sentinel",
                    payload: Data("{}".utf8),
                    updatedAt: 1
                )]
            ))

            let hasPersistedData = try await AppModel.hasPersistedBookData(
                in: fixture.store
            )
            XCTAssertTrue(
                hasPersistedData,
                "Missed persisted collection: \(collection.rawValue)"
            )
            await fixture.store.close()
            fixture.removeFiles()
        }

        let emptyFixture = try AppModelFixture()
        let emptyHasPersistedData = try await AppModel.hasPersistedBookData(
            in: emptyFixture.store
        )
        XCTAssertFalse(emptyHasPersistedData)
        await emptyFixture.store.close()
        emptyFixture.removeFiles()
    }

    @MainActor
    func testAutoLockPersistsOnlyDocumentedDelayChoices() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()

        try await model.updateAutoLockDelay(300)
        let persisted = try await fixture.store.fetch(
            UserProfile.self,
            id: UserProfile.primaryRecordID,
            from: .profile
        )
        XCTAssertEqual(model.profile?.autoLockDelay, 300)
        XCTAssertEqual(persisted?.autoLockDelay, 300)

        do {
            try await model.updateAutoLockDelay(120)
            XCTFail("Expected undocumented auto-lock delay to be rejected")
        } catch AppModelError.invalidBook {
            // Existing legacy values remain readable, but new writes use only
            // the five choices exposed in Settings.
        }
        XCTAssertEqual(model.profile?.autoLockDelay, 300)
        await fixture.store.close()
    }

    @MainActor
    func testAutoLockUsesExactBoundaryAndTreatsClockRollbackAsUnsafe() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let profile = UserProfile(baseCurrency: fixture.sgd, autoLockDelay: 60)
        let model = fixture.model(profile: profile)
        let backgroundedAt = Date(timeIntervalSinceReferenceDate: 10_000)

        model.sceneDidEnterBackground(at: backgroundedAt)
        model.sceneDidBecomeActive(
            at: backgroundedAt.addingTimeInterval(59.999)
        )
        XCTAssertEqual(model.state, .ready)

        let laterBackground = backgroundedAt.addingTimeInterval(120)
        model.sceneDidEnterBackground(at: laterBackground)
        model.sceneDidBecomeActive(at: laterBackground.addingTimeInterval(60))

        XCTAssertEqual(model.state, .locked)
        await model.waitForPendingStoreClose()

        let rollbackFixture = try AppModelFixture()
        defer { rollbackFixture.removeFiles() }
        let rollbackModel = rollbackFixture.model(profile: UserProfile(
            baseCurrency: rollbackFixture.sgd,
            autoLockDelay: 60
        ))
        rollbackModel.sceneDidEnterBackground(at: laterBackground)
        rollbackModel.sceneDidBecomeActive(
            at: laterBackground.addingTimeInterval(-1)
        )

        XCTAssertEqual(rollbackModel.state, .locked)
        await rollbackModel.waitForPendingStoreClose()
    }

    @MainActor
    func testAutoLockDeadlineStartsWhenInactiveAndBackgroundCannotExtendIt() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let profile = UserProfile(baseCurrency: fixture.sgd, autoLockDelay: 60)
        let model = fixture.model(profile: profile)
        let inactiveAt = Date(timeIntervalSinceReferenceDate: 20_000)

        model.sceneDidBecomeInactive(at: inactiveAt)
        // This normal second lifecycle transition must retain the original
        // deadline instead of granting another minute.
        model.sceneDidEnterBackground(at: inactiveAt.addingTimeInterval(59))
        model.sceneDidBecomeActive(at: inactiveAt.addingTimeInterval(60))

        XCTAssertEqual(model.state, .locked)
        await model.waitForPendingStoreClose()
    }

    @MainActor
    func testLaunchingStateTracksExpiredInactivityAndKeepsAuthenticationCover() {
        let model = AppModel()
        let inactiveAt = Date(timeIntervalSinceReferenceDate: 25_000)

        model.sceneDidBecomeInactive(at: inactiveAt)
        model.sceneDidBecomeActive(
            at: inactiveAt.addingTimeInterval(60)
        )

        XCTAssertEqual(model.state, .launching)
        XCTAssertTrue(model.hasDeferredAuthenticationLock)
        XCTAssertTrue(model.requiresAuthenticationPrivacyCover)
    }

    @MainActor
    func testCancelledStartupAuthenticationClearsCoverInBothCallbackOrders() {
        let model = AppModel()
        let inactiveAt = Date(timeIntervalSinceReferenceDate: 26_000)

        model.sceneDidBecomeInactive(at: inactiveAt)
        model.finishCancelledAuthentication()
        XCTAssertEqual(model.state, .locked)
        XCTAssertFalse(model.requiresAuthenticationPrivacyCover)

        model.sceneDidBecomeActive(
            at: inactiveAt.addingTimeInterval(60)
        )

        XCTAssertEqual(model.state, .locked)
        XCTAssertFalse(model.requiresAuthenticationPrivacyCover)

        let reverseOrderModel = AppModel()
        reverseOrderModel.sceneDidBecomeInactive(at: inactiveAt)
        reverseOrderModel.sceneDidBecomeActive(
            at: inactiveAt.addingTimeInterval(60)
        )
        XCTAssertEqual(reverseOrderModel.state, .launching)
        XCTAssertTrue(reverseOrderModel.hasDeferredAuthenticationLock)
        XCTAssertTrue(reverseOrderModel.requiresAuthenticationPrivacyCover)

        reverseOrderModel.finishCancelledAuthentication()

        XCTAssertEqual(reverseOrderModel.state, .locked)
        XCTAssertFalse(reverseOrderModel.hasDeferredAuthenticationLock)
        XCTAssertFalse(reverseOrderModel.requiresAuthenticationPrivacyCover)
    }

    @MainActor
    func testCancelledAuthenticationClearsDecodedRecoveryState() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let entry = try fixture.expense(amount: 8)
        let model = fixture.model(entries: [entry])
        model.finishFailedStartup(message: "Safe recovery message")
        XCTAssertNotNil(model.profile)
        XCTAssertFalse(model.accounts.isEmpty)
        XCTAssertFalse(model.entries.isEmpty)

        model.finishCancelledAuthentication()
        await model.waitForPendingStoreClose()

        XCTAssertEqual(model.state, .locked)
        XCTAssertNil(model.profile)
        XCTAssertTrue(model.accounts.isEmpty)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertFalse(model.requiresAuthenticationPrivacyCover)
        await fixture.store.close()
    }

    @MainActor
    func testFailedStartupCompletesDeferredLockBeforeRemovingCover() {
        let model = AppModel()
        let inactiveAt = Date(timeIntervalSinceReferenceDate: 27_000)

        model.sceneDidBecomeInactive(at: inactiveAt)
        model.sceneDidBecomeActive(
            at: inactiveAt.addingTimeInterval(60)
        )
        XCTAssertTrue(model.hasDeferredAuthenticationLock)
        XCTAssertTrue(model.requiresAuthenticationPrivacyCover)

        model.finishFailedStartup(message: "Safe recovery message")

        XCTAssertEqual(model.state, .locked)
        XCTAssertFalse(model.hasDeferredAuthenticationLock)
        XCTAssertFalse(model.requiresAuthenticationPrivacyCover)
        XCTAssertNil(model.profile)
        XCTAssertTrue(model.accounts.isEmpty)
    }

    @MainActor
    func testFailedRecoveryStateAutoLocksAtBackgroundDeadline() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let entry = try fixture.expense(amount: 9)
        let model = fixture.model(entries: [entry])
        model.finishFailedStartup(message: "Safe recovery message")
        guard case .failed = model.state else {
            return XCTFail("Expected an opened recovery state")
        }

        let inactiveAt = Date(timeIntervalSinceReferenceDate: 28_000)
        model.sceneDidBecomeInactive(at: inactiveAt)
        XCTAssertTrue(model.requiresAuthenticationPrivacyCover)
        model.sceneDidBecomeActive(
            at: inactiveAt.addingTimeInterval(60)
        )
        await model.waitForPendingStoreClose()

        XCTAssertEqual(model.state, .locked)
        XCTAssertNil(model.profile)
        XCTAssertTrue(model.accounts.isEmpty)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertFalse(model.requiresAuthenticationPrivacyCover)
    }

    @MainActor
    func testBecomingInactiveFlushesLatestQuickLogDraftWithoutDebounce() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()
        let draft = QuickLogDraft(
            kind: .expense,
            amountText: "17.25",
            destinationAmountText: "",
            accountID: fixture.wallet.id,
            destinationAccountID: nil,
            categoryID: fixture.food.id,
            occurredAt: Date(timeIntervalSinceReferenceDate: 30_000),
            dateWasEdited: true,
            payee: "Immediate privacy flush",
            note: "",
            smartText: ""
        )

        model.updateQuickLogDraft(draft)
        let inactiveAt = Date(timeIntervalSinceReferenceDate: 31_000)
        model.sceneDidBecomeInactive(at: inactiveAt)
        XCTAssertTrue(model.requiresAuthenticationPrivacyCover)
        await model.waitForPendingQuickLogDraftFlush()

        let persisted = try await fixture.store.fetch(
            QuickLogDraft.self,
            id: QuickLogDraft.primaryRecordID,
            from: .quickLogDrafts
        )
        XCTAssertEqual(persisted, draft)

        model.sceneDidBecomeActive(at: inactiveAt.addingTimeInterval(1))
        XCTAssertEqual(model.state, .ready)
        XCTAssertFalse(model.requiresAuthenticationPrivacyCover)
        await fixture.store.close()
    }

    func testReportingDateFormattingUsesBookTimeZoneAcrossTravelBoundary() throws {
        var kiritimati = Calendar(identifier: .gregorian)
        kiritimati.timeZone = try XCTUnwrap(
            TimeZone(identifier: "Pacific/Kiritimati")
        )
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try XCTUnwrap(
            TimeZone(identifier: "America/Los_Angeles")
        )
        let instant = Date(timeIntervalSince1970: 1_767_240_000)
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted)
            .locale(Locale(identifier: "en_US_POSIX"))

        XCTAssertEqual(
            instant.formattedForReporting(style, calendar: kiritimati),
            "Jan 1, 2026"
        )
        XCTAssertEqual(
            instant.formattedForReporting(style, calendar: losAngeles),
            "Dec 31, 2025"
        )
    }

    @MainActor
    func testZeroDelayAndInvalidLifecycleClockLockImmediately() async throws {
        let immediateFixture = try AppModelFixture()
        defer { immediateFixture.removeFiles() }
        let immediateProfile = UserProfile(
            baseCurrency: immediateFixture.sgd,
            autoLockDelay: 0
        )
        let immediateModel = immediateFixture.model(profile: immediateProfile)

        immediateModel.sceneDidEnterBackground()

        XCTAssertEqual(immediateModel.state, .locked)
        await immediateModel.waitForPendingStoreClose()

        let invalidClockFixture = try AppModelFixture()
        defer { invalidClockFixture.removeFiles() }
        let invalidClockModel = invalidClockFixture.model()

        invalidClockModel.sceneDidEnterBackground(
            at: Date(timeIntervalSinceReferenceDate: .infinity)
        )

        XCTAssertEqual(invalidClockModel.state, .locked)
        await invalidClockModel.waitForPendingStoreClose()
    }

    @MainActor
    func testLockDuringRestoreWaitsThenClearsEveryDecodedValue() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        try await fixture.seed(
            profile: UserProfile(baseCurrency: fixture.sgd),
            accounts: [fixture.wallet, fixture.usAccount, fixture.food]
        )
        let gate = AsyncGate()
        let model = fixture.model(
            lifecycleHooks: hooks(pausing: .beforeRestoreCommit, at: gate)
        )
        let archive = try await model.encryptedBackup(password: "restore-password")

        let restoreTask = Task { @MainActor in
            try await model.restoreEncryptedBackup(
                archive,
                password: "restore-password"
            )
        }
        await gate.waitUntilReached()
        model.lock()
        XCTAssertEqual(model.state, .ready)
        XCTAssertTrue(model.requiresAuthenticationPrivacyCover)
        await gate.release()

        try await restoreTask.value
        await model.waitForPendingStoreClose()
        XCTAssertEqual(model.state, .locked)
        XCTAssertFalse(model.requiresAuthenticationPrivacyCover)
        XCTAssertNil(model.profile)
        XCTAssertTrue(model.accounts.isEmpty)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertTrue(model.receiptAttachments.isEmpty)

        let reopened = try fixture.reopenStore()
        let restoredProfileCount = try await reopened.count(in: .profile)
        XCTAssertEqual(restoredProfileCount, 1)
        await reopened.close()
    }

    @MainActor
    func testExpiredAutoLockKeepsPrivacyCoverWhileRestoreDrains() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            autoLockDelay: 60
        )
        try await fixture.seed(
            profile: profile,
            accounts: [fixture.wallet, fixture.usAccount, fixture.food]
        )
        let gate = AsyncGate()
        let model = fixture.model(
            profile: profile,
            lifecycleHooks: hooks(pausing: .beforeRestoreCommit, at: gate)
        )
        let archive = try await model.encryptedBackup(
            password: "restore-password"
        )
        let restoreTask = Task { @MainActor in
            try await model.restoreEncryptedBackup(
                archive,
                password: "restore-password"
            )
        }
        await gate.waitUntilReached()

        let inactiveAt = Date(timeIntervalSinceReferenceDate: 40_000)
        model.sceneDidBecomeInactive(at: inactiveAt)
        model.sceneDidBecomeActive(
            at: inactiveAt.addingTimeInterval(60)
        )

        XCTAssertEqual(model.state, .ready)
        XCTAssertTrue(model.requiresAuthenticationPrivacyCover)

        await gate.release()
        try await restoreTask.value
        await model.waitForPendingStoreClose()

        XCTAssertEqual(model.state, .locked)
        XCTAssertFalse(model.requiresAuthenticationPrivacyCover)
    }

    @MainActor
    func testBackupAndRestoreBlockWhileLockedCaptureInboxIsPending() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let capture = LockedCapture(
            kind: .expense,
            amountText: "19.90",
            payee: "Pending cafe"
        )
        let inbox = InMemoryLockedCaptureStore(captures: [capture])
        let model = fixture.model(lockedCaptureStore: inbox)

        do {
            _ = try await model.encryptedBackup(password: "backup-password")
            XCTFail("Expected backup to reject an omitted locked-capture row")
        } catch AppModelError.pendingLockedCaptures {
            // The current archive format intentionally does not claim to
            // contain this separately encrypted inbox.
        }
        XCTAssertEqual(model.pendingLockedCaptureCount, 1)
        XCTAssertFalse(model.isWorking)

        do {
            try await model.restoreEncryptedBackup(
                Data([0x4d, 0x55]),
                password: "restore-password"
            )
            XCTFail("Expected restore to reject a cross-book capture boundary")
        } catch AppModelError.pendingLockedCaptures {
            // The candidate is not even parsed while old-book input is queued.
        }
        XCTAssertEqual(model.pendingLockedCaptureCount, 1)
        XCTAssertEqual(model.state, .ready)
        XCTAssertFalse(model.isWorking)

        try await inbox.eraseAll()
        let archive = try await model.encryptedBackup(password: "backup-password")
        XCTAssertFalse(archive.isEmpty)
        XCTAssertEqual(model.pendingLockedCaptureCount, 0)
        await fixture.store.close()
    }

    @MainActor
    func testLockedCaptureRecoveryNeverDeletesAfterTransientOrStaleFailure() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        try await fixture.seed(
            profile: UserProfile(baseCurrency: fixture.sgd),
            accounts: [fixture.wallet, fixture.usAccount, fixture.food]
        )
        let inbox = ScriptedLockedCaptureStore(readError: .unavailable)
        let model = fixture.model(lockedCaptureStore: inbox)

        do {
            _ = try await model.encryptedBackup(password: "capture-retry-pass")
            XCTFail("A transient protected-data failure must block backup")
        } catch LockedCaptureStoreError.unavailable {
            // Retryable failures never enable destructive recovery.
        }
        XCTAssertFalse(model.lockedCaptureInboxIsUnrecoverable)
        do {
            try await model.discardUnavailableLockedCaptures()
            XCTFail("Transient failure must not expose deletion")
        } catch AppModelError.missingRecord {
            // No destructive recovery marker exists.
        }
        let eraseCountAfterTransientFailure = await inbox.eraseCount()
        XCTAssertEqual(eraseCountAfterTransientFailure, 0)

        await inbox.setReadError(.invalidData)
        do {
            _ = try await model.encryptedBackup(password: "capture-retry-pass")
            XCTFail("Corrupt authenticated queue must block backup")
        } catch LockedCaptureStoreError.invalidData {
            // This stable failure can offer explicit recovery.
        }
        XCTAssertTrue(model.lockedCaptureInboxIsUnrecoverable)

        // A successful recheck at the confirmation boundary proves that the
        // old marker was stale. It must clear the marker and preserve bytes.
        await inbox.setReadError(nil)
        do {
            try await model.discardUnavailableLockedCaptures()
            XCTFail("A recovered empty inbox must not be erased")
        } catch AppModelError.missingRecord {
            // Expected after the fresh successful read.
        }
        XCTAssertFalse(model.lockedCaptureInboxIsUnrecoverable)
        let eraseCountAfterStaleMarker = await inbox.eraseCount()
        XCTAssertEqual(eraseCountAfterStaleMarker, 0)

        // The same explicit recovery remains available from a failed startup
        // as long as the authenticated store is open for backup/recovery.
        await inbox.setReadError(.keyMissing)
        do {
            _ = try await model.encryptedBackup(password: "capture-retry-pass")
            XCTFail("Missing device-only key must block backup")
        } catch LockedCaptureStoreError.keyMissing {
            // Definitively unrecoverable ciphertext remains until confirmation.
        }
        model.finishFailedStartup(message: "Safe recovery message")
        try await model.discardUnavailableLockedCaptures()
        let eraseCountAfterConfirmedLoss = await inbox.eraseCount()
        XCTAssertEqual(eraseCountAfterConfirmedLoss, 1)
        XCTAssertFalse(model.lockedCaptureInboxIsUnrecoverable)
        let archive = try await model.encryptedBackup(
            password: "capture-retry-pass"
        )
        XCTAssertFalse(archive.isEmpty)
        await fixture.store.close()
    }

    @MainActor
    func testImmediateBackupFlushesLatestQuickLogDraftIntoLiveStoreAndArchive() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()
        let draft = QuickLogDraft(
            kind: .expense,
            amountText: "83.40",
            destinationAmountText: "",
            accountID: fixture.wallet.id,
            destinationAccountID: nil,
            categoryID: fixture.food.id,
            occurredAt: Date(timeIntervalSinceReferenceDate: 31_500),
            dateWasEdited: true,
            payee: "Latest unsaved form revision",
            note: "Must survive an immediate backup and power loss",
            smartText: ""
        )

        model.updateQuickLogDraft(draft)
        let archive = try await model.encryptedBackup(
            password: "immediate-backup-password"
        )

        let persisted = try await fixture.store.fetch(
            QuickLogDraft.self,
            id: QuickLogDraft.primaryRecordID,
            from: .quickLogDrafts
        )
        XCTAssertEqual(persisted, draft)

        let snapshot = try PortableArchive.open(
            archive,
            password: "immediate-backup-password"
        )
        let archivedRecord = try XCTUnwrap(snapshot.records.first {
            $0.collection == RecordCollection.quickLogDrafts.rawValue
                && $0.recordID == QuickLogDraft.primaryRecordID
        })
        let archivedDraft = try JSONDecoder().decode(
            QuickLogDraft.self,
            from: archivedRecord.payload
        )
        XCTAssertEqual(archivedDraft, draft)
        await fixture.store.close()
    }

    @MainActor
    func testWrongPasswordRestorePersistsLatestDraftAcrossCloseAndReopen() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await fixture.seed(
            profile: profile,
            accounts: [fixture.wallet, fixture.usAccount, fixture.food]
        )
        let archive = try PortableArchive.seal(
            try await fixture.store.snapshot(),
            password: "correct-restore-password"
        )
        let model = fixture.model(profile: profile)
        let latestDraft = QuickLogDraft(
            kind: .expense,
            amountText: "64.20",
            destinationAmountText: "",
            accountID: fixture.wallet.id,
            destinationAccountID: nil,
            categoryID: fixture.food.id,
            occurredAt: Date(timeIntervalSinceReferenceDate: 31_900),
            dateWasEdited: true,
            payee: "Must survive failed restore",
            note: "Latest form revision",
            smartText: ""
        )
        model.updateQuickLogDraft(latestDraft)

        do {
            try await model.restoreEncryptedBackup(
                archive,
                password: "wrong-restore-password"
            )
            XCTFail("Expected authenticated archive rejection")
        } catch PortableArchiveError.authenticationFailed {
            // The live book is unchanged, including the newest draft revision.
        }
        await fixture.store.close()

        let reopened = try fixture.reopenStore()
        let persisted = try await reopened.fetch(
            QuickLogDraft.self,
            id: QuickLogDraft.primaryRecordID,
            from: .quickLogDrafts
        )
        XCTAssertEqual(persisted, latestDraft)
        await reopened.close()
    }

    @MainActor
    func testRestoreScavengesPowerLossValidationArtifacts() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await fixture.seed(
            profile: profile,
            accounts: [fixture.wallet, fixture.usAccount, fixture.food]
        )
        let archive = try PortableArchive.seal(
            try await fixture.store.snapshot(),
            password: "restore-scavenge-pass"
        )
        let validationDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MoneyUp-RestoreValidation-\(fixture.directoryURL.lastPathComponent)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: validationDirectory,
            withIntermediateDirectories: true
        )
        for suffix in ["", "-wal", "-shm"] {
            try Data(repeating: 0xa5, count: 4_096).write(
                to: validationDirectory.appendingPathComponent(
                    "candidate.sqlite3\(suffix)"
                )
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: validationDirectory.path)
        )
        let legacyValidationDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MoneyUp-RestoreValidation-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: legacyValidationDirectory,
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x5a, count: 4_096).write(
            to: legacyValidationDirectory.appendingPathComponent(
                "candidate.sqlite3-wal"
            )
        )

        let model = fixture.model(profile: profile)
        try await model.restoreEncryptedBackup(
            archive,
            password: "restore-scavenge-pass"
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: validationDirectory.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: legacyValidationDirectory.path
            )
        )
        await fixture.store.close()
    }

    @MainActor
    func testPrivacySafeInventoryCountsSnapshotWithoutExportingPayloadValues() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let generatedAt = Date(timeIntervalSince1970: 1_777_777_777)
        let profile = UserProfile(baseCurrency: fixture.sgd)
        let captureStore = InMemoryLockedCaptureStore(captures: [
            LockedCapture(
                kind: .expense,
                amountText: "98.76",
                payee: "Private Capture Payee",
                note: "Private capture note"
            )
        ])
        let entry = try TransactionFactory.expense(
            amount: try Money(12.34, currency: fixture.sgd),
            paidFrom: fixture.wallet.id,
            category: fixture.food.id,
            occurredAt: generatedAt.addingTimeInterval(-86_400),
            payee: "Private Merchant",
            note: "Private note"
        )
        let schedule = try ScheduledTransaction(
            kind: .expense,
            name: "Private Schedule",
            amount: try Money(45.67, currency: fixture.sgd),
            accountID: fixture.wallet.id,
            categoryAccountID: fixture.food.id,
            nextOccurrence: generatedAt.addingTimeInterval(86_400),
            frequency: .monthly,
            recurrenceTimeZoneIdentifier: "UTC"
        )
        var holding = try InvestmentHolding(
            accountID: fixture.wallet.id,
            symbol: "SECRET",
            name: "Private Holding",
            quantity: 0
        )
        try holding.recordPurchase(
            quantity: 2,
            unitCost: try Money(50, currency: fixture.sgd),
            occurredAt: generatedAt.addingTimeInterval(-172_800),
            entryID: UUID()
        )
        let movement = try SavingsGoalMovement(
            kind: .contribution,
            money: try Money(25, currency: fixture.sgd),
            occurredAt: generatedAt.addingTimeInterval(-86_400),
            originTimeZoneIdentifier: "UTC"
        )
        let goal = try SavingsGoal(
            name: "Private Goal",
            kind: .savingsGoal,
            target: try Money(1_000, currency: fixture.sgd),
            targetDate: generatedAt.addingTimeInterval(31_536_000),
            createdAt: generatedAt.addingTimeInterval(-172_800),
            movements: [movement],
            reportingTimeZoneIdentifier: "UTC"
        )
        try await fixture.seed(
            profile: profile,
            accounts: [fixture.wallet, fixture.usAccount, fixture.food],
            entries: [entry],
            schedules: [schedule],
            holdings: [holding],
            savingsGoals: [goal]
        )
        let model = fixture.model(
            profile: profile,
            entries: [entry],
            scheduledTransactions: [schedule],
            investmentHoldings: [holding],
            savingsGoals: [goal],
            lockedCaptureStore: captureStore
        )

        let inventory = try await model.privacySafeDataInventory(
            generatedAt: generatedAt,
            appVersion: "0.6.0",
            buildNumber: "1017.1"
        )

        XCTAssertEqual(inventory.formatVersion, 1)
        XCTAssertEqual(inventory.storedRecordCounts.count, RecordCollection.allCases.count)
        XCTAssertEqual(inventory.storedRecordCount(in: .profile), 1)
        XCTAssertEqual(inventory.storedRecordCount(in: .accounts), 3)
        XCTAssertEqual(inventory.storedRecordCount(in: .journalEntries), 1)
        XCTAssertEqual(inventory.storedRecordCount(in: .scheduledTransactions), 1)
        XCTAssertEqual(inventory.storedRecordCount(in: .investmentHoldings), 1)
        XCTAssertEqual(inventory.storedRecordCount(in: .savingsGoals), 1)
        XCTAssertEqual(inventory.nestedActivityCounts.investmentLots, 1)
        XCTAssertEqual(inventory.nestedActivityCounts.savingsGoalMovements, 1)
        XCTAssertTrue(inventory.nestedActivityCountsComplete)
        XCTAssertEqual(inventory.pendingLockedCaptureCount, 1)
        XCTAssertEqual(inventory.quarantinedRecordCount, 0)
        XCTAssertFalse(inventory.budgetStatusWidgetEnabled)
        XCTAssertEqual(
            inventory.defaultFilename,
            "MoneyUp-Inventory-0.6.0-1017.1-1777777777.json"
        )

        let exported = try XCTUnwrap(
            String(data: inventory.encodedJSON(), encoding: .utf8)
        )
        for privateValue in [
            "Private Merchant",
            "Private note",
            "Private Schedule",
            "Private Holding",
            "Private Goal",
            "Private Capture Payee",
            "Private capture note",
            "98.76",
            "SECRET",
            entry.id.uuidString,
            goal.id.uuidString,
        ] {
            XCTAssertFalse(exported.contains(privateValue))
        }
        XCTAssertTrue(exported.contains("\"journal_entries\" : 1"))
        XCTAssertTrue(exported.contains("\"investmentLots\" : 1"))
        await fixture.store.close()
    }

    func testPrivacySafeInventoryFlagsMissingDecodedNestedRecord() throws {
        let snapshot = DatabaseRecordCountSnapshot(
            schemaVersion: EncryptedRecordStore.currentSchemaVersion,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            storedRecordCounts: [
                RecordCollection.investmentHoldings.rawValue: 1
            ]
        )

        let inventory = PrivacySafeDataInventory(
            snapshot: snapshot,
            investmentHoldings: [],
            savingsGoals: [],
            appVersion: "0.6.0",
            buildNumber: "test",
            pendingLockedCaptureCount: 0,
            quarantinedRecordCount: 1,
            budgetStatusWidgetEnabled: false
        )

        XCTAssertEqual(inventory.storedRecordCount(in: .investmentHoldings), 1)
        XCTAssertEqual(inventory.nestedActivityCounts.investmentLots, 0)
        XCTAssertFalse(inventory.nestedActivityCountsComplete)
        let exported = try XCTUnwrap(
            String(data: inventory.encodedJSON(), encoding: .utf8)
        )
        XCTAssertFalse(exported.contains("recordID"))
        XCTAssertFalse(exported.contains("payload"))
    }

    @MainActor
    func testRestoreRejectsMalformedRelationshipWithoutChangingLiveSnapshot() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let currentProfile = UserProfile(baseCurrency: fixture.sgd)
        try await fixture.seed(
            profile: currentProfile,
            accounts: [fixture.wallet, fixture.usAccount, fixture.food]
        )
        let model = fixture.model(profile: currentProfile)
        let before = try await fixture.store.snapshot()

        let orphanEntry = try TransactionFactory.expense(
            amount: Money(8, currency: fixture.sgd),
            paidFrom: fixture.wallet.id,
            category: UUID(),
            occurredAt: Date(timeIntervalSinceReferenceDate: 400),
            payee: "Orphan"
        )
        let candidate = DatabaseSnapshot(
            schemaVersion: EncryptedRecordStore.currentSchemaVersion,
            records: [
                try storedRecord(
                    currentProfile,
                    id: UserProfile.primaryRecordID,
                    in: .profile
                ),
                try storedRecord(
                    fixture.wallet,
                    id: fixture.wallet.id.uuidString,
                    in: .accounts
                ),
                try storedRecord(
                    orphanEntry,
                    id: orphanEntry.id.uuidString,
                    in: .journalEntries
                )
            ]
        )
        let archive = try PortableArchive.seal(
            candidate,
            password: "restore-password"
        )

        do {
            try await model.restoreEncryptedBackup(
                archive,
                password: "restore-password"
            )
            XCTFail("Expected the orphaned journal relationship to be rejected")
        } catch {
            XCTAssertTrue(error is AppModelError)
        }

        let after = try await fixture.store.snapshot()
        XCTAssertEqual(after.schemaVersion, before.schemaVersion)
        XCTAssertEqual(after.records, before.records)
        XCTAssertEqual(model.accounts, [fixture.wallet, fixture.usAccount, fixture.food])
        XCTAssertEqual(model.state, .ready)
        await fixture.store.close()
    }

    @MainActor
    func testRestoreRejectsDuplicateLogicalIDsWithoutChangingLiveSnapshot() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let currentProfile = UserProfile(baseCurrency: fixture.sgd)
        try await fixture.seed(
            profile: currentProfile,
            accounts: [fixture.wallet, fixture.usAccount, fixture.food]
        )
        let model = fixture.model(profile: currentProfile)
        let before = try await fixture.store.snapshot()
        let duplicateID = try XCTUnwrap(
            UUID(uuidString: "ABCDEF12-3456-4789-ABCD-EF1234567890")
        )
        let duplicate = LedgerAccount(
            id: duplicateID,
            name: "Duplicate",
            kind: .asset,
            currency: fixture.sgd
        )
        let candidate = DatabaseSnapshot(
            schemaVersion: EncryptedRecordStore.currentSchemaVersion,
            records: [
                try storedRecord(
                    currentProfile,
                    id: UserProfile.primaryRecordID,
                    in: .profile
                ),
                try storedRecord(
                    duplicate,
                    id: duplicateID.uuidString,
                    in: .accounts
                ),
                try storedRecord(
                    duplicate,
                    id: duplicateID.uuidString.lowercased(),
                    in: .accounts
                )
            ]
        )
        let archive = try PortableArchive.seal(
            candidate,
            password: "restore-password"
        )

        do {
            try await model.restoreEncryptedBackup(
                archive,
                password: "restore-password"
            )
            XCTFail("Expected duplicate logical account IDs to be rejected")
        } catch {
            XCTAssertTrue(error is AppModelError)
        }

        let after = try await fixture.store.snapshot()
        XCTAssertEqual(after.records, before.records)
        XCTAssertEqual(model.state, .ready)
        await fixture.store.close()
    }

    func testRestoreCandidateRejectsSingleLowercaseUUIDPhysicalKey() throws {
        let accountID = try XCTUnwrap(
            UUID(uuidString: "ABCDEF12-3456-4789-ABCD-EF1234567890")
        )
        let account = LedgerAccount(
            id: accountID,
            name: "Lowercase alias",
            kind: .asset
        )
        let candidate = DatabaseSnapshot(
            schemaVersion: EncryptedRecordStore.currentSchemaVersion,
            records: [
                try storedRecord(
                    account,
                    id: accountID.uuidString.lowercased(),
                    in: .accounts
                )
            ]
        )

        XCTAssertThrowsError(
            try RestoreCandidateValidator.validateSnapshotIdentities(candidate)
        ) { error in
            XCTAssertTrue(error is AppModelError)
        }
    }

    @MainActor
    func testRestoreRejectsRecordPayloadIDMismatchWithoutChangingLiveSnapshot() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let currentProfile = UserProfile(baseCurrency: fixture.sgd)
        try await fixture.seed(
            profile: currentProfile,
            accounts: [fixture.wallet, fixture.usAccount, fixture.food]
        )
        let model = fixture.model(profile: currentProfile)
        let before = try await fixture.store.snapshot()
        let candidate = DatabaseSnapshot(
            schemaVersion: EncryptedRecordStore.currentSchemaVersion,
            records: [
                try storedRecord(
                    currentProfile,
                    id: UserProfile.primaryRecordID,
                    in: .profile
                ),
                try storedRecord(
                    fixture.wallet,
                    id: UUID().uuidString,
                    in: .accounts
                )
            ]
        )
        let archive = try PortableArchive.seal(
            candidate,
            password: "restore-password"
        )

        do {
            try await model.restoreEncryptedBackup(
                archive,
                password: "restore-password"
            )
            XCTFail("Expected the record and payload ID mismatch to be rejected")
        } catch {
            XCTAssertTrue(error is AppModelError)
        }

        let after = try await fixture.store.snapshot()
        XCTAssertEqual(after.records, before.records)
        XCTAssertEqual(model.state, .ready)
        await fixture.store.close()
    }

    @MainActor
    func testRestoreRejectsBookDataWithoutProfileBeforeLiveReplacement() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let currentProfile = UserProfile(baseCurrency: fixture.sgd)
        try await fixture.seed(
            profile: currentProfile,
            accounts: [fixture.wallet, fixture.usAccount, fixture.food]
        )
        let model = fixture.model(profile: currentProfile)
        let before = try await fixture.store.snapshot()
        let candidate = DatabaseSnapshot(
            schemaVersion: EncryptedRecordStore.currentSchemaVersion,
            records: [
                try storedRecord(
                    fixture.wallet,
                    id: fixture.wallet.id.uuidString,
                    in: .accounts
                )
            ]
        )
        let archive = try PortableArchive.seal(
            candidate,
            password: "restore-password"
        )

        do {
            try await model.restoreEncryptedBackup(
                archive,
                password: "restore-password"
            )
            XCTFail("Expected book data without a profile to be rejected")
        } catch {
            XCTAssertTrue(error is AppModelError)
        }

        let after = try await fixture.store.snapshot()
        XCTAssertEqual(after.records, before.records)
        XCTAssertEqual(model.profile, currentProfile)
        XCTAssertEqual(model.state, .ready)
        await fixture.store.close()
    }

    @MainActor
    func testCancellationAtRestoreCommitBoundaryLeavesLiveSnapshotUnchanged() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let currentProfile = UserProfile(baseCurrency: fixture.sgd)
        try await fixture.seed(
            profile: currentProfile,
            accounts: [fixture.wallet, fixture.usAccount, fixture.food]
        )
        let before = try await fixture.store.snapshot()
        let replacementProfile = UserProfile(baseCurrency: fixture.usd)
        let candidate = DatabaseSnapshot(
            schemaVersion: EncryptedRecordStore.currentSchemaVersion,
            records: [
                try storedRecord(
                    replacementProfile,
                    id: UserProfile.primaryRecordID,
                    in: .profile
                ),
                try storedRecord(
                    fixture.usAccount,
                    id: fixture.usAccount.id.uuidString,
                    in: .accounts
                )
            ]
        )
        let archive = try PortableArchive.seal(
            candidate,
            password: "restore-password"
        )
        let gate = AsyncGate()
        let model = fixture.model(
            profile: currentProfile,
            lifecycleHooks: hooks(pausing: .beforeRestoreCommit, at: gate)
        )
        let restoreTask = Task { @MainActor in
            try await model.restoreEncryptedBackup(
                archive,
                password: "restore-password"
            )
        }

        await gate.waitUntilReached()
        restoreTask.cancel()
        await gate.release()
        do {
            try await restoreTask.value
            XCTFail("Expected restore cancellation at the precommit boundary")
        } catch is CancellationError {
            // Expected.
        }

        let after = try await fixture.store.snapshot()
        XCTAssertEqual(after.schemaVersion, before.schemaVersion)
        XCTAssertEqual(after.records, before.records)
        XCTAssertEqual(model.profile, currentProfile)
        XCTAssertEqual(model.state, .ready)
        await fixture.store.close()
    }

    @MainActor
    func testCancellationAfterRestoreCommitRecoversJournalIndexesAndBalance() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let currentProfile = UserProfile(baseCurrency: fixture.sgd)
        let original = try fixture.expense(amount: 17)
        try await fixture.seed(
            profile: currentProfile,
            accounts: [fixture.wallet, fixture.usAccount, fixture.food],
            entries: [original]
        )
        let before = try await fixture.store.snapshot()
        let replacementProfile = UserProfile(baseCurrency: fixture.usd)
        let candidate = DatabaseSnapshot(
            schemaVersion: EncryptedRecordStore.currentSchemaVersion,
            records: [
                try storedRecord(
                    replacementProfile,
                    id: UserProfile.primaryRecordID,
                    in: .profile
                ),
                try storedRecord(
                    fixture.usAccount,
                    id: fixture.usAccount.id.uuidString,
                    in: .accounts
                )
            ]
        )
        let archive = try PortableArchive.seal(
            candidate,
            password: "restore-password"
        )
        let gate = AsyncGate()
        let model = fixture.model(
            profile: currentProfile,
            entries: [original],
            lifecycleHooks: hooks(
                pausing: .afterRestoreCommitBeforeCandidateLoad,
                at: gate
            )
        )
        let restoreTask = Task { @MainActor in
            try await model.restoreEncryptedBackup(
                archive,
                password: "restore-password"
            )
        }

        let reached = await gate.waitUntilReached(timeout: .seconds(5))
        guard reached else {
            restoreTask.cancel()
            await gate.release()
            _ = try? await restoreTask.value
            return XCTFail("Postcommit restore checkpoint timed out")
        }
        restoreTask.cancel()
        await gate.release()
        do {
            try await restoreTask.value
            XCTFail("Expected cancellation after candidate replacement")
        } catch is CancellationError {
            // The original error is preserved after rollback recovery succeeds.
        }

        let after = try await fixture.store.snapshot()
        XCTAssertEqual(after.schemaVersion, before.schemaVersion)
        XCTAssertEqual(after.records, before.records)
        XCTAssertEqual(model.profile, currentProfile)
        XCTAssertEqual(model.entries, [original])
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(
            model.displayBalanceResult(for: fixture.wallet).value?.amount,
            -17
        )

        let diagnostics = try await fixture.store.journalIndexDiagnostics()
        XCTAssertEqual(diagnostics.journalRecordCount, 1)
        XCTAssertEqual(diagnostics.indexedEntryCount, 1)
        XCTAssertEqual(diagnostics.indexedPostingCount, 2)
        let ledger = try await fixture.store.journalLedgerIndex(
            validAccountIDs: Set([
                fixture.wallet.id,
                fixture.usAccount.id,
                fixture.food.id
            ])
        )
        XCTAssertEqual(ledger.entryCount, 1)
        XCTAssertTrue(ledger.issues.isEmpty)
        XCTAssertEqual(
            ledger.balances[fixture.wallet.id]?[fixture.sgd]?.amount,
            -17
        )
        await fixture.store.close()
    }

    @MainActor
    func testRetainedRestoreFailureRepublishesTheUnchangedJournal() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let profile = UserProfile(baseCurrency: fixture.sgd)
        let original = try fixture.expense(amount: 17)
        try await fixture.seed(
            profile: profile,
            accounts: [fixture.wallet, fixture.usAccount, fixture.food],
            entries: [original]
        )
        let candidate = try await fixture.store.snapshot()
        let archive = try PortableArchive.seal(
            candidate,
            password: "restore-password"
        )
        let precommitGate = AsyncGate()
        let model = fixture.model(
            profile: profile,
            entries: [original],
            lifecycleHooks: hooks(
                pausing: .afterJournalProjectionInvalidationBeforeCommit,
                at: precommitGate
            ),
            retainsCompleteJournal: true
        )
        XCTAssertEqual(
            model.displayBalanceResult(for: fixture.wallet).value?.amount,
            -17
        )

        let restoreTask = Task { @MainActor in
            try await model.restoreEncryptedBackup(
                archive,
                password: "restore-password"
            )
        }
        let reached = await precommitGate.waitUntilReached(timeout: .seconds(5))
        XCTAssertTrue(reached, "Restore invalidation checkpoint timed out")
        XCTAssertFalse(model.journalRecentEntriesAreCurrent)
        XCTAssertTrue(model.entries.isEmpty)
        let durableCountBeforeFailure = try await fixture.store.count(
            in: .journalEntries
        )
        XCTAssertEqual(durableCountBeforeFailure, 1)

        // Closing the injected store makes the replacement fail before BEGIN;
        // the on-disk pre-restore book remains available for an independent open.
        await fixture.store.close()
        await precommitGate.release()
        do {
            try await restoreTask.value
            XCTFail("Expected the closed-store restore to fail")
        } catch {
            // The retained projection must be republished from the unchanged book.
        }

        XCTAssertEqual(model.entries, [original])
        XCTAssertTrue(model.journalRecentEntriesAreCurrent)
        XCTAssertEqual(model.journalEntryCount, 1)
        XCTAssertEqual(
            model.displayBalanceResult(for: fixture.wallet).value?.amount,
            -17
        )
        let reopened = try fixture.reopenStore()
        let persisted = try await reopened.fetchAll(
            JournalEntry.self,
            from: .journalEntries
        )
        XCTAssertEqual(persisted, [original])
        await reopened.close()
    }

    @MainActor
    func testRestoreFlushesDebouncedDraftAndBlocksProfileMutationBeforeCommit() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let currentProfile = UserProfile(baseCurrency: fixture.sgd)
        try await fixture.seed(
            profile: currentProfile,
            accounts: [fixture.wallet, fixture.food]
        )
        let candidate = try await fixture.store.snapshot()
        let archive = try PortableArchive.seal(
            candidate,
            password: "restore-password"
        )
        let gate = AsyncGate()
        let model = fixture.model(
            profile: currentProfile,
            lifecycleHooks: hooks(pausing: .beforeRestoreCommit, at: gate)
        )
        model.updateQuickLogDraft(QuickLogDraft(
            kind: .expense,
            amountText: "12",
            destinationAmountText: "",
            accountID: fixture.wallet.id,
            destinationAccountID: nil,
            categoryID: fixture.food.id,
            occurredAt: Date(timeIntervalSinceReferenceDate: 500),
            dateWasEdited: true,
            payee: "Pending draft",
            note: "",
            smartText: ""
        ))

        let restoreTask = Task { @MainActor in
            try await model.restoreEncryptedBackup(
                archive,
                password: "restore-password"
            )
        }
        await gate.waitUntilReached()
        do {
            try await model.updateAutoLockDelay(300)
            XCTFail("Expected profile persistence to respect restore lifecycle")
        } catch AppModelError.transactionInProgress {
            // The candidate remains the only pending durable state transition.
        }
        await gate.release()
        try await restoreTask.value
        try await Task.sleep(for: .milliseconds(350))

        let after = try await fixture.store.snapshot()
        XCTAssertEqual(after.schemaVersion, candidate.schemaVersion)
        XCTAssertEqual(
            after.records.filter {
                $0.collection
                    != RecordCollection.budgetConfigurationTimelines.rawValue
            },
            candidate.records
        )
        XCTAssertEqual(
            after.records.filter {
                $0.collection
                    == RecordCollection.budgetConfigurationTimelines.rawValue
            }.count,
            1
        )
        XCTAssertNil(model.quickLogDraft)
        let draftCount = try await fixture.store.count(in: .quickLogDrafts)
        XCTAssertEqual(draftCount, 0)
        await fixture.store.close()
    }

    func testRestoreIdentityValidationIncludesNetWorthSnapshots() throws {
        let sgd = try CurrencyCode("SGD")
        let snapshot = try NetWorthSnapshot(
            capturedAt: Date(timeIntervalSinceReferenceDate: 10),
            amounts: [try Money(1, currency: sgd)]
        )
        let candidate = DatabaseSnapshot(
            schemaVersion: EncryptedRecordStore.currentSchemaVersion,
            records: [
                try storedRecord(
                    snapshot,
                    id: UUID().uuidString,
                    in: .netWorthSnapshots
                )
            ]
        )

        XCTAssertThrowsError(
            try RestoreCandidateValidator.validateSnapshotIdentities(candidate)
        ) { error in
            XCTAssertTrue(error is AppModelError)
        }
    }

    func testRestoreRevisionIdentityRequiresAnExactSupportedSuffix() throws {
        let sgd = try CurrencyCode("SGD")
        let entry = try TransactionFactory.expense(
            amount: Money(1, currency: sgd),
            paidFrom: UUID(),
            category: UUID()
        )
        let ordinaryRevisionID = "\(entry.id.uuidString)-\(UUID().uuidString)"
        let lifecycleRevisionID = "\(entry.id.uuidString)-lifecycle-\(UUID().uuidString)"

        for recordID in [ordinaryRevisionID, lifecycleRevisionID] {
            let candidate = DatabaseSnapshot(
                schemaVersion: EncryptedRecordStore.currentSchemaVersion,
                records: [
                    try storedRecord(
                        entry,
                        id: recordID,
                        in: .journalEntryRevisions
                    )
                ]
            )
            XCTAssertNoThrow(
                try RestoreCandidateValidator.validateSnapshotIdentities(candidate)
            )
        }

        for recordID in [
            "\(entry.id.uuidString)-not-a-uuid",
            "\(entry.id.uuidString)-lifecycle-not-a-uuid",
            "\(entry.id.uuidString)-\(UUID().uuidString)-trailing"
        ] {
            let candidate = DatabaseSnapshot(
                schemaVersion: EncryptedRecordStore.currentSchemaVersion,
                records: [
                    try storedRecord(
                        entry,
                        id: recordID,
                        in: .journalEntryRevisions
                    )
                ]
            )
            XCTAssertThrowsError(
                try RestoreCandidateValidator.validateSnapshotIdentities(candidate)
            ) { error in
                XCTAssertTrue(error is AppModelError)
            }
        }
    }

    func testRestoreRelationshipValidationUsesTheDraftTransactionKindForSplits() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let profile = UserProfile(baseCurrency: fixture.sgd)
        let salary = LedgerAccount(name: "Salary", kind: .income)
        let splitID = UUID()
        let validIncomeDraft = QuickLogDraft(
            kind: .income,
            amountText: "100",
            destinationAmountText: "",
            accountID: fixture.wallet.id,
            destinationAccountID: nil,
            categoryID: salary.id,
            occurredAt: Date(timeIntervalSinceReferenceDate: 500),
            dateWasEdited: false,
            payee: "Employer",
            note: "",
            smartText: "",
            splitLines: [
                QuickLogSplitDraftLine(
                    id: splitID,
                    categoryID: salary.id,
                    amountText: "50"
                ),
                QuickLogSplitDraftLine(
                    categoryID: salary.id,
                    amountText: "50"
                )
            ]
        )

        try await RestoreCandidateValidator.validateRelationships(
            profile: profile,
            accounts: [fixture.wallet, salary],
            budgetNodes: [],
            scheduledTransactions: [],
            investmentHoldings: [],
            netWorthSnapshots: [],
            quickLogDraft: validIncomeDraft,
            in: fixture.store
        )

        var mismatchedKind = validIncomeDraft
        mismatchedKind.splitLines[0].categoryID = fixture.food.id
        do {
            try await RestoreCandidateValidator.validateRelationships(
                profile: profile,
                accounts: [fixture.wallet, fixture.food, salary],
                budgetNodes: [],
                scheduledTransactions: [],
                investmentHoldings: [],
                netWorthSnapshots: [],
                quickLogDraft: mismatchedKind,
                in: fixture.store
            )
            XCTFail("Expected a mismatched income split category to be rejected")
        } catch {
            XCTAssertTrue(error is AppModelError)
        }

        var duplicateLineIDs = validIncomeDraft
        duplicateLineIDs.splitLines[1].id = splitID
        do {
            try await RestoreCandidateValidator.validateRelationships(
                profile: profile,
                accounts: [fixture.wallet, salary],
                budgetNodes: [],
                scheduledTransactions: [],
                investmentHoldings: [],
                netWorthSnapshots: [],
                quickLogDraft: duplicateLineIDs,
                in: fixture.store
            )
            XCTFail("Expected duplicate draft split identities to be rejected")
        } catch {
            XCTAssertTrue(error is AppModelError)
        }

        await fixture.store.close()
    }

    func testRestoreRejectsDuplicateUnorderedExchangeRatePairOnSameDay() throws {
        let sgd = try CurrencyCode("SGD")
        let usd = try CurrencyCode("USD")
        let utc = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let effectiveAt = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 26
        )))
        let direct = try DatedExchangeRate(
            baseCurrency: sgd,
            quoteCurrency: usd,
            rate: Decimal(string: "0.78")!,
            effectiveAt: effectiveAt,
            calendar: calendar,
            timeZone: utc
        )
        let inverse = try DatedExchangeRate(
            baseCurrency: usd,
            quoteCurrency: sgd,
            rate: Decimal(string: "1.28")!,
            effectiveAt: effectiveAt.addingTimeInterval(3_600),
            calendar: calendar,
            timeZone: utc
        )
        let candidate = DatabaseSnapshot(
            schemaVersion: EncryptedRecordStore.currentSchemaVersion,
            records: [
                try storedRecord(
                    direct,
                    id: direct.id.uuidString,
                    in: .exchangeRates
                ),
                try storedRecord(
                    inverse,
                    id: inverse.id.uuidString,
                    in: .exchangeRates
                )
            ]
        )

        XCTAssertThrowsError(
            try RestoreCandidateValidator.validateSnapshotIdentities(candidate)
        ) { error in
            XCTAssertTrue(error is AppModelError)
        }
    }

    func testRestoreAllowsSameExchangeRatePairOnDifferentDays() throws {
        let sgd = try CurrencyCode("SGD")
        let usd = try CurrencyCode("USD")
        let utc = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let firstDay = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 26
        )))
        let rates = try [0, 1].map { dayOffset in
            try DatedExchangeRate(
                baseCurrency: sgd,
                quoteCurrency: usd,
                rate: Decimal(string: "0.78")!,
                effectiveAt: firstDay.addingTimeInterval(
                    TimeInterval(dayOffset * 86_400)
                ),
                calendar: calendar,
                timeZone: utc
            )
        }
        let candidate = DatabaseSnapshot(
            schemaVersion: EncryptedRecordStore.currentSchemaVersion,
            records: try rates.map {
                try storedRecord(
                    $0,
                    id: $0.id.uuidString,
                    in: .exchangeRates
                )
            }
        )

        XCTAssertNoThrow(
            try RestoreCandidateValidator.validateSnapshotIdentities(candidate)
        )
    }

    func testRestoreRejectsDuplicatePhysicalSingletonRecords() throws {
        let sgd = try CurrencyCode("SGD")
        let profile = UserProfile(baseCurrency: sgd)
        let candidate = DatabaseSnapshot(
            schemaVersion: EncryptedRecordStore.currentSchemaVersion,
            records: [
                try storedRecord(
                    profile,
                    id: UserProfile.primaryRecordID,
                    in: .profile
                ),
                try storedRecord(
                    profile,
                    id: UserProfile.primaryRecordID,
                    in: .profile,
                    updatedAt: 2_000
                )
            ]
        )

        XCTAssertThrowsError(
            try RestoreCandidateValidator.validateSnapshotIdentities(candidate)
        ) { error in
            XCTAssertTrue(error is AppModelError)
        }
    }

    func testRestoreRejectsAccountHierarchyCyclesAndKindMismatches() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            reportingTimeZoneIdentifier: "GMT"
        )
        let firstID = UUID()
        let secondID = UUID()
        let cycle = [
            LedgerAccount(
                id: firstID,
                name: "First",
                kind: .expense,
                parentID: secondID
            ),
            LedgerAccount(
                id: secondID,
                name: "Second",
                kind: .expense,
                parentID: firstID
            )
        ]
        let expenseParent = LedgerAccount(name: "Expense", kind: .expense)
        let mismatchedChild = LedgerAccount(
            name: "Income",
            kind: .income,
            parentID: expenseParent.id
        )

        for invalidAccounts in [cycle, [expenseParent, mismatchedChild]] {
            do {
                try await RestoreCandidateValidator.validateRelationships(
                    profile: profile,
                    accounts: invalidAccounts,
                    budgetNodes: [],
                    scheduledTransactions: [],
                    investmentHoldings: [],
                    netWorthSnapshots: [],
                    quickLogDraft: nil,
                    in: fixture.store
                )
                XCTFail("Expected an invalid account hierarchy to be rejected")
            } catch {
                XCTAssertTrue(error is AppModelError)
            }
        }
        await fixture.store.close()
    }

    func testAccountHierarchyScreeningHandlesDeepChainsAndInvalidDescendants() throws {
        var deepChain: [LedgerAccount] = []
        deepChain.reserveCapacity(12_000)
        var parentID: UUID?
        for index in 0..<12_000 {
            let account = LedgerAccount(
                name: "Depth \(index)",
                kind: .expense,
                parentID: parentID
            )
            deepChain.append(account)
            parentID = account.id
        }
        XCTAssertTrue(
            try AppModel.invalidAccountHierarchyIDs(in: deepChain).isEmpty
        )

        let firstID = UUID()
        let secondID = UUID()
        let descendantID = UUID()
        let orphanID = UUID()
        let orphanDescendantID = UUID()
        let invalidAccounts = [
            LedgerAccount(
                id: firstID,
                name: "Cycle first",
                kind: .expense,
                parentID: secondID
            ),
            LedgerAccount(
                id: secondID,
                name: "Cycle second",
                kind: .expense,
                parentID: firstID
            ),
            LedgerAccount(
                id: descendantID,
                name: "Cycle descendant",
                kind: .expense,
                parentID: firstID
            ),
            LedgerAccount(
                id: orphanID,
                name: "Orphan",
                kind: .expense,
                parentID: UUID()
            ),
            LedgerAccount(
                id: orphanDescendantID,
                name: "Orphan descendant",
                kind: .expense,
                parentID: orphanID
            )
        ]

        XCTAssertEqual(
            try AppModel.invalidAccountHierarchyIDs(in: invalidAccounts),
            Set([
                firstID,
                secondID,
                descendantID,
                orphanID,
                orphanDescendantID
            ])
        )
    }

    func testRestoreRejectsMalformedDuplicateAndUnownedSystemAccounts() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let profile = UserProfile(baseCurrency: fixture.sgd)
        let firstOpening = LedgerAccount(
            name: "Opening 1",
            kind: .equity,
            systemRole: .openingBalances
        )
        let secondOpening = LedgerAccount(
            name: "Opening 2",
            kind: .equity,
            systemRole: .openingBalances
        )
        let malformedOpening = LedgerAccount(
            name: "Malformed",
            kind: .trading,
            currency: fixture.sgd,
            systemRole: .openingBalances
        )
        let firstFX = LedgerAccount(
            name: "FX 1",
            kind: .trading,
            currency: fixture.sgd,
            systemRole: .foreignExchange
        )
        let secondFX = LedgerAccount(
            name: "FX 2",
            kind: .trading,
            currency: fixture.sgd,
            systemRole: .foreignExchange
        )
        let orphanPosition = LedgerAccount(
            name: "Orphan position",
            kind: .asset,
            currency: fixture.sgd,
            systemRole: .investmentPosition
        )

        let invalidSets = [
            [firstOpening, secondOpening],
            [malformedOpening],
            [firstFX, secondFX],
            [orphanPosition]
        ]
        for invalidAccounts in invalidSets {
            do {
                try await RestoreCandidateValidator.validateRelationships(
                    profile: profile,
                    accounts: invalidAccounts,
                    budgetNodes: [],
                    scheduledTransactions: [],
                    investmentHoldings: [],
                    netWorthSnapshots: [],
                    quickLogDraft: nil,
                    in: fixture.store
                )
                XCTFail("Expected invalid system-account topology to be rejected")
            } catch {
                XCTAssertTrue(error is AppModelError)
            }
        }
        await fixture.store.close()
    }

    func testRestoreRejectsSystemAccountUsedByOrdinaryEntry() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let opening = LedgerAccount(
            name: "Opening",
            kind: .equity,
            systemRole: .openingBalances
        )
        let entry = try JournalEntry(
            kind: .expense,
            postings: [
                Posting(
                    accountID: fixture.wallet.id,
                    money: try Money(-1, currency: fixture.sgd)
                ),
                Posting(
                    accountID: opening.id,
                    money: try Money(1, currency: fixture.sgd)
                )
            ]
        )
        try await fixture.store.upsert(
            entry,
            id: entry.id.uuidString,
            in: .journalEntries
        )

        do {
            try await RestoreCandidateValidator.validateRelationships(
                profile: UserProfile(baseCurrency: fixture.sgd),
                accounts: [fixture.wallet, opening],
                budgetNodes: [],
                scheduledTransactions: [],
                investmentHoldings: [],
                netWorthSnapshots: [],
                quickLogDraft: nil,
                in: fixture.store
            )
            XCTFail("Expected ordinary ownership of a system account to fail")
        } catch {
            XCTAssertTrue(error is AppModelError)
        }
        await fixture.store.close()
    }

    func testRestoreRequiresLinkedScheduleToMatchTheJournalEntry() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let entry = try TransactionFactory.expense(
            amount: try Money(9, currency: fixture.sgd),
            paidFrom: fixture.wallet.id,
            category: fixture.food.id,
            occurredAt: date
        )
        try await fixture.store.upsert(
            entry,
            id: entry.id.uuidString,
            in: .journalEntries
        )
        var schedule = try ScheduledTransaction(
            kind: .expense,
            name: "Subscription",
            amount: try Money(10, currency: fixture.sgd),
            accountID: fixture.wallet.id,
            categoryAccountID: fixture.food.id,
            nextOccurrence: date,
            frequency: .monthly,
            recurrenceTimeZoneIdentifier: calendar.timeZone.identifier
        )
        try schedule.resolveCurrent(
            occurrenceID: schedule.currentOccurrenceID,
            as: .matched,
            linkedEntryID: entry.id,
            at: date,
            calendar: calendar
        )

        do {
            try await RestoreCandidateValidator.validateRelationships(
                profile: UserProfile(
                    baseCurrency: fixture.sgd,
                    reportingTimeZoneIdentifier: calendar.timeZone.identifier
                ),
                accounts: [fixture.wallet, fixture.food],
                budgetNodes: [],
                scheduledTransactions: [schedule],
                investmentHoldings: [],
                netWorthSnapshots: [],
                quickLogDraft: nil,
                in: fixture.store
            )
            XCTFail("Expected a linked amount mismatch to be rejected")
        } catch {
            XCTAssertTrue(error is AppModelError)
        }

        var matchingSchedule = try ScheduledTransaction(
            kind: .expense,
            name: "Subscription",
            amount: try Money(9, currency: fixture.sgd),
            accountID: fixture.wallet.id,
            categoryAccountID: fixture.food.id,
            nextOccurrence: date,
            frequency: .monthly,
            recurrenceTimeZoneIdentifier: calendar.timeZone.identifier
        )
        try matchingSchedule.resolveCurrent(
            occurrenceID: matchingSchedule.currentOccurrenceID,
            as: .matched,
            linkedEntryID: entry.id,
            at: date,
            calendar: calendar
        )
        try await RestoreCandidateValidator.validateRelationships(
            profile: UserProfile(
                baseCurrency: fixture.sgd,
                reportingTimeZoneIdentifier: calendar.timeZone.identifier
            ),
            accounts: [fixture.wallet, fixture.food],
            budgetNodes: [],
            scheduledTransactions: [matchingSchedule],
            investmentHoldings: [],
            netWorthSnapshots: [],
            quickLogDraft: nil,
            in: fixture.store
        )
        await fixture.store.close()
    }

    func testRestoreRequiresEveryInvestmentEntryToHaveOneHoldingOwner() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let destination = LedgerAccount(
            name: "Unowned destination",
            kind: .asset,
            currency: fixture.sgd
        )
        let entry = try JournalEntry(
            kind: .investment,
            postings: [
                Posting(
                    accountID: fixture.wallet.id,
                    money: try Money(-10, currency: fixture.sgd)
                ),
                Posting(
                    accountID: destination.id,
                    money: try Money(10, currency: fixture.sgd)
                )
            ]
        )
        try await fixture.store.upsert(
            entry,
            id: entry.id.uuidString,
            in: .journalEntries
        )

        do {
            try await RestoreCandidateValidator.validateRelationships(
                profile: UserProfile(baseCurrency: fixture.sgd),
                accounts: [fixture.wallet, destination],
                budgetNodes: [],
                scheduledTransactions: [],
                investmentHoldings: [],
                netWorthSnapshots: [],
                quickLogDraft: nil,
                in: fixture.store
            )
            XCTFail("Expected an unowned investment entry to be rejected")
        } catch {
            XCTAssertTrue(error is AppModelError)
        }
        await fixture.store.close()
    }

    func testRestoreBudgetAttributionRequiresExactPostingOrAuditedRemap() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let source = LedgerAccount(name: "Old food", kind: .expense)
        let target = LedgerAccount(name: "Food", kind: .expense)
        let instant = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-31T10:30:00Z")
        )
        let originZone = try XCTUnwrap(
            TimeZone(identifier: "Pacific/Kiritimati")
        )
        let originalCandidate = try TransactionFactory.expense(
            amount: try Money(12, currency: fixture.sgd),
            paidFrom: fixture.wallet.id,
            category: source.id,
            occurredAt: instant
        )
        let original = try JournalEntry(
            id: originalCandidate.id,
            kind: originalCandidate.kind,
            occurredAt: originalCandidate.occurredAt,
            createdAt: originalCandidate.createdAt,
            payee: originalCandidate.payee,
            note: originalCandidate.note,
            postings: originalCandidate.postings,
            originContext: .capture(
                for: instant,
                timeZone: originZone
            )
        )
        let remappedPostings = original.postings.map { posting in
            Posting(
                id: posting.id,
                accountID: posting.accountID == source.id
                    ? target.id : posting.accountID,
                money: posting.money,
                memo: posting.memo
            )
        }
        let remapped = try JournalEntry(
            id: original.id,
            kind: original.kind,
            occurredAt: original.occurredAt,
            createdAt: original.createdAt,
            payee: original.payee,
            note: original.note,
            postings: remappedPostings,
            sourceSystem: original.sourceSystem,
            sourceFingerprint: original.sourceFingerprint,
            originContext: original.originContext
        )
        let attribution = try BudgetEntryAttribution(
            entry: original,
            originTimeZoneIdentifier: "GMT"
        )
        try await fixture.store.write([
            try RecordWrite(
                remapped,
                id: remapped.id.uuidString,
                in: .journalEntries
            ),
            try RecordWrite(
                attribution,
                id: attribution.id.uuidString,
                in: .budgetEntryAttributions
            )
        ])
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            reportingTimeZoneIdentifier: "GMT"
        )

        do {
            try await RestoreCandidateValidator.validateRelationships(
                profile: profile,
                accounts: [fixture.wallet, target],
                budgetNodes: [],
                scheduledTransactions: [],
                investmentHoldings: [],
                netWorthSnapshots: [],
                quickLogDraft: nil,
                in: fixture.store
            )
            XCTFail("Expected an unaudited attribution remap to be rejected")
        } catch {
            XCTAssertTrue(error is AppModelError)
        }

        let audit = LedgerAccountLifecycleAudit(
            action: .merged,
            before: source,
            after: target,
            targetID: target.id,
            affectedJournalEntryIDs: [remapped.id]
        )
        try await fixture.store.upsert(
            audit,
            id: audit.id.uuidString,
            in: .accountLifecycleAudit
        )
        try await RestoreCandidateValidator.validateRelationships(
            profile: profile,
            accounts: [fixture.wallet, target],
            budgetNodes: [],
            scheduledTransactions: [],
            investmentHoldings: [],
            netWorthSnapshots: [],
            quickLogDraft: nil,
            in: fixture.store
        )

        let encodedAttribution = try JSONEncoder().encode(attribution)
        var alteredOrigin = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: encodedAttribution
            ) as? [String: Any]
        )
        alteredOrigin["originTimeZoneIdentifier"] = "GMT"
        alteredOrigin["originUTCOffsetSeconds"] = 0
        alteredOrigin["originDayKey"] = "2026-07-31"
        let coherentlyAlteredAttribution = try JSONDecoder().decode(
            BudgetEntryAttribution.self,
            from: try JSONSerialization.data(withJSONObject: alteredOrigin)
        )
        try await fixture.store.upsert(
            coherentlyAlteredAttribution,
            id: coherentlyAlteredAttribution.id.uuidString,
            in: .budgetEntryAttributions
        )
        do {
            try await RestoreCandidateValidator.validateRelationships(
                profile: profile,
                accounts: [fixture.wallet, target],
                budgetNodes: [],
                scheduledTransactions: [],
                investmentHoldings: [],
                netWorthSnapshots: [],
                quickLogDraft: nil,
                in: fixture.store
            )
            XCTFail("Expected a coherent origin-context rewrite to be rejected")
        } catch {
            XCTAssertTrue(error is AppModelError)
        }
        try await fixture.store.upsert(
            attribution,
            id: attribution.id.uuidString,
            in: .budgetEntryAttributions
        )

        let tamperedPostings = try original.postings.map { posting in
            Posting(
                id: posting.id,
                accountID: posting.accountID,
                money: try Money(
                    posting.money.amount < .zero ? -13 : 13,
                    currency: posting.money.currency
                ),
                memo: posting.memo
            )
        }
        let tamperedEntry = try JournalEntry(
            id: original.id,
            kind: original.kind,
            occurredAt: original.occurredAt,
            createdAt: original.createdAt,
            payee: original.payee,
            note: original.note,
            postings: tamperedPostings,
            originContext: original.originContext
        )
        let tamperedAttribution = try BudgetEntryAttribution(
            entry: tamperedEntry,
            originTimeZoneIdentifier: "GMT"
        )
        try await fixture.store.upsert(
            tamperedAttribution,
            id: tamperedAttribution.id.uuidString,
            in: .budgetEntryAttributions
        )
        do {
            try await RestoreCandidateValidator.validateRelationships(
                profile: profile,
                accounts: [fixture.wallet, target],
                budgetNodes: [],
                scheduledTransactions: [],
                investmentHoldings: [],
                netWorthSnapshots: [],
                quickLogDraft: nil,
                in: fixture.store
            )
            XCTFail("Expected altered attribution money to be rejected")
        } catch {
            XCTAssertTrue(error is AppModelError)
        }
        await fixture.store.close()
    }

    func testRestoreAcceptsAFunctionalMultiHopLifecycleRemap() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let source = LedgerAccount(name: "Old food", kind: .expense)
        let intermediate = LedgerAccount(name: "Meals", kind: .expense)
        let target = LedgerAccount(name: "Food", kind: .expense)
        let original = try TransactionFactory.expense(
            amount: try Money(12, currency: fixture.sgd),
            paidFrom: fixture.wallet.id,
            category: source.id,
            occurredAt: Date(timeIntervalSinceReferenceDate: 70_000)
        )
        let remapped = try JournalEntry(
            id: original.id,
            kind: original.kind,
            occurredAt: original.occurredAt,
            createdAt: original.createdAt,
            postings: original.postings.map { posting in
                Posting(
                    id: posting.id,
                    accountID: posting.accountID == source.id
                        ? target.id : posting.accountID,
                    money: posting.money,
                    memo: posting.memo
                )
            },
            originContext: original.originContext
        )
        let attribution = try BudgetEntryAttribution(
            entry: original,
            originTimeZoneIdentifier: "GMT"
        )
        let firstAudit = LedgerAccountLifecycleAudit(
            action: .merged,
            before: source,
            after: intermediate,
            targetID: intermediate.id,
            affectedJournalEntryIDs: [remapped.id]
        )
        let secondAudit = LedgerAccountLifecycleAudit(
            action: .merged,
            before: intermediate,
            after: target,
            targetID: target.id,
            affectedJournalEntryIDs: [remapped.id]
        )
        try await fixture.store.write([
            try RecordWrite(
                firstAudit,
                id: firstAudit.id.uuidString,
                in: .accountLifecycleAudit
            ),
            try RecordWrite(
                secondAudit,
                id: secondAudit.id.uuidString,
                in: .accountLifecycleAudit
            )
        ])

        try await RestoreCandidateValidator.validateBudgetAttributionIntegrity(
            attributions: [attribution],
            journalEntries: [remapped],
            journalByID: [remapped.id: remapped],
            accountByID: [fixture.wallet.id: fixture.wallet, target.id: target],
            in: fixture.store,
            enforcesRestoreWorkLimits: true
        )
        await fixture.store.close()
    }

    func testRestoreRejectsSharedLineageAmplificationBeforePerEntryTraversal() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let source = LedgerAccount(name: "Old food", kind: .expense)
        let target = LedgerAccount(name: "Food", kind: .expense)
        let occurredAt = Date(timeIntervalSinceReferenceDate: 71_000)

        func entry(
            id: UUID,
            categoryID: UUID,
            postingIDs: (UUID, UUID) = (UUID(), UUID()),
            supersedesID: UUID? = nil
        ) throws -> JournalEntry {
            try JournalEntry(
                id: id,
                kind: .expense,
                occurredAt: occurredAt,
                createdAt: occurredAt,
                postings: [
                    Posting(
                        id: postingIDs.0,
                        accountID: fixture.wallet.id,
                        money: try Money(-1, currency: fixture.sgd)
                    ),
                    Posting(
                        id: postingIDs.1,
                        accountID: categoryID,
                        money: try Money(1, currency: fixture.sgd)
                    )
                ],
                supersedesID: supersedesID
            )
        }

        var revisions: [JournalEntry] = []
        var predecessorID: UUID?
        for _ in 0..<256 {
            let revision = try entry(
                id: UUID(),
                categoryID: source.id,
                supersedesID: predecessorID
            )
            revisions.append(revision)
            predecessorID = revision.id
        }
        try await fixture.store.write(try revisions.map { revision in
            try RecordWrite(
                revision,
                id: "\(revision.id.uuidString)-\(UUID().uuidString)",
                in: .journalEntryRevisions
            )
        })
        let sharedPredecessorID = try XCTUnwrap(predecessorID)

        var currentEntries: [JournalEntry] = []
        var attributions: [BudgetEntryAttribution] = []
        for _ in 0..<256 {
            let id = UUID()
            let postingIDs = (UUID(), UUID())
            let original = try entry(
                id: id,
                categoryID: source.id,
                postingIDs: postingIDs
            )
            let current = try entry(
                id: id,
                categoryID: target.id,
                postingIDs: postingIDs,
                supersedesID: sharedPredecessorID
            )
            currentEntries.append(current)
            attributions.append(try BudgetEntryAttribution(
                entry: original,
                originTimeZoneIdentifier: "GMT"
            ))
        }

        do {
            try await RestoreCandidateValidator.validateBudgetAttributionIntegrity(
                attributions: attributions,
                journalEntries: currentEntries,
                journalByID: Dictionary(
                    uniqueKeysWithValues: currentEntries.map { ($0.id, $0) }
                ),
                accountByID: [
                    fixture.wallet.id: fixture.wallet,
                    target.id: target
                ],
                in: fixture.store,
                enforcesRestoreWorkLimits: true
            )
            XCTFail("Expected a shared-predecessor restore graph to fail closed")
        } catch AppModelError.invalidBook {
            // One predecessor can never have multiple logical successors in a
            // book written by MoneyUp, so the amplification graph is rejected.
        }
        await fixture.store.close()
    }

    func testRestoreIdentityValidationObservesCancellation() async throws {
        let profile = UserProfile(baseCurrency: try CurrencyCode("SGD"))
        let candidate = DatabaseSnapshot(
            schemaVersion: EncryptedRecordStore.currentSchemaVersion,
            records: [try storedRecord(
                profile,
                id: UserProfile.primaryRecordID,
                in: .profile
            )]
        )
        let gate = AsyncGate()
        let validation = Task {
            await gate.suspend()
            try RestoreCandidateValidator.validateSnapshotIdentities(candidate)
        }
        let reached = await gate.waitUntilReached(timeout: .seconds(5))
        XCTAssertTrue(reached, "Cancellation checkpoint timed out")
        validation.cancel()
        await gate.release()

        do {
            try await validation.value
            XCTFail("Expected restore identity validation cancellation")
        } catch is CancellationError {
            // Cancellation is observed at the first bounded validation step.
        }
    }

    func testRestoreCandidateRecordLimitBoundaries() {
        XCTAssertTrue(RestoreCandidateValidator.isWithinCandidateRecordLimit(0))
        XCTAssertTrue(RestoreCandidateValidator.isWithinCandidateRecordLimit(
            RestoreCandidateValidator.maximumCandidateRecordCount
        ))
        XCTAssertFalse(RestoreCandidateValidator.isWithinCandidateRecordLimit(-1))
        XCTAssertFalse(RestoreCandidateValidator.isWithinCandidateRecordLimit(
            RestoreCandidateValidator.maximumCandidateRecordCount + 1
        ))
    }

    func testRestoreWorkLimitsRejectOversizedNestedRowsBeforeDomainDecode() throws {
        func payload(_ object: Any) throws -> Data {
            try JSONSerialization.data(withJSONObject: object)
        }
        func snapshot(
            _ collection: RecordCollection,
            _ payload: Data,
            recordID: String = UUID().uuidString
        ) -> DatabaseSnapshot {
            DatabaseSnapshot(
                schemaVersion: EncryptedRecordStore.currentSchemaVersion,
                records: [StoredRecordSnapshot(
                    collection: collection.rawValue,
                    recordID: recordID,
                    payload: payload,
                    updatedAt: 1
                )]
            )
        }

        let candidates = try [
            snapshot(.journalEntries, payload([
                "postings": Array(
                    repeating: [String: Any](),
                    count: JournalEntry.maximumPostingCount + 1
                )
            ])),
            snapshot(.investmentHoldings, payload([
                "lots": Array(
                    repeating: [String: Any](),
                    count: InvestmentHolding.maximumActivitiesPerCollection + 1
                )
            ])),
            snapshot(.savingsGoals, payload([
                "movements": Array(
                    repeating: [String: Any](),
                    count: SavingsGoal.maximumMovementCount + 1
                )
            ])),
            snapshot(.scheduledTransactions, payload([
                "resolutions": Array(
                    repeating: [String: Any](),
                    count: ScheduledTransaction.maximumResolutionCount + 1
                )
            ])),
            snapshot(.accountLifecycleAudit, payload([
                "affectedJournalEntryIDs": Array(
                    repeating: UUID().uuidString,
                    count: LedgerAccountLifecycleAudit
                        .maximumAffectedRecordCount
                ),
                "affectedScheduleIDs": [UUID().uuidString],
                "affectedHoldingIDs": []
            ])),
            snapshot(
                .quickLogDrafts,
                payload([
                    "splitLines": Array(
                        repeating: [String: Any](),
                        count: QuickLogDraft.maximumSplitLineCount + 1
                    )
                ]),
                recordID: QuickLogDraft.primaryRecordID
            ),
            snapshot(
                .budgetConfigurationTimelines,
                payload([
                    "revisions": [[
                        "nodes": Array(
                            repeating: [String: Any](),
                            count: BudgetConfigurationTimeline
                                .maximumNodesPerRevision + 1
                        )
                    ]]
                ]),
                recordID: BudgetConfigurationTimeline.primaryRecordID
            ),
            snapshot(
                .accounts,
                Data(repeating: 0x20, count: RecordWrite.maximumPayloadByteCount + 1)
            ),
            snapshot(
                .accounts,
                Data("{}".utf8),
                recordID: String(
                    repeating: "a",
                    count: RecordWrite.maximumRecordIDByteCount + 1
                )
            )
        ]

        for candidate in candidates {
            XCTAssertThrowsError(
                try RestoreCandidateValidator.validateSnapshotWorkLimits(
                    candidate
                )
            ) { error in
                XCTAssertTrue(error is AppModelError)
            }
        }
    }

    @MainActor
    func testBackupPreservesQuarantinedRawRowsWithoutRunningStrictRestoreDecode() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let oversizedGoalPayload = try JSONSerialization.data(
            withJSONObject: [
                "movements": Array(
                    repeating: [String: Any](),
                    count: SavingsGoal.maximumMovementCount + 1
                )
            ]
        )
        try await fixture.store.restore(DatabaseSnapshot(
            schemaVersion: EncryptedRecordStore.currentSchemaVersion,
            records: [StoredRecordSnapshot(
                collection: RecordCollection.savingsGoals.rawValue,
                recordID: UUID().uuidString,
                payload: oversizedGoalPayload,
                updatedAt: 1
            )]
        ))
        let model = fixture.model()

        let archive = try await model.encryptedBackup(
            password: "restore-shape-boundary"
        )
        let rawBackup = try PortableArchive.open(
            archive,
            password: "restore-shape-boundary"
        )
        XCTAssertEqual(rawBackup.records.count, 1)
        XCTAssertEqual(rawBackup.records.first?.payload, oversizedGoalPayload)
        XCTAssertThrowsError(
            try RestoreCandidateValidator.validateSnapshotWorkLimits(rawBackup)
        ) { error in
            XCTAssertTrue(error is AppModelError)
        }
        XCTAssertFalse(model.isWorking)
        await fixture.store.close()
    }

    @MainActor
    func testRecoveringStartupQuarantinesAliasedAccountIdentityWithoutResurrection() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await fixture.seed(
            profile: profile,
            accounts: [fixture.food]
        )
        let aliasRecordID = UUID().uuidString
        let currentSnapshot = try await fixture.store.snapshot()
        let aliasedSnapshot = DatabaseSnapshot(
            schemaVersion: currentSnapshot.schemaVersion,
            createdAt: currentSnapshot.createdAt,
            records: currentSnapshot.records + [StoredRecordSnapshot(
                collection: RecordCollection.accounts.rawValue,
                recordID: aliasRecordID,
                payload: try JSONEncoder().encode(fixture.wallet),
                updatedAt: Date().timeIntervalSince1970
            )]
        )
        try await fixture.store.restore(aliasedSnapshot)
        let model = fixture.model(
            profile: profile,
            accounts: [fixture.wallet, fixture.food]
        )

        try await model.reloadPersistedBookForTesting()

        XCTAssertFalse(model.accounts.contains { $0.id == fixture.wallet.id })
        XCTAssertNil(model.accountsByID[fixture.wallet.id])
        XCTAssertTrue(model.recoveryIssues.contains(
            "accounts/\(aliasRecordID)"
        ))

        do {
            try await model.deleteLedgerItem(id: fixture.wallet.id)
            XCTFail("An aliased physical identity must not be mutated")
        } catch AppModelError.missingRecord {
            // The alias is quarantined, so a canonical delete cannot miss it
            // and let the account reappear on the next launch.
        }
        let persistedAccountCount = try await fixture.store.count(
            in: .accounts
        )
        XCTAssertEqual(persistedAccountCount, 2)
        try await model.reloadPersistedBookForTesting()
        XCTAssertNil(model.accountsByID[fixture.wallet.id])
        await fixture.store.close()
    }

    @MainActor
    func testRecoveringStartupExcludesCanonicalJournalTwinFromEveryReadPath() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await fixture.seed(
            profile: profile,
            accounts: [fixture.wallet, fixture.food]
        )
        let entryID = try XCTUnwrap(
            UUID(uuidString: "ABCDEF12-3456-4789-ABCD-EF1234567890")
        )
        let candidate = try fixture.expense(amount: 7)
        let entry = try JournalEntry(
            id: entryID,
            kind: candidate.kind,
            occurredAt: candidate.occurredAt,
            createdAt: candidate.createdAt,
            payee: candidate.payee,
            note: candidate.note,
            postings: candidate.postings,
            originContext: candidate.originContext
        )
        let payload = try JSONEncoder().encode(entry)
        let snapshot = try await fixture.store.snapshot()
        try await fixture.store.restore(DatabaseSnapshot(
            schemaVersion: snapshot.schemaVersion,
            createdAt: snapshot.createdAt,
            records: snapshot.records + [
                StoredRecordSnapshot(
                    collection: RecordCollection.journalEntries.rawValue,
                    recordID: entry.id.uuidString,
                    payload: payload,
                    updatedAt: 1
                ),
                StoredRecordSnapshot(
                    collection: RecordCollection.journalEntries.rawValue,
                    recordID: entry.id.uuidString.lowercased(),
                    payload: payload,
                    updatedAt: 1
                )
            ]
        ))
        let model = fixture.model(
            profile: profile,
            accounts: [fixture.wallet, fixture.food]
        )

        try await model.reloadPersistedBookForTesting()

        XCTAssertEqual(model.journalEntryCount, 0)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertEqual(
            model.displayBalanceResult(for: fixture.wallet).value?.amount,
            0
        )
        let history = try await model.historyPage(query: HistoryQuery())
        XCTAssertTrue(history.entries.isEmpty)
        let summary = try await model.historySummary(query: HistoryQuery())
        XCTAssertEqual(summary.transactionCount, 0)
        XCTAssertTrue(summary.amountsByCurrency.isEmpty)
        let interval = DateInterval(
            start: entry.occurredAt.addingTimeInterval(-86_400),
            end: entry.occurredAt.addingTimeInterval(86_400)
        )
        let calendarEntries = try await model.calendarEntries(in: interval)
        XCTAssertTrue(calendarEntries.isEmpty)
        let postingEvents = try await model.journalPostingEvents(in: interval)
        XCTAssertTrue(postingEvents.isEmpty)
        XCTAssertTrue(model.recoveryIssues.contains {
            $0.contains(entry.id.uuidString.lowercased())
        })
        await fixture.store.close()
    }

    @MainActor
    func testRecoveringStartupFailsBudgetProjectionClosedForInvalidAttribution() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let source = LedgerAccount(name: "Old food", kind: .expense)
        let target = LedgerAccount(name: "Food", kind: .expense)
        let instant = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-31T10:30:00Z")
        )
        let originZone = try XCTUnwrap(
            TimeZone(identifier: "Pacific/Kiritimati")
        )
        let originalCandidate = try TransactionFactory.expense(
            amount: try Money(12, currency: fixture.sgd),
            paidFrom: fixture.wallet.id,
            category: source.id,
            occurredAt: instant
        )
        let original = try JournalEntry(
            id: originalCandidate.id,
            kind: originalCandidate.kind,
            occurredAt: originalCandidate.occurredAt,
            createdAt: originalCandidate.createdAt,
            payee: originalCandidate.payee,
            note: originalCandidate.note,
            postings: originalCandidate.postings,
            originContext: .capture(
                for: instant,
                timeZone: originZone
            )
        )
        let remappedPostings = original.postings.map { posting in
            Posting(
                id: posting.id,
                accountID: posting.accountID == source.id
                    ? target.id : posting.accountID,
                money: posting.money,
                memo: posting.memo
            )
        }
        let remapped = try JournalEntry(
            id: original.id,
            kind: original.kind,
            occurredAt: original.occurredAt,
            createdAt: original.createdAt,
            payee: original.payee,
            note: original.note,
            postings: remappedPostings,
            sourceSystem: original.sourceSystem,
            sourceFingerprint: original.sourceFingerprint,
            originContext: original.originContext
        )
        let attribution = try BudgetEntryAttribution(
            entry: original,
            originTimeZoneIdentifier: "GMT"
        )
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            reportingTimeZoneIdentifier: "GMT"
        )
        try await fixture.seed(
            profile: profile,
            accounts: [fixture.wallet, target],
            entries: [remapped]
        )
        try await fixture.store.upsert(
            attribution,
            id: attribution.id.uuidString,
            in: .budgetEntryAttributions
        )
        let model = fixture.model(profile: profile)

        try await model.reloadPersistedBookForTesting()

        XCTAssertTrue(model.recoveryIssues.contains(
            "budget_entry_attributions/inconsistent-history"
        ))
        guard case .unavailable = model.budgetProgressThisMonthResult() else {
            return XCTFail("Unaudited attribution remap must disable budget projection")
        }

        let audit = LedgerAccountLifecycleAudit(
            action: .merged,
            before: source,
            after: target,
            targetID: target.id,
            affectedJournalEntryIDs: [remapped.id]
        )
        try await fixture.store.upsert(
            audit,
            id: audit.id.uuidString,
            in: .accountLifecycleAudit
        )
        try await model.reloadPersistedBookForTesting()

        XCTAssertFalse(model.recoveryIssues.contains(
            "budget_entry_attributions/inconsistent-history"
        ))
        guard case let .available(progress) = model.budgetProgressThisMonthResult()
        else { return XCTFail("An exact audited remap must remain usable") }
        XCTAssertTrue(progress.isEmpty)

        let encodedAttribution = try JSONEncoder().encode(attribution)
        var alteredOrigin = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: encodedAttribution
            ) as? [String: Any]
        )
        alteredOrigin["originTimeZoneIdentifier"] = "GMT"
        alteredOrigin["originUTCOffsetSeconds"] = 0
        alteredOrigin["originDayKey"] = "2026-07-31"
        let coherentlyAlteredAttribution = try JSONDecoder().decode(
            BudgetEntryAttribution.self,
            from: try JSONSerialization.data(withJSONObject: alteredOrigin)
        )
        try await fixture.store.upsert(
            coherentlyAlteredAttribution,
            id: coherentlyAlteredAttribution.id.uuidString,
            in: .budgetEntryAttributions
        )
        try await model.reloadPersistedBookForTesting()

        XCTAssertTrue(model.recoveryIssues.contains(
            "budget_entry_attributions/inconsistent-history"
        ))
        guard case .unavailable = model.budgetProgressThisMonthResult() else {
            return XCTFail("A coherent civil-context rewrite must fail closed")
        }

        let tamperedPostings = try original.postings.map { posting in
            Posting(
                id: posting.id,
                accountID: posting.accountID,
                money: try Money(
                    posting.money.amount < .zero ? -13 : 13,
                    currency: posting.money.currency
                ),
                memo: posting.memo
            )
        }
        let tamperedEntry = try JournalEntry(
            id: original.id,
            kind: original.kind,
            occurredAt: original.occurredAt,
            createdAt: original.createdAt,
            payee: original.payee,
            note: original.note,
            postings: tamperedPostings,
            originContext: original.originContext
        )
        let tamperedAttribution = try BudgetEntryAttribution(
            entry: tamperedEntry,
            originTimeZoneIdentifier: "GMT"
        )
        try await fixture.store.upsert(
            tamperedAttribution,
            id: tamperedAttribution.id.uuidString,
            in: .budgetEntryAttributions
        )
        try await model.reloadPersistedBookForTesting()

        XCTAssertTrue(model.recoveryIssues.contains(
            "budget_entry_attributions/inconsistent-history"
        ))
        guard case .unavailable = model.budgetProgressThisMonthResult() else {
            return XCTFail("Audits must not excuse changed date/money/memo data")
        }
        await fixture.store.close()
    }

    @MainActor
    func testValidRestoreCommitsAfterIsolatedValidation() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let currentProfile = UserProfile(baseCurrency: fixture.sgd)
        try await fixture.seed(
            profile: currentProfile,
            accounts: [fixture.wallet, fixture.food]
        )
        let replacementProfile = UserProfile(baseCurrency: fixture.usd)
        let candidate = DatabaseSnapshot(
            schemaVersion: EncryptedRecordStore.currentSchemaVersion,
            records: [
                try storedRecord(
                    replacementProfile,
                    id: UserProfile.primaryRecordID,
                    in: .profile
                ),
                try storedRecord(
                    fixture.usAccount,
                    id: fixture.usAccount.id.uuidString,
                    in: .accounts
                )
            ]
        )
        let archive = try PortableArchive.seal(
            candidate,
            password: "restore-password"
        )
        let model = fixture.model(profile: currentProfile)

        try await model.restoreEncryptedBackup(
            archive,
            password: "restore-password"
        )

        let restored = try await fixture.store.snapshot()
        XCTAssertEqual(
            restored.records.filter {
                $0.collection
                    != RecordCollection.budgetConfigurationTimelines.rawValue
            },
            candidate.records.sorted {
                if $0.collection == $1.collection {
                    return $0.recordID < $1.recordID
                }
                return $0.collection < $1.collection
            }
        )
        XCTAssertEqual(
            restored.records.filter {
                $0.collection
                    == RecordCollection.budgetConfigurationTimelines.rawValue
            }.count,
            1
        )
        XCTAssertEqual(model.profile, replacementProfile)
        XCTAssertEqual(model.accounts, [fixture.usAccount])
        XCTAssertEqual(model.state, .ready)
        await fixture.store.close()
    }

    @MainActor
    func testLockDuringReceiptScanDiscardsTheStaleResult() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let gate = AsyncGate()
        let model = fixture.model(receiptRecognizer: { _ in
            await gate.suspend()
            return ["Cafe", "Total 12.50"]
        })

        let scanTask = Task { @MainActor in
            try await model.receiptDraft(
                from: Data([0x01]),
                prefersDayFirst: true
            )
        }

        await gate.waitUntilReached()
        model.lock()
        await gate.release()

        let scannedDraft = try await scanTask.value
        XCTAssertNil(scannedDraft)
        await model.waitForPendingStoreClose()
        XCTAssertEqual(model.state, .locked)
        XCTAssertNil(model.quickLogDraft)
    }

    @MainActor
    func testHistoryPagesAndRunningTotalRemainExactAcrossSparseMatches() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        var entries: [JournalEntry] = []
        for offset in 0..<25 {
            entries.append(
                try TransactionFactory.expense(
                    amount: Money(2, currency: fixture.sgd),
                    paidFrom: fixture.wallet.id,
                    category: fixture.food.id,
                    occurredAt: Date(timeIntervalSinceReferenceDate: TimeInterval(offset)),
                    payee: offset.isMultiple(of: 2) ? "Café" : "Grocer"
                )
            )
        }
        try await fixture.seed(
            profile: UserProfile(baseCurrency: fixture.sgd),
            accounts: [fixture.wallet, fixture.usAccount, fixture.food],
            entries: entries
        )
        let model = fixture.model(entries: entries)
        let query = HistoryQuery(searchText: "cafe", kind: .expense)

        var cursor: JournalEntryPageCursor?
        var loaded: [JournalEntry] = []
        repeat {
            let page = try await model.historyPage(
                query: query,
                after: cursor,
                limit: 7
            )
            loaded.append(contentsOf: page.entries)
            cursor = page.nextCursor
        } while cursor != nil

        XCTAssertEqual(loaded.count, 13)
        XCTAssertEqual(Set(loaded.map(\.id)).count, 13)
        XCTAssertTrue(loaded.allSatisfy { $0.payee == "Café" })
        let summary = try await model.historySummary(query: query)
        XCTAssertEqual(summary.transactionCount, 13)
        XCTAssertEqual(summary.amountsByCurrency[fixture.sgd], -26)
        await fixture.store.close()
    }

    @MainActor
    func testPagedHistoryWidensIndexAcrossExtremeOriginAndReportingZones() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let originZone = try XCTUnwrap(TimeZone(secondsFromGMT: 14 * 3_600))
        let reportingZone = try XCTUnwrap(TimeZone(identifier: "Etc/GMT+12"))
        var reportingCalendar = Calendar(identifier: .gregorian)
        reportingCalendar.timeZone = reportingZone
        let dayStart = try XCTUnwrap(
            reportingCalendar.date(from: DateComponents(year: 2026, month: 8, day: 27))
        )
        let dayEnd = try XCTUnwrap(
            reportingCalendar.date(byAdding: .day, value: 1, to: dayStart)
        )
        let targetInstant = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-27T00:30:00+14:00")
        )

        func expense(
            at occurredAt: Date,
            originTimeZone: TimeZone,
            payee: String
        ) throws -> JournalEntry {
            let candidate = try TransactionFactory.expense(
                amount: Money(2, currency: fixture.sgd),
                paidFrom: fixture.wallet.id,
                category: fixture.food.id,
                occurredAt: occurredAt,
                payee: payee
            )
            return try JournalEntry(
                id: candidate.id,
                kind: candidate.kind,
                occurredAt: candidate.occurredAt,
                createdAt: candidate.createdAt,
                payee: candidate.payee,
                note: candidate.note,
                postings: candidate.postings,
                originContext: .capture(
                    for: occurredAt,
                    timeZone: originTimeZone
                )
            )
        }

        let target = try expense(
            at: targetInstant,
            originTimeZone: originZone,
            payee: "Extreme-zone target"
        )
        let distractorStart = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-28T00:00:00Z")
        )
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        var entries = try (0..<200).map { offset in
            try expense(
                at: distractorStart.addingTimeInterval(TimeInterval(offset)),
                originTimeZone: utc,
                payee: "Other day"
            )
        }
        entries.append(target)
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            reportingTimeZoneIdentifier: reportingZone.identifier
        )
        try await fixture.seed(
            profile: profile,
            accounts: [fixture.wallet, fixture.usAccount, fixture.food],
            entries: entries
        )
        let model = fixture.model(profile: profile, entries: entries)
        let query = HistoryQuery(startDate: dayStart, endDateExclusive: dayEnd)

        XCTAssertGreaterThan(dayStart.timeIntervalSince(targetInstant), 86_400)
        XCTAssertLessThan(dayStart.timeIntervalSince(targetInstant), 172_800)
        let page = try await model.historyPage(query: query, limit: 1)
        XCTAssertEqual(page.entries.map(\.id), [target.id])
        let summary = try await model.historySummary(query: query)
        XCTAssertEqual(summary.transactionCount, 1)
        XCTAssertEqual(summary.amountsByCurrency[fixture.sgd], -2)
        await fixture.store.close()
    }

    @MainActor
    func testEveryInsightsPeriodKeepsTwelveMonthTrendContext() throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()
        var sharedTrendInterval: DateInterval?

        for period in ReportPeriod.allCases {
            guard case let .available(report) = model.reportResult(for: period) else {
                XCTFail("Expected report for \(period.rawValue)")
                continue
            }
            XCTAssertEqual(report.monthlyFlows.count, 12)
            if let sharedTrendInterval {
                XCTAssertEqual(report.trendInterval, sharedTrendInterval)
            } else {
                sharedTrendInterval = report.trendInterval
            }
        }
    }

    @MainActor
    func testReceiptAnalysisReturnsReviewableSuggestionsMappedToTheOpenBook() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model(receiptRecognizer: { _ in
            ["Cafe Nero", "TOTAL S$ 12.50"]
        })

        let result = try await model.receiptAnalysis(
            from: Data([0x01]),
            prefersDayFirst: true
        )

        XCTAssertEqual(result?.draft.amount, Decimal(string: "12.50"))
        XCTAssertEqual(result?.draft.payee, "Cafe Nero")
        XCTAssertEqual(result?.draft.categoryID, fixture.food.id)
        XCTAssertEqual(result?.draft.source, .receipt)
        XCTAssertEqual(result?.amountCandidates, [Decimal(string: "12.50")!])
        XCTAssertEqual(result?.categoryHint, .food)
    }

    @MainActor
    func testEraseDuringPendingCommitWaitsThenRemovesTheCommittedDatabase() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let gate = AsyncGate()
        let model = fixture.model(
            lifecycleHooks: hooks(pausing: .beforeJournalCommit, at: gate)
        )

        let saveTask = Task { @MainActor in
            try await model.logExpense(
                amount: 18,
                accountID: fixture.wallet.id,
                categoryID: fixture.food.id,
                occurredAt: Date(timeIntervalSinceReferenceDate: 300),
                payee: "Pending cafe",
                note: nil
            )
        }
        await gate.waitUntilReached()

        let eraseTask = Task { @MainActor in
            await model.eraseAllDataAndRestart()
        }
        for _ in 0..<100 {
            if model.state == .launching { break }
            await Task.yield()
        }
        XCTAssertEqual(model.state, .launching)
        await gate.release()

        let savedID = try await saveTask.value
        XCTAssertNil(savedID)
        await eraseTask.value
        XCTAssertEqual(model.state, .onboarding)
        XCTAssertNil(model.profile)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.databaseURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.databaseURL.path + "-wal")
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.databaseURL.path + "-shm")
        )
    }

    @MainActor
    func testErasePersistsIntentBeforeDeletingMainKeyAndClearsItLast() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let events = EraseEventRecorder()
        let captureStore = EraseRecordingLockedCaptureStore(events: events)
        let intent = DataEraseIntentAccess(
            isPending: { false },
            markPending: { events.record("intent-marked") },
            clear: { events.record("intent-cleared") }
        )
        let model = fixture.model(
            lockedCaptureStore: captureStore,
            deleteDatabaseKey: { events.record("database-key-deleted") },
            dataEraseIntent: intent
        )

        await model.eraseAllDataAndRestart()

        XCTAssertEqual(
            events.snapshot(),
            [
                "intent-marked",
                "database-key-deleted",
                "locked-capture-erased",
                "intent-cleared"
            ]
        )
        XCTAssertEqual(model.state, .onboarding)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.databaseURL.path))
    }

    @MainActor
    func testEraseIntentWriteFailurePerformsNoDestructiveStep() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let artifactsBeforeErase = DatabaseKeyCreationPolicy.artifactURLs(
            for: fixture.databaseURL
        ).filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        XCTAssertFalse(artifactsBeforeErase.isEmpty)
        let events = EraseEventRecorder()
        let captureStore = EraseRecordingLockedCaptureStore(events: events)
        let intent = DataEraseIntentAccess(
            isPending: { false },
            markPending: {
                events.record("intent-mark-attempted")
                throw DatabaseKeyStoreError.unexpectedStatus(-31_337)
            },
            clear: { events.record("intent-cleared") }
        )
        let model = fixture.model(
            lockedCaptureStore: captureStore,
            deleteDatabaseKey: { events.record("database-key-deleted") },
            dataEraseIntent: intent
        )

        await model.eraseAllDataAndRestart()

        XCTAssertEqual(events.snapshot(), ["intent-mark-attempted"])
        guard case .failed = model.state else {
            XCTFail("A failed durable marker must abort erase")
            await fixture.store.close()
            return
        }
        XCTAssertTrue(artifactsBeforeErase.allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        })
        await fixture.store.close()
    }

    @MainActor
    func testPendingEraseFailureLeavesIntentAndBookArtifactsCryptographicallyErased() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoneyUpEraseResumeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("moneyup.sqlite")
        let artifactURLs = DatabaseKeyCreationPolicy.artifactURLs(
            for: databaseURL
        )
        for url in artifactURLs {
            try Data([0xa5]).write(to: url)
        }
        let events = EraseEventRecorder()
        let captureStore = EraseRecordingLockedCaptureStore(
            events: events,
            eraseError: LockedCaptureStoreError.unavailable
        )

        do {
            try await AppModel.completePendingDataErase(
                databaseURL: databaseURL,
                deleteDatabaseKey: {
                    events.record("database-key-deleted")
                },
                lockedCaptureStore: captureStore,
                clearEraseIntent: { events.record("intent-cleared") }
            )
            XCTFail("A failed inbox erase must keep the durable intent")
        } catch LockedCaptureStoreError.unavailable {
            // Startup can retry the idempotent completion while the marker stays.
        }

        XCTAssertEqual(
            events.snapshot(),
            ["database-key-deleted", "locked-capture-erased"]
        )
        XCTAssertTrue(artifactURLs.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        })
    }

    @MainActor
    func testStartupCompletesPendingEraseBeforeOpeningReplacementStore() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let replacementDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoneyUpEraseReplacement-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: replacementDirectory) }
        let replacementStore = try EncryptedRecordStore(
            databaseURL: replacementDirectory.appendingPathComponent("replacement.sqlite"),
            key: Data(repeating: 0x71, count: 32)
        )
        let events = EraseEventRecorder()
        let captureStore = EraseRecordingLockedCaptureStore(events: events)
        let intent = DataEraseIntentAccess(
            isPending: {
                events.record("intent-checked")
                return true
            },
            markPending: { events.record("unexpected-intent-mark") },
            clear: { events.record("intent-cleared") }
        )
        let model = fixture.model(
            lockedCaptureStore: captureStore,
            deleteDatabaseKey: { events.record("database-key-deleted") },
            dataEraseIntent: intent,
            openDatabaseStore: { _ in
                events.record("database-opened")
                return replacementStore
            }
        )

        await model.start()

        XCTAssertEqual(
            events.snapshot(),
            [
                "intent-checked",
                "database-key-deleted",
                "locked-capture-erased",
                "intent-cleared",
                "database-opened"
            ]
        )
        XCTAssertEqual(model.state, .onboarding)
        XCTAssertNil(model.profile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.databaseURL.path))
        await replacementStore.close()
    }

    @MainActor
    func testStartupCleanupFailureKeepsEraseIntentAndNeverOpensDatabase() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let replacementDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoneyUpEraseFailure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: replacementDirectory) }
        let replacementStore = try EncryptedRecordStore(
            databaseURL: replacementDirectory.appendingPathComponent("replacement.sqlite"),
            key: Data(repeating: 0x72, count: 32)
        )
        let events = EraseEventRecorder()
        let captureStore = EraseRecordingLockedCaptureStore(events: events)
        let intent = DataEraseIntentAccess(
            isPending: {
                events.record("intent-checked")
                return true
            },
            markPending: { events.record("unexpected-intent-mark") },
            clear: { events.record("intent-cleared") }
        )
        let model = fixture.model(
            lockedCaptureStore: captureStore,
            deleteDatabaseKey: {
                events.record("database-key-delete-attempted")
                throw DatabaseKeyStoreError.authenticationCancelled
            },
            dataEraseIntent: intent,
            openDatabaseStore: { _ in
                events.record("database-opened")
                return replacementStore
            }
        )

        await model.start()

        XCTAssertEqual(
            events.snapshot(),
            [
                "intent-checked",
                "database-key-delete-attempted"
            ]
        )
        guard case .failed = model.state else {
            XCTFail("A partial erase must fail closed")
            await replacementStore.close()
            return
        }
        XCTAssertNil(model.profile)
        XCTAssertTrue(model.accounts.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.databaseURL.path))
        await replacementStore.close()
    }

    @MainActor
    func testStartupRetriesClearFailureIdempotentlyBeforeOpeningOnce() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let replacementDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoneyUpEraseClearRetry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: replacementDirectory) }
        let replacementStore = try EncryptedRecordStore(
            databaseURL: replacementDirectory.appendingPathComponent("replacement.sqlite"),
            key: Data(repeating: 0x73, count: 32)
        )
        let events = EraseEventRecorder()
        let intent = RetryingEraseIntent(
            events: events,
            clearFailuresRemaining: 1
        )
        let captureStore = EraseRecordingLockedCaptureStore(events: events)
        let model = fixture.model(
            lockedCaptureStore: captureStore,
            deleteDatabaseKey: { events.record("database-key-deleted") },
            dataEraseIntent: intent.access,
            openDatabaseStore: { _ in
                events.record("database-opened")
                return replacementStore
            }
        )

        await model.start()

        guard case .failed = model.state else {
            XCTFail("A marker-clear failure must prevent opening")
            await replacementStore.close()
            return
        }
        XCTAssertTrue(intent.pending)
        XCTAssertEqual(events.snapshot().filter { $0 == "database-opened" }.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.databaseURL.path))

        await model.start()

        XCTAssertFalse(intent.pending)
        XCTAssertEqual(model.state, .onboarding)
        XCTAssertEqual(
            events.snapshot(),
            [
                "intent-checked",
                "database-key-deleted",
                "locked-capture-erased",
                "intent-clear-attempted",
                "intent-checked",
                "database-key-deleted",
                "locked-capture-erased",
                "intent-clear-attempted",
                "database-opened"
            ]
        )
        await replacementStore.close()
    }

    @MainActor
    func testStaleGenerationWriteDoesNotRepopulateMemoryAfterLock() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let gate = AsyncGate()
        let model = fixture.model(
            lifecycleHooks: hooks(pausing: .afterAccountWriteBeforeApply, at: gate)
        )

        let addTask = Task { @MainActor in
            try await model.addAccount(
                name: "Secondary wallet",
                type: .cash,
                currencyCode: "SGD"
            )
        }

        await gate.waitUntilReached()
        model.lock()
        await gate.release()
        try await addTask.value
        await model.waitForPendingStoreClose()

        XCTAssertEqual(model.state, .locked)
        XCTAssertTrue(model.accounts.isEmpty)
        let reopened = try fixture.reopenStore()
        let persisted = try await reopened.fetchAll(
            LedgerAccount.self,
            from: .accounts
        )
        XCTAssertEqual(persisted.map(\.name), ["Secondary wallet"])
        await reopened.close()
    }

    @MainActor
    func testOnboardingAcceptsAssetOverdraftAndCreatesItsOpeningEntry() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()

        try await model.completeOnboarding(
            baseCurrencyCode: "SGD",
            accountName: "Overdraft account",
            accountType: .bank,
            startingBalance: -75
        )

        let account = try XCTUnwrap(
            model.userAccounts.first { $0.name == "Overdraft account" }
        )
        XCTAssertEqual(account.kind, .asset)
        XCTAssertEqual(
            model.displayBalanceResult(for: account).value?.amount,
            -75
        )
        XCTAssertEqual(model.entries.count, 1)
        let storedEntryCount = try await fixture.store.count(in: .journalEntries)
        XCTAssertEqual(storedEntryCount, 1)
        await fixture.store.close()
    }

    @MainActor
    func testAddingLiabilityTreatsPositiveOpeningValueAsAmountOwed() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()

        try await model.addAccount(
            name: "Travel card",
            type: .creditCard,
            currencyCode: "SGD",
            startingBalance: 450
        )

        let account = try XCTUnwrap(
            model.userAccounts.first { $0.name == "Travel card" }
        )
        XCTAssertEqual(account.kind, .liability)
        XCTAssertEqual(
            model.displayBalanceResult(for: account).value?.amount,
            450
        )
        XCTAssertEqual(model.entries.count, 1)

        do {
            try await model.setAccountBalance(
                accountID: account.id,
                displayBalance: -1
            )
            XCTFail("Expected a negative amount-owed rejection")
        } catch AppModelError.negativeAmount {
            // Expected: balance reconciliation keeps liability semantics too.
        }
        XCTAssertEqual(
            model.displayBalanceResult(for: account).value?.amount,
            450
        )
        await fixture.store.close()
    }

    @MainActor
    func testAddingLiabilityRejectsNegativeAmountOwedBeforeWriting() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()

        do {
            try await model.addAccount(
                name: "Invalid card",
                type: .creditCard,
                currencyCode: "SGD",
                startingBalance: -10
            )
            XCTFail("Expected a negative amount-owed rejection")
        } catch AppModelError.negativeAmount {
            // Expected: liabilities use a non-negative consumer amount owed.
        }

        let storedAccountCount = try await fixture.store.count(in: .accounts)
        let storedEntryCount = try await fixture.store.count(in: .journalEntries)
        XCTAssertEqual(storedAccountCount, 0)
        XCTAssertEqual(storedEntryCount, 0)
        await fixture.store.close()
    }

    @MainActor
    func testLockWaitsForCapturePromotionAndKeepsOneDurableDraft() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let capture = LockedCapture(
            kind: .expense,
            amountText: "12.50",
            occurredAt: Date(timeIntervalSinceReferenceDate: 400),
            payee: "Captured cafe"
        )
        let captureStore = InMemoryLockedCaptureStore(captures: [capture])
        let gate = AsyncGate()
        let model = fixture.model(
            lockedCaptureStore: captureStore,
            lifecycleHooks: hooks(pausing: .afterCaptureDraftPersisted, at: gate)
        )

        let promotionTask = Task { @MainActor in
            try await model.promotePendingLockedCapture()
        }
        await gate.waitUntilReached()
        model.lock()
        await gate.release()
        try await promotionTask.value
        await model.waitForPendingStoreClose()

        XCTAssertEqual(model.state, .locked)
        XCTAssertNil(model.quickLogDraft)
        let remainingCaptures = try await captureStore.all()
        XCTAssertTrue(remainingCaptures.isEmpty)

        let reopened = try fixture.reopenStore()
        let promotedDraft = try await reopened.fetch(
            QuickLogDraft.self,
            id: QuickLogDraft.primaryRecordID,
            from: .quickLogDrafts
        )
        let promotedDraftCount = try await reopened.count(in: .quickLogDrafts)
        XCTAssertEqual(promotedDraft?.sourceCaptureID, capture.id)
        XCTAssertEqual(promotedDraftCount, 1)
        await reopened.close()
    }

    @MainActor
    func testRestoreCannotCrossCapturePromotionHandoff() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await fixture.seed(
            profile: profile,
            accounts: [fixture.wallet, fixture.usAccount, fixture.food]
        )
        let archive = try PortableArchive.seal(
            try await fixture.store.snapshot(),
            password: "capture restore barrier"
        )
        let capture = LockedCapture(
            kind: .expense,
            amountText: "22",
            occurredAt: Date(timeIntervalSinceReferenceDate: 400.5)
        )
        let captureStore = InMemoryLockedCaptureStore(captures: [capture])
        let gate = AsyncGate()
        let model = fixture.model(
            profile: profile,
            lockedCaptureStore: captureStore,
            lifecycleHooks: hooks(pausing: .afterCaptureDraftPersisted, at: gate)
        )
        let promotion = Task { @MainActor in
            try await model.promotePendingLockedCapture()
        }
        await gate.waitUntilReached()

        do {
            try await model.restoreEncryptedBackup(
                archive,
                password: "capture restore barrier"
            )
            XCTFail("Restore must not cross the capture handoff")
        } catch AppModelError.transactionInProgress {
            // Expected while the draft/inbox ownership transfer is active.
        }

        await gate.release()
        try await promotion.value
        let remainingCaptures = try await captureStore.all()
        XCTAssertTrue(remainingCaptures.isEmpty)
        XCTAssertEqual(model.quickLogDraft?.sourceCaptureID, capture.id)
        let storedDraft = try await fixture.store.fetch(
            QuickLogDraft.self,
            id: QuickLogDraft.primaryRecordID,
            from: .quickLogDrafts
        )
        XCTAssertEqual(storedDraft?.sourceCaptureID, capture.id)
        await fixture.store.close()
    }

    @MainActor
    func testReviewedCaptureRemovalFailureCannotCreateDuplicateTransaction() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let capture = LockedCapture(
            kind: .expense,
            amountText: "12.50",
            occurredAt: Date(timeIntervalSinceReferenceDate: 401),
            payee: "Retry-safe cafe"
        )
        let captureStore = InMemoryLockedCaptureStore(
            captures: [capture],
            removeFailuresRemaining: 1
        )
        let model = fixture.model(lockedCaptureStore: captureStore)

        do {
            try await model.promotePendingLockedCapture()
            XCTFail("Expected the injected inbox removal failure")
        } catch LockedCaptureStoreError.unavailable {
            // The SQLCipher draft and redacted queue copy intentionally both
            // survive this interrupted handoff.
        }

        XCTAssertEqual(model.quickLogDraft?.sourceCaptureID, capture.id)
        XCTAssertEqual(model.pendingLockedCaptureCount, 1)
        let capturesAfterFailedHandoff = try await captureStore.all()
        let persistedDraftCount = try await fixture.store.count(in: .quickLogDrafts)
        XCTAssertEqual(capturesAfterFailedHandoff, [capture])
        XCTAssertEqual(model.entries.count, 0)
        XCTAssertEqual(persistedDraftCount, 1)

        _ = try await model.logExpense(
            amount: 12.50,
            accountID: fixture.wallet.id,
            categoryID: fixture.food.id,
            occurredAt: capture.occurredAt,
            payee: capture.payee,
            note: nil
        )

        let capturesAfterSave = try await captureStore.all()
        let persistedDraftCountAfterSave = try await fixture.store.count(
            in: .quickLogDrafts
        )
        XCTAssertTrue(capturesAfterSave.isEmpty)
        XCTAssertNil(model.quickLogDraft)
        XCTAssertEqual(model.pendingLockedCaptureCount, 0)
        XCTAssertEqual(model.entries.count, 1)
        XCTAssertEqual(persistedDraftCountAfterSave, 0)
        try await model.promotePendingLockedCapture()
        XCTAssertNil(model.quickLogDraft)
        XCTAssertEqual(model.entries.count, 1)
        await fixture.store.close()
    }

    @MainActor
    func testLockAfterCaptureHandoffCommitsExactlyOnceAndLeavesNoQueueCopy() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let capture = LockedCapture(
            kind: .expense,
            amountText: "8.75",
            occurredAt: Date(timeIntervalSinceReferenceDate: 402),
            payee: "Background cafe"
        )
        let captureStore = InMemoryLockedCaptureStore(captures: [capture])
        let gate = AsyncGate()
        let model = fixture.model(
            lockedCaptureStore: captureStore,
            lifecycleHooks: hooks(pausing: .beforeJournalCommit, at: gate)
        )
        try await model.promotePendingLockedCapture()

        let saveTask = Task { @MainActor in
            try await model.logExpense(
                amount: 8.75,
                accountID: fixture.wallet.id,
                categoryID: fixture.food.id,
                occurredAt: capture.occurredAt,
                payee: capture.payee,
                note: nil
            )
        }
        await gate.waitUntilReached()
        let capturesBeforeCommit = try await captureStore.all()
        XCTAssertTrue(capturesBeforeCommit.isEmpty)

        model.lock()
        await gate.release()
        let savedID = try await saveTask.value
        XCTAssertNotNil(savedID)
        await model.waitForPendingStoreClose()

        let reopened = try fixture.reopenStore()
        let persistedEntries = try await reopened.fetchAll(
            JournalEntry.self,
            from: .journalEntries
        )
        let persistedDraftCount = try await reopened.count(in: .quickLogDrafts)
        let capturesAfterCommit = try await captureStore.all()
        XCTAssertEqual(model.state, .locked)
        XCTAssertEqual(persistedEntries.count, 1)
        XCTAssertEqual(persistedEntries.first?.payee, capture.payee)
        XCTAssertEqual(persistedDraftCount, 0)
        XCTAssertTrue(capturesAfterCommit.isEmpty)
        await reopened.close()
    }

    @MainActor
    func testInvalidBudgetReturnsUnavailableStateInsteadOfEmptyOrZeroValues() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let duplicate = BudgetNode(id: fixture.food.id, name: "Food")
        let model = fixture.model(budgetNodes: [duplicate, duplicate])

        switch model.budgetProgressThisMonthResult() {
        case .available:
            XCTFail("Expected an explicit unavailable budget state")
        case let .unavailable(issue):
            XCTAssertEqual(issue, .budgetCalculationFailed)
        }

        switch model.budgetPlanSummaryThisMonthResult() {
        case .available:
            XCTFail("Expected an explicit unavailable budget summary")
        case let .unavailable(issue):
            XCTAssertEqual(issue, .budgetCalculationFailed)
        }
        await fixture.store.close()
    }

    @MainActor
    func testBudgetTreeCacheReusesAndInvalidatesByBudgetRevisionAndProfile() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let budget = BudgetNode(
            id: fixture.food.id,
            name: fixture.food.name,
            limit: try Money(100, currency: fixture.sgd),
            purpose: .flexible
        )
        let model = fixture.model(budgetNodes: [budget])

        XCTAssertEqual(model.budgetTreeCacheBuildCount, 0)
        _ = model.budgetPurposeOverview()
        _ = model.budgetProgressThisMonthResult()
        _ = model.budgetPlanSummaryThisMonthResult()
        XCTAssertEqual(model.budgetTreeCacheBuildCount, 1)

        try await model.setBudgetLimit(
            categoryID: fixture.food.id,
            amount: 125,
            purpose: .flexible
        )
        XCTAssertEqual(model.budgetTreeCacheBuildCount, 1)
        _ = model.budgetPurposeOverview()
        XCTAssertEqual(model.budgetTreeCacheBuildCount, 2)

        try await model.updateAutoLockDelay(300)
        _ = model.budgetPurposeOverview()
        XCTAssertEqual(model.budgetTreeCacheBuildCount, 3)
        await fixture.store.close()
    }

    @MainActor
    func testReplacingEntryRetainsEncryptedRevisionAndInvalidatesBalanceCache() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let original = try fixture.expense(amount: 10)
        let model = fixture.model(entries: [original])

        XCTAssertEqual(
            model.displayBalanceResult(for: fixture.wallet).value?.amount,
            -10
        )

        try await model.replaceEntry(
            id: original.id,
            kind: .expense,
            amount: 20,
            destinationAmount: nil,
            accountID: fixture.wallet.id,
            destinationAccountID: nil,
            categoryID: fixture.food.id,
            occurredAt: original.occurredAt,
            payee: "Updated cafe",
            note: "Corrected"
        )

        let revisions = try await fixture.store.fetchAll(
            JournalEntry.self,
            from: .journalEntryRevisions
        )
        let replacement = try XCTUnwrap(model.entries.first)
        let fetchedLive = try await fixture.store.fetch(
            JournalEntry.self,
            id: replacement.id.uuidString,
            from: .journalEntries
        )
        let retiredLive = try await fixture.store.fetch(
            JournalEntry.self,
            id: original.id.uuidString,
            from: .journalEntries
        )
        let live = try XCTUnwrap(fetchedLive)

        XCTAssertEqual(revisions, [original])
        XCTAssertNotEqual(live.id, original.id)
        XCTAssertEqual(live.supersedesID, original.id)
        XCTAssertNotNil(live.revisedAt)
        XCTAssertNil(retiredLive)
        XCTAssertEqual(
            model.displayBalanceResult(for: fixture.wallet).value?.amount,
            -20
        )
        await fixture.store.close()
    }

    @MainActor
    func testHistoricalSplitCorrectionRetainsItsArchivedAccountAndCategories() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        var archivedWallet = fixture.wallet
        archivedWallet.isArchived = true
        var archivedFood = fixture.food
        archivedFood.isArchived = true
        let archivedTravel = LedgerAccount(
            name: "Travel",
            kind: .expense,
            isArchived: true
        )
        let foodLineID = UUID()
        let travelLineID = UUID()
        let original = try TransactionFactory.splitExpense(
            amount: try Money(30, currency: fixture.sgd),
            paidFrom: archivedWallet.id,
            splits: [
                TransactionSplitLine(
                    id: foodLineID,
                    categoryAccountID: archivedFood.id,
                    amount: try Money(10, currency: fixture.sgd),
                    memo: "Meal"
                ),
                TransactionSplitLine(
                    id: travelLineID,
                    categoryAccountID: archivedTravel.id,
                    amount: try Money(20, currency: fixture.sgd),
                    memo: "Train"
                )
            ],
            occurredAt: Date(timeIntervalSinceReferenceDate: 500),
            payee: "Trip"
        )
        let model = fixture.model(
            accounts: [
                archivedWallet,
                fixture.usAccount,
                archivedFood,
                archivedTravel
            ],
            entries: [original]
        )

        try await model.replaceEntry(
            id: original.id,
            kind: .expense,
            amount: 30,
            destinationAmount: nil,
            accountID: archivedWallet.id,
            destinationAccountID: nil,
            categoryID: archivedFood.id,
            splitLines: [
                TransactionSplitLine(
                    id: foodLineID,
                    categoryAccountID: archivedFood.id,
                    amount: try Money(12, currency: fixture.sgd),
                    memo: "Corrected meal"
                ),
                TransactionSplitLine(
                    id: travelLineID,
                    categoryAccountID: archivedTravel.id,
                    amount: try Money(18, currency: fixture.sgd),
                    memo: "Corrected train"
                )
            ],
            occurredAt: original.occurredAt,
            payee: original.payee,
            note: "Historical correction"
        )

        let replacement = try XCTUnwrap(model.entries.first)
        XCTAssertEqual(replacement.supersedesID, original.id)
        XCTAssertEqual(
            Set(replacement.postings.map(\.accountID)),
            Set([archivedWallet.id, archivedFood.id, archivedTravel.id])
        )
        XCTAssertEqual(
            replacement.postings.first { $0.id == foodLineID }?.money.amount,
            12
        )
        XCTAssertEqual(
            replacement.postings.first { $0.id == travelLineID }?.money.amount,
            18
        )
        await fixture.store.close()
    }

    @MainActor
    func testHistoricalTransferCorrectionRetainsItsArchivedEndpoints() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        var source = fixture.wallet
        source.isArchived = true
        let destination = LedgerAccount(
            name: "Archived bank",
            kind: .asset,
            currency: fixture.sgd,
            isArchived: true
        )
        let original = try TransactionFactory.transfer(
            amount: try Money(25, currency: fixture.sgd),
            from: source.id,
            to: destination.id,
            occurredAt: Date(timeIntervalSinceReferenceDate: 600),
            note: "Old transfer"
        )
        let model = fixture.model(
            accounts: [source, destination, fixture.food],
            entries: [original]
        )

        try await model.replaceEntry(
            id: original.id,
            kind: .transfer,
            amount: 26,
            destinationAmount: nil,
            accountID: source.id,
            destinationAccountID: destination.id,
            categoryID: nil,
            occurredAt: original.occurredAt,
            payee: nil,
            note: "Corrected transfer"
        )

        let replacement = try XCTUnwrap(model.entries.first)
        XCTAssertEqual(
            Set(replacement.postings.map(\.accountID)),
            Set([source.id, destination.id])
        )
        await fixture.store.close()
    }

    @MainActor
    func testHistoricalCorrectionRejectsOtherArchivedAndSystemLedgerItems() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let original = try fixture.expense(amount: 10)
        let archivedAccount = LedgerAccount(
            name: "Closed bank",
            kind: .asset,
            currency: fixture.sgd,
            isArchived: true
        )
        let archivedCategory = LedgerAccount(
            name: "Old category",
            kind: .expense,
            isArchived: true
        )
        let systemAccount = LedgerAccount(
            name: "Opening balances",
            kind: .asset,
            currency: fixture.sgd,
            systemRole: .openingBalances
        )
        let systemCategory = LedgerAccount(
            name: "Investment gain/loss",
            kind: .expense,
            systemRole: .investmentGainLoss
        )
        let model = fixture.model(
            accounts: [
                fixture.wallet,
                fixture.usAccount,
                fixture.food,
                archivedAccount,
                archivedCategory,
                systemAccount,
                systemCategory
            ],
            entries: [original]
        )

        do {
            try await model.replaceEntry(
                id: original.id,
                kind: .expense,
                amount: 10,
                destinationAmount: nil,
                accountID: archivedAccount.id,
                destinationAccountID: nil,
                categoryID: fixture.food.id,
                occurredAt: original.occurredAt,
                payee: nil,
                note: nil
            )
            XCTFail("Expected an unrelated archived account to be rejected")
        } catch AppModelError.ledgerItemArchived {}

        do {
            try await model.replaceEntry(
                id: original.id,
                kind: .expense,
                amount: 10,
                destinationAmount: nil,
                accountID: fixture.wallet.id,
                destinationAccountID: nil,
                categoryID: archivedCategory.id,
                occurredAt: original.occurredAt,
                payee: nil,
                note: nil
            )
            XCTFail("Expected an unrelated archived category to be rejected")
        } catch AppModelError.ledgerItemArchived {}

        do {
            try await model.replaceEntry(
                id: original.id,
                kind: .expense,
                amount: 10,
                destinationAmount: nil,
                accountID: systemAccount.id,
                destinationAccountID: nil,
                categoryID: fixture.food.id,
                occurredAt: original.occurredAt,
                payee: nil,
                note: nil
            )
            XCTFail("Expected a system account to be rejected")
        } catch AppModelError.systemAccountLifecycleForbidden {}

        do {
            try await model.replaceEntry(
                id: original.id,
                kind: .expense,
                amount: 10,
                destinationAmount: nil,
                accountID: fixture.wallet.id,
                destinationAccountID: nil,
                categoryID: systemCategory.id,
                occurredAt: original.occurredAt,
                payee: nil,
                note: nil
            )
            XCTFail("Expected a system category to be rejected")
        } catch AppModelError.systemAccountLifecycleForbidden {}

        XCTAssertEqual(model.entries, [original])
        let revisionCount = try await fixture.store.count(
            in: .journalEntryRevisions
        )
        XCTAssertEqual(revisionCount, 0)
        await fixture.store.close()
    }

    @MainActor
    func testLazyJournalEditsAndDeletesEntryOlderThanRecentCacheExactly() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let now = Date()
        let month = try XCTUnwrap(Calendar.current.dateInterval(of: .month, for: now))
        var allEntries: [JournalEntry] = []
        for offset in 1...100 {
            allEntries.append(
                try TransactionFactory.expense(
                    amount: Money(Decimal(offset), currency: fixture.sgd),
                    paidFrom: fixture.wallet.id,
                    category: fixture.food.id,
                    occurredAt: month.start.addingTimeInterval(TimeInterval(offset)),
                    payee: "Cafe \(offset)"
                )
            )
        }
        try await fixture.seed(
            profile: UserProfile(baseCurrency: fixture.sgd),
            accounts: [fixture.wallet, fixture.usAccount, fixture.food],
            entries: allEntries
        )
        let recent = Array(allEntries.sorted { $0.occurredAt > $1.occurredAt }.prefix(80))
        let oldest = try XCTUnwrap(allEntries.first)
        XCTAssertFalse(recent.contains { $0.id == oldest.id })
        let model = fixture.model(
            entries: recent,
            retainsCompleteJournal: false
        )

        try await model.replaceEntry(
            id: oldest.id,
            kind: .expense,
            amount: 500,
            destinationAmount: nil,
            accountID: fixture.wallet.id,
            destinationAccountID: nil,
            categoryID: fixture.food.id,
            occurredAt: oldest.occurredAt,
            payee: "Corrected old cafe",
            note: nil
        )

        XCTAssertEqual(model.budgetJournalReplayReadCount, 0)
        XCTAssertEqual(model.entries.count, 80)
        XCTAssertEqual(model.journalEntryCount, 100)
        XCTAssertEqual(
            model.displayBalanceResult(for: fixture.wallet).value?.amount,
            -5_549
        )
        XCTAssertEqual(
            model.reportResult(for: .thisMonth).value?.baseFlow.expense.amount,
            5_549
        )
        let liveAfterEdit = try await fixture.store.fetchAll(
            JournalEntry.self,
            from: .journalEntries
        )
        let replacement = try XCTUnwrap(
            liveAfterEdit.first { $0.supersedesID == oldest.id }
        )

        try await model.deleteEntry(id: replacement.id)

        XCTAssertEqual(model.budgetJournalReplayReadCount, 0)
        XCTAssertEqual(model.entries.count, 80)
        XCTAssertEqual(model.journalEntryCount, 99)
        XCTAssertEqual(
            model.displayBalanceResult(for: fixture.wallet).value?.amount,
            -5_049
        )
        XCTAssertEqual(
            model.reportResult(for: .thisMonth).value?.baseFlow.expense.amount,
            5_049
        )
        await fixture.store.close()
    }

    @MainActor
    func testProjectionReadCannotPublishBetweenJournalCommitAndRefresh() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let projectionGate = FirstRefreshGate()
        let committedWriteGate = AsyncGate()
        let now = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-15T12:00:00Z")
        )
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            reportingTimeZoneIdentifier: "GMT"
        )
        let model = fixture.model(
            profile: profile,
            lifecycleHooks: AppModelLifecycleHooks { checkpoint in
                switch checkpoint {
                case .afterJournalProjectionReadBeforePublish:
                    await projectionGate.suspendFirstCaller()
                case .afterJournalCommitBeforeProjectionRefresh:
                    await committedWriteGate.suspend()
                default:
                    return
                }
            },
            retainsCompleteJournal: false,
            currentDate: { now }
        )

        if case .available = model.reportResult(for: .thisMonth) {
            XCTFail("Expected the lazy projection to begin unavailable")
        }
        let projectionDidReach = await projectionGate.waitUntilReached(
            timeout: .seconds(5)
        )
        XCTAssertTrue(projectionDidReach, "Initial projection checkpoint timed out")

        let saveTask = Task { @MainActor in
            try await model.logExpense(
                amount: 12,
                accountID: fixture.wallet.id,
                categoryID: fixture.food.id,
                occurredAt: now,
                payee: "New journal state",
                note: nil
            )
        }
        let commitDidReach = await committedWriteGate.waitUntilReached(
            timeout: .seconds(5)
        )
        XCTAssertTrue(commitDidReach, "Postcommit checkpoint timed out")

        // The journal row is durable while its owning mutation is still
        // suspended. Releasing the older empty read must not republish an
        // available zero balance/report in this commit-to-refresh window.
        let durableEntryCount = try? await fixture.store.count(
            in: .journalEntries
        )
        XCTAssertEqual(durableEntryCount, 1)
        await projectionGate.release()
        await model.waitForPendingJournalDerivedRefresh()
        let balanceUnavailable: Bool
        if case .unavailable = model.displayBalanceResult(for: fixture.wallet) {
            balanceUnavailable = true
        } else {
            balanceUnavailable = false
        }
        let reportUnavailable: Bool
        if case .unavailable = model.reportResult(for: .thisMonth) {
            reportUnavailable = true
        } else {
            reportUnavailable = false
        }
        XCTAssertTrue(
            balanceUnavailable && reportUnavailable,
            "A superseded projection published during a writer"
        )
        XCTAssertFalse(model.journalRecentEntriesAreCurrent)
        XCTAssertTrue(model.entries.isEmpty)

        await committedWriteGate.release()
        let savedID: UUID?
        do {
            savedID = try await saveTask.value
        } catch {
            XCTFail("Save failed before completing the race: \(error)")
            await fixture.store.close()
            return
        }
        XCTAssertNotNil(savedID)
        await model.waitForPendingJournalDerivedRefresh()

        XCTAssertEqual(model.journalEntryCount, 1)
        XCTAssertTrue(model.journalRecentEntriesAreCurrent)
        XCTAssertEqual(model.entries.first?.id, savedID)
        XCTAssertEqual(
            model.displayBalanceResult(for: fixture.wallet).value?.amount,
            -12
        )
        XCTAssertEqual(
            model.reportResult(for: .thisMonth).value?.baseFlow.expense.amount,
            12
        )
        await fixture.store.close()
    }

    @MainActor
    func testQueuedProjectionCannotAdoptAWriterRevisionBeforeItsTaskStarts() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let commitBoundaryGate = AsyncGate()
        let now = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-15T12:00:00Z")
        )
        let model = fixture.model(
            profile: UserProfile(
                baseCurrency: fixture.sgd,
                reportingTimeZoneIdentifier: "GMT"
            ),
            lifecycleHooks: hooks(
                pausing: .afterJournalProjectionInvalidationBeforeCommit,
                at: commitBoundaryGate
            ),
            retainsCompleteJournal: false,
            currentDate: { now }
        )

        // Enqueue the compact read without yielding the main actor. The direct
        // save below starts its mutation and advances the projection revision
        // before this unstructured refresh task can begin executing.
        if case .available = model.reportResult(for: .thisMonth) {
            XCTFail("Expected the queued lazy projection to begin unavailable")
        }
        let precommitObservation = Task { @MainActor in
            let reached = await commitBoundaryGate.waitUntilReached(
                timeout: .seconds(5)
            )
            await model.waitForPendingJournalDerivedRefresh()
            let storedCount = try? await fixture.store.count(
                in: .journalEntries
            )
            let recentIsCurrent = model.journalRecentEntriesAreCurrent
            let recentCount = model.entries.count
            await commitBoundaryGate.release()
            return (reached, storedCount, recentIsCurrent, recentCount)
        }

        let savedID = try await model.logExpense(
            amount: 14,
            accountID: fixture.wallet.id,
            categoryID: fixture.food.id,
            occurredAt: now,
            payee: "Queued refresh race",
            note: nil
        )
        let observation = await precommitObservation.value

        XCTAssertTrue(observation.0, "Precommit checkpoint timed out")
        XCTAssertEqual(observation.1, 0)
        XCTAssertFalse(
            observation.2,
            "A pre-enqueued refresh adopted the writer's newer revision"
        )
        XCTAssertEqual(observation.3, 0)
        XCTAssertNotNil(savedID)
        XCTAssertTrue(model.journalRecentEntriesAreCurrent)
        XCTAssertEqual(model.entries.first?.id, savedID)
        XCTAssertEqual(
            model.displayBalanceResult(for: fixture.wallet).value?.amount,
            -14
        )
        await fixture.store.close()
    }

    @MainActor
    func testPublishedProjectionFailsClosedBeforeJournalCommitAndRecovers() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let now = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-15T12:00:00Z")
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "GMT"))
        let month = try XCTUnwrap(calendar.dateInterval(of: .month, for: now))
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            showsBudgetStatusWidget: true,
            reportingTimeZoneIdentifier: "GMT"
        )
        let travel = LedgerAccount(name: "Travel", kind: .expense)
        let budget = BudgetNode(
            id: fixture.food.id,
            name: fixture.food.name,
            limit: try Money(100, currency: fixture.sgd),
            purpose: .flexible
        )
        let timeline = try BudgetConfigurationTimeline(
            currency: fixture.sgd,
            revisions: [BudgetConfigurationRevision(
                effectiveMonth: month.start,
                nodes: [budget]
            )]
        )
        let prior = try TransactionFactory.expense(
            amount: try Money(25, currency: fixture.sgd),
            paidFrom: fixture.wallet.id,
            category: fixture.food.id,
            occurredAt: now.addingTimeInterval(-3_600),
            payee: "Before"
        )
        let priorAttribution = try BudgetEntryAttribution(
            entry: prior,
            originTimeZoneIdentifier: "GMT"
        )
        try await fixture.seed(
            profile: profile,
            accounts: [fixture.wallet, fixture.usAccount, fixture.food, travel],
            entries: [prior],
            budgetNodes: [budget],
            budgetConfigurationTimeline: timeline
        )
        let suiteName = "MoneyUpCommitBoundaryWidget-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let widgetStore = BudgetWidgetSnapshotStore(defaults: defaults)
        let commitBoundaryGate = AsyncGate()
        let model = fixture.model(
            profile: profile,
            accounts: [fixture.wallet, fixture.usAccount, fixture.food, travel],
            budgetNodes: [budget],
            lifecycleHooks: hooks(
                pausing: .afterJournalProjectionInvalidationBeforeCommit,
                at: commitBoundaryGate
            ),
            retainsCompleteJournal: false,
            budgetWidgetSnapshotStore: widgetStore,
            budgetConfigurationTimeline: timeline,
            budgetEntryAttributions: [prior.id: priorAttribution],
            currentDate: { now }
        )

        if case .available = model.reportResult(for: .thisMonth) {
            XCTFail("Expected the lazy projection to begin unavailable")
        }
        await model.waitForPendingJournalDerivedRefresh()
        XCTAssertEqual(
            model.displayBalanceResult(for: fixture.wallet).value?.amount,
            -25
        )
        XCTAssertEqual(
            model.reportResult(for: .thisMonth).value?.baseFlow.expense.amount,
            25
        )
        XCTAssertEqual(budgetWidgetPercent(widgetStore.read(now: now)), 25)

        let saveTask = Task { @MainActor in
            try await model.logExpense(
                amount: 12,
                accountID: fixture.wallet.id,
                categoryID: travel.id,
                occurredAt: now,
                payee: "After",
                note: nil
            )
        }
        let commitBoundaryDidReach = await commitBoundaryGate.waitUntilReached(
            timeout: .seconds(5)
        )
        XCTAssertTrue(
            commitBoundaryDidReach,
            "Precommit invalidation checkpoint timed out"
        )

        let precommitStoredCount = try? await fixture.store.count(in: .journalEntries)
        XCTAssertEqual(precommitStoredCount, 1)
        let precommitBalanceUnavailable: Bool
        if case .unavailable = model.displayBalanceResult(for: fixture.wallet) {
            precommitBalanceUnavailable = true
        } else {
            precommitBalanceUnavailable = false
        }
        let precommitReportUnavailable: Bool
        if case .unavailable = model.reportResult(for: .thisMonth) {
            precommitReportUnavailable = true
        } else {
            precommitReportUnavailable = false
        }
        XCTAssertTrue(
            precommitBalanceUnavailable && precommitReportUnavailable,
            "Pre-commit journal projections remained readable"
        )
        XCTAssertFalse(model.journalRecentEntriesAreCurrent)
        XCTAssertTrue(model.entries.isEmpty)
        let invalidatedImpact = model.lifecycleImpact(for: travel.id)
        XCTAssertEqual(invalidatedImpact.transactionCount, 0)
        XCTAssertFalse(invalidatedImpact.transactionReferencesAreCurrent)
        XCTAssertFalse(invalidatedImpact.isUnused)
        XCTAssertEqual(
            widgetStore.read(now: now),
            .needsBudget(validUntil: month.end)
        )

        await commitBoundaryGate.release()
        let savedID: UUID?
        do {
            savedID = try await saveTask.value
        } catch {
            XCTFail("Save failed before completing the race: \(error)")
            await fixture.store.close()
            return
        }
        XCTAssertNotNil(savedID)
        await model.waitForPendingJournalDerivedRefresh()

        let committedStoredCount = try? await fixture.store.count(in: .journalEntries)
        XCTAssertEqual(committedStoredCount, 2)
        XCTAssertEqual(
            model.displayBalanceResult(for: fixture.wallet).value?.amount,
            -37
        )
        XCTAssertEqual(
            model.reportResult(for: .thisMonth).value?.baseFlow.expense.amount,
            37
        )
        let refreshedImpact = model.lifecycleImpact(for: travel.id)
        XCTAssertTrue(model.journalRecentEntriesAreCurrent)
        XCTAssertTrue(refreshedImpact.transactionReferencesAreCurrent)
        XCTAssertEqual(refreshedImpact.transactionCount, 1)
        XCTAssertFalse(refreshedImpact.isUnused)
        XCTAssertEqual(budgetWidgetPercent(widgetStore.read(now: now)), 25)
        await fixture.store.close()
    }

    @MainActor
    func testRetainedJournalWriteFailureRepublishesCoherentPrecommitWidget() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let now = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-15T12:00:00Z")
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "GMT"))
        let month = try XCTUnwrap(calendar.dateInterval(of: .month, for: now))
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            showsBudgetStatusWidget: true,
            reportingTimeZoneIdentifier: "GMT"
        )
        let budget = BudgetNode(
            id: fixture.food.id,
            name: fixture.food.name,
            limit: try Money(100, currency: fixture.sgd),
            purpose: .flexible
        )
        let timeline = try BudgetConfigurationTimeline(
            currency: fixture.sgd,
            revisions: [BudgetConfigurationRevision(
                effectiveMonth: month.start,
                nodes: [budget]
            )]
        )
        let prior = try TransactionFactory.expense(
            amount: try Money(25, currency: fixture.sgd),
            paidFrom: fixture.wallet.id,
            category: fixture.food.id,
            occurredAt: now.addingTimeInterval(-3_600)
        )
        let attribution = try BudgetEntryAttribution(
            entry: prior,
            originTimeZoneIdentifier: "GMT"
        )
        try await fixture.seed(
            profile: profile,
            accounts: [fixture.wallet, fixture.usAccount, fixture.food],
            entries: [prior],
            budgetNodes: [budget],
            budgetConfigurationTimeline: timeline
        )
        let suiteName = "MoneyUpRetainedFailureWidget-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let widgetStore = BudgetWidgetSnapshotStore(defaults: defaults)
        let commitBoundaryGate = AsyncGate()
        let model = fixture.model(
            profile: profile,
            entries: [prior],
            budgetNodes: [budget],
            lifecycleHooks: hooks(
                pausing: .afterJournalProjectionInvalidationBeforeCommit,
                at: commitBoundaryGate
            ),
            retainsCompleteJournal: true,
            budgetWidgetSnapshotStore: widgetStore,
            budgetConfigurationTimeline: timeline,
            budgetEntryAttributions: [prior.id: attribution],
            currentDate: { now }
        )
        XCTAssertEqual(budgetWidgetPercent(widgetStore.read(now: now)), 25)

        let saveTask = Task { @MainActor in
            try await model.logExpense(
                amount: 5,
                accountID: fixture.wallet.id,
                categoryID: fixture.food.id,
                occurredAt: now,
                payee: "Injected write failure",
                note: nil
            )
        }
        let reached = await commitBoundaryGate.waitUntilReached(
            timeout: .seconds(5)
        )
        XCTAssertTrue(reached, "Precommit failure checkpoint timed out")
        XCTAssertEqual(
            widgetStore.read(now: now),
            .needsBudget(validUntil: month.end)
        )
        await fixture.store.close()
        await commitBoundaryGate.release()

        do {
            _ = try await saveTask.value
            XCTFail("Expected the closed-store write to fail")
        } catch {
            // The durable store and retained collection both remain precommit.
        }
        XCTAssertEqual(model.entries, [prior])
        XCTAssertTrue(model.journalRecentEntriesAreCurrent)
        XCTAssertEqual(budgetWidgetPercent(widgetStore.read(now: now)), 25)
    }

    @MainActor
    func testReplacingEntryRejectsImplicitCurrencyChangeWithoutWriting() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let original = try fixture.expense(amount: 10)
        let model = fixture.model(entries: [original])

        do {
            try await model.replaceEntry(
                id: original.id,
                kind: .expense,
                amount: 10,
                destinationAmount: nil,
                accountID: fixture.usAccount.id,
                destinationAccountID: nil,
                categoryID: fixture.food.id,
                occurredAt: original.occurredAt,
                payee: original.payee,
                note: original.note
            )
            XCTFail("Expected a currency-change rejection")
        } catch AppModelError.crossCurrencyEditRequiresConversion {
            // Expected: the UI has no explicit conversion contract for edits.
        }

        let revisionCount = try await fixture.store.count(in: .journalEntryRevisions)
        let entryCount = try await fixture.store.count(in: .journalEntries)
        XCTAssertEqual(revisionCount, 0)
        XCTAssertEqual(entryCount, 0)
        XCTAssertEqual(model.entries, [original])
        await fixture.store.close()
    }

    @MainActor
    func testLegacyPrecisionCanBePreservedButNotChangedToAnotherInvalidValue() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let original = try fixture.expense(amount: Decimal(string: "12.345")!)
        let model = fixture.model(entries: [original])

        try await model.replaceEntry(
            id: original.id,
            kind: .expense,
            amount: Decimal(string: "12.345")!,
            destinationAmount: nil,
            accountID: fixture.wallet.id,
            destinationAccountID: nil,
            categoryID: fixture.food.id,
            occurredAt: original.occurredAt,
            payee: original.payee,
            note: "Preserve the imported amount"
        )
        let replacementID = try XCTUnwrap(model.entries.first?.id)

        do {
            try await model.replaceEntry(
                id: replacementID,
                kind: .expense,
                amount: Decimal(string: "12.346")!,
                destinationAmount: nil,
                accountID: fixture.wallet.id,
                destinationAccountID: nil,
                categoryID: fixture.food.id,
                occurredAt: original.occurredAt,
                payee: original.payee,
                note: "Invalid precision"
            )
            XCTFail("Expected unsupported precision")
        } catch AppModelError.unsupportedPrecision(let currency) {
            XCTAssertEqual(currency, fixture.sgd)
        }

        XCTAssertEqual(model.entries.first?.postings.first?.money.amount, Decimal(string: "12.345"))
        let revisionCount = try await fixture.store.count(in: .journalEntryRevisions)
        XCTAssertEqual(revisionCount, 1)
        await fixture.store.close()
    }

    @MainActor
    func testSchedulesAndHoldingPricesEnforceCurrencyMinorUnits() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let brokerage = LedgerAccount(
            name: "Brokerage",
            kind: .asset,
            currency: fixture.sgd,
            accountType: .brokerage
        )
        let model = fixture.model(accounts: [brokerage, fixture.food])
        let unsupported = try Money(Decimal(string: "1.234")!, currency: fixture.sgd)
        let schedule = try ScheduledTransaction(
            kind: .expense,
            name: "Rent",
            amount: unsupported,
            accountID: brokerage.id,
            categoryAccountID: fixture.food.id,
            nextOccurrence: Date(),
            frequency: .monthly
        )
        let holding = try InvestmentHolding(
            accountID: brokerage.id,
            symbol: "TEST",
            name: "Test holding",
            quantity: 1,
            price: unsupported
        )

        do {
            try await model.addScheduledTransaction(schedule)
            XCTFail("Expected unsupported schedule precision")
        } catch AppModelError.unsupportedPrecision(let currency) {
            XCTAssertEqual(currency, fixture.sgd)
        }
        do {
            try await model.addInvestmentHolding(
                holding,
                treatment: .deductFromCash
            )
            XCTFail("Expected unsupported holding precision")
        } catch AppModelError.unsupportedPrecision(let currency) {
            XCTAssertEqual(currency, fixture.sgd)
        }

        let scheduleCount = try await fixture.store.count(in: .scheduledTransactions)
        let holdingCount = try await fixture.store.count(in: .investmentHoldings)
        XCTAssertEqual(scheduleCount, 0)
        XCTAssertEqual(holdingCount, 0)
        await fixture.store.close()
    }

    @MainActor
    func testSchedulesRejectArchivedAccountsAndCategoriesAtTheWriteBoundary() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()
        let schedule = try ScheduledTransaction(
            kind: .expense,
            name: "Rent",
            amount: try Money(900, currency: fixture.sgd),
            accountID: fixture.wallet.id,
            categoryAccountID: fixture.food.id,
            nextOccurrence: Date(),
            frequency: .monthly
        )

        try await model.setLedgerItemArchived(id: fixture.wallet.id, isArchived: true)
        do {
            try await model.addScheduledTransaction(schedule)
            XCTFail("Expected an archived account to be rejected")
        } catch AppModelError.ledgerItemArchived {
            // Expected: schedule writes honor the same active-only boundary as Log.
        }

        try await model.setLedgerItemArchived(id: fixture.wallet.id, isArchived: false)
        try await model.setLedgerItemArchived(id: fixture.food.id, isArchived: true)
        do {
            try await model.addScheduledTransaction(schedule)
            XCTFail("Expected an archived category to be rejected")
        } catch AppModelError.ledgerItemArchived {
            // Expected.
        }

        XCTAssertTrue(model.scheduledTransactions.isEmpty)
        let storedScheduleCount = try await fixture.store.count(in: .scheduledTransactions)
        XCTAssertEqual(storedScheduleCount, 0)
        await fixture.store.close()
    }

    @MainActor
    func testPostingSchedulePersistsEntryAndAdvancementAtomicallyExactlyOnce() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let schedule = try ScheduledTransaction(
            kind: .expense,
            name: "Rent",
            amount: try Money(900, currency: fixture.sgd),
            accountID: fixture.wallet.id,
            categoryAccountID: fixture.food.id,
            nextOccurrence: Date(timeIntervalSinceReferenceDate: 10_000),
            frequency: .monthly
        )
        let model = fixture.model(
            scheduledTransactions: [schedule],
            retainsCompleteJournal: false
        )
        let occurrenceID = schedule.currentOccurrenceID

        let entryID = try await model.postScheduledOccurrence(
            scheduleID: schedule.id,
            occurrenceID: occurrenceID
        )

        XCTAssertNotNil(entryID)
        XCTAssertEqual(model.entries.count, 1)
        XCTAssertEqual(model.scheduledTransactions.first?.currentOccurrenceIndex, 1)
        let storedEntries = try await fixture.store.fetchAll(
            JournalEntry.self,
            from: .journalEntries
        )
        let storedSchedules = try await fixture.store.fetchAll(
            ScheduledTransaction.self,
            from: .scheduledTransactions
        )
        XCTAssertEqual(storedEntries.count, 1)
        XCTAssertEqual(storedSchedules.first?.resolutions.first?.kind, .posted)
        let selectedDay = try XCTUnwrap(
            FinancialPeriodBoundary.inclusiveDayInterval(
                from: schedule.nextOccurrence,
                through: schedule.nextOccurrence,
                calendar: model.reportingCalendar
            )
        )
        let reloadedActuals = try await model.calendarEntries(in: selectedDay)
        XCTAssertEqual(reloadedActuals.map(\.id), [entryID].compactMap { $0 })

        do {
            _ = try await model.postScheduledOccurrence(
                scheduleID: schedule.id,
                occurrenceID: occurrenceID
            )
            XCTFail("Expected stale occurrence rejection")
        } catch let error as ScheduledTransactionError {
            XCTAssertEqual(error, .staleOccurrence)
        }
        let entryCountAfterRetry = try await fixture.store.count(in: .journalEntries)
        XCTAssertEqual(entryCountAfterRetry, 1)
        await fixture.store.close()
    }

    @MainActor
    func testScheduledBudgetAttributionPreservesPlus14AndMinus12CivilMonths() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let plusZone = try XCTUnwrap(TimeZone(identifier: "Pacific/Kiritimati"))
        let minusZone = try XCTUnwrap(TimeZone(identifier: "Etc/GMT+12"))
        var plusCalendar = Calendar(identifier: .gregorian)
        plusCalendar.timeZone = plusZone
        var minusCalendar = Calendar(identifier: .gregorian)
        minusCalendar.timeZone = minusZone
        let plusDate = try XCTUnwrap(plusCalendar.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 1,
            hour: 0,
            minute: 30
        )))
        let minusDate = try XCTUnwrap(minusCalendar.date(from: DateComponents(
            year: 2026,
            month: 2,
            day: 28,
            hour: 23,
            minute: 30
        )))
        let plusSchedule = try ScheduledTransaction(
            kind: .expense,
            name: "Plus fourteen schedule",
            amount: try Money(5, currency: fixture.sgd),
            accountID: fixture.wallet.id,
            categoryAccountID: fixture.food.id,
            nextOccurrence: plusDate,
            frequency: .monthly,
            recurrenceTimeZoneIdentifier: plusZone.identifier
        )
        let minusSchedule = try ScheduledTransaction(
            kind: .expense,
            name: "Minus twelve schedule",
            amount: try Money(6, currency: fixture.sgd),
            accountID: fixture.wallet.id,
            categoryAccountID: fixture.food.id,
            nextOccurrence: minusDate,
            frequency: .monthly,
            recurrenceTimeZoneIdentifier: minusZone.identifier
        )
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            reportingTimeZoneIdentifier: "GMT"
        )
        let model = fixture.model(
            profile: profile,
            scheduledTransactions: [plusSchedule, minusSchedule]
        )

        _ = try await model.postScheduledOccurrence(
            scheduleID: plusSchedule.id,
            occurrenceID: plusSchedule.currentOccurrenceID,
            occurredAt: plusDate,
            resolvedAt: plusDate,
            calendar: plusCalendar
        )
        _ = try await model.postScheduledOccurrence(
            scheduleID: minusSchedule.id,
            occurrenceID: minusSchedule.currentOccurrenceID,
            occurredAt: minusDate,
            resolvedAt: minusDate,
            calendar: minusCalendar
        )

        let attributions = try await fixture.store.fetchAll(
            BudgetEntryAttribution.self,
            from: .budgetEntryAttributions
        )
        XCTAssertEqual(
            Set(attributions.map {
                "\($0.originDayKey):\($0.originUTCOffsetSeconds)"
            }),
            Set(["2026-03-01:50400", "2026-02-28:-43200"])
        )
        await fixture.store.close()
    }

    @MainActor
    func testManualAndBalanceEntriesUseProfileReportingZoneAcrossMidnight() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            reportingTimeZoneIdentifier: "America/Los_Angeles"
        )
        let model = fixture.model(profile: profile)
        let occurredAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-02-16T07:30:00Z")
        )

        let entryID = try await model.logExpense(
            amount: 20,
            accountID: fixture.wallet.id,
            categoryID: fixture.food.id,
            occurredAt: occurredAt,
            payee: "Reporting midnight",
            note: nil
        )
        let manual = try XCTUnwrap(model.entries.first { $0.id == entryID })
        XCTAssertEqual(manual.originContext.timeZoneIdentifier, "America/Los_Angeles")
        XCTAssertEqual(manual.originContext.dayKey, 20260215)

        let dayStart = try XCTUnwrap(
            model.reportingCalendar.date(
                from: DateComponents(year: 2026, month: 2, day: 15)
            )
        )
        let dayEnd = try XCTUnwrap(
            model.reportingCalendar.date(byAdding: .day, value: 1, to: dayStart)
        )
        let calendarEntries = try await model.calendarEntries(
            in: DateInterval(start: dayStart, end: dayEnd)
        )
        XCTAssertEqual(calendarEntries.map(\.id), [entryID].compactMap { $0 })

        try await model.addAccount(
            name: "Travel wallet",
            type: .cash,
            currencyCode: fixture.sgd.value,
            startingBalance: 100
        )
        let added = try XCTUnwrap(model.accounts.first { $0.name == "Travel wallet" })
        try await model.setAccountBalance(accountID: added.id, displayBalance: 125)
        let adjustments = model.entries.filter { entry in
            entry.kind == .adjustment
                && entry.postings.contains { $0.accountID == added.id }
        }
        XCTAssertEqual(adjustments.count, 2)
        for adjustment in adjustments {
            XCTAssertEqual(
                adjustment.originContext.timeZoneIdentifier,
                "America/Los_Angeles"
            )
            XCTAssertEqual(
                adjustment.originContext.dayKey,
                FinancialPeriodBoundary.dayKey(
                    for: adjustment.occurredAt,
                    calendar: model.reportingCalendar
                )
            )
        }
        await fixture.store.close()
    }

    @MainActor
    func testScheduleAdvancementDefaultsToProfileReportingZone() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let anchor = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-02-15T20:00:00Z")
        )
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            reportingTimeZoneIdentifier: "America/Los_Angeles"
        )
        let schedule = try ScheduledTransaction(
            kind: .expense,
            name: "Reporting-zone bill",
            amount: try Money(90, currency: fixture.sgd),
            accountID: fixture.wallet.id,
            categoryAccountID: fixture.food.id,
            nextOccurrence: anchor,
            frequency: .monthly
        )
        let model = fixture.model(
            profile: profile,
            scheduledTransactions: [schedule]
        )

        var expected = schedule
        try expected.resolveCurrent(
            occurrenceID: schedule.currentOccurrenceID,
            as: .skipped,
            calendar: model.reportingCalendar
        )
        var simulatedDeviceCalendar = Calendar(identifier: .gregorian)
        simulatedDeviceCalendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        var deviceDependent = schedule
        try deviceDependent.resolveCurrent(
            occurrenceID: schedule.currentOccurrenceID,
            as: .skipped,
            calendar: simulatedDeviceCalendar
        )
        XCTAssertNotEqual(expected.nextOccurrence, deviceDependent.nextOccurrence)

        _ = try await model.postScheduledOccurrence(
            scheduleID: schedule.id,
            occurrenceID: schedule.currentOccurrenceID
        )

        XCTAssertEqual(model.scheduledTransactions.first?.nextOccurrence, expected.nextOccurrence)
        XCTAssertEqual(model.entries.first?.originContext.timeZoneIdentifier, "America/Los_Angeles")
        XCTAssertEqual(model.entries.first?.originContext.dayKey, 20260215)
        await fixture.store.close()
    }

    @MainActor
    func testMatchingScheduleLinksExistingEntryWithoutDuplicatingJournal() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let entry = try fixture.expense(amount: 25)
        let schedule = try ScheduledTransaction(
            kind: .expense,
            name: "Lunch",
            amount: try Money(25, currency: fixture.sgd),
            accountID: fixture.wallet.id,
            categoryAccountID: fixture.food.id,
            nextOccurrence: entry.occurredAt,
            frequency: .weekly
        )
        try await fixture.store.upsert(
            entry,
            id: entry.id.uuidString,
            in: .journalEntries
        )
        let model = fixture.model(
            entries: [entry],
            scheduledTransactions: [schedule]
        )

        try await model.matchScheduledOccurrence(
            scheduleID: schedule.id,
            occurrenceID: schedule.currentOccurrenceID,
            entryID: entry.id
        )

        XCTAssertEqual(model.entries.count, 1)
        XCTAssertEqual(
            model.scheduledTransactions.first?.resolutions.first?.linkedEntryID,
            entry.id
        )
        let storedEntryCount = try await fixture.store.count(in: .journalEntries)
        XCTAssertEqual(storedEntryCount, 1)
        await fixture.store.close()
    }

    @MainActor
    func testPostedScheduleEditRelinksAndMatchedDeleteKeepsAuditState() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let postedSchedule = try ScheduledTransaction(
            kind: .expense,
            name: "Rent",
            amount: try Money(25, currency: fixture.sgd),
            accountID: fixture.wallet.id,
            categoryAccountID: fixture.food.id,
            nextOccurrence: Date(timeIntervalSinceReferenceDate: 500),
            frequency: .monthly
        )
        let postedModel = fixture.model(scheduledTransactions: [postedSchedule])
        let postedID = try await postedModel.postScheduledOccurrence(
            scheduleID: postedSchedule.id,
            occurrenceID: postedSchedule.currentOccurrenceID
        )
        let oldID = try XCTUnwrap(postedID)
        try await postedModel.replaceEntry(
            id: oldID,
            kind: .expense,
            amount: 30,
            destinationAmount: nil,
            accountID: fixture.wallet.id,
            destinationAccountID: nil,
            categoryID: fixture.food.id,
            occurredAt: postedSchedule.nextOccurrence,
            payee: "Rent revised",
            note: nil
        )
        let replacement = try XCTUnwrap(postedModel.entries.first)
        XCTAssertNotEqual(replacement.id, oldID)
        XCTAssertEqual(
            postedModel.scheduledTransactions.first?.resolutions.first?.linkedEntryID,
            replacement.id
        )
        let persistedPostedSchedule = try await fixture.store.fetch(
            ScheduledTransaction.self,
            id: postedSchedule.id.uuidString,
            from: .scheduledTransactions
        )
        XCTAssertEqual(
            persistedPostedSchedule?.resolutions.first?.linkedEntryID,
            replacement.id
        )
        await fixture.store.close()

        let matchedFixture = try AppModelFixture()
        defer { matchedFixture.removeFiles() }
        let actual = try matchedFixture.expense(amount: 25)
        try await matchedFixture.store.upsert(
            actual,
            id: actual.id.uuidString,
            in: .journalEntries
        )
        let matchedSchedule = try ScheduledTransaction(
            kind: .expense,
            name: "Lunch",
            amount: try Money(25, currency: matchedFixture.sgd),
            accountID: matchedFixture.wallet.id,
            categoryAccountID: matchedFixture.food.id,
            nextOccurrence: actual.occurredAt,
            frequency: .weekly
        )
        let matchedModel = matchedFixture.model(
            entries: [actual],
            scheduledTransactions: [matchedSchedule]
        )
        try await matchedModel.matchScheduledOccurrence(
            scheduleID: matchedSchedule.id,
            occurrenceID: matchedSchedule.currentOccurrenceID,
            entryID: actual.id
        )
        try await matchedModel.deleteEntry(id: actual.id)

        let deletedResolution = try XCTUnwrap(
            matchedModel.scheduledTransactions.first?.resolutions.first
        )
        XCTAssertEqual(deletedResolution.kind, .entryDeleted)
        XCTAssertNil(deletedResolution.linkedEntryID)
        XCTAssertNotNil(deletedResolution.entryDeletedAt)
        let persistedMatchedSchedule = try await matchedFixture.store.fetch(
            ScheduledTransaction.self,
            id: matchedSchedule.id.uuidString,
            from: .scheduledTransactions
        )
        XCTAssertEqual(
            persistedMatchedSchedule?.resolutions.first?.kind,
            .entryDeleted
        )
        await matchedFixture.store.close()
    }

    @MainActor
    func testOldNonRecentScheduleEntryReplacementStillRelinks() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let old = try fixture.expense(amount: 25)
        var schedule = try ScheduledTransaction(
            kind: .expense,
            name: "Lunch",
            amount: try Money(25, currency: fixture.sgd),
            accountID: fixture.wallet.id,
            categoryAccountID: fixture.food.id,
            nextOccurrence: old.occurredAt,
            frequency: .weekly
        )
        try schedule.resolveCurrent(
            occurrenceID: schedule.currentOccurrenceID,
            as: .matched,
            linkedEntryID: old.id
        )
        var recent: [JournalEntry] = []
        for offset in 1...81 {
            recent.append(try TransactionFactory.expense(
                amount: try Money(1, currency: fixture.sgd),
                paidFrom: fixture.wallet.id,
                category: fixture.food.id,
                occurredAt: old.occurredAt.addingTimeInterval(Double(offset))
            ))
        }
        try await fixture.store.write(
            try ([old] + recent).map {
                try RecordWrite($0, id: $0.id.uuidString, in: .journalEntries)
            } + [try RecordWrite(
                schedule,
                id: schedule.id.uuidString,
                in: .scheduledTransactions
            )]
        )
        let model = fixture.model(
            entries: Array(recent.prefix(80)),
            scheduledTransactions: [schedule],
            retainsCompleteJournal: false
        )
        XCTAssertFalse(model.entries.contains { $0.id == old.id })

        try await model.replaceEntry(
            id: old.id,
            kind: .expense,
            amount: 25,
            destinationAmount: nil,
            accountID: fixture.wallet.id,
            destinationAccountID: nil,
            categoryID: fixture.food.id,
            occurredAt: old.occurredAt,
            payee: "Edited old actual",
            note: nil
        )

        let linkedID = try XCTUnwrap(
            model.scheduledTransactions.first?.resolutions.first?.linkedEntryID
        )
        XCTAssertNotEqual(linkedID, old.id)
        let replacement = try await fixture.store.fetch(
            JournalEntry.self,
            id: linkedID.uuidString,
            from: .journalEntries
        )
        XCTAssertNotNil(replacement)
        await fixture.store.close()
    }

    @MainActor
    func testPausedScheduleMatchBlocksRestoreUntilItsCommit() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let entry = try fixture.expense(amount: 25)
        let schedule = try ScheduledTransaction(
            kind: .expense,
            name: "Lunch",
            amount: try Money(25, currency: fixture.sgd),
            accountID: fixture.wallet.id,
            categoryAccountID: fixture.food.id,
            nextOccurrence: entry.occurredAt,
            frequency: .weekly
        )
        try await fixture.store.upsert(
            entry,
            id: entry.id.uuidString,
            in: .journalEntries
        )
        let gate = AsyncGate()
        let model = fixture.model(
            entries: [entry],
            scheduledTransactions: [schedule],
            lifecycleHooks: hooks(pausing: .beforeScheduleMatchCommit, at: gate)
        )
        let archive = try await model.encryptedBackup(password: "schedule-race")
        let matchTask = Task { @MainActor in
            try await model.matchScheduledOccurrence(
                scheduleID: schedule.id,
                occurrenceID: schedule.currentOccurrenceID,
                entryID: entry.id
            )
        }
        await gate.waitUntilReached()

        do {
            try await model.restoreEncryptedBackup(
                archive,
                password: "schedule-race"
            )
            XCTFail("Expected restore to respect the schedule match barrier")
        } catch AppModelError.transactionInProgress {
            // The stale fetched entry cannot mutate a replacement book.
        }
        await gate.release()
        try await matchTask.value
        XCTAssertEqual(
            model.scheduledTransactions.first?.resolutions.first?.linkedEntryID,
            entry.id
        )
        await fixture.store.close()
    }

    @MainActor
    func testPausedScheduleUpdateBlocksGenericJournalDeletion() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let entry = try fixture.expense(amount: 25)
        try await fixture.store.upsert(
            entry,
            id: entry.id.uuidString,
            in: .journalEntries
        )
        let schedule = try ScheduledTransaction(
            kind: .expense,
            name: "Lunch",
            amount: try Money(25, currency: fixture.sgd),
            accountID: fixture.wallet.id,
            categoryAccountID: fixture.food.id,
            nextOccurrence: entry.occurredAt,
            frequency: .weekly
        )
        let gate = AsyncGate()
        let model = fixture.model(
            entries: [entry],
            scheduledTransactions: [schedule],
            lifecycleHooks: hooks(pausing: .beforeScheduleMutationCommit, at: gate)
        )
        let updateTask = Task { @MainActor in
            try await model.pauseScheduledTransaction(id: schedule.id)
        }
        await gate.waitUntilReached()

        do {
            try await model.deleteEntry(id: entry.id)
            XCTFail("Expected journal deletion to respect schedule mutation")
        } catch AppModelError.transactionInProgress {
            // Atomic schedule state wins; the entry remains untouched.
        }
        await gate.release()
        try await updateTask.value
        let retained = try await fixture.store.fetch(
            JournalEntry.self,
            id: entry.id.uuidString,
            from: .journalEntries
        )
        XCTAssertNotNil(retained)
        XCTAssertEqual(model.scheduledTransactions.first?.status, .paused)
        await fixture.store.close()
    }

    @MainActor
    func testExpenseDeepLinkWhileLockedOffersOnlyLockedCapture() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()
        UserDefaults.standard.set(
            true,
            forKey: AppModel.lockedQuickCapturePreferenceKey
        )

        model.lock()
        let handled = model.handleDeepLink(
            try XCTUnwrap(URL(string: "moneyup://quick-log/expense"))
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(model.state, .locked)
        XCTAssertEqual(model.requestedQuickLogMode, .expense)
        XCTAssertTrue(model.canPresentLockedQuickCapture)
        await fixture.store.close()
    }

    @MainActor
    func testColdBasicDeepLinkRoutesBeforeProtectedBookStartup() throws {
        let model = AppModel(dataEraseIntent: .none)
        UserDefaults.standard.set(
            true,
            forKey: AppModel.lockedQuickCapturePreferenceKey
        )

        let handled = model.handleDeepLink(
            try XCTUnwrap(URL(string: "moneyup://quick-log/expense"))
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(model.state, .locked)
        XCTAssertTrue(model.canPresentLockedQuickCapture)
    }

    @MainActor
    func testColdReceiptDeepLinkDoesNotEnterRedactedCapture() throws {
        let model = AppModel(dataEraseIntent: .none)
        UserDefaults.standard.set(
            true,
            forKey: AppModel.lockedQuickCapturePreferenceKey
        )

        let handled = model.handleDeepLink(
            try XCTUnwrap(URL(string: "moneyup://quick-log/scan-receipt"))
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(model.state, .launching)
        XCTAssertFalse(model.canPresentLockedQuickCapture)
    }

    @MainActor
    func testLockedCaptureKeepsRouteUntilSuccessScreenIsDismissed() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let inbox = InMemoryLockedCaptureStore(captures: [])
        let model = fixture.model(lockedCaptureStore: inbox)
        UserDefaults.standard.set(
            true,
            forKey: AppModel.lockedQuickCapturePreferenceKey
        )
        model.lock()
        _ = model.handleDeepLink(
            try XCTUnwrap(URL(string: "moneyup://quick-log/expense"))
        )

        try await model.saveLockedCapture(
            mode: .expense,
            amountText: "12.50",
            payee: "",
            note: ""
        )

        XCTAssertEqual(model.requestedQuickLogMode, .expense)
        XCTAssertEqual(model.pendingLockedCaptureCount, 1)
        let captures = try await inbox.all()
        XCTAssertEqual(captures.count, 1)
        await fixture.store.close()
    }

    @MainActor
    func testPendingEraseIntentDeniesAndForgetsLockedCaptureRoute() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let inbox = InMemoryLockedCaptureStore(captures: [])
        let model = fixture.model(
            lockedCaptureStore: inbox,
            dataEraseIntent: DataEraseIntentAccess(
                isPending: { true },
                markPending: {},
                clear: {}
            )
        )
        UserDefaults.standard.set(
            true,
            forKey: AppModel.lockedQuickCapturePreferenceKey
        )
        model.lock()

        let handled = model.handleDeepLink(
            try XCTUnwrap(URL(string: "moneyup://quick-log/expense"))
        )

        XCTAssertTrue(handled)
        XCTAssertNil(model.requestedQuickLogMode)
        XCTAssertFalse(model.canPresentLockedQuickCapture)
        do {
            try await model.saveLockedCapture(
                mode: .expense,
                amountText: "12.50",
                payee: "",
                note: ""
            )
            XCTFail("A pending erase must deny redacted capture")
        } catch AppModelError.locked {
            // Startup must resume the erase instead of accepting doomed input.
        }
        let captures = try await inbox.all()
        XCTAssertTrue(captures.isEmpty)
        await fixture.store.close()
    }

    @MainActor
    func testEraseIntentReadFailureFailsClosedForLockedCapture() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let inbox = InMemoryLockedCaptureStore(captures: [])
        let model = fixture.model(
            lockedCaptureStore: inbox,
            dataEraseIntent: DataEraseIntentAccess(
                isPending: {
                    throw DatabaseKeyStoreError.unexpectedStatus(-31_339)
                },
                markPending: {},
                clear: {}
            )
        )
        UserDefaults.standard.set(
            true,
            forKey: AppModel.lockedQuickCapturePreferenceKey
        )
        model.lock()

        _ = model.handleDeepLink(
            try XCTUnwrap(URL(string: "moneyup://quick-log/income"))
        )

        XCTAssertNil(model.requestedQuickLogMode)
        XCTAssertFalse(model.canPresentLockedQuickCapture)
        let captures = try await inbox.all()
        XCTAssertTrue(captures.isEmpty)
        await fixture.store.close()
    }

    @MainActor
    func testAcceptedLockedCaptureWriteBlocksEraseUntilAppendFinishes() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let gate = AsyncGate()
        let inbox = PausingAppendLockedCaptureStore(gate: gate)
        let events = EraseEventRecorder()
        let model = fixture.model(
            lockedCaptureStore: inbox,
            dataEraseIntent: DataEraseIntentAccess(
                isPending: { false },
                markPending: { events.record("intent-marked") },
                clear: {}
            )
        )
        UserDefaults.standard.set(
            true,
            forKey: AppModel.lockedQuickCapturePreferenceKey
        )
        model.lock()
        _ = model.handleDeepLink(
            try XCTUnwrap(URL(string: "moneyup://quick-log/expense"))
        )
        let saveTask = Task { @MainActor in
            try await model.saveLockedCapture(
                mode: .expense,
                amountText: "12.50",
                payee: "",
                note: ""
            )
        }
        await gate.waitUntilReached()

        await model.eraseAllDataAndRestart()

        XCTAssertTrue(events.snapshot().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.databaseURL.path))
        await gate.release()
        try await saveTask.value
        let captures = try await inbox.all()
        XCTAssertEqual(captures.count, 1)
        await fixture.store.close()
    }

    @MainActor
    func testLockedCaptureRejectsMismatchedAndProtectedRoutes() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let inbox = InMemoryLockedCaptureStore(captures: [])
        let model = fixture.model(lockedCaptureStore: inbox)
        UserDefaults.standard.set(
            true,
            forKey: AppModel.lockedQuickCapturePreferenceKey
        )
        model.lock()
        _ = model.handleDeepLink(
            try XCTUnwrap(URL(string: "moneyup://quick-log/expense"))
        )

        do {
            try await model.saveLockedCapture(
                mode: .income,
                amountText: "12.50",
                payee: "",
                note: ""
            )
            XCTFail("Expected a mismatched locked route to be rejected")
        } catch AppModelError.locked {
            // The redacted form may only save the route the user opened.
        }

        _ = model.handleDeepLink(
            try XCTUnwrap(URL(string: "moneyup://quick-log/scan-receipt"))
        )
        do {
            try await model.saveLockedCapture(
                mode: .scanReceipt,
                amountText: "12.50",
                payee: "",
                note: ""
            )
            XCTFail("Expected a protected receipt route to require unlock")
        } catch AppModelError.locked {
            // Receipt capture never writes to the redacted inbox.
        }

        let captures = try await inbox.all()
        XCTAssertTrue(captures.isEmpty)
        XCTAssertEqual(model.pendingLockedCaptureCount, 0)
        await fixture.store.close()
    }

    @MainActor
    func testSavingReviewedCapturePromotesNextQueueItemExactlyOnce() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let first = LockedCapture(kind: .expense, amountText: "10")
        let second = LockedCapture(kind: .expense, amountText: "20")
        let inbox = InMemoryLockedCaptureStore(captures: [first, second])
        let model = fixture.model(lockedCaptureStore: inbox)

        try await model.promotePendingLockedCapture()
        XCTAssertEqual(model.quickLogDraft?.sourceCaptureID, first.id)
        XCTAssertEqual(model.pendingLockedCaptureCount, 1)

        _ = try await model.logExpense(
            amount: 10,
            accountID: fixture.wallet.id,
            categoryID: fixture.food.id,
            occurredAt: Date(),
            payee: nil,
            note: nil
        )

        XCTAssertEqual(model.quickLogDraft?.sourceCaptureID, second.id)
        XCTAssertEqual(model.quickLogDraft?.amountText, "20")
        XCTAssertEqual(model.pendingLockedCaptureCount, 0)
        let remaining = try await inbox.all()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(model.entries.count, 1)
        await fixture.store.close()
    }

    @MainActor
    func testCompletingFirstRunOnboardingPromotesExistingLockedCapture() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let capture = LockedCapture(
            kind: .expense,
            amountText: "14.25",
            occurredAt: Date(timeIntervalSinceReferenceDate: 415),
            payee: "Before setup"
        )
        let inbox = InMemoryLockedCaptureStore(captures: [capture])
        let model = fixture.model(
            profile: nil,
            accounts: [],
            lockedCaptureStore: inbox
        )

        try await model.completeOnboarding(
            baseCurrencyCode: "SGD",
            accountName: "First wallet",
            accountType: .cash,
            startingBalance: .zero
        )

        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.quickLogDraft?.sourceCaptureID, capture.id)
        XCTAssertEqual(model.quickLogDraft?.amountText, "14.25")
        let remainingCaptures = try await inbox.all()
        XCTAssertTrue(remainingCaptures.isEmpty)
        XCTAssertEqual(model.pendingLockedCaptureCount, 0)
        let storedDraft = try await fixture.store.fetch(
            QuickLogDraft.self,
            id: QuickLogDraft.primaryRecordID,
            from: .quickLogDrafts
        )
        XCTAssertEqual(storedDraft?.sourceCaptureID, capture.id)
        await fixture.store.close()
    }

    @MainActor
    func testFlexibleTodayBlocksLegacyLimitsUntilClassified() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model(
            budgetNodes: [
                BudgetNode(
                    id: fixture.food.id,
                    name: "Existing plan",
                    limit: try Money(600, currency: fixture.sgd)
                )
            ]
        )

        guard case let .available(status) = model.flexibleTodayResult() else {
            return XCTFail("Expected Flexible Today to be available with a classification prompt")
        }
        XCTAssertEqual(status, .needsClassification(count: 1))
        await fixture.store.close()
    }

    @MainActor
    func testFlexibleTodayDoesNotIncludeRentAllocation() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let rentID = UUID()
        let model = fixture.model(
            budgetNodes: [
                BudgetNode(
                    id: fixture.food.id,
                    name: "Flexible",
                    limit: try Money(600, currency: fixture.sgd),
                    purpose: .flexible
                ),
                BudgetNode(
                    id: rentID,
                    name: "Rent",
                    limit: try Money(1_500, currency: fixture.sgd),
                    purpose: .commitment
                )
            ]
        )

        guard case let .available(.available(breakdown)) = model.flexibleTodayResult()
        else {
            return XCTFail("Expected available flexible guidance")
        }
        XCTAssertEqual(breakdown.flexibleBudgetRemaining.amount, 600)
        await fixture.store.close()
    }

    @MainActor
    func testFlexibleTodayUsesProfileMonthAcrossDeviceZoneBoundary() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            reportingTimeZoneIdentifier: "America/Los_Angeles"
        )
        let model = fixture.model(
            profile: profile,
            budgetNodes: [
                BudgetNode(
                    id: fixture.food.id,
                    name: "Flexible",
                    limit: try Money(600, currency: fixture.sgd),
                    purpose: .flexible
                )
            ]
        )
        let asOf = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-03-01T07:30:00Z")
        )
        let expectedMonth = try XCTUnwrap(
            model.reportingCalendar.dateInterval(of: .month, for: asOf)
        )
        var simulatedDeviceCalendar = Calendar(identifier: .gregorian)
        simulatedDeviceCalendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let deviceMonth = try XCTUnwrap(
            simulatedDeviceCalendar.dateInterval(of: .month, for: asOf)
        )
        XCTAssertNotEqual(expectedMonth, deviceMonth)

        guard case let .available(.available(breakdown)) = model.flexibleTodayResult(asOf: asOf)
        else {
            return XCTFail("Expected available flexible guidance")
        }
        XCTAssertEqual(breakdown.periodStart, model.reportingCalendar.startOfDay(for: asOf))
        XCTAssertEqual(breakdown.periodEnd, expectedMonth.end)
        XCTAssertEqual(breakdown.remainingDayCount, 1)
        await fixture.store.close()
    }

    @MainActor
    func testArchiveHidesFromPickersButPreservesHistoryAndClearsSoftReferences() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let entry = try fixture.expense(amount: 14)
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            preferredAccountID: fixture.wallet.id
        )
        let draft = QuickLogDraft(
            kind: .expense,
            amountText: "14",
            destinationAmountText: "",
            accountID: fixture.wallet.id,
            destinationAccountID: nil,
            categoryID: fixture.food.id,
            occurredAt: Date(),
            dateWasEdited: false,
            payee: "Cafe",
            note: "",
            smartText: ""
        )
        try await fixture.seed(
            profile: profile,
            accounts: [fixture.wallet, fixture.usAccount, fixture.food],
            entries: [entry],
            quickLogDraft: draft
        )
        let model = fixture.model(
            profile: profile,
            entries: [entry],
            quickLogDraft: draft
        )

        try await model.setLedgerItemArchived(id: fixture.wallet.id, isArchived: true)

        XCTAssertFalse(model.userAccounts.contains { $0.id == fixture.wallet.id })
        XCTAssertTrue(model.allUserAccounts.contains { $0.id == fixture.wallet.id })
        XCTAssertEqual(model.entries, [entry])
        XCTAssertEqual(
            model.displayBalanceResult(for: fixture.wallet).value?.amount,
            -14
        )
        XCTAssertNil(model.profile?.preferredAccountID)
        XCTAssertNil(model.quickLogDraft?.accountID)
        XCTAssertEqual(model.quickLogDraft?.categoryID, fixture.food.id)
        do {
            _ = try await model.logExpense(
                amount: 1,
                accountID: fixture.wallet.id,
                categoryID: fixture.food.id,
                occurredAt: Date(),
                payee: nil,
                note: nil
            )
            XCTFail("Expected archived accounts to be rejected at the write boundary")
        } catch AppModelError.ledgerItemArchived {
            // The UI picker and the AppModel boundary enforce the same rule.
        }
        let stored = try await fixture.store.fetch(
            LedgerAccount.self,
            id: fixture.wallet.id.uuidString,
            from: .accounts
        )
        XCTAssertTrue(try XCTUnwrap(stored).isArchived)
        await fixture.store.close()
    }

    @MainActor
    func testCategoryMergeAtomicallyRepointsAllReferencesAndPreservesRevisionAudit() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let source = LedgerAccount(name: "Meals", kind: .expense)
        let target = fixture.food
        let child = LedgerAccount(
            name: "Work lunches",
            kind: .expense,
            parentID: source.id
        )
        let entry = try TransactionFactory.expense(
            amount: try Money(12, currency: fixture.sgd),
            paidFrom: fixture.wallet.id,
            category: source.id,
            occurredAt: Date(),
            payee: "Cafe",
            note: "Original note"
        )
        let schedule = try ScheduledTransaction(
            kind: .expense,
            name: "Lunch plan",
            amount: try Money(40, currency: fixture.sgd),
            accountID: fixture.wallet.id,
            categoryAccountID: source.id,
            nextOccurrence: Date(),
            frequency: .monthly
        )
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            preferredExpenseCategoryID: source.id
        )
        let draft = QuickLogDraft(
            kind: .expense,
            amountText: "12",
            destinationAmountText: "",
            accountID: fixture.wallet.id,
            destinationAccountID: nil,
            categoryID: source.id,
            occurredAt: Date(),
            dateWasEdited: false,
            payee: "Cafe",
            note: "",
            smartText: ""
        )
        let budgets = [
            BudgetNode(
                id: source.id,
                name: source.name,
                limit: try Money(100, currency: fixture.sgd),
                purpose: .flexible
            ),
            BudgetNode(
                id: target.id,
                name: target.name,
                limit: try Money(250, currency: fixture.sgd),
                purpose: .flexible
            ),
            BudgetNode(id: child.id, parentID: source.id, name: child.name)
        ]
        let sourceAccounts = [fixture.wallet, fixture.usAccount, source, target, child]
        try await fixture.seed(
            profile: profile,
            accounts: sourceAccounts,
            entries: [entry],
            budgetNodes: budgets,
            schedules: [schedule],
            quickLogDraft: draft
        )
        let model = fixture.model(
            profile: profile,
            accounts: sourceAccounts,
            entries: [entry],
            budgetNodes: budgets,
            scheduledTransactions: [schedule],
            quickLogDraft: draft
        )

        try await model.mergeLedgerItem(id: source.id, into: target.id)

        XCTAssertFalse(model.accounts.contains { $0.id == source.id })
        XCTAssertEqual(
            model.accounts.first { $0.id == child.id }?.parentID,
            target.id
        )
        let mergedEntry = try XCTUnwrap(model.entries.first)
        XCTAssertEqual(mergedEntry.id, entry.id)
        XCTAssertEqual(mergedEntry.createdAt, entry.createdAt)
        XCTAssertEqual(mergedEntry.note, entry.note)
        XCTAssertEqual(mergedEntry.originContext, entry.originContext)
        XCTAssertFalse(mergedEntry.postings.contains { $0.accountID == source.id })
        XCTAssertTrue(mergedEntry.postings.contains { $0.accountID == target.id })
        XCTAssertTrue(mergedEntry.balanceByCurrency.values.allSatisfy { $0 == .zero })
        XCTAssertEqual(model.scheduledTransactions.first?.categoryAccountID, target.id)
        XCTAssertEqual(model.profile?.preferredExpenseCategoryID, target.id)
        XCTAssertEqual(model.quickLogDraft?.categoryID, target.id)
        XCTAssertEqual(
            model.budgetNodes.first { $0.id == target.id }?.limit?.amount,
            350
        )
        XCTAssertEqual(
            model.budgetNodes.first { $0.id == child.id }?.parentID,
            target.id
        )

        let storedSource = try await fixture.store.fetch(
            LedgerAccount.self,
            id: source.id.uuidString,
            from: .accounts
        )
        let revisions = try await fixture.store.fetchAll(
            JournalEntry.self,
            from: .journalEntryRevisions
        )
        let audits = try await fixture.store.fetchAll(
            LedgerAccountLifecycleAudit.self,
            from: .accountLifecycleAudit
        )
        XCTAssertNil(storedSource)
        XCTAssertEqual(revisions, [entry])
        XCTAssertEqual(audits.count, 1)
        XCTAssertEqual(audits.first?.action, .merged)
        XCTAssertEqual(audits.first?.before.name, "Meals")
        XCTAssertEqual(audits.first?.affectedJournalEntryIDs, [entry.id])
        await fixture.store.close()
    }

    @MainActor
    func testIncompatibleMergeAndUsedDeletionFailBeforeChangingBook() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let entry = try fixture.expense(amount: 8)
        let model = fixture.model(entries: [entry])

        do {
            try await model.mergeLedgerItem(
                id: fixture.wallet.id,
                into: fixture.usAccount.id
            )
            XCTFail("Expected different currencies to be rejected")
        } catch AppModelError.incompatibleLedgerItems {
            // Expected.
        }
        do {
            try await model.deleteLedgerItem(id: fixture.food.id)
            XCTFail("Expected a referenced category to require reassignment")
        } catch AppModelError.ledgerItemInUse {
            // Expected.
        }

        XCTAssertEqual(model.accounts, [fixture.wallet, fixture.usAccount, fixture.food])
        XCTAssertEqual(model.entries, [entry])
        let auditCount = try await fixture.store.count(in: .accountLifecycleAudit)
        XCTAssertEqual(auditCount, 0)
        await fixture.store.close()
    }

    @MainActor
    func testAccountDeleteWithReassignmentMovesHoldingScheduleDefaultAndDraft() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let target = LedgerAccount(
            name: "Daily bank",
            kind: .asset,
            currency: fixture.sgd,
            accountType: .bank
        )
        let schedule = try ScheduledTransaction(
            kind: .expense,
            name: "Groceries",
            amount: try Money(50, currency: fixture.sgd),
            accountID: fixture.wallet.id,
            categoryAccountID: fixture.food.id,
            nextOccurrence: Date(),
            frequency: .weekly
        )
        let holding = try InvestmentHolding(
            accountID: fixture.wallet.id,
            symbol: "MU",
            name: "Micron",
            quantity: 1,
            price: try Money(100, currency: fixture.sgd)
        )
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            preferredAccountID: fixture.wallet.id
        )
        let draft = QuickLogDraft(
            kind: .transfer,
            amountText: "10",
            destinationAmountText: "",
            accountID: fixture.wallet.id,
            destinationAccountID: target.id,
            categoryID: nil,
            occurredAt: Date(),
            dateWasEdited: false,
            payee: "",
            note: "",
            smartText: ""
        )
        let sourceAccounts = [fixture.wallet, target, fixture.food]
        try await fixture.seed(
            profile: profile,
            accounts: sourceAccounts,
            schedules: [schedule],
            holdings: [holding],
            quickLogDraft: draft
        )
        let model = fixture.model(
            profile: profile,
            accounts: sourceAccounts,
            scheduledTransactions: [schedule],
            investmentHoldings: [holding],
            quickLogDraft: draft
        )

        try await model.deleteLedgerItem(
            id: fixture.wallet.id,
            reassigningTo: target.id
        )

        XCTAssertFalse(model.accounts.contains { $0.id == fixture.wallet.id })
        XCTAssertEqual(model.scheduledTransactions.first?.accountID, target.id)
        XCTAssertEqual(model.investmentHoldings.first?.accountID, target.id)
        XCTAssertEqual(model.profile?.preferredAccountID, target.id)
        XCTAssertEqual(model.quickLogDraft?.accountID, target.id)
        XCTAssertNil(model.quickLogDraft?.destinationAccountID)
        let storedHolding = try await fixture.store.fetch(
            InvestmentHolding.self,
            id: holding.id.uuidString,
            from: .investmentHoldings
        )
        let storedSchedule = try await fixture.store.fetch(
            ScheduledTransaction.self,
            id: schedule.id.uuidString,
            from: .scheduledTransactions
        )
        XCTAssertEqual(storedHolding?.accountID, target.id)
        XCTAssertEqual(storedSchedule?.accountID, target.id)
        await fixture.store.close()
    }

    @MainActor
    func testUnusedCategoryDeletesWhileSystemAccountLifecycleIsRejected() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let unused = LedgerAccount(name: "Unused income", kind: .income)
        let system = LedgerAccount(
            name: "Opening balances",
            kind: .equity,
            systemRole: .openingBalances
        )
        let sourceAccounts = [fixture.wallet, fixture.usAccount, fixture.food, unused, system]
        try await fixture.seed(
            profile: UserProfile(baseCurrency: fixture.sgd),
            accounts: sourceAccounts
        )
        let model = fixture.model(accounts: sourceAccounts)

        try await model.renameLedgerItem(id: unused.id, name: "Side income")
        XCTAssertEqual(model.accounts.first { $0.id == unused.id }?.name, "Side income")
        try await model.deleteLedgerItem(id: unused.id)
        XCTAssertFalse(model.accounts.contains { $0.id == unused.id })
        let storedUnused = try await fixture.store.fetch(
            LedgerAccount.self,
            id: unused.id.uuidString,
            from: .accounts
        )
        XCTAssertNil(storedUnused)

        do {
            try await model.setLedgerItemArchived(id: system.id, isArchived: true)
            XCTFail("Expected protected system-account lifecycle")
        } catch AppModelError.systemAccountLifecycleForbidden {
            // Expected.
        }
        await fixture.store.close()
    }

    @MainActor
    func testSplitAndExplicitReceiptCommitThenDeleteAtomically() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let transport = LedgerAccount(name: "Transport", kind: .expense)
        let model = fixture.model(
            accounts: [fixture.wallet, fixture.usAccount, fixture.food, transport]
        )
        let lines = [
            TransactionSplitLine(
                categoryAccountID: fixture.food.id,
                amount: try Money(7.25, currency: fixture.sgd),
                memo: "Lunch"
            ),
            TransactionSplitLine(
                categoryAccountID: transport.id,
                amount: try Money(2.75, currency: fixture.sgd),
                memo: "Bus"
            )
        ]

        let savedEntryID = try await model.logSplitTransaction(
            kind: .expense,
            amount: 10,
            accountID: fixture.wallet.id,
            lines: lines,
            occurredAt: Date(),
            payee: "Cafe and bus",
            note: nil,
            receiptData: Data([0xff, 0xd8, 0xff, 0x01])
        )
        let entryID = try XCTUnwrap(savedEntryID)

        XCTAssertEqual(model.entries.first?.postings.count, 3)
        XCTAssertEqual(model.receiptAttachments.count, 1)
        XCTAssertEqual(model.receiptAttachments.first?.entryID, entryID)
        let attachmentID = try XCTUnwrap(model.receiptAttachments.first?.id)
        let selectedAttachment = try await model.receiptAttachment(id: attachmentID)
        XCTAssertEqual(selectedAttachment.data, Data([0xff, 0xd8, 0xff, 0x01]))
        let savedEntryCount = try await fixture.store.count(in: .journalEntries)
        let savedAttachmentCount = try await fixture.store.count(in: .receiptAttachments)
        XCTAssertEqual(savedEntryCount, 1)
        XCTAssertEqual(savedAttachmentCount, 1)
        let originalOrigin = model.entries[0].originContext

        let revisedLines = [
            TransactionSplitLine(
                categoryAccountID: fixture.food.id,
                amount: try Money(6, currency: fixture.sgd),
                memo: "Meal revised"
            ),
            TransactionSplitLine(
                categoryAccountID: transport.id,
                amount: try Money(4, currency: fixture.sgd),
                memo: "Ride revised"
            )
        ]
        try await model.replaceEntry(
            id: entryID,
            kind: .expense,
            amount: 10,
            destinationAmount: nil,
            accountID: fixture.wallet.id,
            destinationAccountID: nil,
            categoryID: nil,
            splitLines: revisedLines,
            occurredAt: model.entries[0].occurredAt,
            payee: "Cafe and bus",
            note: "Rebalanced"
        )

        let replacement = try XCTUnwrap(model.entries.first)
        let categoryPostings = replacement.postings.filter {
            $0.accountID == fixture.food.id || $0.accountID == transport.id
        }
        XCTAssertEqual(categoryPostings.count, 2)
        XCTAssertEqual(Set(categoryPostings.map(\.accountID)), Set([fixture.food.id, transport.id]))
        XCTAssertEqual(Set(categoryPostings.compactMap(\.memo)), Set(["Meal revised", "Ride revised"]))
        XCTAssertEqual(model.receiptAttachments.first?.entryID, replacement.id)
        let relinkedAttachment = try await model.receiptAttachment(id: attachmentID)
        XCTAssertEqual(relinkedAttachment.entryID, replacement.id)
        XCTAssertNotEqual(replacement.id, entryID)
        XCTAssertEqual(replacement.originContext, originalOrigin)

        try await model.deleteEntry(id: replacement.id)

        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertTrue(model.receiptAttachments.isEmpty)
        let deletedEntryCount = try await fixture.store.count(in: .journalEntries)
        let deletedAttachmentCount = try await fixture.store.count(in: .receiptAttachments)
        XCTAssertEqual(deletedEntryCount, 0)
        XCTAssertEqual(deletedAttachmentCount, 0)
        await fixture.store.close()
    }

    @MainActor
    func testLedgerLinkedHoldingDoesNotDoubleCountFundedCash() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let equity = LedgerAccount(
            name: "Opening balances",
            kind: .equity,
            systemRole: .openingBalances
        )
        let brokerage = LedgerAccount(
            name: "Brokerage cash",
            kind: .asset,
            currency: fixture.sgd,
            accountType: .brokerage
        )
        let opening = try TransactionFactory.balanceAdjustment(
            displayBalanceDelta: try Money(10_000, currency: fixture.sgd),
            accountID: brokerage.id,
            equityAccountID: equity.id,
            accountIsLiability: false
        )
        let sourceAccounts = [brokerage, fixture.usAccount, fixture.food, equity]
        let model = fixture.model(accounts: sourceAccounts, entries: [opening])
        let holding = try InvestmentHolding(
            accountID: brokerage.id,
            symbol: "MU",
            name: "Micron",
            quantity: 20,
            price: try Money(200, currency: fixture.sgd),
            priceAsOf: Date()
        )

        try await model.addInvestmentHolding(
            holding,
            treatment: .deductFromCash
        )
        let amounts = try XCTUnwrap(model.netWorthByCurrencyResult().value)
        XCTAssertEqual(amounts.first { $0.currency == fixture.sgd }?.amount, 10_000)
        XCTAssertEqual(model.userAccounts.count, 2)
        XCTAssertEqual(model.investmentHoldings.first?.lots.count, 1)
        XCTAssertNotNil(model.investmentHoldings.first?.positionAccountID)
        let journalEntryCount = try await fixture.store.count(in: .journalEntries)
        XCTAssertEqual(journalEntryCount, 1)
        // The injected opening is intentionally not pre-seeded in this unit
        // fixture; only the new atomic purchase is persisted by this action.
        let holdingCount = try await fixture.store.count(in: .investmentHoldings)
        XCTAssertEqual(holdingCount, 1)

        do {
            try await model.deleteInvestmentHolding(id: holding.id)
            XCTFail("Expected a non-empty holding to be protected")
        } catch AppModelError.investmentHoldingNotEmpty {
            // A position must be disposed before its metadata can be removed.
        }
        _ = try await model.recordInvestmentSale(
            holdingID: holding.id,
            quantity: 20,
            unitPrice: 200,
            occurredAt: Date()
        )
        XCTAssertEqual(
            model.netWorthByCurrencyResult().value?
                .first { $0.currency == fixture.sgd }?.amount,
            10_000
        )
        try await model.deleteInvestmentHolding(id: holding.id)
        XCTAssertEqual(model.investmentHoldings.count, 1)
        XCTAssertTrue(model.investmentHoldings[0].isArchived)
        XCTAssertFalse(model.investmentHoldings[0].lots.isEmpty)
        XCTAssertFalse(model.investmentHoldings[0].disposals.isEmpty)
        await fixture.store.close()
    }

    @MainActor
    func testInitialHoldingCanPreserveCashThatAlreadyExcludesPosition() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let brokerage = LedgerAccount(
            name: "Brokerage cash",
            kind: .asset,
            currency: fixture.sgd,
            accountType: .brokerage
        )
        let equity = LedgerAccount(
            name: "Opening balances",
            kind: .equity,
            systemRole: .openingBalances
        )
        let opening = try TransactionFactory.balanceAdjustment(
            displayBalanceDelta: try Money(10_000, currency: fixture.sgd),
            accountID: brokerage.id,
            equityAccountID: equity.id,
            accountIsLiability: false
        )
        let model = fixture.model(
            accounts: [brokerage, fixture.food, equity],
            entries: [opening]
        )
        let holding = try InvestmentHolding(
            accountID: brokerage.id,
            symbol: "MU",
            name: "Micron",
            quantity: 20,
            price: try Money(200, currency: fixture.sgd),
            priceAsOf: Date()
        )

        try await model.addInvestmentHolding(
            holding,
            treatment: .cashAlreadyExcludesPosition
        )

        XCTAssertEqual(model.displayBalanceResult(for: brokerage).value?.amount, 10_000)
        XCTAssertEqual(
            model.netWorthByCurrencyResult().value?.first?.amount,
            14_000
        )
        XCTAssertEqual(model.entries.filter { $0.kind == .investment }.count, 1)
        XCTAssertEqual(model.entries.filter { $0.kind == .adjustment }.count, 1)
        await fixture.store.close()
    }

    @MainActor
    func testDatedRateReplacesSamePairAndDayWithoutAmbiguousLookup() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()
        let myr = try CurrencyCode("MYR")
        let date = Date(timeIntervalSince1970: 1_777_000_000)

        try await model.saveExchangeRate(
            baseCurrency: fixture.sgd,
            quoteCurrency: myr,
            rate: 3.4,
            effectiveAt: date,
            timeZone: TimeZone(secondsFromGMT: 8 * 3_600)!
        )
        try await model.saveExchangeRate(
            baseCurrency: myr,
            quoteCurrency: fixture.sgd,
            rate: Decimal(string: "0.285714")!,
            effectiveAt: date,
            timeZone: TimeZone(secondsFromGMT: 8 * 3_600)!
        )

        XCTAssertEqual(model.exchangeRates.count, 1)
        let storedRateCount = try await fixture.store.count(in: .exchangeRates)
        XCTAssertEqual(storedRateCount, 1)
        let conversion = try model.historicalConversion(
            amount: 10,
            from: fixture.sgd,
            to: myr,
            occurredAt: date
        )
        XCTAssertNotNil(conversion)
        XCTAssertTrue(conversion?.isEstimated == true)
        await fixture.store.close()
    }

    @MainActor
    func testConcurrentSameDayExchangeRateSavesLeaveOneCanonicalRecord() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()
        let myr = try CurrencyCode("MYR")
        let date = Date(timeIntervalSince1970: 1_777_000_000)

        async let direct: Void = model.saveExchangeRate(
            baseCurrency: fixture.sgd,
            quoteCurrency: myr,
            rate: 3.4,
            effectiveAt: date
        )
        async let inverse: Void = model.saveExchangeRate(
            baseCurrency: myr,
            quoteCurrency: fixture.sgd,
            rate: Decimal(string: "0.285714")!,
            effectiveAt: date
        )
        _ = try await (direct, inverse)

        XCTAssertEqual(model.exchangeRates.count, 1)
        let storedRateCount = try await fixture.store.count(in: .exchangeRates)
        XCTAssertEqual(storedRateCount, 1)
        await fixture.store.close()
    }

    @MainActor
    func testHistoricalConversionUsesProfileDayInsteadOfDeviceDay() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            reportingTimeZoneIdentifier: "America/Los_Angeles"
        )
        let model = fixture.model(profile: profile)
        let myr = try CurrencyCode("MYR")
        let day15 = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-02-15T20:00:00Z")
        )
        let day16 = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-02-16T20:00:00Z")
        )
        try await model.saveExchangeRate(
            baseCurrency: fixture.sgd,
            quoteCurrency: myr,
            rate: 3,
            effectiveAt: day15
        )
        try await model.saveExchangeRate(
            baseCurrency: fixture.sgd,
            quoteCurrency: myr,
            rate: 4,
            effectiveAt: day16
        )
        let lateOnReportingDay15 = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-02-16T07:30:00Z")
        )

        let conversion = try XCTUnwrap(
            model.historicalConversion(
                amount: 10,
                from: fixture.sgd,
                to: myr,
                occurredAt: lateOnReportingDay15
            )
        )
        XCTAssertEqual(conversion.converted.amount, 30)
        XCTAssertEqual(conversion.effectiveDayKey, 20260215)
        await fixture.store.close()
    }

    @MainActor
    func testSnapshotFreezesValuesBeforeLaterRepricing() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let brokerage = LedgerAccount(
            name: "Brokerage",
            kind: .asset,
            currency: fixture.sgd,
            accountType: .brokerage
        )
        let model = fixture.model(accounts: [brokerage, fixture.food])
        let holding = try InvestmentHolding(
            accountID: brokerage.id,
            symbol: "MU",
            name: "Micron",
            quantity: 2,
            price: try Money(100, currency: fixture.sgd),
            priceAsOf: Date(timeIntervalSinceReferenceDate: 1_000)
        )
        try await model.addInvestmentHolding(
            holding,
            treatment: .deductFromCash
        )
        try await model.captureNetWorthSnapshot(
            at: Date(timeIntervalSinceReferenceDate: 2_000)
        )
        let frozen = try XCTUnwrap(model.netWorthSnapshots.first)

        try await model.repriceInvestmentHolding(
            id: holding.id,
            unitPrice: 150,
            asOf: Date(timeIntervalSinceReferenceDate: 3_000)
        )

        XCTAssertEqual(frozen.amounts.first?.money.amount, 0)
        XCTAssertEqual(model.netWorthSnapshots.first, frozen)
        XCTAssertEqual(model.investmentHoldings.first?.priceHistory.count, 2)
        let snapshotCount = try await fixture.store.count(in: .netWorthSnapshots)
        XCTAssertEqual(snapshotCount, 1)
        await fixture.store.close()
    }

    @MainActor
    func testMoneyWriteBoundariesRejectHugeAndWrongScaleAmountsBeforePersistence() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()
        let oversized = MonetaryInputPolicy.maximumAbsoluteNewWrite + 1

        do {
            _ = try await model.logExpense(
                amount: oversized,
                accountID: fixture.wallet.id,
                categoryID: fixture.food.id,
                occurredAt: Date(),
                payee: nil,
                note: nil
            )
            XCTFail("Expected an oversized amount to be rejected")
        } catch AppModelError.amountTooLarge {
            // Expected.
        }
        let countAfterOversizedAttempt = try await fixture.store.count(
            in: .journalEntries
        )
        XCTAssertEqual(countAfterOversizedAttempt, 0)

        let jpy = try CurrencyCode("JPY")
        let yenWallet = LedgerAccount(name: "Yen", kind: .asset, currency: jpy)
        let yenModel = fixture.model(accounts: [yenWallet, fixture.food])
        do {
            _ = try await yenModel.logExpense(
                amount: Decimal(string: "100.5")!,
                accountID: yenWallet.id,
                categoryID: fixture.food.id,
                occurredAt: Date(),
                payee: nil,
                note: nil
            )
            XCTFail("Expected JPY fractional precision to be rejected")
        } catch AppModelError.unsupportedPrecision(let currency) {
            XCTAssertEqual(currency, jpy)
        }
        let countAfterWrongScaleAttempt = try await fixture.store.count(
            in: .journalEntries
        )
        XCTAssertEqual(countAfterWrongScaleAttempt, 0)

        let legacySchedule = try ScheduledTransaction(
            kind: .expense,
            name: "Legacy oversized schedule",
            amount: Money(oversized, currency: fixture.sgd),
            accountID: fixture.wallet.id,
            categoryAccountID: fixture.food.id,
            nextOccurrence: Date(),
            frequency: .monthly
        )
        let scheduleModel = fixture.model(
            scheduledTransactions: [legacySchedule]
        )
        do {
            _ = try await scheduleModel.postScheduledOccurrence(
                scheduleID: legacySchedule.id,
                occurrenceID: legacySchedule.currentOccurrenceID
            )
            XCTFail("Expected a new posting from an oversized legacy schedule to fail")
        } catch AppModelError.amountTooLarge {
            // Expected; the stored schedule itself remains untouched.
        }
        let countAfterScheduleAttempt = try await fixture.store.count(
            in: .journalEntries
        )
        XCTAssertEqual(countAfterScheduleAttempt, 0)
        await fixture.store.close()
    }

    @MainActor
    func testInvestmentMutationRejectsBackdatedAndFutureActivity() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let brokerage = LedgerAccount(
            name: "Brokerage",
            kind: .asset,
            currency: fixture.sgd,
            accountType: .brokerage
        )
        let model = fixture.model(accounts: [brokerage, fixture.food])
        let openingDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let holding = try InvestmentHolding(
            accountID: brokerage.id,
            symbol: "MU",
            name: "Micron",
            quantity: 2,
            price: try Money(100, currency: fixture.sgd),
            priceAsOf: openingDate
        )
        try await model.addInvestmentHolding(
            holding,
            treatment: .deductFromCash
        )
        let retainedHolding = try XCTUnwrap(model.investmentHoldings.first)
        let retainedEntries = model.entries

        do {
            try await model.repriceInvestmentHolding(
                id: holding.id,
                unitPrice: 90,
                asOf: openingDate.addingTimeInterval(-1)
            )
            XCTFail("Expected chronological replay protection")
        } catch AppModelError.investmentDateOutOfOrder {
            // Earlier events are not silently inserted into a newer position.
        }
        do {
            try await model.recordInvestmentPurchase(
                holdingID: holding.id,
                quantity: 1,
                unitPrice: 90,
                occurredAt: Date().addingTimeInterval(86_400)
            )
            XCTFail("Expected future activity rejection")
        } catch AppModelError.investmentDateInFuture {
            // Future entries would incorrectly change today's net worth.
        }

        XCTAssertEqual(model.investmentHoldings.first, retainedHolding)
        XCTAssertEqual(model.entries, retainedEntries)
        let journalEntryCount = try await fixture.store.count(
            in: .journalEntries
        )
        let investmentHoldingCount = try await fixture.store.count(
            in: .investmentHoldings
        )
        XCTAssertEqual(journalEntryCount, 1)
        XCTAssertEqual(investmentHoldingCount, 1)
        await fixture.store.close()
    }

    @MainActor
    func testUnchangedLegacyTransactionAmountCanBeSavedExactly() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let legacyAmount = try XCTUnwrap(
            Decimal(string: "1000000000000000.12345")
        )
        let original = try TransactionFactory.expense(
            amount: Money(legacyAmount, currency: fixture.sgd),
            paidFrom: fixture.wallet.id,
            category: fixture.food.id,
            occurredAt: Date(timeIntervalSinceReferenceDate: 42),
            payee: "Legacy"
        )
        let model = fixture.model(entries: [original])

        try await model.replaceEntry(
            id: original.id,
            kind: .expense,
            amount: legacyAmount,
            destinationAmount: nil,
            accountID: fixture.wallet.id,
            destinationAccountID: nil,
            categoryID: fixture.food.id,
            occurredAt: original.occurredAt,
            payee: original.payee,
            note: "Metadata-only edit"
        )

        let replacement = try XCTUnwrap(model.entries.first)
        let assetPosting = try XCTUnwrap(
            replacement.postings.first { $0.accountID == fixture.wallet.id }
        )
        XCTAssertEqual(abs(assetPosting.money.amount), legacyAmount)
        XCTAssertEqual(replacement.note, "Metadata-only edit")

        do {
            try await model.replaceEntry(
                id: replacement.id,
                kind: .expense,
                amount: legacyAmount + 1,
                destinationAmount: nil,
                accountID: fixture.wallet.id,
                destinationAccountID: nil,
                categoryID: fixture.food.id,
                occurredAt: replacement.occurredAt,
                payee: replacement.payee,
                note: replacement.note
            )
            XCTFail("Expected a changed oversized legacy amount to be rejected")
        } catch AppModelError.amountTooLarge {
            // Expected.
        }
        await fixture.store.close()
    }

    @MainActor
    func testReviewedImportMappingsUseExistingLedgerTargets() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let salary = LedgerAccount(name: "Salary", kind: .income)
        let accounts = [fixture.wallet, fixture.usAccount, fixture.food, salary]
        let model = fixture.model(accounts: accounts)
        let row = ImportedTransaction(
            id: "source-1",
            sourceLine: 2,
            kind: .expense,
            occurredAt: Date(),
            amount: 6,
            accountName: "My cash",
            categoryName: "Meals from old app"
        )

        let result = try await model.importTransactions(
            [row],
            fallbackAccountID: fixture.wallet.id,
            fallbackExpenseCategoryID: fixture.food.id,
            fallbackIncomeCategoryID: salary.id,
            accountMappings: ["my cash": fixture.wallet.id],
            expenseCategoryMappings: ["meals from old app": fixture.food.id]
        )

        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(result.categoriesCreated, 0)
        XCTAssertEqual(model.accounts.count, accounts.count)
        XCTAssertTrue(
            model.entries.first?.postings.contains {
                $0.accountID == fixture.food.id && $0.money.amount == 6
            } == true
        )
        await fixture.store.close()
    }

    @MainActor
    func testImportCannotFallThroughWrongCurrencyMappingToHiddenPosition() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let salary = LedgerAccount(name: "Salary", kind: .income)
        let brokerage = LedgerAccount(
            name: "USD Brokerage",
            kind: .asset,
            currency: fixture.usd,
            accountType: .brokerage
        )
        let profile = UserProfile(baseCurrency: fixture.sgd)
        let accounts = [
            fixture.wallet, fixture.usAccount, brokerage, fixture.food, salary
        ]
        try await fixture.seed(profile: profile, accounts: accounts)
        let model = fixture.model(profile: profile, accounts: accounts)
        let holding = try InvestmentHolding(
            accountID: brokerage.id,
            symbol: "MU",
            name: "MoneyUp",
            quantity: .zero
        )
        try await model.addInvestmentHolding(
            holding,
            treatment: .deductFromCash
        )
        let position = try XCTUnwrap(
            model.accounts.first { $0.systemRole == .investmentPosition }
        )
        let row = ImportedTransaction(
            id: "position-name-collision",
            hasExternalID: true,
            sourceLine: 2,
            kind: .expense,
            occurredAt: Date(timeIntervalSinceReferenceDate: 100),
            amount: 10,
            currencyCode: fixture.usd.value,
            accountName: position.name,
            categoryName: fixture.food.name
        )

        let result = try await model.importTransactions(
            [row],
            fallbackAccountID: fixture.wallet.id,
            fallbackExpenseCategoryID: fixture.food.id,
            fallbackIncomeCategoryID: salary.id,
            accountMappings: [
                CSVImportNameResolver.normalizedKey(for: position.name): fixture.wallet.id
            ]
        )

        XCTAssertEqual(result.imported, 0)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertTrue(model.entries.isEmpty)
        let storedEntryCount = try await fixture.store.count(
            in: .journalEntries
        )
        XCTAssertEqual(storedEntryCount, 0)
        await fixture.store.close()
    }

    @MainActor
    func testImportRejectsMaliciousSystemAccountAndCategoryMappings() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let salary = LedgerAccount(name: "Salary", kind: .income)
        let position = LedgerAccount(
            name: "Hidden USD Position",
            kind: .asset,
            currency: fixture.usd,
            systemRole: .investmentPosition
        )
        let systemExpense = LedgerAccount(
            name: "System Expense",
            kind: .expense,
            systemRole: .investmentGainLoss
        )
        let accounts = [
            fixture.wallet, fixture.usAccount, fixture.food, salary,
            position, systemExpense
        ]
        let model = fixture.model(accounts: accounts)
        let row = ImportedTransaction(
            id: "malicious-system-mappings",
            hasExternalID: true,
            sourceLine: 2,
            kind: .expense,
            occurredAt: Date(timeIntervalSinceReferenceDate: 200),
            amount: 12,
            currencyCode: fixture.usd.value,
            accountName: "Mapped source",
            categoryName: systemExpense.name
        )

        let result = try await model.importTransactions(
            [row],
            fallbackAccountID: fixture.usAccount.id,
            fallbackExpenseCategoryID: fixture.food.id,
            fallbackIncomeCategoryID: salary.id,
            accountMappings: ["mapped source": position.id],
            expenseCategoryMappings: ["system expense": systemExpense.id]
        )

        XCTAssertEqual(result.imported, 1)
        let entry = try XCTUnwrap(model.entries.first)
        XCTAssertTrue(entry.postings.contains { $0.accountID == fixture.usAccount.id })
        XCTAssertFalse(entry.postings.contains { $0.accountID == position.id })
        XCTAssertFalse(entry.postings.contains { $0.accountID == systemExpense.id })
        let replacementCategory = try XCTUnwrap(model.accounts.first {
            $0.name == systemExpense.name && $0.id != systemExpense.id
        })
        XCTAssertNil(replacementCategory.systemRole)
        XCTAssertTrue(entry.postings.contains { $0.accountID == replacementCategory.id })
        await fixture.store.close()
    }

    @MainActor
    func testLockDeferredDuringCSVImportAppliesAfterExactCommit() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let salary = LedgerAccount(name: "Salary", kind: .income)
        let gate = AsyncGate()
        let model = fixture.model(
            accounts: [fixture.wallet, fixture.food, salary],
            lifecycleHooks: hooks(pausing: .beforeJournalCommit, at: gate)
        )
        let row = ImportedTransaction(
            id: "lock-during-import",
            sourceLine: 2,
            kind: .expense,
            occurredAt: Date(timeIntervalSinceReferenceDate: 2_026),
            amount: 17,
            accountName: fixture.wallet.name,
            categoryName: fixture.food.name,
            payee: "Durable import"
        )

        let importTask = Task { @MainActor in
            try await model.importTransactions(
                [row],
                fallbackAccountID: fixture.wallet.id,
                fallbackExpenseCategoryID: fixture.food.id,
                fallbackIncomeCategoryID: salary.id
            )
        }
        await gate.waitUntilReached()
        model.lock()
        XCTAssertEqual(model.state, .ready)

        await gate.release()
        let result = try await importTask.value
        XCTAssertEqual(result.imported, 1)
        await model.waitForPendingStoreClose()
        XCTAssertEqual(model.state, .locked)
        XCTAssertTrue(model.entries.isEmpty)

        let reopened = try fixture.reopenStore()
        let persisted = try await reopened.fetchAll(
            JournalEntry.self,
            from: .journalEntries
        )
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted.first?.payee, "Durable import")
        await reopened.close()
    }

    @MainActor
    func testCSVImportBudgetAttributionPreservesPlus14AndMinus12CivilMonths() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let salary = LedgerAccount(name: "Salary", kind: .income)
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            reportingTimeZoneIdentifier: "GMT"
        )
        let model = fixture.model(
            profile: profile,
            accounts: [fixture.wallet, fixture.food, salary]
        )
        let preview = try TransactionCSVImporter.parse(
            """
            ID,Date,Type,Amount,Payee
            plus-14,2026-03-01T00:30:00+14:00,Expense,5,Plus fourteen
            minus-12,2026-02-28T23:30:00-12:00,Expense,6,Minus twelve
            """,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(
            preview.rows.compactMap { $0.originContext?.dayKey },
            [20260301, 20260228]
        )

        let result = try await model.importTransactions(
            preview.rows,
            fallbackAccountID: fixture.wallet.id,
            fallbackExpenseCategoryID: fixture.food.id,
            fallbackIncomeCategoryID: salary.id
        )

        XCTAssertEqual(result.imported, 2)
        let attributions = try await fixture.store.fetchAll(
            BudgetEntryAttribution.self,
            from: .budgetEntryAttributions
        )
        XCTAssertEqual(
            Set(attributions.map {
                "\($0.originDayKey):\($0.originUTCOffsetSeconds)"
            }),
            Set(["2026-03-01:50400", "2026-02-28:-43200"])
        )
        await fixture.store.close()
    }

    @MainActor
    func testExternalImportIDOverridesOnlySemanticDuplicateHeuristic() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let salary = LedgerAccount(name: "Salary", kind: .income)
        let occurredAt = Date(timeIntervalSinceReferenceDate: 500_000)
        let existing = try TransactionFactory.expense(
            amount: try Money(6, currency: fixture.sgd),
            paidFrom: fixture.wallet.id,
            category: fixture.food.id,
            occurredAt: occurredAt,
            payee: "Same-second cafe"
        )
        let profile = UserProfile(baseCurrency: fixture.sgd)
        let accounts = [fixture.wallet, fixture.food, salary]
        try await fixture.seed(
            profile: profile,
            accounts: accounts,
            entries: [existing]
        )
        let model = fixture.model(
            profile: profile,
            accounts: accounts,
            entries: [existing]
        )
        let authoritative = ImportedTransaction(
            id: "bank-transaction-123",
            hasExternalID: true,
            sourceLine: 2,
            kind: .expense,
            occurredAt: occurredAt,
            amount: 6,
            payee: "Same-second cafe"
        )
        let heuristicOnly = ImportedTransaction(
            id: "sha256:v2:synthetic-row",
            sourceLine: 3,
            kind: .expense,
            occurredAt: occurredAt,
            amount: 6,
            payee: "Same-second cafe"
        )

        let result = try await model.importTransactions(
            [authoritative, heuristicOnly],
            fallbackAccountID: fixture.wallet.id,
            fallbackExpenseCategoryID: fixture.food.id,
            fallbackIncomeCategoryID: salary.id
        )

        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(result.duplicates, 1)
        let persistedFingerprint = TransactionCSVImporter.persistenceFingerprint(
            for: authoritative.id,
            sourceSystem: "CSV/Qianji"
        )
        XCTAssertEqual(
            model.entries.filter {
                $0.sourceFingerprint == persistedFingerprint
            }.count,
            1
        )
        await fixture.store.close()
    }

    @MainActor
    func testCorrectedExternalImportIDCannotCreateASecondEntry() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let salary = LedgerAccount(name: "Salary", kind: .income)
        let model = fixture.model(accounts: [fixture.wallet, fixture.food, salary])
        let csv = """
        ID,Date,Type,Amount,Payee,Note
        Exact-Bank-42,2026-08-20,Expense,12,Cafe,Original
        Exact-Bank-42,2026-08-21,Expense,13,Cafe,Corrected
        """
        let preview = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(preview.rows.count, 2)
        XCTAssertEqual(preview.rows[0].id, preview.rows[1].id)

        let first = try await model.importTransactions(
            [preview.rows[0]],
            fallbackAccountID: fixture.wallet.id,
            fallbackExpenseCategoryID: fixture.food.id,
            fallbackIncomeCategoryID: salary.id,
            sourceSystem: "Bank Feed"
        )
        let corrected = try await model.importTransactions(
            [preview.rows[1]],
            fallbackAccountID: fixture.wallet.id,
            fallbackExpenseCategoryID: fixture.food.id,
            fallbackIncomeCategoryID: salary.id,
            sourceSystem: "Bank Feed"
        )

        XCTAssertEqual(first.imported, 1)
        XCTAssertEqual(corrected.imported, 0)
        XCTAssertEqual(corrected.duplicates, 1)
        XCTAssertEqual(model.entries.filter { $0.sourceSystem == "Bank Feed" }.count, 1)
        await fixture.store.close()
    }

    @MainActor
    func testImportFingerprintNamespaceCanonicalizesSourceButSeparatesSources() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let salary = LedgerAccount(name: "Salary", kind: .income)
        let model = fixture.model(accounts: [fixture.wallet, fixture.food, salary])
        let row = ImportedTransaction(
            id: "sha256:external:v1:shared-vendor-id",
            hasExternalID: true,
            sourceLine: 2,
            kind: .expense,
            occurredAt: Date(timeIntervalSinceReferenceDate: 600_000),
            amount: 8,
            payee: "Cafe"
        )

        let first = try await model.importTransactions(
            [row],
            fallbackAccountID: fixture.wallet.id,
            fallbackExpenseCategoryID: fixture.food.id,
            fallbackIncomeCategoryID: salary.id,
            sourceSystem: "Bank   Feed"
        )
        let canonicalDuplicate = try await model.importTransactions(
            [row],
            fallbackAccountID: fixture.wallet.id,
            fallbackExpenseCategoryID: fixture.food.id,
            fallbackIncomeCategoryID: salary.id,
            sourceSystem: " bank feed "
        )
        let otherSource = try await model.importTransactions(
            [row],
            fallbackAccountID: fixture.wallet.id,
            fallbackExpenseCategoryID: fixture.food.id,
            fallbackIncomeCategoryID: salary.id,
            sourceSystem: "Card Feed"
        )

        XCTAssertEqual(first.imported, 1)
        XCTAssertEqual(canonicalDuplicate.duplicates, 1)
        XCTAssertEqual(otherSource.imported, 1)
        let fingerprints = Set(model.entries.compactMap(\.sourceFingerprint))
        XCTAssertEqual(fingerprints, Set([
            TransactionCSVImporter.persistenceFingerprint(
                for: row.id,
                sourceSystem: "Bank Feed"
            ),
            TransactionCSVImporter.persistenceFingerprint(
                for: row.id,
                sourceSystem: "Card Feed"
            )
        ]))
        await fixture.store.close()
    }

    @MainActor
    func testLegacyImportFingerprintMatchesOnlyWithinCanonicalSource() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let salary = LedgerAccount(name: "Salary", kind: .income)
        let base = try TransactionFactory.expense(
            amount: try Money(9, currency: fixture.sgd),
            paidFrom: fixture.wallet.id,
            category: fixture.food.id,
            occurredAt: Date(timeIntervalSinceReferenceDate: 610_000),
            payee: "Legacy cafe"
        )
        let legacyFingerprint = "fnv1a64:legacy-fixture"
        let legacy = try JournalEntry(
            kind: base.kind,
            occurredAt: base.occurredAt,
            createdAt: base.createdAt,
            payee: base.payee,
            note: base.note,
            postings: base.postings,
            sourceSystem: "Bank Feed",
            sourceFingerprint: legacyFingerprint,
            originContext: base.originContext
        )
        let profile = UserProfile(baseCurrency: fixture.sgd)
        let accounts = [fixture.wallet, fixture.food, salary]
        try await fixture.seed(profile: profile, accounts: accounts, entries: [legacy])
        let model = fixture.model(profile: profile, accounts: accounts, entries: [legacy])
        let row = ImportedTransaction(
            id: "sha256:external:v1:new-identity",
            hasExternalID: true,
            legacyFingerprintCandidates: [legacyFingerprint],
            sourceLine: 2,
            kind: .expense,
            occurredAt: base.occurredAt,
            amount: 9,
            payee: "Legacy cafe"
        )

        let sameSource = try await model.importTransactions(
            [row],
            fallbackAccountID: fixture.wallet.id,
            fallbackExpenseCategoryID: fixture.food.id,
            fallbackIncomeCategoryID: salary.id,
            sourceSystem: " bank   feed "
        )
        let collidingLegacyHash = ImportedTransaction(
            id: "sha256:external:v1:distinct-new-identity",
            hasExternalID: true,
            legacyFingerprintCandidates: [legacyFingerprint],
            sourceLine: 3,
            kind: .expense,
            occurredAt: base.occurredAt.addingTimeInterval(86_400),
            amount: 10,
            payee: "Different transaction"
        )
        let safeCollision = try await model.importTransactions(
            [collidingLegacyHash],
            fallbackAccountID: fixture.wallet.id,
            fallbackExpenseCategoryID: fixture.food.id,
            fallbackIncomeCategoryID: salary.id,
            sourceSystem: "Bank Feed"
        )
        let otherSource = try await model.importTransactions(
            [row],
            fallbackAccountID: fixture.wallet.id,
            fallbackExpenseCategoryID: fixture.food.id,
            fallbackIncomeCategoryID: salary.id,
            sourceSystem: "Other Feed"
        )

        XCTAssertEqual(sameSource.duplicates, 1)
        XCTAssertEqual(safeCollision.imported, 1)
        XCTAssertEqual(otherSource.imported, 1)
        XCTAssertEqual(model.entries.count, 3)
        await fixture.store.close()
    }

    @MainActor
    func testSemanticTransferDedupeIncludesDestinationAccount() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let salary = LedgerAccount(name: "Salary", kind: .income)
        let savings = LedgerAccount(
            name: "Savings",
            kind: .asset,
            currency: fixture.sgd
        )
        let reserve = LedgerAccount(
            name: "Reserve",
            kind: .asset,
            currency: fixture.sgd
        )
        let accounts = [fixture.wallet, savings, reserve, fixture.food, salary]
        let model = fixture.model(accounts: accounts)
        let occurredAt = Date(timeIntervalSinceReferenceDate: 620_000)
        func row(id: String, destination: String) -> ImportedTransaction {
            ImportedTransaction(
                id: id,
                sourceLine: 2,
                kind: .transfer,
                occurredAt: occurredAt,
                amount: 10,
                accountName: fixture.wallet.name,
                destinationAccountName: destination,
                payee: "Internal move"
            )
        }

        let first = try await model.importTransactions(
            [row(id: "semantic-transfer-a", destination: savings.name)],
            fallbackAccountID: fixture.wallet.id,
            fallbackExpenseCategoryID: fixture.food.id,
            fallbackIncomeCategoryID: salary.id
        )
        let distinctDestination = try await model.importTransactions(
            [row(id: "semantic-transfer-b", destination: reserve.name)],
            fallbackAccountID: fixture.wallet.id,
            fallbackExpenseCategoryID: fixture.food.id,
            fallbackIncomeCategoryID: salary.id
        )
        let duplicate = try await model.importTransactions(
            [row(id: "semantic-transfer-c", destination: reserve.name)],
            fallbackAccountID: fixture.wallet.id,
            fallbackExpenseCategoryID: fixture.food.id,
            fallbackIncomeCategoryID: salary.id
        )

        XCTAssertEqual(first.imported, 1)
        XCTAssertEqual(distinctDestination.imported, 1)
        XCTAssertEqual(duplicate.duplicates, 1)
        XCTAssertEqual(model.entries.filter { $0.kind == .transfer }.count, 2)
        await fixture.store.close()
    }

    @MainActor
    func testSemanticFXTransferDedupeIncludesReceivedAmountAndCurrency() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let salary = LedgerAccount(name: "Salary", kind: .income)
        let accounts = [fixture.wallet, fixture.usAccount, fixture.food, salary]
        let model = fixture.model(accounts: accounts)
        let occurredAt = Date(timeIntervalSinceReferenceDate: 630_000)
        func row(id: String, destinationAmount: Decimal) -> ImportedTransaction {
            ImportedTransaction(
                id: id,
                sourceLine: 2,
                kind: .transfer,
                occurredAt: occurredAt,
                amount: 100,
                destinationAmount: destinationAmount,
                accountName: fixture.wallet.name,
                destinationAccountName: fixture.usAccount.name,
                payee: "International move"
            )
        }

        let distinctReceipts = try await model.importTransactions(
            [
                row(id: "semantic-fx-a", destinationAmount: 75),
                row(id: "semantic-fx-b", destinationAmount: 76)
            ],
            fallbackAccountID: fixture.wallet.id,
            fallbackExpenseCategoryID: fixture.food.id,
            fallbackIncomeCategoryID: salary.id
        )
        let duplicate = try await model.importTransactions(
            [row(id: "semantic-fx-c", destinationAmount: 76)],
            fallbackAccountID: fixture.wallet.id,
            fallbackExpenseCategoryID: fixture.food.id,
            fallbackIncomeCategoryID: salary.id
        )

        XCTAssertEqual(distinctReceipts.imported, 2)
        XCTAssertEqual(duplicate.duplicates, 1)
        XCTAssertEqual(
            model.accounts.filter { $0.systemRole == .foreignExchange }.count,
            2
        )
        let receipts = model.entries.flatMap(\.postings).filter {
            $0.accountID == fixture.usAccount.id && $0.money.amount > .zero
        }.map { $0.money.amount }.sorted()
        XCTAssertEqual(receipts, [75, 76])
        await fixture.store.close()
    }

    @MainActor
    func testSkippedImportRowCannotLeakItsProposedCategoryIntoLaterCommit() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let salary = LedgerAccount(name: "Salary", kind: .income)
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await fixture.seed(
            profile: profile,
            accounts: [fixture.wallet, fixture.food, salary]
        )
        let model = fixture.model(
            profile: profile,
            accounts: [fixture.wallet, fixture.food, salary]
        )
        let occurredAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-26T12:00:00Z")
        )
        let wrongDay = try TransactionOriginContext(
            calendarIdentifier: "gregorian",
            timeZoneIdentifier: "UTC",
            utcOffsetSeconds: 0,
            dayKey: 20260827
        )
        let rejected = ImportedTransaction(
            id: "rejected-with-new-category",
            sourceLine: 2,
            kind: .expense,
            occurredAt: occurredAt,
            originContext: wrongDay,
            amount: 2,
            categoryName: "Must not be created"
        )
        let accepted = ImportedTransaction(
            id: "accepted-fallback",
            sourceLine: 3,
            kind: .expense,
            occurredAt: occurredAt,
            amount: 3
        )

        let result = try await model.importTransactions(
            [rejected, accepted],
            fallbackAccountID: fixture.wallet.id,
            fallbackExpenseCategoryID: fixture.food.id,
            fallbackIncomeCategoryID: salary.id
        )

        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.categoriesCreated, 0)
        XCTAssertFalse(model.accounts.contains { $0.name == "Must not be created" })
        let persistedAccountCount = try await fixture.store.count(in: .accounts)
        XCTAssertEqual(persistedAccountCount, 3)
        await fixture.store.close()
    }

    @MainActor
    func testImportNeverPostsToArchivedCategoryWithMatchingName() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let salary = LedgerAccount(name: "Salary", kind: .income)
        let archived = LedgerAccount(
            name: "Legacy dining",
            kind: .expense,
            isArchived: true
        )
        let accounts = [
            fixture.wallet,
            fixture.food,
            salary,
            archived
        ]
        let model = fixture.model(accounts: accounts)
        let row = ImportedTransaction(
            id: "archived-category-name",
            sourceLine: 2,
            kind: .expense,
            occurredAt: Date(timeIntervalSinceReferenceDate: 1_000),
            amount: 12,
            categoryName: archived.name
        )

        let result = try await model.importTransactions(
            [row],
            fallbackAccountID: fixture.wallet.id,
            fallbackExpenseCategoryID: fixture.food.id,
            fallbackIncomeCategoryID: salary.id
        )

        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(result.categoriesCreated, 1)
        let activeReplacement = try XCTUnwrap(model.accounts.first {
            $0.kind == .expense
                && !$0.isArchived
                && $0.name == archived.name
        })
        XCTAssertNotEqual(activeReplacement.id, archived.id)
        XCTAssertTrue(
            model.entries.first?.postings.contains {
                $0.accountID == activeReplacement.id && $0.money.amount == 12
            } == true
        )
        XCTAssertFalse(
            model.entries.first?.postings.contains {
                $0.accountID == archived.id
            } == true
        )
        await fixture.store.close()
    }

    @MainActor
    func testLegacyHoldingMigrationUsesExplicitCashInterpretation() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let brokerage = LedgerAccount(
            name: "Brokerage",
            kind: .asset,
            currency: fixture.sgd,
            accountType: .brokerage
        )
        let equity = LedgerAccount(
            name: "Opening balances",
            kind: .equity,
            systemRole: .openingBalances
        )
        let opening = try TransactionFactory.balanceAdjustment(
            displayBalanceDelta: try Money(1_000, currency: fixture.sgd),
            accountID: brokerage.id,
            equityAccountID: equity.id,
            accountIsLiability: false
        )
        let legacy = try InvestmentHolding(
            accountID: brokerage.id,
            symbol: "MU",
            name: "Micron",
            quantity: 2,
            price: try Money(100, currency: fixture.sgd),
            priceAsOf: Date()
        )
        let model = fixture.model(
            accounts: [brokerage, equity, fixture.food],
            entries: [opening],
            investmentHoldings: [legacy]
        )

        try await model.connectLegacyInvestmentHolding(
            id: legacy.id,
            fundingAccountID: brokerage.id,
            deductFromCash: true
        )

        let migrated = try XCTUnwrap(model.investmentHoldings.first)
        XCTAssertNotNil(migrated.positionAccountID)
        XCTAssertEqual(migrated.lots.first?.remainingQuantity, 2)
        XCTAssertEqual(model.displayBalanceResult(for: brokerage).value?.amount, 800)
        XCTAssertEqual(
            model.netWorthByCurrencyResult().value?.first?.amount,
            1_000
        )
        await fixture.store.close()
    }

    @MainActor
    func testEveryPositionLinkedJournalEventRejectsGenericDeletion() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let brokerage = LedgerAccount(
            name: "Brokerage cash",
            kind: .asset,
            currency: fixture.sgd,
            accountType: .brokerage
        )
        let reportingZone = TimeZone(secondsFromGMT: 0)!
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            reportingTimeZoneIdentifier: reportingZone.identifier
        )
        let model = fixture.model(profile: profile, accounts: [brokerage, fixture.food])
        let start = Date().addingTimeInterval(-600)
        let holding = try InvestmentHolding(
            accountID: brokerage.id,
            symbol: "MU",
            name: "Micron",
            quantity: 2,
            price: try Money(100, currency: fixture.sgd),
            priceAsOf: start
        )

        try await model.addInvestmentHolding(
            holding,
            treatment: .cashAlreadyExcludesPosition
        )
        let opening = try XCTUnwrap(model.entries.first)
        try await model.recordInvestmentPurchase(
            holdingID: holding.id,
            quantity: 1,
            unitPrice: 110,
            occurredAt: start.addingTimeInterval(60)
        )
        let purchase = try XCTUnwrap(model.entries.first)
        try await model.repriceInvestmentHolding(
            id: holding.id,
            unitPrice: 120,
            asOf: start.addingTimeInterval(120)
        )
        let repricing = try XCTUnwrap(model.entries.first)
        _ = try await model.recordInvestmentSale(
            holdingID: holding.id,
            quantity: 1,
            unitPrice: 125,
            occurredAt: start.addingTimeInterval(180)
        )
        let sale = try XCTUnwrap(model.entries.first)
        let linkedEvents = [opening, purchase, repricing, sale]
        let beforeHolding = try XCTUnwrap(model.investmentHoldings.first)

        for entry in linkedEvents {
            XCTAssertTrue(model.isProtectedJournalEntry(entry))
            XCTAssertEqual(entry.originContext.timeZoneIdentifier, reportingZone.identifier)
            do {
                try await model.deleteEntry(id: entry.id)
                XCTFail("Expected position-linked deletion protection")
            } catch AppModelError.investmentEntryMutationForbidden {
                // Expected for opening, purchase, valuation, and sale alike.
            }
            let retainedEntry = try await fixture.store.fetch(
                JournalEntry.self,
                id: entry.id.uuidString,
                from: .journalEntries
            )
            XCTAssertNotNil(retainedEntry)
        }
        XCTAssertEqual(model.investmentHoldings.first, beforeHolding)
        let linkedEntryCount = try await fixture.store.count(in: .journalEntries)
        XCTAssertEqual(linkedEntryCount, 4)
        await fixture.store.close()
    }

    @MainActor
    func testLegacyNonzeroHoldingBlocksSnapshotCapture() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let legacy = try InvestmentHolding(
            accountID: fixture.wallet.id,
            symbol: "MU",
            name: "Micron",
            quantity: 1,
            price: try Money(100, currency: fixture.sgd),
            priceAsOf: Date()
        )
        let model = fixture.model(investmentHoldings: [legacy])

        do {
            try await model.captureNetWorthSnapshot()
            XCTFail("Expected legacy holding snapshot protection")
        } catch AppModelError.legacyInvestmentSnapshotForbidden {
            // A ledger-incomplete value must not be frozen as history.
        }
        XCTAssertTrue(model.netWorthSnapshots.isEmpty)
        let snapshotCount = try await fixture.store.count(in: .netWorthSnapshots)
        XCTAssertEqual(snapshotCount, 0)
        await fixture.store.close()
    }

    @MainActor
    func testSnapshotEstimateIsCompleteDatedAndFrozenWithRateEvidence() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let sgdEquity = LedgerAccount(name: "SGD equity", kind: .equity)
        let usdEquity = LedgerAccount(name: "USD equity", kind: .equity)
        let snapshotDate = Date(timeIntervalSince1970: 1_788_000_000)
        let entries = [
            try TransactionFactory.balanceAdjustment(
                displayBalanceDelta: try Money(100, currency: fixture.sgd),
                accountID: fixture.wallet.id,
                equityAccountID: sgdEquity.id,
                accountIsLiability: false
            ),
            try TransactionFactory.balanceAdjustment(
                displayBalanceDelta: try Money(100, currency: fixture.usd),
                accountID: fixture.usAccount.id,
                equityAccountID: usdEquity.id,
                accountIsLiability: false
            )
        ]
        let model = fixture.model(
            profile: UserProfile(
                baseCurrency: fixture.sgd,
                reportingTimeZoneIdentifier: "GMT"
            ),
            accounts: [fixture.wallet, fixture.usAccount, fixture.food, sgdEquity, usdEquity],
            entries: entries
        )

        try await model.captureNetWorthSnapshot(at: snapshotDate)
        XCTAssertNil(model.netWorthSnapshots.first?.estimatedBaseTotal)
        XCTAssertTrue(model.netWorthSnapshots.first?.conversionEvidence.isEmpty == true)

        try await model.saveExchangeRate(
            baseCurrency: fixture.sgd,
            quoteCurrency: fixture.usd,
            rate: 2,
            effectiveAt: snapshotDate.addingTimeInterval(-86_400),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        try await model.captureNetWorthSnapshot(at: snapshotDate)
        let frozen = try XCTUnwrap(model.netWorthSnapshots.first)
        XCTAssertEqual(frozen.estimatedBaseTotal?.amount, 150)
        XCTAssertEqual(frozen.conversionEvidence.count, 1)
        XCTAssertEqual(frozen.conversionEvidence.first?.source.amount, 100)
        XCTAssertEqual(frozen.conversionEvidence.first?.appliedRate, Decimal(string: "0.5"))
        XCTAssertTrue(frozen.conversionEvidence.first?.usedInverseRate == true)

        try await model.saveExchangeRate(
            baseCurrency: fixture.sgd,
            quoteCurrency: fixture.usd,
            rate: 4,
            effectiveAt: snapshotDate,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(frozen.estimatedBaseTotal?.amount, 150)
        XCTAssertEqual(model.netWorthSnapshots.dropFirst().first?.estimatedBaseTotal, nil)
        await fixture.store.close()
    }

    @MainActor
    func testHistoricalConversionUsesFixedReportingZoneAfterTravel() throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let zone = try XCTUnwrap(TimeZone(identifier: "Etc/GMT+12"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let older = try DatedExchangeRate(
            baseCurrency: fixture.sgd,
            quoteCurrency: fixture.usd,
            rate: 2,
            effectiveAt: ISO8601DateFormatter().date(from: "2026-08-26T18:00:00Z")!,
            calendar: calendar,
            timeZone: zone
        )
        let future = try DatedExchangeRate(
            baseCurrency: fixture.sgd,
            quoteCurrency: fixture.usd,
            rate: 3,
            effectiveAt: ISO8601DateFormatter().date(from: "2026-08-27T18:00:00Z")!,
            calendar: calendar,
            timeZone: zone
        )
        let model = fixture.model(
            profile: UserProfile(
                baseCurrency: fixture.sgd,
                reportingTimeZoneIdentifier: zone.identifier
            ),
            exchangeRates: [older, future]
        )
        let occurredAt = ISO8601DateFormatter().date(from: "2026-08-27T05:00:00Z")!

        let result = try model.historicalConversion(
            amount: 10,
            from: fixture.sgd,
            to: fixture.usd,
            occurredAt: occurredAt
        )

        XCTAssertEqual(result?.converted.amount, 20)
        XCTAssertEqual(result?.rateID, older.id)
    }

    @MainActor
    func testSnapshotBarrierDefersLockAndRejectsConcurrentRateMutation() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let gate = AsyncGate()
        let model = fixture.model(
            lifecycleHooks: hooks(pausing: .beforeNetWorthSnapshotCommit, at: gate)
        )
        let snapshotTask = Task { @MainActor in
            try await model.captureNetWorthSnapshot()
        }

        await gate.waitUntilReached()
        do {
            try await model.saveExchangeRate(
                baseCurrency: fixture.sgd,
                quoteCurrency: fixture.usd,
                rate: 2,
                effectiveAt: Date()
            )
            XCTFail("Expected the coherent snapshot barrier")
        } catch AppModelError.transactionInProgress {
            // Snapshot owns the shared mutation barrier until its durable write.
        }
        model.lock()
        XCTAssertEqual(model.state, .ready)
        await gate.release()
        try await snapshotTask.value
        await model.waitForPendingStoreClose()
        XCTAssertEqual(model.state, .locked)

        let reopened = try fixture.reopenStore()
        let persistedSnapshotCount = try await reopened.count(in: .netWorthSnapshots)
        let persistedRateCount = try await reopened.count(in: .exchangeRates)
        XCTAssertEqual(persistedSnapshotCount, 1)
        XCTAssertEqual(persistedRateCount, 0)
        await reopened.close()
    }

    @MainActor
    func testNetWorthOverflowReturnsUnavailableAndCannotBeSnapshotted() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let huge = try XCTUnwrap(
            Decimal(string: "9e127", locale: Locale(identifier: "en_US_POSIX"))
        )
        let secondAsset = LedgerAccount(name: "Second", kind: .asset, currency: fixture.sgd)
        let firstEquity = LedgerAccount(name: "First equity", kind: .equity)
        let secondEquity = LedgerAccount(name: "Second equity", kind: .equity)
        let entries = [
            try TransactionFactory.balanceAdjustment(
                displayBalanceDelta: try Money(huge, currency: fixture.sgd),
                accountID: fixture.wallet.id,
                equityAccountID: firstEquity.id,
                accountIsLiability: false
            ),
            try TransactionFactory.balanceAdjustment(
                displayBalanceDelta: try Money(huge, currency: fixture.sgd),
                accountID: secondAsset.id,
                equityAccountID: secondEquity.id,
                accountIsLiability: false
            )
        ]
        let model = fixture.model(
            accounts: [fixture.wallet, secondAsset, fixture.food, firstEquity, secondEquity],
            entries: entries
        )

        guard case .unavailable(.amountCalculationFailed) = model.netWorthByCurrencyResult() else {
            return XCTFail("Expected checked net-worth overflow handling")
        }
        do {
            try await model.captureNetWorthSnapshot()
            XCTFail("Expected unavailable derived state to block capture")
        } catch AppModelError.invalidBook {
            // No partial/NaN snapshot is written.
        }
        let persistedSnapshotCount = try await fixture.store.count(in: .netWorthSnapshots)
        XCTAssertEqual(persistedSnapshotCount, 0)
        await fixture.store.close()
    }

    @MainActor
    func testAdjustmentCannotBeDeletedAndCompensatingCorrectionIsExact() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let equity = LedgerAccount(
            name: "Opening balances",
            kind: .equity,
            systemRole: .openingBalances
        )
        let opening = try TransactionFactory.balanceAdjustment(
            displayBalanceDelta: try Money(100, currency: fixture.sgd),
            accountID: fixture.wallet.id,
            equityAccountID: equity.id,
            accountIsLiability: false
        )
        try await fixture.store.upsert(
            opening,
            id: opening.id.uuidString,
            in: .journalEntries
        )
        let model = fixture.model(
            accounts: [fixture.wallet, fixture.food, equity],
            entries: [opening]
        )

        do {
            try await model.deleteEntry(id: opening.id)
            XCTFail("Expected reconciliation deletion protection")
        } catch AppModelError.investmentEntryMutationForbidden {
            // Adjustments are corrected by a compensating event.
        }
        try await model.setAccountBalance(
            accountID: fixture.wallet.id,
            displayBalance: 50
        )
        XCTAssertEqual(
            model.displayBalanceResult(for: fixture.wallet).value?.amount,
            50
        )
        let retainedOpening = try await fixture.store.fetch(
            JournalEntry.self,
            id: opening.id.uuidString,
            from: .journalEntries
        )
        XCTAssertNotNil(retainedOpening)
        XCTAssertEqual(model.entries.filter { $0.kind == .adjustment }.count, 2)
        await fixture.store.close()
    }

    @MainActor
    func testEstimatedNetWorthAllowsExactAggregateAboveSingleWriteMaximum() throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let secondSGD = LedgerAccount(name: "Second SGD", kind: .asset, currency: fixture.sgd)
        let myr = try CurrencyCode("MYR")
        let foreign = LedgerAccount(name: "MYR", kind: .asset, currency: myr)
        let equities = (0..<3).map {
            LedgerAccount(name: "Equity \($0)", kind: .equity)
        }
        let maximum = MonetaryInputPolicy.maximumAbsoluteNewWrite
        let entries = [
            try TransactionFactory.balanceAdjustment(
                displayBalanceDelta: try Money(maximum, currency: fixture.sgd),
                accountID: fixture.wallet.id,
                equityAccountID: equities[0].id,
                accountIsLiability: false
            ),
            try TransactionFactory.balanceAdjustment(
                displayBalanceDelta: try Money(maximum, currency: fixture.sgd),
                accountID: secondSGD.id,
                equityAccountID: equities[1].id,
                accountIsLiability: false
            ),
            try TransactionFactory.balanceAdjustment(
                displayBalanceDelta: try Money(1, currency: myr),
                accountID: foreign.id,
                equityAccountID: equities[2].id,
                accountIsLiability: false
            )
        ]
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        let rate = try DatedExchangeRate(
            baseCurrency: fixture.sgd,
            quoteCurrency: myr,
            rate: 1,
            effectiveAt: date,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let model = fixture.model(
            accounts: [fixture.wallet, secondSGD, foreign, fixture.food] + equities,
            entries: entries,
            exchangeRates: [rate]
        )

        let optionalEstimate = try XCTUnwrap(
            model.estimatedNetWorthResult(at: date).value
        )
        let estimate = try XCTUnwrap(optionalEstimate)
        XCTAssertEqual(estimate.total.amount, maximum * 2 + 1)
    }

    @MainActor
    func testInvestmentBookValidationRejectsSharedPositionAndLedgerMismatch() throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let brokerage = LedgerAccount(
            name: "Brokerage",
            kind: .asset,
            currency: fixture.sgd,
            accountType: .brokerage
        )
        let position = LedgerAccount(
            name: "Position",
            kind: .asset,
            currency: fixture.sgd,
            systemRole: .investmentPosition
        )
        let equity = LedgerAccount(name: "Equity", kind: .equity)
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        let firstEntryID = UUID()
        var first = try InvestmentHolding(
            accountID: brokerage.id,
            symbol: "ONE",
            name: "One",
            quantity: 0,
            positionAccountID: position.id
        )
        try first.recordPurchase(
            quantity: 1,
            unitCost: try Money(100, currency: fixture.sgd),
            occurredAt: date,
            entryID: firstEntryID
        )
        try first.recordPrice(
            try Money(100, currency: fixture.sgd),
            asOf: date,
            entryID: firstEntryID
        )
        let mismatchedEntry = try TransactionFactory.investmentOpening(
            positionValue: try Money(90, currency: fixture.sgd),
            positionAccountID: position.id,
            equityAccountID: equity.id,
            occurredAt: date,
            id: firstEntryID
        )
        let mismatchModel = fixture.model(
            accounts: [brokerage, position, equity, fixture.food],
            entries: [mismatchedEntry],
            investmentHoldings: [first]
        )
        XCTAssertThrowsError(try mismatchModel.validateLoadedBook()) { error in
            XCTAssertTrue(error is AppModelError)
        }

        let secondEntryID = UUID()
        var second = try InvestmentHolding(
            accountID: brokerage.id,
            symbol: "TWO",
            name: "Two",
            quantity: 0,
            positionAccountID: position.id
        )
        try second.recordPurchase(
            quantity: 1,
            unitCost: try Money(100, currency: fixture.sgd),
            occurredAt: date,
            entryID: secondEntryID
        )
        try second.recordPrice(
            try Money(100, currency: fixture.sgd),
            asOf: date,
            entryID: secondEntryID
        )
        let firstEntry = try TransactionFactory.investmentOpening(
            positionValue: try Money(100, currency: fixture.sgd),
            positionAccountID: position.id,
            equityAccountID: equity.id,
            occurredAt: date,
            id: firstEntryID
        )
        let secondEntry = try TransactionFactory.investmentOpening(
            positionValue: try Money(100, currency: fixture.sgd),
            positionAccountID: position.id,
            equityAccountID: equity.id,
            occurredAt: date,
            id: secondEntryID
        )
        let sharedModel = fixture.model(
            accounts: [brokerage, position, equity, fixture.food],
            entries: [firstEntry, secondEntry],
            investmentHoldings: [first, second]
        )
        XCTAssertThrowsError(try sharedModel.validateLoadedBook()) { error in
            XCTAssertTrue(error is AppModelError)
        }
    }

    @MainActor
    func testInvestmentCreationRejectsGenericAssetFundingAccount() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()
        let holding = try InvestmentHolding(
            accountID: fixture.wallet.id,
            symbol: "MU",
            name: "Micron",
            quantity: 1,
            price: try Money(100, currency: fixture.sgd),
            priceAsOf: Date()
        )

        do {
            try await model.addInvestmentHolding(
                holding,
                treatment: .deductFromCash
            )
            XCTFail("Expected a dedicated investment funding account")
        } catch AppModelError.missingRecord {
            // Generic cash accounts cannot silently become brokerage funding.
        }
        let storedCount = try await fixture.store.count(in: .investmentHoldings)
        XCTAssertEqual(storedCount, 0)
        await fixture.store.close()
    }

    @MainActor
    func testStalePriceBoundaryUsesProfileReportingCalendar() throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            reportingTimeZoneIdentifier: "America/Los_Angeles"
        )
        let model = fixture.model(profile: profile)
        let now = ISO8601DateFormatter().date(from: "2026-11-08T09:30:00Z")!
        let boundary = try XCTUnwrap(
            model.reportingCalendar.date(byAdding: .day, value: -7, to: now)
        )
        let holding = try InvestmentHolding(
            accountID: fixture.wallet.id,
            symbol: "MU",
            name: "Micron",
            quantity: 1,
            price: try Money(100, currency: fixture.sgd),
            priceAsOf: boundary
        )

        XCTAssertFalse(holding.isPriceStale(
            relativeTo: now,
            calendar: model.reportingCalendar
        ))
        var deviceCalendar = Calendar(identifier: .gregorian)
        deviceCalendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        XCTAssertNotEqual(model.reportingCalendar.timeZone, deviceCalendar.timeZone)
        XCTAssertTrue(try InvestmentHolding(
            accountID: fixture.wallet.id,
            symbol: "MU",
            name: "Micron",
            quantity: 1,
            price: try Money(100, currency: fixture.sgd),
            priceAsOf: boundary.addingTimeInterval(-1)
        ).isPriceStale(relativeTo: now, calendar: model.reportingCalendar))
    }

    @MainActor
    func testInvalidCategoryMetadataDoesNotPartiallyRenameOrWriteAudit() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let profile = UserProfile(baseCurrency: fixture.sgd)
        let budget = BudgetNode(
            id: fixture.food.id,
            name: fixture.food.name,
            limit: try Money(100, currency: fixture.sgd),
            purpose: .flexible
        )
        let sourceAccounts = [fixture.wallet, fixture.usAccount, fixture.food]
        try await fixture.seed(
            profile: profile,
            accounts: sourceAccounts,
            budgetNodes: [budget]
        )
        let model = fixture.model(
            profile: profile,
            accounts: sourceAccounts,
            budgetNodes: [budget]
        )

        do {
            try await model.updateCategoryMetadata(
                categoryID: fixture.food.id,
                name: "Renamed before failure",
                amount: -1,
                purpose: .flexible,
                rolloverRule: .positiveOnly
            )
            XCTFail("Expected invalid budget metadata to reject the whole save")
        } catch AppModelError.negativeAmount {
            // Account, budget, and audit share one validation/write boundary.
        }

        XCTAssertEqual(
            model.accounts.first { $0.id == fixture.food.id }?.name,
            fixture.food.name
        )
        XCTAssertEqual(model.budgetNodes.first?.limit?.amount, 100)
        let storedAccount = try await fixture.store.fetch(
            LedgerAccount.self,
            id: fixture.food.id.uuidString,
            from: .accounts
        )
        let storedBudget = try await fixture.store.fetch(
            BudgetNode.self,
            id: fixture.food.id.uuidString,
            from: .budgetNodes
        )
        XCTAssertEqual(storedAccount?.name, fixture.food.name)
        XCTAssertEqual(storedBudget, budget)
        let auditCount = try await fixture.store.count(
            in: .accountLifecycleAudit
        )
        XCTAssertEqual(auditCount, 0)
        await fixture.store.close()
    }

    @MainActor
    func testCategoryMetadataCommitsAccountBudgetAndAuditTogether() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            reportingTimeZoneIdentifier: "Asia/Singapore"
        )
        let budget = BudgetNode(id: fixture.food.id, name: fixture.food.name)
        let sourceAccounts = [fixture.wallet, fixture.usAccount, fixture.food]
        try await fixture.seed(
            profile: profile,
            accounts: sourceAccounts,
            budgetNodes: [budget]
        )
        let model = fixture.model(
            profile: profile,
            accounts: sourceAccounts,
            budgetNodes: [budget]
        )

        try await model.updateCategoryMetadata(
            categoryID: fixture.food.id,
            name: "Dining",
            amount: Decimal(string: "250.50")!,
            purpose: .flexible,
            rolloverRule: .positiveOnly
        )

        let storedAccount = try await fixture.store.fetch(
            LedgerAccount.self,
            id: fixture.food.id.uuidString,
            from: .accounts
        )
        let storedBudget = try await fixture.store.fetch(
            BudgetNode.self,
            id: fixture.food.id.uuidString,
            from: .budgetNodes
        )
        let audits = try await fixture.store.fetchAll(
            LedgerAccountLifecycleAudit.self,
            from: .accountLifecycleAudit
        )
        XCTAssertEqual(storedAccount?.name, "Dining")
        XCTAssertEqual(storedBudget?.name, "Dining")
        XCTAssertEqual(storedBudget?.limit?.amount, Decimal(string: "250.50"))
        XCTAssertEqual(storedBudget?.purpose, .flexible)
        XCTAssertEqual(storedBudget?.rolloverRule, .positiveOnly)
        XCTAssertNotNil(storedBudget?.rolloverStartedAt)
        XCTAssertEqual(audits.count, 1)
        XCTAssertEqual(audits.first?.action, .categoryMetadataUpdated)
        XCTAssertEqual(audits.first?.before.name, fixture.food.name)
        XCTAssertEqual(audits.first?.after?.name, "Dining")
        XCTAssertEqual(audits.first?.afterBudget, storedBudget)
        await fixture.store.close()
    }

    @MainActor
    func testSavingsGoalLifecyclePersistsMovementsResetAndArchive() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model()
        let goal = try SavingsGoal(
            name: "Emergency fund",
            kind: .savingsGoal,
            target: try Money(1_000, currency: fixture.sgd),
            targetDate: Date().addingTimeInterval(365 * 24 * 60 * 60)
        )

        try await model.addSavingsGoal(goal)
        try await model.addSavingsGoalMovement(
            goalID: goal.id,
            kind: .contribution,
            amount: Decimal(string: "123.45")!
        )
        XCTAssertEqual(
            model.savingsGoalSummary(
                try XCTUnwrap(model.savingsGoals.first)
            ).value?.balance.amount,
            Decimal(string: "123.45")
        )

        try await model.resetSavingsGoal(id: goal.id)
        XCTAssertEqual(
            model.savingsGoalSummary(
                try XCTUnwrap(model.savingsGoals.first)
            ).value?.balance.amount,
            0
        )
        XCTAssertEqual(model.savingsGoals.first?.movements.count, 1)
        XCTAssertEqual(model.savingsGoals.first?.resets.count, 1)

        try await model.setSavingsGoalArchived(id: goal.id, isArchived: true)
        let persisted = try await fixture.store.fetch(
            SavingsGoal.self,
            id: goal.id.uuidString,
            from: .savingsGoals
        )
        XCTAssertTrue(try XCTUnwrap(persisted).isArchived)
        XCTAssertEqual(persisted?.movements.first?.money.amount, Decimal(string: "123.45"))
        await fixture.store.close()
    }

    @MainActor
    func testBudgetWidgetPublishesOnlyRoundedPercentageAfterExplicitOptIn() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let suiteName = "MoneyUpWidgetTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let snapshotStore = BudgetWidgetSnapshotStore(defaults: defaults)
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let entry = try fixture.expense(amount: Decimal(string: "25.49")!)
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            showsBudgetStatusWidget: true,
            reportingTimeZoneIdentifier: "Asia/Singapore"
        )
        let budget = BudgetNode(
            id: fixture.food.id,
            name: fixture.food.name,
            limit: try Money(100, currency: fixture.sgd),
            purpose: .flexible
        )

        _ = fixture.model(
            profile: profile,
            entries: [entry],
            budgetNodes: [budget],
            budgetWidgetSnapshotStore: snapshotStore,
            currentDate: { now }
        )

        XCTAssertEqual(budgetWidgetPercent(snapshotStore.read(now: now)), 25)
        let persistedDomain = defaults.persistentDomain(forName: suiteName) ?? [:]
        let persistedKeys = Set(persistedDomain.keys)
        XCTAssertTrue(persistedKeys.isSubset(of: BudgetWidgetSnapshotStore.allowedPersistedKeys))
        XCTAssertFalse(persistedKeys.contains { key in
            ["amount", "payee", "account", "balance"].contains {
                key.localizedCaseInsensitiveContains($0)
            }
        })
        await fixture.store.close()
    }

    func testBudgetWidgetMigrationIsDisabledAndDeletesSensitivePrototypeKeys() throws {
        let suiteName = "MoneyUpWidgetMigrationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("123.45", forKey: "budgetStatus.amount")
        defaults.set("Cafe", forKey: "widget.payee")
        defaults.set(true, forKey: "budgetStatus.enabled")

        let store = BudgetWidgetSnapshotStore(defaults: defaults)

        XCTAssertEqual(store.read(), .disabled)
        XCTAssertNil(defaults.object(forKey: "budgetStatus.amount"))
        XCTAssertNil(defaults.object(forKey: "widget.payee"))
        XCTAssertEqual(
            defaults.integer(forKey: "budgetStatus.schemaVersion"),
            BudgetWidgetSnapshotStore.currentSchemaVersion
        )
    }

    @MainActor
    func testBudgetWidgetSnapshotSurvivesNormalLock() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let suiteName = "MoneyUpWidgetLockTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let snapshotStore = BudgetWidgetSnapshotStore(defaults: defaults)
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            showsBudgetStatusWidget: true,
            reportingTimeZoneIdentifier: "Asia/Singapore"
        )
        let budget = BudgetNode(
            id: fixture.food.id,
            name: fixture.food.name,
            limit: try Money(100, currency: fixture.sgd),
            purpose: .flexible
        )
        let model = fixture.model(
            profile: profile,
            entries: [try fixture.expense(amount: 25)],
            budgetNodes: [budget],
            budgetWidgetSnapshotStore: snapshotStore,
            currentDate: { now }
        )
        XCTAssertEqual(budgetWidgetPercent(snapshotStore.read(now: now)), 25)

        model.lock()
        await model.waitForPendingStoreClose()

        XCTAssertEqual(model.state, .locked)
        XCTAssertEqual(budgetWidgetPercent(snapshotStore.read(now: now)), 25)
    }

    @MainActor
    func testEraseScrubsBudgetWidgetPercentage() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let suiteName = "MoneyUpWidgetEraseTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let snapshotStore = BudgetWidgetSnapshotStore(defaults: defaults)
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            showsBudgetStatusWidget: true,
            reportingTimeZoneIdentifier: "Asia/Singapore"
        )
        let budget = BudgetNode(
            id: fixture.food.id,
            name: fixture.food.name,
            limit: try Money(100, currency: fixture.sgd),
            purpose: .flexible
        )
        let model = fixture.model(
            profile: profile,
            entries: [try fixture.expense(amount: 25)],
            budgetNodes: [budget],
            budgetWidgetSnapshotStore: snapshotStore,
            currentDate: { now }
        )
        XCTAssertEqual(budgetWidgetPercent(snapshotStore.read(now: now)), 25)

        await model.eraseAllDataAndRestart()

        XCTAssertEqual(model.state, .onboarding)
        XCTAssertEqual(snapshotStore.read(), .disabled)
        XCTAssertNil(defaults.object(forKey: "budgetStatus.percentUsed"))
    }

    @MainActor
    func testNoBookStartupScrubsStaleBudgetWidgetPercentage() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let suiteName = "MoneyUpWidgetNoBookTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let snapshotStore = BudgetWidgetSnapshotStore(defaults: defaults)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        snapshotStore.publish(
            enabled: true,
            percentUsed: 73,
            periodToken: "2026-05",
            validUntil: now.addingTimeInterval(3_600)
        )
        XCTAssertEqual(budgetWidgetPercent(snapshotStore.read(now: now)), 73)

        let model = AppModel(
            store: fixture.store,
            profile: nil,
            accounts: [],
            budgetWidgetSnapshotStore: snapshotStore
        )

        XCTAssertEqual(model.state, .onboarding)
        XCTAssertEqual(snapshotStore.read(), .disabled)
        XCTAssertNil(defaults.object(forKey: "budgetStatus.percentUsed"))
        await fixture.store.close()
    }
}

private func storedRecord<Value: Encodable>(
    _ value: Value,
    id: String,
    in collection: RecordCollection,
    updatedAt: TimeInterval = 1_000
) throws -> StoredRecordSnapshot {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return StoredRecordSnapshot(
        collection: collection.rawValue,
        recordID: id,
        payload: try encoder.encode(value),
        updatedAt: updatedAt
    )
}

extension AppModelTests {
    @MainActor
    func testRecoveringStartupPersistsOneCurrentMonthBudgetCheckpoint()
        async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let calendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: "GMT"
        )
        func date(_ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(
                year: 2026,
                month: month,
                day: day,
                hour: 12
            ))!
        }
        func expense(amount: Decimal, month: Int) throws -> JournalEntry {
            let candidate = try TransactionFactory.expense(
                amount: try Money(amount, currency: fixture.sgd),
                paidFrom: fixture.wallet.id,
                category: fixture.food.id,
                occurredAt: date(month, 15),
                payee: "Checkpoint fixture"
            )
            return try JournalEntry(
                id: candidate.id,
                kind: candidate.kind,
                occurredAt: candidate.occurredAt,
                createdAt: candidate.createdAt,
                payee: candidate.payee,
                note: candidate.note,
                postings: candidate.postings,
                originContext: .capture(
                    for: candidate.occurredAt,
                    timeZone: calendar.timeZone
                )
            )
        }

        let january = try XCTUnwrap(
            calendar.dateInterval(of: .month, for: date(1, 1))?.start
        )
        let march = try XCTUnwrap(
            calendar.dateInterval(of: .month, for: date(3, 1))?.start
        )
        let budget = BudgetNode(
            id: fixture.food.id,
            name: fixture.food.name,
            limit: try Money(100, currency: fixture.sgd),
            rolloverRule: .positiveOnly,
            rolloverStartedAt: january
        )
        let timeline = try BudgetConfigurationTimeline(
            currency: fixture.sgd,
            revisions: [BudgetConfigurationRevision(
                effectiveMonth: january,
                nodes: [budget]
            )]
        )
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            reportingTimeZoneIdentifier: "GMT"
        )
        try await fixture.seed(
            profile: profile,
            accounts: [fixture.wallet, fixture.usAccount, fixture.food],
            entries: [
                try expense(amount: 40, month: 1),
                try expense(amount: 20, month: 2)
            ],
            budgetNodes: [budget],
            budgetConfigurationTimeline: timeline
        )
        let checkpointCurrentDate = date(3, 15)
        let model = fixture.model(
            profile: profile,
            budgetNodes: [budget],
            retainsCompleteJournal: false,
            budgetConfigurationTimeline: timeline,
            currentDate: { checkpointCurrentDate }
        )

        try await model.reloadPersistedBookForTesting()
        let firstCheckpoint = try await fixture.store.fetch(
            BudgetConfigurationTimeline.self,
            id: BudgetConfigurationTimeline.primaryRecordID,
            from: .budgetConfigurationTimelines
        )
        XCTAssertEqual(firstCheckpoint?.revisions.count, 2)
        XCTAssertEqual(
            firstCheckpoint?.revision(effectiveAt: march)
                .openingCarryByID?[fixture.food.id]?.amount,
            140
        )
        XCTAssertEqual(model.budgetJournalReplayReadCount, 0)

        try await model.reloadPersistedBookForTesting()
        let secondCheckpoint = try await fixture.store.fetch(
            BudgetConfigurationTimeline.self,
            id: BudgetConfigurationTimeline.primaryRecordID,
            from: .budgetConfigurationTimelines
        )
        XCTAssertEqual(secondCheckpoint?.revisions.count, 2)
        XCTAssertEqual(
            secondCheckpoint?.revision(effectiveAt: march)
                .openingCarryByID?[fixture.food.id]?.amount,
            140
        )
        XCTAssertEqual(model.budgetJournalReplayReadCount, 0)
        await fixture.store.close()
    }

    @MainActor
    func testLazyBudgetRolloverUsesCompleteClosedMonthProjectionAndRefreshesWidget() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let clock = MutableTestDate(
            FinancialPeriodBoundary.gregorianCalendar(
                timeZoneIdentifier: "GMT"
            ).date(from: DateComponents(
                year: 2026,
                month: 3,
                day: 15,
                hour: 12
            ))!
        )
        let calendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: "GMT"
        )
        func date(_ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(
                year: 2026,
                month: month,
                day: day,
                hour: 12
            ))!
        }
        func expense(amount: Decimal, occurredAt: Date) throws -> JournalEntry {
            let candidate = try TransactionFactory.expense(
                amount: try Money(amount, currency: fixture.sgd),
                paidFrom: fixture.wallet.id,
                category: fixture.food.id,
                occurredAt: occurredAt,
                payee: "Projection"
            )
            return try JournalEntry(
                id: candidate.id,
                kind: candidate.kind,
                occurredAt: candidate.occurredAt,
                createdAt: candidate.createdAt,
                payee: candidate.payee,
                note: candidate.note,
                postings: candidate.postings,
                originContext: .capture(
                    for: occurredAt,
                    timeZone: calendar.timeZone
                )
            )
        }

        let january = try XCTUnwrap(
            calendar.dateInterval(of: .month, for: date(1, 1))?.start
        )
        let budget = BudgetNode(
            id: fixture.food.id,
            name: fixture.food.name,
            limit: try Money(100, currency: fixture.sgd),
            purpose: .flexible,
            rolloverRule: .positiveOnly,
            rolloverStartedAt: january
        )
        let timeline = try BudgetConfigurationTimeline(
            currency: fixture.sgd,
            revisions: [BudgetConfigurationRevision(
                effectiveMonth: january,
                nodes: [budget]
            )]
        )
        let oldClosedMonthEntry = try expense(
            amount: 40,
            occurredAt: date(1, 15)
        )
        let newerCurrentMonthEntries = try (0..<100).map { offset in
            try expense(
                amount: 1,
                occurredAt: date(3, 1).addingTimeInterval(TimeInterval(offset))
            )
        }
        let allEntries = [oldClosedMonthEntry] + newerCurrentMonthEntries
        let recent = Array(
            allEntries.sorted { $0.occurredAt > $1.occurredAt }.prefix(80)
        )
        XCTAssertFalse(recent.contains { $0.id == oldClosedMonthEntry.id })
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            showsBudgetStatusWidget: true,
            reportingTimeZoneIdentifier: "GMT"
        )
        try await fixture.seed(
            profile: profile,
            accounts: [fixture.wallet, fixture.usAccount, fixture.food],
            entries: allEntries,
            budgetNodes: [budget],
            budgetConfigurationTimeline: timeline
        )
        let suiteName = "MoneyUpCompleteBudgetProjection-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let widgetStore = BudgetWidgetSnapshotStore(defaults: defaults)
        let model = fixture.model(
            profile: profile,
            entries: recent,
            budgetNodes: [budget],
            retainsCompleteJournal: false,
            budgetWidgetSnapshotStore: widgetStore,
            budgetConfigurationTimeline: timeline,
            currentDate: { clock.value() }
        )

        _ = model.reportResult(for: .thisMonth)
        await model.waitForPendingJournalDerivedRefresh()

        XCTAssertEqual(model.entries.count, 80)
        XCTAssertEqual(model.journalEntryCount, 101)
        guard case let .available(progress) = model.budgetProgressThisMonthResult()
        else { return XCTFail("Expected a complete March rollover projection") }
        XCTAssertEqual(progress.first?.effectiveLimit?.amount, 260)
        XCTAssertEqual(progress.first?.spent.amount, 100)
        XCTAssertEqual(
            budgetWidgetPercent(widgetStore.read(now: clock.value())),
            38
        )

        clock.set(date(4, 15))
        guard case .unavailable = model.budgetProgressThisMonthResult() else {
            return XCTFail("A prior-month projection must fail closed")
        }
        await model.waitForPendingJournalDerivedRefresh()
        guard case let .available(aprilProgress) = model.budgetProgressThisMonthResult()
        else { return XCTFail("Expected the April projection to refresh") }
        XCTAssertEqual(aprilProgress.first?.effectiveLimit?.amount, 260)
        await fixture.store.close()
    }

    @MainActor
    func testLazyLedgerQuarantinesWholeCurrencyMismatchEntry() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let mismatched = try JournalEntry(
            kind: .expense,
            occurredAt: Date(),
            postings: [
                Posting(
                    accountID: fixture.wallet.id,
                    money: try Money(-12, currency: fixture.usd)
                ),
                Posting(
                    accountID: fixture.food.id,
                    money: try Money(12, currency: fixture.usd)
                )
            ]
        )
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await fixture.seed(
            profile: profile,
            accounts: [fixture.wallet, fixture.usAccount, fixture.food],
            entries: [mismatched]
        )
        let model = fixture.model(
            profile: profile,
            entries: [mismatched],
            retainsCompleteJournal: false
        )

        _ = model.reportResult(for: .thisMonth)
        await model.waitForPendingJournalDerivedRefresh()

        XCTAssertEqual(model.journalEntryCount, 0)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertEqual(
            model.displayBalanceResult(for: fixture.wallet).value?.amount,
            0
        )
        XCTAssertTrue(model.recoveryIssues.contains {
            $0.contains(mismatched.id.uuidString.lowercased())
                || $0.contains(mismatched.id.uuidString)
        })
        await fixture.store.close()
    }

    @MainActor
    func testExplicitCheckpointRecomputationExcludesQuarantinedWholeEntry() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let calendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: "GMT"
        )
        func date(_ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(
                year: 2026,
                month: month,
                day: day,
                hour: 12
            ))!
        }
        let january = try XCTUnwrap(
            calendar.dateInterval(of: .month, for: date(1, 1))?.start
        )
        let march = try XCTUnwrap(
            calendar.dateInterval(of: .month, for: date(3, 1))?.start
        )
        let budget = BudgetNode(
            id: fixture.food.id,
            name: fixture.food.name,
            limit: try Money(100, currency: fixture.sgd),
            rolloverRule: .positiveOnly,
            rolloverStartedAt: january
        )
        let timeline = try BudgetConfigurationTimeline(
            currency: fixture.sgd,
            revisions: [
                BudgetConfigurationRevision(
                    effectiveMonth: january,
                    nodes: [budget]
                ),
                BudgetConfigurationRevision(
                    effectiveMonth: march,
                    nodes: [budget],
                    openingCarry: [
                        fixture.food.id: try Money(0, currency: fixture.sgd)
                    ]
                )
            ]
        )
        let valid = try TransactionFactory.expense(
            amount: try Money(10, currency: fixture.sgd),
            paidFrom: fixture.wallet.id,
            category: fixture.food.id,
            occurredAt: date(1, 15),
            payee: "Valid"
        )
        let orphan = try JournalEntry(
            kind: .expense,
            occurredAt: date(1, 16),
            postings: [
                Posting(
                    accountID: UUID(),
                    money: try Money(-90, currency: fixture.sgd)
                ),
                Posting(
                    accountID: fixture.food.id,
                    money: try Money(90, currency: fixture.sgd)
                )
            ]
        )
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            reportingTimeZoneIdentifier: "GMT"
        )
        let aprilNow = date(4, 15)
        try await fixture.seed(
            profile: profile,
            accounts: [fixture.wallet, fixture.usAccount, fixture.food],
            entries: [valid, orphan],
            budgetNodes: [budget],
            budgetConfigurationTimeline: timeline
        )
        let model = fixture.model(
            profile: profile,
            entries: [valid, orphan],
            budgetNodes: [budget],
            retainsCompleteJournal: false,
            budgetConfigurationTimeline: timeline,
            currentDate: { aprilNow }
        )
        _ = model.reportResult(for: .thisMonth)
        await model.waitForPendingJournalDerivedRefresh()

        try await model.replaceEntry(
            id: valid.id,
            kind: .expense,
            amount: 20,
            destinationAmount: nil,
            accountID: fixture.wallet.id,
            destinationAccountID: nil,
            categoryID: fixture.food.id,
            occurredAt: valid.occurredAt,
            payee: "Corrected valid",
            note: nil
        )

        let stored = try await fixture.store.fetch(
            BudgetConfigurationTimeline.self,
            id: BudgetConfigurationTimeline.primaryRecordID,
            from: .budgetConfigurationTimelines
        )
        XCTAssertEqual(
            stored?.revision(effectiveAt: march)
                .openingCarryByID?[fixture.food.id]?.amount,
            180
        )
        await fixture.store.close()
    }

    @MainActor
    func testLazyCurrentMonthQuickLogAndSchedulePostSkipFullJournalReplay() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let calendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: "GMT"
        )
        func date(_ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(
                year: 2026,
                month: month,
                day: day,
                hour: 12
            ))!
        }
        let january = try XCTUnwrap(
            calendar.dateInterval(of: .month, for: date(1, 1))?.start
        )
        let march = try XCTUnwrap(
            calendar.dateInterval(of: .month, for: date(3, 1))?.start
        )
        let budget = BudgetNode(
            id: fixture.food.id,
            name: fixture.food.name,
            limit: try Money(100, currency: fixture.sgd),
            rolloverRule: .positiveOnly,
            rolloverStartedAt: january
        )
        let timeline = try BudgetConfigurationTimeline(
            currency: fixture.sgd,
            revisions: [
                BudgetConfigurationRevision(
                    effectiveMonth: january,
                    nodes: [budget]
                ),
                BudgetConfigurationRevision(
                    effectiveMonth: march,
                    nodes: [budget],
                    openingCarry: [
                        fixture.food.id: try Money(0, currency: fixture.sgd)
                    ]
                )
            ]
        )
        let schedule = try ScheduledTransaction(
            kind: .expense,
            name: "April scheduled expense",
            amount: try Money(12, currency: fixture.sgd),
            accountID: fixture.wallet.id,
            categoryAccountID: fixture.food.id,
            nextOccurrence: date(4, 12),
            frequency: .monthly,
            recurrenceTimeZoneIdentifier: "GMT"
        )
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            reportingTimeZoneIdentifier: "GMT"
        )
        try await fixture.seed(
            profile: profile,
            accounts: [fixture.wallet, fixture.usAccount, fixture.food],
            budgetNodes: [budget],
            budgetConfigurationTimeline: timeline,
            schedules: [schedule]
        )
        let malformedID = UUID()
        let snapshot = try await fixture.store.snapshot()
        try await fixture.store.restore(DatabaseSnapshot(
            schemaVersion: snapshot.schemaVersion,
            createdAt: snapshot.createdAt,
            records: snapshot.records + [StoredRecordSnapshot(
                collection: RecordCollection.journalEntries.rawValue,
                recordID: malformedID.uuidString,
                payload: Data("{not-json".utf8),
                updatedAt: 1
            )]
        ))
        let aprilNow = date(4, 15)
        let model = fixture.model(
            profile: profile,
            budgetNodes: [budget],
            scheduledTransactions: [schedule],
            retainsCompleteJournal: false,
            budgetConfigurationTimeline: timeline,
            currentDate: { aprilNow }
        )

        let quickLogID = try await model.logExpense(
            amount: 8,
            accountID: fixture.wallet.id,
            categoryID: fixture.food.id,
            occurredAt: date(4, 10),
            payee: "April quick log",
            note: nil
        )
        XCTAssertNotNil(quickLogID)
        XCTAssertEqual(model.budgetJournalReplayReadCount, 0)

        let scheduledID = try await model.postScheduledOccurrence(
            scheduleID: schedule.id,
            occurrenceID: schedule.currentOccurrenceID,
            occurredAt: date(4, 12),
            resolvedAt: date(4, 12),
            calendar: calendar
        )
        XCTAssertNotNil(scheduledID)
        XCTAssertEqual(model.budgetJournalReplayReadCount, 0)

        let recovered = try await fixture.store.fetchAllRecovering(
            JournalEntry.self,
            from: .journalEntries
        )
        XCTAssertEqual(
            Set(recovered.values.map(\.id)),
            Set([quickLogID, scheduledID].compactMap { $0 })
        )
        XCTAssertEqual(recovered.issues.map(\.recordID), [malformedID.uuidString])
        await fixture.store.close()
    }

    @MainActor
    func testLazyCheckpointReplayRecoversPastMalformedJournalRow() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let calendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: "GMT"
        )
        func date(_ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(
                year: 2026,
                month: month,
                day: day,
                hour: 12
            ))!
        }
        let january = try XCTUnwrap(
            calendar.dateInterval(of: .month, for: date(1, 1))?.start
        )
        let march = try XCTUnwrap(
            calendar.dateInterval(of: .month, for: date(3, 1))?.start
        )
        let budget = BudgetNode(
            id: fixture.food.id,
            name: fixture.food.name,
            limit: try Money(100, currency: fixture.sgd),
            rolloverRule: .positiveOnly,
            rolloverStartedAt: january
        )
        let timeline = try BudgetConfigurationTimeline(
            currency: fixture.sgd,
            revisions: [
                BudgetConfigurationRevision(
                    effectiveMonth: january,
                    nodes: [budget]
                ),
                BudgetConfigurationRevision(
                    effectiveMonth: march,
                    nodes: [budget],
                    openingCarry: [
                        fixture.food.id: try Money(0, currency: fixture.sgd)
                    ]
                )
            ]
        )
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            reportingTimeZoneIdentifier: "GMT"
        )
        try await fixture.seed(
            profile: profile,
            accounts: [fixture.wallet, fixture.usAccount, fixture.food],
            budgetNodes: [budget],
            budgetConfigurationTimeline: timeline
        )
        let malformedID = UUID()
        let snapshot = try await fixture.store.snapshot()
        try await fixture.store.restore(DatabaseSnapshot(
            schemaVersion: snapshot.schemaVersion,
            createdAt: snapshot.createdAt,
            records: snapshot.records + [StoredRecordSnapshot(
                collection: RecordCollection.journalEntries.rawValue,
                recordID: malformedID.uuidString,
                payload: Data("{not-json".utf8),
                updatedAt: 1
            )]
        ))
        let aprilNow = date(4, 15)
        let model = fixture.model(
            profile: profile,
            budgetNodes: [budget],
            retainsCompleteJournal: false,
            budgetConfigurationTimeline: timeline,
            currentDate: { aprilNow }
        )

        let entryID = try await model.logExpense(
            amount: 10,
            accountID: fixture.wallet.id,
            categoryID: fixture.food.id,
            occurredAt: date(1, 15),
            payee: "Backdated valid expense",
            note: nil
        )

        XCTAssertNotNil(entryID)
        XCTAssertEqual(model.budgetJournalReplayReadCount, 1)
        XCTAssertTrue(model.recoveryIssues.contains {
            $0.contains(malformedID.uuidString)
        })
        let storedTimeline = try await fixture.store.fetch(
            BudgetConfigurationTimeline.self,
            id: BudgetConfigurationTimeline.primaryRecordID,
            from: .budgetConfigurationTimelines
        )
        XCTAssertEqual(
            storedTimeline?.revision(effectiveAt: march)
                .openingCarryByID?[fixture.food.id]?.amount,
            190
        )
        await fixture.store.close()
    }

    @MainActor
    func testDraftUpdateDuringPausedSaveCannotResurrectDraftAfterReopen() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let gate = AsyncGate()
        let initial = QuickLogDraft(
            kind: .expense,
            amountText: "12",
            destinationAmountText: "",
            accountID: fixture.wallet.id,
            destinationAccountID: nil,
            categoryID: fixture.food.id,
            occurredAt: Date(),
            dateWasEdited: false,
            payee: "Initial",
            note: "",
            smartText: ""
        )
        var late = initial
        late.payee = "Late resurrection"
        let model = fixture.model(
            lifecycleHooks: hooks(pausing: .beforeJournalCommit, at: gate)
        )
        model.updateQuickLogDraft(initial)
        let save = Task { @MainActor in
            try await model.logExpense(
                amount: 12,
                accountID: fixture.wallet.id,
                categoryID: fixture.food.id,
                occurredAt: initial.occurredAt,
                payee: initial.payee,
                note: nil
            )
        }
        await gate.waitUntilReached()

        model.updateQuickLogDraft(late)
        await gate.release()
        _ = try await save.value
        XCTAssertNil(model.quickLogDraft)
        await fixture.store.close()

        let reopened = try fixture.reopenStore()
        let draftCount = try await reopened.count(in: .quickLogDrafts)
        let entryCount = try await reopened.count(in: .journalEntries)
        XCTAssertEqual(draftCount, 0)
        XCTAssertEqual(entryCount, 1)
        await reopened.close()
    }

    @MainActor
    func testRestoreDrainsPausedDraftDebounceBeforeApplyingSnapshot() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let profile = UserProfile(baseCurrency: fixture.sgd)
        let restored = QuickLogDraft(
            kind: .expense,
            amountText: "10",
            destinationAmountText: "",
            accountID: fixture.wallet.id,
            destinationAccountID: nil,
            categoryID: fixture.food.id,
            occurredAt: Date(),
            dateWasEdited: false,
            payee: "Restored draft",
            note: "",
            smartText: ""
        )
        try await fixture.seed(
            profile: profile,
            accounts: [fixture.wallet, fixture.usAccount, fixture.food],
            quickLogDraft: restored
        )
        let archive = try PortableArchive.seal(
            try await fixture.store.snapshot(),
            password: "draft restore pass"
        )
        let gate = AsyncGate()
        let model = fixture.model(
            profile: profile,
            quickLogDraft: restored,
            lifecycleHooks: hooks(pausing: .beforeQuickLogDraftWrite, at: gate)
        )
        var stale = restored
        stale.payee = "Pre-restore stale draft"
        model.updateQuickLogDraft(stale)
        await gate.waitUntilReached()

        let restore = Task { @MainActor in
            try await model.restoreEncryptedBackup(
                archive,
                password: "draft restore pass"
            )
        }
        for _ in 0..<10 { await Task.yield() }
        await gate.release()
        try await restore.value

        let persisted = try await fixture.store.fetch(
            QuickLogDraft.self,
            id: QuickLogDraft.primaryRecordID,
            from: .quickLogDrafts
        )
        XCTAssertEqual(model.quickLogDraft?.payee, "Restored draft")
        XCTAssertEqual(persisted?.payee, "Restored draft")
        await fixture.store.close()
    }

    @MainActor
    func testPausedProfileWriteBlocksRestoreAndDefersLock() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let profile = UserProfile(baseCurrency: fixture.sgd)
        try await fixture.seed(
            profile: profile,
            accounts: [fixture.wallet, fixture.usAccount, fixture.food]
        )
        let archive = try PortableArchive.seal(
            try await fixture.store.snapshot(),
            password: "profile race pass"
        )
        let gate = AsyncGate()
        let model = fixture.model(
            profile: profile,
            lifecycleHooks: hooks(pausing: .beforeProfileWrite, at: gate)
        )
        let update = Task { @MainActor in
            try await model.updateAutoLockDelay(300)
        }
        await gate.waitUntilReached()

        do {
            try await model.restoreEncryptedBackup(
                archive,
                password: "profile race pass"
            )
            XCTFail("Restore must not interleave a profile primary-row write")
        } catch AppModelError.transactionInProgress {
            // Expected while the coordinated profile mutation is paused.
        }
        model.lock()
        XCTAssertEqual(model.state, .ready)
        await gate.release()
        try await update.value
        await model.waitForPendingStoreClose()
        XCTAssertEqual(model.state, .locked)

        let reopened = try fixture.reopenStore()
        let persisted = try await reopened.fetch(
            UserProfile.self,
            id: UserProfile.primaryRecordID,
            from: .profile
        )
        XCTAssertEqual(persisted?.autoLockDelay, 300)
        await reopened.close()
    }

    @MainActor
    func testAugustBudgetEditPersistsProspectiveTimelineAndKeepsClosedCarry() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            reportingTimeZoneIdentifier: "Asia/Singapore"
        )
        let calendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: profile.reportingTimeZoneIdentifier
        )
        func date(_ month: Int, _ day: Int = 1) -> Date {
            calendar.date(from: DateComponents(
                year: 2026,
                month: month,
                day: day,
                hour: 12
            ))!
        }
        let januaryStart = try XCTUnwrap(
            calendar.dateInterval(of: .month, for: date(1))?.start
        )
        let budget = BudgetNode(
            id: fixture.food.id,
            name: fixture.food.name,
            limit: try Money(100, currency: fixture.sgd),
            purpose: .flexible,
            rolloverRule: .positiveOnly,
            rolloverStartedAt: januaryStart
        )
        let timeline = try BudgetConfigurationTimeline(
            currency: fixture.sgd,
            revisions: [BudgetConfigurationRevision(
                effectiveMonth: januaryStart,
                nodes: [budget]
            )]
        )
        let entries = try (1...7).map { month in
            try TransactionFactory.expense(
                amount: Money(10, currency: fixture.sgd),
                paidFrom: fixture.wallet.id,
                category: fixture.food.id,
                occurredAt: date(month, 15),
                payee: "Month \(month)"
            )
        }
        let augustNow = date(8, 15)
        let model = fixture.model(
            profile: profile,
            entries: entries,
            budgetNodes: [budget],
            budgetConfigurationTimeline: timeline,
            currentDate: { augustNow }
        )

        try await model.setBudgetLimit(
            categoryID: fixture.food.id,
            amount: 200,
            purpose: .flexible
        )

        guard case let .available(progress) = model.budgetProgressThisMonthResult()
        else { return XCTFail("Expected exact rollover progress") }
        XCTAssertEqual(progress.first?.effectiveLimit?.amount, 830)
        let stored = try await fixture.store.fetch(
            BudgetConfigurationTimeline.self,
            id: BudgetConfigurationTimeline.primaryRecordID,
            from: .budgetConfigurationTimelines
        )
        XCTAssertEqual(stored?.revisions.count, 2)
        XCTAssertEqual(
            try stored?.tree(effectiveAt: januaryStart).nodes.first?.limit?.amount,
            100
        )
        let augustStart = try XCTUnwrap(
            calendar.dateInterval(of: .month, for: augustNow)?.start
        )
        XCTAssertEqual(
            try stored?.tree(effectiveAt: augustStart).nodes.first?.limit?.amount,
            200
        )
        await fixture.store.close()
    }

    @MainActor
    func testHistoricalEditInvalidatesCheckpointByAttributedCivilMonthNotInstant() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            reportingTimeZoneIdentifier: "Pacific/Kiritimati"
        )
        let reportingCalendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: profile.reportingTimeZoneIdentifier
        )
        let utcCalendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: "GMT"
        )
        let january = try XCTUnwrap(reportingCalendar.date(from: DateComponents(
            year: 2026,
            month: 1,
            day: 1
        )))
        let february = try XCTUnwrap(reportingCalendar.date(from: DateComponents(
            year: 2026,
            month: 2,
            day: 1
        )))
        let now = try XCTUnwrap(reportingCalendar.date(from: DateComponents(
            year: 2026,
            month: 2,
            day: 15,
            hour: 12
        )))
        // This instant is February 1 in the reporting zone, but the persisted
        // authoring context attributes it to January 31 in UTC-12.
        let occurrenceInstant = try XCTUnwrap(utcCalendar.date(from: DateComponents(
            year: 2026,
            month: 2,
            day: 1,
            hour: 1
        )))
        let budget = BudgetNode(
            id: fixture.food.id,
            name: fixture.food.name,
            limit: try Money(100, currency: fixture.sgd),
            rolloverRule: .positiveOnly,
            rolloverStartedAt: january
        )
        let timeline = try BudgetConfigurationTimeline(
            currency: fixture.sgd,
            revisions: [
                BudgetConfigurationRevision(
                    effectiveMonth: january,
                    nodes: [budget]
                ),
                BudgetConfigurationRevision(
                    effectiveMonth: february,
                    nodes: [budget],
                    openingCarry: [
                        fixture.food.id: try Money(90, currency: fixture.sgd)
                    ]
                )
            ]
        )
        let candidateEntry = try TransactionFactory.expense(
            amount: try Money(10, currency: fixture.sgd),
            paidFrom: fixture.wallet.id,
            category: fixture.food.id,
            occurredAt: occurrenceInstant,
            payee: "Boundary expense"
        )
        let entry = try JournalEntry(
            id: candidateEntry.id,
            kind: candidateEntry.kind,
            occurredAt: candidateEntry.occurredAt,
            createdAt: candidateEntry.createdAt,
            payee: candidateEntry.payee,
            note: candidateEntry.note,
            postings: candidateEntry.postings,
            originContext: .capture(
                for: occurrenceInstant,
                timeZone: try XCTUnwrap(TimeZone(identifier: "Etc/GMT+12"))
            )
        )
        let attribution = try BudgetEntryAttribution(
            entry: entry,
            originTimeZoneIdentifier: "Etc/GMT+12"
        )
        XCTAssertEqual(attribution.originDayKey, "2026-01-31")
        try await fixture.seed(
            profile: profile,
            accounts: [fixture.wallet, fixture.usAccount, fixture.food],
            entries: [entry],
            budgetNodes: [budget],
            budgetConfigurationTimeline: timeline
        )
        try await fixture.store.upsert(
            attribution,
            id: attribution.id.uuidString,
            in: .budgetEntryAttributions
        )
        let model = fixture.model(
            profile: profile,
            entries: [entry],
            budgetNodes: [budget],
            budgetConfigurationTimeline: timeline,
            budgetEntryAttributions: [entry.id: attribution],
            currentDate: { now }
        )

        try await model.replaceEntry(
            id: entry.id,
            kind: .expense,
            amount: 20,
            destinationAmount: nil,
            accountID: fixture.wallet.id,
            destinationAccountID: nil,
            categoryID: fixture.food.id,
            occurredAt: occurrenceInstant,
            payee: "Boundary correction",
            note: nil
        )

        guard case let .available(progress) = model.budgetProgressThisMonthResult()
        else { return XCTFail("Expected recomputed February checkpoint") }
        XCTAssertEqual(progress.first?.effectiveLimit?.amount, 180)
        let stored = try await fixture.store.fetch(
            BudgetConfigurationTimeline.self,
            id: BudgetConfigurationTimeline.primaryRecordID,
            from: .budgetConfigurationTimelines
        )
        XCTAssertEqual(
            stored?.revision(effectiveAt: february)
                .openingCarryByID?[fixture.food.id]?.amount,
            80
        )
        await fixture.store.close()
    }

    @MainActor
    func testMergeThenHistoricalAmountDateAndDeleteRecomputeCheckpointExactly() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let source = LedgerAccount(name: "Old dining", kind: .expense)
        let target = fixture.food
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            reportingTimeZoneIdentifier: "Asia/Singapore"
        )
        let calendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: profile.reportingTimeZoneIdentifier
        )
        func date(_ month: Int, _ day: Int = 1) -> Date {
            calendar.date(from: DateComponents(
                year: 2026,
                month: month,
                day: day,
                hour: 12
            ))!
        }
        let january = try XCTUnwrap(
            calendar.dateInterval(of: .month, for: date(1))?.start
        )
        let augustNow = date(8, 15)
        let sourceBudget = BudgetNode(
            id: source.id,
            name: source.name,
            limit: try Money(100, currency: fixture.sgd),
            rolloverRule: .positiveOnly,
            rolloverStartedAt: january
        )
        let targetBudget = BudgetNode(
            id: target.id,
            name: target.name,
            limit: try Money(100, currency: fixture.sgd),
            rolloverRule: .fullBalance,
            rolloverStartedAt: january
        )
        let timeline = try BudgetConfigurationTimeline(
            currency: fixture.sgd,
            revisions: [BudgetConfigurationRevision(
                effectiveMonth: january,
                nodes: [sourceBudget, targetBudget]
            )]
        )
        let sourceEntry = try TransactionFactory.expense(
            amount: try Money(150, currency: fixture.sgd),
            paidFrom: fixture.wallet.id,
            category: source.id,
            occurredAt: date(1, 15),
            payee: "Source expense"
        )
        let targetEntry = try TransactionFactory.expense(
            amount: try Money(150, currency: fixture.sgd),
            paidFrom: fixture.wallet.id,
            category: target.id,
            occurredAt: date(1, 16),
            payee: "Target expense"
        )
        let accounts = [fixture.wallet, fixture.usAccount, source, target]
        try await fixture.seed(
            profile: profile,
            accounts: accounts,
            entries: [sourceEntry, targetEntry],
            budgetNodes: [sourceBudget, targetBudget],
            budgetConfigurationTimeline: timeline
        )
        let model = fixture.model(
            profile: profile,
            accounts: accounts,
            entries: [sourceEntry, targetEntry],
            budgetNodes: [sourceBudget, targetBudget],
            budgetConfigurationTimeline: timeline,
            currentDate: { augustNow }
        )
        func targetLimit() throws -> Decimal {
            guard case let .available(progress) = model.budgetProgressThisMonthResult(),
                  let value = progress.first(where: {
                      $0.node.id == target.id
                  })?.effectiveLimit?.amount else {
                throw AppModelError.invalidBook
            }
            return value
        }

        try await model.mergeLedgerItem(id: source.id, into: target.id)
        XCTAssertEqual(try targetLimit(), 1_350)

        try await model.replaceEntry(
            id: sourceEntry.id,
            kind: .expense,
            amount: 50,
            destinationAmount: nil,
            accountID: fixture.wallet.id,
            destinationAccountID: nil,
            categoryID: target.id,
            occurredAt: date(1, 15),
            payee: "Source amount correction",
            note: nil
        )
        var corrected = try XCTUnwrap(model.entries.first {
            $0.payee == "Source amount correction"
        })
        var persistedAttributions = try await fixture.store.fetchAll(
            BudgetEntryAttribution.self,
            from: .budgetEntryAttributions
        )
        XCTAssertEqual(try targetLimit(), 1_400)
        XCTAssertTrue(
            persistedAttributions.first { $0.id == corrected.id }?.postings
                .contains { $0.accountID == source.id } == true
        )

        try await model.replaceEntry(
            id: corrected.id,
            kind: .expense,
            amount: 250,
            destinationAmount: nil,
            accountID: fixture.wallet.id,
            destinationAccountID: nil,
            categoryID: target.id,
            occurredAt: date(1, 15),
            payee: "Source overspend correction",
            note: nil
        )
        corrected = try XCTUnwrap(model.entries.first {
            $0.payee == "Source overspend correction"
        })
        XCTAssertEqual(try targetLimit(), 1_350)

        try await model.replaceEntry(
            id: corrected.id,
            kind: .expense,
            amount: 250,
            destinationAmount: nil,
            accountID: fixture.wallet.id,
            destinationAccountID: nil,
            categoryID: target.id,
            occurredAt: date(2, 15),
            payee: "Source date correction",
            note: nil
        )
        corrected = try XCTUnwrap(model.entries.first {
            $0.payee == "Source date correction"
        })
        XCTAssertEqual(try targetLimit(), 1_250)

        let beforeFailureEntries = model.entries
        let beforeFailureTimeline = try await fixture.store.fetch(
            BudgetConfigurationTimeline.self,
            id: BudgetConfigurationTimeline.primaryRecordID,
            from: .budgetConfigurationTimelines
        )
        do {
            try await model.replaceEntry(
                id: corrected.id,
                kind: .expense,
                amount: 1,
                destinationAmount: nil,
                accountID: fixture.wallet.id,
                destinationAccountID: nil,
                categoryID: UUID(),
                occurredAt: date(1, 1),
                payee: "Must fail",
                note: nil
            )
            XCTFail("Expected invalid category to preserve journal/checkpoint")
        } catch AppModelError.missingRecord {
            // Validation fails before the atomic journal/checkpoint write.
        }
        XCTAssertEqual(model.entries, beforeFailureEntries)
        let timelineAfterFailure = try await fixture.store.fetch(
            BudgetConfigurationTimeline.self,
            id: BudgetConfigurationTimeline.primaryRecordID,
            from: .budgetConfigurationTimelines
        )
        XCTAssertEqual(timelineAfterFailure, beforeFailureTimeline)

        try await model.deleteEntry(id: corrected.id)
        XCTAssertEqual(try targetLimit(), 1_450)
        persistedAttributions = try await fixture.store.fetchAll(
            BudgetEntryAttribution.self,
            from: .budgetEntryAttributions
        )
        XCTAssertFalse(persistedAttributions.contains { $0.id == corrected.id })

        let fetchedTimeline = try await fixture.store.fetch(
            BudgetConfigurationTimeline.self,
            id: BudgetConfigurationTimeline.primaryRecordID,
            from: .budgetConfigurationTimelines
        )
        let persistedTimeline = try XCTUnwrap(fetchedTimeline)
        let persistedEntries = try await fixture.store.fetchAll(
            JournalEntry.self,
            from: .journalEntries
        )
        let persistedAccounts = try await fixture.store.fetchAll(
            LedgerAccount.self,
            from: .accounts
        )
        let persistedBudgets = try await fixture.store.fetchAll(
            BudgetNode.self,
            from: .budgetNodes
        )
        await fixture.store.close()
        let reopened = try fixture.reopenStore()
        let reopenedModel = fixture.model(
            store: reopened,
            profile: profile,
            accounts: persistedAccounts,
            entries: persistedEntries,
            budgetNodes: persistedBudgets,
            budgetConfigurationTimeline: persistedTimeline,
            budgetEntryAttributions: Dictionary(uniqueKeysWithValues:
                persistedAttributions.map { ($0.id, $0) }
            ),
            currentDate: { augustNow }
        )
        guard case let .available(reopenedProgress) =
            reopenedModel.budgetProgressThisMonthResult() else {
            return XCTFail("Persisted recomputed checkpoint must reopen")
        }
        XCTAssertEqual(
            reopenedProgress.first { $0.node.id == target.id }?
                .effectiveLimit?.amount,
            1_450
        )
        await reopened.close()
    }

    @MainActor
    func testExplicitBackdatedRecategoryToFutureNodeIsUnbudgetedNotFailure() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let source = LedgerAccount(name: "Old dining", kind: .expense)
        let target = fixture.food
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            reportingTimeZoneIdentifier: "Asia/Singapore"
        )
        let calendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: profile.reportingTimeZoneIdentifier
        )
        func date(_ month: Int, _ day: Int = 1) -> Date {
            calendar.date(from: DateComponents(
                year: 2026,
                month: month,
                day: day,
                hour: 12
            ))!
        }
        let january = try XCTUnwrap(
            calendar.dateInterval(of: .month, for: date(1))?.start
        )
        let budgets = [
            BudgetNode(
                id: source.id,
                name: source.name,
                limit: try Money(100, currency: fixture.sgd),
                rolloverRule: .positiveOnly,
                rolloverStartedAt: january
            ),
            BudgetNode(
                id: target.id,
                name: target.name,
                limit: try Money(100, currency: fixture.sgd),
                rolloverRule: .fullBalance,
                rolloverStartedAt: january
            )
        ]
        let timeline = try BudgetConfigurationTimeline(
            currency: fixture.sgd,
            revisions: [BudgetConfigurationRevision(
                effectiveMonth: january,
                nodes: budgets
            )]
        )
        let sourceEntry = try TransactionFactory.expense(
            amount: try Money(150, currency: fixture.sgd),
            paidFrom: fixture.wallet.id,
            category: source.id,
            occurredAt: date(1, 15),
            payee: "Source expense"
        )
        let targetEntry = try TransactionFactory.expense(
            amount: try Money(150, currency: fixture.sgd),
            paidFrom: fixture.wallet.id,
            category: target.id,
            occurredAt: date(1, 16),
            payee: "Target expense"
        )
        let augustNow = date(8, 15)
        let accounts = [fixture.wallet, fixture.usAccount, source, target]
        try await fixture.seed(
            profile: profile,
            accounts: accounts,
            entries: [sourceEntry, targetEntry],
            budgetNodes: budgets,
            budgetConfigurationTimeline: timeline
        )
        let model = fixture.model(
            profile: profile,
            accounts: accounts,
            entries: [sourceEntry, targetEntry],
            budgetNodes: budgets,
            budgetConfigurationTimeline: timeline,
            currentDate: { augustNow }
        )

        try await model.mergeLedgerItem(id: source.id, into: target.id)
        try await model.addCategory(name: "Created in August", kind: .expense)
        let futureCategory = try XCTUnwrap(model.expenseCategories.first {
            $0.name == "Created in August"
        })
        try await model.replaceEntry(
            id: sourceEntry.id,
            kind: .expense,
            amount: 150,
            destinationAmount: nil,
            accountID: fixture.wallet.id,
            destinationAccountID: nil,
            categoryID: futureCategory.id,
            occurredAt: date(1, 15),
            payee: "Explicit future recategory",
            note: nil
        )

        guard case let .available(progress) = model.budgetProgressThisMonthResult()
        else { return XCTFail("Future category must be unbudgeted, not fatal") }
        XCTAssertEqual(
            progress.first { $0.node.id == target.id }?.effectiveLimit?.amount,
            1_450
        )
        let replacement = try XCTUnwrap(model.entries.first {
            $0.payee == "Explicit future recategory"
        })
        let attribution = try await fixture.store.fetch(
            BudgetEntryAttribution.self,
            id: replacement.id.uuidString,
            from: .budgetEntryAttributions
        )
        XCTAssertTrue(
            attribution?.postings.contains {
                $0.accountID == futureCategory.id
            } == true
        )
        XCTAssertFalse(
            attribution?.postings.contains { $0.accountID == source.id } == true
        )
        await fixture.store.close()
    }

    @MainActor
    func testNonBoundaryTimelineRevisionMakesBudgetUnavailableWithoutFallback() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            reportingTimeZoneIdentifier: "Asia/Singapore"
        )
        let calendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: profile.reportingTimeZoneIdentifier
        )
        let noon = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 1,
            day: 1,
            hour: 12
        )))
        let budget = BudgetNode(
            id: fixture.food.id,
            name: fixture.food.name,
            limit: try Money(100, currency: fixture.sgd),
            rolloverRule: .positiveOnly,
            rolloverStartedAt: noon
        )
        let malformedBoundary = try BudgetConfigurationTimeline(
            currency: fixture.sgd,
            revisions: [BudgetConfigurationRevision(
                effectiveMonth: noon,
                nodes: [budget]
            )]
        )
        let model = fixture.model(
            profile: profile,
            budgetNodes: [budget],
            budgetConfigurationTimeline: malformedBoundary,
            currentDate: { noon }
        )

        guard case let .unavailable(issue) = model.budgetProgressThisMonthResult()
        else { return XCTFail("Malformed timeline must never use today's tree") }
        XCTAssertEqual(issue, .budgetCalculationFailed)
        await fixture.store.close()
    }

    @MainActor
    func testRestoringLegacyBookPersistsEarliestActivationBaseline() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            reportingTimeZoneIdentifier: "Asia/Singapore"
        )
        let calendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: profile.reportingTimeZoneIdentifier
        )
        let january = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 1,
            day: 1
        )))
        let august = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 15
        )))
        let budget = BudgetNode(
            id: fixture.food.id,
            name: fixture.food.name,
            limit: try Money(100, currency: fixture.sgd),
            rolloverRule: .positiveOnly,
            rolloverStartedAt: january
        )
        try await fixture.seed(
            profile: profile,
            accounts: [fixture.wallet, fixture.usAccount, fixture.food],
            budgetNodes: [budget]
        )
        let legacySnapshot = try await fixture.store.snapshot()
        XCTAssertFalse(legacySnapshot.records.contains {
            $0.collection == RecordCollection.budgetConfigurationTimelines.rawValue
        })
        let archive = try PortableArchive.seal(
            legacySnapshot,
            password: "correct horse battery"
        )
        let model = fixture.model(
            profile: profile,
            budgetNodes: [budget],
            currentDate: { august }
        )

        try await model.restoreEncryptedBackup(
            archive,
            password: "correct horse battery"
        )

        let migrated = try await fixture.store.fetch(
            BudgetConfigurationTimeline.self,
            id: BudgetConfigurationTimeline.primaryRecordID,
            from: .budgetConfigurationTimelines
        )
        XCTAssertEqual(migrated?.revisions.count, 1)
        XCTAssertEqual(migrated?.revisions.first?.effectiveMonth, january)
        XCTAssertEqual(migrated?.revisions.first?.nodes, [budget])
        await fixture.store.close()
    }

    @MainActor
    func testSavingsGoalArithmeticFailureIsExplicitUnavailableState() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let huge = Decimal(sign: .plus, exponent: 127, significand: 9)
        let created = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let goal = try SavingsGoal(
            name: "Overflow",
            kind: .savingsGoal,
            target: try Money(huge, currency: fixture.sgd),
            targetDate: created.addingTimeInterval(10_000),
            createdAt: created,
            movements: [
                try SavingsGoalMovement(
                    kind: .contribution,
                    money: try Money(huge, currency: fixture.sgd),
                    occurredAt: created.addingTimeInterval(1),
                    originTimeZoneIdentifier: "Asia/Singapore"
                ),
                try SavingsGoalMovement(
                    kind: .contribution,
                    money: try Money(huge, currency: fixture.sgd),
                    occurredAt: created.addingTimeInterval(2),
                    originTimeZoneIdentifier: "Asia/Singapore"
                )
            ],
            reportingTimeZoneIdentifier: "Asia/Singapore"
        )
        let model = fixture.model(savingsGoals: [goal])

        XCTAssertNil(
            model.savingsGoalSummary(
                goal,
                asOf: created.addingTimeInterval(3)
            ).value
        )
        guard case let .unavailable(issue) = model.savingsGoalSummary(
            goal,
            asOf: created.addingTimeInterval(3)
        ) else { return XCTFail("Expected explicit unavailable goal summary") }
        XCTAssertEqual(issue, .goalCalculationFailed)
        XCTAssertFalse(issue.localizedDescription.isEmpty)
        await fixture.store.close()
    }

    @MainActor
    func testConcurrentGoalContributionsSerializeWithoutLosingMovement() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let gate = AsyncGate()
        let goal = try SavingsGoal(
            name: "Emergency",
            kind: .savingsGoal,
            target: try Money(1_000, currency: fixture.sgd),
            targetDate: Date(timeIntervalSinceReferenceDate: 900_000_000),
            createdAt: Date(timeIntervalSinceReferenceDate: 700_000_000)
        )
        let model = fixture.model(
            savingsGoals: [goal],
            lifecycleHooks: hooks(pausing: .beforeSavingsGoalWrite, at: gate)
        )
        let first = Task { @MainActor in
            try await model.addSavingsGoalMovement(
                goalID: goal.id,
                kind: .contribution,
                amount: 10,
                occurredAt: Date(timeIntervalSinceReferenceDate: 800_000_000)
            )
        }
        await gate.waitUntilReached()
        let second = Task { @MainActor in
            try await model.addSavingsGoalMovement(
                goalID: goal.id,
                kind: .contribution,
                amount: 20,
                occurredAt: Date(timeIntervalSinceReferenceDate: 800_000_001)
            )
        }
        for _ in 0..<10 { await Task.yield() }
        await gate.release()

        try await first.value
        try await second.value

        let saved = try XCTUnwrap(model.savingsGoals.first { $0.id == goal.id })
        XCTAssertEqual(saved.movements.count, 2)
        XCTAssertEqual(
            model.savingsGoalSummary(
                saved,
                asOf: Date(timeIntervalSinceReferenceDate: 800_000_010)
            ).value?.balance.amount,
            30
        )
        let persisted = try await fixture.store.fetch(
            SavingsGoal.self,
            id: goal.id.uuidString,
            from: .savingsGoals
        )
        XCTAssertEqual(persisted?.movements.count, 2)
        await fixture.store.close()
    }

    @MainActor
    func testAppAuthoredGoalEventsUseProfileReportingOriginAcrossTravel() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let profile = UserProfile(
            baseCurrency: fixture.sgd,
            reportingTimeZoneIdentifier: "Pacific/Kiritimati"
        )
        let goal = try SavingsGoal(
            name: "Trip",
            kind: .sinkingFund,
            target: try Money(500, currency: fixture.sgd),
            targetDate: Date(timeIntervalSinceReferenceDate: 900_000_000),
            createdAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
            reportingTimeZoneIdentifier: profile.reportingTimeZoneIdentifier
        )
        let utc = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: "GMT"
        )
        let movementInstant = try XCTUnwrap(utc.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 31,
            hour: 10,
            minute: 30
        )))
        let resetInstant = movementInstant.addingTimeInterval(60 * 60)
        let model = fixture.model(profile: profile, savingsGoals: [goal])

        try await model.addSavingsGoalMovement(
            goalID: goal.id,
            kind: .contribution,
            amount: 25,
            occurredAt: movementInstant
        )
        try await model.resetSavingsGoal(id: goal.id, at: resetInstant)

        let saved = try XCTUnwrap(model.savingsGoals.first)
        XCTAssertEqual(
            saved.movements.first?.originTimeZoneIdentifier,
            "Pacific/Kiritimati"
        )
        XCTAssertEqual(saved.movements.first?.originDayKey, "2026-08-01")
        XCTAssertEqual(
            saved.resets.first?.originTimeZoneIdentifier,
            "Pacific/Kiritimati"
        )
        XCTAssertEqual(saved.resets.first?.originDayKey, "2026-08-01")
        await fixture.store.close()
    }

    @MainActor
    func testGoalMutationReResolvesIDAfterPrecedingSaveResortsArray() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let gate = AsyncGate()
        let firstID = UUID()
        let secondID = UUID()
        let createdAt = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let firstGoal = try SavingsGoal(
            id: firstID,
            name: "First",
            kind: .savingsGoal,
            target: try Money(1_000, currency: fixture.sgd),
            targetDate: Date(timeIntervalSinceReferenceDate: 800_000_000),
            createdAt: createdAt
        )
        let secondGoal = try SavingsGoal(
            id: secondID,
            name: "Second",
            kind: .savingsGoal,
            target: try Money(2_000, currency: fixture.sgd),
            targetDate: Date(timeIntervalSinceReferenceDate: 810_000_000),
            createdAt: createdAt
        )
        let model = fixture.model(
            savingsGoals: [firstGoal, secondGoal],
            lifecycleHooks: hooks(pausing: .beforeSavingsGoalWrite, at: gate)
        )
        let update = Task { @MainActor in
            try await model.updateSavingsGoal(
                id: firstID,
                name: "First updated",
                kind: .savingsGoal,
                targetAmount: 1_500,
                targetDate: Date(timeIntervalSinceReferenceDate: 820_000_000),
                resetRule: .never
            )
        }
        await gate.waitUntilReached()
        let contribution = Task { @MainActor in
            try await model.addSavingsGoalMovement(
                goalID: firstID,
                kind: .contribution,
                amount: 25,
                occurredAt: Date(timeIntervalSinceReferenceDate: 790_000_000)
            )
        }
        for _ in 0..<10 { await Task.yield() }
        await gate.release()

        try await update.value
        try await contribution.value

        XCTAssertEqual(
            Set(model.savingsGoals.map(\.id)),
            Set([firstID, secondID])
        )
        let updated = try XCTUnwrap(model.savingsGoals.first { $0.id == firstID })
        XCTAssertEqual(updated.name, "First updated")
        XCTAssertEqual(updated.target.amount, 1_500)
        XCTAssertEqual(updated.movements.count, 1)
        XCTAssertEqual(model.savingsGoals.first?.id, secondID)
        await fixture.store.close()
    }

    @MainActor
    func testQueuedUpdateWaitsForPausedGoalAdd() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let gate = AsyncGate()
        let goal = try SavingsGoal(
            name: "Travel",
            kind: .sinkingFund,
            target: try Money(500, currency: fixture.sgd),
            targetDate: Date(timeIntervalSinceReferenceDate: 900_000_000),
            createdAt: Date(timeIntervalSinceReferenceDate: 700_000_000)
        )
        let model = fixture.model(
            savingsGoals: [],
            lifecycleHooks: hooks(pausing: .beforeSavingsGoalWrite, at: gate)
        )
        let add = Task { @MainActor in try await model.addSavingsGoal(goal) }
        await gate.waitUntilReached()
        let update = Task { @MainActor in
            try await model.updateSavingsGoal(
                id: goal.id,
                name: "Travel updated",
                kind: .sinkingFund,
                targetAmount: 750,
                targetDate: Date(timeIntervalSinceReferenceDate: 910_000_000),
                resetRule: .yearly
            )
        }
        for _ in 0..<10 { await Task.yield() }
        await gate.release()

        try await add.value
        try await update.value

        XCTAssertEqual(model.savingsGoals.first?.name, "Travel updated")
        XCTAssertEqual(model.savingsGoals.first?.target.amount, 750)
        await fixture.store.close()
    }

    @MainActor
    func testContributionWithdrawalResetArchiveAndDeleteUseOneFIFOGoalLane() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let gate = AsyncGate()
        let goal = try SavingsGoal(
            name: "Buffer",
            kind: .savingsGoal,
            target: try Money(1_000, currency: fixture.sgd),
            targetDate: Date(timeIntervalSinceReferenceDate: 900_000_000),
            createdAt: Date(timeIntervalSinceReferenceDate: 700_000_000)
        )
        let model = fixture.model(
            savingsGoals: [goal],
            lifecycleHooks: hooks(pausing: .beforeSavingsGoalWrite, at: gate)
        )
        let contribution = Task { @MainActor in
            try await model.addSavingsGoalMovement(
                goalID: goal.id,
                kind: .contribution,
                amount: 100,
                occurredAt: Date(timeIntervalSinceReferenceDate: 780_000_000)
            )
        }
        await gate.waitUntilReached()
        let withdrawal = Task { @MainActor in
            try await model.addSavingsGoalMovement(
                goalID: goal.id,
                kind: .withdrawal,
                amount: 10,
                occurredAt: Date(timeIntervalSinceReferenceDate: 780_000_001)
            )
        }
        await Task.yield()
        let reset = Task { @MainActor in
            try await model.resetSavingsGoal(
                id: goal.id,
                at: Date(timeIntervalSinceReferenceDate: 780_000_002)
            )
        }
        await Task.yield()
        let archive = Task { @MainActor in
            try await model.setSavingsGoalArchived(id: goal.id, isArchived: true)
        }
        await Task.yield()
        let deletion = Task { @MainActor in
            try await model.deleteSavingsGoal(id: goal.id)
        }
        for _ in 0..<10 { await Task.yield() }
        await gate.release()

        try await contribution.value
        try await withdrawal.value
        try await reset.value
        try await archive.value
        try await deletion.value

        XCTAssertFalse(model.savingsGoals.contains { $0.id == goal.id })
        let persisted = try await fixture.store.fetch(
            SavingsGoal.self,
            id: goal.id.uuidString,
            from: .savingsGoals
        )
        XCTAssertNil(persisted)
        await fixture.store.close()
    }

    @MainActor
    func testRestoreWaitsForPausedGoalMutationAndClosesGoalBarrier() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let profile = UserProfile(baseCurrency: fixture.sgd)
        let goal = try SavingsGoal(
            name: "Emergency",
            kind: .savingsGoal,
            target: try Money(1_000, currency: fixture.sgd),
            targetDate: Date(timeIntervalSinceReferenceDate: 900_000_000),
            createdAt: Date(timeIntervalSinceReferenceDate: 700_000_000)
        )
        let schedule = try ScheduledTransaction(
            kind: .expense,
            name: "Restore barrier bill",
            amount: try Money(25, currency: fixture.sgd),
            accountID: fixture.wallet.id,
            categoryAccountID: fixture.food.id,
            nextOccurrence: Date(timeIntervalSinceReferenceDate: 850_000_000),
            frequency: .monthly
        )
        try await fixture.seed(
            profile: profile,
            accounts: [fixture.wallet, fixture.usAccount, fixture.food],
            schedules: [schedule],
            savingsGoals: [goal]
        )
        let restoreSnapshot = try await fixture.store.snapshot()
        let archive = try PortableArchive.seal(
            restoreSnapshot,
            password: "restore barrier pass"
        )
        let gate = AsyncGate()
        let model = fixture.model(
            profile: profile,
            scheduledTransactions: [schedule],
            savingsGoals: [goal],
            lifecycleHooks: hooks(pausing: .beforeSavingsGoalWrite, at: gate)
        )
        let contribution = Task { @MainActor in
            try await model.addSavingsGoalMovement(
                goalID: goal.id,
                kind: .contribution,
                amount: 10,
                occurredAt: Date(timeIntervalSinceReferenceDate: 800_000_000)
            )
        }
        await gate.waitUntilReached()
        let restore = Task { @MainActor in
            try await model.restoreEncryptedBackup(
                archive,
                password: "restore barrier pass"
            )
        }
        for _ in 0..<10 { await Task.yield() }

        do {
            try await model.addSavingsGoalMovement(
                goalID: goal.id,
                kind: .contribution,
                amount: 20,
                occurredAt: Date(timeIntervalSinceReferenceDate: 800_000_001)
            )
            XCTFail("Restore must close the global goal-mutation barrier")
        } catch AppModelError.transactionInProgress {
            // Expected while restore waits for the already-started write.
        }
        do {
            try await model.pauseScheduledTransaction(id: schedule.id)
            XCTFail("Restore must block schedule-only mutations while draining goals")
        } catch AppModelError.transactionInProgress {
            // Expected: restore owns the cross-feature mutation barrier.
        }
        do {
            _ = try await model.postScheduledOccurrence(
                scheduleID: schedule.id,
                occurrenceID: schedule.currentOccurrenceID
            )
            XCTFail("Restore must block journal-and-schedule mutations")
        } catch AppModelError.transactionInProgress {
            // Expected: no schedule posting can be overwritten by restore.
        }

        await gate.release()
        try await contribution.value
        try await restore.value

        XCTAssertEqual(model.savingsGoals.first?.movements.count, 0)
        XCTAssertEqual(model.state, .ready)
        await fixture.store.close()
    }

    @MainActor
    func testLockDefersUntilPausedGoalMutationCommitsThenClearsMemory() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let goal = try SavingsGoal(
            name: "Buffer",
            kind: .savingsGoal,
            target: try Money(500, currency: fixture.sgd),
            targetDate: Date(timeIntervalSinceReferenceDate: 900_000_000),
            createdAt: Date(timeIntervalSinceReferenceDate: 700_000_000)
        )
        let gate = AsyncGate()
        let model = fixture.model(
            savingsGoals: [goal],
            lifecycleHooks: hooks(pausing: .beforeSavingsGoalWrite, at: gate)
        )
        let contribution = Task { @MainActor in
            try await model.addSavingsGoalMovement(
                goalID: goal.id,
                kind: .contribution,
                amount: 15,
                occurredAt: Date(timeIntervalSinceReferenceDate: 800_000_000)
            )
        }
        await gate.waitUntilReached()

        model.lock()
        XCTAssertEqual(model.state, .ready)
        await gate.release()
        try await contribution.value
        await model.waitForPendingStoreClose()

        XCTAssertEqual(model.state, .locked)
        XCTAssertTrue(model.savingsGoals.isEmpty)
        let reopened = try fixture.reopenStore()
        let persisted = try await reopened.fetch(
            SavingsGoal.self,
            id: goal.id.uuidString,
            from: .savingsGoals
        )
        XCTAssertEqual(persisted?.movements.count, 1)
        await reopened.close()
    }

    func testVersionOneWidgetPercentageMigratesToStaleWithoutDisclosure() throws {
        let suiteName = "MoneyUpWidgetV1MigrationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(1, forKey: "budgetStatus.schemaVersion")
        defaults.set(true, forKey: "budgetStatus.enabled")
        defaults.set("available", forKey: "budgetStatus.state")
        defaults.set(88, forKey: "budgetStatus.percentUsed")

        let store = BudgetWidgetSnapshotStore(defaults: defaults)

        XCTAssertEqual(store.read(), .stale)
        XCTAssertNil(defaults.object(forKey: "budgetStatus.percentUsed"))
        XCTAssertTrue(defaults.bool(forKey: "budgetStatus.enabled"))
        XCTAssertEqual(
            defaults.integer(forKey: "budgetStatus.schemaVersion"),
            BudgetWidgetSnapshotStore.currentSchemaVersion
        )
    }

    func testFutureWidgetSchemaIsDisabledAndUnknownPayloadIsScrubbed() throws {
        let suiteName = "MoneyUpWidgetFutureMigration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(99, forKey: "budgetStatus.schemaVersion")
        defaults.set(true, forKey: "budgetStatus.enabled")
        defaults.set("available", forKey: "budgetStatus.state")
        defaults.set(88, forKey: "budgetStatus.percentUsed")
        defaults.set("sensitive", forKey: "budgetStatus.futureAmount")

        let store = BudgetWidgetSnapshotStore(defaults: defaults)

        XCTAssertEqual(store.read(), .disabled)
        XCTAssertNil(defaults.object(forKey: "budgetStatus.percentUsed"))
        XCTAssertNil(defaults.object(forKey: "budgetStatus.futureAmount"))
        XCTAssertEqual(
            defaults.integer(forKey: "budgetStatus.schemaVersion"),
            BudgetWidgetSnapshotStore.currentSchemaVersion
        )
    }

    func testTamperedExtremeWidgetPercentClampsBeforeIntegerConversion() throws {
        let suiteName = "MoneyUpWidgetExtremePercent-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let expiry = Date().addingTimeInterval(60)
        defaults.set(
            BudgetWidgetSnapshotStore.currentSchemaVersion,
            forKey: "budgetStatus.schemaVersion"
        )
        defaults.set(true, forKey: "budgetStatus.enabled")
        defaults.set("available", forKey: "budgetStatus.state")
        defaults.set("2026-08", forKey: "budgetStatus.periodToken")
        defaults.set(expiry, forKey: "budgetStatus.validUntil")
        defaults.set(Int.max, forKey: "budgetStatus.percentUsed")
        let store = BudgetWidgetSnapshotStore(defaults: defaults)

        XCTAssertEqual(
            store.read(now: expiry.addingTimeInterval(-1)),
            .available(percentUsed: 9_999, validUntil: expiry)
        )
    }

    func testBudgetWidgetExpiresAtExactReportingMonthBoundaryAcrossZones() throws {
        for identifier in ["Asia/Singapore", "America/Los_Angeles"] {
            let safeIdentifier = identifier.replacingOccurrences(of: "/", with: "_")
            let suiteName = "MoneyUpWidgetBoundary-\(safeIdentifier)-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let store = BudgetWidgetSnapshotStore(defaults: defaults)
            let calendar = FinancialPeriodBoundary.gregorianCalendar(
                timeZoneIdentifier: identifier
            )
            let august = try XCTUnwrap(calendar.date(from: DateComponents(
                year: 2026,
                month: 8,
                day: 31,
                hour: 23,
                minute: 59
            )))
            let interval = try XCTUnwrap(
                calendar.dateInterval(of: .month, for: august)
            )
            let token = try XCTUnwrap(
                BudgetWidgetSnapshotStore.periodToken(
                    for: interval.start,
                    calendar: calendar
                )
            )
            store.publish(
                enabled: true,
                percentUsed: 42,
                periodToken: token,
                validUntil: interval.end
            )

            XCTAssertEqual(
                store.read(now: interval.end.addingTimeInterval(-0.001)),
                .available(percentUsed: 42, validUntil: interval.end),
                identifier
            )
            XCTAssertEqual(store.read(now: interval.end), .stale, identifier)
            XCTAssertNil(
                defaults.object(forKey: "budgetStatus.percentUsed"),
                identifier
            )
        }
    }

    func testNeedsBudgetWidgetAlsoSchedulesMonthBoundaryExpiry() throws {
        let suiteName = "MoneyUpWidgetNeedsBudgetBoundary-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BudgetWidgetSnapshotStore(defaults: defaults)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let expiry = now.addingTimeInterval(30)
        store.publish(
            enabled: true,
            percentUsed: nil,
            periodToken: "2026-05",
            validUntil: expiry
        )

        XCTAssertEqual(store.read(now: now), .needsBudget(validUntil: expiry))
        XCTAssertEqual(store.read(now: expiry), .stale)
    }

    func testMissingProfileBookDetectionCoversEveryDurableCollection() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let durable = RecordCollection.allCases.filter {
            $0 != .profile && $0 != .quickLogDrafts
        }

        for collection in durable {
            let recordID = "sentinel"
            try await fixture.store.restore(DatabaseSnapshot(
                schemaVersion: EncryptedRecordStore.currentSchemaVersion,
                records: [StoredRecordSnapshot(
                    collection: collection.rawValue,
                    recordID: recordID,
                    payload: Data("{}".utf8),
                    updatedAt: 1
                )]
            ))
            let detected = try await AppModel.containsPersistedBookData(
                in: fixture.store
            )
            XCTAssertTrue(detected, collection.rawValue)
            try await fixture.store.remove(id: recordID, from: collection)
            let cleared = try await AppModel.containsPersistedBookData(
                in: fixture.store
            )
            XCTAssertFalse(cleared, collection.rawValue)
        }
        await fixture.store.close()
    }

    @MainActor
    func testInvalidAutoLockChoiceIsNotPersisted() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let profile = UserProfile(baseCurrency: fixture.sgd, autoLockDelay: 60)
        try await fixture.seed(
            profile: profile,
            accounts: [fixture.wallet, fixture.usAccount, fixture.food]
        )
        let model = fixture.model(profile: profile)

        do {
            try await model.updateAutoLockDelay(30)
            XCTFail("Expected non-Golden auto-lock choice to fail")
        } catch AppModelError.invalidBook {
            // Invalid choices never reach the encrypted primary profile row.
        }
        let stored = try await fixture.store.fetch(
            UserProfile.self,
            id: UserProfile.primaryRecordID,
            from: .profile
        )
        XCTAssertEqual(model.profile?.autoLockDelay, 60)
        XCTAssertEqual(stored?.autoLockDelay, 60)
        await fixture.store.close()
    }
}

private final class MutableTestDate: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Date

    init(_ value: Date) {
        storedValue = value
    }

    func value() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func set(_ value: Date) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}

private struct AppModelFixture {
    let directoryURL: URL
    let databaseURL: URL
    let store: EncryptedRecordStore
    let sgd: CurrencyCode
    let usd: CurrencyCode
    let wallet: LedgerAccount
    let usAccount: LedgerAccount
    let food: LedgerAccount

    init() throws {
        let sgd = try CurrencyCode("SGD")
        let usd = try CurrencyCode("USD")
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoneyUpAppTests-\(UUID().uuidString)")
        let databaseURL = directoryURL.appendingPathComponent("moneyup.sqlite3")
        self.directoryURL = directoryURL
        self.databaseURL = databaseURL
        store = try EncryptedRecordStore(
            databaseURL: databaseURL,
            key: Data(repeating: 0x2a, count: 32)
        )
        self.sgd = sgd
        self.usd = usd
        wallet = LedgerAccount(name: "Wallet", kind: .asset, currency: sgd)
        usAccount = LedgerAccount(name: "USD Cash", kind: .asset, currency: usd)
        food = LedgerAccount(name: "Food", kind: .expense)
    }

    @MainActor
    func model(
        store: EncryptedRecordStore? = nil,
        profile: UserProfile? = nil,
        accounts: [LedgerAccount]? = nil,
        entries: [JournalEntry] = [],
        budgetNodes: [BudgetNode] = [],
        scheduledTransactions: [ScheduledTransaction] = [],
        investmentHoldings: [InvestmentHolding] = [],
        receiptAttachments: [ReceiptAttachment] = [],
        exchangeRates: [DatedExchangeRate] = [],
        netWorthSnapshots: [NetWorthSnapshot] = [],
        savingsGoals: [SavingsGoal] = [],
        quickLogDraft: QuickLogDraft? = nil,
        lockedCaptureStore: any LockedCaptureStoring = InMemoryLockedCaptureStore(
            captures: []
        ),
        receiptRecognizer: @escaping ReceiptLineRecognizer = { data in
            try await ReceiptScanner.recognizeLines(inImageData: data)
        },
        lifecycleHooks: AppModelLifecycleHooks = .none,
        deleteDatabaseKey: @escaping @Sendable () throws -> Void = {},
        dataEraseIntent: DataEraseIntentAccess = .none,
        openDatabaseStore: @escaping DatabaseStoreOpener =
            DatabaseStoreOpeners.production,
        retainsCompleteJournal: Bool = true,
        budgetWidgetSnapshotStore: BudgetWidgetSnapshotStore = BudgetWidgetSnapshotStore(),
        budgetConfigurationTimeline: BudgetConfigurationTimeline? = nil,
        budgetEntryAttributions: [UUID: BudgetEntryAttribution] = [:],
        currentDate: @escaping @Sendable () -> Date = Date.init
    ) -> AppModel {
        AppModel(
            store: store ?? self.store,
            profile: profile ?? UserProfile(baseCurrency: sgd),
            accounts: accounts ?? [wallet, usAccount, food],
            entries: entries,
            budgetNodes: budgetNodes,
            scheduledTransactions: scheduledTransactions,
            investmentHoldings: investmentHoldings,
            receiptAttachments: receiptAttachments,
            exchangeRates: exchangeRates,
            netWorthSnapshots: netWorthSnapshots,
            savingsGoals: savingsGoals,
            quickLogDraft: quickLogDraft,
            lockedCaptureStore: lockedCaptureStore,
            receiptRecognizer: receiptRecognizer,
            lifecycleHooks: lifecycleHooks,
            databaseURLForErase: databaseURL,
            deleteDatabaseKey: deleteDatabaseKey,
            dataEraseIntent: dataEraseIntent,
            openDatabaseStore: openDatabaseStore,
            retainsCompleteJournal: retainsCompleteJournal,
            budgetWidgetSnapshotStore: budgetWidgetSnapshotStore,
            budgetConfigurationTimeline: budgetConfigurationTimeline,
            budgetEntryAttributions: budgetEntryAttributions,
            currentDate: currentDate
        )
    }

    func seed(
        profile: UserProfile,
        accounts: [LedgerAccount],
        entries: [JournalEntry] = [],
        budgetNodes: [BudgetNode] = [],
        budgetConfigurationTimeline: BudgetConfigurationTimeline? = nil,
        schedules: [ScheduledTransaction] = [],
        holdings: [InvestmentHolding] = [],
        savingsGoals: [SavingsGoal] = [],
        quickLogDraft: QuickLogDraft? = nil
    ) async throws {
        var writes: [RecordWrite] = [
            try RecordWrite(
                profile,
                id: UserProfile.primaryRecordID,
                in: .profile
            )
        ]
        writes += try accounts.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .accounts)
        }
        writes += try entries.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .journalEntries)
        }
        writes += try budgetNodes.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .budgetNodes)
        }
        if let budgetConfigurationTimeline {
            writes.append(try RecordWrite(
                budgetConfigurationTimeline,
                id: BudgetConfigurationTimeline.primaryRecordID,
                in: .budgetConfigurationTimelines
            ))
        }
        writes += try schedules.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .scheduledTransactions)
        }
        writes += try holdings.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .investmentHoldings)
        }
        writes += try savingsGoals.map {
            try RecordWrite($0, id: $0.id.uuidString, in: .savingsGoals)
        }
        if let quickLogDraft {
            writes.append(
                try RecordWrite(
                    quickLogDraft,
                    id: QuickLogDraft.primaryRecordID,
                    in: .quickLogDrafts
                )
            )
        }
        try await store.write(writes)
    }

    func reopenStore() throws -> EncryptedRecordStore {
        try EncryptedRecordStore(
            databaseURL: databaseURL,
            key: Data(repeating: 0x2a, count: 32)
        )
    }

    func expense(amount: Decimal) throws -> JournalEntry {
        try TransactionFactory.expense(
            amount: Money(amount, currency: sgd),
            paidFrom: wallet.id,
            category: food.id,
            occurredAt: Date(timeIntervalSinceReferenceDate: 100),
            payee: "Cafe"
        )
    }

    func removeFiles() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private func hooks(
    pausing checkpoint: AppModelLifecycleCheckpoint,
    at gate: AsyncGate
) -> AppModelLifecycleHooks {
    AppModelLifecycleHooks { candidate in
        guard candidate == checkpoint else { return }
        await gate.suspend()
    }
}

private func hooks(
    pausingFirst checkpoint: AppModelLifecycleCheckpoint,
    at gate: FirstRefreshGate
) -> AppModelLifecycleHooks {
    AppModelLifecycleHooks { candidate in
        guard candidate == checkpoint else { return }
        await gate.suspendFirstCaller()
    }
}

private actor FirstRefreshGate {
    private var firstCallerClaimed = false
    private var reached = false
    private var released = false
    private var reachWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspendFirstCaller() async {
        guard !firstCallerClaimed else { return }
        firstCallerClaimed = true
        reached = true
        let waiters = reachWaiters
        reachWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilReached() async {
        guard !reached else { return }
        await withCheckedContinuation { continuation in
            reachWaiters.append(continuation)
        }
    }

    func waitUntilReached(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !reached {
            guard clock.now < deadline else { return false }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return false
            }
        }
        return true
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor AsyncGate {
    private var reached = false
    private var released = false
    private var reachWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        reached = true
        let waiters = reachWaiters
        reachWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilReached() async {
        guard !reached else { return }
        await withCheckedContinuation { continuation in
            reachWaiters.append(continuation)
        }
    }

    func waitUntilReached(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !reached {
            guard clock.now < deadline else { return false }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return false
            }
        }
        return true
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor InMemoryLockedCaptureStore: LockedCaptureStoring {
    private var captures: [LockedCapture]
    private var removeFailuresRemaining: Int

    init(captures: [LockedCapture], removeFailuresRemaining: Int = 0) {
        self.captures = captures
        self.removeFailuresRemaining = removeFailuresRemaining
    }

    func all() async throws -> [LockedCapture] {
        captures
    }

    @discardableResult
    func append(_ capture: LockedCapture) async throws -> Int {
        guard !captures.contains(where: { $0.id == capture.id }) else {
            return captures.count
        }
        captures.append(capture)
        return captures.count
    }

    @discardableResult
    func remove(id: UUID) async throws -> Int {
        if removeFailuresRemaining > 0 {
            removeFailuresRemaining -= 1
            throw LockedCaptureStoreError.unavailable
        }
        captures.removeAll { $0.id == id }
        return captures.count
    }

    func eraseAll() async throws {
        captures.removeAll()
    }
}

private actor PausingAppendLockedCaptureStore: LockedCaptureStoring {
    private let gate: AsyncGate
    private var captures: [LockedCapture] = []

    init(gate: AsyncGate) {
        self.gate = gate
    }

    func all() async throws -> [LockedCapture] {
        captures
    }

    @discardableResult
    func append(_ capture: LockedCapture) async throws -> Int {
        await gate.suspend()
        captures.append(capture)
        return captures.count
    }

    @discardableResult
    func remove(id: UUID) async throws -> Int {
        captures.removeAll { $0.id == id }
        return captures.count
    }

    func eraseAll() async throws {
        captures.removeAll()
    }
}

private final class EraseEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func record(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private final class RetryingEraseIntent: @unchecked Sendable {
    private let lock = NSLock()
    private let events: EraseEventRecorder
    private var isPendingValue = true
    private var clearFailuresRemaining: Int

    init(
        events: EraseEventRecorder,
        clearFailuresRemaining: Int
    ) {
        self.events = events
        self.clearFailuresRemaining = clearFailuresRemaining
    }

    var pending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isPendingValue
    }

    var access: DataEraseIntentAccess {
        DataEraseIntentAccess(
            isPending: { [self] in
                events.record("intent-checked")
                return pending
            },
            markPending: { [self] in
                lock.lock()
                isPendingValue = true
                lock.unlock()
            },
            clear: { [self] in
                events.record("intent-clear-attempted")
                lock.lock()
                defer { lock.unlock() }
                if clearFailuresRemaining > 0 {
                    clearFailuresRemaining -= 1
                    throw DatabaseKeyStoreError.unexpectedStatus(-31_338)
                }
                isPendingValue = false
            }
        )
    }
}

private actor EraseRecordingLockedCaptureStore: LockedCaptureStoring {
    private let events: EraseEventRecorder
    private let eraseError: LockedCaptureStoreError?

    init(
        events: EraseEventRecorder,
        eraseError: LockedCaptureStoreError? = nil
    ) {
        self.events = events
        self.eraseError = eraseError
    }

    func all() async throws -> [LockedCapture] { [] }

    @discardableResult
    func append(_ capture: LockedCapture) async throws -> Int { 0 }

    @discardableResult
    func remove(id: UUID) async throws -> Int { 0 }

    func eraseAll() async throws {
        events.record("locked-capture-erased")
        if let eraseError { throw eraseError }
    }
}

private actor ScriptedLockedCaptureStore: LockedCaptureStoring {
    private var captures: [LockedCapture]
    private var readError: LockedCaptureStoreError?
    private var eraseCallCount = 0

    init(
        captures: [LockedCapture] = [],
        readError: LockedCaptureStoreError? = nil
    ) {
        self.captures = captures
        self.readError = readError
    }

    func setReadError(_ error: LockedCaptureStoreError?) {
        readError = error
    }

    func eraseCount() -> Int { eraseCallCount }

    func all() async throws -> [LockedCapture] {
        if let readError { throw readError }
        return captures
    }

    @discardableResult
    func append(_ capture: LockedCapture) async throws -> Int {
        if let readError { throw readError }
        if !captures.contains(where: { $0.id == capture.id }) {
            captures.append(capture)
        }
        return captures.count
    }

    @discardableResult
    func remove(id: UUID) async throws -> Int {
        if let readError { throw readError }
        captures.removeAll { $0.id == id }
        return captures.count
    }

    func eraseAll() async throws {
        eraseCallCount += 1
        captures.removeAll()
        readError = nil
    }
}
