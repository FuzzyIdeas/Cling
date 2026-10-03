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
