import AppKit
import Lowtech
import System

// MARK: - FolderIcons

/// Folders that look different from a plain folder in Finder: a custom icon, symbol or emoji, a cloud service's
/// root, a system folder like Downloads, a drive or an app. A result's folder line shows the icon of the deepest
/// of them before the path. Each folder is looked up once, off the main thread, and kept for the session, since its icon
/// almost never changes.
///
/// Telling one apart costs no drawing: a custom icon and a symbol or emoji both set the Finder flag that marks a
/// custom icon, read with one `getxattr`, and the rest are known by their path. Only a marked folder's icon is asked
/// for, and IconServices hands that back as a lazy image that is rendered once, off the main thread, by the rows.
@MainActor
final class FolderIcons {
    struct Mark {
        init(folder: String, icon: NSImage, glyph: Bool) {
            self.folder = folder
            self.icon = icon
            self.glyph = glyph
            prefix = folder + "/"
        }

        /// The folder's full path.
        let folder: String
        let icon: NSImage
        /// The icon is the symbol or emoji picked for the folder in Finder, which is drawn as it is rather than
        /// rendered once, so a symbol follows light and dark mode.
        let glyph: Bool

        /// `shown`, the `~` form of `dir`, as it reads after the icon: whole, without the `~/`, which the icon makes
        /// redundant (`Pictures/Shoot/2026`). Takes the `~` form from the caller, which has it already, as making it
        /// costs a regex.
        func shownPath(of dir: FilePath, shown: String) -> String? {
            guard dir.string == folder || dir.string.hasPrefix(prefix) else { return nil }
            return shown.hasPrefix("~/") ? String(shown.dropFirst(2)) : shown
        }

        private let prefix: String
    }

    static let shared = FolderIcons()

    /// Called once a burst of lookups has landed, so the visible rows redraw once.
    var onMarksReady: (() -> Void)?

    /// The deepest folder in `dir` with an icon of its own, below Home and the startup disk, which head almost every
    /// path. Nil while it's being looked up and when there is none.
    func mark(in dir: FilePath) -> Mark? {
        let key = dir.string
        if let known = marks[key] {
            return known
        }
        lookUp(key)
        return nil
    }

    /// Like `mark(in:)`, waiting for the lookup when it hasn't been done yet.
    func markWhenKnown(in dir: FilePath) async -> Mark? {
        let key = dir.string
        if let known = marks[key] {
            return known
        }
        return await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
            lookUp(key)
        }
    }

    private nonisolated static let probe = Probe()

    private let queue = DispatchQueue(label: "com.lowtechguys.Cling.folderIcons", qos: .userInitiated)
    private var marks: [String: Mark?] = [:]
    private var pending: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Mark?, Never>]] = [:]
    private var readyNotificationScheduled = false

    /// Each cloud folder's service icon, under its real path and the Home folder links that lead to it (`~/Dropbox`),
    /// which is how results show it. The same image every time, so the rows' rendered copy of it is reused.
    private lazy var cloudIcons: [String: NSImage] = {
        var icons: [String: NSImage] = [:]
        for location in FUZZY.cloudLocations {
            let icon = location.icon
            icons[location.root.string] = icon
            if location.appPath == nil {
                // iCloud Drive's files are in its own folder inside Mobile Documents.
                icons[(location.root / "com~apple~CloudDocs").string] = icon
            }
        }
        for link in SearchEngine.homeFolderLinks() {
            if let icon = icons[link.real] {
                icons[link.shown] = icon
            }
        }
        return icons
    }()

    private func lookUp(_ key: String) {
        guard !pending.contains(key) else { return }
        pending.insert(key)
        let cloud = cloudIcons
        let cloudFolders = Set(cloud.keys)
        let network = FUZZY.networkVolumes.map { $0.string + "/" }
        queue.async {
            let found = Self.probe.deepestMarked(in: key, cloudFolders: cloudFolders, network: network)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.pending.remove(key)
                    let mark = found.flatMap { found in
                        (found.icon ?? cloud[found.folder]).map { Mark(folder: found.folder, icon: $0, glyph: found.glyph) }
                    }
                    // A folder is a few dozen bytes here; the cap only matters after hours of scrolling through new ones.
                    if self.marks.count > 20000 {
                        self.marks.removeAll(keepingCapacity: true)
                    }
                    self.marks[key] = .some(mark)
                    for waiter in self.waiters.removeValue(forKey: key) ?? [] {
                        waiter.resume(returning: mark)
                    }
                    if mark != nil {
                        self.scheduleReadyNotification()
                    }
                }
            }
        }
    }

    private func scheduleReadyNotification() {
        guard !readyNotificationScheduled else { return }
        readyNotificationScheduled = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.readyNotificationScheduled = false
                self.onMarksReady?()
            }
        }
    }
}

// MARK: - Probe

/// The per-folder answers, used only on `FolderIcons.queue`: a folder shared by many results is looked at once.
private final class Probe: @unchecked Sendable {
    struct Found {
        let folder: String
        /// Nil for a cloud folder, whose service icon the main actor has.
        let icon: NSImage?
        let glyph: Bool
    }

    func deepestMarked(in dir: String, cloudFolders: Set<String>, network: [String]) -> Found? {
        var folder = dir
        while folder.count > 1, folder != home {
            if cloudFolders.contains(folder) {
                return Found(folder: folder, icon: nil, glyph: false)
            }
            if let icon = icon(of: folder, network: network) {
                return Found(folder: folder, icon: icon.image, glyph: icon.glyph)
            }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return nil
    }

    private let home = NSHomeDirectory()
    private var known: [String: (image: NSImage, glyph: Bool)?] = [:]

    /// The folders that macOS draws with an icon of their own.
    private lazy var systemFolders: Set<String> = {
        let inHome = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public", "Library", "Applications", "Sites", ".Trash"]
        return Set(inHome.map { home + "/" + $0 } + ["/Applications", "/Applications/Utilities", "/Library", "/System"])
    }()

    private func icon(of folder: String, network: [String]) -> (image: NSImage, glyph: Bool)? {
        if let cached = known[folder] {
            return cached
        }
        var icon: (image: NSImage, glyph: Bool)?
        if marked(folder, network: network) {
            icon = pickedGlyph(folder).map { ($0, true) } ?? (NSWorkspace.shared.icon(forFile: folder), false)
        }
        if known.count > 50000 {
            known.removeAll(keepingCapacity: true)
        }
        known[folder] = .some(icon)
        return icon
    }

    private func marked(_ folder: String, network: [String]) -> Bool {
        if systemFolders.contains(folder) {
            return true
        }
        let isVolume = folder.hasPrefix("/Volumes/") && !folder.dropFirst(9).contains("/")
        if isVolume {
            return FileManager.default.fileExists(atPath: folder)
        }
        // A network share can take seconds to answer, and every lookup after it waits in line.
        if network.contains(where: { folder.hasPrefix($0) }) {
            return false
        }
        let name = (folder as NSString).lastPathComponent
        if name.dropFirst().contains("."), (try? URL(fileURLWithPath: folder).resourceValues(forKeys: [.isPackageKey]))?.isPackage == true {
            return true
        }
        return hasCustomIcon(folder)
    }

    /// The Finder flag set by a custom icon and by a symbol or emoji picked in Finder.
    private func hasCustomIcon(_ path: String) -> Bool {
        var info = [UInt8](repeating: 0, count: 32)
        guard getxattr(path, "com.apple.FinderInfo", &info, 32, 0, XATTR_NOFOLLOW) == 32 else { return false }
        return (UInt16(info[8]) << 8 | UInt16(info[9])) & 0x0400 != 0
    }

    /// The symbol or emoji picked for the folder in Finder, on its own: drawn inside the folder at the size of a line
    /// of text, it's too small to make out.
    private func pickedGlyph(_ path: String) -> NSImage? {
        let attribute = "com.apple.icon.folder#S"
        let size = getxattr(path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, attribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read == size, let picked = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }

        let image: NSImage
        if let emoji = picked["emoji"] as? String, !emoji.isEmpty {
            image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
                let text = NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: rect.height * 0.82)])
                let size = text.size()
                text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
                return true
            }
        } else if let name = picked["sym"] as? String,
                  let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                  .withSymbolConfiguration(.init(pointSize: 26, weight: .semibold).applying(.init(paletteColors: [.secondaryLabelColor])))
        {
            image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
                let fit = min(rect.width / symbol.size.width, rect.height / symbol.size.height)
                let size = NSSize(width: symbol.size.width * fit, height: symbol.size.height * fit)
                symbol.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
                return true
            }
        } else {
            return nil
        }
        // Drawn again each time, in the colours of the appearance it's drawn in.
        image.cacheMode = .never
        return image
    }
}
