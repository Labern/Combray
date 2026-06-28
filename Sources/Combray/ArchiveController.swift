import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CombrayCore

/// Which model transcribes. "Automatic" uses the best model your plan allows (Opus, falling back to
/// Sonnet if your account can't use Opus); the others force a choice.
enum TranscriptionModel: String, CaseIterable, Identifiable {
    case auto, best, fast
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Automatic"
        case .best: return "Best · Opus"
        case .fast: return "Fast · Sonnet"
        }
    }
    var detail: String {
        switch self {
        case .auto: return "Opus on a paid plan, Sonnet otherwise"
        case .best: return "Highest quality (needs a paid plan)"
        case .fast: return "Quicker and cheaper, works on any plan"
        }
    }
    /// The model id to try first.
    var modelID: String {
        switch self {
        case .fast: return "claude-sonnet-4-6"
        case .auto, .best: return "claude-opus-4-8"
        }
    }
}

/// The app's controller (MVC): owns the archive + services, exposes observable state to the views,
/// and runs the actions (import, transcribe, edit, search). Kept deliberately "fat & simple."
@MainActor
final class ArchiveController: ObservableObject {
    let archive: Archive
    let images: ImageStore
    private let client = AnthropicClient()
    let capture = CaptureServer()

    // Collections
    @Published var letters: [Letter] = []
    @Published var people: [Person] = []
    @Published var years: [Int] = []
    /// letterId → display names of (sender, recipients-joined) for the sidebar rows.
    @Published var participantsByLetter: [String: (from: String?, to: String?)] = [:]

    // Current selection + its loaded detail
    @Published var selectedLetterID: String?
    @Published var focusedPersonID: String?
    @Published var pages: [Page] = []
    @Published var sender: Person?
    @Published var recipients: [Person] = []

    // Search
    @Published var searchText: String = ""
    @Published var hits: [SearchHit] = []

    // Status
    @Published var busy: String?
    @Published var errorText: String?
    /// True while a transcription request is in flight — drives the spinning indicator.
    @Published var isTranscribing = false
    /// Briefly true right after a transcription completes — shows the "Transcribed!" confirmation.
    @Published var transcribedFlash = false
    @Published var hasAPIKey: Bool = Keychain.hasCredential()

    // iCloud Drive backup
    @Published var iCloudBusy = false
    @Published var iCloudStatus: String?
    @Published var autoTranscribe: Bool = (UserDefaults.standard.object(forKey: "autoTranscribe") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(autoTranscribe, forKey: "autoTranscribe") }
    }
    @Published var transcriptionModel: TranscriptionModel =
        TranscriptionModel(rawValue: UserDefaults.standard.string(forKey: "transcriptionModel") ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(transcriptionModel.rawValue, forKey: "transcriptionModel") }
    }
    @Published var showSettings = false

    // Adding letters
    @Published var showAddChoice = false

    // iPhone capture
    @Published var captureURL: String?
    @Published var showCapture = false

    // Sign in with Claude
    @Published var showSignIn = false
    @Published var signInBusy = false
    private var pkce: ClaudeAuth.PKCE?
    private let callbackServer = OAuthCallbackServer()
    private var signInRedirect = ""

    init() {
        // Move any old ~/Documents/Combray archive into the ungated Application Support location,
        // so macOS stops prompting for Documents access on every launch.
        ImageStore.migrateFromDocumentsIfNeeded()
        let store = ImageStore(root: ImageStore.defaultRoot())
        self.images = store
        do {
            let db = try AppDatabase.makeOnDisk(at: store.databaseURL)
            self.archive = Archive(db)
        } catch {
            fatalError("Could not open the Combray database: \(error)")
        }
        // Folders are the source of truth — rebuild any missing index rows from disk.
        try? archive.importFromFiles(Backup.scan(lettersDir: store.lettersDir))
        try? archive.mergeDuplicatePeople()
        reload()

        capture.onURL = { [weak self] url in Task { @MainActor in self?.captureURL = url } }
        capture.onLetter = { [weak self] batch, urls in
            Task { @MainActor in await self?.importFromCapture(batch: batch, urls: urls) }
        }
    }

    /// Writes the durable folder record (letter.json + transcription.txt) for a letter.
    private func backup(_ id: String) {
        try? archive.writeBackup(forLetterId: id, lettersDir: images.lettersDir)
    }

    // MARK: - iCloud Drive backup

    /// The user's iCloud Drive root (`~/Library/Mobile Documents/com~apple~CloudDocs`), or nil if
    /// iCloud Drive isn't set up on this Mac. No entitlement needed — this is the shared CloudDocs area.
    static var iCloudDriveRoot: URL? {
        let p = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return FileManager.default.fileExists(atPath: p.path) ? p : nil
    }

    var iCloudAvailable: Bool { Self.iCloudDriveRoot != nil }

    /// Copies the whole `Letters/` tree (images + letter.json — the source of truth) into
    /// `iCloud Drive/Combray/Letters/`. Non-destructive: the local archive is untouched and the
    /// SQLite index isn't copied (it's a disposable cache rebuilt from these folders).
    func backupToICloud() {
        guard let drive = Self.iCloudDriveRoot else {
            iCloudStatus = "iCloud Drive isn’t set up on this Mac."
            return
        }
        let srcLetters = images.lettersDir
        let destLetters = drive.appendingPathComponent("Combray/Letters", isDirectory: true)
        iCloudBusy = true
        iCloudStatus = "Backing up to iCloud…"
        Task.detached {
            let fm = FileManager.default
            var copied = 0
            var failure: String?
            do {
                try fm.createDirectory(at: destLetters, withIntermediateDirectories: true)
                let subs = (try? fm.contentsOfDirectory(at: srcLetters, includingPropertiesForKeys: nil)) ?? []
                for sub in subs where sub.hasDirectoryPath {
                    let target = destLetters.appendingPathComponent(sub.lastPathComponent)
                    if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
                    try fm.copyItem(at: sub, to: target)
                    copied += 1
                }
            } catch { failure = error.localizedDescription }
            let done = copied
            await MainActor.run {
                self.iCloudBusy = false
                self.iCloudStatus = failure.map { "iCloud backup failed: \($0)" }
                    ?? "Backed up \(done) letter\(done == 1 ? "" : "s") to iCloud ✓"
            }
        }
    }

    var selectedLetter: Letter? {
        guard let id = selectedLetterID else { return nil }
        return letters.first { $0.id == id }
    }

    func reload() {
        do {
            try? archive.mergeDuplicatePeople()
            letters = try archive.allLetters()
            people = try archive.people()
            years = try archive.years()
            let raw = (try? archive.allParticipants()) ?? [:]
            participantsByLetter = raw.mapValues {
                (from: $0.sender, to: $0.recipients.isEmpty ? nil : $0.recipients.joined(separator: ", "))
            }
        } catch { errorText = error.localizedDescription }
    }

    func select(_ id: String?) {
        selectedLetterID = id
        loadDetail()
    }

    /// Focus a letter in the detail pane (clearing any person focus).
    func showLetter(_ id: String) {
        focusedPersonID = nil
        select(id)
    }

    /// Focus a person (author) in the detail pane.
    func showPerson(_ id: String) {
        selectedLetterID = nil
        pages = []; sender = nil; recipients = []
        focusedPersonID = id
    }

    /// Return to the home (welcome) screen.
    func goHome() {
        selectedLetterID = nil
        focusedPersonID = nil
        pages = []; sender = nil; recipients = []
    }

    private func loadDetail() {
        guard let id = selectedLetterID else { pages = []; sender = nil; recipients = []; return }
        do {
            pages = try archive.pages(forLetterId: id)
            let parties = try archive.participants(forLetterId: id)
            sender = parties.sender
            recipients = parties.recipients
        } catch { errorText = error.localizedDescription }
    }

    // MARK: - Import

    /// Imports image files as a new letter, then kicks off transcription.
    func importLetter(from urls: [URL]) {
        do {
            var letter = Letter()
            letter.number = (try? archive.nextLetterNumber()) ?? 1
            letter = try archive.save(letter)
            let n = letter.number
            let newPages = urls.enumerated().compactMap { pair in
                try? images.importImage(from: pair.element, letterId: letter.id, letterNumber: n, index: pair.offset)
            }
            try archive.setPages(newPages, forLetterId: letter.id)
            reload()
            select(letter.id)
            backup(letter.id)
            if autoTranscribe { Task { await transcribe(letterId: letter.id) } }
        } catch { errorText = error.localizedDescription }
    }

    // MARK: - Transcription

    func transcribeSelected() async {
        guard let id = selectedLetterID else { return }
        await transcribe(letterId: id)
    }

    func transcribe(letterId: String) async {
        guard Keychain.hasCredential() else {
            errorText = "Sign in to Claude first (or add an API key in Settings)."
            return
        }
        let pageList = (try? archive.pages(forLetterId: letterId)) ?? []
        let urls = pageList.map { images.url(for: $0) }
        guard !urls.isEmpty else { errorText = "This letter has no page images."; return }

        busy = "Reading the handwriting…"
        isTranscribing = true
        defer { busy = nil; isTranscribing = false }
        do {
            let result = try await transcribeWithFallback(urls)
            _ = try archive.applyTranscription(result, toLetterId: letterId)
            backup(letterId)
            reload()
            if selectedLetterID == letterId { loadDetail() }
            flashTranscribed()
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Runs transcription with the chosen model. In "Automatic" mode, if Opus is rejected because the
    /// account isn't on a paid plan, it transparently retries with Sonnet.
    private func transcribeWithFallback(_ urls: [URL]) async throws -> TranscriptionResult {
        let primary = transcriptionModel.modelID
        do {
            return try await client.transcribe(imageURLs: urls, model: primary)
        } catch let AnthropicError.http(status, msg)
                    where transcriptionModel == .auto && primary == "claude-opus-4-8"
                    && Self.looksLikePlanLimit(status, msg) {
            busy = "Switching to Sonnet for your plan…"
            return try await client.transcribe(imageURLs: urls, model: "claude-sonnet-4-6")
        }
    }

    /// Heuristic: does this API error look like "your plan can't use this model"?
    static func looksLikePlanLimit(_ status: Int, _ msg: String) -> Bool {
        if status == 403 || status == 404 { return true }
        let m = msg.lowercased()
        return (status == 400 || status == 429)
            && (m.contains("model") || m.contains("not available") || m.contains("permission")
                || m.contains("access") || m.contains("plan") || m.contains("tier")
                || m.contains("not allowed") || m.contains("upgrade"))
    }

    // MARK: - Account

    /// A human description of the connected Claude account (for Settings).
    var accountSummary: String {
        guard let cred = Keychain.credential() else { return "Not connected" }
        return cred.kind == .oauth ? "Connected with your Claude account" : "Connected with an API key"
    }

    /// Disconnects the current account so a different one can be connected.
    func disconnect() {
        Keychain.clear()
        hasAPIKey = Keychain.hasCredential()
    }

    // MARK: - Web viewer

    private lazy var webServer = WebServer(archive: archive, images: images)
    @Published var webURL: String?
    @Published var webLanURL: String?

    /// Starts the local web viewer (once) and opens the archive in the default browser.
    func showOnWeb() {
        webServer.start()
        webURL = webServer.localURL
        webLanURL = webServer.lanURL
        if let u = URL(string: webServer.localURL) { NSWorkspace.shared.open(u) }
    }

    /// Shows the transient "Transcribed!" confirmation for a couple of seconds after a successful run.
    private func flashTranscribed() {
        withAnimation { transcribedFlash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            withAnimation { self?.transcribedFlash = false }
        }
    }

    // MARK: - Pinning & row actions

    static let maxPins = 3
    var pinnedCount: Int { letters.filter(\.pinned).count }

    /// Pin / unpin a letter. At most `maxPins` (3) may be pinned across the whole archive.
    func togglePin(_ letter: Letter) {
        var l = letter
        if !l.pinned && pinnedCount >= Self.maxPins {
            errorText = "You can pin up to \(Self.maxPins) letters — unpin one first."
            return
        }
        l.pinned.toggle()
        update(l)
    }

    /// Copies a letter's transcription to the clipboard.
    func copyTranscription(_ letter: Letter) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(letter.transcription, forType: .string)
    }

    /// Reveals the letter's source folder (images + letter.json) in Finder.
    func revealInFinder(_ letter: Letter) {
        let folder = images.lettersDir.appendingPathComponent("\(letter.number)", isDirectory: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// Removes a letter from the index and moves its source folder to the Trash (recoverable).
    func deleteLetter(_ letter: Letter) {
        let folder = images.lettersDir.appendingPathComponent("\(letter.number)", isDirectory: true)
        do {
            try archive.deleteLetter(id: letter.id)
            try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
            if selectedLetterID == letter.id { goHome() }
            reload()
        } catch { errorText = error.localizedDescription }
    }

    // MARK: - Page editing + delete confirmations

    /// A letter awaiting an "Are you sure?" confirmation before deletion (set by the sidebar menu).
    @Published var pendingDeleteLetter: Letter?
    /// A page image awaiting an "Are you sure?" confirmation before deletion (set by the image menu).
    @Published var pendingDeletePage: Page?

    /// Removes one page image (its file + record), reindexes the rest, updates the folder backup.
    func deletePage(_ page: Page) {
        try? FileManager.default.removeItem(at: images.url(for: page))
        var remaining = ((try? archive.pages(forLetterId: page.letterId)) ?? []).filter { $0.id != page.id }
        for i in remaining.indices { remaining[i].pageIndex = i }
        try? archive.setPages(remaining, forLetterId: page.letterId)
        backup(page.letterId)
        if selectedLetterID == page.letterId { loadDetail() }
    }

    /// Opens a file picker and replaces one page's image with the chosen file (keeping its position).
    func replacePageWithPicker(_ page: Page) {
        guard let letter = letters.first(where: { $0.id == page.letterId }) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? FileManager.default.removeItem(at: images.url(for: page))
        guard let newPage = try? images.importImage(from: url, letterId: page.letterId,
                                                     letterNumber: letter.number, index: page.pageIndex) else { return }
        var pages = (try? archive.pages(forLetterId: page.letterId)) ?? []
        if let i = pages.firstIndex(where: { $0.id == page.id }) {
            pages[i].imagePath = newPage.imagePath
            pages[i].width = newPage.width
            pages[i].height = newPage.height
        }
        try? archive.setPages(pages, forLetterId: page.letterId)
        backup(page.letterId)
        if selectedLetterID == page.letterId { loadDetail() }
    }

    // MARK: - Editing

    func saveTranscription(_ text: String) {
        guard var letter = selectedLetter else { return }
        letter.transcription = text
        update(letter)
    }

    func update(_ letter: Letter) {
        do {
            _ = try archive.save(letter)
            backup(letter.id)
            reload()
            if selectedLetterID == letter.id { loadDetail() }
        } catch { errorText = error.localizedDescription }
    }

    /// Updates the selected letter's sender/recipients (by name), creating people as needed.
    func updateParticipants(sender: String?, recipients: [String]) {
        guard let id = selectedLetterID else { return }
        let s = (sender?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
        let r = recipients.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        do {
            try archive.setParticipants(letterId: id, sender: s, recipients: r)
            backup(id)
            reload(); loadDetail()
        } catch { errorText = error.localizedDescription }
    }

    /// Updates the selected letter's date (manual edit).
    func updateDate(_ value: String) {
        guard var letter = selectedLetter else { return }
        let v = value.trimmingCharacters(in: .whitespaces)
        letter.dateValue = v.isEmpty ? nil : v
        letter.dateYear = Int(v.prefix(4)).flatMap { (1000...9999).contains($0) ? $0 : nil }
        if !v.isEmpty { letter.dateSource = .manual }
        update(letter)
    }

    func deleteLetter(_ id: String) {
        do {
            try archive.deleteLetter(id: id)
            if selectedLetterID == id { select(nil) }
            reload()
        } catch { errorText = error.localizedDescription }
    }

    // MARK: - Search

    func runSearch() {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { hits = []; return }
        hits = (try? archive.search(searchText)) ?? []
    }

    // MARK: - People & chat

    func letters(forPerson id: String) -> [Letter] {
        (try? archive.letters(forPersonId: id)) ?? []
    }
    func correspondents(of id: String) -> [Person] {
        (try? archive.correspondents(ofPersonId: id)) ?? []
    }
    func correspondence(forLetter id: String) -> [Letter] {
        (try? archive.correspondence(forLetterId: id)) ?? []
    }
    func sender(ofLetter id: String) -> Person? {
        (try? archive.participants(forLetterId: id))?.sender
    }

    // MARK: - API key

    func saveAPIKey(_ key: String) {
        Keychain.setAPIKey(key.trimmingCharacters(in: .whitespacesAndNewlines))
        hasAPIKey = Keychain.hasCredential()
    }

    func startSignIn() {
        let p = ClaudeAuth.makePKCE()
        pkce = p
        let redirect = ClaudeAuth.loopbackRedirect(port: callbackServer.port)
        signInRedirect = redirect
        callbackServer.onCode = { [weak self] code, _ in
            Task { @MainActor in
                self?.callbackServer.stop()
                await self?.completeSignIn(code: code)
            }
        }
        callbackServer.start()
        signInBusy = true
        NSWorkspace.shared.open(ClaudeAuth.authorizeURL(p, redirectURI: redirect))
        showSignIn = true
    }

    func completeSignIn(code: String) async {
        guard let p = pkce else { return }
        signInBusy = true
        defer { signInBusy = false }
        do {
            let tokens = try await ClaudeAuth.exchange(code: code, pkce: p, redirectURI: signInRedirect)
            Keychain.save(StoredCredential(kind: .oauth, accessToken: tokens.accessToken,
                                           refreshToken: tokens.refreshToken, expiresAt: tokens.expiresAt))
            hasAPIKey = Keychain.hasCredential()
            showSignIn = false
        } catch {
            errorText = error.localizedDescription
        }
    }

    func cancelSignIn() {
        callbackServer.stop()
        signInBusy = false
        showSignIn = false
    }

    // MARK: - Import panel

    /// Opens a file picker for letter pages, then imports + transcribes them.
    func pickAndImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.message = "Choose the photographed page(s) of one letter, in order."
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            importLetter(from: panel.urls)
        }
    }

    func startCapture() { captureURL = nil; capture.start(); showCapture = true }
    func stopCapture() { capture.stop(); showCapture = false }

    /// Imports a captured batch and reports progress back to the phone via the capture server.
    func importFromCapture(batch: String, urls: [URL]) async {
        do {
            var letter = Letter()
            letter.number = (try? archive.nextLetterNumber()) ?? 1
            letter = try archive.save(letter)
            let n = letter.number
            let pages = urls.enumerated().compactMap {
                try? images.importImage(from: $0.element, letterId: letter.id, letterNumber: n, index: $0.offset)
            }
            try archive.setPages(pages, forLetterId: letter.id)
            reload(); select(letter.id); backup(letter.id)
            if autoTranscribe {
                capture.setStatus(batch, "transcribing")
                await transcribe(letterId: letter.id)
                let ok = (try? archive.letter(id: letter.id))?.transcription.isEmpty == false
                capture.setStatus(batch, ok ? "done" : "error")
            } else {
                capture.setStatus(batch, "saved")
            }
        } catch {
            capture.setStatus(batch, "error")
            errorText = error.localizedDescription
        }
    }

    // MARK: - Export & share

    /// One-click export of the transcription to a .docx file.
    func exportDOCX(_ letter: Letter) {
        let parties = try? archive.participants(forLetterId: letter.id)
        let sender = parties?.sender?.displayName
        let recipients = parties?.recipients.map(\.displayName) ?? []

        // Name the file after what the document actually is (the type-aware title), e.g.
        // "Postcard_from_Venice.docx" — falling back to a systematic name if there's no title.
        let datePart = letter.dateValue ?? "undated"
        let titled = letter.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (titled?.isEmpty == false) ? titled! : "letter_\(letter.number)_\(datePart)_\(sender ?? "unknown")"
        let suggested = Self.safeFilename(base) + ".docx"

        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggested
        panel.allowedContentTypes = [UTType(filenameExtension: "docx") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let doc = NSMutableAttributedString()
        if let title = letter.title {
            doc.append(NSAttributedString(string: title + "\n",
                attributes: [.font: NSFont.boldSystemFont(ofSize: 18)]))
        }
        var meta: [String] = []
        if let sender { meta.append("From: \(sender)") }
        if !recipients.isEmpty { meta.append("To: \(recipients.joined(separator: ", "))") }
        if let date = letter.dateValue { meta.append("Date: \(date)") }
        if !meta.isEmpty {
            doc.append(NSAttributedString(string: meta.joined(separator: "\n") + "\n\n",
                attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        doc.append(NSAttributedString(string: letter.transcription,
            attributes: [.font: NSFont.systemFont(ofSize: 13)]))

        do {
            let data = try doc.data(
                from: NSRange(location: 0, length: doc.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            try data.write(to: url)
        } catch {
            errorText = "Export failed: \(error.localizedDescription)"
        }
    }

    /// Opens a Gmail compose tab (in Google Chrome) pre-filled with the letter's details + transcription.
    func shareViaGmail(_ letter: Letter) {
        let parties = try? archive.participants(forLetterId: letter.id)
        var header: [String] = []
        if let sender = parties?.sender?.displayName { header.append("From: \(sender)") }
        let recipients = parties?.recipients.map(\.displayName) ?? []
        if !recipients.isEmpty { header.append("To: \(recipients.joined(separator: ", "))") }
        if let date = letter.dateValue { header.append("Date: \(date)") }
        let body = (header.isEmpty ? "" : header.joined(separator: "\n") + "\n\n") + letter.transcription

        var comps = URLComponents(string: "https://mail.google.com/mail/")!
        comps.queryItems = [
            URLQueryItem(name: "view", value: "cm"),
            URLQueryItem(name: "fs", value: "1"),
            URLQueryItem(name: "su", value: letter.title ?? "Letter \(letter.number)"),
            URLQueryItem(name: "body", value: body)
        ]
        guard let url = comps.url else { return }
        let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: config) { _, error in
            if error != nil { NSWorkspace.shared.open(url) }  // fall back to default browser
        }
    }

    static func safeFilename(_ s: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return s.components(separatedBy: invalid).joined().replacingOccurrences(of: " ", with: "_")
    }
}

/// Headless `--serve` mode: run only the capture server (no GUI) so the upload → letter pipeline
/// can be exercised with curl from a terminal.
func runCaptureServerHeadless() -> Never {
    let images = ImageStore(root: ImageStore.defaultRoot())
    let db = try! AppDatabase.makeOnDisk(at: images.databaseURL)
    let archive = Archive(db)
    let server = CaptureServer()
    server.onURL = { url in print("CAPTURE_URL", url ?? "nil") }
    server.onLetter = { _, urls in
        do {
            var letter = Letter()
            letter.number = (try? archive.nextLetterNumber()) ?? 1
            letter = try archive.save(letter)
            let pages = urls.enumerated().compactMap {
                try? images.importImage(from: $0.element, letterId: letter.id,
                                        letterNumber: letter.number, index: $0.offset)
            }
            try archive.setPages(pages, forLetterId: letter.id)
            try archive.writeBackup(forLetterId: letter.id, lettersDir: images.lettersDir)
            print("IMPORTED letter", letter.number, "pages", pages.count)
        } catch { print("import error", error) }
    }
    server.start()
    RunLoop.main.run()
    fatalError("unreachable")
}

/// Headless `--web` mode: serve only the read-only web viewer (no GUI) so it can be curl-tested.
func runWebServerHeadless() -> Never {
    let images = ImageStore(root: ImageStore.defaultRoot())
    let db = try! AppDatabase.makeOnDisk(at: images.databaseURL)
    let archive = Archive(db)
    try? archive.importFromFiles(Backup.scan(lettersDir: images.lettersDir))
    let server = WebServer(archive: archive, images: images)
    server.start()
    print("WEB", server.localURL)
    RunLoop.main.run()
    fatalError("unreachable")
}
