import Foundation

extension AppModel {
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
