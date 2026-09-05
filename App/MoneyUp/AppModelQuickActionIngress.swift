import Foundation

extension AppModel {
    /// A process can die after the redacted inbox append but before the UI
    /// delivery is durably acknowledged. The ingress token is also the inbox
    /// append's idempotency key, so a recreated view recognizes the committed
    /// capture and never enables a second form for that delivery.
    func resumeCommittedLockedCaptureIfPresent(
        request: QuickLogRouteRequest
    ) async throws -> Bool {
        guard request.requiresIngressAcknowledgement,
              requestedQuickLogRequest == request,
              state == .locked,
              canPresentLockedQuickCapture else { return false }
        let captures = try await lockedCaptureStore.all()
        guard requestedQuickLogRequest == request,
              state == .locked,
              canPresentLockedQuickCapture else {
            throw AppModelError.locked
        }
        pendingLockedCaptureCount = captures.count
        guard captures.contains(where: {
            $0.id == request.ingressToken
        }) else { return false }
        guard quickActionRouteBroker.acknowledge(
            token: request.ingressToken,
            allowingCommittedCaptureReplay: true
        ) else {
            throw MoneyUpQuickActionIngressError.unavailable
        }
        return true
    }

    /// Scene activation retries a previously presented request whose exact
    /// durable acknowledgement hit a transient coordination/protection error.
    func retryPresentedQuickActionAcknowledgement() {
        guard let request = requestedQuickLogRequest,
              request.requiresIngressAcknowledgement,
              quickActionRouteBroker.needsAcknowledgementRetry(
                  token: request.ingressToken
              ),
              presentedQuickLogRequest == request else { return }
        consumeQuickLogRequest(request)
    }

}
