import Foundation

public enum Command: String, CaseIterable {
    case export, archive, rebuild, verify
}

public struct Config {
    public var command: Command = .export
    public var output: URL
    public var sources: Set<ExportSource> = Set(ExportSource.exportable)
    public var pastDays = 365
    public var futureDays = 365
    public var completedDays = 30
    public var whatsappChats = 20
    public var demo = false
    // archive
    public var backfillSince: Date
    public var rescanDays = 100
    public var fullSweepDays = 7
    public var notify = false
    /// Where ChatGPT and Claude export zips are picked up. Zips stay where they are.
    public var aiInbox = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)

    static let flags: [Command: Set<String>] = [.export: ["--demo"], .archive: ["--demo", "--notify"], .rebuild: [], .verify: []]
    static let valued: [Command: Set<String>] = [
        .export: ["--output", "--sources", "--past-days", "--future-days", "--completed-days"],
        .archive: ["--output", "--sources", "--backfill-since", "--rescan-days", "--full-sweep-days", "--ai-inbox"],
        .rebuild: ["--output"], .verify: ["--output"],
    ]

    public init(arguments: [String]) throws {
        guard let name = arguments.first, let command = Command(rawValue: name) else {
            throw ExportError.message("Expected a command: \(Command.allCases.map(\.rawValue).joined(separator: ", ")). Use --help for usage.")
        }
        self.command = command
        backfillSince = Self.civilDate("2000-01-01")!
        var values = Array(arguments.dropFirst()).makeIterator()
        var outputPath: String?
        var seen = Set<String>()
        while let option = values.next() {
            guard seen.insert(option).inserted else { throw ExportError.message("Repeated option: \(option)") }
            if Self.flags[command]!.contains(option) {
                if option == "--demo" { demo = true }
                if option == "--notify" { notify = true }
                continue
            }
            guard Self.valued[command]!.contains(option) else { throw ExportError.message("Unknown option: \(option)") }
            guard let value = values.next(), !value.hasPrefix("--"), !value.isEmpty else { throw ExportError.message("Missing value for \(option)") }
            switch option {
            case "--output": outputPath = value
            case "--ai-inbox": aiInbox = URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
            case "--sources":
                let allowed = command == .export ? ExportSource.exportable : ExportSource.allCases
                let names = value.split(separator: ",", omittingEmptySubsequences: false)
                let selected = names.compactMap { ExportSource(rawValue: String($0)) }.filter(allowed.contains)
                guard selected.count == names.count, !selected.isEmpty else { throw ExportError.message("Sources must be a comma-separated list of \(allowed.map(\.rawValue).joined(separator: ",")).") }
                sources = Set(selected)
            case "--backfill-since":
                guard let date = Self.civilDate(value) else { throw ExportError.message("--backfill-since must be a date as YYYY-MM-DD.") }
                backfillSince = date
            default:
                guard let days = Int(value), (1...730).contains(days) else { throw ExportError.message("\(option) must be between 1 and 730 days.") }
                if option == "--past-days" { pastDays = days }
                if option == "--future-days" { futureDays = days }
                if option == "--completed-days" { completedDays = days }
                if option == "--rescan-days" { rescanDays = days }
                if option == "--full-sweep-days" { fullSweepDays = days }
            }
        }
        guard let outputPath else {
            throw ExportError.message(command == .export ? "--output is required. Choose a dedicated export folder." : "--output is required. Choose a dedicated archive folder.")
        }
        output = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }

    /// Local midnight of a strict `YYYY-MM-DD` date.
    static func civilDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard value.count == 10, let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return date
    }

    public func window(now: Date) -> (start: Date, end: Date, completedSince: Date) {
        let calendar = Calendar.current
        return (calendar.date(byAdding: .day, value: -pastDays, to: now)!,
                calendar.date(byAdding: .day, value: futureDays, to: now)!,
                calendar.date(byAdding: .day, value: -completedDays, to: now)!)
    }

    public static let help = """
    icloud-exporter — read Apple Notes, Reminders, Calendar, and WhatsApp chats into Markdown

    Usage:
      icloud-exporter export --output <directory> [options]
      icloud-exporter archive --output <directory> [options]
      icloud-exporter rebuild --output <directory>
      icloud-exporter verify --output <directory>

    Commands:
      export      Mirror the sources into Markdown snapshots
      archive     Keep a lifelong archive that never loses items: deleted, expired
                  and revoked items are marked, never dropped
      rebuild     Regenerate every archive page from the ledger
      verify      Check the archive ledger (not available yet)

    Export options:
      --sources notes,reminders,calendar,whatsapp   Sources to export (default: all)
      --past-days N                       Calendar and WhatsApp history (default: 365)
      --future-days N                     Calendar lookahead (default: 365)
      --completed-days N                  Completed reminder history (default: 30)
      --demo                              Export synthetic examples; no local app access

    Archive options:
      --sources notes,reminders,calendar,whatsapp,chatgpt,claude,claudecode
                                          Sources to archive (default: notes,reminders,calendar,whatsapp)
      --backfill-since YYYY-MM-DD         First run reads history back to this date (default: 2000-01-01)
      --rescan-days N                     Recent history re-read on every run (default: 100)
      --full-sweep-days N                 Days between full re-reads (default: 7)
      --ai-inbox <directory>              Folder with ChatGPT/Claude export zips (default: ~/Downloads);
                                          each new zip is imported once and left in place
      --notify                            Notify when WhatsApp capture falls behind
      --demo                              Archive synthetic examples; no local app access

      --help                              Show this help
      --version                           Show version

    Day counts must be 1–730. WhatsApp exports the 20 most recently active chats
    in that history window. Exported files are managed snapshots, not backups.
    Choose an empty dedicated folder, or a previous export folder. Export and
    archive folders must be separate.

    Archive layout: _index.md, Timeline/ and _Disappeared/ by month, WhatsApp/<chat>/,
    Calendar/ and Reminders/ by month, Notes/ by account and folder, and ChatGPT/,
    Claude/ and ClaudeCode/ by the month a chat started. The ledger in .archive/ is
    the source of truth; pages are views of it.
    """
}
