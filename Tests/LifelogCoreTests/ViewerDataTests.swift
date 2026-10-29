import Foundation
import XCTest
@testable import LifelogCore

/// The HTML viewer's data scripts. Everything is synthetic: the `archive --demo` runs and fake WhatsApp messages.
@MainActor
final class ViewerDataTests: XCTestCase {
    let options = ArchiveOptions(backfillSince: at("2026-01-01T00:00:00Z"), rescanDays: 100, fullSweepDays: 7)
    let berlin = TimeZone(identifier: "Europe/Berlin")!

    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// The demo archive, as `archive --demo` writes it.
    func demo(_ root: URL, now: Date, zone: TimeZone) async throws -> (Ledger, RunLog) {
        let ledger = Ledger(root: root, host: Demo.archiveHost), runLog = RunLog(root: root, host: Demo.archiveHost)
        let archiver = Archiver(ledger: ledger, runLog: runLog, index: ArchiveIndex(), options: options, cacheRoot: nil, timeZone: zone)
        for run in Demo.archiveRuns(now: now) {
            let summary = try await archiver.run(run.readers, now: run.at, demo: true)
            XCTAssertNil(summary.pageError)
        }
        return (ledger, runLog)
    }

    /// Every file under `_viewer/`, by path.
    func viewer(_ root: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        let base = root.appendingPathComponent(ViewerData.folder).resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(at: root.appendingPathComponent(ViewerData.folder), includingPropertiesForKeys: nil) else { return files }
        for case let url as URL in walker where !url.hasDirectoryPath {
            files[String(url.resolvingSymlinksInPath().path.dropFirst(base.count + 1))] = try Data(contentsOf: url)
        }
        return files
    }

    /// The JSON inside a data script.
    func json(_ data: Data) throws -> [String: Any] {
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("window.ARCHIVE.load(") && text.hasSuffix(");\n"), text.prefix(40) + "…")
        let inner = text.dropFirst("window.ARCHIVE.load(".count).dropLast(");\n".count)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(inner.utf8)) as? [String: Any])
    }

    func message(_ id: String, _ time: String, _ text: String) -> ArchivePayload {
        .message(WhatsAppArchiveMessage(chatJID: "anna@s.whatsapp.net", chatTitle: "Anna", chatKind: "direct", message: WhatsAppMessageRecord(
            id: "pk\(id)", sender: "Anna", timestamp: at(time), fromMe: false, text: text, placeholder: nil, stanzaID: "S\(id)", rawType: 0)))
    }

    func run(_ root: URL, _ payloads: [ArchivePayload], now: Date) async throws -> ArchiveSummary {
        let ledger = Ledger(root: root, host: "mac1")
        let archiver = Archiver(ledger: ledger, runLog: RunLog(root: root, host: "mac1"), index: try ArchiveIndex.load(ledger, cacheRoot: nil),
                                options: options, cacheRoot: nil, timeZone: berlin)
        let reader = FakeReader(.whatsapp) { _ in [ArchiveRead(payloads: payloads, scope: .whatsapp(since: at("2026-01-01T00:00:00Z"), chats: ["anna@s.whatsapp.net"]))] }
        let summary = try await archiver.run([reader], now: now)
        XCTAssertNil(summary.pageError)
        return summary
    }

    // MARK: Tests

    func testDemoWritesTheAppAndChunksThatParseAsJSON() async throws {
        let root = try temporaryDirectory()
        _ = try await demo(root, now: at("2026-10-26T22:42:31Z"), zone: berlin)
        let files = try viewer(root)
        for name in ViewerData.assets { XCTAssertFalse(files[name]?.isEmpty ?? true, name) }
        XCTAssertTrue(String(decoding: files["index.html"]!, as: UTF8.self).contains("Content-Security-Policy"))

        let manifest = try json(files["data/manifest.js"]!)
        XCTAssertEqual(manifest["kind"] as? String, "manifest")
        XCTAssertEqual(manifest["demo"] as? Bool, true)
        let gone = try XCTUnwrap(manifest["disappeared"] as? [[String: Any]])
        XCTAssertEqual(Set(gone.compactMap { $0["state"] as? String }), ["deleted", "expired", "revoked"])
        XCTAssertTrue(gone.allSatisfy { ($0["link"] as? String)?.hasPrefix("../") == true })

        let chunks = files.keys.filter { $0.hasPrefix("data/") && $0 != "data/manifest.js" }
        XCTAssertFalse(chunks.isEmpty)
        var history = 0
        for path in chunks {
            let chunk = try json(files[path]!)
            XCTAssertEqual(chunk["kind"] as? String, "chunk")
            XCTAssertEqual("data/\(chunk["source"] as! String)/\(chunk["month"] as! String).js", path)
            for item in try XCTUnwrap(chunk["items"] as? [[String: Any]]) {
                XCTAssertTrue((item["key"] as? String)?.hasPrefix("\(chunk["source"] as! String)/") == true)
                history += (item["history"] as? [Any])?.count ?? 0
            }
        }
        XCTAssertGreaterThan(history, 0, "items carry their ledger history")
        // A revoked demo message shows when it was added and when it was revoked.
        let whatsapp = try XCTUnwrap(chunks.first { $0.hasPrefix("data/whatsapp/") })
        let revoked = try XCTUnwrap((try json(files[whatsapp]!)["items"] as! [[String: Any]]).first { $0["state"] as? String == "revoked" })
        XCTAssertEqual((revoked["history"] as! [[String: Any]]).compactMap { $0["what"] as? String }.filter { $0 != "changed" }, ["added", "revoked"])
    }

    func testScriptEscapesScriptEndsAndLineSeparators() throws {
        struct Value: Encodable { var text: String }
        let text = "</script><script>alert(1)</script> <!-- a\u{2028}b\u{2029}c \"quoted\" \\ end"
        let script = ViewerData.script(Value(text: text))
        XCTAssertFalse(script.contains("</"))
        XCTAssertFalse(script.contains("<!--"))
        XCTAssertFalse(script.contains("\u{2028}") || script.contains("\u{2029}"))
        XCTAssertEqual(try json(Data(script.utf8))["text"] as? String, text)
    }

    func testOnlyChangedMonthsAreRewritten() async throws {
        let root = try temporaryDirectory()
        let september = message("1", "2026-09-10T08:00:00Z", "September"), october = message("2", "2026-10-10T08:00:00Z", "October")
        _ = try await run(root, [september, october], now: at("2026-10-20T18:00:00Z"))
        let old = root.appendingPathComponent(ViewerData.chunkPath(.whatsapp, "2026-09"))
        let past = at("2001-01-01T00:00:00Z")
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: old.path)

        // A new October message: September's chunk is not written.
        let all = [september, october, message("3", "2026-10-20T08:00:00Z", "New")]
        let summary = try await run(root, all, now: at("2026-10-21T18:00:00Z"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: old.path)[.modificationDate] as? Date, past)
        let chunk = try json(Data(contentsOf: root.appendingPathComponent(ViewerData.chunkPath(.whatsapp, "2026-10"))))
        XCTAssertEqual((chunk["items"] as! [[String: Any]]).count, 2)
        XCTAssertGreaterThan(summary.pages.written, 0)

        // Nothing new: only `_index.md`, the static app and the manifest are rendered, no month chunk.
        let quiet = try await run(root, all, now: at("2026-10-22T18:00:00Z"))
        XCTAssertEqual(quiet.pages.written + quiet.pages.unchanged, 1 + ViewerData.assets.count + 1)
    }

    /// `rebuild` right after `archive --demo` writes no viewer file, in place or from the ledger alone, whichever zone
    /// the runs and the rebuild are in. CI also runs the suite under `TZ=UTC`.
    func testRebuildAfterDemoWritesNoViewerFiles() async throws {
        for zone in ["UTC", "Europe/Berlin"].map({ TimeZone(identifier: $0)! }) {
            for clock in ["2026-10-26T22:42:31Z", "2026-10-26T23:59:59Z", "2026-03-29T01:00:00Z"] {
                let now = at(clock) + 0.123456
                let root = try temporaryDirectory()
                let (ledger, runLog) = try await demo(root, now: now, zone: zone)
                let incremental = try viewer(root)
                let rebuilt = try Archiver.rebuild(ledger, runLog: runLog, index: try ArchiveIndex.load(ledger, cacheRoot: nil), now: now + 90,
                                                   timeZone: TimeZone(identifier: "America/New_York")!)
                XCTAssertEqual([rebuilt.written, rebuilt.removed], [0, 0], "\(zone.identifier) \(clock)")
                XCTAssertEqual(try viewer(root), incremental)

                let copy = try temporaryDirectory()
                try FileManager.default.copyItem(at: root.appendingPathComponent(Ledger.folderName), to: copy.appendingPathComponent(Ledger.folderName))
                try FileManager.default.removeItem(at: copy.appendingPathComponent(ExportStore.pagesManifestName))
                let fresh = Ledger(root: copy, host: "rebuild")
                _ = try Archiver.rebuild(fresh, runLog: RunLog(root: copy, host: "rebuild"), index: try ArchiveIndex.load(fresh, cacheRoot: nil), now: now + 3600, timeZone: berlin)
                let other = try viewer(copy)
                XCTAssertEqual(Set(other.keys), Set(incremental.keys), "\(zone.identifier) \(clock)")
                for (path, data) in incremental where other[path] != data { XCTFail("\(zone.identifier) \(clock): \(path) differs after rebuild") }
            }
        }
    }

    func testNoViewerRemovesAnEarlierOne() async throws {
        let root = try temporaryDirectory()
        let (ledger, runLog) = try await demo(root, now: at("2026-10-26T22:42:31Z"), zone: berlin)
        XCTAssertFalse(try viewer(root).isEmpty)
        let summary = try Archiver.rebuild(ledger, runLog: runLog, index: try ArchiveIndex.load(ledger, cacheRoot: nil), now: at("2026-10-27T00:00:00Z"), viewer: false)
        XCTAssertEqual(summary.written, 0)
        XCTAssertGreaterThan(summary.removed, 0)
        XCTAssertTrue(try viewer(root).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("_index.md").path))
    }

    func testViewerPathsAreOnlyAllowedInTheArchive() {
        let archive = ExportStore(output: FileManager.default.temporaryDirectory, layout: .archive)
        XCTAssertTrue(archive.allows("viewer", path: "_viewer/data/whatsapp/2026-10.js"))
        XCTAssertTrue(archive.allows("viewer", path: "_viewer/index.html"))
        XCTAssertFalse(archive.allows("viewer", path: "_viewer/run.sh"))
        XCTAssertFalse(archive.allows("viewer", path: "WhatsApp/x.js"))
        XCTAssertFalse(ExportStore(output: FileManager.default.temporaryDirectory).allows("viewer", path: "_viewer/index.html"))
    }

    func testConfigParsesViewerOptions() throws {
        XCTAssertFalse(try Config(arguments: ["archive", "--output", "/tmp/a", "--no-viewer"]).viewer)
        XCTAssertFalse(try Config(arguments: ["rebuild", "--output", "/tmp/a", "--no-viewer"]).viewer)
        XCTAssertTrue(try Config(arguments: ["archive", "--output", "/tmp/a"]).viewer)
        XCTAssertEqual(try Config(arguments: ["open", "--output", "/tmp/a"]).command, .open)
        XCTAssertThrowsError(try Config(arguments: ["export", "--output", "/tmp/a", "--no-viewer"]))
    }
}

private func at(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
