import Darwin
import Foundation

// MARK: - Reading index files

/// Asks the kernel to start reading the whole file into the cache now. Index files are loaded or mapped and then read
/// front to back; left to page faults, a cold file comes in at about 1 GB/s, while one read-ahead request lets the SSD
/// deliver it at its own speed (9 GB/s on an M5).
func adviseSequentialRead(_ path: String) {
    let fd = open(path, O_RDONLY)
    guard fd >= 0 else { return }
    defer { close(fd) }
    var st = stat()
    guard fstat(fd, &st) == 0, st.st_size > 0 else { return }
    var offset: off_t = 0
    // radvisory.ra_count is an Int32, so a file past 2 GB is advised in pieces.
    let chunk: off_t = 1 << 30
    while offset < st.st_size {
        var ra = radvisory(ra_offset: offset, ra_count: Int32(min(chunk, st.st_size - offset)))
        _ = fcntl(fd, F_RDADVISE, &ra)
        offset += chunk
    }
}

// MARK: - AtomicFileWriter

/// Writes a file through a small buffer to a temporary name and renames it over the destination when done, so a crash
/// or a full disk mid-write leaves the previous file whole, and nothing the size of the file is held in memory.
final class AtomicFileWriter {
    init?(destination: String) {
        self.destination = destination
        temporary = destination + ".saving"
        fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return nil }
        buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
    }

    deinit {
        buffer.deallocate()
        if fd >= 0 {
            close(fd)
            unlink(temporary)
        }
    }

    let destination: String
    let temporary: String
    private(set) var written = 0
    private(set) var failed = false

    var position: Int {
        written + used
    }

    func write(_ bytes: UnsafeRawPointer, count: Int) {
        guard !failed, count > 0 else { return }
        if used + count > capacity {
            flush()
        }
        if count >= capacity {
            writeOut(bytes, count)
            return
        }
        memcpy(buffer + used, bytes, count)
        used += count
    }

    func write(_ value: some Any) {
        withUnsafeBytes(of: value) { write($0.baseAddress!, count: $0.count) }
    }

    func write(zeros count: Int) {
        var left = count
        while left > 0 {
            if used == capacity {
                flush()
            }
            let n = min(left, capacity - used)
            memset(buffer + used, 0, n)
            used += n
            left -= n
        }
    }

    /// Pads with zeros up to the next multiple of `alignment`.
    func align(to alignment: Int) {
        let total = written + used
        let pad = (alignment - total % alignment) % alignment
        write(zeros: pad)
    }

    /// Flushes, closes and renames over the destination. Returns false, and leaves the destination alone, if any write
    /// failed.
    func commit() -> Bool {
        flush()
        let ok = !failed && close(fd) == 0
        fd = -1
        guard ok, rename(temporary, destination) == 0 else {
            unlink(temporary)
            return false
        }
        return true
    }

    private let capacity = 1 << 20
    private var buffer: UnsafeMutableRawPointer
    private var used = 0
    private var fd: Int32

    private func flush() {
        guard used > 0 else { return }
        writeOut(buffer, used)
        used = 0
    }

    private func writeOut(_ bytes: UnsafeRawPointer, _ count: Int) {
        var off = 0
        while off < count, !failed {
            let n = Darwin.write(fd, bytes + off, count - off)
            if n <= 0 {
                if n < 0, errno == EINTR {
                    continue
                }
                failed = true
                break
            }
            off += n
        }
        written += off
    }
}

// MARK: - ColumnStorage

/// The memory behind a column: plain values (nothing reference-counted inside) in one contiguous block that grows by
/// doubling. Freed explicitly by its owner.
struct ColumnStorage<T> {
    init() {
        base = UnsafeMutablePointer<T>.allocate(capacity: 1)
        capacity = 1
    }

    private(set) var base: UnsafeMutablePointer<T>
    private(set) var count = 0
    private(set) var capacity: Int

    mutating func reserve(_ minimumCapacity: Int) {
        guard minimumCapacity > capacity else { return }
        let bytes = minimumCapacity * MemoryLayout<T>.stride
        guard let grown = realloc(base, bytes) else { fatalError("ColumnStorage: out of memory growing to \(bytes) bytes") }
        base = grown.assumingMemoryBound(to: T.self)
        capacity = minimumCapacity
    }

    @inline(__always) mutating func append(_ value: T) {
        if count == capacity {
            reserve(Swift.max(16, capacity &* 2))
        }
        (base + count).initialize(to: value)
        count &+= 1
    }

    mutating func append(raw source: UnsafeRawPointer, count n: Int) {
        guard n > 0 else { return }
        if count + n > capacity {
            reserve(Swift.max(count + n, capacity &* 2))
        }
        memcpy(base + count, source, n * MemoryLayout<T>.stride)
        count &+= n
    }

    mutating func append(repeating value: T, count n: Int) {
        guard n > 0 else { return }
        if count + n > capacity {
            reserve(Swift.max(count + n, capacity &* 2))
        }
        (base + count).initialize(repeating: value, count: n)
        count &+= n
    }

    /// Sets the count without initializing anything, for callers that fill the memory themselves.
    mutating func setCount(_ n: Int) {
        reserve(n)
        count = n
    }

    mutating func removeAll() {
        count = 0
    }

    func release() {
        free(base)
    }
}

// MARK: - Column

/// A growable array of plain values kept per index entry. The engine's lock guards it; it does no locking itself.
final class Column<T> {
    deinit {
        storage.release()
    }

    var storage = ColumnStorage<T>()

    @inline(__always) var count: Int {
        storage.count
    }
    @inline(__always) var isEmpty: Bool {
        storage.count == 0
    }
    var capacity: Int {
        storage.capacity
    }
    var byteCount: Int {
        storage.count * MemoryLayout<T>.stride
    }

    @inline(__always) subscript(i: Int) -> T {
        get {
            assert(i >= 0 && i < storage.count, "Column index \(i) out of range 0..<\(storage.count)")
            return storage.base[i]
        }
        set {
            assert(i >= 0 && i < storage.count, "Column index \(i) out of range 0..<\(storage.count)")
            storage.base[i] = newValue
        }
    }

    @inline(__always) func append(_ value: T) {
        storage.append(value)
    }
    func append(repeating value: T, count: Int) {
        storage.append(repeating: value, count: count)
    }
    func append(raw source: UnsafeRawPointer, count: Int) {
        storage.append(raw: source, count: count)
    }
    func reserveCapacity(_ n: Int) {
        storage.reserve(n)
    }
    func removeAll() {
        storage.removeAll()
    }

    @inline(__always) func withUnsafeBufferPointer<R>(_ body: (UnsafeBufferPointer<T>) throws -> R) rethrows -> R {
        try body(UnsafeBufferPointer(start: storage.base, count: storage.count))
    }

    @inline(__always) func withUnsafeMutableBufferPointer<R>(_ body: (UnsafeMutableBufferPointer<T>) throws -> R) rethrows -> R {
        try body(UnsafeMutableBufferPointer(start: storage.base, count: storage.count))
    }
}

// MARK: - IntColumn

/// A column of unsigned integers narrower than `Int`, read and written as `Int`: the engine's arithmetic stays in
/// `Int` while each value takes 2 or 4 bytes instead of 8. Values are stored truncated, so callers keep them in range.
final class IntColumn<S: FixedWidthInteger & UnsignedInteger> {
    deinit {
        storage.release()
    }

    var storage = ColumnStorage<S>()

    @inline(__always) var count: Int {
        storage.count
    }
    var byteCount: Int {
        storage.count * MemoryLayout<S>.stride
    }

    @inline(__always) subscript(i: Int) -> Int {
        get {
            assert(i >= 0 && i < storage.count, "IntColumn index \(i) out of range 0..<\(storage.count)")
            return Int(storage.base[i])
        }
        set {
            assert(i >= 0 && i < storage.count, "IntColumn index \(i) out of range 0..<\(storage.count)")
            storage.base[i] = S(truncatingIfNeeded: newValue)
        }
    }

    @inline(__always) func append(_ value: Int) {
        storage.append(S(truncatingIfNeeded: value))
    }
    func append(raw source: UnsafeRawPointer, count: Int) {
        storage.append(raw: source, count: count)
    }
    func reserveCapacity(_ n: Int) {
        storage.reserve(n)
    }
    func removeAll() {
        storage.removeAll()
    }
}

// MARK: - PathTable

/// Path to entry id, keeping only the ids: 4 bytes a slot where a `[String: Int]` kept a String key and an Int per
/// entry. The engine hashes paths from its own stored bytes and compares candidates against them, so the table never
/// holds a path itself.
struct PathTable {
    static let emptySlot: UInt32 = 0
    static let removedSlot: UInt32 = .max

    private(set) var slots: [UInt32] = []
    private(set) var live = 0

    var isEmpty: Bool {
        slots.isEmpty
    }
    var memoryBytes: Int {
        slots.capacity * 4
    }

    /// The FNV-style hash of `len` bytes, 8 at a time. Callers hash ASCII-lowercased bytes so the stored, lowercased
    /// copy of a path hashes the same without being rebuilt.
    @inline(__always) static func hash(_ p: UnsafePointer<UInt8>, _ len: Int) -> Int {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325 ^ UInt64(len)
        var k = 0
        let raw = UnsafeRawPointer(p)
        while k &+ 8 <= len {
            h = (h ^ raw.loadUnaligned(fromByteOffset: k, as: UInt64.self)) &* 0x0000_0100_0000_01B3
            h ^= h >> 29
            k &+= 8
        }
        var tail: UInt64 = 0
        var shift: UInt64 = 0
        while k < len {
            tail |= UInt64(p[k]) << shift
            shift &+= 8
            k &+= 1
        }
        h = (h ^ tail) &* 0x0000_0100_0000_01B3
        // fmix64
        h ^= h >> 33
        h = h &* 0xFF51_AFD7_ED55_8CCD
        h ^= h >> 33
        h = h &* 0xC4CE_B9FE_1A85_EC53
        h ^= h >> 33
        return Int(truncatingIfNeeded: h)
    }

    /// An empty table sized for `n` paths.
    mutating func reset(capacityFor n: Int) {
        var cap = 16
        while cap * 3 < (n + 1) * 4 {
            cap <<= 1
        }
        slots = [UInt32](repeating: Self.emptySlot, count: cap)
        live = 0
        used = 0
    }

    func find(hash: Int, matches: (Int) -> Bool) -> Int? {
        guard !slots.isEmpty else { return nil }
        let mask = slots.count - 1
        var s = hash & mask
        while true {
            let v = slots[s]
            if v == Self.emptySlot {
                return nil
            }
            if v != Self.removedSlot, matches(Int(v) - 1) {
                return Int(v) - 1
            }
            s = (s + 1) & mask
        }
    }

    /// Adds an id that isn't in the table. `rehash` gives any id's hash, for when the table grows.
    mutating func insert(id: Int, hash: Int, rehash: (Int) -> Int) {
        if slots.isEmpty || (used + 1) * 4 > slots.count * 3 {
            let old = slots
            reset(capacityFor: max(live + 1, live * 2))
            for v in old where v != Self.emptySlot && v != Self.removedSlot {
                place(v, hash: rehash(Int(v) - 1))
            }
        }
        place(UInt32(id + 1), hash: hash)
    }

    /// Removes `id`, found by probing from its hash. Returns whether it was there.
    @discardableResult
    mutating func remove(id: Int, hash: Int) -> Bool {
        guard !slots.isEmpty else { return false }
        let mask = slots.count - 1
        let target = UInt32(id + 1)
        var s = hash & mask
        while true {
            let v = slots[s]
            if v == Self.emptySlot {
                return false
            }
            if v == target {
                slots[s] = Self.removedSlot
                live -= 1
                return true
            }
            s = (s + 1) & mask
        }
    }

    mutating func removeAll() {
        slots = []
        live = 0
        used = 0
    }

    /// Live ids plus removed markers: what the probe sequences have to step over.
    private var used = 0

    private mutating func place(_ value: UInt32, hash: Int) {
        let mask = slots.count - 1
        var s = hash & mask
        while slots[s] != Self.emptySlot {
            s = (s + 1) & mask
        }
        slots[s] = value
        live += 1
        used += 1
    }
}
