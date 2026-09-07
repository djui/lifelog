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
        return snapshot
    }
}
