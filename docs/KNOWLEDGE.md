# Combray — Project Knowledge

Durable, pick-up-cold knowledge for Combray. Update this file; don't duplicate it.

## What it is
A personal **macOS** app (Swift/SwiftUI) that transcribes **near-illegible handwritten letters**
with **Claude**, stores each as a structured, editable entry, and lets you browse by person/year,
read a correspondence as a chat, and full-text search everything. The transcription quality is the
point; everything else is the home around it.

## Where everything lives
- **Project (source):** `~/Combray` — a **Swift Package** (`Package.swift`). It is **NOT a local git
  repo** (we push from throwaway copies so the working tree stays editable — see Distribution).
  Targets: `CombrayCore` (library), `Combray` (the `@main` SwiftUI app executable), `CombrayCoreTests`.
  Dependency: GRDB (`github.com/groue/GRDB.swift`, from 7.0.0).
- **Your data (the archive):** `~/Library/Application Support/Combray/` (was `~/Documents/Combray` until
  v0.7 — MOVED because Documents is TCC-protected and macOS re-prompted for access on every ad-hoc
  reinstall; App Support is never gated → zero permission prompts. `ImageStore.migrateFromDocumentsIfNeeded()`
  auto-moves an old Documents archive on first launch.)
  - `Letters/<n>/` — one folder per letter (n = sequential number): `letter_<n>_page_<y>.<ext>` (the
    original page images, openable in Preview), `letter.json` (all metadata + transcription),
    `transcription.txt` (plain text).
  - `combray.sqlite` — the index/cache (rebuildable from the folders).
- **Credentials:** `~/Library/Application Support/Combray/credentials.json` (0600). **Not the
  Keychain** — an unsigned/rebuilt dev app loses its Keychain ACL and prompts for the login password
  every launch; a file avoids that. The iCloud backup only copies `Letters/`, so the token isn't backed up.
- **Installed app:** `/Applications/Combray.app` (so Spotlight/Launchpad find it).
- **GitHub:** `github.com/Labern/Combray` (public). Release `v0.1` ships `Combray.pkg`.
  Homebrew tap: `github.com/Labern/homebrew-combray` (`Casks/combray.rb`).

## Folders are the source of truth (VITAL — user requirement)
On launch the app runs `Backup.scan(lettersDir:)` + `archive.importFromFiles(...)` to **rebuild any
missing letters from `letter.json`**. So the app survives a DB loss or a full rewrite — the plain
files are canonical. In DEBUG the migrator sets `eraseDatabaseOnSchemaChange = true`: a schema change
wipes+rebuilds the SQLite, then reconcile re-imports from the folders (data persists). `Backup.write`
writes `letter.json` + `transcription.txt` after every change (`controller.backup(id)`).

## Architecture / key files
- **CombrayCore** (UI-free, testable):
  - `Models.swift` — `Letter` (id, **number**, title, dateValue/dateYear/dateSource/dateConfidence,
    `transcription` [canonical/editable], `aiTranscription` [raw first AI output — kept for restore],
    notes, summary, meta{Location/Relationship/RelationshipState/WriterGoals}, **notableQuotes**
    [newline-joined], timestamps), `Person`, `Page`, `LetterPerson` (role sender|recipient), enums.
  - `AppDatabase.swift` — GRDB schema/migrations + FTS5 `letterSearch`. **Add new Letter columns here
    too** or `save()` throws "no such column".
  - `Archive.swift` — the repository: CRUD, `setParticipants`, `search`, `applyTranscription(_:toLetterId:)`,
    `correspondence(forLetterId:)`, `nextLetterNumber()`, `backupFile/writeBackup/importFromFiles`,
    helpers `clean`/`year`/`composedTitle`.
  - `AnthropicClient.swift` — `transcribe(imageURLs:)`, `TranscriptionResult` (lenient decode),
    `authHeaders()`, the prompt (`instruction`) and `schema`.
  - `ClaudeAuth.swift` — OAuth PKCE flow.
  - `Keychain.swift` — credential **file** store (name is legacy; it's a JSON file now). `StoredCredential`.
  - `ImageStore.swift` — `defaultRoot()` = `~/Library/Application Support/Combray`; `lettersDir` = `Letters`; `importImage(...)`; `migrateFromDocumentsIfNeeded()`.
  - `Backup.swift` — `LetterFile` (the `letter.json` shape) + `Backup.write/scan`.
- **Combray** (app):
  - `CombrayApp.swift` — `@main`. `init` handles `--render <png>` (UI preview) and `--serve` (headless
    capture server for curl tests) then exits before the GUI.
  - `ArchiveController.swift` — the `@MainActor` controller the views bind to. Owns Archive, ImageStore,
    AnthropicClient, CaptureServer. Import/transcribe/edit/search/people, sign-in, capture, export/share,
    `goHome`, `updateParticipants`, `updateDate`, `importFromCapture`. Plus the headless
    `runCaptureServerHeadless()`.
  - `Views.swift` — all SwiftUI. RootView (NavigationSplitView + QuoteBar footer), SidebarView,
    DetailContainer, ExplainerView (home), LetterDetailView, ZoomableImage, MetaPanel, ChatSheet,
    PersonDetailView, SettingsView, AddLetterSheet, SignInSheet, CaptureSheet, QuoteBar, helpers.
  - `Theme.swift` — tokens + `BigButtonStyle` + `MadeleineMark` (drawn icon) + `MadeleineIcon` +
    `installMadeleineDockIcon()` + `renderMadeleinePNG` (the UI-mock preview render).
  - `CaptureServer.swift` — iPhone capture web server. `OAuthCallbackServer.swift` — OAuth loopback catcher.

## Auth — "Sign in with Claude" (OAuth)
`ClaudeAuth`: client_id `9d1c250a-e61b-44d9-88ed-5944d1962f5e`, authorize `https://claude.ai/oauth/authorize`,
token `https://console.anthropic.com/v1/oauth/token`, scopes `org:create_api_key user:profile user:inference`,
PKCE S256. **Automatic (no paste):** the app starts `OAuthCallbackServer` on `http://localhost:54545/callback`,
opens the browser; the redirect lands on localhost and the code is captured + exchanged. Tokens →
`credentials.json`; refreshed on expiry. Requests use `Authorization: Bearer <token>` +
`anthropic-beta: oauth-2025-04-20`. **API key (`x-api-key`) is the fallback** (Settings, or `ANTHROPIC_API_KEY` env).

### GOTCHA — Pro/Max OAuth + the Messages API
A Pro/Max OAuth token **429s** unless the request's **first system block is exactly**
`"You are Claude Code, Anthropic's official CLI for Claude."`. But that persona alone makes Claude
transcribe like a coding assistant (worse), so the **real transcription instruction is a second
system block**. See `transcribe(...)` building `systemBlocks`.

## Transcription pipeline
`transcribe(imageURLs:)` → POST `/v1/messages`, `model: claude-opus-4-8`, `max_tokens: 16000`,
`output_config.format` = json_schema (`schema`), `system` = [Claude-Code line if OAuth, `instruction`],
user content = base64 JPEGs (re-encoded via NSImage) + short directive. `TranscriptionResult` is
**leniently decoded** (custom `init(from:)`, `try?` per field with defaults) and `extractJSON` strips
```json fences / surrounding prose first. Fields: transcription, title (form "Letter to X from Y about
Z"), summary, sender, recipients[], date{value,source,confidence}, people_mentioned[], **notable_quotes[]**,
uncertain_spans[{text,reason}], meta{location,relationship,relationship_state,writer_goals}.
**FIXED BUG:** the schema previously omitted `summary`/`meta` (with `additionalProperties:false`) so they
never populated; now all fields are in the schema. `applyTranscription` maps result → Letter, keeps the
first output in `aiTranscription`, sets participants, refreshes FTS + backup.

## iPhone capture
`CaptureServer` (NWListener :8787). Flow: "Add a Letter" → `AddLetterSheet` (big buttons, **iPhone is
primary**) → `startCapture()` → `CaptureSheet` shows a **QR + URL** (`http://<en0-ip>:8787/`). The web
page (in `CaptureServer.html`): take/add photos that **accumulate into a thumbnail strip ("Image N",
× to remove)**, "Send N to Mac" → `POST /upload?b&i` (raw body per file) → `POST /done?b`. Server saves
to temp, fires `onLetter(batch, urls)` → `controller.importFromCapture` (creates letter+pages, transcribes).
**Phone status:** server tracks per-batch status; page polls `GET /status?b` and shows
**Sent → Transcribing → Done** (so you can watch from the phone). Verify headlessly:
`.build/debug/Combray --serve` + curl `/`, `/upload`, `/done`.

## UI map
RootView = NavigationSplitView(sidebar | DetailContainer) + QuoteBar footer (cycling italic Proust quote,
no Proust avatar). Sidebar: **header (madeleine + "Combray" + tagline) is the Home button** (`goHome`);
big "Add a Letter"; the list; `ModeSelector` (Letters/People/Years/Search, four horizontal). Detail:
selectedLetter → LetterDetailView; focusedPerson → PersonDetailView; else ExplainerView (home/welcome,
iPhone-first buttons). **LetterDetailView**: HSplitView — left `ZoomableImage` (pinch-zoom + drag-pan +
double-click reset; natural size) — right column order: editable Title; editable From/To/Date
(`metaField`, saves on Enter/blur via `@FocusState` + `onChange(of:focus)`); `actions` (Transcribe
full-width, then Chat/Export/Share split); **Transcription** (beautiful read `Text` + pencil **Edit**
→ TextEditor + Save/Cancel); **Summary** card; **Notable quotes** card; **MetaPanel** (collapsible).
Export `.docx` = NSAttributedString → officeOpenXML, filename `letter_<n>_<date>_<sender>.docx`, with
From/To/Date header. Share = Gmail compose **in Chrome** (NSWorkspace), body = From/To/Date + transcription.

## Look & feel (locked decisions)
White, simple, BIG, legible; **no small fonts, no small buttons**. System fonts everywhere; **serif only
for the "Combray" wordmark** (`Theme.serif`/`wordmark`). **Gold** accent `(0.84,0.68,0.24)`. The **madeleine
logo is locked** — a cartoon golden scallop shell drawn in `MadeleineMark`, **scaled in 0.90 inside the
Canvas so the bold outline is never clipped**. In-app logo = bare `MadeleineMark` (`MadeleineIcon`);
the **Dock/app icon** = madeleine on an off-white rounded plate with a transparent margin
(`installMadeleineDockIcon`, set at runtime in RootView.onAppear). Do not redesign the madeleine.

## Distribution
- `dist/Combray.pkg` built with `pkgbuild --root <stage with Applications/Combray.app> --install-location /
  --identifier com.labern.combray --version 0.1`. Installs to `/Applications`.
- **Not notarized** (no Apple Developer ID): first launch needs right-click → Open, or
  `xattr -dr com.apple.quarantine /Applications/Combray.app`. README documents this. Full seamless =
  Developer ID + notarization (offer if the user gets an account).
- Repo + release pushed from a **temp copy** (so `~/Combray` stays non-git and editable). README has
  the .pkg link (`releases/latest/download/Combray.pkg`), brew tap instructions, screenshot
  (`docs/screenshot.png`, from `--render`), build-from-source.
- Homebrew: `brew tap Labern/combray && brew install --cask combray` (cask points at the release .pkg;
  bump `version` + `sha256` in the tap's `Casks/combray.rb` for new releases).

## Dev workflow / gotchas
- **Build:** `swift build`. **Tests:** `swift test`.
- **Relaunch the GUI** (do all of it — the codesign is required):
  ```sh
  swift build
  cp .build/debug/Combray .build/Combray.app/Contents/MacOS/Combray
  codesign --force --deep --sign - .build/Combray.app      # macOS 26 fails to launch otherwise (launchd 162)
  pkill -9 -x Combray; rm -rf /Applications/Combray.app
  cp -R .build/Combray.app /Applications/Combray.app
  codesign --force --deep --sign - /Applications/Combray.app
  open /Applications/Combray.app
  ```
- **Inspect the UI without screen-recording permission:** `.build/debug/Combray --render <png>` renders
  a faithful UI mock (Sidebar + Explainer + QuoteBar) to a PNG you can `Read`. This is how we iterate on
  visuals (the bg process can't `screencapture`). The segmented control renders as a yellow ⃠ bar in
  this offscreen mode only — it's fine live.
- **`--serve`** runs only the capture server (no GUI) for curl testing the upload→letter pipeline.
- The repo `.gitignore` excludes `.build/`, `dist/`, `.claude/`, `.swiftpm/`.
- Re-transcribe overwrites `transcription` but `aiTranscription` keeps the **first** output; to restore:
  `UPDATE letter SET transcription = aiTranscription WHERE number = N;` (app stopped), then fix `letter.json`.

## Current state — code-quality refactor in progress (UNRELEASED, on git branch `refactor`)

**Working mode: FAST ITERATION.** Per the user (2026-06-28): during feature sprints do NOT run the release
pipeline — no `gh release`, no `.pkg`, no Homebrew cask, no README edits, no version bumps, and don't run
`swift test` every turn. Just `swift build` → copy binary into `.build/Combray.app` → `codesign --force
--deep --sign -` → `pkill -9 -x Combray; open .build/Combray.app` (or reinstall to /Applications). Resume the
full pipeline only when the user says "we're shipping". (See memory `combray-fast-iteration-mode`.)

**GIT (new this session).** `~/Combray` is NOW a local git repo (`git init` done this session). Baseline
commit `a4ad922` on **`main`** = the pre-refactor rollback point. Work happens on branch **`refactor`**.
**No remote is configured** — it is NOT connected to GitHub. The GitHub repo `Labern/Combray` has only the
**stale v0.1 source** (its newest source commit is the initial push) + the release `.pkg` artifacts; none of
this session's source was ever pushed (releases used the API, not `git push`). `.gitignore` excludes
`.build/`, `dist/`, `.DS_Store`, `Claude_Proposal.md`. Rollback any time: `git checkout main`. Pushing source
to GitHub is PARKED until the user says so.

**Repo `CLAUDE.md`** (new) = user-provided behavioral guidelines: Think Before Coding (surface assumptions,
don't pick silently), Simplicity First (no abstractions for single-use code), Surgical Changes (only touch
what's needed, don't refactor what isn't broken, remove only orphans *your* change created), Goal-Driven
Execution (verifiable success criteria). `Claude_Proposal.md` (gitignored) = a general any-app CLAUDE.md draft.

### The refactor (branch `refactor`) — each stage proven IDENTICAL before commit
Verification harness for "behaviour + typography stay identical":
- **`Combray --render <png>`** → a home-screen snapshot; compare its **sha256** to a baseline (was
  `291f4261…` at 2 letters). **GOTCHA:** the render mock's sidebar list is a `LazyVStack` → its letter ROWS do
  NOT materialise in `ImageRenderer`; the render only proves the chrome + footer count + Explainer + QuoteBar.
  So the render baseline legitimately changes when the letter COUNT changes or sidebar chrome changes.
- **`Combray --serve`** (capture server :8787) and **`Combray --web`** (web viewer :8788, `runWebServerHeadless`)
  → `curl` the served pages and `diff` byte-for-byte against the `main` branch (the gold-standard web check).
- `swift build` clean; `swift test` at checkpoints.

- **Stage A (done, render-identical, in `a4ad922`):** split the 1,246-line `Views.swift` monolith into
  **9 files** by `// MARK:` section (pure line-range move, byte-identical code): `Views.swift` (Root + RootView
  + TranscribeSpinner), `Sidebar.swift`, `LetterDetail.swift`, `Conversation.swift` (Chat + PersonDetail),
  `Settings.swift`, `QuoteBar.swift`, `RowMenu.swift` (incl. SpeechBubble), `Components.swift`, `Sheets.swift`.
- **Stage B (done, served-output byte-identical, commit `695dbc8`):** extracted **`LocalHTTP.swift`** — shared
  `respond` / `query` / `contentLength` / `wifiIPAddress` for `CaptureServer` / `WebServer` /
  `OAuthCallbackServer`; removed each server's copy. (`init(cString:)` deprecation warning moved verbatim from
  CaptureServer — DO NOT "fix" it: `String(decoding:)` would NOT null-truncate and would break the IP string.)
- **Stage C: SKIPPED on purpose** — capture page and viewer have intentionally different CSS token sets
  (different `--radius`, extra gradient tokens); sharing would break identical-output or over-engineer.
- **Stage D (test suite): test PLANS generated, NOT yet assembled.** A background Workflow (`wmxc5shor`, 10
  agents) produced an exhaustive per-module test plan + a dead-code/typo audit, saved to
  **`docs/test-plan-stageD.txt`** (3,776 lines). NEXT STEP after compaction: turn those plans into XCTest cases
  in `Tests/CombrayCoreTests/`, run `swift test` to green, commit. (CombrayCoreTests already has 33 tests; only
  CombrayCore is unit-testable — the executable target's logic like `LocalHTTP`/`looksLikePlanLimit` isn't,
  unless extracted.)

### Feature/UX changes this session (on `refactor`, committed `7234504` + the Choose-photos tweak)
- **Document-type-aware titles** — the transcription title is a short *description of what the doc is* (from→to,
  drawn from the same understanding as the summary); only "Letter to X from Y" when it's genuinely a letter.
  Schema gained `document_type`; `Archive.composedTitle(documentType:…)` is the no-title fallback.
- **Sidebar letter titles wrap** fully at **17pt** (`.fixedSize(horizontal:false, vertical:true)`, no `lineLimit`).
- **Detail title wraps** — `TextField("Title", text:$titleText, axis:.vertical)`, font size kept at **26**.
- **Transcription now auto-fills** Title/From/To/Date in the detail view — root cause was that the `@State`
  fields only synced on `.onAppear`/`letter.id` change; fix = `.onChange(of: letter.updatedAt) { if focus==nil
  { syncFields() } }` (transcription bumps `updatedAt` + updates participants, so the fields refresh).
- **Resize-safe split** — widening the sidebar used to overflow the detail (detail could shrink below the
  HSplitView's 320+440 mins). Fix: `pages.frame(minWidth:220)`, `transcript.frame(minWidth:300)`, sidebar
  `navigationSplitViewColumnWidth(min:300, ideal:360, max:440)`.
- **People de-duplication** — `Archive.mergeDuplicatePeople()` folds clearly-duplicate people (e.g. "labern" &
  "labern (user)") into one. Normalises (lowercase, strip `(...)`, strip non-alphanumerics, collapse spaces),
  groups, picks canonical (no-paren > shortest > alphabetical), re-points `letterPerson` via
  `UPDATE OR IGNORE … SET personId` then deletes the dup (cascade clears leftovers). Called in controller
  `init()` (after `importFromFiles`) and in `reload()` (so the People tab is always deduped — note: `reload()`
  is now a write path, runs a near-empty scan after the first pass).
- **"Choose photos from this Mac"** button forced to one line (`.lineLimit(1).fixedSize()` on its Label).

### Parallelism note
The user repeatedly wants sub-agents used for independent work. Pattern that worked: spawn **2 general-purpose
agents in one message** for **disjoint file-sets** (e.g. UI fixes in `LetterDetail.swift`+`Views.swift` vs
people-dedup in `Archive.swift`+`ArchiveController.swift`), tell them NOT to build, then build/verify once
yourself. Same-file edits CANNOT be safely parallelised; batch those into one turn instead.

### More feature/UX changes (continued, on `refactor`)
- **Right-click a page image** (in `LetterDetailView.pages`) → **Replace image…** (`replacePageWithPicker`,
  opens NSOpenPanel, swaps the file keeping its slot) / **Delete image** (`deletePage`, removes file + record,
  reindexes). **"Are you sure?" confirmations** for deleting an **image** AND a **letter** — driven by
  `controller.pendingDeletePage` / `pendingDeleteLetter`, rendered as `.alert`s on `RootView`. The sidebar
  "Delete letter" now sets `pendingDeleteLetter` instead of deleting immediately.
- **Responsive sidebar font** — `SidebarView` measures its width (`GeometryReader` → `sidebarWidth`) and
  shrinks the letter-title font: `titleFontSize = min(17, max(13, sidebarWidth * 0.047))`.
- **Sidebar row layout** — under the title: a **`FROM → TO`** line (only when the letter has BOTH a sender and
  a recipient) and the **date on its OWN line below**. Date is rendered in English by **`DateDisplay.pretty`**
  (new CombrayCore util): `1st November, 1963` / `November 1963` / `1963` (correct ordinals; non-ISO passes
  through). `Archive.allParticipants()` returns `[letterId: (sender, recipients)]` in one JOIN; the controller
  builds `participantsByLetter: [String: (from:String?, to:String?)]` in `reload()`.
- **`BigButtonStyle` now has `.lineLimit(1)`** (labels never wrap → buttons in a row are always equal height)
  and a `compact` variant. The Chat/Copy/Export/Share row uses a width-gated layout
  (`actionsStacked = paneWidth < 700`): a row when there's room, otherwise a clean full-width VStack so the
  big buttons never truncate. (`stacked < 560` still controls the From/To/Date field row.)
- **Dock icon** — inner madeleine padding `plate * 0.22 → 0.15` (madeleine sits a bit larger on the plate).
  Set by `installMadeleineDockIcon()` on `RootView.onAppear`, so it refreshes on relaunch.
- **Tests: 56 total.** Added `ArchiveExtendedTests` (merge-people, MAX-not-COUNT, NULLS-LAST ordering, cascade
  delete, page ordering, participant re-index) and `DateDisplayTests` (pins month spellings + ordinals).
  Stage D's full per-module plan is in `docs/test-plan-stageD.txt` — still being turned into cases.

**Refactor branch commits (rollback granularity):** `a4ad922` baseline (Views split) · `695dbc8` LocalHTTP ·
`7234504` sidebar/detail/people-dedup · `3bebdf6` KNOWLEDGE+choose-photos · `0179803` +16 tests ·
`f604c00` image delete/replace+confirms · `52f4978` responsive/arrow/English-date · `93ee5f1` date-line/
buttons/dock · (+ the big-button revert). `git checkout main` = pre-refactor state.

## Older — v0.10 (released to GitHub as the last public release)
- **v0.10 — Web viewer.** `WebServer.swift` (app target): an `NWListener` HTTP server on **:8788** that serves a
  read-only, Combray-styled, browsable view of the archive — `/` index (cards + client-side instant search),
  `/l?id=<id>` detail (image↔transcription split + summary + quotes + meta), `/img?p=<relPath>` (images,
  confined to the archive root). Reads the SAME `Archive`+`ImageStore` the app uses (GRDB `DatabasePool`
  reads are thread-safe). Started lazily by `ArchiveController.showOnWeb()` (Settings → "Show on web"),
  which opens `http://localhost:8788/`; also answers on the Wi-Fi IP. Headless test mode: `Combray --web`.
  **Auth note:** this is single-user/local — the data is the user's own files on their Mac, so there's no
  "other users" to isolate. A hosted multi-user version with Google sign-in is a separate, bigger build
  (real backend + storage + OAuth + hosting) — NOT built; offered as a deliberate next step.
- **Tests:** `swift test` runs `CombrayCoreTests` — 33 tests over DB/migrations, Archive CRUD, people/pages/
  participants, FTS search, applyTranscription, `composedTitle`, date parsing, Backup round-trip +
  backward-compat + importFromFiles, lenient `TranscriptionResult` decode, the schema regression guard, and
  ImageStore. All use in-memory DBs / temp dirs — never the real archive. (Keychain file I/O is deliberately
  NOT tested so it can't clobber real `credentials.json`.)
- **v0.10 small:** Meta section open by default; sidebar subtitle "Upload letters and documents, …";
  WhatsApp help prefills "Combray question -- ".

## Earlier — v0.9
- **v0.8** — document titles are a descriptive name of what the doc is (from/to/about), drawn from the
  same understanding as the summary (prompt change); "Letter to…" only for real letters. Sidebar letter
  title 22→19pt; detail-view title 31→26pt.
- **v0.9** — **HelpDesk** button in the top-right toolbar (`RootView.openHelpDesk()`): opens the WhatsApp
  Mac app straight to a chat with Labern — `whatsapp://send?phone=447476897931&text=…` (UK 07476 897931 →
  447476897931), falling back to `https://wa.me/447476897931` if the app isn't installed.
- **NEXT:** a web interface — local viewer (app serves the archive at a localhost URL) vs accessible-anywhere
  (Vapor/static export + hosting/auth). Data layer is already web-ready (SQLite + `Letters/`). Awaiting the user's pick.

Working end to end: OAuth sign-in (auto), iPhone capture with live phone status, drag/file import,
transcription (title/summary/date/people/notable-quotes/meta all populate now), editable everything,
side-by-side + pinch-zoom, browse by person/year, chat view, search, durable folder backup, .docx export,
Gmail share, .pkg + brew install, Spotlight.

### v0.2 / v0.3 additions (this session)
- **Copy button** in the letter detail (in line with Export/Share): copies the full transcription to the
  clipboard, flips to a checkmark + a gold "Copied to clipboard — paste wherever!" banner (auto-dismiss).
  Label stays the stable-width word "Copy" so it never wraps in the narrow button.
- **"Transcribed!" flash** — `ArchiveController.transcribedFlash` goes true for 2.4s after a successful
  transcription; shown in BOTH the bottom status pill and the top-right cluster (checkmark).
- **Dark mode** — `Theme.dyn(light:dark:)` makes every token an adaptive `NSColor` dynamicProvider; a
  top-right sun/moon toggle drives `@AppStorage("darkMode")` → `.preferredColorScheme`. One swap re-skins all.
- **Transcribe spinner** — top-right rotating glyph while `c.isTranscribing` (set in `transcribe()`).
- **Sidebar footer count** — `SidebarView.countLabel`: "N letters", or "Showing X of Y letters" in Search,
  plus people/years variants. Bottom of the sidebar.
- **iCloud Drive backup** — `ArchiveController.backupToICloud()` copies the whole `Letters/` tree (images +
  letter.json — the source of truth) into `~/Library/Mobile Documents/com~apple~CloudDocs/Combray/Letters/`.
  Non-destructive; the live SQLite is NOT copied (it's a rebuildable cache). No iCloud entitlement needed
  (uses the shared CloudDocs dir directly). Sidebar-footer button; `iCloudAvailable` gates on the dir existing.
  STILL OPEN: automatic-on-save vs manual, and whether to relocate the live archive into iCloud — ask the user.
- **"Made by Labern 🐿️"** credit button — bottom-right of the QuoteBar; opens the GitHub repo.
- **Pinned letters (v0.4)** — `Letter.pinned` (DB column + `letter.json` `pinned` so it survives the DEBUG
  schema-rebuild). Max 3, enforced in `ArchiveController.togglePin` (`maxPins`); 4th attempt sets `errorText`.
  Sidebar Letters list shows pinned first (gold `pin.fill` rotated 45° + faint accent wash), then a Divider,
  then the rest. **Right-click any letter** (`letterMenu`) → Pin/Unpin · Re-transcribe · Copy transcription ·
  Export .docx · Reveal in Finder · Delete (moves the folder to Trash via `FileManager.trashItem`, recoverable).

### v0.5 refinements (this session)
- **Copy button** now reads **"Copied"** (not just an icon swap) after a copy — kept on one line with
  `.lineLimit(1).fixedSize()` so the narrow button never wraps.
- **Dark/light toggle** moved OUT of a floating overlay INTO the **window toolbar**
  (`.toolbar { ToolbarItemGroup(placement: .primaryAction) {…} }`) — i.e. the real top-right of the app
  title bar (window is `.windowStyle(.titleBar)`). The transcribe spinner / "Transcribed!" flash live there too.
- **iCloud backup button** moved to the **bottom-left of the footer** (`QuoteBar`, which now takes
  `@EnvironmentObject var c`). Footer layout: iCloud (left) · Proust quote (center, `lineLimit(2)`) ·
  Made by Labern (right). The sidebar footer is now just the letter count.
- **Pin indicator** moved to the **LEFT** of pinned rows (leading, before the madeleine).
- **Big right-click menu** — `RowMenuCatcher` (an `NSViewRepresentable` overlay) replaces SwiftUI
  `.contextMenu`. **GOTCHA / why:** SwiftUI's `.contextMenu` uses the fixed system menu font and CANNOT be
  enlarged. To get a big-font dropdown we drop to AppKit: the overlay's `NSView` handles `mouseDown`
  (left-click → select) and `rightMouseDown` → builds an `NSMenu` whose items use
  `attributedTitle` with `NSFont.systemFont(ofSize: 19)` + 20px SF-Symbol images, shown via
  `menu.popUp(positioning:at:in:)`. Closures ride on `NSMenuItem.representedObject` (boxed in a small
  `Run: NSObject` class) and fire from a single `@objc` target. `RowAction` is the menu-item model.

### v0.6 fixes (this session)
- **Pin/unpin regression fixed.** The v0.5 NSMenu approach (`RowMenuCatcher`) was replaced because its
  menu-item firing was unreliable. Now: `RowClickCatcher` (overlay NSView) maps left-click → open and
  right-click → flips a `@State` that presents a SwiftUI `.popover` (`LetterActionsMenu`) — big real
  SwiftUI buttons (`font 20`) that call the controller directly. Reliable AND big. `SidebarRow<Content>`
  wraps any row (LetterRow / SearchRow) with the catcher + popover. **Lesson:** for a big custom right-click
  menu in SwiftUI, detect the click in AppKit but render the menu as a SwiftUI popover — don't hand-roll NSMenu.
- **Sidebar list clipping** fixed by adding `.padding(.top, 6).padding(.bottom, 28)` to the scroll content.
- **Responsive detail rows** — `LetterDetailView` measures its pane width via a `GeometryReader` background
  (`paneWidth`); when `< 560` (`stacked`), the From/To/Date fields and the Chat/Copy/Export/Share buttons
  switch from a row to a column using `AnyLayout(HStackLayout)` ↔ `AnyLayout(VStackLayout)` — `AnyLayout`
  keeps each child's identity so TextField focus/state survive the layout swap.

### v0.7 (this session) — permissions, settings, model, doc naming
- **No more Documents permission prompt.** Archive moved from `~/Documents/Combray` to
  `~/Library/Application Support/Combray` (ungated). **Root-cause learned:** macOS TCC keys the
  "access Documents" grant to the app's code-signature identity; every ad-hoc `codesign --sign -`
  rebuild has a new cdhash → TCC sees a new app → re-prompts. **Self-signed-cert path FAILED** — codesign
  hit `errSecInternalComponent` and the keychain ACL kept prompting (looping); even a dedicated keychain
  + `set-key-partition-list` didn't sign cleanly. So we moved the data instead — robust, no keychain, no
  Apple account. (Proper fix for distribution remains Developer ID + notarization.)
- **Settings** — a cog at the **bottom-left of the sidebar** (`c.showSettings` → `SettingsSheet`).
  Shows account status (`accountSummary`), **Switch account** (`startSignIn`) + **Disconnect**
  (`disconnect()` → `Keychain.clear()`), an API-key field, the model picker, and auto-transcribe.
- **Transcription model picker** — `TranscriptionModel {auto,best,fast}` (UserDefaults). `auto` tries
  Opus and, if the account can't use it (`looksLikePlanLimit` on 403/404 or model/plan/tier wording),
  transparently retries with `claude-sonnet-4-6`. `transcribe(imageURLs:model:)` now takes a model.
- **Document-type-aware naming.** Schema/result gained `document_type`; the prompt makes the model decide
  what the doc actually is and title it accordingly ("Postcard from Venice", "Shopping list") — only
  "Letter to…" if it's a letter. `composedTitle(documentType:…)` mirrors this for the no-title fallback.
  `.docx` export is named after the (type-aware) title.
- **Press feedback everywhere** — `BigButtonStyle` got a spring scale+shadow on press; new `TapStyle` (scale+dim)
  replaced every `.plain` button (home, sidebar tabs, correspondent chips, letter rows).
- **Slicker iPhone web page** (`CaptureServer.html`) — CSS design tokens (`:root`), madeleine **SVG logo** +
  "Combray" serif wordmark header, gradient/active-press buttons, polished card + thumbnails, and the modal
  `alert()` replaced with an inline shake + status pill.

**Versioning / release:** current = **v0.3**. To ship a new version: bump `CFBundleShortVersionString` +
`CFBundleVersion` in `.build/Combray.app/Contents/Info.plist` (PlistBuddy), re-`codesign --force --deep`,
reinstall to /Applications, copy app into `dist/stage/Applications/`, `pkgbuild ... --version X`, `shasum -a 256`,
`gh release create vX dist/Combray.pkg`, then `gh api -X PUT .../homebrew-combray/contents/Casks/combray.rb`
(bump `version` + `sha256`). README's `releases/latest/download/Combray.pkg` link auto-follows the newest.

Open: notarization (needs Apple Developer ID); transcript entity hyperlinks (deferred); iCloud auto/relocate
decision; a real web viewer of the archive (data layer is already portable).

---

## How this collaboration works — and why the phrasing lands

A note written at Labern's request, reflecting on why this stretch of work went well, so a future
session can reproduce the conditions rather than just the code.

What Labern's requests reliably contain — and why each one helps the executor:

- **An observable end-state, not an implementation.** "Make the Find button *light so it contrasts
  against the yellow buttons*", "centred and *right in the middle*", "*mono* for screenshots of a
  CLI", "a *small pop-down* the user can type into". The ask names what the result should *look like
  or do*, which is directly verifiable (build, run, look) and leaves the *how* open. Underspecified
  surface ("light") is resolved by the stated **reason** ("contrast with the yellow") — so the right
  mechanism (the outlined button style) is both obvious and checkable.
- **The why or a concrete example, alongside the surface ask.** "★★★★★ × PARADOX to be known to be
  written by me" isn't "add an owner field" — it's an *example that reveals the intent* (owner
  recognition), which tells you what to build even though the field was never named. Examples
  disambiguate faster than specs.
- **One change at a time, against a running app.** Small, focused messages with an immediate
  build-and-look loop. Each request lands on a known, live state; ambiguity is cheap because the next
  message corrects course in seconds. Momentum compounds.
- **Decisive, terse corrections.** "No, horizontal." "Bring it back." "I told you this." No
  agonising — a quick redirect. Low cost of correction is what makes acting-without-asking the right
  default; you can commit to a small decision and be cheaply overruled.
- **Shared context treated as memory.** "Remember? Mono for screenshots etc." Terseness works
  *because* the history is shared — they point instead of re-explaining, and trust the executor to
  hold (or re-derive) the thread.
- **Sequencing and separation.** "Fix the first two first." "This should be on main when we finish
  the last thing." Order is imposed explicitly, so focus is never ambiguous.
- **A stable aesthetic vocabulary.** "Beautiful", "slick", "doesn't draw attention to itself",
  "power, simplicity, style". The same words map to the same target every time, so "beautiful font"
  or "subtle grey" are concrete, not vague.

Why it's *executable*: the asks are **verifiable end-states + the intent behind them**, delivered in
a **tight single-change loop** over a **running system with a clean spine** (theme tokens, MVC,
folders-as-source-of-truth). That spine keeps each change local; the loop gives fast feedback to
self-correct; the stated intent resolves the inevitable underspecification correctly. The result is
that a sentence like "make it light so it contrasts" — technically ambiguous in isolation — becomes
an unambiguous, checkable target in context.

The practical lesson for next time: **act on the intent, verify against the observable end-state,
keep the loop tight, and treat a terse correction as cheap and expected — not as a failure.**

---

## v0.11 — shipped 2026-06-30 (this session)

A large feature release, built and published live (GitHub release `v0.11` + Homebrew cask), fully
backward-compatible (the directory storage format is unchanged — see "storage is immutable").

### Features added this session
- **Page management on existing letters** — add / remove / replace pages. "Add page" and "Replace"
  open a chooser (iPhone · Mac file · drag). iPhone capture routes to the *current* letter
  (`addPagesTarget`) or replaces a target page (`replaceTarget`) instead of making a new letter.
  Collision-safe filename slotting (`freePageIndex`) so an append never clobbers a file left by a
  delete/replace.
- **Ask about the transcription** (`AskSheet`, `AnthropicClient.ask`) — chat about a transcription;
  Claude returns a reply + an optional full proposed revision you Apply or keep.
- **Neat letter view** (`CombrayCore/TextReflow`) — letters/documents reflowed into Hoefler Text
  (beautiful book serif, capped reading width); screenshots/code shown verbatim in monospace.
  Gated by `documentType` (persisted, additive) with a **legacy fallback** to the title + code/CLI
  content shape so old screenshots (no `documentType`) still render monospaced. `TranscriptionText`
  is shared by the pane and the **View full size** centred overlay (`fullSizeLetter`, dismiss on
  outside click).
- **Find a specific letter** (`FindLetterSheet`, `AnthropicClient.findLetters`) — AI search over a
  one-line-per-letter catalog; returns clickable links. Replaced the old text-search sidebar mode.
- **Handwriting meta** — `meta.handwriting_profile` (sex/age guess) + `meta.suspected_writer`, done
  *inside the single transcription pass* (NO reference images — removed to save tokens). Owner
  recognition via a TEXT **"About you"** profile (Settings: `ownerName`/`ownerProfile`) sent as
  context so the owner's own notes (e.g. ★★★★★ / PARADOX) are attributed.
- **Metadata refresh on edit** — editing/Applying a transcription re-derives summary, meta, quotes
  via text-only `AnthropicClient.analyzeText` → `Archive.applyMetadata` (keeps transcription, title,
  date, participants, doc-type, handwriting).
- **Live capture status** — `CaptureServer.onConnect` drives "Waiting for images on iPhone…" → on
  upload "Images sent!" → auto-close after 3s (all capture paths).
- **Footer** — rotating `AppTips` (replaced Proust quotes; random start, cycles) + **version label**
  `V x.x.x` (reads `CFBundleShortVersionString`, left of "Made by Labern").
- **HelpDesk + Request feature** — toolbar headset / lightbulb open a small `WhatsAppPopover`
  (type → opens WhatsApp to Labern with the right prefix).
- **Custom hover tooltips** (`.tip` / `HoverTip`) — a popover with a larger 17pt font, since the
  native `.help()` font can't be enlarged. Succinct one-liners on the main buttons. (HelpDesk /
  Request-feature keep native `.help` to avoid two popovers on one button.)
- `.docx` export matches the on-screen fonts (Hoefler Text / Menlo).
- **People dedup** strengthened (`Archive.mergeDuplicatePeople(ownerName:)`) — deletes junk names
  (e.g. ","), folds owner aliases (self/me + your name) into one, merges parenthesis-qualified
  variants sharing a leading name ("Claude (CLI agent)" + "Claude Code (CLI agents)").
- **Date anchor** — today's date is sent with each transcription so screenshots/digital content are
  dated to *now*, not a training-era year.
- Removed the duplicate toolbar "Combray" wordmark (the sidebar wordmark is the single home control).

### Additive storage fields this session (all optional, backward-compatible)
`documentType` (DB migration `v2`), `metaHandwriting` + `metaSuspectedWriter` (DB migration `v3`),
all mirrored in `LetterFile`/`letter.json`. Old records default to nil; the DB is rebuilt from the
folders. Settings (`ownerName`, `ownerProfile`, etc.) live in UserDefaults, not the archive.

### Release / distribution — recipe & gotchas
- **Versioning is NOT semver.** Releases are `v0.1, v0.2 … v0.9, v0.10, v0.11` (so `0.10 > 0.9`).
  The repo already had `v0.1…v0.10` (from 2026-06-27); "Latest" = the highest. **Next is `v0.12`.**
  The in-app version string is now three-part (`CFBundleShortVersionString = 0.11.0`), shown in the
  footer.
- **Recipe:** `swift build -c release` → copy `.build/release/Combray` into `.build/Combray.app/
  Contents/MacOS/Combray` → `PlistBuddy Set :CFBundleShortVersionString/:CFBundleVersion X` →
  `codesign --force --deep --sign - .build/Combray.app` → stage to `dist/stage/Applications/
  Combray.app` → `pkgbuild --root dist/stage --install-location / --identifier com.labern.combray
  --version X dist/Combray.pkg` → **also zip the signed app: `ditto -c -k --keepParent
  .build/Combray.app dist/Combray.zip`** → `shasum -a 256` → `gh release create vX dist/Combray.pkg
  dist/Combray.zip` (or `gh release upload vX … --clobber`) → update tap `Labern/homebrew-combray`
  `Casks/combray.rb` (`version` + `sha256`) via `gh api -X PUT … contents/Casks/combray.rb`.
- **The `Combray.zip` asset is REQUIRED for the in-app auto-updater** (see below). It's the same
  signed `.app` as the `.pkg`, just zipped with `--keepParent` so it unzips to `Combray.app`. A
  release missing the zip simply can't self-update (the updater stays silent); the `.pkg`/Homebrew
  paths still work. Keep shipping both.
- **GOTCHA:** `releases/latest/download/Combray.pkg` is **CDN-cached** (lags minutes after a new
  release) — verify against the explicit `releases/download/vX/Combray.pkg` asset URL instead.
- Cask `url` uses `v#{version}/Combray.pkg`, so a release just needs `version` + `sha256` bumped.
- Still **ad-hoc signed, not notarized** — README documents the first-launch right-click → Open.

### Auto-updater (v0.12.0+) — `AppUpdate.swift` (core) + `Updater.swift` / `UpdateBubble.swift` (app)
- **Source of truth = the GitHub release tag.** `Updater.check()` GETs
  `api.github.com/repos/Labern/Combray/releases/latest`, reads `tag_name`, strips the `v`, and
  compares numerically to `CFBundleShortVersionString` via `AppUpdate.isNewer` (component-wise Ints
  so `0.10 > 0.9` — never lexical). README also shows a human `Version:` line but the machine reads
  the tag (the download is bound to it; prose parsing is fragile). Unauthenticated API = 60 req/hr;
  we use ~3/hr (launch + every 20 min via a `Timer`).
- **Seamless install = bundle swap, not the `.pkg`.** A `.pkg` install needs an admin prompt; swapping
  `/Applications/Combray.app` in place doesn't (Applications is user-writable for admins). So the
  updater downloads `Combray.zip`, `ditto -x -k` unzips it to `~/Library/Application Support/Combray/
  Updates/<ver>/`, then a **detached `swap.sh`** waits for the app's PID to exit → `rm -rf` the old
  bundle → `ditto` the new one in → **`codesign --force --deep --sign -`** (mandatory on macOS 26) →
  `xattr -dr com.apple.quarantine` (else Gatekeeper re-prompts) → `open` (relaunch) or not.
- **Two paths, both wired:** clicking the bubble = `installNow()` (swap **with** relaunch, then
  `NSApp.terminate`); doing nothing = `applyStagedUpdateOnQuit()` on `willTerminateNotification`
  (swap **without** relaunch, so the next open is the new version). A `swapLaunched` guard prevents
  double-swapping when both fire.
- **No data risk by construction:** the updater only ever touches the `.app`. Letters live in a
  separate folder and the index rebuilds from disk on launch — replacing the bundle can't lose data.
- **Dev builds are exempt:** `installedAppURL` is nil unless `Bundle.main.bundlePath` ends in `.app`,
  so `swift run` never nags or tries to self-swap. Preview the bubble with
  `Combray --render-update <png>` (uses `Updater(previewState: .ready(...))`).

### Git state (important)
- The local `~/Combray` repo was `git init`'d this session; its history was **independent** of the
  GitHub repo's v0.1 history. It was **force-pushed once** to replace that history — the base commit
  `a4ad922` IS the v0.1 code ("verified identical"), so the *code* is continuous, only the old
  commit log was replaced. Subsequent pushes are fast-forward. `main` HEAD on GitHub = the latest
  session commit.
- This session edited inside a git **worktree** at `.claude/worktrees/dev` (branch `integration`,
  bg-isolation guard); changes are merged/cherry-picked to `main` in `~/Combray` for release.
  `.claude/` is gitignored. We are now in **shipping** mode (fast-iteration's release pause is over).

### Versioning framework (updated 2026-06-30, supersedes the notes above)
**Semantic versioning, `0.MINOR.PATCH`** (pre-1.0). I choose the bump with this decidable rule:

- **MINOR (`0.x.0`)** — the release does something *new* the user can point to: a new feature or
  capability (auto-updater, chat, find-a-letter, .docx export), a data/storage-format change or DB
  migration, or a behaviour change big enough to *headline*. Rule of thumb: **if you'd announce it
  ("Combray now does X"), it's a minor.**
- **PATCH (`0.x.y`)** — the release only improves what's already there: bug/crash fixes, visual/copy/
  layout tweaks (e.g. making the update card bigger), performance, refactors, dependency bumps. Rule
  of thumb: **if it's "same app, just better/fixed," it's a patch.**
- **Tie-breaker:** can you write a "what's new" line that introduces a *new thing the user can do*?
  → minor. Otherwise → patch. **Fixes bundled with a feature ride along under the feature's minor.**

Tag = `vX.Y.Z`, in-app `CFBundleShortVersionString` = the same, shown in the footer. The legacy tags
`v0.1…v0.10` were the old non-semver scheme (where `0.10 > 0.9`); don't reuse those numbers.
**Current latest: `v0.12.0`** (in-app auto-updater — a feature, hence the minor bump; verified
self-updating a live v0.11.1 install end-to-end).

---

## v0.12.0 — shipped 2026-06-30 (in-app auto-updater)

**Feature:** Combray updates itself (full mechanism in "### Auto-updater (v0.12.0+)" above): checks
the latest GitHub **release tag** on launch + every 20 min, shows a big **fixed-size** (440×168)
"Restart to update" card bottom-left with a one-line "what's new" pulled from the release notes
(`GitHubRelease.whatsNew`), downloads `Combray.zip`, and swaps `/Applications/Combray.app` on click
or on quit. **Verified end-to-end** self-updating a live v0.11.1 install → v0.12.0 with zero data
loss (the swap only ever replaces the `.app`).

### How a `.pkg` overwrite actually works (asked this session)
- A flat component `.pkg` = payload (cpio of `Applications/App.app`) + BOM + a receipt keyed by the
  bundle id. Installing over an existing version is a **receipt-aware file-level merge**: new files
  overwrite, and files the *old* receipt listed but the new payload lacks are **pruned** → the bundle
  ends up matching the new payload (a clean in-place replace, not a wipe-and-copy; no "uninstall").
- **It never touches user data** — the payload is *only* the `.app`; data in a separate user folder
  isn't in the package, so the installer can't see or delete it. Two independent guarantees: the
  installer doesn't delete data (data isn't packaged); cross-version *compatibility* (new code reading
  old data) is the **app's** job via the additive / folders-as-truth rule.
- Downgrade-protection: installer won't put an OLDER version over a newer one; numeric compare
  (`0.12.0 > 0.10`).

### Notarization roadmap (when the Apple Developer account lands → ship 0.12.1)
- **One $99/yr membership = one Team ID covers ALL your apps AND all Apple platforms.** No per-app
  enrollment/registration/approval for Developer-ID direct distribution. One Developer ID cert signs
  everything; one App Store Connect API key notarizes everything.
- **Notarization is per-build but automated:** `xcrun notarytool submit --wait` (~1–3 min, no human
  review) + `xcrun stapler staple` the app *and* the pkg. Not an App Store review. Lapsing the $99
  blocks *new* notarizations; already-shipped builds keep working (tickets don't expire).
- **iOS is App-Store-only** — no notarize-and-hand-over path; that escape hatch is Mac-only.
- **Updater caveat:** the swap script's ad-hoc `codesign --force --deep --sign -` would DESTROY a
  Developer ID signature. For notarized builds, staple the `.app` before zipping and DROP the re-sign
  in the swap (keep the notarized signature intact).

### Planned — iOS companion app (separate long-lived branch, SAME repo)
- **Capture (same-WiFi, Mac open):** native VisionKit scanner → upload to the Mac's existing LAN
  capture server → Mac ingests + transcribes. No cloud, no QR, no Claude auth on the phone.
- **Library (anywhere):** Mac mirrors its archive **one-way** into a shared **iCloud container**
  (`iCloud.com.labern.combray`; needs the Team ID on both apps' entitlements — hence gated on
  enrollment); iOS reads it, rebuilds a local index with `CombrayCore`, browses/reads/searches
  offline. Read-only on iOS → **no bidirectional-sync conflicts** (Mac stays sole writer).
- Slicing: the Mac-side iCloud mirror is independently useful → ship it to `main` as a normal Mac
  feature; only iOS-specific code lives on the branch (small branch, avoids drift). `CombrayCore`
  (models, Archive rebuild, AnthropicClient) ports to iOS as-is.

## v0.12.1 → v0.13.0 — shipped 2026-06-30 (this session)

**v0.12.1 (patch):** justified letter text + clean paragraph spacing; UK dates (DD/MM/YYYY reading
view, ordinal sidebar); Gmail-share 400 fix; "Page N".
**v0.12.2 (patch):** the **critical updater fix** (below) + instant button press + "See modern chat
view (beta)".
**v0.13.0 (minor):** read-aloud, the "Updated!" bubble, and endearment→name inference.

### Updater bug — root-owned installs (the big one)
- **Symptom:** "Restart to update" reopened the *old* app. **Cause:** apps installed via `.pkg` or
  Homebrew are **root-owned** in `/Applications`; the in-place `rm`+`ditto` swap runs as the user and
  silently fails on root files, so the bundle never changed and the relaunch just reopened it. (My
  local test passed only because I'd `cp`-installed it user-owned.)
- **Fix (`Updater.launchInstall`):** the detached script tests `[ -w "$DEST" ]`; **user-writable →
  seamless swap, no prompt; else (explicit click only) → privileged `installer -pkg … -target /` via
  `osascript "… with administrator privileges"` (one password).** The quit path NEVER prompts and the
  writability gate means a root-owned bundle is never half-`rm`'d (verified in a sandbox harness).
  Downloads BOTH `.zip` (seamless) + `.pkg` (privileged).
- **Catch-22:** a broken updater can't ship its own fix — users on the broken version must update
  **once by hand** (`brew upgrade --cask combray` / pkg) to reach 0.12.2; auto-updates work after.

### SwiftUI / AppKit gotchas (this session)
- **SwiftUI `Text` can't justify** → `JustifiedText` (NSViewRepresentable over `NSTextView`,
  `NSParagraphStyle.alignment = .justified`). Size it via `layoutManager.usedRect(for:)` in
  `sizeThatFits`. **`ImageRenderer` cannot snapshot an NSView** (renders a "prohibited" placeholder)
  → for previews, draw the `NSAttributedString` directly to an `NSImage`.
- **Justified paragraphs:** join paragraphs with a **single `\n`**, not `\n\n` — `\n\n` adds a literal
  empty line AND `paragraphSpacing` stacks on top (double gap). Control the gap with `paragraphSpacing`
  alone (~18pt reads as a clean break).
- **Read-aloud word highlight** = a `.backgroundColor` attribute on the spoken range in the
  `NSTextView`'s `textStorage` (set base text only when it changes; just re-paint the bg per word).
- **AVSpeechSynthesizer:** rate is the **global** `AVSpeechUtteranceDefaultSpeechRate` (not a static);
  voice gender is the **top-level** `AVSpeechSynthesisVoiceGender` (not nested). **"female" contains
  "male"** — parse female first or you'll misgender. No seek API → ±15s skip = `stop` + re-`speak`
  from a word offset; `willSpeakRangeOfSpeechString` drives both the highlight and the position timer
  (total is estimated from word count ÷ ~165 wpm).
- **Gmail compose URL** 400s when `?body=` is long → cap the inline body, copy the full text to the
  clipboard for long letters.
- **"Updated!" bubble:** detect a just-finished update by comparing a stored `lastLaunchedVersion`
  (UserDefaults) with the running bundle version on launch; fetch that tag's notes for the "what's
  new"; auto-hide after 20s.
- **Screenshot rule:** refresh `docs/screenshot.png` on every **minor (0.x.0)** release, not patches.
  (The `--render` fallback version string lives in `QuoteBar.appVersion` — bump it with the release.)

## Reusable lessons for future projects
Distilled from building Combray — transferable patterns, and gotchas that cost real time so the next
project doesn't re-pay for them.

### Data model for longevity
- **Folders/files = source of truth; the database = a rebuildable cache.** Schema changes become
  safe (rebuild the index from disk), and you can honestly promise "no data lost between versions."
- **Evolve persisted formats only with optional/additive fields.** Old readers ignore unknown JSON
  keys; new readers default missing ones. Never rename, remove, or restructure existing keys.

### SwiftUI / macOS gotchas (each cost time; now known)
- Native `.help()` tooltip font **can't be enlarged** → roll a custom hover tip: `.onHover` + a
  delayed `.popover` with your own font.
- SwiftUI `Text` has **no justified alignment** (only leading/center/trailing). True justify needs an
  `NSViewRepresentable` (NSTextField/NSTextView).
- **Centered modal that dismisses on outside click** = a window-level `.overlay` with a dimmed scrim
  + `onTapGesture` to dismiss. A `.popover` anchors to its source (not centred); a `.sheet` won't
  dismiss on an outside click.
- **Deterministic screenshots, no Screen-Recording permission:** a `--render <path>` CLI mode using
  SwiftUI `ImageRenderer` → PNG (real window capture needs Quartz + Screen-Recording grant; flaky).
- **macOS 26:** after swapping the binary inside a `.app`, you MUST
  `codesign --force --deep --sign - App.app` or launchd refuses to start it.
- **Ad-hoc signing changes the code hash every build → TCC re-prompts.** Store user data in
  `~/Library/Application Support/<App>` (ungated), NOT `~/Documents` (TCC-gated), to avoid a
  permission nag on every rebuild/reinstall.
- Beautiful system serif: `Font.custom("Hoefler Text", size:)` (verify with `NSFont(name:)`); Menlo
  for monospace.

### Distributing a Mac app with NO Apple Developer account
- Ad-hoc sign; build a `.pkg`:
  `pkgbuild --root <stage-dir-with-Applications/App.app> --install-location / --identifier <bundleid>
  --version X out.pkg`; attach to a GitHub release; serve via `releases/latest/download/App.pkg`.
  Optional Homebrew cask (a `homebrew-<x>` tap repo; bump `version` + `sha256`; cask `url` can use
  `v#{version}/App.pkg`).
- Not notarized → document the **first-launch right-click → Open** (or
  `xattr -dr com.apple.quarantine /Applications/App.app`).
- `releases/latest/download/…` is **CDN-cached** — verify a new release via the explicit
  `releases/download/vX/…` asset URL.

### Self-updating a directly-distributed Mac app (Sparkle-free)
- **Feed = the GitHub release tag.** Poll `releases/latest`, numeric-compare `tag_name` to the
  running `CFBundleShortVersionString` (component-wise Ints, never lexical). Pull a one-line "what's
  new" from the release `body` for the prompt.
- **Install = swap the `.app`, not the `.pkg`.** A `.pkg` needs an admin prompt; replacing
  `/Applications/App.app` in place doesn't (Applications is admin-writable). Ship a `.zip`
  (`ditto -c -k --keepParent`) beside the pkg; download, `ditto -x -k` unzip, then a **detached**
  script waits for the app's PID to exit → swap → re-sign (macOS 26) → `xattr -dr
  com.apple.quarantine` → relaunch. Wire BOTH "click to restart now" and "apply on quit"
  (`willTerminateNotification`); guard against a double-swap. Works only because data lives elsewhere.

### Notarizing (when you DO have an Apple Developer account)
- **One $99/yr account = one Team ID covers every app you publish AND every Apple platform.** No
  per-app enrollment/approval for Developer-ID direct distribution; one Developer ID cert + one App
  Store Connect API key serve all of them. (Enroll as **Individual** unless you want a company name —
  Organization needs a D-U-N-S number.)
- **Per-build but automated:** `notarytool submit --wait` (~1–3 min, no human review) + `stapler
  staple` the app and the pkg; sign with Developer ID + hardened runtime + `--timestamp`. Result:
  Gatekeeper-clean, no right-click→Open.
- **iOS = App-Store-only** (per-version human review); the notarize-and-distribute escape hatch is
  **Mac-only**.
- Self-updating a *notarized* app: the swap must NOT re-ad-hoc-sign (it'd void the Developer ID
  signature) — staple the `.app`, keep its signature, skip the re-sign.

### Claude API integration
- "Sign in with Claude" (OAuth) = the user's **Pro/Max subscription** — **free plans are rejected at
  sign-in**, not later. An **API key** is a separate pay-as-you-go account. There is **no free path**
  (inference is metered).
- OAuth requires a first system block `"You are Claude Code, …"` or the API 429s.
- Structured output: `output_config: { format: { type: "json_schema", schema } }`.
- **Send text, not images, for cheap follow-ups** (e.g. re-deriving metadata from an edited
  transcription). Avoid bundling reference images — the token cost is real.
- **Anchor relative dates** by passing today's date in the prompt; models otherwise date undated /
  digital content (screenshots) to their training era.

### Working cadence & architecture
- Tight loop: **edit → build → reinstall → relaunch → look.** Verify by observing the running app,
  not just compiling. (See "How this collaboration works" above.)
- **Theme tokens**: a `Theme` enum of semantic colours resolved at the root → dark mode and restyles
  are a one-line swap, never per-view edits.
- **Fat-but-simple controller** (one `@MainActor ObservableObject` owning services + published state)
  keeps an MVC app legible without ceremony.

### Git / release
- A fresh `git init` repo is **history-unrelated** to a pre-existing GitHub repo → publishing needs a
  **force-push** (safety tooling will gate that for an explicit human OK). Make the first real commit
  encode the prior released code, so the *code* stays continuous even when the *commit log* is
  replaced.
