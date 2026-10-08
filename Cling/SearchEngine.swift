import Foundation
import simd
#if canImport(Ignore)
    import Ignore
#endif
import os.log

private let slog = Logger(subsystem: clingSubsystem, category: "SearchEngine")

// MARK: - ScoringConfig

struct ScoringConfig: Codable, Equatable {
    static let `default` = ScoringConfig()

    var scoreMatch = 16
    var gapStart = -3
    var gapExtend = -1
    var bonusBoundary = 8
    var bonusNonWord = 8
    var bonusCamel = 7
    var bonusConsecutive = 4
    var firstCharMultiplier = 2
    var bonusWhitespace = 8
    var bonusDelimiter = 9
    var rankHasBaseBonus = 15
    var rankPrefixMatchBonus = 20
    var rankImportanceMultiplier = 8
    var rankLongPathThreshold = 80
    var basenameWastePenalty = 2

    static func load() -> ScoringConfig {
        guard let data = UserDefaults.standard.data(forKey: "scoringConfig"),
              let config = try? JSONDecoder().decode(ScoringConfig.self, from: data)
        else { return .default }
        return config
    }

    static func fromJSON(_ json: String) -> ScoringConfig? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ScoringConfig.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: "scoringConfig")
    }

    func toJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self), let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

}

private var SC = ScoringConfig.load()

private var scoreMatch: Int {
    SC.scoreMatch
}
private var gapStart: Int {
    SC.gapStart
}
private var gapExtend: Int {
    SC.gapExtend
}
private var bonusBoundary: Int {
    SC.bonusBoundary
}
private var bonusNonWord: Int {
    SC.bonusNonWord
}
private var bonusCamel123: Int {
    SC.bonusCamel
}
private var bonusConsec: Int {
    SC.bonusConsecutive
}
private var firstCharMul: Int {
    SC.firstCharMultiplier
}
private var bonusBdWhite: Int {
    SC.bonusWhitespace
}
private var bonusBdDelim: Int {
    SC.bonusDelimiter
}

func reloadScoringConfig() {
    SC = ScoringConfig.load()
    rebuildBonusFlat()
}

// MARK: - CC

private enum CC: Int { case white = 0, nonWord, delim, lower, upper, letter, number }
private let ccCount = 7

private let ccTable: [CC] = {
    var t = [CC](repeating: .nonWord, count: 256)
    for i in 0x61 ... 0x7A {
        t[i] = .lower
    }
    for i in 0x41 ... 0x5A {
        t[i] = .upper
    }
    for i in 0x30 ... 0x39 {
        t[i] = .number
    }
    for v: Int in [0x09, 0x0A, 0x0D, 0x20] {
        t[v] = .white
    }
    for v: Int in [0x2F, 0x2D, 0x5F, 0x2E, 0x2C, 0x3A, 0x3B, 0x7C] {
        t[v] = .delim
    }
    return t
}()

private func buildBonusFlat() -> [Int] {
    func b(_ p: CC, _ c: CC) -> Int {
        if c.rawValue > CC.nonWord.rawValue {
            switch p {
            case .white: return bonusBdWhite
            case .delim: return bonusBdDelim
            case .nonWord: return bonusBoundary
            default: break
            }
        }
        if p == .lower, c == .upper {
            return bonusCamel123
        }
        if p != .number, c == .number {
            return bonusCamel123
        }
        switch c {
        case .nonWord, .delim: return bonusNonWord
        case .white: return bonusBdWhite
        default: return 0
        }
    }
    var m = [Int](repeating: 0, count: ccCount * ccCount)
    for p in 0 ..< ccCount {
        for c in 0 ..< ccCount {
            m[p * ccCount + c] = b(CC(rawValue: p)!, CC(rawValue: c)!)
        }
    }
    return m
}

private var bonusFlat: [Int] = buildBonusFlat()

private func rebuildBonusFlat() {
    bonusFlat = buildBonusFlat()
}

// MARK: - SIMD Helpers

/// Find first occurrence of `needle` byte in buffer starting at `from`, using SIMD16 (128-bit NEON).
@inline(__always)
private func simdFindByte(_ base: UnsafePointer<UInt8>, count: Int, needle: UInt8, from: Int) -> Int {
    let needleVec = SIMD16<UInt8>(repeating: needle)
    var i = from

    while i &+ 16 <= count {
        let block = UnsafeRawPointer(base + i).loadUnaligned(as: SIMD16<UInt8>.self)
        let cmp = block .== needleVec
        // Check if any lane matched
        var lane = 0
        while lane < 16 {
            if cmp[lane] {
                return i &+ lane
            }
            lane &+= 1
        }
        i &+= 16
    }
    while i < count {
        if base[i] == needle {
            return i
        }
        i &+= 1
    }
    return -1
}

/// SIMD-accelerated substring search: locate `needle` in `base[0..<count]` by SIMD-scanning
/// for the first byte, then verifying the rest. Used for literal/anchor/negation operators.
@inline(__always)
private func simdContains(_ base: UnsafePointer<UInt8>, count: Int, needle: UnsafePointer<UInt8>, needleLen: Int) -> Bool {
    if needleLen == 0 {
        return true
    }
    if needleLen > count {
        return false
    }
    let first = needle[0]
    let limit = count &- needleLen
    var from = 0
    while from <= limit {
        let pos = simdFindByte(base, count: count, needle: first, from: from)
        if pos < 0 || pos > limit {
            return false
        }
        var j = 1
        var ok = true
        while j < needleLen {
            if base[pos &+ j] != needle[j] {
                ok = false; break
            }
            j &+= 1
        }
        if ok {
            return true
        }
        from = pos &+ 1
    }
    return false
}

/// `$` anchor matcher: true if `needle` is a suffix of the basename, or of the basename
/// stem (basename minus its final `.ext`). So "icon$" matches "crank-icon.png" via the
/// stem "crank-icon", and "icon.png$" matches via the full basename.
@inline(__always)
private func nameEndsWith(_ base: UnsafePointer<UInt8>, off: Int, len: Int, bnStart: Int, needle: UnsafePointer<UInt8>, needleLen: Int) -> Bool {
    let bnLen = len &- bnStart
    if needleLen == 0 || needleLen > bnLen {
        return false
    }
    let bnFloor = off &+ bnStart
    @inline(__always) func endsAt(_ end: Int) -> Bool {
        let start = end &- needleLen
        if start < bnFloor {
            return false
        }
        var j = 0
        while j < needleLen {
            if base[start &+ j] != needle[j] {
                return false
            }
            j &+= 1
        }
        return true
    }
    if endsAt(off &+ len) {
        return true
    }
    // Find the final '.' within the basename (skip a leading dotfile dot).
    var dot = -1
    var k = off &+ len &- 1
    while k > bnFloor {
        if base[k] == 0x2E {
            dot = k; break
        }
        k &-= 1
    }
    if dot > bnFloor {
        return endsAt(dot)
    }
    return false
}

/// SIMD bitmask filter: check `masks[i] & qMask == qMask` for 8 entries at once.
/// Returns number of passing indices written to `out`.
private func simdFilterMasks(
    _ maskPtr: UnsafePointer<UInt64>, count: Int,
    queryMask: UInt64,
    extIDs: UnsafePointer<UInt16>?, extTarget: UInt16,
    filterByExt: Bool,
    out: UnsafeMutablePointer<Int>
) -> Int {
    var resultCount = 0
    let qm = SIMD8<UInt64>(repeating: queryMask)

    var i = 0
    while i &+ 8 <= count {
        let v = UnsafeRawPointer(maskPtr + i).loadUnaligned(as: SIMD8<UInt64>.self)
        let maskMatch = (v & qm) .== qm
        // Check lanes
        var anyMatch = false
        var lane = 0
        while lane < 8 {
            if maskMatch[lane] {
                anyMatch = true; break
            }
            lane &+= 1
        }
        if anyMatch {
            lane = 0
            while lane < 8 {
                if maskMatch[lane] {
                    let idx = i &+ lane
                    if !filterByExt || extIDs![idx] == extTarget {
                        out[resultCount] = idx
                        resultCount &+= 1
                    }
                }
                lane &+= 1
            }
        }
        i &+= 8
    }
    // Scalar remainder
    while i < count {
        if maskPtr[i] & queryMask == queryMask {
            if !filterByExt || extIDs![i] == extTarget {
                out[resultCount] = i
                resultCount &+= 1
            }
        }
        i &+= 1
    }
    return resultCount
}

// MARK: - Byte-level Fuzzy Matcher

@inline(__always) private func toLowerByte(_ b: UInt8) -> UInt8 {
    (b >= 0x41 && b <= 0x5A) ? b &+ 32 : b
}

private func fuzzyScoreBytes(
    _ pat: UnsafeBufferPointer<UInt8>,
    _ txt: UnsafeBufferPointer<UInt8>,
    boundaries: UInt64 = 0,
    boundariesOffset: Int = 0
) -> (score: Int, start: Int, end: Int)? {
    let M = pat.count, N = txt.count
    if M == 0 {
        return (0, 0, 0)
    }
    if M > N {
        return nil
    }

    let txtBase = txt.baseAddress!
    let firstChar = pat[0]

    var bestScore = Int.min
    var bestStart = -1
    var bestEnd = -1

    // Anchor enumeration: try matching from each pat[0] occurrence and keep
    // the best-scoring alignment. Plain leftmost-greedy misses tighter matches:
    // e.g. "lnr" against "/users/alex/projects/lunar/..." picks 'l' in 'alex'
    // (cross-segment, low score) and never explores 'lunar' (single-segment,
    // boundary-aligned, much higher score).
    var anchorFrom = 0
    var anchorsTried = 0
    let maxAnchors = 32

    while anchorsTried < maxAnchors {
        let anchor = simdFindByte(txtBase, count: N, needle: firstChar, from: anchorFrom)
        if anchor < 0 {
            break
        }
        if anchor &+ M > N {
            break
        }

        // Forward greedy from this anchor
        var pi = 1
        var searchFrom = anchor &+ 1
        var lastPos = anchor
        var matched = true
        while pi < M {
            let pos = simdFindByte(txtBase, count: N, needle: pat[pi], from: searchFrom)
            if pos < 0 {
                matched = false; break
            }
            lastPos = pos
            searchFrom = pos &+ 1
            pi &+= 1
        }
        // If the suffix can't be matched from this anchor it can't be matched
        // from any later anchor either: forward-greedy from a > anchor would
        // either reuse the same suffix positions or skip past them.
        if !matched {
            break
        }

        let eidx = lastPos &+ 1
        var sidx = anchor

        // Backward tighten within [anchor, eidx)
        pi = M &- 1
        var bi = eidx &- 1
        while bi >= anchor {
            if txtBase[bi] == pat[pi] {
                pi &-= 1
                if pi < 0 {
                    sidx = bi; break
                }
            }
            bi &-= 1
        }

        // Score the alignment within [sidx, eidx)
        var score = 0, consecutive = 0, firstBonus = 0, inGap = false
        var prevCC = sidx > 0 ? ccTable[Int(txt[sidx &- 1])].rawValue : CC.delim.rawValue
        pi = 0
        for i in sidx ..< eidx {
            let b = txt[i]
            let curCC = ccTable[Int(b)].rawValue
            if toLowerByte(b) == pat[pi] {
                score &+= scoreMatch
                var bonus = bonusFlat[prevCC &* ccCount &+ curCC]
                // Use precomputed boundary info to restore camelCase/delimiter bonuses lost by lowercasing
                if boundaries != 0 {
                    let bpos = i &- boundariesOffset
                    if bpos >= 0, bpos < 64, boundaries & (1 << UInt64(bpos)) != 0 {
                        bonus = max(bonus, bonusBoundary)
                    }
                }
                if consecutive == 0 {
                    firstBonus = bonus
                } else {
                    if bonus >= bonusBoundary, bonus > firstBonus {
                        firstBonus = bonus
                    }
                    bonus = max(bonus, max(bonusConsec, firstBonus))
                }
                score &+= pi == 0 ? bonus &* firstCharMul : bonus
                inGap = false; consecutive &+= 1; pi &+= 1
            } else {
                score &+= inGap ? gapExtend : gapStart
                inGap = true; consecutive = 0; firstBonus = 0
            }
            prevCC = curCC
        }

        if score > bestScore {
            bestScore = score
            bestStart = sidx
            bestEnd = eidx
        }

        anchorFrom = anchor &+ 1
        anchorsTried &+= 1
    }

    return bestStart < 0 ? nil : (bestScore, bestStart, bestEnd)
}

// MARK: - Letter Bitmask (a-z + 0-9 + . - _)

@inline(__always)
private func letterMaskBytes(_ p: UnsafeBufferPointer<UInt8>) -> UInt64 {
    var m: UInt64 = 0
    for i in 0 ..< p.count {
        let v = p[i]
        if v >= 0x61, v <= 0x7A {
            m |= 1 << UInt64(v &- 0x61)
        } else if v >= 0x30, v <= 0x39 {
            m |= 1 << UInt64(26 &+ v &- 0x30)
        } else if v == 0x2E {
            m |= 1 << 36
        } else if v == 0x2D {
            m |= 1 << 37
        } else if v == 0x5F {
            m |= 1 << 38
        }
    }
    return m
}

/// Split a query into space-delimited tokens, but keep a double-quoted run as a single token
/// (quotes removed). Lets a path with spaces survive, e.g. `in:"/Users/me/My Folder"`. Single
/// quotes are left intact so the leading-quote literal operator ('foo) is unaffected.
/// How far a typed extension is from a real one, in the terms the person typing was thinking in.
///
/// Dropping letters is abbreviation, not error: `ml` is how you shorten `toml`, the same way
/// `cfghlx` shortens `config helix`. Levenshtein charges two deletions for that while charging only
/// one substitution for `ml` against `md`, which ranked a README above the `.toml` actually being
/// looked for. A tail contained in the extension in order is therefore free, and edit distance is
/// left to do what it is good at: catching a genuine slip like `yml` for `toml`.
private func extDistance(_ tail: [UInt8], _ ext: [UInt8], limit: Int) -> Int {
    // Half the extension at least, or it isn't an abbreviation of it. `extID` puts no length cap
    // on what counts as an extension, so the index is full of junk like `.o-5VSGCNWGXUX6`, and a
    // long enough string contains almost any short tail in order: `ml` "abbreviates" `.metal`, and
    // `gyml` matched a build-artifact suffix well enough to be picked over the real `yml`.
    if tail.count * 2 >= ext.count {
        var t = 0
        for c in ext where t < tail.count {
            if tail[t] == c {
                t &+= 1
            }
        }
        if t == tail.count {
            return 0
        }
    }
    return editDistance(tail, ext, limit: limit)
}

/// Levenshtein distance between two short byte strings, abandoned once it passes `limit`.
/// Extensions are a handful of bytes, so the plain table is cheaper than anything cleverer.
private func editDistance(_ a: [UInt8], _ b: [UInt8], limit: Int) -> Int {
    if a.isEmpty {
        return b.count
    }
    if b.isEmpty {
        return a.count
    }
    if abs(a.count - b.count) > limit {
        return limit + 1
    }

    var prev = Array(0 ... b.count)
    var cur = [Int](repeating: 0, count: b.count + 1)
    for i in 1 ... a.count {
        cur[0] = i
        var rowMin = cur[0]
        for j in 1 ... b.count {
            let cost = a[i - 1] == b[j - 1] ? 0 : 1
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            rowMin = min(rowMin, cur[j])
        }
        if rowMin > limit {
            return limit + 1
        }
        swap(&prev, &cur)
    }
    return prev[b.count]
}

/// How far a typed extension may sit from the real one before it stops counting as that extension.
/// Two edits is what `yml` costs against `toml`, which is the case this exists for.
private let extTailMaxDistance = 2

/// What an approximately-matched extension is worth, on the same scale the fuzzy matcher pays for
/// characters it really did match (`scoreMatch` each). An exact extension earns the full amount, so
/// reading `helixcfgtml` as name + `tml` scores like the eleven-character match it is; two edits away
/// earns a third of it. Without this a split reading always loses to a longer literal subsequence,
/// however much junk that subsequence had to walk through.
private func extCredit(distance: Int, maxDist: Int, tailLen: Int) -> Int {
    (maxDist + 1 - distance) * tailLen * SC.scoreMatch / (maxDist + 1)
}

/// Ways to read a single-token query as `<name><extension>`, longest name first.
///
/// Bare fuzzy queries only. A space, dot, slash or operator sigil means the query already states
/// what it wants (`in:`, `.toml`, `^foo`, `!bar`), and guessing an extension on top of that would
/// fight the user rather than help.
private func extensionTailSplits(_ q: String) -> [(head: String, tail: [UInt8])] {
    let bytes = Array(q.utf8)
    guard bytes.count >= 6 else { return [] }
    for b in bytes {
        let isLower = b >= 0x61 && b <= 0x7A
        let isDigit = b >= 0x30 && b <= 0x39
        guard isLower || isDigit else { return [] }
    }
    var splits: [(head: String, tail: [UInt8])] = []
    // The name has to carry the search on its own. At 4 or 5 bytes a head matches half the disk,
    // and the extension credit then promotes whichever of those happened to rank well, even a
    // `.cc` file, two edits from `cfg`.
    for tailLen in 2 ... 5 where bytes.count - tailLen >= 6 {
        splits.append((
            String(decoding: bytes[0 ..< (bytes.count - tailLen)], as: UTF8.self),
            Array(bytes[(bytes.count - tailLen)...])
        ))
    }
    return splits
}

// MARK: - Typo tolerance

/// What `typos` typos cost a result's rank. A misspelt name otherwise ranks as its twin spelt the way the query was
/// would, so this is what orders one typo ahead of two, and either behind a near-miss of the fuzzy match that needed
/// none. Names holding the query exactly as typed are kept ahead of every typo by `typosAfterTypedMatches`.
///
/// A second typo costs twice the first. Two skipped letters can drop a whole suffix, which is right for `catalogue`
/// against `catalog` but also reads `canceled` as `cancel`, and every name that is just `cancel` would then outrank
/// the `cancelled` one that differs by a single letter.
private func typoCost(_ typos: Int) -> Int {
    typos * (typos + 1) / 2 * SC.scoreMatch
}

/// A name a misspelt reading found: the score its twin spelt as typed would have, and the typos between them.
private typealias TypoHit = (score: Int, typos: Int)

/// Furthest a misspelt name sinks to stay behind the names that hold the query as typed: four matched letters' worth,
/// or eight steps of folder importance.
private var typoTypedReach: Int {
    4 * SC.scoreMatch
}

// MARK: - TypoQuery

/// A bare query read as words that may be misspelt, for the pass that finds `color` from `colour`.
///
/// A fuzzy match already forgives a letter left out (`occurence` finds `occurrence`). What it can't forgive is a letter
/// the name doesn't have: one typed extra (`colour`, `catalogue`), one typed for another (`grey`, `licence`, `seperate`)
/// or two swapped (`metre`, `centre`). Each of those comes down to skipping a letter of the query, so that is the only
/// edit there is: one per query, or two once it is long enough to stay specific without them.
private struct TypoQuery {
    init?(_ query: String) {
        let words = query.lowercased().split(separator: " ").map { Array($0.utf8) }
        var letters: [UInt8] = []
        var skippable: UInt64 = 0
        var wordStarts: UInt64 = 0
        var swappable: UInt64 = 0
        for word in words {
            // A swap in a four-letter word leaves too little of it standing: `form` swaps into `from`.
            if word.count >= 5, letters.count + word.count <= 64 {
                swappable |= (word.count == 64 ? .max : (1 << UInt64(word.count)) - 1) << UInt64(letters.count)
            }
            for (i, b) in word.enumerated() {
                let isLetter = b >= 0x61 && b <= 0x7A
                // Operators, extensions, paths and anything non-ASCII say exactly what the query wants.
                guard isLetter || (b >= 0x30 && b <= 0x39) else { return nil }
                guard letters.count < 64 else { return nil }
                // Nobody misspells the letter a word starts with, and letting it go reads `grey` as `rey`. Digits are
                // typed on purpose too.
                if i == 0 {
                    wordStarts |= 1 << UInt64(letters.count)
                } else if isLetter {
                    skippable |= 1 << UInt64(letters.count)
                }
                letters.append(b)
            }
        }
        guard letters.count >= 4, skippable != 0 else { return nil }
        // A query without its vowels is an abbreviation, and one with a letter skipped reads as some other word
        // spelt out in full, which then ranks as a whole word above the names it abbreviates. Words people misspell
        // keep their vowels, so a quarter of the letters is the floor.
        var vowels = 0, alpha = 0
        for b in letters where b >= 0x61 {
            alpha += 1
            if b == 0x61 || b == 0x65 || b == 0x69 || b == 0x6F || b == 0x75 || b == 0x79 {
                vowels += 1
            }
        }
        guard vowels * 4 >= alpha else { return nil }

        self.words = words
        self.letters = letters
        self.skippable = skippable
        self.wordStarts = wordStarts
        self.swappable = swappable
        budget = letters.count >= 8 ? 2 : 1
        mask = letters.withUnsafeBufferPointer { letterMaskBytes($0) }
        var peq = [UInt64](repeating: 0, count: 256)
        for (i, b) in letters.enumerated() {
            peq[Int(b)] |= 1 << UInt64(i)
        }
        self.peq = peq
        twinScore = words.reduce(0) { sum, word in
            sum + word.withUnsafeBufferPointer { fuzzyScoreBytes($0, $0)?.score ?? 0 }
        }
    }

    let words: [[UInt8]]
    /// The words run together, which is how a name is matched against them.
    let letters: [UInt8]
    /// Bit i: `letters[i]` may be skipped.
    let skippable: UInt64
    /// Bit i: `letters[i]` starts one of the words.
    let wordStarts: UInt64
    /// Bit i: `letters[i]` may be found swapped with its neighbour.
    let swappable: UInt64
    /// Most letters one reading may skip.
    let budget: Int
    let mask: UInt64
    /// Bit i of entry b: `letters[i] == b`, for `lcsLength`.
    let peq: [UInt64]
    /// What the words score against a name that starts with them spelt exactly as typed, before the rest of the name
    /// is charged for.
    let twinScore: Int

    /// The query with the letters in `skip` left out, its words kept apart.
    func reading(skipping skip: UInt64) -> String {
        var out: [UInt8] = []
        var li = 0
        for word in words {
            if !out.isEmpty {
                out.append(0x20)
            }
            for b in word {
                if skip & (1 << UInt64(li)) == 0 {
                    out.append(b)
                }
                li += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// Length of the longest common subsequence of the query and `txt`, bit-parallel (Hyyrö 2004): an add and a few logic
/// ops per byte, so it rules out nearly every name before a single reading of the query is tried on it.
@inline(__always)
private func lcsLength(_ peq: UnsafePointer<UInt64>, _ m: Int, _ txt: UnsafePointer<UInt8>, _ n: Int) -> Int {
    var v = UInt64.max
    var j = 0
    while j < n {
        let u = v & peq[Int(txt[j])]
        v = (v &+ u) | (v &- u)
        j &+= 1
    }
    let full: UInt64 = m == 64 ? .max : (1 << UInt64(m)) &- 1
    return (~v & full).nonzeroBitCount
}

/// Whether a word of the name starts at `pos`: its first byte, after a delimiter, or a camelCase hump.
@inline(__always)
private func startsWord(_ bn: UnsafeBufferPointer<UInt8>, _ pos: Int, _ bounds: UInt64) -> Bool {
    if pos == 0 {
        return true
    }
    if pos < 64 {
        return bounds & (1 << UInt64(pos)) != 0
    }
    let prev = bn[pos - 1]
    return prev < 0x80 && !(prev >= 0x61 && prev <= 0x7A) && !(prev >= 0x30 && prev <= 0x39)
}

/// Whether a word of the name ends right before `pos`.
@inline(__always)
private func endsWord(_ bn: UnsafeBufferPointer<UInt8>, _ pos: Int, _ bounds: UInt64) -> Bool {
    if pos >= bn.count {
        return true
    }
    let b = bn[pos]
    if (b >= 0x61 && b <= 0x7A) || b >= 0x80 {
        return pos < 64 && bounds & (1 << UInt64(pos)) != 0
    }
    return true
}

/// The best reading of the name `bn` as a misspelling of the query: the query letters it skips, the stretch of the name
/// it covers and how many typos it takes. Nil when the name holds the query as typed, which the plain search ranks on
/// its own, or when no reading lands on a word of it.
///
/// Fewest typos first, and among those the one covering most of the name, which is the one whose twin wastes least.
private func typoReading(
    _ tq: TypoQuery, _ bn: UnsafeBufferPointer<UInt8>, bounds: UInt64, lcs: Int
) -> (skip: UInt64, window: Int, typos: Int)? {
    let m = tq.letters.count
    if lcs == m, typoAlignment(tq, skipping: 0, dropping: 0, bn, bounds: bounds) != nil {
        return nil
    }
    var best: (skip: UInt64, window: Int, typos: Int)?
    func consider(_ skip: UInt64) {
        let skipped = skip.nonzeroBitCount
        guard let a = typoAlignment(tq, skipping: skip, dropping: tq.budget - skipped, bn, bounds: bounds) else { return }
        let window = a.end - a.start
        let typos = skipped + a.dropped
        // A reading has to cover a word worth the name: three letters match half the disk, and a short query read
        // as a three-letter word buries the longer names it abbreviates.
        guard typos > 0, window >= 4 else { return }
        if best == nil || typos < best!.typos || typos == best!.typos && window > best!.window {
            best = (skip, window, typos)
        }
    }
    // Every reading is a common subsequence of query and name, so `lcs` says how many letters it has to skip. Skipping
    // none, the name may still hold letters the query dropped: `documnt` against `document`.
    if lcs == m {
        consider(0)
    }
    if lcs >= m - 1, best?.typos ?? 2 > 1 {
        for i in 0 ..< m where tq.skippable & (1 << UInt64(i)) != 0 {
            // Skipping either half of a doubled letter reads the same.
            if i > 0, tq.letters[i] == tq.letters[i - 1], tq.skippable & (1 << UInt64(i - 1)) != 0 {
                continue
            }
            consider(1 << UInt64(i))
        }
    }
    if best == nil, tq.budget >= 2, lcs >= m - 2 {
        for i in 0 ..< m where tq.skippable & (1 << UInt64(i)) != 0 {
            for j in i + 1 ..< m where tq.skippable & (1 << UInt64(j)) != 0 {
                consider(1 << UInt64(i) | 1 << UInt64(j))
            }
        }
    }
    return best
}

/// Most bytes that may separate two words of a misspelt query in a name: ` - ` at most.
private let typoMaxSeparator = 3

/// Where the query, less the letters in `skip`, sits in the name `bn` as a misspelt word: the stretch of the name it
/// covers and how many of the name's letters the query dropped, or nil.
///
/// The name may differ from the query only where a letter was skipped: by as many letters of its own as were skipped
/// there (`gray` has its `a` right where `grey` has the `e`), or by the skipped letter turning up one place late, which
/// is two letters swapped (`metre` against `meter`, `recieve` against `receive`). Anywhere else inside a word it may
/// hold up to `dropping` letters the query left out (`documnt` against `document`). Each word of the query stays
/// inside one word of the name, starting where that word starts, and the misspelt word ends where the name's word
/// does, give or take a plural `s`. That is what keeps `grey` off names whose stray letter sits somewhere
/// else, and off `green` (`gre` stops mid-word).
private func typoAlignment(
    _ tq: TypoQuery, skipping skip: UInt64, dropping: Int, _ bn: UnsafeBufferPointer<UInt8>, bounds: UInt64
) -> (start: Int, end: Int, dropped: Int)? {
    let m = tq.letters.count
    let n = bn.count
    @inline(__always) func isWordByte(_ b: UInt8) -> Bool {
        (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) || b >= 0x80
    }

    /// The end of the stretch and the drops left, matching on from query letter `qi` found at name position `pos`.
    /// `late` is a letter skipped right before `qi` that may still turn up next, or 0.
    func matchRest(_ qi: Int, _ pos: Int, _ late: UInt8, _ left: Int) -> (end: Int, left: Int)? {
        var next = qi + 1
        while next < m, skip & (1 << UInt64(next)) != 0 {
            next += 1
        }
        let skipped = next - qi - 1
        let lateHere = late != 0 && pos + 1 < n && bn[pos + 1] == late && !startsWord(bn, pos + 1, bounds)
        if next == m {
            // A swap finishes the word as typed, whatever the name goes on with: `metre` finds `meters`.
            if lateHere {
                return (pos + 2, left)
            }
            // Spelt exactly as typed, which the plain search ranks on its own.
            if skip == 0, left == dropping {
                return (pos + 1, left)
            }
            if endsWord(bn, pos + 1, bounds) {
                return (pos + 1, left)
            }
            if pos + 1 < n, bn[pos + 1] == 0x73, endsWord(bn, pos + 2, bounds) {
                return (pos + 2, left)
            }
            return nil
        }
        // Try with the late letter taken first, then without it.
        var attempt = lateHere ? 0 : 1
        while attempt < 2 {
            let from = attempt == 0 ? pos + 2 : pos + 1
            attempt += 1
            if tq.wordStarts & (1 << UInt64(next)) != 0 {
                // The next word of the query starts the next word of the name, past whatever separates them: a space,
                // punctuation, or nothing at a camelCase hump.
                var p = from
                while p < n, p - from < typoMaxSeparator, !isWordByte(bn[p]) {
                    p += 1
                }
                if p < n, bn[p] == tq.letters[next], startsWord(bn, p, bounds), let r = matchRest(next, p, 0, left) {
                    return r
                }
                continue
            }
            // Inside a word, the name may hold up to `skipped` letters of its own before the next one, and any it
            // holds past those are letters the query dropped. When it holds none, the skipped letter may still turn
            // up right after, as half of a swap.
            var p = from
            while p < n, p <= from + skipped + left, isWordByte(bn[p]), !startsWord(bn, p, bounds) {
                let carry = skipped > 0 && p == from && tq.swappable & (1 << UInt64(next - 1)) != 0
                    ? tq.letters[next - 1]
                    : 0
                if bn[p] == tq.letters[next], let r = matchRest(next, p, carry, left - max(0, p - from - skipped)) {
                    return r
                }
                p += 1
            }
        }
        return nil
    }

    let first = tq.letters[0]
    var s = 0
    while s < n {
        if bn[s] == first, startsWord(bn, s, bounds), let r = matchRest(0, s, 0, dropping) {
            return (s, r.end, dropping - r.left)
        }
        s += 1
    }
    return nil
}

func tokenizeQuery(_ s: String) -> [String] {
    var tokens: [String] = []
    var cur = ""
    var inQuote = false
    var has = false
    var escaped = false
    for ch in s {
        if escaped {
            // Kept as typed, a space or quote included, and decoded with the rest of the token.
            cur.append(ch); escaped = false
        } else if ch == "\\" {
            cur.append(ch); has = true; escaped = true
        } else if ch == "\"" {
            inQuote.toggle(); has = true
        } else if ch == " ", !inQuote {
            if has {
                tokens.append(cur); cur = ""; has = false
            }
        } else {
            cur.append(ch); has = true
        }
    }
    if has {
        tokens.append(cur)
    }
    return tokens
}

/// Escapes for what a query can't otherwise hold: `\r`, `\n` and `\t` (a custom folder icon is a file named `Icon\r`),
/// `\xHH` for any byte and `\uHHHH` for any character, and a backslash before a space, a quote, a backslash or an
/// operator character (`\ `, `\"`, `\'`, `\!`, `\^`, `\$`, `\\`) for that character as plain text. Any other backslash
/// stays as typed, so a query that already had one means what it did before.
///
/// The token comes from the lowercased query and goes back lowercased, as `\x41` decodes to an uppercase A.
func decodeQueryEscapes(_ token: String) -> String {
    guard token.utf8.contains(0x5C) else { return token }
    let src = Array(token.utf8)
    var out: [UInt8] = []
    out.reserveCapacity(src.count)

    @inline(__always) func hexValue(_ b: UInt8) -> UInt32? {
        switch b {
        case 0x30 ... 0x39: UInt32(b - 0x30)
        case 0x61 ... 0x66: UInt32(b - 0x61 + 10)
        case 0x41 ... 0x46: UInt32(b - 0x41 + 10)
        default: nil
        }
    }
    /// The value of `count` hex digits starting at `at`, when they are all there.
    func hex(at start: Int, count: Int) -> UInt32? {
        guard start + count <= src.count else { return nil }
        var v: UInt32 = 0
        for k in start ..< start + count {
            guard let d = hexValue(src[k]) else { return nil }
            v = v << 4 | d
        }
        return v
    }

    var i = 0
    while i < src.count {
        guard src[i] == 0x5C, i + 1 < src.count else {
            out.append(src[i]); i += 1
            continue
        }
        switch src[i + 1] {
        case UInt8(ascii: "r"):
            out.append(0x0D); i += 2
        case UInt8(ascii: "n"):
            out.append(0x0A); i += 2
        case UInt8(ascii: "t"):
            out.append(0x09); i += 2
        case UInt8(ascii: " "), UInt8(ascii: "\""), UInt8(ascii: "'"), UInt8(ascii: "!"),
             UInt8(ascii: "^"), UInt8(ascii: "$"), UInt8(ascii: "\\"):
            out.append(src[i + 1]); i += 2
        case UInt8(ascii: "x"):
            if let byte = hex(at: i + 2, count: 2) {
                out.append(UInt8(byte)); i += 4
            } else {
                out.append(src[i]); i += 1
            }
        case UInt8(ascii: "u"):
            if let code = hex(at: i + 2, count: 4), let scalar = Unicode.Scalar(code) {
                out.append(contentsOf: Array(String(Character(scalar)).utf8)); i += 6
            } else {
                out.append(src[i]); i += 1
            }
        default:
            out.append(src[i]); i += 1
        }
    }
    return String(decoding: out, as: UTF8.self).lowercased()
}

/// Whether the last character of a token is escaped: an odd run of backslashes right before it.
func lastIsEscaped(_ token: String) -> Bool {
    var backslashes = 0
    for b in token.utf8.dropLast().reversed() {
        guard b == 0x5C else { break }
        backslashes += 1
    }
    return backslashes % 2 == 1
}

// MARK: - SearchResult

struct SearchResult: Comparable {
    let path: String
    let isDir: Bool
    let score: Int
    let quality: Int
    let hasBase: Bool
    let segmentMatches: Int // number of tokens matching at path segment boundaries (for multi-token)
    let pathImportance: Int // 4=important dir, 3=home, 2=library, 1=system, 0=hidden
    let prefixMatch: Bool
    let depth: Int
    var sourceLabel = ""
    /// Score credited for an extension the user typed approximately, on the same scale as characters
    /// the matcher really did match. Zero unless this result came from an extension reading.
    var extCredit = 0
    /// Letters of the query this result's name doesn't have: `colour` finds `color` with one.
    /// Zero for everything the query matches as typed.
    var typos = 0
    /// Highest rank this result may have, set by `typosAfterTypedMatches`.
    var rankCap = Int.max
    /// For a misspelt reading of a name the plain search found too: the rank that match earned, which the
    /// reading never drops the name below.
    var rankAsTyped = Int.min

    /// Composite rank combining match type, importance, and quality into a single comparable value.
    /// hasBase and prefixMatch provide bonuses, but quality differences can overcome them.
    /// Uses max(score, quality) so boundary-aligned matches with wider windows aren't penalized.
    ///
    /// `quality` is the match's density (score per byte of the window it spans). People abbreviate
    /// by dropping vowels from words they can hear, so a real query lands in a tight window, while
    /// a long path can always be made to yield the same letters by scattering them across unrelated
    /// words. Both come out with a high `score`, and taking the better of the two let the scattered
    /// one ride on length alone. Charge it for the difference, but only once density has fallen
    /// below half the score: dense matches, which is nearly all of them, are left exactly as they
    /// were, so this costs the ranking nothing where the match already looks human.
    var rank: Int {
        max(rankAsTyped, min(scoredRank, rankCap))
    }

    /// The rank the match itself earns, before `typosAfterTypedMatches` places a misspelt one.
    var scoredRank: Int {
        var r = max(score, quality)
        let densityFloor = score / 2
        if quality < densityFloor {
            r -= densityFloor - quality
        }
        if hasBase {
            r += SC.rankHasBaseBonus
        }
        r += segmentMatches * SC.rankHasBaseBonus
        if prefixMatch {
            r += SC.rankPrefixMatchBonus
        }
        r += extCredit
        r -= typoCost(typos)
        r += pathImportance * SC.rankImportanceMultiplier
        r -= max(0, path.count - SC.rankLongPathThreshold)
        return r
    }

    /// Whether the name holds the query exactly as typed, where the name or one of its words starts: the
    /// query names something that exists. A match the fuzzy subsequence assembled doesn't count, since on
    /// a full disk nearly every misspelling assembles one somewhere (`cahin` out of `caching`).
    var matchesAsTyped: Bool {
        typos == 0 && hasBase && prefixMatch
    }

    static func < (lhs: SearchResult, rhs: SearchResult) -> Bool {
        let lr = lhs.rank, rr = rhs.rank
        if lr != rr {
            return lr < rr
        }
        if lhs.score != rhs.score {
            return lhs.score < rhs.score
        }
        if lhs.depth != rhs.depth {
            return lhs.depth > rhs.depth
        }
        return lhs.path.count > rhs.path.count
    }
}

extension [SearchResult] {
    /// These results with every name found by reading the query as misspelt ranked below the last name it matched as
    /// typed. Applied wherever results meet, since one index's typo can't be weighed against another's exact match
    /// any other way.
    ///
    /// A query that matches something as typed meant that something, so names holding it come before any misspelt
    /// reading, even a shorter name that would score higher.
    ///
    /// A misspelt name drops at most `typoTypedReach` for it, though. One name that happens to start with the query,
    /// deep in some system folder at the bottom of the list, would otherwise sink every typo under the scattered
    /// matches ranked above it.
    func typosAfterTypedMatches() -> [SearchResult] {
        var floor = Int.max
        for r in self where r.matchesAsTyped {
            floor = Swift.min(floor, r.rank)
        }
        guard floor != Int.max, contains(where: { $0.typos > 0 && $0.scoredRank >= floor }) else { return self }
        // From the match's own rank, so placing the same results again, as each index does and then the merge of
        // all of them, never sinks a name further than the lowest floor does on its own.
        return map { r in
            guard r.typos > 0, r.scoredRank >= floor else { return r }
            var capped = r
            capped.rankCap = Swift.min(r.rankCap, Swift.max(floor - 1, r.scoredRank - typoTypedReach))
            return capped
        }
    }
}

// MARK: - IgnoreNegations

/// The `!` rules of an ignore file that name a path below where its patterns are anchored (`!Library/Caches/Clop/*`,
/// and every rule Cling writes to re-include a path). Inside a folder the file leaves out only these can bring
/// anything back, so a walk goes into an ignored folder only when one of them could match something in there.
///
/// A `!` rule that matches at any depth (`!*.pdf`, `!**/Files.noindex/`) brings back what it matches in the folders
/// a walk goes into anyway, as in git. Going into every ignored folder for one of those, and the default ignore file
/// has one, listed hundreds of thousands of files in toolchains, Mail and simulators only to leave them all out.
struct IgnoreNegations: Sendable {
    init(_ content: String?) {
        var rules: [[String]] = []
        for line in content?.split(whereSeparator: \.isNewline) ?? [] {
            guard line.hasPrefix("!") else { continue }
            var pattern = line.dropFirst()
            while let last = pattern.last, last == " " || last == "\t" || last == "/" {
                pattern.removeLast()
            }
            // No slash before the end, or a leading `**/`: it matches at any depth.
            guard pattern.contains("/"), !pattern.hasPrefix("**/") else { continue }
            if pattern.hasPrefix("/") {
                pattern.removeFirst()
            }
            rules.append(pattern.split(separator: "/").map(String.init))
        }
        self.rules = rules
    }

    /// Each rule's path components, relative to where the patterns are anchored.
    let rules: [[String]]

    /// Whether a rule could match something inside `dir`, given the folder the patterns are anchored to.
    func reachBelow(_ dir: String, base: String) -> Bool {
        guard !rules.isEmpty else { return false }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard dir.hasPrefix(prefix) else { return false }
        let parts = dir.dropFirst(prefix.count).split(separator: "/")
        return rules.contains { rule in
            for (i, part) in parts.enumerated() {
                guard i < rule.count else { return false }
                if rule[i] == "**" {
                    return true
                }
                // In either case: going in when unsure only costs a listing.
                guard fnmatch(rule[i], String(part), FNM_CASEFOLD) == 0 else { return false }
            }
            return rule.count > parts.count
        }
    }
}

// MARK: - WalkRules

/// The rules a walk applies below its root, set up once so a walk and a single-path check after it agree.
struct WalkRules: @unchecked Sendable {
    init(
        walkRoot: String, ignoreFile: String?, ignoreRoot: String?, skipDir: ((String) -> Bool)?, applyBlocklist: Bool, discoverGitignore: Bool,
        skipAppleDouble: Bool = false
    ) {
        self.walkRoot = walkRoot
        self.ignoreFile = ignoreFile
        self.ignoreRoot = ignoreRoot
        self.skipDir = skipDir
        self.applyBlocklist = applyBlocklist
        self.discoverGitignore = discoverGitignore
        self.skipAppleDouble = skipAppleDouble

        // Pre-extract extension patterns from ignore file content for fast file-level filtering
        let ignoreContent: String? = ignoreFile.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        ignoredExtensions = ignoreContent.map { SearchEngine.extractExtensionPatterns(from: $0) } ?? []
        negations = IgnoreNegations(ignoreContent)
        // Per-file blocklist checks are only needed when there are `!` exceptions (then we descend into blocked
        // dirs and must filter their files). With no exceptions, directory pruning alone is exact, so skip it.
        blocklistAllows = applyBlocklist && PathBlocklist.shared.hasAllows

        // The gitignore (swift-ignore / Rust `ignore` crate) panics if queried with a path that is not a
        // descendant of the matcher's root. Two modes:
        //  - rooted (ignoreRoot != nil): patterns anchor to `ignoreRoot` (== the walked dir) while the file
        //    lives elsewhere (e.g. a scope ignore for /Applications stored in our cache dir).
        //  - file-rooted (default): patterns anchor to the ignore file's own parent directory.
        let base: String? = ignoreFile.flatMap { ignoreFile in
            if let ignoreRoot {
                return ignoreRoot
            }
            let parent = (ignoreFile as NSString).deletingLastPathComponent
            guard !parent.isEmpty else { return nil }
            let prefix = parent.hasSuffix("/") ? parent : parent + "/"
            return walkRoot == parent || walkRoot.hasPrefix(prefix) ? parent : nil
        }
        ignoreBase = base
        ignoreCheck = {
            guard let ignoreFile, base != nil else { return nil }
            if let ignoreRoot {
                return { $0.isIgnored(in: ignoreFile, root: ignoreRoot, isDir: $1) }
            }
            return { $0.isIgnored(in: ignoreFile, isDir: $1) }
        }()
    }

    /// What a walk does with a folder: whether it goes inside, whether it indexes the folder itself, and which
    /// `.gitignore` files apply to what is inside it.
    struct Folder {
        var descended: Bool
        var added: Bool
        var gitignores: [(file: String, ownerDir: String)]
    }

    let walkRoot: String
    let ignoreFile: String?
    let ignoreRoot: String?
    let skipDir: ((String) -> Bool)?
    let applyBlocklist: Bool
    let discoverGitignore: Bool
    /// Leaves out the `._` files macOS writes beside each file on a drive that can't hold its metadata, as a drive's walk does.
    let skipAppleDouble: Bool
    let ignoredExtensions: Set<String>
    let negations: IgnoreNegations
    let blocklistAllows: Bool
    /// Where the ignore file's patterns are anchored, when it applies to this walk at all.
    let ignoreBase: String?
    /// Whether the ignore file leaves a path out, told whether it is a folder: the walk knows already, and
    /// letting the matcher find out cost a stat per entry.
    let ignoreCheck: ((String, Bool) -> Bool)?

    /// The same rules with no `.gitignore` files read.
    var withoutGitignore: WalkRules {
        WalkRules(
            walkRoot: walkRoot, ignoreFile: ignoreFile, ignoreRoot: ignoreRoot, skipDir: skipDir,
            applyBlocklist: applyBlocklist, discoverGitignore: false, skipAppleDouble: skipAppleDouble
        )
    }

    /// Whether the walk goes inside a folder the ignore file leaves out.
    func entersIgnored(_ dir: String) -> Bool {
        guard let ignoreBase else { return false }
        return negations.reachBelow(dir, base: ignoreBase)
    }

    /// The walk's folder checks, in its order, starting from the verdict for the folder above. The root itself is
    /// never checked or indexed by a walk, only gone into.
    func folder(_ dir: String, cache: inout [String: Folder]) -> Folder {
        if dir.utf8.count <= walkRoot.utf8.count {
            return Folder(descended: dir == walkRoot, added: false, gitignores: [])
        }
        if let known = cache[dir] {
            return known
        }
        let above = folder(dir.parentPath, cache: &cache)
        let verdict = check(dir, above: above)
        cache[dir] = verdict
        return verdict
    }

    private func check(_ dir: String, above: Folder) -> Folder {
        let skipped = Folder(descended: false, added: false, gitignores: above.gitignores)
        guard above.descended else { return skipped }

        if dir.lastPathComponentNative == ".git" {
            return skipped
        }
        if let ignoreCheck, ignoreCheck(dir, true) {
            // A `!` rule naming a path inside (e.g. `*` + `!some/path/`) still needs the walk to go in.
            return Folder(descended: entersIgnored(dir), added: false, gitignores: above.gitignores)
        }
        if applyBlocklist, pathBlockMatch(dir), isPathBlocked(dir) {
            // Blocked, but an allow-exception may live below: the walk goes inside without indexing it.
            return Folder(descended: blocklistDirHasAllowedDescendant(dir), added: false, gitignores: above.gitignores)
        }
        if let skipDir, skipDir(dir) {
            return skipped
        }
        var gitignores = above.gitignores
        if discoverGitignore {
            if gitignores.contains(where: { dir.isIgnored(in: $0.file, root: $0.ownerDir, isDir: true) }) {
                return skipped
            }
            if let file = SearchEngine.gitignoreFile(in: dir) {
                gitignores.append((file, dir))
            }
        }
        // A folder others may open things in by name but not list (`--x`, all over /private/var/db and in
        // /Library/Caches) is indexed by a walk with nothing inside it. FSEvents names what changes in there and
        // lstat finds it, so without this a replay kept adding files that the next walk dropped again.
        return Folder(descended: access(dir, R_OK | X_OK) == 0, added: true, gitignores: gitignores)
    }
}

// MARK: - Path components

extension String {
    /// The folder above, split on bytes: going through NSString hands back a bridged string, and every hash and
    /// compare on one of those (millions of them in a replay of file changes) takes the slow path.
    var parentPath: String {
        guard let slash = utf8.lastIndex(of: UInt8(ascii: "/")) else { return "" }
        return slash == utf8.startIndex ? "/" : String(self[..<slash])
    }

    var lastPathComponentNative: Substring {
        guard let slash = utf8.lastIndex(of: UInt8(ascii: "/")) else { return self[...] }
        return self[index(after: slash)...]
    }
}

// MARK: - CloudDownloads

/// Listing a folder that iCloud Drive, Dropbox or another file provider keeps only in the cloud makes macOS download
/// it first, and a walk would wait on the network for that. With downloads paused on the walking thread such a
/// folder lists as empty right away, while the folder itself is still indexed. Walks never suspend, so pausing
/// covers exactly the walk, and nothing else that later runs on the same thread.
struct CloudDownloads {
    let previous: Int32

    static func pause() -> Self {
        let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        return Self(previous: max(previous, IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT))
    }

    /// A package kept online only: a document that is a folder on disk, like a book, a GarageBand project or a
    /// Pixelmator image. iCloud Drive downloads a package whole as soon as anything lists it, so it counts as a file.
    /// Telling one apart reads the folder's own attributes with downloads paused, never what is inside it.
    static func isOnlinePackage(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_flags & UInt32(SF_DATALESS) != 0, st.st_mode & S_IFMT == S_IFDIR else {
            return false
        }
        let paused = pause()
        defer { paused.resume() }
        return (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
    }

    func resume() {
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous)
    }

}

// MARK: - SearchEngine

final class SearchEngine: @unchecked Sendable {
    /// What an entry needs besides its bytes, in 4 bytes. The path itself is never kept as a `String`: its
    /// lowercased bytes are in `allBytes`, the positions of its uppercase ASCII letters in `caseBits`, and a `String`
    /// is made only for the few entries a search returns.
    struct Entry {
        init(bnStart: Int, segCount: Int, isDir: Bool, nonASCII: Bool) {
            bnStart16 = UInt16(min(bnStart, 65535))
            segCount8 = UInt8(min(segCount, 255))
            flags = (isDir ? Self.dirFlag : 0) | (nonASCII ? Self.nonASCIIFlag : 0)
        }

        static let dirFlag: UInt8 = 1
        /// The path has bytes past ASCII, so it can be spelled in more than one Unicode normalization form.
        static let nonASCIIFlag: UInt8 = 2

        var bnStart16: UInt16
        var segCount8: UInt8
        var flags: UInt8

        @inline(__always) var bnStart: Int {
            Int(bnStart16)
        }
        @inline(__always) var segCount: Int {
            Int(segCount8)
        }
        @inline(__always) var isDir: Bool {
            flags & Self.dirFlag != 0
        }
        @inline(__always) var nonASCII: Bool {
            flags & Self.nonASCIIFlag != 0
        }
    }

    // MARK: - Folder counts

    struct ChildCount: Sendable {
        let path: String
        var isDir: Bool
        /// The child's own entry plus everything below it.
        var count: Int
    }

    static let sectionAlignment = 16384

    /// Whether v4 files are memory-mapped (the default) or read into the heap. Mapped, an index costs the app almost
    /// nothing until searched, and the system takes the pages back under memory pressure and reads them in again when
    /// needed.
    /// `-mapIndexFiles NO` reads them into the heap, for comparing the two.
    nonisolated(unsafe) static var mapIndexFiles = UserDefaults.standard.object(forKey: "mapIndexFiles") as? Bool ?? true

    /// Memory held by the file extension table every engine shares, built from the first index loaded: its three
    /// dictionaries, and the names too long for a String to keep inline (stored once, both dictionaries holding them).
    static var extensionTableBytes: Int {
        extLock.withLock {
            func storage<K, V>(_ dictionary: [K: V]) -> Int {
                // `capacity` is three quarters of the buckets, each holding a key, a value and a bit of the occupancy map.
                let buckets = dictionary.capacity * 4 / 3
                return buckets * (MemoryLayout<K>.stride + MemoryLayout<V>.stride) + buckets / 8
            }
            let names = globalExtToID.keys.reduce(0) { total, ext in
                let n = ext.utf8.count
                return n > 15 ? total + (32 + n + 1 + 15) / 16 * 16 : total
            }
            return storage(globalExtToID) + storage(globalExtHashToID) + storage(globalIdToExt) + names
        }
    }

    /// Never waits on `lock`: the main thread reads it, and a live update that builds the path table first holds the
    /// lock for as long as that takes.
    var count: Int {
        publishedCount.withLock { $0 }
    }

    /// Whether anything was added or removed since the last save (or load).
    var hasUnsavedChanges: Bool {
        lock.withLock { changes != savedChanges }
    }

    /// Whether the index is read from a mapped file rather than held in the heap.
    var isMapped: Bool {
        lock.withLock { masks.storage.isMapped }
    }

    /// What the index adds to the app's memory: the pages of its columns it has written to, and the tables kept on the
    /// heap. The clean pages mapped from its file are left to the system's file cache.
    var footprintBytes: Int {
        lock.withLock {
            let columns = entries.footprintBytes + bnBoundaries.footprintBytes + masks.footprintBytes + bnMasks.footprintBytes
                + allBytes.footprintBytes + caseBits.footprintBytes + byteOffsets.footprintBytes + byteLengths.footprintBytes
                + extIDs.footprintBytes
            let tables = pathTable.memoryBytes + (free.capacity + (sortedByPath?.capacity ?? 0)) * MemoryLayout<Int>.stride
            return columns + tables
        }
    }

    // MARK: - FTS Filesystem Walker

    /// Build a set of file extension patterns from an ignore file (patterns like "*.pyc", "*.o")
    static func extractExtensionPatterns(from ignoreContent: String) -> Set<String> {
        var exts = Set<String>()
        for line in ignoreContent.components(separatedBy: .newlines) {
            let p = line.trimmingCharacters(in: .whitespaces)
            if p.hasPrefix("*."), !p.contains("/"), p.dropFirst(2).allSatisfy({ $0 != "*" }) {
                exts.insert(String(p.dropFirst(1))) // keep the dot: ".pyc"
            }
        }
        return exts
    }

    /// Path of a directory's own `.gitignore` (or `.ignore`) if present, for per-directory ignore discovery.
    /// Whether a walk of `rules.walkRoot` would add `path`, for a single change reported after the walk. Every folder
    /// between the root and the path gets the checks the walk gives a folder before descending into it, then the path
    /// gets the ones for what it is, in the walk's order. Keep in step with `walkDirectory`.
    ///
    /// `folders` caches each folder's verdict and the `.gitignore` files in force below it, across a batch of paths.
    static func walkAdmits(_ path: String, isDir: Bool, rules: WalkRules, folders: inout [String: WalkRules.Folder]) -> Bool {
        let root = rules.walkRoot
        guard path.utf8.count > root.utf8.count, path.hasPrefix(root), path.utf8[path.utf8.index(path.utf8.startIndex, offsetBy: root.utf8.count)] == UInt8(ascii: "/") || root == "/" else {
            return false
        }
        let above = rules.folder(path.parentPath, cache: &folders)
        guard above.descended else { return false }

        if isDir {
            return rules.folder(path, cache: &folders).added
        }

        let name = path.lastPathComponentNative
        if name == ".DS_Store" || name == ".localized" || name == "Icon\r" {
            return false
        }
        if rules.skipAppleDouble, name.hasPrefix("._"), name.utf8.count > 2 {
            return false
        }
        if !rules.ignoredExtensions.isEmpty, let dot = name.lastIndex(of: "."), name.distance(from: dot, to: name.endIndex) <= 20,
           rules.ignoredExtensions.contains(String(name[dot...]))
        {
            return false
        }
        if let ignoreCheck = rules.ignoreCheck, ignoreCheck(path, false) {
            return false
        }
        if rules.blocklistAllows, isPathBlocked(path) {
            return false
        }
        if rules.discoverGitignore, above.gitignores.contains(where: { path.isIgnored(in: $0.file, root: $0.ownerDir, isDir: false) }) {
            return false
        }
        return true
    }

    static func gitignoreFile(in dir: String) -> String? {
        for name in [".gitignore", ".ignore"] {
            let p = dir + "/" + name
            if access(p, F_OK) == 0 {
                return p
            }
        }
        return nil
    }

    /// Room left after `count` loaded entries (or bytes), so the first live change after a load appends in place
    /// instead of reallocating and copying every array: about 80 ms of holding the lock on a 700K-entry scope.
    static func headroom(_ count: Int, minimum: Int = 1024) -> Int {
        max(minimum, count / 64)
    }

    /// Where a folder named in `in:` really is when a symlink leads to it, and the folder as the disk spells it, since
    /// the query arrives lowercased. Nil when no symlink is involved.
    static func symlinkedFolder(_ path: String) -> (real: String, shown: String)? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buf) != nil else { return nil }
        let real = String(cString: buf)
        // realpath also corrects the case of every component, which takes no link.
        guard real.lowercased() != path.lowercased() else { return nil }
        // The canonical path keeps the last component when it is the link, and resolves a link above it.
        let canonical = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath
        let shown = canonical.flatMap { $0.lowercased() == real.lowercased() ? nil : $0 } ?? path
        return (real, shown)
    }

    /// Folders right in Home that are symlinks to a deeper folder, like `~/.ssh` kept in a dotfiles folder. Walks
    /// don't follow links, so their files are indexed where the links point, and results show them under the link,
    /// the path people know. A link to a folder no deeper than itself (`~/.go` to `~/go`) is left alone. Read again
    /// at most once a minute.
    static func homeFolderLinks() -> [(real: String, shown: String)] {
        homeLinksLock.lock()
        defer { homeLinksLock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        if now - homeLinksCache.at < 60 {
            return homeLinksCache.links
        }
        let home = NSHomeDirectory()
        var links: [(real: String, shown: String)] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? [] {
            let path = home + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK else { continue }
            var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard realpath(path, &buf) != nil else { continue }
            let real = String(cString: buf)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: real, isDirectory: &isDir), isDir.boolValue,
                  real.split(separator: "/").count > path.split(separator: "/").count
            else { continue }
            links.append((real, path))
        }
        homeLinksCache = (now, links)
        return links
    }

    /// Every indexed path, in the case it has on disk.
    func allPaths() -> [String] {
        lock.withLock {
            var paths: [String] = []
            paths.reserveCapacity(liveCount)
            for i in 0 ..< entries.count where byteLengths[i] > 0 {
                paths.append(path(i))
            }
            return paths
        }
    }

    /// Appends every entry `other` holds, without a duplicate check. A folder walked into an engine of its own then
    /// replaces its old entries in one step, rather than going missing from results while it is walked again.
    func appendEntries(of other: SearchEngine) {
        let added = other.lock.withLock {
            (0 ..< other.entries.count).filter { other.byteLengths[$0] > 0 }.map { (other.path($0), other.entries[$0].isDir) }
        }
        lock.withLock {
            for (path, isDir) in added {
                _appendPath(path, isDir: isDir)
            }
        }
    }

    // MARK: - Capacity

    func reserveCapacity(_ n: Int, avgPathLen: Int = 50) {
        lock.withLock {
            entries.reserveCapacity(n)
            masks.reserveCapacity(n)
            bnMasks.reserveCapacity(n)
            bnBoundaries.reserveCapacity(n)
            byteOffsets.reserveCapacity(n)
            byteLengths.reserveCapacity(n)
            extIDs.reserveCapacity(n)
            allBytes.reserveCapacity(n * avgPathLen)
            caseBits.reserveCapacity(n * avgPathLen / 64 + 1)
        }
    }

    // MARK: - Add / Remove

    /// Thread-safe add for use during parallel walks and FSEvents.
    @discardableResult
    func addPath(_ path: String, isDir: Bool) -> Int {
        lock.withLock { _addPath(path, isDir: isDir) }
    }

    /// Adds a path the index doesn't hold yet, saying whether it did.
    func addPathIfMissing(_ path: String, isDir: Bool) -> Bool {
        lock.withLock {
            guard lookup(path) == nil else { return false }
            indexInsert(_insertPath(path, isDir: isDir))
            return true
        }
    }

    /// Add without looking for an existing entry, for an engine that never builds the path index (at millions
    /// of entries the Everything index can't afford one). A path added twice turns up twice in this engine's
    /// results, and merging results collapses them by path.
    func appendPath(_ path: String, isDir: Bool) {
        lock.withLock { _appendPath(path, isDir: isDir) }
    }

    /// Thread-safe remove.
    @discardableResult
    func removePath(_ path: String) -> Bool {
        lock.withLock { _removePath(path) }
    }

    func hasPath(_ path: String) -> Bool {
        lock.withLock { lookup(path) != nil }
    }

    /// What sits directly in `dir`, each with the number of entries it accounts for. Matches on the lowercased
    /// bytes, like the folder filter. A walk adds a folder's contents in one run, so consecutive entries mostly
    /// share a child and the dictionary is only consulted when the child changes.
    func childCounts(of dir: String) -> [ChildCount] {
        let prefix = Self.lowercasedDirPrefix(dir)
        let pLen = prefix.count
        var counts: [ChildCount] = []
        var indexByName: [[UInt8]: Int] = [:]
        var lastIdx = -1, lastOff = 0, lastLen = 0

        lock.lock()
        defer { lock.unlock() }
        allBytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for i in 0 ..< entries.count {
                let len = byteLengths[i]
                guard len > pLen else { continue }
                let off = byteOffsets[i]
                guard memcmp(base + off, prefix, pLen) == 0 else { continue }

                let stop = off + len
                var end = off + pLen
                while end < stop, base[end] != 0x2F {
                    end &+= 1
                }
                let childLen = end - off
                guard childLen > pLen else { continue }
                let isDir = end < stop || entries[i].isDir

                if lastIdx >= 0, childLen == lastLen, memcmp(base + off, base + lastOff, childLen) == 0 {
                    counts[lastIdx].count &+= 1
                    counts[lastIdx].isDir = counts[lastIdx].isDir || isDir
                    continue
                }
                let name = Array(UnsafeBufferPointer(start: base + off + pLen, count: childLen - pLen))
                if let idx = indexByName[name] {
                    counts[idx].count &+= 1
                    counts[idx].isDir = counts[idx].isDir || isDir
                    lastIdx = idx
                } else {
                    // Lowercasing is byte for byte, so the same range of the stored path keeps its case.
                    let path = path(i, prefix: childLen)
                    indexByName[name] = counts.count
                    lastIdx = counts.count
                    counts.append(ChildCount(path: path, isDir: isDir, count: 1))
                }
                lastOff = off
                lastLen = childLen
            }
        }
        return counts
    }

    /// Number of entries below `dir`.
    func countBelow(_ dir: String) -> Int {
        let prefix = Self.lowercasedDirPrefix(dir)
        let pLen = prefix.count
        var n = 0
        lock.lock()
        defer { lock.unlock() }
        allBytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for i in 0 ..< entries.count where byteLengths[i] > pLen && memcmp(base + byteOffsets[i], prefix, pLen) == 0 {
                n &+= 1
            }
        }
        return n
    }

    /// The entries at or below each of `dirs`, the folder's own one included, in a single pass however many there are.
    /// A folder inside another of the list is counted as part of the outer one only.
    func countsBelow(_ dirs: [String]) -> [Int] {
        let own = dirs.map(Self.lowercasedDirPrefix)
        let prefixes = Set(own).sorted { $0.lexicographicallyPrecedes($1) }
            .reduce(into: [[UInt8]]()) { kept, p in
                if let last = kept.last, p.starts(with: last) {
                    return
                }
                kept.append(p)
            }
        guard !prefixes.isEmpty else { return own.map { _ in 0 } }

        var counts = [Int](repeating: 0, count: prefixes.count)
        lock.lock()
        allBytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for i in 0 ..< entries.count where byteLengths[i] > 0 {
                if let p = Self.prefixIndex(base + byteOffsets[i], byteLengths[i], prefixes) {
                    counts[p] &+= 1
                }
            }
        }
        lock.unlock()
        let byPrefix = Dictionary(zip(prefixes, counts), uniquingKeysWith: { a, _ in a })
        return own.map { byPrefix[$0] ?? 0 }
    }

    /// Remove `dir` and everything below it, returning how many entries went.
    @discardableResult
    func removeSubtree(_ dir: String) -> Int {
        removeSubtrees([dir])
    }

    /// Removes these paths and, for the folders among them, everything below them. Each one is looked up in the path
    /// index, so a path that isn't indexed costs a lookup and a file costs nothing more; only a folder that is
    /// indexed costs a pass over the entries. `found` is told each of the paths that was indexed.
    @discardableResult
    func removeIndexed(_ paths: [String], found: (String) -> Void = { _ in }) -> Int {
        guard !paths.isEmpty else { return 0 }
        var dirs: [String] = []
        var removed = 0
        lock.withLock {
            for path in paths {
                guard let id = lookup(path) else { continue }
                found(path)
                if entries[id].isDir {
                    dirs.append(path)
                } else {
                    _removeID(id)
                    removed += 1
                }
            }
            if removed > 0 {
                sortedByPath = nil
            }
        }
        if !dirs.isEmpty {
            removed += removeSubtrees(dirs)
        }
        return removed
    }

    /// Remove each of `dirs` and everything below them in a single pass, however many there are, returning how
    /// many entries went. Matches on the lowercased bytes, like the folder filter.
    @discardableResult
    func removeSubtrees(_ dirs: [String]) -> Int {
        // Sorted, and without any prefix that sits inside another one (it is covered already). That makes the
        // set prefix-free, so a path can only fall under the last prefix that sorts at or before it.
        let prefixes = dirs.map(Self.lowercasedDirPrefix)
            .sorted { $0.lexicographicallyPrecedes($1) }
            .reduce(into: [[UInt8]]()) { kept, p in
                if let last = kept.last, p.starts(with: last) {
                    return
                }
                kept.append(p)
            }
        guard !prefixes.isEmpty else { return 0 }

        var ids: [Int] = []
        lock.lock()
        defer { lock.unlock() }
        allBytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for i in 0 ..< entries.count where byteLengths[i] > 0 {
                if Self.isInside(base + byteOffsets[i], byteLengths[i], prefixes) {
                    ids.append(i)
                }
            }
        }
        for id in ids {
            _removeID(id)
        }
        if !ids.isEmpty {
            // Emptied slots sort first, which would break the binary search over the old order.
            sortedByPath = nil
        }
        return ids.count
    }

    /// Remove the `._` files macOS writes beside each file on a drive that can't hold the file's metadata (exFAT, FAT,
    /// some network shares), returning how many went. One pass over the entries.
    @discardableResult
    func removeAppleDoubleFiles() -> Int {
        var ids: [Int] = []
        lock.lock()
        defer { lock.unlock() }
        allBytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for i in 0 ..< entries.count where byteLengths[i] > 2 && !entries[i].isDir {
                let path = base + byteOffsets[i]
                var slash = byteLengths[i] - 1
                while slash >= 0, path[slash] != 0x2F {
                    slash -= 1
                }
                if slash + 3 < byteLengths[i], path[slash + 1] == 0x2E, path[slash + 2] == 0x5F {
                    ids.append(i)
                }
            }
        }
        for id in ids {
            _removeID(id)
        }
        if !ids.isEmpty {
            sortedByPath = nil
        }
        return ids.count
    }

    func clear() {
        lock.withLock {
            entries.removeAll()
            masks.removeAll()
            bnMasks.removeAll()
            bnBoundaries.removeAll()
            allBytes.removeAll()
            caseBits.removeAll()
            byteOffsets.removeAll()
            byteLengths.removeAll()
            extIDs.removeAll()
            // The extension IDs are shared by every engine, so they stay registered.
            free.removeAll()
            liveCount = 0
            mappedCount = 0
            pathTable.removeAll()
            pathIndexBuilt = false
            sortedByPath = nil
        }
    }

    /// Writes the index as v4 to a temporary file and renames it into place, so a crash or a full disk mid-write leaves
    /// the previous file whole. Everything streams through a small buffer instead of a copy the size of the file, and
    /// the bytes removed paths left in `allBytes` are dropped.
    ///
    /// Removed entries stay as zeroed slots so ids don't move, unless `compacting`, which renumbers the entries and is
    /// only for an engine nobody holds ids from yet (one being loaded). With mapping on, the engine then maps the file
    /// it just wrote, which turns everything changed since the last save back into clean file pages.
    @discardableResult
    func saveBinaryIndex(to url: URL, compacting: Bool = false) -> Bool {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let out = AtomicFileWriter(destination: url.path) else {
            slog.error("saveBinaryIndex: can't create \(url.path).saving")
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        let savingChanges = changes
        let n = entries.count
        var live = 0, liveBytes = 0
        var maxExt: UInt16 = 0
        var i = 0
        while i < n {
            if byteLengths[i] > 0 {
                live &+= 1
                liveBytes &+= byteLengths[i]
                maxExt = max(maxExt, extIDs[i])
            }
            i &+= 1
        }
        let keep = !compacting
        let count = keep ? n : live
        let caseWords = (liveBytes + 63) / 64
        let extNames: [String] = Self.extLock.withLock {
            (0 ..< Int(maxExt)).map { Self.globalIdToExt[UInt16($0 + 1)] ?? "" }
        }
        var nameBytes: [UInt8] = []
        for name in extNames {
            nameBytes.append(contentsOf: name.utf8)
            nameBytes.append(0)
        }

        let lengths: [Int] = [count * 8, count * 8, count * 8, count * 4, count * 2, count * 4, count * 2, liveBytes, caseWords * 8, nameBytes.count]
        var sectionOffsets: [Int] = []
        var pos = Self.sectionAlignment
        for length in lengths {
            sectionOffsets.append(pos)
            pos += (length + Self.sectionAlignment - 1) / Self.sectionAlignment * Self.sectionAlignment
        }

        out.write(Self.binaryMagicV4)
        out.write(Self.binaryVersionV4)
        out.write(UInt32(Section.allCases.count))
        out.write(UInt64(count))
        out.write(UInt64(liveBytes))
        out.write(UInt64(caseWords))
        out.write(UInt64(maxExt))
        out.write(UInt64(0))
        out.write(UInt64(0))
        for (off, length) in zip(sectionOffsets, lengths) {
            out.write(UInt64(off))
            out.write(UInt64(length))
        }

        func section(_ s: Section) {
            out.align(to: Self.sectionAlignment)
            assert(out.position == sectionOffsets[s.rawValue], "section \(s) at \(out.position), expected \(sectionOffsets[s.rawValue])")
        }
        /// Runs of live slots go out in one write each (with nothing removed, the whole column at once); removed slots
        /// are written as zeros when kept.
        func writeColumn(_ base: UnsafeRawPointer, stride: Int) {
            var i = 0
            while i < n {
                let isLive = byteLengths[i] > 0
                var j = i &+ 1
                while j < n, (byteLengths[j] > 0) == isLive {
                    j &+= 1
                }
                if isLive {
                    out.write(base + i * stride, count: (j - i) * stride)
                } else if keep {
                    out.write(zeros: (j - i) * stride)
                }
                i = j
            }
        }

        section(.masks)
        writeColumn(masks.storage.base, stride: 8)
        section(.bnMasks)
        writeColumn(bnMasks.storage.base, stride: 8)
        section(.bnBoundaries)
        writeColumn(bnBoundaries.storage.base, stride: 8)

        // Where each live entry's bytes start once the gaps are closed, and the runs of bytes that move together.
        let newOffsets = ScratchBuffer<UInt32>(zeroed: count)
        defer { newOffsets.release() }
        var runs: [(from: Int, to: Int, length: Int)] = []
        var next = 0, k = 0
        i = 0
        while i < n {
            let len = byteLengths[i]
            if len > 0 {
                let off = byteOffsets[i]
                newOffsets.base[keep ? i : k] = UInt32(next)
                if let last = runs.last, last.from + last.length == off, last.to + last.length == next {
                    runs[runs.count - 1].length += len
                } else {
                    runs.append((off, next, len))
                }
                next += len
                k &+= 1
            }
            i &+= 1
        }
        section(.byteOffsets)
        out.write(newOffsets.base, count: count * 4)
        section(.byteLengths)
        writeColumn(byteLengths.storage.base, stride: 2)
        section(.entries)
        writeColumn(entries.storage.base, stride: 4)
        section(.extIDs)
        writeColumn(extIDs.storage.base, stride: 2)
        section(.allBytes)
        for run in runs {
            out.write(allBytes.storage.base + run.from, count: run.length)
        }
        section(.caseBits)
        let newBits = ScratchBuffer<UInt64>(zeroed: caseWords)
        defer { newBits.release() }
        for run in runs {
            copyBits(from: caseBits.storage.base, at: run.from, to: newBits.base, at: run.to, count: run.length)
        }
        out.write(newBits.base, count: caseWords * 8)
        section(.extNames)
        nameBytes.withUnsafeBytes { out.write($0.baseAddress!, count: $0.count) }
        out.align(to: Self.sectionAlignment)

        let size = out.position
        guard out.commit() else {
            slog.error("saveBinaryIndex: writing \(url.path) failed")
            return false
        }
        savedChanges = savingChanges
        let writeMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        var remapped = false
        if Self.mapIndexFiles, let columns = readV4(url, trusted: true) {
            install(columns, keepingIDs: keep)
            remapped = true
        }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        slog.info("saveBinaryIndex: \(live) of \(n) entries, \(size / 1_048_576)MB written in \(writeMs, format: .fixed(precision: 1))ms\(remapped ? ", mapped" : "") in \(ms, format: .fixed(precision: 1))ms")
        return true
    }

    func loadBinaryIndex(from url: URL, progress: ((Int) -> Void)? = nil) -> Bool {
        let t0 = CFAbsoluteTimeGetCurrent()
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            slog.error("loadBinaryIndex: failed to open \(url.path)")
            return false
        }
        var magic: UInt64 = 0
        let got = pread(fd, &magic, 8, 0)
        close(fd)
        guard got == 8 else {
            slog.error("loadBinaryIndex: \(url.path) is too short")
            return false
        }
        let columns: LoadedColumns?
        switch magic {
        case Self.binaryMagicV4: columns = readV4(url, trusted: false, progress: progress)
        case Self.binaryMagic: columns = readV3(url, progress: progress)
        default:
            slog.error("loadBinaryIndex: bad magic in \(url.path)")
            return false
        }
        guard let columns else { return false }
        let n = columns.entries.count
        lock.withLock { install(columns, keepingIDs: false) }

        if Self.mapIndexFiles {
            if magic == Self.binaryMagic {
                // A v3 file from before this version: written as v4 and mapped from then on.
                saveBinaryIndex(to: url, compacting: true)
            } else if n - columns.live > max(1024, n / 20) {
                // Removed entries are kept as holes while Cling runs; a load with many of them is when they go.
                saveBinaryIndex(to: url, compacting: true)
            }
        }
        progress?(n)
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        let mapped = isMapped
        slog.info("loadBinaryIndex: \(columns.live) entries from \(url.lastPathComponent)\(mapped ? ", mapped" : "") in \(ms, format: .fixed(precision: 1))ms")
        return true
    }

    /// Build pathToID from entries (call after bulk load to enable add/remove)
    func buildPathIndex() {
        let t0 = CFAbsoluteTimeGetCurrent()
        pathTable.reset(capacityFor: liveCount)
        for i in 0 ..< entries.count where byteLengths[i] > 0 {
            pathTable.insert(id: i, hash: entryHash(i), rehash: entryHash)
        }
        pathIndexBuilt = true
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        let count = pathTable.live
        let kb = pathTable.memoryBytes / 1024
        slog.debug("buildPathIndex: \(count) entries, \(kb)KB in \(ms, format: .fixed(precision: 1))ms")
    }

    /// Build sorted path index for O(log n) prefix lookups. Call after index loading.
    /// Holds lock for the sort (runs on background thread, never blocks main thread).
    func buildSortedPathIndex() {
        let t0 = CFAbsoluteTimeGetCurrent()

        lock.lock()
        let n = entries.count
        guard n > 0 else { sortedByPath = nil; lock.unlock(); return }

        var sorted = [Int](unsafeUninitializedCapacity: n) {
            buf, count in
            var i = 0
            while i < n {
                buf[i] = i; i &+= 1
            }
            count = n
        }

        allBytes.withUnsafeBufferPointer { buf in
            let base = buf.baseAddress!
            sorted.sort { a, b in
                let aOff = byteOffsets[a], aLen = byteLengths[a]
                let bOff = byteOffsets[b], bLen = byteLengths[b]
                let cmp = memcmp(base + aOff, base + bOff, min(aLen, bLen))
                if cmp != 0 {
                    return cmp < 0
                }
                return aLen < bLen
            }
        }

        sortedByPath = sorted
        lock.unlock()

        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        slog.debug("buildSortedPathIndex: \(n) entries in \(ms, format: .fixed(precision: 1))ms")
    }

    @discardableResult
    func walkDirectory(
        _ dir: String,
        ignoreFile: String? = nil,
        ignoreRoot: String? = nil,
        skipDir: ((String) -> Bool)? = nil,
        applyBlocklist: Bool = false,
        discoverGitignore: Bool = false,
        inheritedGitignores: [(file: String, ownerDir: String)] = [],
        skipGitDirs: Bool = true,
        skipJunkFiles: Bool = true,
        skipAppleDouble: Bool = false,
        dedupe: Bool = true,
        listOnlineFolders: Bool = false,
        progress: ((Int, String) -> Void)? = nil,
        cancelled: (() -> Bool)? = nil
    ) -> Int {
        let t0 = CFAbsoluteTimeGetCurrent()

        // `listOnlineFolders` lets the walk wait for a cloud service to list the folders it keeps online only. That
        // fetches their names and nothing else: the walk opens folders, never files or packages.
        let downloads = listOnlineFolders ? nil : CloudDownloads.pause()
        defer { downloads?.resume() }

        let cDir = strdup(dir)!
        defer { Darwin.free(cDir) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cDir, nil]

        let opts = Int32(FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV | FTS_NOSTAT)
        guard let ftsp = fts_open(&paths, opts, nil) else {
            slog.error("walkDirectory: fts_open failed for \(dir)")
            return 0
        }
        defer { fts_close(ftsp) }

        let rules = WalkRules(
            walkRoot: dir, ignoreFile: ignoreFile, ignoreRoot: ignoreRoot, skipDir: skipDir,
            applyBlocklist: applyBlocklist, discoverGitignore: discoverGitignore
        )
        let ignoredExtensions = rules.ignoredExtensions
        let blocklistAllows = rules.blocklistAllows
        let ignoreCheck = rules.ignoreCheck

        // Per-directory .gitignore/.ignore matchers, discovered as we descend (deepest last). A path is
        // ignored if any active matcher reports it ignored (checked deepest-first, short-circuit). We pop by
        // ancestor-prefix at point of use rather than on FTS_DP, because FTS_SKIP'd dirs emit no FTS_DP.
        var gitignoreStack: [(file: String, ownerDir: String)] = inheritedGitignores
        func gitignored(_ path: String, isDir: Bool) -> Bool {
            while let top = gitignoreStack.last, path != top.ownerDir, !path.hasPrefix(top.ownerDir + "/") {
                gitignoreStack.removeLast()
            }
            for entry in gitignoreStack.reversed() where path.isIgnored(in: entry.file, root: entry.ownerDir, isDir: isDir) {
                return true
            }
            return false
        }

        var added = 0
        var skippedIgnore = 0
        var lastProgress = t0

        // Batch entries to reduce lock contention during parallel walks
        let batchSize = 2048
        var batch: [(String, Bool)] = []
        batch.reserveCapacity(batchSize)

        func flushBatch() {
            guard !batch.isEmpty else { return }
            lock.lock()
            for (p, d) in batch {
                if dedupe {
                    _ = _addPath(p, isDir: d)
                } else {
                    _appendPath(p, isDir: d)
                }
            }
            lock.unlock()
            batch.removeAll(keepingCapacity: true)
        }

        while let ent = fts_read(ftsp) {
            if cancelled?() == true {
                break
            }

            let info = ent.pointee.fts_info
            if ent.pointee.fts_level == 0 {
                continue
            }

            let pathLen = Int(ent.pointee.fts_pathlen)
            let pathPtr = UnsafeRawPointer(ent.pointee.fts_path!).assumingMemoryBound(to: UInt8.self)

            switch Int32(info) {
            case FTS_D:
                // Skip .git
                if skipGitDirs, ent.pointee.fts_namelen == 4 {
                    let n = ent.pointee.fts_path!.advanced(by: pathLen &- 4)
                    if n[0] == 0x2E, n[1] == 0x67, n[2] == 0x69, n[3] == 0x74 {
                        fts_set(ftsp, ent, Int32(FTS_SKIP))
                        continue
                    }
                }

                let fullPath = String(decoding: UnsafeBufferPointer(start: pathPtr, count: pathLen), as: UTF8.self)

                if let ignoreCheck, ignoreCheck(fullPath, true) {
                    // A `!` rule naming a path inside (e.g. `*` + `!some/path/`) still needs the walk to go in.
                    if !rules.entersIgnored(fullPath) {
                        fts_set(ftsp, ent, Int32(FTS_SKIP))
                    }
                    skippedIgnore &+= 1
                    continue
                }
                if applyBlocklist, pathBlockMatch(fullPath) {
                    if !isPathBlocked(fullPath) {
                        // An allow exception wins at this level (e.g. `!.app/Contents/MacOS/`): index and descend.
                    } else if blocklistDirHasAllowedDescendant(fullPath) {
                        // Blocked, but an allow-exception lives below: descend without indexing this dir.
                        skippedIgnore &+= 1
                        continue
                    } else {
                        fts_set(ftsp, ent, Int32(FTS_SKIP))
                        skippedIgnore &+= 1
                        continue
                    }
                }
                if let skipDir, skipDir(fullPath) {
                    fts_set(ftsp, ent, Int32(FTS_SKIP))
                    continue
                }
                if discoverGitignore {
                    // Test against ancestors' .gitignore files before pushing this dir's own.
                    if gitignored(fullPath, isDir: true) {
                        fts_set(ftsp, ent, Int32(FTS_SKIP))
                        skippedIgnore &+= 1
                        continue
                    }
                    if let gf = Self.gitignoreFile(in: fullPath) {
                        gitignoreStack.append((gf, fullPath))
                    }
                }

                // Listing an online-only package would download all of it; it goes in as one entry, unopened.
                if listOnlineFolders, CloudDownloads.isOnlinePackage(fullPath) {
                    fts_set(ftsp, ent, Int32(FTS_SKIP))
                }
                batch.append((fullPath, true))
                added &+= 1

            case FTS_F, FTS_SL, FTS_SLNONE, FTS_NSOK:
                // Skip .DS_Store, .localized, Icon\r
                let nameLen = Int(ent.pointee.fts_namelen)
                let n = ent.pointee.fts_path!.advanced(by: pathLen &- nameLen)
                if skipJunkFiles, nameLen == 9, n[0] == 0x2E, n[1] == 0x44, n[2] == 0x53,
                   n[3] == 0x5F, n[4] == 0x53
                {
                    continue
                } // .DS_Store
                if skipJunkFiles, nameLen == 10, n[0] == 0x2E, n[1] == 0x6C, n[2] == 0x6F,
                   n[3] == 0x63
                {
                    continue
                } // .localized
                if skipJunkFiles, nameLen == 5, n[0] == 0x49, n[1] == 0x63, n[2] == 0x6F,
                   n[3] == 0x6E, n[4] == 0x0D
                {
                    continue
                } // Icon\r
                if skipAppleDouble, nameLen > 2, n[0] == 0x2E, n[1] == 0x5F {
                    continue
                } // ._name

                if !ignoredExtensions.isEmpty {
                    var extStart = -1
                    for k in stride(from: pathLen - 1, through: max(pathLen - 20, 0), by: -1) {
                        let b = pathPtr[k]
                        if b == 0x2F {
                            break
                        }
                        if b == 0x2E {
                            extStart = k; break
                        }
                    }
                    if extStart >= 0 {
                        let ext = String(decoding: UnsafeBufferPointer(start: pathPtr + extStart, count: pathLen - extStart), as: UTF8.self)
                        if ignoredExtensions.contains(ext) {
                            skippedIgnore &+= 1
                            continue
                        }
                    }
                }

                let fullPath = String(decoding: UnsafeBufferPointer(start: pathPtr, count: pathLen), as: UTF8.self)
                if let ignoreCheck, ignoreCheck(fullPath, false) {
                    skippedIgnore &+= 1
                    continue
                }
                // When blocklist exceptions exist, files are checked individually: we descend into blocked
                // directories to reach allowed paths, so each file must be re-tested so only allowed ones get in.
                if blocklistAllows, isPathBlocked(fullPath) {
                    skippedIgnore &+= 1
                    continue
                }
                if discoverGitignore, gitignored(fullPath, isDir: false) {
                    skippedIgnore &+= 1
                    continue
                }
                batch.append((fullPath, false))
                added &+= 1

            case FTS_DP: continue

            default: continue
            }

            if batch.count >= batchSize {
                flushBatch()
            }

            // Progress reporting (every 500ms)
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastProgress > 0.5 {
                lastProgress = now
                progress?(added, batch.last?.0 ?? dir)
                // A walk that waits on the network gets each folder's files into search as it lists them.
                if listOnlineFolders {
                    flushBatch()
                }
            }
        }

        flushBatch()
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        slog.info("walkDirectory: \(dir) added=\(added) skippedIgnore=\(skippedIgnore) in \(ms, format: .fixed(precision: 1))ms")
        return added
    }

    /// Walk using FileManager for network/external volumes (batches directory reads, better for high-latency storage)
    /// Supports checkpointing: saves completed top-level directories to a file so indexing can resume after a crash.
    @discardableResult
    func walkDirectoryURL(
        _ dir: String,
        ignoreFile: String? = nil,
        skipDir: ((String) -> Bool)? = nil,
        checkpointFile: URL? = nil,
        progress: ((Int, String) -> Void)? = nil,
        cancelled: (() -> Bool)? = nil
    ) -> Int {
        let t0 = CFAbsoluteTimeGetCurrent()
        let downloads = CloudDownloads.pause()
        defer { downloads.resume() }
        let fm = FileManager.default
        let baseURL = URL(fileURLWithPath: dir)
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        let basePath = baseURL.path
        let checkpointDepth = 3

        let ignoreContent: String? = ignoreFile.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        let ignoredExtensions: Set<String> = ignoreContent.map { Self.extractExtensionPatterns(from: $0) } ?? []
        let negations = IgnoreNegations(ignoreContent)

        // Only apply ignore checks when the walked dir is under the ignore file's parent (see walkDirectory).
        let ignoreRootPrefix: String? = ignoreFile.flatMap { f -> String? in
            let parent = (f as NSString).deletingLastPathComponent
            guard !parent.isEmpty else { return nil }
            let prefix = parent.hasSuffix("/") ? parent : parent + "/"
            return (dir == parent || dir.hasPrefix(prefix)) ? prefix : nil
        }
        let effectiveIgnoreFile: String? = ignoreRootPrefix != nil ? ignoreFile : nil

        // Load completed checkpoints from previous interrupted run
        var completedDirs = Set<String>()
        if let cpFile = checkpointFile, let cpData = try? String(contentsOf: cpFile, encoding: .utf8) {
            for line in cpData.components(separatedBy: "\n") where !line.isEmpty {
                completedDirs.insert(line)
            }
            if !completedDirs.isEmpty {
                slog.info("walkDirectoryURL: resuming with \(completedDirs.count) completed checkpoints")
            }
        }

        var added = 0
        var lastProgress = t0

        let batchSize = 2048
        var batch: [(String, Bool)] = []
        batch.reserveCapacity(batchSize)

        func flushBatch() {
            guard !batch.isEmpty else { return }
            lock.lock()
            for (p, d) in batch {
                _ = _addPath(p, isDir: d)
            }
            lock.unlock()
            batch.removeAll(keepingCapacity: true)
        }

        func saveCheckpoint(_ dirPath: String) {
            guard let cpFile = checkpointFile else { return }
            completedDirs.insert(dirPath)
            try? (completedDirs.joined(separator: "\n") + "\n").write(to: cpFile, atomically: true, encoding: .utf8)
        }

        func depthRelativeToBase(_ path: String) -> Int {
            let rel = path.dropFirst(basePath.count)
            return rel.components(separatedBy: "/").filter { !$0.isEmpty }.count
        }

        // BFS using a queue of directories to visit
        var queue = [baseURL]
        var qi = 0

        while qi < queue.count {
            if cancelled?() == true {
                break
            }

            let dirURL = queue[qi]
            qi += 1
            let dirPath = dirURL.path

            // Skip already-completed checkpoint dirs
            if completedDirs.contains(dirPath) {
                continue
            }

            guard let contents = try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
                continue
            }

            for url in contents {
                if cancelled?() == true {
                    break
                }

                let path = url.path
                let name = url.lastPathComponent

                // Only drives are walked this way, and the `._` files are the metadata macOS writes beside each file on
                // one that can't hold it, as the SMB walk skips them too.
                if name == ".DS_Store" || name == ".localized" || name.hasPrefix("._") {
                    continue
                }
                if name.hasSuffix("\r"), name.hasPrefix("Icon") {
                    continue
                }

                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

                if isDir {
                    if name == ".git" {
                        continue
                    }
                    if let effectiveIgnoreFile, path.isIgnored(in: effectiveIgnoreFile, isDir: true) {
                        // A `!` rule naming a path inside still needs the walk to go in.
                        if negations.reachBelow(path, base: (effectiveIgnoreFile as NSString).deletingLastPathComponent) {
                            queue.append(url)
                        }
                        continue
                    }
                    if let skipDir, skipDir(path) {
                        continue
                    }
                    queue.append(url)
                } else {
                    if !ignoredExtensions.isEmpty {
                        let ext = "." + (url.pathExtension.lowercased())
                        if ext.count > 1, ignoredExtensions.contains(ext) {
                            continue
                        }
                    }
                    if let effectiveIgnoreFile, path.isIgnored(in: effectiveIgnoreFile, isDir: false) {
                        continue
                    }
                }

                batch.append((path, isDir))
                added += 1

                if batch.count >= batchSize {
                    flushBatch()
                }

                let now = CFAbsoluteTimeGetCurrent()
                if now - lastProgress > 0.3 {
                    lastProgress = now
                    progress?(added, path)
                }
            }

            // Checkpoint: save progress after completing top-level dirs (depth <= checkpointDepth)
            if depthRelativeToBase(dirPath) <= checkpointDepth {
                flushBatch()
                saveCheckpoint(dirPath)
            }
        }

        flushBatch()
        // Clean up checkpoint file on successful completion
        if let cpFile = checkpointFile, cancelled?() != true {
            try? fm.removeItem(at: cpFile)
        }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        slog.info("walkDirectoryURL: \(dir) added=\(added) in \(ms, format: .fixed(precision: 1))ms")
        return added
    }

    /// Pre-filter entries by suffix/dirsOnly, returning matching entry indices.
    /// The result can be cached and passed to search() as candidatePool.
    /// Holds lock for the scan (runs on background thread, never blocks main thread).
    func prefilter(extensions: String?, dirsOnly: Bool) -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        let n = entries.count

        // Support multiple extensions separated by space, comma, or pipe: ".png .jpeg" or ".mp4 | .mov"
        let suffixes = extensions?
            .replacingOccurrences(of: "|", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .split(separator: " ")
            .map { String($0).lowercased() }
            .filter { $0.hasPrefix(".") } ?? []
        // Resolve to ext IDs where possible, keep byte arrays for unknown extensions
        var knownExtIDs = [UInt16]()
        var unknownSuffixBytes = [[UInt8]]()
        for sfx in suffixes {
            if let eid = extToID[sfx] {
                knownExtIDs.append(eid)
            } else {
                unknownSuffixBytes.append(Array(sfx.utf8))
            }
        }
        let hasSuffixFilter = !knownExtIDs.isEmpty || !unknownSuffixBytes.isEmpty

        var result = [Int]()
        result.reserveCapacity(n / 10)

        var i = 0
        while i < n {
            if dirsOnly, !entries[i].isDir {
                i &+= 1; continue
            }
            if hasSuffixFilter {
                var matched = false
                // Check known ext IDs (O(1) per ID)
                if !knownExtIDs.isEmpty {
                    let eid = extIDs[i]
                    var ei = 0
                    while ei < knownExtIDs.count {
                        if eid == knownExtIDs[ei] {
                            matched = true; break
                        }
                        ei &+= 1
                    }
                }
                // Fallback: byte-level suffix check for unknown extensions
                if !matched, !unknownSuffixBytes.isEmpty {
                    let len = byteLengths[i]
                    let off = byteOffsets[i]
                    var si = 0
                    while si < unknownSuffixBytes.count {
                        let sfx = unknownSuffixBytes[si]
                        if len >= sfx.count {
                            var ok = true; var j = 0
                            while j < sfx.count {
                                if allBytes[off + len - sfx.count + j] != sfx[j] {
                                    ok = false; break
                                }
                                j &+= 1
                            }
                            if ok {
                                matched = true; break
                            }
                        }
                        si &+= 1
                    }
                }
                if !matched {
                    i &+= 1; continue
                }
            }
            result.append(i)
            i &+= 1
        }
        slog.debug("prefilter: suffixes=\(suffixes) dirsOnly=\(dirsOnly) knownIDs=\(knownExtIDs.count) unknownSfx=\(unknownSuffixBytes.count) → \(result.count)/\(n) entries")
        return result
    }

    /// Searches, and for a bare query also reads it as misspelt: `colour` finds `color` and `grey`
    /// finds `gray`. A name found that way ranks as it would spelt the way
    /// it was typed, less `typoCost`, so one that really is spelt that way keeps its place ahead.
    func search(
        query: String,
        maxResults: Int = 200,
        folderPrefixes: [String]? = nil,
        excludedPrefixes: [String]? = nil,
        excludedPaths: Set<String>? = nil,
        suffixPattern: String? = nil,
        dirsOnly: Bool = false,
        maxDepth: Int? = nil,
        candidatePool: [Int]? = nil,
        literalDefault: Bool = false,
        cancelled: (() -> Bool)? = nil
    ) -> [SearchResult] {
        let found = searchReadingExtension(
            query: query, maxResults: maxResults, folderPrefixes: folderPrefixes,
            excludedPrefixes: excludedPrefixes, excludedPaths: excludedPaths,
            suffixPattern: suffixPattern, dirsOnly: dirsOnly, maxDepth: maxDepth,
            candidatePool: candidatePool, literalDefault: literalDefault, cancelled: cancelled
        )
        guard !literalDefault, let tq = TypoQuery(query), cancelled?() != true else { return found }
        // A misspelt name ranks at most its score plus this, in an important folder with every bonus a name can get.
        // Once the plain results fill the list, a name that can't beat the last of them is left out before it costs a
        // search, which is most of them for a common word: `contents` reads as every `Content*` on the disk.
        let bonus = SC.rankHasBaseBonus * (tq.words.count > 1 ? tq.words.count + 1 : 1)
            + SC.rankPrefixMatchBonus + 4 * SC.rankImportanceMultiplier - typoCost(1)
        let minScore = if found.count >= maxResults, let last = found.last {
            last.rank - bonus
        } else {
            Int.min
        }
        guard tq.twinScore >= minScore else { return found }
        // A full list that ends on a name matched as typed has no room for a misspelt one, which ranks below it.
        if found.count >= maxResults, found.last?.matchesAsTyped == true {
            return found
        }

        let groups = typoMatches(
            tq, minScore: minScore, candidatePool: candidatePool, dirsOnly: dirsOnly, suffixPattern: suffixPattern,
            cancelled: cancelled
        )
        var misspelt: [SearchResult] = []
        // One search per reading, over only the names that reading was picked for, so every result is filtered and
        // ranked by the same code as the plain ones. In a fixed order, so equal ranks don't trade places as you type.
        for (skip, hits) in groups.sorted(by: { $0.key < $1.key }) {
            if cancelled?() == true {
                return found
            }
            let reading = searchCore(
                query: tq.reading(skipping: skip), maxResults: maxResults, folderPrefixes: folderPrefixes,
                excludedPrefixes: excludedPrefixes, excludedPaths: excludedPaths,
                suffixPattern: suffixPattern, dirsOnly: dirsOnly, maxDepth: maxDepth,
                candidatePool: hits.keys.sorted(), cancelled: cancelled,
                misspelt: hits
            )
            misspelt.append(contentsOf: reading.filter { $0.typos > 0 })
        }
        guard !misspelt.isEmpty else { return found }

        // A name both readings found takes the misspelt one, which may rank it higher (`documnt` reads `document` as
        // one dropped letter, not a scattered match) but never lower than it ranked as typed, however far placing
        // the typos below the exact matches sinks it.
        var all = found
        var at: [String: Int] = [:]
        for (i, r) in found.enumerated() {
            at[r.path] = i
        }
        for var r in misspelt {
            if let i = at[r.path] {
                guard !all[i].matchesAsTyped else { continue }
                r.rankAsTyped = all[i].rank
                all[i] = r
            } else {
                at[r.path] = all.count
                all.append(r)
            }
        }
        all = all.typosAfterTypedMatches()
        all.sort { $0 > $1 }
        return Array(all.prefix(maxResults))
    }

    // MARK: - Paths from the stored bytes

    /// The path of entry `id` as it is on disk (or its first `prefix` bytes), rebuilt from its lowercased bytes and
    /// case bits. Caller holds the lock.
    func path(_ id: Int, prefix: Int? = nil) -> String {
        let off = byteOffsets[id]
        let len = min(byteLengths[id], prefix ?? Int.max)
        guard len > 0 else { return "" }
        return String(unsafeUninitializedCapacity: len) { dst in
            restoreCase(off, len, into: dst.baseAddress!)
            return len
        }
    }

    private enum Section: Int, CaseIterable {
        case masks, bnMasks, bnBoundaries, byteOffsets, byteLengths, entries, extIDs, allBytes, caseBits, extNames
    }

    private struct V4Header {
        static let size = 64 + Section.allCases.count * 16

        var entryCount = 0
        var allBytesCount = 0
        var caseWords = 0
        var extCount = 0
        var sections: [(offset: Int, length: Int)] = []

        /// Reads and checks a header against the file size. Every count is bounded while still a UInt64, so a garbage
        /// header can't trap in a conversion before it is rejected.
        static func read(_ raw: UnsafeRawPointer, fileSize: Int) -> V4Header? {
            guard raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self) == binaryMagicV4,
                  raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self) == binaryVersionV4,
                  raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self) == UInt32(Section.allCases.count)
            else { return nil }
            let limit = UInt64(fileSize)
            let n = raw.loadUnaligned(fromByteOffset: 16, as: UInt64.self)
            let ab = raw.loadUnaligned(fromByteOffset: 24, as: UInt64.self)
            let words = raw.loadUnaligned(fromByteOffset: 32, as: UInt64.self)
            let exts = raw.loadUnaligned(fromByteOffset: 40, as: UInt64.self)
            guard n <= limit / 36, ab <= limit, ab <= UInt64(UInt32.max), words <= limit / 8, exts <= UInt64(UInt16.max) else { return nil }
            var h = V4Header(entryCount: Int(n), allBytesCount: Int(ab), caseWords: Int(words), extCount: Int(exts))
            guard h.caseWords * 64 >= h.allBytesCount else { return nil }
            for s in Section.allCases {
                let off = raw.loadUnaligned(fromByteOffset: 64 + s.rawValue * 16, as: UInt64.self)
                let len = raw.loadUnaligned(fromByteOffset: 64 + s.rawValue * 16 + 8, as: UInt64.self)
                guard off <= limit, len <= limit, off + len <= limit, off % UInt64(sectionAlignment) == 0 else { return nil }
                if let expected = h.expectedLength(s), Int(len) != expected {
                    return nil
                }
                h.sections.append((Int(off), Int(len)))
            }
            return h
        }

        func expectedLength(_ s: Section) -> Int? {
            switch s {
            case .masks, .bnMasks, .bnBoundaries: entryCount * 8
            case .byteOffsets, .entries: entryCount * 4
            case .byteLengths, .extIDs: entryCount * 2
            case .allBytes: allBytesCount
            case .caseBits: caseWords * 8
            case .extNames: nil
            }
        }

    }

    // MARK: - Search

    /// Sort dimensions (all descending: higher = better):
    ///   a = has_base:       1 if basename matched (non-slash queries), else 0
    ///   b = prefix_match:   1 if basename starts/ends with query or extension token
    ///   c = path_importance: 4=important user dir, 3=home, 2=library, 1=system, 0=hidden
    ///   d = basename:     fuzzy score of query vs basename (checked before tightness so boundary matches win)
    ///   e = tightness:    -(match window width), tighter = better
    ///   f = fullpath:     fuzzy score of query vs full path
    ///   g = dir_bonus:    +100 if dir and query ends with /, -100 if file, 0 if no /
    ///   h = depth:        -(segment count), shallower = better
    ///   i = shorter:      -(path byte length), shorter = better
    private struct SortKey: Comparable {
        let a, b, c, d, e, f, g, h, i: Int32

        @inline(__always) static func < (l: SortKey, r: SortKey) -> Bool {
            if l.a != r.a {
                return l.a > r.a
            }
            if l.b != r.b {
                return l.b > r.b
            }
            if l.c != r.c {
                return l.c > r.c
            }
            if l.d != r.d {
                return l.d > r.d
            }
            if l.e != r.e {
                return l.e > r.e
            }
            if l.f != r.f {
                return l.f > r.f
            }
            if l.g != r.g {
                return l.g > r.g
            }
            if l.h != r.h {
                return l.h > r.h
            }
            return l.i > r.i
        }
        @inline(__always) static func == (l: SortKey, r: SortKey) -> Bool {
            l.a == r.a && l.b == r.b && l.c == r.c && l.d == r.d && l.e == r.e && l.f == r.f && l.g == r.g && l.h == r.h && l.i == r.i
        }
    }

    /// One per scored candidate, so a broad query holds millions of them at once: 32-bit fields keep it at 56 bytes
    /// instead of 80. Scores, qualities and ids all fit.
    private struct ScoredEntry {
        init(id: Int, key: SortKey, bestScore: Int, quality: Int, hasBase: Bool, segmentMatches: Int = 0) {
            _id = Int32(truncatingIfNeeded: id)
            self.key = key
            _bestScore = Int32(clamping: bestScore)
            _quality = Int32(clamping: quality)
            _segmentMatches = Int32(clamping: segmentMatches)
            self.hasBase = hasBase
        }

        let key: SortKey
        let hasBase: Bool

        var id: Int {
            Int(_id)
        }
        var bestScore: Int {
            Int(_bestScore)
        }
        var quality: Int {
            Int(_quality)
        }
        var segmentMatches: Int {
            Int(_segmentMatches)
        }

        private let _id: Int32
        private let _bestScore: Int32
        private let _quality: Int32
        private let _segmentMatches: Int32
    }

    /// Columns read from a file, not yet installed.
    private struct LoadedColumns {
        let entries = Column<Entry>()
        let masks = Column<UInt64>()
        let bnMasks = Column<UInt64>()
        let bnBoundaries = Column<UInt64>()
        let byteOffsets = IntColumn<UInt32>()
        let byteLengths = IntColumn<UInt16>()
        let extIDs = Column<UInt16>()
        let allBytes = Column<UInt8>()
        let caseBits = Column<UInt64>()
        var live = 0
    }

    private static let homeLinksLock = NSLock()
    private nonisolated(unsafe) static var homeLinksCache: (at: CFAbsoluteTime, links: [(real: String, shown: String)]) = (0, [])

    // MARK: - Binary persistence

    /// v4 ("CLINGIX4"): a 16 KB header, then one section per column, each starting on a 16 KB boundary and laid out
    /// exactly as the engine keeps it in memory, so loading is one read per section with nothing to convert.
    ///
    ///     header    magic, version, section count, entry count, allBytes count, caseBits words, extension count,
    ///               then (offset, length) for each section in `Section` order
    ///     sections  masks, bnMasks, bnBoundaries [UInt64]; byteOffsets [UInt32]; byteLengths [UInt16];
    ///               entries [Entry, 4 bytes]; extIDs [UInt16]; allBytes [UInt8]; caseBits [UInt64];
    ///               extension names, NUL-separated, the k-th naming extension ID k + 1
    ///
    /// v3 files ("CLINGIX3", per-entry path strings) still load, and are written as v4 at the next save.
    private static let binaryMagicV4: UInt64 = 0x3449_584E_494C_4C43 // "CLINGIX4" little-endian
    private static let binaryVersionV4: UInt32 = 1

    /// Per-entry bytes in the fixed-size section: masks + bnMasks + bnBoundaries (8 each), byteOffsets (4),
    /// byteLengths + bnStarts (2 each), segCounts + isDirs (1 each).
    private static let binaryBytesPerEntry = 34

    // MARK: - Binary Persistence (fast load via mmap + memcpy)

    // Binary format:
    // [8]  magic: "CLINGIX3"
    // [8]  entryCount: UInt64
    // [8]  allBytesCount: UInt64
    // [entryCount * 8]  masks: [UInt64]
    // [entryCount * 8]  bnMasks: [UInt64]
    // [entryCount * 8]  bnBoundaries: [UInt64]
    // [entryCount * 4]  byteOffsets: [UInt32]  (max 4GB of path bytes)
    // [entryCount * 2]  byteLengths: [UInt16]  (max 65535 bytes per path)
    // [entryCount * 2]  bnStarts: [UInt16]
    // [entryCount * 1]  segCounts: [UInt8]
    // [entryCount * 1]  isDirs: [UInt8]        (0 or 1)
    // [allBytesCount]   allBytes: [UInt8]       (lowercased path bytes)
    // [remaining]       pathStrings: null-terminated UTF-8 strings concatenated

    private static let binaryMagic: UInt64 = 0x3349_584E_494C_4C43 // "CLINGIX3" little-endian

    private static var globalExtToID: [String: UInt16] = [:]
    private static var globalExtHashToID: [UInt64: UInt16] = [:]
    private static var globalIdToExt: [UInt16: String] = [:]
    private static var globalNextExtID: UInt16 = 1
    private static let extLock = NSLock()

    private let publishedCount = OSAllocatedUnfairLock(initialState: 0)
    /// Entries below this id sit in pages mapped from the index file: a removal there only zeroes the two values search
    /// checks, and the slot isn't reused, so the fewest pages get copied.
    private var mappedCount = 0
    private var changes = 0
    private var savedChanges = 0
    private let entries = Column<Entry>()

    private let bnBoundaries = Column<UInt64>() // bit N = 1 means basename byte N is a word boundary (camelCase, delimiter, etc.)

    private let masks = Column<UInt64>()
    private let bnMasks = Column<UInt64>()
    /// Every path's bytes with ASCII lowercased, which is what search reads. Removed paths leave their bytes behind
    /// until the next save.
    private let allBytes = Column<UInt8>()
    /// One bit per byte of `allBytes`: set where the path has an uppercase ASCII letter. Lowercasing touches nothing
    /// else, so this and `allBytes` give back every path byte for byte.
    private let caseBits = Column<UInt64>()
    private let byteOffsets = IntColumn<UInt32>()
    private let byteLengths = IntColumn<UInt16>()

    private let extIDs = Column<UInt16>() // Extension ID per entry (0 = no extension)

    private var free: [Int] = []
    /// Path to id, built on first need (a live change, a lookup), as ids hashed from the stored bytes.
    private var pathTable = PathTable()
    private var pathIndexBuilt = false
    private var sortedByPath: [Int]?

    /// Lock for thread-safe mutations during parallel walks
    private let lock = NSLock()

    /// Entries that hold a path. Removed ones stay behind as holes until the next save.
    private var liveCount = 0 {
        didSet { publishedCount.withLock { $0 = liveCount } }
    }

    /// Per-engine accessors that delegate to global state
    private var extToID: [String: UInt16] {
        get { Self.globalExtToID }
        set { Self.globalExtToID = newValue }
    }
    private var extHashToID: [UInt64: UInt16] {
        get { Self.globalExtHashToID }
        set { Self.globalExtHashToID = newValue }
    }
    private var idToExt: [UInt16: String] {
        get { Self.globalIdToExt }
        set { Self.globalIdToExt = newValue }
    }
    private var nextExtID: UInt16 {
        get { Self.globalNextExtID }
        set { Self.globalNextExtID = newValue }
    }

    /// This process's ID for each extension name, registering the new ones; index 0 (no extension) maps to 0.
    private static func registerExtensions(_ names: [String]) -> [UInt16] {
        var map: [UInt16] = [0]
        map.reserveCapacity(names.count + 1)
        extLock.lock()
        defer { extLock.unlock() }
        for name in names {
            var bytes = Array(name.utf8)
            guard bytes.count > 1 else {
                map.append(0)
                continue
            }
            let h = bytes.withUnsafeMutableBufferPointer { extHash($0.baseAddress!, from: 0, len: $0.count) }
            if let id = globalExtHashToID[h] {
                map.append(id)
                continue
            }
            // The first engine loaded keeps its own IDs when they are free, so its column needs no rewriting.
            var id = UInt16(map.count)
            if globalIdToExt[id] != nil || id == 0 {
                id = globalNextExtID
                globalNextExtID &+= 1
            }
            globalNextExtID = max(globalNextExtID, id &+ 1)
            globalExtHashToID[h] = id
            globalExtToID[name] = id
            globalIdToExt[id] = name
            map.append(id)
        }
        return map
    }

    private static func lowercasedDirPrefix(_ dir: String) -> [UInt8] {
        (dir.hasSuffix("/") ? dir : dir + "/").utf8.map(toLowerByte)
    }

    /// Whether the path bytes name one of the `dir/` prefixes' dirs or something below one. Compares the path
    /// with a slash appended, so the dir itself lands exactly on its prefix.
    private static func isInside(_ path: UnsafePointer<UInt8>, _ len: Int, _ prefixes: [[UInt8]]) -> Bool {
        prefixIndex(path, len, prefixes) != nil
    }

    /// Which of the sorted, prefix-free `dir/` prefixes names the path's dir or one holding it.
    private static func prefixIndex(_ path: UnsafePointer<UInt8>, _ len: Int, _ prefixes: [[UInt8]]) -> Int? {
        // Index of the first prefix that sorts after the slashed path.
        var lo = 0, hi = prefixes.count
        while lo < hi {
            let mid = (lo &+ hi) / 2
            if compareSlashed(prefixes[mid], path, len) <= 0 {
                lo = mid &+ 1
            } else {
                hi = mid
            }
        }
        guard lo > 0 else { return nil }
        let prefix = prefixes[lo - 1]
        guard len + 1 >= prefix.count else { return nil }
        let inside = prefix.withUnsafeBufferPointer { p in
            memcmp(path, p.baseAddress!, min(len, prefix.count)) == 0
        }
        return inside ? lo - 1 : nil
    }

    /// Orders `prefix` against the path bytes followed by `/`: negative, zero or positive like memcmp.
    private static func compareSlashed(_ prefix: [UInt8], _ path: UnsafePointer<UInt8>, _ len: Int) -> Int {
        let n = min(prefix.count, len + 1)
        var k = 0
        while k < n {
            let a = prefix[k]
            let b = k < len ? path[k] : 0x2F
            if a != b {
                return a < b ? -1 : 1
            }
            k &+= 1
        }
        return prefix.count - (len + 1)
    }

    /// The split whose tail sits closest to a real extension, longest tail breaking ties. Scans the
    /// extension list without building a table or running a search, so the readings that resemble
    /// nothing cost almost nothing to rule out.
    private static func closestExtensionSplit(
        _ splits: [(head: String, tail: [UInt8])], maxDist: Int
    ) -> (head: String, tail: [UInt8])? {
        guard !splits.isEmpty else { return nil }
        extLock.lock()
        let known = globalIdToExt
        extLock.unlock()

        var best: (head: String, tail: [UInt8])?
        var bestDist = maxDist + 1
        for split in splits {
            var d = maxDist + 1
            for ext in known.values {
                let e = Array(ext.dropFirst().utf8)
                guard !e.isEmpty else { continue }
                d = min(d, extDistance(split.tail, e, limit: maxDist))
                if d == 0 {
                    break
                }
            }
            if d <= maxDist, d <= bestDist {
                bestDist = d; best = split
            }
        }
        return best
    }

    /// Known extensions within `maxDist` edits of what the user typed, keyed by extension ID and
    /// valued by the score credited for landing on one, so ranking a candidate is a lookup.
    private static func extCreditTable(for tail: [UInt8], maxDist: Int) -> [UInt16: Int] {
        extLock.lock()
        let known = globalIdToExt
        extLock.unlock()

        var table: [UInt16: Int] = [:]
        for (id, ext) in known {
            let e = Array(ext.dropFirst().utf8) // stored with the leading dot
            guard !e.isEmpty else { continue }
            let d = extDistance(tail, e, limit: maxDist)
            if d <= maxDist {
                table[id] = extCredit(distance: d, maxDist: maxDist, tailLen: tail.count)
            }
        }
        return table
    }

    /// The entry count and byte count come out of the file's own header, and every read below is an
    /// unchecked `memcpy` or pointer walk against them. A crash or a full disk mid-write leaves a
    /// truncated index whose header still claims the full size, so check the declared sizes fit the
    /// file before reading a single byte of it: a bad index must lose to a re-index, not read off the
    /// end of the map. The per-entry checks are folded into the loops that already read those values,
    /// so this stays O(1) and index loading keeps its speed.
    private static func binaryHeaderBounds(
        rawN: UInt64, rawAllBytes: UInt64, totalLen: Int
    ) -> (n: Int, allBytesCount: Int)? {
        // Bound both counts while they are still UInt64. `Int(_: UInt64)` traps above Int.max, so
        // converting first would crash on a garbage header before any bounds check could run. Every
        // entry costs binaryBytesPerEntry in the fixed section plus at least a NUL terminator, and
        // allBytes has to fit too, so the file's own size caps both.
        guard rawN <= UInt64(totalLen / (binaryBytesPerEntry + 1)), rawAllBytes <= UInt64(totalLen) else {
            return nil
        }
        let n = Int(rawN)
        let allBytesCount = Int(rawAllBytes)
        guard 24 + n * binaryBytesPerEntry + allBytesCount <= totalLen else { return nil }
        return (n, allBytesCount)
    }

    /// Hash extension bytes into a UInt64 key (up to 8 bytes including the dot)
    @inline(__always) private static func extHash(_ bytes: UnsafePointer<UInt8>, from dotPos: Int, len: Int) -> UInt64 {
        var h: UInt64 = 0
        let extLen = min(len - dotPos, 8)
        var k = 0
        while k < extLen {
            h |= UInt64(bytes[dotPos + k]) << UInt64(k &* 8)
            k &+= 1
        }
        return h
    }

    // MARK: - Path index

    /// The bytes a path is looked up by: its own UTF-8 when it is all ASCII, otherwise its NFC form. NFC and NFD
    /// spellings of an accented path are then the same path, as `String ==` treats them, while only the few paths with
    /// bytes past ASCII pay for normalizing.
    private static func lookupKey(_ path: String) -> [UInt8] {
        let utf8 = path.utf8
        if !utf8.contains(where: { $0 >= 0x80 }) {
            return Array(utf8)
        }
        return Array(path.precomposedStringWithCanonicalMapping.utf8)
    }

    /// Paths are hashed lowercased, so a stored entry hashes straight from `allBytes`.
    private static func keyHash(_ key: [UInt8]) -> Int {
        var lower = key
        for i in lower.indices {
            lower[i] = toLowerByte(lower[i])
        }
        return lower.withUnsafeBufferPointer { PathTable.hash($0.baseAddress!, $0.count) }
    }

    /// Searches, and for a bare query also reads it as a name plus a possibly-mistyped extension,
    /// keeping whichever reading produces the better top result. `hlxcfgyml` finds
    /// `.config/helix/config.toml`, because `yml` is two edits from `toml` and so is credited as a
    /// near-match instead of having to contain its letters.
    ///
    /// The literal reading always competes on equal terms and keeps ties, so a query that today
    /// finds what the user wanted still finds it. A split only wins by ranking higher, which needs
    /// both a better name match and an extension that resembles what they typed.
    private func searchReadingExtension(
        query: String,
        maxResults: Int,
        folderPrefixes: [String]?,
        excludedPrefixes: [String]?,
        excludedPaths: Set<String>?,
        suffixPattern: String?,
        dirsOnly: Bool,
        maxDepth: Int?,
        candidatePool: [Int]?,
        literalDefault: Bool,
        cancelled: (() -> Bool)?
    ) -> [SearchResult] {
        let strict = searchCore(
            query: query, maxResults: maxResults, folderPrefixes: folderPrefixes,
            excludedPrefixes: excludedPrefixes, excludedPaths: excludedPaths,
            suffixPattern: suffixPattern, dirsOnly: dirsOnly, maxDepth: maxDepth,
            candidatePool: candidatePool, literalDefault: literalDefault, cancelled: cancelled
        )
        guard !literalDefault else { return strict }
        // The literal reading matched a filename, so it found something the user could have meant.
        // Guessing at a mistyped extension on top of that is how `modifiedpyc` stops finding
        // `modified.cpython-311.pyc` and starts finding `modified.py`, one edit away and not what
        // was asked for. Reinterpret only when every literal match is scattered down a path.
        guard !strict.contains(where: { $0.hasBase || $0.segmentMatches > 0 }) else { return strict }
        // A dense literal match is one a human could have typed on purpose, so leave it alone.
        // Without this `srcmainjava` pays for four extra searches to re-derive the `Main.java` it
        // had already found.
        if let top = strict.first, top.quality >= top.score / 2 {
            return strict
        }

        let splits = extensionTailSplits(query.trimmingCharacters(in: .whitespaces).lowercased())
        // Only the reading whose tail comes closest to a real extension is worth a search. Scoring
        // the splits against the extension list first keeps this to one extra search rather than
        // one per candidate tail length.
        guard let split = Self.closestExtensionSplit(splits, maxDist: extTailMaxDistance) else { return strict }
        if cancelled?() == true {
            return strict
        }

        let table = Self.extCreditTable(for: split.tail, maxDist: extTailMaxDistance)
        let retry = searchCore(
            query: split.head, maxResults: maxResults, folderPrefixes: folderPrefixes,
            excludedPrefixes: excludedPrefixes, excludedPaths: excludedPaths,
            suffixPattern: suffixPattern, dirsOnly: dirsOnly, maxDepth: maxDepth,
            candidatePool: candidatePool, literalDefault: literalDefault, cancelled: cancelled,
            extCredits: table
        )
        // Three things before a split may displace the literal reading: it landed on a file whose
        // extension really does resemble the typed one, its own match is dense rather than
        // scattered, and it wins by a clear margin. Ranks from two different queries aren't
        // strictly comparable, so a hair's-breadth win means nothing and the literal keeps ties.
        //
        // Density is what stops gibberish inventing answers: `xyzwvutsrq` has no literal match at
        // all, so anything the split turns up would otherwise win by default.
        //
        // The split's match may still be path-scattered across segments: `hlxcfg` finds
        // `.config/helix/config.toml` over two directories and a filename, so requiring a basename
        // match would rule out the case this exists for. Density allows that; noise it does not.
        guard let top = retry.first, top.extCredit > 0,
              top.quality >= top.score / 2,
              top.rank > (strict.first?.rank ?? Int.min) + SC.rankPrefixMatchBonus
        else { return strict }
        return retry
    }

    /// Every entry a misspelt reading of the query finds by name, grouped by the letters that reading skipped, with the
    /// score its name would have had spelt the way the query was. Names scoring under `minScore` are left out.
    private func typoMatches(
        _ tq: TypoQuery, minScore: Int, candidatePool: [Int]?, dirsOnly: Bool, suffixPattern: String?,
        cancelled: (() -> Bool)?
    ) -> [UInt64: [Int: TypoHit]] {
        lock.lock()
        defer { lock.unlock() }
        let n = entries.count
        let total = candidatePool?.count ?? n
        guard total > 0 else { return [:] }
        let m = tq.letters.count
        let waste = SC.basenameWastePenalty
        let widest = m + typoMaxSeparator * (tq.words.count - 1)
        let suffix = suffixPattern.map { Array($0.lowercased().utf8) }
        let isCancelled = cancelled ?? { false }

        let procs = max(ProcessInfo.processInfo.activeProcessorCount, 1)
        let chunkSize = max((total + procs - 1) / procs, 4096)
        let chunks = (total + chunkSize - 1) / chunkSize
        let store = UnsafeMutablePointer<[(id: Int, skip: UInt64, hit: TypoHit)]>.allocate(capacity: chunks)
        store.initialize(repeating: [], count: chunks)
        defer {
            store.deinitialize(count: chunks)
            store.deallocate()
        }

        allBytes.withUnsafeBufferPointer { all in
            tq.peq.withUnsafeBufferPointer { peq in
                DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                    var local: [(id: Int, skip: UInt64, hit: TypoHit)] = []
                    var k = chunk * chunkSize
                    let end = min(k + chunkSize, total)
                    while k < end {
                        if k & 0xFFF == 0, isCancelled() {
                            break
                        }
                        let i = candidatePool?[k] ?? k
                        k &+= 1
                        // A name missing more of the query's letters than it may skip can't be read as it.
                        guard i >= 0, i < n, (tq.mask & ~self.bnMasks[i]).nonzeroBitCount <= tq.budget else { continue }
                        let e = self.entries[i]
                        let off = self.byteOffsets[i]
                        let len = self.byteLengths[i]
                        let bnLen = len - e.bnStart
                        // A reading covers the query's letters and the separators between its words at most, so a name
                        // this much longer is charged too much waste to score enough, whatever it reads as.
                        guard bnLen >= m - tq.budget, tq.twinScore - (bnLen - widest) * waste >= minScore else { continue }
                        // A pool comes already narrowed to these, the way searchCore takes it.
                        if candidatePool == nil {
                            if dirsOnly, !e.isDir {
                                continue
                            }
                            if let suffix {
                                guard len >= suffix.count, memcmp(all.baseAddress! + off + len - suffix.count, suffix, suffix.count) == 0 else { continue }
                            }
                        }
                        let bn = UnsafeBufferPointer(start: all.baseAddress! + off + e.bnStart, count: bnLen)
                        let lcs = lcsLength(peq.baseAddress!, m, bn.baseAddress!, bnLen)
                        guard lcs >= m - tq.budget else { continue }
                        if let r = typoReading(tq, bn, bounds: self.bnBoundaries[i], lcs: lcs) {
                            // The twin has the query's letters where the reading found its own, and the rest of the
                            // name around them, which searchCore charges for as basename waste.
                            let score = tq.twinScore - (bnLen - r.window) * waste
                            if score >= minScore {
                                local.append((i, r.skip, (score, r.typos)))
                            }
                        }
                    }
                    store[chunk] = local
                }
            }
        }

        var groups: [UInt64: [Int: TypoHit]] = [:]
        for c in 0 ..< chunks {
            for hit in store[c] {
                groups[hit.skip, default: [:]][hit.id] = hit.hit
            }
        }
        return groups
    }

    /// Maps each section of a v4 file into its column (or reads it there when mapping is off), checks every entry
    /// against the file's own counts unless the file was just written by this engine, and brings extension IDs into
    /// this process's numbering.
    private func readV4(_ url: URL, trusted: Bool, progress: ((Int) -> Void)? = nil) -> LoadedColumns? {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        let fileSize = Int(st.st_size)
        if !trusted {
            adviseSequentialRead(url.path)
        }

        var headerBuf = [UInt8](repeating: 0, count: V4Header.size)
        guard fileSize >= V4Header.size, pread(fd, &headerBuf, V4Header.size, 0) == V4Header.size,
              let header = headerBuf.withUnsafeBytes({ V4Header.read($0.baseAddress!, fileSize: fileSize) })
        else {
            slog.error("loadBinaryIndex: bad v4 header in \(url.path)")
            return nil
        }
        let n = header.entryCount

        /// Maps section `s` into `storage`, or reads it there when mapping is off or fails, leaving headroom after it.
        func read<T>(_ s: Section, into storage: inout ColumnStorage<T>, count: Int, headroom: Int) -> Bool {
            let (off, length) = header.sections[s.rawValue]
            let page = ColumnStorage<T>.pageSize
            if Self.mapIndexFiles, off + (length + page - 1) / page * page <= fileSize,
               let mapped = ColumnStorage<T>.mapped(fd: fd, offset: off, length: length, count: count, capacity: count + headroom)
            {
                storage.release()
                storage = mapped
                return true
            }
            storage.reserve(count + headroom)
            storage.setCount(count)
            let dst = UnsafeMutableRawPointer(storage.base)
            var done = 0
            while done < length {
                let r = pread(fd, dst + done, length - done, off_t(off + done))
                guard r > 0 else { return false }
                done += r
            }
            return true
        }

        // Room to double before a column has to move, which costs address space only: a page counts once it's written.
        var c = LoadedColumns()
        let extra = max(Self.headroom(n), n), byteExtra = max(Self.headroom(header.allBytesCount, minimum: 65536), header.allBytesCount)
        guard read(.masks, into: &c.masks.storage, count: n, headroom: extra),
              read(.bnMasks, into: &c.bnMasks.storage, count: n, headroom: extra),
              read(.bnBoundaries, into: &c.bnBoundaries.storage, count: n, headroom: extra),
              read(.byteOffsets, into: &c.byteOffsets.storage, count: n, headroom: extra),
              read(.byteLengths, into: &c.byteLengths.storage, count: n, headroom: extra),
              read(.entries, into: &c.entries.storage, count: n, headroom: extra),
              read(.extIDs, into: &c.extIDs.storage, count: n, headroom: extra),
              read(.allBytes, into: &c.allBytes.storage, count: header.allBytesCount, headroom: byteExtra),
              read(.caseBits, into: &c.caseBits.storage, count: header.caseWords, headroom: byteExtra / 64 + 1)
        else {
            slog.error("loadBinaryIndex: short read in \(url.path)")
            return nil
        }
        progress?(n / 2)

        // The scorer and the path rebuild read allBytes[off ..< off + len] unchecked, so a corrupt entry must not get in.
        var i = 0
        var live = 0
        if trusted {
            while i < n {
                if c.byteLengths[i] > 0 {
                    live &+= 1
                }
                i &+= 1
            }
        } else {
            while i < n {
                let len = c.byteLengths[i]
                if c.byteOffsets[i] &+ len > header.allBytesCount || c.entries[i].bnStart > len || Int(c.extIDs[i]) > header.extCount {
                    slog.error("loadBinaryIndex: entry \(i) out of bounds in \(url.path)")
                    return nil
                }
                if len > 0 {
                    live &+= 1
                }
                i &+= 1
            }
        }
        c.live = live

        // Extension IDs are this process's: map the file's onto them, which costs nothing when they already agree.
        let (namesOff, namesLen) = header.sections[Section.extNames.rawValue]
        var names = [UInt8](repeating: 0, count: namesLen)
        guard namesLen == 0 || pread(fd, &names, namesLen, off_t(namesOff)) == namesLen else { return nil }
        let extNames = names.split(separator: 0, omittingEmptySubsequences: false).prefix(header.extCount).map { String(decoding: $0, as: UTF8.self) }
        guard extNames.count == header.extCount else {
            slog.error("loadBinaryIndex: extension names truncated in \(url.path)")
            return nil
        }
        let map = Self.registerExtensions(extNames)
        if map.enumerated().contains(where: { $0.offset != Int($0.element) }) {
            c.extIDs.withUnsafeMutableBufferPointer { ids in
                for j in ids.indices {
                    ids[j] = map[Int(ids[j])]
                }
            }
        }
        return c
    }

    /// Reads a v3 file into the heap: the per-entry path strings become case bits and a flag for paths beyond ASCII.
    private func readV3(_ url: URL, progress: ((Int) -> Void)?) -> LoadedColumns? {
        adviseSequentialRead(url.path)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            slog.error("loadBinaryIndex: failed to read \(url.path)")
            return nil
        }
        return data.withUnsafeBytes { buf -> LoadedColumns? in
            let ptr = buf.baseAddress!
            let totalLen = buf.count
            guard totalLen > 24 else { return nil }
            let rawN = ptr.load(fromByteOffset: 8, as: UInt64.self)
            let rawAllBytes = ptr.load(fromByteOffset: 16, as: UInt64.self)
            guard let (n, allBytesCount) = Self.binaryHeaderBounds(rawN: rawN, rawAllBytes: rawAllBytes, totalLen: totalLen) else {
                slog.error("loadBinaryIndex: truncated index, n=\(rawN) allBytes=\(rawAllBytes) file=\(totalLen)B")
                return nil
            }
            let extra = Self.headroom(n), byteExtra = Self.headroom(allBytesCount, minimum: 65536)
            func column(_ c: Column<some Any>, _ src: UnsafeRawPointer, _ count: Int, _ headroom: Int) {
                c.reserveCapacity(count + headroom)
                c.append(raw: src, count: count)
            }
            var c = LoadedColumns()
            var offset = 24
            column(c.masks, ptr + offset, n, extra)
            offset += n * 8
            column(c.bnMasks, ptr + offset, n, extra)
            offset += n * 8
            column(c.bnBoundaries, ptr + offset, n, extra)
            offset += n * 8
            c.byteOffsets.reserveCapacity(n + extra)
            c.byteOffsets.append(raw: ptr + offset, count: n)
            offset += n * 4
            c.byteLengths.reserveCapacity(n + extra)
            c.byteLengths.append(raw: ptr + offset, count: n)
            offset += n * 2
            let bnStartsOffset = offset
            offset += n * 2
            let segCountsOffset = offset
            offset += n
            let isDirsOffset = offset
            offset += n
            progress?(n / 4)

            var i = 0
            while i < n {
                if c.byteOffsets[i] &+ c.byteLengths[i] > allBytesCount {
                    slog.error("loadBinaryIndex: entry byte range outside allBytes, \(url.path)")
                    return nil
                }
                i &+= 1
            }
            column(c.allBytes, ptr + offset, allBytesCount, byteExtra)
            offset += allBytesCount
            progress?(n / 2)

            // Each entry's original-case string follows the previous one's NUL, and ASCII lowercasing keeps lengths,
            // so its start is the running sum of lengths + 1 and its NUL must sit right after it.
            let strBase = (ptr + offset).assumingMemoryBound(to: UInt8.self)
            let strEnd = totalLen - offset
            c.caseBits.reserveCapacity((allBytesCount + byteExtra) / 64 + 1)
            c.caseBits.append(repeating: 0, count: (allBytesCount + 63) / 64)
            c.entries.reserveCapacity(n + extra)
            let bits = c.caseBits.storage.base
            var strOff = 0
            var live = 0
            i = 0
            while i < n {
                let len = c.byteLengths[i]
                guard strOff + len < strEnd, strBase[strOff + len] == 0 else {
                    slog.error("loadBinaryIndex: path strings truncated at entry \(i)/\(n), \(url.path)")
                    return nil
                }
                let at = c.byteOffsets[i]
                var nonASCII = false
                var k = 0
                while k < len {
                    let ch = strBase[strOff + k]
                    if ch &- 0x41 < 26 {
                        let bit = at + k
                        bits[bit >> 6] |= 1 << UInt64(bit & 63)
                    } else if ch >= 0x80 {
                        nonASCII = true
                    }
                    k &+= 1
                }
                c.entries.append(Entry(
                    bnStart: Int(ptr.loadUnaligned(fromByteOffset: bnStartsOffset + i * 2, as: UInt16.self)),
                    segCount: Int((ptr + segCountsOffset + i).load(as: UInt8.self)),
                    isDir: (ptr + isDirsOffset + i).load(as: UInt8.self) != 0,
                    nonASCII: nonASCII
                ))
                if len > 0 {
                    live &+= 1
                }
                strOff += len + 1
                i &+= 1
            }
            c.live = live
            progress?(n * 3 / 4)

            c.extIDs.reserveCapacity(n + extra)
            c.extIDs.append(repeating: 0, count: n)
            c.allBytes.withUnsafeBufferPointer { b in
                let base = b.baseAddress!
                var i = 0
                while i < n {
                    if c.byteLengths[i] > 0 {
                        c.extIDs[i] = extID(for: base + c.byteOffsets[i], len: c.byteLengths[i], bnStart: c.entries[i].bnStart)
                    }
                    i &+= 1
                }
            }
            return c
        }
    }

    /// Swaps loaded columns in. Kept ids (a save that mapped what it wrote) leave the path index and sorted order
    /// valid; otherwise they are rebuilt on first need. Caller holds the lock.
    private func install(_ c: LoadedColumns, keepingIDs: Bool) {
        swap(&entries.storage, &c.entries.storage)
        swap(&masks.storage, &c.masks.storage)
        swap(&bnMasks.storage, &c.bnMasks.storage)
        swap(&bnBoundaries.storage, &c.bnBoundaries.storage)
        swap(&byteOffsets.storage, &c.byteOffsets.storage)
        swap(&byteLengths.storage, &c.byteLengths.storage)
        swap(&extIDs.storage, &c.extIDs.storage)
        swap(&allBytes.storage, &c.allBytes.storage)
        swap(&caseBits.storage, &c.caseBits.storage)
        liveCount = c.live
        mappedCount = masks.storage.isMapped ? entries.count : 0
        free.removeAll()
        if !keepingIDs {
            pathTable.removeAll()
            pathIndexBuilt = false
            sortedByPath = nil
        }
    }

    private func searchCore(
        query: String,
        maxResults: Int = 200,
        folderPrefixes: [String]? = nil,
        excludedPrefixes: [String]? = nil,
        excludedPaths: Set<String>? = nil,
        suffixPattern: String? = nil,
        dirsOnly: Bool = false,
        maxDepth: Int? = nil,
        candidatePool: [Int]? = nil,
        literalDefault: Bool = false,
        cancelled: (() -> Bool)? = nil,
        extCredits: [UInt16: Int]? = nil,
        misspelt: [Int: TypoHit]? = nil
    ) -> [SearchResult] {
        let t0 = CFAbsoluteTimeGetCurrent()

        // Hold lock for the entire search to prevent concurrent array reallocation.
        // Walkers batch 2048 entries before locking, so contention is minimal.
        lock.lock()
        defer { lock.unlock() }
        let n = entries.count
        guard n > 0 else { return [] }

        let qTrimmed = query.trimmingCharacters(in: .whitespaces)
        let qLower = qTrimmed.lowercased()
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path

        // Operator needles carry both NFD (primary, matches APFS storage) and NFC forms.
        // A path added programmatically or from a non-APFS volume may be NFC, so an accented
        // literal/anchor needle must be tried in both forms — mirroring the fuzzy path's NFC
        // fallback (qAltBytes).
        typealias OpNeedle = (nfd: [UInt8], nfc: [UInt8]?)
        @inline(__always) func opNeedle(_ s: String) -> OpNeedle {
            // Compare the UTF-8 BYTES, not the Strings: String == uses Unicode canonical
            // equivalence, so a composed vs decomposed string compares equal and would hide
            // the very difference we need the NFC fallback for.
            let nfd = Array(s.decomposedStringWithCanonicalMapping.utf8)
            let nfc = Array(s.precomposedStringWithCanonicalMapping.utf8)
            return (nfd, nfc != nfd ? nfc : nil)
        }
        /// Letters guaranteed present in EVERY normalization form (intersection), so the candidate
        /// prefilter / negation gate never drops a path that differs only by NFC/NFD spelling.
        @inline(__always) func needleMask(_ n: OpNeedle) -> UInt64 {
            let m1 = n.nfd.withUnsafeBufferPointer { letterMaskBytes($0) }
            guard let alt = n.nfc else { return m1 }
            return m1 & alt.withUnsafeBufferPointer { letterMaskBytes($0) }
        }

        // Positive token buckets (existing semantics)
        var inPrefixes: [String] = []
        var inAliases: [(real: String, shown: String)] = []
        var queryDepths: [Int] = []
        var extStrings: [String] = [] // ".pdf"
        var dirSegStrings: [String] = [] // "rcmd/"
        var fuzzyTokens: [String] = []
        // Operator buckets (fzf-style)
        var litSubstrings: [OpNeedle] = [] // 'foo  → required contiguous substring
        var anchorStarts: [OpNeedle] = [] // ^foo or /foo → required substring "/foo"
        var anchorEnds: [OpNeedle] = [] // foo$ → name ends with foo (extension optional)
        var negSubstrings: [OpNeedle] = [] // !foo, !foo/, !/x/ → reject if substring present
        var negExtStrings: [String] = [] // !.py → reject by extension
        var negAnchorStarts: [OpNeedle] = []
        var negAnchorEnds: [OpNeedle] = []
        var filesOnly = false // !/ → exclude directories

        for rawTok in tokenizeQuery(qLower) {
            var t = String(rawTok)
            // Negation sigil (leading '!')
            var negate = false
            if t.hasPrefix("!") {
                if t.count == 1 {
                    fuzzyTokens.append("!"); continue
                } // bare "!" is literal text
                negate = true; t = String(t.dropFirst())
            }
            if negate, t == "/" {
                filesOnly = true; continue
            }

            // Folder-scope / depth tokens (positive only)
            if !negate, t.hasPrefix("in:"), t.count > 3 {
                var path = decodeQueryEscapes(String(t.dropFirst(3)))
                if path.hasPrefix("~") {
                    path = homePath + path.dropFirst()
                }
                while path.count > 1, path.hasSuffix("/") {
                    path = String(path.dropLast())
                }
                // Mirror macOS firmlinks: /tmp, /var, /etc are exposed both as themselves and
                // under /private. Index stores the resolved /private/* form, so add it.
                if path == "/tmp" || path == "/var" || path == "/etc"
                    || path.hasPrefix("/tmp/") || path.hasPrefix("/var/") || path.hasPrefix("/etc/")
                {
                    inPrefixes.append(path); inPrefixes.append("/private" + path)
                } else if path == "/private/tmp" || path == "/private/var" || path == "/private/etc"
                    || path.hasPrefix("/private/tmp/") || path.hasPrefix("/private/var/") || path.hasPrefix("/private/etc/")
                {
                    inPrefixes.append(path); inPrefixes.append(String(path.dropFirst("/private".count)))
                } else {
                    inPrefixes.append(path)
                    // Walks store a symlinked folder's files where the link points (`~/.ssh` into a dotfiles
                    // folder), so look there too, and show what is found under the name typed.
                    if let link = Self.symlinkedFolder(path) {
                        inPrefixes.append(link.real)
                        inAliases.append(link)
                    }
                }
                continue
            }
            if !negate, t.hasPrefix("depth:"), t.count > 6 {
                if let d = Int(t.dropFirst(6)) {
                    queryDepths.append(d)
                }
                continue
            }

            // Anchor sigils: trailing '$' (end), leading '^'/single-segment '/' (start), leading '\'' (quote).
            var anchorEnd = false
            if t.hasSuffix("$"), t.count > 1, !lastIsEscaped(t) {
                anchorEnd = true; t = String(t.dropLast())
            }
            var anchorStart = false
            var quoted = false
            if t.hasPrefix("'"), t.count > 1 {
                quoted = true; t = String(t.dropFirst())
            } else if t.hasPrefix("^"), t.count > 1 {
                anchorStart = true; t = String(t.dropFirst())
            } else if t.hasPrefix("/") {
                let rest = String(t.dropFirst())
                if !rest.isEmpty, !rest.contains("/") {
                    anchorStart = true; t = rest // single-segment /foo → start anchor
                } else {
                    while t.hasPrefix("/") {
                        t = String(t.dropFirst())
                    } // legacy: strip leading slashes
                }
            }
            if t.isEmpty {
                continue
            }
            // The operators above are read from the token as typed, so an escaped character is only ever text.
            let body = t
            let text = decodeQueryEscapes(body)

            if anchorStart || anchorEnd {
                if anchorStart {
                    let b = opNeedle("/" + text)
                    if negate {
                        negAnchorStarts.append(b)
                    } else {
                        anchorStarts.append(b)
                    }
                }
                if anchorEnd {
                    let b = opNeedle(text)
                    if negate {
                        negAnchorEnds.append(b)
                    } else {
                        anchorEnds.append(b)
                    }
                }
                continue
            }

            // Extension / dir-segment classifiers are skipped for a quoted body so the quote
            // operator always treats it as plain text (e.g. "'.tar", "'photos/").
            if !quoted, body.hasPrefix("."), body.count > 1 {
                if negate {
                    negExtStrings.append(text)
                } else {
                    extStrings.append(text)
                }
                continue
            }
            if !quoted, body.hasPrefix("*."), body.count > 2 {
                let ext = "." + text.dropFirst(2)
                if negate {
                    negExtStrings.append(ext)
                } else {
                    extStrings.append(ext)
                }
                continue
            }
            if !quoted, body.hasSuffix("/"), body.count > 1 {
                if negate {
                    negSubstrings.append(opNeedle(text))
                } else {
                    dirSegStrings.append(text)
                }
                continue
            }
            // Plain word: fuzzy by default, literal substring when quoted or negated. The quote
            // flips whichever mode is NOT the default, so under literalDefault a bareword is the
            // literal one and 'foo is the fuzzy escape hatch (like fzf's --exact).
            if negate {
                negSubstrings.append(opNeedle(text))
            } else if literalDefault != quoted {
                litSubstrings.append(opNeedle(text))
                // A bareword under literalDefault also feeds the fuzzy scorer: the substring gate
                // above decides WHICH paths match, the score only ranks them. Without it a literal
                // query loses every ranking signal (basename hit, prefix, tightness) and falls back
                // to path importance alone. Contiguous text always matches as a subsequence, so
                // this never widens the result set. Explicit 'foo keeps its pure-gate semantics
                // (order-independent across several quoted words) untouched.
                if literalDefault {
                    fuzzyTokens.append(text)
                }
            } else {
                fuzzyTokens.append(text)
            }
        }

        let extTokenBytes: [[UInt8]] = extStrings.map { Array($0.utf8) }
        // Pre-resolve extension IDs for O(1) matching (UInt16 compare vs byte-by-byte suffix)
        let extTokenIDs: [UInt16] = extStrings.compactMap { extToID[$0] }
        // Extensions never seen during indexing have no extID; match them by trailing bytes. These
        // match disjunctively with extTokenIDs — a file matches if ANY queried extension fits.
        let extUnknownBytes: [[UInt8]] = extStrings.filter { extToID[$0] == nil }.map { Array($0.utf8) }
        let hasExtFilter = !extTokenBytes.isEmpty
        let dirSegments: [[UInt8]] = dirSegStrings.map { Array($0.utf8) }
        let negExtIDs: [UInt16] = negExtStrings.compactMap { extToID[$0] }
        let negExtUnknownBytes: [[UInt8]] = negExtStrings.filter { extToID[$0] == nil }.map { Array($0.utf8) }
        // Prefer directories when the query carries a positive dir-segment (e.g. "config/").
        let wantDir = !dirSegments.isEmpty
        // Effective depth limit: smallest of query depth tokens and the explicit parameter
        let effectiveMaxDepth: Int? = {
            var v = maxDepth
            for d in queryDepths {
                v = v.map { min($0, d) } ?? d
            }
            return v
        }()
        let q = fuzzyTokens.joined()
        let hasPositiveOperator = !litSubstrings.isEmpty || !anchorStarts.isEmpty || !anchorEnds.isEmpty
        let hasNegativeOperator = !negSubstrings.isEmpty || !negExtStrings.isEmpty
            || !negAnchorStarts.isEmpty || !negAnchorEnds.isEmpty || filesOnly
        let hasOperators = hasPositiveOperator || hasNegativeOperator
        // Dirs-only only when the query is SOLELY dir segments: a fuzzy/ext token, or a positive
        // operator ('foo, ^foo, foo$), means the user also wants the matching files inside.
        let dirsOnly = dirsOnly
            || (!dirSegments.isEmpty && fuzzyTokens.isEmpty && extTokenBytes.isEmpty && !hasPositiveOperator)
        let hasFuzzyQuery = !q.isEmpty || !extTokenBytes.isEmpty || !dirSegments.isEmpty || hasPositiveOperator

        // APFS stores paths in NFD (decomposed Unicode), so normalize query to NFD for primary matching.
        // Prepare NFC bytes as a fallback for paths stored in NFC (programmatically added, or from a
        // non-APFS volume). Compare the UTF-8 BYTES — String == uses Unicode canonical equivalence, so
        // a composed vs decomposed String compares equal and would silently null the fallback.
        let qBytes = Array(q.decomposedStringWithCanonicalMapping.utf8)
        let qNFCBytes = Array(q.precomposedStringWithCanonicalMapping.utf8)
        let qAltBytes: [UInt8]? = qNFCBytes != qBytes ? qNFCBytes : nil
        // qMask gates the candidate prefilter. When NFD and NFC differ, use the letter intersection
        // so an NFC-stored accented path isn't pruned before the NFC fallback in scoring can run.
        let qMask: UInt64 = {
            guard !qBytes.isEmpty else { return 0 }
            let m1 = qBytes.withUnsafeBufferPointer { letterMaskBytes($0) }
            guard let alt = qAltBytes else { return m1 }
            return m1 & alt.withUnsafeBufferPointer { letterMaskBytes($0) }
        }()
        // Per-token byte arrays for independent multi-token scoring. NFD-normalized to match APFS
        // storage (like qBytes), with a per-token NFC alternate (like qAltBytes) so an IME-typed
        // CJK/accented token still matches a path stored in the other normalization form. Without
        // this, a query like "회의록 2026" (typed NFC) never matches the NFD-stored path in
        // the multi-token pass, silently dropping the gap-free per-token score and its boundary
        // bonuses, so the file sinks below less relevant results.
        let tokenBytes: [[UInt8]]?
        let tokenAltBytes: [[UInt8]?]
        if fuzzyTokens.count > 1 {
            var prim: [[UInt8]] = []
            var alt: [[UInt8]?] = []
            prim.reserveCapacity(fuzzyTokens.count)
            alt.reserveCapacity(fuzzyTokens.count)
            for tok in fuzzyTokens {
                let nfd = Array(tok.decomposedStringWithCanonicalMapping.utf8)
                let nfc = Array(tok.precomposedStringWithCanonicalMapping.utf8)
                prim.append(nfd)
                alt.append(nfc != nfd ? nfc : nil)
            }
            tokenBytes = prim
            tokenAltBytes = alt
        } else {
            tokenBytes = nil
            tokenAltBytes = []
        }
        // Bitmask filter uses only ASCII letters/digits, which are identical across NFC/NFD, so no alt mask needed
        // Include extension token letters in the mask for candidate filtering
        // Only a SINGLE extension folds its letters into the conjunctive candidate-prefilter mask.
        // Multiple extensions match disjunctively (OR) — see extensionMatches — so AND-ing their
        // combined letters into combinedMask would demand every extension's letters appear in one
        // path at once (e.g. j from .json AND x from .xml AND z from .zsh), which matches nothing.
        // With >1 extension the precise extID/suffix test in extensionMatches does the filtering.
        var extMask: UInt64 = 0
        if extTokenBytes.count == 1 {
            extTokenBytes[0].withUnsafeBufferPointer { extMask |= letterMaskBytes($0) }
        }
        var dirMask: UInt64 = 0
        for seg in dirSegments {
            seg.withUnsafeBufferPointer { dirMask |= letterMaskBytes($0) }
        }
        // Positive literal/anchor letters are required-present, so fold them into the candidate
        // prefilter mask. needleMask() uses the NFC∩NFD intersection so an accented needle never
        // prunes a path that differs only by normalization. ('/' contributes no bits.)
        var opMask: UInt64 = 0
        for lit in litSubstrings {
            opMask |= needleMask(lit)
        }
        for a in anchorStarts {
            opMask |= needleMask(a)
        }
        for a in anchorEnds {
            opMask |= needleMask(a)
        }
        let combinedMask = qMask | extMask | dirMask | opMask
        // Per-needle letter masks gate the negation substring scan: a path can only contain
        // the needle if its whole-path mask has every needle letter, so the scan is skipped
        // for the overwhelming majority of entries.
        let negSubMasks: [UInt64] = negSubstrings.map { needleMask($0) }
        let negAnchorStartMasks: [UInt64] = negAnchorStarts.map { needleMask($0) }

        let baseBytes: [UInt8]
        let baseAltBytes: [UInt8]?
        let hasSlash: Bool
        if !qBytes.isEmpty {
            hasSlash = qBytes.contains(0x2F)
            if let lastSlash = qBytes.lastIndex(of: 0x2F) {
                baseBytes = Array(qBytes[(lastSlash + 1)...])
            } else {
                baseBytes = qBytes
            }
            if let alt = qAltBytes {
                if let lastSlash = alt.lastIndex(of: 0x2F) {
                    baseAltBytes = Array(alt[(lastSlash + 1)...])
                } else {
                    baseAltBytes = alt
                }
            } else {
                baseAltBytes = nil
            }
        } else {
            hasSlash = false
            baseBytes = []
            baseAltBytes = nil
        }
        // Intersection with the NFC basename letters (when they differ) for the same reason as qMask.
        let baseMask: UInt64 = {
            guard !baseBytes.isEmpty else { return 0 }
            let m1 = baseBytes.withUnsafeBufferPointer { letterMaskBytes($0) }
            guard let alt = baseAltBytes else { return m1 }
            return m1 & alt.withUnsafeBufferPointer { letterMaskBytes($0) }
        }()
        let suffixBytes: [UInt8]? = suffixPattern.map { Array($0.lowercased().utf8) }
        let queryHasDot = qBytes.contains(0x2E) || !extTokenBytes.isEmpty

        // Path importance prefixes for scoring (lowercased to match allBytes)
        let homePrefix = NSHomeDirectory().lowercased()
        let homePrefixBytes = Array(homePrefix.utf8)
        let importantPrefixes = [
            homePrefix + "/documents", homePrefix + "/desktop", homePrefix + "/downloads",
            homePrefix + "/projects", homePrefix + "/temp",
            homePrefix + "/music", homePrefix + "/movies", homePrefix + "/pictures",
            homePrefix + "/library/mobile documents", // iCloud Drive
            homePrefix + "/library/cloudstorage", // Dropbox, Google Drive, OneDrive…
            homePrefix + "/.config",
            "/applications",
        ].map { Array($0.utf8) }
        let libraryPrefix = Array((homePrefix + "/library").utf8)
        let configPrefix = Array((homePrefix + "/.config").utf8)
        // Like Recents' shallow dotdirs: config people open by hand sits right inside these, wherever they live (a
        // dotfiles folder `~/.ssh` links to included). Deeper down are caches, sockets and key stores.
        let configDotdirs: [[UInt8]] = [".ssh", ".aws", ".kube", ".gnupg", ".docker"].map { Array($0.utf8) }

        /// Path importance (higher = more relevant to the user), shared by the fuzzy scoring loop
        /// and the extension-only fast path:
        ///   4 = important user dir (Documents, Desktop, Downloads, Projects, Music, Movies, Pictures, iCloud, cloud storage, /Applications)
        ///   3 = other home visible
        ///   2 = home Library visible
        ///   1 = system/root visible
        ///   0 = hidden (dotfile/dotdir anywhere in the path, except `~/.config` and a config dotdir's own files)
        @inline(__always)
        func computePathImportance(_ allBase: UnsafePointer<UInt8>, _ off: Int, _ len: Int, _ bnOff: Int) -> Int32 {
            // `~/.config` is where a lot of what people go looking for actually lives, and it is
            // hidden only by the dot on the directory itself. Skip that one segment when deciding
            // whether the path is hidden; a dot anywhere below it still counts.
            var hiddenScanFrom = 0
            if len > configPrefix.count, allBase[off + configPrefix.count] == 0x2F {
                var ok = true
                var j = 0
                while j < configPrefix.count {
                    if allBase[off + j] != configPrefix[j] {
                        ok = false; break
                    }
                    j &+= 1
                }
                if ok {
                    hiddenScanFrom = configPrefix.count
                }
            }
            let isHidden: Bool = !queryHasDot && {
                if bnOff < len, allBase[off + bnOff] == 0x2E {
                    return true
                }
                var p = hiddenScanFrom
                while p < len {
                    if allBase[off + p] == 0x2F, p + 1 < len, allBase[off + p + 1] == 0x2E {
                        // Only a config dotdir that is the basename's own folder is skipped: the segment from here
                        // to the slash before the basename is then exactly its name.
                        let segLen = bnOff - 2 - p
                        var configParent = false
                        var di = 0
                        while di < configDotdirs.count, !configParent {
                            let name = configDotdirs[di]
                            if name.count == segLen {
                                var j = 0
                                while j < segLen, allBase[off + p + 1 + j] == name[j] {
                                    j &+= 1
                                }
                                configParent = j == segLen
                            }
                            di &+= 1
                        }
                        if !configParent {
                            return true
                        }
                    }
                    p &+= 1
                }
                return false
            }()
            if isHidden {
                return 0
            }
            // Important dirs first.
            var ipi = 0
            while ipi < importantPrefixes.count {
                let pfx = importantPrefixes[ipi]
                if len >= pfx.count {
                    var ok = true
                    var j = 0
                    while j < pfx.count {
                        if allBase[off + j] != pfx[j] {
                            ok = false; break
                        }
                        j &+= 1
                    }
                    if ok {
                        return 4
                    }
                }
                ipi &+= 1
            }
            // Home path: distinguish Library (lower priority) from other home.
            if len >= homePrefixBytes.count, {
                var hp = 0
                while hp < homePrefixBytes.count {
                    if allBase[off + hp] != homePrefixBytes[hp] {
                        return false
                    }
                    hp &+= 1
                }
                return true
            }() {
                var isLib = len >= libraryPrefix.count
                if isLib {
                    var j = 0
                    while j < libraryPrefix.count {
                        if allBase[off + j] != libraryPrefix[j] {
                            isLib = false; break
                        }
                        j &+= 1
                    }
                }
                return isLib ? 2 : 3
            }
            return 1
        }

        // Merge in: query tokens with folderPrefixes parameter
        let allFolderPrefixes: [String]? = {
            let combined = (folderPrefixes ?? []) + inPrefixes
            return combined.isEmpty ? nil : combined
        }()
        // Pre-convert prefixes to lowercased byte arrays (allBytes stores lowercased paths)
        let folderPrefixBytes: [[UInt8]]? = allFolderPrefixes?.map { Array($0.lowercased().utf8) }
        // Match the indexer's segCount convention: 1 + number of slashes (with trailing slashes trimmed),
        // except root "/" which is 1.
        let folderPrefixSegCounts: [Int]? = allFolderPrefixes?.map { p -> Int in
            if p == "/" {
                return 1
            }
            var s = p
            while s.count > 1, s.hasSuffix("/") {
                s.removeLast()
            }
            var n = 1
            for c in s where c == "/" {
                n &+= 1
            }
            return n
        }
        let excludedPrefixBytes: [[UInt8]]? = excludedPrefixes?.map { Array($0.lowercased().utf8) }
        let inAliasPrefixes = inAliases.map { (real: Array(($0.real + "/").utf8), shown: $0.shown + "/") }
        // Home's folder links, except where the query reaches for the folder a link points to: an `in:` at or below
        // it, or around it without also taking in the link (`in:~/Dropbox`, not `in:~`).
        let inFolders = inPrefixes.map { ($0.hasSuffix("/") ? $0 : $0 + "/").lowercased() }
        let linkPrefixes = Self.homeFolderLinks().compactMap { link -> (real: [UInt8], shown: String)? in
            let real = (link.real + "/").lowercased()
            let shown = (link.shown + "/").lowercased()
            if inFolders.contains(where: { $0.hasPrefix(real) || (real.hasPrefix($0) && !shown.hasPrefix($0)) }) {
                return nil
            }
            return (Array((link.real + "/").utf8), link.shown + "/")
        }

        /// A result's path, under the symlinked folder it was asked for or the Home folder link it lies under.
        func shownPath(_ id: Int) -> String {
            let p = path(id)
            for alias in inAliasPrefixes where p.utf8.starts(with: alias.real) {
                return alias.shown + String(decoding: p.utf8.dropFirst(alias.real.count), as: UTF8.self)
            }
            for link in linkPrefixes where p.utf8.starts(with: link.real) {
                return link.shown + String(decoding: p.utf8.dropFirst(link.real.count), as: UTF8.self)
            }
            return p
        }

        @inline(__always) func depthOK(_ i: Int) -> Bool {
            guard let maxD = effectiveMaxDepth else { return true }
            // Default base = 1 (root "/"), so entries directly at root have depth 0
            var base = 1
            if let prefixes = folderPrefixBytes, let segs = folderPrefixSegCounts {
                let off = byteOffsets[i]
                let len = byteLengths[i]
                var pi = 0
                while pi < prefixes.count {
                    let prefix = prefixes[pi]
                    if len >= prefix.count {
                        var ok = true
                        var j = 0
                        while j < prefix.count {
                            if allBytes[off + j] != prefix[j] {
                                ok = false; break
                            }
                            j &+= 1
                        }
                        if ok, segs[pi] > base {
                            base = segs[pi]
                        }
                    }
                    pi &+= 1
                }
            }
            let d = entries[i].segCount - base - 1
            return d <= maxD
        }

        // Phase 1: candidate filter
        let t1 = CFAbsoluteTimeGetCurrent()
        var cands = [Int]()
        cands.reserveCapacity(min(n, 50000))

        // Pre-compute excluded IDs for O(1) integer lookup instead of O(path_len) string hashing
        let excludedIDs: Set<Int>? = if let excl = excludedPaths, !excl.isEmpty {
            Set(excl.compactMap { lookup($0) })
        } else {
            nil
        }

        let isCancelled = cancelled ?? { false }

        /// Dir-segment match (shared by every candidate-filter path). A token "X/" matches a
        /// descendant via the literal substring "X/", AND — the folder-self-match fix — the
        /// directory X itself, whose stored path has no trailing slash (so its last segment
        /// equals X). Without the self-match, "releasenotes/" found files inside ReleaseNotes
        /// but never the folder itself.
        @inline(__always) func dirSegMatches(_ i: Int) -> Bool {
            guard !dirSegments.isEmpty else { return true }
            let off = byteOffsets[i]
            let len = byteLengths[i]
            let isDir = entries[i].isDir
            var si = 0
            while si < dirSegments.count {
                let seg = dirSegments[si]
                let segLen = seg.count
                guard len >= segLen else { return false }
                var found = false
                // Descendant: literal substring "X/" anywhere in the path.
                var p = 0
                let limit = len - segLen
                while p <= limit {
                    var ok = true
                    var j = 0
                    while j < segLen {
                        if allBytes[off + p + j] != seg[j] {
                            ok = false; break
                        }
                        j &+= 1
                    }
                    if ok {
                        found = true; break
                    }
                    p &+= 1
                }
                // Folder-self: a directory whose own last segment equals "X" (drop the trailing '/').
                if !found, isDir {
                    let core = segLen - 1
                    if len >= core {
                        var ok = true
                        var j = 0
                        while j < core {
                            if allBytes[off + len - core + j] != seg[j] {
                                ok = false; break
                            }
                            j &+= 1
                        }
                        if ok {
                            let start = off + len - core
                            if start == off || allBytes[start - 1] == 0x2F {
                                found = true
                            }
                        }
                    }
                }
                if !found {
                    return false
                }
                si &+= 1
            }
            return true
        }

        /// Disjunctive extension test shared by every candidate-filter path: a file matches if its
        /// extID equals ANY queried extension (O(1)), or — for an extension never seen during
        /// indexing (no extID) — its trailing bytes equal ANY such token. The OR is the whole point:
        /// ".json .yaml .xml" should return files that are json OR yaml OR xml, not all three at once.
        @inline(__always) func extensionMatches(_ eid: UInt16, _ off: Int, _ len: Int) -> Bool {
            var ei = 0
            while ei < extTokenIDs.count {
                if eid == extTokenIDs[ei] {
                    return true
                }
                ei &+= 1
            }
            var ui = 0
            while ui < extUnknownBytes.count {
                let ext = extUnknownBytes[ui]
                if len >= ext.count {
                    var m = true
                    var j = 0
                    while j < ext.count {
                        if allBytes[off + len - ext.count + j] != ext[j] {
                            m = false; break
                        }
                        j &+= 1
                    }
                    if m {
                        return true
                    }
                }
                ui &+= 1
            }
            return false
        }

        /// Common filter: mask, extension ID, excluded IDs/prefixes
        @inline(__always) func applyBaseFilters(_ i: Int) -> Bool {
            if hasFuzzyQuery, masks[i] & combinedMask != combinedMask {
                return false
            }
            if !hasFuzzyQuery, masks[i] == 0 {
                return false
            }

            if let excl = excludedIDs, excl.contains(i) {
                return false
            }

            let off = byteOffsets[i]
            let len = byteLengths[i]

            // Extension filter (disjunctive): reject unless the entry matches ANY queried extension.
            if hasExtFilter, !extensionMatches(extIDs[i], off, len) {
                return false
            }

            if let prefixes = excludedPrefixBytes {
                var pi = 0
                while pi < prefixes.count {
                    let prefix = prefixes[pi]
                    if len >= prefix.count {
                        var ok = true
                        var j = 0
                        while j < prefix.count {
                            if allBytes[off + j] != prefix[j] {
                                ok = false; break
                            }
                            j &+= 1
                        }
                        if ok {
                            return false
                        }
                    }
                    pi &+= 1
                }
            }

            // Dir segment match (descendant substring + folder-self), shared helper.
            if !dirSegMatches(i) {
                return false
            }

            return true
        }

        /// Full filter: base + dirsOnly + suffix (skipped when candidatePool already pre-filtered these)
        @inline(__always) func applyAllFilters(_ i: Int) -> Bool {
            guard applyBaseFilters(i) else { return false }

            if dirsOnly, !entries[i].isDir {
                return false
            }

            if let sfx = suffixBytes {
                let off = byteOffsets[i]
                let len = byteLengths[i]
                if len < sfx.count {
                    return false
                }
                var match = true
                var j = 0
                while j < sfx.count {
                    if allBytes[off + len - sfx.count + j] != sfx[j] {
                        match = false; break
                    }
                    j &+= 1
                }
                if !match {
                    return false
                }
            }

            return true
        }

        // Byte-level folder prefix check (shared by candidatePool and full scan paths)
        // A path is "inside" a folder prefix only if it is a STRICT descendant: it starts with the
        // prefix AND has a path separator right after it. This excludes the folder itself (so
        // `in:~/Foo` returns only the contents, not Foo) and excludes prefix-siblings (so `in:~/Foo`
        // doesn't match ~/Foobar). The folder prefixes are stored without a trailing slash (root "/"
        // being the sole exception, which already ends in '/').
        @inline(__always) func strictlyInside(_ off: Int, _ len: Int, _ prefix: [UInt8]) -> Bool {
            let pc = prefix.count
            guard pc > 0, len > pc else { return false }
            var j = 0
            while j < pc {
                if allBytes[off + j] != prefix[j] {
                    return false
                }
                j &+= 1
            }
            if prefix[pc - 1] == 0x2F {
                return true
            }
            return allBytes[off + pc] == 0x2F
        }

        @inline(__always) func matchesFolderPrefix(_ i: Int) -> Bool {
            guard let prefixes = folderPrefixBytes else { return true }
            let off = byteOffsets[i]
            let len = byteLengths[i]
            var pi = 0
            while pi < prefixes.count {
                if strictlyInside(off, len, prefixes[pi]) {
                    return true
                }
                pi &+= 1
            }
            return false
        }

        /// Operator pass: positive literal/anchor terms (required) + negation/files-only
        /// (reject). Run once over the assembled candidate list so every filter path
        /// (full-scan, sorted-prefix, QuickFilter pool) honors it uniformly. `allBase` is the
        /// start of the shared lowercased byte buffer; valid for the lock's duration.
        /// Match an operator needle in either normalization form (NFD primary, NFC fallback).
        @inline(__always) func containsOp(_ pathPtr: UnsafePointer<UInt8>, _ len: Int, _ n: OpNeedle) -> Bool {
            if n.nfd.withUnsafeBufferPointer({ simdContains(pathPtr, count: len, needle: $0.baseAddress!, needleLen: $0.count) }) {
                return true
            }
            guard let alt = n.nfc else { return false }
            return alt.withUnsafeBufferPointer { simdContains(pathPtr, count: len, needle: $0.baseAddress!, needleLen: $0.count) }
        }
        @inline(__always) func nameEndsOp(_ allBase: UnsafePointer<UInt8>, _ off: Int, _ len: Int, _ bnStart: Int, _ n: OpNeedle) -> Bool {
            if n.nfd.withUnsafeBufferPointer({ nameEndsWith(allBase, off: off, len: len, bnStart: bnStart, needle: $0.baseAddress!, needleLen: $0.count) }) {
                return true
            }
            guard let alt = n.nfc else { return false }
            return alt.withUnsafeBufferPointer { nameEndsWith(allBase, off: off, len: len, bnStart: bnStart, needle: $0.baseAddress!, needleLen: $0.count) }
        }

        @inline(__always) func passesOperators(_ i: Int, _ allBase: UnsafePointer<UInt8>) -> Bool {
            let off = byteOffsets[i]
            let len = byteLengths[i]
            let e = entries[i]
            if filesOnly, e.isDir {
                return false
            }
            let pathPtr = allBase + off

            var k = 0
            while k < litSubstrings.count {
                if !containsOp(pathPtr, len, litSubstrings[k]) {
                    return false
                }
                k &+= 1
            }
            k = 0
            while k < anchorStarts.count {
                if !containsOp(pathPtr, len, anchorStarts[k]) {
                    return false
                }
                k &+= 1
            }
            k = 0
            while k < anchorEnds.count {
                if !nameEndsOp(allBase, off, len, e.bnStart, anchorEnds[k]) {
                    return false
                }
                k &+= 1
            }

            if !negExtIDs.isEmpty {
                let eid = extIDs[i]
                var ni = 0
                while ni < negExtIDs.count {
                    if eid == negExtIDs[ni] {
                        return false
                    }; ni &+= 1
                }
            }
            if !negExtUnknownBytes.isEmpty {
                var ni = 0
                while ni < negExtUnknownBytes.count {
                    let ext = negExtUnknownBytes[ni]
                    if len >= ext.count {
                        var match = true
                        var j = 0
                        while j < ext.count {
                            if allBase[off + len - ext.count + j] != ext[j] {
                                match = false; break
                            }; j &+= 1
                        }
                        if match {
                            return false
                        }
                    }
                    ni &+= 1
                }
            }
            k = 0
            while k < negSubstrings.count {
                if masks[i] & negSubMasks[k] == negSubMasks[k], containsOp(pathPtr, len, negSubstrings[k]) {
                    return false
                }
                k &+= 1
            }
            k = 0
            while k < negAnchorStarts.count {
                if masks[i] & negAnchorStartMasks[k] == negAnchorStartMasks[k], containsOp(pathPtr, len, negAnchorStarts[k]) {
                    return false
                }
                k &+= 1
            }
            k = 0
            while k < negAnchorEnds.count {
                if nameEndsOp(allBase, off, len, e.bnStart, negAnchorEnds[k]) {
                    return false
                }
                k &+= 1
            }
            return true
        }

        if let pool = candidatePool {
            // Pre-filtered candidate pool (from QuickFilter prefilter)
            // suffix/dirsOnly already applied, also apply folder prefix + mask + excluded
            //
            // The pool is a snapshot of entry indices captured by prefilter() against the engine
            // as it was then. A reindex/reload since then (clear() or loadBinaryIndex()) can have
            // replaced the parallel arrays with a shorter set, leaving stale indices that now point
            // past the end. All parallel arrays are length n under the lock, so n is the authoritative
            // bound: skip anything out of range rather than trapping on masks[i]/byteOffsets[i]/etc.
            var pi = 0
            while pi < pool.count {
                let i = pool[pi]
                if i >= 0, i < n, applyBaseFilters(i), matchesFolderPrefix(i), depthOK(i) {
                    cands.append(i)
                }
                pi &+= 1
            }
        } else if let prefixBytes = folderPrefixBytes, let sorted = sortedByPath {
            // Fast path: O(log n + k) prefix lookup via sorted index (built lazily)
            var pxi = 0
            while pxi < prefixBytes.count {
                let prefix = prefixBytes[pxi]
                let lo = sortedLowerBound(prefix, sorted: sorted)
                let hi = sortedUpperBound(prefix, sorted: sorted, from: lo)
                var idx = lo
                while idx < hi {
                    let i = sorted[idx]
                    // The [lo, hi) range matches the prefix loosely (includes the folder itself and
                    // prefix-siblings); strictlyInside keeps only true descendants.
                    if strictlyInside(byteOffsets[i], byteLengths[i], prefix), applyAllFilters(i), depthOK(i) {
                        cands.append(i)
                    }
                    idx &+= 1
                }
                pxi &+= 1
            }
        } else {
            // Parallel full scan across CPU cores
            let filterProcs = max(ProcessInfo.processInfo.activeProcessorCount, 1)
            let filterChunkSize = (n + filterProcs - 1) / filterProcs
            let filterChunks = (n + filterChunkSize - 1) / filterChunkSize
            let candStore = UnsafeMutablePointer<ScratchBuffer<Int>?>.allocate(capacity: max(filterChunks, 1))
            candStore.initialize(repeating: nil, count: max(filterChunks, 1))
            defer {
                for ci in 0 ..< max(filterChunks, 1) {
                    candStore[ci]?.release()
                }
                candStore.deinitialize(count: max(filterChunks, 1))
                candStore.deallocate()
            }

            masks.withUnsafeBufferPointer { maskBuf in
                let maskPtr = maskBuf.baseAddress!
                DispatchQueue.concurrentPerform(iterations: filterChunks) { chunk in
                    let lo = chunk * filterChunkSize
                    let hi = min(lo + filterChunkSize, n)
                    var local = ScratchBuffer<Int>(capacity: hi - lo)

                    var i = lo
                    while i < hi {
                        if hasFuzzyQuery {
                            if maskPtr[i] & combinedMask != combinedMask {
                                i &+= 1; continue
                            }
                        } else {
                            if maskPtr[i] == 0 {
                                i &+= 1; continue
                            }
                        }
                        if let excl = excludedIDs, excl.contains(i) {
                            i &+= 1; continue
                        }

                        let off = byteOffsets[i]
                        let len = byteLengths[i]

                        // Extension filter (disjunctive): keep only entries matching ANY queried extension.
                        if hasExtFilter, !extensionMatches(self.extIDs[i], off, len) {
                            i &+= 1; continue
                        }

                        if let prefixes = folderPrefixBytes {
                            var matched = false
                            var pi = 0
                            while pi < prefixes.count {
                                if strictlyInside(off, len, prefixes[pi]) {
                                    matched = true; break
                                }
                                pi &+= 1
                            }
                            if !matched {
                                i &+= 1; continue
                            }
                        }

                        if let prefixes = excludedPrefixBytes {
                            var excluded = false
                            var pi = 0
                            while pi < prefixes.count {
                                let prefix = prefixes[pi]
                                if len >= prefix.count {
                                    var ok = true
                                    var j = 0
                                    while j < prefix.count {
                                        if allBytes[off + j] != prefix[j] {
                                            ok = false; break
                                        }
                                        j &+= 1
                                    }
                                    if ok {
                                        excluded = true; break
                                    }
                                }
                                pi &+= 1
                            }
                            if excluded {
                                i &+= 1; continue
                            }
                        }

                        if dirsOnly, !entries[i].isDir {
                            i &+= 1; continue
                        }

                        if let sfx = suffixBytes {
                            if len < sfx.count {
                                i &+= 1; continue
                            }
                            var match = true
                            var j = 0
                            while j < sfx.count {
                                if allBytes[off + len - sfx.count + j] != sfx[j] {
                                    match = false; break
                                }
                                j &+= 1
                            }
                            if !match {
                                i &+= 1; continue
                            }
                        }

                        // Dir segment match (descendant substring + folder-self), shared helper.
                        if !dirSegMatches(i) {
                            i &+= 1; continue
                        }

                        if !depthOK(i) {
                            i &+= 1; continue
                        }

                        local.append(i)
                        i &+= 1
                    }
                    candStore[chunk] = local
                }
            }

            // Merge chunk results
            var total = 0
            for ci in 0 ..< filterChunks {
                total &+= candStore[ci]?.count ?? 0
            }
            cands.reserveCapacity(total)
            for ci in 0 ..< filterChunks {
                if let local = candStore[ci] {
                    cands.append(contentsOf: local.buffer)
                }
            }
        }
        // Apply fzf-style operators (negation, literal, anchors, files-only) in one SIMD pass
        // over the assembled candidate list. Positive operator letters are already in
        // combinedMask, so most non-matches were pruned upstream; this confirms substrings and
        // rejects negated matches before scoring and before the extension-only fast path.
        if hasOperators, !cands.isEmpty {
            allBytes.withUnsafeBufferPointer { buf in
                let allBase = buf.baseAddress!
                cands = cands.filter { passesOperators($0, allBase) }
            }
        }
        // Trigger lazy build of sorted path index for next folder-filtered search
        if folderPrefixBytes != nil, sortedByPath == nil {
            DispatchQueue.global(qos: .utility).async { [self] in buildSortedPathIndex() }
        }
        let filterMs = (CFAbsoluteTimeGetCurrent() - t1) * 1000
        if cands.count > 200_000 {
            // A candidate whose BASENAME carries every query letter is where exact, prefix and
            // basename matches come from, so it is exempt from the length cull. Without the
            // exemption a perfect hit is dropped for being deep: ".../idlelib/searchengine.py"
            // (123 bytes) for query "searchengine" sits far past the ~77 byte cutoff a 1.5M entry
            // scope produces, while weak subsequence matches survive purely by having shorter
            // paths. Needs a real fuzzy body, since baseMask == 0 (extension-only query) would
            // exempt every candidate and defeat the cap.
            //
            // The counting sort and the exempt tally share one pass: each candidate costs a random
            // read of byteLengths/bnMasks, so walking the list twice to count them separately
            // doubled the cost of a broad query.
            let maxPathLen = 4096
            let lenCounts = UnsafeMutablePointer<Int>.allocate(capacity: maxPathLen * 2)
            lenCounts.initialize(repeating: 0, count: maxPathLen * 2)
            let exemptLenCounts = lenCounts + maxPathLen
            let splitExempt = baseMask != 0
            var exemptCount = 0
            var ci = 0
            while ci < cands.count {
                let id = cands[ci]
                let l = min(byteLengths[id], maxPathLen - 1)
                if splitExempt, bnMasks[id] & baseMask == baseMask {
                    exemptCount &+= 1; exemptLenCounts[l] &+= 1
                } else {
                    lenCounts[l] &+= 1
                }
                ci &+= 1
            }
            // A one or two character query matches nearly every basename. If the exempt set alone
            // blows the budget, fold it back in and length-cull everything as before.
            let exemptActive = exemptCount > 0 && exemptCount < 200_000
            if !exemptActive, exemptCount > 0 {
                var mi = 0
                while mi < maxPathLen {
                    lenCounts[mi] &+= exemptLenCounts[mi]; mi &+= 1
                }
                exemptCount = 0
            }
            // Exempt entries are long by construction (that is why the cull was dropping them) and
            // scoring cost scales with path length, so an unbounded exemption makes a common-letter
            // query like "readme" (116k exempt) roughly twice as slow. Cap it: the shortest
            // exemptCap of them are kept, which covers the handful of deep exact matches a specific
            // query produces while bounding the extra work a vague one can buy.
            let exemptCap = 50000
            var exemptCutoff = maxPathLen - 1
            if exemptActive, exemptCount > exemptCap {
                var ecumul = 0
                var eli = 0
                while eli < maxPathLen {
                    ecumul &+= exemptLenCounts[eli]
                    if ecumul >= exemptCap {
                        exemptCutoff = eli; break
                    }
                    eli &+= 1
                }
                exemptCount = ecumul
            }
            let budget = 200_000 - exemptCount

            var cumul = 0, cutoff = maxPathLen - 1
            var li = 0
            while li < maxPathLen {
                cumul &+= lenCounts[li]
                if cumul >= budget {
                    cutoff = li; break
                }
                li &+= 1
            }
            lenCounts.deallocate()
            // Keep ALL entries at or below cutoff length (don't bias by entry order), plus every
            // exempt entry regardless of how long its path is.
            var filtered = [Int]()
            filtered.reserveCapacity(cumul + exemptCount)
            ci = 0
            while ci < cands.count {
                let id = cands[ci]
                if byteLengths[id] <= cutoff
                    || (exemptActive && byteLengths[id] <= exemptCutoff && bnMasks[id] & baseMask == baseMask)
                {
                    filtered.append(id)
                }
                ci &+= 1
            }
            cands = filtered
        }

        if qBytes.isEmpty, dirSegments.isEmpty {
            // Extension-only filter: keep only entries matching the extension
            if !extTokenBytes.isEmpty {
                var extFiltered = [Int]()
                extFiltered.reserveCapacity(cands.count / 10)
                var ci = 0
                while ci < cands.count {
                    let id = cands[ci]
                    if extensionMatches(extIDs[id], byteOffsets[id], byteLengths[id]) {
                        extFiltered.append(id)
                    }
                    ci &+= 1
                }
                cands = extFiltered
            }

            // Rank: important locations first (so user media beats shallow system/app noise),
            // then shallower paths, then shorter paths. Importance is precomputed once per
            // candidate and also written into each SearchResult, so the cross-engine merge's
            // re-sort by rank preserves this ordering instead of collapsing everything to rank 0.
            var imp = [Int32](repeating: 1, count: cands.count)
            allBytes.withUnsafeBufferPointer { buf in
                let allBase = buf.baseAddress!
                var ci = 0
                while ci < cands.count {
                    let id = cands[ci]
                    imp[ci] = computePathImportance(allBase, byteOffsets[id], byteLengths[id], entries[id].bnStart)
                    ci &+= 1
                }
            }
            // Sort an index permutation so `imp` stays aligned with its candidate.
            var order = Array(0 ..< cands.count)
            order.sort { x, y in
                if imp[x] != imp[y] {
                    return imp[x] > imp[y]
                }
                let aSeg = entries[cands[x]].segCount, bSeg = entries[cands[y]].segCount
                if aSeg != bSeg {
                    return aSeg < bSeg
                }
                return byteLengths[cands[x]] < byteLengths[cands[y]]
            }
            let results = order.prefix(maxResults).map { oi -> SearchResult in
                let id = cands[oi]
                let e = entries[id]
                return SearchResult(path: shownPath(id), isDir: e.isDir, score: 0, quality: 0, hasBase: false, segmentMatches: 0, pathImportance: Int(imp[oi]), prefixMatch: false, depth: e.segCount)
            }
            let totalMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            slog.debug("search: q=\"\(query)\" \(n) entries, \(cands.count) cands, \(results.count) results in \(totalMs, format: .fixed(precision: 1))ms (filter=\(filterMs, format: .fixed(precision: 1))ms)")
            return results
        }

        // Phase 2: fuzzy scoring
        let t2 = CFAbsoluteTimeGetCurrent()
        if isCancelled() {
            return []
        }

        let nCands = cands.count
        let nProcs = max(ProcessInfo.processInfo.activeProcessorCount, 1)
        let chunkSize = max(nCands / nProcs, 512)
        let nChunks = nCands == 0 ? 0 : (nCands + chunkSize - 1) / chunkSize
        let chunkStore = UnsafeMutablePointer<ScratchBuffer<ScoredEntry>?>.allocate(capacity: max(nChunks, 1))
        chunkStore.initialize(repeating: nil, count: max(nChunks, 1))
        defer {
            for ci in 0 ..< max(nChunks, 1) {
                chunkStore[ci]?.release()
            }
            chunkStore.deinitialize(count: max(nChunks, 1))
            chunkStore.deallocate()
        }

        allBytes.withUnsafeBufferPointer { allBuf in
            let allBase = allBuf.baseAddress!

            qBytes.withUnsafeBufferPointer { qBuf in
                baseBytes.withUnsafeBufferPointer { baseBuf in
                    DispatchQueue.concurrentPerform(iterations: nChunks) { chunk in
                        let lo = chunk * chunkSize
                        let hi = min(lo + chunkSize, nCands)
                        var local = ScratchBuffer<ScoredEntry>(capacity: hi - lo)
                        // Scratch for the reordered token pass, allocated per chunk rather than per
                        // candidate so the scoring loop stays allocation-free.
                        let tokenCount = tokenBytes?.count ?? 0
                        var tokenPos = [Int](repeating: 0, count: tokenCount)
                        var tokenOrder = [Int](repeating: 0, count: tokenCount)
                        var idx = lo
                        while idx < hi {
                            if idx & 0x1FF == 0, isCancelled() {
                                break
                            }
                            let id = cands[idx]
                            let e = self.entries[id]
                            let off = self.byteOffsets[id]
                            let len = self.byteLengths[id]
                            let bnOff = e.bnStart

                            var baseScore = Int.min, baseWindow = 0
                            var pathScore = Int.min, pathWindow = 0
                            var segMatches = 0
                            let hasBase: Bool
                            let hasPath: Bool

                            if qBuf.count > 0 {
                                let bnBuf = UnsafeBufferPointer(start: allBase + off + bnOff, count: len - bnOff)
                                let bnBounds = self.bnBoundaries[id]
                                if self.bnMasks[id] & baseMask == baseMask {
                                    if let r = fuzzyScoreBytes(baseBuf, bnBuf, boundaries: bnBounds) {
                                        baseScore = r.score; baseWindow = r.end - r.start
                                    }
                                }

                                let pathBuf = UnsafeBufferPointer(start: allBase + off, count: len)
                                if let r = fuzzyScoreBytes(qBuf, pathBuf, boundaries: bnBounds, boundariesOffset: bnOff) {
                                    pathScore = r.score; pathWindow = r.end - r.start
                                }

                                // Multi-token independent scoring: score each token separately against
                                // non-overlapping regions. Each token must match after the previous token's
                                // match end, so "prv sky" matches "PrivateFrameworks/SkyLight" but each
                                // token occupies a distinct path segment.
                                if let tokens = tokenBytes {
                                    var tokenPathScore = 0, tokenPathStart = Int.max, tokenPathEnd = 0
                                    var allTokensMatchPath = true
                                    var pathSearchFrom = 0
                                    var tokenSegMatches = 0
                                    // Terms get added in the order they occur to the person typing,
                                    // which need not be the order the path stores them in: someone
                                    // narrowing `bkgprvpng` to one project types `bkgprvpng vacation`,
                                    // and the path spells it `Vacation/.../background-preview.png`.
                                    // Attempt 0 walks the tokens as typed; on failure, attempt 1
                                    // places each token independently and walks them in the order
                                    // the path actually puts them in. Only a query that would have
                                    // found nothing pays for the second pass.
                                    var attempt = 0
                                    while attempt < 2 {
                                        if attempt == 0 {
                                            for i in 0 ..< tokens.count {
                                                tokenOrder[i] = i
                                            }
                                        } else {
                                            let whole = UnsafeBufferPointer(start: allBase + off, count: len)
                                            var placed = true
                                            for (ti, token) in tokens.enumerated() {
                                                var pr = token.withUnsafeBufferPointer {
                                                    fuzzyScoreBytes($0, whole, boundaries: bnBounds, boundariesOffset: bnOff)
                                                }
                                                if pr == nil, let alt = tokenAltBytes[ti] {
                                                    pr = alt.withUnsafeBufferPointer {
                                                        fuzzyScoreBytes($0, whole, boundaries: bnBounds, boundariesOffset: bnOff)
                                                    }
                                                }
                                                guard let pr else { placed = false; break }
                                                tokenPos[ti] = pr.start
                                                tokenOrder[ti] = ti
                                            }
                                            // A token that matches nowhere on its own can't be
                                            // rescued by reordering.
                                            guard placed else { break }
                                            // Insertion sort: a query is a handful of tokens.
                                            var si = 1
                                            while si < tokens.count {
                                                let v = tokenOrder[si]
                                                var sj = si - 1
                                                while sj >= 0, tokenPos[tokenOrder[sj]] > tokenPos[v] {
                                                    tokenOrder[sj + 1] = tokenOrder[sj]; sj &-= 1
                                                }
                                                tokenOrder[sj + 1] = v; si &+= 1
                                            }
                                        }
                                        tokenPathScore = 0; tokenPathStart = Int.max; tokenPathEnd = 0
                                        allTokensMatchPath = true; pathSearchFrom = 0; tokenSegMatches = 0

                                        for oi in 0 ..< tokens.count {
                                            let ti = tokenOrder[oi]
                                            let token = tokens[ti]
                                            guard allTokensMatchPath, pathSearchFrom < len else {
                                                allTokensMatchPath = false; break
                                            }
                                            let slice = UnsafeBufferPointer(start: allBase + off + pathSearchFrom, count: len - pathSearchFrom)
                                            // May go negative once pathSearchFrom passes bnOff: bpos = i - boff
                                            // must stay basename-relative, and fuzzyScoreBytes guards 0..<64.
                                            let boff = bnOff - pathSearchFrom
                                            var r = token.withUnsafeBufferPointer {
                                                fuzzyScoreBytes($0, slice, boundaries: bnBounds, boundariesOffset: boff)
                                            }
                                            // NFC fallback: the stored path may be in the other normalization form.
                                            // Scale the score up to the NFD byte length so NFC-stored paths rank
                                            // on the same scale as NFD-stored twins (NFD hangul is ~2x the bytes).
                                            if r == nil, let alt = tokenAltBytes[ti] {
                                                r = alt.withUnsafeBufferPointer {
                                                    fuzzyScoreBytes($0, slice, boundaries: bnBounds, boundariesOffset: boff)
                                                }
                                                if let rr = r, !alt.isEmpty {
                                                    r = (rr.score * token.count / alt.count, rr.start, rr.end)
                                                }
                                            }
                                            if let r {
                                                tokenPathScore &+= r.score
                                                let absStart = pathSearchFrom + r.start
                                                let absEnd = pathSearchFrom + r.end
                                                tokenPathStart = min(tokenPathStart, absStart)
                                                tokenPathEnd = max(tokenPathEnd, absEnd)
                                                // Check if match starts at a segment boundary (after / or start of path).
                                                // A hidden folder's name starts after its dot: `ssh` names `/.ssh`.
                                                if absStart == 0 || allBase[off + absStart - 1] == 0x2F
                                                    || (absStart >= 2 && allBase[off + absStart - 1] == 0x2E && allBase[off + absStart - 2] == 0x2F)
                                                {
                                                    tokenSegMatches &+= 1
                                                }
                                                pathSearchFrom = absEnd
                                            } else {
                                                allTokensMatchPath = false; break
                                            }
                                        }
                                        if allTokensMatchPath {
                                            break
                                        }
                                        attempt &+= 1
                                    }
                                    if allTokensMatchPath, tokenPathScore > pathScore {
                                        pathScore = tokenPathScore; pathWindow = tokenPathEnd - tokenPathStart
                                        segMatches = tokenSegMatches
                                    }

                                    var tokenBaseScore = 0, tokenBaseStart = Int.max, tokenBaseEnd = 0
                                    var allTokensMatchBase = true
                                    var baseSearchFrom = 0
                                    let bnLen = len - bnOff
                                    for (ti, token) in tokens.enumerated() {
                                        guard allTokensMatchBase, baseSearchFrom < bnLen else {
                                            allTokensMatchBase = false; break
                                        }
                                        let slice = UnsafeBufferPointer(start: allBase + off + bnOff + baseSearchFrom, count: bnLen - baseSearchFrom)
                                        // Slice byte i is basename byte i + baseSearchFrom, so the offset is
                                        // negative: bpos = i - (-baseSearchFrom) = i + baseSearchFrom.
                                        var r = token.withUnsafeBufferPointer {
                                            fuzzyScoreBytes($0, slice, boundaries: bnBounds, boundariesOffset: -baseSearchFrom)
                                        }
                                        if r == nil, let alt = tokenAltBytes[ti] {
                                            r = alt.withUnsafeBufferPointer {
                                                fuzzyScoreBytes($0, slice, boundaries: bnBounds, boundariesOffset: -baseSearchFrom)
                                            }
                                            if let rr = r, !alt.isEmpty {
                                                r = (rr.score * token.count / alt.count, rr.start, rr.end)
                                            }
                                        }
                                        if let r {
                                            tokenBaseScore &+= r.score
                                            tokenBaseStart = min(tokenBaseStart, baseSearchFrom + r.start)
                                            tokenBaseEnd = max(tokenBaseEnd, baseSearchFrom + r.end)
                                            baseSearchFrom = baseSearchFrom + r.end
                                        } else {
                                            allTokensMatchBase = false; break
                                        }
                                    }
                                    if allTokensMatchBase, tokenBaseScore > baseScore {
                                        baseScore = tokenBaseScore; baseWindow = tokenBaseEnd - tokenBaseStart
                                    }
                                }

                                // NFC fallback for Unicode paths that differ in normalization
                                if baseScore == Int.min, pathScore == Int.min, let altQ = qAltBytes, let altBase = baseAltBytes {
                                    altQ.withUnsafeBufferPointer { altQBuf in
                                        altBase.withUnsafeBufferPointer { altBaseBuf in
                                            // Same NFD-scale normalization as the per-token fallback above.
                                            if let r = fuzzyScoreBytes(altBaseBuf, bnBuf, boundaries: bnBounds) {
                                                baseScore = r.score * baseBytes.count / altBase.count; baseWindow = r.end - r.start
                                            }
                                            if let r = fuzzyScoreBytes(altQBuf, pathBuf, boundaries: bnBounds, boundariesOffset: bnOff) {
                                                pathScore = r.score * qBytes.count / altQ.count; pathWindow = r.end - r.start
                                            }
                                        }
                                    }
                                }

                                hasBase = baseScore > Int.min
                                hasPath = pathScore > Int.min
                                guard hasBase || hasPath else { idx &+= 1; continue }
                            } else if !dirSegments.isEmpty {
                                // Dir-segment-only query: score based on path brevity
                                // (dir segment already verified as literal match in candidate filter)
                                let dirSegLen = dirSegments.reduce(0) { $0 + $1.count }
                                pathScore = dirSegLen * 16 // scoreMatch per char
                                pathWindow = len
                                hasBase = false
                                hasPath = true
                            } else {
                                // Extension-only query: no fuzzy match needed
                                hasBase = false
                                hasPath = false
                            }

                            let sHasBase = Int32(hasSlash ? 0 : (hasBase ? 1 : 0))

                            // Path importance (see computePathImportance, defined above): lifts
                            // user/media dirs above system noise; hidden paths sink to 0.
                            let sPathImportance = computePathImportance(allBase, off, len, bnOff)

                            // Prefix/extension match
                            let sPrefixMatch: Int32
                            let bnLen = len - e.bnStart

                            // Check extension tokens against entry's extension ID (O(1)) or fallback to byte suffix
                            var extOK = false
                            if !extTokenIDs.isEmpty {
                                let eid = self.extIDs[id]
                                var ei = 0
                                while ei < extTokenIDs.count {
                                    if eid == extTokenIDs[ei] {
                                        extOK = true; break
                                    }
                                    ei &+= 1
                                }
                            } else if !extTokenBytes.isEmpty {
                                var ei = 0
                                while ei < extTokenBytes.count {
                                    let ext = extTokenBytes[ei]
                                    if bnLen >= ext.count {
                                        var match = true
                                        var p = 0
                                        while p < ext.count {
                                            if allBase[off + e.bnStart + bnLen - ext.count + p] != ext[p] {
                                                match = false; break
                                            }
                                            p &+= 1
                                        }
                                        if match {
                                            extOK = true; break
                                        }
                                    }
                                    ei &+= 1
                                }
                            }

                            if let tokens = tokenBytes, hasBase {
                                // Multi-token: check each token as literal substring at word boundaries in basename
                                let bnBase = off + e.bnStart
                                var tokenBoundaryCount = 0
                                var ti = 0
                                while ti < tokens.count {
                                    let token = tokens[ti]
                                    let tLen = token.count
                                    guard tLen <= bnLen else { ti &+= 1; continue }
                                    var found = false
                                    // Check prefix: basename starts with this token
                                    var p = 0
                                    var prefixOK = true
                                    while p < tLen {
                                        if allBase[bnBase + p] != token[p] {
                                            prefixOK = false; break
                                        }
                                        p &+= 1
                                    }
                                    if prefixOK {
                                        found = true
                                    }
                                    if !found {
                                        // Check after each word boundary (space, dash, underscore, dot, slash)
                                        var bi = 1
                                        while bi + tLen <= bnLen {
                                            let prev = allBase[bnBase + bi - 1]
                                            if prev == 0x20 || prev == 0x2D || prev == 0x5F || prev == 0x2E || prev == 0x2F {
                                                var ok = true; p = 0
                                                while p < tLen {
                                                    if allBase[bnBase + bi + p] != token[p] {
                                                        ok = false; break
                                                    }
                                                    p &+= 1
                                                }
                                                if ok {
                                                    found = true; break
                                                }
                                            }
                                            bi &+= 1
                                        }
                                    }
                                    if found {
                                        tokenBoundaryCount &+= 1
                                    }
                                    ti &+= 1
                                }
                                if tokenBoundaryCount == tokens.count || extOK {
                                    sPrefixMatch = 2
                                } else if tokenBoundaryCount > 0 {
                                    sPrefixMatch = 1
                                } else {
                                    sPrefixMatch = 0
                                }
                                segMatches = max(segMatches, tokenBoundaryCount)
                            } else if hasBase, baseBytes.count <= bnLen {
                                let bnBase = off + e.bnStart
                                // Check prefix: basename starts with query
                                var prefixOK = true
                                var p = 0
                                while p < baseBytes.count {
                                    if allBase[bnBase + p] != baseBytes[p] {
                                        prefixOK = false; break
                                    }
                                    p &+= 1
                                }
                                if prefixOK || extOK {
                                    sPrefixMatch = 2
                                } else {
                                    // Check word-boundary: query matches right after a delimiter (- _ . /) in basename
                                    var boundaryMatch = false
                                    var bi = 1
                                    while bi + baseBytes.count <= bnLen {
                                        let prev = allBase[bnBase + bi - 1]
                                        if prev == 0x2D || prev == 0x5F || prev == 0x2E || prev == 0x2F || prev == 0x20 {
                                            var ok = true; p = 0
                                            while p < baseBytes.count {
                                                if allBase[bnBase + bi + p] != baseBytes[p] {
                                                    ok = false; break
                                                }
                                                p &+= 1
                                            }
                                            if ok {
                                                boundaryMatch = true; break
                                            }
                                        }
                                        bi &+= 1
                                    }
                                    sPrefixMatch = boundaryMatch ? 1 : 0
                                }
                            } else {
                                sPrefixMatch = extOK ? 2 : 0
                            }

                            let tight = hasBase ? baseWindow : pathWindow
                            // Penalize unmatched basename bytes so tight matches in short
                            // basenames (e.g. "mkfl" → "Makefile") beat sparse matches in
                            // long camelCase basenames (e.g. "...MaskForLocal...").
                            let basenameWaste = hasBase ? max(0, bnLen - baseWindow) : 0
                            let adjBaseScore = baseScore &- basenameWaste &* SC.basenameWastePenalty
                            let sTight = Int32(-tight)
                            let sBase = Int32(hasBase ? adjBaseScore : -1000)
                            let sPath = Int32(hasPath ? pathScore : -1000)
                            let sDir = Int32(wantDir ? (e.isDir ? 100 : -100) : 0)
                            let sDepth = Int32(-e.segCount)
                            let sShorter = Int32(-len)

                            // When hasBase, pathScore for a non-slash query usually matches the
                            // same characters in the basename, so taking max() with raw pathScore
                            // would discard the waste penalty. Prefer adjBaseScore in that case.
                            let best = hasBase ? adjBaseScore : (hasPath ? pathScore : 0)
                            let queryLen = !qBytes.isEmpty ? qBytes.count : dirSegments.reduce(0) { $0 + $1.count }
                            let qual: Int = if hasBase {
                                adjBaseScore * baseBytes.count / max(baseWindow, 1)
                            } else if tokenBytes != nil {
                                // Multi-token: use score directly since window spans across segments
                                pathScore
                            } else {
                                pathScore * queryLen / max(pathWindow, 1)
                            }

                            let key = SortKey(
                                a: sHasBase,
                                b: sPrefixMatch,
                                c: sPathImportance,
                                d: sBase,
                                e: sTight,
                                f: sPath,
                                g: sDir,
                                h: sDepth,
                                i: sShorter
                            )
                            local.append(ScoredEntry(
                                id: id,
                                key: key,
                                bestScore: best,
                                quality: qual,
                                hasBase: hasBase,
                                segmentMatches: segMatches
                            ))
                            idx &+= 1
                        }
                        chunkStore[chunk] = local
                    }
                }
            }
        }
        let scoreMs = (CFAbsoluteTimeGetCurrent() - t2) * 1000
        var totalScored = 0
        for i in 0 ..< nChunks {
            totalScored &+= chunkStore[i]?.count ?? 0
        }

        if isCancelled() {
            return []
        }

        // The pool is the first maxResults * 4 of all scored entries in key order, ties in chunk then id order (what a
        // stable sort of the chunks one after another gives), after a quality floor set by the top entry. Each chunk
        // filters and sorts its own entries in place and only its first pool-size reach the final sort, instead of
        // copying every scored entry into one array (twice, with the floor) and sorting it all.
        let t3 = CFAbsoluteTimeGetCurrent()
        let poolSize = maxResults * 4
        var top: ScoredEntry?
        for ci in 0 ..< nChunks {
            guard let local = chunkStore[ci] else { continue }
            for e in local.buffer where top == nil || e.key < top!.key {
                top = e
            }
        }
        var pool: [ScoredEntry] = []
        if let top {
            let minQ = max(top.quality * 4 / 10, qBytes.count * scoreMatch / 2)
            // Basename matches are exempt from the density floor (like FuzzyClient.mergeResults):
            // an NFC-stored CJK basename match scores on the smaller NFC byte scale and would
            // otherwise be dropped whenever NFD-stored path matches set a high topQ.
            let passes = { (e: ScoredEntry) in e.quality >= minQ || e.hasBase }
            // If the strict density-based floor kills every match (typical for
            // a dense single-token query like "prvskyl" that legitimately spans
            // multiple path segments — quality = pathScore * qLen / window
            // collapses with wide windows), fall back to the unfiltered set so
            // the user sees low-density matches instead of zero results.
            var anyPasses = false
            for ci in 0 ..< nChunks where !anyPasses {
                anyPasses = chunkStore[ci]?.buffer.contains(where: passes) ?? false
            }
            DispatchQueue.concurrentPerform(iterations: nChunks) { ci in
                guard var local = chunkStore[ci] else { return }
                let buf = local.buffer
                if anyPasses {
                    var kept = 0
                    for j in 0 ..< buf.count where passes(buf[j]) {
                        buf[kept] = buf[j]
                        kept &+= 1
                    }
                    local.truncate(to: kept)
                }
                var sorted = local.buffer
                sorted.sort { $0.key < $1.key }
                local.truncate(to: poolSize)
                chunkStore[ci] = local
            }
            for ci in 0 ..< nChunks {
                if let local = chunkStore[ci] {
                    pool.append(contentsOf: local.buffer)
                }
            }
            pool.sort { $0.key < $1.key }
            if pool.count > poolSize {
                pool.removeLast(pool.count - poolSize)
            }
        }
        let sortMs = (CFAbsoluteTimeGetCurrent() - t3) * 1000

        // Keep a wider pool (4x maxResults) then sort by rank to ensure high-scoring
        // path matches aren't eclipsed by lower-scoring basename matches
        var results = pool.map { s in
            let e = entries[s.id]
            let credit = extCredits.map { $0[s.id < extIDs.count ? extIDs[s.id] : 0] ?? 0 } ?? 0
            // A misspelt name scores as its twin spelt the way it was typed would, which starts on a word the way the
            // reading had to.
            let twin = misspelt?[s.id]
            return SearchResult(
                path: shownPath(s.id),
                isDir: e.isDir,
                score: twin?.score ?? s.bestScore,
                quality: twin?.score ?? s.quality,
                hasBase: s.hasBase,
                segmentMatches: s.segmentMatches,
                pathImportance: Int(s.key.c),
                prefixMatch: twin != nil || s.key.b > 0,
                depth: e.segCount,
                extCredit: credit,
                typos: twin?.typos ?? 0
            )
        }
        results.sort { $0 > $1 }
        results = Array(results.prefix(maxResults))

        let totalMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        slog
            .debug(
                "search: q=\"\(query)\" \(n) entries, \(cands.count) cands, \(totalScored) scored, \(results.count) results in \(totalMs, format: .fixed(precision: 1))ms (filter=\(filterMs, format: .fixed(precision: 1))ms score=\(scoreMs, format: .fixed(precision: 1))ms sort=\(sortMs, format: .fixed(precision: 1))ms)"
            )
        return results
    }

    /// Binary search: first index in sorted where path >= prefix
    private func sortedLowerBound(_ prefix: [UInt8], sorted: [Int]) -> Int {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = lo &+ (hi &- lo) >> 1
            let id = sorted[mid]
            let off = byteOffsets[id], len = byteLengths[id]
            let cmpLen = min(len, prefix.count)
            var less = false
            var j = 0
            while j < cmpLen {
                if allBytes[off + j] != prefix[j] {
                    less = allBytes[off + j] < prefix[j]
                    break
                }
                j &+= 1
            }
            if j == cmpLen {
                less = len < prefix.count
            }
            if less {
                lo = mid &+ 1
            } else {
                hi = mid
            }
        }
        return lo
    }

    /// Binary search: first index in sorted where path does NOT start with prefix
    private func sortedUpperBound(_ prefix: [UInt8], sorted: [Int], from lower: Int) -> Int {
        var lo = lower, hi = sorted.count
        while lo < hi {
            let mid = lo &+ (hi &- lo) >> 1
            let id = sorted[mid]
            let off = byteOffsets[id], len = byteLengths[id]
            guard len >= prefix.count else { hi = mid; continue }
            var starts = true
            var j = 0
            while j < prefix.count {
                if allBytes[off + j] != prefix[j] {
                    starts = false; break
                }
                j &+= 1
            }
            if starts {
                lo = mid &+ 1
            } else {
                hi = mid
            }
        }
        return lo
    }

    /// Get or assign a numeric ID for a file extension using byte-level hashing
    @inline(__always) private func extID(for bytes: UnsafePointer<UInt8>, len: Int, bnStart: Int) -> UInt16 {
        // Scan backward from end to find last '.' in basename
        var dotPos = -1
        var k = len - 1
        while k >= bnStart {
            if bytes[k] == 0x2E {
                dotPos = k; break
            }
            if bytes[k] == 0x2F {
                break
            }
            k -= 1
        }
        guard dotPos >= 0, dotPos < len - 1 else { return 0 }

        let h = Self.extHash(bytes, from: dotPos, len: len)

        Self.extLock.lock()
        if let id = Self.globalExtHashToID[h] {
            Self.extLock.unlock()
            return id
        }

        let ext = String(decoding: UnsafeBufferPointer(start: bytes + dotPos, count: len - dotPos), as: UTF8.self)
        let id = Self.globalNextExtID
        Self.globalNextExtID &+= 1
        Self.globalExtHashToID[h] = id
        Self.globalExtToID[ext] = id
        Self.globalIdToExt[id] = ext
        Self.extLock.unlock()
        return id
    }

    private func ensurePathIndex() {
        guard !pathIndexBuilt else { return }
        buildPathIndex()
    }

    /// Copies `len` stored bytes from `off` with their uppercase letters put back.
    @inline(__always) private func restoreCase(_ off: Int, _ len: Int, into dst: UnsafeMutablePointer<UInt8>) {
        memcpy(dst, allBytes.storage.base + off, len)
        let bits = caseBits.storage.base
        let end = off + len
        var w = off >> 6
        while w << 6 < end {
            let wordStart = w << 6
            var word = bits[w]
            if off > wordStart {
                word &= ~((UInt64(1) << UInt64(off - wordStart)) &- 1)
            }
            if end - wordStart < 64 {
                word &= (UInt64(1) << UInt64(end - wordStart)) &- 1
            }
            while word != 0 {
                dst[wordStart + word.trailingZeroBitCount - off] &-= 0x20
                word &= word &- 1
            }
            w &+= 1
        }
    }

    /// The hash of entry `id`'s lookup key. Caller holds the lock.
    private func entryHash(_ id: Int) -> Int {
        if entries[id].nonASCII {
            return Self.keyHash(Self.lookupKey(path(id)))
        }
        return PathTable.hash(allBytes.storage.base + byteOffsets[id], byteLengths[id])
    }

    /// Whether entry `id` is the path with this lookup key: byte for byte, case included. Caller holds the lock.
    private func entryMatches(_ id: Int, key: UnsafeBufferPointer<UInt8>) -> Bool {
        let len = byteLengths[id]
        guard len > 0 else { return false }
        if entries[id].nonASCII {
            return Self.lookupKey(path(id)).withUnsafeBufferPointer { $0.elementsEqual(key) }
        }
        guard len == key.count else { return false }
        let off = byteOffsets[id]
        let bytes = allBytes.storage.base + off
        let bits = caseBits.storage.base
        var k = 0
        while k < len {
            let c = key[k]
            let low = toLowerByte(c)
            guard bytes[k] == low else { return false }
            let bit = off &+ k
            let upper = bits[bit >> 6] >> UInt64(bit & 63) & 1 == 1
            guard upper == (c != low) else { return false }
            k &+= 1
        }
        return true
    }

    /// The id of an indexed path, building the path index on first use. Caller holds the lock.
    private func lookup(_ path: String) -> Int? {
        ensurePathIndex()
        let key = Self.lookupKey(path)
        let hash = Self.keyHash(key)
        return key.withUnsafeBufferPointer { k in
            pathTable.find(hash: hash) { entryMatches($0, key: k) }
        }
    }

    private func indexInsert(_ id: Int) {
        pathTable.insert(id: id, hash: entryHash(id), rehash: entryHash)
    }

    // MARK: - Unlocked internals (caller must hold lock)

    private func _addPath(_ path: String, isDir: Bool) -> Int {
        if let existing = lookup(path) {
            return existing
        }
        let id = _insertPath(path, isDir: isDir)
        indexInsert(id)
        return id
    }

    /// Fills a freed slot or appends, with no duplicate check and no path index update. Caller must hold the lock.
    private func _insertPath(_ path: String, isDir: Bool) -> Int {
        let byteOff = allBytes.count
        var bnStart = 0, segCount = 1
        var mask: UInt64 = 0, bnMaskAccum: UInt64 = 0
        var pathLen = 0
        var boundaries: UInt64 = 0
        var nonASCII = false

        // Use withUTF8 to avoid iterator overhead in debug builds
        var _path = path
        _path.withUTF8 { utf8 in
            let words = (byteOff + utf8.count + 63) >> 6
            if caseBits.count < words {
                caseBits.append(repeating: 0, count: words - caseBits.count)
            }
            var p = 0
            var prevCC: CC = .delim // treat start of path as delimiter boundary
            while p < utf8.count {
                let orig = utf8[p]
                let low = toLowerByte(orig)
                allBytes.append(low)
                if low != orig {
                    let bit = byteOff &+ p
                    caseBits[bit >> 6] |= 1 << UInt64(bit & 63)
                } else if orig >= 0x80 {
                    nonASCII = true
                }
                pathLen &+= 1

                if low == 0x2F {
                    segCount &+= 1
                    bnStart = pathLen
                    bnMaskAccum = 0
                    boundaries = 0
                    prevCC = .delim
                } else {
                    var bit: UInt64 = 0
                    if low >= 0x61, low <= 0x7A {
                        bit = 1 << UInt64(low &- 0x61)
                    } else if low >= 0x30, low <= 0x39 {
                        bit = 1 << UInt64(26 &+ low &- 0x30)
                    } else if low == 0x2E {
                        bit = 1 << 36
                    } else if low == 0x2D {
                        bit = 1 << 37
                    } else if low == 0x5F {
                        bit = 1 << 38
                    }
                    mask |= bit
                    bnMaskAccum |= bit

                    // Compute word boundary from original case
                    let curCC = ccTable[Int(orig)]
                    let bnPos = pathLen - 1 - bnStart
                    if bnPos < 64 {
                        let isBoundary =
                            (prevCC == .lower && curCC == .upper) || // camelCase
                            (prevCC == .delim || prevCC == .white || prevCC == .nonWord) || // after delimiter
                            (prevCC != .number && curCC == .number) || // letter->digit
                            bnPos == 0 // start of basename
                        if isBoundary {
                            boundaries |= 1 << UInt64(bnPos)
                        }
                    }
                    prevCC = curCC
                }
                p &+= 1
            }
        }

        // Compute extension ID from the lowercased bytes in allBytes
        let eid = allBytes.withUnsafeBufferPointer { buf in
            extID(for: buf.baseAddress! + byteOff, len: pathLen, bnStart: bnStart)
        }

        let entry = Entry(bnStart: bnStart, segCount: segCount, isDir: isDir, nonASCII: nonASCII)
        liveCount &+= 1
        changes &+= 1
        let id: Int
        if let f = free.popLast() {
            id = f
            entries[id] = entry
            masks[id] = mask
            bnMasks[id] = bnMaskAccum
            bnBoundaries[id] = boundaries
            byteOffsets[id] = byteOff
            byteLengths[id] = pathLen
            extIDs[id] = eid
        } else {
            id = entries.count
            entries.append(entry)
            masks.append(mask)
            bnMasks.append(bnMaskAccum)
            bnBoundaries.append(boundaries)
            byteOffsets.append(byteOff)
            byteLengths.append(pathLen)
            extIDs.append(eid)
        }
        return id
    }

    private func _removePath(_ path: String) -> Bool {
        guard let id = lookup(path) else { return false }
        _removeID(id)
        return true
    }

    /// Caller must hold the lock.
    private func _removeID(_ id: Int) {
        guard byteLengths[id] > 0 else { return }
        if pathIndexBuilt {
            pathTable.remove(id: id, hash: entryHash(id))
        }
        liveCount &-= 1
        changes &+= 1
        // A zero mask and length are all search and the other passes look at, so in a mapped file that is two pages
        // copied at most, and the slot stays a hole until the next save.
        masks[id] = 0
        byteLengths[id] = 0
        guard id >= mappedCount else { return }
        entries[id] = Entry(bnStart: 0, segCount: 0, isDir: false, nonASCII: false)
        bnMasks[id] = 0
        bnBoundaries[id] = 0
        byteOffsets[id] = 0
        extIDs[id] = 0
        free.append(id)
    }

    /// Caller must hold the lock.
    private func _appendPath(_ path: String, isDir: Bool) {
        let id = _insertPath(path, isDir: isDir)
        if pathIndexBuilt {
            indexInsert(id)
        }
        sortedByPath = nil
    }
}

/// ORs `count` bits starting at bit `from` of `src` into `dst` starting at bit `to`. `dst` starts zeroed.
func copyBits(from src: UnsafePointer<UInt64>, at from: Int, to dst: UnsafeMutablePointer<UInt64>, at to: Int, count: Int) {
    var from = from, to = to, left = count
    while left > 0 {
        let n = min(left, 64 - (from & 63), 64 - (to & 63))
        var bits = src[from >> 6] >> UInt64(from & 63)
        if n < 64 {
            bits &= (UInt64(1) << UInt64(n)) &- 1
        }
        dst[to >> 6] |= bits << UInt64(to & 63)
        from &+= n
        to &+= n
        left &-= n
    }
}
