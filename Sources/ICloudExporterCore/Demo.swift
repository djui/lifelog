import Foundation

public enum Demo {
    public static func snapshot(now: Date) -> ExportSnapshot {
        var snapshot = ExportSnapshot()
        snapshot.notes = [NoteRecord(id: "demo-note-1", title: "Patagonia ideas", account: "Example account", folder: "Travel", created: now.addingTimeInterval(-86400), modified: now, bodyHTML: "<h2>Planning ideas</h2><ul><li>Compare hiking routes</li><li>Check weather and transport</li></ul><p>These are synthetic examples.</p>")]
        snapshot.reminders = [
            ReminderRecord(id: "demo-reminder-1", title: "Compare trail options", list: "Travel", notes: "Look at distance and elevation.", isCompleted: false, completionDate: nil, due: "2026-10-01", priority: 5, url: nil),
            ReminderRecord(id: "demo-reminder-2", title: "Start a trip checklist", list: "Travel", notes: nil, isCompleted: true, completionDate: now.addingTimeInterval(-3600), due: nil, priority: 0, url: nil)
        ]
        snapshot.events = [
            CalendarRecord(id: "demo-event-1", title: "Trip planning", calendar: "Personal", start: now.addingTimeInterval(3600), end: now.addingTimeInterval(7200), isAllDay: false, timeZone: TimeZone.current.identifier, location: nil, notes: "Compare a few possible routes.", url: nil),
            CalendarRecord(id: "demo-event-2", title: "Planning catch-up", calendar: "Personal", start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-3600), isAllDay: false, timeZone: TimeZone.current.identifier, location: nil, notes: nil, url: nil)
        ]
        snapshot.chats = [
            WhatsAppChatRecord(
                id: "demo-chat-1",
                title: "Alex",
                kind: "direct",
                jid: "15555550100@s.whatsapp.net",
                messages: [
                    WhatsAppMessageRecord(id: "demo-msg-1", sender: "Me", timestamp: now.addingTimeInterval(-3600), fromMe: true, text: "Want to compare a few trail options this week?", placeholder: nil),
                    WhatsAppMessageRecord(id: "demo-msg-2", sender: "Alex", timestamp: now.addingTimeInterval(-1800), fromMe: false, text: "Yes — I will send the map.", placeholder: nil),
                    WhatsAppMessageRecord(id: "demo-msg-3", sender: "Alex", timestamp: now.addingTimeInterval(-600), fromMe: false, text: nil, placeholder: "Image")
                ]
            )
        ]
        return snapshot
    }
}

extension Demo {
    /// Host id of demo ledgers, so a demo never creates the Mac's real host id.
    public static let archiveHost = "demo"

    /// Three synthetic runs: a first sighting a day ago, then two later runs in which items change and vanish.
    /// Two complete misses are needed for a tombstone, so the third run shows deleted and expired items,
    /// next to a revoked message, a rescheduled event, an edited note and a locked note.
    @MainActor
    public static func archiveRuns(now: Date) -> [(at: Date, readers: [ArchiveReader])] {
        let hour: TimeInterval = 3600
        let since = now.addingTimeInterval(-100 * 24 * hour)
        let times = [now.addingTimeInterval(-24.5 * hour), now.addingTimeInterval(-hour), now]
        let jid = "15555550100@s.whatsapp.net"

        func message(_ id: String, _ sender: String, _ age: TimeInterval, _ text: String?, revoked: Bool = false) -> WhatsAppMessageRecord {
            WhatsAppMessageRecord(id: id, sender: sender, timestamp: now.addingTimeInterval(-age), fromMe: sender == "Me", text: revoked ? nil : text, placeholder: nil,
                                  stanzaID: "DEMO\(id)", rawType: revoked ? 14 : 0, isRevoked: revoked)
        }
        func messages(_ run: Int) -> [ArchivePayload] {
            var list = [message("1", "Me", 26 * hour, "Want to compare a few trail options this week?"),
                        message("4", "Alex", 25.6 * hour, "Running late, start without me", revoked: run > 0)]
            // A 24 h disappearing-message timer: both vanish when they are a day old.
            if run == 0 { list += [message("2", "Alex", 25 * hour, "Yes — I will send the map."), message("3", "Alex", 24.9 * hour, "Meet at the trailhead at 8?")] }
            if run > 0 { list.append(message("5", "Me", 1.1 * hour, "Map received, thanks!")) }
            return list.map { .message(WhatsAppArchiveMessage(chatJID: jid, chatTitle: "Alex", chatKind: "direct", message: $0)) }
        }
        func reminders(_ run: Int) -> [ArchivePayload] {
            var list = [ReminderRecord(id: "demo-reminder-1", title: "Compare trail options", list: "Travel", notes: "Look at distance and elevation.", isCompleted: false, completionDate: nil, due: nil, priority: 5, url: nil, externalID: "demo-ext-1"),
                        ReminderRecord(id: "demo-reminder-2", title: "Start a trip checklist", list: "Travel", notes: nil, isCompleted: run > 0, completionDate: run > 0 ? times[1] : nil, due: nil, priority: 0, url: nil, externalID: "demo-ext-2")]
            if run == 0 { list.append(ReminderRecord(id: "demo-reminder-3", title: "Book a hostel", list: "Travel", notes: nil, isCompleted: false, completionDate: nil, due: nil, priority: 0, url: nil, externalID: "demo-ext-3")) }
            return list.map(ArchivePayload.reminder)
        }
        func events(_ run: Int) -> [ArchivePayload] {
            let zone = TimeZone.current.identifier
            let start = now.addingTimeInterval((run == 0 ? 72 : 96) * hour)
            var list = [CalendarRecord(id: "demo-event-1", title: "Trip planning", calendar: "Personal", start: start, end: start + hour, isAllDay: false, timeZone: zone, location: nil, notes: "Compare a few possible routes.", url: nil, externalID: "demo-ext-event-1")]
            if run == 0 { list.append(CalendarRecord(id: "demo-event-2", title: "Dentist", calendar: "Personal", start: now + 48 * hour, end: now + 49 * hour, isAllDay: false, timeZone: zone, location: nil, notes: nil, url: nil, externalID: "demo-ext-event-2")) }
            return list.map(ArchivePayload.event)
        }
        func notes(_ run: Int) -> [ArchivePayload] {
            [NoteRecord(id: "demo-note-1", title: "Patagonia ideas", account: "Example account", folder: "Travel", created: times[0], modified: times[min(run, 1)],
                        bodyHTML: run == 0 ? "<p>Compare hiking routes.</p>" : "<p>Compare hiking routes.</p><p>Check weather and transport.</p>", folderID: "demo-folder"),
             NoteRecord(id: "demo-note-2", title: "Packing list", account: "Example account", folder: "Travel", created: times[0], modified: times[0],
                        bodyHTML: run < 2 ? "<p>Boots, rain jacket.</p>" : "", isLocked: run == 2, folderID: "demo-folder")].map(ArchivePayload.note)
        }
        let claude = [AIChatMessage(id: "demo-ai-1", role: "user", timestamp: times[0], text: "Which month is best for hiking in Patagonia?"),
                      AIChatMessage(id: "demo-ai-2", role: "assistant", timestamp: times[0] + 30, text: "December to February: long days and milder weather.")]
            .map { ArchivePayload.aiMessage(AIArchiveMessage(source: .claude, chatID: "demo-chat", chatTitle: "Patagonia hiking", message: $0)) }

        return times.indices.map { run in
            var readers: [ArchiveReader] = [
                DemoReader(source: .reminders, read: ArchiveRead(payloads: reminders(run), scope: .reminders(completedSince: since))),
                DemoReader(source: .calendar, read: ArchiveRead(payloads: events(run), scope: .calendar(from: since, to: now + 730 * 24 * hour))),
                DemoReader(source: .whatsapp, read: ArchiveRead(payloads: messages(run), scope: .whatsapp(since: since, chats: [jid]))),
                DemoReader(source: .notes, read: ArchiveRead(payloads: notes(run), scope: .notes)),
            ]
            if run == 0 { readers.append(DemoReader(source: .claude, read: ArchiveRead(payloads: claude, scope: Scope(), digest: "demo-export"))) }
            return (times[run], readers)
        }
    }
}

/// Returns one fixed read; used by the demo and the tests.
public struct DemoReader: ArchiveReader {
    public let source: ArchiveSource
    public let fixedMode: ReadMode? = .demo
    let reads: [ArchiveRead]

    public init(source: ArchiveSource, read: ArchiveRead) { self.source = source; reads = [read] }
    public func read(_ request: ArchiveReadRequest) async throws -> [ArchiveRead] { reads }
}
