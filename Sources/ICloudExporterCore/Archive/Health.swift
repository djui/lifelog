import AppKit
import Foundation

/// A stretch without a complete WhatsApp read that is longer than the shortest disappearing timer (24 h).
/// Messages on that timer sent between `lossFrom` and `lossUntil` may have expired before any read saw them.
public struct CaptureGap: Equatable {
    /// End of the last complete read before the gap.
    public var lastRead: Date
    /// End of the complete read that closed the gap; nil while it is still open.
    public var closed: Date?
    public var lossFrom: Date
    public var lossUntil: Date
}

/// Something worth a macOS notification. `id` is stable for one gap or problem, so it is sent once.
public struct HealthNotice: Equatable {
    public enum Kind: String { case whatsappEarly, whatsappLoss, readFailures, staleImport }
    public var id: String
    public var kind: Kind
    public var title: String
    public var body: String
}

public struct HealthReport: Equatable {
    /// One line each, for stderr and `_index.md`.
    public var warnings: [String] = []
    public var notices: [HealthNotice] = []
    /// Every WhatsApp capture gap in the run log, oldest first, the open one last.
    public var gaps: [CaptureGap] = []
    public var hoursSinceWhatsApp: Double?
}

/// Capture health from the run log. Pure apart from the WhatsApp Desktop check, which callers pass in.
public enum Health {
    /// The shortest WhatsApp disappearing timer: a longer gap can lose messages for good.
    public static let timer: TimeInterval = 24 * 3600
    /// Early warning, four hours before the first message could expire unseen.
    public static let earlyWarning: TimeInterval = 20 * 3600
    /// Incomplete or failed reads in a row before a source is flagged.
    public static let failureStreak = 3
    /// ChatGPT and Claude exports are manual; remind after this long without a new one.
    public static let staleImport: TimeInterval = 45 * 86_400
    /// Closed gaps stay in the warnings this long; `gaps` keeps all of them.
    public static let recentGap: TimeInterval = 30 * 86_400
    public static let whatsAppBundleID = "net.whatsapp.WhatsApp"

    /// Warnings for `_index.md`, read from the run log on disk.
    public static func warnings(runLog: RunLog, now: Date, sources: Set<ArchiveSource>? = nil, whatsAppRunning: Bool? = whatsAppRunning(),
                                timeZone: TimeZone = .current) -> [String] {
        do {
            return report(try runLog.read().records, now: now, sources: sources, whatsAppRunning: whatsAppRunning, timeZone: timeZone).warnings
        } catch {
            return ["The run log could not be read: \(error.localizedDescription)"]
        }
    }

    /// `sources` are the archived sources; nil means every source in the run log. `whatsAppRunning` nil skips that check.
    public static func report(_ records: [RunRecord], now: Date, sources: Set<ArchiveSource>? = nil, whatsAppRunning: Bool?, timeZone: TimeZone = .current) -> HealthReport {
        var report = HealthReport()
        let watched = sources ?? Set(records.map(\.source))
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = timeZone
        local.dateFormat = "yyyy-MM-dd HH:mm"
        func time(_ date: Date) -> String { local.string(from: date) }
        func hours(_ interval: TimeInterval) -> Int { Int(interval / 3600) }

        if watched.contains(.whatsapp) {
            let reads = records.filter { $0.source == .whatsapp && $0.complete }.map(\.end).sorted()
            for (before, after) in zip(reads, reads.dropFirst()) where after.timeIntervalSince(before) > timer {
                report.gaps.append(CaptureGap(lastRead: before, closed: after, lossFrom: before, lossUntil: after - timer))
            }
            let desktop = whatsAppRunning == false ? " WhatsApp Desktop is not running, so new messages do not reach this Mac." : ""
            if let last = reads.last {
                let age = now.timeIntervalSince(last)
                report.hoursSinceWhatsApp = age / 3600
                let id = JSONLines.timestamp.string(from: last)
                if age > timer {
                    report.gaps.append(CaptureGap(lastRead: last, closed: nil, lossFrom: last, lossUntil: now - timer))
                    let text = "No complete WhatsApp read for \(hours(age)) h. Disappearing messages (24 h) sent between \(time(last)) and \(time(now - timer)) may be lost."
                    report.warnings.append(text)
                    report.notices.append(HealthNotice(id: "whatsapp-gap-\(id)", kind: .whatsappLoss, title: "WhatsApp messages may be lost", body: text + desktop))
                } else if age >= earlyWarning {
                    let text = "No complete WhatsApp read for \(hours(age)) h. Disappearing messages (24 h) start to expire unseen at \(time(last + timer))."
                    report.warnings.append(text)
                    report.notices.append(HealthNotice(id: "whatsapp-early-\(id)", kind: .whatsappEarly, title: "WhatsApp archive falls behind", body: text + desktop))
                }
            } else if records.contains(where: { $0.source == .whatsapp }) {
                report.warnings.append("WhatsApp has not been read completely yet.")
            }
            for gap in report.gaps where gap.closed.map({ now.timeIntervalSince($0) <= recentGap }) == true {
                report.warnings.append("WhatsApp capture gap of \(hours(gap.closed!.timeIntervalSince(gap.lastRead))) h ended \(time(gap.closed!)). Disappearing messages (24 h) sent between \(time(gap.lossFrom)) and \(time(gap.lossUntil)) may be lost.")
            }
            // A gap that the latest read just closed, for a Mac that slept through it. Same id as the open gap, so it is sent once.
            if let gap = report.gaps.last, let closed = gap.closed, closed == reads.last, now.timeIntervalSince(closed) < timer {
                report.notices.append(HealthNotice(id: "whatsapp-gap-\(JSONLines.timestamp.string(from: gap.lastRead))", kind: .whatsappLoss, title: "WhatsApp messages may have been lost",
                                                   body: "No complete WhatsApp read between \(time(gap.lastRead)) and \(time(closed)). Disappearing messages (24 h) sent between \(time(gap.lossFrom)) and \(time(gap.lossUntil)) may be lost."))
            }
            if whatsAppRunning == false { report.warnings.append(desktop.trimmingCharacters(in: .whitespaces)) }
        }

        for source in ArchiveSource.allCases where watched.contains(source) {
            let runs = records.filter { $0.source == source }.sorted { $0.end < $1.end }
            let streak = Array(runs.reversed().prefix { !$0.complete })
            guard streak.count >= failureStreak, let first = streak.last, let latest = streak.first else { continue }
            let text = "\(source.displayName): the last \(streak.count) reads failed or were partial (latest: \(latest.warnings.first ?? "partial read"))."
            report.warnings.append(text)
            report.notices.append(HealthNotice(id: "failures-\(source.rawValue)-\(JSONLines.timestamp.string(from: first.end))", kind: .readFailures,
                                               title: "\(source.displayName) is not being archived", body: text))
        }

        let archiveStart = records.map(\.start).min()
        for source in [ArchiveSource.chatgpt, .claude] where watched.contains(source) {
            let lastImport = records.filter { $0.source == source && $0.digest != nil }.map(\.end).max()
            guard let since = lastImport ?? archiveStart, now.timeIntervalSince(since) >= staleImport else { continue }
            let days = Int(now.timeIntervalSince(since) / 86_400)
            let text = lastImport == nil
                ? "\(source.displayName): no export imported in the \(days) days since the archive started. Request an export and leave the zip in the AI inbox."
                : "\(source.displayName): no new export imported for \(days) days. Request an export and leave the zip in the AI inbox."
            report.warnings.append(text)
            report.notices.append(HealthNotice(id: "stale-\(source.rawValue)-\(JSONLines.timestamp.string(from: since))", kind: .staleImport,
                                               title: "Time for a new \(source.displayName) export", body: text))
        }
        return report
    }

    public static func whatsAppRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: whatsAppBundleID).isEmpty
    }
}

/// Notice ids already sent, kept in the archive's cache folder so the synced archive never changes for it.
public struct SentNotices: Equatable {
    /// Ids older than this are dropped; their gaps are long over.
    public static let retention: TimeInterval = 180 * 86_400
    public static let fileName = "notifications.json"
    public var sent: [String: Date] = [:]

    public init() {}

    public static func load(_ url: URL) -> SentNotices {
        var notices = SentNotices()
        if let data = try? Data(contentsOf: url), let sent = try? JSONLines.decoder.decode([String: Date].self, from: data) { notices.sent = sent }
        return notices
    }

    public func unsent(_ notices: [HealthNotice]) -> [HealthNotice] {
        var seen = Set(sent.keys)
        return notices.filter { seen.insert($0.id).inserted }
    }

    public mutating func mark(_ id: String, at now: Date) {
        sent[id] = now
        sent = sent.filter { now.timeIntervalSince($0.value) < Self.retention }
    }

    public func save(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONLines.encoder.encode(sent).write(to: url, options: .atomic)
    }
}
