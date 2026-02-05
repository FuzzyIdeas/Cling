import Defaults
import Foundation
import Lowtech
import System

let SORT_ATTRS = [
    kMDItemLastUsedDate,
    kMDItemFSContentChangeDate,
    kMDItemFSCreationDate,
] as CFArray

extension CFComparisonResult {
    func reversed() -> CFComparisonResult {
        switch self {
        case .compareLessThan:
            return .compareGreaterThan
        case .compareGreaterThan:
            return .compareLessThan
        case .compareEqualTo:
            return .compareEqualTo
        @unknown default:
            return .compareEqualTo
        }
    }
}

let sortComparator: MDQuerySortComparatorFunction = { values1, values2, context in
    guard let value1 = values1?.pointee?.takeUnretainedValue() else {
        return .compareGreaterThan
    }
    guard let value2 = values2?.pointee?.takeUnretainedValue() else {
        return .compareLessThan
    }

    let date1 = value1 as! CFDate
    let date2 = value2 as! CFDate

    return CFDateCompare(date1, date2, nil).reversed()
}

extension MDQuery {
    @MainActor
    func getPaths() -> [FilePath] {
        var paths: [FilePath] = []
        for i in 0 ..< MDQueryGetResultCount(self) {
            guard let rawPtr = MDQueryGetResultAtIndex(self, i) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(rawPtr).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }

            let filePath = FilePath(path)
            if FUZZY.removedFiles.contains(filePath.string) || FUZZY.excludedPaths.contains(filePath.string) { continue }
            if filePath.starts(with: HOME), filePath.string.isIgnored(in: fsignoreString) { continue }
            if !isRelevantDefaultPath(path) { continue }
            paths.append(filePath)
        }
        return paths
    }
}

@MainActor var recentsSetTask: DispatchWorkItem? {
    didSet {
        oldValue?.cancel()
    }
}

let queryFinishCallback: CFNotificationCallback = { notificationCenter, observer, notificationName, object, userInfo in
    guard let object: UnsafeRawPointer else { return }
    let query: MDQuery = unsafeBitCast(object, to: MDQuery.self)

    mainActor {
        let mdPaths = query.getPaths()
        log.debug("MDQuery finish: \(mdPaths.count) paths after filtering")
        FUZZY.mdQueryRecents = mdPaths
        FUZZY.updateDefaultResults()
    }
}

let queryUpdateCallback: CFNotificationCallback = { notificationCenter, observer, notificationName, object, userInfo in
    guard let object: UnsafeRawPointer else { return }

    let userInfo = userInfo as? [CFString: Any]
    let added = userInfo?[kMDQueryUpdateAddedItems] as? [MDItem]
    let removed = userInfo?[kMDQueryUpdateRemovedItems] as? [MDItem]
    guard added?.isEmpty == false || removed?.isEmpty == false else { return }

    let query: MDQuery = unsafeBitCast(object, to: MDQuery.self)

    mainActor {
        let mdPaths = query.getPaths()
        FUZZY.mdQueryRecents = mdPaths
        FUZZY.updateDefaultResults(debounce: true)
    }

    // let changed = userInfo?[kMDQueryUpdateChangedItems] as? [MDItem]

    // for item in added ?? [] {
    //     print("Added: \(item.description)")
    // }
    // for item in removed ?? [] {
    //     print("Removed: \(item.description)")
    // }
    // for item in changed ?? [] {
    //     print("Changed: \(item.description)")
    // }
}

extension MDItem {
    var description: String {
        guard let path = MDItemCopyAttribute(self, kMDItemPath) as? String else {
            return "<MDItem Unknown>"
        }
        guard let date = MDItemCopyAttribute(self, kMDItemLastUsedDate) as? Date ?? MDItemCopyAttribute(self, kMDItemFSContentChangeDate) as? Date ?? MDItemCopyAttribute(self, kMDItemFSCreationDate) as? Date,
              let size = MDItemCopyAttribute(self, kMDItemFSSize) as? Int
        else {
            return "<MDItem \(path)>"
        }
        return "<MDItem \(path) | \(date.formatted(dateFormat)) | \(size.humanSize)>"
    }
}

// Filter to files modified in the last 7 days. $time.now(-604800) = 7 days in seconds.
// Note: $time.today(-7) doesn't work with MDQueryCreate, but $time.now(-seconds) does.
let queryString =
    #"((kMDItemSupportFileType != "MDSystemFile")) && ((kMDItemFSContentChangeDate >= $time.now(-604800)) && ((kMDItemContentTypeTree = public.content) || (kMDItemContentTypeTree = "com.microsoft.*"cdw) || (kMDItemContentTypeTree = public.archive)))"#

private let cachedHomeBytes: [UInt8] = Array(NSHomeDirectory().utf8)
private let applicationsBytes: [UInt8] = Array("/Applications/".utf8)
private let dotAppBytes: [UInt8] = Array(".app".utf8)
private let libraryBytes: [UInt8] = Array("Library/".utf8)
private let icloudPrefixBytes: [UInt8] = Array("Library/Mobile Documents/com~apple~CloudDocs/".utf8)
private let slashByte = UInt8(ascii: "/")
private let dotByte = UInt8(ascii: ".")

// Exact dotfiles in $HOME worth showing (e.g. ~/.<name>)
private let allowedDotfiles: [[UInt8]] = [
    ".gitconfig", ".gitignore", ".zshrc", ".bashrc", ".bash_profile",
    ".zprofile", ".profile", ".vimrc", ".tmux.conf", ".npmrc", ".env",
    ".zshenv", ".inputrc", ".editorconfig", ".hushlogin", ".curlrc",
    ".wgetrc", ".gemrc", ".tool-versions", ".fsignore",
].map { Array($0.utf8) }

// Dotdirs where only direct children (depth 1) are relevant (config files, not caches)
private let allowedShallowDotdirs: [[UInt8]] = [
    ".config/", ".ssh/", ".aws/", ".kube/", ".gnupg/", ".docker/",
].map { Array($0.utf8) }

private func utf8Contains(_ haystack: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
    let nLen = needle.count
    guard haystack.count >= nLen else { return false }
    let end = haystack.count - nLen
    for i in 0 ... end {
        if memcmp(haystack.baseAddress! + i, needle, nLen) == 0 { return true }
    }
    return false
}

private func utf8HasPrefix(_ haystack: UnsafeBufferPointer<UInt8>, offset: Int = 0, _ prefix: [UInt8]) -> Bool {
    guard haystack.count - offset >= prefix.count else { return false }
    return memcmp(haystack.baseAddress! + offset, prefix, prefix.count) == 0
}

private func utf8HasSuffix(_ haystack: UnsafeBufferPointer<UInt8>, _ suffix: [UInt8]) -> Bool {
    guard haystack.count >= suffix.count else { return false }
    return memcmp(haystack.baseAddress! + haystack.count - suffix.count, suffix, suffix.count) == 0
}

/// Check if a path is relevant for default/recent results (generic for any macOS user)
func isRelevantDefaultPath(_ path: String) -> Bool {
    if isPathBlocked(path) { return false }

    var result = false
    path.utf8.withContiguousStorageIfAvailable { buf in

        // /Applications/*.app (top-level bundles only)
        if utf8HasPrefix(buf, applicationsBytes), utf8HasSuffix(buf, dotAppBytes) {
            // Check no slash after "/Applications/"
            let afterApps = applicationsBytes.count
            for i in afterApps ..< buf.count - dotAppBytes.count {
                if buf[i] == slashByte { return }
            }
            result = true
            return
        }

        // Home paths
        let homeLen = cachedHomeBytes.count
        guard buf.count > homeLen + 1, utf8HasPrefix(buf, cachedHomeBytes), buf[homeLen] == slashByte else { return }

        let relStart = homeLen + 1
        // Anything in home that's NOT in Library/ is user content
        if !utf8HasPrefix(buf, offset: relStart, libraryBytes) {
            // Dotfiles/dotdirs: only allow specific user-editable files
            if buf[relStart] == dotByte {
                // Exact dotfiles (e.g. ~/.zshrc, ~/.gitconfig)
                let relLen = buf.count - relStart
                for allowed in allowedDotfiles {
                    if relLen == allowed.count, utf8HasPrefix(buf, offset: relStart, allowed) {
                        result = true; return
                    }
                }
                // Shallow dotdirs: only direct children (no subdirs)
                for dir in allowedShallowDotdirs {
                    if utf8HasPrefix(buf, offset: relStart, dir) {
                        // Check no further slash after the dotdir prefix
                        let afterDir = relStart + dir.count
                        for i in afterDir ..< buf.count {
                            if buf[i] == slashByte { return }
                        }
                        result = true; return
                    }
                }
                return
            }
            result = true
            return
        }
        // Allow iCloud Drive (shallow: max ~2 levels into user folders)
        if utf8HasPrefix(buf, offset: relStart, icloudPrefixBytes) {
            let icloudStart = relStart + icloudPrefixBytes.count
            var slashCount = 0
            for i in icloudStart ..< buf.count {
                if buf[i] == slashByte { slashCount += 1 }
            }
            // depth = components separated by "/" count, which is slashCount + 1 if non-empty
            result = slashCount + 1 <= 3
        }
    }
    return result
}

private let mdQueryObserver: UnsafeMutablePointer<AnyObject?> = .allocate(capacity: 1)

func stopRecentsQuery(_ query: MDQuery) {
    MDQueryStop(query)
    CFNotificationCenterRemoveObserver(
        CFNotificationCenterGetLocalCenter(),
        mdQueryObserver,
        CFNotificationName(kMDQueryDidFinishNotification),
        unsafeBitCast(query, to: UnsafeRawPointer.self)
    )
    CFNotificationCenterRemoveObserver(
        CFNotificationCenterGetLocalCenter(),
        mdQueryObserver,
        CFNotificationName(kMDQueryDidUpdateNotification),
        unsafeBitCast(query, to: UnsafeRawPointer.self)
    )
}

func queryRecents() -> MDQuery? {
    guard let query = MDQueryCreate(kCFAllocatorDefault, queryString as CFString, [kMDItemPath] as CFArray, SORT_ATTRS) else {
        log.error("Failed to create query")
        return nil
    }
    MDQuerySetSearchScope(query, [kMDQueryScopeHome] as CFArray, 0)
    MDQuerySetMaxCount(query, Defaults[.maxResultsCount])
    MDQuerySetSortComparator(query, sortComparator, nil)
    MDQuerySetDispatchQueue(query, .main)
    log.debug("queryRecents: created query, maxCount=\(Defaults[.maxResultsCount])")

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetLocalCenter(),
        mdQueryObserver,
        queryFinishCallback,
        kMDQueryDidFinishNotification,
        unsafeBitCast(query, to: UnsafeRawPointer.self),
        .deliverImmediately
    )
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetLocalCenter(),
        mdQueryObserver,
        queryUpdateCallback,
        kMDQueryDidUpdateNotification,
        unsafeBitCast(query, to: UnsafeRawPointer.self),
        .deliverImmediately
    )

    MDQueryExecute(query, kMDQueryWantsUpdates.rawValue.u)
    return query
}
