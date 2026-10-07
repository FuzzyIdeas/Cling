import ApplicationServices
import Cocoa
import OSLog

private let log = Logger(subsystem: clingSubsystem, category: "FilePanel")

// MARK: - FilePanel

/// An Open or Save panel shown by another app, pointed at files through the panel's own accessibility elements:
/// no keystrokes, no clicks and no drag, so the cursor and keyboard stay with the user.
///
/// Nothing in the panel sets its folder directly. Its URL, document and "Where" values are read-only, and the panel
/// service behind sandboxed apps only answers the app that owns it. So this goes there the way a person would: a
/// sidebar row or the "Where" pop-up to a folder above the target, then down one folder at a time, then selects.
///
/// Whatever the panel can't reach that way (folders it hides like `/private` or `~/Library`, paths through packages,
/// a result that doesn't read back as asked) makes `reveal` return false, and the caller drops the files instead.
final class FilePanel {
    private init(element: AXUIElement, kind: Kind) {
        self.element = element
        self.kind = kind
    }

    enum Kind { case open, save }

    /// Serial, so a second drop waits for the first instead of steering the same panel at the same time.
    static let queue = DispatchQueue(label: "com.lowtechguys.Cling.FilePanel", qos: .userInitiated)

    let kind: Kind

    /// The Open or Save panel in front in `app`, as a window or as a sheet.
    static func find(in app: NSRunningApplication) -> FilePanel? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier).withTimeout()
        let focused = appElement.element(kAXFocusedWindowAttribute)
        // A panel is modal, so it is the focused window or a sheet on it. Other windows only get the cheap
        // identifier check, in case focus is momentarily elsewhere.
        if let focused {
            for candidate in [focused] + focused.children.filter({ $0.role == kAXSheetRole }) {
                if let kind = kind(of: candidate, deep: true) {
                    return FilePanel(element: candidate, kind: kind)
                }
            }
        }
        for window in appElement.elements(kAXWindowsAttribute) {
            for candidate in [window] + window.children.filter({ $0.role == kAXSheetRole }) {
                if let kind = kind(of: candidate, deep: false) {
                    return FilePanel(element: candidate, kind: kind)
                }
            }
        }
        return nil
    }

    /// Points the panel at `urls` and returns true once it reads back the folder, selection and name asked for:
    /// - one folder: the panel shows its contents (Open) or saves into it (Save)
    /// - one file: the panel shows its folder with the file selected (Open), or saves into its folder under its
    ///   name (Save), where macOS asks before replacing the file
    /// - several: the panel shows the folder holding most of them, with those selected (Open) or as the destination
    ///   (Save)
    ///
    /// Blocks on accessibility calls to the other app, so it runs on `queue`.
    func reveal(_ urls: [URL]) -> Bool {
        let started = Date()
        guard let plan = Plan(urls, for: kind) else {
            log.info("Panel can't list the files, dropping them instead")
            return false
        }

        // A collapsed Save panel has no sidebar or file list to walk. It is expanded for the walk and collapsed again
        // after, because the panel remembers the state for the app's next Save panel.
        var expanded = false
        if kind == .save, fileView() == nil {
            guard expand() else {
                log.info("Save panel didn't expand")
                return false
            }
            expanded = true
        }

        var done = navigate(to: plan.folder)
        if done, !plan.selection.isEmpty {
            done = select(plan.selection, in: plan.folder)
        }
        if expanded {
            collapse()
        }
        if done, let name = plan.name {
            done = setName(name)
        }
        // Collapsing must not move the destination: check it afterwards, in the state the user sees.
        done = done && shows(plan.folder, final: true)

        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if done {
            log.info("Panel pointed at \(plan.selection.count) selected, name \(plan.name != nil), in \(ms)ms")
        } else {
            log.info("Panel didn't get there in \(ms)ms, dropping the files instead")
        }
        return done
    }

    private enum ViewKind { case icon, list, column }

    /// A file in the current file list: `cell` is what selecting takes (a row, or the cell around an icon or a
    /// column entry), `entry` carries the URL and opens on AXOpen.
    private struct Item {
        let cell: AXUIElement
        let entry: AXUIElement
        let path: String
    }

    /// What `reveal` aims for, worked out from the paths before touching the panel.
    private struct Plan {
        init?(_ urls: [URL], for kind: Kind) {
            // Paths as the panel lists them: real, but keeping `/private`, which `resolvingSymlinksInPath` drops.
            let paths = urls.compactMap { realPath($0.path) }
            guard !paths.isEmpty, paths.count == urls.count else { return nil }

            if paths.count == 1, isFolder(paths[0]) {
                folder = paths[0]
                selection = []
                name = nil
            } else {
                let byFolder = Dictionary(grouping: paths, by: parent)
                let most = byFolder.values.map(\.count).max() ?? 0
                // Ties go to the folder of the earliest file, which is the one the user picked first.
                let chosen = paths.map(parent).first { byFolder[$0]?.count == most }!
                folder = chosen
                selection = kind == .open ? Set(paths.filter { parent($0) == chosen }) : []
                name = kind == .save && paths.count == 1 ? (paths[0] as NSString).lastPathComponent : nil
            }

            // The panel lists neither hidden folders nor hidden files, and shows packages as files that AXOpen
            // would choose instead of entering.
            let root = volumeRoot(of: folder)
            guard browsable(folder, below: root), !selection.contains(where: isHidden) else { return nil }
        }

        /// The folder the panel ends up in.
        let folder: String
        /// Files to select there (Open panels).
        let selection: Set<String>
        /// The name for the name field (Save panels, one file).
        let name: String?
    }

    /// Rows the walk never needs to look inside when it is looking for the panel's own controls.
    private static let collectionRoles: Set<String> = [
        kAXOutlineRole, kAXListRole, kAXBrowserRole, kAXTableRole, kAXRowRole, kAXCellRole, kAXMenuRole, kAXScrollBarRole,
    ]

    private let element: AXUIElement
    private var cachedView: (view: AXUIElement, kind: ViewKind)?

    /// Looked up once, like the file list: its title is read on every step. The panel keeps it when it expands.
    private lazy var wherePopup: AXUIElement? = element.first(depth: 3, skipping: Self.collectionRoles) { $0.identifier == "where popup" }
        ?? element.first(depth: 3, skipping: Self.collectionRoles) { $0.role == kAXPopUpButtonRole }

    /// The name of the folder the panel shows, as its "Where" pop-up reads it.
    private var whereTitle: String? {
        wherePopup?.string(kAXValueAttribute)
    }

    private var sidebar: AXUIElement? {
        element.first(depth: 4, skipping: Self.collectionRoles) { e in
            e.role == kAXOutlineRole && e.identifier != "ListView" && Self.isSidebar(e)
        }
    }

    private var disclosure: AXUIElement? {
        element.first(depth: 3, skipping: Self.collectionRoles) { $0.identifier == "NS_OPEN_SAVE_DISCLOSURE_TRIANGLE" }
    }

    /// AppKit names its panels; systems that might not are recognised by the panel's own buttons, with the name
    /// field telling Save from Open.
    private static func kind(of element: AXUIElement, deep: Bool) -> Kind? {
        switch element.identifier {
        case "open-panel": return .open
        case "save-panel": return .save
        default: break
        }
        guard deep else { return nil }
        let ids = Set(element.descendants(depth: 2, skipping: collectionRoles) { !$0.identifier.isEmpty }.map(\.identifier))
        guard ids.contains("OKButton"), ids.contains("CancelButton") else { return nil }
        return ids.contains("saveAsNameTextField") ? .save : .open
    }

    private static func isSidebar(_ outline: AXUIElement) -> Bool {
        if outline.string(kAXDescriptionAttribute) == "sidebar" {
            return true
        }
        // The description is localized; the section headers (Favorites, Locations) carry a fixed identifier.
        return outline.elements(kAXRowsAttribute).prefix(4).contains { row in
            row.first(depth: 2) { $0.identifier == "xSidebarHeader" } != nil
        }
    }

    /// The file list, looked up once: the element stays the same while the panel changes folder, and every step polls
    /// it. Expanding or collapsing a Save panel adds or removes it, so those look again.
    private func fileView(refresh: Bool = false) -> (view: AXUIElement, kind: ViewKind)? {
        if !refresh, let cachedView, !cachedView.view.role.isEmpty {
            return cachedView
        }
        cachedView = findFileView()
        return cachedView
    }

    private func findFileView() -> (view: AXUIElement, kind: ViewKind)? {
        let view = element.first(depth: 5, skipping: Self.collectionRoles) { e in
            switch e.identifier {
            case "IconView", "ListView", "ColumnView": return true
            default: break
            }
            switch e.role {
            case kAXBrowserRole: return true
            case kAXListRole: return e.subrole == "AXCollectionList"
            case kAXOutlineRole: return !Self.isSidebar(e)
            default: return false
            }
        }
        guard let view else { return nil }
        switch (view.identifier, view.role) {
        case ("ColumnView", _), (_, kAXBrowserRole): return (view, .column)
        case ("ListView", _), (_, kAXOutlineRole): return (view, .list)
        default: return (view, .icon)
        }
    }

    // MARK: Reading the file list

    /// Column view's columns, one per folder of the path, deepest last: browser > scroll area > one scroll area per
    /// column > list.
    private func columns(_ browser: AXUIElement) -> [AXUIElement] {
        browser.descendants(depth: 3, skipping: [kAXListRole]) { $0.role == kAXListRole }
    }

    /// The entry carrying the URL in a list cell, row or icon: the name column comes first in a row.
    private func entry(in cell: AXUIElement, kind: ViewKind) -> AXUIElement? {
        let holder = kind == .list ? cell.children.first : cell
        return holder?.children.first { $0.path != nil }
    }

    /// The folder whose files the list shows, nil while it is empty or loading. Reads one entry, not the whole list.
    private func currentFolder() -> String? {
        guard let (view, kind) = fileView() else { return nil }
        switch kind {
        case .icon:
            return view.children.lazy.compactMap { $0.children.first.flatMap { self.entry(in: $0, kind: kind)?.path } }.first.map(parent)
        case .list:
            return view.elements(kAXRowsAttribute).first.flatMap { entry(in: $0, kind: kind)?.path }.map(parent)
        case .column:
            return columns(view).reversed().lazy.compactMap { $0.children.first.flatMap { self.entry(in: $0, kind: kind)?.path } }.first.map(parent)
        }
    }

    /// The listed entries for `paths`, which all sit in `folder`. Stops as soon as it has them all, and in column view
    /// only reads the column listing `folder`, since each URL costs a call into the other app.
    private func items(_ paths: Set<String>, in folder: String) -> [Item] {
        guard let (view, kind) = fileView() else { return [] }
        let cells: [AXUIElement]
        switch kind {
        case .icon:
            cells = view.children.flatMap(\.children)
        case .list:
            cells = view.elements(kAXRowsAttribute)
        case .column:
            let column = columns(view).reversed().first { column in
                column.children.first.flatMap { self.entry(in: $0, kind: kind)?.path }.map(parent) == folder
            }
            cells = column?.children ?? []
        }
        // Icon cells are named after their file, which skips reading the URL of every other file.
        let names = Set(paths.flatMap { [($0 as NSString).lastPathComponent, FileManager.default.displayName(atPath: $0)] })
        var found: [Item] = []
        for cell in cells {
            if kind == .icon, case let id = cell.identifier, !id.isEmpty, !names.contains(id) {
                continue
            }
            if let entry = entry(in: cell, kind: kind), let path = entry.path, paths.contains(path) {
                found.append(Item(cell: cell, entry: entry, path: path))
                if found.count == paths.count {
                    break
                }
            }
        }
        return found
    }

    private func item(_ path: String) -> Item? {
        items([path], in: parent(path)).first
    }

    /// Whether the panel shows `folder`. While walking, the "Where" title is enough and cheap; the final check also
    /// compares the listed files' folder, since two folders on the path can share a name.
    private func shows(_ folder: String, final: Bool = false) -> Bool {
        guard whereTitle == FileManager.default.displayName(atPath: folder) else { return false }
        guard final, let current = currentFolder() else { return true }
        return current == folder
    }

    // MARK: Moving

    private func navigate(to folder: String) -> Bool {
        let root = volumeRoot(of: folder)
        // Recents and search results list files from anywhere, so the listed files' folder only counts when the
        // "Where" title names it too.
        let current = currentFolder().flatMap { shows($0) ? $0 : nil }
        if current == folder {
            return true
        }
        // Already above it: only the way down is left.
        if let current, folder.hasPrefix(current == "/" ? "/" : current + "/"), descend(from: current, to: folder) {
            return true
        }
        // Beside it: up through the "Where" pop-up, which lists the current folder's parents, to the closest one they
        // share, then down. Saves walking down from the volume through folders the panel already passed.
        if let current, case let shared = sharedParent(current, folder), shared != root {
            let levels = depth(current) - depth(shared)
            log.debug("Going \(levels) folders up through the Where pop-up")
            if pickFromWhereMenu({ $0.indices.contains(levels) ? $0[levels] : nil }),
               waitFor(1.5, { self.shows(shared) }), descend(from: shared, to: folder)
            {
                return true
            }
        }
        return goToVolume(root) && descend(from: root, to: folder)
    }

    private func goToVolume(_ root: String) -> Bool {
        let name = FileManager.default.displayName(atPath: root)
        if let sidebar, let row = sidebar.elements(kAXRowsAttribute).first(where: { row in
            row.first(depth: 2) { $0.role == kAXStaticTextRole }?.string(kAXValueAttribute) == name
        }) {
            log.debug("Going to the volume through the sidebar")
            sidebar.set(kAXSelectedRowsAttribute, [row] as CFArray)
            if waitFor(1.5, { self.shows(root) }) {
                return true
            }
        }
        // The volume can be missing from the sidebar. The "Where" pop-up always ends at the computer, which lists
        // every volume.
        log.debug("Volume not in the sidebar, going through the computer")
        return pickFromWhereMenu { $0.last } && enter(root)
    }

    private func descend(from start: String, to folder: String) -> Bool {
        let rest = folder.dropFirst(start.count).split(separator: "/")
        var path = start
        for component in rest {
            path = (path as NSString).appendingPathComponent(String(component))
            guard enter(path) else {
                log.debug("Couldn't open a folder on the way down")
                return false
            }
        }
        return true
    }

    /// Opens `folder`, listed in the folder the panel shows, and waits until the panel shows its contents.
    private func enter(_ folder: String) -> Bool {
        var found: Item?
        guard waitFor(2, { found = self.item(folder); return found != nil }), let found, let (_, kind) = fileView() else {
            return false
        }
        switch kind {
        case .column:
            // AXOpen in column view is a double-click, which chooses the folder when the panel takes folders.
            // Selecting it opens the next column and chooses nothing.
            found.cell.element(kAXParentAttribute)?.set(kAXSelectedChildrenAttribute, [found.cell] as CFArray)
        case .icon, .list:
            // Reports an error even when it opens the folder; the panel is checked instead.
            AXUIElementPerformAction(found.entry, "AXOpen" as CFString)
        }
        return waitFor { self.shows(folder) }
    }

    /// Opens the "Where" pop-up and picks from the folders it lists: the current one first, then each parent up to
    /// the computer. Recent places after them are left out.
    private func pickFromWhereMenu(_ pick: ([AXUIElement]) -> AXUIElement?) -> Bool {
        guard let popup = wherePopup else { return false }
        AXUIElementPerformAction(popup, kAXPressAction as CFString)
        var menu: AXUIElement?
        guard waitFor(1, { menu = popup.first(depth: 1) { $0.role == kAXMenuRole }; return menu != nil }), let menu else {
            return false
        }
        let parents = Array(menu.children.prefix { !($0.string(kAXTitleAttribute) ?? "").isEmpty })
        guard let choice = pick(parents) else {
            AXUIElementPerformAction(menu, kAXCancelAction as CFString)
            return false
        }
        return AXUIElementPerformAction(choice, kAXPressAction as CFString) == .success
    }

    // MARK: Selecting and naming

    private func select(_ paths: Set<String>, in folder: String) -> Bool {
        var found: [Item] = []
        guard waitFor(2, {
            found = self.items(paths, in: folder)
            return found.count == paths.count
        }), let (view, kind) = fileView() else {
            log.debug("Files to select aren't listed")
            return false
        }

        // Each view takes its selection on a different element; the set reports errors even when it works.
        let cells = found.map(\.cell) as CFArray
        let holder: AXUIElement? = switch kind {
        case .icon: view
        case .list: view
        case .column: found[0].cell.element(kAXParentAttribute)
        }
        guard let holder else { return false }
        holder.set(kind == .list ? kAXSelectedRowsAttribute : kAXSelectedChildrenAttribute, cells)

        return waitFor(1) {
            let selected = holder.elements(kind == .list ? kAXSelectedRowsAttribute : kAXSelectedChildrenAttribute)
            return Set(selected.compactMap { self.entry(in: $0, kind: kind)?.path }) == paths
        }
    }

    private func setName(_ name: String) -> Bool {
        guard let field = element.first(depth: 3, skipping: Self.collectionRoles, where: { $0.identifier == "saveAsNameTextField" }) else {
            return false
        }
        // Entered through the field's editor rather than set as its value. Once the panel has changed folder, a value
        // set directly gets the panel's own extension added on save (`notes.md` saved as `notes.md.txt`), while text
        // entered through the editor is kept as is, like the name a drop puts there.
        field.set(kAXFocusedAttribute, kCFBooleanTrue)
        var all = CFRange(location: 0, length: (field.string(kAXValueAttribute) ?? "").utf16.count)
        if let range = AXValueCreate(.cfRange, &all) {
            field.set(kAXSelectedTextRangeAttribute, range)
        }
        field.set(kAXSelectedTextAttribute, name as CFString)
        if field.string(kAXValueAttribute) != name {
            field.set(kAXValueAttribute, name as CFString)
        }
        return field.string(kAXValueAttribute) == name
    }

    private func expand() -> Bool {
        guard let disclosure, (disclosure.value(kAXValueAttribute) as? Int) == 0 else { return false }
        AXUIElementPerformAction(disclosure, kAXPressAction as CFString)
        return waitFor { self.fileView(refresh: true) != nil }
    }

    private func collapse() {
        guard let disclosure, (disclosure.value(kAXValueAttribute) as? Int) == 1 else { return }
        AXUIElementPerformAction(disclosure, kAXPressAction as CFString)
        _ = waitFor { self.fileView(refresh: true) == nil }
    }

    /// Polls `condition` until it holds or `seconds` pass: the panel answers each step asynchronously.
    private func waitFor(_ seconds: TimeInterval = 1.5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() {
                return true
            }
            usleep(15000)
        }
        return condition()
    }
}

// MARK: - Paths

private func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

private func parent(_ path: String) -> String {
    (path as NSString).deletingLastPathComponent
}

private func depth(_ path: String) -> Int {
    path.split(separator: "/").count
}

private func sharedParent(_ a: String, _ b: String) -> String {
    let shared = zip(a.split(separator: "/"), b.split(separator: "/")).prefix { $0 == $1 }.map(\.0)
    return "/" + shared.joined(separator: "/")
}

/// Where the panel starts each volume: `/` for the startup disk, `/Volumes/<name>` for the others.
private func volumeRoot(of path: String) -> String {
    let parts = path.split(separator: "/")
    return parts.count >= 2 && parts[0] == "Volumes" ? "/Volumes/\(parts[1])" : "/"
}

private func resourceValues(_ path: String) -> URLResourceValues? {
    try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isHiddenKey])
}

/// A folder the panel opens rather than treating as a file: not a package.
private func isFolder(_ path: String) -> Bool {
    guard let values = resourceValues(path) else { return false }
    return values.isDirectory == true && values.isPackage != true
}

private func isHidden(_ path: String) -> Bool {
    resourceValues(path)?.isHidden == true
}

/// Whether each folder from `root` down to `folder` is listed by the panel and opens as a folder.
private func browsable(_ folder: String, below root: String) -> Bool {
    var path = root
    for component in folder.dropFirst(root.count).split(separator: "/") {
        path = (path as NSString).appendingPathComponent(String(component))
        guard isFolder(path), !isHidden(path) else { return false }
    }
    return true
}

// MARK: - Accessibility

private extension AXUIElement {
    var role: String {
        string(kAXRoleAttribute) ?? ""
    }
    var subrole: String {
        string(kAXSubroleAttribute) ?? ""
    }
    var identifier: String {
        string(kAXIdentifierAttribute) ?? ""
    }
    var children: [AXUIElement] {
        elements(kAXChildrenAttribute)
    }

    /// The file an entry in the file list stands for.
    var path: String? {
        (value(kAXURLAttribute) as? URL)?.standardizedFileURL.path
    }

    /// Every element handed out gets the short timeout: a call into a busy app or panel service would otherwise wait
    /// the default 6 seconds.
    @discardableResult
    func withTimeout() -> AXUIElement {
        AXUIElementSetMessagingTimeout(self, 1)
        return self
    }

    func value(_ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    func string(_ attribute: String) -> String? {
        value(attribute) as? String
    }

    func element(_ attribute: String) -> AXUIElement? {
        guard let value = value(attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement).withTimeout()
    }

    func elements(_ attribute: String) -> [AXUIElement] {
        guard let values = value(attribute) as? [AnyObject] else { return [] }
        return values.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement).withTimeout() : nil }
    }

    func set(_ attribute: String, _ value: CFTypeRef) {
        AXUIElementSetAttributeValue(self, attribute as CFString, value)
    }

    /// Depth-first, not looking inside `skipping` roles (after checking them), so a search for the panel's controls
    /// doesn't read every file in the list.
    func first(depth: Int, skipping: Set<String> = [], where match: (AXUIElement) -> Bool) -> AXUIElement? {
        for child in children {
            if match(child) {
                return child
            }
            if depth > 1, !skipping.contains(child.role), let found = child.first(depth: depth - 1, skipping: skipping, where: match) {
                return found
            }
        }
        return nil
    }

    func descendants(depth: Int, skipping: Set<String> = [], where match: (AXUIElement) -> Bool) -> [AXUIElement] {
        children.flatMap { child -> [AXUIElement] in
            let own = match(child) ? [child] : []
            guard depth > 1, !skipping.contains(child.role) else { return own }
            return own + child.descendants(depth: depth - 1, skipping: skipping, where: match)
        }
    }
}
