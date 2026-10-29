import Foundation

public struct MergeResult: Equatable {
    public var events: [LedgerEvent] = []
    /// Run warnings, such as a tripped circuit breaker.
    public var warnings: [String] = []

    /// Event counts for the run log: `added`, `changed`, `rekeyed`, `missingPending`, `missingCleared`, `stateChanged.<state>`.
    public var counts: [String: Int] {
        Dictionary(events.map { ($0.type == .stateChanged ? "stateChanged.\($0.state?.rawValue ?? "?")" : $0.type.rawValue, 1) }, uniquingKeysWith: +)
    }
}

/// Lifecycle rules: (previous index, observation) → ledger events. Pure: no I/O, no clock, no Apple APIs.
/// When in doubt it prefers `unknown` over a false `deleted` (decision 12).
public enum Merger {
    /// Above this share of a source's in-scope items vanishing at once, the read is suspected, not the items.
    public static let breakerShare = 0.2
    /// The breaker needs at least this many missing items, so one of three reminders vanishing still counts.
    public static let breakerMinimum = 10
    public static let massDisappearance = "mass-disappearance"
    /// WhatsApp disappearing-message timers. There is no timer column (V3), so they are inferred from age.
    public static let timers: [(label: String, seconds: TimeInterval)] = [("24h", 86_400), ("7d", 7 * 86_400), ("90d", 90 * 86_400)]
    public static let timerTolerance = 0.1

    public static func merge(_ index: ArchiveIndex, _ observation: Observation) -> MergeResult {
        var merge = Run(observation: observation)
        let source = observation.source
        let previous = index.items.filter { $0.key.source == source }

        var observed: [ItemKey: ArchivedItem] = [:]
        var order: [ItemKey] = []
        for item in observation.items {
            guard item.key.source == source, item.payload.source == source else { merge.warn("\(item.key.source.rawValue)/\(item.key.id): not a \(source.rawValue) item, ignored"); continue }
            guard observed[item.key] == nil else { merge.warn("\(source.rawValue)/\(item.key.id): duplicate key in one read, kept the first"); continue }
            observed[item.key] = item
            order.append(item.key)
        }

        // Rule 6: only a complete read is evidence of absence. Archived items are frozen, not exempt.
        var missing: [ArchivedItem] = []
        if observation.complete {
            missing = previous.values
                .filter { observed[$0.key] == nil && !$0.state.isTombstone && observation.scope.contains($0) }
                .sorted { $0.key < $1.key }
        }

        // Rule 7: a missing key plus a new key with the same container and text is one item under a new key.
        var relinked: [ItemKey: ArchivedItem] = [:]
        var pool = Dictionary(grouping: missing) { Relink(container: StableKey.container(of: $0.payload), hash: $0.contentHash) }
            .mapValues { $0.sorted { ($0.scopeDate ?? .distantPast, $0.key) < ($1.scopeDate ?? .distantPast, $1.key) } }
        for key in order where previous[key] == nil {
            let item = observed[key]!
            let relink = Relink(container: StableKey.container(of: item.payload), hash: item.contentHash)
            guard let old = pool[relink]?.first else { continue }
            pool[relink]!.removeFirst()
            relinked[key] = old
        }
        let relinkedOld = Set(relinked.values.map(\.key))
        missing.removeAll { relinkedOld.contains($0.key) }

        for key in order {
            let item = observed[key]!
            if var old = relinked[key] {
                merge.emit(.rekeyed, old.key, newKey: key)
                old.key = key
                merge.update(old, with: item)
            } else if let old = previous[key] {
                merge.update(old, with: item)
            } else {
                merge.add(item)
            }
        }

        if !missing.isEmpty { merge.absent(missing, watched: previous.values.filter { !$0.state.isTombstone && (observed[$0.key] != nil || observation.scope.contains($0)) }.count, index: previous) }

        // Out of scope and older than the live window: frozen, not gone.
        for old in previous.values.sorted(by: { $0.key < $1.key })
        where observed[old.key] == nil && !relinkedOld.contains(old.key) && !old.state.isTombstone && old.state != .archived
            && !observation.scope.contains(old) && observation.scope.hasLeftLiveWindow(old) {
            merge.emit(.stateChanged, old.key, state: .archived, reason: "outside the live window")
        }
        return merge.result
    }

    struct Relink: Hashable { var container, hash: String }

    /// The events of one merge, built in order.
    struct Run {
        let observation: Observation
        var result = MergeResult()

        init(observation: Observation) { self.observation = observation }

        mutating func warn(_ warning: String) { result.warnings.append(warning) }

        mutating func emit(_ type: LedgerEventType, _ key: ItemKey, item: ArchivedItem? = nil, state: LifecycleState? = nil, reason: String? = nil, newKey: ItemKey? = nil) {
            result.events.append(LedgerEvent(type: type, at: observation.at, run: observation.runID, key: key, item: item, state: state, reason: reason, newKey: newKey))
        }

        /// Rule 1. Completed, locked and revoked items start in that state (rule 9).
        mutating func add(_ item: ArchivedItem) {
            var item = item
            item.state = item.payload.observedState; item.stateSince = observation.at; item.reason = nil
            item.firstSeen = nil; item.lastSeen = nil; item.missingSince = nil; item.missingReason = nil
            emit(.added, item.key, item: item)
        }

        /// Rules 2, 8 and 9 for an item seen again, possibly under a new key.
        mutating func update(_ old: ArchivedItem, with item: ArchivedItem) {
            var next = keepLastText(item, old)
            next.flags = old.flags
            let textChanged = next.contentHash != old.contentHash
            if textChanged || StableKey.facets(of: next.payload) != StableKey.facets(of: old.payload) {
                if textChanged { next.flags.edited = true }
                if case .event(let was) = old.payload, case .event(let now) = next.payload {
                    if was.start != now.start || was.end != now.end { next.flags.rescheduledFrom = JSONLines.timestamp.string(from: was.start) }
                    if was.status != now.status { next.flags.statusFrom = was.status ?? "none" }
                    if was.participation != now.participation { next.flags.participationFrom = was.participation ?? "none" }
                }
                next.state = old.state; next.stateSince = old.stateSince; next.reason = old.reason
                next.firstSeen = old.firstSeen; next.lastSeen = nil; next.missingSince = old.missingSince; next.missingReason = old.missingReason
                emit(.changed, next.key, item: next)
            }

            let state = next.payload.observedState
            if old.state.isTombstone {
                emit(.stateChanged, next.key, state: state, reason: "reappeared")
            } else if old.state == .archived {
                emit(.stateChanged, next.key, state: state, reason: "back in scope")
            } else if old.state != state {
                emit(.stateChanged, next.key, state: state, reason: Self.transition(from: old.state, to: state))
            } else if old.missingSince != nil {
                emit(.missingCleared, next.key)
            }
        }

        /// A revoked message or a locked note arrives without its text. The archive keeps the last text it saw (decision 2, V5).
        func keepLastText(_ item: ArchivedItem, _ old: ArchivedItem) -> ArchivedItem {
            var item = item
            switch (item.payload, old.payload) {
            case (.message(var now), .message(let was)) where now.message.isRevoked == true && (now.message.text ?? "").isEmpty:
                now.message.text = was.message.text
                now.message.placeholder = was.message.placeholder
                item.payload = .message(now)
            case (.note(var now), .note(let was)) where now.isLocked == true && now.bodyHTML.isEmpty:
                now.bodyHTML = was.bodyHTML
                item.payload = .note(now)
            default:
                return item
            }
            item.contentHash = StableKey.contentHash(of: item.payload)
            return item
        }

        static func transition(from: LifecycleState, to: LifecycleState) -> String {
            switch (from, to) {
            case (_, .completed): return "completed"
            case (.completed, _): return "reopened"
            case (_, .locked): return "locked"
            case (.locked, _): return "unlocked"
            case (_, .revoked): return "deleted by the sender"
            case (.trashed, _): return "restored"
            default: return "\(from.rawValue) → \(to.rawValue)"
            }
        }

        /// Rules 4 and 5 for in-scope items missing from a complete read. `watched` counts the
        /// source's in-scope, not yet tombstoned items, seen or not.
        mutating func absent(_ missing: [ArchivedItem], watched: Int, index: [ItemKey: ArchivedItem]) {
            let source = observation.source.rawValue
            let tripped = missing.count >= Merger.breakerMinimum && Double(missing.count) > Merger.breakerShare * Double(watched)
            if tripped {
                warn("\(source): \(missing.count) of \(watched) in-scope items missing at once; held as pending and never deleted automatically")
            }
            let timers = similarVanishings(missing, index: index)
            for old in missing {
                if old.missingSince == nil {
                    emit(.missingPending, old.key, reason: tripped ? Merger.massDisappearance : nil)
                } else if tripped || old.missingReason == Merger.massDisappearance {
                    emit(.stateChanged, old.key, state: .unknown, reason: "\(Merger.massDisappearance): missing in two runs, not confirmed as deleted")
                } else {
                    let (state, reason) = tombstone(old, timers: timers)
                    emit(.stateChanged, old.key, state: state, reason: reason)
                }
            }
        }

        func tombstone(_ old: ArchivedItem, timers: [String: Int]) -> (LifecycleState, String) {
            switch old.payload {
            case .message(let value):
                if let label = Merger.timer(age: (old.missingSince ?? observation.at).timeIntervalSince(value.message.timestamp)),
                   timers["\(value.chatJID) \(label)", default: 0] >= 2 {
                    return (.expired, "disappearing message timer (\(label), inferred)")
                }
                return (.deleted, "missing in two complete reads (no disappearing timer matched, inferred)")
            case .event(let event) where event.status == "cancelled":
                return (.deleted, "cancelled, then missing in two complete reads")
            default:
                return (.deleted, "missing in two complete reads")
            }
        }

        /// Per chat and timer, how many messages vanished at that age: the ones missing now,
        /// plus those already expired with that timer. One match alone is a coincidence.
        func similarVanishings(_ missing: [ArchivedItem], index: [ItemKey: ArchivedItem]) -> [String: Int] {
            var counts: [String: Int] = [:]
            for old in missing {
                guard case .message(let value) = old.payload,
                      let label = Merger.timer(age: (old.missingSince ?? observation.at).timeIntervalSince(value.message.timestamp)) else { continue }
                counts["\(value.chatJID) \(label)", default: 0] += 1
            }
            for old in index.values where old.state == .expired {
                guard case .message(let value) = old.payload,
                      let label = Merger.timers.first(where: { old.reason?.contains("timer (\($0.label),") == true })?.label else { continue }
                counts["\(value.chatJID) \(label)", default: 0] += 1
            }
            return counts
        }
    }

    static func timer(age: TimeInterval) -> String? {
        timers.first { abs(age - $0.seconds) <= $0.seconds * timerTolerance }?.label
    }
}
