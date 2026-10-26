# Lifelong archive: implementation plan

Status: plan only, nothing implemented. Date: 2026-10-26. Design and decisions: [lifelong-archive.md](lifelong-archive.md).

Each phase is one PR that leaves `main` releasable. `export` (the mirror) keeps its current behaviour throughout. All new behaviour lives behind a new `archive` command writing to a **new, separate folder**.

Order follows decision 7 (no git stop-gap): **capture first, views later.** Phases 1–4 start preserving data; phase 5 makes it pleasant to read.

---

## Phase 0: verify assumptions on real data (read-only, no PR)

Before writing the merge rules, confirm these against your own Mac. Read schema and metadata only, never message bodies.

| # | Question | How | Affects |
|---|---|---|---|
| V1 | WhatsApp: does `ZWAMESSAGE.ZSTANZAID` exist and stay stable after a WhatsApp Desktop re-link? | `PRAGMA table_info(ZWAMESSAGE)` on a copy | identity (§5 of design) |
| V2 | WhatsApp: message type value for "This message was deleted" (expected `14`) and for edited messages | `SELECT ZMESSAGETYPE, COUNT(*) … GROUP BY 1` | `revoked` state |
| V3 | WhatsApp: columns that carry the disappearing timer (chat-level setting and/or per-message duration/expiry) | `PRAGMA table_info` on `ZWACHATSESSION`, `ZWAMESSAGE`, `ZWAMESSAGEINFO` | `expired` vs `deleted` |
| V4 | Notes: do notes in *Recently Deleted* appear in `account.notes`, and how is that folder named (localized)? | small JXA probe listing folder names + counts | `trashed` state |
| V5 | Notes: are title and dates of password-protected notes readable without unlocking? | JXA probe on one locked note | locked stubs (phase 2) |
| V6 | EventKit: does `calendarItemExternalIdentifier` survive a calendar re-sync, and does a 4-year predicate span still apply on macOS 14+? | test on a throwaway calendar | calendar identity, backfill chunking |
| V7 | WhatsApp Desktop bundle identifier (expected `net.whatsapp.WhatsApp`) | `osascript -e 'id of app "WhatsApp"'` | health check |

Results are in the "Schema notes" section of the design doc. V1–V5 and V7 are done; V6 is documented but untested (it needs a write). Phase 2 code must stay schema-tolerant either way (check that each column exists before using it).

---

## Phase 1: ledger foundation and `archive` command shell

Goal: an append-only, sync-safe ledger with a reader and fold. No source reads yet.

**New files** (`Sources/ICloudExporterCore/Archive/`)

| File | Contents |
|---|---|
| `ArchiveModels.swift` | `ArchiveSource` (reuse `ExportSource`), `LifecycleState` (`active, completed, archived, trashed, deleted, expired, revoked, unknown`), `ItemKey` (source + stable key), `ArchivedItem` (key, nativeID, partition civil date + UTC offset, state, stateSince, lastSeen?, flags such as `edited` and `rescheduledFrom`, `contentHash`, payload enum wrapping the existing record structs). |
| `Ledger.swift` | JSONL event types: `added`, `changed`, `stateChanged`, `rekeyed`, `missingPending`, `missingCleared`. Writer: `O_APPEND`, one JSON object per line, `fsync` after each run's batch. Files: `.archive/ledger/<source>/<YYYY-MM>.<host-id>.jsonl`, partitioned by **append month**. The host suffix keeps two Macs from writing the same file. Reader: tolerates a torn last line (ignored and reported by `verify`), merges all host files in timestamp order. |
| `RunLog.swift` | `.archive/runs/<YYYY-MM>.<host-id>.jsonl`, one line per source per run: run id, start/end, `complete: Bool`, scope description, counts, warnings. This is where `last_seen` comes from: an item present in the latest complete run covering it was "seen" then. There's no per-item `last_seen` rewrite, so the ledger stays append-only. |
| `ArchiveIndex.swift` | In-memory fold of the ledger into `[ItemKey: ArchivedItem]`. A cache at `~/Library/Caches/com.djui.icloud-exporter/<archive-path-hash>/index.json` is keyed by ledger file sizes and mtimes. A miss means a full refold. Nothing mutable lives in the synced folder. |
| `ArchiveLock.swift` | Extract the `flock` logic from `ExportStore.write` so `archive`, `rebuild` and `verify` share it. |

**Changed files**

| File | Change |
|---|---|
| `Config.swift` | Split into `Command` (`export`, `archive`, `rebuild`, `verify`) + per-command options. `archive` options: `--output`, `--sources`, `--backfill-since YYYY-MM-DD` (default `2000-01-01`), `--rescan-days` (default 100, more than the longest WhatsApp timer of 90 d), `--full-sweep-days` (default 7), `--notify`, `--demo`. Update `help`. |
| `ICloudExporter.swift` | Dispatch on `Command`. Move the current body into `runExport`, and add a stub `runArchive`. |
| `ExportStore.swift` | Use `ArchiveLock`. Refuse an output that contains `.archive/` (and `archive` refuses an output that contains `.icloud-exporter-manifest.json` at the root), so archive and export folders can't be mixed up. |

**Tests**: `Tests/…/LedgerTests.swift` (append/read roundtrip, torn last line, two hosts interleaved, fold idempotence); `ConfigTests` cases for the new commands.

---

## Phase 2: wider, identity-stable readers

Goal: readers return **everything in scope** with stable keys and the extra fields lifecycle needs. Export output must stay byte-identical (existing tests guard this).

| File | Change |
|---|---|
| `Models.swift` | Add optional fields so `export` is unaffected. **Note**: `isLocked`, `isTrashed`. **Reminder**: `externalID`, `created`, `modified`. **Calendar**: `externalID`, `status` (confirmed/tentative/cancelled), `participation` (my attendee status), `created`, `modified`. **WhatsApp message**: `stanzaID`, `rawType`, `isRevoked`, `isEdited?`, `ephemeralDuration?`. **WhatsApp chat**: `isRemoved`, `isHidden`, `ephemeralSetting?`. |
| `WhatsAppExporter.swift` | Add `fetchArchive(since:now:)`: **all** sessions of type 0/1, including `ZREMOVED`/`ZHIDDEN` (flagged, not filtered), no chat limit. Messages since `since` of **every type**: text types 0, 7, 41–43 as messages; 6/10 as system events; 14 as `isRevoked` with an empty body; any other type as a placeholder with its type number. Read `ZSTANZAID` and `ZSENTDATE`. Keep a `hasColumn(table:column:)` helper so schema drift degrades gracefully. The existing `read` stays for `export`. |
| `EventKitExporter.swift` | `events(from:to:)` becomes chunked (≤ 4-year spans, V6) with dedupe by occurrence id. Fill the new fields (`calendarItemExternalIdentifier`, `status`, current-user attendee `participantStatus`, `creationDate`, `lastModifiedDate`). `reminders(completedSince: Date?)`: `nil` means all completed (for backfill and full sweep). |
| `Resources/notes.js` | Emit locked notes as **stubs** (id, title, folder id + path, dates, `locked: true`, no body) instead of skipping them. V5 confirmed title, dates and folder are readable. Otherwise a note that becomes locked would look deleted. Also emit the folder id, because two folders can share a name. No Recently Deleted detection: V4 showed scripting doesn't expose it, so trashed notes simply go missing. |
| `NotesExporter.swift` | Decode the new fields. `MarkdownWriter` keeps skipping locked stubs for `export`, so export output doesn't change. |

**Tests**: extend `WhatsAppExporterTests` fixtures (removed chat, revoked message, stanza ids, missing optional columns); `EventKitExporterTests` for chunk boundaries and dedupe; `NotesTests` for locked stubs and trashed detection in `decode`; a regression test that `export` output is unchanged.

---

## Phase 3: merge engine (lifecycle rules)

Goal: a pure function from (previous index, observation) to ledger events, fully unit-tested without Apple APIs.

| New file | Contents |
|---|---|
| `Archive/Observation.swift` | `Observation { source, runID, at, complete, scope, items: [ArchivedItem] }`. |
| `Archive/Scope.swift` | Per-source "would this item have been read?" predicate. **WhatsApp**: message date ≥ rescan cutoff (or backfill), chat present in this read. **Calendar**: occurrence start inside the read window. **Reminders**: incomplete always; completed if completion date ≥ cutoff (all on a full sweep). **Notes**: always (every read is full). Items outside scope stay untouched; if their date has left the live window, they're promoted to `archived`. |
| `Archive/Merger.swift` | Rules below. |
| `Archive/StableKey.swift` | Key derivation. **WhatsApp**: chat JID + `ZISFROMME` + `ZSTANZAID` (V1: stanza ids aren't globally unique), adding the message date on a collision. **Calendar**: external id + occurrence date. **Reminders**: external id. **Notes**: Core Data id. Plus the content hash (normalized text fields). |

**Merger rules** (decisions 4, 9, 11, 12):

1. **New key** → `added`.
2. **Same key, different hash** → `changed`. Store the new current content only (decision 9). For calendar, keep `rescheduledFrom` when start/end moved, and status/participation changes as flags (decision 11). For WhatsApp, a message turning into the revoked type → `stateChanged(revoked)`, **keeping the last-seen text** (decision 2).
3. **Note moved into Recently Deleted** → `stateChanged(trashed)`; moved back → `active`.
4. **Missing, in scope, complete read**:
   - first miss → `missingPending` (no visible change yet);
   - second consecutive complete miss → `stateChanged` with a reason. **WhatsApp**: there's no timer column (V3), so `expired` is inferred when the message's age at disappearance is close to 24 h, 7 d or 90 d (±10%) and other messages in that chat vanish the same way; else `deleted`. The reason text says "inferred". **Others**: `deleted`, or a Calendar `cancelled` status seen earlier is kept as the reason.
5. **Circuit breaker**: if > 20% of in-scope items of a source go missing in one run (minimum 10 items), emit nothing destructive. Mark them `missingPending` with reason `mass-disappearance` and a run warning. They become `unknown` after two such runs and never become `deleted` automatically.
6. **Incomplete read** (`complete == false`) → only `added`/`changed`, never a miss.
7. **Re-link**: a missing key plus a new key with the same source, container (chat/calendar/list/folder) and content hash in the same run → `rekeyed`, not a tombstone + duplicate.
8. **Resurrection**: a tombstoned key seen again → `stateChanged(active)` with reason `reappeared`.
9. **Reminders**: completion is a state (`completed`), not a disappearance.

**Tests**: `MergerTests.swift`, table-driven, one case per rule plus combinations (re-link + breaker, revoke then expire, resurrection after a full sweep).

---

## Phase 4: `archive` end-to-end, capture starts here

Goal: scheduled runs append to the ledger. Views are minimal (only `_index.md` with run status), so this phase can ship fast and stop the losses.

| File | Change |
|---|---|
| `Archive/Archiver.swift` (new) | For each selected source: decide the read mode, then read → `Observation` → `Merger` → append ledger + run log → update the index cache. **Read modes**: *backfill* when the source has no complete run yet (`--backfill-since` → +2 years, all chats, all completed reminders); *full sweep* when the last full sweep is older than `--full-sweep-days`; otherwise *rescan* (`--rescan-days`). A read failure records `complete: false` and the remaining sources continue (same pattern as the `export` loop). |
| `ICloudExporter.swift` | `runArchive` wires `Archiver` and prints a summary (`added`, `changed`, `tombstoned`, `pending`, warnings). |
| `Demo.swift` | `archive --demo` uses two synthetic observations so a demo shows tombstones, revoked and expired items. CI already runs a demo export, so add an archive demo step to `.github/workflows/ci.yml`. |
| `launchd/com.djui.icloud-exporter.archive.plist.example` (new) | Two agents are suggested: `--sources whatsapp,reminders,calendar` every 600 s, and `--sources notes` every 3600 s (Notes reads take minutes). They share the lock. |

**Tests**: an `ArchiverTests` integration test with an injected fake reader per source (protocol `ArchiveReader`) covering backfill → rescan → full sweep transitions and failure isolation.

**Ship gate**: run it on your Mac for a week in parallel with the existing `export`, then compare counts.

---

## Phase 5: date-structured views

Goal: Markdown pages regenerated from the index, laid out as decided (month files + Timeline, deleted items in place + digest, notes by account/folder).

| File | Change |
|---|---|
| `Archive/Partition.swift` (new) | Civil date from instant + stored UTC offset (decision 15). **WhatsApp**: Mac timezone at capture, recorded in the run log. **Calendar**: event timezone or civil date for all-day. **Reminders**: completion date if completed, else creation date. |
| `Archive/Views/WhatsAppView.swift` | `WhatsApp/<chat>--<jid-hash>/_chat.md` + `YYYY/YYYY-MM.md`. Day headings. Inline state badges (`expired …`, `revoked …`, `edited`). Removed chats get a banner. |
| `Archive/Views/CalendarView.swift` | `Calendar/YYYY/YYYY-MM.md` by occurrence start. Deleted events struck through. Labels for cancelled, declined/tentative and `rescheduled from`. |
| `Archive/Views/RemindersView.swift` | `Reminders/open.md` + `Reminders/YYYY/YYYY-MM.md` by completion (or deletion) month (decision 10). |
| `Archive/Views/NotesView.swift` | Same paths as `export` (account/folder/title--hash). Front-matter `state`, `last_seen`, `noticed`. Trashed/deleted notes stay in place with a banner (decision 8). |
| `Archive/Views/TimelineView.swift` | `Timeline/YYYY/YYYY-MM.md`: per day, links into the month files for messages, events, reminders done, and notes created or edited. |
| `Archive/Views/DisappearedView.swift` | `_Disappeared/YYYY/YYYY-MM.md`: every transition to `trashed/deleted/expired/revoked/unknown` that month, grouped by source, with links. |
| `Archive/Views/IndexView.swift` | `_index.md`: last complete run per source, health warnings (phase 6), links to the current month. |
| `MarkdownWriter.swift` | Make `yaml`, `line`, `safeComponent`, `digest` and `messageBody` `internal static` helpers the views can share (currently mostly `static` in the same enum, so this is just access, no logic changes). |
| `ExportStore.swift` | Generalize `Entry.source` to a **group** string so non-source top-level directories (`Timeline`, `_Disappeared`) validate. Keep the digest/ownership/journal logic as is. Views are derived, so stale removal stays correct. Only changed month files are rewritten (already true via digest compare). |
| `Archiver.swift` / `ICloudExporter.swift` | `archive` renders affected months after merging. `rebuild` renders everything from the ledger. |

**Tests**: golden-file tests per view (`Tests/…/ArchiveViewTests.swift`), a partition test across DST and travel offsets, and a `rebuild` test showing it produces the same pages as incremental runs.

---

## Phase 6: health, notifications, `verify`

| File | Change |
|---|---|
| `Archive/Health.swift` (new) | From the run log: time since the last complete WhatsApp run; whether WhatsApp Desktop is running (`NSWorkspace.runningApplications`, bundle id per V7); repeated read failures. Produces warnings for `_index.md`. |
| `Sources/ICloudExporter/Notifier.swift` (new) | `UNUserNotificationCenter` from the signed app (decision 17). Notifies when (a) no complete WhatsApp read for 20 h, an early warning before the 24 h timer, or (b) a gap > 24 h happened, with the "possible loss between X and Y" window recorded in the run log and `_Disappeared`. At most one notification per gap. Enabled with `--notify`. |
| `Support/Info.plist` | Add a notification usage string if required. Confirm the permission prompt shows with the existing bundle identity. |
| `Archive/Verifier.swift` (new) + `verify` command | Parse every ledger line, report torn lines, duplicate or conflicting events, keys that never fold cleanly, and view files whose digest doesn't match a fresh render. Exits non-zero on problems. |

**Tests**: `HealthTests` with synthetic run logs; `VerifierTests` with corrupted fixtures.

---

## Phase 8: static HTML viewer (see, read, search)

Decisions: a **static, offline HTML viewer** generated next to the archive, used on the **Mac only**, showing **coverage, disappeared items, search and timeline**. There's no server, no network and no third-party libraries. It's plain JS and CSS, matching the repo's zero-dependency rule. Depends on phase 5 (partitioning and the index fold).

**Why `.js` data files and not JSON:** browsers block `fetch()` of local files opened via `file://`. Data is shipped as small scripts (`window.ARCHIVE.load({...})`) loaded with `<script>` tags, which work offline from the folder.

**Generated layout** (written by `archive` for changed months, and by `rebuild` for everything, through `ExportStore` as group `viewer`):

```text
_viewer/
  index.html              # static, copied from resources
  app.js, style.css       # static, copied from resources
  data/
    manifest.js           # sources, months, counts per source × month × state, runs, gaps, disappeared list, people/chats/calendars/lists/folders
    whatsapp/2026-10.js   # items of that month: key, date, state, flags, sender, text, link to the Markdown month file, lifecycle events
    calendar/2026-10.js
    reminders/2026-10.js
    notes/2026-10.js      # partitioned by modified month for the viewer only
```

**Screens**

| Screen | Content |
|---|---|
| Coverage | Heatmap of sources × months (count per cell; colour for items that are still active vs disappeared). Last complete run per source. Capture gaps from the run log are shown as hatched cells. Click a cell to open that month in the Timeline. |
| Disappeared | Newest first: deleted, expired, revoked, unknown and pending items. Filter by source/state. Each row shows last seen → noticed, the last known text, and a link. |
| Search | Full-text search over the loaded month chunks with filters (source, chat/person, calendar/list/folder, state, date range). Results grouped by day, with terms highlighted. Chunks load lazily, newest first. A search across everything loads them all (text-only archive: expected < 2 s for tens of MB; measure in phase 4 and add a prebuilt token index per month if slower). |
| Timeline | Day-by-day across sources: messages per chat (collapsed), events, reminders completed, notes created or edited. Disappeared items are shown inline with their badge. |
| Item detail | Full text plus the lifecycle history from the ledger (added, changed, rescheduled, revoked, expired, re-linked, reappeared) with dates. Links to the Markdown file. |

**Files**

| File | Change |
|---|---|
| `Sources/ICloudExporterCore/Resources/viewer/index.html`, `app.js`, `style.css` (new) | The static app. Hash-based routing (`#/coverage`, `#/search?q=…`) so it works from `file://`. A CSP meta tag blocks all network access (`default-src 'none'` + self scripts and styles). Light/dark via `prefers-color-scheme`. |
| `Archive/Views/ViewerData.swift` (new) | Builds `manifest.js` and the month chunks from the index fold and run log. Data is JSON-encoded inside a fixed `window.ARCHIVE.load(...)` wrapper. Only months changed in this run are rewritten. |
| `Archive/Archiver.swift`, `ICloudExporter.swift` | Render the viewer after the Markdown pages. Add `--no-viewer` to skip it. Add an `open` convenience (`icloud-exporter open --output …` → opens `_viewer/index.html` in the default browser). |
| `ExportStore.swift` | Allow the `viewer` group and `.js`/`.css`/`.html` suffixes. Today's validation only accepts `.md`. |
| `Package.swift` | `viewer/` is already covered by `resources: [.process("Resources")]`. Switch to `.copy("Resources/viewer")` if processing flattens the folder. |

**Tests**: `ViewerDataTests` (chunks parse as JSON after stripping the wrapper, only changed months rewritten, escaping of `</script>`-like text and U+2028), plus a CI smoke step that runs `archive --demo` and checks `_viewer/index.html` and `data/manifest.js` exist. A real browser test is optional later (no headless browser in CI today).

**Privacy**: the viewer holds the same plain text as the Markdown, including expired messages, so it carries the same sensitivity. It makes no network requests.

---

## Phase 9: ChatGPT and Claude chats

**Decided (2026-10-26): route A + B.** Official ChatGPT and Claude exports are imported from an inbox folder, and Claude Code transcripts are read locally. Route C is rejected.

Neither service keeps a readable local copy of your chats the way WhatsApp Desktop does. The ChatGPT macOS app encrypts its local cache, and the Claude desktop app is a web client with server-side history. There are three realistic routes:

| Route | Source | Pros | Cons |
|---|---|---|---|
| **A. Official data exports** (recommended) | ChatGPT: Settings → Data controls → Export data. Claude: Settings → Privacy → Export data. Both email a zip with a `conversations.json` (format to verify on a real export). | Supported, complete (all chats, full text), no credentials in the tool. A complete export is a **complete read**, so a chat missing from a newer export is `deleted` under the usual rules. | Manual: you request the export and download the zip. The cadence is however often you export (e.g. monthly), so a chat created and deleted between two exports is never seen. |
| **B. Claude Code transcripts** | `~/.claude/projects/*/*.jsonl` (local, written by Claude Code and the desktop app's Code tab) | Fully local, automatic, every 10 min like WhatsApp | Covers only Claude Code sessions, not claude.ai chats. Large tool output needs trimming. |
| **C. Unofficial web APIs with a session cookie** | chatgpt.com / claude.ai private endpoints | Automatic, near real-time | Against the terms of service, breaks often, and stores a login token. **Not recommended.** |

**Shape (A + B)**

| File | Change |
|---|---|
| `Models.swift` | `ExportSource` gains `chatgpt`, `claude`, `claudecode`. New `AIChatRecord { id, title, created, updated, model?, project?, messages: [role, timestamp, text, attachmentPlaceholders] }`. |
| `Archive/Importers/AIExportImporter.swift` (new) | Watches an **inbox folder** (`--ai-inbox`, default `~/Downloads`) for new ChatGPT/Claude export zips (matched by structure, not filename). Unpacks them to a private temp dir, parses `conversations.json`, and records the zip's digest in the run log so the same export is never imported twice. Each import is one complete observation of that service. Zips are **left in place** by default; a `--ai-inbox-cleanup` flag can delete them after a successful import. |
| `Archive/Importers/ClaudeCodeReader.swift` (new) | Reads the session JSONL files: user and assistant text turns, while tool calls and results become one-line placeholders (tool name and size). Incremental by file size and offset. |
| `Archive/Views/AIChatView.swift` (new) | `ChatGPT/YYYY/YYYY-MM/<title>--<id>.md`, partitioned by **creation month** (a chat is one conversation), with updated chats re-rendered. Same states and badges, and included in Timeline, `_Disappeared` and the viewer. |

**Notes**
- Manual export cadence is accepted. A chat created and deleted between two exports is never seen. `_index.md` and the viewer show the date of the last import per service, so a stale import is visible.
- Claude Code transcripts are included and contain work code and tool output. Tool results stay as one-line placeholders to keep size and sensitivity down.
- Still to verify on a real export before coding: the exact `conversations.json` structure of each service (branches and edits in ChatGPT's message tree, attachments in Claude's export).
- Phase order: after phase 8. It reuses the ledger, merger and views unchanged; only readers and one view are new.

---

## Phase 7: docs

| File | Change |
|---|---|
| `README.md` | New "Lifelong archive" section: `archive`/`rebuild`/`verify`, folder layout, states and their meaning, the "absence ≠ deletion" rules, launchd setup for two agents. A **privacy note**: the archive keeps other people's expired/revoked messages in plain text in your synced folder (decision 6). Limitations: messages that expire before a run sees them are unrecoverable; media are placeholders. |
| `docs/plans/lifelong-archive.md` | Link to this file; schema notes from phase 0. |

---

## Size and order at a glance

| Phase | PR | Rough size | Starts preserving data? |
|---|---|---|---|
| 0 | none | probes only | no |
| 1 | ledger + CLI shell | ~400 LOC + tests | no |
| 2 | wider readers | ~350 LOC + fixtures | no |
| 3 | merge engine | ~350 LOC + many table tests | no |
| 4 | archive end-to-end | ~250 LOC | **yes** |
| 5 | views | ~600 LOC + golden tests | (readable) |
| 6 | health / notify / verify | ~300 LOC | (safer) |
| 8 | static HTML viewer | ~400 LOC Swift + ~800 LOC JS/CSS | (browsable, searchable) |
| 9 | ChatGPT/Claude exports + Claude Code transcripts | ~500 LOC + fixtures | (new sources) |
| 7 | docs (last, covers the viewer and AI chats too) | n/a | n/a |

Phases 1–3 have no Apple dependency except phase 2's readers, so they can be developed and tested entirely with fixtures. Phase 4 is the first time your real data flows into the archive.

## Risks to watch during implementation

- **Index refold cost**: years of WhatsApp text may be tens of MB of JSONL. Measure fold time in phase 4. If it's above ~2 s, snapshot the fold into the cache more aggressively (never into the synced folder).
- **Drive and append**: Google Drive re-uploads the whole current-month file on each change. Fine at text sizes. If uploads churn, switch the partition to per-day for the current month only.
- **Notes runtime**: a full Notes read every hour can take minutes. Keep it on its own agent so WhatsApp's 10-minute cadence never waits behind it.
- **False tombstones from schema drift** (WhatsApp updates): column checks + the circuit breaker + two-run confirmation are the defence. `verify` and `_Disappeared` make mistakes visible and reversible (resurrection).
