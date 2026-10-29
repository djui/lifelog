import Foundation

/// `_Disappeared/YYYY/YYYY-MM.md`: every item that became trashed, deleted, expired, revoked or unknown that month,
/// by source, with the last text, when it was last seen and noticed, and a link to where it stays in place (decision 8).
enum DisappearedView {
    static let folder = "_Disappeared"

    static func pages(_ context: ViewContext) -> [Page] {
        let items = ArchiveSource.allCases.flatMap { context.items($0) }.filter(ArchivePages.gone)
        return ArchivePages.months(items, folder: folder, month: { String(context.day($0.stateSince).prefix(7)) }).map { month in
            Page(path: month.path, group: "disappeared", keys: Set(month.items.map(\.key))) { page(month.items, path: month.path, month: month.month, context) }
        }
    }

    static func page(_ items: [ArchivedItem], path: String, month: String, _ context: ViewContext) -> String {
        var lines = ["# Disappeared · \(month)", "",
                     "\(items.count) item\(items.count == 1 ? "" : "s") noticed as trashed, deleted, expired, revoked or unknown this month. "
                     + "Each stays in place on its page, with the last text the archive saw.", ""]
        for source in ArchiveSource.allCases {
            let shown = items.filter { $0.key.source == source }.sorted { ($0.stateSince, $0.key) < ($1.stateSince, $1.key) }
            guard !shown.isEmpty else { continue }
            lines += ["## \(source.displayName)", ""]
            for item in shown {
                let home = ArchivePages.home(item, context)
                let link = ArchivePages.link(home.path, from: path, anchor: home.anchor)
                var line = "- **\(item.state.rawValue)** [\(ArchivePages.label(home.label))](\(link)): \(summary(item))"
                let seen = context.lastSeen(item).map { "last seen \(context.moment($0)), " } ?? ""
                line += " · \(seen)noticed \(context.moment(item.stateSince))"
                if let reason = item.reason { line += " · \(MarkdownWriter.line(reason))" }
                lines.append(line)
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func summary(_ item: ArchivedItem) -> String {
        switch item.payload {
        case .message: return WhatsAppView.summary(item)
        case .event: return CalendarView.summary(item)
        case .reminder: return RemindersView.summary(item)
        case .note: return NotesView.summary(item)
        case .aiMessage: return AIChatView.summary(item)
        }
    }
}
