# Lifelong archive: never lose an item, mark what vanished

Status: proposal, nothing implemented. Date: 2026-10-26. Implementation plan: [lifelong-archive-implementation.md](lifelong-archive-implementation.md).

## 1. Where data is lost today

The exporter is a **mirror**, not an archive. Every run rewrites the selected sources and deletes files that are no longer produced (`ExportStore.write` removes `previous.files` entries missing from `next`). So data leaves the export for two different reasons:

| Cause | Notes | Reminders | Calendar | WhatsApp |
|---|---|---|---|---|
| Deleted / expired at the source | user delete; 30 days in *Recently Deleted*, then gone | deleted reminder disappears from EventKit | deleted / cancelled event disappears | disappearing messages (24 h / 7 d / 90 d), "deleted for everyone", cleared or removed chats (`ZREMOVED` sessions are filtered out) |
| Falls out of **our own window** | – | completed > `--completed-days` (30) | outside `--past-days` / `--future-days` (365) | older than `--past-days`; not in the 20 most active chats |
| Edited (old version lost) | every edit overwrites the file | title/due/notes changes | reschedules, moves | edited messages |
| Filtered by type | locked notes | – | – | system/revoked message types (only types 0,1,2,3,4,5,8 are read) |

The second row is self-inflicted and is the cheapest win: even if nothing were deleted at the source, a 2-year-old calendar event or the 21st chat is already absent from the export.

## 2. Core idea: separate *observing* from *presenting*

```
 Apple / WhatsApp  ──read──▶  Observation (this run)  ──merge──▶  Ledger (append-only, source of truth)
                                                                      │
                                                                      └──render──▶  Markdown views (disposable, date-structured)
```

- **Ledger**: every record ever seen, with `first_seen`, `last_seen`, content versions, and lifecycle state. Nothing is ever removed from it. Only the merge step writes to it, and only by appending.
- **Views**: Markdown regenerated from the ledger. Can be thrown away and rebuilt, re-laid out by date, filtered, etc. The current "refuse to overwrite edited files" rule stays for views.

This turns "deleted at source" from a file deletion into a **state transition** on a record.

## 3. Lifecycle vocabulary

One shared set of states, with source-specific reasons:

| State | Meaning | Examples |
|---|---|---|
| `active` | seen in the latest complete read | – |
| `edited` | active, but content changed since first seen (versions kept) | note edited, event rescheduled, WA message edited |
| `completed` | finished, still exists at source | completed reminder |
| `archived` | still exists but we stopped re-reading it (outside the live window); frozen, not deleted | event 3 years ago, completed reminder from 2024 |
| `trashed` | in a recoverable bin at source | note in *Recently Deleted* |
| `deleted` | gone from source, within scope, after a complete read | reminder/event/note deleted |
| `expired` | vanished due to a timer | WA disappearing message |
| `revoked` | sender replaced it with a "deleted" stub | WA "This message was deleted" |
| `unknown` | absent, but we cannot prove why (scope changed, read incomplete) | permission lost, chat now outside top-N |

Every non-`active` record carries `state_since` (when we noticed) and `last_seen` (last time we saw it alive). The truthful claim is "disappeared between `last_seen` and `state_since`", not an exact deletion time — Apple does not give us one.

## 4. The hard part: absence ≠ deletion

A missing item only becomes `deleted`/`expired` when **all** hold:

1. The source read finished successfully (no timeout, no permission error, no warning that says data was partial).
2. The item would be **in scope** of this read (its date still inside the read window, its chat/list/calendar/folder was read).
3. A **circuit breaker** did not trip: if, say, > 20 % of a source's in-scope records vanish at once, treat it as a read problem (logged out of WhatsApp, iCloud account removed, Notes timeout), mark them `unknown`, and warn loudly.
4. Optionally: absent in **two consecutive** complete reads (protects against sync flapping on iCloud).

Otherwise the item stays in its last state, or `unknown`. A later sighting resurrects it (and records that).

## 5. Identity (what is "the same record"?)

Tombstones are only as good as IDs. Current IDs and their risks:

- **Notes**: Core Data `x-coredata://…` id. Changes if a note moves between accounts or iCloud is re-set-up.
- **Reminders / Calendar**: `calendarItemIdentifier` is local and can change after a re-sync; `calendarItemExternalIdentifier` survives re-sync but can collide (and recurring occurrences share it). Need a composite (`external id + occurrence date`), with a fuzzy fallback (title + start + calendar) for re-linking.
- **WhatsApp**: `Z_PK` changes when the DB is rebuilt (reinstall, re-link of WhatsApp Desktop). The WhatsApp message id (`ZSTANZAID`, to verify) is stable across rebuilds; chat id should be the JID, not `Z_PK`.

Plan: store both a stable key and the native id, and a re-link pass that merges "deleted A + new B" pairs with identical content within one run instead of producing a tombstone plus a duplicate.

## 6. Ledger storage options

| Option | Pros | Cons |
|---|---|---|
| **A. JSONL per source per month** (`.ledger/whatsapp/2026-10.jsonl`) | append-only, human-greppable, sync-client friendly (past months never change), easy to back up | needs an index rebuilt on start; no ad-hoc queries without tooling |
| **B. SQLite** (one file) | real queries, versions, fast merges; ships with macOS, no deps | a live SQLite file inside Google Drive / iCloud Drive can corrupt; must live in a local dir and be backed up separately |
| **C. Git repo of the Markdown** | zero new code to start: commit after each run; history and diffs for free | deletions are only visible via git archaeology; doesn't fix the window problem; `.git` inside a Drive-synced folder is a bad idea |

Recommendation: **A** for the archive (it is the format most likely to still be readable in 30 years), with an in-memory or cache index. Use **C today** as a stop-gap safety net while this is built (see §9, phase 0).

## 7. Date-structured layout

Principle: **partition by the date an item belongs to; closed periods become immutable files.** That makes slicing easy (`2026/2026-10*`), keeps sync churn low, and lets an AI tool load "October 2026" without the rest.

```text
Archive/
  _index.md
  Timeline/
    2026/
      2026-10.md                # month digest across all sources, links into the files below
      2026-10-26.md             # optional daily journal: messages, events, reminders done, notes touched
  WhatsApp/
    <chat>--<jid-hash>/
      _chat.md                  # participants, chat-level state (removed? ephemeral setting history)
      2026/2026-10.md           # messages by month; expired/revoked/edited marked inline
  Calendar/
    2026/2026-10.md             # by start date; deleted/rescheduled events stay, struck through + reason
  Reminders/
    open.md                     # living view: currently open
    2026/2026-10.md             # by completion date (or deletion date); history of changes
  Notes/
    <account>/<folder>/<title>--<hash>.md   # current text + state header
    <account>/<folder>/<title>--<hash>/versions/2026-10-26T1012.md
  _Disappeared/
    2026/2026-10.md             # every state change to deleted/expired/revoked/trashed that month, across sources
  .ledger/…                     # source of truth (§6)
```

Which date a record belongs to:

| Source | Partition date | Why |
|---|---|---|
| WhatsApp message | message timestamp | conversation is chronological |
| Calendar event | start date (per occurrence) | "what happened in March" |
| Reminder | completion date if done, else creation date; open ones also in `open.md` | open reminders have no natural home |
| Note | **not** date-partitioned by path (notes are living docs); versions by modified date; Timeline lists "notes edited this day" | moving notes between month folders on every edit would be churn |

## 8. How "deleted" looks in Markdown

In-place, never hidden, consistent across sources:

```markdown
---
state: expired
last_seen: 2026-10-25T21:40:00+01:00
noticed: 2026-10-26T08:10:00+01:00
reason: disappearing message timer (24h)
---
```

Inline for messages/events:

```markdown
- 21:14 **Anna**: see you at 8 · `expired 2026-10-26 (24h timer)`
- ~~10:00–11:00 Dentist~~ · `deleted 2026-10-20, last seen 2026-10-19`
- 09:00–10:00 Standup · `rescheduled from 08:30 on 2026-10-12`
```

Plus a per-month `_Disappeared/` digest so you can review losses without hunting.

## 9. Phased plan

0. **Stop-gap (no code)**: export into a local git repo and commit after each launchd run; back it up. Keeps snapshots while the rest is built. Caveat: only covers what the current windows export.
1. **Widen capture, incrementally**: high-water marks per source instead of rolling windows; all WhatsApp chats (not top 20), including removed/hidden chats and revoked messages; one-off full Calendar backfill (EventKit limits a single predicate to ~4 years → chunked); all completed reminders once, then incremental; include Notes *Recently Deleted* as `trashed`.
2. **Ledger + merge**: record model with stable keys, `first_seen`/`last_seen`, content hash, versions; append-only writer with the existing lock/journal discipline.
3. **Absence detection**: complete-read flag per source, scope check, circuit breaker, two-run confirmation, resurrection, re-linking.
4. **Date-partitioned views** + Timeline + `_Disappeared` digest; frozen closed months.
5. **Health**: run log in the ledger; warn when the last successful WhatsApp read is older than the shortest disappearing timer in use (24 h) — that's a guaranteed-loss window; status line in `_index.md`.
6. **Migration**: import existing export folders as the initial ledger observation (state `unknown` for anything we cannot date).

## 10. Risks and limits worth knowing up front

- **Capture only wins if it runs before the timer**: a 24 h disappearing message is lost if the Mac is asleep/off or WhatsApp Desktop hasn't synced for 24 h. Cadence and a "WhatsApp Desktop is running" check matter more than code.
- **Messages deleted before we ever saw them** are unknowable. We record gaps, not contents.
- **Media**: today only placeholders. A lifelong archive of text without photos/voice notes may disappoint; media changes the storage budget by orders of magnitude.
- **Privacy & consent**: disappearing messages are the other person's choice. Keeping them is legal for personal use in most places but the archive becomes very sensitive. Consider where it syncs and whether it should be encrypted (e.g. ledger in an encrypted APFS volume/sparsebundle, views without expired content).
- **Unofficial WhatsApp schema** can change with any update; ledger design must tolerate partial reads without false tombstones (§4).
- **Storage growth** is unbounded by design; text-only is small (MBs/year), media is not.

## Decisions so far

| # | Decision | Consequence |
|---|---|---|
| 1 | Personal memory archive, not evidence-grade | No hash chain or signing. Timestamps are best-effort. |
| 2 | Expired/revoked WhatsApp messages keep their **full text**, marked | Archive is sensitive, so sharing settings of the synced folder matter. |
| 8 | Vanished items stay **in place + monthly `_Disappeared/` digest** | As in §8. |
| 5 | Ledger lives **in the synced folder** next to the views | Rules out SQLite (option B). Ledger = JSONL month files (option A). Closed months are never rewritten, and the current month is append-only, so the sync client never sees a half-written database. A git stop-gap (phase 0) must not live in that folder. |
| 4 | **Backfill everything** once, then incremental | Phase 1 starts with a one-off full read: chunked calendar history, every chat in the local WhatsApp DB, all completed reminders. |
| 3 | Media stays **placeholders** | Text-only archive (MBs/year). Placeholders should still record type, file name and size so a gap is visible. |
| 9 | **Current + deleted only**, no full version history | Drop `versions/` from §7. A record keeps its latest observed text, which is also the text kept when it disappears. Edits are flagged (`edited`, `rescheduled from …`), but earlier text is not kept. |
| 13/14 | **Month files + cross-source Timeline** | Layout as in §7, minus note versions. |
| 12 | Prefer **`unknown` over false `deleted`** | §4 rules apply in full: circuit breaker at about 20%, plus two consecutive complete reads before a tombstone. |
| 15 | **Local timezone at the time**, stored with its offset | Calendar events carry their own timezone. WhatsApp timestamps don't, so the day is assigned with the Mac's timezone at capture time. That's correct for live capture but only approximate for backfilled history from travel periods. |
| 17 | **macOS notification** when the last successful WhatsApp read is older than 24 h | Phase 5 gains a notifier (`osascript display notification` or UserNotifications from the signed app). |
| 18 | **Start fresh** in a new folder, and leave old exports untouched | Phase 6 (migration) is dropped. |

| 6 | **No extra encryption.** The archive relies on Google account security and FileVault | Mention in the README that the archive holds other people's expired messages in plain text. |
| 7 | **No git stop-gap** | Phase 0 is dropped. Losses continue until the archive ships, so ship phases 1–3 (capture + ledger + tombstones) before any view work. |
| 10 | Completed reminders go to their **month of completion**. `open.md` lists only open ones | As in §7. |
| 11 | Calendar keeps **invitation status and changes** (accepted/declined/tentative, cancelled, rescheduled) as labels | Record model gains `participationStatus`, `status` and the previous start/end. Reschedules show the old time, so this is a small exception to "current text only". |
| 16 | Notes keep the **account/folder layout**. The Timeline links to notes created or edited each month | No date-based paths for notes. |
| 19 | The tool **grows new commands**: an `archive` mode next to the mirror `export`, plus `rebuild` and `verify` | `export` keeps its current behaviour. `archive` writes the ledger and pages, `rebuild` regenerates the pages from the ledger, `verify` checks the ledger is consistent. |

| 20 | A **static HTML viewer** (coverage, disappeared, search, timeline), Mac only | Phase 8 of the implementation plan. |
| 21 | Add **ChatGPT and Claude chats** via official exports dropped in an inbox folder, plus local **Claude Code transcripts**. No unofficial APIs | Phase 9 of the implementation plan. Manual export cadence is accepted. |

All questions are decided.

## Schema notes (phase 0, 2026-10-26)

Probed read-only on the user's Mac. Only names, counts and booleans were read, no note titles, bodies or messages. WhatsApp was probed by the user from Terminal.app with Full Disk Access (WhatsApp Desktop 26.41.74).

| # | Result | Consequence for the plan |
|---|---|---|
| V1 | `ZWAMESSAGE.ZSTANZAID` exists and is **always filled** (8,799 rows), but only **8,793 are distinct**, so it isn't globally unique. Stability after a WhatsApp re-link can't be tested without re-linking. | Stable message key = **chat JID + `ZISFROMME` + `ZSTANZAID`** (stanza ids are per sender/chat), with `Z_PK` kept as native id. On a key collision within one read, fall back to adding `ZMESSAGEDATE`. |
| V2 | Type **14**: 35 rows, **none with text**. That matches the "This message was deleted" stub. There are **no edit columns**. Edits may live in `ZFLAGS` bits or a separate message type; unverified. | `revoked` = the same key turning into type 14 (text cleared), keeping the last-seen text. Edits are detected only as "same key, text hash changed" → `edited` flag; no schema field is needed. |
| V2+ | Types the current exporter skips **that do carry text**: **7** (380 rows, all with text; likely messages with a link preview), 6 (32 of 55, likely system/group events), 10 (13 of 176), 41/42/43 (11 rows, unknown, maybe polls or events). | The **current `export` silently drops ~380 link messages.** The archive reads types 7 and 41–43 as messages, and 6/10 as system events (shown muted). Other types without text become placeholders by type number. |
| V3 | There are **no timer columns** (`EPHEMERAL`/`EXPIR`/`DISAPPEAR` match nothing). `ZWAMESSAGEINFO` holds only a receipt blob. The chat-level setting probably sits in `ZWACHATSESSION.ZPROPERTIES` → a properties table, or in group-event system messages; not probed. | `expired` is **inferred**: a message that vanishes when its age is close to 24 h, 7 d or 90 d (±10%) in a chat where several messages vanish the same way → `expired (timer, inferred)`. Otherwise → `deleted`. An optional later probe of the properties table could make this exact. |
| chats | 288 sessions, 2 hidden, 0 removed. | Removed/hidden handling stays, but isn't urgent. |
| V4 | Notes scripting shows **no Recently Deleted folder**: 1 account, 33 folders, and the folder counts add up exactly to `account.notes` (429). Trashed notes are invisible to the exporter. | No `trashed` state for Notes. A note moved to Recently Deleted simply goes missing and becomes `deleted` after two complete reads, keeping its last text. Drop the "Recently Deleted" detection from phase 2 (`notes.js`). |
| V5 | All 6 locked notes have readable **title, dates and folder** without unlocking. | Locked stubs (phase 2) can carry title + folder + dates. A note becoming locked shows as `locked`, not deleted. |
| V6 | Not tested: checking ID stability needs a throwaway calendar, which is a write. Apple documents that `predicateForEvents(withStart:end:)` matches at most a **4-year span** and silently truncates longer ranges. | Keep ≤ 4-year chunks for backfill. Treat `calendarItemExternalIdentifier` as "mostly stable": keep the re-link rule (phase 3, rule 7). |
| V7 | WhatsApp Desktop bundle id is **`net.whatsapp.WhatsApp`** (version 26.41.74, in `/Applications`). | Health check uses that id. |
| extra | Two top-level folders share the name **"Diary"** (different ids). | Today's export path is account/folder/title--hash. Same-named folders merge into one directory, and the note hash keeps files apart, so nothing breaks. But the archive's Notes view should keep the folder id in front-matter, so the two "Diary" folders stay distinguishable. |

## 11. Questions to decide (the grilling)

**Scope & intent**
1. Is the goal a *personal memory archive* (read by you / an AI later) or *evidence-grade* (provable timestamps, tamper evidence, hash chain)? Evidence-grade adds signing and changes formats.
2. Should expired WhatsApp messages from **others** be kept verbatim, kept only as "a message expired here", or be configurable per chat?
3. Media: placeholders forever, copy files, or thumbnails only? What storage budget per year is acceptable?
4. Do you want history **before** today backfilled as far as the sources allow (full calendar, all chats, all completed reminders), or start the trail now?

**Where it lives**
5. Is the destination still Google Drive? If yes, the ledger must not be a live SQLite file there. Is a local, backed-up ledger + Drive-synced Markdown views OK?
6. Encryption at rest: required, nice to have, or not needed?
7. Is a git stop-gap (phase 0) acceptable for you right now, in a non-Drive local folder?

**Semantics**
8. When an item vanishes, do you want it **in place** (struck-through, labelled) or **moved** to a `_Disappeared/` area — or both (in place + digest)?
9. Are edits important (full version history of notes/events/messages), or only "current + was deleted"?
10. Reminder lifecycle: is "completed" an archive state for you, or should completed reminders keep living in their list view?
11. Calendar: track declined/cancelled invitations and reschedules as history, or just "existed / deleted"?
12. How aggressive should the circuit breaker be? (False "deleted" vs. missed deletions — which hurts more?)

**Structure**
13. Month files or day files as the primary unit? (Day = many tiny files; month = fewer, bigger files.)
14. Do you want a cross-source daily/monthly **Timeline**, or keep sources strictly separate?
15. Timezone of record: local time at the moment of the event, or a fixed home timezone? (Travel makes day boundaries ambiguous.)
16. Notes: keep path by account/folder (current), or also by creation date?

**Operations**
17. How often is the Mac awake with WhatsApp Desktop running? Would a missed-24h warning (notification) be useful, or noise?
18. Should old export folders be migrated into the ledger, or start fresh alongside them?
19. Is this tool still "read-only and simple" in spirit, or are you OK with it growing an internal database and a rebuild/reindex command?
