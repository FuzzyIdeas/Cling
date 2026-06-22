import Foundation

/// One editable exclusion rule line. Mechanism-agnostic: `chipEligible` (whether its store honors globs) is
/// supplied by the caller, which also maps the serialized text back to a concrete rule by index.
struct ExcludeRuleLine: TokenizedRuleLine, Equatable {
    let hasBang: Bool
    let anchored: Bool
    let dirSlash: Bool
    var tokens: [RuleToken]
    let chipEligible: Bool

    func serialize() -> String {
        (hasBang ? "!" : "") + (anchored ? "/" : "") + tokens.map(\.display).joined(separator: "/") + (dirSlash ? "/" : "")
    }

    static func parse(_ line: String, chipEligible: Bool) -> ExcludeRuleLine {
        let f = RuleGrid.frame(line)
        return ExcludeRuleLine(hasBang: f.hasBang, anchored: f.anchored, dirSlash: f.dirSlash, tokens: f.tokens, chipEligible: chipEligible)
    }
}

/// Editable state for an exclude option's generated rules. Pure: cycles literal tokens, supports a raw-text
/// override, and serializes back. The caller rebuilds concrete rules from `effectiveLines()` by index.
struct ExcludeEdit: Equatable {
    var lines: [ExcludeRuleLine]
    private(set) var rawText: [String]?

    var isRaw: Bool { rawText != nil }

    init(rules: [(line: String, chipEligible: Bool)]) {
        lines = rules.map { ExcludeRuleLine.parse($0.line, chipEligible: $0.chipEligible) }
        rawText = nil
    }

    func togglableColumns() -> Set<Int> { RuleGrid.togglableColumns(lines) }

    mutating func cycle(column c: Int) { RuleGrid.cycle(&lines, column: c) }

    mutating func setRaw(_ index: Int, _ text: String) {
        if rawText == nil { rawText = lines.map { $0.serialize() } }
        guard rawText!.indices.contains(index) else { return }
        rawText![index] = text
    }

    mutating func commitRaw() {
        guard let raw = rawText else { return }
        lines = zip(lines, raw).map { line, text in ExcludeRuleLine.parse(text, chipEligible: line.chipEligible) }
        rawText = nil
    }

    func effectiveLines() -> [String] {
        lines.enumerated().map { i, line in rawText?[i] ?? line.serialize() }
    }
}

/// A countable approximation of an exclusion rule: a Cling search query plus optional folder scope.
struct ExcludeCountQuery: Equatable {
    var query: String
    var folders: [String]
    var dirsOnly: Bool
}

/// Translate one (possibly edited) exclusion rule into a Cling query that counts how many indexed items it
/// would hit. Best effort: over-counts for wildcards (any-depth vs one level), which is the safe direction for
/// an exclusion warning. Returns nil when no confident translation exists (the UI then shows no number).
func excludeCountQuery(line: String, supportsGlobs: Bool, blocklistPrefix: Bool, root: String?) -> ExcludeCountQuery? {
    let f = RuleGrid.frame(line)
    let tokens = f.tokens.map(\.original)
    guard !tokens.isEmpty else { return nil }
    let isWild: (String) -> Bool = { $0.contains("*") }

    // Extension glob: *.ext
    if supportsGlobs, tokens.count == 1, tokens[0].hasPrefix("*."), tokens[0].count > 2 {
        return ExcludeCountQuery(query: ".\(tokens[0].dropFirst(2))", folders: [], dirsOnly: false)
    }

    if !supportsGlobs {
        if blocklistPrefix {
            let abs = (f.anchored ? "/" : "") + tokens.joined(separator: "/")
            return ExcludeCountQuery(query: "", folders: [abs], dirsOnly: false)
        }
        guard let name = tokens.last(where: { !isWild($0) }) else { return nil }
        return ExcludeCountQuery(query: "\(name)/", folders: [], dirsOnly: true)
    }

    // fsignore path pattern
    if f.anchored, let root {
        if !tokens.contains(where: isWild) {
            return ExcludeCountQuery(query: "", folders: [root + "/" + tokens.joined(separator: "/")], dirsOnly: false)
        }
        let firstWild = tokens.firstIndex(where: isWild)!
        let prefix = tokens.prefix(firstWild).joined(separator: "/")
        let folder = prefix.isEmpty ? root : root + "/" + prefix
        // A trailing `*.ext` (e.g. /Music/nano/*.m4a) counts files of that type inside the prefix folder.
        if let last = tokens.last, last.hasPrefix("*."), last.count > 2 {
            return ExcludeCountQuery(query: ".\(last.dropFirst(2))", folders: [folder], dirsOnly: false)
        }
        if let name = tokens.suffix(from: firstWild + 1).last(where: { !isWild($0) }) {
            return ExcludeCountQuery(query: f.dirSlash ? "\(name)/" : "\(name)$", folders: [folder], dirsOnly: f.dirSlash)
        }
        return ExcludeCountQuery(query: "", folders: [folder], dirsOnly: false)
    }

    // unanchored fsignore: bare name at any depth
    guard let name = tokens.last(where: { !isWild($0) }) else { return nil }
    return ExcludeCountQuery(query: f.dirSlash ? "\(name)/" : "\(name)$", folders: [], dirsOnly: f.dirSlash)
}
