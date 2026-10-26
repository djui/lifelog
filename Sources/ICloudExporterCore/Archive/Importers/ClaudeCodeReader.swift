import Foundation

/// Where the previous read of one transcript stopped.
public struct ClaudeCodeCursor: Codable, Equatable {
    /// Bytes consumed, always at a line boundary.
    public var offset: UInt64
    /// The file's inode; a different one means the file was replaced and is read again from the start.
    public var fileID: UInt64?
    /// Tool calls whose result has not been read yet, by tool-use id, so a later read can name the tool.
    public var pendingTools: [String: String]
    public init(offset: UInt64 = 0, fileID: UInt64? = nil, pendingTools: [String: String] = [:]) {
        self.offset = offset; self.fileID = fileID; self.pendingTools = pendingTools
    }
}

/// What one read of one transcript added.
public struct ClaudeCodeSessionRead {
    /// Relative to the projects folder, such as `-Users-me-dev-app/<session>.jsonl`.
    public var path: String
    /// Only the messages after the cursor. The title is empty when this read saw neither a summary nor a first prompt.
    public var chat: AIChatRecord
    public var cursor: ClaudeCodeCursor
    /// True when the file shrank or was replaced, so `chat` holds the whole session again.
    public var restarted: Bool
    public var warnings: [String]
}

/// Reads Claude Code session transcripts, `~/.claude/projects/<project>/<session>.jsonl`, incrementally.
///
/// User and assistant text is kept. Tool calls and tool results become one-line placeholders with the tool
/// name and size, and reasoning is dropped to a placeholder, so work code and output stay out of the archive.
public enum ClaudeCodeReader {
    public static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
    static let titleLength = 80

    /// `<project>/<session>.jsonl` files directly under `root`, sorted. Subagent folders deeper down are not sessions.
    public static func sessionFiles(root: URL = defaultRoot) -> [String] {
        let manager = FileManager.default
        guard let projects = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var files: [String] = []
        for project in projects where (try? project.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let entries = (try? manager.contentsOfDirectory(at: project, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
            for file in entries where file.pathExtension == "jsonl" && (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                files.append(project.lastPathComponent + "/" + file.lastPathComponent)
            }
        }
        return files.sorted()
    }

    /// Reads every session that grew since `cursors` (keyed by relative path). Unchanged sessions are left out.
    public static func read(root: URL = defaultRoot, cursors: [String: ClaudeCodeCursor] = [:]) -> SourceResult<ClaudeCodeSessionRead> {
        var result = SourceResult<ClaudeCodeSessionRead>(records: [])
        for path in sessionFiles(root: root) {
            do {
                let read = try read(root: root, path: path, cursor: cursors[path])
                if read.restarted || read.cursor != cursors[path] { result.records.append(read) }
                result.warnings += read.warnings
            } catch {
                result.warnings.append("\(path): \(error.localizedDescription)")
            }
        }
        return result
    }

    public static func read(root: URL = defaultRoot, path: String, cursor: ClaudeCodeCursor?) throws -> ClaudeCodeSessionRead {
        let url = root.appendingPathComponent(path)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let fileID = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        var state = cursor ?? ClaudeCodeCursor()
        let restarted = cursor != nil && (size < state.offset || (state.fileID != nil && state.fileID != fileID))
        if restarted || cursor == nil { state = ClaudeCodeCursor(fileID: fileID) }
        state.fileID = fileID

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: state.offset)
        let data = try handle.readToEnd() ?? Data()
        // A line still being written has no newline yet; leave it for the next read.
        let end = data.lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
        var parser = Parser(pendingTools: state.pendingTools, session: (path as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: ""))
        for line in data[data.startIndex..<end].split(separator: 0x0A) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else {
                parser.warnings.append("\(path): the line at byte \(state.offset + UInt64(line.startIndex - data.startIndex)) is not JSON; skipped.")
                continue
            }
            parser.add(object)
        }
        state.offset += UInt64(end - data.startIndex)
        state.pendingTools = parser.pendingTools
        let project = parser.cwd ?? (path as NSString).deletingLastPathComponent
        let chat = AIChatRecord(id: parser.session, title: parser.title ?? "", created: parser.messages.first?.timestamp,
                                updated: parser.messages.last?.timestamp, model: parser.model, project: project, messages: parser.messages)
        return ClaudeCodeSessionRead(path: path, chat: chat, cursor: state, restarted: restarted, warnings: parser.warnings)
    }

    struct Parser {
        var pendingTools: [String: String]
        var session: String
        var messages: [AIChatMessage] = []
        var warnings: [String] = []
        var title, cwd, model: String?
        var lastAssistantID: String?

        init(pendingTools: [String: String], session: String) { self.pendingTools = pendingTools; self.session = session }

        mutating func add(_ line: [String: Any]) {
            let type = AIExportImporter.string(line["type"])
            if type == "summary", let text = AIExportImporter.string(line["summary"]) { title = text; return }
            guard type == "user" || type == "assistant", let message = line["message"] as? [String: Any] else { return }
            // Meta lines are injected context, sidechains are subagent conversations.
            if line["isMeta"] as? Bool == true || line["isSidechain"] as? Bool == true { return }
            if let id = AIExportImporter.string(line["sessionId"]) { session = id }
            if let value = AIExportImporter.string(line["cwd"]) { cwd = value }
            var role = AIExportImporter.string(message["role"]) ?? type!
            let timestamp = AIExportImporter.isoDate(line["timestamp"])
            let messageModel = AIExportImporter.string(message["model"])
            if let messageModel { model = messageModel }
            var parts: [String] = []
            var attachments: [String] = []
            if let text = message["content"] as? String {
                parts.append(text)
            } else {
                for case let block as [String: Any] in (message["content"] as? [Any]) ?? [] {
                    switch AIExportImporter.string(block["type"]) {
                    case "text":
                        if let text = AIExportImporter.string(block["text"]) { parts.append(text) }
                    case "tool_use":
                        let name = AIExportImporter.string(block["name"]) ?? "tool"
                        if let id = AIExportImporter.string(block["id"]) { pendingTools[id] = name }
                        parts.append(AIExportImporter.placeholder("tool call", name, size: AIExportImporter.jsonSize(block["input"] ?? [:])))
                    case "tool_result":
                        let name = AIExportImporter.string(block["tool_use_id"]).flatMap { pendingTools.removeValue(forKey: $0) }
                        let kind = block["is_error"] as? Bool == true ? "tool error" : "tool result"
                        parts.append(AIExportImporter.placeholder(kind, name, size: AIExportImporter.jsonSize(block["content"] ?? "")))
                    case "image":
                        attachments.append("[image]")
                    case let other:
                        parts.append("[\(other ?? "block"): \(AIExportImporter.jsonSize(block)) bytes]")
                    }
                }
            }
            let blocks = (message["content"] as? [Any])?.compactMap { ($0 as? [String: Any]).flatMap { AIExportImporter.string($0["type"]) } } ?? []
            if !blocks.isEmpty, blocks.allSatisfy({ $0 == "tool_result" }) { role = "tool" }
            let text = parts.joined(separator: "\n")
            if title == nil, role == "user", !text.isEmpty, !text.hasPrefix("[") {
                let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
                title = line.count > ClaudeCodeReader.titleLength ? String(line.prefix(ClaudeCodeReader.titleLength - 1)) + "…" : line
            }
            // Claude Code writes one line per content block of a streamed reply; they share the message id.
            let messageID = AIExportImporter.string(message["id"])
            if role == "assistant", let messageID, messageID == lastAssistantID, var last = messages.popLast() {
                last.text = [last.text, text].filter { !$0.isEmpty }.joined(separator: "\n")
                last.attachments += attachments
                messages.append(last)
                return
            }
            lastAssistantID = role == "assistant" ? messageID : nil
            messages.append(AIChatMessage(id: AIExportImporter.string(line["uuid"]), role: role, timestamp: timestamp, text: text,
                                          attachments: attachments, model: messageModel))
        }
    }
}
