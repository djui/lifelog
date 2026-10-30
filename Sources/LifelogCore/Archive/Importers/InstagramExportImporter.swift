import Foundation

/// Imports the direct messages of an Instagram "Download your information" export in JSON format.
///
/// Each conversation is a folder `…/messages/<inbox|message_requests|…>/<thread>/` with `message_1.json`,
/// `message_2.json` and so on, under `your_instagram_activity/` in current exports. Large exports are split
/// across several zips, so one zip is never a complete read: Instagram imports only add.
public enum InstagramExportImporter {
    static let activityRoot = "your_instagram_activity/messages/"

    /// Nil when the zip holds no Instagram messages. `names` are the zip's members.
    static func importZip(_ zip: URL, digest: String, names: [String]) throws -> AIExport? {
        let members = names.filter(isMessageFile)
        guard !members.isEmpty, isInstagram(names) else {
            if names.contains(where: { $0.contains(activityRoot) && $0.hasSuffix(".html") }) {
                throw ExportError.message("This Instagram export is in HTML format. Request the export again with the format set to JSON.")
            }
            return nil
        }
        return try AIExportImporter.withPrivateDirectory { directory in
            // Patterns, not member names: an account has thousands of threads. Media are never unpacked.
            _ = try AIExportImporter.run(["-qq", "-o", zip.path, "*messages/*/message_*.json", "-d", directory.path])
            var threads: [String: [[String: Any]]] = [:]
            var warnings: [String] = []
            for member in members {
                let file = directory.appendingPathComponent(member)
                guard let data = try? Data(contentsOf: file), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    warnings.append("Instagram \(member) could not be read; skipped.")
                    continue
                }
                threads[threadID(member), default: []].append(object)
            }
            let parsed = parse(threads)
            return AIExport(source: .instagram, zip: zip, digest: digest, chats: parsed.records, complete: (warnings + parsed.warnings).isEmpty,
                            warnings: warnings + parsed.warnings)
        }
    }

    /// `…/messages/<folder>/<thread>/message_<n>.json`, at most two folders above `messages/`.
    static func isMessageFile(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4, parts.count <= 6, !name.contains(".."), !name.contains(where: "*?[]\\".contains),
              let file = parts.last, file.hasPrefix("message_"), file.hasSuffix(".json"),
              parts[parts.count - 4] == "messages" else { return false }
        return true
    }

    /// Facebook exports use the same message format, under `your_facebook_activity/`. Older Instagram exports
    /// have `messages/` at the root; they are recognized by Instagram files next to it.
    static func isInstagram(_ names: [String]) -> Bool {
        if names.contains(where: { $0.contains("your_facebook_activity/") }) { return false }
        return names.contains { $0.hasPrefix(activityRoot) || $0.contains("/" + activityRoot) || $0.lowercased().contains("instagram") }
    }

    /// The thread folder, such as `alice_1234567890`. It stays the same when a request is accepted and moves to the inbox.
    static func threadID(_ member: String) -> String {
        let parts = member.split(separator: "/")
        return String(parts[parts.count - 2])
    }

    static func parse(_ threads: [String: [[String: Any]]]) -> SourceResult<AIChatRecord> {
        var result = SourceResult<AIChatRecord>(records: [])
        for (id, files) in threads.sorted(by: { $0.key < $1.key }) {
            let listed = files.flatMap { ($0["messages"] as? [Any]) ?? [] }
            let raw = listed.compactMap { $0 as? [String: Any] }
            let names = (files.first?["participants"] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap { text($0["name"]) } }
            let title = files.lazy.compactMap { text($0["title"]) }.first ?? (names.isEmpty ? id : names.joined(separator: ", "))
            if raw.count < listed.count { result.warnings.append("Instagram chat \(title): some messages are malformed; skipped.") }
            // Files list messages newest first, and the export has no message ids.
            var seen: [String: Int] = [:]
            let messages = raw.sorted { (int($0["timestamp_ms"]) ?? 0) < (int($1["timestamp_ms"]) ?? 0) }.map { message -> AIChatMessage in
                let sender = text(message["sender_name"]) ?? "unknown"
                var key = "\(int(message["timestamp_ms"]) ?? 0)/\(sender)"
                seen[key, default: 0] += 1
                if seen[key]! > 1 { key += "/\(seen[key]!)" }
                return self.message(message, id: key, sender: sender)
            }
            let times = messages.compactMap(\.timestamp)
            result.records.append(AIChatRecord(id: id, title: title, created: times.min(), updated: times.max(), messages: messages))
        }
        return result
    }

    /// Reactions are left out: one added later would mark the message as edited.
    static func message(_ message: [String: Any], id: String, sender: String) -> AIChatMessage {
        func file(_ media: Any?) -> String? { ((media as? [String: Any]).flatMap { text($0["uri"]) }).map { ($0 as NSString).lastPathComponent } }
        var attachments: [String] = []
        for (key, kind) in [("photos", "photo"), ("videos", "video"), ("audio_files", "audio"), ("files", "file"), ("gifs", "gif")] {
            for media in (message[key] as? [Any]) ?? [] { attachments.append(AIExportImporter.placeholder(kind, file(media), size: nil)) }
        }
        if message["sticker"] != nil { attachments.append(AIExportImporter.placeholder("sticker", file(message["sticker"]), size: nil)) }
        if let share = message["share"] as? [String: Any] {
            attachments.append(AIExportImporter.placeholder("shared", text(share["link"]) ?? text(share["share_text"]), size: nil))
        }
        var body = text(message["content"]) ?? ""
        if body.isEmpty, message["is_unsent"] as? Bool == true { body = "[unsent]" }
        if body.isEmpty, let seconds = int(message["call_duration"]) { body = "[call, \(seconds) s]" }
        let timestamp = int(message["timestamp_ms"]).map { Date(timeIntervalSince1970: Double($0) / 1000) }
        return AIChatMessage(id: id, role: sender, timestamp: timestamp, text: body, attachments: attachments)
    }

    static func int(_ value: Any?) -> Int? { AIExportImporter.int(value) }

    static func text(_ value: Any?) -> String? { AIExportImporter.string(value).map(repairMojibake) }

    /// Meta writes each UTF-8 byte as its own `\u00XX` escape, so `é` arrives as `Ã©`. Strings that are not
    /// such byte sequences are left as they are.
    static func repairMojibake(_ value: String) -> String {
        let scalars = value.unicodeScalars
        guard scalars.contains(where: { $0.value >= 0x80 }), scalars.allSatisfy({ $0.value <= 0xFF }) else { return value }
        return String(bytes: scalars.map { UInt8($0.value) }, encoding: .utf8) ?? value
    }
}
