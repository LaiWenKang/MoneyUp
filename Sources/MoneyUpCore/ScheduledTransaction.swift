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
    public private(set) var nextOccurrence: Date
    public var frequency: RecurrenceFrequency
    public private(set) var status: ScheduledTransactionStatus
    public private(set) var recurrenceAnchor: Date
    public private(set) var seriesVersion: Int
    public private(set) var currentOccurrenceIndex: Int
    public private(set) var currentConfirmation: ScheduledOccurrenceConfirmation?
    public private(set) var resolutions: [ScheduledOccurrenceResolution]
    public private(set) var endedAt: Date?
    /// New records retain the recurrence zone so encode/decode validation and
    /// month-end anchoring remain stable when the device travels.
    public private(set) var recurrenceTimeZoneIdentifier: String?

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

    private enum CodingKeys: String, CodingKey {
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
    public func updating(
        kind: JournalEntryKind,
        name: String,
        amount: Money,
        accountID: UUID,
        categoryAccountID: UUID,
        nextOccurrence: Date,
        frequency: RecurrenceFrequency,
        recurrenceTimeZone: TimeZone? = nil
    ) throws -> ScheduledTransaction {
        let effectiveTimeZoneIdentifier = recurrenceTimeZone?.identifier
            ?? recurrenceTimeZoneIdentifier
        var updated = try ScheduledTransaction(
            id: id,
            kind: kind,
            name: name,
            amount: amount,
            accountID: accountID,
            categoryAccountID: categoryAccountID,
            nextOccurrence: nextOccurrence,
            frequency: frequency,
            recurrenceTimeZoneIdentifier: effectiveTimeZoneIdentifier
        )
        updated.status = status
        updated.endedAt = endedAt
        updated.resolutions = resolutions

        // Compare the canonical value created above. Cosmetic whitespace that
        // normalizes back to the stored name is a true no-op, while every
        // effective posting/recurrence change invalidates stale confirmation.
        let occurrenceSemanticsAreUnchanged = self.kind == updated.kind
            && self.name == updated.name
            && self.amount == updated.amount
            && self.accountID == updated.accountID
            && self.categoryAccountID == updated.categoryAccountID
            && self.nextOccurrence == updated.nextOccurrence
            && self.frequency == updated.frequency
            && recurrenceTimeZoneIdentifier
                == updated.recurrenceTimeZoneIdentifier
        if occurrenceSemanticsAreUnchanged {
            updated.recurrenceAnchor = recurrenceAnchor
            updated.seriesVersion = seriesVersion
            updated.currentOccurrenceIndex = currentOccurrenceIndex
            updated.currentConfirmation = currentConfirmation
        } else {
            let nextVersion = seriesVersion.addingReportingOverflow(1)
            guard !nextVersion.overflow else {
                throw ScheduledTransactionError.cannotAdvance
            }
            updated.seriesVersion = nextVersion.partialValue
            updated.recurrenceTimeZoneIdentifier = effectiveTimeZoneIdentifier
        }
        try updated.validateLifecycle(calendar: recurrenceTimeZone.map {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = $0
            return calendar
        })
        return updated
    }

    public mutating func pause() throws {
        guard status != .ended else { throw ScheduledTransactionError.ended }
        status = .paused
    }

    public mutating func resume() throws {
        guard status != .ended else { throw ScheduledTransactionError.ended }
        status = .active
    }

    public mutating func end(at date: Date = Date()) throws {
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw ScheduledTransactionError.invalidLifecycle
        }
        status = .ended
        endedAt = date
        currentConfirmation = nil
    }

    /// Confirmation records review but remains a forecast until posted/matched.
    public mutating func confirmCurrent(
        occurrenceID: ScheduledOccurrenceID,
        at date: Date = Date()
    ) throws {
        try requireCurrentActiveOccurrence(occurrenceID)
        guard !resolutions.contains(where: { $0.occurrenceID == occurrenceID }) else {
            throw ScheduledTransactionError.occurrenceAlreadyResolved
        }
        currentConfirmation = try ScheduledOccurrenceConfirmation(
            occurrenceID: occurrenceID,
            scheduledFor: nextOccurrence,
            confirmedAt: date
        )
    }

    /// Resolves the caller's exact occurrence and advances the recurrence.
    public mutating func resolveCurrent(
        occurrenceID: ScheduledOccurrenceID,
        as resolutionKind: ScheduledOccurrenceResolutionKind,
        linkedEntryID: UUID? = nil,
        at date: Date = Date(),
        calendar: Calendar = .current
    ) throws {
        try requireCurrentActiveOccurrence(occurrenceID)
        guard !resolutions.contains(where: { $0.occurrenceID == occurrenceID }) else {
            throw ScheduledTransactionError.occurrenceAlreadyResolved
        }
        switch resolutionKind {
        case .posted, .matched:
            guard let linkedEntryID else {
                throw ScheduledTransactionError.linkedEntryRequired
            }
            guard !resolutions.contains(where: {
                $0.linkedEntryID == linkedEntryID
            }) else {
                throw ScheduledTransactionError.invalidResolutionState
            }
        case .skipped:
            guard linkedEntryID == nil else {
                throw ScheduledTransactionError.unexpectedLinkedEntry
            }
        case .entryDeleted:
            throw ScheduledTransactionError.invalidResolutionState
        }

        let nextIndex = currentOccurrenceIndex.addingReportingOverflow(1)
        guard !nextIndex.overflow,
              let followingOccurrence = anchoredOccurrence(
                index: nextIndex.partialValue,
                calendar: calendar
              ) else {
            throw ScheduledTransactionError.cannotAdvance
        }
        recurrenceTimeZoneIdentifier = calendar.timeZone.identifier
        resolutions.append(
            try ScheduledOccurrenceResolution(
                occurrenceID: occurrenceID,
                scheduledFor: nextOccurrence,
                kind: resolutionKind,
                linkedEntryID: linkedEntryID,
                resolvedAt: date
            )
        )
        currentOccurrenceIndex = nextIndex.partialValue
        nextOccurrence = followingOccurrence
        currentConfirmation = nil
    }

    /// Atomically keeps the occurrence audit trail attached when History
    /// replaces a journal entry with a new revision identity.
    public mutating func relinkEntry(from oldID: UUID, to newID: UUID) throws {
        guard oldID != newID else {
            throw ScheduledTransactionError.invalidResolutionState
        }
        let matchingIndices = resolutions.indices.filter {
            resolutions[$0].linkedEntryID == oldID
        }
        guard !matchingIndices.isEmpty else {
            throw ScheduledTransactionError.linkedEntryNotFound
        }
        guard !resolutions.contains(where: { $0.linkedEntryID == newID }) else {
            throw ScheduledTransactionError.invalidResolutionState
        }
        for index in matchingIndices {
            let resolution = resolutions[index]
            guard resolution.kind == .posted || resolution.kind == .matched else {
                throw ScheduledTransactionError.invalidResolutionState
            }
            resolutions[index] = try ScheduledOccurrenceResolution(
                occurrenceID: resolution.occurrenceID,
                scheduledFor: resolution.scheduledFor,
                kind: resolution.kind,
                linkedEntryID: newID,
                resolvedAt: resolution.resolvedAt
            )
        }
    }

    /// Retains occurrence advancement while making deletion of the actual an
    /// explicit audit fact rather than falsely rewriting it as skipped.
    public mutating func markLinkedEntryDeleted(
        _ entryID: UUID,
        at deletedAt: Date = Date()
    ) throws {
        let matchingIndices = resolutions.indices.filter {
            resolutions[$0].linkedEntryID == entryID
        }
        guard !matchingIndices.isEmpty else {
            throw ScheduledTransactionError.linkedEntryNotFound
        }
        for index in matchingIndices {
            let resolution = resolutions[index]
            guard resolution.kind == .posted || resolution.kind == .matched else {
                throw ScheduledTransactionError.invalidResolutionState
            }
            resolutions[index] = try ScheduledOccurrenceResolution(
                occurrenceID: resolution.occurrenceID,
                scheduledFor: resolution.scheduledFor,
                kind: .entryDeleted,
                linkedEntryID: nil,
                resolvedAt: resolution.resolvedAt,
                entryDeletedAt: deletedAt
            )
        }
    }

    public func matches(_ entry: JournalEntry) -> Bool {
        guard entry.kind == kind else { return false }
        let accountAmount = kind == .expense ? amount.negated : amount
        let categoryAmount = accountAmount.negated
        return entry.postings.contains {
            $0.accountID == accountID && $0.money == accountAmount
        } && entry.postings.contains {
            $0.accountID == categoryAccountID && $0.money == categoryAmount
        }
    }

    public func occurrences(
        through endDate: Date,
        calendar: Calendar = .current,
        maximumCount: Int = 120
    ) -> [Date] {
        guard isActive, maximumCount > 0, nextOccurrence <= endDate else {
            return []
        }
        var dates: [Date] = []
        var offset = 0
        while dates.count < maximumCount,
              let candidate = occurrence(offset: offset, calendar: calendar),
              candidate <= endDate {
            dates.append(candidate)
            offset += 1
        }
        return dates
    }

    public func occurrence(
        onOrAfter referenceDate: Date,
        calendar: Calendar = .current
    ) -> Date? {
        guard isActive else { return nil }
        guard referenceDate > nextOccurrence else { return nextOccurrence }
        let absoluteOffset = estimatedAnchorOffset(
            onOrAfter: referenceDate,
            calendar: calendar
        )
        let candidateIndex = max(currentOccurrenceIndex, absoluteOffset)
        guard let candidate = anchoredOccurrence(index: candidateIndex, calendar: calendar) else {
            return nil
        }
        if candidate >= referenceDate { return candidate }
        let followingIndex = candidateIndex.addingReportingOverflow(1)
        guard !followingIndex.overflow else { return nil }
        return anchoredOccurrence(
            index: followingIndex.partialValue,
            calendar: calendar
        )
    }

    public func occurs(on date: Date, calendar: Calendar = .current) -> Bool {
        guard isActive,
              calendar.startOfDay(for: date) >= calendar.startOfDay(for: nextOccurrence)
        else { return false }

        let absoluteOffset: Int
        switch frequency {
        case .weekly:
            let days = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: recurrenceAnchor),
                to: calendar.startOfDay(for: date)
            ).day ?? -1
            guard days >= 0, days.isMultiple(of: 7) else { return false }
            absoluteOffset = days / 7
        case .monthly, .yearly:
            guard let anchorMonth = calendar.dateInterval(
                of: .month,
                for: recurrenceAnchor
            )?.start,
            let targetMonth = calendar.dateInterval(of: .month, for: date)?.start else {
                return false
            }
            let months = calendar.dateComponents(
                [.month],
                from: anchorMonth,
                to: targetMonth
            ).month ?? -1
            guard months >= 0 else { return false }
            if frequency == .yearly {
                guard months.isMultiple(of: 12) else { return false }
                absoluteOffset = months / 12
            } else {
                absoluteOffset = months
            }
        }
        guard absoluteOffset >= currentOccurrenceIndex,
              let candidate = anchoredOccurrence(index: absoluteOffset, calendar: calendar)
        else { return false }
        return calendar.isDate(candidate, inSameDayAs: date)
    }

    private func requireCurrentActiveOccurrence(
        _ occurrenceID: ScheduledOccurrenceID
    ) throws {
        guard status != .ended else { throw ScheduledTransactionError.ended }
        guard status == .active else { throw ScheduledTransactionError.inactive }
        guard occurrenceID == currentOccurrenceID else {
            throw ScheduledTransactionError.staleOccurrence
        }
    }

    private func estimatedAnchorOffset(
        onOrAfter referenceDate: Date,
        calendar: Calendar
    ) -> Int {
        switch frequency {
        case .weekly:
            let days = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: recurrenceAnchor),
                to: calendar.startOfDay(for: referenceDate)
            ).day ?? 0
            return max(0, days / 7)
        case .monthly, .yearly:
            guard let anchorMonth = calendar.dateInterval(
                of: .month,
                for: recurrenceAnchor
            )?.start,
            let referenceMonth = calendar.dateInterval(
                of: .month,
                for: referenceDate
            )?.start else { return currentOccurrenceIndex }
            let months = calendar.dateComponents(
                [.month],
                from: anchorMonth,
                to: referenceMonth
            ).month ?? 0
            return frequency == .monthly ? max(0, months) : max(0, months / 12)
        }
    }

    private func occurrence(offset: Int, calendar: Calendar) -> Date? {
        guard offset >= 0 else { return nil }
        let index = currentOccurrenceIndex.addingReportingOverflow(offset)
        guard !index.overflow else { return nil }
        return anchoredOccurrence(index: index.partialValue, calendar: calendar)
    }

    private func anchoredOccurrence(index: Int, calendar: Calendar) -> Date? {
        guard index >= 0 else { return nil }
        if index == 0 { return recurrenceAnchor }
        switch frequency {
        case .weekly:
            return calendar.date(
                byAdding: .weekOfYear,
                value: index,
                to: recurrenceAnchor
            )
        case .monthly:
            return monthAnchoredOccurrence(monthOffset: index, calendar: calendar)
        case .yearly:
            let multiplication = index.multipliedReportingOverflow(by: 12)
            guard !multiplication.overflow else { return nil }
            return monthAnchoredOccurrence(
                monthOffset: multiplication.partialValue,
                calendar: calendar
            )
        }
    }

    private func monthAnchoredOccurrence(
        monthOffset: Int,
        calendar: Calendar
    ) -> Date? {
        guard let anchorMonth = calendar.dateInterval(
            of: .month,
            for: recurrenceAnchor
        )?.start,
        let targetMonth = calendar.date(
            byAdding: .month,
            value: monthOffset,
            to: anchorMonth
        ),
        let validDays = calendar.range(of: .day, in: .month, for: targetMonth),
        let lastDay = validDays.last else { return nil }

        let anchor = calendar.dateComponents(
            [.day, .hour, .minute, .second, .nanosecond],
            from: recurrenceAnchor
        )
        guard let anchorDay = anchor.day else { return nil }
        var target = calendar.dateComponents([.era, .year, .month], from: targetMonth)
        target.day = min(anchorDay, lastDay)
        target.hour = anchor.hour
        target.minute = anchor.minute
        target.second = anchor.second
        target.nanosecond = anchor.nanosecond
        return calendar.date(from: target)
    }
}
