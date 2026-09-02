import Foundation
@testable import MoneyUp
import XCTest

final class PlatformQuickLogActionTests: XCTestCase {
    @MainActor
    func testPersistedActionsMapToExactDataFreeDeepLinks() throws {
        let expected: [(
            action: MoneyUpQuickAction,
            rawValue: String,
            url: String,
            launchMode: QuickLogLaunchMode
        )] = [
            (.expense, "expense", "moneyup://quick-log/expense", .expense),
            (.income, "income", "moneyup://quick-log/income", .income),
            (.transfer, "transfer", "moneyup://quick-log/transfer", .transfer),
            (.refund, "refund", "moneyup://quick-log/refund", .refund),
            (
                .smartEntry,
                "smartEntry",
                "moneyup://quick-log/smart-entry",
                .smartEntry
            ),
            (
                .scanReceipt,
                "scanReceipt",
                "moneyup://quick-log/scan-receipt",
                .scanReceipt
            )
        ]

        XCTAssertEqual(MoneyUpQuickAction.allCases, expected.map { $0.action })
        XCTAssertEqual(
            expected.map { $0.action.rawValue },
            expected.map { $0.rawValue }
        )

        let broker = MoneyUpQuickActionRouteBroker()
        let model = AppModel(
            dataEraseIntent: .none,
            quickActionRouteBroker: broker
        )
        for mapping in expected {
            let url = mapping.action.deepLink
            let components = try XCTUnwrap(
                URLComponents(url: url, resolvingAgainstBaseURL: false)
            )
            XCTAssertEqual(url.absoluteString, mapping.url)
            XCTAssertEqual(components.scheme, "moneyup")
            XCTAssertEqual(components.host, "quick-log")
            XCTAssertNil(components.user)
            XCTAssertNil(components.password)
            XCTAssertNil(components.port)
            XCTAssertNil(components.query)
            XCTAssertNil(components.fragment)
            XCTAssertEqual(
                MoneyUpQuickAction(exactDeepLink: url),
                mapping.action
            )
            XCTAssertEqual(QuickLogLaunchMode(mapping.action), mapping.launchMode)
            let intent = OpenQuickLogIntent(action: mapping.action)
            XCTAssertEqual(intent.action, mapping.action)
            XCTAssertTrue(model.handleDeepLink(url))
            XCTAssertEqual(model.requestedQuickLogMode, mapping.launchMode)
            model.consumeQuickLogRequest(
                try XCTUnwrap(model.requestedQuickLogRequest)
            )
        }
    }

    @MainActor
    func testDeepLinkAllowlistRejectsEveryNoncanonicalVariant() throws {
        let rejected = [
            "moneyup://quick-log/expense?amount=1",
            "moneyup://quick-log/expense#fragment",
            "moneyup://user@quick-log/expense",
            "moneyup://user:password@quick-log/expense",
            "moneyup://quick-log:443/expense",
            "MONEYUP://quick-log/expense",
            "moneyup://QUICK-LOG/expense",
            "moneyup://quick-log/EXPENSE",
            "moneyup://quick-log/%65xpense",
            "moneyup://quick-log/%2E/expense",
            "moneyup://quick-log//expense",
            "moneyup://quick-log/expense/",
            "moneyup://quick-log/expense/extra",
            "moneyup://quick-log/expense%2Fextra"
        ]
        let broker = MoneyUpQuickActionRouteBroker()
        let model = AppModel(
            dataEraseIntent: .none,
            quickActionRouteBroker: broker
        )

        for rawURL in rejected {
            let url = try XCTUnwrap(URL(string: rawURL), rawURL)
            XCTAssertNil(MoneyUpQuickAction(exactDeepLink: url), rawURL)
            XCTAssertFalse(model.handleDeepLink(url), rawURL)
            XCTAssertNil(model.requestedQuickLogRequest, rawURL)
            XCTAssertEqual(broker.pendingCount, 0, rawURL)
        }

        let base = try XCTUnwrap(URL(string: "moneyup://quick-log/"))
        let relative = try XCTUnwrap(URL(string: "expense", relativeTo: base))
        XCTAssertEqual(
            relative.absoluteString,
            MoneyUpQuickAction.expense.deepLink.absoluteString
        )
        XCTAssertNotNil(relative.baseURL)
        XCTAssertNil(MoneyUpQuickAction(exactDeepLink: relative))
        XCTAssertFalse(model.handleDeepLink(relative))
        XCTAssertNil(model.requestedQuickLogRequest)
        XCTAssertEqual(broker.pendingCount, 0)
    }

    @MainActor
    func testDirectDeepLinksEnterFIFOAndWaitForTransientAppWork() throws {
        let broker = MoneyUpQuickActionRouteBroker()
        let model = AppModel(
            dataEraseIntent: .none,
            quickActionRouteBroker: broker
        )
        model.state = .ready
        model.isWorking = true

        for url in [
            MoneyUpQuickAction.expense.deepLink,
            MoneyUpQuickAction.income.deepLink
        ] {
            let action = try XCTUnwrap(
                MoneyUpQuickAction(exactDeepLink: url)
            )
            XCTAssertTrue(broker.submit(action))
        }

        XCTAssertEqual(
            MoneyUpQuickActionRouting.routeNext(from: broker, into: model),
            .deferred
        )
        XCTAssertEqual(broker.pendingCount, 2)

        model.isWorking = false
        XCTAssertEqual(
            MoneyUpQuickActionRouting.routeNext(from: broker, into: model),
            .routed
        )
        let first = try XCTUnwrap(model.requestedQuickLogRequest)
        XCTAssertEqual(first.mode, .expense)
        XCTAssertEqual(broker.pendingCount, 1)
        XCTAssertEqual(
            MoneyUpQuickActionRouting.routeNext(from: broker, into: model),
            .deferred
        )

        model.consumeQuickLogRequest(first)
        XCTAssertEqual(
            MoneyUpQuickActionRouting.routeNext(from: broker, into: model),
            .routed
        )
        XCTAssertEqual(model.requestedQuickLogMode, .income)
        XCTAssertEqual(broker.pendingCount, 0)
    }

    @MainActor
    func testDirectDeepLinkFailsClosedAtBoundaryAndUnreadableTombstone() throws {
        let broker = MoneyUpQuickActionRouteBroker()
        let action = try XCTUnwrap(
            MoneyUpQuickAction(
                exactDeepLink: MoneyUpQuickAction.refund.deepLink
            )
        )
        let epoch = broker.beginAuthoritativeBoundary()

        XCTAssertFalse(broker.submit(action))
        XCTAssertEqual(broker.pendingCount, 0)
        broker.endAuthoritativeBoundary(epoch)

        let model = AppModel(
            dataEraseIntent: DataEraseIntentAccess(
                isPending: {
                    throw NSError(
                        domain: "PlatformQuickLogActionTests",
                        code: 2
                    )
                },
                markPending: {},
                clear: {}
            ),
            quickActionRouteBroker: broker
        )
        XCTAssertTrue(broker.submit(action))
        XCTAssertEqual(
            MoneyUpQuickActionRouting.routeNext(from: broker, into: model),
            .discarded
        )
        XCTAssertEqual(broker.pendingCount, 0)
        XCTAssertNil(model.requestedQuickLogRequest)
    }

    @MainActor
    func testTombstoneBecomingPendingAfterDequeueDiscardsWholeQueue() {
        assertPostDequeueTombstoneDenial([
            .pending(false),
            .pending(true)
        ])
    }

    @MainActor
    func testTombstoneBecomingUnreadableAfterDequeueDiscardsWholeQueue() {
        assertPostDequeueTombstoneDenial([
            .pending(false),
            .unreadable
        ])
    }

    @MainActor
    func testLockSafeTombstoneBecomingPendingDiscardsWholeQueue() {
        assertPostDequeueTombstoneDenial(
            [.pending(false), .pending(false), .pending(true)],
            lockedCaptureEnabled: true
        )
    }

    @MainActor
    func testLockSafeTombstoneBecomingUnreadableDiscardsWholeQueue() {
        assertPostDequeueTombstoneDenial(
            [.pending(false), .pending(false), .unreadable],
            lockedCaptureEnabled: true
        )
    }

    func testDefaultIntentCarriesOnlyTheClosedExpenseAction() {
        let intent = OpenQuickLogIntent()

        XCTAssertEqual(intent.action, .expense)
        XCTAssertEqual(
            intent.action.deepLink.absoluteString,
            "moneyup://quick-log/expense"
        )
    }

    @MainActor
    func testColdBasicActionWaitsForStartupWorkThenRoutesOnce() throws {
        let broker = MoneyUpQuickActionRouteBroker()
        let model = AppModel(
            dataEraseIntent: .none,
            quickActionRouteBroker: broker
        )
        let defaults = UserDefaults.standard
        let key = AppModel.lockedQuickCapturePreferenceKey
        let previous = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        XCTAssertEqual(model.state, .launching)
        model.isWorking = true
        let action = try XCTUnwrap(
            MoneyUpQuickAction(
                exactDeepLink: MoneyUpQuickAction.expense.deepLink
            )
        )
        XCTAssertTrue(broker.submit(action))

        XCTAssertEqual(
            MoneyUpQuickActionRouting.routeNext(from: broker, into: model),
            .deferred
        )
        XCTAssertEqual(broker.pendingCount, 1)
        XCTAssertNil(model.requestedQuickLogMode)

        model.isWorking = false
        XCTAssertEqual(
            MoneyUpQuickActionRouting.routeNext(from: broker, into: model),
            .routed
        )
        XCTAssertEqual(broker.pendingCount, 0)
        XCTAssertEqual(model.requestedQuickLogMode, .expense)
        XCTAssertTrue(model.canPresentLockedQuickCapture)
    }

    @MainActor
    func testTwoIdenticalInvocationsWaitForSequentialUIConsumption() throws {
        let broker = MoneyUpQuickActionRouteBroker()
        let model = AppModel(
            dataEraseIntent: .none,
            quickActionRouteBroker: broker
        )
        model.state = .ready

        broker.submit(.income)
        broker.submit(.income)

        XCTAssertEqual(
            MoneyUpQuickActionRouting.routeNext(from: broker, into: model),
            .routed
        )
        XCTAssertEqual(model.requestedQuickLogMode, .income)
        let firstRequest = try XCTUnwrap(model.requestedQuickLogRequest)
        XCTAssertEqual(broker.pendingCount, 1)
        XCTAssertEqual(
            MoneyUpQuickActionRouting.routeNext(from: broker, into: model),
            .deferred
        )
        XCTAssertEqual(broker.pendingCount, 1)

        model.consumeQuickLogRequest(firstRequest)
        XCTAssertEqual(
            MoneyUpQuickActionRouting.routeNext(from: broker, into: model),
            .routed
        )
        XCTAssertEqual(model.requestedQuickLogMode, .income)
        let secondRequest = try XCTUnwrap(model.requestedQuickLogRequest)
        XCTAssertNotEqual(secondRequest.id, firstRequest.id)
        XCTAssertEqual(secondRequest.generation, firstRequest.generation)
        model.consumeQuickLogRequest(firstRequest)
        XCTAssertEqual(model.requestedQuickLogRequest, secondRequest)
        XCTAssertEqual(broker.pendingCount, 0)
        model.consumeQuickLogRequest(secondRequest)
        XCTAssertEqual(
            MoneyUpQuickActionRouting.routeNext(from: broker, into: model),
            .idle
        )
    }

    @MainActor
    func testPresentedRequestRejectsOldGenerationAndKeepsDuplicatesDistinct() throws {
        let broker = MoneyUpQuickActionRouteBroker()
        let model = AppModel(
            dataEraseIntent: .none,
            quickActionRouteBroker: broker
        )
        model.requestedQuickLogMode = .income
        let first = try XCTUnwrap(model.requestedQuickLogRequest)
        XCTAssertTrue(model.presentQuickLogRequest(first))
        XCTAssertEqual(model.presentedQuickLogRequest, first)

        model.consumeQuickLogRequest(first)
        model.requestedQuickLogMode = .income
        let duplicate = try XCTUnwrap(model.requestedQuickLogRequest)
        XCTAssertTrue(model.presentQuickLogRequest(duplicate))
        XCTAssertNotEqual(duplicate.id, first.id)
        XCTAssertEqual(model.presentedQuickLogRequest, duplicate)

        let epoch = model.beginAuthoritativeQuickActionBoundary()
        XCTAssertNil(model.presentedQuickLogRequest)
        broker.endAuthoritativeBoundary(epoch)
        XCTAssertFalse(model.presentQuickLogRequest(duplicate))
    }

    @MainActor
    func testWarmActionsPreserveFIFOAcrossSequentialUIConsumption() {
        let broker = MoneyUpQuickActionRouteBroker()
        let model = AppModel(
            dataEraseIntent: .none,
            quickActionRouteBroker: broker
        )
        model.state = .ready
        let expected: [MoneyUpQuickAction] = [
            .smartEntry, .scanReceipt, .transfer, .refund
        ]

        expected.forEach { broker.submit($0) }

        for action in expected {
            XCTAssertEqual(
                MoneyUpQuickActionRouting.routeNext(from: broker, into: model),
                .routed
            )
            XCTAssertEqual(
                model.requestedQuickLogMode,
                QuickLogLaunchMode(rawValue: action.deepLink.lastPathComponent)
            )
            model.requestedQuickLogMode = nil
        }
        XCTAssertEqual(broker.pendingCount, 0)
    }

    @MainActor
    func testRouteBrokerRejectsNewestActionAtCapacityWithoutReordering() {
        let broker = MoneyUpQuickActionRouteBroker()
        let accepted = (0..<MoneyUpQuickActionRouteBroker.maximumPendingActionCount)
            .map { index in
                MoneyUpQuickAction.allCases[index % MoneyUpQuickAction.allCases.count]
            }

        for action in accepted {
            XCTAssertTrue(broker.submit(action))
        }
        let revisionAtCapacity = broker.revision
        XCTAssertFalse(broker.submit(.scanReceipt))
        XCTAssertEqual(broker.revision, revisionAtCapacity + 1)
        XCTAssertEqual(
            broker.pendingCount,
            MoneyUpQuickActionRouteBroker.maximumPendingActionCount
        )

        XCTAssertEqual(
            accepted.compactMap { _ in broker.takePendingAction() },
            accepted
        )
        XCTAssertNil(broker.takePendingAction())
    }

    @MainActor
    func testCapacityRejectionWakesUnreadableTombstoneDiscard() {
        let broker = MoneyUpQuickActionRouteBroker()
        let model = AppModel(
            dataEraseIntent: DataEraseIntentAccess(
                isPending: { throw PlatformEraseIntentProbeError.unreadable },
                markPending: {},
                clear: {}
            ),
            quickActionRouteBroker: broker
        )
        for index in 0..<MoneyUpQuickActionRouteBroker.maximumPendingActionCount {
            XCTAssertTrue(broker.submit(
                MoneyUpQuickAction.allCases[index % MoneyUpQuickAction.allCases.count]
            ))
        }
        let revisionAtCapacity = broker.revision

        XCTAssertFalse(broker.submit(.refund))
        XCTAssertEqual(broker.revision, revisionAtCapacity + 1)
        XCTAssertEqual(
            MoneyUpQuickActionRouting.routeNext(from: broker, into: model),
            .discarded
        )
        XCTAssertEqual(broker.pendingCount, 0)
        XCTAssertNil(model.requestedQuickLogRequest)
    }

    @MainActor
    func testBoundaryEpochsRejectUntilEveryAuthoritativeLifecycleFinishes() {
        let broker = MoneyUpQuickActionRouteBroker()
        XCTAssertTrue(broker.submit(.expense))

        let firstEpoch = broker.beginAuthoritativeBoundary()
        XCTAssertEqual(broker.pendingCount, 0)
        XCTAssertTrue(broker.isAuthoritativeBoundaryActive)
        XCTAssertFalse(broker.submit(.income))

        let secondEpoch = broker.beginAuthoritativeBoundary()
        broker.endAuthoritativeBoundary(firstEpoch)
        XCTAssertTrue(broker.isAuthoritativeBoundaryActive)
        XCTAssertFalse(broker.submit(.refund))
        XCTAssertFalse(broker.submit(.refund))

        let revisionBeforeRepeatedFinish = broker.revision
        broker.endAuthoritativeBoundary(firstEpoch)
        XCTAssertEqual(broker.revision, revisionBeforeRepeatedFinish)
        broker.endAuthoritativeBoundary(secondEpoch)
        XCTAssertFalse(broker.isAuthoritativeBoundaryActive)
        XCTAssertTrue(broker.submit(.transfer))
    }

    @MainActor
    func testDirectDeepLinkCannotRepopulateAnAuthoritativeBoundary() {
        let broker = MoneyUpQuickActionRouteBroker()
        let model = AppModel(
            dataEraseIntent: .none,
            quickActionRouteBroker: broker
        )
        model.requestedQuickLogMode = .income
        let oldRequest = model.requestedQuickLogRequest

        let epoch = model.beginAuthoritativeQuickActionBoundary()
        XCTAssertNil(model.requestedQuickLogRequest)
        model.requestedQuickLogMode = .refund
        XCTAssertNil(model.requestedQuickLogRequest)
        XCTAssertFalse(model.handleDeepLink(MoneyUpQuickAction.refund.deepLink))
        XCTAssertNil(model.requestedQuickLogRequest)

        broker.endAuthoritativeBoundary(epoch)
        XCTAssertTrue(model.handleDeepLink(MoneyUpQuickAction.refund.deepLink))
        XCTAssertNotEqual(model.requestedQuickLogRequest, oldRequest)
        XCTAssertEqual(
            model.requestedQuickLogRequest?.generation,
            broker.handoffGeneration
        )
    }

    @MainActor
    func testQueueDeferredByBusyWorkIsDiscardedWhenRestoreBoundaryBegins() {
        let broker = MoneyUpQuickActionRouteBroker()
        let model = AppModel(
            dataEraseIntent: .none,
            quickActionRouteBroker: broker
        )
        model.isWorking = true
        broker.submit(.expense)
        broker.submit(.income)

        XCTAssertEqual(
            MoneyUpQuickActionRouting.routeNext(from: broker, into: model),
            .deferred
        )
        XCTAssertEqual(broker.pendingCount, 2)

        model.goalMutationBarrierClosed = true
        let revisionBeforeDiscard = broker.revision

        XCTAssertEqual(
            MoneyUpQuickActionRouting.routeNext(from: broker, into: model),
            .discarded
        )
        XCTAssertEqual(broker.pendingCount, 0)
        XCTAssertEqual(broker.revision, revisionBeforeDiscard + 1)
        XCTAssertNil(model.requestedQuickLogMode)
    }

    @MainActor
    func testOrdinarySameBookLifecycleRetainsFIFOThenRoutes() throws {
        let broker = MoneyUpQuickActionRouteBroker()
        let model = AppModel(
            dataEraseIntent: .none,
            quickActionRouteBroker: broker
        )
        model.state = .ready
        model.isLifecycleMutationInProgress = true
        model.isWorking = true
        broker.submit(.income)
        broker.submit(.transfer)

        XCTAssertEqual(
            MoneyUpQuickActionRouting.routeNext(from: broker, into: model),
            .deferred
        )
        XCTAssertEqual(broker.pendingCount, 2)
        XCTAssertNil(model.requestedQuickLogMode)

        model.isWorking = false
        model.isLifecycleMutationInProgress = false
        XCTAssertEqual(
            MoneyUpQuickActionRouting.routeNext(from: broker, into: model),
            .routed
        )
        XCTAssertEqual(broker.pendingCount, 1)
        XCTAssertEqual(model.requestedQuickLogMode, .income)

        model.consumeQuickLogRequest(try XCTUnwrap(model.requestedQuickLogRequest))
        XCTAssertEqual(
            MoneyUpQuickActionRouting.routeNext(from: broker, into: model),
            .routed
        )
        XCTAssertEqual(broker.pendingCount, 0)
        XCTAssertEqual(model.requestedQuickLogMode, .transfer)
    }

    @MainActor
    func testActionSubmittedDuringEraseIsDiscardedBeforeRouting() {
        let broker = MoneyUpQuickActionRouteBroker()
        let model = AppModel(
            dataEraseIntent: DataEraseIntentAccess(
                isPending: { true },
                markPending: {},
                clear: {}
            ),
            quickActionRouteBroker: broker
        )
        model.isWorking = true
        model.isLifecycleMutationInProgress = true
        model.goalMutationBarrierClosed = true
        broker.submit(.scanReceipt)
        broker.submit(.scanReceipt)

        XCTAssertEqual(
            MoneyUpQuickActionRouting.routeNext(from: broker, into: model),
            .discarded
        )
        XCTAssertEqual(broker.pendingCount, 0)
        XCTAssertNil(model.requestedQuickLogMode)
    }

    @MainActor
    func testPendingEraseTombstoneDiscardsWholeQueueFailClosed() {
        let broker = MoneyUpQuickActionRouteBroker()
        let model = AppModel(
            dataEraseIntent: DataEraseIntentAccess(
                isPending: { true },
                markPending: {},
                clear: {}
            ),
            quickActionRouteBroker: broker
        )
        broker.submit(.smartEntry)
        broker.submit(.transfer)

        XCTAssertEqual(
            MoneyUpQuickActionRouting.routeNext(from: broker, into: model),
            .discarded
        )
        XCTAssertEqual(broker.pendingCount, 0)
        XCTAssertNil(model.requestedQuickLogMode)
    }

    @MainActor
    func testEraseTombstoneCheckFailureDiscardsWholeQueueFailClosed() {
        let broker = MoneyUpQuickActionRouteBroker()
        let model = AppModel(
            dataEraseIntent: DataEraseIntentAccess(
                isPending: {
                    throw NSError(
                        domain: "PlatformQuickLogActionTests",
                        code: 1
                    )
                },
                markPending: {},
                clear: {}
            ),
            quickActionRouteBroker: broker
        )
        model.isWorking = true
        broker.submit(.refund)
        broker.submit(.expense)

        XCTAssertEqual(
            MoneyUpQuickActionRouting.routeNext(from: broker, into: model),
            .discarded
        )
        XCTAssertEqual(broker.pendingCount, 0)
        XCTAssertNil(model.requestedQuickLogMode)
    }

    @MainActor
    private func assertPostDequeueTombstoneDenial(
        _ outcomes: [PlatformEraseIntentOutcome],
        lockedCaptureEnabled: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let defaults = UserDefaults.standard
        let key = AppModel.lockedQuickCapturePreferenceKey
        let previous = defaults.object(forKey: key)
        defaults.set(lockedCaptureEnabled, forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let probe = PlatformEraseIntentProbe(outcomes)
        let broker = MoneyUpQuickActionRouteBroker()
        let model = AppModel(
            dataEraseIntent: DataEraseIntentAccess(
                isPending: { try probe.read() },
                markPending: {},
                clear: {}
            ),
            quickActionRouteBroker: broker
        )
        model.state = .launching
        XCTAssertTrue(broker.submit(.expense), file: file, line: line)
        XCTAssertTrue(broker.submit(.income), file: file, line: line)

        XCTAssertEqual(
            MoneyUpQuickActionRouting.routeNext(from: broker, into: model),
            .discarded,
            file: file,
            line: line
        )
        XCTAssertEqual(broker.pendingCount, 0, file: file, line: line)
        XCTAssertNil(model.requestedQuickLogRequest, file: file, line: line)
        XCTAssertEqual(
            probe.readCount,
            outcomes.count,
            file: file,
            line: line
        )
    }
}

private enum PlatformEraseIntentOutcome: Sendable {
    case pending(Bool)
    case unreadable
}

private enum PlatformEraseIntentProbeError: Error {
    case unreadable
    case unexpectedRead
}

private final class PlatformEraseIntentProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [PlatformEraseIntentOutcome]
    private var storedReadCount = 0

    init(_ outcomes: [PlatformEraseIntentOutcome]) {
        self.outcomes = outcomes
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedReadCount
    }

    func read() throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        storedReadCount += 1
        guard !outcomes.isEmpty else {
            throw PlatformEraseIntentProbeError.unexpectedRead
        }
        switch outcomes.removeFirst() {
        case let .pending(value):
            return value
        case .unreadable:
            throw PlatformEraseIntentProbeError.unreadable
        }
    }
}
