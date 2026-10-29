import Foundation

/// `Calendar/YYYY/YYYY-MM.md` by occurrence start. Deleted events are struck through; cancelled, declined, tentative
/// and rescheduled events are labelled, and a reschedule shows the old time (decision 11).
enum CalendarView {
    static let folder = ExportSource.calendar.directoryName

    static func event(_ item: ArchivedItem) -> CalendarRecord? {
        if case .event(let value) = item.payload { return value }
        return nil
    }

    static func pages(_ context: ViewContext) -> [Page] {
        ArchivePages.months(context.items(.calendar), folder: folder).map { month in
            Page(path: month.path, group: ExportSource.calendar.rawValue, keys: Set(month.items.map(\.key))) { page(month.items, month: month.month, context) }
        }
    }

    static func page(_ items: [ArchivedItem], month: String, _ context: ViewContext) -> String {
        var lines = ["# Calendar · \(month)", ""]
        for (day, events) in ArchivePages.days(items) {
            lines += ["## \(day)", ""]
            let sorted = events.sorted {
                let a = event($0)!, b = event($1)!
                return (a.isAllDay ? 0 : 1, a.start, a.title, $0.key.id) < (b.isAllDay ? 0 : 1, b.start, b.title, $1.key.id)
            }
            for item in sorted { lines += self.lines(item, context) }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func lines(_ item: ArchivedItem, _ context: ViewContext) -> [String] {
        let value = event(item)!
        var text = "\(time(item, value)) \(MarkdownWriter.line(value.title))"
        if ArchivePages.struck(item) { text = "~~\(text)~~" }
        var meta = " · \(MarkdownWriter.line(value.calendar))"
        if value.isAllDay, let last = lastDay(value) { meta += " · until \(last)" }
        if let location = value.location, !location.isEmpty { meta += " · \(MarkdownWriter.line(location))" }
        var lines = ["- \(text)\(meta)\(ArchivePages.suffix(labels(item, value) + ArchivePages.badges(item, context)))"]
        if let notes = value.notes, !notes.isEmpty { lines.append("  - \(MarkdownWriter.line(notes))") }
        if let url = value.url { lines.append("  - \(MarkdownWriter.line(url))") }
        return lines
    }

    /// `10:00–11:00`, `all day`, or `23:00–2026-10-29 01:00` across midnight.
    static func time(_ item: ArchivedItem, _ value: CalendarRecord) -> String {
        if value.isAllDay { return "all day" }
        return "\(item.partition.clock(value.start))–\(moment(value.end, item, value))"
    }

    /// A time in the event's own zone, with its date when that is not the event's day.
    static func moment(_ date: Date, _ item: ArchivedItem, _ value: CalendarRecord) -> String {
        let offset = value.timeZone.flatMap(TimeZone.init(identifier:))?.secondsFromGMT(for: date) ?? item.partition.utcOffset
        let day = Partition.day(date, utcOffset: offset)
        return (day == item.partition.date ? "" : day + " ") + Partition.clock(date, utcOffset: offset)
    }

    /// The last day of a multi-day all-day event.
    static func lastDay(_ value: CalendarRecord) -> String? {
        guard let start = value.startDate, let end = value.endDate, let last = previousDay(end), last > start else { return nil }
        return last
    }

    /// All-day end dates are exclusive.
    static func previousDay(_ date: String) -> String? {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let day = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        return Partition.day(day - 86_400, utcOffset: 0)
    }

    static func labels(_ item: ArchivedItem, _ value: CalendarRecord) -> [String] {
        var labels: [String] = []
        if value.status == "cancelled" { labels.append("cancelled") }
        if let participation = value.participation, participation == "declined" || participation == "tentative" {
            let was = item.flags.participationFrom.map { $0 != "none" && $0 != participation ? " (was \($0))" : "" } ?? ""
            labels.append(participation + was)
        }
        if let from = item.flags.rescheduledFrom, let old = JSONLines.timestamp.date(from: from) ?? ISO8601DateFormatter().date(from: from) {
            labels.append(value.isAllDay ? "rescheduled from \(item.partition.day(old))" : "rescheduled from \(moment(old, item, value))")
        }
        return labels
    }

    static func home(_ item: ArchivedItem) -> Home {
        Home(path: "\(folder)/\(item.partition.year)/\(item.partition.month).md", anchor: item.partition.date, label: "Calendar", noun: "event")
    }

    static func summary(_ item: ArchivedItem) -> String {
        let value = event(item)!
        return "\(item.partition.date) \(time(item, value)) \(ArchivePages.shorten(value.title))"
    }
}
