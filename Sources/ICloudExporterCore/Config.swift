import Foundation

public struct Config {
    public var output: URL
    public var sources: Set<ExportSource> = Set(ExportSource.allCases)
    public var pastDays = 365
    public var futureDays = 365
    public var completedDays = 30
    public var whatsappChats = 20
    public var demo = false

    public init(arguments: [String]) throws {
        guard arguments.first == "export" else { throw ExportError.message("Expected 'export'. Use --help for usage.") }
        var values = Array(arguments.dropFirst()).makeIterator()
        var outputPath: String?
        var seen = Set<String>()
        while let option = values.next() {
            guard seen.insert(option).inserted else { throw ExportError.message("Repeated option: \(option)") }
            if option == "--demo" { demo = true; continue }
            guard ["--output", "--sources", "--past-days", "--future-days", "--completed-days"].contains(option) else {
                throw ExportError.message("Unknown option: \(option)")
            }
            guard let value = values.next(), !value.hasPrefix("--"), !value.isEmpty else { throw ExportError.message("Missing value for \(option)") }
            switch option {
            case "--output": outputPath = value
            case "--sources":
                let names = value.split(separator: ",", omittingEmptySubsequences: false)
                let selected = names.compactMap { ExportSource(rawValue: String($0)) }
                guard selected.count == names.count, !selected.isEmpty else { throw ExportError.message("Sources must be a comma-separated list of \(ExportSource.allCases.map(\.rawValue).joined(separator: ",")).") }
                sources = Set(selected)
            default:
                guard let days = Int(value), (1...730).contains(days) else { throw ExportError.message("\(option) must be between 1 and 730 days.") }
                if option == "--past-days" { pastDays = days }
                if option == "--future-days" { futureDays = days }
                if option == "--completed-days" { completedDays = days }
            }
        }
        guard let outputPath else { throw ExportError.message("--output is required. Choose a dedicated export folder.") }
        output = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
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

    Options:
      --sources notes,reminders,calendar,whatsapp   Sources to export (default: all)
      --past-days N                       Calendar and WhatsApp history (default: 365)
      --future-days N                     Calendar lookahead (default: 365)
      --completed-days N                  Completed reminder history (default: 30)
      --demo                              Export synthetic examples; no local app access
      --help                              Show this help
      --version                           Show version

    Day counts must be 1–730. WhatsApp exports the 20 most recently active chats
    in that history window. Exported files are managed snapshots, not backups.
    Choose an empty dedicated folder, or a previous export folder.
    """
}
