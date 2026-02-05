import Foundation
import simd
#if canImport(Ignore)
    import Ignore
#endif
import os.log

private let slog = Logger(subsystem: "com.lowtechguys.Cling", category: "SearchEngine")

// MARK: - Scoring Constants (fzf path scheme)

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

private var scoreMatch: Int { SC.scoreMatch }
private var gapStart: Int { SC.gapStart }
private var gapExtend: Int { SC.gapExtend }
private var bonusBoundary: Int { SC.bonusBoundary }
private var bonusNonWord: Int { SC.bonusNonWord }
private var bonusCamel123: Int { SC.bonusCamel }
private var bonusConsec: Int { SC.bonusConsecutive }
private var firstCharMul: Int { SC.firstCharMultiplier }
private var bonusBdWhite: Int { SC.bonusWhitespace }
private var bonusBdDelim: Int { SC.bonusDelimiter }

func reloadScoringConfig() {
    SC = ScoringConfig.load()
    rebuildBonusFlat()
}

// MARK: - Character Classes

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
        if p == .lower, c == .upper { return bonusCamel123 }
        if p != .number, c == .number { return bonusCamel123 }
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
            if cmp[lane] { return i &+ lane }
            lane &+= 1
        }
        i &+= 16
    }
    while i < count {
        if base[i] == needle { return i }
        i &+= 1
    }
    return -1
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
            if maskMatch[lane] { anyMatch = true; break }
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

@inline(__always) private func toLowerByte(_ b: UInt8) -> UInt8 { (b >= 0x41 && b <= 0x5A) ? b &+ 32 : b }

private func fuzzyScoreBytes(
    _ pat: UnsafeBufferPointer<UInt8>,
    _ txt: UnsafeBufferPointer<UInt8>,
    boundaries: UInt64 = 0,
    boundariesOffset: Int = 0
) -> (score: Int, start: Int, end: Int)? {
    let M = pat.count, N = txt.count
    if M == 0 { return (0, 0, 0) }
    if M > N { return nil }

    let txtBase = txt.baseAddress!

    // Forward scan: find leftmost match using SIMD byte search for each pattern char
    var pi = 0, sidx = -1, eidx = -1
    var searchFrom = 0
    while pi < M {
        let needle = pat[pi]
        // Use SIMD for longer texts, scalar for short
        let pos: Int
        if N &- searchFrom >= 16 {
            pos = simdFindByte(txtBase, count: N, needle: needle, from: searchFrom)
        } else {
            var p = searchFrom; pos = -1
            // Inline scalar search
            var found = -1
            while p < N {
                if txtBase[p] == needle { found = p; break }
                p &+= 1
            }
            if found < 0 { return nil }
            // Use found directly below
            if sidx < 0 { sidx = found }
            pi &+= 1
            searchFrom = found &+ 1
            if pi == M { eidx = found &+ 1 }
            continue
        }
        if pos < 0 { return nil }
        if sidx < 0 { sidx = pos }
        pi &+= 1
        searchFrom = pos &+ 1
        if pi == M { eidx = pos &+ 1 }
    }
    guard sidx >= 0, eidx >= 0 else { return nil }

    // Backward scan: tighten match window
    pi = M &- 1
    var bi = eidx &- 1
    while bi >= sidx {
        if txtBase[bi] == pat[pi] {
            pi &-= 1
            if pi < 0 { sidx = bi; break }
        }
        bi &-= 1
    }

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
                if bonus >= bonusBoundary, bonus > firstBonus { firstBonus = bonus }
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
    return (score, sidx, eidx)
}

// MARK: - Letter Bitmask (a-z + 0-9 + . - _)

@inline(__always)
private func letterMaskBytes(_ p: UnsafeBufferPointer<UInt8>) -> UInt64 {
    var m: UInt64 = 0
    for i in 0 ..< p.count {
        let v = p[i]
        if v >= 0x61, v <= 0x7A { m |= 1 << UInt64(v &- 0x61) }
        else if v >= 0x30, v <= 0x39 { m |= 1 << UInt64(26 &+ v &- 0x30) }
        else if v == 0x2E { m |= 1 << 36 }
        else if v == 0x2D { m |= 1 << 37 }
        else if v == 0x5F { m |= 1 << 38 }
    }
    return m
}

// MARK: - Search Result

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

    /// Composite rank combining match type, importance, and quality into a single comparable value.
    /// hasBase and prefixMatch provide bonuses, but quality differences can overcome them.
    /// Uses max(score, quality) so boundary-aligned matches with wider windows aren't penalized.
    var rank: Int {
        var r = max(score, quality)
        if hasBase { r += SC.rankHasBaseBonus }
        r += segmentMatches * SC.rankHasBaseBonus
        if prefixMatch { r += SC.rankPrefixMatchBonus }
        r += pathImportance * SC.rankImportanceMultiplier
        r -= max(0, path.count - SC.rankLongPathThreshold)
        return r
    }

    static func < (lhs: SearchResult, rhs: SearchResult) -> Bool {
        let lr = lhs.rank, rr = rhs.rank
        if lr != rr { return lr < rr }
        if lhs.score != rhs.score { return lhs.score < rhs.score }
        if lhs.depth != rhs.depth { return lhs.depth > rhs.depth }
        return lhs.path.count > rhs.path.count
    }
}

// MARK: - SearchEngine

final class SearchEngine: @unchecked Sendable {
    struct Entry {
        var path: String
        var isDir: Bool
        var bnStart: Int
        var segCount: Int
        var pathLen: Int
    }

    private(set) var entries: [Entry] = []

    private(set) var bnBoundaries: [UInt64] = [] // bit N = 1 means basename byte N is a word boundary (camelCase, delimiter, etc.)

    var count: Int { lock.withLock { entries.count - free.count } }

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
        }
    }

    // MARK: - Add / Remove

    /// Thread-safe add for use during parallel walks and FSEvents.
    @discardableResult
    func addPath(_ path: String, isDir: Bool) -> Int {
        lock.withLock { _addPath(path, isDir: isDir) }
    }

    /// Thread-safe remove.
    @discardableResult
    func removePath(_ path: String) -> Bool {
        lock.withLock { _removePath(path) }
    }

    func hasPath(_ path: String) -> Bool { lock.withLock { ensurePathIndex(); return pathToID[path] != nil } }

    func clear() {
        lock.withLock {
            entries.removeAll()
            masks.removeAll()
            bnMasks.removeAll()
            allBytes.removeAll()
            byteOffsets.removeAll()
            byteLengths.removeAll()
            extIDs.removeAll()
            extToID.removeAll()
            extHashToID.removeAll()
            idToExt.removeAll()
            nextExtID = 1
            free.removeAll()
            pathToID.removeAll()
            pathIndexBuilt = false
            sortedByPath = nil
        }
    }

    func saveBinaryIndex(to url: URL) {
        let t0 = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let n = entries.count

        // Compute total path string bytes
        var totalPathBytes = 0
        var idx = 0
        while idx < n {
            totalPathBytes += entries[idx].path.utf8.count + 1 // +1 for null terminator
            idx &+= 1
        }

        let headerSize = 24 // magic + entryCount + allBytesCount
        let masksSize = n * 8
        let bnMasksSize = n * 8
        let bnBoundariesSize = n * 8
        let offsetsSize = n * 4
        let lengthsSize = n * 2
        let bnStartsSize = n * 2
        let segCountsSize = n
        let isDirsSize = n
        let totalSize = headerSize + masksSize + bnMasksSize + bnBoundariesSize + offsetsSize + lengthsSize + bnStartsSize + segCountsSize + isDirsSize + allBytes.count + totalPathBytes

        var data = Data(count: totalSize)
        data.withUnsafeMutableBytes { buf in
            let ptr = buf.baseAddress!
            var offset = 0

            // Header
            ptr.storeBytes(of: Self.binaryMagic, toByteOffset: offset, as: UInt64.self); offset += 8
            ptr.storeBytes(of: UInt64(n), toByteOffset: offset, as: UInt64.self); offset += 8
            ptr.storeBytes(of: UInt64(allBytes.count), toByteOffset: offset, as: UInt64.self); offset += 8

            // Masks
            masks.withUnsafeBufferPointer { src in _ = memcpy(ptr + offset, src.baseAddress!, n * 8) }; offset += masksSize
            bnMasks.withUnsafeBufferPointer { src in _ = memcpy(ptr + offset, src.baseAddress!, n * 8) }; offset += bnMasksSize
            bnBoundaries.withUnsafeBufferPointer { src in _ = memcpy(ptr + offset, src.baseAddress!, n * 8) }; offset += bnBoundariesSize

            // Compact byteOffsets as UInt32
            var i = 0
            while i < n {
                ptr.storeBytes(of: UInt32(byteOffsets[i]), toByteOffset: offset + i * 4, as: UInt32.self)
                i &+= 1
            }
            offset += offsetsSize

            // Compact byteLengths as UInt16
            i = 0
            while i < n {
                ptr.storeBytes(of: UInt16(min(entries[i].pathLen, 65535)), toByteOffset: offset + i * 2, as: UInt16.self)
                i &+= 1
            }
            offset += lengthsSize

            // bnStarts
            i = 0
            while i < n {
                ptr.storeBytes(of: UInt16(min(entries[i].bnStart, 65535)), toByteOffset: offset + i * 2, as: UInt16.self)
                i &+= 1
            }
            offset += bnStartsSize

            // segCounts
            i = 0
            while i < n {
                (ptr + offset + i).storeBytes(of: UInt8(min(entries[i].segCount, 255)), as: UInt8.self)
                i &+= 1
            }
            offset += segCountsSize

            // isDirs
            i = 0
            while i < n {
                (ptr + offset + i).storeBytes(of: UInt8(entries[i].isDir ? 1 : 0), as: UInt8.self)
                i &+= 1
            }
            offset += isDirsSize

            // allBytes
            allBytes.withUnsafeBufferPointer { src in _ = memcpy(ptr + offset, src.baseAddress!, allBytes.count) }
            offset += allBytes.count

            // Path strings (null-terminated)
            i = 0
            while i < n {
                let path = entries[i].path
                var mutPath = path
                mutPath.withUTF8 { utf8 in
                    _ = memcpy(ptr + offset, utf8.baseAddress!, utf8.count)
                    offset += utf8.count
                }
                (ptr + offset).storeBytes(of: UInt8(0), as: UInt8.self)
                offset += 1
                i &+= 1
            }
        }
        lock.unlock()

        try? data.write(to: url)
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        slog.info("saveBinaryIndex: \(n) entries, \(totalSize / 1_048_576)MB in \(ms, format: .fixed(precision: 1))ms")
    }

    func loadBinaryIndex(from url: URL, progress: ((Int) -> Void)? = nil) -> Bool {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            slog.error("loadBinaryIndex: failed to read \(url.path)")
            return false
        }
        let readMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        let t1 = CFAbsoluteTimeGetCurrent()
        var loaded = false

        data.withUnsafeBytes { buf in
            let ptr = buf.baseAddress!
            let totalLen = buf.count
            guard totalLen > 24 else { return }

            let magic = ptr.load(fromByteOffset: 0, as: UInt64.self)
            guard magic == Self.binaryMagic else {
                slog.error("loadBinaryIndex: bad magic")
                return
            }

            let n = Int(ptr.load(fromByteOffset: 8, as: UInt64.self))
            let allBytesCount = Int(ptr.load(fromByteOffset: 16, as: UInt64.self))

            lock.lock()
            let headerSize = 24
            var offset = headerSize

            // Masks: bulk memcpy
            masks = [UInt64](repeating: 0, count: n)
            masks.withUnsafeMutableBufferPointer { dst in _ = memcpy(dst.baseAddress!, ptr + offset, n * 8) }
            offset += n * 8

            bnMasks = [UInt64](repeating: 0, count: n)
            bnMasks.withUnsafeMutableBufferPointer { dst in _ = memcpy(dst.baseAddress!, ptr + offset, n * 8) }
            offset += n * 8

            bnBoundaries = [UInt64](repeating: 0, count: n)
            bnBoundaries.withUnsafeMutableBufferPointer { dst in _ = memcpy(dst.baseAddress!, ptr + offset, n * 8) }
            offset += n * 8

            progress?(n / 4)

            // byteOffsets from UInt32
            byteOffsets = [Int](repeating: 0, count: n)
            var i = 0
            while i < n {
                byteOffsets[i] = Int(ptr.load(fromByteOffset: offset + i * 4, as: UInt32.self))
                i &+= 1
            }
            offset += n * 4

            // byteLengths from UInt16
            byteLengths = [Int](repeating: 0, count: n)
            i = 0
            while i < n {
                byteLengths[i] = Int(ptr.load(fromByteOffset: offset + i * 2, as: UInt16.self))
                i &+= 1
            }
            offset += n * 2

            // bnStarts
            var bnStarts = [Int](repeating: 0, count: n)
            i = 0
            while i < n {
                bnStarts[i] = Int(ptr.load(fromByteOffset: offset + i * 2, as: UInt16.self))
                i &+= 1
            }
            offset += n * 2

            // segCounts
            var segCounts = [Int](repeating: 0, count: n)
            i = 0
            while i < n {
                segCounts[i] = Int((ptr + offset + i).load(as: UInt8.self))
                i &+= 1
            }
            offset += n

            // isDirs
            var isDirs = [Bool](repeating: false, count: n)
            i = 0
            while i < n {
                isDirs[i] = (ptr + offset + i).load(as: UInt8.self) != 0
                i &+= 1
            }
            offset += n

            progress?(n / 2)

            // allBytes: bulk memcpy
            allBytes = [UInt8](repeating: 0, count: allBytesCount)
            allBytes.withUnsafeMutableBufferPointer { dst in _ = memcpy(dst.baseAddress!, ptr + offset, allBytesCount) }
            offset += allBytesCount

            progress?(n * 3 / 4)

            // Path strings (null-terminated)
            entries = [Entry](repeating: Entry(path: "", isDir: false, bnStart: 0, segCount: 0, pathLen: 0), count: n)
            i = 0
            let strBase = (ptr + offset).assumingMemoryBound(to: UInt8.self)
            var strOff = 0
            while i < n {
                // Find null terminator
                var sLen = 0
                while strBase[strOff + sLen] != 0 {
                    sLen &+= 1
                }
                let path = String(decoding: UnsafeBufferPointer(start: strBase + strOff, count: sLen), as: UTF8.self)
                entries[i] = Entry(path: path, isDir: isDirs[i], bnStart: bnStarts[i], segCount: segCounts[i], pathLen: byteLengths[i])
                strOff += sLen + 1
                i &+= 1
            }

            computeExtIDs()
            pathIndexBuilt = false
            sortedByPath = nil
            lock.unlock()
            loaded = true
            progress?(n)
        }

        let parseMs = (CFAbsoluteTimeGetCurrent() - t1) * 1000
        let n = entries.count
        slog.info("loadBinaryIndex: \(n) entries, read=\(readMs, format: .fixed(precision: 1))ms parse=\(parseMs, format: .fixed(precision: 1))ms")
        return loaded
    }

    /// Append entries from a binary index file into the current engine.
    @discardableResult
    func appendBinaryIndex(from url: URL, progress: ((Int) -> Void)? = nil) -> Bool {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }

        var appended = false
        data.withUnsafeBytes { raw in
            let ptr = raw.baseAddress!
            let totalLen = raw.count
            guard totalLen > 24 else { return }

            let magic = ptr.load(fromByteOffset: 0, as: UInt64.self)
            guard magic == Self.binaryMagic else { return }

            let n = Int(ptr.load(fromByteOffset: 8, as: UInt64.self))
            let allBytesCount = Int(ptr.load(fromByteOffset: 16, as: UInt64.self))

            let headerSize = 24
            var offset = headerSize

            var newMasks = [UInt64](repeating: 0, count: n)
            newMasks.withUnsafeMutableBufferPointer { dst in _ = memcpy(dst.baseAddress!, ptr + offset, n * 8) }
            offset += n * 8

            var newBnMasks = [UInt64](repeating: 0, count: n)
            newBnMasks.withUnsafeMutableBufferPointer { dst in _ = memcpy(dst.baseAddress!, ptr + offset, n * 8) }
            offset += n * 8

            var newBnBoundaries = [UInt64](repeating: 0, count: n)
            newBnBoundaries.withUnsafeMutableBufferPointer { dst in _ = memcpy(dst.baseAddress!, ptr + offset, n * 8) }
            offset += n * 8

            var newByteOffsets = [Int](repeating: 0, count: n)
            var i = 0
            while i < n {
                newByteOffsets[i] = Int(ptr.load(fromByteOffset: offset + i * 4, as: UInt32.self))
                i &+= 1
            }
            offset += n * 4

            var newByteLengths = [Int](repeating: 0, count: n)
            i = 0
            while i < n {
                newByteLengths[i] = Int(ptr.load(fromByteOffset: offset + i * 2, as: UInt16.self))
                i &+= 1
            }
            offset += n * 2

            var bnStarts = [Int](repeating: 0, count: n)
            i = 0
            while i < n {
                bnStarts[i] = Int(ptr.load(fromByteOffset: offset + i * 2, as: UInt16.self))
                i &+= 1
            }
            offset += n * 2

            var segCounts = [Int](repeating: 0, count: n)
            i = 0
            while i < n {
                segCounts[i] = Int((ptr + offset + i).load(as: UInt8.self))
                i &+= 1
            }
            offset += n

            var isDirs = [Bool](repeating: false, count: n)
            i = 0
            while i < n {
                isDirs[i] = (ptr + offset + i).load(as: UInt8.self) != 0
                i &+= 1
            }
            offset += n

            var newAllBytes = [UInt8](repeating: 0, count: allBytesCount)
            newAllBytes.withUnsafeMutableBufferPointer { dst in _ = memcpy(dst.baseAddress!, ptr + offset, allBytesCount) }
            offset += allBytesCount

            var newEntries = [Entry](repeating: Entry(path: "", isDir: false, bnStart: 0, segCount: 0, pathLen: 0), count: n)
            let strBase = (ptr + offset).assumingMemoryBound(to: UInt8.self)
            var strOff = 0
            i = 0
            while i < n {
                var sLen = 0
                while strBase[strOff + sLen] != 0 {
                    sLen &+= 1
                }
                let path = String(decoding: UnsafeBufferPointer(start: strBase + strOff, count: sLen), as: UTF8.self)
                newEntries[i] = Entry(path: path, isDir: isDirs[i], bnStart: bnStarts[i], segCount: segCounts[i], pathLen: newByteLengths[i])
                strOff += sLen + 1
                i &+= 1
            }

            // Append under lock, shifting byteOffsets by current allBytes size
            lock.lock()
            let baseOffset = allBytes.count
            i = 0
            while i < n {
                newByteOffsets[i] += baseOffset
                i &+= 1
            }
            entries.append(contentsOf: newEntries)
            masks.append(contentsOf: newMasks)
            bnMasks.append(contentsOf: newBnMasks)
            bnBoundaries.append(contentsOf: newBnBoundaries)
            byteOffsets.append(contentsOf: newByteOffsets)
            byteLengths.append(contentsOf: newByteLengths)
            allBytes.append(contentsOf: newAllBytes)
            computeExtIDs()
            pathIndexBuilt = false
            sortedByPath = nil
            lock.unlock()
            appended = true
            progress?(n)
        }

        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        let total = lock.withLock { entries.count }
        slog.info("appendBinaryIndex: \(url.lastPathComponent) \(total) total entries in \(ms, format: .fixed(precision: 1))ms")
        return appended
    }

    // MARK: - Text Persistence (human-readable, used as fallback)

    func saveIndex(to url: URL) {
        let t0 = CFAbsoluteTimeGetCurrent()

        lock.lock()
        let entryCount = entries.count

        // Write as raw bytes directly from stored data
        var data = Data()
        data.reserveCapacity(allBytes.count + entryCount * 4 + 20)
        data.append(contentsOf: "cling-index-v1\n".utf8)

        let dTab = UInt8(ascii: "\t")
        let dNL = UInt8(ascii: "\n")
        let dD = UInt8(ascii: "D")
        let dF = UInt8(ascii: "F")

        for i in 0 ..< entryCount {
            let e = entries[i]
            guard e.pathLen > 0 else { continue } // skip freed slots
            data.append(e.isDir ? dD : dF)
            data.append(dTab)
            data.append(contentsOf: e.path.utf8)
            data.append(dNL)
        }
        lock.unlock()

        try? data.write(to: url)

        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        slog.info("saveIndex: \(entryCount) entries in \(ms, format: .fixed(precision: 1))ms to \(url.path)")
    }

    /// Build pathToID from entries (call after bulk load to enable add/remove)
    func buildPathIndex() {
        let t0 = CFAbsoluteTimeGetCurrent()
        pathToID.reserveCapacity(entries.count)
        for i in 0 ..< entries.count where !entries[i].path.isEmpty {
            pathToID[entries[i].path] = i
        }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        slog.debug("buildPathIndex: \(self.pathToID.count) entries in \(ms, format: .fixed(precision: 1))ms")
    }

    /// Build sorted path index for O(log n) prefix lookups. Call after index loading.
    /// Holds lock for the sort (runs on background thread, never blocks main thread).
    func buildSortedPathIndex() {
        let t0 = CFAbsoluteTimeGetCurrent()

        lock.lock()
        let n = entries.count
        guard n > 0 else { sortedByPath = nil; lock.unlock(); return }

        var sorted = [Int](unsafeUninitializedCapacity: n) { buf, count in
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
                if cmp != 0 { return cmp < 0 }
                return aLen < bLen
            }
        }

        sortedByPath = sorted
        lock.unlock()

        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        slog.debug("buildSortedPathIndex: \(n) entries in \(ms, format: .fixed(precision: 1))ms")
    }

    func loadIndex(from url: URL, progress: ((Int) -> Void)? = nil) -> Bool {
        let t0 = CFAbsoluteTimeGetCurrent()

        // Memory-map the file instead of reading into Data (avoids 1.1GB copy)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            slog.error("loadIndex: failed to read \(url.path)")
            return false
        }
        let readMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        let t1 = CFAbsoluteTimeGetCurrent()
        var entryCount = 0

        data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let len = buf.count
            guard len > 15 else { return }

            // Verify header: "cling-index-v1\n"
            let headerEnd = 14
            guard len > headerEnd,
                  base[0] == 0x63, /* c */
                  base[6] == 0x69, /* i (in "index") */
                  base[headerEnd] == 0x0A else { return }

            // Count newlines for pre-allocation (while loop to avoid Range<Int> generic overhead in debug)
            let t_count = CFAbsoluteTimeGetCurrent()
            var nlCount = 0
            var _k = 0
            while _k < len {
                if base[_k] == 0x0A { nlCount &+= 1 }; _k &+= 1
            }
            let countMs = (CFAbsoluteTimeGetCurrent() - t_count) * 1000
            slog.debug("loadIndex: counted \(nlCount) lines in \(countMs, format: .fixed(precision: 1))ms")

            lock.lock()
            entries.reserveCapacity(nlCount)
            masks.reserveCapacity(nlCount)
            bnMasks.reserveCapacity(nlCount)
            byteOffsets.reserveCapacity(nlCount)
            byteLengths.reserveCapacity(nlCount)
            // allBytes stores lowercased path bytes; total bytes ~ file size minus overhead
            allBytes.reserveCapacity(len)

            // Two-pass approach:
            // Pass 1: scan lines, compute lowercased bytes + masks directly from mmap'd bytes
            //         Store a (fileOffset, length) per entry for deferred String creation
            // Pass 2: create Entry.path Strings in bulk

            // Temp storage for file offsets (avoids String creation in hot loop)
            var pathOffsets = [Int]() // offset into `base` where the path starts
            var pathLens = [Int]() // length of path in bytes
            var isDirs = [Bool]()
            pathOffsets.reserveCapacity(nlCount)
            pathLens.reserveCapacity(nlCount)
            isDirs.reserveCapacity(nlCount)

            var i = headerEnd + 1 // skip header line
            while i < len {
                var j = i
                while j < len, base[j] != 0x0A {
                    j &+= 1
                }

                if j - i > 2 {
                    let isDir = base[i] == 0x44 // 'D'
                    let pathStart = i + 2
                    let pathLen = j - pathStart

                    // Compute lowercased bytes, masks, bnStart, segCount in one pass over raw bytes
                    let byteOff = allBytes.count
                    var bnStart = 0, segCount = 1
                    var mask: UInt64 = 0, bnMaskAccum: UInt64 = 0

                    // Bulk-copy bytes then lowercase in-place (avoids per-byte append overhead)
                    let copyStart = allBytes.count
                    allBytes.append(contentsOf: UnsafeBufferPointer(start: base + pathStart, count: pathLen))

                    var k = 0
                    while k < pathLen {
                        let b = allBytes[copyStart &+ k]
                        let low = toLowerByte(b)
                        if low != b { allBytes[copyStart &+ k] = low }

                        if low == 0x2F {
                            segCount &+= 1
                            bnStart = k + 1
                            bnMaskAccum = 0
                        } else {
                            var bit: UInt64 = 0
                            if low >= 0x61, low <= 0x7A { bit = 1 << UInt64(low &- 0x61) }
                            else if low >= 0x30, low <= 0x39 { bit = 1 << UInt64(26 &+ low &- 0x30) }
                            else if low == 0x2E { bit = 1 << 36 }
                            else if low == 0x2D { bit = 1 << 37 }
                            else if low == 0x5F { bit = 1 << 38 }
                            mask |= bit
                            bnMaskAccum |= bit
                        }
                        k &+= 1
                    }

                    // Store everything except the String (deferred)
                    pathOffsets.append(pathStart)
                    pathLens.append(pathLen)
                    isDirs.append(isDir)

                    // Append parallel arrays (no Entry.path yet, placeholder empty string)
                    entries.append(Entry(
                        path: "",
                        isDir: isDir,
                        bnStart: bnStart,
                        segCount: segCount,
                        pathLen: pathLen
                    ))
                    masks.append(mask)
                    bnMasks.append(bnMaskAccum)
                    byteOffsets.append(byteOff)
                    byteLengths.append(pathLen)
                    let eid = allBytes.withUnsafeBufferPointer { buf in
                        extID(for: buf.baseAddress! + byteOff, len: pathLen, bnStart: bnStart)
                    }
                    extIDs.append(eid)

                    entryCount &+= 1
                    if entryCount % 200_000 == 0 {
                        progress?(entryCount)
                    }
                }
                i = j + 1
            }

            // Pass 2: create String objects for Entry.path (bulk, still from mmap'd buffer)
            let t_strings = CFAbsoluteTimeGetCurrent()
            var idx = 0
            while idx < entryCount {
                entries[idx].path = String(decoding: UnsafeBufferPointer(start: base + pathOffsets[idx], count: pathLens[idx]), as: UTF8.self)
                idx &+= 1
            }
            let stringMs = (CFAbsoluteTimeGetCurrent() - t_strings) * 1000
            slog.debug("loadIndex: created \(entryCount) strings in \(stringMs, format: .fixed(precision: 1))ms")

            pathIndexBuilt = false
            sortedByPath = nil
            lock.unlock()
        }

        let parseMs = (CFAbsoluteTimeGetCurrent() - t1) * 1000
        slog.info("loadIndex: \(entryCount) entries, read=\(readMs, format: .fixed(precision: 1))ms parse=\(parseMs, format: .fixed(precision: 1))ms")
        return entryCount > 0
    }

    @discardableResult
    func walkDirectory(
        _ dir: String,
        ignoreFile: String? = nil,
        skipDir: ((String) -> Bool)? = nil,
        progress: ((Int, String) -> Void)? = nil,
        cancelled: (() -> Bool)? = nil
    ) -> Int {
        let t0 = CFAbsoluteTimeGetCurrent()

        let cDir = strdup(dir)!
        defer { Darwin.free(cDir) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cDir, nil]

        let opts = Int32(FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV)
        guard let ftsp = fts_open(&paths, opts, nil) else {
            slog.error("walkDirectory: fts_open failed for \(dir)")
            return 0
        }
        defer { fts_close(ftsp) }

        // Pre-extract extension patterns from ignore file content for fast file-level filtering
        let ignoreContent: String? = ignoreFile.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        let ignoredExtensions: Set<String> = ignoreContent.map { Self.extractExtensionPatterns(from: $0) } ?? []

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
                _ = _addPath(p, isDir: d)
            }
            lock.unlock()
            batch.removeAll(keepingCapacity: true)
        }

        while let ent = fts_read(ftsp) {
            if cancelled?() == true { break }

            let info = ent.pointee.fts_info
            if ent.pointee.fts_level == 0 { continue }

            let pathLen = Int(ent.pointee.fts_pathlen)
            let pathPtr = UnsafeRawPointer(ent.pointee.fts_path!).assumingMemoryBound(to: UInt8.self)

            switch Int32(info) {
            case FTS_D:
                // Skip .git
                if ent.pointee.fts_namelen == 4 {
                    let n = ent.pointee.fts_path!.advanced(by: pathLen &- 4)
                    if n[0] == 0x2E, n[1] == 0x67, n[2] == 0x69, n[3] == 0x74 {
                        fts_set(ftsp, ent, Int32(FTS_SKIP))
                        continue
                    }
                }

                let fullPath = String(decoding: UnsafeBufferPointer(start: pathPtr, count: pathLen), as: UTF8.self)

                if let ignoreFile, fullPath.isIgnored(in: ignoreFile) {
                    fts_set(ftsp, ent, Int32(FTS_SKIP))
                    skippedIgnore &+= 1
                    continue
                }
                if let skipDir, skipDir(fullPath) {
                    fts_set(ftsp, ent, Int32(FTS_SKIP))
                    continue
                }

                batch.append((fullPath, true))
                added &+= 1

            case FTS_F, FTS_SL, FTS_SLNONE:
                // Skip .DS_Store, .localized, Icon\r
                let nameLen = Int(ent.pointee.fts_namelen)
                let n = ent.pointee.fts_path!.advanced(by: pathLen &- nameLen)
                if nameLen == 9, n[0] == 0x2E, n[1] == 0x44, n[2] == 0x53,
                   n[3] == 0x5F, n[4] == 0x53 { continue } // .DS_Store
                if nameLen == 10, n[0] == 0x2E, n[1] == 0x6C, n[2] == 0x6F,
                   n[3] == 0x63 { continue } // .localized
                if nameLen == 5, n[0] == 0x49, n[1] == 0x63, n[2] == 0x6F,
                   n[3] == 0x6E, n[4] == 0x0D { continue } // Icon\r

                if !ignoredExtensions.isEmpty {
                    var extStart = -1
                    for k in stride(from: pathLen - 1, through: max(pathLen - 20, 0), by: -1) {
                        let b = pathPtr[k]
                        if b == 0x2F { break }
                        if b == 0x2E { extStart = k; break }
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
                batch.append((fullPath, false))
                added &+= 1

            case FTS_DP: continue

            default: continue
            }

            if batch.count >= batchSize { flushBatch() }

            // Progress reporting (every 500ms)
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastProgress > 0.5 {
                lastProgress = now
                progress?(added, batch.last?.0 ?? dir)
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
        let fm = FileManager.default
        let baseURL = URL(fileURLWithPath: dir)
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        let basePath = baseURL.path
        let checkpointDepth = 3

        let ignoreContent: String? = ignoreFile.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        let ignoredExtensions: Set<String> = ignoreContent.map { Self.extractExtensionPatterns(from: $0) } ?? []

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
            if cancelled?() == true { break }

            let dirURL = queue[qi]
            qi += 1
            let dirPath = dirURL.path

            // Skip already-completed checkpoint dirs
            if completedDirs.contains(dirPath) { continue }

            guard let contents = try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
                continue
            }

            for url in contents {
                if cancelled?() == true { break }

                let path = url.path
                let name = url.lastPathComponent

                if name == ".DS_Store" || name == ".localized" { continue }
                if name.hasSuffix("\r"), name.hasPrefix("Icon") { continue }

                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

                if isDir {
                    if name == ".git" { continue }
                    if let ignoreFile, path.isIgnored(in: ignoreFile) { continue }
                    if let skipDir, skipDir(path) { continue }
                    queue.append(url)
                } else {
                    if !ignoredExtensions.isEmpty {
                        let ext = "." + (url.pathExtension.lowercased())
                        if ext.count > 1, ignoredExtensions.contains(ext) { continue }
                    }
                }

                batch.append((path, isDir))
                added += 1

                if batch.count >= batchSize { flushBatch() }

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
            if dirsOnly, !entries[i].isDir { i &+= 1; continue }
            if hasSuffixFilter {
                var matched = false
                // Check known ext IDs (O(1) per ID)
                if !knownExtIDs.isEmpty {
                    let eid = extIDs[i]
                    var ei = 0
                    while ei < knownExtIDs.count {
                        if eid == knownExtIDs[ei] { matched = true; break }
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
                                if allBytes[off + len - sfx.count + j] != sfx[j] { ok = false; break }
                                j &+= 1
                            }
                            if ok { matched = true; break }
                        }
                        si &+= 1
                    }
                }
                if !matched { i &+= 1; continue }
            }
            result.append(i)
            i &+= 1
        }
        slog.debug("prefilter: suffixes=\(suffixes) dirsOnly=\(dirsOnly) knownIDs=\(knownExtIDs.count) unknownSfx=\(unknownSuffixBytes.count) → \(result.count)/\(n) entries")
        return result
    }

    func search(
        query: String,
        maxResults: Int = 200,
        folderPrefixes: [String]? = nil,
        excludedPrefixes: [String]? = nil,
        excludedPaths: Set<String>? = nil,
        suffixPattern: String? = nil,
        dirsOnly: Bool = false,
        candidatePool: [Int]? = nil,
        cancelled: (() -> Bool)? = nil
    ) -> [SearchResult] {
        let t0 = CFAbsoluteTimeGetCurrent()

        // Hold lock for the entire search to prevent concurrent array reallocation.
        // Walkers batch 2048 entries before locking, so contention is minimal.
        lock.lock()
        defer { lock.unlock() }
        let n = entries.count

        let qTrimmed = query.trimmingCharacters(in: .whitespaces)
        let wantDir = qTrimmed.hasSuffix("/")
        var qRaw = qTrimmed.lowercased()
        while qRaw.hasPrefix("/") { qRaw.removeFirst() }

        // Split into tokens, separate extension tokens (starting with '.' or '*.') and folder tokens (starting with 'in:') from fuzzy tokens
        let qTokens = qRaw.split(separator: " ")
        func isExtToken(_ t: Substring) -> Bool { t.hasPrefix(".") || t.hasPrefix("*.") }
        func extString(_ t: Substring) -> String { t.hasPrefix("*.") ? "." + t.dropFirst(2) : String(t) }
        func isInToken(_ t: Substring) -> Bool { t.hasPrefix("in:") && t.count > 3 }
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let inPrefixes: [String] = qTokens.compactMap { token -> String? in
            guard isInToken(token) else { return nil }
            var path = String(token.dropFirst(3))
            if path.hasPrefix("~") { path = homePath + path.dropFirst() }
            return path
        }
        let extTokenBytes: [[UInt8]] = qTokens.compactMap { isExtToken($0) ? Array(extString($0).utf8) : nil }
        // Pre-resolve extension IDs for O(1) matching (UInt16 compare vs byte-by-byte suffix)
        let extTokenIDs: [UInt16] = qTokens.compactMap { token in
            guard isExtToken(token) else { return nil }
            return extToID[extString(token)]
        }
        // Separate dir-segment tokens (ending with '/') from plain fuzzy tokens.
        // Dir-segment tokens like "rcmd/" require a literal substring "rcmd/" in the path (not fuzzy).
        func isDirSegment(_ t: Substring) -> Bool { t.hasSuffix("/") && t.count > 1 }
        let dirSegments: [[UInt8]] = qTokens.compactMap { isDirSegment($0) ? Array(String($0).utf8) : nil }
        let fuzzyTokens = qTokens.filter { !isExtToken($0) && !isInToken($0) && !isDirSegment($0) }.map(String.init)
        let q = fuzzyTokens.joined()
        // Dirs-only when the query is solely dir segments (e.g. "rcmd/" with no fuzzy/ext tokens)
        let dirsOnly = dirsOnly || (!dirSegments.isEmpty && fuzzyTokens.isEmpty && extTokenBytes.isEmpty)
        let hasFuzzyQuery = !q.isEmpty || !extTokenBytes.isEmpty || !dirSegments.isEmpty

        // APFS stores paths in NFD (decomposed Unicode), so normalize query to NFD for primary matching.
        // Also prepare NFC bytes for fallback if query has different NFC/NFD representations.
        let qNFD = q.decomposedStringWithCanonicalMapping
        let qNFC = q.precomposedStringWithCanonicalMapping
        let qBytes = Array(qNFD.utf8)
        let qAltBytes: [UInt8]? = (qNFC != qNFD) ? Array(qNFC.utf8) : nil
        let qMask: UInt64 = !qBytes.isEmpty ? qBytes.withUnsafeBufferPointer { letterMaskBytes($0) } : 0
        // Per-token byte arrays for independent multi-token scoring
        let tokenBytes: [[UInt8]]? = fuzzyTokens.count > 1 ? fuzzyTokens.map { Array($0.utf8) } : nil
        // Bitmask filter uses only ASCII letters/digits, which are identical across NFC/NFD, so no alt mask needed
        // Include extension token letters in the mask for candidate filtering
        var extMask: UInt64 = 0
        for ext in extTokenBytes {
            ext.withUnsafeBufferPointer { extMask |= letterMaskBytes($0) }
        }
        var dirMask: UInt64 = 0
        for seg in dirSegments {
            seg.withUnsafeBufferPointer { dirMask |= letterMaskBytes($0) }
        }
        let combinedMask = qMask | extMask | dirMask

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
        let baseMask: UInt64 = !baseBytes.isEmpty ? baseBytes.withUnsafeBufferPointer { letterMaskBytes($0) } : 0
        let suffixBytes: [UInt8]? = suffixPattern.map { Array($0.lowercased().utf8) }
        let queryHasDot = qBytes.contains(0x2E) || !extTokenBytes.isEmpty

        // Path importance prefixes for scoring (lowercased to match allBytes)
        let homePrefix = NSHomeDirectory().lowercased()
        let homePrefixBytes = Array(homePrefix.utf8)
        let importantPrefixes = [
            homePrefix + "/documents", homePrefix + "/desktop", homePrefix + "/downloads",
            homePrefix + "/projects", homePrefix + "/temp",
            homePrefix + "/library/mobile documents", // iCloud Drive
            "/applications",
        ].map { Array($0.utf8) }
        let libraryPrefix = Array((homePrefix + "/library").utf8)

        // Merge in: query tokens with folderPrefixes parameter
        let allFolderPrefixes: [String]? = {
            let combined = (folderPrefixes ?? []) + inPrefixes
            return combined.isEmpty ? nil : combined
        }()
        // Pre-convert prefixes to lowercased byte arrays (allBytes stores lowercased paths)
        let folderPrefixBytes: [[UInt8]]? = allFolderPrefixes?.map { Array($0.lowercased().utf8) }
        let excludedPrefixBytes: [[UInt8]]? = excludedPrefixes?.map { Array($0.lowercased().utf8) }

        // Phase 1: candidate filter
        let t1 = CFAbsoluteTimeGetCurrent()
        var cands = [Int]()
        cands.reserveCapacity(min(n, 50000))

        // Pre-compute excluded IDs for O(1) integer lookup instead of O(path_len) string hashing
        let excludedIDs: Set<Int>?
        if let excl = excludedPaths, !excl.isEmpty {
            ensurePathIndex()
            excludedIDs = Set(excl.compactMap { pathToID[$0] })
        } else {
            excludedIDs = nil
        }

        let isCancelled = cancelled ?? { false }

        // Common filter: mask, extension ID, excluded IDs/prefixes
        @inline(__always) func applyBaseFilters(_ i: Int) -> Bool {
            if hasFuzzyQuery, masks[i] & combinedMask != combinedMask { return false }
            if !hasFuzzyQuery, masks[i] == 0 { return false }

            // Extension ID prefilter: O(1) check instead of scoring all candidates
            if !extTokenIDs.isEmpty {
                let eid = extIDs[i]
                var matched = false
                var ei = 0
                while ei < extTokenIDs.count {
                    if eid == extTokenIDs[ei] { matched = true; break }
                    ei &+= 1
                }
                if !matched { return false }
            }

            if let excl = excludedIDs, excl.contains(i) { return false }

            let off = byteOffsets[i]
            let len = byteLengths[i]

            // Byte suffix fallback for extensions not in extToID (rare extensions)
            if extTokenIDs.count < extTokenBytes.count {
                var allExtMatch = true
                var ei = 0
                while ei < extTokenBytes.count {
                    let ext = extTokenBytes[ei]
                    if len >= ext.count {
                        var match = true
                        var j = 0
                        while j < ext.count {
                            if allBytes[off + len - ext.count + j] != ext[j] { match = false; break }
                            j &+= 1
                        }
                        if !match { allExtMatch = false; break }
                    } else { allExtMatch = false; break }
                    ei &+= 1
                }
                if !allExtMatch { return false }
            }

            if let prefixes = excludedPrefixBytes {
                var pi = 0
                while pi < prefixes.count {
                    let prefix = prefixes[pi]
                    if len >= prefix.count {
                        var ok = true
                        var j = 0
                        while j < prefix.count {
                            if allBytes[off + j] != prefix[j] { ok = false; break }
                            j &+= 1
                        }
                        if ok { return false }
                    }
                    pi &+= 1
                }
            }

            // Dir segment literal check: require e.g. "cling/" as a contiguous substring in the path
            if !dirSegments.isEmpty {
                var si = 0
                while si < dirSegments.count {
                    let seg = dirSegments[si]
                    let segLen = seg.count
                    guard len >= segLen else { return false }
                    var found = false
                    var p = 0
                    let limit = len - segLen
                    while p <= limit {
                        var ok = true
                        var j = 0
                        while j < segLen {
                            if allBytes[off + p + j] != seg[j] { ok = false; break }
                            j &+= 1
                        }
                        if ok { found = true; break }
                        p &+= 1
                    }
                    if !found { return false }
                    si &+= 1
                }
            }

            return true
        }

        // Full filter: base + dirsOnly + suffix (skipped when candidatePool already pre-filtered these)
        @inline(__always) func applyAllFilters(_ i: Int) -> Bool {
            guard applyBaseFilters(i) else { return false }

            if dirsOnly, !entries[i].isDir { return false }

            if let sfx = suffixBytes {
                let off = byteOffsets[i]
                let len = byteLengths[i]
                if len < sfx.count { return false }
                var match = true
                var j = 0
                while j < sfx.count {
                    if allBytes[off + len - sfx.count + j] != sfx[j] { match = false; break }
                    j &+= 1
                }
                if !match { return false }
            }

            return true
        }

        // Byte-level folder prefix check (shared by candidatePool and full scan paths)
        @inline(__always) func matchesFolderPrefix(_ i: Int) -> Bool {
            guard let prefixes = folderPrefixBytes else { return true }
            let off = byteOffsets[i]
            let len = byteLengths[i]
            var pi = 0
            while pi < prefixes.count {
                let prefix = prefixes[pi]
                if len >= prefix.count {
                    var ok = true
                    var j = 0
                    while j < prefix.count {
                        if allBytes[off + j] != prefix[j] { ok = false; break }
                        j &+= 1
                    }
                    if ok { return true }
                }
                pi &+= 1
            }
            return false
        }

        if let pool = candidatePool {
            // Pre-filtered candidate pool (from QuickFilter prefilter)
            // suffix/dirsOnly already applied, also apply folder prefix + mask + excluded
            var pi = 0
            while pi < pool.count {
                let i = pool[pi]
                if applyBaseFilters(i), matchesFolderPrefix(i) { cands.append(i) }
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
                    if applyAllFilters(i) { cands.append(i) }
                    idx &+= 1
                }
                pxi &+= 1
            }
        } else {
            // Parallel full scan across CPU cores
            let filterProcs = max(ProcessInfo.processInfo.activeProcessorCount, 1)
            let filterChunkSize = (n + filterProcs - 1) / filterProcs
            let filterChunks = (n + filterChunkSize - 1) / filterChunkSize
            let candStore = UnsafeMutablePointer<[Int]>.allocate(capacity: max(filterChunks, 1))
            candStore.initialize(repeating: [], count: max(filterChunks, 1))
            defer { candStore.deinitialize(count: max(filterChunks, 1)); candStore.deallocate() }

            masks.withUnsafeBufferPointer { maskBuf in
                let maskPtr = maskBuf.baseAddress!
                DispatchQueue.concurrentPerform(iterations: filterChunks) { chunk in
                    let lo = chunk * filterChunkSize
                    let hi = min(lo + filterChunkSize, n)
                    var local = [Int]()
                    local.reserveCapacity((hi - lo) / 10)

                    var i = lo
                    while i < hi {
                        if hasFuzzyQuery {
                            if maskPtr[i] & combinedMask != combinedMask { i &+= 1; continue }
                        } else {
                            if maskPtr[i] == 0 { i &+= 1; continue }
                        }
                        if !extTokenIDs.isEmpty {
                            let eid = self.extIDs[i]
                            var matched = false
                            var ei = 0
                            while ei < extTokenIDs.count {
                                if eid == extTokenIDs[ei] { matched = true; break }
                                ei &+= 1
                            }
                            if !matched { i &+= 1; continue }
                        }
                        if let excl = excludedIDs, excl.contains(i) { i &+= 1; continue }

                        let off = byteOffsets[i]
                        let len = byteLengths[i]

                        // Byte suffix fallback for extensions not in extToID (rare extensions)
                        if extTokenIDs.count < extTokenBytes.count {
                            var allExtMatch = true
                            var ei = 0
                            while ei < extTokenBytes.count {
                                let ext = extTokenBytes[ei]
                                if len >= ext.count {
                                    var match = true
                                    var j = 0
                                    while j < ext.count {
                                        if allBytes[off + len - ext.count + j] != ext[j] { match = false; break }
                                        j &+= 1
                                    }
                                    if !match { allExtMatch = false; break }
                                } else { allExtMatch = false; break }
                                ei &+= 1
                            }
                            if !allExtMatch { i &+= 1; continue }
                        }

                        if let prefixes = folderPrefixBytes {
                            var matched = false
                            var pi = 0
                            while pi < prefixes.count {
                                let prefix = prefixes[pi]
                                if len >= prefix.count {
                                    var ok = true
                                    var j = 0
                                    while j < prefix.count {
                                        if allBytes[off + j] != prefix[j] { ok = false; break }
                                        j &+= 1
                                    }
                                    if ok { matched = true; break }
                                }
                                pi &+= 1
                            }
                            if !matched { i &+= 1; continue }
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
                                        if allBytes[off + j] != prefix[j] { ok = false; break }
                                        j &+= 1
                                    }
                                    if ok { excluded = true; break }
                                }
                                pi &+= 1
                            }
                            if excluded { i &+= 1; continue }
                        }

                        if dirsOnly, !entries[i].isDir { i &+= 1; continue }

                        if let sfx = suffixBytes {
                            if len < sfx.count { i &+= 1; continue }
                            var match = true
                            var j = 0
                            while j < sfx.count {
                                if allBytes[off + len - sfx.count + j] != sfx[j] { match = false; break }
                                j &+= 1
                            }
                            if !match { i &+= 1; continue }
                        }

                        // Dir segment literal substring check (e.g. "cling/" must appear in path)
                        if !dirSegments.isEmpty {
                            var allFound = true
                            var si = 0
                            while si < dirSegments.count {
                                let seg = dirSegments[si]
                                let segLen = seg.count
                                if len < segLen { allFound = false; break }
                                var found = false
                                var p = 0
                                let limit = len - segLen
                                while p <= limit {
                                    var ok = true
                                    var j = 0
                                    while j < segLen {
                                        if allBytes[off + p + j] != seg[j] { ok = false; break }
                                        j &+= 1
                                    }
                                    if ok { found = true; break }
                                    p &+= 1
                                }
                                if !found { allFound = false; break }
                                si &+= 1
                            }
                            if !allFound { i &+= 1; continue }
                        }

                        local.append(i)
                        i &+= 1
                    }
                    candStore[chunk] = local
                }
            }

            // Merge chunk results
            var ci = 0
            while ci < filterChunks {
                cands.append(contentsOf: candStore[ci])
                ci &+= 1
            }
        }
        // Trigger lazy build of sorted path index for next folder-filtered search
        if folderPrefixBytes != nil, sortedByPath == nil {
            DispatchQueue.global(qos: .utility).async { [self] in buildSortedPathIndex() }
        }
        let filterMs = (CFAbsoluteTimeGetCurrent() - t1) * 1000
        if cands.count > 200_000 {
            // O(n) partial selection by path length using counting sort
            let maxPathLen = 4096
            let lenCounts = UnsafeMutablePointer<Int>.allocate(capacity: maxPathLen)
            lenCounts.initialize(repeating: 0, count: maxPathLen)
            var ci = 0
            while ci < cands.count {
                lenCounts[min(byteLengths[cands[ci]], maxPathLen - 1)] &+= 1; ci &+= 1
            }
            var cumul = 0, cutoff = maxPathLen - 1
            var li = 0
            while li < maxPathLen {
                cumul &+= lenCounts[li]
                if cumul >= 200_000 { cutoff = li; break }
                li &+= 1
            }
            lenCounts.deallocate()
            // Keep ALL entries at or below cutoff length (don't bias by entry order)
            var filtered = [Int]()
            filtered.reserveCapacity(cumul)
            ci = 0
            while ci < cands.count {
                if byteLengths[cands[ci]] <= cutoff {
                    filtered.append(cands[ci])
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
                    // Try fast ID check first, fall back to byte suffix
                    var matched = false
                    if !extTokenIDs.isEmpty {
                        var ei = 0
                        while ei < extTokenIDs.count {
                            if extIDs[id] == extTokenIDs[ei] { matched = true; break }
                            ei &+= 1
                        }
                    }
                    if !matched, extTokenIDs.count < extTokenBytes.count {
                        let off = byteOffsets[id]
                        let len = byteLengths[id]
                        matched = true
                        var ei = 0
                        while ei < extTokenBytes.count {
                            let ext = extTokenBytes[ei]
                            if len >= ext.count {
                                var ok = true
                                var j = 0
                                while j < ext.count {
                                    if allBytes[off + len - ext.count + j] != ext[j] { ok = false; break }
                                    j &+= 1
                                }
                                if !ok { matched = false; break }
                            } else { matched = false; break }
                            ei &+= 1
                        }
                    }
                    if matched { extFiltered.append(id) }
                    ci &+= 1
                }
                cands = extFiltered
            }

            // Partial sort: only need top maxResults by (segCount, pathLen)
            // Bucket by segCount first (typically 1-20), then take shortest paths
            if cands.count > maxResults * 2 {
                let maxSeg = 64
                let segBuckets = UnsafeMutablePointer<[Int]>.allocate(capacity: maxSeg)
                segBuckets.initialize(repeating: [], count: maxSeg)
                defer { segBuckets.deinitialize(count: maxSeg); segBuckets.deallocate() }
                var ci = 0
                while ci < cands.count {
                    let seg = min(entries[cands[ci]].segCount, maxSeg - 1)
                    segBuckets[seg].append(cands[ci])
                    ci &+= 1
                }
                var sorted = [Int]()
                sorted.reserveCapacity(maxResults)
                var si = 0
                while si < maxSeg, sorted.count < maxResults {
                    var bucket = segBuckets[si]
                    if !bucket.isEmpty {
                        if sorted.count + bucket.count > maxResults {
                            bucket.sort { byteLengths[$0] < byteLengths[$1] }
                            sorted.append(contentsOf: bucket.prefix(maxResults - sorted.count))
                        } else {
                            sorted.append(contentsOf: bucket)
                        }
                    }
                    si &+= 1
                }
                cands = sorted
            } else {
                cands.sort {
                    let aSeg = entries[$0].segCount, bSeg = entries[$1].segCount
                    if aSeg != bSeg { return aSeg < bSeg }
                    return byteLengths[$0] < byteLengths[$1]
                }
            }
            let results = cands.prefix(maxResults).map { id in
                let e = entries[id]
                return SearchResult(path: e.path, isDir: e.isDir, score: 0, quality: 0, hasBase: false, segmentMatches: 0, pathImportance: 0, prefixMatch: false, depth: e.segCount)
            }
            let totalMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            slog.debug("search: q=\"\(query)\" \(n) entries, \(cands.count) cands, \(results.count) results in \(totalMs, format: .fixed(precision: 1))ms (filter=\(filterMs, format: .fixed(precision: 1))ms)")
            return results
        }

        // Phase 2: fuzzy scoring
        let t2 = CFAbsoluteTimeGetCurrent()
        if isCancelled() { return [] }

        let nCands = cands.count
        let nProcs = max(ProcessInfo.processInfo.activeProcessorCount, 1)
        let chunkSize = max(nCands / nProcs, 512)
        let nChunks = nCands == 0 ? 0 : (nCands + chunkSize - 1) / chunkSize
        let chunkStore = UnsafeMutablePointer<[ScoredEntry]>.allocate(capacity: max(nChunks, 1))
        chunkStore.initialize(repeating: [], count: max(nChunks, 1))
        defer { chunkStore.deinitialize(count: max(nChunks, 1)); chunkStore.deallocate() }

        allBytes.withUnsafeBufferPointer { allBuf in
            let allBase = allBuf.baseAddress!

            qBytes.withUnsafeBufferPointer { qBuf in
                baseBytes.withUnsafeBufferPointer { baseBuf in
                    DispatchQueue.concurrentPerform(iterations: nChunks) { chunk in
                        let lo = chunk * chunkSize
                        let hi = min(lo + chunkSize, nCands)
                        var local = [ScoredEntry]()
                        local.reserveCapacity(hi - lo)
                        var idx = lo
                        while idx < hi {
                            if idx & 0x1FF == 0, isCancelled() { break }
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
                                    for token in tokens {
                                        token.withUnsafeBufferPointer { tBuf in
                                            guard allTokensMatchPath, pathSearchFrom < len else {
                                                allTokensMatchPath = false; return
                                            }
                                            let slice = UnsafeBufferPointer(start: allBase + off + pathSearchFrom, count: len - pathSearchFrom)
                                            if let r = fuzzyScoreBytes(tBuf, slice, boundaries: bnBounds, boundariesOffset: max(0, bnOff - pathSearchFrom)) {
                                                tokenPathScore &+= r.score
                                                let absStart = pathSearchFrom + r.start
                                                let absEnd = pathSearchFrom + r.end
                                                tokenPathStart = min(tokenPathStart, absStart)
                                                tokenPathEnd = max(tokenPathEnd, absEnd)
                                                // Check if match starts at a segment boundary (after / or start of path)
                                                if absStart == 0 || allBase[off + absStart - 1] == 0x2F {
                                                    tokenSegMatches &+= 1
                                                }
                                                pathSearchFrom = absEnd
                                            } else { allTokensMatchPath = false }
                                        }
                                    }
                                    if allTokensMatchPath, tokenPathScore > pathScore {
                                        pathScore = tokenPathScore; pathWindow = tokenPathEnd - tokenPathStart
                                        segMatches = tokenSegMatches
                                    }

                                    var tokenBaseScore = 0, tokenBaseStart = Int.max, tokenBaseEnd = 0
                                    var allTokensMatchBase = true
                                    var baseSearchFrom = 0
                                    let bnLen = len - bnOff
                                    for token in tokens {
                                        token.withUnsafeBufferPointer { tBuf in
                                            guard allTokensMatchBase, baseSearchFrom < bnLen else {
                                                allTokensMatchBase = false; return
                                            }
                                            let slice = UnsafeBufferPointer(start: allBase + off + bnOff + baseSearchFrom, count: bnLen - baseSearchFrom)
                                            if let r = fuzzyScoreBytes(tBuf, slice, boundaries: bnBounds, boundariesOffset: baseSearchFrom) {
                                                tokenBaseScore &+= r.score
                                                tokenBaseStart = min(tokenBaseStart, baseSearchFrom + r.start)
                                                tokenBaseEnd = max(tokenBaseEnd, baseSearchFrom + r.end)
                                                baseSearchFrom = baseSearchFrom + r.end
                                            } else { allTokensMatchBase = false }
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
                                            if let r = fuzzyScoreBytes(altBaseBuf, bnBuf, boundaries: bnBounds) {
                                                baseScore = r.score; baseWindow = r.end - r.start
                                            }
                                            if let r = fuzzyScoreBytes(altQBuf, pathBuf, boundaries: bnBounds, boundariesOffset: bnOff) {
                                                pathScore = r.score; pathWindow = r.end - r.start
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

                            // Path importance (higher = more relevant to user):
                            //   4 = important user dir (Documents, Desktop, Downloads, Projects, /Applications)
                            //   3 = other home visible
                            //   2 = home Library visible
                            //   1 = system/root visible
                            //   0 = hidden (dotfile/dotdir in path)
                            let sPathImportance: Int32
                            let isHidden: Bool = !queryHasDot && {
                                let bnOff = e.bnStart
                                if bnOff < len, allBase[off + bnOff] == 0x2E { return true }
                                var p = 0
                                while p < len {
                                    if allBase[off + p] == 0x2F, p + 1 < len, allBase[off + p + 1] == 0x2E { return true }
                                    p &+= 1
                                }
                                return false
                            }()
                            if isHidden {
                                sPathImportance = 0
                            } else {
                                // Check important dirs first
                                var important = false
                                var ipi = 0
                                while ipi < importantPrefixes.count {
                                    let pfx = importantPrefixes[ipi]
                                    if len >= pfx.count {
                                        var ok = true; var j = 0
                                        while j < pfx.count {
                                            if allBase[off + j] != pfx[j] { ok = false; break }
                                            j &+= 1
                                        }
                                        if ok { important = true; break }
                                    }
                                    ipi &+= 1
                                }
                                if important {
                                    sPathImportance = 4
                                } else if len >= homePrefixBytes.count, {
                                    var hp = 0
                                    while hp < homePrefixBytes.count {
                                        if allBase[off + hp] != homePrefixBytes[hp] { return false }
                                        hp &+= 1
                                    }
                                    return true
                                }() {
                                    // Home path: check if Library (lower priority) or other home
                                    var isLib = len >= libraryPrefix.count
                                    if isLib {
                                        var j = 0
                                        while j < libraryPrefix.count {
                                            if allBase[off + j] != libraryPrefix[j] { isLib = false; break }
                                            j &+= 1
                                        }
                                    }
                                    sPathImportance = isLib ? 2 : 3
                                } else {
                                    sPathImportance = 1
                                }
                            }

                            // Prefix/extension match
                            let sPrefixMatch: Int32
                            let bnLen = len - e.bnStart

                            // Check extension tokens against entry's extension ID (O(1)) or fallback to byte suffix
                            var extOK = false
                            if !extTokenIDs.isEmpty {
                                let eid = self.extIDs[id]
                                var ei = 0
                                while ei < extTokenIDs.count {
                                    if eid == extTokenIDs[ei] { extOK = true; break }
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
                                            if allBase[off + e.bnStart + bnLen - ext.count + p] != ext[p] { match = false; break }
                                            p &+= 1
                                        }
                                        if match { extOK = true; break }
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
                                        if allBase[bnBase + p] != token[p] { prefixOK = false; break }
                                        p &+= 1
                                    }
                                    if prefixOK { found = true }
                                    if !found {
                                        // Check after each word boundary (space, dash, underscore, dot, slash)
                                        var bi = 1
                                        while bi + tLen <= bnLen {
                                            let prev = allBase[bnBase + bi - 1]
                                            if prev == 0x20 || prev == 0x2D || prev == 0x5F || prev == 0x2E || prev == 0x2F {
                                                var ok = true; p = 0
                                                while p < tLen {
                                                    if allBase[bnBase + bi + p] != token[p] { ok = false; break }
                                                    p &+= 1
                                                }
                                                if ok { found = true; break }
                                            }
                                            bi &+= 1
                                        }
                                    }
                                    if found { tokenBoundaryCount &+= 1 }
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
                                    if allBase[bnBase + p] != baseBytes[p] { prefixOK = false; break }
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
                                                if allBase[bnBase + bi + p] != baseBytes[p] { ok = false; break }
                                                p &+= 1
                                            }
                                            if ok { boundaryMatch = true; break }
                                        }
                                        bi &+= 1
                                    }
                                    sPrefixMatch = boundaryMatch ? 1 : 0
                                }
                            } else {
                                sPrefixMatch = extOK ? 2 : 0
                            }

                            let tight = hasBase ? baseWindow : pathWindow
                            let sTight = Int32(-tight)
                            let sBase = Int32(hasBase ? baseScore : -1000)
                            let sPath = Int32(hasPath ? pathScore : -1000)
                            let sDir = Int32(wantDir ? (e.isDir ? 100 : -100) : 0)
                            let sDepth = Int32(-e.segCount)
                            let sShorter = Int32(-e.pathLen)

                            let best = max(hasBase ? baseScore : 0, hasPath ? pathScore : 0)
                            let queryLen = !qBytes.isEmpty ? qBytes.count : dirSegments.reduce(0) { $0 + $1.count }
                            let qual: Int = if hasBase {
                                baseScore * baseBytes.count / max(baseWindow, 1)
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
        var scored = [ScoredEntry]()
        var totalScored = 0
        for i in 0 ..< nChunks {
            totalScored &+= chunkStore[i].count
        }
        scored.reserveCapacity(min(totalScored, maxResults * 4))
        for i in 0 ..< nChunks {
            scored.append(contentsOf: chunkStore[i])
        }

        if isCancelled() { return [] }

        let t3 = CFAbsoluteTimeGetCurrent()
        scored.sort { $0.key < $1.key }
        let sortMs = (CFAbsoluteTimeGetCurrent() - t3) * 1000

        if !scored.isEmpty {
            let topQ = scored[0].quality
            let minQ = max(topQ * 4 / 10, qBytes.count * scoreMatch / 2)
            scored = scored.filter { $0.quality >= minQ }
        }

        // Keep a wider pool (4x maxResults) then sort by rank to ensure high-scoring
        // path matches aren't eclipsed by lower-scoring basename matches
        let pool = scored.prefix(maxResults * 4)
        var results = pool.map { s in
            let e = entries[s.id]
            return SearchResult(path: e.path, isDir: e.isDir, score: s.bestScore, quality: s.quality, hasBase: s.hasBase, segmentMatches: s.segmentMatches, pathImportance: Int(s.key.c), prefixMatch: s.key.b > 0, depth: e.segCount)
        }
        results.sort { $0 > $1 }
        results = Array(results.prefix(maxResults))

        let totalMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        slog
            .debug(
                "search: q=\"\(query)\" \(n) entries, \(cands.count) cands, \(scored.count) scored, \(results.count) results in \(totalMs, format: .fixed(precision: 1))ms (filter=\(filterMs, format: .fixed(precision: 1))ms score=\(scoreMs, format: .fixed(precision: 1))ms sort=\(sortMs, format: .fixed(precision: 1))ms)"
            )
        return results
    }

    // MARK: - Search

    // Sort dimensions (all descending: higher = better):
    //   a = has_base:       1 if basename matched (non-slash queries), else 0
    //   b = prefix_match:   1 if basename starts/ends with query or extension token
    //   c = path_importance: 4=important user dir, 3=home, 2=library, 1=system, 0=hidden
    //   d = basename:     fuzzy score of query vs basename (checked before tightness so boundary matches win)
    //   e = tightness:    -(match window width), tighter = better
    //   f = fullpath:     fuzzy score of query vs full path
    //   g = dir_bonus:    +100 if dir and query ends with /, -100 if file, 0 if no /
    //   h = depth:        -(segment count), shallower = better
    //   i = shorter:      -(path byte length), shorter = better
    private struct SortKey: Comparable {
        let a, b, c, d, e, f, g, h, i: Int32

        @inline(__always) static func < (l: SortKey, r: SortKey) -> Bool {
            if l.a != r.a { return l.a > r.a }
            if l.b != r.b { return l.b > r.b }
            if l.c != r.c { return l.c > r.c }
            if l.d != r.d { return l.d > r.d }
            if l.e != r.e { return l.e > r.e }
            if l.f != r.f { return l.f > r.f }
            if l.g != r.g { return l.g > r.g }
            if l.h != r.h { return l.h > r.h }
            return l.i > r.i
        }
        @inline(__always) static func == (l: SortKey, r: SortKey) -> Bool {
            l.a == r.a && l.b == r.b && l.c == r.c && l.d == r.d && l.e == r.e && l.f == r.f && l.g == r.g && l.h == r.h && l.i == r.i
        }
    }

    private struct ScoredEntry {
        let id: Int
        let key: SortKey
        let bestScore: Int
        let quality: Int
        let hasBase: Bool
        var segmentMatches = 0
    }

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

    private var masks: [UInt64] = []
    private var bnMasks: [UInt64] = []
    private var allBytes: [UInt8] = []
    private var byteOffsets: [Int] = []
    private var byteLengths: [Int] = []

    private var extIDs: [UInt16] = [] // Extension ID per entry (0 = no extension)

    private var free: [Int] = []
    private var pathToID: [String: Int] = [:]
    private var pathIndexBuilt = false
    private var sortedByPath: [Int]?

    /// Lock for thread-safe mutations during parallel walks
    private let lock = NSLock()

    // Per-engine accessors that delegate to global state
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

    // MARK: - FTS Filesystem Walker

    /// Build a set of file extension patterns from an ignore file (patterns like "*.pyc", "*.o")
    private static func extractExtensionPatterns(from ignoreContent: String) -> Set<String> {
        var exts = Set<String>()
        for line in ignoreContent.components(separatedBy: .newlines) {
            let p = line.trimmingCharacters(in: .whitespaces)
            if p.hasPrefix("*."), !p.contains("/"), p.dropFirst(2).allSatisfy({ $0 != "*" }) {
                exts.insert(String(p.dropFirst(1))) // keep the dot: ".pyc"
            }
        }
        return exts
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
            if j == cmpLen { less = len < prefix.count }
            if less { lo = mid &+ 1 } else { hi = mid }
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
                if allBytes[off + j] != prefix[j] { starts = false; break }
                j &+= 1
            }
            if starts { lo = mid &+ 1 } else { hi = mid }
        }
        return lo
    }

    /// Compute extIDs for all entries that don't have one yet (after binary index load)
    private func computeExtIDs() {
        let n = entries.count
        if extIDs.count < n {
            extIDs.append(contentsOf: repeatElement(UInt16(0), count: n - extIDs.count))
        }
        allBytes.withUnsafeBufferPointer { buf in
            let base = buf.baseAddress!
            var i = 0
            while i < n {
                if extIDs[i] == 0, byteLengths[i] > 0 {
                    extIDs[i] = extID(for: base + byteOffsets[i], len: byteLengths[i], bnStart: entries[i].bnStart)
                }
                i &+= 1
            }
        }
        let extCount = extToID.count
        slog.debug("computeExtIDs: \(extCount) unique extensions for \(n) entries")
    }

    /// Get or assign a numeric ID for a file extension using byte-level hashing
    @inline(__always) private func extID(for bytes: UnsafePointer<UInt8>, len: Int, bnStart: Int) -> UInt16 {
        // Scan backward from end to find last '.' in basename
        var dotPos = -1
        var k = len - 1
        while k >= bnStart {
            if bytes[k] == 0x2E { dotPos = k; break }
            if bytes[k] == 0x2F { break }
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
        pathIndexBuilt = true
        buildPathIndex()
    }

    // MARK: - Unlocked internals (caller must hold lock)

    private func _addPath(_ path: String, isDir: Bool) -> Int {
        ensurePathIndex()
        if let existing = pathToID[path] { return existing }

        let byteOff = allBytes.count
        var bnStart = 0, segCount = 1
        var mask: UInt64 = 0, bnMaskAccum: UInt64 = 0
        var pathLen = 0
        var boundaries: UInt64 = 0

        // Use withUTF8 to avoid iterator overhead in debug builds
        var _path = path
        _path.withUTF8 { utf8 in
            var p = 0
            var prevCC: CC = .delim // treat start of path as delimiter boundary
            while p < utf8.count {
                let orig = utf8[p]
                let low = toLowerByte(orig)
                allBytes.append(low)
                pathLen &+= 1

                if low == 0x2F {
                    segCount &+= 1
                    bnStart = pathLen
                    bnMaskAccum = 0
                    boundaries = 0
                    prevCC = .delim
                } else {
                    var bit: UInt64 = 0
                    if low >= 0x61, low <= 0x7A { bit = 1 << UInt64(low &- 0x61) }
                    else if low >= 0x30, low <= 0x39 { bit = 1 << UInt64(26 &+ low &- 0x30) }
                    else if low == 0x2E { bit = 1 << 36 }
                    else if low == 0x2D { bit = 1 << 37 }
                    else if low == 0x5F { bit = 1 << 38 }
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
                        if isBoundary { boundaries |= 1 << UInt64(bnPos) }
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

        let entry = Entry(
            path: path,
            isDir: isDir,
            bnStart: bnStart,
            segCount: segCount,
            pathLen: pathLen
        )
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
        pathToID[path] = id
        return id
    }

    private func _removePath(_ path: String) -> Bool {
        ensurePathIndex()
        guard let id = pathToID.removeValue(forKey: path) else { return false }
        entries[id] = Entry(path: "", isDir: false, bnStart: 0, segCount: 0, pathLen: 0)
        masks[id] = 0
        bnMasks[id] = 0
        bnBoundaries[id] = 0
        byteOffsets[id] = 0
        byteLengths[id] = 0
        extIDs[id] = 0
        free.append(id)
        return true
    }

    /// Bulk-add without pathToID dedup check (for initial load only).
    /// Caller must hold the lock.
    private func _bulkAddPath(_ path: String, isDir: Bool) {
        let byteOff = allBytes.count
        var bnStart = 0, segCount = 1
        var mask: UInt64 = 0, bnMaskAccum: UInt64 = 0
        var pathLen = 0

        var _path = path
        _path.withUTF8 { utf8 in
            var p = 0
            while p < utf8.count {
                let low = toLowerByte(utf8[p])
                allBytes.append(low)
                pathLen &+= 1
                if low == 0x2F {
                    segCount &+= 1
                    bnStart = pathLen
                    bnMaskAccum = 0
                } else {
                    var bit: UInt64 = 0
                    if low >= 0x61, low <= 0x7A { bit = 1 << UInt64(low &- 0x61) }
                    else if low >= 0x30, low <= 0x39 { bit = 1 << UInt64(26 &+ low &- 0x30) }
                    else if low == 0x2E { bit = 1 << 36 }
                    else if low == 0x2D { bit = 1 << 37 }
                    else if low == 0x5F { bit = 1 << 38 }
                    mask |= bit
                    bnMaskAccum |= bit
                }
                p &+= 1
            }
        }

        entries.append(Entry(path: path, isDir: isDir, bnStart: bnStart, segCount: segCount, pathLen: pathLen))
        masks.append(mask)
        bnMasks.append(bnMaskAccum)
        byteOffsets.append(byteOff)
        byteLengths.append(pathLen)
        let eid = allBytes.withUnsafeBufferPointer { buf in
            extID(for: buf.baseAddress! + byteOff, len: pathLen, bnStart: bnStart)
        }
        extIDs.append(eid)
    }

}
