import Foundation

public enum AwakeDeadline {
    public static func make(startedAt: Date, duration: LidAwakeDuration) -> Date? {
        duration.seconds.map { startedAt.addingTimeInterval($0) }
    }

    public static func remaining(until deadline: Date, now: Date = Date()) -> TimeInterval {
        max(0, deadline.timeIntervalSince(now))
    }

    /// Round up so caffeinate cannot release before the shared absolute deadline.
    /// The app and helper also enforce that deadline independently.
    public static func timeoutSeconds(until deadline: Date, now: Date = Date()) -> Int {
        max(1, Int(ceil(remaining(until: deadline, now: now))))
    }
}
