import Foundation
import XCTest
@testable import LifelogCore

/// Guards that the archive readers' extra fields never change `export` Markdown.
final class ExportRegressionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_788_780_000)

    func snapshot() -> ExportSnapshot {
        var snapshot = ExportSnapshot()
        snapshot.notes = [
            NoteRecord(id: "note-1", title: "Plans", account: "iCloud", folder: "Diary/2026",
                       created: now.addingTimeInterval(-86_400), modified: now,
                       bodyHTML: "<h1>Plans</h1><ul><li>One</li><li>Two</li></ul>"),
            NoteRecord(id: "note-2", title: "Plans", account: "iCloud", folder: "Diary",
                       created: nil, modified: nil, bodyHTML: "<p>Same name, other folder</p>")
        ]
        snapshot.reminders = [
            ReminderRecord(id: "r-1", title: "Call", list: "Home", notes: "about trip", isCompleted: false,
                           completionDate: nil, due: "2026-09-08", priority: 1, url: nil),
            ReminderRecord(id: "r-2", title: "Pay", list: "Home", notes: nil, isCompleted: true,
                           completionDate: now.addingTimeInterval(-3_600), due: nil, priority: 0, url: "https://example.com")
        ]
        snapshot.events = [
            CalendarRecord(id: "e-1", title: "Standup", calendar: "Work", start: now.addingTimeInterval(-7_200),
                           end: now.addingTimeInterval(-5_400), isAllDay: false, timeZone: "Europe/Stockholm",
                           location: "Room 1", notes: "notes", url: nil),
            CalendarRecord(id: "e-2#2026-09-09", title: "Holiday", calendar: "Home", start: now.addingTimeInterval(86_400),
                           end: now.addingTimeInterval(2 * 86_400), isAllDay: true, timeZone: "Europe/Stockholm",
                           location: nil, notes: nil, url: nil, startDate: "2026-09-09", endDate: "2026-09-10")
        ]
        snapshot.chats = [
            WhatsAppChatRecord(id: "1", title: "Alex", kind: "direct", jid: "1@s.whatsapp.net", messages: [
                WhatsAppMessageRecord(id: "10", sender: "Alex", timestamp: now.addingTimeInterval(-600), fromMe: false, text: "Hi", placeholder: nil),
                WhatsAppMessageRecord(id: "11", sender: "Me", timestamp: now.addingTimeInterval(-500), fromMe: true, text: nil, placeholder: "Image")
            ])
        ]
        return snapshot
    }

    func render(_ snapshot: ExportSnapshot) throws -> String {
        let config = try Config(arguments: ["export", "--output", "/tmp/unused"])
        let documents = try MarkdownWriter.documents(snapshot: snapshot, config: config, now: now)
        return documents.map { "\($0.group) \($0.path)\n\($0.content)" }.joined(separator: "\n\u{0}\n")
    }

    /// Digest of the output before the archive fields existed.
    let golden = "190f4626067e37921a02a4268c8eb603c674e9d4d6bf02e27eacb12963641097"

    func testExportMarkdownMatchesGolden() throws {
        let rendered = try render(snapshot())
        XCTAssertEqual(MarkdownWriter.digest(Data(rendered.utf8)), golden, rendered)
    }

    func testArchiveFieldsAndLockedStubsDoNotChangeExport() throws {
        var snapshot = snapshot()
        snapshot.notes[0].isLocked = false
        snapshot.notes[0].folderID = "f-1"
        snapshot.notes.append(NoteRecord(id: "note-3", title: "Locked", account: "iCloud", folder: "Diary",
                                         created: now, modified: now, bodyHTML: "", isLocked: true, folderID: "f-2"))
        snapshot.reminders[0].externalID = "ext-r"
        snapshot.reminders[0].created = now
        snapshot.reminders[0].modified = now
        snapshot.events[0].externalID = "ext-e"
        snapshot.events[0].status = "cancelled"
        snapshot.events[0].participation = "declined"
        snapshot.events[0].created = now
        snapshot.events[0].modified = now
        snapshot.chats[0].isRemoved = true
        snapshot.chats[0].isHidden = false
        snapshot.chats[0].messages[0].stanzaID = "3EB0"
        snapshot.chats[0].messages[0].rawType = 0
        snapshot.chats[0].messages[0].isRevoked = false
        snapshot.chats[0].messages[0].isSystem = false
        snapshot.chats[0].messages[0].sentDate = now
        let rendered = try render(snapshot)
        XCTAssertEqual(MarkdownWriter.digest(Data(rendered.utf8)), golden, rendered)
    }
}
