import Foundation
import CryptoKit

public struct ExportDocument {
    public var path: String
    public var content: String
    public var source: ExportSource
}

public enum MarkdownWriter {
    public static func timestamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    static func yaml(_ value: String) -> String {
        // JSON double-quoted strings are valid YAML scalars, including embedded newlines.
        String(data: try! JSONEncoder().encode(value), encoding: .utf8)!
    }

    static func line(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    public static func safeComponent(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?*\"<>|").union(.controlCharacters)
        let replaced = value.unicodeScalars.map { forbidden.contains($0) ? "-" : String($0) }.joined()
        // A case-only rename must resolve to the same path on macOS volumes.
        let trimmed = replaced.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        var result = ""
        for character in trimmed {
            guard result.utf8.count + String(character).utf8.count <= 100 else { break }
            result.append(character)
        }
        return result.isEmpty ? "untitled" : result
    }

    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    public static func documents(snapshot: ExportSnapshot, config: Config, now: Date) throws -> [ExportDocument] {
        var documents: [ExportDocument] = []
        if config.sources.contains(.notes) {
            var ids = Set<String>()
            for note in snapshot.notes.sorted(by: { $0.id < $1.id }) {
                guard !note.id.isEmpty, ids.insert(note.id).inserted else { throw ExportError.message("Notes returned a missing or duplicate identifier; export stopped.") }
                let folders = note.folder.split(separator: "/").map { safeComponent(String($0)) }
                let path = (["Notes", safeComponent(note.account)] + folders + [safeComponent(note.title) + "--" + digest(Data(note.id.utf8)).prefix(16) + ".md"]).joined(separator: "/")
                var meta = ["---", "apple_id: \(yaml(note.id))", "account: \(yaml(note.account))", "folder: \(yaml(note.folder))"]
                if let created = note.created { meta.append("created: \(yaml(timestamp(created)))") }
                if let modified = note.modified { meta.append("modified: \(yaml(timestamp(modified)))") }
                let content = (meta + ["---", "", "# \(line(note.title))", "", NotesHTML.markdown(from: note.bodyHTML), ""]).joined(separator: "\n")
                documents.append(ExportDocument(path: path, content: content, source: .notes))
            }
        }
        if config.sources.contains(.reminders) {
            let sorted = snapshot.reminders.sorted { ($0.list, $0.due ?? "~", $0.title, $0.id) < ($1.list, $1.due ?? "~", $1.title, $1.id) }
            documents.append(ExportDocument(path: "Reminders/current-reminders.md", content: reminders(sorted.filter { !$0.isCompleted }, title: "Current reminders"), source: .reminders))
            documents.append(ExportDocument(path: "Reminders/completed-recent.md", content: reminders(sorted.filter { $0.isCompleted }, title: "Reminders completed in the last \(config.completedDays) days"), source: .reminders))
        }
        if config.sources.contains(.calendar) {
            let sorted = snapshot.events.sorted { ($0.start, $0.calendar, $0.id) < ($1.start, $1.calendar, $1.id) }
            let window = config.window(now: now)
            documents.append(ExportDocument(path: "Calendar/recent-\(config.pastDays)-days.md", content: events(sorted.filter { $0.start < now && $0.end > window.start }, title: "Calendar: recent \(config.pastDays) days", from: window.start, to: now), source: .calendar))
            documents.append(ExportDocument(path: "Calendar/upcoming-\(config.futureDays)-days.md", content: events(sorted.filter { $0.end > now && $0.start < window.end }, title: "Calendar: upcoming \(config.futureDays) days", from: now, to: window.end), source: .calendar))
        }
        if config.sources.contains(.whatsapp) {
            var ids = Set<String>()
            for chat in snapshot.chats.sorted(by: { $0.id < $1.id }) {
                guard !chat.id.isEmpty, ids.insert(chat.id).inserted else { throw ExportError.message("WhatsApp returned a missing or duplicate identifier; export stopped.") }
                let path = [ExportSource.whatsapp.directoryName, safeComponent(chat.title) + "--" + digest(Data(chat.id.utf8)).prefix(16) + ".md"].joined(separator: "/")
                let meta = ["---", "chat_id: \(yaml(chat.id))", "title: \(yaml(chat.title))", "kind: \(yaml(chat.kind))", "jid: \(yaml(chat.jid))", "---"]
                documents.append(ExportDocument(path: path, content: chatMarkdown(chat, meta: meta), source: .whatsapp))
            }
        }
        guard Set(documents.map(\.path)).count == documents.count else { throw ExportError.message("Export filenames collide; no files were written.") }
        return documents
    }

    static func reminders(_ records: [ReminderRecord], title: String) -> String {
        var lines = ["# \(title)", ""]
        if records.isEmpty { lines.append("No reminders in this view.") }
        for item in records {
            lines += ["## \(line(item.title))", "", "- Completed: \(item.isCompleted ? "yes" : "no")", "- List: \(line(item.list))", "- Apple ID: \(line(item.id))"]
            if let due = item.due { lines.append("- Due: \(line(due))") }
            if let completed = item.completionDate { lines.append("- Completed at: \(timestamp(completed))") }
            if item.priority != 0 { lines.append("- Priority: \(item.priority) (1 highest, 9 lowest)") }
            if let url = item.url { lines.append("- URL: \(line(url))") }
            if let notes = item.notes, !notes.isEmpty { lines += ["", notes] }
            lines.append("")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func events(_ records: [CalendarRecord], title: String, from: Date, to: Date) -> String {
        var lines = ["# \(title)", "", "Window: \(timestamp(from)) to \(timestamp(to)) (end exclusive). Ongoing events may appear in both views.", ""]
        if records.isEmpty { lines.append("No events in this view.") }
        for event in records {
            lines += ["## \(line(event.title))", "", "- Calendar: \(line(event.calendar))", "- Apple ID: \(line(event.id))", "- All day: \(event.isAllDay ? "yes" : "no")"]
            if event.isAllDay, let start = event.startDate, let end = event.endDate {
                lines += ["- Start date: \(start)", "- End date: \(end) (exclusive)"]
            } else {
                lines += ["- Start: \(timestamp(event.start))", "- End: \(timestamp(event.end))"]
            }
            if let zone = event.timeZone { lines.append("- Time zone: \(line(zone))") }
            if let location = event.location, !location.isEmpty { lines.append("- Location: \(line(location))") }
            if let url = event.url { lines.append("- URL: \(line(url))") }
            if let notes = event.notes, !notes.isEmpty { lines += ["", notes] }
            lines.append("")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func chatMarkdown(_ chat: WhatsAppChatRecord, meta: [String]) -> String {
        var lines = meta + ["", "# \(line(chat.title))", ""]
        let messages = chat.messages.sorted { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }
        if messages.isEmpty { lines.append("No messages in this view.") }
        for message in messages {
            guard let body = messageBody(message) else { continue }
            lines.append("- \(timestamp(message.timestamp)) **\(line(message.sender)):** \(line(body))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func messageBody(_ message: WhatsAppMessageRecord) -> String? {
        let caption = message.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let placeholder = message.placeholder, !placeholder.isEmpty {
            return caption.isEmpty ? "[\(placeholder)]" : "[\(placeholder)] \(caption)"
        }
        return caption.isEmpty ? nil : caption
    }
}
