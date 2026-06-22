import Foundation

/// Where an editable rule line will be written. Drives matching semantics: fsignore lines are gitignore
/// patterns (wildcards honored); blocklist lines are literal byte matches (wildcards are dead text).
enum RuleLineKind: Equatable {
    case blocklistPrefix
    case blocklistContains
    case fsignoreReExclude
    case fsignoreReInclude

    var isFsignore: Bool { self == .fsignoreReExclude || self == .fsignoreReInclude }
}

/// One `/`-separated path component of a rule. Literal tokens can be toggled to `*`; tokens that were
/// already wildcards in the generated rule (`**`, `*.ext`) are fixed.
struct RuleToken: Equatable {
    let original: String
    let isLiteral: Bool
    var wildcarded: Bool = false

    var display: String { isLiteral ? (wildcarded ? "*" : original) : original }
}

/// A single editable rule line: an optional leading `!`, then path tokens.
struct RuleLine: Equatable {
    let kind: RuleLineKind
    let hasBang: Bool
    var tokens: [RuleToken]

    var isFsignore: Bool { kind.isFsignore }

    func serialize() -> String {
        (hasBang ? "!" : "") + tokens.map(\.display).joined(separator: "/")
    }

    static func parse(_ text: String, kind: RuleLineKind) -> RuleLine {
        var s = text
        let bang = s.hasPrefix("!")
        if bang { s.removeFirst() }
        let parts = s.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let tokens = parts.map { part -> RuleToken in
            RuleToken(original: part, isLiteral: !part.contains("*"), wildcarded: false)
        }
        return RuleLine(kind: kind, hasBang: bang, tokens: tokens)
    }
}

/// Editable state for one inclusion option's generated add-lines. Pure: parses, column-aligns and toggles
/// fsignore tokens, supports a raw-text override, and serializes back into kind-tagged lines.
struct RuleEdit: Equatable {
    var lines: [RuleLine]
    /// When non-nil, a raw-edit override parallel to `lines` (one entry per line). Bypasses the token grid.
    private(set) var rawText: [String]?

    var isRaw: Bool { rawText != nil }

    init(blocklistPrefixes: [String], blocklistContains: [String], reExclude: [String], reInclude: [String]) {
        var ls: [RuleLine] = []
        ls += blocklistPrefixes.map { RuleLine.parse($0, kind: .blocklistPrefix) }
        ls += blocklistContains.map { RuleLine.parse($0, kind: .blocklistContains) }
        ls += reExclude.map { RuleLine.parse($0, kind: .fsignoreReExclude) }
        ls += reInclude.map { RuleLine.parse($0, kind: .fsignoreReInclude) }
        lines = ls
        rawText = nil
    }

    /// Column indices (over fsignore lines only) that hold at least one literal token and no fixed wildcard,
    /// so a click can toggle them in lockstep.
    func togglableColumns() -> Set<Int> {
        let fs = lines.filter(\.isFsignore)
        guard !fs.isEmpty else { return [] }
        let maxLen = fs.map { $0.tokens.count }.max() ?? 0
        var cols = Set<Int>()
        for c in 0 ..< maxLen {
            var hasLiteral = false
            var hasFixedWildcard = false
            for line in fs where c < line.tokens.count {
                if line.tokens[c].isLiteral { hasLiteral = true } else { hasFixedWildcard = true }
            }
            if hasLiteral, !hasFixedWildcard { cols.insert(c) }
        }
        return cols
    }

    /// Flip literal↔`*` for every fsignore line that has a literal token at `column`, all to the same new state.
    mutating func toggle(column c: Int) {
        var newVal: Bool?
        for i in lines.indices where lines[i].isFsignore && c < lines[i].tokens.count && lines[i].tokens[c].isLiteral {
            if newVal == nil { newVal = !lines[i].tokens[c].wildcarded }
            lines[i].tokens[c].wildcarded = newVal!
        }
    }

    /// Begin (or continue) a raw-text override and set one line's text.
    mutating func setRaw(_ index: Int, _ text: String) {
        if rawText == nil { rawText = lines.map { $0.serialize() } }
        guard rawText!.indices.contains(index) else { return }
        rawText![index] = text
    }

    /// Re-parse the raw override back into tokenized lines (preserving each line's kind) and clear the override.
    mutating func commitRaw() {
        guard let raw = rawText else { return }
        lines = zip(lines, raw).map { line, text in RuleLine.parse(text, kind: line.kind) }
        rawText = nil
    }

    /// Serialized lines in apply order, raw override applied.
    func effectiveLines() -> [(kind: RuleLineKind, text: String)] {
        lines.enumerated().map { i, line in
            (line.kind, rawText?[i] ?? line.serialize())
        }
    }

    /// Lines that positively cover the target (used by the ✓/✗ probe): blocklist exceptions and fsignore
    /// re-includes, with the leading `!` stripped. Re-exclude lines are not coverage, and a line that has
    /// lost its `!` (e.g. a raw edit deleting it) is no longer a re-inclusion, so it does not count as
    /// coverage either, keeping the badge honest about what apply would actually write.
    func reincludeLinesForValidation() -> [(kind: RuleLineKind, text: String)] {
        effectiveLines().compactMap { kind, text in
            guard kind != .fsignoreReExclude, text.hasPrefix("!") else { return nil }
            return (kind, String(text.dropFirst()))
        }
    }
}
