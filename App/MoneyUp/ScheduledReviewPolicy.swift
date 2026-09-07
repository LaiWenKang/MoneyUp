import MoneyUpCore

/// Review the earliest unresolved active occurrence. Asking for a future
/// recurrence would hide an overdue item as soon as its scheduled time passed.
enum ScheduledReviewPolicy {
    static func next(in schedules: [ScheduledTransaction]) -> ScheduledTransaction? {
        schedules.filter { $0.status == .active }.min {
            if $0.nextOccurrence != $1.nextOccurrence { return $0.nextOccurrence < $1.nextOccurrence }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}
