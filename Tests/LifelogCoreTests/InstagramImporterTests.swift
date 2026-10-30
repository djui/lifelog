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

final class InstagramImporterTests: XCTestCase {
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

    func testOtherExportsAreNotInstagram() throws {
        let inbox = try temporaryDirectory()
        try InstagramFixture.zip(["your_facebook_activity/messages/inbox/bob_1/message_1.json": InstagramFixture.thread([])], named: "facebook.zip", in: inbox)
        try InstagramFixture.zip(["messages/inbox/bob_1/message_1.json": InstagramFixture.thread([])], named: "unknown.zip", in: inbox)
        try InstagramFixture.zip(["your_instagram_activity/messages/inbox/bob_1/message_1.html": "<html></html>"], named: "html.zip", in: inbox)
        let result = AIExportImporter.scan(inbox: inbox)
        XCTAssertEqual(result.records.count, 0)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].hasPrefix("html.zip: ") && result.warnings[0].contains("JSON"), "\(result.warnings)")
    }

    func testMojibakeRepairLeavesRealTextAlone() {
        XCTAssertEqual(InstagramExportImporter.repairMojibake("Caf\u{00C3}\u{00A9}"), "Café")
        XCTAssertEqual(InstagramExportImporter.repairMojibake("\u{00F0}\u{009F}\u{0098}\u{0080}"), "😀")
        XCTAssertEqual(InstagramExportImporter.repairMojibake("Café"), "Café")
        XCTAssertEqual(InstagramExportImporter.repairMojibake("plain"), "plain")
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
