import Foundation

actor CloudKitWebClient {
    typealias JSON = CloudBackupJSON
    enum Operation: String { case currentUser = "users/current", lookup = "records/lookup"
        case query = "records/query", modify = "records/modify", assetUpload = "assets/upload" }
    let configuration: CloudBackupConfiguration
    let transport: any CloudBackupHTTPTransporting
    private var webToken: String?
    private let expectedUser: String?
    private let persistToken: (@Sendable (String) async throws -> Void)?
    private var requestInProgress = false

    init(configuration: CloudBackupConfiguration, transport: any CloudBackupHTTPTransporting,
        webToken: String? = nil, expectedUser: String? = nil,
        persistToken: (@Sendable (String) async throws -> Void)? = nil) {
        self.configuration = configuration
        self.transport = transport
        self.webToken = webToken
        self.expectedUser = expectedUser
        self.persistToken = persistToken
    }

    func signInURL() async throws -> URL {
        guard webToken == nil else { throw CloudBackupError.busy }
        let response = try await request(.currentUser, allowsSignInResponse: true)
        guard response["serverErrorCode"].string == "AUTHENTICATION_REQUIRED",
              let rawURL = response["redirectURL"].string,
              let url = URL(string: rawURL), CloudBackupConfiguration.isAppleSignInURL(url) else {
            throw CloudBackupError.invalidResponse
        }
        return url
    }

    func verifiedAccount() async throws -> CloudBackupAccount {
        guard webToken?.isEmpty == false else { throw CloudBackupError.reconnectRequired }
        let result = try await request(.currentUser)
        guard let user = result["userRecordName"].string, !user.isEmpty, user.utf8.count <= 512,
              let webToken else { throw CloudBackupError.invalidResponse }
        if let expectedUser, user != expectedUser { throw CloudBackupError.accountChanged }
        return CloudBackupAccount(configurationID: configuration.identity,
            userRecordName: user, webToken: webToken)
    }

    func listBackups(continuation: String? = nil) async throws -> (backups: [CloudBackupManifest], continuation: String?) {
        _ = try await verifiedAccount()
        var payload: [String: JSON] = [
            "query": .object(["recordType": .string("MoneyUpBackup"), "sortBy": .array([
                .object(["fieldName": .string("createdAt"), "ascending": .bool(false)])])]),
            "resultsLimit": .integer(50)]
        if let continuation {
            guard continuation.utf8.count <= 32_768 else { throw CloudBackupError.invalidResponse }
            payload["continuationMarker"] = .string(continuation)
        }
        let result = try await request(.query, payload: .object(payload))
        guard let records = result["records"].array, records.count <= 50 else {
            throw CloudBackupError.invalidResponse
        }
        let backups = try records.map(Self.manifest(from:))
        guard Set(backups.map(\.id)).count == backups.count else { throw CloudBackupError.invalidResponse }
        return (backups, result["continuationMarker"].string)
    }

    func lookup(_ recordName: String) async throws -> JSON? {
        let result = try await request(.lookup,
            payload: .object(["records": .array([.object(["recordName": .string(recordName)])])]))
        guard let records = result["records"].array, records.count == 1,
              let record = records.first, record["recordName"].string == recordName else {
            throw CloudBackupError.invalidResponse
        }
        if record["serverErrorCode"].string == "NOT_FOUND" { return nil }
        try Self.checkError(record)
        return record
    }

    func create(recordName: String, recordType: String, fields: [String: JSON]) async throws {
        let record = JSON.object(["recordName": .string(recordName), "recordType": .string(recordType),
            "fields": .object(fields)])
        try await modify(.object(["operationType": .string("create"), "record": record]), recordName: recordName)
    }

    func modify(_ operation: JSON, recordName: String) async throws {
        let result = try await request(.modify, payload: .object(["operations": .array([operation])]))
        guard let records = result["records"].array, records.count == 1,
              let record = records.first, record["recordName"].string == recordName else {
            throw CloudBackupError.invalidResponse
        }
        try Self.checkError(record)
    }

    func uploadAsset(_ data: Data, recordName: String) async throws -> JSON {
        guard !data.isEmpty, data.count <= CloudBackupManifest.chunkByteCount else {
            throw CloudBackupError.damagedBackup
        }
        let result = try await request(.assetUpload, payload: .object(["tokens": .array([
            .object(["recordName": .string(recordName), "recordType": .string("MoneyUpBackupChunk"),
                "fieldName": .string("payload")])])]))
        guard let tokens = result["tokens"].array, tokens.count == 1, let token = tokens.first,
              token["recordName"].string == recordName, token["fieldName"].string == "payload",
              let rawURL = token["url"].string, let url = URL(string: rawURL),
              CloudBackupConfiguration.isAppleAssetURL(url) else { throw CloudBackupError.invalidResponse }
        var upload = URLRequest(url: url)
        upload.httpMethod = "POST"
        upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        upload.httpBody = data
        let response = try await transport.execute(upload, maximumResponseBytes: 1_048_576)
        guard (200..<300).contains(response.status) else { throw CloudBackupError.offline }
        let receipt = try JSONDecoder().decode(JSON.self, from: response.data)["singleFile"]
        guard receipt["size"].integer == Int64(data.count), receipt["fileChecksum"].string != nil,
              receipt["wrappingKey"].string != nil, receipt["receipt"].string != nil,
              receipt["referenceChecksum"].string != nil else { throw CloudBackupError.invalidResponse }
        return receipt
    }

    func downloadAsset(_ asset: JSON, expectedBytes: Int) async throws -> Data {
        guard asset["size"].integer == Int64(expectedBytes),
              let rawURL = asset["downloadURL"].string,
              let url = URL(string: rawURL), CloudBackupConfiguration.isAppleAssetURL(url) else {
            throw CloudBackupError.damagedBackup
        }
        let response = try await transport.execute(URLRequest(url: url), maximumResponseBytes: expectedBytes)
        guard (200..<300).contains(response.status), response.data.count == expectedBytes else {
            throw CloudBackupError.damagedBackup
        }
        return response.data
    }

    static func manifest(from record: JSON) throws -> CloudBackupManifest {
        try checkError(record)
        guard record["recordType"].string == "MoneyUpBackup",
              let encoded = record["fields"]["manifest"]["value"].string,
              encoded.utf8.count <= 32_768,
              let manifest = try? JSONDecoder().decode(CloudBackupManifest.self, from: Data(encoded.utf8)),
              record["recordName"].string == manifest.recordName else { throw CloudBackupError.damagedBackup }
        try manifest.validate()
        return manifest
    }

    private func request(_ operation: Operation, payload: JSON? = nil,
        allowsSignInResponse: Bool = false) async throws -> JSON {
        guard !requestInProgress else { throw CloudBackupError.busy }
        requestInProgress = true
        defer { requestInProgress = false }
        try Task.checkCancellation()
        let response = try await transport.execute(try makeRequest(operation, payload: payload),
            maximumResponseBytes: 2_097_152)
        // Apple's current CloudKit JS reads these two headers, in this order.
        // Persist rotation before exposing success or making another request.
        if webToken != nil,
           let next = response.headers["x-apple-cloudkit-web-auth-token"]
                ?? response.headers["x-apple-cloudkit-session"] {
            guard !next.isEmpty, next.utf8.count <= CloudBackupAccount.maximumTokenBytes else {
                throw CloudBackupError.invalidResponse
            }
            try await persistToken?(next)
            webToken = next
        }
        let json: JSON
        do { json = try JSONDecoder().decode(JSON.self, from: response.data) }
        catch { throw CloudBackupError.invalidResponse }
        if allowsSignInResponse, json["serverErrorCode"].string == "AUTHENTICATION_REQUIRED" { return json }
        try Self.checkError(json)
        guard (200..<300).contains(response.status) else {
            if response.status == 401 || response.status == 403 { throw CloudBackupError.reconnectRequired }
            throw CloudBackupError.offline
        }
        return json
    }

    private func makeRequest(_ operation: Operation, payload: JSON?) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.apple-cloudkit.com"
        components.path = "/database/1/\(configuration.container)/\(configuration.environment.rawValue)/private/\(operation.rawValue)"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let api = configuration.apiToken.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw CloudBackupError.unavailable
        }
        var query = "ckAPIToken=" + api
        if let webToken {
            guard !webToken.isEmpty, let encoded = webToken.addingPercentEncoding(withAllowedCharacters: allowed) else {
                throw CloudBackupError.reconnectRequired
            }
            query += "&ckWebAuthToken=" + encoded
        }
        components.percentEncodedQuery = query
        guard let url = components.url else { throw CloudBackupError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = operation == .currentUser ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // CloudKit checks the API token's allowed origin even for native requests.
        var origin = URLComponents()
        origin.scheme = "https"
        origin.host = configuration.callbackURL.host
        guard let originValue = origin.string else { throw CloudBackupError.unavailable }
        request.setValue(originValue, forHTTPHeaderField: "Origin")
        if let payload { request.httpBody = try JSONEncoder().encode(payload) }
        return request
    }

    static func checkError(_ json: JSON) throws {
        guard let code = json["serverErrorCode"].string else { return }
        switch code {
        case "AUTHENTICATION_REQUIRED", "AUTHENTICATION_FAILED", "ACCESS_DENIED":
            throw CloudBackupError.reconnectRequired
        case "QUOTA_EXCEEDED": throw CloudBackupError.quotaExceeded
        case "NOT_FOUND": throw CloudBackupError.missingBackup
        case "BAD_REQUEST", "ATOMIC_ERROR", "VALIDATING_REFERENCE_ERROR":
            throw CloudBackupError.requestRejected
        case "THROTTLED", "TRY_AGAIN_LATER", "SERVICE_UNAVAILABLE", "INTERNAL_ERROR":
            let retry = min(86_400, max(60, json["retryAfter"].integer ?? 60))
            throw CloudBackupError.retryLater(TimeInterval(retry))
        default: throw CloudBackupError.invalidResponse
        }
    }
}
