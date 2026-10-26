import Foundation
import XCTest
@testable import ICloudExporterCore

/// A reader that answers each request with `respond` and remembers what it was asked.
@MainActor
final class FakeReader: ArchiveReader {
    let source: ArchiveSource
    let fixedMode: ReadMode?
    var requests: [ArchiveReadRequest] = []
    var respond: (ArchiveReadRequest) throws -> [ArchiveRead]

    init(_ source: ArchiveSource, fixedMode: ReadMode? = nil, respond: @escaping (ArchiveReadRequest) throws -> [ArchiveRead]) {
        self.source = source; self.fixedMode = fixedMode; self.respond = respond
    }

    func read(_ request: ArchiveReadRequest) async throws -> [ArchiveRead] {
        requests.append(request)
        return try respond(request)
    }
}

/// Everything here is synthetic: fake readers, temp folders, and transcripts and zips built by the tests.
@MainActor
final class ArchiverTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    let day: TimeInterval = 86_400
    let options = ArchiveOptions(backfillSince: Date(timeIntervalSince1970: 946_684_800), rescanDays: 100, fullSweepDays: 7)

    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A fresh archiver per run, as each `archive` invocation starts from the ledger on disk.
    func archiver(_ root: URL, cacheRoot: URL? = nil) throws -> Archiver {
        let ledger = Ledger(root: root, host: "mac1")
        return Archiver(ledger: ledger, runLog: RunLog(root: root, host: "mac1"), index: try ArchiveIndex.load(ledger, cacheRoot: cacheRoot),
                        options: options, cacheRoot: cacheRoot, timeZone: TimeZone(identifier: "Europe/Berlin")!)
    }

    func reminder(_ id: String, _ title: String = "Buy milk") -> ArchivePayload {
        .reminder(ReminderRecord(id: id, title: title, list: "Home", notes: nil, isCompleted: false, completionDate: nil, due: nil, priority: 0, url: nil, externalID: "ext-\(id)"))
    }

    func note(_ id: String) -> ArchivePayload {
        .note(NoteRecord(id: id, title: "Note \(id)", account: "iCloud", folder: "Notes", created: t0, modified: t0, bodyHTML: "<p>\(id)</p>"))
    }

    func testReadModesMoveFromBackfillToRescanToFullSweep() async throws {
        let root = try temporaryDirectory()
        let payload = reminder("1")
        let reader = FakeReader(.reminders) { _ in [ArchiveRead(payloads: [payload], scope: .reminders(completedSince: nil))] }
        for offset in [0, 1, 6.9, 7, 8, 15] { _ = try await archiver(root).run([reader], now: t0 + offset * day) }
        XCTAssertEqual(reader.requests.map(\.mode), [.backfill, .rescan, .rescan, .full, .rescan, .full])

        let backfill = reader.requests[0], rescan = reader.requests[1]
        XCTAssertEqual(backfill.from, options.backfillSince)
        XCTAssertEqual(backfill.liveFrom, options.backfillSince)
        XCTAssertEqual(rescan.from, Calendar.current.date(byAdding: .day, value: -100, to: t0 + day))
        XCTAssertNil(rescan.liveFrom)
        XCTAssertEqual(rescan.previous.keys.map(\.id), ["ext-1"], "readers see this source's current items")

        let records = try RunLog(root: root, host: "mac1").read().records
        XCTAssertEqual(records.map(\.mode), ["backfill", "rescan", "rescan", "full", "rescan", "full"])
        XCTAssertEqual(records.first?.counts, ["added": 1])
        XCTAssertEqual(records.dropFirst().map(\.counts), Array(repeating: [:], count: 5), "an unchanged item adds nothing")
    }

    func testIncompleteOrFailedBackfillIsRetried() async throws {
        let root = try temporaryDirectory()
        var attempt = 0
        let scope = Scope.calendar(from: t0, to: t0 + day)
        let reader = FakeReader(.calendar) { _ in
            attempt += 1
            if attempt == 1 { throw ExportError.message("Calendar access was denied.") }
            return [ArchiveRead(payloads: [], scope: scope, complete: attempt > 2, warnings: attempt == 2 ? ["partial"] : [])]
        }
        for offset in 0..<4 { _ = try await archiver(root).run([reader], now: t0 + Double(offset) * day) }
        XCTAssertEqual(reader.requests.map(\.mode), [.backfill, .backfill, .backfill, .rescan])
    }

    func testFailedSourceIsLoggedAndOthersContinue() async throws {
        let root = try temporaryDirectory()
        let broken = FakeReader(.whatsapp) { _ in throw ExportError.message("WhatsApp Desktop data was not found; skipped.") }
        let payloads = [note("n1"), note("n2")]
        let notes = FakeReader(.notes) { _ in [ArchiveRead(payloads: payloads, scope: .notes)] }
        let archiver = try archiver(root)
        let summary = try await archiver.run([broken, notes], now: t0)

        XCTAssertEqual(summary.failures, [.whatsapp: "WhatsApp Desktop data was not found; skipped."])
        XCTAssertEqual(summary.added, 2)
        XCTAssertEqual(Set(archiver.index.items.keys.map(\.id)), ["n1", "n2"])
        let records = try RunLog(root: root, host: "mac1").read().records
        let failed = try XCTUnwrap(records.first { $0.source == .whatsapp })
        XCTAssertFalse(failed.complete)
        XCTAssertEqual(failed.scope, "read failed")
        XCTAssertEqual(failed.mode, "backfill")
        XCTAssertEqual(failed.warnings, ["WhatsApp Desktop data was not found; skipped."])
        XCTAssertTrue(try XCTUnwrap(records.first { $0.source == .notes }).complete)

        let page = try String(contentsOf: root.appendingPathComponent("_index.md"), encoding: .utf8)
        XCTAssertTrue(page.contains("| Notes | 2026-09-21 16:13 |"), page)
        XCTAssertTrue(page.contains("| backfill | 2 | 0 | 0 |"), page)
        XCTAssertTrue(page.contains("| WhatsApp | never | – | 0 | 0 | 0 |"), page)
        XCTAssertTrue(page.contains("- WhatsApp, 2026-09-21 16:13:"), page)
    }

    func testTombstoneNeedsTwoCompleteMissesAndSurvivesReload() async throws {
        let root = try temporaryDirectory()
        let cache = try temporaryDirectory()
        var present = [reminder("1"), reminder("2", "Call Anna"), reminder("3", "Water plants")]
        var complete = true
        let reader = FakeReader(.reminders) { _ in [ArchiveRead(payloads: present, scope: .reminders(completedSince: nil), complete: complete)] }

        _ = try await archiver(root, cacheRoot: cache).run([reader], now: t0)
        present.removeLast()
        var summary = try await archiver(root, cacheRoot: cache).run([reader], now: t0 + day)
        XCTAssertEqual(summary.pending, 1)
        // An incomplete read in between neither confirms nor clears the miss.
        complete = false
        summary = try await archiver(root, cacheRoot: cache).run([reader], now: t0 + 2 * day)
        XCTAssertEqual(summary.tombstoned + summary.pending, 0)
        complete = true
        let archiver = try archiver(root, cacheRoot: cache)
        summary = try await archiver.run([reader], now: t0 + 3 * day)
        XCTAssertEqual(summary.tombstoned, 1)
        XCTAssertEqual(archiver.index.items[ItemKey(source: .reminders, id: "ext-3")]?.state, .deleted)

        // The cache written after the run matches a fresh fold of the ledger.
        let ledger = Ledger(root: root, host: "mac1")
        XCTAssertEqual(try ArchiveIndex.load(ledger, cacheRoot: cache).items, archiver.index.items)
        XCTAssertEqual(try ArchiveIndex.load(ledger, cacheRoot: nil).items, archiver.index.items)
    }

    func testAIExportDigestsAreImportedOnce() async throws {
        let root = try temporaryDirectory()
        let chat = AIArchiveMessage(source: .chatgpt, chatID: "c1", chatTitle: "Trip", message: AIChatMessage(id: "m1", role: "user", timestamp: t0, text: "Hello"))
        let reader = FakeReader(.chatgpt, fixedMode: .import) { request in
            request.importedDigests.contains("zip-1") ? [] : [ArchiveRead(payloads: [.aiMessage(chat)], scope: Scope(), digest: "zip-1")]
        }
        _ = try await archiver(root).run([reader], now: t0)
        let summary = try await archiver(root).run([reader], now: t0 + day)
        XCTAssertEqual(reader.requests.map(\.importedDigests), [[], ["zip-1"]])
        XCTAssertEqual(reader.requests.map(\.mode), [.import, .import])
        XCTAssertTrue(summary.lines.isEmpty, "nothing new is not a run")
        XCTAssertEqual(try RunLog(root: root, host: "mac1").read().records.map(\.digest), ["zip-1"])
    }

    func testInboxZipIsImportedOnceAndLeftInPlace() async throws {
        let root = try temporaryDirectory()
        let inbox = try temporaryDirectory()
        let staging = try temporaryDirectory()
        let conversations = """
        [{"uuid": "conv-1", "name": "Trip ideas", "created_at": "2026-01-02T03:04:05.123456Z", "updated_at": "2026-01-02T03:05:00Z",
          "chat_messages": [
            {"uuid": "m1", "sender": "human", "created_at": "2026-01-02T03:04:05Z", "content": [{"type": "text", "text": "Where to hike?"}]},
            {"uuid": "m2", "sender": "assistant", "created_at": "2026-01-02T03:04:09Z", "content": [{"type": "text", "text": "Patagonia."}]}]}]
        """
        try Data(conversations.utf8).write(to: staging.appendingPathComponent("conversations.json"))
        try Data("[]".utf8).write(to: staging.appendingPathComponent("users.json"))
        let zip = inbox.appendingPathComponent("data-export.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", staging.path, zip.path]
        try process.run()
        process.waitUntilExit()

        let shared = AIInbox(url: inbox)
        let first = try await archiver(root).run([AIExportArchiveReader(source: .claude, inbox: shared), AIExportArchiveReader(source: .chatgpt, inbox: shared)], now: t0)
        XCTAssertEqual(first.lines.map(\.source), [.claude], "a Claude export is not a ChatGPT one")
        XCTAssertEqual(first.added, 2)
        let archiver = try archiver(root)
        let second = try await archiver.run([AIExportArchiveReader(source: .claude, inbox: AIInbox(url: inbox))], now: t0 + day)
        XCTAssertTrue(second.lines.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: zip.path))
        XCTAssertEqual(Set(archiver.index.items.keys.map(\.id)), ["conv-1/m1", "conv-1/m2"])
    }

    func testUnreadableInboxIsLoggedWithoutAnImport() async throws {
        let root = try temporaryDirectory()
        let missing = try temporaryDirectory().appendingPathComponent("nope")
        let summary = try await archiver(root).run([AIExportArchiveReader(source: .chatgpt, inbox: AIInbox(url: missing))], now: t0)
        XCTAssertEqual(summary.lines.map(\.complete), [false])
        XCTAssertEqual(summary.warnings.count, 1)
        XCTAssertNil(try RunLog(root: root, host: "mac1").read().records.first?.digest)
    }

    func testClaudeCodeTranscriptsAreReadIncrementally() async throws {
        let root = try temporaryDirectory()
        let projects = try temporaryDirectory()
        let cursorFile = try temporaryDirectory().appendingPathComponent("cursors.json")
        let file = projects.appendingPathComponent("-Users-test-app/s-1.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        func line(_ type: String, _ uuid: String, _ second: Int, _ text: String) -> String {
            #"{"type": "\#(type)", "uuid": "\#(uuid)", "sessionId": "s-1", "cwd": "/Users/test/app", "timestamp": "2026-01-02T03:04:0\#(second)Z", "message": {"role": "\#(type)", "content": "\#(text)"}}"# + "\n"
        }
        try Data((line("user", "u1", 1, "Fix the parser") + line("assistant", "a1", 2, "Done.")).utf8).write(to: file)
        let reader = ClaudeCodeArchiveReader(root: projects, cursorFile: cursorFile)

        let first = try await archiver(root).run([reader], now: t0)
        XCTAssertEqual(first.added, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cursorFile.path), "the read position is saved after the append")

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line("user", "u2", 3, "Thanks").utf8))
        try handle.close()
        let archiver = try archiver(root)
        let second = try await archiver.run([reader], now: t0 + 600)
        XCTAssertEqual(second.lines.first?.counts, ["added": 1])
        XCTAssertEqual(second.lines.first?.mode, .incremental)
        let added = try XCTUnwrap(archiver.index.items[ItemKey(source: .claudecode, id: "s-1/u2")])
        guard case .aiMessage(let value) = added.payload else { return XCTFail("not an AI message") }
        XCTAssertEqual(value.chatTitle, "Fix the parser", "a later read keeps the session title")

        // A removed transcript is Claude Code's own cleanup, not a deletion.
        try FileManager.default.removeItem(at: file)
        for offset in 1...2 { _ = try await self.archiver(root).run([reader], now: t0 + 600 + Double(offset) * day) }
        XCTAssertTrue(try self.archiver(root).index.items.values.allSatisfy { $0.state == .active && $0.missingSince == nil })

        // Cursors for sessions an archive does not hold are ignored, so a fresh archive reads everything.
        try Data((line("user", "u1", 1, "Fix the parser") + line("assistant", "a1", 2, "Done.") + line("user", "u2", 3, "Thanks")).utf8).write(to: file)
        _ = try await self.archiver(root).run([reader], now: t0 + 8 * day)
        let fresh = try await self.archiver(try temporaryDirectory()).run([reader], now: t0 + 9 * day)
        XCTAssertEqual(fresh.added, 3)
    }

    func testDemoAndRealArchivesDoNotMix() async throws {
        let root = try temporaryDirectory()
        for run in Demo.archiveRuns(now: t0) { _ = try await archiver(root).run(run.readers, now: run.at, demo: true) }
        let payload = note("n1")
        let reader = FakeReader(.notes) { _ in [ArchiveRead(payloads: [payload], scope: .notes)] }
        do {
            _ = try await archiver(root).run([reader], now: t0 + day)
            XCTFail("a real run must refuse a demo archive")
        } catch {}
        XCTAssertTrue(reader.requests.isEmpty, "the refusal comes before any read")

        let real = try temporaryDirectory()
        _ = try await archiver(real).run([reader], now: t0)
        do {
            _ = try await archiver(real).run(Demo.archiveRuns(now: t0)[0].readers, now: t0, demo: true)
            XCTFail("a demo must refuse a real archive")
        } catch {}
    }

    func testDemoShowsEveryKindOfDisappearance() async throws {
        let root = try temporaryDirectory()
        for run in Demo.archiveRuns(now: t0) { _ = try await archiver(root).run(run.readers, now: run.at, demo: true) }
        let items = try archiver(root).index.items.values
        let states = Dictionary(grouping: items, by: \.state).mapValues(\.count)
        XCTAssertEqual(states[.expired], 2)
        XCTAssertEqual(states[.revoked], 1)
        XCTAssertEqual(states[.deleted], 2)
        XCTAssertEqual(states[.locked], 1)
        XCTAssertEqual(states[.completed], 1)
        let revoked = try XCTUnwrap(items.first { $0.state == .revoked })
        guard case .message(let value) = revoked.payload else { return XCTFail("not a message") }
        XCTAssertEqual(value.message.text, "Running late, start without me", "a revoked message keeps its last text")
    }

    func testPartitionUsesTheItemsOwnDateAndZone() {
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        let late = Date(timeIntervalSince1970: 1_790_031_600) // 2026-09-21 23:00 UTC
        let message = ArchivePayload.message(WhatsAppArchiveMessage(chatJID: "j", chatTitle: "A", chatKind: "direct",
                                                                    message: WhatsAppMessageRecord(id: "1", sender: "A", timestamp: late, fromMe: false, text: "hi", placeholder: nil)))
        XCTAssertEqual(Partition.of(message, fallback: t0, timeZone: berlin), Partition(date: "2026-09-22", utcOffset: 7200))
        let event = ArchivePayload.event(CalendarRecord(id: "e", title: "Call", calendar: "Work", start: late, end: late + 3600, isAllDay: false,
                                                        timeZone: "America/New_York", location: nil, notes: nil, url: nil))
        XCTAssertEqual(Partition.of(event, fallback: t0, timeZone: berlin), Partition(date: "2026-09-21", utcOffset: -14400))
    }

    func testAIMessagesRoundTripThroughTheLedger() throws {
        let root = try temporaryDirectory()
        let ledger = Ledger(root: root, host: "mac1")
        let message = AIChatMessage(id: nil, role: "user", timestamp: nil, text: "hi", attachments: ["[file: a.pdf]"])
        let export = AIExport(source: .claude, zip: root.appendingPathComponent("x.zip"), digest: "d",
                              chats: [AIChatRecord(id: "c", title: "T", created: nil, updated: nil, project: "P", messages: [message, message])], complete: true, warnings: [])
        let read = AIExportArchiveReader.read(export)
        XCTAssertEqual(read.digest, "d")
        let items = StableKey.items(read.payloads, at: t0) { _ in Partition(date: "2026-09-21", utcOffset: 0) }
        XCTAssertEqual(items.map(\.key.id), ["c/#0", "c/#1"], "repeated messages without ids keep their own keys")
        XCTAssertEqual(items[0].key.source, .claude)
        try ledger.append(items.map { LedgerEvent(type: .added, at: t0, run: "r1", key: $0.key, item: $0) })
        XCTAssertEqual(ArchiveIndex.fold(try ledger.read().events).items[items[1].key]?.payload, read.payloads[1])
    }
}
