import XCTest
@testable import LifelogCore

final class MergerTests: XCTestCase {
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    static let hour: TimeInterval = 3600, day: TimeInterval = 86_400
    static let chat = "491701234567@s.whatsapp.net"

    // MARK: Records

    static func note(_ id: String, _ body: String = "hello", locked: Bool = false, folder: String = "Notes") -> ArchivePayload {
        .note(NoteRecord(id: id, title: "Title \(id)", account: "iCloud", folder: folder, created: t0, modified: t0, bodyHTML: locked ? "" : "<p>\(body)</p>",
                         isLocked: locked, folderID: "folder-\(folder)"))
    }

    static func reminder(_ id: String, _ title: String = "Buy milk", completed: Date? = nil) -> ArchivePayload {
        .reminder(ReminderRecord(id: "local-\(id)", title: title, list: "Home", notes: nil, isCompleted: completed != nil, completionDate: completed,
                                 due: nil, priority: 0, url: nil, externalID: id))
    }

    static func event(_ id: String, _ title: String = "Dentist", start: Date = t0 + 2 * day, status: String = "confirmed", calendar: String = "Home") -> ArchivePayload {
        .event(CalendarRecord(id: "cal-\(id)", title: title, calendar: calendar, start: start, end: start + hour, isAllDay: false, timeZone: "Europe/Berlin",
                              location: nil, notes: nil, url: nil, externalID: id, status: status))
    }

    static func message(_ stanza: String, _ text: String = "see you at 8", at: Date = t0, chat: String = chat, revoked: Bool = false, fromMe: Bool = false, pk: String? = nil) -> ArchivePayload {
        let record = WhatsAppMessageRecord(id: pk ?? "pk-\(stanza)", sender: fromMe ? "Me" : "Anna", timestamp: at, fromMe: fromMe, text: revoked ? nil : text, placeholder: nil,
                                           stanzaID: stanza, rawType: revoked ? 14 : 0, isRevoked: revoked)
        return .message(WhatsAppArchiveMessage(chatJID: chat, chatTitle: "Anna", chatKind: "direct", message: record))
    }

    static func items(_ payloads: [ArchivePayload], at: Date = t0) -> [ArchivedItem] {
        StableKey.items(payloads, at: at) { _ in Partition(date: "2026-09-21", utcOffset: 7200) }
    }

    // MARK: Runs

    struct Step {
        var at: TimeInterval
        var payloads: [ArchivePayload]
        var complete = true
        var scope = Scope()
        /// Compact events: `added <id>`, `stateChanged <id> <state>`, `rekeyed <id> → <id>`, …
        var expect: [String]
        var warnings = 0
    }

    struct Case { var name: String; var source: ArchiveSource; var steps: [Step] }

    static func describe(_ event: LedgerEvent) -> String {
        var text = "\(event.type.rawValue) \(event.key.id)"
        if let state = event.state { text += " \(state.rawValue)" }
        if let newKey = event.newKey { text += " → \(newKey.id)" }
        return text
    }

    static func added(_ payloads: [ArchivePayload]) -> [String] { payloads.map { "added \(StableKey.id(of: $0))" } }
    static func each(_ type: String, _ payloads: ArraySlice<ArchivePayload>, _ suffix: String = "") -> [String] {
        payloads.map { "\(type) \(StableKey.id(of: $0))\(suffix)" }.sorted()
    }

    /// Merges each step into an index folded from the previous steps' events, as `archive` will.
    @discardableResult
    func run(_ test: Case, file: StaticString = #filePath, line: UInt = #line) -> (ArchiveIndex, [MergeResult]) {
        var index = ArchiveIndex()
        var results: [MergeResult] = []
        for (number, step) in test.steps.enumerated() {
            let at = Self.t0 + step.at
            let observation = Observation(source: test.source, runID: "r\(number)", at: at, complete: step.complete, scope: step.scope, items: Self.items(step.payloads, at: at))
            let result = Merger.merge(index, observation)
            XCTAssertEqual(result.events.map(Self.describe), step.expect, "\(test.name), step \(number)", file: file, line: line)
            XCTAssertEqual(result.warnings.count, step.warnings, "\(test.name), step \(number) warnings: \(result.warnings)", file: file, line: line)
            for event in result.events { index.apply(event) }
            XCTAssertEqual(index.issues, [], "\(test.name), step \(number)", file: file, line: line)
            results.append(result)
        }
        return (index, results)
    }

    func item(_ index: ArchiveIndex, _ source: ArchiveSource, _ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> ArchivedItem {
        try XCTUnwrap(index.items[ItemKey(source: source, id: id)], "no \(source.rawValue)/\(id)", file: file, line: line)
    }

    static let wa1 = "\(chat)/0/s1", wa2 = "\(chat)/0/s2"
    static let dentist = "e1@2026-09-23T14:13:20.000Z", moved = "e1@2026-09-24T14:13:20.000Z"

    // MARK: One case per rule

    func testRules() throws {
        let many = (1...20).map { Self.note("n\($0)") }
        let window = Scope.calendar(from: Self.t0 + 10 * Self.day, to: Self.t0 + 400 * Self.day, liveFrom: Self.t0 + 10 * Self.day)
        let cases: [Case] = [
            Case(name: "1 new key is added", source: .notes, steps: [
                Step(at: 0, payloads: [Self.note("n1")], expect: ["added n1"]),
                Step(at: 600, payloads: [Self.note("n1")], expect: []),
            ]),
            Case(name: "2 same key, new text is changed", source: .notes, steps: [
                Step(at: 0, payloads: [Self.note("n1")], expect: ["added n1"]),
                Step(at: 600, payloads: [Self.note("n1", "hello again")], expect: ["changed n1"]),
            ]),
            Case(name: "2 whitespace and line endings are not a change", source: .notes, steps: [
                Step(at: 0, payloads: [Self.note("n1", "a\r\nb")], expect: ["added n1"]),
                Step(at: 600, payloads: [Self.note("n1", "a  \nb")], expect: []),
            ]),
            Case(name: "2 revoked message is a state change", source: .whatsapp, steps: [
                Step(at: 0, payloads: [Self.message("s1")], expect: ["added \(Self.wa1)"]),
                Step(at: 600, payloads: [Self.message("s1", revoked: true)], expect: ["changed \(Self.wa1)", "stateChanged \(Self.wa1) revoked"]),
                Step(at: 1200, payloads: [Self.message("s1", revoked: true)], expect: []),
            ]),
            Case(name: "4 deleted after two consecutive complete misses", source: .notes, steps: [
                Step(at: 0, payloads: [Self.note("n1"), Self.note("n2")], expect: ["added n1", "added n2"]),
                Step(at: 600, payloads: [Self.note("n2")], expect: ["missingPending n1"]),
                Step(at: 1200, payloads: [Self.note("n2")], expect: ["stateChanged n1 deleted"]),
                Step(at: 1800, payloads: [Self.note("n2")], expect: []),
            ]),
            Case(name: "4 a sighting between two misses resets the count", source: .notes, steps: [
                Step(at: 0, payloads: [Self.note("n1")], expect: ["added n1"]),
                Step(at: 600, payloads: [], expect: ["missingPending n1"]),
                Step(at: 1200, payloads: [Self.note("n1")], expect: ["missingCleared n1"]),
                Step(at: 1800, payloads: [], expect: ["missingPending n1"]),
            ]),
            Case(name: "4 out-of-scope items never go missing", source: .whatsapp, steps: [
                Step(at: 0, payloads: [Self.message("s1"), Self.message("s2", chat: "other@g.us")], expect: ["added \(Self.wa1)", "added other@g.us/0/s2"]),
                Step(at: 600, payloads: [], scope: .whatsapp(since: Self.t0 + 1, chats: [Self.chat]), expect: []),
                Step(at: 1200, payloads: [Self.message("s1")], scope: .whatsapp(since: nil, chats: [Self.chat]), expect: []),
            ]),
            Case(name: "5 breaker holds a mass disappearance as pending, then unknown, never deleted", source: .notes, steps: [
                Step(at: 0, payloads: many, expect: Self.added(many)),
                Step(at: 600, payloads: Array(many.prefix(5)), expect: Self.each("missingPending", many.dropFirst(5)), warnings: 1),
                Step(at: 1200, payloads: Array(many.prefix(5)), expect: Self.each("stateChanged", many.dropFirst(5), " unknown"), warnings: 1),
                Step(at: 1800, payloads: Array(many.prefix(5)), expect: []),
            ]),
            Case(name: "5 a held item becomes unknown even if the next run looks normal", source: .notes, steps: [
                Step(at: 0, payloads: many, expect: Self.added(many)),
                Step(at: 600, payloads: Array(many.prefix(5)), expect: Self.each("missingPending", many.dropFirst(5)), warnings: 1),
                Step(at: 1200, payloads: Array(many.prefix(5) + many.dropFirst(6)), expect: Self.added([]) + many.dropFirst(6).map { "missingCleared \(StableKey.id(of: $0))" } + ["stateChanged n6 unknown"]),
            ]),
            Case(name: "5 below the minimum the breaker stays off", source: .notes, steps: [
                Step(at: 0, payloads: Array(many.prefix(4)), expect: Self.added(Array(many.prefix(4)))),
                Step(at: 600, payloads: [many[0]], expect: ["missingPending n2", "missingPending n3", "missingPending n4"]),
                Step(at: 1200, payloads: [many[0]], expect: ["stateChanged n2 deleted", "stateChanged n3 deleted", "stateChanged n4 deleted"]),
            ]),
            Case(name: "6 an incomplete read only adds and changes", source: .notes, steps: [
                Step(at: 0, payloads: [Self.note("n1"), Self.note("n2")], expect: ["added n1", "added n2"]),
                Step(at: 600, payloads: [Self.note("n2", "edited"), Self.note("n3")], complete: false, expect: ["changed n2", "added n3"]),
                Step(at: 1200, payloads: [Self.note("n2", "edited"), Self.note("n3")], complete: false, expect: []),
            ]),
            Case(name: "7 new key with the same container and text is re-linked", source: .reminders, steps: [
                Step(at: 0, payloads: [Self.reminder("x1")], expect: ["added x1"]),
                Step(at: 600, payloads: [Self.reminder("x2")], expect: ["rekeyed x1 → x2"]),
                Step(at: 1200, payloads: [Self.reminder("x2")], expect: []),
            ]),
            Case(name: "7 different text is a new item, not a re-link", source: .reminders, steps: [
                Step(at: 0, payloads: [Self.reminder("x1")], expect: ["added x1"]),
                Step(at: 600, payloads: [Self.reminder("x2", "Buy bread")], expect: ["added x2", "missingPending x1"]),
            ]),
            Case(name: "7 an incomplete read never re-links", source: .reminders, steps: [
                Step(at: 0, payloads: [Self.reminder("x1")], expect: ["added x1"]),
                Step(at: 600, payloads: [Self.reminder("x2")], complete: false, expect: ["added x2"]),
            ]),
            Case(name: "7 a rescheduled event is re-linked", source: .calendar, steps: [
                Step(at: 0, payloads: [Self.event("e1")], expect: ["added \(Self.dentist)"]),
                Step(at: 600, payloads: [Self.event("e1", start: Self.t0 + 3 * Self.day)], expect: ["rekeyed \(Self.dentist) → \(Self.moved)", "changed \(Self.moved)"]),
            ]),
            Case(name: "8 a tombstoned key seen again reappears", source: .notes, steps: [
                Step(at: 0, payloads: [Self.note("n1")], expect: ["added n1"]),
                Step(at: 600, payloads: [], expect: ["missingPending n1"]),
                Step(at: 1200, payloads: [], expect: ["stateChanged n1 deleted"]),
                Step(at: 1800, payloads: [Self.note("n1")], expect: ["stateChanged n1 active"]),
            ]),
            Case(name: "9 reminder completion is a state, and so is reopening", source: .reminders, steps: [
                Step(at: 0, payloads: [Self.reminder("x1")], expect: ["added x1"]),
                Step(at: 600, payloads: [Self.reminder("x1", completed: Self.t0 + 500)], expect: ["changed x1", "stateChanged x1 completed"]),
                Step(at: 1200, payloads: [Self.reminder("x1")], expect: ["changed x1", "stateChanged x1 active"]),
            ]),
            Case(name: "out-of-window items are archived, and come back when read again", source: .calendar, steps: [
                Step(at: 0, payloads: [Self.event("e1")], expect: ["added \(Self.dentist)"]),
                Step(at: 600, payloads: [], scope: window, expect: ["stateChanged \(Self.dentist) archived"]),
                Step(at: 1200, payloads: [], scope: window, expect: []),
                Step(at: 1800, payloads: [Self.event("e1")], scope: .calendar(from: Self.t0, to: Self.t0 + 400 * Self.day), expect: ["stateChanged \(Self.dentist) active"]),
            ]),
            Case(name: "a locked note is a state, not a deletion", source: .notes, steps: [
                Step(at: 0, payloads: [Self.note("n1", "secret plans")], expect: ["added n1"]),
                Step(at: 600, payloads: [Self.note("n1", locked: true)], expect: ["changed n1", "stateChanged n1 locked"]),
                Step(at: 1200, payloads: [Self.note("n1", locked: true)], expect: []),
                Step(at: 1800, payloads: [Self.note("n1", "secret plans")], expect: ["changed n1", "stateChanged n1 active"]),
            ]),
        ]
        for test in cases { run(test) }
    }

    // MARK: Details the table can't show

    func testChangedKeepsFlagsAndCalendarHistory() throws {
        let (index, _) = run(Case(name: "calendar", source: .calendar, steps: [
            Step(at: 0, payloads: [Self.event("e1")], expect: ["added \(Self.dentist)"]),
            Step(at: 600, payloads: [Self.event("e1", "Dentist (moved)", status: "tentative")], expect: ["changed \(Self.dentist)"]),
        ]))
        let event = try item(index, .calendar, Self.dentist)
        XCTAssertEqual(event.flags, ItemFlags(edited: true, statusFrom: "confirmed"))
        XCTAssertEqual(event.firstSeen, Self.t0)
        XCTAssertEqual(event.lastSeen, Self.t0 + 600)
    }

    func testRescheduleViaRelinkRecordsOldStart() throws {
        let (index, _) = run(Case(name: "reschedule", source: .calendar, steps: [
            Step(at: 0, payloads: [Self.event("e1")], expect: ["added \(Self.dentist)"]),
            Step(at: 600, payloads: [Self.event("e1", start: Self.t0 + 3 * Self.day)], expect: ["rekeyed \(Self.dentist) → \(Self.moved)", "changed \(Self.moved)"]),
        ]))
        let event = try item(index, .calendar, Self.moved)
        XCTAssertEqual(event.flags.rescheduledFrom, "2026-09-23T14:13:20.000Z")
        XCTAssertFalse(event.flags.edited)
        XCTAssertEqual(event.firstSeen, Self.t0)
        XCTAssertNil(index.items[ItemKey(source: .calendar, id: Self.dentist)])
    }

    func testRevokedMessageKeepsLastSeenText() throws {
        let (index, results) = run(Case(name: "revoke", source: .whatsapp, steps: [
            Step(at: 0, payloads: [Self.message("s1", "meet at the old bridge")], expect: ["added \(Self.wa1)"]),
            Step(at: 600, payloads: [Self.message("s1", revoked: true)], expect: ["changed \(Self.wa1)", "stateChanged \(Self.wa1) revoked"]),
        ]))
        let message = try item(index, .whatsapp, Self.wa1)
        XCTAssertEqual(message.state, .revoked)
        XCTAssertEqual(message.reason, "deleted by the sender")
        guard case .message(let value) = message.payload else { return XCTFail("not a message") }
        XCTAssertEqual(value.message.text, "meet at the old bridge")
        XCTAssertEqual(value.message.isRevoked, true)
        XCTAssertFalse(message.flags.edited)
        XCTAssertEqual(results[1].counts, ["changed": 1, "stateChanged.revoked": 1])
    }

    func testLockedNoteKeepsBody() throws {
        let (index, _) = run(Case(name: "lock", source: .notes, steps: [
            Step(at: 0, payloads: [Self.note("n1", "secret plans")], expect: ["added n1"]),
            Step(at: 600, payloads: [Self.note("n1", locked: true)], expect: ["changed n1", "stateChanged n1 locked"]),
        ]))
        let note = try item(index, .notes, "n1")
        guard case .note(let record) = note.payload else { return XCTFail("not a note") }
        XCTAssertEqual(record.bodyHTML, "<p>secret plans</p>")
        XCTAssertEqual(note.state, .locked)
        XCTAssertFalse(note.flags.edited)
    }

    func testFirstSightingStates() throws {
        let (reminders, _) = run(Case(name: "completed", source: .reminders, steps: [
            Step(at: 0, payloads: [Self.reminder("x1", completed: Self.t0 - Self.day)], expect: ["added x1"]),
        ]))
        XCTAssertEqual(try item(reminders, .reminders, "x1").state, .completed)
        let (notes, _) = run(Case(name: "locked", source: .notes, steps: [Step(at: 0, payloads: [Self.note("n1", locked: true)], expect: ["added n1"])]))
        XCTAssertEqual(try item(notes, .notes, "n1").state, .locked)
    }

    func testExpiredIsInferredFromAgeAndSimilarVanishings() throws {
        // Two messages from one chat vanish ~24 h after they were sent: a timer, inferred.
        let first = Self.day + 300
        let keep = Self.message("s3", "keep", at: Self.t0 + 120)
        let (index, _) = run(Case(name: "expire", source: .whatsapp, steps: [
            Step(at: 0, payloads: [Self.message("s1", at: Self.t0), Self.message("s2", at: Self.t0 + 60), keep],
                 expect: ["added \(Self.wa1)", "added \(Self.wa2)", "added \(Self.chat)/0/s3"]),
            Step(at: first, payloads: [keep], expect: ["missingPending \(Self.wa1)", "missingPending \(Self.wa2)"]),
            Step(at: first + 600, payloads: [keep], expect: ["stateChanged \(Self.wa1) expired", "stateChanged \(Self.wa2) expired"]),
        ]))
        let message = try item(index, .whatsapp, Self.wa1)
        XCTAssertEqual(message.reason, "disappearing message timer (24h, inferred)")
        guard case .message(let value) = message.payload else { return XCTFail("not a message") }
        XCTAssertEqual(value.message.text, "see you at 8", "expired messages keep their text (decision 2)")
    }

    func testOneMatchingAgeAloneIsDeletedButJoinsAnEarlierTimer() throws {
        let other = "other@g.us"
        let keep = Self.message("s3", at: Self.t0 + 120, chat: other)
        let (index, _) = run(Case(name: "lone", source: .whatsapp, steps: [
            Step(at: 0, payloads: [Self.message("s1", at: Self.t0), Self.message("s2", at: Self.t0 + 60, chat: other), keep],
                 expect: ["added \(Self.wa1)", "added \(other)/0/s2", "added \(other)/0/s3"]),
            Step(at: 7 * Self.day, payloads: [keep], expect: ["missingPending \(Self.wa1)", "missingPending \(other)/0/s2"]),
            Step(at: 7 * Self.day + 600, payloads: [keep], expect: ["stateChanged \(Self.wa1) deleted", "stateChanged \(other)/0/s2 deleted"]),
        ]))
        XCTAssertEqual(try item(index, .whatsapp, Self.wa1).reason, "missing in two complete reads (no disappearing timer matched, inferred)")

        // An earlier expiry with the same timer in the chat makes a single vanishing look like a timer too.
        var seeded = ArchiveIndex()
        let expired = Self.items([Self.message("s9", at: Self.t0 - Self.day)])[0]
        let lone = Self.items([Self.message("s1", at: Self.t0)])[0]
        for event in [
            LedgerEvent(type: .added, at: Self.t0, run: "r0", key: expired.key, item: expired),
            LedgerEvent(type: .stateChanged, at: Self.t0, run: "r0", key: expired.key, state: .expired, reason: "disappearing message timer (24h, inferred)"),
            LedgerEvent(type: .added, at: Self.t0, run: "r0", key: lone.key, item: lone),
            LedgerEvent(type: .missingPending, at: Self.t0 + Self.day, run: "r1", key: lone.key),
        ] { seeded.apply(event) }
        let result = Merger.merge(seeded, Observation(source: .whatsapp, runID: "r2", at: Self.t0 + Self.day + 600, complete: true, scope: Scope(from: Self.t0 - Self.hour), items: []))
        XCTAssertEqual(result.events.map(Self.describe), ["stateChanged \(Self.wa1) expired"])
    }

    func testTimerTolerance() {
        XCTAssertEqual(Merger.timer(age: 86_400 * 1.09), "24h")
        XCTAssertNil(Merger.timer(age: 86_400 * 1.2))
        XCTAssertEqual(Merger.timer(age: 7 * 86_400 * 0.92), "7d")
        XCTAssertEqual(Merger.timer(age: 90 * 86_400 * 1.05), "90d")
        XCTAssertNil(Merger.timer(age: 30 * 86_400))
    }

    func testCancelledEventKeepsReason() throws {
        let (index, _) = run(Case(name: "cancelled", source: .calendar, steps: [
            Step(at: 0, payloads: [Self.event("e1", status: "cancelled")], expect: ["added \(Self.dentist)"]),
            Step(at: 600, payloads: [], expect: ["missingPending \(Self.dentist)"]),
            Step(at: 1200, payloads: [], expect: ["stateChanged \(Self.dentist) deleted"]),
        ]))
        XCTAssertEqual(try item(index, .calendar, Self.dentist).reason, "cancelled, then missing in two complete reads")
    }

    func testBreakerWarnsAndMarksReason() throws {
        let many = (1...20).map { Self.note("n\($0)") }
        let (index, results) = run(Case(name: "breaker", source: .notes, steps: [
            Step(at: 0, payloads: many, expect: Self.added(many)),
            Step(at: 600, payloads: [], expect: Self.each("missingPending", many[...]), warnings: 1),
        ]))
        XCTAssertEqual(results[1].warnings, ["notes: 20 of 20 in-scope items missing at once; held as pending and never deleted automatically"])
        XCTAssertEqual(try item(index, .notes, "n1").missingReason, Merger.massDisappearance)
        XCTAssertEqual(try item(index, .notes, "n1").state, .active)
    }

    func testForeignAndDuplicateItemsAreWarnedAbout() {
        let items = Self.items([Self.note("n1"), Self.reminder("x1")])
        let result = Merger.merge(ArchiveIndex(), Observation(source: .notes, runID: "r1", at: Self.t0, complete: true, scope: .notes, items: items + [items[0]]))
        XCTAssertEqual(result.events.map(Self.describe), ["added n1"])
        XCTAssertEqual(result.warnings.count, 2)
    }

    // MARK: Combinations

    func testRelinkDoesNotTripTheBreaker() throws {
        // Every calendar item id changes at once (a re-sync): all re-linked, nothing pending, no warning.
        let before = (1...12).map { Self.event("old\($0)", "Event \($0)", start: Self.t0 + Double($0) * Self.day) }
        let after = (1...12).map { Self.event("new\($0)", "Event \($0)", start: Self.t0 + Double($0) * Self.day) }
        let (index, _) = run(Case(name: "relink + breaker", source: .calendar, steps: [
            Step(at: 0, payloads: before, expect: Self.added(before)),
            Step(at: 600, payloads: after, expect: zip(before, after).map { "rekeyed \(StableKey.id(of: $0)) → \(StableKey.id(of: $1))" }),
        ]))
        XCTAssertEqual(index.items.count, 12)
        XCTAssertTrue(index.items.values.allSatisfy { $0.state == .active && $0.missingSince == nil && $0.key.id.hasPrefix("new") })
    }

    func testRelinkInsideAMassDisappearance() throws {
        // One re-keyed item among a mass disappearance is re-linked; the breaker still holds the rest.
        let many = (1...20).map { Self.reminder("x\($0)", "Task \($0)") }
        let rekeyed = Self.reminder("y1", "Task 1")
        let (index, _) = run(Case(name: "relink inside a mass disappearance", source: .reminders, steps: [
            Step(at: 0, payloads: many, expect: Self.added(many)),
            Step(at: 600, payloads: [rekeyed] + many[11...], expect: ["rekeyed x1 → y1"] + Self.each("missingPending", many[1...10]), warnings: 1),
            Step(at: 1200, payloads: [rekeyed], expect: (Self.each("stateChanged", many[1...10], " unknown") + Self.each("missingPending", many[11...])).sorted {
                $0.split(separator: " ")[1] < $1.split(separator: " ")[1]
            }, warnings: 1),
        ]))
        XCTAssertEqual(try item(index, .reminders, "y1").state, .active)
        XCTAssertEqual(try item(index, .reminders, "x2").state, .unknown)
        XCTAssertEqual(try item(index, .reminders, "x12").missingReason, Merger.massDisappearance)
    }

    func testRevokeThenExpire() throws {
        let (index, _) = run(Case(name: "revoke then expire", source: .whatsapp, steps: [
            Step(at: 0, payloads: [Self.message("s1", "first", at: Self.t0), Self.message("s2", "second", at: Self.t0 + 30)],
                 expect: ["added \(Self.wa1)", "added \(Self.wa2)"]),
            Step(at: 600, payloads: [Self.message("s1", at: Self.t0, revoked: true), Self.message("s2", "second", at: Self.t0 + 30)],
                 expect: ["changed \(Self.wa1)", "stateChanged \(Self.wa1) revoked"]),
            Step(at: Self.day, payloads: [], expect: ["missingPending \(Self.wa1)", "missingPending \(Self.wa2)"]),
            Step(at: Self.day + 600, payloads: [], expect: ["stateChanged \(Self.wa1) expired", "stateChanged \(Self.wa2) expired"]),
        ]))
        let message = try item(index, .whatsapp, Self.wa1)
        guard case .message(let value) = message.payload else { return XCTFail("not a message") }
        XCTAssertEqual(value.message.text, "first", "a revoked, then expired message still has its last text")
    }

    func testResurrectionAfterFullSweep() throws {
        // Deleted by two rescans, untouched while out of scope, then a full sweep finds it again.
        let old = Self.message("s1", "from last year", at: Self.t0 - 200 * Self.day)
        let rescan = Scope.whatsapp(since: Self.t0 - 300 * Self.day, chats: nil)
        let narrow = Scope.whatsapp(since: Self.t0 - 100 * Self.day, chats: nil)
        let (index, _) = run(Case(name: "resurrection", source: .whatsapp, steps: [
            Step(at: 0, payloads: [old], scope: rescan, expect: ["added \(Self.wa1)"]),
            Step(at: 600, payloads: [], scope: rescan, expect: ["missingPending \(Self.wa1)"]),
            Step(at: 1200, payloads: [], scope: rescan, expect: ["stateChanged \(Self.wa1) deleted"]),
            Step(at: 1800, payloads: [], scope: narrow, expect: []),
            Step(at: 2400, payloads: [old], scope: .whatsapp(since: nil, chats: nil), expect: ["stateChanged \(Self.wa1) active"]),
        ]))
        let message = try item(index, .whatsapp, Self.wa1)
        XCTAssertEqual(message.reason, "reappeared")
        XCTAssertEqual(message.stateSince, Self.t0 + 2400)
    }

    func testMergeIsPure() {
        let items = Self.items([Self.note("n1"), Self.note("n2")])
        var index = ArchiveIndex()
        for event in Merger.merge(index, Observation(source: .notes, runID: "r1", at: Self.t0, complete: true, scope: .notes, items: items)).events { index.apply(event) }
        let snapshot = index
        let observation = Observation(source: .notes, runID: "r2", at: Self.t0 + 600, complete: true, scope: .notes, items: [items[1]])
        XCTAssertEqual(Merger.merge(index, observation), Merger.merge(index, observation))
        XCTAssertEqual(index, snapshot)
    }

    // MARK: Keys and scope

    func testStableKeys() {
        XCTAssertEqual(StableKey.id(of: Self.note("x-coredata://1/ICNote/p1")), "x-coredata://1/ICNote/p1")
        XCTAssertEqual(StableKey.id(of: Self.reminder("ext-1")), "ext-1")
        XCTAssertEqual(StableKey.id(of: .reminder(ReminderRecord(id: "loc", title: "t", list: "l", notes: nil, isCompleted: false, completionDate: nil, due: nil, priority: 0, url: nil))), "local:loc")
        XCTAssertEqual(StableKey.id(of: Self.event("ext-2")), "ext-2@2026-09-23T14:13:20.000Z")
        let allDay = CalendarRecord(id: "c", title: "Holiday", calendar: "Home", start: Self.t0, end: Self.t0 + Self.day, isAllDay: true, timeZone: nil, location: nil, notes: nil, url: nil,
                                    startDate: "2026-09-21", endDate: "2026-09-22", externalID: "ext-3")
        XCTAssertEqual(StableKey.id(of: .event(allDay)), "ext-3@2026-09-21")
        XCTAssertEqual(StableKey.id(of: Self.message("ABC", fromMe: true)), "\(Self.chat)/1/ABC")
    }

    func testWhatsAppCollisionsGainTheDateThenTheNativeID() {
        let payloads = [Self.message("dup", at: Self.t0, pk: "1"), Self.message("dup", at: Self.t0 + 1, pk: "2"),
                        Self.message("dup", at: Self.t0 + 1, pk: "3"), Self.message("dup", fromMe: true), Self.message("dup", chat: "other@g.us")]
        let ids = Self.items(payloads).map(\.key.id)
        XCTAssertEqual(ids, [
            "\(Self.chat)/0/dup@2026-09-21T14:13:20.000Z",
            "\(Self.chat)/0/dup@2026-09-21T14:13:21.000Z#2",
            "\(Self.chat)/0/dup@2026-09-21T14:13:21.000Z#3",
            "\(Self.chat)/1/dup",
            "other@g.us/0/dup",
        ])
    }

    func testContentHashIgnoresTimesAndNormalizesText() {
        XCTAssertEqual(StableKey.contentHash(of: Self.event("e1")), StableKey.contentHash(of: Self.event("e2", start: Self.t0, status: "cancelled")))
        XCTAssertNotEqual(StableKey.contentHash(of: Self.event("e1")), StableKey.contentHash(of: Self.event("e1", "Doctor")))
        XCTAssertEqual(StableKey.contentHash(of: Self.message("s1", "Cafe\u{301} \r\nok  ")), StableKey.contentHash(of: Self.message("s1", "Café\nok")))
    }

    func testScope() {
        let calendar = Scope.calendar(from: Self.t0, to: Self.t0 + 10 * Self.day, liveFrom: Self.t0)
        let events = Self.items([Self.event("in", start: Self.t0 + Self.day), Self.event("old", start: Self.t0 - Self.day), Self.event("late", start: Self.t0 + 10 * Self.day)])
        XCTAssertEqual(events.map(calendar.contains), [true, false, false])
        XCTAssertEqual(events.map(calendar.hasLeftLiveWindow), [false, true, false])

        let tasks = Self.items([Self.reminder("open"), Self.reminder("recent", completed: Self.t0 + 1), Self.reminder("old", completed: Self.t0 - 1)])
        XCTAssertEqual(tasks.map(Scope.reminders(completedSince: Self.t0).contains), [true, true, false])
        XCTAssertEqual(tasks.map(Scope.reminders(completedSince: nil).contains), [true, true, true])
        XCTAssertTrue(Scope.notes.contains(Self.items([Self.note("n1")])[0]))
    }
}
