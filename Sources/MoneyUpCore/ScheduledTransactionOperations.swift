import Foundation

extension ScheduledTransaction {
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

    func requireCurrentActiveOccurrence(
        _ occurrenceID: ScheduledOccurrenceID
    ) throws {
        guard status != .ended else { throw ScheduledTransactionError.ended }
        guard status == .active else { throw ScheduledTransactionError.inactive }
        guard occurrenceID == currentOccurrenceID else {
            throw ScheduledTransactionError.staleOccurrence
        }
    }

    func estimatedAnchorOffset(
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

    func occurrence(offset: Int, calendar: Calendar) -> Date? {
        guard offset >= 0 else { return nil }
        let index = currentOccurrenceIndex.addingReportingOverflow(offset)
        guard !index.overflow else { return nil }
        return anchoredOccurrence(index: index.partialValue, calendar: calendar)
    }

    func anchoredOccurrence(index: Int, calendar: Calendar) -> Date? {
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

    func monthAnchoredOccurrence(
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
