import Foundation

/// One page per ChatGPT, Claude or Claude Code conversation: `<Service>/YYYY/YYYY-MM/<title>--<id-hash>.md`, by the month
/// of its first message. Messages are the archived items, so a chat grows and its states show per message.
enum AIChatView {
    static let sources: [ArchiveSource] = [.chatgpt, .claude, .claudecode]

    static func message(_ item: ArchivedItem) -> AIArchiveMessage? {
        if case .aiMessage(let value) = item.payload { return value }
        return nil
    }

    static func ordered(_ items: [ArchivedItem]) -> [ArchivedItem] {
        func time(_ item: ArchivedItem) -> Date { message(item)?.message.timestamp ?? item.firstSeen ?? item.stateSince }
        return items.sorted { (time($0), $0.key.id) < (time($1), $1.key.id) }
    }

    /// Page path and latest title per chat, keyed by `<source>/<chat id>`.
    static func chats(_ items: [ArchiveSource: [ArchivedItem]]) -> (paths: [String: String], titles: [String: String]) {
        var paths: [String: String] = [:], titles: [String: String] = [:]
        for source in sources {
            for (chat, items) in Dictionary(grouping: items[source] ?? [], by: { message($0)?.chatID ?? "" }) {
                let sorted = ordered(items)
                let month = sorted.map(\.partition.month).min()!
                let title = message(sorted.last!)!.chatTitle
                paths["\(source.rawValue)/\(chat)"] = "\(source.directoryName)/\(month.prefix(4))/\(month)/\(MarkdownWriter.hashedName(title, id: chat)).md"
                titles["\(source.rawValue)/\(chat)"] = title
            }
        }
        return (paths, titles)
    }

    static func pages(_ context: ViewContext) -> [Page] {
        var pages: [Page] = []
        for source in sources {
            for (chat, items) in Dictionary(grouping: context.items(source), by: { message($0)?.chatID ?? "" }).sorted(by: { $0.key < $1.key }) {
                pages.append(Page(path: context.aiChatPaths["\(source.rawValue)/\(chat)"]!, group: source.rawValue, keys: Set(items.map(\.key))) {
                    page(ordered(items), source: source, context)
                })
            }
        }
        return pages
    }

    static func page(_ items: [ArchivedItem], source: ArchiveSource, _ context: ViewContext) -> String {
        let latest = message(items.last!)!
        let yaml = MarkdownWriter.yaml
        var lines = ["---", "service: \(yaml(source.displayName))", "chat_id: \(yaml(latest.chatID))", "title: \(yaml(latest.chatTitle))"]
        if let project = latest.project { lines.append("project: \(yaml(project))") }
        lines += ["messages: \(items.count)", "---", "", "# \(MarkdownWriter.line(latest.chatTitle))", ""]
        for item in items {
            let value = message(item)!.message
            var heading = value.timestamp.map { "\(item.partition.day($0)) \(item.partition.clock($0)) · " } ?? ""
            heading += MarkdownWriter.line(value.role)
            if let model = value.model { heading += " (\(MarkdownWriter.line(model)))" }
            let text = ArchivePages.struck(item) ? "~~\(value.text)~~" : value.text
            lines += ["## \(heading)\(ArchivePages.suffix(ArchivePages.badges(item, context)))", "", text, ""]
            if !value.attachments.isEmpty { lines += value.attachments.map { "- \(MarkdownWriter.line($0))" } + [""] }
        }
        return lines.joined(separator: "\n")
    }

    static func home(_ item: ArchivedItem, _ context: ViewContext) -> Home {
        let value = message(item)!
        let path = context.aiChatPaths["\(item.key.source.rawValue)/\(value.chatID)"] ?? item.key.source.directoryName
        return Home(path: path, anchor: nil, label: context.aiChatTitles["\(item.key.source.rawValue)/\(value.chatID)"] ?? value.chatTitle, noun: "message")
    }

    static func summary(_ item: ArchivedItem) -> String {
        let value = message(item)!
        return "\(ArchivePages.shorten(value.chatTitle, 60)), \(MarkdownWriter.line(value.message.role)): \(ArchivePages.shorten(value.message.text))"
    }
}
