import Foundation

// MARK: - RuleLineKind

/// Where an editable rule line will be written. Drives matching semantics: fsignore lines are gitignore
/// patterns (wildcards honored); blocklist lines are literal byte matches (wildcards are dead text).
enum RuleLineKind: Equatable {
    case blocklistPrefix
    case blocklistContains
    case fsignoreReExclude
    case fsignoreReInclude

    var isFsignore: Bool {
        self == .fsignoreReExclude || self == .fsignoreReInclude
    }
}

// MARK: - RuleToken

/// One `/`-separated path component of a rule. A literal token cycles through wildcard states on click;
/// tokens that were already wildcards in the generated rule (`**`, `*.ext`) are fixed and never cycle.
struct RuleToken: Equatable {
    /// Wildcard state of a literal token. A file-like segment (one with an extension) gains an extra
    /// "keep the extension" step: literal -> `*.ext` -> `*` -> literal. A plain segment skips it:
    /// literal -> `*` -> literal.
    enum State: Equatable { case literal, extWildcard, fullWildcard }

    let original: String
    let isLiteral: Bool
    /// Extension of a file-like literal segment (e.g. "mp4" for "video.mp4"), else nil.
    let ext: String?
    var state: State = .literal

    var display: String {
        guard isLiteral else { return original }
        switch state {
        case .literal: return original
        case .extWildcard: return ext.map { "*.\($0)" } ?? "*"
        case .fullWildcard: return "*"
        }
    }

    /// Whether a literal token is currently showing a wildcard (drives the chip tint).
    var isWildcarded: Bool {
        isLiteral && state != .literal
    }

    /// Detect a file extension on a literal segment, mirroring `IndexInclusionAnalyzer.fileExtension`
    /// (a dot not at the start, a short non-empty extension, no spaces or wildcards). Case is preserved.
    static func detectExt(_ s: String) -> String? {
        guard let dot = s.lastIndex(of: "."), dot != s.startIndex else { return nil }
        let ext = String(s[s.index(after: dot)...])
        guard !ext.isEmpty, ext.count <= 12, !ext.contains(" "), !ext.contains("*") else { return nil }
        return ext
    }

    /// Advance to the next state in the cycle. No-op for fixed-wildcard tokens.
    mutating func cycle() {
        guard isLiteral else { return }
        switch state {
        case .literal: state = (ext != nil) ? .extWildcard : .fullWildcard
        case .extWildcard: state = .fullWildcard
        case .fullWildcard: state = .literal
        }
    }

}

// MARK: - TokenizedRuleLine

/// A rule line whose path tokens can be wildcard-cycled. `chipEligible` is true when its store honors globs.
protocol TokenizedRuleLine {
    var tokens: [RuleToken] { get set }
    var chipEligible: Bool { get }
}

// MARK: - RuleGrid

/// Shared, store-agnostic grid logic over a set of aligned rule lines: which columns can cycle, and cycling
/// them in lockstep. Used by both the reindex (`RuleEdit`) and exclude (`ExcludeEdit`) editors.
enum RuleGrid {
    /// Parse a rule line into its framing (leading `!`, leading `/` anchor, trailing `/` dir marker) and its
    /// `/`-split path tokens. A token containing `*` is a fixed wildcard; others are literal (with a detected
    /// extension when file-like).
    static func frame(_ line: String) -> (hasBang: Bool, anchored: Bool, dirSlash: Bool, tokens: [RuleToken]) {
        var s = line
        let bang = s.hasPrefix("!"); if bang { s.removeFirst() }
        let anchored = s.hasPrefix("/"); if anchored { s.removeFirst() }
        let dirSlash = s.count > 1 && s.hasSuffix("/"); if dirSlash { s.removeLast() }
        let parts = s.isEmpty ? [] : s.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let tokens = parts.map { part -> RuleToken in
            let literal = !part.contains("*")
            return RuleToken(original: part, isLiteral: literal, ext: literal ? RuleToken.detectExt(part) : nil)
        }
        return (bang, anchored, dirSlash, tokens)
    }

    /// Columns (over chip-eligible lines only) with at least one literal token and no fixed wildcard.
    static func togglableColumns(_ lines: [some TokenizedRuleLine]) -> Set<Int> {
        let eligible = lines.filter(\.chipEligible)
        guard !eligible.isEmpty else { return [] }
        let maxLen = eligible.map(\.tokens.count).max() ?? 0
        var cols = Set<Int>()
        for c in 0 ..< maxLen {
            var hasLiteral = false, hasFixedWildcard = false
            for line in eligible where c < line.tokens.count {
                if line.tokens[c].isLiteral { hasLiteral = true } else { hasFixedWildcard = true }
            }
            if hasLiteral, !hasFixedWildcard { cols.insert(c) }
        }
        return cols
    }

    /// Advance the wildcard state of every chip-eligible line's literal token at `column`, all to the same
    /// new state. The first cycles naturally; the rest are forced to match so the lines stay in lockstep.
    static func cycle(_ lines: inout [some TokenizedRuleLine], column c: Int) {
        var target: RuleToken.State?
        for i in lines.indices where lines[i].chipEligible && c < lines[i].tokens.count && lines[i].tokens[c].isLiteral {
            if target == nil { lines[i].tokens[c].cycle(); target = lines[i].tokens[c].state }
            else { lines[i].tokens[c].state = target! }
        }
    }

    /// Middle-truncate a string to roughly `max` characters (eliding the centre with `…`). Returns it unchanged
    /// when it already fits.
    static func middleTruncated(_ s: String, max: Int) -> String {
        guard s.count > max else { return s }
        guard max >= 3 else { return String(s.prefix(max)) }
        let keep = max - 1
        return "\(s.prefix(keep - keep / 2))…\(s.suffix(keep / 2))"
    }

    /// Fit path segments into a character `budget` (joined by `/`) by middle-truncating the LONGEST segments
    /// first, just enough to fit, leaving shorter segments untouched. Returns the segments unchanged when they
    /// already fit, so a short path that fits the row is never truncated. `minSeg` is the floor a segment is
    /// trimmed to before the next-longest is trimmed instead.
    static func fitSegments(_ segs: [String], budget: Int, minSeg: Int = 6) -> [String] {
        guard budget > 0, !segs.isEmpty else { return segs }
        let separators = segs.count - 1
        func total(_ s: [String]) -> Int {
            s.reduce(0) { $0 + $1.count } + separators
        }
        guard total(segs) > budget else { return segs }
        var out = segs
        var loops = 0
        while total(out) > budget, loops < 500 {
            loops += 1
            guard let idx = out.indices
                .filter({ out[$0].count > minSeg })
                .max(by: { out[$0].count < out[$1].count }) else { break }
            let over = total(out) - budget
            out[idx] = middleTruncated(out[idx], max: Swift.max(minSeg, out[idx].count - over))
        }
        return out
    }
}

// MARK: - RuleLine

/// A single editable rule line: optional leading `!`, optional `/` anchor, path tokens, optional trailing `/`.
struct RuleLine: Equatable, TokenizedRuleLine {
    let kind: RuleLineKind
    let hasBang: Bool
    let anchored: Bool
    let dirSlash: Bool
    var tokens: [RuleToken]
    /// Whether this rule is applied. Disabled rules are still shown (so the user can re-enable them) but are
    /// excluded from what apply writes and from the coverage check.
    var enabled = true

    var isFsignore: Bool {
        kind.isFsignore
    }
    var chipEligible: Bool {
        isFsignore
    }

    static func parse(_ text: String, kind: RuleLineKind) -> RuleLine {
        let f = RuleGrid.frame(text)
        return RuleLine(kind: kind, hasBang: f.hasBang, anchored: f.anchored, dirSlash: f.dirSlash, tokens: f.tokens)
    }

    func serialize() -> String {
        (hasBang ? "!" : "") + (anchored ? "/" : "") + tokens.map(\.display).joined(separator: "/") + (dirSlash ? "/" : "")
    }

}

// MARK: - RuleEdit

/// Editable state for one inclusion option's generated add-lines. Pure: parses, column-aligns and toggles
/// fsignore tokens, supports a raw-text override, and serializes back into kind-tagged lines.
struct RuleEdit: Equatable {
    init(blocklistPrefixes: [String], blocklistContains: [String], reExclude: [String], reInclude: [String]) {
        var ls: [RuleLine] = []
        ls += blocklistPrefixes.map { RuleLine.parse($0, kind: .blocklistPrefix) }
        ls += blocklistContains.map { RuleLine.parse($0, kind: .blocklistContains) }
        ls += reExclude.map { RuleLine.parse($0, kind: .fsignoreReExclude) }
        ls += reInclude.map { RuleLine.parse($0, kind: .fsignoreReInclude) }
        lines = ls
        rawText = nil
    }

    var lines: [RuleLine]
    /// When non-nil, a raw-edit override parallel to `lines` (one entry per line). Bypasses the token grid.
    private(set) var rawText: [String]?

    var isRaw: Bool {
        rawText != nil
    }

    /// Column indices (over fsignore lines only) that hold at least one literal token and no fixed wildcard,
    /// so a click can cycle them in lockstep.
    func togglableColumns() -> Set<Int> {
        RuleGrid.togglableColumns(lines)
    }

    /// Advance the wildcard state of every fsignore line's literal token at `column`, all to the same new
    /// state. The first matching token cycles naturally; the rest are forced to match so the lines stay in
    /// lockstep even if they ever held different originals.
    mutating func cycle(column c: Int) {
        RuleGrid.cycle(&lines, column: c)
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
        lines = zip(lines, raw).map { line, text in
            var parsed = RuleLine.parse(text, kind: line.kind)
            parsed.enabled = line.enabled
            return parsed
        }
        rawText = nil
    }

    /// Enable or disable one line (by index into `lines`).
    mutating func setEnabled(_ index: Int, _ on: Bool) {
        guard lines.indices.contains(index) else { return }
        lines[index].enabled = on
    }

    /// Serialized lines in apply order, raw override applied. Parallel to `lines` (includes disabled ones), so
    /// callers can index by position; use `enabledEffectiveLines()` for what apply should actually write.
    func effectiveLines() -> [(kind: RuleLineKind, text: String)] {
        lines.enumerated().map { i, line in
            (line.kind, rawText?[i] ?? line.serialize())
        }
    }

    /// Only the enabled lines, serialized in apply order.
    func enabledEffectiveLines() -> [(kind: RuleLineKind, text: String)] {
        lines.indices.compactMap { i in
            lines[i].enabled ? (lines[i].kind, rawText?[i] ?? lines[i].serialize()) : nil
        }
    }

    /// Lines that positively cover the target (used by the ✓/✗ probe): enabled blocklist exceptions and
    /// fsignore re-includes, with the leading `!` stripped. Re-exclude lines are not coverage, and a line that
    /// has lost its `!` (e.g. a raw edit deleting it) is no longer a re-inclusion, so it does not count as
    /// coverage either, keeping the badge honest about what apply would actually write.
    func reincludeLinesForValidation() -> [(kind: RuleLineKind, text: String)] {
        enabledEffectiveLines().compactMap { kind, text in
            guard kind != .fsignoreReExclude, text.hasPrefix("!") else { return nil }
            return (kind, String(text.dropFirst()))
        }
    }
}
