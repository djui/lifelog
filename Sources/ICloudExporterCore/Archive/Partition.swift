import Foundation

/// Civil dates for the views (decision 15). Each item stores the UTC offset that produced its date: the event's own
/// time zone for calendar items, and the Mac's time zone at capture for everything else (recorded per run in the run
/// log). Views format every item time with that stored offset, so a page reads the same on any Mac and in any zone.
extension Partition {
    /// The civil date of `instant` at a fixed offset.
    public init(_ instant: Date, utcOffset: Int) { self.init(date: Self.day(instant, utcOffset: utcOffset), utcOffset: utcOffset) }

    /// The civil date of `instant` in `timeZone`, with the offset in effect at that instant (so DST is respected).
    public init(_ instant: Date, timeZone: TimeZone) { self.init(instant, utcOffset: timeZone.secondsFromGMT(for: instant)) }

    /// The date an item belongs to. Notes by last edit, reminders by completion (else creation), events by their start
    /// in their own zone (all-day ones by their civil start date), messages by their timestamp.
    public static func of(_ payload: ArchivePayload, fallback: Date, timeZone: TimeZone = .current) -> Partition {
        switch payload {
        case .note(let note): return Partition(note.modified ?? note.created ?? fallback, timeZone: timeZone)
        case .reminder(let reminder): return Partition(reminder.completionDate ?? reminder.created ?? fallback, timeZone: timeZone)
        case .event(let event):
            if event.isAllDay, let day = event.startDate { return Partition(date: day, utcOffset: timeZone.secondsFromGMT(for: event.start)) }
            return Partition(event.start, timeZone: event.timeZone.flatMap(TimeZone.init(identifier:)) ?? timeZone)
        case .message(let value): return Partition(value.message.timestamp, timeZone: timeZone)
        case .aiMessage(let value): return Partition(value.message.timestamp ?? fallback, timeZone: timeZone)
        }
    }

    /// `YYYY-MM`.
    public var month: String { String(date.prefix(7)) }
    /// `YYYY`.
    public var year: String { String(date.prefix(4)) }

    /// `HH:mm` of `instant` at this partition's offset.
    public func clock(_ instant: Date) -> String { Self.clock(instant, utcOffset: utcOffset) }
    /// `YYYY-MM-DD` of `instant` at this partition's offset.
    public func day(_ instant: Date) -> String { Self.day(instant, utcOffset: utcOffset) }

    // Plain arithmetic instead of formatters: pages format every message, and the result must not depend on the Mac.

    public static func day(_ instant: Date, utcOffset: Int) -> String {
        let civil = civil(instant, utcOffset: utcOffset)
        return String(format: "%04d-%02d-%02d", civil.year, civil.month, civil.day)
    }

    public static func clock(_ instant: Date, utcOffset: Int) -> String {
        let second = civil(instant, utcOffset: utcOffset).second
        return String(format: "%02d:%02d", second / 3600, second % 3600 / 60)
    }

    /// ISO 8601 with the offset, such as `2026-10-25T21:40:00+01:00`.
    public static func iso(_ instant: Date, utcOffset: Int) -> String {
        let second = civil(instant, utcOffset: utcOffset).second
        let offset = abs(utcOffset)
        return day(instant, utcOffset: utcOffset) + String(format: "T%02d:%02d:%02d%@%02d:%02d", second / 3600, second % 3600 / 60, second % 60,
                                                            utcOffset < 0 ? "-" : "+", offset / 3600, offset % 3600 / 60)
    }

    /// Gregorian date and second of the day (H. Hinnant's days-to-civil algorithm).
    static func civil(_ instant: Date, utcOffset: Int) -> (year: Int, month: Int, day: Int, second: Int) {
        let t = Int(floor(instant.timeIntervalSince1970)) + utcOffset
        let days = t >= 0 ? t / 86_400 : (t - 86_399) / 86_400
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, doy - (153 * mp + 2) / 5 + 1, t - days * 86_400)
    }
}
