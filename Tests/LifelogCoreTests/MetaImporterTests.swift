import Foundation
import XCTest
@testable import LifelogCore

/// Every fixture is synthetic; the shape follows Instagram's JSON "Download your information" export.
enum InstagramFixture {
    static let thread = "your_instagram_activity/messages/inbox/alice_123/"

    static func thread(_ messages: [String]) -> String {
        #"{"participants": [{"name": "Alice"}, {"name": "Me"}], "title": "Alice", "thread_path": "inbox/alice_123", "messages": [\#(messages.joined(separator: ","))]}"#
    }

    /// Files list the newest messages first. `CafÃ©` is Meta's escaping of `Café`: each UTF-8 byte as its own code point.
    static let page1 = thread([
        #"{"sender_name": "Me", "timestamp_ms": 1700000003000, "content": "CafÃ©?"}"#,
        #"{"sender_name": "Alice", "timestamp_ms": 1700000002000, "photos": [{"uri": "your_instagram_activity/messages/inbox/alice_123/photos/p1.jpg"}]}"#,
    ])

    static let page2 = thread([
        #"{"sender_name": "Alice", "timestamp_ms": 1700000001000, "content": "Hi", "reactions": [{"reaction": "x", "actor": "Me"}]}"#,
        #"{"sender_name": "Alice", "timestamp_ms": 1700000001000, "content": "Hi again"}"#,
        #"{"sender_name": "Me", "timestamp_ms": 1700000000000, "is_unsent": true}"#,
    ])

    /// Zips `files` (path → contents) into `inbox/name`.
    @discardableResult
    static func zip(_ files: [String: String], named name: String, in inbox: URL) throws -> URL {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        for (path, contents) in files {
            let url = staging.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        let output = inbox.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", staging.path, output.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return output
    }
}

final class MetaImporterTests: XCTestCase {
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testParsesThreadsAcrossFilesInTimeOrder() throws {
        let inbox = try temporaryDirectory()
        try InstagramFixture.zip([InstagramFixture.thread + "message_1.json": InstagramFixture.page1,
                                  InstagramFixture.thread + "message_2.json": InstagramFixture.page2,
                                  InstagramFixture.thread + "photos/p1.jpg": "jpeg"], named: "instagram-me.zip", in: inbox)
        let result = AIExportImporter.scan(inbox: inbox)
        XCTAssertEqual(result.warnings, [])
        let export = try XCTUnwrap(result.records.first)
        XCTAssertEqual(export.source, .instagram)
        XCTAssertTrue(export.complete)
        let chat = try XCTUnwrap(export.chats.first)
        XCTAssertEqual(chat.id, "alice_123")
        XCTAssertEqual(chat.title, "Alice")
        XCTAssertEqual(chat.messages.map(\.role), ["Me", "Alice", "Alice", "Alice", "Me"])
        XCTAssertEqual(chat.messages.map(\.text), ["[unsent]", "Hi", "Hi again", "", "Café?"])
        XCTAssertEqual(chat.messages[3].attachments, ["[photo: p1.jpg]"])
        XCTAssertEqual(Set(chat.messages.compactMap(\.id)).count, 5, "messages in the same millisecond get their own ids")
        XCTAssertEqual(chat.messages.first?.timestamp, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testFacebookExportsAreMessenger() throws {
        let inbox = try temporaryDirectory()
        try InstagramFixture.zip(["your_facebook_activity/messages/inbox/bob_1/message_1.json": InstagramFixture.page1,
                                  "your_facebook_activity/messages/e2ee_cutover/carol_2/message_1.json": InstagramFixture.page2], named: "facebook.zip", in: inbox)
        try InstagramFixture.zip(["messages/inbox/bob_1/message_1.json": InstagramFixture.page1, "profile_information/facebook_profile.json": "{}"],
                                 named: "legacy.zip", in: inbox)
        let result = AIExportImporter.scan(inbox: inbox)
        XCTAssertEqual(result.warnings, [])
        XCTAssertEqual(result.records.map(\.source), [.messenger, .messenger])
        XCTAssertEqual(result.records.first { $0.zip.lastPathComponent == "facebook.zip" }?.chats.map(\.id), ["bob_1", "carol_2"])
    }

    func testUnrecognizedExportsAreSkipped() throws {
        let inbox = try temporaryDirectory()
        try InstagramFixture.zip(["messages/inbox/bob_1/message_1.json": InstagramFixture.thread([])], named: "unknown.zip", in: inbox)
        try InstagramFixture.zip(["your_instagram_activity/messages/inbox/bob_1/message_1.json": InstagramFixture.thread([]),
                                  "your_facebook_activity/messages/inbox/bob_1/message_1.json": InstagramFixture.thread([])], named: "both.zip", in: inbox)
        try InstagramFixture.zip(["your_instagram_activity/messages/inbox/bob_1/message_1.html": "<html></html>"], named: "html.zip", in: inbox)
        try InstagramFixture.zip(["your_facebook_activity/messages/inbox/bob_1/message_1.html": "<html></html>"], named: "html-fb.zip", in: inbox)
        let result = AIExportImporter.scan(inbox: inbox)
        XCTAssertEqual(result.records.count, 0)
        XCTAssertEqual(result.warnings.sorted(), [
            "html-fb.zip: This Facebook export is in HTML format. Request the export again with the format set to JSON.",
            "html.zip: This Instagram export is in HTML format. Request the export again with the format set to JSON.",
        ])
    }

    func testMojibakeRepairLeavesRealTextAlone() {
        XCTAssertEqual(MetaExportImporter.repairMojibake("Caf\u{00C3}\u{00A9}"), "Café")
        XCTAssertEqual(MetaExportImporter.repairMojibake("\u{00F0}\u{009F}\u{0098}\u{0080}"), "😀")
        XCTAssertEqual(MetaExportImporter.repairMojibake("Café"), "Café")
        XCTAssertEqual(MetaExportImporter.repairMojibake("plain"), "plain")
    }
}

extension ArchiverTests {
    /// Exports come in parts, so a message missing from later exports is never taken for deleted.
    func testInstagramImportsOnlyAdd() async throws {
        let root = try temporaryDirectory()
        let inbox = try temporaryDirectory()
        try InstagramFixture.zip([InstagramFixture.thread + "message_1.json": InstagramFixture.page1,
                                  InstagramFixture.thread + "message_2.json": InstagramFixture.page2], named: "a.zip", in: inbox)
        let first = try await archiver(root).run([AIExportArchiveReader(source: .instagram, inbox: AIInbox(url: inbox))], now: t0)
        XCTAssertEqual(first.added, 5)
        for run in 1...2 {
            try InstagramFixture.zip([InstagramFixture.thread + "message_1.json": InstagramFixture.page1, "part.txt": "\(run)"], named: "part-\(run).zip", in: inbox)
            let summary = try await archiver(root).run([AIExportArchiveReader(source: .instagram, inbox: AIInbox(url: inbox))], now: t0 + Double(run) * day)
            XCTAssertEqual(summary.lines.map(\.source), [.instagram], "the new part is imported")
        }
        let items = try archiver(root).index.items.values
        XCTAssertEqual(items.count, 5)
        XCTAssertTrue(items.allSatisfy { $0.state == .active && $0.missingSince == nil })
        XCTAssertTrue(items.allSatisfy { $0.key.source == .instagram })
    }
}

/// Synthetic files in the shapes of Facebook's JSON export, outside Messenger.
enum FacebookFixture {
    static let posts = #"""
    [{"timestamp": 1700000000, "title": "Me wrote on Alice's profile.", "data": [{"post": "GlÃ¼ckwunsch!"}, {}]},
     {"timestamp": 1700000100, "title": "Me shared a link.", "attachments": [{"data": [{"external_context": {"url": "https://example.com"}}]}], "data": [{}]},
     {"timestamp": 1700000100, "title": "Me added a photo.", "attachments": [{"data": [{"media": {"uri": "your_facebook_activity/posts/media/p/1.jpg", "description": "Lake"}}]}], "data": [{}]}]
    """#
    static let comments = #"{"comments_v2": [{"timestamp": 1702000000, "data": [{"comment": {"comment": "Nice", "author": "Me", "group": "Runners"}}], "title": "Me commented on Bob's post."}]}"#
    static let events = #"{"event_responses_v2": {"events_joined": [{"name": "Picnic", "start_timestamp": 1700100000, "end_timestamp": 0}], "events_declined": [{"name": "Gala", "start_timestamp": 1700200000}]}}"#
    static let sold = #"""
    [{"timestamp": 1700300000, "media": [], "label_values": [{"label": "Product title", "value": "Lamp"}, {"label": "Buyer allowed calling", "value": "False"},
      {"dict": [{"dict": [{"label": "Name", "value": "Carol"}], "title": ""}], "title": "Buyer"}], "fbid": "1"},
     {"media": [], "label_values": [{"label": "Search query", "value": "sofa"}, {"label": "Creation time", "timestamp_value": 1700400000}], "fbid": "2"},
     {"media": [], "label_values": [{"label": "Option", "value": "Undated"}], "fbid": "3"}]
    """#
    static let album = #"{"name": "Trip", "photos": [{"uri": "your_facebook_activity/posts/media/Trip/2.jpg", "creation_timestamp": 1700000200, "title": "Trip"}], "cover_photo": {}, "last_modified_timestamp": 1}"#
    static let friends = #"{"friends_v2": [{"name": "Dana", "timestamp": 1700500000}]}"#

    static var files: [String: String] {
        ["your_facebook_activity/posts/your_posts__check_ins__photos_and_videos_1.json": posts,
         "your_facebook_activity/posts/album/0.json": album,
         "your_facebook_activity/comments_and_reactions/comments.json": comments,
         "your_facebook_activity/events/your_event_responses.json": events,
         "your_facebook_activity/facebook_marketplace/conversations_you_had_as_a_seller.json": sold,
         "connections/friends/your_friends.json": friends,
         "ads_information/ads_viewed.json": #"[{"timestamp": 1700000000, "title": "An ad"}]"#,
         "your_facebook_activity/messages/inbox/bob_1/message_1.json": InstagramFixture.page1]
    }
}

final class FacebookImporterTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!

    func testFacebookZipGivesMessengerAndFacebookExports() throws {
        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: inbox) }
        try InstagramFixture.zip(FacebookFixture.files, named: "facebook.zip", in: inbox)
        let result = AIExportImporter.scan(inbox: inbox)
        XCTAssertEqual(result.warnings, [])
        XCTAssertEqual(result.records.map(\.source), [.messenger, .facebook])
        XCTAssertEqual(result.records[0].chats.map(\.id), ["bob_1"])
    }

    func testEntriesBecomeMonthlyCategoryChats() throws {
        let files = FacebookFixture.files.compactMap { path, json -> (member: String, file: FacebookExportImporter.File, json: Any)? in
            FacebookExportImporter.members([path]).first.map { ($0.member, $0.file, try! JSONSerialization.jsonObject(with: Data(json.utf8))) }
        }
        XCTAssertEqual(files.count, 6, "ads and Messenger files are not Facebook items")
        let chats = FacebookExportImporter.chats(files, timeZone: utc)
        XCTAssertEqual(chats.map(\.id), ["comments/2023-12", "events/2023-11", "friends/2023-11", "marketplace/2023-11", "photos-and-videos/2023-11", "posts/2023-11"])
        XCTAssertEqual(chats.map(\.title).last, "Posts 2023-11")
        func messages(_ id: String) -> [AIChatMessage] { chats.first { $0.id == id }!.messages }

        let posts = messages("posts/2023-11")
        XCTAssertEqual(posts.map(\.text), ["Me wrote on Alice's profile.\nGlückwunsch!", "Me added a photo.\nLake", "Me shared a link."])
        XCTAssertEqual(posts.map(\.attachments), [[], ["[photo: 1.jpg]"], ["[link: https://example.com]"]])
        XCTAssertEqual(Set(posts.compactMap(\.id)).count, 3, "entries in the same second get their own ids")
        XCTAssertEqual(posts[0].id, "posts/your_posts__check_ins__photos_and_videos_1/1700000000")

        XCTAssertEqual(messages("photos-and-videos/2023-11").map(\.text), ["Trip"])
        XCTAssertEqual(messages("comments/2023-12").map(\.text), ["Me commented on Bob's post.\nNice\nGroup: Runners"])
        XCTAssertEqual(messages("events/2023-11").map(\.role), ["Event: joined", "Event: declined"])
        XCTAssertEqual(messages("events/2023-11").map(\.text), ["Picnic", "Gala"])
        let market = messages("marketplace/2023-11")
        XCTAssertEqual(market.map(\.text), ["Product title: Lamp\nBuyer: Carol", "Search query: sofa"], "flags and undated entries are left out")
        XCTAssertEqual(market.map(\.timestamp), [Date(timeIntervalSince1970: 1_700_300_000), Date(timeIntervalSince1970: 1_700_400_000)])
        XCTAssertEqual(messages("friends/2023-11").map { "\($0.role): \($0.text)" }, ["Became friends: Dana"])
    }

    func testPatternsStayWithinOneFolder() {
        XCTAssertTrue(FacebookExportImporter.matches("your_facebook_activity/posts/album/12.json", "your_facebook_activity/posts/album/*.json"))
        XCTAssertFalse(FacebookExportImporter.matches("your_facebook_activity/posts/album/x/12.json", "your_facebook_activity/posts/album/*.json"))
        XCTAssertFalse(FacebookExportImporter.matches("x/your_facebook_activity/posts/album/12.json", "your_facebook_activity/posts/album/*.json"))
    }
}

extension ArchiverTests {
    /// A Facebook zip already imported for Messenger, before the Facebook source was turned on, is still imported for Facebook.
    func testFacebookImportsAZipMessengerAlreadyImported() async throws {
        let root = try temporaryDirectory()
        let inbox = try temporaryDirectory()
        try InstagramFixture.zip(FacebookFixture.files, named: "facebook.zip", in: inbox)
        let first = try await archiver(root).run([AIExportArchiveReader(source: .messenger, inbox: AIInbox(url: inbox))], now: t0)
        XCTAssertEqual(first.lines.map(\.source), [.messenger])
        let shared = AIInbox(url: inbox)
        let second = try await archiver(root).run([AIExportArchiveReader(source: .messenger, inbox: shared), AIExportArchiveReader(source: .facebook, inbox: shared)],
                                                  now: t0 + day)
        XCTAssertEqual(second.lines.map(\.source), [.facebook])
        XCTAssertGreaterThan(second.added, 0)
        let third = try await archiver(root).run([AIExportArchiveReader(source: .messenger, inbox: AIInbox(url: inbox)),
                                                  AIExportArchiveReader(source: .facebook, inbox: AIInbox(url: inbox))], now: t0 + 2 * day)
        XCTAssertTrue(third.lines.isEmpty)
        XCTAssertTrue(try archiver(root).index.items.values.allSatisfy { $0.state == .active })
    }

    /// Facebook entries used to be archived as chat messages. They keep their keys and hashes as entries, so the next
    /// import rewrites each once as an entry without marking it edited, and the pages read the same.
    func testFacebookMovesFromMessagesToEntries() async throws {
        let root = try temporaryDirectory()
        let inbox = try temporaryDirectory()
        try InstagramFixture.zip(FacebookFixture.files, named: "facebook.zip", in: inbox)
        let export = try XCTUnwrap(AIInbox(url: inbox).exports(skipping: []).records.first { $0.source == .facebook })
        // What Lifelog 0.3 wrote for the same export.
        let legacy = export.chats.flatMap { chat in
            chat.messages.map { ArchivePayload.aiMessage(AIArchiveMessage(source: .facebook, chatID: chat.id, chatTitle: chat.title, message: $0)) }
        }
        let reader = FakeReader(.facebook, fixedMode: .import) { _ in [ArchiveRead(payloads: legacy, scope: Scope(containers: []))] }
        _ = try await archiver(root).run([reader], now: t0)
        let before = try archiver(root).index.items
        let page = try XCTUnwrap(FileManager.default.subpathsOfDirectory(atPath: root.appendingPathComponent("Facebook").path).first { $0.hasSuffix(".md") })
        let pageBefore = try String(contentsOf: root.appendingPathComponent("Facebook/\(page)"), encoding: .utf8)

        let summary = try await archiver(root).run([AIExportArchiveReader(source: .facebook, inbox: AIInbox(url: inbox))], now: t0 + day)
        XCTAssertEqual(summary.added, 0)
        XCTAssertEqual(summary.changed, before.count)
        let after = try archiver(root).index.items
        XCTAssertEqual(Set(after.keys), Set(before.keys))
        XCTAssertTrue(after.values.allSatisfy { if case .entry = $0.payload { return !$0.flags.edited } else { return false } })
        XCTAssertEqual(after.mapValues(\.contentHash), before.mapValues(\.contentHash))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Facebook/\(page)"), encoding: .utf8), pageBefore)
    }
}
