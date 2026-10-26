import Foundation

/// `Reminders/open.md` lists open reminders by list. Completed reminders go to the month of completion, and gone
/// ones to the month they were noticed gone (decision 10): `Reminders/YYYY/YYYY-MM.md`.
enum RemindersView {
    static let folder = ExportSource.reminders.directoryName
    static let openPath = "\(folder)/open.md"

    static func reminder(_ item: ArchivedItem) -> ReminderRecord? {
        if case .reminder(let value) = item.payload { return value }
        return nil
    }

    static func isOpen(_ item: ArchivedItem) -> Bool { reminder(item)?.isCompleted == false && !ArchivePages.gone(item) }

    /// The civil date a filed reminder sits under: noticed gone, else completed. Nil for open reminders.
    static func filed(_ item: ArchivedItem) -> String? {
        if ArchivePages.gone(item) { return item.partition.day(item.stateSince) }
        return reminder(item)?.isCompleted == true ? item.partition.date : nil
    }

    static func pages(_ context: ViewContext) -> [Page] {
        let items = context.items(.reminders)
        guard !items.isEmpty else { return [] }
        let open = items.filter(isOpen)
        var pages = [Page(path: openPath, group: ExportSource.reminders.rawValue, keys: Set(open.map(\.key))) { openPage(open, context) }]
        for month in ArchivePages.months(items.filter { filed($0) != nil }, folder: folder, month: { String(filed($0)!.prefix(7)) }) {
            pages.append(Page(path: month.path, group: ExportSource.reminders.rawValue, keys: Set(month.items.map(\.key))) {
                page(month.items, month: month.month, context)
            })
        }
        return pages
    }

    static func openPage(_ items: [ArchivedItem], _ context: ViewContext) -> String {
        var lines = ["# Open reminders", ""]
        if items.isEmpty { lines += ["No open reminders.", ""] }
        for (list, reminders) in Dictionary(grouping: items, by: { reminder($0)!.list }).sorted(by: { $0.key < $1.key }) {
            lines += ["## \(MarkdownWriter.line(list))", ""]
            let sorted = reminders.sorted {
                let a = reminder($0)!, b = reminder($1)!
                return (a.due ?? "~", a.title, $0.key.id) < (b.due ?? "~", b.title, $1.key.id)
            }
            for item in sorted { lines += self.lines(item, context, list: false) }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func page(_ items: [ArchivedItem], month: String, _ context: ViewContext) -> String {
        var lines = ["# Reminders · \(month)", ""]
        for (day, reminders) in ArchivePages.days(items, date: { filed($0)! }) {
            lines += ["## \(day)", ""]
            let sorted = reminders.sorted {
                let a = reminder($0)!, b = reminder($1)!
                return (a.completionDate ?? $0.stateSince, a.title, $0.key.id) < (b.completionDate ?? $1.stateSince, b.title, $1.key.id)
            }
            for item in sorted { lines += self.lines(item, context, list: true) }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func lines(_ item: ArchivedItem, _ context: ViewContext, list: Bool) -> [String] {
        let value = reminder(item)!
        var text = "[\(value.isCompleted ? "x" : " ")] "
        if value.isCompleted, !ArchivePages.gone(item), let done = value.completionDate { text += item.partition.clock(done) + " " }
        text += MarkdownWriter.line(value.title)
        if ArchivePages.struck(item) { text = "~~\(text)~~" }
        var meta = list ? " · \(MarkdownWriter.line(value.list))" : ""
        if let due = value.due { meta += " · due \(MarkdownWriter.line(due))" }
        if value.priority != 0 { meta += " · priority \(value.priority)" }
        var lines = ["- \(text)\(meta)\(ArchivePages.suffix(ArchivePages.badges(item, context)))"]
        if let notes = value.notes, !notes.isEmpty { lines.append("  - \(MarkdownWriter.line(notes))") }
        if let url = value.url { lines.append("  - \(MarkdownWriter.line(url))") }
        return lines
    }

    static func home(_ item: ArchivedItem, _ context: ViewContext) -> Home {
        guard let day = filed(item) else { return Home(path: openPath, anchor: nil, label: "Open reminders", noun: "reminder") }
        return Home(path: "\(folder)/\(day.prefix(4))/\(day.prefix(7)).md", anchor: day, label: "Reminders", noun: "reminder")
    }

    static func summary(_ item: ArchivedItem) -> String {
        let value = reminder(item)!
        return "\(ArchivePages.shorten(value.title)) (\(MarkdownWriter.line(value.list)))"
    }
}
