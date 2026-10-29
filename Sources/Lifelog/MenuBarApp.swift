import AppKit
import Combine
import LifelogCore
import ServiceManagement
import SwiftUI

/// The menu bar face of the app: archive runs on a schedule (`Scheduler`), their status, the viewer and the archive
/// folder, Open at Login, and the Settings window.
struct MenuBarApp: App {
    @StateObject private var model = MenuModel()

    var body: some Scene {
        MenuBarExtra {
            Text(model.folder.map { "Archive: \($0.lastPathComponent)" } ?? "No archive folder chosen")
            ForEach(model.status, id: \.self) { Text($0) }
            if let menu = model.menu {
                ForEach(menu.sources, id: \.source) { row in
                    Label("\(row.source.displayName): \(Self.short(row.detail))", systemImage: Self.symbol(row.state))
                }
                ForEach(menu.warnings, id: \.self) { Label(Self.short($0), systemImage: "exclamationmark.triangle") }
            }
            if model.folder != nil, !model.started {
                Button("Start Archiving Here…") { model.startHere() }
            }
            if let title = model.takeOverTitle {
                Button(title) { model.takeOver() }
            }
            Divider()
            Button("Run Now") { model.scheduler.runNow() }.keyboardShortcut("r")
                .disabled(model.folder == nil || model.scheduler.running != nil || !model.scheduler.agents.isEmpty)
            Menu("Pause") {
                Button("For 1 Hour") { model.scheduler.pause(for: 3600) }
                Button("For 8 Hours") { model.scheduler.pause(for: 8 * 3600) }
                Button("Resume") { model.scheduler.pause(for: nil) }.disabled(model.scheduler.pausedUntil == nil)
            }
            Button("Show Log") { NSWorkspace.shared.open(Runner.log) }.disabled(!FileManager.default.fileExists(atPath: Runner.log.path))
            Divider()
            Button("Open Viewer") { model.openViewer() }.keyboardShortcut("o")
            Button("Open Archive Folder") { model.openFolder() }.disabled(model.folder == nil)
            Button("Choose Archive Folder…") { model.chooseFolder() }
            Divider()
            Toggle("Open at Login", isOn: Binding(get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) }))
            SettingsLink { Text("Settings…") }.keyboardShortcut(",")
            Divider()
            Button("Quit Lifelog") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        } label: {
            MenuBarLabel(icon: model.menu?.icon ?? .idle, spinner: model.spinner)
        }
        Settings {
            SettingsView(model: model)
        }
    }

    static func symbol(_ state: SourceStatus.State) -> String {
        switch state {
        case .ok: return "checkmark.circle"
        case .reading: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle"
        }
    }

    /// Menu items don't wrap; long warnings are cut, and Show Log has the rest.
    static func short(_ text: String) -> String { text.count <= 90 ? text : String(text.prefix(89)) + "…" }
}

/// The icon alone observes the spinner, so turning it redraws the icon and not the menu.
struct MenuBarLabel: View {
    var icon: IconState
    @ObservedObject var spinner: Spinner

    var body: some View {
        Image(nsImage: MenuBarIcon.image(icon, frame: icon == .running ? spinner.frame : 0))
    }
}

/// Steps the running icon's spinner, so a long run (a full Notes read takes minutes) doesn't look stuck. It ticks
/// only while a run is in progress, and not at all with Reduce Motion on.
@MainActor
final class Spinner: ObservableObject {
    @Published private(set) var frame = 0
    private var timer: Timer?

    func spin(_ on: Bool) {
        let on = on && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard on != (timer != nil) else { return }
        timer?.invalidate()
        timer = nil
        frame = 0
        guard on else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self.map { $0.frame = ($0.frame + 1) % MenuBarIcon.spinnerFrames } }
        }
    }
}

@MainActor
final class MenuModel: ObservableObject {
    static let folderKey = "archiveFolder"
    static let startedKey = "archiveStartedIn"

    @Published private(set) var folder: URL?
    @Published private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled
    let defaults: UserDefaults
    let scheduler: Scheduler
    let spinner = Spinner()
    private var forward: AnyCancellable?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        folder = defaults.string(forKey: Self.folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
        scheduler = Scheduler(defaults: defaults)
        forward = scheduler.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            // Sent before the change: look at the new state once it is set.
            DispatchQueue.main.async { self.map { $0.spinner.spin($0.scheduler.running != nil) } }
        }
        scheduler.start()
        if started { scheduler.folder = folder }
    }

    /// Archiving runs only in a folder that holds an archive already, or one the user confirmed, so choosing a busy
    /// folder (such as a whole Drive) never starts writing pages into it by surprise.
    var started: Bool {
        guard let folder else { return false }
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent(Ledger.folderName).path)
            || defaults.string(forKey: Self.startedKey) == folder.path
    }

    func startHere() {
        guard let folder else { return }
        let items = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Start archiving in \(folder.lastPathComponent)?"
        alert.informativeText = (items.isEmpty ? "The folder is empty. " : "The folder already holds \(items.count) item\(items.count == 1 ? "" : "s"); the archive adds _index.md, Notes/, WhatsApp/, Calendar/ and more next to them. An empty folder of its own is better. ")
            + "The first run reads your Notes, Reminders, Calendar and WhatsApp history, so macOS asks for access."
        alert.addButton(withTitle: "Start Archiving")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        defaults.set(folder.path, forKey: Self.startedKey)
        scheduler.folder = folder
        objectWillChange.send()
    }

    /// Status lines under the folder: what runs, what's next, and what went wrong.
    var status: [String] {
        let scheduler = scheduler
        guard folder != nil else { return ["Choose an archive folder to start archiving."] }
        guard started else { return ["No archive in this folder yet."] }
        if !scheduler.agents.isEmpty {
            return ["Runs come from launchd (\(scheduler.agents.count) archive agent\(scheduler.agents.count == 1 ? "" : "s")). Take over to let the app schedule them."]
        }
        var lines: [String] = []
        if let lane = scheduler.running {
            lines.append("Archiving \((scheduler.reading.map { [$0] } ?? lane.sources).map(\.displayName).joined(separator: ", "))…")
        } else if let paused = scheduler.pausedUntil {
            lines.append("Paused until \(Self.time(paused))")
        } else {
            lines.append(scheduler.next.map { "Next run \(Self.time($0))" } ?? "Starting a run…")
        }
        return lines
    }

    /// Source rows, warnings and the icon state, once the app schedules runs in an archive.
    var menu: MenuStatus? {
        guard started, scheduler.agents.isEmpty else { return nil }
        return MenuStatus.make(records: scheduler.records, now: Date(), running: scheduler.running, reading: scheduler.reading,
                               pausedUntil: scheduler.pausedUntil, failure: scheduler.failure, health: scheduler.health, time: Self.time)
    }

    /// `14:31`, or `28 Oct, 14:31` when not today.
    static func time(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : date.formatted(.dateTime.day().month().hour().minute())
    }

    func openViewer() {
        guard let folder = folder ?? pickFolder() else { return }
        let page = folder.appendingPathComponent("_viewer/index.html")
        guard FileManager.default.fileExists(atPath: page.path) else {
            return alert("No viewer in \(folder.lastPathComponent)", "Run `lifelog archive` or `rebuild` for this folder first; they write _viewer/index.html.")
        }
        NSWorkspace.shared.open(page)
    }

    func openFolder() {
        guard let folder else { return }
        NSWorkspace.shared.open(folder)
    }

    func chooseFolder() { _ = pickFolder() }

    /// Asks for the archive folder and remembers it. A folder without `.archive/` is kept too: the first run creates it.
    func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose the archive folder"
        panel.message = "The folder `lifelog archive --output` writes to. It must not be an export folder."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do { try Ledger.checkFolder(url) } catch {
            alert("This folder can't hold the archive", error.localizedDescription)
            return nil
        }
        defaults.set(url.path, forKey: Self.folderKey)
        folder = url
        scheduler.folder = started ? url : nil
        return url
    }

    func setOpensAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on { try service.register() } else { try service.unregister() }
        } catch {
            alert("Could not change Open at Login", error.localizedDescription)
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        opensAtLogin = service.status == .enabled
    }

    // MARK: launchd

    /// Where taken-over agents are moved, so they can be restored by moving them back.
    static var disabledAgents: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.djui.icloud-exporter/Disabled LaunchAgents")
    }

    /// The menu item for installed agents: take over archive agents, or stop the export agent once the archive runs.
    var takeOverTitle: String? {
        let agents = LaunchAgents.agents()
        if agents.contains(where: \.isArchive) { return "Take Over from launchd…" }
        return agents.isEmpty ? nil : "Stop the Export Agent…"
    }

    /// Unloads the agents, moves their plists aside and, for archive agents, adopts their folder, sources and
    /// options, so the app schedules the same runs. The export agent goes too only when asked: running both for a
    /// week is the README's advice before retiring `export`.
    func takeOver() {
        let agents = LaunchAgents.agents()
        let archive = agents.filter(\.isArchive), export = agents.filter { !$0.isArchive }
        guard !agents.isEmpty else { return }
        let adopted = LaunchAgents.adopt(archive, into: AppSettings.load(defaults))
        if let folder = adopted?.folder ?? folder, Scheduler.locked(folder) {
            return alert("A run is in progress", "Try again when it has finished, in a minute or two.")
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        let names = (archive.isEmpty ? export : archive).map { "• \($0.label)" }.joined(separator: "\n")
        let moved = "Their files move to ~/Library/Application Support/com.djui.icloud-exporter/Disabled LaunchAgents, so you can restore them."
        if let adopted {
            alert.messageText = "Take over from launchd?"
            alert.informativeText = "Lifelog will archive \(adopted.folder.lastPathComponent) on the same schedule, and stop these agents:\n\(names)\n\n\(moved)"
            alert.addButton(withTitle: "Take Over")
            if !export.isEmpty {
                alert.showsSuppressionButton = true
                alert.suppressionButton?.title = "Also stop the export agent (the archive replaces it)"
                alert.suppressionButton?.state = .off
            }
        } else {
            alert.messageText = "Stop the export agent?"
            alert.informativeText = "The archive keeps everything the export mirror has, and more. Stop these agents:\n\(names)\n\n\(moved)"
            alert.addButton(withTitle: "Stop Export Agent")
        }
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let stopping = archive + (adopted == nil || alert.suppressionButton?.state == .on ? export : [])
        var problems: [String] = []
        for agent in stopping {
            do { try Self.disable(agent) } catch { problems.append("\(agent.label): \(error.localizedDescription)") }
        }
        if let adopted {
            adopted.settings.save(defaults)
            // The agents already archived there, so the folder needs no Start Archiving Here.
            defaults.set(adopted.folder.path, forKey: Self.folderKey)
            defaults.set(adopted.folder.path, forKey: Self.startedKey)
            folder = adopted.folder
            scheduler.folder = adopted.folder
        }
        scheduler.tick()
        objectWillChange.send()
        if !problems.isEmpty { self.alert("Some agents could not be stopped", problems.joined(separator: "\n")) }
    }

    static func disable(_ agent: LaunchAgents.Agent) throws {
        // Not loaded is fine: the plist is moved aside either way.
        let launchctl = Process()
        launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        launchctl.arguments = ["bootout", "gui/\(getuid())", agent.file.path]
        launchctl.standardOutput = FileHandle.nullDevice
        launchctl.standardError = FileHandle.nullDevice
        try launchctl.run()
        launchctl.waitUntilExit()
        let manager = FileManager.default
        try manager.createDirectory(at: disabledAgents, withIntermediateDirectories: true)
        let target = disabledAgents.appendingPathComponent(agent.file.lastPathComponent)
        try? manager.removeItem(at: target)
        try manager.moveItem(at: agent.file, to: target)
    }

    func alert(_ title: String, _ message: String) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
