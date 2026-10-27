import Foundation

/// What the viewer needs beyond the index: the static app and each item's lifecycle history. The ledger is read only
/// for the sources whose month chunks are rendered, and only once per run.
public final class Viewer {
    let ledger: Ledger
    var history: [ItemKey: [LedgerEvent]] = [:]
    var loaded = Set<ArchiveSource>()
    var assets: [String: String] = [:]

    public init(ledger: Ledger) { self.ledger = ledger }

    /// Loads what the selected pages render with, so rendering itself cannot fail.
    func prepare(_ pages: [Page]) throws {
        let sources = Set(pages.compactMap(\.history)).subtracting(loaded)
        if !sources.isEmpty {
            history.merge(ViewerData.history(try ledger.read(sources: sources).events)) { $1 }
            loaded.formUnion(sources)
        }
        guard assets.isEmpty, pages.contains(where: { $0.group == ViewerData.group }) else { return }
        for name in ViewerData.assets {
            guard let url = NotesExporter.resourceURL("viewer/\(name)"), let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw ExportError.message("The viewer resource \(name) is missing from the app bundle.")
            }
            assets[name] = text
        }
    }
}

/// `_viewer/`: a static, offline HTML app next to the archive (phase 8). Browsers block `fetch()` from `file://`, so the
/// data ships as scripts that call `window.ARCHIVE.load({...})`: `data/manifest.js` and `data/<source>/<YYYY-MM>.js`.
/// Month chunks are pages like the Markdown ones, so a run rewrites only the months its changes touched, and every
/// time, badge and last-seen date comes from the same derivations as the Markdown pages.
enum ViewerData {
    static let folder = "_viewer"
    static let group = "viewer"
    static let assets = ["index.html", "app.js", "style.css"]
    static let manifestPath = "\(folder)/data/manifest.js"

    static func chunkPath(_ source: ArchiveSource, _ month: String) -> String { "\(folder)/data/\(source.rawValue)/\(month).js" }

    static func pages(_ context: ViewContext, viewer: Viewer) -> [Page] {
        var pages = assets.map { name in Page(path: "\(folder)/\(name)", group: group, keys: [], always: true) { viewer.assets[name] ?? "" } }
        for source in ArchiveSource.allCases {
            for (month, items) in Dictionary(grouping: context.items(source), by: \.partition.month).sorted(by: { $0.key < $1.key }) {
                pages.append(Page(path: chunkPath(source, month), group: group, keys: Set(items.map(\.key)), history: source) {
                    script(Chunk(source: source.rawValue, month: month, items: items.map { item($0, context, history: viewer.history[$0.key] ?? []) }))
                })
            }
        }
        pages.append(Page(path: manifestPath, group: group, keys: [], always: true) { script(manifest(context)) })
        return pages
    }

    // MARK: Data

    struct Chunk: Encodable {
        var kind = "chunk"
        var source, month: String
        var items: [Item]
    }

    struct Item: Encodable {
        /// `<source>/<id>`.
        var key: String
        var day: String
        var time: String?
        var state: String
        var badges: [String]
        /// Sender of a message, role in an AI chat.
        var who: String?
        /// Chat, calendar, list, folder or AI chat.
        var group: String?
        var title: String?
        var text: String
        /// The Markdown page, relative to `_viewer/index.html`.
        var link: String
        var seen, noticed, reason: String?
        var history: [Event]
    }

    struct Event: Encodable {
        var at: String
        var what: String
        var detail: String?
    }

    struct Manifest: Encodable {
        var kind = "manifest"
        var version = 1
        var demo: Bool
        var updated: String?
        var sources: [Source]
        var disappeared: [Gone]
        var groups: [String: [String]]
        var people: [String]
    }

    struct Source: Encodable {
        var id, name: String
        var items, gone, pending: Int
        var lastComplete, mode: String?
        /// Month → state → items, by the month of each chunk.
        var months: [String: [String: Int]]
        /// Month → complete runs.
        var runs: [String: Int]
        /// Months inside the archive's run history without a complete run of this source.
        var gaps: [String]
    }

    struct Gone: Encodable {
        var key, source, state, month, label, text, link, noticed: String
        var seen, reason: String?
    }

    // MARK: Rendering

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// JSON inside a fixed wrapper. `<` and the JavaScript line separators are escaped, so no text can end a script
    /// element or a line inside the data, and stripping the wrapper leaves plain JSON.
    static func script(_ value: some Encodable) -> String {
        let json = String(decoding: try! encoder.encode(value), as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "window.ARCHIVE.load(\(json));\n"
    }

    static func link(_ item: ArchivedItem, _ context: ViewContext) -> String {
        let home = ArchivePages.home(item, context)
        return "../" + ArchivePages.link(home.path, from: IndexView.path, anchor: home.anchor)
    }

    static func item(_ item: ArchivedItem, _ context: ViewContext, history: [LedgerEvent]) -> Item {
        var value = Item(key: "\(item.key.source.rawValue)/\(item.key.id)", day: item.partition.date, state: item.state.rawValue,
                         badges: ArchivePages.badges(item, context), text: "", link: link(item, context), history: events(history, context))
        value.group = group(item, context)
        value.seen = context.lastSeen(item).map(context.moment)
        if item.state != .active { value.noticed = context.moment(item.stateSince); value.reason = item.reason }
        func join(_ parts: [String?]) -> String { parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n") }
        switch item.payload {
        case .message(let message):
            value.time = item.partition.clock(message.message.timestamp)
            value.who = message.message.isSystem == true ? nil : message.message.sender
            value.text = MarkdownWriter.messageBody(message.message) ?? "[no text]"
        case .event(let event):
            value.time = CalendarView.time(item, event)
            value.title = event.title
            value.text = join([event.location, event.notes, event.url])
            value.badges = CalendarView.labels(item, event) + value.badges
        case .reminder(let reminder):
            value.time = reminder.completionDate.map(item.partition.clock)
            value.title = reminder.title
            value.text = join([reminder.due.map { "due \($0)" }, reminder.notes, reminder.url])
            if reminder.isCompleted { value.badges.insert("completed", at: 0) }
        case .note(let note):
            value.time = note.modified.map(item.partition.clock)
            value.title = note.title
            value.text = NotesHTML.markdown(from: note.bodyHTML)
        case .aiMessage(let message):
            value.time = message.message.timestamp.map(item.partition.clock)
            value.who = message.message.role
            value.text = join([message.message.text] + message.message.attachments)
        }
        return value
    }

    /// The chat, calendar, list, folder or AI chat an item belongs to, for the search filters.
    static func group(_ item: ArchivedItem, _ context: ViewContext) -> String {
        switch item.payload {
        case .message(let value): return context.chatTitles[value.chatJID] ?? value.chatTitle
        case .event(let value): return value.calendar
        case .reminder(let value): return value.list
        case .note(let value): return "\(value.account) / \(value.folder)"
        case .aiMessage(let value): return context.aiChatTitles["\(item.key.source.rawValue)/\(value.chatID)"] ?? value.chatTitle
        }
    }

    /// Each item's ledger events in order. A re-keyed item takes the history of its old key along.
    static func history(_ events: [LedgerEvent]) -> [ItemKey: [LedgerEvent]] {
        var history: [ItemKey: [LedgerEvent]] = [:]
        for event in events {
            if event.type == .rekeyed, let newKey = event.newKey {
                history[newKey] = (history.removeValue(forKey: event.key) ?? []) + (history[newKey] ?? []) + [event]
            } else {
                history[event.key, default: []].append(event)
            }
        }
        return history
    }

    /// Lifecycle lines for the item detail: added, changed, edited, rescheduled, state changes, reappeared, re-linked, missing.
    static func events(_ events: [LedgerEvent], _ context: ViewContext) -> [Event] {
        var lines: [Event] = []
        var state = LifecycleState.active
        var previous: ArchivedItem?
        for event in events {
            let at = context.moment(event.at)
            switch event.type {
            case .added, .changed:
                guard let item = event.item else { continue }
                if event.type == .added {
                    state = item.state
                    lines.append(Event(at: at, what: "added"))
                } else if case .event(let value) = item.payload, let from = item.flags.rescheduledFrom, from != previous?.flags.rescheduledFrom {
                    lines.append(Event(at: at, what: "rescheduled", detail: CalendarView.labels(item, value).first { $0.hasPrefix("rescheduled") }))
                } else {
                    lines.append(Event(at: at, what: item.flags.edited && previous?.flags.edited != true ? "edited" : "changed"))
                }
                previous = item
            case .stateChanged:
                guard let new = event.state, new != state else { continue }
                let back = ArchivePages.gone(state) && !ArchivePages.gone(new)
                lines.append(Event(at: at, what: back ? "reappeared" : new.rawValue, detail: back ? new.rawValue : event.reason))
                state = new
            case .rekeyed:
                lines.append(Event(at: at, what: "re-linked", detail: "was \(event.key.id)"))
            case .missingPending:
                lines.append(Event(at: at, what: "missing", detail: event.reason))
            case .missingCleared:
                lines.append(Event(at: at, what: "seen again"))
            }
        }
        return lines
    }

    static func manifest(_ context: ViewContext) -> Manifest {
        let records = context.records
        let complete = RunLog.lastComplete(records)
        func month(_ record: RunRecord) -> String { String(context.day(record.start).prefix(7)) }
        let runMonths = Dictionary(grouping: records.filter(\.complete), by: \.source).mapValues { Dictionary(grouping: $0, by: month).mapValues(\.count) }
        let first = Dictionary(grouping: records, by: \.source).mapValues { $0.map(month).min()! }
        let last = records.map(month).max()
        var sources: [Source] = []
        var gone: [Gone] = []
        var groups: [String: Set<String>] = [:]
        var people = Set<String>()
        for source in ArchiveSource.allCases where first[source] != nil || !context.items(source).isEmpty {
            let items = context.items(source)
            var months: [String: [String: Int]] = [:]
            for item in items { months[item.partition.month, default: [:]][item.state.rawValue, default: 0] += 1 }
            let runs = runMonths[source] ?? [:]
            var gaps: [String] = []
            if var month = first[source], let last {
                while month <= last {
                    if runs[month] == nil { gaps.append(month) }
                    month = next(month)
                }
            }
            sources.append(Source(id: source.rawValue, name: source.displayName, items: items.count,
                                  gone: items.filter { $0.state.isTombstone || $0.state == .revoked }.count, pending: items.filter { $0.missingSince != nil }.count,
                                  lastComplete: complete[source].map { context.moment($0.start) }, mode: complete[source]?.mode, months: months, runs: runs, gaps: gaps))
            for item in items {
                groups[source.rawValue, default: []].insert(group(item, context))
                if let message = WhatsAppView.message(item), message.message.isSystem != true { people.insert(message.message.sender) }
                let pending = item.missingSince != nil && !ArchivePages.gone(item)
                guard ArchivePages.gone(item) || pending else { continue }
                gone.append(Gone(key: "\(source.rawValue)/\(item.key.id)", source: source.rawValue, state: pending ? "pending" : item.state.rawValue,
                                 month: item.partition.month, label: ArchivePages.home(item, context).label, text: DisappearedView.summary(item),
                                 link: link(item, context), noticed: context.moment(pending ? item.missingSince! : item.stateSince),
                                 seen: context.lastSeen(item).map(context.moment), reason: pending ? item.missingReason : item.reason))
            }
        }
        // Newest first; ties by key.
        gone.sort { ($0.noticed, $1.key) > ($1.noticed, $0.key) }
        return Manifest(demo: context.demo, updated: records.map(\.start).max().map(context.moment), sources: sources, disappeared: gone,
                        groups: groups.mapValues { $0.sorted() }, people: people.sorted())
    }

    /// The `YYYY-MM` after `month`.
    static func next(_ month: String) -> String {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        return parts[1] == 12 ? String(format: "%04d-01", parts[0] + 1) : String(format: "%04d-%02d", parts[0], parts[1] + 1)
    }
}
