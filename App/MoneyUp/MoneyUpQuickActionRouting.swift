import Foundation

@MainActor
enum MoneyUpQuickActionRoutingResult: Equatable {
    case idle
    case deferred
    case discarded
    case routed
    case requiresStart
}

@MainActor
enum MoneyUpQuickActionRoutingDisposition: Equatable {
    case route
    case deferTransiently
    case denyAuthoritatively
}

extension AppModel {
    /// Erase and book-replacement authority wins before same-book busy-state
    /// deferral. A tombstone read failure is not evidence that the old book is
    /// still valid, so queued actions fail closed rather than crossing books.
    var quickActionRoutingDisposition: MoneyUpQuickActionRoutingDisposition {
        guard !quickActionRouteBroker.isAuthoritativeBoundaryActive,
              !goalMutationBarrierClosed else { return .denyAuthoritatively }
        do {
            guard try dataEraseIntent.isPending() == false else {
                return .denyAuthoritatively
            }
        } catch {
            return .denyAuthoritatively
        }
        guard !isBookReplacementInProgress,
              startupFailureKind != .missingDeviceBoundKey,
              (try? hasPendingKeyCliffRecoveryTransaction()) == false else {
            return .denyAuthoritatively
        }
        guard !isLifecycleMutationInProgress,
              !isWorking,
              !lockedCaptureWriteInProgress,
              requestedQuickLogMode == nil else { return .deferTransiently }
        return .route
    }
}

/// Routes at most one queued action into AppModel's single request slot.
/// Transient app work leaves FIFO state untouched. An authoritative lifecycle
/// boundary discards the complete old-book queue before any action is taken;
/// an authoritative denial discovered after dequeue discards the tail too.
@MainActor
enum MoneyUpQuickActionRouting {
    static func routeNext(
        from broker: MoneyUpQuickActionRouteBroker,
        into model: AppModel
    ) -> MoneyUpQuickActionRoutingResult {
        guard broker.pendingAction != nil else { return .idle }
        guard broker === model.quickActionRouteBroker else {
            broker.discardAllPendingActions()
            return .discarded
        }
        switch model.quickActionRoutingDisposition {
        case .denyAuthoritatively:
            broker.discardAllPendingActions()
            return .discarded
        case .deferTransiently:
            return .deferred
        case .route:
            break
        }
        guard let record = broker.takePendingRecord() else { return .idle }
        guard model.handleDeepLink(record.action.deepLink) else {
            broker.discardAllPendingActions()
            return .discarded
        }
        guard model.requestedQuickLogMode != nil,
              model.requestedQuickLogRequest?.ingressToken == record.token else {
            broker.discardAllPendingActions()
            return .discarded
        }
        guard model.state == .locked,
              !model.isLockSafeQuickCaptureRequested else { return .routed }
        return .requiresStart
    }
}
