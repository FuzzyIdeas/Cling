import AppKit
import Defaults
import DiskArbitration
import Lowtech
import System

// MARK: - FolderIcons

/// Folders that look different from a plain folder in Finder: a custom icon, symbol or emoji, a cloud service's
/// root, a system folder like Downloads, a drive or an app. A result's folder line shows the icon of the deepest
/// of them before the path. A drive's folders aren't looked into: the drive's own icon, picked in Settings or
/// its kind's, stands for every path on it. Each folder is looked up once, off the main thread, and kept for the session, since its icon
/// almost never changes.
///
/// Telling one apart costs no drawing: a custom icon and a symbol or emoji both set the Finder flag that marks a
/// custom icon, read with one `getxattr`, and the rest are known by their path. Only a marked folder's icon is asked
/// for, and IconServices hands that back as a lazy image that is rendered once, off the main thread, by the rows.
@MainActor
final class FolderIcons {
    private init() {
        volumeIcons = Self.byPath(Defaults[.volumeIcons])
        // A drive's kind is read once while it's mounted, and a drive mounted again can be another one by the same name.
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.forgetVolumes() }
            }
        }
        Task { [weak self] in
            for await icons in Defaults.updates(.volumeIcons, initial: false) {
                self?.volumeIcons = Self.byPath(icons)
                self?.forgetVolumes()
            }
        }
    }

    struct Mark {
        init(folder: String, icon: NSImage, glyph: Bool, inside: Bool = false, name: String? = nil) {
            self.folder = folder
            self.icon = icon
            self.glyph = glyph
            self.inside = inside
            self.name = name ?? (folder as NSString).lastPathComponent
            prefix = folder + "/"
        }

        /// The folder's full path.
        let folder: String
        let icon: NSImage
        /// The icon is one of Cling's blue tiles (a symbol or emoji picked in Finder, Home's, the startup disk's or a
        /// drive's), which is drawn as it is rather than rendered once, as drawing it costs no more.
        let glyph: Bool
        /// What the line reads for the folder itself: Finder's name for it, or the cloud service's.
        let name: String

        /// `shown`, the `~` form of `dir`, as it reads after the icon: whole, without the `~/`, `/` or `/Volumes/` it
        /// starts with, which the icon stands for (`Pictures/Shoot/2026`, `Users/Shared`, `Photos/Archive`), and the
        /// folder's name for Home, `/` or a cloud folder itself, where no path would follow the icon. Takes the `~`
        /// form from the caller, which has it already, as making it costs a regex.
        func shownPath(of dir: FilePath, shown: String) -> String? {
            guard folder == "/" || dir.string == folder || dir.string.hasPrefix(prefix) else { return nil }
            if inside {
                return dir.string == folder ? name : String(dir.string.dropFirst(prefix.count))
            }
            if shown.hasPrefix(FolderIcons.volumes) {
                return String(shown.dropFirst(FolderIcons.volumes.count))
            }
            if shown == "~" || shown == "/" {
                return name
            }
            if shown.hasPrefix("~/") {
                return String(shown.dropFirst(2))
            }
            return shown.hasPrefix("/") ? String(shown.dropFirst()) : shown
        }

        /// The folder is a cloud service's own, deep in ~/Library (`Library/CloudStorage/GoogleDrive-…/My Drive`), so
        /// what follows it is the path that means something, and what comes before it only repeats the icon.
        private let inside: Bool
        private let prefix: String
    }

    static let shared = FolderIcons()
    nonisolated static let volumes = "/Volumes/"

    /// Called once a burst of lookups has landed, so the visible rows redraw once.
    var onMarksReady: (() -> Void)?

    /// What a folder line starts with when no folder in it has an icon of its own: a house for Home, # for the rest of
    /// the startup disk. Every line starts with an icon, so the paths after them line up.
    static func fallback(for dir: FilePath) -> Mark {
        let path = dir.string
        return path == homeMark.folder || path.hasPrefix(homeMark.folder + "/") ? homeMark : rootMark
    }

    /// The icon a folder line starts with: its deepest folder's own, or the fallback while that's being looked up and
    /// when there is none.
    func lineMark(in dir: FilePath) -> Mark {
        mark(in: dir) ?? Self.fallback(for: dir)
    }

    func lineMarkWhenKnown(in dir: FilePath) async -> Mark {
        await markWhenKnown(in: dir) ?? Self.fallback(for: dir)
    }

    /// The icon a drive's paths start with when none is picked for it, by its kind: what Settings shows on its row.
    func kindSymbol(of volume: FilePath) async -> String {
        let network = FUZZY.networkVolumes.map { $0.string + "/" }
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Self.probe.volumeSymbol(volume.string, picked: nil, network: network))
            }
        }
    }

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
    private static let library = NSHomeDirectory() + "/Library/"
    private static let homeMark = Mark(
        folder: NSHomeDirectory(), icon: symbolTile("house") ?? NSImage(), glyph: true,
        name: FileManager.default.displayName(atPath: NSHomeDirectory())
    )
    private static let rootMark = Mark(folder: "/", icon: symbolTile("number") ?? NSImage(), glyph: true, name: FileManager.default.displayName(atPath: "/"))

    private let queue = DispatchQueue(label: "com.lowtechguys.Cling.folderIcons", qos: .userInitiated)
    private var marks: [String: Mark?] = [:]
    /// The symbol picked for each drive in Settings, by its path.
    private var volumeIcons: [String: String] = [:]
    /// Moves on when a drive's icon may have changed, so a lookup that started before doesn't keep the old one.
    private var volumeGeneration = 0
    private var pending: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Mark?, Never>]] = [:]
    private var readyNotificationScheduled = false

    /// Each cloud folder's service icon and name, under its real path and the Home folder links that lead to it
    /// (`~/Dropbox`), which is how results show it. The same image every time, so the rows' rendered copy of it is reused.
    private lazy var cloudIcons: [String: (icon: NSImage, name: String)] = {
        var icons: [String: (icon: NSImage, name: String)] = [:]
        for location in FUZZY.cloudLocations {
            let service = (icon: location.icon, name: location.name)
            icons[location.root.string] = service
            if location.appPath == nil {
                // iCloud Drive's files are in its own folder inside Mobile Documents.
                icons[(location.root / "com~apple~CloudDocs").string] = service
            }
        }
        for link in SearchEngine.homeFolderLinks() {
            if let service = icons[link.real] {
                icons[link.shown] = service
            }
        }
        return icons
    }()

    private static func byPath(_ icons: [FilePath: String]) -> [String: String] {
        Dictionary(icons.map { ($0.key.string, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    private func forgetVolumes() {
        volumeGeneration += 1
        marks = marks.filter { !$0.key.hasPrefix(Self.volumes) }
        queue.async { Self.probe.forgetVolumes() }
        scheduleReadyNotification()
    }

    private func lookUp(_ key: String) {
        guard !pending.contains(key) else { return }
        pending.insert(key)
        let cloud = cloudIcons
        let cloudFolders = Set(cloud.keys)
        let network = FUZZY.networkVolumes.map { $0.string + "/" }
        let picked = volumeIcons
        let generation = volumeGeneration
        queue.async {
            let found = Self.probe.deepestMarked(in: key, cloudFolders: cloudFolders, network: network, picked: picked)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.pending.remove(key)
                    if key.hasPrefix(Self.volumes), generation != self.volumeGeneration {
                        self.lookUp(key)
                        return
                    }
                    let mark = found.flatMap { found in
                        (found.icon ?? cloud[found.folder]?.icon).map {
                            Mark(
                                folder: found.folder, icon: $0, glyph: found.glyph,
                                inside: found.icon == nil && found.folder.hasPrefix(Self.library), name: cloud[found.folder]?.name
                            )
                        }
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

    func deepestMarked(in dir: String, cloudFolders: Set<String>, network: [String], picked: [String: String]) -> Found? {
        // A drive's folders aren't looked into, which spares a slow drive the reads: its icon stands for all of them.
        if dir.hasPrefix(FolderIcons.volumes), let name = dir.dropFirst(FolderIcons.volumes.count).split(separator: "/", maxSplits: 1).first {
            let root = FolderIcons.volumes + name
            return symbol(volumeSymbol(root, picked: picked[root], network: network)).map { Found(folder: root, icon: $0, glyph: true) }
        }
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

    /// The symbol picked for the drive mounted at `root`, or its kind's. A network share is never asked, as it can
    /// take seconds to answer.
    func volumeSymbol(_ root: String, picked: String?, network: [String]) -> String {
        if let picked, symbol(picked) != nil {
            return picked
        }
        if network.contains(root + "/") {
            return "network"
        }
        if let kind = volumeKinds[root] {
            return kind
        }
        guard FileManager.default.fileExists(atPath: root) else { return "externaldrive.badge.xmark" }
        let kind = driveSymbol(root)
        volumeKinds[root] = kind
        return kind
    }

    func forgetVolumes() {
        volumeKinds.removeAll()
    }

    private let home = NSHomeDirectory()
    private var known: [String: (image: NSImage, glyph: Bool)?] = [:]
    private var volumeKinds: [String: String] = [:]
    private var symbols: [String: NSImage] = [:]
    private lazy var diskSession = DASessionCreate(kCFAllocatorDefault)

    /// The folders that macOS draws with an icon of their own.
    private lazy var systemFolders: Set<String> = {
        let inHome = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public", "Library", "Applications", "Sites", ".Trash"]
        return Set(inHome.map { home + "/" + $0 } + ["/Applications", "/Applications/Utilities", "/Library"])
    }()

    /// Folders told apart by their path alone, whose contents read better as a sign than as a folder icon.
    private let pathSymbols: [String: String] = [
        "/System": "apple.logo",
        "/bin": "terminal", "/sbin": "terminal", "/usr/bin": "terminal", "/usr/sbin": "terminal", "/usr/libexec": "terminal",
        "/usr/local/bin": "terminal", "/usr/local/sbin": "terminal",
        "/opt/homebrew": "mug", "/opt/homebrew/bin": "terminal", "/opt/homebrew/sbin": "terminal",
    ]

    private func icon(of folder: String, network: [String]) -> (image: NSImage, glyph: Bool)? {
        if let cached = known[folder] {
            return cached
        }
        let icon = lookUpIcon(of: folder, network: network)
        if known.count > 50000 {
            known.removeAll(keepingCapacity: true)
        }
        known[folder] = .some(icon)
        return icon
    }

    private func lookUpIcon(of folder: String, network: [String]) -> (image: NSImage, glyph: Bool)? {
        if let name = pathSymbols[folder] {
            return symbol(name).map { ($0, true) }
        }
        // A network share can take seconds to answer, and every lookup after it waits in line, so its folders are
        // never asked about: the share's own folder gets the network sign from the list of shares alone.
        if network.contains(folder + "/") {
            return symbol("network").map { ($0, true) }
        }
        if network.contains(where: { folder.hasPrefix($0) }) {
            return nil
        }
        if systemFolders.contains(folder) {
            return (NSWorkspace.shared.icon(forFile: folder), false)
        }
        let name = (folder as NSString).lastPathComponent
        let package = name.dropFirst().contains(".") && (try? URL(fileURLWithPath: folder).resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
        guard package || hasCustomIcon(folder) else { return nil }
        return pickedGlyph(folder).map { ($0, true) } ?? (NSWorkspace.shared.icon(forFile: folder), false)
    }

    /// The kind of drive mounted at `volume`, from DiskArbitration's description of it: a disk image, an SD card, a
    /// USB stick (removable media on USB; a USB disk is fixed), an internal disk, or an external one.
    private func driveSymbol(_ volume: String) -> String {
        guard let diskSession, let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, diskSession, URL(fileURLWithPath: volume) as CFURL),
              let info = DADiskCopyDescription(disk) as NSDictionary?
        else { return "externaldrive" }
        let bus = info[kDADiskDescriptionDeviceProtocolKey] as? String ?? ""
        let model = info[kDADiskDescriptionDeviceModelKey] as? String ?? ""
        if model == "Disk Image" || bus == "Disk Image" {
            return "shippingbox"
        }
        if bus == "Secure Digital" {
            return "sdcard"
        }
        if bus == "USB", info[kDADiskDescriptionMediaRemovableKey] as? Bool == true {
            return "mediastick"
        }
        return info[kDADiskDescriptionDeviceInternalKey] as? Bool == true ? "internaldrive" : "externaldrive"
    }

    /// One image per symbol and colour, so every row showing it draws the same one.
    private func symbol(_ name: String, label: Int = 0) -> NSImage? {
        let key = "\(name) \(label)"
        if let image = symbols[key] {
            return image
        }
        let image = symbolTile(name, label: label)
        symbols[key] = image
        return image
    }

    /// The Finder flag set by a custom icon and by a symbol or emoji picked in Finder.
    private func hasCustomIcon(_ path: String) -> Bool {
        var info = [UInt8](repeating: 0, count: 32)
        guard getxattr(path, "com.apple.FinderInfo", &info, 32, 0, XATTR_NOFOLLOW) == 32 else { return false }
        return (UInt16(info[8]) << 8 | UInt16(info[9])) & 0x0400 != 0
    }

    /// The symbol or emoji picked for the folder in Finder, on a tile in the folder's colour. Finder's own icon presses
    /// it into the folder a shade darker, which at the size of a line of text is too faint to make out.
    private func pickedGlyph(_ path: String) -> NSImage? {
        let attribute = "com.apple.icon.folder#S"
        let size = getxattr(path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, attribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read == size, let picked = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }

        let label = folderLabel(path)
        if let emoji = picked["emoji"] as? String, !emoji.isEmpty {
            return folderTile(label: label) { room in
                let text = NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: room.height * 0.9)])
                let size = text.size()
                text.draw(at: NSPoint(x: room.midX - size.width / 2, y: room.midY - size.height / 2))
            }
        }
        return (picked["sym"] as? String).flatMap { symbol($0, label: label) }
    }
}

/// The colour Finder draws a folder in, from its first colour tag, as a label number (1 gray, 2 green, 3 purple, 4 blue,
/// 5 yellow, 6 red, 7 orange), or 0 for an untagged folder's blue.
///
/// A tag is stored with its name and the number it had when it was added, and Finder colours the folder by the tag's
/// name as the tag list has it now. So a tag named after a colour counts as that colour whatever number it was stored
/// with (a folder tagged "Orange" years ago can carry 1, gray, and still show orange), and only a tag of another name
/// goes by its number.
private func folderLabel(_ path: String) -> Int {
    let attribute = "com.apple.metadata:_kMDItemUserTags"
    let size = getxattr(path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
    guard size > 0 else { return 0 }
    var data = Data(count: size)
    let read = data.withUnsafeMutableBytes { getxattr(path, attribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
    guard read == size, let tags = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String] else { return 0 }
    for tag in tags {
        let parts = tag.split(separator: "\n", maxSplits: 1)
        guard let name = parts.first?.lowercased() else { continue }
        if let label = labelByName[name] ?? parts.dropFirst().first.flatMap({ Int($0) }), (1 ... 7).contains(label) {
            return label
        }
    }
    return 0
}

/// The colour tags by name, in English and in the language macOS names them in here.
private let labelByName: [String: Int] = {
    var names = ["gray": 1, "grey": 1, "green": 2, "purple": 3, "blue": 4, "yellow": 5, "red": 6, "orange": 7]
    for (label, name) in NSWorkspace.shared.fileLabels.enumerated() where label > 0 {
        names[name.lowercased()] = label
    }
    return names
}()

/// Cling's own icon for a folder line: an SF Symbol on a rounded rectangle in a folder's colour (Finder's blue unless
/// `label` gives another), the size and shape of a folder icon, so it reads as one of the folder icons around it.
/// Drawn solid rather than cut out of the tile, which at this size leaves the symbol too thin to make out.
private func symbolTile(_ name: String, label: Int = 0) -> NSImage? {
    let colors = TileColors.of(label)
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 26, weight: .semibold).applying(.init(paletteColors: [colors.ink])))
    else { return nil }
    return folderTile(label: label) { room in
        let fit = min(room.width / symbol.size.width, room.height / symbol.size.height)
        let size = NSSize(width: symbol.size.width * fit, height: symbol.size.height * fit)
        symbol.draw(in: NSRect(x: room.midX - size.width / 2, y: room.midY - size.height / 2, width: size.width, height: size.height))
    }
}

/// The tile in the colour of `label`, with `content` drawn in the room inside it.
private func folderTile(label: Int = 0, _ content: @escaping (NSRect) -> Void) -> NSImage {
    let colors = TileColors.of(label)
    return NSImage(size: NSSize(width: 32, height: 32), flipped: false) { _ in
        // A little larger than a folder icon's own outline, which has its tab and pressed-in symbol to stand out by.
        let tile = NSRect(x: 1, y: 3, width: 30, height: 26)
        colors.fill.draw(in: NSBezierPath(roundedRect: tile, xRadius: 6.5, yRadius: 6.5), angle: -90)
        content(tile.insetBy(dx: 3, dy: 3))
        return true
    }
}

// MARK: - TileColors

/// A tile's colours: the top and bottom of a folder icon as macOS tints it for each colour tag, and the symbol in the
/// same hue, much darker than Finder's pressed-in one so it stays readable at this size.
private struct TileColors {
    private init(top: (CGFloat, CGFloat, CGFloat), bottom: (CGFloat, CGFloat, CGFloat)) {
        let bottomColor = NSColor(srgbRed: bottom.0, green: bottom.1, blue: bottom.2, alpha: 1)
        fill = NSGradient(starting: NSColor(srgbRed: top.0, green: top.1, blue: top.2, alpha: 1), ending: bottomColor)!
        let saturation = bottomColor.saturationComponent
        ink = NSColor(
            hue: bottomColor.hueComponent, saturation: saturation < 0.1 ? saturation : min(saturation + 0.15, 0.95),
            brightness: bottomColor.brightnessComponent * 0.62, alpha: 1
        )
    }

    let fill: NSGradient
    let ink: NSColor

    static func of(_ label: Int) -> TileColors {
        all[(0 ..< all.count).contains(label) ? label : 0]
    }

    private static let all: [TileColors] = [
        TileColors(top: (0.42, 0.79, 0.96), bottom: (0.30, 0.71, 0.89)), // no tag
        TileColors(top: (0.58, 0.58, 0.60), bottom: (0.50, 0.50, 0.52)), // gray
        TileColors(top: (0.29, 0.79, 0.40), bottom: (0.18, 0.71, 0.31)), // green
        TileColors(top: (0.80, 0.29, 0.88), bottom: (0.72, 0.16, 0.79)), // purple
        TileColors(top: (0.22, 0.56, 1.00), bottom: (0.00, 0.48, 0.91)), // blue
        TileColors(top: (1.00, 0.81, 0.22), bottom: (0.91, 0.72, 0.00)), // yellow
        TileColors(top: (1.00, 0.31, 0.32), bottom: (0.91, 0.20, 0.21)), // red
        TileColors(top: (1.00, 0.58, 0.27), bottom: (0.91, 0.50, 0.14)), // orange
    ]

}
