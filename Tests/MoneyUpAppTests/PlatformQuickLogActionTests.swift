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
        let epoch = try broker.beginAuthoritativeBoundary()

        XCTAssertFalse(broker.submit(action))
        XCTAssertEqual(broker.pendingCount, 0)
        broker.endAuthoritativeBoundary(epoch)
        XCTAssertTrue(
            broker.reopenDurableAdmissionAfterAuthoritativeRecovery()
        )

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

        let epoch = try model.beginAuthoritativeQuickActionBoundary()
        XCTAssertNil(model.presentedQuickLogRequest)
        broker.endAuthoritativeBoundary(epoch)
        XCTAssertFalse(model.presentQuickLogRequest(duplicate))
    }

    @MainActor
    func testAcknowledgementAtomicallyClearsQueuedAndPresentedSlots() throws {
        let broker = MoneyUpQuickActionRouteBroker()
        let model = AppModel(
            dataEraseIntent: .none,
            quickActionRouteBroker: broker
        )
        model.state = .ready
        model.requestedQuickLogMode = .expense
        let request = try XCTUnwrap(model.requestedQuickLogRequest)

        XCTAssertTrue(model.presentQuickLogRequest(request))
        XCTAssertEqual(model.requestedQuickLogRequest, request)
        XCTAssertEqual(model.presentedQuickLogRequest, request)

        model.consumeQuickLogRequest(request)

        XCTAssertNil(model.requestedQuickLogMode)
        XCTAssertNil(model.requestedQuickLogRequest)
        XCTAssertNil(model.presentedQuickLogRequest)
        // Recreating the Log hierarchy cannot present the acknowledged token.
        XCTAssertFalse(model.presentQuickLogRequest(request))
        model.consumeQuickLogRequest(request)
        XCTAssertNil(model.presentedQuickLogRequest)
    }

    @MainActor
    func testStaleAcknowledgementCannotClearANewerPresentedRequest() throws {
        let broker = MoneyUpQuickActionRouteBroker()
        let model = AppModel(
            dataEraseIntent: .none,
            quickActionRouteBroker: broker
        )
        model.state = .ready
        model.requestedQuickLogMode = .income
        let first = try XCTUnwrap(model.requestedQuickLogRequest)
        XCTAssertTrue(model.presentQuickLogRequest(first))
        model.consumeQuickLogRequest(first)

        model.requestedQuickLogMode = .income
        let second = try XCTUnwrap(model.requestedQuickLogRequest)
        XCTAssertTrue(model.presentQuickLogRequest(second))
        model.consumeQuickLogRequest(first)

        XCTAssertEqual(model.requestedQuickLogRequest, second)
        XCTAssertEqual(model.presentedQuickLogRequest, second)
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
            model.consumeQuickLogRequest(
                try! XCTUnwrap(model.requestedQuickLogRequest)
            )
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

        for action in accepted {
            let record = broker.takePendingRecord()
            XCTAssertEqual(record?.action, action)
            XCTAssertTrue(broker.acknowledge(token: try! XCTUnwrap(record?.token)))
        }
        XCTAssertNil(broker.takePendingRecord())
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
    func testBoundaryEpochsRejectUntilEveryAuthoritativeLifecycleFinishes() throws {
        let broker = MoneyUpQuickActionRouteBroker()
        XCTAssertTrue(broker.submit(.expense))

        let firstEpoch = try broker.beginAuthoritativeBoundary()
        XCTAssertEqual(broker.pendingCount, 0)
        XCTAssertTrue(broker.isAuthoritativeBoundaryActive)
        XCTAssertTrue(broker.isAuthoritativeLifecycleBoundaryActive)
        XCTAssertFalse(broker.submit(.income))

        let secondEpoch = try broker.beginAuthoritativeBoundary()
        broker.endAuthoritativeBoundary(firstEpoch)
        XCTAssertTrue(broker.isAuthoritativeBoundaryActive)
        XCTAssertFalse(broker.submit(.refund))
        XCTAssertFalse(broker.submit(.refund))

        let revisionBeforeRepeatedFinish = broker.revision
        broker.endAuthoritativeBoundary(firstEpoch)
        XCTAssertEqual(broker.revision, revisionBeforeRepeatedFinish)
        broker.endAuthoritativeBoundary(secondEpoch)
        XCTAssertTrue(broker.isAuthoritativeBoundaryActive)
        XCTAssertFalse(broker.isAuthoritativeLifecycleBoundaryActive)
        XCTAssertFalse(broker.submit(.transfer))
        XCTAssertTrue(
            broker.reopenDurableAdmissionAfterAuthoritativeRecovery()
        )
        XCTAssertFalse(broker.isAuthoritativeBoundaryActive)
        XCTAssertTrue(broker.submit(.transfer))
    }

    @MainActor
    func testDirectDeepLinkCannotRepopulateAnAuthoritativeBoundary() throws {
        let broker = MoneyUpQuickActionRouteBroker()
        let model = AppModel(
            dataEraseIntent: .none,
            quickActionRouteBroker: broker
        )
        model.requestedQuickLogMode = .income
        let oldRequest = model.requestedQuickLogRequest

        let epoch = try model.beginAuthoritativeQuickActionBoundary()
        XCTAssertNil(model.requestedQuickLogRequest)
        model.requestedQuickLogMode = .refund
        XCTAssertNil(model.requestedQuickLogRequest)
        XCTAssertFalse(model.handleDeepLink(MoneyUpQuickAction.refund.deepLink))
        XCTAssertNil(model.requestedQuickLogRequest)

        broker.endAuthoritativeBoundary(epoch)
        XCTAssertFalse(model.handleDeepLink(MoneyUpQuickAction.refund.deepLink))
        XCTAssertTrue(
            broker.reopenDurableAdmissionAfterAuthoritativeRecovery()
        )
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
    func testDurableIngressSurvivesProcessRecreationUntilExactUIAck() throws {
        let fixture = try makeDurableIngressFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        let token = UUID()
        let producer = durableBroker(at: fixture.fileURL)

        XCTAssertTrue(producer.submit(.income, token: token))

        let coldBroker = durableBroker(at: fixture.fileURL)
        let model = AppModel(
            dataEraseIntent: .none,
            quickActionRouteBroker: coldBroker
        )
        model.state = .ready
        XCTAssertEqual(coldBroker.pendingCount, 1)
        XCTAssertEqual(
            MoneyUpQuickActionRouting.routeNext(from: coldBroker, into: model),
            .routed
        )
        let request = try XCTUnwrap(model.requestedQuickLogRequest)
        XCTAssertEqual(request.ingressToken, token)

        // Dequeue is delivery, not consumption. A killed app sees the same
        // stable head and may replay navigation without creating a transaction.
        let beforeAckRecreation = durableBroker(at: fixture.fileURL)
        XCTAssertEqual(beforeAckRecreation.pendingCount, 1)
        XCTAssertEqual(beforeAckRecreation.pendingAction, .income)

        model.consumeQuickLogRequest(request)
        XCTAssertNil(model.requestedQuickLogRequest)
        XCTAssertEqual(durableBroker(at: fixture.fileURL).pendingCount, 0)
    }

    @MainActor
    func testAbsentDurableStorePersistsOnlyExactBoundedProtocolShape() throws {
        let fixture = try makeDurableIngressFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        let storageDirectory = fixture.directoryURL.appendingPathComponent(
            MoneyUpQuickActionIngressFileStore.storageDirectoryName,
            isDirectory: true
        )
        let fileURL = storageDirectory.appendingPathComponent(
            MoneyUpQuickActionIngressFileStore.fileName
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageDirectory.path))
        let broker = durableBroker(at: fileURL)
        let token = UUID()
        XCTAssertFalse(broker.isAuthoritativeBoundaryActive)
        XCTAssertTrue(broker.submit(.smartEntry, token: token))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: storageDirectory.path
        )
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1,
            0o700
        )

        let data = try Data(contentsOf: fileURL)
        XCTAssertLessThanOrEqual(
            data.count,
            MoneyUpQuickActionIngressFileStore.maximumPayloadByteCount
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(
            Set(root.keys),
            Set(["schemaVersion", "authorityToken", "admission", "records"])
        )
        let records = try XCTUnwrap(root["records"] as? [[String: Any]])
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(Set(records[0].keys), Set(["token", "action"]))
        XCTAssertEqual(records[0]["token"] as? String, token.uuidString)
        XCTAssertEqual(records[0]["action"] as? String, "smartEntry")
    }

    @MainActor
    func testCrashAfterDequeueBeforeAckReplaysTheSameStableToken() throws {
        let fixture = try makeDurableIngressFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        let token = UUID()
        let firstProcess = durableBroker(at: fixture.fileURL)
        XCTAssertTrue(firstProcess.submit(.refund, token: token))
        XCTAssertEqual(firstProcess.takePendingRecord()?.token, token)
        XCTAssertEqual(firstProcess.pendingCount, 0)

        let recreatedProcess = durableBroker(at: fixture.fileURL)
        let replay = try XCTUnwrap(recreatedProcess.takePendingRecord())
        XCTAssertEqual(replay.token, token)
        XCTAssertEqual(replay.action, .refund)
        XCTAssertTrue(recreatedProcess.acknowledge(token: token))
        XCTAssertEqual(durableBroker(at: fixture.fileURL).pendingCount, 0)
    }

    @MainActor
    func testDurableAckCannotRemoveAnotherOrDuplicateRecord() throws {
        let fixture = try makeDurableIngressFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        let firstToken = UUID()
        let secondToken = UUID()
        let broker = durableBroker(at: fixture.fileURL)
        XCTAssertTrue(broker.submit(.expense, token: firstToken))
        XCTAssertTrue(broker.submit(.expense, token: secondToken))
        XCTAssertEqual(broker.takePendingRecord()?.token, firstToken)

        XCTAssertFalse(broker.acknowledge(token: secondToken))
        XCTAssertTrue(broker.ownsActiveDelivery(token: firstToken))
        XCTAssertEqual(durableBroker(at: fixture.fileURL).pendingCount, 2)
        XCTAssertTrue(broker.acknowledge(token: firstToken))
        XCTAssertTrue(broker.acknowledge(token: firstToken))

        let remaining = durableBroker(at: fixture.fileURL)
        XCTAssertEqual(remaining.pendingCount, 1)
        XCTAssertEqual(remaining.takePendingRecord()?.token, secondToken)
    }

    @MainActor
    func testLockedCaptureSaveThenDoneUsesExactIdempotentAcknowledgement()
    async throws {
        let ingress = try makeDurableIngressFixture()
        defer { try? FileManager.default.removeItem(at: ingress.directoryURL) }
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let inbox = DurableActionLockedCaptureStore()
        let broker = durableBroker(at: ingress.fileURL)
        let token = UUID()
        XCTAssertTrue(broker.submit(.expense, token: token))
        let model = fixture.model(
            lockedCaptureStore: inbox,
            quickActionRouteBroker: broker
        )
        model.state = .locked
        UserDefaults.standard.set(
            true,
            forKey: AppModel.lockedQuickCapturePreferenceKey
        )
        XCTAssertEqual(
            MoneyUpQuickActionRouting.routeNext(from: broker, into: model),
            .routed
        )
        let request = try XCTUnwrap(model.requestedQuickLogRequest)

        try await model.saveLockedCapture(
            request: request,
            amountText: "12.50",
            payee: "Cafe",
            note: "Lunch"
        )
        model.consumeQuickLogRequest(request)

        XCTAssertNil(model.requestedQuickLogRequest)
        XCTAssertEqual(durableBroker(at: ingress.fileURL).pendingCount, 0)
        let captures = try await inbox.all()
        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures.first?.id, token)
        await fixture.store.close()
    }

    @MainActor
    func testCrashAfterLockedInboxCommitReplaysAsSavedWithoutDuplicate()
    async throws {
        let ingress = try makeDurableIngressFixture()
        defer { try? FileManager.default.removeItem(at: ingress.directoryURL) }
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let inbox = DurableActionLockedCaptureStore()
        let token = UUID()
        let firstBroker = durableBroker(at: ingress.fileURL)
        XCTAssertTrue(firstBroker.submit(.income, token: token))
        let firstModel = fixture.model(
            lockedCaptureStore: inbox,
            quickActionRouteBroker: firstBroker
        )
        firstModel.state = .locked
        UserDefaults.standard.set(
            true,
            forKey: AppModel.lockedQuickCapturePreferenceKey
        )
        XCTAssertEqual(
            MoneyUpQuickActionRouting.routeNext(
                from: firstBroker,
                into: firstModel
            ),
            .routed
        )
        let firstRequest = try XCTUnwrap(firstModel.requestedQuickLogRequest)

        // This is the kill point: the encrypted inbox append committed, but
        // the durable action head has not yet received its UI acknowledgement.
        try await firstModel.saveLockedCapture(
            mode: firstRequest.mode,
            captureID: firstRequest.ingressToken,
            amountText: "91.25",
            payee: "Payroll",
            note: "Original payload"
        )

        let recreatedBroker = durableBroker(at: ingress.fileURL)
        let recreatedModel = fixture.model(
            lockedCaptureStore: inbox,
            quickActionRouteBroker: recreatedBroker
        )
        recreatedModel.state = .locked
        XCTAssertEqual(
            MoneyUpQuickActionRouting.routeNext(
                from: recreatedBroker,
                into: recreatedModel
            ),
            .routed
        )
        let replay = try XCTUnwrap(recreatedModel.requestedQuickLogRequest)
        XCTAssertEqual(replay.ingressToken, token)
        let resumed = try await recreatedModel.resumeCommittedLockedCaptureIfPresent(
            request: replay
        )
        XCTAssertTrue(resumed)
        recreatedModel.consumeQuickLogRequest(replay)

        XCTAssertNil(recreatedModel.requestedQuickLogRequest)
        XCTAssertEqual(durableBroker(at: ingress.fileURL).pendingCount, 0)
        let captures = try await inbox.all()
        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures.first?.id, token)
        XCTAssertEqual(captures.first?.amountText, "91.25")
        XCTAssertEqual(captures.first?.note, "Original payload")
        await fixture.store.close()
    }

    @MainActor
    func testAckFailureAfterLockedCommitDismissesAndSafelyReplays() async throws {
        let ingress = try makeDurableIngressFixture()
        defer { try? FileManager.default.removeItem(at: ingress.directoryURL) }
        let fixture = try AppModelFixture()
        defer { fixture.removeFiles() }
        let inbox = DurableActionLockedCaptureStore()
        let backing = MoneyUpQuickActionIngressFileStore(fileURL: ingress.fileURL)
        let failingStore = ControllableQuickActionIngressStore(backing: backing)
        let broker = MoneyUpQuickActionRouteBroker(ingressStore: failingStore)
        let token = UUID()
        XCTAssertTrue(broker.submit(.refund, token: token))
        let model = fixture.model(
            lockedCaptureStore: inbox,
            quickActionRouteBroker: broker
        )
        model.state = .locked
        UserDefaults.standard.set(
            true,
            forKey: AppModel.lockedQuickCapturePreferenceKey
        )
        XCTAssertEqual(
            MoneyUpQuickActionRouting.routeNext(from: broker, into: model),
            .routed
        )
        let request = try XCTUnwrap(model.requestedQuickLogRequest)
        failingStore.failNextAcknowledgement()

        try await model.saveLockedCapture(
            request: request,
            amountText: "7",
            payee: "Return",
            note: "Committed before failed ack"
        )
        XCTAssertTrue(broker.isAuthoritativeBoundaryActive)
        XCTAssertFalse(broker.isAuthoritativeLifecycleBoundaryActive)
        model.consumeQuickLogRequest(request)
        XCTAssertNil(model.requestedQuickLogRequest)

        // The failed durable removal leaves the exact token eligible for an
        // at-least-once navigation replay, but its stable capture ID makes the
        // financial inbox append idempotent.
        let replayBroker = durableBroker(at: ingress.fileURL)
        XCTAssertEqual(replayBroker.pendingCount, 1)
        let replayModel = fixture.model(
            lockedCaptureStore: inbox,
            quickActionRouteBroker: replayBroker
        )
        replayModel.state = .locked
        XCTAssertEqual(
            MoneyUpQuickActionRouting.routeNext(
                from: replayBroker,
                into: replayModel
            ),
            .routed
        )
        let replay = try XCTUnwrap(replayModel.requestedQuickLogRequest)
        let resumed = try await replayModel.resumeCommittedLockedCaptureIfPresent(
            request: replay
        )
        XCTAssertTrue(resumed)
        replayModel.consumeQuickLogRequest(replay)
        let captures = try await inbox.all()
        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures.first?.id, token)
        XCTAssertEqual(captures.first?.amountText, "7")
        await fixture.store.close()
    }

    @MainActor
    func testTransientReloadFailurePreservesExactActiveDeliveryForRetry()
    throws {
        let ingress = try makeDurableIngressFixture()
        defer { try? FileManager.default.removeItem(at: ingress.directoryURL) }
        let backing = MoneyUpQuickActionIngressFileStore(fileURL: ingress.fileURL)
        let store = ControllableQuickActionIngressStore(backing: backing)
        let broker = MoneyUpQuickActionRouteBroker(ingressStore: store)
        let token = UUID()
        XCTAssertTrue(broker.submit(.transfer, token: token))
        XCTAssertEqual(broker.takePendingRecord()?.token, token)

        store.failLoads = true
        broker.reloadDurableIngress()
        XCTAssertTrue(broker.isAuthoritativeBoundaryActive)
        XCTAssertTrue(broker.ownsActiveDelivery(token: token))

        store.failLoads = false
        broker.reloadDurableIngress()
        XCTAssertFalse(broker.isAuthoritativeBoundaryActive)
        XCTAssertTrue(broker.ownsActiveDelivery(token: token))
        XCTAssertTrue(broker.acknowledge(token: token))
        XCTAssertEqual(durableBroker(at: ingress.fileURL).pendingCount, 0)
    }

    @MainActor
    func testAmbiguousAppendCommitIsConfirmedBeforeIntentSuccess() throws {
        let ingress = try makeDurableIngressFixture()
        defer { try? FileManager.default.removeItem(at: ingress.directoryURL) }
        let store = ControllableQuickActionIngressStore(
            backing: MoneyUpQuickActionIngressFileStore(fileURL: ingress.fileURL)
        )
        let broker = MoneyUpQuickActionRouteBroker(ingressStore: store)
        let token = UUID()
        store.commitNextAppendButReturnUnavailable = true

        XCTAssertTrue(broker.submit(.refund, token: token))

        let recreated = durableBroker(at: ingress.fileURL)
        let record = try XCTUnwrap(recreated.takePendingRecord())
        XCTAssertEqual(record.token, token)
        XCTAssertEqual(record.action, .refund)
        XCTAssertTrue(recreated.acknowledge(token: token))
    }

    @MainActor
    func testAmbiguousAckCommitConvergesOnlyInSameOpenAuthorityEpoch()
    throws {
        let ingress = try makeDurableIngressFixture()
        defer { try? FileManager.default.removeItem(at: ingress.directoryURL) }
        let store = ControllableQuickActionIngressStore(
            backing: MoneyUpQuickActionIngressFileStore(fileURL: ingress.fileURL)
        )
        let broker = MoneyUpQuickActionRouteBroker(ingressStore: store)
        let firstToken = UUID()
        let secondToken = UUID()
        XCTAssertTrue(broker.submit(.expense, token: firstToken))
        XCTAssertTrue(broker.submit(.income, token: secondToken))
        XCTAssertEqual(broker.takePendingRecord()?.token, firstToken)
        store.commitNextAcknowledgementButReturnUnavailable = true

        XCTAssertFalse(broker.acknowledge(token: firstToken))
        XCTAssertTrue(broker.ownsActiveDelivery(token: firstToken))
        broker.reloadDurableIngress()

        XCTAssertFalse(broker.ownsActiveDelivery(token: firstToken))
        XCTAssertTrue(broker.acknowledge(token: firstToken))
        XCTAssertEqual(broker.takePendingRecord()?.token, secondToken)
        XCTAssertTrue(broker.acknowledge(token: secondToken))
        XCTAssertEqual(durableBroker(at: ingress.fileURL).pendingCount, 0)
    }

    @MainActor
    func testAuthorityChangeCannotConvergeAnOldActiveAcknowledgement()
    throws {
        let ingress = try makeDurableIngressFixture()
        defer { try? FileManager.default.removeItem(at: ingress.directoryURL) }
        let broker = durableBroker(at: ingress.fileURL)
        let token = UUID()
        XCTAssertTrue(broker.submit(.transfer, token: token))
        XCTAssertEqual(broker.takePendingRecord()?.token, token)
        let authority = MoneyUpQuickActionIngressFileStore(
            fileURL: ingress.fileURL
        )
        XCTAssertTrue(authority.invalidateAndClose().didApply)
        XCTAssertTrue(authority.reopenEmpty().didApply)

        broker.reloadDurableIngress()

        XCTAssertFalse(broker.ownsActiveDelivery(token: token))
        XCTAssertFalse(broker.acknowledge(token: token))
        XCTAssertEqual(broker.pendingCount, 0)

        let acknowledgedToken = UUID()
        XCTAssertTrue(broker.submit(.refund, token: acknowledgedToken))
        XCTAssertEqual(broker.takePendingRecord()?.token, acknowledgedToken)
        XCTAssertTrue(broker.acknowledge(token: acknowledgedToken))
        XCTAssertTrue(broker.acknowledge(token: acknowledgedToken))
        XCTAssertTrue(authority.invalidateAndClose().didApply)
        XCTAssertTrue(authority.reopenEmpty().didApply)
        broker.reloadDurableIngress()
        XCTAssertFalse(broker.acknowledge(token: acknowledgedToken))
    }

    @MainActor
    func testDurableIngressRejectsCorruptFutureAndOversizedPayloads() throws {
        let fixtures: [Data] = [
            Data("not-json".utf8),
            Data(
                """
                {"admission":"open","authorityToken":"\(UUID().uuidString)","records":[],"schemaVersion":2}
                """.utf8
            ),
            Data(
                """
                {"admission":"open","authorityToken":"\(UUID().uuidString)","records":[{"action":"expense","note":"must-not-cross","token":"\(UUID().uuidString)"}],"schemaVersion":1}
                """.utf8
            ),
            Data(
                """
                {"admission":"open","authorityToken":"\(UUID().uuidString)","records":[],"schemaVersion":1,"schemaVersion":1}
                """.utf8
            ),
            Data(
                repeating: 0x61,
                count: MoneyUpQuickActionIngressFileStore
                    .maximumPayloadByteCount + 1
            )
        ]

        for payload in fixtures {
            let fixture = try makeDurableIngressFixture()
            defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
            try payload.write(to: fixture.fileURL, options: .atomic)
            let broker = durableBroker(at: fixture.fileURL)
            XCTAssertTrue(broker.isAuthoritativeBoundaryActive)
            XCTAssertFalse(broker.submit(.transfer))
            XCTAssertEqual(broker.pendingCount, 0)
        }
    }

    @MainActor
    func testKnownDurableFileDisappearanceFailsClosedUntilRecovery() throws {
        let fixture = try makeDurableIngressFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        let broker = durableBroker(at: fixture.fileURL)
        XCTAssertTrue(broker.submit(.expense))
        let accepted = try XCTUnwrap(broker.takePendingRecord())
        XCTAssertTrue(broker.acknowledge(token: accepted.token))
        try FileManager.default.removeItem(at: fixture.fileURL)

        broker.reloadDurableIngress()

        XCTAssertTrue(broker.isAuthoritativeBoundaryActive)
        XCTAssertFalse(broker.submit(.income))
        XCTAssertTrue(
            broker.reopenDurableAdmissionAfterAuthoritativeRecovery()
        )
        XCTAssertTrue(broker.submit(.income))
    }

    @MainActor
    func testDurableRequestCannotClearWhenItsAckStoreBecomesUnreadable() throws {
        let fixture = try makeDurableIngressFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        let broker = durableBroker(at: fixture.fileURL)
        let model = AppModel(
            dataEraseIntent: .none,
            quickActionRouteBroker: broker
        )
        model.state = .ready
        XCTAssertTrue(broker.submit(.expense))
        XCTAssertEqual(
            MoneyUpQuickActionRouting.routeNext(from: broker, into: model),
            .routed
        )
        let request = try XCTUnwrap(model.requestedQuickLogRequest)
        XCTAssertTrue(request.requiresIngressAcknowledgement)
        try Data("corrupt-after-delivery".utf8).write(
            to: fixture.fileURL,
            options: .atomic
        )
        broker.reloadDurableIngress()

        model.consumeQuickLogRequest(request)

        XCTAssertEqual(model.requestedQuickLogRequest, request)
        XCTAssertTrue(broker.isAuthoritativeBoundaryActive)
        XCTAssertTrue(broker.ownsActiveDelivery(token: request.ingressToken))

        model.finishValidatedQuickActionIngressRecovery()

        XCTAssertNil(model.requestedQuickLogRequest)
        XCTAssertFalse(broker.isAuthoritativeBoundaryActive)
        XCTAssertTrue(broker.submit(.refund))
    }

    @MainActor
    func testSceneRetryOnlyAcknowledgesAnExplicitlyFailedConsume() throws {
        let fixture = try makeDurableIngressFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        let store = ControllableQuickActionIngressStore(
            backing: MoneyUpQuickActionIngressFileStore(
                fileURL: fixture.fileURL
            )
        )
        let broker = MoneyUpQuickActionRouteBroker(ingressStore: store)
        let model = AppModel(
            dataEraseIntent: .none,
            quickActionRouteBroker: broker
        )
        model.state = .ready
        XCTAssertTrue(broker.submit(.scanReceipt))
        XCTAssertEqual(
            MoneyUpQuickActionRouting.routeNext(from: broker, into: model),
            .routed
        )
        let request = try XCTUnwrap(model.requestedQuickLogRequest)
        XCTAssertTrue(model.presentQuickLogRequest(request))

        // Merely backgrounding an open editor is not an acknowledgement.
        model.retryPresentedQuickActionAcknowledgement()
        XCTAssertEqual(model.requestedQuickLogRequest, request)
        XCTAssertFalse(broker.needsAcknowledgementRetry(
            token: request.ingressToken
        ))
        XCTAssertTrue(broker.ownsActiveDelivery(token: request.ingressToken))

        store.failNextAcknowledgement()
        model.consumeQuickLogRequest(request)
        XCTAssertEqual(model.requestedQuickLogRequest, request)
        XCTAssertTrue(broker.needsAcknowledgementRetry(
            token: request.ingressToken
        ))

        model.retryPresentedQuickActionAcknowledgement()
        XCTAssertNil(model.requestedQuickLogRequest)
        XCTAssertFalse(broker.needsAcknowledgementRetry(
            token: request.ingressToken
        ))
        XCTAssertEqual(durableBroker(at: fixture.fileURL).pendingCount, 0)
    }

    @MainActor
    func testDurableCapacityRejectsNewestWithoutEvictingFIFO() throws {
        let fixture = try makeDurableIngressFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        let broker = durableBroker(at: fixture.fileURL)
        let accepted = (0..<MoneyUpQuickActionRouteBroker.maximumPendingActionCount)
            .map { index in
                (
                    MoneyUpQuickAction.allCases[
                        index % MoneyUpQuickAction.allCases.count
                    ],
                    UUID()
                )
            }
        for (action, token) in accepted {
            XCTAssertTrue(broker.submit(action, token: token))
        }
        XCTAssertFalse(broker.submit(.scanReceipt, token: UUID()))

        var recreated = durableBroker(at: fixture.fileURL)
        for (action, token) in accepted {
            let record = try XCTUnwrap(recreated.takePendingRecord())
            XCTAssertEqual(record.action, action)
            XCTAssertEqual(record.token, token)
            XCTAssertTrue(recreated.acknowledge(token: token))
        }
        recreated = durableBroker(at: fixture.fileURL)
        XCTAssertEqual(recreated.pendingCount, 0)
    }

    @MainActor
    func testSeparateStoresCoordinateConcurrentAppendsWithoutLostRecords()
    throws {
        let fixture = try makeDurableIngressFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        let records = (0..<12).map { index in
            MoneyUpQuickActionIngressRecord(
                token: UUID(),
                action: MoneyUpQuickAction.allCases[
                    index % MoneyUpQuickAction.allCases.count
                ]
            )
        }
        let epochStore = MoneyUpQuickActionIngressFileStore(
            fileURL: fixture.fileURL
        )
        let validatedStartup = MoneyUpQuickActionRouteBroker(
            ingressStore: epochStore
        )
        XCTAssertTrue(
            validatedStartup
                .reopenDurableAdmissionAfterAuthoritativeRecovery()
        )
        let authorityToken = try durableAuthorityToken(from: epochStore.load())
        let outcomes = ConcurrentMutationOutcomes()
        DispatchQueue.concurrentPerform(iterations: records.count) { index in
            let store = MoneyUpQuickActionIngressFileStore(
                fileURL: fixture.fileURL
            )
            outcomes.append(store.append(
                records[index],
                expectedAuthorityToken: authorityToken
            ).didApply)
        }

        XCTAssertEqual(outcomes.values.count, records.count)
        XCTAssertTrue(outcomes.values.allSatisfy { $0 })
        let broker = durableBroker(at: fixture.fileURL)
        var persistedTokens: Set<UUID> = []
        for _ in records.indices {
            guard let record = broker.takePendingRecord() else { break }
            persistedTokens.insert(record.token)
            XCTAssertTrue(broker.acknowledge(token: record.token))
        }
        XCTAssertEqual(persistedTokens, Set(records.map(\.token)))
        let resourceValues = try fixture.directoryURL.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        )
        XCTAssertEqual(resourceValues.isExcludedFromBackup, true)
    }

    @MainActor
    func testStaleProducerCannotAppendAcrossClosedAndReopenedEpoch() throws {
        let fixture = try makeDurableIngressFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        let backing = MoneyUpQuickActionIngressFileStore(
            fileURL: fixture.fileURL
        )
        let store = ControllableQuickActionIngressStore(backing: backing)
        let staleProducer = MoneyUpQuickActionRouteBroker(ingressStore: store)
        XCTAssertTrue(staleProducer.submit(.expense))
        let first = try XCTUnwrap(staleProducer.takePendingRecord())
        XCTAssertTrue(staleProducer.acknowledge(token: first.token))

        // The producer passes its local open-epoch guard. The injected store
        // then models another process closing and reopening authority before
        // this producer enters its coordinated read/modify/write section.
        store.rotateAuthorityBeforeNextAppend = true
        XCTAssertFalse(staleProducer.submit(.income))
        let recreated = durableBroker(at: fixture.fileURL)
        XCTAssertEqual(recreated.pendingCount, 0)
    }

    @MainActor
    func testDurableBoundaryStaysClosedAcrossCrashUntilValidatedRecovery() throws {
        let fixture = try makeDurableIngressFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        let oldProcess = durableBroker(at: fixture.fileURL)
        XCTAssertTrue(oldProcess.submit(.income))
        _ = try oldProcess.beginAuthoritativeBoundary()

        let extensionDuringBoundary = durableBroker(at: fixture.fileURL)
        XCTAssertTrue(extensionDuringBoundary.isAuthoritativeBoundaryActive)
        XCTAssertFalse(extensionDuringBoundary.submit(.expense))

        // Simulate process death without balancing the in-memory epoch.
        let recoveryProcess = durableBroker(at: fixture.fileURL)
        XCTAssertTrue(recoveryProcess.isAuthoritativeBoundaryActive)
        XCTAssertFalse(recoveryProcess.submit(.refund))
        XCTAssertTrue(
            recoveryProcess
                .reopenDurableAdmissionAfterAuthoritativeRecovery()
        )

        let afterValidatedRecovery = durableBroker(at: fixture.fileURL)
        XCTAssertFalse(afterValidatedRecovery.isAuthoritativeBoundaryActive)
        XCTAssertEqual(afterValidatedRecovery.pendingCount, 0)
        XCTAssertTrue(afterValidatedRecovery.submit(.transfer))
    }

    @MainActor
    func testValidatedRecoveryPreservesConcurrentFirstAcceptedAction() throws {
        let fixture = try makeDurableIngressFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        let recoveringApp = durableBroker(at: fixture.fileURL)
        let extensionProcess = durableBroker(at: fixture.fileURL)
        let token = UUID()

        // Both processes observed absence. The extension wins the first
        // coordinated append while app startup is still validating its book.
        XCTAssertTrue(extensionProcess.submit(.income, token: token))
        XCTAssertTrue(
            recoveringApp.reopenDurableAdmissionAfterAuthoritativeRecovery()
        )

        let accepted = try XCTUnwrap(recoveringApp.takePendingRecord())
        XCTAssertEqual(accepted.token, token)
        XCTAssertEqual(accepted.action, .income)
        XCTAssertTrue(recoveringApp.acknowledge(token: token))
    }

    @MainActor
    func testLongLivedExtensionReloadsAfterValidatedBoundaryRecovery() throws {
        let fixture = try makeDurableIngressFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        let app = durableBroker(at: fixture.fileURL)
        XCTAssertTrue(app.reopenDurableAdmissionAfterAuthoritativeRecovery())
        let extensionProcess = durableBroker(at: fixture.fileURL)
        let quietExtensionProcess = durableBroker(at: fixture.fileURL)
        let epoch = try app.beginAuthoritativeBoundary()

        XCTAssertFalse(extensionProcess.submit(.expense))
        app.endAuthoritativeBoundary(epoch)
        XCTAssertFalse(app.submit(.income))
        XCTAssertTrue(app.reopenDurableAdmissionAfterAuthoritativeRecovery())

        let previouslyBlockedToken = UUID()
        let cachedOpenToken = UUID()
        XCTAssertTrue(extensionProcess.submit(
            .refund,
            token: previouslyBlockedToken
        ))
        XCTAssertTrue(quietExtensionProcess.submit(
            .transfer,
            token: cachedOpenToken
        ))
        let inspection = durableBroker(at: fixture.fileURL)
        XCTAssertEqual(inspection.pendingCount, 2)
        XCTAssertEqual(
            inspection.takePendingRecord()?.token,
            previouslyBlockedToken
        )
        XCTAssertTrue(inspection.acknowledge(token: previouslyBlockedToken))
        XCTAssertEqual(inspection.takePendingRecord()?.token, cachedOpenToken)
    }

    @MainActor
    func testBoundaryPersistenceFailureThrowsBeforeLifecycleMayProceed() {
        let broker = MoneyUpQuickActionRouteBroker(
            ingressStore: MoneyUpQuickActionIngressFileStore(fileURL: nil)
        )

        XCTAssertThrowsError(try broker.beginAuthoritativeBoundary())
        XCTAssertTrue(broker.isAuthoritativeBoundaryActive)
        XCTAssertFalse(broker.submit(.expense))
    }

    @MainActor
    func testCrashClosedIngressDoesNotHideLockedOrRecoveryState() {
        let broker = MoneyUpQuickActionRouteBroker(
            ingressStore: MoneyUpQuickActionIngressFileStore(fileURL: nil)
        )
        let model = AppModel(
            dataEraseIntent: .none,
            quickActionRouteBroker: broker
        )

        XCTAssertTrue(broker.isAuthoritativeBoundaryActive)
        XCTAssertFalse(broker.isAuthoritativeLifecycleBoundaryActive)
        model.finishCancelledAuthentication()
        XCTAssertEqual(model.state, .locked)
        XCTAssertFalse(model.canPresentLockedQuickCapture)

        model.finishFailedStartup(message: "Recoverable startup failure")
        XCTAssertEqual(model.state, .failed("Recoverable startup failure"))
        XCTAssertTrue(broker.isAuthoritativeBoundaryActive)
        XCTAssertFalse(broker.isAuthoritativeLifecycleBoundaryActive)
    }

    @MainActor
    func testValidatedRecoveryClearsOrphanedRequestAndAllowsNewRouting()
    throws {
        let ingress = try makeDurableIngressFixture()
        defer { try? FileManager.default.removeItem(at: ingress.directoryURL) }
        let broker = durableBroker(at: ingress.fileURL)
        let model = AppModel(
            dataEraseIntent: .none,
            quickActionRouteBroker: broker
        )
        model.state = .ready
        XCTAssertTrue(broker.submit(.smartEntry))
        XCTAssertEqual(
            MoneyUpQuickActionRouting.routeNext(from: broker, into: model),
            .routed
        )
        XCTAssertNotNil(model.requestedQuickLogRequest)

        let otherProcess = MoneyUpQuickActionIngressFileStore(
            fileURL: ingress.fileURL
        )
        XCTAssertTrue(otherProcess.invalidateAndClose().didApply)
        broker.reloadDurableIngress()
        XCTAssertTrue(broker.isAuthoritativeBoundaryActive)
        XCTAssertNotNil(model.requestedQuickLogRequest)

        model.finishValidatedQuickActionIngressRecovery()

        XCTAssertFalse(broker.isAuthoritativeBoundaryActive)
        XCTAssertNil(model.requestedQuickLogRequest)
        XCTAssertTrue(broker.submit(.income))
        XCTAssertEqual(
            MoneyUpQuickActionRouting.routeNext(from: broker, into: model),
            .routed
        )
        XCTAssertEqual(model.requestedQuickLogMode, .income)
    }

    @MainActor
    func testRestoreEntryDoesNotStrandStateWhenDurableCloseFails() {
        let broker = MoneyUpQuickActionRouteBroker(
            ingressStore: MoneyUpQuickActionIngressFileStore(fileURL: nil)
        )
        let model = AppModel(
            dataEraseIntent: .none,
            quickActionRouteBroker: broker
        )
        let originalRevision = model.logicalBookRevision

        XCTAssertThrowsError(try model.beginRestoreMutation())
        XCTAssertFalse(model.isBookReplacementInProgress)
        XCTAssertFalse(model.isWorking)
        XCTAssertFalse(model.goalMutationBarrierClosed)
        XCTAssertFalse(model.isLifecycleMutationInProgress)
        XCTAssertEqual(model.logicalBookRevision, originalRevision)
    }

    @MainActor
    func testKeyCliffEntryDoesNotStrandStateWhenDurableCloseFails() async {
        let broker = MoneyUpQuickActionRouteBroker(
            ingressStore: MoneyUpQuickActionIngressFileStore(fileURL: nil)
        )
        let model = AppModel(
            dataEraseIntent: .none,
            quickActionRouteBroker: broker
        )
        model.startupFailureKind = .missingDeviceBoundKey
        model.state = .failed("test")
        let originalRevision = model.logicalBookRevision

        do {
            try await model.recoverMissingDeviceBoundKey(
                placeholderRestoreTicket(),
                password: "unused"
            )
            XCTFail("durable close failure must abort key replacement")
        } catch {
            XCTAssertTrue(error is MoneyUpQuickActionIngressError)
        }
        XCTAssertFalse(model.isBookReplacementInProgress)
        XCTAssertFalse(model.isWorking)
        XCTAssertFalse(model.goalMutationBarrierClosed)
        XCTAssertFalse(model.isLifecycleMutationInProgress)
        XCTAssertEqual(model.logicalBookRevision, originalRevision)
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

private struct DurableIngressFixture: Sendable {
    let directoryURL: URL
    let fileURL: URL
}

private func makeDurableIngressFixture() throws -> DurableIngressFixture {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("MoneyUpQuickActionTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true
    )
    return DurableIngressFixture(
        directoryURL: directoryURL,
        fileURL: directoryURL.appendingPathComponent(
            MoneyUpQuickActionIngressFileStore.fileName
        )
    )
}

private func durableAuthorityToken(
    from load: MoneyUpQuickActionIngressLoad
) throws -> UUID {
    guard case let .available(snapshot) = load else {
        throw MoneyUpQuickActionIngressError.unavailable
    }
    return try XCTUnwrap(snapshot.authorityToken)
}

@MainActor
private func durableBroker(at fileURL: URL) -> MoneyUpQuickActionRouteBroker {
    MoneyUpQuickActionRouteBroker(
        ingressStore: MoneyUpQuickActionIngressFileStore(fileURL: fileURL)
    )
}

private func placeholderRestoreTicket() -> RestorePreviewTicket {
    let summary = RestorePreview.BookSummary(
        storedRecordCounts: [:],
        entryDateSpan: nil,
        currencies: [],
        quarantinedRecordCount: 0,
        reportingTimeZoneIdentifier: "GMT"
    )
    return RestorePreviewTicket(
        preview: RestorePreview(
            archiveFormatVersion: 2,
            archiveSchemaVersion: 7,
            current: summary,
            candidate: summary
        ),
        stagedArchiveURL: URL(fileURLWithPath: "/unused"),
        archiveFingerprint: RestoreArchiveFingerprint(
            byteCount: 0,
            sha256: Data()
        )
    )
}

private actor DurableActionLockedCaptureStore: LockedCaptureStoring {
    private var captures: [LockedCapture] = []

    func all() async throws -> [LockedCapture] {
        captures
    }

    @discardableResult
    func append(_ capture: LockedCapture) async throws -> Int {
        captures = try LockedCaptureStore.queueByAppending(
            capture,
            to: captures
        )
        return captures.count
    }

    @discardableResult
    func remove(id: UUID) async throws -> Int {
        captures.removeAll { $0.id == id }
        return captures.count
    }

    func eraseAll() async throws {
        captures.removeAll(keepingCapacity: false)
    }
}

private final class ControllableQuickActionIngressStore:
    MoneyUpQuickActionIngressStoring {
    private let backing: MoneyUpQuickActionIngressFileStore
    var failLoads = false
    var rotateAuthorityBeforeNextAppend = false
    var commitNextAppendButReturnUnavailable = false
    var commitNextAcknowledgementButReturnUnavailable = false
    private var acknowledgementFailuresRemaining = 0

    init(backing: MoneyUpQuickActionIngressFileStore) {
        self.backing = backing
    }

    func failNextAcknowledgement() {
        acknowledgementFailuresRemaining += 1
    }

    func load() -> MoneyUpQuickActionIngressLoad {
        failLoads ? .unavailable : backing.load()
    }

    func append(
        _ record: MoneyUpQuickActionIngressRecord,
        expectedAuthorityToken: UUID?
    ) -> MoneyUpQuickActionIngressMutation {
        if commitNextAppendButReturnUnavailable {
            commitNextAppendButReturnUnavailable = false
            let committed = backing.append(
                record,
                expectedAuthorityToken: expectedAuthorityToken
            )
            guard committed.didApply else { return committed }
            return MoneyUpQuickActionIngressMutation(
                didApply: false,
                load: .unavailable
            )
        }
        if rotateAuthorityBeforeNextAppend {
            rotateAuthorityBeforeNextAppend = false
            guard backing.invalidateAndClose().didApply,
                  backing.reopenEmpty().didApply else {
                return MoneyUpQuickActionIngressMutation(
                    didApply: false,
                    load: .unavailable
                )
            }
        }
        return backing.append(
            record,
            expectedAuthorityToken: expectedAuthorityToken
        )
    }

    func acknowledge(
        token: UUID,
        expectedAuthorityToken: UUID
    ) -> MoneyUpQuickActionIngressMutation {
        if commitNextAcknowledgementButReturnUnavailable {
            commitNextAcknowledgementButReturnUnavailable = false
            let committed = backing.acknowledge(
                token: token,
                expectedAuthorityToken: expectedAuthorityToken
            )
            guard committed.didApply else { return committed }
            return MoneyUpQuickActionIngressMutation(
                didApply: false,
                load: .unavailable
            )
        }
        guard acknowledgementFailuresRemaining > 0 else {
            return backing.acknowledge(
                token: token,
                expectedAuthorityToken: expectedAuthorityToken
            )
        }
        acknowledgementFailuresRemaining -= 1
        return MoneyUpQuickActionIngressMutation(
            didApply: false,
            load: .unavailable
        )
    }

    func invalidateAndClose() -> MoneyUpQuickActionIngressMutation {
        backing.invalidateAndClose()
    }

    func reopenEmpty() -> MoneyUpQuickActionIngressMutation {
        backing.reopenEmpty()
    }

    func recoverOpenAfterValidatedLifecycle()
        -> MoneyUpQuickActionIngressMutation {
        backing.recoverOpenAfterValidatedLifecycle()
    }
}

private final class ConcurrentMutationOutcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Bool] = []

    var values: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }

    func append(_ value: Bool) {
        lock.lock()
        storedValues.append(value)
        lock.unlock()
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
