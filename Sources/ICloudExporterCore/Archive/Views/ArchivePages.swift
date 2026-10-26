import Foundation

/// Everything a page needs: the folded index and the run log. Item times use each item's own stored offset (`Partition`).
/// Lifecycle times (when an item was last seen or noticed gone) are run times, shown in the zone that run recorded,
/// so pages come out the same whichever Mac renders them; `timeZone` is only the fallback and the zone of `now`.
public struct ViewContext {
    public var index: ArchiveIndex
    public var records: [RunRecord]
    public var now: Date
    public var timeZone: TimeZone
    public var demo: Bool
    /// Warnings for the "Health" section of `_index.md` (phase 6).
    public var health: [String]

    let items: [ArchiveSource: [ArchivedItem]]
    /// WhatsApp chat JID → `WhatsApp/<title>--<hash>`, named after the chat's latest title.
    let chatFolders: [String: String]
    let chatTitles: [String: String]
    /// `<source>/<chat id>` → page path and latest title of each AI conversation.
    let aiChatPaths, aiChatTitles: [String: String]
    /// Starts of complete runs per source, oldest first.
    let completeRuns: [ArchiveSource: [Date]]
    /// Run start → the Mac's zone during that run.
    let runZones: [Date: TimeZone]

    public init(index: ArchiveIndex, records: [RunRecord], now: Date, timeZone: TimeZone = .current, demo: Bool = false, health: [String] = []) {
        self.index = index; self.records = records; self.now = now; self.timeZone = timeZone; self.demo = demo; self.health = health
        let items = Dictionary(grouping: index.items.values.sorted { $0.key < $1.key }, by: \.key.source)
        var latest: [String: (date: Date, title: String)] = [:]
        for item in items[.whatsapp] ?? [] {
            guard case .message(let value) = item.payload else { continue }
            if latest[value.chatJID].map({ value.message.timestamp >= $0.date }) ?? true { latest[value.chatJID] = (value.message.timestamp, value.chatTitle) }
        }
        self.items = items
        chatFolders = Dictionary(uniqueKeysWithValues: latest.map { jid, chat in
            (jid, "\(ExportSource.whatsapp.directoryName)/" + MarkdownWriter.hashedName(chat.title, id: jid))
        })
        chatTitles = latest.mapValues(\.title)
        (aiChatPaths, aiChatTitles) = AIChatView.chats(items)
        completeRuns = Dictionary(grouping: records.filter(\.complete), by: \.source).mapValues { $0.map(\.start).sorted() }
        runZones = Dictionary(records.compactMap { record in record.timeZone.flatMap(TimeZone.init(identifier:)).map { (record.start, $0) } }) { a, _ in a }
    }

    func items(_ source: ArchiveSource) -> [ArchivedItem] { items[source] ?? [] }

    // Lifecycle times, in the zone of the run they come from.
    func offset(_ date: Date) -> Int { (runZones[date] ?? timeZone).secondsFromGMT(for: date) }
    func day(_ date: Date) -> String { Partition.day(date, utcOffset: offset(date)) }
    func moment(_ date: Date) -> String { day(date) + " " + Partition.clock(date, utcOffset: offset(date)) }
    func iso(_ date: Date) -> String { Partition.iso(date, utcOffset: offset(date)) }

    /// An item's own time (not its partition date) in the zone of the run that last captured the item, as ISO 8601.
    func captured(_ date: Date, _ item: ArchivedItem) -> String {
        let zone = item.lastSeen.flatMap { runZones[$0] }
        return Partition.iso(date, utcOffset: zone?.secondsFromGMT(for: date) ?? item.partition.utcOffset)
    }

    /// When a gone or missing item was last seen alive. The ledger records only content changes, so this comes from the
    /// run log: a tombstone needs two complete misses, so the item was last seen in the complete run before the first miss.
    /// Live items get nil: their last sighting moves with every run, and pages must not change on every run.
    func lastSeen(_ item: ArchivedItem) -> Date? {
        let runs = completeRuns[item.key.source] ?? []
        if item.state.isTombstone || item.state == .trashed {
            return [runs.filter { $0 < item.stateSince }.dropLast().last, item.lastSeen].compactMap { $0 }.max()
        }
        // A revoked stub is still there; what is gone is the text, last seen in the run before.
        if item.state == .revoked { return runs.filter { $0 < item.stateSince }.last ?? item.lastSeen }
        if let missing = item.missingSince { return [runs.filter { $0 < missing }.last, item.lastSeen].compactMap { $0 }.max() }
        return nil
    }
}

/// One Markdown page: where it goes, which items it shows, and how to render it. Rendering is deferred so an
/// archive run renders only the pages its changes touched.
struct Page {
    var path: String
    var group: String
    var keys: Set<ItemKey>
    /// Rendered on every run, such as `_index.md`.
    var always = false
    var render: () -> String
}

/// Where an item is shown, for links from the Timeline and `_Disappeared`.
struct Home: Hashable {
    var path: String
    var anchor: String?
    var label: String
    /// Singular noun for counts on the Timeline, such as `message`.
    var noun: String
}

public enum ArchivePages {
    static func pages(_ context: ViewContext) -> [Page] {
        var pages = WhatsAppView.pages(context) + CalendarView.pages(context) + RemindersView.pages(context) + NotesView.pages(context)
            + AIChatView.pages(context)
        pages += TimelineView.pages(context) + DisappearedView.pages(context)
        pages.append(IndexView.page(context, paths: Set(pages.map(\.path))))
        return pages
    }

    static func home(_ item: ArchivedItem, _ context: ViewContext) -> Home {
        switch item.payload {
        case .message: return WhatsAppView.home(item, context)
        case .event: return CalendarView.home(item)
        case .reminder: return RemindersView.home(item, context)
        case .note(let note): return NotesView.home(note)
        case .aiMessage: return AIChatView.home(item, context)
        }
    }

    /// Writes the pages. With `touched`, only pages that show a touched item now or showed one in `before` are rendered,
    /// plus pages the manifest does not own yet; the rest are kept as they are. Without it every page is rendered (`rebuild`).
    /// Pages that are no longer produced are removed.
    public static func write(_ context: ViewContext, to store: ExportStore, before: ArchiveIndex? = nil, touched: Set<ItemKey>? = nil) throws -> ExportSummary {
        let pages = pages(context)
        guard Set(pages.map(\.path)).count == pages.count else { throw ExportError.message("Archive page paths collide; no pages were written.") }
        var selected = pages
        if let touched {
            let managed = try store.managedPaths()
            var touched = touched
            var stale = Set<String>()
            if let before {
                let old = ViewContext(index: before, records: context.records, now: context.now, timeZone: context.timeZone, demo: context.demo, health: context.health)
                touched.formUnion(renamedChats(old, context))
                stale = Set(Self.pages(old).filter { !$0.keys.isDisjoint(with: touched) }.map(\.path))
            }
            selected = pages.filter { $0.always || !managed.contains($0.path) || stale.contains($0.path) || !$0.keys.isDisjoint(with: touched) }
        }
        let rendered = Set(selected.map(\.path))
        let documents = selected.map { ExportDocument(path: $0.path, content: $0.render(), group: $0.group) }
        return try store.writePages(documents, keeping: Set(pages.map(\.path)).subtracting(rendered), demo: context.demo)
    }

    /// Every message of a chat whose folder, page or title changed: pages elsewhere (such as older Timeline months) link to it.
    static func renamedChats(_ old: ViewContext, _ new: ViewContext) -> Set<ItemKey> {
        var chats = Set<String>()
        for (jid, folder) in new.chatFolders where old.chatFolders[jid] != folder || old.chatTitles[jid] != new.chatTitles[jid] { chats.insert(jid) }
        for (chat, path) in new.aiChatPaths where old.aiChatPaths[chat] != path || old.aiChatTitles[chat] != new.aiChatTitles[chat] { chats.insert(chat) }
        guard !chats.isEmpty else { return [] }
        var keys = Set<ItemKey>()
        for context in [old, new] {
            for item in ArchiveSource.allCases.flatMap({ context.items($0) }) {
                switch item.payload {
                case .message(let value) where chats.contains(value.chatJID): keys.insert(item.key)
                case .aiMessage(let value) where chats.contains("\(item.key.source.rawValue)/\(value.chatID)"): keys.insert(item.key)
                default: break
                }
            }
        }
        return keys
    }

    // Shared formatting.

    /// Relative link from one page to another, such as `../../Calendar/2026/2026-10.md#2026-10-28`.
    static func link(_ target: String, from page: String, anchor: String? = nil) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#[]()")
        let from = page.split(separator: "/").dropLast(), to = target.split(separator: "/")
        var shared = 0
        while shared < from.count, shared < to.count - 1, from[from.startIndex + shared] == to[shared] { shared += 1 }
        let path = Array(repeating: "..", count: from.count - shared) + to.dropFirst(shared).map(String.init)
        return path.joined(separator: "/").addingPercentEncoding(withAllowedCharacters: allowed)! + (anchor.map { "#\($0)" } ?? "")
    }

    /// One-line text that is safe inside a link label.
    static func label(_ text: String) -> String {
        MarkdownWriter.line(text).replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }

    static func shorten(_ text: String, _ limit: Int = 100) -> String {
        let flat = MarkdownWriter.line(text).trimmingCharacters(in: .whitespaces)
        return flat.count <= limit ? flat : String(flat.prefix(limit - 1)) + "…"
    }

    /// Deleted items are struck through; expired and revoked ones keep their text readable (decision 2).
    static func struck(_ item: ArchivedItem) -> Bool { item.state == .deleted || item.state == .trashed }

    static func gone(_ item: ArchivedItem) -> Bool { item.state.isTombstone || item.state == .revoked || item.state == .trashed }

    /// Inline state labels, such as `deleted 2026-10-20, last seen 2026-10-19`.
    static func badges(_ item: ArchivedItem, _ context: ViewContext) -> [String] {
        var badges: [String] = []
        let noticed = context.day(item.stateSince)
        let seen = context.lastSeen(item).map { ", last seen \(context.day($0))" } ?? ""
        switch item.state {
        case .deleted: badges.append("deleted \(noticed)\(seen)")
        case .expired: badges.append("expired \(noticed)\(item.reason.map { ": \($0)" } ?? "")")
        case .revoked: badges.append("revoked \(noticed)")
        case .unknown: badges.append("unknown since \(noticed)\(seen)")
        case .trashed: badges.append("trashed \(noticed)")
        case .locked: badges.append("locked")
        case .active, .completed, .archived: break
        }
        if let missing = item.missingSince, !gone(item) { badges.append("missing since \(context.day(missing)), not confirmed") }
        if item.flags.edited { badges.append("edited") }
        return badges
    }

    static func suffix(_ badges: [String]) -> String {
        badges.map { " · `\($0.replacingOccurrences(of: "`", with: "'"))`" }.joined()
    }

    static func days(_ items: [ArchivedItem], date: (ArchivedItem) -> String = { $0.partition.date }) -> [(String, [ArchivedItem])] {
        Dictionary(grouping: items, by: date).sorted { $0.key < $1.key }
    }

    /// Groups items into month pages under `folder`: `<folder>/YYYY/YYYY-MM.md`.
    static func months(_ items: [ArchivedItem], folder: String, month: (ArchivedItem) -> String = { $0.partition.month }) -> [(path: String, month: String, items: [ArchivedItem])] {
        Dictionary(grouping: items, by: month).sorted { $0.key < $1.key }.map { ("\(folder)/\($0.key.prefix(4))/\($0.key).md", $0.key, $0.value) }
    }
}
