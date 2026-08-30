import Foundation

public enum RecurrenceFrequency: String, Codable, CaseIterable, Sendable {
    case weekly
    case monthly
    case yearly
}

public enum ScheduledTransactionStatus: String, Codable, CaseIterable, Sendable {
    case active
    case paused
    case ended
}

public struct ScheduledOccurrenceID: Codable, Equatable, Hashable, Sendable {
    public let scheduleID: UUID
    public let seriesVersion: Int
    public let index: Int

    public init(scheduleID: UUID, seriesVersion: Int, index: Int) {
        self.scheduleID = scheduleID
        self.seriesVersion = seriesVersion
        self.index = index
    }

    private enum CodingKeys: String, CodingKey {
        case scheduleID, seriesVersion, index
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSeries = try container.decode(Int.self, forKey: .seriesVersion)
        let decodedIndex = try container.decode(Int.self, forKey: .index)
        guard decodedSeries >= 0, decodedIndex >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .index,
                in: container,
                debugDescription: "Negative scheduled occurrence identity"
            )
        }
        self.init(
            scheduleID: try container.decode(UUID.self, forKey: .scheduleID),
            seriesVersion: decodedSeries,
            index: decodedIndex
        )
    }
}

public enum ScheduledOccurrenceResolutionKind: String, Codable, Sendable {
    case skipped
    case posted
    case matched
    /// The occurrence remains resolved and advanced, while the linked actual
    /// was later removed through History.
    case entryDeleted = "entry_deleted"
}

public struct ScheduledOccurrenceResolution: Codable, Equatable, Sendable, Identifiable {
    public let occurrenceID: ScheduledOccurrenceID
    public let scheduledFor: Date
    public let kind: ScheduledOccurrenceResolutionKind
    public let linkedEntryID: UUID?
    public let resolvedAt: Date
    public let entryDeletedAt: Date?

    public var id: ScheduledOccurrenceID { occurrenceID }

    public init(
        occurrenceID: ScheduledOccurrenceID,
        scheduledFor: Date,
        kind: ScheduledOccurrenceResolutionKind,
        linkedEntryID: UUID?,
        resolvedAt: Date,
        entryDeletedAt: Date? = nil
    ) throws {
        guard scheduledFor.timeIntervalSinceReferenceDate.isFinite,
              resolvedAt.timeIntervalSinceReferenceDate.isFinite,
              entryDeletedAt?.timeIntervalSinceReferenceDate.isFinite != false else {
            throw ScheduledTransactionError.invalidLifecycle
        }
        switch kind {
        case .posted, .matched:
            guard linkedEntryID != nil, entryDeletedAt == nil else {
                throw ScheduledTransactionError.invalidResolutionState
            }
        case .skipped:
            guard linkedEntryID == nil, entryDeletedAt == nil else {
                throw ScheduledTransactionError.invalidResolutionState
            }
        case .entryDeleted:
            guard linkedEntryID == nil, entryDeletedAt != nil else {
                throw ScheduledTransactionError.invalidResolutionState
            }
        }
        self.occurrenceID = occurrenceID
        self.scheduledFor = scheduledFor
        self.kind = kind
        self.linkedEntryID = linkedEntryID
        self.resolvedAt = resolvedAt
        self.entryDeletedAt = entryDeletedAt
    }

    private enum CodingKeys: String, CodingKey {
        case occurrenceID, scheduledFor, kind, linkedEntryID, resolvedAt
        case entryDeletedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                occurrenceID: container.decode(
                    ScheduledOccurrenceID.self,
                    forKey: .occurrenceID
                ),
                scheduledFor: container.decode(Date.self, forKey: .scheduledFor),
                kind: container.decode(
                    ScheduledOccurrenceResolutionKind.self,
                    forKey: .kind
                ),
                linkedEntryID: container.decodeIfPresent(
                    UUID.self,
                    forKey: .linkedEntryID
                ),
                resolvedAt: container.decode(Date.self, forKey: .resolvedAt),
                entryDeletedAt: container.decodeIfPresent(
                    Date.self,
                    forKey: .entryDeletedAt
                )
            )
        } catch let error as ScheduledTransactionError {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Invalid occurrence resolution: \(error)"
            )
        }
    }
}

public struct ScheduledOccurrenceConfirmation: Codable, Equatable, Sendable {
    public let occurrenceID: ScheduledOccurrenceID
    public let scheduledFor: Date
    public let confirmedAt: Date

    public init(
        occurrenceID: ScheduledOccurrenceID,
        scheduledFor: Date,
        confirmedAt: Date
    ) throws {
        guard scheduledFor.timeIntervalSinceReferenceDate.isFinite,
              confirmedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ScheduledTransactionError.invalidLifecycle
        }
        self.occurrenceID = occurrenceID
        self.scheduledFor = scheduledFor
        self.confirmedAt = confirmedAt
    }

    private enum CodingKeys: String, CodingKey {
        case occurrenceID, scheduledFor, confirmedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                occurrenceID: container.decode(
                    ScheduledOccurrenceID.self,
                    forKey: .occurrenceID
                ),
                scheduledFor: container.decode(Date.self, forKey: .scheduledFor),
                confirmedAt: container.decode(Date.self, forKey: .confirmedAt)
            )
        } catch let error as ScheduledTransactionError {
            throw DecodingError.dataCorruptedError(
                forKey: .confirmedAt,
                in: container,
                debugDescription: "Invalid occurrence confirmation: \(error)"
            )
        }
    }
}

public enum ScheduledTransactionError: Error, Equatable, Sendable {
    case unsupportedKind
    case amountMustBePositive
    case nameCannotBeEmpty
    case inactive
    case ended
    case staleOccurrence
    case occurrenceAlreadyResolved
    case linkedEntryRequired
    case unexpectedLinkedEntry
    case cannotAdvance
    case linkedEntryNotFound
    case invalidResolutionState
    case invalidLifecycle
}

/// A recurring forecast with an explicit, auditable occurrence lifecycle.
///
/// `recurrenceAnchor` never moves. `currentOccurrenceIndex` and
/// `nextOccurrence` advance together only when the current occurrence is
/// skipped, posted, or matched. Keeping the original anchor avoids the classic
/// 31 January -> 28 February -> 28 March drift.
public struct ScheduledTransaction: Codable, Equatable, Identifiable, Sendable {
    public static let maximumResolutionCount = 4_096
    public let id: UUID
    public var kind: JournalEntryKind
    public var name: String
    public var amount: Money
    public var accountID: UUID
    public var categoryAccountID: UUID
    public internal(set) var nextOccurrence: Date
    public var frequency: RecurrenceFrequency
    public internal(set) var status: ScheduledTransactionStatus
    public internal(set) var recurrenceAnchor: Date
    public internal(set) var seriesVersion: Int
    public internal(set) var currentOccurrenceIndex: Int
    public internal(set) var currentConfirmation: ScheduledOccurrenceConfirmation?
    public internal(set) var resolutions: [ScheduledOccurrenceResolution]
    public internal(set) var endedAt: Date?
    /// New records retain the recurrence zone so encode/decode validation and
    /// month-end anchoring remain stable when the device travels.
    public internal(set) var recurrenceTimeZoneIdentifier: String?

    /// Source-compatible view for calculations written before lifecycle state.
    public var isActive: Bool { status == .active }

    public var currentOccurrenceID: ScheduledOccurrenceID {
        ScheduledOccurrenceID(
            scheduleID: id,
            seriesVersion: seriesVersion,
            index: currentOccurrenceIndex
        )
    }

    public var isCurrentOccurrenceConfirmed: Bool {
        currentConfirmation?.occurrenceID == currentOccurrenceID
    }

    public init(
        id: UUID = UUID(),
        kind: JournalEntryKind,
        name: String,
        amount: Money,
        accountID: UUID,
        categoryAccountID: UUID,
        nextOccurrence: Date,
        frequency: RecurrenceFrequency,
        isActive: Bool = true,
        recurrenceTimeZoneIdentifier: String? = TimeZone.current.identifier
    ) throws {
        guard kind == .expense || kind == .income else {
            throw ScheduledTransactionError.unsupportedKind
        }
        guard amount.amount > .zero else {
            throw ScheduledTransactionError.amountMustBePositive
        }
        guard nextOccurrence.timeIntervalSinceReferenceDate.isFinite else {
            throw ScheduledTransactionError.invalidLifecycle
        }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw ScheduledTransactionError.nameCannotBeEmpty
        }

        self.id = id
        self.kind = kind
        self.name = normalizedName
        self.amount = amount
        self.accountID = accountID
        self.categoryAccountID = categoryAccountID
        self.nextOccurrence = nextOccurrence
        self.frequency = frequency
        status = isActive ? .active : .paused
        recurrenceAnchor = nextOccurrence
        seriesVersion = 0
        currentOccurrenceIndex = 0
        currentConfirmation = nil
        resolutions = []
        endedAt = nil
        if let recurrenceTimeZoneIdentifier,
           TimeZone(identifier: recurrenceTimeZoneIdentifier) == nil {
            throw ScheduledTransactionError.invalidLifecycle
        }
        self.recurrenceTimeZoneIdentifier = recurrenceTimeZoneIdentifier
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, name, amount, accountID, categoryAccountID
        case nextOccurrence, frequency, isActive, status, recurrenceAnchor
        case seriesVersion, currentOccurrenceIndex, currentConfirmation
        case resolutions, endedAt
        case recurrenceTimeZoneIdentifier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedNextOccurrence = try container.decode(Date.self, forKey: .nextOccurrence)
        do {
            let legacyIsActive = try container.decodeIfPresent(
                Bool.self,
                forKey: .isActive
            ) ?? true
            let decodedRecurrenceTimeZoneIdentifier = try container.decodeIfPresent(
                String.self,
                forKey: .recurrenceTimeZoneIdentifier
            )
            try self.init(
                id: container.decode(UUID.self, forKey: .id),
                kind: container.decode(JournalEntryKind.self, forKey: .kind),
                name: container.decode(String.self, forKey: .name),
                amount: container.decode(Money.self, forKey: .amount),
                accountID: container.decode(UUID.self, forKey: .accountID),
                categoryAccountID: container.decode(UUID.self, forKey: .categoryAccountID),
                nextOccurrence: decodedNextOccurrence,
                frequency: container.decode(RecurrenceFrequency.self, forKey: .frequency),
                isActive: legacyIsActive,
                recurrenceTimeZoneIdentifier: decodedRecurrenceTimeZoneIdentifier
            )

            // Older records migrate to the first unresolved occurrence without
            // requiring an eager database rewrite.
            recurrenceAnchor = try container.decodeIfPresent(
                Date.self,
                forKey: .recurrenceAnchor
            ) ?? decodedNextOccurrence
            seriesVersion = try container.decodeIfPresent(
                Int.self,
                forKey: .seriesVersion
            ) ?? 0
            currentOccurrenceIndex = try container.decodeIfPresent(
                Int.self,
                forKey: .currentOccurrenceIndex
            ) ?? 0
            status = try container.decodeIfPresent(
                ScheduledTransactionStatus.self,
                forKey: .status
            ) ?? (legacyIsActive ? .active : .paused)
            currentConfirmation = try container.decodeIfPresent(
                ScheduledOccurrenceConfirmation.self,
                forKey: .currentConfirmation
            )
            resolutions = try container.decodeIfPresent(
                [ScheduledOccurrenceResolution].self,
                forKey: .resolutions
            ) ?? []
            guard resolutions.count <= Self.maximumResolutionCount else {
                throw ScheduledTransactionError.invalidLifecycle
            }
            endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)

            try validateLifecycle()
        } catch let error as ScheduledTransactionError {
            throw DecodingError.dataCorruptedError(
                forKey: .amount,
                in: container,
                debugDescription: "Invalid scheduled transaction: \(error)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(name, forKey: .name)
        try container.encode(amount, forKey: .amount)
        try container.encode(accountID, forKey: .accountID)
        try container.encode(categoryAccountID, forKey: .categoryAccountID)
        try container.encode(nextOccurrence, forKey: .nextOccurrence)
        try container.encode(frequency, forKey: .frequency)
        try container.encode(isActive, forKey: .isActive)
        try container.encode(status, forKey: .status)
        try container.encode(recurrenceAnchor, forKey: .recurrenceAnchor)
        try container.encode(seriesVersion, forKey: .seriesVersion)
        try container.encode(currentOccurrenceIndex, forKey: .currentOccurrenceIndex)
        try container.encodeIfPresent(currentConfirmation, forKey: .currentConfirmation)
        try container.encode(resolutions, forKey: .resolutions)
        try container.encodeIfPresent(endedAt, forKey: .endedAt)
        try container.encodeIfPresent(
            recurrenceTimeZoneIdentifier,
            forKey: .recurrenceTimeZoneIdentifier
        )
    }

    public func validateLifecycle(calendar suppliedCalendar: Calendar? = nil) throws {
        try Task.checkCancellation()
        guard resolutions.count <= Self.maximumResolutionCount,
              seriesVersion >= 0,
              currentOccurrenceIndex >= 0,
              nextOccurrence.timeIntervalSinceReferenceDate.isFinite,
              recurrenceAnchor.timeIntervalSinceReferenceDate.isFinite,
              endedAt?.timeIntervalSinceReferenceDate.isFinite != false,
              currentConfirmation?.scheduledFor.timeIntervalSinceReferenceDate.isFinite
                != false,
              currentConfirmation?.confirmedAt.timeIntervalSinceReferenceDate.isFinite
                != false else {
            throw ScheduledTransactionError.invalidLifecycle
        }
        switch status {
        case .ended:
            guard endedAt != nil, currentConfirmation == nil else {
                throw ScheduledTransactionError.invalidLifecycle
            }
        case .active, .paused:
            guard endedAt == nil else {
                throw ScheduledTransactionError.invalidLifecycle
            }
        }

        var resolutionIDs = Set<ScheduledOccurrenceID>()
        var linkedEntryIDs = Set<UUID>()
        var currentSeriesResolutions: [ScheduledOccurrenceResolution] = []
        var previousOccurrenceID: ScheduledOccurrenceID?
        for (index, resolution) in resolutions.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            let occurrenceID = resolution.occurrenceID
            guard resolution.scheduledFor.timeIntervalSinceReferenceDate.isFinite,
                  resolution.resolvedAt.timeIntervalSinceReferenceDate.isFinite,
                  resolution.entryDeletedAt?.timeIntervalSinceReferenceDate.isFinite
                    != false,
                  occurrenceID.scheduleID == id,
                  occurrenceID.seriesVersion <= seriesVersion,
                  resolution.entryDeletedAt.map({ $0 >= resolution.resolvedAt }) ?? true,
                  resolutionIDs.insert(occurrenceID).inserted else {
                throw ScheduledTransactionError.invalidLifecycle
            }
            if let linkedEntryID = resolution.linkedEntryID,
               !linkedEntryIDs.insert(linkedEntryID).inserted {
                throw ScheduledTransactionError.invalidLifecycle
            }
            if let previousOccurrenceID {
                guard previousOccurrenceID.seriesVersion < occurrenceID.seriesVersion
                        || (previousOccurrenceID.seriesVersion == occurrenceID.seriesVersion
                            && previousOccurrenceID.index < occurrenceID.index) else {
                    throw ScheduledTransactionError.invalidLifecycle
                }
            }
            if occurrenceID.seriesVersion == seriesVersion {
                currentSeriesResolutions.append(resolution)
            }
            previousOccurrenceID = occurrenceID
        }
        guard currentSeriesResolutions.count == currentOccurrenceIndex else {
            throw ScheduledTransactionError.invalidLifecycle
        }
        for (index, resolution) in currentSeriesResolutions.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            guard resolution.occurrenceID.index == index else {
                throw ScheduledTransactionError.invalidLifecycle
            }
        }
        if let confirmation = currentConfirmation {
            guard status != .ended,
                  confirmation.occurrenceID == currentOccurrenceID,
                  confirmation.scheduledFor == nextOccurrence else {
                throw ScheduledTransactionError.invalidLifecycle
            }
        }

        var recurrenceCalendar = suppliedCalendar
        if recurrenceCalendar == nil,
           let identifier = recurrenceTimeZoneIdentifier,
           let timeZone = TimeZone(identifier: identifier) {
            var decodedCalendar = Calendar(identifier: .gregorian)
            decodedCalendar.timeZone = timeZone
            recurrenceCalendar = decodedCalendar
        }
        if let recurrenceCalendar {
            guard anchoredOccurrence(
                index: currentOccurrenceIndex,
                calendar: recurrenceCalendar
            ) == nextOccurrence else {
                throw ScheduledTransactionError.invalidLifecycle
            }
            for (index, resolution) in currentSeriesResolutions.enumerated() {
                if index.isMultiple(of: 128) { try Task.checkCancellation() }
                guard anchoredOccurrence(
                    index: resolution.occurrenceID.index,
                    calendar: recurrenceCalendar
                ) == resolution.scheduledFor else {
                    throw ScheduledTransactionError.invalidLifecycle
                }
            }
        }
        try Task.checkCancellation()
    }

    /// Returns a series edit while retaining the audit trail. Any change to the
    /// occurrence's posting or recurrence semantics starts a new version so a
    /// confirmation or stale UI created for the old terms cannot resolve it.
}
