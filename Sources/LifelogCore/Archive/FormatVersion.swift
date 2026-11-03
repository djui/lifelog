import Foundation

/// A JSON line with a format version `v`, such as a ledger event or a run log record.
///
/// Two Macs can share one archive while running different Lifelog versions. A line that the
/// running version cannot fully understand is never treated as damage: it is reported as written
/// by a newer Lifelog, left out of the fold, and the commands that would act on an incomplete
/// fold (writing pages, `rebuild`, `dedupe --apply`) stop until Lifelog is updated.
///
/// Bump `currentVersion` when a change to the line or to a record inside it would be misread by
/// the released versions, such as a renamed or retyped field. Adding an optional field, a payload
/// kind, an event type, a state or a source needs no bump: older versions recognize those as newer
/// on their own (see `newer`). Lines of every earlier version must keep decoding; the fixture tests
/// in `FormatVersionTests` hold lines as released versions wrote them.
protocol Versioned {
    static var currentVersion: Int { get }
    var v: Int { get }
    /// Why a line that does not decode was written by a newer Lifelog, or nil when it is just damaged.
    static func newer(_ line: Data) -> String?
}

extension Versioned {
    static func newer(_ line: Data) -> String? {
        guard let v = (try? JSONLines.decoder.decode(VersionProbe.self, from: line))?.v else { return nil }
        return v > currentVersion ? "format \(v)" : nil
    }
}

private struct VersionProbe: Decodable { var v: Int? }

extension RunRecord: Versioned {
    static let currentVersion = 1
}

extension LedgerEvent: Versioned {
    static let currentVersion = 1

    /// Names in an undecodable event that this version does not know: a newer format, event type,
    /// source, state or payload kind. Decoding only the names keeps damaged lines apart from newer ones.
    static func newer(_ line: Data) -> String? {
        struct Key: Decodable { var source: String? }
        struct Payload: Decodable { var kind: String? }
        struct Item: Decodable { var key: Key?; var state: String?; var payload: Payload? }
        struct Probe: Decodable { var v: Int?; var type: String?; var key: Key?; var newKey: Key?; var state: String?; var item: Item? }
        guard let probe = try? JSONLines.decoder.decode(Probe.self, from: line) else { return nil }
        if let v = probe.v, v > currentVersion { return "format \(v)" }
        if let type = probe.type, LedgerEventType(rawValue: type) == nil { return "event type \(type)" }
        for source in [probe.key?.source, probe.newKey?.source, probe.item?.key?.source].compactMap({ $0 }) where ArchiveSource(rawValue: source) == nil {
            return "source \(source)"
        }
        for state in [probe.state, probe.item?.state].compactMap({ $0 }) where LifecycleState(rawValue: state) == nil { return "state \(state)" }
        if let kind = probe.item?.payload?.kind, !ArchivePayload.kinds.contains(kind) { return "item kind \(kind)" }
        return nil
    }
}

/// Lines a newer Lifelog wrote, found while reading the ledger or the run log.
public struct NewerLines: Codable, Equatable {
    /// `<location>: <what is newer>`, such as `ledger/whatsapp/2026-11.ab12.jsonl:4: format 2`.
    public var lines: [String] = []
    /// Ledger source folders with such lines, by folder name, since a newer source has no `ArchiveSource` here.
    public var sources: Set<String> = []

    public init() {}

    public var isEmpty: Bool { lines.isEmpty && sources.isEmpty }

    mutating func merge(_ other: NewerLines) { lines += other.lines; sources.formUnion(other.sources) }

    /// What to tell the user, or nil when there is nothing newer.
    public var message: String? {
        guard !isEmpty else { return nil }
        let names = sources.sorted()
        let example = lines.first.map { " (first: \($0))" } ?? ""
        return "This archive holds \(lines.count) line\(lines.count == 1 ? "" : "s")\(names.isEmpty ? "" : " for \(names.joined(separator: ", "))") written by a newer version of Lifelog\(example). Update Lifelog on this Mac."
    }

    /// Throws for commands that must see the whole ledger, such as writing pages.
    public func require() throws {
        if let message { throw ExportError.message(message) }
    }
}
