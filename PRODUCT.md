# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

The offline viewer and the landing page are web surfaces. The menu bar app and its Settings window are native macOS (SwiftUI) and follow macOS conventions; both are in scope for design work.

## Users

Primarily the author, keeping a lifelong record of their own notes, reminders, calendar and chats. The product is published so that other Mac users can use it too, and the menu bar app and landing page must work for people who are not technical: they download the app, pick a folder, grant permissions once, and then only look at the menu bar and the viewer. The CLI and launchd setup are for power users.

## Product Purpose

Lifelog keeps a local, read-only, lifelong archive of Apple Notes, Reminders and Calendar, WhatsApp, Instagram and Facebook Messenger messages, ChatGPT and Claude exports, and Claude Code transcripts. It reads these sources on a schedule, records every change in an append-only ledger, and writes Markdown pages by source and by month, a Timeline across sources, and an offline HTML viewer. Success means that anything the user has once seen can still be found later, even after it expired, was deleted or was unsent at the source.

## Positioning

An archive, not a mirror: a mirror forgets, Lifelog does not. Items that disappear at the source stay in the archive with their last content and a record of what happened. "Absence is not deletion": an item only counts as gone after a complete, in-scope read missed it twice in a row and the circuit breaker (over 20% of a source vanishing at once) did not trip. It runs entirely on the user's Mac with no account, cloud service or API key.

## Operating Context

- The menu bar app runs the archive every 10 minutes (hourly for Notes and AI exports), catches up after sleep, and shows each source's last read, warnings and the next run. It offers Run Now, Pause, Open Viewer and Show Log.
- The archive folder is any folder the user picks, often one synced by Google Drive; Lifelog never configures syncing itself.
- Meta, ChatGPT and Claude data arrives as export zips the user downloads into `~/Downloads`; the app reminds the user after 45 days without a new export.
- The viewer is opened by double-clicking `index.html` in the archive, or with `lifelog open`. It offers full-text search, per-source coverage and a timeline.
- The user may hand the archive folder to an AI tool of their choice.
- macOS permission prompts (Calendar, Reminders, Notes automation, Full Disk Access for WhatsApp) are part of first run.

## Capabilities and Constraints

- Item states include active, edited, completed, rescheduled, deleted, expired, revoked and locked; a monthly `_Disappeared` digest lists what went away.
- CLI: `lifelog archive`, `rebuild`, `verify`, `open`, plus the older `export` mirror mode. A `--demo` mode uses synthetic data only.
- Requires macOS 14 or newer. Swift package with no third-party dependencies.
- Password-protected notes are kept as stubs; attachments and media become placeholders, not copies.
- WhatsApp is an unofficial read of WhatsApp Desktop's local database; encrypted Messenger chats are not in Meta's export and are not imported.

## Brand Commitments

- Name: Lifelog (formerly icloud-exporter). Bundle id `com.djui.lifelog`.
- App icon: `Support/AppIcon.icns`, `docs/icon.png`.
- Tagline in use: "Everything you've seen. Kept for life."
- Local, no cloud: no account, server, API key or network use; nothing leaves the Mac unless the user's chosen folder syncs.
- Nothing vanishes: deleted, expired and revoked items are always kept, searchable and shown, marked with what happened.
- The viewer is static HTML with no external assets or network calls.
- Free and open source (MIT), with no analytics, tracking or upsell.

## Evidence on Hand

- Landing page: `docs/index.html` (GitHub Pages), with an illustrative timeline and menu bar mockup.
- Viewer: `Sources/LifelogCore/Resources/viewer/`.
- Design rationale: `docs/plans/lifelong-archive.md`.
- Synthetic demo data: `Sources/LifelogCore/Demo.swift` (`lifelog archive --demo`).
- Notarized releases on GitHub (v0.1.0, v0.2.0, v0.2.1, v0.2.2).
- There are no testimonials, user counts, press or benchmarks; do not invent any.

## Product Principles

1. Never lose anything: when unsure, keep and mark, never drop.
2. Trust is earned by honesty: show what was read, what failed and what disappeared, plainly.
3. Local and private by construction: no feature may require the network or an account.
4. Quiet by default: it runs in the background and asks for attention only when the user must act.
5. Plain files outlive apps: everything stays readable without Lifelog.
