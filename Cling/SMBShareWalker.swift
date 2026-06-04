import Darwin
import Foundation
import Lowtech
import os.log
import System

private let slog = Logger(subsystem: clingSubsystem, category: "SMBShareWalker")

// MARK: - NTSTATUS / SMB constants

typealias NTSTATUS = UInt32
private typealias SMBHANDLE = UnsafeMutableRawPointer
private typealias SMBFID = UInt64

private let STATUS_SUCCESS: NTSTATUS = 0x0000_0000
private let STATUS_NO_MORE_FILES: NTSTATUS = 0x8000_0006
private let STATUS_BUFFER_OVERFLOW: NTSTATUS = 0x8000_0005
private let STATUS_OBJECT_NAME_NOT_FOUND: NTSTATUS = 0xC000_0034
private let STATUS_OBJECT_PATH_NOT_FOUND: NTSTATUS = 0xC000_003A

private let FileIdBothDirectoryInformation: UInt8 = 37
private let SMB2_QUERY_DIRECTORY_RESTART_SCANS: UInt8 = 0x01

private let FILE_LIST_DIRECTORY_ACCESS: UInt32 = 0x100081
private let FILE_SHARE_READ_WRITE: UInt32 = 0x0003
private let FILE_OPEN_EXISTING: UInt32 = 0x0001
private let FILE_CREATE_OPTIONS_NONE: UInt32 = 0x0000_0000
private let FILE_CREATE_OPTIONS_DIRECTORY: UInt32 = 0x0000_0001

// MARK: - FileIdBothDirInfo

private struct FileIdBothDirInfo {
    var nextEntryOffset: UInt32
    var fileIndex: UInt32
    var creationTime: Int64
    var lastAccessTime: Int64
    var lastWriteTime: Int64
    var changeTime: Int64
    var endOfFile: Int64
    var allocationSize: Int64
    var fileAttributes: UInt32
    var fileNameLength: UInt32
    var eaSize: UInt32
    var shortNameLength: UInt8
    var reserved1: UInt8
    var shortName: (
        UInt16, UInt16, UInt16, UInt16,
        UInt16, UInt16, UInt16, UInt16,
        UInt16, UInt16, UInt16, UInt16
    )
    var reserved2: UInt16
    var fileId: UInt64
}

private let FILE_ATTRIBUTE_DIRECTORY: UInt32 = 0x0010
private let FILE_ATTRIBUTE_HIDDEN: UInt32 = 0x0002
private let FILE_ATTRIBUTE_REPARSE_POINT: UInt32 = 0x0400

// MARK: - FILETIME -> Date

private let filetimeEpochOffset: Int64 = 11_644_473_600

private func filetimeToDate(_ ft: Int64) -> Date {
    let seconds = Double(ft) / 10_000_000.0 - Double(filetimeEpochOffset)
    return Date(timeIntervalSince1970: seconds)
}

// MARK: - SMBFileMetadata

struct SMBFileMetadata: Codable {
    let size: Int64
    let modificationDate: Date
    let creationDate: Date
}

func smbMetadataCacheFile(_ volume: FilePath) -> FilePath {
    indexFolder / "\(volume.name.string.replacingOccurrences(of: " ", with: "-"))-smb-meta.json"
}

// MARK: - SMBMetadataCache

final class SMBMetadataCache {
    var count: Int {
        lock.withLock { entries.count }
    }

    func set(_ path: String, metadata: SMBFileMetadata) {
        lock.withLock { entries[path] = metadata }
    }

    func get(_ path: String) -> SMBFileMetadata? {
        lock.withLock { entries[path] }
    }

    func save(to file: FilePath) {
        lock.lock()
        let snapshot = entries
        lock.unlock()

        guard !snapshot.isEmpty else { return }
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: file.url)
            slog.info("SMBMetadataCache: saved \(snapshot.count) entries to \(file.string)")
        } catch {
            slog.error("SMBMetadataCache: save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func load(from file: FilePath) {
        guard file.exists else { return }
        do {
            let data = try Data(contentsOf: file.url)
            let loaded = try JSONDecoder().decode([String: SMBFileMetadata].self, from: data)
            lock.withLock { entries = loaded }
            slog.info("SMBMetadataCache: loaded \(loaded.count) entries from \(file.string)")
        } catch {
            slog.error("SMBMetadataCache: load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private var entries: [String: SMBFileMetadata] = [:]
    private let lock = NSLock()

}

// MARK: - SMBFramework

private enum SMBFramework {
    typealias SMBOpenServerWithMountPoint = @convention(c) (
        UnsafePointer<CChar>,
        UnsafePointer<CChar>?,
        UnsafeMutablePointer<SMBHANDLE?>,
        UInt64
    ) -> NTSTATUS

    typealias SMBReleaseServer = @convention(c) (SMBHANDLE) -> NTSTATUS

    typealias SMBCreateFile = @convention(c) (
        SMBHANDLE,
        UnsafePointer<CChar>,
        UInt32,
        UInt32,
        UnsafeMutableRawPointer?,
        UInt32,
        UInt32,
        UnsafeMutablePointer<SMBFID>
    ) -> NTSTATUS

    typealias SMBCloseFile = @convention(c) (SMBHANDLE, SMBFID) -> NTSTATUS

    typealias SMBQueryDir = @convention(c) (
        SMBHANDLE,
        UInt8,
        UInt8,
        UInt32,
        SMBFID,
        UnsafePointer<CChar>,
        UInt32,
        UnsafeMutablePointer<CChar>,
        UInt32,
        UnsafeMutablePointer<UInt32>,
        UnsafeMutablePointer<UInt32>
    ) -> NTSTATUS

    static let handle: UnsafeMutableRawPointer? = dlopen("/System/Library/PrivateFrameworks/SMBClient.framework/SMBClient", RTLD_LAZY)

    static let openServerWithMountPoint: SMBOpenServerWithMountPoint? = symbol("SMBOpenServerWithMountPoint")
    static let releaseServer: SMBReleaseServer? = symbol("SMBReleaseServer")
    static let createFile: SMBCreateFile? = symbol("SMBCreateFile")
    static let closeFile: SMBCloseFile? = symbol("SMBCloseFile")
    static let queryDir: SMBQueryDir? = symbol("SMBQueryDir")

    static var available: Bool {
        openServerWithMountPoint != nil && releaseServer != nil &&
            createFile != nil && closeFile != nil && queryDir != nil
    }

    static func symbol<T>(_ name: String) -> T? {
        guard let h = handle, let sym = dlsym(h, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

}

// MARK: - SendableConnection

private struct SendableConnection: @unchecked Sendable { let raw: SMBHANDLE }

// MARK: - SendableQueryFn

private struct SendableQueryFn: @unchecked Sendable { let fn: SMBFramework.SMBQueryDir }

// MARK: - SendableCreateFn

private struct SendableCreateFn: @unchecked Sendable { let fn: SMBFramework.SMBCreateFile }

// MARK: - SendableCloseFn

private struct SendableCloseFn: @unchecked Sendable { let fn: SMBFramework.SMBCloseFile }

// MARK: - Helpers

func isSMBVolume(_ mountPoint: String) -> Bool {
    var fs = statfs()
    guard mountPoint.withCString({ statfs($0, &fs) }) == 0 else { return false }
    let typeName = fs.f_fstypename
    let typeStr = withUnsafePointer(to: typeName) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: typeName)) {
            String(cString: $0)
        }
    }
    return typeStr == "smbfs"
}

private func mountedShareName(for mountPoint: String) -> String {
    var fs = statfs()
    guard mountPoint.withCString({ statfs($0, &fs) }) == 0 else {
        return URL(fileURLWithPath: mountPoint).lastPathComponent
    }

    let mountFromRaw = fs.f_mntfromname
    let mountFrom = withUnsafePointer(to: mountFromRaw) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: mountFromRaw)) {
            String(cString: $0)
        }
    }

    if mountFrom.hasPrefix("smb://") || mountFrom.hasPrefix("SMB://"),
       let url = URL(string: mountFrom),
       let share = url.pathComponents.filter({ $0 != "/" }).last, !share.isEmpty
    {
        return share
    }

    if mountFrom.hasPrefix("//"),
       let last = mountFrom.split(separator: "/", omittingEmptySubsequences: true).last, !last.isEmpty
    {
        return String(last)
    }

    return URL(fileURLWithPath: mountPoint).lastPathComponent
}

private func smbDirectoryPathCandidates(for logicalPath: String) -> [String] {
    func dedupe(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    if logicalPath == "/" {
        return dedupe(["\\", "/", "", "."])
    }

    let trimmed = logicalPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let windowsRelative = trimmed.replacingOccurrences(of: "/", with: "\\")

    return dedupe([
        "\\\(windowsRelative)",
        "\\\(windowsRelative)\\",
        windowsRelative,
        "\(windowsRelative)\\",
        logicalPath,
        "/\(trimmed)",
        "./\(trimmed)",
        "\(trimmed)/",
    ])
}

private func isPathNotFoundStatus(_ status: NTSTATUS) -> Bool {
    status == STATUS_OBJECT_NAME_NOT_FOUND || status == STATUS_OBJECT_PATH_NOT_FOUND
}

private func makeAbsolutePath(parent: String, child: String) -> String {
    parent == "/" ? "/\(child)" : "\(parent)/\(child)"
}

// MARK: - Directory handle

private func openDirectoryHandle(
    conn: SMBHANDLE,
    logicalPath: String,
    createFn: SMBFramework.SMBCreateFile
) throws -> SMBFID {
    let candidates = smbDirectoryPathCandidates(for: logicalPath)
    var lastFailure: NTSTATUS = STATUS_SUCCESS

    for candidate in candidates {
        for createOptions in [FILE_CREATE_OPTIONS_DIRECTORY, FILE_CREATE_OPTIONS_NONE] {
            var fid: SMBFID = 0
            let status: NTSTATUS = candidate.withCString { cPath in
                createFn(conn, cPath, FILE_LIST_DIRECTORY_ACCESS, FILE_SHARE_READ_WRITE, nil, FILE_OPEN_EXISTING, createOptions, &fid)
            }
            if status == STATUS_SUCCESS {
                return fid
            }
            lastFailure = status
        }
    }

    throw SMBWalkError.openDirectoryFailed(path: logicalPath, status: lastFailure)
}

// MARK: - DirPage

private struct DirPage {
    let paths: [(path: String, isDir: Bool, size: Int64, modDate: Date, createDate: Date)]
    let subdirectories: [(path: String, fileId: UInt64)]
}

private func parseDirectoryBuffer(
    buffer: UnsafeMutableRawPointer,
    returned: UInt32,
    dirPath: String,
    mountPoint: String,
    skipHidden: Bool,
    shouldSkip: (String) -> Bool,
    shouldSkipTraversal: ((String) -> Bool)? = nil
) -> DirPage {
    let fixedSize = MemoryLayout<FileIdBothDirInfo>.size
    var paths: [(String, Bool, Int64, Date, Date)] = []
    var subdirs: [(path: String, fileId: UInt64)] = []
    var offset = 0
    let total = Int(returned)

    while offset < total {
        guard offset + fixedSize <= total else { break }

        let entryPtr = buffer.advanced(by: offset)
        let info = entryPtr.load(as: FileIdBothDirInfo.self)
        let nameLength = Int(info.fileNameLength)
        let nameStart = offset + fixedSize
        let nameEnd = nameStart + nameLength

        guard nameLength >= 0, nameEnd <= total else { break }

        let namePtr = entryPtr.advanced(by: fixedSize)
        let nameData = Data(bytes: namePtr, count: nameLength)
        let name = String(data: nameData, encoding: .utf16LittleEndian) ?? ""

        if name != ".", name != ".." {
            let attrs = info.fileAttributes
            let isDir = (attrs & FILE_ATTRIBUTE_DIRECTORY) != 0
            let isHidden = (attrs & FILE_ATTRIBUTE_HIDDEN) != 0
            let isReparse = (attrs & FILE_ATTRIBUTE_REPARSE_POINT) != 0

            if name == ".DS_Store" || name.hasPrefix("._") || name == ".localized" {
                // skip macOS metadata files
            } else if skipHidden, isHidden {
                // skip hidden
            } else {
                let smbPath = makeAbsolutePath(parent: dirPath, child: name)
                let localPath = mountPoint + smbPath

                let skipped = shouldSkip(localPath)
                if !skipped {
                    let modDate = filetimeToDate(info.lastWriteTime)
                    let createDate = filetimeToDate(info.creationTime)
                    paths.append((localPath, isDir, info.endOfFile, modDate, createDate))
                }
                let skipTraversal = shouldSkipTraversal?(localPath) ?? shouldSkip(localPath)
                if isDir, !isReparse, !skipTraversal {
                    subdirs.append((path: smbPath, fileId: info.fileId))
                }
            }
        }

        if info.nextEntryOffset == 0 { break }
        let next = Int(info.nextEntryOffset)
        guard next > 0, offset + next <= total else { break }
        offset += next
    }

    return DirPage(paths: paths, subdirectories: subdirs)
}

// MARK: - Single directory query

private func querySingleDirectory(
    conn: SMBHANDLE,
    dirPath: String,
    mountPoint: String,
    skipHidden: Bool,
    shouldSkip: @escaping (String) -> Bool,
    shouldSkipTraversal: ((String) -> Bool)? = nil,
    createFn: SMBFramework.SMBCreateFile,
    closeFn: SMBFramework.SMBCloseFile,
    queryFn: SMBFramework.SMBQueryDir
) throws -> DirPage {
    let bufferSize: UInt32 = 65536
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(bufferSize), alignment: 8)
    defer { buffer.deallocate() }
    let bufferChars = buffer.bindMemory(to: CChar.self, capacity: Int(bufferSize))

    var allPaths: [(String, Bool, Int64, Date, Date)] = []
    var allSubdirs: [(path: String, fileId: UInt64)] = []
    var isFirstCall = true

    let dirFID: SMBFID
    do {
        dirFID = try openDirectoryHandle(conn: conn, logicalPath: dirPath, createFn: createFn)
    } catch {
        if dirPath != "/", let e = error as? SMBWalkError, case let .openDirectoryFailed(_, status) = e, isPathNotFoundStatus(status) {
            slog.warning("SMB: skipping vanished directory \(dirPath)")
            return DirPage(paths: [], subdirectories: [])
        }
        throw error
    }
    defer { _ = closeFn(conn, dirFID) }

    while true {
        var returned: UInt32 = 0
        var queryReplyLength: UInt32 = 0
        let status: NTSTATUS = "*".withCString { patternCStr in
            let patternLenWithNull = UInt32(strlen(patternCStr) + 1)
            return queryFn(
                conn,
                FileIdBothDirectoryInformation,
                isFirstCall ? SMB2_QUERY_DIRECTORY_RESTART_SCANS : 0,
                0, dirFID, patternCStr, patternLenWithNull,
                bufferChars, bufferSize,
                &returned, &queryReplyLength
            )
        }
        isFirstCall = false

        if status == STATUS_NO_MORE_FILES { break }

        if dirPath != "/", isPathNotFoundStatus(status) {
            slog.warning("SMB: skipping unreadable directory \(dirPath)")
            return DirPage(paths: allPaths, subdirectories: allSubdirs)
        }

        guard status == STATUS_SUCCESS || status == STATUS_BUFFER_OVERFLOW else {
            throw SMBWalkError.queryFailed(path: dirPath, status: status)
        }

        if returned == 0 { continue }

        let page = parseDirectoryBuffer(
            buffer: buffer, returned: returned, dirPath: dirPath,
            mountPoint: mountPoint, skipHidden: skipHidden, shouldSkip: shouldSkip,
            shouldSkipTraversal: shouldSkipTraversal
        )
        allPaths.append(contentsOf: page.paths)
        allSubdirs.append(contentsOf: page.subdirectories)
    }

    return DirPage(paths: allPaths, subdirectories: allSubdirs)
}

// MARK: - SMBWalkError

enum SMBWalkError: Error, CustomStringConvertible {
    case frameworkNotLoaded
    case openServerFailed(NTSTATUS)
    case openDirectoryFailed(path: String, status: NTSTATUS)
    case queryFailed(path: String, status: NTSTATUS)

    var description: String {
        switch self {
        case .frameworkNotLoaded:
            "SMBClient.framework symbols not available"
        case let .openServerFailed(status):
            String(format: "SMBOpenServerWithMountPoint failed: 0x%08X", status)
        case let .openDirectoryFailed(path, status):
            String(format: "SMBCreateFile failed for %@: 0x%08X", path, status)
        case let .queryFailed(path, status):
            String(format: "SMBQueryDir failed for %@: 0x%08X", path, status)
        }
    }
}

// MARK: - Public walk API

/// Walk an SMB share using the native SMBClient.framework for fast enumeration.
/// Returns the number of entries added to the engine, or throws on failure so the caller can fall back to FileManager.
func walkSMBShare(
    engine: SearchEngine,
    mountPoint: String,
    ignoreFile: String? = nil,
    skipDir: ((String) -> Bool)? = nil,
    metadataCache: SMBMetadataCache? = nil,
    maxConcurrent: Int = 8,
    progress: ((Int, String) -> Void)? = nil,
    cancelled: (() -> Bool)? = nil
) async throws -> Int {
    guard SMBFramework.available,
          let openFn = SMBFramework.openServerWithMountPoint,
          let releaseFn = SMBFramework.releaseServer,
          let createFn = SMBFramework.createFile,
          let closeFn = SMBFramework.closeFile,
          let queryFn = SMBFramework.queryDir
    else {
        throw SMBWalkError.frameworkNotLoaded
    }

    let ignoreContent: String? = ignoreFile.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
    let ignoredExtensions: Set<String> = ignoreContent.map { SearchEngine.extractExtensionPatterns(from: $0) } ?? []
    let hasNegationPatterns: Bool = ignoreContent?.contains("\n!") == true || ignoreContent?.hasPrefix("!") == true

    let shouldSkip: (String) -> Bool = { path in
        if isPathBlocked(path) { return true }
        if let skipDir, skipDir(path) { return true }
        if !ignoredExtensions.isEmpty {
            let ext = "." + (URL(fileURLWithPath: path).pathExtension.lowercased())
            if ext.count > 1, ignoredExtensions.contains(ext) { return true }
        }
        if let ignoreFile, path.isIgnored(in: ignoreFile) { return true }
        return false
    }

    // When negation patterns exist, a directory may be ignored but still
    // need traversal so un-ignored descendants can be found.
    let shouldSkipTraversal: (String) -> Bool = { path in
        if isPathBlocked(path) { return true }
        if let skipDir, skipDir(path) { return true }
        if !hasNegationPatterns, let ignoreFile, path.isIgnored(in: ignoreFile) { return true }
        return false
    }

    var handle: SMBHANDLE? = nil
    let treeName = mountedShareName(for: mountPoint)
    slog.info("SMB: connecting mount=\(mountPoint) tree=\(treeName) maxConcurrent=\(maxConcurrent)")

    let openStatus: NTSTATUS = mountPoint.withCString { mountCStr in
        treeName.withCString { treeCStr in
            openFn(mountCStr, treeCStr, &handle, 0)
        }
    }

    guard openStatus == STATUS_SUCCESS, let conn = handle else {
        throw SMBWalkError.openServerFailed(openStatus)
    }
    slog.info("SMB: connected to \(mountPoint)")
    defer { _ = releaseFn(conn) }

    let sendableConn = SendableConnection(raw: conn)
    let sendableCreateFn = SendableCreateFn(fn: createFn)
    let sendableCloseFn = SendableCloseFn(fn: closeFn)
    let sendableQueryFn = SendableQueryFn(fn: queryFn)

    var added = 0
    let t0 = CFAbsoluteTimeGetCurrent()
    var lastProgress = t0

    func processDirPage(_ page: DirPage) {
        for (path, isDir, size, modDate, createDate) in page.paths {
            engine.addPath(path, isDir: isDir)
            added += 1

            if !isDir, let cache = metadataCache {
                cache.set(path, metadata: SMBFileMetadata(size: size, modificationDate: modDate, creationDate: createDate))
            }

            let now = CFAbsoluteTimeGetCurrent()
            if now - lastProgress > 0.3 {
                lastProgress = now
                progress?(added, path)
            }
        }
    }

    if maxConcurrent <= 1 {
        var pending = ["/"]
        var seenFileIds: Set<UInt64> = []

        while let dirPath = pending.popLast() {
            if cancelled?() == true { break }

            let page = try querySingleDirectory(
                conn: conn, dirPath: dirPath, mountPoint: mountPoint,
                skipHidden: true, shouldSkip: shouldSkip, shouldSkipTraversal: shouldSkipTraversal,
                createFn: createFn, closeFn: closeFn, queryFn: queryFn
            )
            processDirPage(page)

            for subdir in page.subdirectories {
                if subdir.fileId != 0 {
                    guard seenFileIds.insert(subdir.fileId).inserted else { continue }
                }
                pending.append(subdir.path)
            }
        }
    } else {
        try await withThrowingTaskGroup(of: DirPage.self) { group in
            var pending: Set<String> = ["/"]
            var seenFileIds: Set<UInt64> = []
            var inFlight = 0

            while !pending.isEmpty || inFlight > 0 {
                if cancelled?() == true {
                    group.cancelAll()
                    break
                }

                while !pending.isEmpty, inFlight < maxConcurrent {
                    let dirPath = pending.removeFirst()
                    inFlight += 1

                    group.addTask {
                        try querySingleDirectory(
                            conn: sendableConn.raw, dirPath: dirPath, mountPoint: mountPoint,
                            skipHidden: true, shouldSkip: shouldSkip, shouldSkipTraversal: shouldSkipTraversal,
                            createFn: sendableCreateFn.fn, closeFn: sendableCloseFn.fn, queryFn: sendableQueryFn.fn
                        )
                    }
                }

                guard let page = try await group.next() else { break }
                inFlight -= 1

                processDirPage(page)

                for subdir in page.subdirectories {
                    if subdir.fileId != 0 {
                        guard seenFileIds.insert(subdir.fileId).inserted else { continue }
                    }
                    pending.insert(subdir.path)
                }
            }
        }
    }

    let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
    slog.info("SMB: walkSMBShare \(mountPoint) added=\(added) in \(ms, format: .fixed(precision: 1))ms")
    return added
}
