import Foundation

/// A non-secret manifest for the filesystem half of key-cliff recovery.
///
/// The replacement SQLCipher database is fully built and validated before
/// this manifest is published. Once published, startup can deterministically
/// finish installation or restore the original unreadable ciphertext without
/// retaining the archive password or the replacement key in a file.
enum KeyCliffRecoveryPhase: String, Codable, Sendable {
    case installing
    case rollingBack
}

struct KeyCliffRecoveryManifest: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let originalArtifactMask: Int
    let candidateArtifactMask: Int
    let phase: KeyCliffRecoveryPhase

    init(originalArtifactMask: Int, candidateArtifactMask: Int) {
        version = Self.currentVersion
        self.originalArtifactMask = originalArtifactMask
        self.candidateArtifactMask = candidateArtifactMask
        phase = .installing
    }

    init(
        version: Int,
        originalArtifactMask: Int,
        candidateArtifactMask: Int,
        phase: KeyCliffRecoveryPhase
    ) {
        self.version = version
        self.originalArtifactMask = originalArtifactMask
        self.candidateArtifactMask = candidateArtifactMask
        self.phase = phase
    }
}

enum KeyCliffRecoveryTransaction {
    private enum Artifact: Int, CaseIterable {
        case database = 1
        case writeAheadLog = 2
        case sharedMemory = 4

        var suffix: String {
            switch self {
            case .database: ""
            case .writeAheadLog: "-wal"
            case .sharedMemory: "-shm"
            }
        }
    }

    private static let directoryName = "KeyCliffRecovery"
    private static let candidateName = "candidate.sqlite"
    private static let originalName = "original.sqlite"
    private static let manifestName = "pending.json"

    static func directoryURL(for databaseURL: URL) -> URL {
        databaseURL.deletingLastPathComponent().appendingPathComponent(
            directoryName,
            isDirectory: true
        )
    }

    static func candidateDatabaseURL(for databaseURL: URL) -> URL {
        directoryURL(for: databaseURL).appendingPathComponent(
            candidateName,
            isDirectory: false
        )
    }

    static func hasPendingManifest(for databaseURL: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: manifestURL(for: databaseURL).path
        )
    }

    static func phase(for databaseURL: URL) throws -> KeyCliffRecoveryPhase {
        try loadManifest(for: databaseURL).phase
    }

    /// Removes only a directory that has no committed manifest. It can be an
    /// abandoned pre-commit candidate whose random key never entered the
    /// Keychain, or bounded post-commit residue left after the marker was
    /// atomically removed. In either case the live artifacts, not this exact
    /// owned directory, are authoritative.
    static func scavengeUncommittedCandidate(
        for databaseURL: URL,
        cleanupMarkerlessDirectory: (URL) throws -> Void = {
            try FileManager.default.removeItem(at: $0)
        }
    ) {
        let directory = directoryURL(for: databaseURL)
        guard FileManager.default.fileExists(atPath: directory.path),
              !hasPendingManifest(for: databaseURL) else { return }
        // Markerless residue has no recovery authority. A cleanup failure must
        // not prevent startup from opening the already-authoritative live book;
        // the exact owned directory remains bounded and can be retried later.
        try? cleanupMarkerlessDirectory(directory)
    }

    static func prepareCandidateDirectory(for databaseURL: URL) throws {
        let directory = directoryURL(for: databaseURL)
        guard !hasPendingManifest(for: databaseURL) else {
            throw AppModelError.transactionInProgress
        }
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        #if os(iOS)
        var protectedDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedDirectory.setResourceValues(values)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen],
            ofItemAtPath: directory.path
        )
        #endif
    }

    /// Publishes the only durable recovery marker after the isolated candidate
    /// has closed successfully. The marker contains artifact-presence bits,
    /// not identifiers, financial data, a password, or key material.
    static func publishManifest(for databaseURL: URL) throws {
        let candidateURL = candidateDatabaseURL(for: databaseURL)
        let candidateMask = artifactMask(at: candidateURL)
        guard candidateMask & Artifact.database.rawValue != 0 else {
            throw AppModelError.invalidBook
        }
        let manifest = KeyCliffRecoveryManifest(
            originalArtifactMask: artifactMask(at: databaseURL),
            candidateArtifactMask: candidateMask
        )
        let encoded = try JSONEncoder().encode(manifest)
        try encoded.write(
            to: manifestURL(for: databaseURL),
            options: [.atomic, .completeFileProtectionUnlessOpen]
        )
    }

    /// Installs the closed SQLCipher candidate. Every rename stays on the same
    /// volume. The manifest's masks make this idempotent even if the process is
    /// interrupted between any two main/WAL/SHM moves.
    static func installCandidate(for databaseURL: URL) throws {
        let manifest = try loadManifest(for: databaseURL)
        guard manifest.phase == .installing else {
            throw AppModelError.restoreRecoveryFailed
        }
        let directory = directoryURL(for: databaseURL)
        let candidateURL = directory.appendingPathComponent(candidateName)
        let originalURL = directory.appendingPathComponent(originalName)

        for artifact in Artifact.allCases
        where manifest.originalArtifactMask & artifact.rawValue != 0 {
            let live = artifactURL(base: databaseURL, artifact: artifact)
            let rollback = artifactURL(base: originalURL, artifact: artifact)
            if FileManager.default.fileExists(atPath: rollback.path) { continue }
            guard FileManager.default.fileExists(atPath: live.path) else {
                throw AppModelError.restoreRecoveryFailed
            }
            try FileManager.default.moveItem(at: live, to: rollback)
        }

        for artifact in Artifact.allCases
        where manifest.candidateArtifactMask & artifact.rawValue != 0 {
            let candidate = artifactURL(base: candidateURL, artifact: artifact)
            let live = artifactURL(base: databaseURL, artifact: artifact)
            guard FileManager.default.fileExists(atPath: candidate.path) else {
                // A missing candidate artifact is valid only when that exact
                // rename already completed before interruption.
                guard FileManager.default.fileExists(atPath: live.path) else {
                    throw AppModelError.restoreRecoveryFailed
                }
                continue
            }
            if FileManager.default.fileExists(atPath: live.path) {
                try FileManager.default.removeItem(at: live)
            }
            try FileManager.default.moveItem(at: candidate, to: live)
        }
    }

    /// Restores exactly the pre-recovery artifact set. Callers publish the
    /// rollback phase and delete the new Keychain key first; if interruption
    /// follows, startup repeats this operation instead of opening a mixed book.
    static func restoreOriginal(for databaseURL: URL) throws {
        let manifest = try loadManifest(for: databaseURL)
        guard manifest.phase == .rollingBack else {
            throw AppModelError.restoreRecoveryFailed
        }
        let directory = directoryURL(for: databaseURL)
        let originalURL = directory.appendingPathComponent(originalName)

        for artifact in Artifact.allCases {
            let live = artifactURL(base: databaseURL, artifact: artifact)
            let rollback = artifactURL(base: originalURL, artifact: artifact)
            let originallyExisted = manifest.originalArtifactMask
                & artifact.rawValue != 0
            if FileManager.default.fileExists(atPath: rollback.path) {
                if FileManager.default.fileExists(atPath: live.path) {
                    try FileManager.default.removeItem(at: live)
                }
                try FileManager.default.moveItem(at: rollback, to: live)
            } else if originallyExisted {
                guard FileManager.default.fileExists(atPath: live.path) else {
                    throw AppModelError.restoreRecoveryFailed
                }
            } else if FileManager.default.fileExists(atPath: live.path) {
                try FileManager.default.removeItem(at: live)
            }
        }
        try removeTransactionDirectory(for: databaseURL)
    }

    /// Marks rollback before deleting the replacement key or moving any file.
    /// Startup therefore continues rollback instead of reinstalling a partly
    /// removed candidate after an interruption.
    static func beginRollback(for databaseURL: URL) throws {
        let current = try loadManifest(for: databaseURL)
        guard current.phase != .rollingBack else { return }
        let rollback = KeyCliffRecoveryManifest(
            version: current.version,
            originalArtifactMask: current.originalArtifactMask,
            candidateArtifactMask: current.candidateArtifactMask,
            phase: .rollingBack
        )
        let encoded = try JSONEncoder().encode(rollback)
        try encoded.write(
            to: manifestURL(for: databaseURL),
            options: [.atomic, .completeFileProtectionUnlessOpen]
        )
    }

    /// Atomically removes the authority marker before best-effort cleanup.
    ///
    /// A recursive directory removal is not a commit point: interruption can
    /// delete an original rollback artifact while leaving `pending.json`
    /// behind. Startup would then mistake the installed candidate for an
    /// original artifact. Once the exact marker unlink succeeds, the live
    /// candidate and its Keychain key are irrevocably authoritative; cleanup
    /// failure must never escape into a rollback path.
    static func complete(
        for databaseURL: URL,
        removeCommitMarker: (URL) throws -> Void = {
            try FileManager.default.removeItem(at: $0)
        },
        cleanupMarkerlessDirectory: (URL) throws -> Void = {
            try FileManager.default.removeItem(at: $0)
        }
    ) throws {
        let manifest = try loadManifest(for: databaseURL)
        guard manifest.phase == .installing else {
            throw AppModelError.restoreRecoveryFailed
        }
        let marker = manifestURL(for: databaseURL)
        let directory = directoryURL(for: databaseURL)
        try removeCommitMarker(marker)
        try? cleanupMarkerlessDirectory(directory)
    }

    static func removeAll(for databaseURL: URL) throws {
        let directory = directoryURL(for: databaseURL)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return
        }
        try FileManager.default.removeItem(at: directory)
    }

    private static func removeTransactionDirectory(
        for databaseURL: URL
    ) throws {
        try removeAll(for: databaseURL)
    }

    private static func loadManifest(
        for databaseURL: URL
    ) throws -> KeyCliffRecoveryManifest {
        let data = try Data(contentsOf: manifestURL(for: databaseURL))
        let manifest = try JSONDecoder().decode(
            KeyCliffRecoveryManifest.self,
            from: data
        )
        guard manifest.version == KeyCliffRecoveryManifest.currentVersion,
              manifest.originalArtifactMask & ~7 == 0,
              manifest.candidateArtifactMask & ~7 == 0,
              manifest.candidateArtifactMask & Artifact.database.rawValue != 0
        else { throw AppModelError.restoreRecoveryFailed }
        return manifest
    }

    private static func manifestURL(for databaseURL: URL) -> URL {
        directoryURL(for: databaseURL).appendingPathComponent(
            manifestName,
            isDirectory: false
        )
    }

    private static func artifactMask(at baseURL: URL) -> Int {
        Artifact.allCases.reduce(into: 0) { mask, artifact in
            let url = artifactURL(base: baseURL, artifact: artifact)
            if FileManager.default.fileExists(atPath: url.path) {
                mask |= artifact.rawValue
            }
        }
    }

    private static func artifactURL(
        base: URL,
        artifact: Artifact
    ) -> URL {
        URL(fileURLWithPath: base.path + artifact.suffix)
    }
}
