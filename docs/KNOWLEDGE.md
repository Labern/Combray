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

## Current state / next — v0.10 (released)
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
