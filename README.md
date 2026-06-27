# Combray

*One bite of the madeleine brings it all back.*

A personal **macOS** app that rescues **near-illegible handwritten letters** into a searchable,
browsable archive. Photograph a letter with your iPhone, and **Claude** transcribes it — then stores
it as a structured entry (sender, recipient, date, summary), side-by-side with the photo, organized
by people and year, searchable in full text.

![Combray](docs/screenshot.png)

## Download

### Installer (.pkg)

Download the latest **[Combray.pkg](https://github.com/Labern/Combray/releases/latest/download/Combray.pkg)**
and open it. It installs **Combray** into your **Applications** folder (so it shows up in Spotlight,
Launchpad, and the Applications window).

> Combray isn't notarized yet, so the **first** time you open it, right-click **Combray** in
> Applications → **Open** (or run `xattr -dr com.apple.quarantine /Applications/Combray.app`).
> After that it opens normally.

### Homebrew

```sh
brew tap Labern/combray
brew install --cask combray
```

### Build from source

```sh
git clone https://github.com/Labern/Combray
cd Combray
swift run Combray
```

## What it does

- **Sign in with Claude** — one click, no API key (uses your Claude plan). A browser page opens,
  you approve, and you're in.
- **Add a letter from your iPhone** — the Mac shows a QR code; open it on your phone, photograph
  each page (they appear in a strip as you go), and they upload straight into a new letter. Your
  phone even shows *Sent → Transcribing → Done*. (Or drag photos in / choose from the Mac.)
- **Claude transcribes** the handwriting — faithfully, preserving stars, symbols, and layout — and
  fills in a "Letter to … from … about …" title, the sender, recipients, date, and a summary.
  Everything is editable; pinch the photo to zoom.
- **Browse** by person or year, read a back-and-forth correspondence as a **chat**, and **search**
  the full text of every letter.

## Your data is yours

Every letter is written to a plain, **Finder-browsable folder** at `~/Documents/Combray/letters/<n>/`:

- `letter_<n>_page_<y>.jpg` — the original page images (open them in Preview)
- `letter.json` — sender, date, summary, and the transcription
- `transcription.txt` — the transcription as plain text

The app rebuilds its index from those files on launch, so your archive survives even a future
rewrite of the app. Nothing is locked inside a proprietary database.

---

Built with Swift / SwiftUI + GRDB, transcription by Claude. Named for Proust's village of recovered
memory — and yes, the icon is a madeleine.
