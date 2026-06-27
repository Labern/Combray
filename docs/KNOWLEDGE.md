# Combray — Project Knowledge

> Durable knowledge for picking this project up cold. Update this file; don't duplicate it.

## What it is

**Combray** is a personal, single-user **macOS app** that rescues **near-illegible handwritten
letters** into a searchable, browsable archive. Each letter = one or more photographed pages + an
AI-generated, user-editable transcription. Browse by person, relationship, and year; full-text
search across everything; side-by-side image-vs-transcription proofing.

The transcription capability is already **proven** — the user transcribed real letters by dropping
photos into Claude/ChatGPT chat. So the engine is de-risked; the work is the *home* around it.

## Name & icon

- **Name: Combray** — Proust's childhood village, resurrected whole from one taste of a madeleine;
  the book's emblem of memory recovered. (Chosen after rejecting puns/portmanteaus; the rule the
  user set: **references and quotations only**, sourced from **Shakespeare + Proust in English**.
  Note the lovely hinge: Proust's English title *Remembrance of Things Past* is itself a line from
  Shakespeare's **Sonnet 30** — a good well for in-app epigraphs later.)
- **Icon: a madeleine** — the cake whose taste detonates involuntary memory. Keep it warm and
  simple, matching the white/clean/legible aesthetic. *(TODO: design the AppIcon asset.)*

## Locked decisions

| Topic | Decision |
|---|---|
| **Capture link** | macOS **Continuity Camera "Insert from iPhone"** (built-in; full-res, auto-deskewed pages drop straight in; no companion app). Also accept drag-drop + watched-folder import. |
| **Transcription** | **Cloud Claude, best quality** — `claude-opus-4-8` vision via REST. (User OK with photos leaving the Mac; it's the only thing that reads this handwriting.) |
| **Web** | **Vital, but built later.** Build Mac-first; keep the data layer portable so a web viewer (image-vs-transcription + search) reuses it without a rewrite. → drives the GRDB/SQLite choice. |
| **Look & feel** | **Clean native Mac. White, simple, big legible controls, NO small buttons.** Color only as occasional flourish. Theme via tokens so it stays swappable. |
| **Distribution** | Must install on **another Mac**. Ship a self-contained `.app` → double-click **`.pkg`** (pkgbuild/productbuild) into /Applications. API key entered in-app (never bundled). |

## Architecture / stack

- **App:** SwiftUI macOS app (`Sources/Combray`, `@main CombrayApp`). `NavigationSplitView`:
  sidebar (All · People · Relationships · By Year · Search) → letter list → side-by-side detail.
- **Core (testable, UI-free):** `Sources/CombrayCore` — models, DB, repository, search, Anthropic
  client, theme tokens, Keychain. CLI-buildable + testable (no Xcode needed for logic).
- **Persistence + search:** **GRDB** over SQLite, with an **FTS5** virtual table for fast,
  ranked, highlighted full-text search. One portable `.sqlite` file = the future web backend's data.
- **Images:** lossless originals on disk (archive root), **paths in the DB** (no blobs);
  thumbnails via QuickLookThumbnailing.
- **AI:** Anthropic REST `POST /v1/messages`, **no Swift SDK** → `URLSession` async/await.
  One vision call returns transcription **and** structured fields. Key in **Keychain**.

## Data model (see `Models.swift`, `AppDatabase.swift`)

`letter` (title, dateValue/dateYear/dateSource/dateConfidence, transcription [canonical, editable],
aiTranscription [raw original — kept for diff/re-run], notes, timestamps) · `page` (letterId,
pageIndex, imagePath, thumbnailPath, dims) · `person` (displayName, aka, notes) · `letterPerson`
(letterId, personId, role: sender|recipient — many-to-many) · `relationship` (personId, relation) ·
`letterSearch` (FTS5: letterId UNINDEXED, title, body, names — rebuilt per-letter by the repository).

## Transcription pipeline

Per page/letter: load original → HEIC→JPEG/PNG if needed → base64 → `POST /v1/messages`
(`model:"claude-opus-4-8"`, image block(s) + instruction). Use **`output_config.format`**
(json_schema) — **NOT** the deprecated `output_format` — to force typed output:
`{ transcription, title, sender, recipients[], date{value,source,confidence}, people_mentioned[],
uncertain_spans[] }`. Generous `max_tokens`; **stream** long letters. Store raw + editable
transcription; map `uncertain_spans` to highlights in the proofing pane. **Batch API** (50% off)
for backlog transcription.

## Build & run

```sh
cd ~/Combray
swift build        # builds CombrayCore + the Combray executable (links GRDB)
swift test         # runs CombrayCore unit tests
swift run Combray  # launches the SwiftUI app (dev)
```

Later: wrap in an **Xcode app target** to get App Sandbox + entitlements (`com.apple.security.
network.client` for the API; the Continuity Camera "Insert from iPhone" responder hooks) and to
build the distributable `.app`/`.pkg`. Add `Scripts/build_pkg.sh` then. Notarization needs an Apple
Developer ID; without it the second Mac needs a one-time right-click→Open (or
`xattr -dr com.apple.quarantine`).

## Gotchas learned

- **`~/Developer` is the user's own git repo** (umbrella with a `writing-test` project) — do NOT
  scaffold inside it. Combray lives standalone at **`~/Combray`** (outside any repo) for clean,
  self-contained version control. (Background-session isolation guard blocks Writes into a tracked
  checkout; a standalone dir sidesteps it.)
- **Anthropic structured output param is `output_config.format`**, not the deprecated `output_format`.
- **Continuity Camera as a raw webcam can't be remotely triggered and caps ~2.7MP** — too low for
  fine script. The right path is **"Insert from iPhone"** (AppKit responder chain: `validRequestor
  (forSendType:returnType:)` + `NSServicesMenuRequestor.readSelection(from:)`), which yields full-res,
  deskewed pages.
- **No official Anthropic Swift SDK** — call the REST API directly (URLSession).

## Status & next

1. ✅ Toolchain + GRDB resolve; package builds; tests pass; renamed to Combray.
2. ⏳ **Core data layer** — schema/migrations (`AppDatabase`), models, repository, FTS5 search (+ tests).
3. Anthropic `URLSession` client (Keychain, streaming, structured output) + tests.
4. SwiftUI shell: split view, big-button design system, theme tokens, side-by-side proofing.
5. Ingest: Insert-from-iPhone + drag-drop/folder; image store + thumbnails. (needs Xcode wrap)
6. Entities & browse; FTS search UI; web-readiness pass; `.pkg` build script.
