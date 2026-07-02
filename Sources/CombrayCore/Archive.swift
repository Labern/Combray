import Foundation
import GRDB

/// One full-text search result: which letter matched, how well, and a highlighted snippet.
public struct SearchHit: Sendable, Hashable {
    public let letterId: String
    /// BM25 score (lower = more relevant).
    public let rank: Double
    /// A snippet of the matching transcription with matches wrapped in « ».
    public let snippet: String
}

/// The data access layer over `AppDatabase`. UI-free and Sendable, so a future web service can
/// adopt the same queries against the same SQLite file.
public struct Archive: Sendable {
    public let database: AppDatabase

    public init(_ database: AppDatabase) {
        self.database = database
    }

    private var dbWriter: any DatabaseWriter { database.dbWriter }
    private var reader: any DatabaseReader { database.reader }

    // MARK: - Letters

    /// Inserts or updates a letter, bumps `updatedAt`, and refreshes its search index.
    @discardableResult
    public func save(_ letter: Letter) throws -> Letter {
        var saved = letter
        saved.updatedAt = Date()
        try dbWriter.write { db in
            try saved.save(db)
            try refreshSearchIndex(db, letterId: saved.id)
        }
        return saved
    }

    public func deleteLetter(id: String) throws {
        try dbWriter.write { db in
            // ON DELETE CASCADE clears pages and letterPerson; clear the FTS row explicitly.
            try db.execute(sql: "DELETE FROM letterSearch WHERE letterId = ?", arguments: [id])
            _ = try Letter.deleteOne(db, key: id)
        }
    }

    public func letter(id: String) throws -> Letter? {
        try reader.read { db in try Letter.fetchOne(db, key: id) }
    }

    /// The next sequential, human-friendly letter number.
    public func nextLetterNumber() throws -> Int {
        try reader.read { db in
            (try Int.fetchOne(db, sql: "SELECT MAX(number) FROM letter") ?? 0) + 1
        }
    }

    /// All letters, newest first by resolved year then creation time.
    public func allLetters() throws -> [Letter] {
        try reader.read { db in
            try Letter
                .order(sql: "dateYear DESC NULLS LAST, createdAt DESC")
                .fetchAll(db)
        }
    }

    public func letters(forYear year: Int) throws -> [Letter] {
        try reader.read { db in
            try Letter.filter(Column("dateYear") == year)
                .order(sql: "createdAt DESC")
                .fetchAll(db)
        }
    }

    public func letters(forPersonId personId: String) throws -> [Letter] {
        try reader.read { db in
            try Letter.fetchAll(db, sql: """
                SELECT letter.* FROM letter
                JOIN letterPerson ON letterPerson.letterId = letter.id
                WHERE letterPerson.personId = ?
                ORDER BY letter.dateYear ASC, letter.createdAt ASC
                """, arguments: [personId])
        }
    }

    /// Distinct years that have at least one letter, newest first.
    public func years() throws -> [Int] {
        try reader.read { db in
            try Int.fetchAll(db, sql: """
                SELECT DISTINCT dateYear FROM letter
                WHERE dateYear IS NOT NULL ORDER BY dateYear DESC
                """)
        }
    }

    // MARK: - Pages

    /// Replaces the page set for a letter (used after import / re-import).
    public func setPages(_ pages: [Page], forLetterId letterId: String) throws {
        try dbWriter.write { db in
            try Page.filter(Column("letterId") == letterId).deleteAll(db)
            for page in pages { try page.insert(db) }
        }
    }

    public func pages(forLetterId letterId: String) throws -> [Page] {
        try reader.read { db in
            try Page.filter(Column("letterId") == letterId)
                .order(Column("pageIndex"))
                .fetchAll(db)
        }
    }

    // MARK: - People

    public func people() throws -> [Person] {
        try reader.read { db in
            try Person.order(Column("displayName")).fetchAll(db)
        }
    }

    /// Every letter's participants in one query, for list display without per-row fetches.
    public func allParticipants() throws -> [String: (sender: String?, recipients: [String])] {
        try reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT lp.letterId AS lid, lp.role AS role, p.displayName AS name
                FROM letterPerson lp JOIN person p ON p.id = lp.personId
                ORDER BY p.displayName
                """)
            var out: [String: (sender: String?, recipients: [String])] = [:]
            for r in rows {
                let lid: String = r["lid"]
                let role: String = r["role"]
                let name: String = r["name"]
                var entry = out[lid] ?? (sender: nil, recipients: [])
                if role == "sender" { entry.sender = name } else { entry.recipients.append(name) }
                out[lid] = entry
            }
            return out
        }
    }

    /// Folds clearly-duplicate people into one entity and removes junk names, keeping the simplest
    /// name and re-pointing every letter's participants at it. Handles:
    ///   • junk names with no real letters (e.g. "," ) → deleted;
    ///   • owner aliases ("self"/"me"/"myself"/"i" and the owner's own name) → one person;
    ///   • spelling/parenthesis variants ("labern", "labern (user)");
    ///   • parenthesis-qualified variants sharing a leading name ("Claude (CLI agent)" and
    ///     "Claude Code (CLI agents)") — distinct plain names like "Anne" / "Anne Marie" are left.
    public func mergeDuplicatePeople(ownerName: String? = nil) throws {
        try dbWriter.write { db in
            let all = try Person.fetchAll(db)
            func hadParen(_ s: String) -> Bool { s.contains("(") }
            func norm(_ s: String) -> String {
                var t = s.lowercased()
                while let o = t.firstIndex(of: "("), let c = t[o...].firstIndex(of: ")") {
                    t.removeSubrange(o...c)
                }
                t = t.replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
                return t.split(separator: " ").joined(separator: " ")
            }
            func words(_ s: String) -> [String] { s.split(separator: " ").map(String.init) }

            // 1. Delete junk people (no real name) — the cascade removes their roles too.
            for p in all where norm(p.displayName).isEmpty { _ = try Person.deleteOne(db, key: p.id) }
            let people = all.filter { !norm($0.displayName).isEmpty }

            // 2. Owner aliases.
            let ownerNorm = ownerName.map(norm) ?? ""
            let ownerAliases: Set<String> = ["self", "me", "myself", "i"]
            func isOwner(_ n: String) -> Bool { (!ownerNorm.isEmpty && n == ownerNorm) || ownerAliases.contains(n) }

            // 3. For parenthesis-qualified names, collapse onto the shortest paren-qualified name
            //    whose words are a leading prefix (so the two "Claude … (CLI …)" fold together).
            let parenNorms = people.filter { hadParen($0.displayName) }.map { norm($0.displayName) }
            func prefixKey(_ n: String) -> String {
                var best = n
                for m in parenNorms where words(m).count < words(best).count && Array(words(n).prefix(words(m).count)) == words(m) {
                    best = m
                }
                return best
            }
            func groupKey(_ p: Person) -> String {
                let n = norm(p.displayName)
                if isOwner(n) { return "##owner##" }
                return hadParen(p.displayName) ? prefixKey(n) : n
            }

            var groups: [String: [Person]] = [:]
            for p in people { groups[groupKey(p), default: []].append(p) }

            func simpler(_ a: Person, _ b: Person) -> Bool {
                let ap = a.displayName.contains("("), bp = b.displayName.contains("(")
                if ap != bp { return !ap }
                if a.displayName.count != b.displayName.count { return a.displayName.count < b.displayName.count }
                return a.displayName < b.displayName
            }

            for (key, members) in groups where members.count > 1 {
                var canonical = members.sorted(by: simpler).first!
                // For the owner, prefer the person literally named the owner; show the owner's name.
                if key == "##owner##", let ownerName, !ownerName.trimmingCharacters(in: .whitespaces).isEmpty {
                    canonical = members.first { norm($0.displayName) == ownerNorm } ?? canonical
                    if canonical.displayName != ownerName {
                        try db.execute(sql: "UPDATE person SET displayName = ? WHERE id = ?",
                                       arguments: [ownerName, canonical.id])
                    }
                }
                for dup in members where dup.id != canonical.id {
                    try db.execute(sql: "UPDATE OR IGNORE letterPerson SET personId = ? WHERE personId = ?",
                                   arguments: [canonical.id, dup.id])
                    _ = try Person.deleteOne(db, key: dup.id)
                }
            }
        }
    }

    /// Finds a person by display name (case-insensitively), or creates one. `resolver` maps an
    /// incoming name to its canonical form first — the alias store + relation folding, supplied by
    /// the controller — so "Mother", "mum" and "darling sweetness" all land on the ONE "Mum" row.
    @discardableResult
    public func findOrCreatePerson(named name: String, resolver: ((String) -> String)? = nil) throws -> Person {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = (resolver?(trimmed) ?? trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
        return try dbWriter.write { db in
            if let existing = try Person.fetchOne(
                db, sql: "SELECT * FROM person WHERE LOWER(displayName) = LOWER(?)",
                arguments: [resolved]) {
                return existing
            }
            let person = Person(displayName: resolved)
            try person.insert(db)
            return person
        }
    }

    /// Folds people into their canonical identities: for each `alias → canonical`, every person row
    /// matching the alias is merged into the canonical person (created or renamed if needed), the
    /// letters re-pointed, and their search rows refreshed. Returns how many rows were folded.
    @discardableResult
    public func mergePeople(applying merges: [String: String]) throws -> Int {
        guard !merges.isEmpty else { return 0 }
        var applied = 0
        try dbWriter.write { db in
            var byNorm: [String: [Person]] = [:]
            for p in try Person.fetchAll(db) {
                byNorm[PeopleResolver.normalize(p.displayName), default: []].append(p)
            }
            for (alias, canonical) in merges {
                let aNorm = PeopleResolver.normalize(alias)
                let cNorm = PeopleResolver.normalize(canonical)
                guard !aNorm.isEmpty, aNorm != cNorm else {
                    // Same identity, different display (e.g. "mum" → "Mum"): just fix the spelling.
                    if let p = byNorm[aNorm]?.first, p.displayName != canonical {
                        try db.execute(sql: "UPDATE person SET displayName = ? WHERE id = ?",
                                       arguments: [canonical, p.id])
                    }
                    continue
                }
                guard var victims = byNorm[aNorm], !victims.isEmpty else { continue }
                let target: Person
                if let existing = byNorm[cNorm]?.first {
                    target = existing
                } else {
                    // No row for the canonical name yet — promote the first alias row by renaming it.
                    var keep = victims.removeFirst()
                    try db.execute(sql: "UPDATE person SET displayName = ? WHERE id = ?",
                                   arguments: [canonical, keep.id])
                    keep.displayName = canonical
                    byNorm[cNorm] = [keep]
                    target = keep
                }
                for v in victims where v.id != target.id {
                    let lids = try String.fetchAll(
                        db, sql: "SELECT letterId FROM letterPerson WHERE personId = ?", arguments: [v.id])
                    try db.execute(sql: "UPDATE OR IGNORE letterPerson SET personId = ? WHERE personId = ?",
                                   arguments: [target.id, v.id])
                    try db.execute(sql: "DELETE FROM letterPerson WHERE personId = ?", arguments: [v.id])
                    _ = try Person.deleteOne(db, key: v.id)
                    for lid in lids { try refreshSearchIndex(db, letterId: lid) }
                    applied += 1
                }
                byNorm[aNorm] = []
            }
        }
        return applied
    }

    /// Sets the sender and recipients for a letter (by name), then refreshes its search index.
    /// `resolver` canonicalizes each name first (see `findOrCreatePerson`).
    public func setParticipants(letterId: String, sender: String?, recipients: [String],
                                resolver: ((String) -> String)? = nil) throws {
        // Resolve names first (their own write transactions are fine).
        let senderPerson = try sender.map { try findOrCreatePerson(named: $0, resolver: resolver) }
        let recipientPeople = try recipients.map { try findOrCreatePerson(named: $0, resolver: resolver) }

        try dbWriter.write { db in
            try LetterPerson.filter(Column("letterId") == letterId).deleteAll(db)
            if let s = senderPerson {
                try LetterPerson(letterId: letterId, personId: s.id, role: .sender).insert(db)
            }
            for r in recipientPeople {
                try LetterPerson(letterId: letterId, personId: r.id, role: .recipient).insert(db)
            }
            try refreshSearchIndex(db, letterId: letterId)
        }
    }

    /// The sender and recipients attached to a letter.
    public func participants(forLetterId letterId: String) throws -> (sender: Person?, recipients: [Person]) {
        try reader.read { db in
            let sender = try Person.fetchOne(db, sql: """
                SELECT person.* FROM person
                JOIN letterPerson ON letterPerson.personId = person.id
                WHERE letterPerson.letterId = ? AND letterPerson.role = ?
                """, arguments: [letterId, PersonRole.sender.rawValue])
            let recipients = try Person.fetchAll(db, sql: """
                SELECT person.* FROM person
                JOIN letterPerson ON letterPerson.personId = person.id
                WHERE letterPerson.letterId = ? AND letterPerson.role = ?
                ORDER BY person.displayName
                """, arguments: [letterId, PersonRole.recipient.rawValue])
            return (sender, recipients)
        }
    }

    // MARK: - Search

    /// Full-text search across titles, transcriptions, and participant names. Ranked by BM25.
    public func search(_ query: String) throws -> [SearchHit] {
        guard let pattern = Self.ftsPattern(from: query) else { return [] }
        return try reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT letterId,
                       bm25(letterSearch) AS rank,
                       snippet(letterSearch, 2, '«', '»', '…', 12) AS snippet
                FROM letterSearch
                WHERE letterSearch MATCH ?
                ORDER BY rank
                """, arguments: [pattern])
            .map { row in
                SearchHit(
                    letterId: row["letterId"],
                    rank: row["rank"],
                    snippet: row["snippet"]
                )
            }
        }
    }

    // MARK: - Transcription ingest

    public enum ArchiveError: Error { case letterNotFound }

    /// Applies a model transcription result to a letter — text, summary, date, hidden meta — and
    /// sets sender/recipients (creating people as needed). Refreshes the search index.
    @discardableResult
    public func applyTranscription(_ r: TranscriptionResult, toLetterId letterId: String,
                                   resolver: ((String) -> String)? = nil) throws -> Letter {
        guard var letter = try letter(id: letterId) else { throw ArchiveError.letterNotFound }
        letter.transcription = r.transcription
        if letter.aiTranscription == nil { letter.aiTranscription = r.transcription }
        letter.title = Self.clean(r.title)
            ?? Self.composedTitle(documentType: r.document_type, sender: r.sender,
                                  recipients: r.recipients, summary: r.summary)
            ?? letter.title
        letter.summary = Self.clean(r.summary)
        letter.documentType = Self.clean(r.document_type)
        letter.dateValue = Self.clean(r.date.value)
        letter.dateYear = Self.year(from: r.date.value)
        letter.dateSource = DateSource(rawValue: r.date.source) ?? .unknown
        letter.dateConfidence = Confidence(rawValue: r.date.confidence)
        letter.metaLocation = Self.clean(r.meta.location)
        letter.metaRelationship = Self.clean(r.meta.relationship)
        letter.metaRelationshipState = Self.clean(r.meta.relationship_state)
        letter.metaWriterGoals = Self.clean(r.meta.writer_goals)
        letter.metaHandwriting = Self.clean(r.meta.handwriting_profile)
        letter.metaSuspectedWriter = Self.clean(r.meta.suspected_writer)
        letter.notableQuotes = r.notable_quotes.isEmpty ? nil : r.notable_quotes.joined(separator: "\n")
        letter.uncertainSpans = LetterFile.encodeUncertain(
            r.uncertain_spans.map { LetterFile.UncertainItem(text: $0.text, reason: $0.reason) })
        let saved = try save(letter)
        try setParticipants(letterId: letterId,
                            sender: Self.clean(r.sender),
                            recipients: r.recipients.compactMap(Self.clean),
                            resolver: resolver)
        return saved
    }

    /// Re-applies only the *derived* analysis fields from a fresh reading of an edited transcription —
    /// summary, the meta object, suspected writer, and notable quotes — WITHOUT touching the
    /// transcription, title, date, participants, document type, or the handwriting guess (which needs
    /// the images). Used after the user edits or accepts a corrected transcription.
    @discardableResult
    public func applyMetadata(_ r: TranscriptionResult, toLetterId letterId: String) throws -> Letter {
        guard var letter = try letter(id: letterId) else { throw ArchiveError.letterNotFound }
        letter.summary = Self.clean(r.summary)
        letter.metaLocation = Self.clean(r.meta.location)
        letter.metaRelationship = Self.clean(r.meta.relationship)
        letter.metaRelationshipState = Self.clean(r.meta.relationship_state)
        letter.metaWriterGoals = Self.clean(r.meta.writer_goals)
        if let sw = Self.clean(r.meta.suspected_writer) { letter.metaSuspectedWriter = sw }
        if !r.notable_quotes.isEmpty { letter.notableQuotes = r.notable_quotes.joined(separator: "\n") }
        return try save(letter)
    }

    // MARK: - Correspondence (chat thread + authors)

    /// All letters exchanged between this letter's two principals, oldest first — the chat thread.
    public func correspondence(forLetterId letterId: String) throws -> [Letter] {
        let parties = try participants(forLetterId: letterId)
        guard let a = parties.sender?.id, let b = parties.recipients.first?.id else {
            return try [letter(id: letterId)].compactMap { $0 }
        }
        return try reader.read { db in
            try Letter.fetchAll(db, sql: """
                SELECT letter.* FROM letter
                WHERE letter.id IN (SELECT letterId FROM letterPerson WHERE personId = ?)
                  AND letter.id IN (SELECT letterId FROM letterPerson WHERE personId = ?)
                ORDER BY letter.dateYear ASC, letter.createdAt ASC
                """, arguments: [a, b])
        }
    }

    /// People who appear on a letter alongside the given person — their correspondents.
    public func correspondents(ofPersonId personId: String) throws -> [Person] {
        try reader.read { db in
            try Person.fetchAll(db, sql: """
                SELECT DISTINCT p.* FROM person p
                JOIN letterPerson lp ON lp.personId = p.id
                WHERE lp.letterId IN (SELECT letterId FROM letterPerson WHERE personId = ?)
                  AND p.id <> ?
                ORDER BY p.displayName
                """, arguments: [personId, personId])
        }
    }

    // MARK: - Durable file backups (folders are the source of truth)

    /// Builds the on-disk record for a letter (used to write its `letter.json`).
    public func backupFile(forLetterId id: String) throws -> LetterFile? {
        guard let letter = try letter(id: id) else { return nil }
        let parties = try participants(forLetterId: id)
        let pageNames = try pages(forLetterId: id).map { ($0.imagePath as NSString).lastPathComponent }
        return LetterFile(
            number: letter.number,
            id: letter.id,
            title: letter.title,
            date: .init(value: letter.dateValue,
                        source: letter.dateSource.rawValue,
                        confidence: letter.dateConfidence?.rawValue),
            from: parties.sender?.displayName,
            to: parties.recipients.map(\.displayName),
            summary: letter.summary,
            documentType: letter.documentType,
            meta: .init(location: letter.metaLocation,
                        relationship: letter.metaRelationship,
                        relationshipState: letter.metaRelationshipState,
                        writerGoals: letter.metaWriterGoals,
                        handwriting: letter.metaHandwriting,
                        suspectedWriter: letter.metaSuspectedWriter),
            transcription: letter.transcription,
            aiTranscription: letter.aiTranscription,
            pages: pageNames,
            notableQuotes: letter.notableQuotes?.split(separator: "\n").map(String.init),
            speechSubstitutions: LetterFile.decodeSpeechSubs(letter.speechSubstitutions),
            uncertainSpans: LetterFile.decodeUncertain(letter.uncertainSpans),
            pinned: letter.pinned ? true : nil,
            createdAt: letter.createdAt,
            updatedAt: letter.updatedAt)
    }

    /// Stores the read-aloud voicing substitutions for a letter (JSON `[{original, spoken}]`) —
    /// computed once, replayed on every future read-aloud.
    public func saveSpeechSubstitutions(letterId: String, json: String) throws {
        guard var l = try letter(id: letterId) else { return }
        l.speechSubstitutions = json
        _ = try save(l)
    }

    /// Writes `letter.json` + `transcription.txt` for a letter into its folder.
    public func writeBackup(forLetterId id: String, lettersDir: URL) throws {
        guard let file = try backupFile(forLetterId: id) else { return }
        try Backup.write(file, lettersDir: lettersDir)
    }

    /// Rebuilds DB rows for any folder-letters not yet indexed (e.g. after a DB loss or app change).
    public func importFromFiles(_ files: [LetterFile]) throws {
        for f in files {
            if try letter(id: f.id) != nil { continue }   // already indexed
            let letter = Letter(
                id: f.id, number: f.number, title: f.title,
                dateValue: f.date.value, dateYear: Self.year(from: f.date.value ?? ""),
                dateSource: DateSource(rawValue: f.date.source) ?? .unknown,
                dateConfidence: f.date.confidence.flatMap(Confidence.init(rawValue:)),
                transcription: f.transcription, aiTranscription: f.aiTranscription,
                summary: f.summary, documentType: f.documentType,
                metaLocation: f.meta.location, metaRelationship: f.meta.relationship,
                metaRelationshipState: f.meta.relationshipState, metaWriterGoals: f.meta.writerGoals,
                metaHandwriting: f.meta.handwriting, metaSuspectedWriter: f.meta.suspectedWriter,
                notableQuotes: (f.notableQuotes?.isEmpty ?? true) ? nil : f.notableQuotes?.joined(separator: "\n"),
                speechSubstitutions: LetterFile.encodeSpeechSubs(f.speechSubstitutions),
                uncertainSpans: LetterFile.encodeUncertain(f.uncertainSpans),
                pinned: f.pinned ?? false,
                createdAt: f.createdAt, updatedAt: f.updatedAt)
            _ = try save(letter)
            let pageRows = f.pages.enumerated().map { idx, name in
                Page(letterId: f.id, pageIndex: idx, imagePath: "Letters/\(f.number)/\(name)")
            }
            try setPages(pageRows, forLetterId: f.id)
            try setParticipants(letterId: f.id, sender: f.from, recipients: f.to)
        }
    }

    // MARK: - Helpers

    static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// Builds a "<Type> to … from …" title from extracted fields when the model gave none.
    /// Uses the detected document type (letter, postcard, note, list, …) so it isn't always "Letter".
    static func composedTitle(documentType: String, sender: String,
                              recipients: [String], summary: String) -> String? {
        let s = clean(sender)
        let r = recipients.compactMap(clean)
        // The kind of document, Capitalized — defaults to "Letter".
        let kind = (clean(documentType)?.capitalized) ?? "Letter"

        // For things that aren't correspondence, a "to/from" framing reads oddly — prefer the
        // summary (e.g. "Shopping list", "Recipe — plum cake").
        let correspondence = ["Letter", "Postcard", "Card", "Note", "Telegram", "Invitation"]
        if !correspondence.contains(kind) {
            if let summary = clean(summary) {
                return "\(kind) — \(summary.split(separator: " ").prefix(8).joined(separator: " "))"
            }
            return (s == nil && r.isEmpty) ? kind : nil
        }

        guard s != nil || !r.isEmpty else {
            return clean(summary).map { "\(kind) — \($0.split(separator: " ").prefix(8).joined(separator: " "))" } ?? kind
        }
        var parts = [kind]
        if !r.isEmpty { parts.append("to \(r.joined(separator: ", "))") }
        if let s { parts.append("from \(s)") }
        return parts.joined(separator: " ")
    }

    /// Extracts a 4-digit year from a (possibly partial) date string like "1962-03".
    static func year(from value: String) -> Int? {
        let digits = value.prefix(4)
        guard digits.count == 4, let y = Int(digits), (1000...9999).contains(y) else { return nil }
        return y
    }

    // MARK: - Internals

    /// Rebuilds the FTS row for one letter: title + transcription body + denormalized names.
    private func refreshSearchIndex(_ db: Database, letterId: String) throws {
        guard let letter = try Letter.fetchOne(db, key: letterId) else { return }
        let names = try String.fetchAll(db, sql: """
            SELECT person.displayName FROM person
            JOIN letterPerson ON letterPerson.personId = person.id
            WHERE letterPerson.letterId = ?
            """, arguments: [letterId]).joined(separator: " ")

        let body = [letter.transcription, letter.summary ?? ""].joined(separator: "\n")
        try db.execute(sql: "DELETE FROM letterSearch WHERE letterId = ?", arguments: [letterId])
        try db.execute(sql: """
            INSERT INTO letterSearch (letterId, title, body, names) VALUES (?, ?, ?, ?)
            """, arguments: [letterId, letter.title ?? "", body, names])
    }

    /// Builds a safe FTS5 MATCH pattern: each token quoted, implicit AND, last token prefix-matched.
    static func ftsPattern(from query: String) -> String? {
        let tokens = query
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        guard !tokens.isEmpty else { return nil }
        return tokens.enumerated().map { index, token in
            let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
            let prefix = index == tokens.count - 1 ? "*" : ""
            return "\"\(escaped)\"\(prefix)"
        }.joined(separator: " ")
    }
}
