import CryptoKit
import Foundation
import MoneyUpPersistence

enum CloudBackupError: Error, Equatable, Sendable {
    case unavailable, invalidResponse, invalidCallback, reconnectRequired
    case accountChanged, busy, offline, quotaExceeded, missingBackup
    case damagedBackup, localStorage, recoveryPasswordRequired, requestRejected
    case retryLater(TimeInterval)
}

extension CloudBackupError: LocalizedError {
    var errorDescription: String? {
        let key: String = switch self {
        case .unavailable: "cloud.error.unavailable"
        case .invalidCallback: "cloud.error.connection"
        case .invalidResponse: "cloud.error.response"
        case .requestRejected: "cloud.error.request_rejected"
        case .reconnectRequired: "cloud.error.reconnect"
        case .accountChanged: "cloud.error.account_changed"
        case .busy: "cloud.error.busy"
        case .offline, .retryLater: "cloud.error.retry"
        case .quotaExceeded: "cloud.error.quota"
        case .missingBackup: "cloud.error.missing"
        case .damagedBackup: "cloud.error.damaged"
        case .localStorage: "cloud.error.local_storage"
        case .recoveryPasswordRequired: "cloud.error.password"
        }
        return AppLocalization.string(key)
    }
}

struct CloudBackupConfiguration: Equatable, Sendable {
    enum Environment: String, Sendable { case development, production }
    let container: String
    let environment: Environment
    let apiToken: String
    let callbackURL: URL
    let isInternalBeta: Bool

    init(container: String, environment: Environment, apiToken: String, callbackURL: URL,
        isInternalBeta: Bool = false) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard !isInternalBeta || environment == .production,
              container.hasPrefix("iCloud."), container.utf8.count <= 255,
              container.unicodeScalars.allSatisfy(allowed.contains),
              !apiToken.isEmpty, apiToken.utf8.count <= 4_096,
              Self.isSecureURL(callbackURL), !callbackURL.path.isEmpty,
              callbackURL.query == nil, callbackURL.fragment == nil else {
            throw CloudBackupError.unavailable
        }
        self.container = container
        self.environment = environment
        self.apiToken = apiToken
        self.callbackURL = callbackURL
        self.isInternalBeta = isInternalBeta
    }

    var identity: String {
        CloudBackupManifest.digest(Data("\(container)/\(environment.rawValue)/\(callbackURL.absoluteString)".utf8))
    }

    static func bundled(_ bundle: Bundle = .main) -> Self? {
        guard bundle.object(forInfoDictionaryKey: "MoneyUpCloudBackupEnabled") as? Bool == true,
              let container = bundle.object(forInfoDictionaryKey: "MoneyUpCloudContainer") as? String,
              let rawEnvironment = bundle.object(forInfoDictionaryKey: "MoneyUpCloudEnvironment") as? String,
              let environment = Environment(rawValue: rawEnvironment),
              let apiToken = bundle.object(forInfoDictionaryKey: "MoneyUpCloudAPIToken") as? String,
              let rawCallback = bundle.object(forInfoDictionaryKey: "MoneyUpCloudCallbackURL") as? String,
              let callbackURL = URL(string: rawCallback) else { return nil }
        let channel = bundle.object(forInfoDictionaryKey: "MoneyUpCloudBackupReleaseChannel") as? String ?? "validated"
        guard ["validated", "internal-beta"].contains(channel) else { return nil }
        guard channel != "internal-beta"
                || bundle.object(forInfoDictionaryKey: "MoneyUpCloudBackupDeviceValidationPending") as? Bool == true else { return nil }
        return try? Self(container: container, environment: environment,
            apiToken: apiToken, callbackURL: callbackURL, isInternalBeta: channel == "internal-beta")
    }

    static func isSecureURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false
            && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443)
    }

    static func isAppleSignInURL(_ url: URL) -> Bool {
        guard isSecureURL(url), let host = url.host?.lowercased() else { return false }
        return ["apple.com", "icloud.com", "apple-cloudkit.com"].contains {
            host == $0 || host.hasSuffix("." + $0)
        }
    }

    static func isAppleAssetURL(_ url: URL) -> Bool {
        guard isSecureURL(url), let host = url.host?.lowercased() else { return false }
        return ["icloud-content.com", "icloud.com", "apple-cloudkit.com"].contains {
            host == $0 || host.hasSuffix("." + $0)
        }
    }

    func token(from callback: URL) throws -> String {
        guard Self.isSecureURL(callback), callback.host == callbackURL.host,
              callback.path == callbackURL.path, callback.fragment == nil,
              let components = URLComponents(url: callback, resolvingAgainstBaseURL: false) else {
            throw CloudBackupError.invalidCallback
        }
        let tokens = components.queryItems?.filter { $0.name == "ckWebAuthToken" } ?? []
        guard tokens.count == 1, let token = tokens.first?.value,
              !token.isEmpty, token.utf8.count <= CloudBackupAccount.maximumTokenBytes else {
            throw CloudBackupError.invalidCallback
        }
        return token
    }
}

struct CloudBackupAccount: Codable, Equatable, Sendable {
    static let maximumTokenBytes = 32_768
    var connectionID = UUID()
    let configurationID: String
    let userRecordName: String
    var webToken: String
    var label: String = ""
    var bookID: UUID?
    var recoveryPassword: String?
    var recoveryContextID: UUID?
    var automaticEnabled = false
    var consentRevision: UInt64 = 0
    var lastSuccessfulBackup: Date?

    var isValid: Bool {
        configurationID.count == 64 && !userRecordName.isEmpty && userRecordName.utf8.count <= 512
            && webToken.utf8.count <= Self.maximumTokenBytes && label.utf8.count <= 256
            && (recoveryPassword?.utf8.count ?? 0) <= PortableArchive.maximumPasswordByteCount
            && (!automaticEnabled || (bookID != nil && recoveryContextID != nil && (recoveryPassword?.count ?? 0) >= 10))
    }
}

struct CloudBackupBookIdentity: Codable, Equatable, Sendable {
    static let recordID = "current"
    let id: UUID
}

/// Only opaque identity, ciphertext integrity, size, and time leave the device
/// outside the already encrypted portable archive.
struct CloudBackupManifest: Codable, Equatable, Identifiable, Sendable {
    static let chunkByteCount = 8 * 1_024 * 1_024
    static let maximumChunkCount = (PortableArchive.maximumArchiveByteCount + chunkByteCount - 1) / chunkByteCount
    struct Chunk: Codable, Equatable, Sendable {
        let byteCount: Int
        let sha256: String
    }
    let version: Int
    let id: UUID
    let bookID: UUID
    let createdAt: Date
    let byteCount: Int
    let sha256: String
    let chunks: [Chunk]

    var recordName: String { "backup-" + id.uuidString.lowercased() }
    func chunkRecordName(_ index: Int) -> String { recordName + "-chunk-\(index)" }

    func validate() throws {
        guard version == 1, byteCount > 0,
              PortableArchive.isWithinArchiveByteLimit(byteCount),
              !chunks.isEmpty, chunks.count <= Self.maximumChunkCount,
              chunks.count == (byteCount + Self.chunkByteCount - 1) / Self.chunkByteCount,
              createdAt.timeIntervalSince1970.isFinite,
              abs(createdAt.timeIntervalSince1970) < 10_000_000_000,
              Self.isDigest(sha256) else { throw CloudBackupError.damagedBackup }
        var total = 0
        for (index, chunk) in chunks.enumerated() {
            let expected = min(Self.chunkByteCount, byteCount - total)
            guard chunk.byteCount == expected, Self.isDigest(chunk.sha256),
                  index == chunks.count - 1 || expected == Self.chunkByteCount else {
                throw CloudBackupError.damagedBackup
            }
            total += chunk.byteCount
        }
        guard total == byteCount else { throw CloudBackupError.damagedBackup }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
