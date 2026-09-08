import Foundation

struct CloudBackupHTTPResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let data: Data
}

protocol CloudBackupHTTPTransporting: Sendable {
    func execute(_ request: URLRequest, maximumResponseBytes: Int) async throws -> CloudBackupHTTPResponse
}

/// The sole reviewed network boundary. No redirects, cookie jar, shared
/// credentials, cache, analytics, URL logging, or weakening of TLS validation.
final class CloudBackupHTTPTransport: NSObject, CloudBackupHTTPTransporting,
    URLSessionTaskDelegate, @unchecked Sendable {
    func execute(_ request: URLRequest, maximumResponseBytes: Int) async throws -> CloudBackupHTTPResponse {
        guard let url = request.url, CloudBackupConfiguration.isSecureURL(url),
              url.host == "api.apple-cloudkit.com" || CloudBackupConfiguration.isAppleAssetURL(url),
              maximumResponseBytes > 0,
              maximumResponseBytes <= CloudBackupManifest.chunkByteCount else {
            throw CloudBackupError.invalidResponse
        }
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse,
                  response.url == request.url,
                  response.expectedContentLength <= Int64(maximumResponseBytes) else {
                throw CloudBackupError.invalidResponse
            }
            var data = Data()
            data.reserveCapacity(min(maximumResponseBytes, max(0, Int(response.expectedContentLength))))
            for try await byte in bytes {
                if data.count.isMultiple(of: 65_536) { try Task.checkCancellation() }
                guard data.count < maximumResponseBytes else { throw CloudBackupError.invalidResponse }
                data.append(byte)
            }
            var headers: [String: String] = [:]
            for (key, value) in response.allHeaderFields {
                if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
            }
            return CloudBackupHTTPResponse(status: response.statusCode, headers: headers, data: data)
        } catch is CancellationError { throw CancellationError() }
        catch let error as CloudBackupError { throw error }
        catch {
            try Task.checkCancellation()
            throw CloudBackupError.offline
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
