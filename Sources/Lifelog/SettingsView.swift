import AppKit
import ApplicationServices
import EventKit
import LifelogCore
import SwiftUI

/// The Settings window: General, Sources, Permissions and Advanced. Changes are saved at once and the next check of
/// the scheduler uses them.
struct SettingsView: View {
    @ObservedObject var model: MenuModel
    @State private var settings: AppSettings

    init(model: MenuModel) {
        self.model = model
        _settings = State(initialValue: AppSettings.load(model.defaults))
    }

    var body: some View {
        TabView {
            GeneralTab(model: model, settings: $settings).tabItem { Label("General", systemImage: "gearshape") }
            SourcesTab(settings: $settings).tabItem { Label("Sources", systemImage: "clock") }
            PermissionsTab().tabItem { Label("Permissions", systemImage: "lock") }
            AdvancedTab(model: model, settings: $settings).tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 560)
        .onChange(of: settings) { _, settings in
            settings.save(model.defaults)
            model.scheduler.tick()
        }
        // A menu bar app is not active, so its windows would open behind the frontmost app.
        .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
    }
}

struct GeneralTab: View {
    @ObservedObject var model: MenuModel
    @Binding var settings: AppSettings

    var body: some View {
        Form {
            LabeledContent("Archive folder") {
                HStack {
                    Text(model.folder?.path ?? "Not chosen").truncationMode(.middle).lineLimit(1).foregroundStyle(model.folder == nil ? .secondary : .primary)
                    Button("Choose…") { model.chooseFolder() }
                }
            }
            if model.folder != nil, !model.started {
                LabeledContent("") {
                    Button("Start Archiving Here…") { model.startHere() }
                }
            }
            Toggle("Open at login", isOn: Binding(get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) }))
            Toggle(isOn: $settings.notify) {
                Text("Notifications")
                Text("When WhatsApp falls behind, reads keep failing, or a ChatGPT, Claude or Instagram export is due.")
            }
        }
        .formStyle(.grouped)
    }
}

struct SourcesTab: View {
    @Binding var settings: AppSettings

    var body: some View {
        Form {
            Section("Sources") {
                ForEach(ArchiveReaders.order, id: \.self) { source in
                    Picker(source.displayName, selection: Binding(get: { settings.lane(of: source) }, set: { settings.sourceLanes[source] = $0 })) {
                        Text("Frequent").tag(Lane.frequent.id)
                        Text("Hourly").tag(Lane.hourly.id)
                        Text("Off").tag(AppSettings.off)
                    }
                }
            }
            Section {
                Picker(selection: $settings.frequentMinutes) {
                    ForEach(AppSettings.frequentChoices, id: \.self) { Text("Every \($0) minutes").tag($0) }
                } label: {
                    Text("Frequent")
                    Text("WhatsApp's shortest disappearing timer is 24 hours.")
                }
                Picker(selection: $settings.hourlyMinutes) {
                    ForEach(AppSettings.hourlyChoices, id: \.self) { Text($0 < 60 ? "Every \($0) minutes" : "Every \($0 / 60) hour\($0 == 60 ? "" : "s")").tag($0) }
                } label: {
                    Text("Hourly")
                    Text("A full Notes read can take minutes.")
                }
                Toggle("Run when the Mac wakes", isOn: $settings.runOnWake)
                Toggle("Wait for power before hourly runs", isOn: $settings.deferOnBattery)
            }
            Section("ChatGPT, Claude and Instagram exports") {
                LabeledContent("Inbox folder") {
                    HStack {
                        Text(settings.aiInbox?.path ?? "~/Downloads").truncationMode(.middle).lineLimit(1)
                        Button("Choose…") { if let url = chooseFolder("Choose the folder with ChatGPT, Claude and Instagram export zips") { settings.aiInbox = url } }
                        if settings.aiInbox != nil { Button("Reset") { settings.aiInbox = nil } }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct AdvancedTab: View {
    @ObservedObject var model: MenuModel
    @Binding var settings: AppSettings
    @State private var since = ""
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                TextField(text: $since, prompt: Text("2000-01-01")) {
                    Text("History from")
                    Text("How far back the first read of a source goes, as YYYY-MM-DD.")
                }
                .onAppear { since = settings.backfillSince ?? "" }
                .onSubmit(applySince)
                Stepper("Re-read the last \(settings.rescanDays) days on every run", value: $settings.rescanDays, in: 1...730)
                Stepper("Read everything again every \(settings.fullSweepDays) days", value: $settings.fullSweepDays, in: 1...730)
                Toggle("Write the HTML viewer", isOn: $settings.viewer)
            }
            Section("Archive") {
                HStack {
                    Button("Verify Archive") { run(["verify"]) }
                    Button("Rebuild Pages") { run(["rebuild"] + (settings.viewer ? [] : ["--no-viewer"])) }
                    Button("Show Ledger in Finder") {
                        if let folder = model.folder { NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent(Ledger.folderName)]) }
                    }
                }
                .disabled(!model.started || busy)
            }
        }
        .formStyle(.grouped)
        .onDisappear(perform: applySince)
    }

    func applySince() {
        let value = since.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { settings.backfillSince = nil; return }
        guard Config.civilDate(value) != nil else { return model.alert("Not a date", "Write the date as YYYY-MM-DD, such as 2015-01-01.") }
        settings.backfillSince = value
    }

    /// Verify and Rebuild run as the CLI does, in a child process, and report its last line.
    func run(_ command: [String]) {
        guard let folder = model.folder else { return }
        busy = true
        Task {
            let result = await Runner.run(command + ["--output", folder.path], timeout: 3600)
            busy = false
            model.alert(result.status == 0 ? "\(command[0].capitalized) finished" : "\(command[0].capitalized) failed",
                        result.problem ?? result.last ?? "See Show Log for details.")
        }
    }
}

/// What macOS lets the app read. Checking never asks: a missing permission is asked for on the next read that needs it.
struct PermissionsTab: View {
    struct Row: Identifiable {
        var id: String { name }
        var name: String
        var detail: String
        var granted: Bool?
        var pane: String
    }

    @State private var rows: [Row] = []

    var body: some View {
        Form {
            Section {
                ForEach(rows) { row in
                    LabeledContent {
                        Button("Open System Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(row.pane)")!) }
                    } label: {
                        Label {
                            Text(row.name)
                            Text(row.detail)
                        } icon: {
                            Image(systemName: row.granted == true ? "checkmark.circle.fill" : row.granted == false ? "xmark.circle.fill" : "questionmark.circle")
                                .foregroundStyle(row.granted == true ? .green : row.granted == false ? .red : .secondary)
                        }
                    }
                }
            } footer: {
                HStack {
                    Text("Grant access to Lifelog. The first read of each source asks if needed.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Again", action: refresh)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
    }

    func refresh() { rows = Self.check() }

    static func check() -> [Row] {
        func eventKit(_ name: String, _ entity: EKEntityType, _ pane: String) -> Row {
            switch EKEventStore.authorizationStatus(for: entity) {
            case .fullAccess: return Row(name: name, detail: "Full access", granted: true, pane: pane)
            case .notDetermined: return Row(name: name, detail: "Asked on the first read", granted: nil, pane: pane)
            case .writeOnly: return Row(name: name, detail: "Add-only access is not enough; allow full access", granted: false, pane: pane)
            default: return Row(name: name, detail: "Denied", granted: false, pane: pane)
            }
        }
        return [eventKit("Calendar", .event, "Privacy_Calendars"), eventKit("Reminders", .reminder, "Privacy_Reminders"), notes(), fullDiskAccess()]
    }

    /// Automation of Notes, without asking.
    static func notes() -> Row {
        var target = AEAddressDesc()
        let bundle = "com.apple.Notes"
        _ = bundle.withCString { AECreateDesc(typeApplicationBundleID, $0, strlen($0), &target) }
        defer { AEDisposeDesc(&target) }
        let pane = "Privacy_Automation"
        switch AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false) {
        case noErr: return Row(name: "Notes", detail: "Allowed to control Notes", granted: true, pane: pane)
        case OSStatus(errAEEventNotPermitted): return Row(name: "Notes", detail: "Not allowed to control Notes", granted: false, pane: pane)
        case OSStatus(procNotFound): return Row(name: "Notes", detail: "Checked when Notes is open", granted: nil, pane: pane)
        default: return Row(name: "Notes", detail: "Asked on the first Notes read", granted: nil, pane: pane)
        }
    }

    /// WhatsApp's database needs Full Disk Access (or access to other apps' data). The TCC database opens only with
    /// Full Disk Access, and trying never shows a prompt.
    static func fullDiskAccess() -> Row {
        let tcc = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        let fd = open(tcc.path, O_RDONLY)
        if fd >= 0 { close(fd) }
        return Row(name: "Full Disk Access", detail: fd >= 0 ? "Granted, so WhatsApp can be read" : "Needed to read WhatsApp", granted: fd >= 0, pane: "Privacy_AllFiles")
    }
}

/// An Open panel for a folder; nil when cancelled.
@MainActor
func chooseFolder(_ title: String) -> URL? {
    let panel = NSOpenPanel()
    panel.title = title
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    NSApplication.shared.activate(ignoringOtherApps: true)
    return panel.runModal() == .OK ? panel.url : nil
}
