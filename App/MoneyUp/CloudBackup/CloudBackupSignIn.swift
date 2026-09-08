import AuthenticationServices
import Foundation
import UIKit

@MainActor
protocol CloudBackupAuthenticating {
    func authenticate(at url: URL, configuration: CloudBackupConfiguration) async throws -> String
}

@MainActor
final class CloudBackupSignIn: NSObject, ASWebAuthenticationPresentationContextProviding, CloudBackupAuthenticating {
    weak var anchor: ASPresentationAnchor?
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?

    func authenticate(at url: URL, configuration: CloudBackupConfiguration) async throws -> String {
        guard CloudBackupConfiguration.isAppleSignInURL(url), session == nil,
              anchor != nil, let host = configuration.callbackURL.host else {
            throw CloudBackupError.unavailable
        }
        let callback: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let session = ASWebAuthenticationSession(url: url,
                    callback: .https(host: host, path: configuration.callbackURL.path)) { [weak self] url, error in
                    Task { @MainActor in
                        guard let self else { return }
                        if let url { self.finish(.success(url)) }
                        else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                            self.finish(.failure(CancellationError()))
                        } else { self.finish(.failure(CloudBackupError.invalidCallback)) }
                    }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = true
                self.session = session
                if !session.start() { finish(.failure(CloudBackupError.unavailable)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
        try Task.checkCancellation()
        return try configuration.token(from: callback)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? ASPresentationAnchor()
    }

    func cancel() {
        session?.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<URL, Error>) {
        let pending = continuation
        continuation = nil
        session = nil
        pending?.resume(with: result)
    }
}
