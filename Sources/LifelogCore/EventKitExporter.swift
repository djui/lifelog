import Foundation
@preconcurrency import EventKit

/// Reads the event store without saving, removing, or modifying its contents.
@MainActor
public final class EventKitExporter {
    private let store = EKEventStore()

    public init() {}

    /// `completedSince == nil` reads every completed reminder (archive backfill and full sweeps).
    public func reminders(completedSince: Date?) async throws -> SourceResult<ReminderRecord> {
        guard completedSince?.timeIntervalSinceReferenceDate.isFinite ?? true else {
            throw ExportError.message("The completed-reminder cutoff must be a valid date.")
        }
        try await requireAccess(to: .reminder)
        let incomplete = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: nil
        )
        let recentlyCompleted = store.predicateForCompletedReminders(
            withCompletionDateStarting: completedSince, ending: nil, calendars: nil
        )
        ExportLog.info("reminders: fetching incomplete")
        let active = try await fetchReminders(matching: incomplete)
        ExportLog.info("reminders: fetching completed since \(completedSince.map { ISO8601DateFormatter().string(from: $0) } ?? "the beginning")")
        let completed = try await fetchReminders(matching: recentlyCompleted)

        // A reminder can change completion state between the two queries.
        var records: [String: ReminderRecord] = [:]
        for reminder in active + completed {
            let record = ReminderRecord(
                id: reminder.calendarItemIdentifier,
                title: reminder.title ?? "",
                list: reminder.calendar?.title ?? "",
                notes: reminder.notes,
                isCompleted: reminder.isCompleted,
                completionDate: reminder.completionDate,
                due: try EventKitDates.reminderDue(reminder.dueDateComponents),
                priority: Int(reminder.priority),
                url: reminder.url?.absoluteString,
                externalID: reminder.calendarItemExternalIdentifier,
                created: reminder.creationDate,
                modified: reminder.lastModifiedDate
            )
            records[record.id] = record
        }
        let result = SourceResult(records: records.values.sorted { $0.id < $1.id })
        ExportLog.info("reminders: read \(result.records.count) reminders")
        return result
    }

    /// Windows longer than EventKit's four-year predicate limit are read in chunks.
    public func events(from: Date, to: Date) async throws -> SourceResult<CalendarRecord> {
        let chunks = try EventKitDates.eventChunks(from: from, to: to)
        try await requireAccess(to: .event)
        let formatter = ISO8601DateFormatter()
        let defaultTimeZone = TimeZone.current
        var batches: [[CalendarRecord]] = []
        for chunk in chunks {
            try Task.checkCancellation()
            ExportLog.info("calendar: fetching events from \(formatter.string(from: chunk.from)) to \(formatter.string(from: chunk.to))")
            let predicate = store.predicateForEvents(withStart: chunk.from, end: chunk.to, calendars: nil)
            let events = store.events(matching: predicate)
            ExportLog.info("calendar: mapping \(events.count) EventKit events")
            batches.append(try events.map { try record(for: $0, defaultTimeZone: defaultTimeZone) })
        }
        try Task.checkCancellation()
        let result = SourceResult(records: EventKitDates.merged(batches).sorted {
            $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start
        })
        ExportLog.info("calendar: read \(result.records.count) events")
        return result
    }

    private func record(for event: EKEvent, defaultTimeZone: TimeZone) throws -> CalendarRecord {
        guard let start = event.startDate, let end = event.endDate,
              start.timeIntervalSinceReferenceDate.isFinite,
              end.timeIntervalSinceReferenceDate.isFinite, end >= start else {
            throw ExportError.message("Calendar returned an event with invalid dates; the export was not replaced.")
        }
        // EventKit returns floating/all-day dates in the system's default zone.
        // Civil dates preserve the actual day even when JSON encodes the instants in UTC.
        let zone = event.isAllDay ? defaultTimeZone : event.timeZone
        let occurrence = event.hasRecurrenceRules || event.isDetached ? (event.occurrenceDate ?? start) : nil
        return CalendarRecord(
            id: EventKitDates.occurrenceIdentifier(
                itemID: event.calendarItemIdentifier,
                occurrence: occurrence,
                allDayTimeZone: event.isAllDay ? defaultTimeZone : nil
            ),
            title: event.title ?? "",
            calendar: event.calendar?.title ?? "",
            start: start,
            end: end,
            isAllDay: event.isAllDay,
            timeZone: zone?.identifier,
            location: event.location,
            notes: event.notes,
            url: event.url?.absoluteString,
            startDate: event.isAllDay ? EventKitDates.civilDate(start, in: defaultTimeZone) : nil,
            endDate: event.isAllDay ? EventKitDates.civilDate(end, in: defaultTimeZone) : nil,
            externalID: event.calendarItemExternalIdentifier,
            status: EventKitLabels.status(event.status),
            participation: event.attendees?.first(where: \.isCurrentUser).map { EventKitLabels.participation($0.participantStatus) },
            created: event.creationDate,
            modified: event.lastModifiedDate
        )
    }

    private func requireAccess(to entity: EKEntityType) async throws {
        try Task.checkCancellation()
        let source = entity == .event ? "Calendars" : "Reminders"
        let label = entity == .event ? "calendar" : "reminders"
        switch EKEventStore.authorizationStatus(for: entity) {
        case .fullAccess:
            ExportLog.info("\(label): access already granted")
            return
        case .restricted:
            throw ExportError.message("\(source) access is restricted by macOS policy. Ask the Mac's administrator to allow Lifelog to access \(source), then run it again.")
        case .denied:
            throw accessDenied(source)
        case .notDetermined, .writeOnly:
            ExportLog.info("\(label): waiting for access prompt")
        @unknown default:
            throw accessDenied(source)
        }
        let granted: Bool
        do {
            if entity == .event {
                granted = try await store.requestFullAccessToEvents()
            } else {
                granted = try await store.requestFullAccessToReminders()
            }
        } catch {
            throw ExportError.message("Could not request \(source) access: \(error.localizedDescription). \(accessInstructions(source))")
        }
        try Task.checkCancellation()
        guard granted else { throw accessDenied(source) }
        ExportLog.info("\(label): access granted")
    }

    private func accessDenied(_ source: String) -> ExportError {
        .message("\(source) full access was denied. \(accessInstructions(source))")
    }

    private func accessInstructions(_ source: String) -> String {
        "Open System Settings → Privacy & Security → \(source), enable full access for Lifelog or the app that launched it (such as Terminal), then run the exporter again."
    }

    private func fetchReminders(matching predicate: NSPredicate) async throws -> [EKReminder] {
        try await EventKitCallback<[EKReminder]>.wait(timeoutNanoseconds: 60_000_000_000) { finish in
            let identifier = self.store.fetchReminders(matching: predicate) { reminders in
                if let reminders {
                    finish(.success(reminders))
                } else {
                    finish(.failure(ExportError.message("Reminders returned no fetch result. Check Reminders access in System Settings → Privacy & Security and run the exporter again.")))
                }
            }
            return { self.store.cancelFetchRequest(identifier) }
        }
    }
}

/// Date mapping is independent of EventKit so it can be checked without permission prompts.
enum EventKitDates {
    static func validateEventRange(from: Date, to: Date) throws {
        // EventKit silently truncates windows longer than four years. A fixed 1,460-day
        // cap is safe across leap years and agrees with the command-line option limits.
        let duration = to.timeIntervalSince(from)
        guard from.timeIntervalSinceReferenceDate.isFinite,
              to.timeIntervalSinceReferenceDate.isFinite,
              duration > 0, duration <= 1_460 * 86_400 else {
            throw ExportError.message("The calendar window must have increasing dates and span no more than 1,460 days (four years).")
        }
    }

    static let maxEventSpan: TimeInterval = 1_460 * 86_400

    /// Splits a window into back-to-back spans EventKit will not truncate.
    static func eventChunks(from: Date, to: Date) throws -> [(from: Date, to: Date)] {
        guard from.timeIntervalSinceReferenceDate.isFinite, to.timeIntervalSinceReferenceDate.isFinite, to > from else {
            throw ExportError.message("The calendar window must have increasing, valid dates.")
        }
        var chunks: [(from: Date, to: Date)] = []
        var start = from
        while start < to {
            let end = min(start.addingTimeInterval(maxEventSpan), to)
            try validateEventRange(from: start, to: end)
            chunks.append((start, end))
            start = end
        }
        return chunks
    }

    /// Events overlapping a chunk boundary come back from both chunks; keep the first copy.
    static func merged(_ batches: [[CalendarRecord]]) -> [CalendarRecord] {
        var seen = Set<String>()
        return batches.joined().filter { seen.insert($0.id).inserted }
    }

    static func civilDate(_ date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    static func occurrenceIdentifier(itemID: String, occurrence: Date?, allDayTimeZone: TimeZone?) -> String {
        guard let occurrence else { return itemID }
        let suffix: String
        if let zone = allDayTimeZone {
            suffix = civilDate(occurrence, in: zone)
        } else {
            suffix = ISO8601DateFormatter().string(from: occurrence)
        }
        return "\(itemID)#\(suffix)"
    }

    static func reminderDue(_ components: DateComponents?) throws -> String? {
        guard let components else { return nil }
        guard let year = components.year, let month = components.month, let day = components.day,
              (1...9_999).contains(year), (1...12).contains(month), (1...31).contains(day) else {
            throw ExportError.message("A reminder has incomplete due-date components; the export was not replaced.")
        }
        let hasTime = components.hour != nil || components.minute != nil || components.second != nil
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = components.second ?? 0
        guard (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else {
            throw ExportError.message("A reminder has invalid due-time components; the export was not replaced.")
        }
        // Validate civil components in UTC so floating dates are not shifted by this Mac's zone.
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(secondsFromGMT: 0)!
        let dateParts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let validationDate = gregorian.date(from: dateParts) else {
            throw ExportError.message("A reminder has an invalid due date; the export was not replaced.")
        }
        let validated = gregorian.dateComponents([.year, .month, .day], from: validationDate)
        guard validated.year == year, validated.month == month, validated.day == day else {
            throw ExportError.message("A reminder has an invalid due date; the export was not replaced.")
        }
        let date = String(format: "%04d-%02d-%02d", year, month, day)
        guard hasTime else { return date }
        let local = date + String(format: "T%02d:%02d:%02d", hour, minute, second)
        guard let timeZone = components.timeZone else { return local }
        gregorian.timeZone = timeZone
        guard let instant = gregorian.date(from: dateParts) else {
            throw ExportError.message("A reminder's due date cannot be represented in its time zone.")
        }
        let zoned = gregorian.dateComponents([.year, .month, .day, .hour, .minute, .second], from: instant)
        guard zoned.year == year, zoned.month == month, zoned.day == day,
              zoned.hour == hour, zoned.minute == minute, zoned.second == second else {
            throw ExportError.message("A reminder's due time does not exist in its time zone, possibly because of a daylight-saving change.")
        }
        let offset = timeZone.secondsFromGMT(for: instant)
        let sign = offset < 0 ? "-" : "+"
        let absoluteOffset = abs(offset)
        return local + String(format: "%@%02d:%02d", sign, absoluteOffset / 3_600, (absoluteOffset % 3_600) / 60)
    }
}

enum EventKitLabels {
    static func status(_ status: EKEventStatus) -> String {
        switch status {
        case .none: return "none"
        case .confirmed: return "confirmed"
        case .tentative: return "tentative"
        case .canceled: return "cancelled"
        @unknown default: return "unknown"
        }
    }

    static func participation(_ status: EKParticipantStatus) -> String {
        switch status {
        case .unknown: return "unknown"
        case .pending: return "pending"
        case .accepted: return "accepted"
        case .declined: return "declined"
        case .tentative: return "tentative"
        case .delegated: return "delegated"
        case .completed: return "completed"
        case .inProcess: return "in-process"
        @unknown default: return "unknown"
        }
    }
}

/// A cancelled EventKit fetch never calls its completion handler. Resume our own
/// continuation on cancellation/timeout, and ignore any late completion safely.
@MainActor
final class EventKitCallback<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var cancelRequest: (() -> Void)?
    private var deadline: Task<Void, Never>?

    static func wait(
        timeoutNanoseconds: UInt64,
        start: (@escaping (Result<Value, Error>) -> Void) -> (() -> Void)
    ) async throws -> Value {
        let callback = EventKitCallback<Value>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                callback.continuation = continuation
                callback.deadline = Task { @MainActor in
                    var elapsed: UInt64 = 0
                    let step: UInt64 = 15_000_000_000
                    while elapsed + step < timeoutNanoseconds {
                        do { try await Task.sleep(nanoseconds: step) } catch { return }
                        elapsed += step
                        ExportLog.info("reminders: still waiting for EventKit (\(elapsed / 1_000_000_000)s)")
                    }
                    do { try await Task.sleep(nanoseconds: timeoutNanoseconds - elapsed) } catch { return }
                    callback.finish(.failure(ExportError.message("Reminders did not respond within 60 seconds. Open Reminders and try the export again.")), cancelling: true)
                }
                callback.cancelRequest = start { result in
                    Task { @MainActor in callback.finish(result, cancelling: false) }
                }
            }
        } onCancel: {
            Task { @MainActor in callback.finish(.failure(CancellationError()), cancelling: true) }
        }
    }

    private func finish(_ result: Result<Value, Error>, cancelling: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        deadline?.cancel()
        deadline = nil
        if cancelling { cancelRequest?() }
        cancelRequest = nil
        continuation.resume(with: result)
    }
}
