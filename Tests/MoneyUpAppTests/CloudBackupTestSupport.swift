import Foundation
@testable import MoneyUp

actor TestCloudBackupVault: CloudBackupVault {
    var account: CloudBackupAccount?
    var failRotation = false
    init(_ account: CloudBackupAccount? = nil) { self.account = account }
    func load() -> CloudBackupAccount? { account }
    func save(_ account: CloudBackupAccount) { self.account = account }
    func clear() { account = nil }
    func pauseAutomatic() { account?.automaticEnabled = false; account?.consentRevision &+= 1 }
    func enableBackup(connectionID: UUID, consentRevision: UInt64, bookID: UUID,
        password: String, recoveryContextID: UUID) throws -> CloudBackupAccount {
        guard var value = account, value.connectionID == connectionID,
              value.consentRevision == consentRevision else { throw CloudBackupError.accountChanged }
        value.bookID = bookID
        value.recoveryPassword = password
        value.recoveryContextID = recoveryContextID
        value.automaticEnabled = true
        account = value
        return value
    }
    func recordSuccess(_ date: Date, connectionID: UUID, bookID: UUID,
        recoveryContextID: UUID) throws -> CloudBackupAccount {
        guard var value = account, value.connectionID == connectionID, value.bookID == bookID,
              value.recoveryContextID == recoveryContextID else { throw CloudBackupError.accountChanged }
        value.lastSuccessfulBackup = date
        account = value
        return value
    }
    func setRotationFailure() { failRotation = true }
    func rotateToken(_ token: String, connectionID: UUID) throws {
        guard !failRotation else { throw CloudBackupError.localStorage }
        guard account?.connectionID == connectionID else { throw CloudBackupError.accountChanged }
        account?.webToken = token
    }
}

@MainActor
struct TestCloudBackupSignIn: CloudBackupAuthenticating {
    let token: String?
    func authenticate(at url: URL, configuration: CloudBackupConfiguration) throws -> String {
        guard let token else { throw CancellationError() }
        return token
    }
}

/// In-memory implementation of the documented wire protocol. It rotates each
/// session token and keeps separate stores for separate signed-in users.
actor TestCloudBackupServer: CloudBackupHTTPTransporting {
    typealias JSON = CloudBackupJSON
    private var tokens: [String: String] = ["token-A": "user-A", "token-B": "user-B"]
    private var records: [String: [String: JSON]] = [:]
    private var assets: [String: Data] = [:]
    private var sequence = 0
    private var requests: [URLRequest] = []
    private var failChunk: Int?
    private var corruptDownloads = false
    private var quotaExceeded = false
    private var modifyError: String?

    func capturedRequests() -> [URLRequest] { requests }
    func setFailChunk(_ index: Int?) { failChunk = index }
    func setCorruptDownloads(_ value: Bool = true) { corruptDownloads = value }
    func setQuotaExceeded() { quotaExceeded = true }
    func setModifyError(_ code: String?) { modifyError = code }
    func expireSessions() { tokens = [:] }
    func manifestCount(for user: String) -> Int {
        (records[user] ?? [:]).values.filter { $0["recordType"].string == "MoneyUpBackup" }.count
    }
    func recordCount(for user: String) -> Int { records[user]?.count ?? 0 }

    func execute(_ request: URLRequest, maximumResponseBytes: Int) throws -> CloudBackupHTTPResponse {
        try Task.checkCancellation()
        requests.append(request)
        guard let url = request.url else { throw CloudBackupError.invalidResponse }
        if url.host == "upload.icloud-content.com" {
            let key = url.path
            if let failChunk, key.hasSuffix("-chunk-\(failChunk)") { throw CloudBackupError.offline }
            let bytes = request.httpBody ?? Data()
            assets[key] = bytes
            return try response(.object(["singleFile": .object([
                "size": .integer(Int64(bytes.count)), "fileChecksum": .string(CloudBackupManifest.digest(bytes)),
                "wrappingKey": .string("synthetic"), "receipt": .string(key), "referenceChecksum": .string("synthetic")])]))
        }
        if url.host == "download.icloud-content.com" {
            guard var bytes = assets[url.path] else { throw CloudBackupError.missingBackup }
            if corruptDownloads, !bytes.isEmpty { bytes[0] ^= 1 }
            return CloudBackupHTTPResponse(status: 200, headers: [:], data: bytes)
        }
        guard url.host == "api.apple-cloudkit.com", url.path.contains("/private/") else {
            throw CloudBackupError.invalidResponse
        }
        guard request.value(forHTTPHeaderField: "Origin") == "https://moneyup.example" else {
            return try response(.object(["serverErrorCode": .string("AUTHENTICATION_FAILED")]), status: 401)
        }
        let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "ckWebAuthToken" }?.value
        guard let token, let user = tokens.removeValue(forKey: token) else {
            return try response(.object(["serverErrorCode": .string("AUTHENTICATION_REQUIRED"),
                "redirectURL": .string("https://idmsa.apple.com/IDMSWebAuth/auth")]), status: 421)
        }
        sequence += 1
        let nextToken = "rotated-\(sequence)-\(user)"
        tokens[nextToken] = user
        let headers = ["x-apple-cloudkit-web-auth-token": nextToken]
        if url.path.hasSuffix("/users/current") {
            return try response(.object(["userRecordName": .string(user)]), headers: headers)
        }
        let payload = try JSONDecoder().decode(JSON.self, from: request.httpBody ?? Data())
        if quotaExceeded { return try response(.object(["serverErrorCode": .string("QUOTA_EXCEEDED")]), headers: headers) }
        if url.path.hasSuffix("/records/lookup") {
            let result = (payload["records"].array ?? []).map { item in
                let name = item["recordName"].string ?? ""
                return records[user]?[name] ?? .object(["recordName": .string(name), "serverErrorCode": .string("NOT_FOUND")])
            }
            return try response(.object(["records": .array(result)]), headers: headers)
        }
        if url.path.hasSuffix("/assets/upload") {
            let output = (payload["tokens"].array ?? []).map { token in
                let name = token["recordName"].string ?? ""
                return JSON.object(["recordName": .string(name), "fieldName": token["fieldName"],
                    "url": .string("https://upload.icloud-content.com/\(user)/\(name)")])
            }
            return try response(.object(["tokens": .array(output)]), headers: headers)
        }
        if url.path.hasSuffix("/records/modify") {
            return try modify(payload, user: user, headers: headers)
        }
        if url.path.hasSuffix("/records/query") {
            let matching = (records[user] ?? [:]).values.filter {
                $0["recordType"].string == payload["query"]["recordType"].string
            }.sorted { ($0["fields"]["createdAt"]["value"].integer ?? 0) > ($1["fields"]["createdAt"]["value"].integer ?? 0) }
            let start = Int(payload["continuationMarker"].string ?? "0") ?? 0
            let page = Array(matching.dropFirst(start).prefix(50))
            var result: [String: JSON] = ["records": .array(page)]
            if start + page.count < matching.count { result["continuationMarker"] = .string(String(start + page.count)) }
            return try response(.object(result), headers: headers)
        }
        throw CloudBackupError.invalidResponse
    }

    private func modify(_ payload: JSON, user: String, headers: [String: String]) throws -> CloudBackupHTTPResponse {
        if let modifyError {
            return try response(.object(["serverErrorCode": .string(modifyError),
                "reason": .string("Private server detail must never reach the UI")]), status: 400, headers: headers)
        }
        // CloudKit's wire types differ from schema types. In particular, ASSET
        // is rejected before saving; upload receipts omit type or use ASSETID.
        let wireTypes: Set<String> = ["STRING", "INT64", "DOUBLE", "TIMESTAMP", "REFERENCE", "ASSETID", "LOCATION", "BYTES"]
        for operation in payload["operations"].array ?? [] {
            for field in operation["record"]["fields"].object?.values ?? [:].values {
                if let type = field["type"].string, !wireTypes.contains(type) {
                    return try response(.object(["serverErrorCode": .string("BAD_REQUEST"),
                        "reason": .string("BadRequestException: Unexpected input")]), status: 400, headers: headers)
                }
            }
        }
        var output: [JSON] = []
        for operation in payload["operations"].array ?? [] {
            var record = operation["record"].object ?? [:]
            let name = record["recordName"]?.string ?? ""
            if operation["operationType"].string == "delete" {
                records[user]?[name] = nil
                output.append(.object(["recordName": .string(name), "deleted": .bool(true)]))
                continue
            }
            if records[user]?[name] != nil {
                output.append(.object(["recordName": .string(name), "serverErrorCode": .string("EXISTS")]))
                continue
            }
            var fields = record["fields"]?.object ?? [:]
            if let asset = fields["payload"]?["value"].object {
                var stored = asset
                stored["downloadURL"] = .string("https://download.icloud-content.com/\(user)/\(name)")
                fields["payload"] = .field(.object(stored), type: "ASSETID")
            }
            record["fields"] = .object(fields)
            record["recordChangeTag"] = .string("change-\(sequence)")
            records[user, default: [:]][name] = .object(record)
            output.append(.object(record))
        }
        return try response(.object(["records": .array(output)]), headers: headers)
    }

    private func response(_ json: JSON, status: Int = 200, headers: [String: String] = [:]) throws -> CloudBackupHTTPResponse {
        CloudBackupHTTPResponse(status: status, headers: headers, data: try JSONEncoder().encode(json))
    }
}

func cloudBackupTestConfiguration() throws -> CloudBackupConfiguration {
    guard let callback = URL(string: "https://moneyup.example/auth/icloud/callback") else { throw CloudBackupError.unavailable }
    return try CloudBackupConfiguration(container: "iCloud.com.laiwenkang.MoneyUp",
        environment: .development, apiToken: "synthetic-api", callbackURL: callback)
}
