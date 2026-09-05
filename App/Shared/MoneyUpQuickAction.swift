import AppIntents
import Foundation
import Observation
import SwiftUI

/// The complete, data-free set of routes exposed outside the app.
///
/// Raw values are persisted by existing widget configurations. Keep them
/// stable even though the two multiword URL path components use hyphens.
enum MoneyUpQuickAction: String, AppEnum, CaseIterable, Codable, Identifiable,
    Sendable {
    case expense = "expense"
    case income = "income"
    case transfer = "transfer"
    case refund = "refund"
    case smartEntry = "smartEntry"
    case scanReceipt = "scanReceipt"

    static let typeDisplayRepresentation: TypeDisplayRepresentation =
        "platform_action.type"

    static let caseDisplayRepresentations: [MoneyUpQuickAction: DisplayRepresentation] = [
        .expense: "platform_action.expense",
        .income: "platform_action.income",
        .transfer: "platform_action.transfer",
        .refund: "platform_action.refund",
        .smartEntry: "platform_action.smart_entry",
        .scanReceipt: "platform_action.scan_receipt"
    ]

    var id: String { rawValue }

    /// Exhaustive literal mappings make the external route an allowlist. No
    /// caller can append a query, fragment, identifier, or user-authored text.
    var deepLink: URL {
        switch self {
        case .expense:
            URL(string: "moneyup://quick-log/expense")!
        case .income:
            URL(string: "moneyup://quick-log/income")!
        case .transfer:
            URL(string: "moneyup://quick-log/transfer")!
        case .refund:
            URL(string: "moneyup://quick-log/refund")!
        case .smartEntry:
            URL(string: "moneyup://quick-log/smart-entry")!
        case .scanReceipt:
            URL(string: "moneyup://quick-log/scan-receipt")!
        }
    }

    /// Accepts only the six canonical external spellings byte for byte.
    /// Foundation URL component normalization is intentionally not used here:
    /// case variants, escapes, credentials, ports, suffixes, queries, and
    /// fragments must all fail closed before an action reaches the broker.
    init?(exactDeepLink url: URL) {
        guard url.baseURL == nil else { return nil }
        let literal = url.relativeString
        guard literal == url.absoluteString else { return nil }
        guard let action = Self.allCases.first(where: {
            $0.deepLink.absoluteString == literal
        }) else {
            return nil
        }
        self = action
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .expense:
            "platform_action.expense"
        case .income:
            "platform_action.income"
        case .transfer:
            "platform_action.transfer"
        case .refund:
            "platform_action.refund"
        case .smartEntry:
            "platform_action.smart_entry"
        case .scanReceipt:
            "platform_action.scan_receipt"
        }
    }

    var systemImage: String {
        switch self {
        case .expense:
            "arrow.up.right"
        case .income:
            "arrow.down.left"
        case .transfer:
            "arrow.left.arrow.right"
        case .refund:
            "arrow.uturn.backward.circle"
        case .smartEntry:
            "sparkles"
        case .scanReceipt:
            "doc.text.viewfinder"
        }
    }

    var requiresUnlock: Bool {
        self == .smartEntry || self == .scanReceipt
    }

    var accessibilityHintKey: LocalizedStringKey {
        requiresUnlock
            ? "platform_action.unlock_required"
            : "platform_action.capture_without_unlock"
    }

    static func mediumActions(
        preferred: MoneyUpQuickAction
    ) -> [MoneyUpQuickAction] {
        let fallback: [MoneyUpQuickAction] = [
            .expense,
            .income,
            .transfer,
            .refund,
            .scanReceipt,
            .smartEntry
        ]
        return [preferred] + Array(fallback.filter { $0 != preferred }.prefix(3))
    }
}

/// One data-free, durable ingress item. The token identifies this accepted
/// handoff only; it is never a ledger, user, account, or logical-book ID.
struct MoneyUpQuickActionIngressRecord: Codable, Equatable, Sendable {
    let token: UUID
    let action: MoneyUpQuickAction
}

enum MoneyUpQuickActionIngressAdmission: String, Codable, Equatable, Sendable {
    case open
    case closed
}

struct MoneyUpQuickActionIngressSnapshot: Equatable, Sendable {
    let authorityToken: UUID?
    let admission: MoneyUpQuickActionIngressAdmission
    let records: [MoneyUpQuickActionIngressRecord]
}

enum MoneyUpQuickActionIngressLoad: Equatable, Sendable {
    case available(MoneyUpQuickActionIngressSnapshot)
    case unavailable
}

struct MoneyUpQuickActionIngressMutation: Equatable, Sendable {
    let didApply: Bool
    let load: MoneyUpQuickActionIngressLoad
}

protocol MoneyUpQuickActionIngressStoring: AnyObject {
    func load() -> MoneyUpQuickActionIngressLoad
    func append(
        _ record: MoneyUpQuickActionIngressRecord,
        expectedAuthorityToken: UUID?
    ) -> MoneyUpQuickActionIngressMutation
    func acknowledge(
        token: UUID,
        expectedAuthorityToken: UUID
    ) -> MoneyUpQuickActionIngressMutation
    func invalidateAndClose() -> MoneyUpQuickActionIngressMutation
    func reopenEmpty() -> MoneyUpQuickActionIngressMutation
    func recoverOpenAfterValidatedLifecycle() -> MoneyUpQuickActionIngressMutation
}

/// A small App Group file is the cross-process commit point for action ingress.
/// Its schema can encode only protocol metadata and the closed action enum.
/// Every read/modify/write is coordinated, bounded, and atomically replaced.
final class MoneyUpQuickActionIngressFileStore:
    MoneyUpQuickActionIngressStoring {
    static let currentSchemaVersion = 1
    static let maximumRecordCount = 16
    static let maximumPayloadByteCount = 4_096
    static let storageDirectoryName = "MoneyUpQuickActionIngress"
    static let fileName = "moneyup-quick-action-ingress-v1.json"

    private struct Envelope: Codable, Equatable {
        var schemaVersion: Int
        var authorityToken: UUID
        var admission: MoneyUpQuickActionIngressAdmission
        var records: [MoneyUpQuickActionIngressRecord]

        static func empty(
            admission: MoneyUpQuickActionIngressAdmission
        ) -> Envelope {
            Envelope(
                schemaVersion: MoneyUpQuickActionIngressFileStore
                    .currentSchemaVersion,
                authorityToken: UUID(),
                admission: admission,
                records: []
            )
        }
    }

    private enum DecodeResult {
        case available(Envelope)
        case absent
        case unavailable
    }

    private let fileURL: URL?
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL?, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
    }

    convenience init(appGroupIdentifier: String) {
        let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )
        let directory = container?
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(Self.storageDirectoryName, isDirectory: true)
        self.init(fileURL: directory?.appendingPathComponent(Self.fileName))
    }

    func load() -> MoneyUpQuickActionIngressLoad {
        guard let fileURL else { return .unavailable }
        var result: MoneyUpQuickActionIngressLoad = .unavailable
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: fileURL,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            switch decodeEnvelope(at: coordinatedURL) {
            case let .available(envelope):
                result = .available(Self.snapshot(envelope))
            case .absent:
                result = .available(MoneyUpQuickActionIngressSnapshot(
                    authorityToken: nil,
                    admission: .open,
                    records: []
                ))
            case .unavailable:
                result = .unavailable
            }
        }
        guard coordinationError == nil else { return .unavailable }
        return result
    }

    func append(
        _ record: MoneyUpQuickActionIngressRecord,
        expectedAuthorityToken: UUID?
    ) -> MoneyUpQuickActionIngressMutation {
        mutate(resetUnavailable: false) { envelope, wasAbsent in
            guard (wasAbsent && expectedAuthorityToken == nil)
                    || envelope.authorityToken == expectedAuthorityToken,
                  envelope.admission == .open,
                  envelope.records.count < Self.maximumRecordCount,
                  !envelope.records.contains(where: {
                      $0.token == record.token
                  }) else { return false }
            envelope.records.append(record)
            return true
        }
    }

    func acknowledge(
        token: UUID,
        expectedAuthorityToken: UUID
    ) -> MoneyUpQuickActionIngressMutation {
        mutate(resetUnavailable: false) { envelope, wasAbsent in
            guard !wasAbsent,
                  envelope.authorityToken == expectedAuthorityToken,
                  envelope.admission == .open,
                  envelope.records.first?.token == token else { return false }
            envelope.records.removeFirst()
            return true
        }
    }

    func invalidateAndClose() -> MoneyUpQuickActionIngressMutation {
        mutate(resetUnavailable: true) { envelope, _ in
            envelope = .empty(admission: .closed)
            return true
        }
    }

    func reopenEmpty() -> MoneyUpQuickActionIngressMutation {
        mutate(resetUnavailable: true) { envelope, _ in
            envelope = .empty(admission: .open)
            return true
        }
    }

    /// A validated app lifecycle may recover absent, closed, or unreadable
    /// ingress. A concurrently established valid/open epoch is preserved
    /// byte-for-byte, including every action it already accepted.
    func recoverOpenAfterValidatedLifecycle() -> MoneyUpQuickActionIngressMutation {
        mutate(resetUnavailable: true) { envelope, wasAbsent in
            guard wasAbsent || envelope.admission == .closed else {
                return false
            }
            envelope = .empty(admission: .open)
            return true
        }
    }

    private func mutate(
        resetUnavailable: Bool,
        _ transform: (inout Envelope, Bool) -> Bool
    ) -> MoneyUpQuickActionIngressMutation {
        guard let fileURL else {
            return MoneyUpQuickActionIngressMutation(
                didApply: false,
                load: .unavailable
            )
        }
        var result = MoneyUpQuickActionIngressMutation(
            didApply: false,
            load: .unavailable
        )
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: fileURL,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            var envelope: Envelope
            let wasAbsent: Bool
            switch decodeEnvelope(at: coordinatedURL) {
            case let .available(decoded):
                envelope = decoded
                wasAbsent = false
            case .absent:
                envelope = .empty(admission: .open)
                wasAbsent = true
            case .unavailable:
                guard resetUnavailable else { return }
                envelope = .empty(admission: .closed)
                wasAbsent = false
            }
            guard transform(&envelope, wasAbsent), Self.isValid(envelope) else {
                let load: MoneyUpQuickActionIngressLoad = wasAbsent
                    ? .available(MoneyUpQuickActionIngressSnapshot(
                        authorityToken: nil,
                        admission: .open,
                        records: []
                    ))
                    : .available(Self.snapshot(envelope))
                result = MoneyUpQuickActionIngressMutation(
                    didApply: false,
                    load: load
                )
                return
            }
            do {
                try writeEnvelope(envelope, to: coordinatedURL)
                result = MoneyUpQuickActionIngressMutation(
                    didApply: true,
                    load: .available(Self.snapshot(envelope))
                )
            } catch {
                // Atomic replacement can be durably visible even when the
                // surrounding API reports an ambiguous late error. Confirm
                // the exact postcondition while still inside coordination.
                if case let .available(persisted) = decodeEnvelope(
                    at: coordinatedURL
                ), persisted == envelope {
                    result = MoneyUpQuickActionIngressMutation(
                        didApply: true,
                        load: .available(Self.snapshot(persisted))
                    )
                }
            }
        }
        guard coordinationError == nil || result.didApply else {
            return MoneyUpQuickActionIngressMutation(
                didApply: false,
                load: .unavailable
            )
        }
        return result
    }

    private func writeEnvelope(_ envelope: Envelope, to url: URL) throws {
        let data = try encoder.encode(envelope)
        guard data.count <= Self.maximumPayloadByteCount else {
            throw MoneyUpQuickActionIngressError.unavailable
        }
        var storageDirectory = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // `createDirectory` applies attributes only when it creates the last
        // component. Reassert the private mode for an existing App Group
        // directory without reading file metadata or timestamps.
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: storageDirectory.path
        )
        // Durable ingress is install-local protocol state, not user data.
        // Excluding its dedicated directory from backup prevents an accepted
        // token from migrating into another install/book epoch while retaining
        // stronger durability than a purgeable Caches location.
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try storageDirectory.setResourceValues(resourceValues)
        try data.write(
            to: url,
            // The payload is strictly data-free. First-unlock protection keeps
            // Lock Screen quick capture available after the user has unlocked
            // once this boot, while protecting reboot-before-first-unlock.
            options: [
                .atomic,
                .completeFileProtectionUntilFirstUserAuthentication
            ]
        )
    }

    private func decodeEnvelope(at url: URL) -> DecodeResult {
        guard fileManager.fileExists(atPath: url.path) else { return .absent }
        do {
            guard let data = try boundedData(at: url),
                  Self.hasExactDataFreeShape(data) else {
                return .unavailable
            }
            let envelope = try decoder.decode(Envelope.self, from: data)
            // Our writer emits sorted canonical JSON. Requiring that exact
            // representation also rejects duplicate keys that a semantic JSON
            // object parser would otherwise collapse before shape validation.
            guard Self.isValid(envelope),
                  try encoder.encode(envelope) == data else {
                return .unavailable
            }
            return .available(envelope)
        } catch {
            return .unavailable
        }
    }

    private func boundedData(at url: URL) throws -> Data? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= Self.maximumPayloadByteCount {
            let remaining = Self.maximumPayloadByteCount + 1 - data.count
            guard let chunk = try handle.read(upToCount: remaining),
                  !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard !data.isEmpty,
              data.count <= Self.maximumPayloadByteCount else { return nil }
        return data
    }

    private static func hasExactDataFreeShape(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              Set(root.keys) == Set([
                  "schemaVersion", "authorityToken", "admission", "records"
              ]),
              root["schemaVersion"] is NSNumber,
              root["authorityToken"] is String,
              root["admission"] is String,
              let records = root["records"] as? [[String: Any]] else {
            return false
        }
        return records.allSatisfy {
            Set($0.keys) == Set(["token", "action"])
                && $0["token"] is String
                && $0["action"] is String
        }
    }

    private static func isValid(_ envelope: Envelope) -> Bool {
        guard envelope.schemaVersion == currentSchemaVersion,
              envelope.records.count <= maximumRecordCount,
              Set(envelope.records.map(\.token)).count
                == envelope.records.count else { return false }
        return envelope.admission == .open || envelope.records.isEmpty
    }

    private static func snapshot(
        _ envelope: Envelope
    ) -> MoneyUpQuickActionIngressSnapshot {
        MoneyUpQuickActionIngressSnapshot(
            authorityToken: envelope.authorityToken,
            admission: envelope.admission,
            records: envelope.records
        )
    }
}

/// A bounded, crash-tolerant FIFO handoff from App Intents to the app.
/// The shared instance persists only action records and opaque tokens. Tests
/// and previews use the explicit ephemeral initializer.
@MainActor
@Observable
final class MoneyUpQuickActionRouteBroker {
    static let shared = MoneyUpQuickActionRouteBroker(
        ingressStore: MoneyUpQuickActionIngressFileStore(
            appGroupIdentifier: BudgetWidgetSnapshotStore.appGroupIdentifier
        )
    )
    static let maximumPendingActionCount =
        MoneyUpQuickActionIngressFileStore.maximumRecordCount

    private let ingressStore: (any MoneyUpQuickActionIngressStoring)?
    private var pendingRecords: [MoneyUpQuickActionIngressRecord] = []
    private var activeDeliveryToken: UUID?
    private var acknowledgedDeliveryToken: UUID?
    private var acknowledgementRetryToken: UUID?
    private var durableAuthorityToken: UUID?
    private var durableAdmissionBlocked = false
    private var nextBoundaryEpoch: UInt64 = 0
    private var activeBoundaryEpochs: Set<UInt64> = []
    private(set) var revision: UInt64 = 0
    private(set) var handoffGeneration: UInt64 = 0

    var pendingAction: MoneyUpQuickAction? { pendingRecords.first?.action }
    var pendingCount: Int { pendingRecords.count }
    var activeIngressToken: UUID? { activeDeliveryToken }
    var isAuthoritativeLifecycleBoundaryActive: Bool {
        !activeBoundaryEpochs.isEmpty
    }
    var isAuthoritativeBoundaryActive: Bool {
        isAuthoritativeLifecycleBoundaryActive || durableAdmissionBlocked
    }

    init(ingressStore: (any MoneyUpQuickActionIngressStoring)? = nil) {
        self.ingressStore = ingressStore
        guard let ingressStore else { return }
        apply(ingressStore.load(), preservingActiveDelivery: false)
    }

    /// The durable store commits before this returns true. A retry has no OS
    /// invocation identifier, so separate submissions intentionally get
    /// separate tokens; capacity rejects the newest without evicting old work.
    @discardableResult
    func submit(
        _ action: MoneyUpQuickAction,
        token: UUID = UUID()
    ) -> Bool {
        guard !isAuthoritativeLifecycleBoundaryActive else { return false }
        if ingressStore != nil {
            // A long-lived extension may hold either side of an app lifecycle
            // boundary. Refresh before each new invocation, then let the
            // authority CAS reject any rotation between this read and append.
            reloadDurableIngress()
        }
        guard !durableAdmissionBlocked else { return false }
        let record = MoneyUpQuickActionIngressRecord(
            token: token,
            action: action
        )
        if let ingressStore {
            let expectedAuthorityToken = durableAuthorityToken
            let mutation = ingressStore.append(
                record,
                expectedAuthorityToken: expectedAuthorityToken
            )
            var confirmedLoad = mutation.load
            var wasAccepted = mutation.didApply
            if !wasAccepted, case .unavailable = mutation.load {
                let confirmation = ingressStore.load()
                confirmedLoad = confirmation
                if case let .available(snapshot) = confirmation,
                   snapshot.admission == .open,
                   expectedAuthorityToken == nil
                    || snapshot.authorityToken == expectedAuthorityToken,
                   snapshot.records.contains(record) {
                    wasAccepted = true
                }
            }
            apply(confirmedLoad, preservingActiveDelivery: true)
            revision &+= 1
            return wasAccepted
        }
        let acceptedCount = pendingRecords.count
            + (activeDeliveryToken == nil ? 0 : 1)
        guard acceptedCount < Self.maximumPendingActionCount,
              activeDeliveryToken != token,
              !pendingRecords.contains(where: { $0.token == token }) else {
            revision &+= 1
            return false
        }
        pendingRecords.append(record)
        revision &+= 1
        return true
    }

    /// Begins one delivery without acknowledging durable ingress. The record
    /// remains on disk until the exact UI request token is acknowledged.
    func takePendingRecord() -> MoneyUpQuickActionIngressRecord? {
        guard !isAuthoritativeBoundaryActive,
              activeDeliveryToken == nil,
              !pendingRecords.isEmpty else { return nil }
        let record = pendingRecords.removeFirst()
        activeDeliveryToken = record.token
        acknowledgedDeliveryToken = nil
        acknowledgementRetryToken = nil
        revision &+= 1
        return record
    }

    func ownsActiveDelivery(token: UUID) -> Bool {
        activeDeliveryToken == token
    }

    func needsAcknowledgementRetry(token: UUID) -> Bool {
        acknowledgementRetryToken == token
    }

    /// Only the active token can remove the durable FIFO head. A duplicate or
    /// stale acknowledgement therefore cannot consume a different request.
    /// A confirmed locked-inbox commit may finalize locally if durable removal
    /// is temporarily unavailable: its token-bound append makes a later replay
    /// idempotent. Other UI acknowledgements retain the active token for retry.
    @discardableResult
    func acknowledge(
        token: UUID,
        allowingCommittedCaptureReplay: Bool = false
    ) -> Bool {
        guard activeDeliveryToken == token else {
            guard acknowledgedDeliveryToken == token else { return false }
            acknowledgementRetryToken = nil
            return true
        }
        if let ingressStore {
            guard let durableAuthorityToken else { return false }
            let mutation = ingressStore.acknowledge(
                token: token,
                expectedAuthorityToken: durableAuthorityToken
            )
            if case .unavailable = mutation.load {
                if allowingCommittedCaptureReplay {
                    activeDeliveryToken = nil
                    acknowledgedDeliveryToken = token
                    acknowledgementRetryToken = nil
                    apply(mutation.load, preservingActiveDelivery: false)
                } else {
                    acknowledgementRetryToken = token
                    apply(mutation.load, preservingActiveDelivery: true)
                }
                revision &+= 1
                return allowingCommittedCaptureReplay
            }
            guard mutation.didApply else {
                apply(mutation.load, preservingActiveDelivery: true)
                if acknowledgedDeliveryToken == token {
                    acknowledgementRetryToken = nil
                    revision &+= 1
                    return true
                }
                acknowledgementRetryToken = activeDeliveryToken == token
                    ? token : nil
                revision &+= 1
                return false
            }
            activeDeliveryToken = nil
            apply(mutation.load, preservingActiveDelivery: false)
            acknowledgedDeliveryToken = token
            acknowledgementRetryToken = nil
            revision &+= 1
            return true
        }
        activeDeliveryToken = nil
        acknowledgedDeliveryToken = token
        acknowledgementRetryToken = nil
        revision &+= 1
        return true
    }

    /// Reloads work accepted by another process. An active token is kept only
    /// while it is still the durable head, preventing same-process redelivery.
    func reloadDurableIngress() {
        guard let ingressStore else { return }
        let before = pendingRecords
        let wasBlocked = durableAdmissionBlocked
        let activeBefore = activeDeliveryToken
        let acknowledgedBefore = acknowledgedDeliveryToken
        apply(ingressStore.load(), preservingActiveDelivery: true)
        if pendingRecords != before
            || durableAdmissionBlocked != wasBlocked
            || activeDeliveryToken != activeBefore
            || acknowledgedDeliveryToken != acknowledgedBefore {
            revision &+= 1
        }
    }

    /// An authoritative erase or book-replacement boundary invalidates every
    /// old action and closes cross-process admission before lifecycle work.
    func discardAllPendingActions() {
        activeDeliveryToken = nil
        acknowledgedDeliveryToken = nil
        acknowledgementRetryToken = nil
        pendingRecords.removeAll(keepingCapacity: false)
        if let ingressStore {
            let mutation = ingressStore.invalidateAndClose()
            apply(mutation.load, preservingActiveDelivery: false)
            durableAdmissionBlocked = true
        }
        revision &+= 1
    }

    /// Starts a durable book boundary before any asynchronous lifecycle work.
    /// A write failure also blocks this process; later authoritative recovery
    /// resets the file rather than trusting ambiguous ingress.
    @discardableResult
    func beginAuthoritativeBoundary() throws -> UInt64 {
        nextBoundaryEpoch &+= 1
        let epoch = nextBoundaryEpoch
        handoffGeneration &+= 1
        activeDeliveryToken = nil
        acknowledgedDeliveryToken = nil
        acknowledgementRetryToken = nil
        pendingRecords.removeAll(keepingCapacity: false)
        durableAdmissionBlocked = true
        if let ingressStore {
            let mutation = ingressStore.invalidateAndClose()
            apply(mutation.load, preservingActiveDelivery: false)
            durableAdmissionBlocked = true
            guard mutation.didApply else {
                revision &+= 1
                throw MoneyUpQuickActionIngressError.unavailable
            }
        }
        activeBoundaryEpochs.insert(epoch)
        revision &+= 1
        return epoch
    }

    /// Ending an in-process lifecycle epoch never reopens durable admission.
    /// Only a separate, explicit validated-success call may do that after the
    /// final overlapping epoch has ended; every failure therefore stays closed.
    func endAuthoritativeBoundary(_ epoch: UInt64) {
        guard activeBoundaryEpochs.remove(epoch) != nil else { return }
        revision &+= 1
    }

    /// Successful startup is the authority that may recover a closed,
    /// corrupt, future-schema, or crash-interrupted ingress file. The
    /// coordinated recovery preserves a concurrently established valid/open
    /// epoch; only absent, invalid, or closed state is replaced with new epoch.
    @discardableResult
    func reopenDurableAdmissionAfterAuthoritativeRecovery() -> Bool {
        guard activeBoundaryEpochs.isEmpty else { return false }
        guard let ingressStore else {
            durableAdmissionBlocked = false
            return true
        }
        guard durableAdmissionBlocked || durableAuthorityToken == nil else {
            reloadDurableIngress()
            return !durableAdmissionBlocked
        }
        let mutation = ingressStore.recoverOpenAfterValidatedLifecycle()
        if mutation.didApply {
            activeDeliveryToken = nil
            acknowledgedDeliveryToken = nil
            acknowledgementRetryToken = nil
        }
        apply(
            mutation.load,
            preservingActiveDelivery: !mutation.didApply
        )
        let isOpen: Bool
        if case let .available(snapshot) = mutation.load {
            isOpen = snapshot.admission == .open
        } else {
            isOpen = false
        }
        durableAdmissionBlocked = !isOpen
        revision &+= 1
        return isOpen
    }

    private func apply(
        _ load: MoneyUpQuickActionIngressLoad,
        preservingActiveDelivery: Bool
    ) {
        switch load {
        case let .available(snapshot):
            let previousAuthorityToken = durableAuthorityToken
            let previousActiveDeliveryToken = activeDeliveryToken
            if snapshot.authorityToken == nil,
               previousAuthorityToken != nil {
                if !preservingActiveDelivery {
                    activeDeliveryToken = nil
                }
                pendingRecords.removeAll(keepingCapacity: false)
                durableAdmissionBlocked = true
                return
            }
            durableAuthorityToken = snapshot.authorityToken
            durableAdmissionBlocked = snapshot.admission == .closed
            if previousAuthorityToken != snapshot.authorityToken {
                acknowledgedDeliveryToken = nil
                acknowledgementRetryToken = nil
            }
            if preservingActiveDelivery,
               previousAuthorityToken == snapshot.authorityToken,
               let activeDeliveryToken,
               snapshot.records.first?.token == activeDeliveryToken {
                pendingRecords = Array(snapshot.records.dropFirst())
            } else if preservingActiveDelivery,
                      previousAuthorityToken == snapshot.authorityToken,
                      snapshot.admission == .open,
                      let previousActiveDeliveryToken,
                      !snapshot.records.contains(where: {
                          $0.token == previousActiveDeliveryToken
                      }) {
                // The coordinated removal may have committed even if its
                // caller received an ambiguous I/O/coordinator result. Only
                // the same open authority epoch and exact token absence can
                // converge that acknowledgement; a different epoch cannot.
                activeDeliveryToken = nil
                acknowledgedDeliveryToken = previousActiveDeliveryToken
                pendingRecords = snapshot.records
            } else {
                self.activeDeliveryToken = nil
                pendingRecords = snapshot.records
                if preservingActiveDelivery,
                   previousAuthorityToken == snapshot.authorityToken,
                   let previousActiveDeliveryToken,
                   snapshot.records.contains(where: {
                       $0.token == previousActiveDeliveryToken
                   }) {
                    // Seeing an active token anywhere except the head violates
                    // FIFO history. Keep the durable file for diagnosis, but
                    // stop admission/routing rather than reordering it.
                    pendingRecords.removeAll(keepingCapacity: false)
                    durableAdmissionBlocked = true
                }
            }
        case .unavailable:
            if !preservingActiveDelivery {
                activeDeliveryToken = nil
            }
            pendingRecords.removeAll(keepingCapacity: false)
            durableAdmissionBlocked = true
        }
    }
}

enum MoneyUpQuickActionIngressError: Error {
    case unavailable
}

/// Opens the app after durably accepting one allowlisted, data-free action.
/// The action enum is the intent's only input; there is no dialog or payload.
struct OpenQuickLogIntent: AppIntent {
    static let title: LocalizedStringResource = "platform_intent.open_quick_log.title"
    static let description = IntentDescription(
        "platform_intent.open_quick_log.description"
    )
    @available(iOS, obsoleted: 26.0, message: "Replaced by supportedModes")
    static var openAppWhenRun: Bool { true }

#if compiler(>=6.2)
    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = [.foreground(.immediate)]
#endif

    @Parameter(title: "platform_intent.open_quick_log.action", default: .expense)
    var action: MoneyUpQuickAction

    init() {
        action = .expense
    }

    init(action: MoneyUpQuickAction) {
        self.action = action
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard MoneyUpQuickActionRouteBroker.shared.submit(action) else {
            throw MoneyUpQuickActionIngressError.unavailable
        }
        return .result()
    }
}

// Keep the configuration conformance with the intent in both the app and
// widget-extension targets so the system can resolve it on every surface.
extension OpenQuickLogIntent: ControlConfigurationIntent {}
