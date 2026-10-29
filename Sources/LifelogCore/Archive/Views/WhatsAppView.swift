import Foundation

/// `WhatsApp/<chat>--<jid-hash>/_chat.md` plus `YYYY/YYYY-MM.md` with day headings. Expired, revoked and edited
/// messages stay in place with a badge; deleted ones are struck through.
enum WhatsAppView {
    static func message(_ item: ArchivedItem) -> WhatsAppArchiveMessage? {
        if case .message(let value) = item.payload { return value }
        return nil
    }

    static func ordered(_ items: [ArchivedItem]) -> [ArchivedItem] {
        items.sorted { (message($0)?.message.timestamp ?? .distantPast, $0.key.id) < (message($1)?.message.timestamp ?? .distantPast, $1.key.id) }
    }

    static func pages(_ context: ViewContext) -> [Page] {
        var pages: [Page] = []
        let chats = Dictionary(grouping: context.items(.whatsapp)) { message($0)?.chatJID ?? "" }
        for (jid, items) in chats.sorted(by: { $0.key < $1.key }) {
            guard let folder = context.chatFolders[jid] else { continue }
            let months = ArchivePages.months(items, folder: folder)
            pages.append(Page(path: "\(folder)/_chat.md", group: ExportSource.whatsapp.rawValue, keys: Set(items.map(\.key))) {
                chat(jid: jid, page: "\(folder)/_chat.md", items: items, months: months)
            })
            for month in months {
                pages.append(Page(path: month.path, group: ExportSource.whatsapp.rawValue, keys: Set(month.items.map(\.key))) {
                    page(month.items, month: month.month, context)
                })
            }
        }
        return pages
    }

    static func chat(jid: String, page: String, items: [ArchivedItem], months: [(path: String, month: String, items: [ArchivedItem])]) -> String {
        let latest = message(ordered(items).last!)!
        let dates = items.map(\.partition.date).sorted()
        var lines = ["---", "jid: \(MarkdownWriter.yaml(jid))", "title: \(MarkdownWriter.yaml(latest.chatTitle))", "kind: \(MarkdownWriter.yaml(latest.chatKind))",
                     "messages: \(items.count)", "first: \(MarkdownWriter.yaml(dates.first!))", "last: \(MarkdownWriter.yaml(dates.last!))", "---", "",
                     "# \(MarkdownWriter.line(latest.chatTitle))", "",
                     "| Month | Messages | Gone |", "|---|---:|---:|"]
        for month in months.reversed() {
            lines.append("| [\(month.month)](\(ArchivePages.link(month.path, from: page))) | \(month.items.count) | \(month.items.filter(ArchivePages.gone).count) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func page(_ items: [ArchivedItem], month: String, _ context: ViewContext) -> String {
        let title = message(ordered(items).last!)!.chatTitle
        var lines = ["# \(MarkdownWriter.line(title)) · \(month)", ""]
        for (day, messages) in ArchivePages.days(items) {
            lines += ["## \(day)", ""]
            for item in ordered(messages) { lines.append(self.line(item, context)) }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func line(_ item: ArchivedItem, _ context: ViewContext) -> String {
        let value = message(item)!.message
        let body = MarkdownWriter.messageBody(value).map(MarkdownWriter.line) ?? "[no text]"
        let time = item.partition.clock(value.timestamp)
        var text = value.isSystem == true ? "\(time) _\(body)_" : "\(time) **\(MarkdownWriter.line(value.sender)):** \(body)"
        if ArchivePages.struck(item) { text = "~~\(text)~~" }
        return "- \(text)\(ArchivePages.suffix(ArchivePages.badges(item, context)))"
    }

    static func home(_ item: ArchivedItem, _ context: ViewContext) -> Home {
        let value = message(item)!
        let folder = context.chatFolders[value.chatJID] ?? ExportSource.whatsapp.directoryName
        return Home(path: "\(folder)/\(item.partition.year)/\(item.partition.month).md", anchor: item.partition.date,
                    label: context.chatTitles[value.chatJID] ?? value.chatTitle, noun: "message")
    }

    static func summary(_ item: ArchivedItem) -> String {
        let value = message(item)!.message
        return "\(item.partition.clock(value.timestamp)) \(MarkdownWriter.line(value.sender)): \(ArchivePages.shorten(MarkdownWriter.messageBody(value) ?? "[no text]"))"
    }
}
