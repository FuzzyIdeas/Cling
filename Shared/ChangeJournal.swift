import CoreServices
import Foundation

// MARK: - FSEventsHistory

/// FSEvents keeps a log of file changes on each disk whether or not anything is watching, so an index saved with
/// its position in that log can catch up on launch by replaying from there instead of walking again.
enum FSEventsHistory {
    /// The sealed system volume only changes in a macOS update, and FSEvents doesn't report those.
    static var systemBuild: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    /// Identifies the data volume's FSEvents history; it changes when that history is thrown away.
    static var fseventsUUID: String {
        var st = stat()
        guard lstat("/Users", &st) == 0, let uuid = FSEventsCopyUUIDForDevice(st.st_dev) else { return "" }
        return CFUUIDCreateString(nil, uuid) as String? ?? ""
    }

    static func isRoot(_ path: String) -> Bool {
        path == "/" || path == "/System/Volumes/Data" || path == "/System/Volumes/Data/"
    }

    /// The data volume's own mount path maps back onto /, and the system's helper volumes and /dev are left out.
    static func normalized(_ raw: String) -> String? {
        var path = raw
        // A path bridged from NSString is copied to native storage once here, which keeps the hashing, comparing and
        // prefix checks that follow off the slow path. FSChangeStream's paths are native already.
        path.makeContiguousUTF8()
        if path.utf8.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        if path.hasPrefix("/System/Volumes/Data/") {
            return String(path.utf8.dropFirst("/System/Volumes/Data".utf8.count))!
        }
        guard !path.isEmpty, path != "/", !path.hasPrefix("/System/Volumes/"), !path.hasPrefix("/dev/") else { return nil }
        return path
    }
}

// MARK: - ChangeJournal

/// The file changes made while Cling is closed, gathered by its background agent (`cling catch-up`) every few hours,
/// so that opening Cling finds its indexes nearly current: it applies these and replays only what happened after the
/// agent last ran, instead of a day or more of FSEvents history, or a walk of every scope.
///
/// Only the paths and what happened to them are kept, merged per path. The agent never loads or writes the indexes,
/// which would mean reading and writing hundreds of MB every few hours.
///
/// On disk: one line of JSON (the header), then `flags<TAB>path<NUL>` for each path.
struct ChangeJournal {
    struct Header: Codable {
        /// The FSEvents position the changes follow. Every saved scope at or past it can use them.
        var start: UInt64
        /// The position they reach.
        var end: UInt64
        var system = FSEventsHistory.systemBuild
        var fseventsUUID = FSEventsHistory.fseventsUUID
        /// FSEvents dropped changes or lost its history, or there were too many to keep: the saved indexes can't catch
        /// up from here and are walked.
        var lost = false
        var lastRun = Date()
    }

    /// Cling's `-indexFolder` moves it along with the index.
    static let folder = UserDefaults.standard.string(forKey: "indexFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("com.lowtechguys.Cling", isDirectory: true)
    static let file = folder.appendingPathComponent("change-journal")
    /// Past this many paths it is cheaper to walk.
    static let maxPaths = 2_000_000

    var header: Header
    /// FSEvents flags of everything that happened to each path, merged.
    var changes: [String: UInt32] = [:]

    /// Whether these changes are from this disk's current FSEvents history and can be trusted.
    var usable: Bool {
        !header.lost && header.system == FSEventsHistory.systemBuild && header.fseventsUUID == FSEventsHistory.fseventsUUID
            && header.end <= FSEventsGetCurrentEventId()
    }

    static func readHeader() -> Header? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var line = Data()
        while let chunk = try? handle.read(upToCount: 4096), !chunk.isEmpty {
            if let newline = chunk.firstIndex(of: 0x0A) {
                line.append(chunk[chunk.startIndex ..< newline])
                return try? JSONDecoder().decode(Header.self, from: line)
            }
            line.append(chunk)
        }
        return nil
    }

    static func read() -> Self? {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
              let newline = data.firstIndex(of: 0x0A),
              let header = try? JSONDecoder().decode(Header.self, from: data[data.startIndex ..< newline])
        else { return nil }

        var journal = Self(header: header)
        data[(newline + 1)...].withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            let bytes = buf.bindMemory(to: UInt8.self)
            var i = 0
            while i < bytes.count {
                guard let tab = bytes[i...].firstIndex(of: 0x09), let end = bytes[tab...].firstIndex(of: 0) else { break }
                let flags = UInt32(String(decoding: UnsafeBufferPointer(rebasing: bytes[i ..< tab]), as: UTF8.self)) ?? 0
                let path = String(decoding: UnsafeBufferPointer(rebasing: bytes[(tab + 1) ..< end]), as: UTF8.self)
                journal.changes[path, default: 0] |= flags
                i = end + 1
            }
        }
        return journal
    }

    /// The indexes were saved at or past every change kept here, so they are no longer needed.
    static func discard(ifSavedPast position: UInt64) {
        guard let header = readHeader(), header.end <= position else { return }
        try? FileManager.default.removeItem(at: file)
    }

    func write() throws {
        var data = try JSONEncoder().encode(header)
        data.append(0x0A)
        data.reserveCapacity(data.count + changes.count * 96)
        for (path, flags) in changes {
            data.append(contentsOf: Array("\(flags)\t".utf8))
            data.append(contentsOf: Array(path.utf8))
            data.append(0)
        }
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try data.write(to: Self.file, options: .atomic)
    }

}
