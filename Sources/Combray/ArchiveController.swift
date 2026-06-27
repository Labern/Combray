import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CombrayCore

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
    @Published var hasAPIKey: Bool = Keychain.hasCredential()
    @Published var autoTranscribe: Bool = (UserDefaults.standard.object(forKey: "autoTranscribe") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(autoTranscribe, forKey: "autoTranscribe") }
    }

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

    var selectedLetter: Letter? {
        guard let id = selectedLetterID else { return nil }
        return letters.first { $0.id == id }
    }

    func reload() {
        do {
            letters = try archive.allLetters()
            people = try archive.people()
            years = try archive.years()
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
        defer { busy = nil }
        do {
            let result = try await client.transcribe(imageURLs: urls)
            _ = try archive.applyTranscription(result, toLetterId: letterId)
            backup(letterId)
            reload()
            if selectedLetterID == letterId { loadDetail() }
        } catch {
            errorText = error.localizedDescription
        }
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

        // Systematic filename so there's never a rename issue, e.g. letter_3_1962-03_Eleanor_Brun.docx
        let datePart = letter.dateValue ?? "undated"
        let suggested = Self.safeFilename("letter_\(letter.number)_\(datePart)_\(sender ?? "unknown")") + ".docx"

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
