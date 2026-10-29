import Foundation

/// Everything one source read returned in one run, plus what the read covered.
public struct Observation {
    public var source: ArchiveSource
    public var runID: String
    public var at: Date
    /// False when the read failed or was partial. Such reads never count as evidence of absence.
    public var complete: Bool
    public var scope: Scope
    /// Built with `StableKey.items`, so keys are unique within the read.
    public var items: [ArchivedItem]

    public init(source: ArchiveSource, runID: String, at: Date, complete: Bool, scope: Scope, items: [ArchivedItem]) {
        self.source = source; self.runID = runID; self.at = at; self.complete = complete; self.scope = scope; self.items = items
    }
}
