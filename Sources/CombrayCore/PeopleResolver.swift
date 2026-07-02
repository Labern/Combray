import Foundation

/// Canonical person resolution: the same human being arrives from transcriptions under many names —
/// "Eleanor", "Eleanor Whitfield", "eleanor", "Mother", "Mum", "darling sweetness" — and the People
/// index must show exactly ONE entry per person. Three layers do that:
///
///  1. **Deterministic** (this file, pure + unit-tested): case/diacritic/punctuation variants,
///     relation-term variants (Mother/Mummy/Mum → "Mum" — the user searches by the relation),
///     endearment detection, and unambiguous first-name ⊂ full-name folding.
///  2. **The alias store** (`people.json` at the archive root — additive, letter folders untouched):
///     every resolution ever made, persisted, so it survives index rebuilds and is applied to all
///     future transcriptions. This is what makes a resolution *final*.
///  3. **Claude inference** (`AnthropicClient.resolvePeople`): the judgement calls — who "darling
///     sweetness" really is, that "Vivienne" is the owner's mother — proposed with confidence and
///     folded into the alias store.
public enum PeopleResolver {

    /// Lowercased, diacritic-folded, parenthetical-stripped, punctuation-free, space-collapsed.
    public static func normalize(_ s: String) -> String {
        var t = s.folding(options: [.diacriticInsensitive, .caseInsensitive],
                          locale: Locale(identifier: "en"))
        while let o = t.firstIndex(of: "("), let c = t[o...].firstIndex(of: ")") {
            t.removeSubrange(o...c)
        }
        t = t.replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
        return t.split(separator: " ").joined(separator: " ")
    }

    /// Filler words that decorate a name without identifying anyone: "my dearest Mother" → "Mother".
    private static let filler: Set<String> = ["my", "dear", "dearest", "darling", "sweet", "own",
                                              "the", "your", "our", "old", "little"]

    /// Relation-term variants → the canonical relation name the owner would search by.
    private static let relations: [String: String] = [
        "mum": "Mum", "mummy": "Mum", "mom": "Mum", "mommy": "Mum", "mother": "Mum",
        "ma": "Mum", "mama": "Mum", "mamma": "Mum",
        "dad": "Dad", "daddy": "Dad", "father": "Dad", "papa": "Dad", "pa": "Dad", "pop": "Dad",
        "grandma": "Grandma", "granny": "Grandma", "grannie": "Grandma", "gran": "Grandma",
        "nana": "Grandma", "nan": "Grandma", "grandmother": "Grandma",
        "grandpa": "Grandpa", "grandad": "Grandpa", "granddad": "Grandpa",
        "grandfather": "Grandpa", "gramps": "Grandpa", "grampa": "Grandpa",
    ]

    /// Whole names that are terms of endearment, not identities — they need inference to a person.
    private static let endearments: Set<String> = [
        "sweetness", "sweetheart", "sweetie", "darling", "dearest", "dear", "dearie", "love",
        "beloved", "honey", "angel", "pet", "treasure", "duck", "ducky", "lovey", "poppet",
    ]

    private static func meaningfulWords(_ s: String) -> [String] {
        normalize(s).split(separator: " ").map(String.init).filter { !filler.contains($0) }
    }

    /// The canonical form when the name *is* a relation ("Mother" → "Mum", "Auntie Vera" →
    /// "Aunt Vera"), or nil when the name isn't a relation term / is already canonical.
    public static func relationCanonical(_ s: String) -> String? {
        let words = meaningfulWords(s)
        if words.count == 1, let canon = relations[words[0]] {
            return canon == s.trimmingCharacters(in: .whitespaces) ? nil : canon
        }
        // "Auntie Vera" / "aunty vera" → "Aunt Vera"; "uncle bill" → "Uncle Bill"
        if words.count == 2 {
            let prefix: String?
            switch words[0] {
            case "aunt", "auntie", "aunty": prefix = "Aunt"
            case "uncle": prefix = "Uncle"
            default: prefix = nil
            }
            if let prefix {
                let canon = "\(prefix) \(words[1].capitalized)"
                return canon == s.trimmingCharacters(in: .whitespaces) ? nil : canon
            }
        }
        return nil
    }

    /// True when the whole name is nothing but endearments ("sweetness", "darling sweetness") —
    /// never a valid canonical identity; Claude inference resolves who it really is.
    public static func isEndearment(_ s: String) -> Bool {
        let words = meaningfulWords(s)
        return !words.isEmpty && words.allSatisfy { endearments.contains($0) }
    }

    /// Deterministic merge proposals for a set of display names: `[alias: canonical]`.
    /// Handles case/punctuation variants, relation-term variants, and single-word names that are
    /// unambiguously the first name of exactly one fuller name. Owner names are left alone
    /// (the archive's owner pass handles those).
    public static func deterministicMerges(names: [String], ownerName: String? = nil) -> [String: String] {
        var merges: [String: String] = [:]
        let ownerNorm = ownerName.map(normalize) ?? ""
        let ownerAliases: Set<String> = ["self", "me", "myself", "i"]
        func isOwner(_ n: String) -> Bool { (!ownerNorm.isEmpty && n == ownerNorm) || ownerAliases.contains(n) }
        let candidates = names.filter { !isOwner(normalize($0)) && !normalize($0).isEmpty }

        // 1. Relation-term variants → canonical relation.
        for name in candidates {
            if let canon = relationCanonical(name) { merges[name] = canon }
        }

        // 2. Same normalized form → the best-looking display of the group.
        func better(_ a: String, _ b: String) -> Bool {   // true when `a` is the better canonical
            let aCap = a.first?.isUppercase == true, bCap = b.first?.isUppercase == true
            if aCap != bCap { return aCap }
            let aParen = a.contains("("), bParen = b.contains("(")
            if aParen != bParen { return !aParen }
            if a.count != b.count { return a.count < b.count }
            return a < b
        }
        var byNorm: [String: [String]] = [:]
        for name in candidates where merges[name] == nil {
            byNorm[normalize(name), default: []].append(name)
        }
        for (_, group) in byNorm where group.count > 1 {
            let canonical = group.sorted(by: better).first!
            for name in group where name != canonical { merges[name] = canonical }
        }

        // 3. A single-word name that is the first word of exactly ONE fuller name folds into it
        //    ("Eleanor" → "Eleanor Whitfield"); ambiguous first names are left alone.
        let fullNames = candidates.filter { normalize($0).contains(" ") && merges[$0] == nil }
        for name in candidates where merges[name] == nil {
            let n = normalize(name)
            guard !n.contains(" "), relations[n] == nil, !endearments.contains(n) else { continue }
            let matches = fullNames.filter { normalize($0).hasPrefix(n + " ") }
            if matches.count == 1 { merges[name] = matches[0] }
        }

        // Chase chains so every alias points at a terminal canonical (a → b, b → c ⇒ a → c).
        for (alias, var canon) in merges {
            var hops = 0
            while let next = merges[canon], hops < 3 { canon = next; hops += 1 }
            if normalize(alias) == normalize(canon) && alias == canon { merges[alias] = nil }
            else { merges[alias] = canon }
        }
        return merges
    }
}

/// The persistent alias map — every resolution ever made, keyed by normalized alias, stored as
/// `people.json` at the archive root. Additive: letter folders are never touched, and a rebuilt
/// index re-applies every past resolution, which is what makes a merge *canonical and final*.
public struct PeopleAliases: Codable, Sendable {
    public var version: Int
    public var aliases: [String: String]     // normalized alias → canonical display name

    public init() { version = 1; aliases = [:] }

    public static func url(inArchiveRoot root: URL) -> URL {
        root.appendingPathComponent("people.json")
    }

    public static func load(fromArchiveRoot root: URL) -> PeopleAliases {
        guard let data = try? Data(contentsOf: url(inArchiveRoot: root)),
              let loaded = try? JSONDecoder().decode(PeopleAliases.self, from: data)
        else { return PeopleAliases() }
        return loaded
    }

    public func save(toArchiveRoot root: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: Self.url(inArchiveRoot: root), options: .atomic)
    }

    /// The canonical display name for `name`, chasing chains, or nil when unmapped.
    public func canonical(for name: String) -> String? {
        var current = PeopleResolver.normalize(name)
        var result: String?
        var hops = 0
        while let next = aliases[current], hops < 4 {
            result = next
            let nextNorm = PeopleResolver.normalize(next)
            if nextNorm == current { break }
            current = nextNorm
            hops += 1
        }
        return result
    }

    /// Record `alias` → `canonical` (no-op for self-references; collapses chains as it stores).
    public mutating func set(alias: String, canonical: String) {
        let aNorm = PeopleResolver.normalize(alias)
        let terminal = self.canonical(for: canonical) ?? canonical
        guard !aNorm.isEmpty, aNorm != PeopleResolver.normalize(terminal) else { return }
        aliases[aNorm] = terminal
    }
}
