import Foundation
import XCTest
@testable import LifelogCore

/// Every fixture is synthetic and built here; the shapes follow the public descriptions of each export.
final class AIExportImporterTests: XCTestCase {
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Zips `files` (path → contents) into `inbox/name`.
    @discardableResult
    func zip(_ files: [String: String], named name: String, in inbox: URL) throws -> URL {
        let staging = try temporaryDirectory()
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

    func node(_ id: String, parent: String?, children: [String], role: String? = nil, text: String = "", time: Double = 0,
              metadata: String = #"{"model_slug": "gpt-test"}"#) -> String {
        let message = role.map { """
        {"id": "\(id)", "author": {"role": "\($0)"}, "create_time": \(time), "content": {"content_type": "text", "parts": ["\(text)"]}, "recipient": "all", "metadata": \(metadata)}
        """ } ?? "null"
        let parentValue = parent.map { "\"\($0)\"" } ?? "null"
        return "\"\(id)\": {\"id\": \"\(id)\", \"parent\": \(parentValue), \"children\": [\(children.map { "\"\($0)\"" }.joined(separator: ","))], \"message\": \(message)}"
    }

    var chatGPTConversations: String {
        // root → system → u1 → a1 (regenerated away) | a2 → u2a (edited away) | u2b → tool call → tool output → a3 (current)
        let mapping = [
            node("root", parent: nil, children: ["sys"]),
            node("sys", parent: "root", children: ["u1"], role: "system", text: "", time: 1_700_000_000),
            node("u1", parent: "sys", children: ["a1", "a2"], role: "user", text: "Hello there", time: 1_700_000_010,
                 metadata: #"{"attachments": [{"id": "file-1", "name": "notes.pdf", "size": 2048}]}"#),
            node("a1", parent: "u1", children: [], role: "assistant", text: "First answer", time: 1_700_000_020),
            node("a2", parent: "u1", children: ["u2a", "u2b"], role: "assistant", text: "Second answer", time: 1_700_000_030),
            node("u2a", parent: "a2", children: [], role: "user", text: "Original question", time: 1_700_000_040),
            node("u2b", parent: "a2", children: ["call"], role: "user", text: "Edited question", time: 1_700_000_050),
            """
            "call": {"id": "call", "parent": "u2b", "children": ["out"], "message": {"id": "call", "author": {"role": "assistant"}, "create_time": 1700000060, "recipient": "python", "content": {"content_type": "code", "language": "python", "text": "print(1)"}}}
            """,
            """
            "out": {"id": "out", "parent": "call", "children": ["a3"], "message": {"id": "out", "author": {"role": "tool", "name": "python"}, "create_time": 1700000061, "content": {"content_type": "execution_output", "text": "1"}}}
            """,
            """
            "a3": {"id": "a3", "parent": "out", "children": [], "message": {"id": "a3", "author": {"role": "assistant"}, "create_time": 1700000070, "recipient": "all", "content": {"content_type": "multimodal_text", "parts": ["Here is a chart", {"content_type": "image_asset_pointer", "asset_pointer": "file-service://img", "size_bytes": 512}]}, "metadata": {"model_slug": "gpt-test-2"}}}
            """,
        ].joined(separator: ",\n")
        return """
        [{"title": "Greetings", "create_time": 1700000000.5, "update_time": 1700000070, "conversation_id": "c-1", "current_node": "a3",
          "default_model_slug": "gpt-test", "gizmo_id": "g-p-project1", "mapping": {\(mapping)}},
         {"title": "No current node", "create_time": 1700001000, "update_time": 1700001100, "id": "c-2", "mapping": {
           \(node("r", parent: nil, children: ["x", "y"])),
           \(node("x", parent: "r", children: [], role: "user", text: "older", time: 1_700_001_010)),
           \(node("y", parent: "r", children: [], role: "user", text: "newer", time: 1_700_001_020))}}]
        """
    }

    let claudeConversations = """
    [{"uuid": "k-1", "name": "Trip planning", "summary": "", "created_at": "2024-05-01T12:00:00.123456Z", "updated_at": "2024-05-01T12:05:00Z",
      "project_uuid": "p-1", "account": {"uuid": "acct"},
      "chat_messages": [
        {"uuid": "m1", "sender": "human", "text": "Plan a trip", "created_at": "2024-05-01T12:00:01.5Z", "content": [{"type": "text", "text": "Plan a trip"}],
         "attachments": [{"file_name": "itinerary.txt", "file_size": 300, "file_type": "txt", "extracted_content": "secret plans"}], "files": [{"file_name": "photo.jpg"}]},
        {"uuid": "m2", "sender": "assistant", "text": "", "created_at": "2024-05-01T12:00:05Z", "content": [
          {"type": "thinking", "thinking": "hmm"},
          {"type": "tool_use", "name": "web_search", "input": {"query": "trains"}},
          {"type": "tool_result", "name": "web_search", "content": [{"type": "text", "text": "results"}]},
          {"type": "text", "text": "Take the train."}]},
        {"uuid": "m3", "sender": "human", "text": "Thanks", "created_at": "2024-05-01T12:01:00Z"}]}]
    """

    func testChatGPTExportFollowsCurrentBranch() throws {
        let inbox = try temporaryDirectory()
        // Any name: exports are found by structure.
        let file = try zip(["conversations.json": chatGPTConversations, "chat.html": "<html></html>", "user.json": "{}",
                            "file-abc.png": "not really a png"], named: "random name (1).zip", in: inbox)
        let before = try Data(contentsOf: file)

        let result = AIExportImporter.scan(inbox: inbox)
        XCTAssertEqual(result.warnings, [])
        let export = try XCTUnwrap(result.records.first)
        XCTAssertEqual(export.source, .chatgpt)
        XCTAssertTrue(export.complete)
        XCTAssertEqual(export.digest, MarkdownWriter.digest(before))
        XCTAssertEqual(try Data(contentsOf: file), before, "the zip is left in place, unchanged")

        let chat = try XCTUnwrap(export.chats.first { $0.id == "c-1" })
        XCTAssertEqual(chat.title, "Greetings")
        XCTAssertEqual(chat.created, Date(timeIntervalSince1970: 1_700_000_000.5))
        XCTAssertEqual(chat.model, "gpt-test")
        XCTAssertEqual(chat.project, "g-p-project1")
        XCTAssertEqual(chat.messages.map(\.id), ["u1", "a2", "u2b", "call", "out", "a3"], "empty system and other branches are left out")
        XCTAssertEqual(chat.otherBranchMessages, 2, "a1 and u2a")
        XCTAssertEqual(chat.messages.map(\.role), ["user", "assistant", "user", "assistant", "tool", "assistant"])
        XCTAssertEqual(chat.messages[0].attachments, ["[attachment: notes.pdf, 2048 bytes]"])
        XCTAssertEqual(chat.messages[2].text, "Edited question")
        XCTAssertTrue(chat.messages[3].text.hasPrefix("[tool call: python, "))
        XCTAssertTrue(chat.messages[4].text.hasPrefix("[tool result: python, "))
        XCTAssertFalse(chat.messages[3].text.contains("print(1)"))
        XCTAssertEqual(chat.messages[5].text, "Here is a chart")
        XCTAssertEqual(chat.messages[5].attachments, ["[image: file-service://img, 512 bytes]"])
        XCTAssertEqual(chat.messages[5].model, "gpt-test-2")

        let fallback = try XCTUnwrap(export.chats.first { $0.id == "c-2" })
        XCTAssertEqual(fallback.messages.map(\.text), ["newer"], "without current_node, the most recent leaf")
        XCTAssertEqual(fallback.otherBranchMessages, 1)
    }

    func testClaudeExportInsideTopFolder() throws {
        let inbox = try temporaryDirectory()
        try zip(["data-2024/conversations.json": claudeConversations, "data-2024/users.json": "[]",
                 "data-2024/projects.json": #"[{"uuid": "p-1", "name": "Travel"}]"#], named: "export.zip", in: inbox)
        let export = try XCTUnwrap(AIExportImporter.scan(inbox: inbox).records.first)
        XCTAssertEqual(export.source, .claude)
        XCTAssertTrue(export.complete)
        let chat = try XCTUnwrap(export.chats.first)
        XCTAssertEqual(chat.id, "k-1")
        XCTAssertEqual(chat.title, "Trip planning")
        XCTAssertEqual(chat.project, "Travel")
        XCTAssertEqual(chat.created!.timeIntervalSince1970, 1_714_564_800.123, accuracy: 0.001)
        XCTAssertEqual(chat.updated, Date(timeIntervalSince1970: 1_714_565_100))
        XCTAssertEqual(chat.messages.map(\.role), ["user", "assistant", "user"])
        XCTAssertEqual(chat.messages[0].timestamp!.timeIntervalSince1970, 1_714_564_801.5, accuracy: 0.001)
        XCTAssertEqual(chat.messages[0].attachments, ["[attachment: itinerary.txt, 300 bytes]", "[file: photo.jpg]"])
        XCTAssertFalse(chat.messages[0].text.contains("secret plans"), "extracted attachment text is not copied")
        let reply = chat.messages[1].text.split(separator: "\n").map(String.init)
        XCTAssertEqual(reply.count, 4)
        XCTAssertTrue(reply[0].hasPrefix("[thinking: "))
        XCTAssertTrue(reply[1].hasPrefix("[tool call: web_search, "))
        XCTAssertTrue(reply[2].hasPrefix("[tool result: web_search, "))
        XCTAssertEqual(reply[3], "Take the train.")
        XCTAssertEqual(chat.messages[2].text, "Thanks", "messages without content blocks fall back to text")
    }

    func testEmptyExportsAreRecognizedBySiblingFiles() throws {
        let inbox = try temporaryDirectory()
        try zip(["conversations.json": "[]", "message_feedback.json": "[]"], named: "a.zip", in: inbox)
        try zip(["conversations.json": "[]", "users.json": "[]"], named: "b.zip", in: inbox)
        try zip(["conversations.json": "[]"], named: "c.zip", in: inbox)
        let result = AIExportImporter.scan(inbox: inbox)
        XCTAssertEqual(Set(result.records.map(\.source)), [.chatgpt, .claude])
        XCTAssertTrue(result.records.allSatisfy { $0.chats.isEmpty && $0.complete }, "an empty export is a complete read of zero chats")
    }

    func testIgnoresOtherFilesAndSkipsKnownDigests() throws {
        let inbox = try temporaryDirectory()
        try zip(["photos/a.jpg": "x"], named: "holiday.zip", in: inbox)
        try zip(["deep/er/conversations.json": chatGPTConversations], named: "nested.zip", in: inbox)
        try Data("PK not a zip".utf8).write(to: inbox.appendingPathComponent("fake.zip"))
        try Data(chatGPTConversations.utf8).write(to: inbox.appendingPathComponent("conversations.json"))
        let real = try zip(["conversations.json": claudeConversations], named: "x.bin", in: inbox)
        try FileManager.default.createSymbolicLink(at: inbox.appendingPathComponent("link.zip"), withDestinationURL: real)

        let first = AIExportImporter.scan(inbox: inbox)
        XCTAssertEqual(first.warnings, [])
        XCTAssertEqual(first.records.map(\.zip.lastPathComponent), ["x.bin"])
        let again = AIExportImporter.scan(inbox: inbox, skipDigests: Set(first.records.map(\.digest)))
        XCTAssertEqual(again.records.count, 0)
    }

    func testMalformedInputWarnsAndMarksIncomplete() throws {
        let inbox = try temporaryDirectory()
        try zip(["conversations.json": "{ not json"], named: "broken.zip", in: inbox)
        try zip(["conversations.json": #"{"mapping": {}}"#], named: "object.zip", in: inbox)
        let mixed = """
        [{"title": "ok", "conversation_id": "c-ok", "mapping": {}}, {"title": "no id", "mapping": {}}, 42,
         {"conversation_id": "c-cycle", "current_node": "a", "mapping": {"a": {"parent": "b", "children": [], "message": null}, "b": {"parent": "a", "children": ["a"]}}}]
        """
        try zip(["conversations.json": mixed], named: "mixed.zip", in: inbox)
        try Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x01]).write(to: inbox.appendingPathComponent("truncated.zip"))

        let result = AIExportImporter.scan(inbox: inbox)
        XCTAssertEqual(result.warnings.count, 3, "\(result.warnings)")
        XCTAssertTrue(result.warnings.contains { $0.hasPrefix("broken.zip: ") })
        XCTAssertTrue(result.warnings.contains { $0.hasPrefix("object.zip: ") })
        XCTAssertTrue(result.warnings.contains { $0.hasPrefix("truncated.zip: ") })
        let export = try XCTUnwrap(result.records.first)
        XCTAssertEqual(export.zip.lastPathComponent, "mixed.zip")
        XCTAssertFalse(export.complete, "a skipped conversation would otherwise look deleted")
        XCTAssertEqual(export.warnings.count, 2)
        XCTAssertEqual(export.chats.map(\.id), ["c-ok", "c-cycle"])
        XCTAssertEqual(export.chats[1].messages, [], "a parent cycle terminates")

        XCTAssertEqual(AIExportImporter.scan(inbox: inbox.appendingPathComponent("missing")).warnings.count, 1)
    }

    func testTempDirectoryIsPrivateAndRemoved() throws {
        var seen: URL?
        try AIExportImporter.withPrivateDirectory { directory in
            seen = directory
            let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o700)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(seen).path))
        XCTAssertThrowsError(try AIExportImporter.withPrivateDirectory { directory -> Void in
            seen = directory
            throw ExportError.message("boom")
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(seen).path))
    }

    func testISODates() {
        XCTAssertEqual(AIExportImporter.isoDate("2024-05-01T12:00:00Z"), Date(timeIntervalSince1970: 1_714_564_800))
        XCTAssertEqual(AIExportImporter.isoDate("2024-05-01T12:00:00.250+02:00"), Date(timeIntervalSince1970: 1_714_557_600.25))
        XCTAssertEqual(AIExportImporter.isoDate("2024-05-01T12:00:00.123456789Z")!.timeIntervalSince1970, 1_714_564_800.123, accuracy: 0.001)
        XCTAssertNil(AIExportImporter.isoDate("yesterday"))
        XCTAssertNil(AIExportImporter.isoDate(12))
        XCTAssertNil(AIExportImporter.epoch(true))
    }
}

final class ClaudeCodeReaderTests: XCTestCase {
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    let path = "-Users-test-dev-app/s-1.jsonl"

    func line(_ type: String, _ uuid: String, at second: Int, message: String, extra: String = "") -> String {
        #"{"type": "\#(type)", "uuid": "\#(uuid)", "sessionId": "s-1", "cwd": "/Users/test/dev/app", "timestamp": "2026-01-02T03:04:\#(String(format: "%02d", second)).500Z", "message": \#(message)\#(extra)}"# + "\n"
    }

    var firstPart: String {
        line("user", "u0", at: 0, message: #"{"role": "user", "content": "<local-command-caveat>ignore</local-command-caveat>"}"#, extra: #", "isMeta": true"#)
            + line("user", "u1", at: 1, message: #"{"role": "user", "content": "Fix the failing test\nin the parser"}"#)
            + line("assistant", "a1", at: 2, message: #"{"id": "msg_1", "role": "assistant", "model": "claude-test", "content": [{"type": "thinking", "thinking": "let me see"}]}"#)
            + line("assistant", "a2", at: 3, message: #"{"id": "msg_1", "role": "assistant", "model": "claude-test", "content": [{"type": "text", "text": "Running the tests."}, {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "swift test"}}]}"#)
            + "{ broken\n"
            + #"{"type": "file-history-snapshot", "snapshot": {}}"# + "\n"
    }

    var secondPart: String {
        line("user", "u2", at: 4, message: #"{"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": "All 42 tests passed with secret output"}]}"#)
            + line("assistant", "a3", at: 5, message: #"{"id": "msg_2", "role": "assistant", "model": "claude-test", "content": [{"type": "text", "text": "Done."}]}"#)
            + line("assistant", "x1", at: 6, message: #"{"role": "assistant", "content": "subagent chatter"}"#, extra: #", "isSidechain": true"#)
    }

    func write(_ text: String, to root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Rewrite in place so the inode, and with it the cursor's file id, stays the same.
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        } else {
            try Data(text.utf8).write(to: url)
        }
    }

    func testReadsTextAndPlaceholdersIncrementally() throws {
        let root = try temporaryDirectory()
        let partial = #"{"type": "user", "uuid": "u2", "mess"#
        try write(firstPart + partial, to: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("-Users-test-dev-app/s-1/subagents"), withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: root.appendingPathComponent("-Users-test-dev-app/s-1/subagents/agent.jsonl"))
        XCTAssertEqual(ClaudeCodeReader.sessionFiles(root: root), [path])

        let first = ClaudeCodeReader.read(root: root)
        let read = try XCTUnwrap(first.records.first)
        XCTAssertEqual(first.warnings.count, 1, "the broken line")
        XCTAssertEqual(read.chat.id, "s-1")
        XCTAssertEqual(read.chat.title, "Fix the failing test")
        XCTAssertEqual(read.chat.project, "/Users/test/dev/app")
        XCTAssertEqual(read.chat.model, "claude-test")
        XCTAssertEqual(read.chat.messages.map(\.role), ["user", "assistant"], "meta lines are dropped and streamed blocks merged")
        XCTAssertEqual(read.chat.messages[1].text.split(separator: "\n").count, 3)
        XCTAssertTrue(read.chat.messages[1].text.contains("Running the tests."))
        XCTAssertTrue(read.chat.messages[1].text.contains("[tool call: Bash, "))
        XCTAssertFalse(read.chat.messages[1].text.contains("swift test"))
        XCTAssertEqual(read.chat.created!.timeIntervalSince1970.truncatingRemainder(dividingBy: 60), 1.5, accuracy: 0.001)
        XCTAssertEqual(read.cursor.offset, UInt64(firstPart.utf8.count), "the unfinished line is left for later")
        XCTAssertEqual(read.cursor.pendingTools, ["t1": "Bash"])
        XCTAssertFalse(read.restarted)

        XCTAssertEqual(ClaudeCodeReader.read(root: root, cursors: [path: read.cursor]).records.count, 0, "nothing new")

        try write(firstPart + secondPart, to: root)
        let next = try XCTUnwrap(ClaudeCodeReader.read(root: root, cursors: [path: read.cursor]).records.first)
        XCTAssertFalse(next.restarted)
        XCTAssertEqual(next.chat.title, "", "the first prompt was in an earlier read")
        XCTAssertEqual(next.chat.messages.map(\.role), ["tool", "assistant"], "sidechain lines are dropped")
        XCTAssertTrue(next.chat.messages[0].text.hasPrefix("[tool result: Bash, "))
        XCTAssertFalse(next.chat.messages[0].text.contains("secret"))
        XCTAssertEqual(next.chat.messages[1].text, "Done.")
        XCTAssertEqual(next.cursor.pendingTools, [:])
        XCTAssertEqual(next.cursor.offset, UInt64((firstPart + secondPart).utf8.count))
    }

    func testRestartsWhenTheFileShrinksOrIsReplaced() throws {
        let root = try temporaryDirectory()
        try write(firstPart + secondPart, to: root)
        let full = try ClaudeCodeReader.read(root: root, path: path, cursor: nil)

        try write(secondPart, to: root)
        let shrunk = try ClaudeCodeReader.read(root: root, path: path, cursor: full.cursor)
        XCTAssertTrue(shrunk.restarted)
        XCTAssertEqual(shrunk.chat.messages.map(\.text).last, "Done.")

        var stale = shrunk.cursor
        stale.fileID = (stale.fileID ?? 0) &+ 1
        let replaced = try ClaudeCodeReader.read(root: root, path: path, cursor: stale)
        XCTAssertTrue(replaced.restarted)
        XCTAssertEqual(replaced.cursor.offset, UInt64(secondPart.utf8.count))
    }

    func testSummaryTitleAndUnknownToolResults() throws {
        let root = try temporaryDirectory()
        try write(#"{"type": "summary", "summary": "Parser fix", "leafUuid": "u9"}"# + "\n" + secondPart, to: root)
        let read = try ClaudeCodeReader.read(root: root, path: path, cursor: nil)
        XCTAssertEqual(read.chat.title, "Parser fix")
        XCTAssertTrue(read.chat.messages[0].text.hasPrefix("[tool result, "), "the call was never seen, so no name")
        XCTAssertEqual(ClaudeCodeReader.read(root: root.appendingPathComponent("missing")).records.count, 0)
        XCTAssertThrowsError(try ClaudeCodeReader.read(root: root, path: "nope/x.jsonl", cursor: nil))
    }
}

final class AISourceConfigTests: XCTestCase {
    func testAISourcesAreArchiveOnly() throws {
        XCTAssertEqual(try Config(arguments: ["export", "--output", "/tmp/x"]).sources, Set(ExportSource.exportable))
        XCTAssertThrowsError(try Config(arguments: ["export", "--output", "/tmp/x", "--sources", "notes,chatgpt"]))
        XCTAssertEqual(try Config(arguments: ["archive", "--output", "/tmp/a"]).sources, Set(ExportSource.exportable), "opt-in until runs import them")
        XCTAssertEqual(try Config(arguments: ["archive", "--output", "/tmp/a", "--sources", "chatgpt,claude,claudecode"]).sources, [.chatgpt, .claude, .claudecode])
    }
}
