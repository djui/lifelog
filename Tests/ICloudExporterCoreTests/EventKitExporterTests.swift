import Foundation
import XCTest
@testable import ICloudExporterCore

final class EventKitExporterTests: XCTestCase {
    func testDateOnlyReminderPreservesCivilDate() throws {
        var due = DateComponents(year: 2026, month: 9, day: 7)
        due.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        XCTAssertEqual(try EventKitDates.reminderDue(due), "2026-09-07")
        XCTAssertNil(try EventKitDates.reminderDue(nil))
    }

    func testFloatingReminderDoesNotInventTimeZone() throws {
        let due = DateComponents(year: 2026, month: 9, day: 7, hour: 10, minute: 45)
        XCTAssertEqual(try EventKitDates.reminderDue(due), "2026-09-07T10:45:00")
    }

    func testTimedReminderUsesOffsetForItsDate() throws {
        var due = DateComponents(year: 2026, month: 7, day: 7, hour: 10, minute: 45)
        due.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        XCTAssertEqual(try EventKitDates.reminderDue(due), "2026-07-07T10:45:00+02:00")
        due.month = 1
        XCTAssertEqual(try EventKitDates.reminderDue(due), "2026-01-07T10:45:00+01:00")
    }

    func testReminderRejectsInvalidCivilDatesAndDSTGap() throws {
        XCTAssertThrowsError(try EventKitDates.reminderDue(DateComponents(year: 2026, month: 2, day: 30)))
        XCTAssertThrowsError(try EventKitDates.reminderDue(DateComponents(month: 9, day: 7)))
        XCTAssertEqual(try EventKitDates.reminderDue(DateComponents(year: 2024, month: 2, day: 29)), "2024-02-29")
        var gap = DateComponents(year: 2026, month: 3, day: 29, hour: 2, minute: 30)
        gap.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        XCTAssertThrowsError(try EventKitDates.reminderDue(gap))
    }

    func testAllDayDatesRemainLocalAcrossUTCAndDSTBoundaries() {
        let start = ISO8601DateFormatter().date(from: "2026-03-28T23:00:00Z")!
        let end = ISO8601DateFormatter().date(from: "2026-03-29T22:00:00Z")!
        let zone = TimeZone(identifier: "Europe/Stockholm")!
        XCTAssertEqual(EventKitDates.civilDate(start, in: zone), "2026-03-29")
        XCTAssertEqual(EventKitDates.civilDate(end, in: zone), "2026-03-30")
        XCTAssertEqual(end.timeIntervalSince(start), 23 * 3_600)
    }

    func testRecurringOccurrencesHaveDistinctStableIdentifiers() {
        let date = ISO8601DateFormatter().date(from: "2026-09-06T22:00:00Z")!
        let zone = TimeZone(identifier: "Europe/Stockholm")!
        XCTAssertEqual(EventKitDates.occurrenceIdentifier(itemID: "series", occurrence: date, allDayTimeZone: zone), "series#2026-09-07")
        XCTAssertEqual(EventKitDates.occurrenceIdentifier(itemID: "series", occurrence: date, allDayTimeZone: nil), "series#2026-09-06T22:00:00Z")
        XCTAssertEqual(EventKitDates.occurrenceIdentifier(itemID: "single", occurrence: nil, allDayTimeZone: nil), "single")
    }

    func testCalendarRangeRejectsTruncationAndInvalidDates() throws {
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertNoThrow(try EventKitDates.validateEventRange(from: start, to: start.addingTimeInterval(1_460 * 86_400)))
        XCTAssertThrowsError(try EventKitDates.validateEventRange(from: start, to: start.addingTimeInterval(1_460 * 86_400 + 1)))
        XCTAssertThrowsError(try EventKitDates.validateEventRange(from: start, to: start))
        XCTAssertThrowsError(try EventKitDates.validateEventRange(from: start, to: start.addingTimeInterval(-1)))
        XCTAssertThrowsError(try EventKitDates.validateEventRange(from: start, to: Date(timeIntervalSince1970: .infinity)))
    }

    func testEventChunksCoverLongWindowsWithoutGaps() throws {
        let start = Date(timeIntervalSince1970: 946_684_800)
        let end = start.addingTimeInterval(10 * 365 * 86_400)
        let chunks = try EventKitDates.eventChunks(from: start, to: end)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks.first?.from, start)
        XCTAssertEqual(chunks.last?.to, end)
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(previous.to, next.from)
        }
        for chunk in chunks {
            XCTAssertNoThrow(try EventKitDates.validateEventRange(from: chunk.from, to: chunk.to))
        }
    }

    func testEventChunksKeepShortWindowsWhole() throws {
        let start = Date(timeIntervalSince1970: 0)
        let exact = start.addingTimeInterval(1_460 * 86_400)
        XCTAssertEqual(try EventKitDates.eventChunks(from: start, to: exact).count, 1)
        XCTAssertEqual(try EventKitDates.eventChunks(from: start, to: exact.addingTimeInterval(1)).count, 2)
        XCTAssertThrowsError(try EventKitDates.eventChunks(from: start, to: start))
        XCTAssertThrowsError(try EventKitDates.eventChunks(from: start, to: Date(timeIntervalSince1970: .infinity)))
    }

    func testMergedDropsEventsRepeatedAcrossChunks() {
        func event(_ id: String, _ title: String) -> CalendarRecord {
            CalendarRecord(id: id, title: title, calendar: "Work", start: Date(timeIntervalSince1970: 0),
                           end: Date(timeIntervalSince1970: 60), isAllDay: false, timeZone: nil, location: nil, notes: nil, url: nil)
        }
        let merged = EventKitDates.merged([[event("a", "first"), event("span", "first")], [event("span", "second"), event("b", "second")]])
        XCTAssertEqual(merged.map(\.id), ["a", "span", "b"])
        XCTAssertEqual(merged.first { $0.id == "span" }?.title, "first")
    }

    func testStatusAndParticipationLabels() {
        XCTAssertEqual(EventKitLabels.status(.canceled), "cancelled")
        XCTAssertEqual(EventKitLabels.status(.tentative), "tentative")
        XCTAssertEqual(EventKitLabels.participation(.declined), "declined")
        XCTAssertEqual(EventKitLabels.participation(.inProcess), "in-process")
    }

    @MainActor
    func testCallbackAcceptsOnlyFirstResult() async throws {
        let value = try await EventKitCallback<Int>.wait(timeoutNanoseconds: 1_000_000_000) { complete in
            complete(.success(42))
            complete(.success(100))
            return { XCTFail("Successful fetch must not be cancelled") }
        }
        XCTAssertEqual(value, 42)
    }

    @MainActor
    func testMissingCallbackTimesOutAndCancelsRequest() async {
        var cancelled = false
        do {
            let _: Int = try await EventKitCallback<Int>.wait(timeoutNanoseconds: 1_000_000) { _ in
                { cancelled = true }
            }
            XCTFail("A missing callback must fail")
        } catch {
            XCTAssertTrue(cancelled)
        }
    }

    @MainActor
    func testCancelledFetchResumesWithoutEventKitCallback() async {
        let started = expectation(description: "fetch started")
        var cancelled = false
        let task = Task {
            try await EventKitCallback<Int>.wait(timeoutNanoseconds: 1_000_000_000) { _ in
                started.fulfill()
                return { cancelled = true }
            }
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must fail")
        } catch {
            XCTAssertTrue(error is CancellationError)
            XCTAssertTrue(cancelled)
        }
    }
}
