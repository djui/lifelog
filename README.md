# icloud-exporter

A local, read-only exporter for Apple Notes, Reminders, Calendar, and local WhatsApp chats. It writes Markdown files that you can browse, search, or provide to an AI tool of your choice. The exporter does not change your Apple or WhatsApp data and does not need an API key, web service, MCP server, or ChatGPT subscription.

Requires macOS 14 or newer and Swift 5.9 or newer to build. There are no third-party package dependencies.

## Build and try it

```sh
./scripts/build.sh
./dist/icloud-exporter --help
./dist/icloud-exporter export --output "$PWD/demo-export" --demo
```

The demo uses synthetic data and does not request access to Notes, Reminders, Calendar, or WhatsApp. The build script packages a signed `dist/icloud-exporter.app` (required for macOS permissions) and a convenience symlink at `dist/icloud-exporter`. Keep the `.app` together when copying the exporter elsewhere.

To export your data, run the packaged app in the foreground first:

```sh
./dist/icloud-exporter.app/Contents/MacOS/icloud-exporter export \
  --output "$HOME/Documents/iCloud Export"
```

macOS may ask for Calendar and Reminders access, permission to control Notes, and permission to access data from other apps (WhatsApp’s local database, and any export folder owned by another app such as Google Drive). Grant those prompts once for `iCloud Exporter`. If a scheduled run keeps asking, macOS is not recognizing a stable app identity: use the `.app` path above, not `swift run` or a rebuilt unsigned binary. Notes uses macOS automation; Calendar and Reminders use EventKit; WhatsApp is an unofficial read of WhatsApp Desktop’s `ChatStorage.sqlite`. If access was denied, review System Settings → Privacy & Security (Calendar, Reminders, Automation, and Full Disk Access) and add `icloud-exporter.app` there. Use that same `.app` for scheduled runs.

## Options

```text
icloud-exporter export --output <directory>
  [--sources notes,reminders,calendar,whatsapp]
  [--past-days 365]
  [--future-days 365]
  [--completed-days 30]
  [--demo]
```

`--output` is required. All four sources are selected by default. Use a comma-separated list to limit the export:

```sh
./dist/icloud-exporter.app/Contents/MacOS/icloud-exporter export \
  --output "$HOME/Documents/iCloud Export" \
  --sources reminders,calendar \
  --past-days 30 --future-days 60 --completed-days 14
```

`--past-days` and `--future-days` set the Calendar look-back and look-ahead windows, measured from the time the export starts. Events that overlap a window are included; an ongoing event can appear in both files. `--past-days` also limits WhatsApp message history. WhatsApp exports the 20 most recently active 1:1 and group chats in that window. `--completed-days` limits recently completed reminders; incomplete reminders are exported separately. `--help` displays usage and `--version` displays the exporter version.

## Exported files

With the default windows, the directory looks like this:

```text
iCloud Export/
  _index.md
  Notes/
    <account>/
      <folder>/
        <title>--<stable-hash>.md
  Reminders/
    current-reminders.md
    completed-recent.md
  Calendar/
    upcoming-365-days.md
    recent-365-days.md
  WhatsApp/
    <chat>--<stable-hash>.md
```

Calendar filenames reflect the configured windows: `upcoming-<future-days>-days.md` and `recent-<past-days>-days.md`. Note and WhatsApp filenames include a stable identifier hash to distinguish items with the same title. Path components are sanitized and lowercased so case-only renames work on macOS; titles and metadata retain their original case.

The hidden `.icloud-exporter-manifest.json` tracks files managed by the exporter so that subsequent runs can remove stale exports. Unrelated files are preserved. Exporting selected sources preserves the previous exports and timestamps for unselected sources in the index. If an existing destination file has been edited or is not managed by the exporter, the run refuses to overwrite it. Treat generated files as snapshots: keep your own annotations separately, or export into a new directory when resolving a conflict.

Each selected source is written as soon as it has been read. Files are replaced atomically, and an interrupted write leaves a `.icloud-exporter-pending.json` journal so the next run can recover. The directory as a whole is not an atomic snapshot; a sync client may briefly observe files from two runs, and a failed source leaves previously written sources in place. An output lock prevents overlapping exporter writes. Demo and live exports must use separate directories.

Choose any writable output directory. It can be a local folder or a folder synced by your own Google Drive or other sync client. The exporter does not connect to Drive or configure syncing. Exports contain readable personal data, so choose the destination and sharing settings accordingly. How an AI product can access these files depends on that product and your setup.

## Limitations

- All password-protected Notes are skipped, even when currently unlocked. Embedded images, drawings, scans, and attachments are replaced with placeholders so the export stays small.
- Notes formatting is converted to Markdown on a best-effort basis; the result is a text snapshot, not a full Notes backup.
- Calendar export covers the requested time windows rather than the entire calendar history.
- WhatsApp export reads the local WhatsApp Desktop database only (`~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared`). It is unofficial, does not talk to WhatsApp servers, and is not a full chat backup. It writes the 20 most recently active chats, limited to `--past-days`. Images, audio, video, and other attachments become placeholders; media files are not copied. Missing WhatsApp data is skipped with a warning. If the database exists but cannot be read, allow access to other apps’ data, or grant Full Disk Access to `icloud-exporter.app`.
- Access depends on the macOS permissions and Apple accounts available to the user running the exporter. Scheduling does not bypass permission prompts. A bare or ad-hoc CLI has no stable identity, so macOS can ask again on every launchd run. The packaged, signed `.app` is the identity to grant. After rebuilding with a different bundle identifier or an ad-hoc signature, macOS treats the exporter as a new app and asks again.
- Export folders from an older build are not recognized. Use a new output directory, or the run will refuse to overwrite files it does not manage.
- This is a one-way export. Editing Markdown does not update Notes, Reminders, Calendar, or WhatsApp.

## Optional scheduling with launchd

Scheduling is manual. First complete a successful foreground export using `dist/icloud-exporter.app/Contents/MacOS/icloud-exporter`, the same path you will schedule. Then:

1. Create `~/Library/LaunchAgents` if needed, then copy `launchd/com.djui.icloud-exporter.plist.example` to `~/Library/LaunchAgents/com.djui.icloud-exporter.plist`.
2. Edit the copied file, replacing every placeholder with an absolute path for the `.app` executable, output directory, and log files. Leave `AssociatedBundleIdentifiers` as `com.djui.icloud-exporter`. Create the parent log directory if it does not exist. A plist does not expand `~`, `$HOME`, or shell commands. Escape XML characters such as `&` as `&amp;` when they occur in paths.
3. Validate and load the agent:

```sh
plutil -lint "$HOME/Library/LaunchAgents/com.djui.icloud-exporter.plist"
launchctl bootstrap "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/com.djui.icloud-exporter.plist"
```

The example runs when loaded and then approximately every ten minutes while your user session is active. A sleeping or logged-out Mac does not provide an exact ten-minute schedule. Check the configured logs if a scheduled export fails.

To stop the agent before changing or removing it:

```sh
launchctl bootout "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/com.djui.icloud-exporter.plist"
```

After editing an unloaded agent, validate it and load it again. Building the project does not install or load a launch agent.

## Lifelong archive

`export` is a mirror: each run rewrites the selected sources and removes files for items that are gone, or that fall outside the time windows. `archive` keeps everything it has ever seen. When an item is deleted at the source, it expires, or its sender deletes it, the item stays in the archive with its last text and is marked with its new state. Nothing is dropped. The design and its decisions are in [docs/plans/lifelong-archive.md](docs/plans/lifelong-archive.md).

Try it with synthetic data first. The demo needs a new, empty folder:

```bash
./dist/icloud-exporter archive --output "$PWD/demo-archive" --demo
```

```bash
./dist/icloud-exporter open --output "$PWD/demo-archive"
```

The demo replays a few runs, so it shows deleted, expired, revoked, edited and locked items. A demo folder and a real archive cannot be mixed: a real run refuses a demo folder, and the demo refuses a real one.

### Commands

```text
icloud-exporter archive --output <directory>
  [--sources notes,reminders,calendar,whatsapp,chatgpt,claude,claudecode]
  [--backfill-since 2000-01-01]
  [--rescan-days 100]
  [--full-sweep-days 7]
  [--ai-inbox ~/Downloads]
  [--notify]
  [--no-viewer]
  [--demo]
icloud-exporter rebuild --output <directory> [--no-viewer]
icloud-exporter verify --output <directory>
icloud-exporter open --output <directory>
```

- `archive` reads the selected sources, records what changed, and rewrites the pages that show changed items. `--sources` defaults to `notes,reminders,calendar,whatsapp`. Add `chatgpt`, `claude` and `claudecode` to archive AI chats as well (see [Sources](#sources)).
- `rebuild` regenerates every page from the ledger. Use it after deleting or damaging pages, or when an `archive` run reports that its pages were not written.
- `verify` checks the ledger, the run log and the index cache without changing anything. It prints `Problem:` lines and exits non-zero when the archive cannot be trusted. It prints `Note:` lines for harmless issues, such as a stale cache.
- `open` opens the offline viewer, `_viewer/index.html`, in your default browser.

Each source is read in one of three modes:

- **Backfill** happens on the first run, and on every run until a backfill completes. It reads everything back to `--backfill-since` (default `2000-01-01`): all calendar history, every chat in the local WhatsApp database, and all completed reminders. Expect the first run to take a while.
- **Full sweep** happens when the last complete backfill or full sweep is older than `--full-sweep-days` (default 7). It reads everything again, so that old deletions show up.
- **Rescan** is used on every other run. It re-reads the last `--rescan-days` (default 100). That is longer than WhatsApp's longest disappearing-message timer (90 days).

Notes are always read in full. A failed source is logged as incomplete and the other sources continue. The run exits non-zero when any source failed.

`--no-viewer` skips the HTML viewer and removes an existing one. `--notify` posts a macOS notification when capture falls behind (see [Health](#health-and-verify)).

### Folder layout

Use a new, empty folder for the archive, separate from any `export` folder. Each command refuses the other's folders. A Google Drive-synced folder works: past months are never rewritten, and the current month's ledger file is only appended to.

```text
Archive/
  _index.md                          # last complete read per source, health warnings, links
  Timeline/2026/2026-10.md           # per day, across sources, links into the files below
  _Disappeared/2026/2026-10.md       # everything that was deleted, expired, revoked or became unknown that month
  WhatsApp/<chat>--<hash>/
    _chat.md
    2026/2026-10.md                  # messages by month; states marked inline
  Calendar/2026/2026-10.md           # events by start date
  Reminders/
    open.md                          # open reminders
    2026/2026-10.md                  # by completion (or deletion) month
  Notes/<account>/<folder>/<title>--<hash>.md
  ChatGPT/2026/2026-10/<title>--<hash>.md   # by the month a chat started
  Claude/…  ClaudeCode/…             # same as ChatGPT
  _viewer/index.html                 # offline viewer, plus app.js, style.css and data/
  .archive/
    ledger/<source>/<YYYY-MM>.<host>.jsonl   # append-only source of truth
    runs/<YYYY-MM>.<host>.jsonl              # run log: one line per source per run
    pages.json                               # which pages the archive owns
```

The ledger is the source of truth. Everything else is a view of it and can be regenerated with `rebuild`. Ledger files are plain JSON lines, partitioned by the month they were written. Each Mac writes only files carrying its own host id, so two Macs never write the same file. Don't edit pages by hand: like `export`, the archive refuses to overwrite a page that was changed outside it.

Caches live outside the synced folder, in `~/Library/Caches/com.djui.icloud-exporter/<archive-hash>/`. They hold the folded index, the Claude Code read positions, the AI inbox digests and the notifications already sent. All of them can be deleted. The next run rebuilds the index from the ledger, and reads every Claude Code transcript again without adding duplicates.

### States

| State | Meaning |
|---|---|
| `active` | Seen in the latest read. |
| edited | Not a state but a flag: the item's text changed since it was first seen. Only the latest text is kept. Calendar events also record `rescheduled from …` and changes to status and invitation response. |
| `completed` | A completed reminder that still exists. Reopening it makes it active again. |
| `archived` | Older than `--backfill-since`, so no read covers it any more. It is frozen, not deleted. |
| `trashed` | In a recoverable bin at the source. No source reports this today: Notes scripting does not expose *Recently Deleted*, so a trashed note goes missing and becomes `deleted`. |
| `locked` | A note that was locked. Its title, folder and dates are still read, and the archive keeps the last text it saw before the lock. |
| `deleted` | Gone from the source, according to the rules below. |
| `expired` | A WhatsApp message that disappeared on a timer. WhatsApp has no timer column, so this is inferred: the message vanished at an age close to 24 hours, 7 days or 90 days (±10%), and at least one other message in the same chat vanished at the same age. Otherwise it is `deleted`. The reason always says "inferred". |
| `revoked` | A WhatsApp message its sender deleted for everyone. The archive keeps the text it saw before. |
| `unknown` | Went missing in a mass disappearance (see the circuit breaker below). It is never turned into `deleted` automatically. |

Every vanished item stays on its page with its last text, and is also listed in that month's `_Disappeared` page. The archive records when it last saw an item and when it noticed the change. Apple and WhatsApp don't report deletion times, so the truth is "gone between these two times".

If an item that was deleted, expired or unknown appears again, it becomes active again with the reason `reappeared`.

### Absence is not deletion

Something missing from a read is only marked as gone when all of these hold:

- **The read was complete.** A read with a timeout, a permission error or a partial result only adds and updates items. It never counts as evidence that something is missing.
- **The item was in scope.** Only items the read would have covered can go missing. For example, a rescan doesn't count calendar events older than its window.
- **It was missing twice.** The first complete read without the item marks it pending, which is invisible on the pages. Only the second consecutive complete miss turns it into `deleted` or `expired`. If it is seen again in between, the pending mark is cleared.
- **The circuit breaker did not trip.** If more than 20% of a source's in-scope items go missing in one run (and at least 10 items), the read is suspected instead of the items. They stay pending, the run warns, and after a second miss they become `unknown`, never `deleted`.

Some sources never tombstone:

- **Claude Code** transcripts are only ever added to. Claude Code removes old transcripts on its own, so a vanished session is not a deletion.
- **A WhatsApp chat that vanishes as a whole** is never tombstoned. Only chats present in a read are in scope, so a removed chat or a re-linked WhatsApp Desktop does not mark every message as deleted.

A missing item plus a new item with the same container and the same text, seen in the same run, is treated as one item whose ID changed, not as a deletion plus a duplicate.

### Sources

- **Notes, Reminders, Calendar, WhatsApp** use the same access as `export` (see above). Unlike `export`, the archive reads every WhatsApp chat (not just the 20 most active ones), all message types, and all calendar history in chunks of at most four years. Locked notes are kept as stubs with title, folder and dates.
- **ChatGPT and Claude** (`chatgpt`, `claude`) are imported from the official account exports: in ChatGPT, Settings → Data controls → Export data; in Claude, Settings → Privacy → Export data. Leave the downloaded zip in the AI inbox: `~/Downloads` by default, or the folder you set with `--ai-inbox`. Each run looks at the zips directly in that folder, not in subfolders. Exports are recognized by their contents, not by their file name. Each zip is imported once, tracked by its SHA-256 digest in the run log, and left where it is. A complete export counts as a complete read of that service, so a chat missing from two newer exports becomes `deleted`. Exports are manual, so a chat created and deleted between two exports is never seen.
- **Claude Code** (`claudecode`) reads the session transcripts in `~/.claude/projects/` incrementally, picking up only new lines on each run. User and assistant text is kept. Tool calls, tool results and reasoning become one-line placeholders, so work code and tool output stay out of the archive.

### The offline viewer

Each `archive` and `rebuild` writes a static viewer to `_viewer/`. It shows coverage per source, the disappeared items, a timeline and full-text search. It is plain HTML, JavaScript and data files, works without a network connection or server, and needs nothing to keep running. Open it with:

```bash
./dist/icloud-exporter open --output "$HOME/Archive"
```

You can also double-click `_viewer/index.html`.

### Health and verify

The run log records every read, so the archive can tell when capture falls behind:

- WhatsApp is the urgent one. A message on a 24-hour timer is lost for good if no read sees it within 24 hours. `_index.md` and the output of each run warn after 20 hours without a complete WhatsApp read, and again with the possible-loss window once the gap passes 24 hours. They also warn when WhatsApp Desktop (`net.whatsapp.WhatsApp`) is not running.
- After three failed or partial reads in a row, a source is flagged.
- ChatGPT and Claude are flagged after 45 days without a new export.

With `--notify`, each of these is also posted once as a macOS notification from `iCloud Exporter`. Allow notifications when macOS asks.

Run `verify` from time to time, and after anything unusual such as a sync conflict:

```bash
./dist/icloud-exporter.app/Contents/MacOS/icloud-exporter verify --output "$HOME/Archive"
```

### First run

Run the first archive in the foreground from Terminal.app, using the `.app` path, so that the macOS permission prompts appear and can be granted to `iCloud Exporter`. Archive one source at a time into a new, empty folder, so that a prompt or a slow backfill is easy to tell apart. The examples use `$HOME/Archive`. A Google Drive folder works the same way.

```bash
./dist/icloud-exporter.app/Contents/MacOS/icloud-exporter archive --output "$HOME/Archive" --sources reminders
```

```bash
./dist/icloud-exporter.app/Contents/MacOS/icloud-exporter archive --output "$HOME/Archive" --sources calendar
```

```bash
./dist/icloud-exporter.app/Contents/MacOS/icloud-exporter archive --output "$HOME/Archive" --sources whatsapp
```

```bash
./dist/icloud-exporter.app/Contents/MacOS/icloud-exporter archive --output "$HOME/Archive" --sources claudecode
```

```bash
./dist/icloud-exporter.app/Contents/MacOS/icloud-exporter archive --output "$HOME/Archive" --sources chatgpt,claude
```

```bash
./dist/icloud-exporter.app/Contents/MacOS/icloud-exporter archive --output "$HOME/Archive" --sources notes
```

Each line of output names the source, the read mode and what changed. Then check the result:

```bash
./dist/icloud-exporter.app/Contents/MacOS/icloud-exporter verify --output "$HOME/Archive"
```

### Scheduling the archive

Use two launchd agents that share one archive folder. They share its lock, so when one is running, the other fails fast and tries again at its next interval.

- A fast agent runs `whatsapp,reminders,calendar,claudecode` every 10 minutes, because disappearing messages can expire after 24 hours.
- A slow agent runs `notes,chatgpt,claude` every hour, because a full Notes read can take minutes.

1. Copy `launchd/com.djui.icloud-exporter.archive.plist.example` to `~/Library/LaunchAgents/com.djui.icloud-exporter.archive.plist`. Replace every `/ABSOLUTE/PATH/TO/…` placeholder, as for the export agent above.
2. Save a second copy as `~/Library/LaunchAgents/com.djui.icloud-exporter.archive-slow.plist`. In it, change the `Label` to `com.djui.icloud-exporter.archive-slow`, `--sources` to `notes,chatgpt,claude`, `StartInterval` to `3600`, and the log file names to `archive-slow.log` and `archive-slow.error.log`.
3. Add `--notify` to `ProgramArguments` in the fast agent if you want notifications.
4. Validate and load both agents:

```bash
plutil -lint "$HOME/Library/LaunchAgents/com.djui.icloud-exporter.archive.plist" "$HOME/Library/LaunchAgents/com.djui.icloud-exporter.archive-slow.plist"
```

```bash
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.djui.icloud-exporter.archive.plist"
```

```bash
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.djui.icloud-exporter.archive-slow.plist"
```

Use `launchctl bootout` with the same arguments to stop an agent.

### Before retiring `export`

Keep your existing `export` agent running for about a week alongside the archive, writing to its own folder. Then compare the two: the same notes, reminders and recent events should appear in both, and the archive should have more WhatsApp chats and history. Check the `_index.md` health section and `verify`. Unload the export agent only after that.

### Privacy

The archive keeps other people's WhatsApp messages after they expired or were deleted for everyone, in plain text, in the folder you choose. If that is a Google Drive folder, they sync there. Those people chose to make the messages disappear, and the archive overrides that choice for your copy. There is no extra encryption: the archive relies on your Google account security and FileVault. Choose the folder's sharing settings accordingly, and don't share the archive with an AI tool or person you wouldn't show those messages to. Claude Code transcripts can contain work code in the text turns, even though tool output is reduced to placeholders.

### Archive limitations

- A message that expires or is deleted before any run sees it is unrecoverable. The archive records capture gaps but cannot fill them, so keep the Mac awake and WhatsApp Desktop running.
- Images, voice notes, videos and attachments are placeholders only. No media files are copied.
- Inferred `expired` states can be wrong, for example when a message happens to be deleted at about the age of a timer.
- WhatsApp's database schema is unofficial and can change with any WhatsApp update. The circuit breaker and two-miss rule exist so that such a change produces `unknown` rather than false deletions.
- The ChatGPT and Claude importers were built against the documented shape of `conversations.json`, but have not yet been checked against real exports. Branches and edits in ChatGPT conversations and attachments in Claude exports are the most likely to differ. Look at the imported chats after your first import.
- Storage grows forever by design. Text-only is small, a few megabytes per year.

## Development

```sh
swift test
./scripts/build.sh
```

CI runs tests on macOS and checks that the packaged executable can produce a demo export and a demo archive. Tests and the demo do not require access to your Apple or WhatsApp data.
