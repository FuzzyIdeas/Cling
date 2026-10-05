//
//  ZipStream.swift
//  Cling
//
//  ZIPs for Web Access, written while they download.
//
//  The whole archive is laid out before a byte goes out, so it has an exact size (a real progress bar and time left in
//  every browser) and comes out as the same bytes every time (a dropped download picks up where it stopped, through
//  Range). Entries are stored rather than deflated: what comes off a Mac this way is mostly photos, videos and PDFs,
//  which are compressed already, and only stored entries have a size known in advance.
//
//  Each file's CRC-32 is read just before its header goes out. zlib does that at ~29 GB/s on Apple silicon, so the
//  cost is one extra read of the file, most of which the page cache then serves to the send. In exchange the archive
//  needs no data descriptors, which some unzippers mishandle for stored entries.
//

import CryptoKit
import Foundation
import zlib

// MARK: - ZipArchive

final class ZipArchive: @unchecked Sendable {
    /// Walks `items` (files, and folders with everything inside them) into an archive layout. Each item lands at the
    /// archive's top level under `name`.
    init(items: [(path: String, name: String)]) throws {
        var entries = [Entry]()
        var taken = Set<String>()
        let deadline = Date().addingTimeInterval(Self.planTimeout)
        for item in items {
            let name = Self.unique(item.name, in: &taken)
            try Self.add(path: item.path, name: name, top: true, to: &entries, deadline: deadline)
        }

        var offset: UInt64 = 0
        var centralSize: UInt64 = 0
        var newest = 0
        for i in entries.indices {
            entries[i].offset = offset
            offset += entries[i].headerLength + entries[i].dataLength
            centralSize += 46 + UInt64(entries[i].name.count) + 9 + entries[i].centralZip64ExtraLength
            newest = max(newest, entries[i].mtime)
        }
        self.entries = entries
        centralDirectoryOffset = offset
        self.centralSize = centralSize
        zip64End = entries.count >= 0xFFFF || offset >= 0xFFFF_FFFF || centralSize >= 0xFFFF_FFFF
        length = offset + centralSize + (zip64End ? 56 + 20 : 0) + 22
        lastModified = newest

        var hash = SHA256()
        for entry in entries {
            hash.update(data: entry.name)
            hash.update(data: Data(entry.identity.utf8))
        }
        etag = "\"z" + hash.finalize().prefix(16).map { String(format: "%02x", $0) }.joined() + "\""
    }

    enum PlanError: Error {
        case tooMany
        case unreadable
    }

    struct Entry {
        enum Kind {
            case file
            case directory
            case symlink(Data)
        }

        /// UTF-8 and NFC, "/" between components, a trailing "/" on folders.
        let name: Data
        let path: String
        let kind: Kind
        let size: UInt64
        let mtime: Int
        let mode: UInt16
        /// What the file was when it was planned, so a changed file gets its CRC read again.
        let identity: String
        var offset: UInt64 = 0

        var dataLength: UInt64 {
            switch kind {
            case .file: size
            case .directory: 0
            case let .symlink(target): UInt64(target.count)
            }
        }

        var zip64: Bool {
            dataLength >= 0xFFFF_FFFF
        }
        var headerLength: UInt64 {
            30 + UInt64(name.count) + 9 + (zip64 ? 20 : 0)
        }
        var centralZip64ExtraLength: UInt64 {
            let fields = (zip64 ? 2 : 0) + (offset >= 0xFFFF_FFFF ? 1 : 0)
            return fields == 0 ? 0 : 4 + 8 * UInt64(fields)
        }
    }

    /// Past this many entries an archive is refused: a whole home folder, picked by mistake.
    static let maxEntries = 100_000

    let entries: [Entry]
    let centralDirectoryOffset: UInt64
    let length: UInt64
    let etag: String
    /// Seconds since 1970 of the newest entry.
    let lastModified: Int

    func localHeader(_ index: Int) throws -> Data {
        let entry = entries[index]
        let crc = try crc(index)
        let (time, date) = Self.dosTime(entry.mtime)
        let size32 = entry.zip64 ? 0xFFFF_FFFF : UInt32(entry.dataLength)
        var d = Data(capacity: Int(entry.headerLength))
        d.le32(0x0403_4B50)
        d.le16(entry.zip64 ? 45 : 20)
        d.le16(Self.utf8Flag)
        d.le16(0) // stored
        d.le16(time)
        d.le16(date)
        d.le32(crc)
        d.le32(size32)
        d.le32(size32)
        d.le16(UInt16(entry.name.count))
        d.le16(9 + (entry.zip64 ? 20 : 0))
        d.append(entry.name)
        if entry.zip64 {
            d.le16(0x0001)
            d.le16(16)
            d.le64(entry.dataLength)
            d.le64(entry.dataLength)
        }
        d.appendTimestamp(entry.mtime)
        return d
    }

    /// The central directory and the end records, which need every entry's CRC.
    func tail() throws -> Data {
        var d = Data(capacity: Int(centralSize) + 100)
        for index in entries.indices {
            let entry = entries[index]
            let crc = try crc(index)
            let (time, date) = Self.dosTime(entry.mtime)
            let bigOffset = entry.offset >= 0xFFFF_FFFF
            let size32 = entry.zip64 ? 0xFFFF_FFFF : UInt32(entry.dataLength)
            d.le32(0x0201_4B50)
            d.le16(0x033F) // made by Unix, spec 6.3
            d.le16(entry.zip64 || bigOffset ? 45 : 20)
            d.le16(Self.utf8Flag)
            d.le16(0)
            d.le16(time)
            d.le16(date)
            d.le32(crc)
            d.le32(size32)
            d.le32(size32)
            d.le16(UInt16(entry.name.count))
            d.le16(UInt16(9 + entry.centralZip64ExtraLength))
            d.le16(0) // comment
            d.le16(0) // disk
            d.le16(0) // internal attributes
            var external = UInt32(entry.mode) << 16
            if case .directory = entry.kind {
                external |= 0x10
            }
            d.le32(external)
            d.le32(bigOffset ? 0xFFFF_FFFF : UInt32(entry.offset))
            d.append(entry.name)
            if entry.centralZip64ExtraLength > 0 {
                d.le16(0x0001)
                d.le16(UInt16(entry.centralZip64ExtraLength - 4))
                if entry.zip64 {
                    d.le64(entry.dataLength)
                    d.le64(entry.dataLength)
                }
                if bigOffset {
                    d.le64(entry.offset)
                }
            }
            d.appendTimestamp(entry.mtime)
        }

        let count = UInt64(entries.count)
        if zip64End {
            let recordOffset = centralDirectoryOffset + centralSize
            d.le32(0x0606_4B50)
            d.le64(44)
            d.le16(0x033F)
            d.le16(45)
            d.le32(0)
            d.le32(0)
            d.le64(count)
            d.le64(count)
            d.le64(centralSize)
            d.le64(centralDirectoryOffset)
            d.le32(0x0706_4B50)
            d.le32(0)
            d.le64(recordOffset)
            d.le32(1)
        }
        d.le32(0x0605_4B50)
        d.le16(0)
        d.le16(0)
        d.le16(count >= 0xFFFF ? 0xFFFF : UInt16(count))
        d.le16(count >= 0xFFFF ? 0xFFFF : UInt16(count))
        d.le32(centralSize >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(centralSize))
        d.le32(centralDirectoryOffset >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(centralDirectoryOffset))
        d.le16(0)
        return d
    }

    func crc(_ index: Int) throws -> UInt32 {
        let entry = entries[index]
        switch entry.kind {
        case .directory:
            return 0
        case let .symlink(target):
            return target.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
        case .file:
            if let known = ZipCRCCache.shared.get(entry.identity) {
                return known
            }
            let fd = open(entry.path, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { throw PlanError.unreadable }
            defer { close(fd) }
            let chunk = 4 << 20
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
            defer { buffer.deallocate() }
            var crc = crc32(0, nil, 0)
            var offset: UInt64 = 0
            while offset < entry.size {
                let want = Int(min(UInt64(chunk), entry.size - offset))
                let got = pread(fd, buffer, want, off_t(offset))
                // Shorter than planned: the archive can't keep the size it promised.
                guard got > 0 else { throw PlanError.unreadable }
                crc = crc32(crc, buffer.assumingMemoryBound(to: Bytef.self), uInt(got))
                offset += UInt64(got)
            }
            ZipCRCCache.shared.set(entry.identity, UInt32(crc))
            return UInt32(crc)
        }
    }

    /// The entry whose header or data holds `position`, which must be before the central directory.
    func entryIndex(at position: UInt64) -> Int {
        var low = 0
        var high = entries.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if entries[mid].offset <= position {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }

    /// Enumerating a big folder stops here and refuses the archive, so a download never waits on it for minutes.
    private static let planTimeout: TimeInterval = 20
    private static let utf8Flag: UInt16 = 0x0800

    private let centralSize: UInt64
    private let zip64End: Bool

    private static func unique(_ name: String, in taken: inout Set<String>) -> String {
        guard taken.contains(name) else {
            taken.insert(name)
            return name
        }
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !taken.contains(candidate) {
                taken.insert(candidate)
                return candidate
            }
            n += 1
        }
    }

    private static func add(path: String, name: String, top: Bool, to entries: inout [Entry], deadline: Date) throws {
        guard entries.count < maxEntries, Date() < deadline else { throw PlanError.tooMany }
        var st = stat()
        // A picked symlink stands for what it points to; one met inside a folder stays a link.
        guard (top ? stat(path, &st) : lstat(path, &st)) == 0 else { return }
        let identity = "\(st.st_dev):\(st.st_ino):\(st.st_size):\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
        let nfc = name.precomposedStringWithCanonicalMapping
        let mtime = st.st_mtimespec.tv_sec
        let mode = UInt16(st.st_mode)

        switch st.st_mode & S_IFMT {
        case S_IFREG:
            guard access(path, R_OK) == 0 else { return }
            entries.append(Entry(name: Data(nfc.utf8), path: path, kind: .file, size: UInt64(st.st_size), mtime: mtime, mode: mode, identity: identity))
        case S_IFLNK:
            var target = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let n = readlink(path, &target, Int(PATH_MAX))
            guard n > 0 else { return }
            let data = Data(bytes: target, count: n)
            entries.append(Entry(name: Data(nfc.utf8), path: path, kind: .symlink(data), size: UInt64(n), mtime: mtime, mode: mode, identity: identity))
        case S_IFDIR:
            entries.append(Entry(name: Data((nfc + "/").utf8), path: path, kind: .directory, size: 0, mtime: mtime, mode: mode, identity: identity))
            guard let children = try? FileManager.default.contentsOfDirectory(atPath: path) else { return }
            for child in children.sorted() where child != ".DS_Store" {
                let childPath = path == "/" ? "/" + child : path + "/" + child
                guard !WebAccessServer.isPrivate(childPath) else { continue }
                try add(path: childPath, name: name + "/" + child, top: false, to: &entries, deadline: deadline)
            }
        default:
            // Sockets, pipes and devices have no content to put in an archive.
            return
        }
    }

    private static func dosTime(_ seconds: Int) -> (time: UInt16, date: UInt16) {
        var t = time_t(seconds)
        var parts = tm()
        localtime_r(&t, &parts)
        let year = Int(parts.tm_year) + 1900
        guard year >= 1980 else { return (0, (1 << 5) | 1) }
        let clamped = min(year, 2107)
        let time = UInt16(parts.tm_hour) << 11 | UInt16(parts.tm_min) << 5 | UInt16(parts.tm_sec / 2)
        let date = UInt16(clamped - 1980) << 9 | UInt16(parts.tm_mon + 1) << 5 | UInt16(parts.tm_mday)
        return (time, date)
    }
}

// MARK: - ZipStream

/// One byte range of a `ZipArchive`, produced as it is sent.
final class ZipStream: HTTPBodyStream {
    init(archive: ZipArchive, range: ClosedRange<UInt64>) {
        self.archive = archive
        position = range.lowerBound
        end = range.upperBound + 1
        length = end - position
    }

    deinit { close() }

    let length: UInt64

    func read(max: Int) throws -> Data {
        var out = Data(capacity: max)
        while out.count < max, position < end {
            try fill(&out, room: Int(min(UInt64(max - out.count), end - position)))
        }
        return out
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    private let archive: ZipArchive
    private let end: UInt64
    private var position: UInt64
    private var header: (index: Int, data: Data)?
    private var tail: Data?
    private var fd: Int32 = -1
    private var fdIndex = -1

    private func fill(_ out: inout Data, room: Int) throws {
        if position >= archive.centralDirectoryOffset {
            if tail == nil {
                tail = try archive.tail()
            }
            let from = Int(position - archive.centralDirectoryOffset)
            let n = min(room, tail!.count - from)
            guard n > 0 else { throw ZipArchive.PlanError.unreadable }
            out.append(tail![from ..< from + n])
            position += UInt64(n)
            return
        }

        let index = archive.entryIndex(at: position)
        let entry = archive.entries[index]
        let dataStart = entry.offset + entry.headerLength
        if position < dataStart {
            if header?.index != index {
                header = try (index, archive.localHeader(index))
            }
            let bytes = header!.data
            let from = Int(position - entry.offset)
            let n = min(room, bytes.count - from)
            out.append(bytes[from ..< from + n])
            position += UInt64(n)
            return
        }

        let within = position - dataStart
        let n = Int(min(UInt64(room), entry.dataLength - within))
        switch entry.kind {
        case .directory:
            return
        case let .symlink(target):
            out.append(target[Int(within) ..< Int(within) + n])
            position += UInt64(n)
        case .file:
            if fdIndex != index {
                close()
                fd = open(entry.path, O_RDONLY | O_CLOEXEC)
                guard fd >= 0 else { throw ZipArchive.PlanError.unreadable }
                fdIndex = index
            }
            let start = out.count
            out.count += n
            let got = out.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + start, n, off_t(within)) }
            guard got > 0 else { throw ZipArchive.PlanError.unreadable }
            out.count = start + got
            position += UInt64(got)
        }
    }
}

// MARK: - ZipCRCCache

/// CRCs already read, by what each file was when it was read. A resumed download reuses them, so the files before the
/// resume point aren't read again just for the central directory.
final class ZipCRCCache: @unchecked Sendable {
    static let shared = ZipCRCCache()

    func get(_ identity: String) -> UInt32? {
        lock.withLock { crcs[identity] }
    }

    func set(_ identity: String, _ crc: UInt32) {
        lock.withLock {
            if crcs.count >= 200_000 {
                crcs.removeAll(keepingCapacity: true)
            }
            crcs[identity] = crc
        }
    }

    private let lock = NSLock()
    private var crcs: [String: UInt32] = [:]
}

// MARK: - Little-endian writers

private extension Data {
    mutating func le16(_ v: UInt16) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }

    mutating func le32(_ v: UInt32) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }

    mutating func le64(_ v: UInt64) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }

    /// The extended timestamp field (0x5455), modification time only, which unzippers prefer to the DOS time for
    /// being UTC and to the second.
    mutating func appendTimestamp(_ seconds: Int) {
        le16(0x5455)
        le16(5)
        append(1)
        le32(UInt32(truncatingIfNeeded: seconds))
    }
}
