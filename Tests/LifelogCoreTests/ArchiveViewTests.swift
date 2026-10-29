import Foundation
import XCTest
@testable import LifelogCore

/// Golden-file tests for the archive pages. Everything is synthetic: three archive runs around the end of DST in
/// Berlin, the last one captured while travelling in New York. Set `UPDATE_GOLDEN=1` to rewrite the golden files.
@MainActor
final class ArchiveViewTests: XCTestCase {
    static let berlin = TimeZone(identifier: "Europe/Berlin")!
    static let newYork = TimeZone(identifier: "America/New_York")!
    let since = at("2026-01-01T00:00:00Z")
    let options = ArchiveOptions(backfillSince: at("2026-01-01T00:00:00Z"), rescanDays: 100, fullSweepDays: 7)
    /// Runs: before and after the clocks go back in Berlin, then in New York.
    let runs: [(at: Date, zone: TimeZone)] = [(at("2026-10-24T18:00:00Z"), berlin), (at("2026-10-25T18:00:00Z"), berlin), (at("2026-10-26T18:00:00Z"), newYork)]

    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func archiver(_ root: URL, zone: TimeZone) throws -> Archiver {
        let ledger = Ledger(root: root, host: "mac1")
        return Archiver(ledger: ledger, runLog: RunLog(root: root, host: "mac1"), index: try ArchiveIndex.load(ledger, cacheRoot: nil),
                        options: options, cacheRoot: nil, timeZone: zone)
    }

    // MARK: Fixture

    func message(_ id: String, chat: String = "anna@s.whatsapp.net", title: String = "Anna", _ time: String, _ sender: String, _ text: String?,
                 placeholder: String? = nil, revoked: Bool = false, system: Bool = false) -> ArchivePayload {
        .message(WhatsAppArchiveMessage(chatJID: chat, chatTitle: title, chatKind: "direct", message: WhatsAppMessageRecord(
            id: "pk\(id)", sender: sender, timestamp: at(time), fromMe: sender == "Me", text: revoked ? nil : text, placeholder: placeholder,
            stanzaID: "S\(id)", rawType: revoked ? 14 : 0, isRevoked: revoked, isSystem: system)))
    }

    func messages(_ run: Int) -> [ArchivePayload] {
        let anna = run == 2 ? "Anna B." : "Anna"
        var list = [
            message("1", title: anna, "2026-10-23T19:14:00Z", "Anna", "see you at 8"),
            message("4", title: anna, "2026-10-23T20:00:00Z", "Anna", "wrong chat, sorry", revoked: run > 0),
            message("5", title: anna, "2026-10-23T20:05:00Z", "Me", run == 0 ? "Dinner at 7?" : "Dinner at 8?"),
            message("6", title: anna, "2026-10-23T20:06:00Z", "Anna", "Messages are end-to-end encrypted.", system: true),
            message("7", title: anna, "2026-10-23T20:10:00Z", "Anna", "the view", placeholder: "Image"),
            message("b1", chat: "ben@s.whatsapp.net", title: "Ben", "2026-09-30T21:30:00Z", "Ben", "Last day of September"),
            message("b2", chat: "ben@s.whatsapp.net", title: "Ben", "2026-10-02T07:00:00Z", "Me", "Morning!"),
        ]
        if run == 0 {
            // A 24 h timer: both vanish at about a day old. The third one has no timer that fits.
            list += [message("2", "2026-10-24T17:30:00Z", "Anna", "the door code is 1234"), message("3", "2026-10-24T17:45:00Z", "Anna", "delete this later"),
                     message("9", "2026-10-20T10:00:00Z", "Me", "an old note to self")]
        }
        // First seen while travelling: 22:30 on the 25th in New York, 03:30 on the 26th in Berlin.
        if run == 2 { list.append(message("8", title: anna, "2026-10-26T02:30:00Z", "Me", "Landed in New York")) }
        return list
    }

    func events(_ run: Int) -> [ArchivePayload] {
        func event(_ id: String, _ title: String, _ start: String, _ end: String, zone: String = "Europe/Berlin", status: String? = nil, participation: String? = nil,
                   location: String? = nil, notes: String? = nil) -> CalendarRecord {
            CalendarRecord(id: "local-\(id)", title: title, calendar: "Work", start: at(start), end: at(end), isAllDay: false, timeZone: zone, location: location, notes: notes, url: nil,
                           externalID: "ext-\(id)", status: status, participation: participation)
        }
        var list = [
            event("standup", "Standup", run == 2 ? "2026-10-27T09:00:00Z" : "2026-10-27T08:30:00Z", run == 2 ? "2026-10-27T09:15:00Z" : "2026-10-27T08:45:00Z"),
            event("party", "Team party", "2026-10-29T17:00:00Z", "2026-10-29T21:00:00Z", status: "cancelled"),
            event("review", "Design review", "2026-10-28T13:00:00Z", "2026-10-28T14:00:00Z", participation: run == 0 ? "accepted" : "declined", location: "Room 4"),
            event("flight", "Flight to Tokyo", "2026-10-30T15:00:00Z", "2026-10-30T22:00:00Z", zone: "Asia/Tokyo", notes: "Seat 42A\nGate B12"),
            event("night", "Night shift", "2026-10-21T20:00:00Z", "2026-10-22T04:00:00Z"),
            CalendarRecord(id: "local-offsite", title: "Offsite", calendar: "Work", start: at("2026-10-28T23:00:00Z"), end: at("2026-10-30T23:00:00Z"), isAllDay: true,
                           timeZone: nil, location: nil, notes: nil, url: nil, startDate: "2026-10-29", endDate: "2026-10-31", externalID: "ext-offsite"),
        ]
        if run == 0 { list.append(event("dentist", "Dentist", "2026-10-28T09:00:00Z", "2026-10-28T10:00:00Z")) }
        return list.map(ArchivePayload.event)
    }

    func reminders(_ run: Int) -> [ArchivePayload] {
        func reminder(_ id: String, _ title: String, list: String = "Home", done: String? = nil, due: String? = nil, priority: Int = 0, notes: String? = nil) -> ArchivePayload {
            .reminder(ReminderRecord(id: "local-\(id)", title: title, list: list, notes: notes, isCompleted: done != nil, completionDate: done.map(at), due: due, priority: priority,
                                     url: nil, externalID: "ext-\(id)", created: at("2026-10-22T08:00:00Z")))
        }
        var list = [reminder("milk", "Buy milk", due: "2026-10-27", priority: 1, notes: "Oat milk"), reminder("passport", "Renew passport", list: "Admin"),
                    reminder("taxes", "File taxes", list: "Admin", done: run > 0 ? "2026-10-25T09:15:00Z" : nil),
                    reminder("bike", "Fix bike", done: "2026-09-29T07:00:00Z")]
        if run == 0 { list.append(reminder("plumber", "Call plumber")) }
        return list
    }

    func notes(_ run: Int) -> [ArchivePayload] {
        func note(_ id: String, _ title: String, folder: String = "Notes", folderID: String = "f-notes", body: String, modified: String = "2026-10-22T10:00:00Z",
                  locked: Bool = false) -> ArchivePayload {
            .note(NoteRecord(id: "x-coredata://note/\(id)", title: title, account: "iCloud", folder: folder, created: at("2026-10-20T09:00:00Z"), modified: at(modified),
                             bodyHTML: body, isLocked: locked, folderID: folderID))
        }
        var list = [
            // Two top-level folders share the name "Diary" (schema notes); the folder id tells them apart.
            note("1", "Day one", folder: "Diary", folderID: "f-diary-1", body: "<p>Rain all day.</p>"),
            note("2", "Day one", folder: "Diary", folderID: "f-diary-2", body: "<p>Sunny.</p>", modified: "2026-10-20T09:00:00Z"),
            note("3", "Recipes", body: run == 0 ? "<ul><li>Pancakes</li></ul>" : "<ul><li>Pancakes</li><li>Soup</li></ul>",
                 modified: run == 0 ? "2026-10-22T10:00:00Z" : "2026-10-25T08:00:00Z"),
            note("5", "Bank", body: run == 0 ? "<p>Account notes</p>" : "", locked: run > 0),
        ]
        if run == 0 { list.append(note("4", "Old plans", body: "<p>Move to Lisbon?</p>")) }
        return list
    }

    func ai(_ run: Int, source: ArchiveSource) -> [ArchiveRead] {
        switch (source, run) {
        case (.chatgpt, 0):
            let messages = [AIChatMessage(id: "g1", role: "user", timestamp: at("2026-10-24T07:00:00Z"), text: "Ideas for a weekend in Porto?"),
                            AIChatMessage(id: "g2", role: "assistant", timestamp: at("2026-10-24T07:00:20Z"), text: "- Ribeira walk\n- Port cellars", model: "gpt-x")]
            let payloads = messages.map { ArchivePayload.aiMessage(AIArchiveMessage(source: .chatgpt, chatID: "c-porto", chatTitle: "Weekend in Porto", message: $0)) }
            return [ArchiveRead(payloads: payloads, scope: Scope(), digest: "zip-1")]
        case (.claudecode, 0), (.claudecode, 2):
            var messages = [AIChatMessage(id: "u1", role: "user", timestamp: at("2026-10-24T09:00:00Z"), text: "Add a rebuild command")]
            if run == 2 { messages.append(AIChatMessage(id: "a1", role: "assistant", timestamp: at("2026-10-26T15:00:00Z"), text: "[tool call: Bash, 120 bytes]")) }
            let payloads = messages.map { ArchivePayload.aiMessage(AIArchiveMessage(source: .claudecode, chatID: "s-1", chatTitle: "Rebuild", project: "lifelog", message: $0)) }
            return [ArchiveRead(payloads: payloads, scope: Scope())]
        default:
            return []
        }
    }

    func readers(_ run: Int) -> [ArchiveReader] {
        let chats: Set<String> = ["anna@s.whatsapp.net", "ben@s.whatsapp.net"]
        return [
            FakeReader(.reminders) { _ in [ArchiveRead(payloads: self.reminders(run), scope: .reminders(completedSince: nil))] },
            FakeReader(.calendar) { _ in [ArchiveRead(payloads: self.events(run), scope: .calendar(from: self.since, to: at("2027-12-31T00:00:00Z")))] },
            FakeReader(.whatsapp) { _ in [ArchiveRead(payloads: self.messages(run), scope: .whatsapp(since: self.since, chats: chats))] },
            FakeReader(.notes) { _ in [ArchiveRead(payloads: self.notes(run), scope: .notes)] },
            FakeReader(.chatgpt, fixedMode: .import) { _ in self.ai(run, source: .chatgpt) },
            FakeReader(.claudecode, fixedMode: .incremental) { _ in self.ai(run, source: .claudecode) },
        ]
    }

    /// Runs the first `count` archive runs into `root` and returns the last summary.
    @discardableResult
    func archive(_ root: URL, runs count: Int = 3, from first: Int = 0) async throws -> ArchiveSummary {
        var summary = ArchiveSummary()
        for run in first..<count {
            summary = try await archiver(root, zone: runs[run].zone).run(readers(run), now: runs[run].at)
            XCTAssertNil(summary.pageError)
            XCTAssertTrue(summary.failures.isEmpty, "\(summary.failures)")
        }
        return summary
    }

    /// Every page under `root` except the ledger, by path.
    func pages(_ root: URL) throws -> [String: String] {
        var pages: [String: String] = [:]
        let base = root.resolvingSymlinksInPath().path
        for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)! where url.pathExtension == "md" {
            let path = String(url.resolvingSymlinksInPath().path.dropFirst(base.count + 1))
            guard !path.hasPrefix(".") else { continue }
            pages[path] = try String(contentsOf: url, encoding: .utf8)
        }
        return pages
    }

    // MARK: Golden files

    func testPagesMatchGoldenFiles() async throws {
        let root = try temporaryDirectory()
        try await archive(root)
        let pages = try pages(root)
        let golden = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Golden")
        let views: [(name: String, prefixes: [String])] = [
            ("whatsapp", ["WhatsApp/"]), ("calendar", ["Calendar/"]), ("reminders", ["Reminders/"]), ("notes", ["Notes/"]),
            ("ai-chats", ["ChatGPT/", "Claude/", "ClaudeCode/"]), ("timeline", ["Timeline/"]), ("disappeared", ["_Disappeared/"]), ("index", ["_index.md"]),
        ]
        var covered = 0
        for view in views {
            let shown = pages.keys.filter { path in view.prefixes.contains { path.hasPrefix($0) } }.sorted()
            covered += shown.count
            XCTAssertFalse(shown.isEmpty, view.name)
            let actual = shown.map { "<!-- \($0) -->\n\(pages[$0]!)" }.joined(separator: "\n")
            let file = golden.appendingPathComponent("\(view.name).md")
            if ProcessInfo.processInfo.environment["UPDATE_GOLDEN"] == "1" {
                try FileManager.default.createDirectory(at: golden, withIntermediateDirectories: true)
                try Data(actual.utf8).write(to: file)
                continue
            }
            let expected = try String(contentsOf: file, encoding: .utf8)
            XCTAssertEqual(actual, expected, "\(view.name) differs from Golden/\(view.name).md; run with UPDATE_GOLDEN=1 and review the diff")
        }
        XCTAssertEqual(covered, pages.count, "every page belongs to a golden file")
    }

    // MARK: Rebuild and incremental runs

    func testRebuildMatchesIncrementalRuns() async throws {
        let root = try temporaryDirectory()
        try await archive(root)
        let incremental = try pages(root)
        // Plus the viewer under `_viewer/` (ViewerDataTests).
        let files = incremental.count + FileManager.default.enumerator(atPath: root.appendingPathComponent(ViewerData.folder).path)!
            .compactMap { $0 as? String }.filter { $0.contains(".") }.count

        // A second folder with only the ledger and run log, as if every page had been deleted. The rebuilding Mac is in
        // yet another zone: lifecycle times come from the zones in the run log, so only "Updated" could differ.
        let copy = try temporaryDirectory()
        try FileManager.default.copyItem(at: root.appendingPathComponent(Ledger.folderName), to: copy.appendingPathComponent(Ledger.folderName))
        try FileManager.default.removeItem(at: copy.appendingPathComponent(ExportStore.pagesManifestName))
        let ledger = Ledger(root: copy, host: "rebuild")
        let summary = try Archiver.rebuild(ledger, runLog: RunLog(root: copy, host: "rebuild"), index: try ArchiveIndex.load(ledger, cacheRoot: nil),
                                           now: runs[2].at, timeZone: Self.newYork)
        XCTAssertEqual(summary.written, files)
        XCTAssertEqual(try pages(copy), incremental)

        // Rebuilding in place rewrites nothing.
        let inPlace = Ledger(root: root, host: "rebuild")
        let again = try Archiver.rebuild(inPlace, runLog: RunLog(root: root, host: "rebuild"), index: try ArchiveIndex.load(inPlace, cacheRoot: nil),
                                         now: runs[2].at, timeZone: Self.newYork)
        XCTAssertEqual([again.written, again.removed, again.unchanged], [0, 0, files])
    }

    /// The CI smoke test: `rebuild` right after `archive --demo` writes nothing. Real clocks have sub-millisecond parts
    /// the ledger does not keep, so clocks around midnight UTC and odd fractions are tried in several zones.
    func testRebuildAfterDemoWritesNothing() async throws {
        let clocks = ["2026-10-26T22:42:31.123456Z", "2026-10-26T23:59:59.9996Z", "2026-10-27T00:00:00.0004Z", "2026-10-25T00:30:00.5Z", "2026-03-29T01:00:00.25Z"]
        for zone in ["UTC", "Europe/Berlin", "America/Los_Angeles"].map({ TimeZone(identifier: $0)! }) {
            for clock in clocks {
                let fraction = Double(clock.split(separator: ".")[1].dropLast()).map { $0 / pow(10, Double(clock.split(separator: ".")[1].count - 1)) } ?? 0
                let now = at(String(clock.split(separator: ".")[0]) + "Z") + fraction
                let root = try temporaryDirectory()
                let ledger = Ledger(root: root, host: Demo.archiveHost), runLog = RunLog(root: root, host: Demo.archiveHost)
                let archiver = Archiver(ledger: ledger, runLog: runLog, index: ArchiveIndex(), options: options, cacheRoot: nil, timeZone: zone)
                for run in Demo.archiveRuns(now: now) {
                    let summary = try await archiver.run(run.readers, now: run.at, demo: true)
                    XCTAssertNil(summary.pageError)
                }
                let incremental = try pages(root)
                // Later, as CI runs it, and on a Mac in another zone.
                let rebuilt = try Archiver.rebuild(ledger, runLog: runLog, index: try ArchiveIndex.load(ledger, cacheRoot: nil), now: now + 90, timeZone: Self.newYork)
                XCTAssertEqual(rebuilt.written, 0, "\(zone.identifier) \(clock)")
                XCTAssertEqual(rebuilt.removed, 0, "\(zone.identifier) \(clock)")
                let again = try pages(root)
                for (path, page) in incremental where again[path] != page { XCTFail("\(zone.identifier) \(clock): \(path) rewritten by rebuild: \(firstDifference(page, again[path]))") }

                // And every page matches a rebuild from the ledger alone.
                let copy = try temporaryDirectory()
                try FileManager.default.copyItem(at: root.appendingPathComponent(Ledger.folderName), to: copy.appendingPathComponent(Ledger.folderName))
                try FileManager.default.removeItem(at: copy.appendingPathComponent(ExportStore.pagesManifestName))
                let fresh = Ledger(root: copy, host: "rebuild")
                _ = try Archiver.rebuild(fresh, runLog: RunLog(root: copy, host: "rebuild"), index: try ArchiveIndex.load(fresh, cacheRoot: nil), now: now + 3600, timeZone: Self.berlin)
                let other = try pages(copy)
                XCTAssertEqual(Set(other.keys), Set(incremental.keys), "\(zone.identifier) \(clock)")
                for (path, page) in incremental where other[path] != page { XCTFail("\(zone.identifier) \(clock): \(path) differs after rebuild: \(firstDifference(page, other[path]))") }
            }
        }
    }

    func testRunRendersOnlyTouchedPagesAndRemovesStaleOnes() async throws {
        let root = try temporaryDirectory()
        try await archive(root, runs: 2)
        let total = try pages(root).count
        XCTAssertTrue(try pages(root).keys.contains { $0.hasPrefix("WhatsApp/anna--") })

        // Run 3 renames Anna's chat, so her folder moves and the old one is removed.
        let summary = try await archive(root, runs: 3, from: 2)
        let after = try pages(root)
        XCTAssertGreaterThan(summary.pages.removed, 0)
        XCTAssertFalse(after.keys.contains { $0.hasPrefix("WhatsApp/anna--") })
        XCTAssertTrue(after.keys.contains { $0.hasPrefix("WhatsApp/anna b--") })
        XCTAssertFalse(after.values.contains { $0.contains("anna--") }, "no page links to the old folder")
        XCTAssertLessThan(summary.pages.written + summary.pages.unchanged, after.count, "untouched pages are not rendered")

        // A run with nothing new renders only `_index.md`, plus the viewer's static app and manifest.
        let quiet = try await archiver(root, zone: Self.newYork).run([], now: runs[2].at + 600)
        XCTAssertEqual(quiet.pages.written + quiet.pages.unchanged, 1 + ViewerData.assets.count + 1)
        XCTAssertGreaterThan(total, 1)
    }

    func testEditedPageStopsPagesButNotTheLedger() async throws {
        let root = try temporaryDirectory()
        try await archive(root, runs: 1)
        let page = root.appendingPathComponent("Reminders/open.md")
        try Data("my edit\n".utf8).write(to: page)
        let summary = try await archiver(root, zone: Self.berlin).run(readers(1), now: runs[1].at)
        XCTAssertEqual(summary.pageError, "Export file was edited outside the exporter: Reminders/open.md. Move it aside before retrying.")
        XCTAssertGreaterThan(summary.changed, 0, "the merge was still appended")
        XCTAssertEqual(try String(contentsOf: page, encoding: .utf8), "my edit\n")
    }

    func testPhase4IndexPageIsAdopted() async throws {
        let root = try temporaryDirectory()
        try Data("# Archive\n\nUpdated earlier.\n".utf8).write(to: root.appendingPathComponent("_index.md"))
        let summary = try await archiver(root, zone: Self.berlin).run(readers(0), now: runs[0].at)
        XCTAssertNil(summary.pageError)
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("_index.md"), encoding: .utf8).contains("## Health"))

        let other = try temporaryDirectory()
        try Data("my own index\n".utf8).write(to: other.appendingPathComponent("_index.md"))
        let refused = try await archiver(other, zone: Self.berlin).run(readers(0), now: runs[0].at)
        XCTAssertEqual(refused.pageError, "Refusing to overwrite an unmanaged file: _index.md")
    }

    func testHealthWarningsAreShownInTheIndex() async throws {
        let root = try temporaryDirectory()
        try await archive(root, runs: 1)
        // Three days later only Notes is read: the WhatsApp capture gap shows in the index, as `archive` wires it.
        let later = runs[0].at + 3 * 86_400
        let archiver = try archiver(root, zone: Self.berlin)
        archiver.health = { records, now in Health.report(records, now: now, whatsAppRunning: nil, timeZone: Self.berlin).warnings }
        _ = try await archiver.run([FakeReader(.notes) { _ in [ArchiveRead(payloads: self.notes(0), scope: .notes)] }], now: later)
        let index = try String(contentsOf: root.appendingPathComponent("_index.md"), encoding: .utf8)
        XCTAssertTrue(index.contains("## Health\n\n- No complete WhatsApp read for 71 h. Disappearing messages (24 h) sent between 2026-10-24 20:00 and 2026-10-26 19:00 may be lost.\n"), index)

        // `rebuild` takes the same warnings from the run log.
        let ledger = Ledger(root: root, host: "rebuild"), runLog = RunLog(root: root, host: "rebuild")
        let warnings = Health.warnings(runLog: runLog, now: later + 3600, whatsAppRunning: nil, timeZone: Self.berlin)
        XCTAssertFalse(warnings.isEmpty)
        _ = try Archiver.rebuild(ledger, runLog: runLog, index: try ArchiveIndex.load(ledger, cacheRoot: nil), now: later + 3600, timeZone: Self.berlin, health: warnings)
        let rebuilt = try String(contentsOf: root.appendingPathComponent("_index.md"), encoding: .utf8)
        XCTAssertTrue(rebuilt.contains("sent between 2026-10-24 20:00 and 2026-10-26 20:00 may be lost."), rebuilt)
    }

    func testArchivePagesAndExportStayApart() throws {
        let store = ExportStore(output: try temporaryDirectory())
        XCTAssertTrue(store.allows("notes", path: "Notes/a.md"))
        XCTAssertFalse(store.allows("timeline", path: "Timeline/2026/2026-10.md"), "export does not own archive-only groups")
        XCTAssertFalse(store.allows("chatgpt", path: "ChatGPT/a.md"))
        let pages = ExportStore(output: try temporaryDirectory(), layout: .archive)
        XCTAssertTrue(pages.allows("timeline", path: "Timeline/2026/2026-10.md"))
        XCTAssertTrue(pages.allows("disappeared", path: "_Disappeared/2026/2026-10.md"))
        XCTAssertTrue(pages.allows("claudecode", path: "ClaudeCode/2026/2026-10/x.md"))
        XCTAssertFalse(pages.allows("timeline", path: "Calendar/2026/2026-10.md"))
        XCTAssertFalse(pages.allows("index", path: "Timeline/_index.md"))
    }

    // MARK: Partition

    func testPartitionAcrossDSTAndTravel() {
        let berlin = Self.berlin, newYork = Self.newYork
        // Autumn: 00:30 local is still summer time on the 25th, and winter time a day later.
        XCTAssertEqual(Partition(at("2026-10-24T22:30:00Z"), timeZone: berlin), Partition(date: "2026-10-25", utcOffset: 7200))
        XCTAssertEqual(Partition(at("2026-10-25T23:30:00Z"), timeZone: berlin), Partition(date: "2026-10-26", utcOffset: 3600))
        // Spring: the hour from 02:00 to 03:00 does not exist.
        XCTAssertEqual(Partition(at("2026-03-28T23:30:00Z"), timeZone: berlin), Partition(date: "2026-03-29", utcOffset: 3600))
        XCTAssertEqual(Partition(at("2026-03-29T22:30:00Z"), timeZone: berlin), Partition(date: "2026-03-30", utcOffset: 7200))
        // Travel: the same instant is the 25th in New York and the 26th in Berlin.
        let landed = at("2026-10-26T02:30:00Z")
        XCTAssertEqual(Partition(landed, timeZone: newYork), Partition(date: "2026-10-25", utcOffset: -14400))
        XCTAssertEqual(Partition(landed, timeZone: berlin), Partition(date: "2026-10-26", utcOffset: 3600))
        XCTAssertEqual(Partition(landed, timeZone: newYork).clock(landed), "22:30")

        // Calendar items use their own zone (or their civil date when all-day), not the Mac's.
        let flight = CalendarRecord(id: "f", title: "Flight", calendar: "Work", start: at("2026-10-30T15:00:00Z"), end: at("2026-10-30T22:00:00Z"), isAllDay: false,
                                    timeZone: "Asia/Tokyo", location: nil, notes: nil, url: nil)
        XCTAssertEqual(Partition.of(.event(flight), fallback: landed, timeZone: berlin), Partition(date: "2026-10-31", utcOffset: 32400))
        var holiday = flight
        holiday.isAllDay = true; holiday.startDate = "2026-10-29"; holiday.endDate = "2026-10-30"
        XCTAssertEqual(Partition.of(.event(holiday), fallback: landed, timeZone: newYork).date, "2026-10-29")

        // The arithmetic holds before 1970, on leap days and with half-hour offsets.
        XCTAssertEqual(Partition.day(Date(timeIntervalSince1970: -1), utcOffset: 0), "1969-12-31")
        XCTAssertEqual(Partition.clock(Date(timeIntervalSince1970: -1), utcOffset: 0), "23:59")
        XCTAssertEqual(Partition.day(at("2028-02-29T12:00:00Z"), utcOffset: 0), "2028-02-29")
        XCTAssertEqual(Partition.iso(at("2026-10-25T20:40:00Z"), utcOffset: 3600), "2026-10-25T21:40:00+01:00")
        XCTAssertEqual(Partition.iso(at("2026-10-25T20:40:00Z"), utcOffset: -16200), "2026-10-25T16:10:00-04:30")
        XCTAssertEqual(Partition(date: "2026-10-25", utcOffset: 0).month, "2026-10")
    }

    func testRunLogRecordsTheCaptureZone() async throws {
        let root = try temporaryDirectory()
        try await archive(root)
        let records = try RunLog(root: root, host: "mac1").read().records
        XCTAssertEqual(Set(records.filter { $0.start < runs[2].at }.map(\.timeZone)), ["Europe/Berlin"])
        XCTAssertEqual(Set(records.filter { $0.start == runs[2].at }.map(\.timeZone)), ["America/New_York"])
    }

    func testLinksAreRelative() {
        XCTAssertEqual(ArchivePages.link("WhatsApp/a--1/2026/2026-10.md", from: "WhatsApp/a--1/_chat.md"), "2026/2026-10.md")
        XCTAssertEqual(ArchivePages.link("Calendar/2026/2026-10.md", from: "Timeline/2026/2026-10.md", anchor: "2026-10-28"), "../../Calendar/2026/2026-10.md#2026-10-28")
        XCTAssertEqual(ArchivePages.link("Notes/i cloud/a (1).md", from: "_index.md"), "Notes/i%20cloud/a%20%281%29.md")
    }
}

/// The first line that differs, for readable failures.
private func firstDifference(_ a: String, _ b: String?) -> String {
    let left = a.components(separatedBy: "\n"), right = (b ?? "").components(separatedBy: "\n")
    for index in 0..<max(left.count, right.count) where (index < left.count ? left[index] : nil) != (index < right.count ? right[index] : nil) {
        return "line \(index + 1): \(index < left.count ? left[index] : "<none>") ≠ \(index < right.count ? right[index] : "<none>")"
    }
    return "same"
}

private func at(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
