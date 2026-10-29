import Foundation

/// `Timeline/YYYY/YYYY-MM.md`: per day and across sources, links to where that day's messages, events, reminders,
/// notes and AI chats are shown (decisions 13/14 and 16).
enum TimelineView {
    static let folder = "Timeline"

    static func pages(_ context: ViewContext) -> [Page] {
        let items = ArchiveSource.allCases.flatMap { context.items($0) }
        return ArchivePages.months(items, folder: folder).map { month in
            Page(path: month.path, group: "timeline", keys: Set(month.items.map(\.key))) { page(month.items, path: month.path, month: month.month, context) }
        }
    }

    static func page(_ items: [ArchivedItem], path: String, month: String, _ context: ViewContext) -> String {
        var lines = ["# Timeline · \(month)", ""]
        for (day, entries) in ArchivePages.days(items) {
            lines += ["## \(day)", ""]
            for source in ArchiveSource.allCases {
                let homes = Dictionary(grouping: entries.filter { $0.key.source == source }) { ArchivePages.home($0, context) }
                for (home, shown) in homes.sorted(by: { ($0.key.label, $0.key.path, $0.key.anchor ?? "") < ($1.key.label, $1.key.path, $1.key.anchor ?? "") }) {
                    let link = ArchivePages.link(home.path, from: path, anchor: home.anchor)
                    lines.append("- \(source.displayName): [\(ArchivePages.label(home.label))](\(link)) · \(detail(shown, home: home, day: day))")
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// `3 messages, 1 gone`, or for a note `edited` / `created`.
    static func detail(_ items: [ArchivedItem], home: Home, day: String) -> String {
        let gone = items.filter(ArchivePages.gone).count
        var text: String
        if items.count == 1, let note = NotesView.note(items[0]) {
            text = note.created.map { items[0].partition.day($0) == day } == true ? "created" : "edited"
        } else {
            text = "\(items.count) \(home.noun)\(items.count == 1 ? "" : "s")"
        }
        if gone > 0 { text += ", \(gone) gone" }
        return text
    }
}
