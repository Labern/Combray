import Foundation
import GRDB

// MARK: - Enums

/// Why a letter's date is what it is.
public enum DateSource: String, Codable, Sendable, CaseIterable {
    /// A date physically written on the letter.
    case written
    /// A date the model inferred from the letter's contents.
    case inferred
    /// The user set or corrected the date by hand.
    case manual
    /// No date could be determined.
    case unknown
}

/// How confident we are in an extracted value (date, sender, etc.).
public enum Confidence: String, Codable, Sendable, CaseIterable {
    case high, medium, low
}

/// A person's role on a specific letter.
public enum PersonRole: String, Codable, Sendable, CaseIterable {
    case sender
    case recipient
}

// MARK: - Person

/// Someone who wrote or received letters (or is mentioned in them).
public struct Person: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    /// Canonical display name, e.g. "Eleanor Brun".
    public var displayName: String
    /// Alternate spellings / nicknames the model has seen, newline-separated.
    public var aka: String?
    public var notes: String?

    public init(id: String = UUID().uuidString,
                displayName: String,
                aka: String? = nil,
                notes: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.aka = aka
        self.notes = notes
    }
}

extension Person: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "person"
}

// MARK: - Relationship

/// A relationship label for browsing ("grandmother", "friend", …).
public struct Relationship: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var personId: String
    /// Free-text relation label, lowercased for grouping.
    public var relation: String

    public init(id: String = UUID().uuidString, personId: String, relation: String) {
        self.id = id
        self.personId = personId
        self.relation = relation
    }
}

extension Relationship: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "relationship"
}

// MARK: - Letter

/// One archived letter: metadata + the canonical (user-editable) transcription.
/// Pages (the photographed images) live in the `page` table.
public struct Letter: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    /// Human-friendly sequential number (1, 2, 3…) used for Finder-browsable file paths.
    public var number: Int
    public var title: String?
    /// Resolved date as a possibly-partial ISO string ("1962", "1962-03", "1962-03-04").
    public var dateValue: String?
    /// Extracted year, for fast "browse by year" grouping/sorting.
    public var dateYear: Int?
    public var dateSource: DateSource
    public var dateConfidence: Confidence?
    /// The canonical transcription the user reads and edits.
    public var transcription: String
    /// The original, untouched model output — kept so edits are diffable and re-runnable.
    public var aiTranscription: String?
    public var notes: String?
    /// A short content summary, shown on every letter view.
    public var summary: String?
    /// What the document is — "letter", "postcard", "screenshot", … Drives the neat letter-view
    /// formatting (prose is reflowed; screenshots/code keep exact whitespace). Optional & additive:
    /// absent in records written by older app versions (then defaults to the reflowed view).
    public var documentType: String?
    // Hidden "meta" scan — details intelligently inferred from the letter's contents.
    public var metaLocation: String?
    public var metaRelationship: String?
    public var metaRelationshipState: String?
    public var metaWriterGoals: String?
    /// Guess at the writer's sex/age from handwriting style (meta). Optional & additive.
    public var metaHandwriting: String?
    /// Suspected writer when the handwriting matches a known reference (meta). Optional & additive.
    public var metaSuspectedWriter: String?
    /// Notable verbatim quotes, newline-separated.
    public var notableQuotes: String?
    /// Read-aloud voicing substitutions, JSON `[{"original": …, "spoken": …}]` — Claude's context
    /// judgements for dates/times/old-money, computed once per letter. Optional & additive.
    public var speechSubstitutions: String?
    /// Questionable readings awaiting review, JSON `[{"text": …, "reason": …, "status": …}]`
    /// (status: open | approved | denied). Optional & additive.
    public var uncertainSpans: String?
    /// Pinned to the top of the sidebar (at most 3 across the whole archive).
    public var pinned: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString,
                number: Int = 0,
                title: String? = nil,
                dateValue: String? = nil,
                dateYear: Int? = nil,
                dateSource: DateSource = .unknown,
                dateConfidence: Confidence? = nil,
                transcription: String = "",
                aiTranscription: String? = nil,
                notes: String? = nil,
                summary: String? = nil,
                documentType: String? = nil,
                metaLocation: String? = nil,
                metaRelationship: String? = nil,
                metaRelationshipState: String? = nil,
                metaWriterGoals: String? = nil,
                metaHandwriting: String? = nil,
                metaSuspectedWriter: String? = nil,
                notableQuotes: String? = nil,
                speechSubstitutions: String? = nil,
                uncertainSpans: String? = nil,
                pinned: Bool = false,
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.number = number
        self.title = title
        self.dateValue = dateValue
        self.dateYear = dateYear
        self.dateSource = dateSource
        self.dateConfidence = dateConfidence
        self.transcription = transcription
        self.aiTranscription = aiTranscription
        self.notes = notes
        self.summary = summary
        self.documentType = documentType
        self.metaLocation = metaLocation
        self.metaRelationship = metaRelationship
        self.metaRelationshipState = metaRelationshipState
        self.metaWriterGoals = metaWriterGoals
        self.metaHandwriting = metaHandwriting
        self.metaSuspectedWriter = metaSuspectedWriter
        self.notableQuotes = notableQuotes
        self.speechSubstitutions = speechSubstitutions
        self.uncertainSpans = uncertainSpans
        self.pinned = pinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension Letter: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "letter"
}

// MARK: - Page

/// One photographed page of a letter. The lossless original lives on disk; we store its path.
public struct Page: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var letterId: String
    public var pageIndex: Int
    /// Path (relative to the archive root) of the lossless original image.
    public var imagePath: String
    /// Path of a cached thumbnail, if generated.
    public var thumbnailPath: String?
    public var width: Int?
    public var height: Int?

    public init(id: String = UUID().uuidString,
                letterId: String,
                pageIndex: Int,
                imagePath: String,
                thumbnailPath: String? = nil,
                width: Int? = nil,
                height: Int? = nil) {
        self.id = id
        self.letterId = letterId
        self.pageIndex = pageIndex
        self.imagePath = imagePath
        self.thumbnailPath = thumbnailPath
        self.width = width
        self.height = height
    }
}

extension Page: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "page"
}

// MARK: - LetterPerson (join)

/// Links a letter to a person in a role (sender / recipient). Many-to-many.
public struct LetterPerson: Codable, Hashable, Sendable {
    public var letterId: String
    public var personId: String
    public var role: PersonRole

    public init(letterId: String, personId: String, role: PersonRole) {
        self.letterId = letterId
        self.personId = personId
        self.role = role
    }
}

extension LetterPerson: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "letterPerson"
}
