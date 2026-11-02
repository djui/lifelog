import Foundation

/// Imports what you did on Facebook, apart from Messenger, from a "Download your information" export in JSON format:
/// posts, photos and videos, stories, comments, reactions, groups, events, Marketplace, friends and so on.
///
/// Each category becomes one chat per month (`posts/2021-05`, titled `Posts 2021-05`), with one message per entry. Only the
/// files in `files` are read; ads, security, login and device logs, settings and payments are left out. Media become placeholders.
/// Facebook writes entries in several shapes; `entries` and `entry` handle all of them generically.
public enum FacebookExportImporter {
    /// A file inside the export, the category it belongs to and the heading of its entries.
    struct File {
        var path: String
        var category: String
        var label: String
    }

    static let files: [File] = [
        File(path: "your_facebook_activity/posts/your_posts__check_ins__photos_and_videos_*.json", category: "Posts", label: "Post"),
        File(path: "your_facebook_activity/posts/album/*.json", category: "Photos and videos", label: "Photo"),
        File(path: "your_facebook_activity/posts/your_uncategorized_photos.json", category: "Photos and videos", label: "Photo"),
        File(path: "your_facebook_activity/posts/your_videos.json", category: "Photos and videos", label: "Video"),
        File(path: "your_facebook_activity/posts/places_you_have_been_tagged_in.json", category: "Places", label: "Tagged at"),
        File(path: "your_facebook_activity/activity_you're_tagged_in/*.json", category: "Tagged", label: "Tagged"),
        File(path: "your_facebook_activity/stories/archived_stories.json", category: "Stories", label: "Story"),
        File(path: "your_facebook_activity/reels/your_reels.json", category: "Stories", label: "Reel"),
        File(path: "your_facebook_activity/comments_and_reactions/comments.json", category: "Comments", label: "Comment"),
        File(path: "your_facebook_activity/comments_and_reactions/likes_and_reactions*.json", category: "Reactions", label: "Reaction"),
        File(path: "your_facebook_activity/groups/group_posts_and_comments.json", category: "Groups", label: "Group post"),
        File(path: "your_facebook_activity/groups/your_comments_in_groups.json", category: "Groups", label: "Group comment"),
        File(path: "your_facebook_activity/groups/your_group_membership_activity.json", category: "Groups", label: "Joined group"),
        File(path: "your_facebook_activity/events/your_event_responses.json", category: "Events", label: "Event"),
        File(path: "your_facebook_activity/events/event_invitations.json", category: "Events", label: "Invited"),
        File(path: "your_facebook_activity/events/events_you_hosted.json", category: "Events", label: "Hosted"),
        File(path: "your_facebook_activity/facebook_marketplace/items_sold.json", category: "Marketplace", label: "Selling"),
        File(path: "your_facebook_activity/facebook_marketplace/your_marketplace_items.json", category: "Marketplace", label: "Listing"),
        File(path: "your_facebook_activity/facebook_marketplace/conversations_you_had_as_a_buyer.json", category: "Marketplace", label: "Buying"),
        File(path: "your_facebook_activity/facebook_marketplace/conversations_you_had_as_a_seller.json", category: "Marketplace", label: "Selling"),
        File(path: "your_facebook_activity/facebook_marketplace/your_saved_searches.json", category: "Marketplace", label: "Saved search"),
        File(path: "your_facebook_activity/facebook_marketplace/your_search_history.json", category: "Marketplace", label: "Search"),
        File(path: "your_facebook_activity/saved_items_and_collections/your_saved_items.json", category: "Saved", label: "Saved"),
        File(path: "your_facebook_activity/polls/your_poll_votes.json", category: "Polls", label: "Vote"),
        File(path: "your_facebook_activity/pages/pages_you've_liked.json", category: "Pages", label: "Liked page"),
        File(path: "your_facebook_activity/pages/pages_and_profiles_you_follow.json", category: "Pages", label: "Followed"),
        File(path: "your_facebook_activity/other_activity/pokes.json", category: "Pokes", label: "Poke"),
        File(path: "connections/friends/your_friends.json", category: "Friends", label: "Became friends"),
        File(path: "connections/friends/removed_friends.json", category: "Friends", label: "Removed friend"),
        File(path: "connections/friends/sent_friend_requests.json", category: "Friends", label: "Sent friend request"),
        File(path: "connections/friends/rejected_friend_requests.json", category: "Friends", label: "Declined friend request"),
        File(path: "connections/followers/who_you've_followed.json", category: "Friends", label: "Followed"),
        File(path: "personal_information/profile_information/profile_update_history.json", category: "Profile", label: "Profile update"),
    ]

    /// The members of `names` that are read, with the file each one matches. A pattern's `*` stays within one folder.
    static func members(_ names: [String]) -> [(member: String, file: File)] {
        names.compactMap { name in
            guard !name.contains(".."), !name.contains(where: "*?[]\\".contains) else { return nil }
            return files.first { matches(name, $0.path) }.map { (name, $0) }
        }
    }

    static func matches(_ name: String, _ pattern: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        let wanted = pattern.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == wanted.count else { return false }
        return zip(parts, wanted).allSatisfy { part, want in
            guard let star = want.firstIndex(of: "*") else { return part == want }
            let prefix = want[..<star], suffix = want[want.index(after: star)...]
            return part.count >= prefix.count + suffix.count && part.hasPrefix(prefix) && part.hasSuffix(suffix)
        }
    }

    /// Nil when the zip has none of the files. `names` are the zip's members.
    static func importZip(_ zip: URL, digest: String, names: [String], timeZone: TimeZone = .current) throws -> AIExport? {
        let members = members(names)
        guard !members.isEmpty else { return nil }
        return try AIExportImporter.withPrivateDirectory { directory in
            _ = try AIExportImporter.run(["-qq", "-o", zip.path] + members.map(\.member) + ["-d", directory.path])
            var parsed: [(member: String, file: File, json: Any)] = []
            var warnings: [String] = []
            for (member, file) in members {
                guard let data = try? Data(contentsOf: directory.appendingPathComponent(member)), let json = try? JSONSerialization.jsonObject(with: data) else {
                    warnings.append("Facebook \(member) could not be read; skipped.")
                    continue
                }
                parsed.append((member, file, json))
            }
            let chats = chats(parsed, timeZone: timeZone)
            return AIExport(source: .facebook, zip: zip, digest: digest, chats: chats, complete: warnings.isEmpty, warnings: warnings)
        }
    }

    static func chats(_ files: [(member: String, file: File, json: Any)], timeZone: TimeZone) -> [AIChatRecord] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // Keyed by member and time, so an entry keeps its id when later exports add others. Entries in the same second are told apart by content.
        var byChat: [String: (title: String, messages: [AIChatMessage])] = [:]
        for (member, file, json) in files {
            var seen: [String: Int] = [:]
            let stem = ((member as NSString).lastPathComponent as NSString).deletingPathExtension
            let folder = ((member as NSString).deletingLastPathComponent as NSString).lastPathComponent
            for message in entries(json, label: file.label).sorted(by: { ($0.timestamp!, $0.role, $0.text) < ($1.timestamp!, $1.role, $1.text) }) {
                var message = message
                let time = message.timestamp!
                var key = "\(folder)/\(stem)/\(Int(time.timeIntervalSince1970))"
                seen[key, default: 0] += 1
                if seen[key]! > 1 { key += "/\(seen[key]!)" }
                message.id = key
                let month = calendar.dateComponents([.year, .month], from: time)
                let suffix = String(format: "%04d-%02d", month.year!, month.month!)
                let chat = "\(slug(file.category))/\(suffix)"
                byChat[chat, default: ("\(file.category) \(suffix)", [])].messages.append(message)
            }
        }
        return byChat.sorted { $0.key < $1.key }.map { id, chat in
            let messages = chat.messages.sorted { ($0.timestamp!, $0.id!) < ($1.timestamp!, $1.id!) }
            return AIChatRecord(id: id, title: chat.title, created: messages.first?.timestamp, updated: messages.last?.timestamp, messages: messages)
        }
    }

    static func slug(_ category: String) -> String { category.lowercased().replacingOccurrences(of: " ", with: "-") }

    /// Every dated entry of a file. Files are a list of entries, or an object holding one list (`comments_v2`), several
    /// (`event_responses_v2` with `events_joined` and so on, whose names become the headings), or a single entry.
    static func entries(_ json: Any, label: String) -> [AIChatMessage] {
        if let list = json as? [Any] { return list.compactMap { ($0 as? [String: Any]).flatMap { entry($0, label: label) } } }
        guard let object = json as? [String: Any] else { return [] }
        let lists = object.filter { $0.value is [Any] && $0.key != "media" && $0.key != "label_values" }
        let groups = object.filter { ($0.value as? [String: Any])?.values.contains { $0 is [Any] } == true }
        if lists.count == 1, let list = lists.first?.value as? [Any], object["label_values"] == nil {
            // An album names its photos; other files hold one list such as `comments_v2`.
            let album = MetaExportImporter.text(object["name"])
            return list.compactMap { ($0 as? [String: Any]).flatMap { entry($0, label: label, context: album) } }
        }
        if groups.count == 1, let group = groups.first?.value as? [String: Any] {
            return group.sorted { $0.key < $1.key }.flatMap { key, value in entries(value, label: heading(key, label: label)) }
        }
        return entry(object, label: label).map { [$0] } ?? []
    }

    /// `events_joined` under `Event` → `Event: joined`.
    static func heading(_ key: String, label: String) -> String {
        var words = key.split(separator: "_").map(String.init)
        if let first = words.first, label.lowercased().hasPrefix(first.lowercased().dropLast()) { words.removeFirst() }
        return words.isEmpty ? label : "\(label): \(words.joined(separator: " "))"
    }

    /// One entry, or nil when it has no date or nothing to show. The text is the entry's title, what was written and any
    /// named values; photos, videos and links become placeholders.
    static func entry(_ entry: [String: Any], label: String, context: String? = nil) -> AIChatMessage? {
        var lines: [String] = []
        var attachments: [String] = []
        func add(_ value: Any?) { if let text = MetaExportImporter.text(value), !lines.contains(text) { lines.append(text) } }
        func link(_ value: Any?) { if let url = MetaExportImporter.text(value) { attachments.append(AIExportImporter.placeholder("link", url, size: nil)) } }

        add(entry["title"])
        add(entry["name"])
        for case let data as [String: Any] in (entry["data"] as? [Any]) ?? [] {
            add(data["post"])
            add(data["name"])
            if let comment = data["comment"] as? [String: Any] {
                add(comment["comment"])
                if let group = MetaExportImporter.text(comment["group"]) { add("Group: \(group)") }
            }
        }
        add(entry["description"])
        if let poker = MetaExportImporter.text(entry["poker"]), let pokee = MetaExportImporter.text(entry["pokee"]) { add("\(poker) poked \(pokee)") }
        for key in ["price", "category", "marketplace"] { if let value = MetaExportImporter.text(entry[key]) { add("\(key.capitalized): \(value)") } }
        link(entry["url"])
        if let uri = MetaExportImporter.text(entry["uri"]) { attachments.append(media(uri)) }
        for case let attachment as [String: Any] in (entry["attachments"] as? [Any]) ?? [] {
            for case let data as [String: Any] in (attachment["data"] as? [Any]) ?? [] {
                if let item = data["media"] as? [String: Any] {
                    if let uri = MetaExportImporter.text(item["uri"]) { attachments.append(media(uri)) }
                    add(item["description"])
                }
                if let external = data["external_context"] as? [String: Any] { link(external["url"] ?? external["name"]) }
                if let place = data["place"] as? [String: Any], let name = MetaExportImporter.text(place["name"]) { add("Place: \(name)") }
                if let event = data["event"] as? [String: Any], let name = MetaExportImporter.text(event["name"]) { add("Event: \(name)") }
                add(data["text"])
            }
        }
        var times: [Int] = []
        if let values = entry["label_values"] as? [Any] { labelValues(values, lines: &lines, times: &times, attachments: &attachments) }
        guard !lines.isEmpty || !attachments.isEmpty else { return nil }
        if let context, !lines.contains(context) { lines.insert(context, at: 0) }

        let keys = ["timestamp", "created_timestamp", "creation_timestamp", "start_timestamp", "response_time"]
        guard let seconds = keys.lazy.compactMap({ MetaExportImporter.int(entry[$0]) }).first(where: { $0 > 0 }) ?? times.first(where: { $0 > 0 }) else { return nil }
        return AIChatMessage(role: label, timestamp: Date(timeIntervalSince1970: Double(seconds)), text: lines.joined(separator: "\n"), attachments: attachments)
    }

    /// Newer files describe an entry as `label_values`: `{"label": "Product title", "value": "…"}`, with times as
    /// `timestamp_value` and nested `dict` and `vec` lists. Empty values and flags such as `False` are left out.
    static func labelValues(_ values: [Any], lines: inout [String], times: inout [Int], attachments: inout [String]) {
        for case let value as [String: Any] in values {
            let label = MetaExportImporter.text(value["label"]) ?? MetaExportImporter.text(value["title"])
            if let seconds = MetaExportImporter.int(value["timestamp_value"]) { times.append(seconds); continue }
            if let href = MetaExportImporter.text(value["href"]) { attachments.append(AIExportImporter.placeholder("link", href, size: nil)); continue }
            if let text = MetaExportImporter.text(value["value"]), !["True", "False", "0"].contains(text) {
                let line = label.map { "\($0): \(text)" } ?? text
                if !lines.contains(line) { lines.append(line) }
            }
            for case let item as [String: Any] in (value["media"] as? [Any]) ?? [] {
                if let uri = MetaExportImporter.text(item["uri"]) { attachments.append(media(uri)) }
            }
            for key in ["dict", "vec"] {
                guard let list = value[key] as? [Any] else { continue }
                var inner: [String] = []
                labelValues(list, lines: &inner, times: &times, attachments: &attachments)
                // A group holding just a name, such as `Buyer`, reads better as `Buyer: Alice` than as `Name: Alice`.
                if let label, inner.count == 1, inner[0].hasPrefix("Name: ") { inner = ["\(label): \(inner[0].dropFirst("Name: ".count))"] }
                for line in inner where !lines.contains(line) { lines.append(line) }
            }
        }
    }

    static func media(_ uri: String) -> String {
        let name = (uri as NSString).lastPathComponent
        let kind = ["mp4", "mov"].contains((name as NSString).pathExtension.lowercased()) ? "video" : "photo"
        return AIExportImporter.placeholder(kind, name, size: nil)
    }
}
