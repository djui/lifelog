import Foundation
import ICloudExporterCore
import Darwin

@main
struct ICloudExporter {
    @MainActor
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty || arguments == ["--help"] || arguments == ["help"] || arguments == ["export", "--help"] {
            print(Config.help)
            return
        }
        if arguments == ["--version"] { print("icloud-exporter 0.1.0"); return }
        do {
            let config = try Config(arguments: arguments)
            let now = Date()
            let window = config.window(now: now)
            var snapshot = ExportSnapshot()
            if config.demo {
                snapshot = Demo.snapshot(now: now)
            } else {
                let eventKit = EventKitExporter()
                if config.sources.contains(.notes) {
                    let result = try await NotesExporter.fetch()
                    snapshot.notes = result.records; snapshot.warnings[.notes] = result.warnings
                }
                if config.sources.contains(.reminders) {
                    let result = try await eventKit.reminders(completedSince: window.completedSince)
                    snapshot.reminders = result.records; snapshot.warnings[.reminders] = result.warnings
                }
                if config.sources.contains(.calendar) {
                    let result = try await eventKit.events(from: window.start, to: window.end)
                    snapshot.events = result.records; snapshot.warnings[.calendar] = result.warnings
                }
            }
            // Complete all source reads before changing the managed snapshot.
            let documents = try MarkdownWriter.documents(snapshot: snapshot, config: config, now: now)
            let summary = try ExportStore(output: config.output).write(documents, sources: config.sources, now: now, demo: config.demo, warnings: snapshot.warnings)
            print("Export complete: \(summary.written) files written, \(summary.unchanged) unchanged, \(summary.removed) removed.")
            print("Output: \(config.output.path)")
            for source in ExportSource.allCases {
                for warning in snapshot.warnings[source] ?? [] { stderr("Warning (\(source.rawValue)): \(warning)") }
            }
        } catch {
            stderr("Export failed: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func stderr(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }
}
