import Foundation
import XCTest
@testable import LifelogCore

/// Synthetic archives shaped like those built while repeated Claude Code lines collided.
@MainActor
final class DedupeTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func message(_ uuid: String, _ text: String, chat: String = "s-1", source: ArchiveSource = .claudecode) -> ArchivePayload {
        .aiMessage(AIArchiveMessage(source: source, chatID: chat, chatTitle: "Fix", message: AIChatMessage(id: uuid, role: "user", timestamp: t0, text: text)))
    }

    func added(_ payload: ArchivePayload, id: String? = nil, at: Date) -> LedgerEvent {
        let key = ItemKey(source: payload.source, id: id ?? StableKey.id(of: payload))
        let item = ArchivedItem(key: key, nativeID: StableKey.nativeID(of: payload), partition: Partition(date: "2026-09-21", utcOffset: 0),
                                stateSince: at, contentHash: StableKey.contentHash(of: payload), payload: payload)
        return LedgerEvent(type: .added, at: at, run: "r-\(at.timeIntervalSince1970)", key: key, item: item)
    }

    /// `u1` archived under both keys, `u2` only under its `#` key, `u3` only plain, a ChatGPT message
    /// under both, and a repeat with other text under its `~<hash>` key.
    func history() -> [LedgerEvent] {
        [added(message("u1", "Fix the parser"), id: "s-1/u1#u1", at: t0),
         added(message("u2", "Done."), id: "s-1/u2#u2", at: t0),
         added(message("u1", "Fix the parser"), at: t0 + 600),
         added(message("u3", "Thanks"), at: t0 + 600),
         added(message("c1", "Hi", chat: "c", source: .chatgpt), id: "c/c1#c1", at: t0),
         added(message("c1", "Hi", chat: "c", source: .chatgpt), at: t0 + 600),
         added(message("u3", "Thanks!"), id: "s-1/u3#u3~abc", at: t0 + 600)]
    }

    func testOnlyClaudeCodeDuplicatesOfAPlainKeyArePaired() {
        let index = ArchiveIndex.fold(history())
        XCTAssertEqual(Dedupe.pairs(in: index), [Dedupe.Pair(duplicate: ItemKey(source: .claudecode, id: "s-1/u1#u1"), twin: ItemKey(source: .claudecode, id: "s-1/u1"), textDiffers: false)])
    }

    func testPairWithOtherTextIsFlagged() {
        let index = ArchiveIndex.fold([added(message("u1", "Fix the parser"), id: "s-1/u1#u1", at: t0), added(message("u1", "Fix the parser, please"), at: t0 + 600)])
        XCTAssertEqual(Dedupe.pairs(in: index).map(\.textDiffers), [true])
    }

    func testRetiringAppendsRekeyedEventsAndKeepsTheTwin() throws {
        let root = try temporaryDirectory()
        let ledger = Ledger(root: root, host: "mac1")
        try ledger.append(history())
        let file = ledger.directory.appendingPathComponent("claudecode/\(JSONLines.month(t0)).mac1.jsonl")
        let before = try Data(contentsOf: file)

        let index = try ArchiveIndex.load(ledger, cacheRoot: nil)
        let retired = try Dedupe.retire(Dedupe.pairs(in: index), ledger: ledger, index: index, now: t0 + 1200, cacheRoot: nil)

        let after = try Data(contentsOf: file)
        XCTAssertEqual(after.prefix(before.count), before, "earlier ledger lines are left as they were")
        let appended = try JSONLines.decoder.decode(LedgerEvent.self, from: after.dropFirst(before.count).dropLast())
        XCTAssertEqual(appended.type, .rekeyed)
        XCTAssertEqual(appended.key.id, "s-1/u1#u1")
        XCTAssertEqual(appended.newKey?.id, "s-1/u1")
        XCTAssertEqual(appended.reason, Dedupe.reason)

        let ids = Set(retired.items.keys.filter { $0.source == .claudecode }.map(\.id))
        XCTAssertEqual(ids, ["s-1/u1", "s-1/u2#u2", "s-1/u3", "s-1/u3#u3~abc"], "a # item without a plain twin stays")
        XCTAssertEqual(retired.items[ItemKey(source: .claudecode, id: "s-1/u1")]?.firstSeen, t0, "the twin keeps the earlier first sighting")
        XCTAssertEqual(try ArchiveIndex.load(ledger, cacheRoot: nil), retired, "a refold from disk agrees")
        XCTAssertEqual(Dedupe.pairs(in: retired), [], "a second run finds nothing")
        let report = try Verifier.verify(root: root, cacheRoot: nil)
        XCTAssertEqual(report.problems, [])
        XCTAssertFalse(report.notes.contains { $0.contains("dedupe") }, "a dedupe run needs no run log line")
    }

    func testViewerHistoryMovesOntoTheTwin() throws {
        let index = ArchiveIndex.fold(history())
        let events = history() + Dedupe.events(Dedupe.pairs(in: index), at: t0 + 1200, host: "mac1")
        let twin = ViewerData.history(events)[ItemKey(source: .claudecode, id: "s-1/u1")]
        XCTAssertEqual(twin?.map(\.type), [.added, .added, .rekeyed])
        XCTAssertNil(ViewerData.history(events)[ItemKey(source: .claudecode, id: "s-1/u1#u1")])
    }

    func testLaterReadsKeepThePlainKey() {
        let index = ArchiveIndex.fold(history() + Dedupe.events(Dedupe.pairs(in: ArchiveIndex.fold(history())), at: t0 + 1200, host: "mac1"))
        let items = StableKey.items([message("u1", "Fix the parser")], at: t0 + 1800, archived: { index.items[$0] != nil }) { _ in Partition(date: "2026-09-21", utcOffset: 0) }
        XCTAssertEqual(items.map(\.key.id), ["s-1/u1"])
    }

    func testDedupeCommandIsADryRunUnlessApplied() throws {
        XCTAssertFalse(try Config(arguments: ["dedupe", "--output", "/tmp/a"]).apply)
        XCTAssertTrue(try Config(arguments: ["dedupe", "--output", "/tmp/a", "--apply"]).apply)
        XCTAssertThrowsError(try Config(arguments: ["archive", "--output", "/tmp/a", "--apply"]))
    }
}
