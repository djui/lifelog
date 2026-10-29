import CryptoKit
import Foundation

/// One official ChatGPT or Claude data export. A complete export is a complete read of that service.
public struct AIExport {
    public var source: ArchiveSource
    public var zip: URL
    /// SHA-256 of the zip, so a later run can skip an export it already imported.
    public var digest: String
    public var chats: [AIChatRecord]
    /// False when a conversation could not be parsed; such an export must not count as evidence of absence.
    public var complete: Bool
    public var warnings: [String]
}

/// Imports ChatGPT and Claude account exports dropped into an inbox folder.
///
/// Exports are recognized by their contents (a `conversations.json` whose shape matches one service), not by
/// file name. Only the JSON files are unpacked, into a private temp directory that is removed afterwards.
/// The zips are left in place.
public enum AIExportImporter {
    static let unzip = URL(fileURLWithPath: "/usr/bin/unzip")
    static let conversations = "conversations.json"

    /// Every export in `inbox` (not recursive), oldest first. Zips whose digest is in `skipDigests` are not unpacked.
    /// `digest` lets the caller reuse digests of zips it has hashed before.
    public static func scan(inbox: URL, skipDigests: Set<String> = [], digest: ((URL) throws -> String)? = nil) -> SourceResult<AIExport> {
        var result = SourceResult<AIExport>(records: [])
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            result.warnings.append("AI export inbox \(inbox.path) could not be read; skipped.")
            return result
        }
        let candidates = files.filter { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return values?.isRegularFile == true && values?.isSymbolicLink != true && isZip(url)
        }.sorted { (modified($0), $0.lastPathComponent) < (modified($1), $1.lastPathComponent) }
        for zip in candidates {
            do {
                let digest = try (digest ?? fileDigest)(zip)
                if skipDigests.contains(digest) { continue }
                if let export = try importZip(zip, digest: digest) { result.records.append(export) }
            } catch {
                result.warnings.append("\(zip.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return result
    }

    /// Nil when the zip is not a ChatGPT or Claude export.
    public static func importZip(_ zip: URL) throws -> AIExport? { try importZip(zip, digest: try fileDigest(zip)) }

    static func importZip(_ zip: URL, digest: String) throws -> AIExport? {
        let names = try listMembers(zip)
        guard let member = exportRoot(names) else { return nil }
        let prefix = String(member.dropLast(conversations.count))
        let siblings = Set(names.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
        return try withPrivateDirectory { directory in
            let data = try extract(member, from: zip, to: directory)
            guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
                throw ExportError.message("conversations.json is not a JSON list.")
            }
            guard let source = service(of: items, siblings: siblings) else { return nil }
            let parsed: SourceResult<AIChatRecord>
            if source == .chatgpt {
                parsed = parseChatGPT(items)
            } else {
                let projects = siblings.contains("projects.json") ? try? extract(prefix + "projects.json", from: zip, to: directory) : nil
                parsed = parseClaude(items, projects: projects)
            }
            return AIExport(source: source, zip: zip, digest: digest, chats: parsed.records, complete: parsed.warnings.isEmpty, warnings: parsed.warnings)
        }
    }

    /// `conversations.json` at the zip root or inside one top-level folder.
    static func exportRoot(_ names: [String]) -> String? {
        names.filter { name in
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            return parts.last.map(String.init) == conversations && parts.count <= 2 && !name.contains("..") && !name.contains(where: "*?[]\\".contains)
        }.min { $0.count < $1.count }
    }

    /// ChatGPT conversations carry a `mapping` tree, Claude ones a `chat_messages` list. An empty export is
    /// recognized by the files next to `conversations.json`.
    static func service(of items: [Any], siblings: Set<String>) -> ArchiveSource? {
        let objects = items.compactMap { $0 as? [String: Any] }
        if objects.contains(where: { $0["mapping"] != nil }) { return .chatgpt }
        if objects.contains(where: { $0["chat_messages"] != nil }) { return .claude }
        guard items.isEmpty else { return nil }
        if siblings.contains("chat.html") || siblings.contains("message_feedback.json") { return .chatgpt }
        if siblings.contains("users.json") || siblings.contains("projects.json") { return .claude }
        return nil
    }

    // MARK: ChatGPT

    static func parseChatGPT(_ items: [Any]) -> SourceResult<AIChatRecord> {
        var result = SourceResult<AIChatRecord>(records: [])
        for (index, item) in items.enumerated() {
            guard let conversation = item as? [String: Any], let mapping = conversation["mapping"] as? [String: Any],
                  let id = string(conversation["conversation_id"]) ?? string(conversation["id"]) else {
                result.warnings.append("ChatGPT conversation \(index + 1) is malformed; skipped.")
                continue
            }
            let nodes = mapping.compactMapValues { $0 as? [String: Any] }
            let path = currentPath(nodes, current: string(conversation["current_node"]))
            let onPath = Set(path)
            let otherBranches = nodes.filter { !onPath.contains($0.key) && $0.value["message"] is [String: Any] }.count
            let messages = path.compactMap { nodes[$0]?["message"] as? [String: Any] }.compactMap(chatGPTMessage)
            result.records.append(AIChatRecord(
                id: id, title: string(conversation["title"]) ?? "",
                created: epoch(conversation["create_time"]), updated: epoch(conversation["update_time"]),
                model: string(conversation["default_model_slug"]) ?? messages.last(where: { $0.model != nil })?.model,
                project: string(conversation["gizmo_id"]), messages: messages,
                otherBranchMessages: otherBranches > 0 ? otherBranches : nil))
        }
        return result
    }

    /// Root-to-leaf node ids ending at `current`. Without a usable `current_node`, the most recent leaf.
    static func currentPath(_ nodes: [String: [String: Any]], current: String?) -> [String] {
        var leaf = current.flatMap { nodes[$0] != nil ? $0 : nil }
        if leaf == nil {
            func time(_ node: [String: Any]) -> Date { epoch((node["message"] as? [String: Any])?["create_time"]) ?? .distantPast }
            leaf = nodes.filter { (($0.value["children"] as? [Any]) ?? []).isEmpty }
                .max { (time($0.value), $0.key) < (time($1.value), $1.key) }?.key
        }
        var path: [String] = []
        var seen = Set<String>()
        while let id = leaf, let node = nodes[id], seen.insert(id).inserted {
            path.append(id)
            leaf = string(node["parent"])
        }
        return path.reversed()
    }

    static func chatGPTMessage(_ message: [String: Any]) -> AIChatMessage? {
        let author = message["author"] as? [String: Any]
        let role = string(author?["role"]) ?? "unknown"
        let metadata = message["metadata"] as? [String: Any] ?? [:]
        let content = message["content"] as? [String: Any] ?? [:]
        let type = string(content["content_type"]) ?? "text"
        // Custom instructions and other scaffolding the app never shows.
        if metadata["is_visually_hidden_from_conversation"] as? Bool == true || type == "user_editable_context" { return nil }
        var attachments = ((metadata["attachments"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }.map { file in
            placeholder("attachment", string(file["name"]) ?? string(file["id"]), size: int(file["size"]))
        }
        var text: String
        if type == "text" || type == "multimodal_text" {
            var parts: [String] = []
            for part in (content["parts"] as? [Any]) ?? [] {
                if let value = part as? String { parts.append(value); continue }
                guard let object = part as? [String: Any] else { continue }
                let kind = string(object["content_type"]) ?? "part"
                attachments.append(placeholder(kind == "image_asset_pointer" ? "image" : kind, string(object["asset_pointer"]), size: int(object["size_bytes"])))
            }
            text = parts.joined(separator: "\n")
        } else {
            // Code, tool output, browsing results, reasoning and anything newer.
            text = "[\(type): \(jsonSize(content)) bytes]"
        }
        if role == "tool" {
            text = placeholder("tool result", string(author?["name"]), size: jsonSize(content))
        } else if role == "assistant", let recipient = string(message["recipient"]), recipient != "all" {
            text = placeholder("tool call", recipient, size: jsonSize(content))
        }
        if role == "system", text.isEmpty { return nil }
        return AIChatMessage(id: string(message["id"]), role: role, timestamp: epoch(message["create_time"]), text: text,
                             attachments: attachments, model: string(metadata["model_slug"]))
    }

    // MARK: Claude

    static func parseClaude(_ items: [Any], projects: Data?) -> SourceResult<AIChatRecord> {
        var result = SourceResult<AIChatRecord>(records: [])
        var projectNames: [String: String] = [:]
        if let projects, let list = (try? JSONSerialization.jsonObject(with: projects)) as? [Any] {
            for case let project as [String: Any] in list {
                if let id = string(project["uuid"]), let name = string(project["name"]) { projectNames[id] = name }
            }
        }
        for (index, item) in items.enumerated() {
            guard let conversation = item as? [String: Any], let id = string(conversation["uuid"]),
                  let list = conversation["chat_messages"] as? [Any] else {
                result.warnings.append("Claude conversation \(index + 1) is malformed; skipped.")
                continue
            }
            let project = (conversation["project"] as? [String: Any]).flatMap { string($0["name"]) ?? string($0["uuid"]) }
                ?? string(conversation["project_uuid"]).map { projectNames[$0] ?? $0 }
            result.records.append(AIChatRecord(
                id: id, title: string(conversation["name"]) ?? "",
                created: isoDate(conversation["created_at"]), updated: isoDate(conversation["updated_at"]),
                model: string(conversation["model"]), project: project,
                messages: list.compactMap { $0 as? [String: Any] }.map(claudeMessage)))
        }
        return result
    }

    static func claudeMessage(_ message: [String: Any]) -> AIChatMessage {
        let sender = string(message["sender"]) ?? "unknown"
        var parts: [String] = []
        for case let block as [String: Any] in (message["content"] as? [Any]) ?? [] {
            switch string(block["type"]) {
            case "text": if let text = string(block["text"]) { parts.append(text) }
            case "tool_use": parts.append(placeholder("tool call", string(block["name"]), size: jsonSize(block["input"] ?? [:])))
            case "tool_result": parts.append(placeholder("tool result", string(block["name"]), size: jsonSize(block["content"] ?? [])))
            case let type: parts.append("[\(type ?? "block"): \(jsonSize(block)) bytes]")
            }
        }
        let text = parts.isEmpty ? string(message["text"]) ?? "" : parts.joined(separator: "\n")
        var attachments = ((message["attachments"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }.map { file in
            placeholder("attachment", string(file["file_name"]), size: int(file["file_size"]))
        }
        attachments += ((message["files"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }.map { file in
            placeholder("file", string(file["file_name"]), size: nil)
        }
        return AIChatMessage(id: string(message["uuid"]), role: sender == "human" ? "user" : sender,
                             timestamp: isoDate(message["created_at"]), text: text, attachments: attachments)
    }

    // MARK: Zip and files

    static func isZip(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data([0x50, 0x4B, 0x03, 0x04])
    }

    static func modified(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }

    static func fileDigest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func listMembers(_ zip: URL) throws -> [String] {
        String(decoding: try run(["-Z1", zip.path]), as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// Unpacks one member, without its folders, into `directory` and reads it. Media are never unpacked.
    static func extract(_ member: String, from zip: URL, to directory: URL) throws -> Data {
        _ = try run(["-qq", "-o", "-j", zip.path, member, "-d", directory.path])
        guard let data = try? Data(contentsOf: directory.appendingPathComponent((member as NSString).lastPathComponent)) else {
            throw ExportError.message("\(member) could not be unpacked.")
        }
        return data
    }

    static func run(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = unzip
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ExportError.message("The zip could not be read (unzip exit \(process.terminationStatus)).") }
        return data
    }

    /// A 0700 directory that is removed when `body` returns or throws.
    static func withPrivateDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lifelog-ai-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }

    // MARK: Values

    static func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }

    static func epoch(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue)
    }

    /// ISO 8601 with any number of fractional digits; Claude writes microseconds.
    static func isoDate(_ value: Any?) -> Date? {
        guard let text = string(value) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = ISO8601DateFormatter().date(from: text) ?? fractional.date(from: text) { return date }
        // 2024-05-01T12:00:00.123456Z -> 2024-05-01T12:00:00.123Z
        guard let dot = text.firstIndex(of: ".") else { return nil }
        let fraction = text[text.index(after: dot)...].prefix { $0.isNumber }
        guard !fraction.isEmpty else { return nil }
        let rest = text[fraction.endIndex...]
        return fractional.date(from: text[..<dot] + "." + fraction.prefix(3).padding(toLength: 3, withPad: "0", startingAt: 0) + rest)
    }

    static func jsonSize(_ value: Any) -> Int {
        if let text = value as? String { return text.utf8.count }
        guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) else { return 0 }
        return data.count
    }

    static func placeholder(_ kind: String, _ name: String?, size: Int?) -> String {
        "[" + kind + (name.map { ": " + $0 } ?? "") + (size.map { ", \($0) bytes" } ?? "") + "]"
    }
}
