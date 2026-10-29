import Foundation

/// One page per note at its current account/folder path, as in `export` (decision 16). Front-matter carries the state,
/// when the note was last seen and noticed gone, and the folder id (two folders can share a name). Deleted, trashed and
/// locked notes stay in place with a banner and the last text the archive saw (decisions 8 and 9).
enum NotesView {
    static func note(_ item: ArchivedItem) -> NoteRecord? {
        if case .note(let value) = item.payload { return value }
        return nil
    }

    static func pages(_ context: ViewContext) -> [Page] {
        context.items(.notes).map { item in
            Page(path: MarkdownWriter.notePath(note(item)!), group: ExportSource.notes.rawValue, keys: [item.key]) { page(item, context) }
        }
    }

    static func page(_ item: ArchivedItem, _ context: ViewContext) -> String {
        let value = note(item)!
        let yaml = MarkdownWriter.yaml
        var lines = ["---", "apple_id: \(yaml(value.id))", "account: \(yaml(value.account))", "folder: \(yaml(value.folder))"]
        if let folderID = value.folderID { lines.append("folder_id: \(yaml(folderID))") }
        if let created = value.created { lines.append("created: \(yaml(context.captured(created, item)))") }
        if let modified = value.modified { lines.append("modified: \(yaml(context.captured(modified, item)))") }
        lines.append("state: \(yaml(item.state.rawValue))")
        if let seen = context.lastSeen(item) { lines.append("last_seen: \(yaml(context.iso(seen)))") }
        if item.state != .active { lines.append("noticed: \(yaml(context.iso(item.stateSince)))") }
        if let reason = item.reason, item.state != .active { lines.append("reason: \(yaml(reason))") }
        if let missing = item.missingSince { lines.append("missing_since: \(yaml(context.iso(missing)))") }
        lines += ["---", ""]
        if let banner = banner(item, context) { lines += [banner, ""] }
        lines += ["# \(MarkdownWriter.line(value.title))", "", NotesHTML.markdown(from: value.bodyHTML), ""]
        return lines.joined(separator: "\n")
    }

    static func banner(_ item: ArchivedItem, _ context: ViewContext) -> String? {
        let seen = context.lastSeen(item).map { "last seen \(context.moment($0)), " } ?? ""
        let noticed = "noticed \(context.moment(item.stateSince))"
        switch item.state {
        case .deleted, .expired, .unknown, .trashed:
            let what = item.state == .unknown ? "Unaccounted for" : item.state.rawValue.prefix(1).uppercased() + item.state.rawValue.dropFirst()
            return "> **\(what)** in Notes: \(seen)\(noticed). This is the last text the archive saw."
        case .locked:
            return "> **Locked** in Notes since \(context.moment(item.stateSince)). The text below is the last one seen before it was locked, if any."
        default:
            guard let missing = item.missingSince else { return nil }
            return "> **Missing** from Notes since \(context.moment(missing)), not yet confirmed as deleted."
        }
    }

    static func home(_ note: NoteRecord) -> Home { Home(path: MarkdownWriter.notePath(note), anchor: nil, label: note.title, noun: "note") }

    static func summary(_ item: ArchivedItem) -> String {
        let value = note(item)!
        return "\(ArchivePages.shorten(value.title)) (\(MarkdownWriter.line(value.folder)))"
    }
}
