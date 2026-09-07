# icloud-exporter

A local, read-only exporter for Apple Notes, Reminders, and Calendar. It writes Markdown files that you can browse, search, or provide to an AI tool of your choice. The exporter does not change your Apple data and does not need an API key, web service, MCP server, or ChatGPT subscription.

Requires macOS 14 or newer and Swift 5.9 or newer to build. There are no third-party package dependencies.

## Build and try it

```sh
./scripts/build.sh
./dist/icloud-exporter/icloud-exporter --help
./dist/icloud-exporter/icloud-exporter export --output "$PWD/demo-export" --demo
```

The demo uses synthetic data and does not request access to Notes, Reminders, or Calendar. The build script puts the executable and its required SwiftPM resource bundle together in `dist/icloud-exporter/`. Keep that directory together when copying the exporter elsewhere.

To export your data, run the packaged executable in the foreground first:

```sh
./dist/icloud-exporter/icloud-exporter export \
  --output "$HOME/Documents/iCloud Export"
```

macOS may ask for Calendar and Reminders access and permission to control Notes. Grant the requested access for the sources you want to export. Notes uses macOS automation; Calendar and Reminders use EventKit. If access was denied, review the relevant entries in System Settings → Privacy & Security before retrying. Use the same executable path for the initial permission run and any scheduled runs.

## Options

```text
icloud-exporter export --output <directory>
  [--sources notes,reminders,calendar]
  [--past-days 365]
  [--future-days 365]
  [--completed-days 30]
  [--demo]
```

`--output` is required. All three sources are selected by default. Use a comma-separated list to limit the export:

```sh
./dist/icloud-exporter/icloud-exporter export \
  --output "$HOME/Documents/iCloud Export" \
  --sources reminders,calendar \
  --past-days 30 --future-days 60 --completed-days 14
```

`--past-days` and `--future-days` set the Calendar look-back and look-ahead windows, measured from the time the export starts. Events that overlap a window are included; an ongoing event can appear in both files. `--completed-days` limits recently completed reminders; incomplete reminders are exported separately. `--help` displays usage and `--version` displays the exporter version.

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
```

Calendar filenames reflect the configured windows: `upcoming-<future-days>-days.md` and `recent-<past-days>-days.md`. Note filenames include a stable identifier hash to distinguish notes with the same title. Path components are sanitized and lowercased so case-only renames work on macOS; titles and metadata retain their original case.

The hidden `.icloud-exporter-manifest.json` tracks files managed by the exporter so that subsequent runs can remove stale exports. Unrelated files are preserved. Exporting selected sources preserves the previous exports and timestamps for unselected sources in the index. If an existing destination file has been edited or is not managed by the exporter, the run refuses to overwrite it. Treat generated files as snapshots: keep your own annotations separately, or export into a new directory when resolving a conflict.

All selected sources must be read successfully before export files are updated. Files are replaced atomically, and an interrupted write leaves a `.icloud-exporter-pending.json` journal so the next run can recover. Retry with at least the same sources if prompted. The directory as a whole is not an atomic snapshot; a sync client may briefly observe files from two runs. An output lock prevents overlapping exporter writes. Demo and live exports must use separate directories.

Choose any writable output directory. It can be a local folder or a folder synced by your own Google Drive or other sync client. The exporter does not connect to Drive or configure syncing. Exports contain readable personal data, so choose the destination and sharing settings accordingly. How an AI product can access these files depends on that product and your setup.

## Limitations

- All password-protected Notes are skipped, even when currently unlocked. Attachments, drawings, scans, and embedded files are not exported.
- Notes formatting is converted to Markdown on a best-effort basis; the result is a text snapshot, not a full Notes backup.
- Calendar export covers the requested time windows rather than the entire calendar history.
- Access depends on the macOS permissions and Apple accounts available to the user running the exporter. Scheduling does not bypass permission prompts. After rebuilding with a new bundle identifier, macOS treats the exporter as a different app and asks for Calendar, Reminders, and Notes access again.
- Export folders from an older build are not recognized. Use a new output directory, or the run will refuse to overwrite files it does not manage.
- This is a one-way export. Editing Markdown does not update Notes, Reminders, or Calendar.

## Optional scheduling with launchd

Scheduling is manual. First complete a successful foreground export using the executable path you intend to schedule. Then:

1. Create `~/Library/LaunchAgents` if needed, then copy `launchd/com.djui.icloud-exporter.plist.example` to `~/Library/LaunchAgents/com.djui.icloud-exporter.plist`.
2. Edit the copied file, replacing every placeholder with an absolute path for the executable, output directory, and log files. Create the parent log directory if it does not exist. A plist does not expand `~`, `$HOME`, or shell commands. Escape XML characters such as `&` as `&amp;` when they occur in paths.
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

## Development

```sh
swift test
./scripts/build.sh
```

CI runs tests on macOS and checks that the packaged executable can produce a demo export. Tests and the demo do not require access to your Apple data.
