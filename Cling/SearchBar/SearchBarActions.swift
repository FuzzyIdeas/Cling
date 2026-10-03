//
//  SearchBarActions.swift
//  Cling
//
//  File actions, menus and filter handling for the search bar. Each action does what the main
//  window's toolbar does for the same selection, with the same shortcuts.
//

import AppKit
import Defaults
import KeyboardShortcuts
import Lowtech
import OSLog
import System

private let log = Logger(subsystem: clingSubsystem, category: "SearchBarActions")

extension SearchBarController {
    // MARK: Actions

    func perform(_ id: ActionID) {
        let sel = selection
        guard !sel.isEmpty || id == .togglePreview else { return }
        commitQuery()

        switch id {
        case .open:
            RH.trackRun(sel)
            for url in sel.map(\.url) {
                NSWorkspace.shared.open(url)
            }
            collapse()
        case .showInFinder:
            RH.trackRun(sel)
            revealInFinder(sel.map(\.url))
            collapse()
        case .quickLook:
            toggleQuickLook()
        case .openWith:
            showActionsMenu(.openWith)
        case .openInTerminal:
            guard let terminal = Defaults[.terminalApp].existingFilePath?.url else { return }
            RH.trackRun(sel)
            let dirs = sel.map { isDirectory($0) ? $0.url : $0.dir.url }.uniqued
            NSWorkspace.shared.open(dirs, withApplicationAt: terminal, configuration: .init(), completionHandler: { _, _ in })
            collapse()
        case .openInEditor:
            guard let editor = Defaults[.editorApp].existingFilePath?.url else { return }
            RH.trackRun(sel)
            NSWorkspace.shared.open(sel.map(\.url), withApplicationAt: editor, configuration: .init(), completionHandler: { _, _ in })
            collapse()
        case .copy:
            RH.trackRun(sel)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(sel.map(\.url) as [NSPasteboardWriting])
            root?.hintBar.flash("Copied")
        case .copyPaths:
            copyPaths(sel)
            root?.hintBar.flash("Copied")
        case .moveTo:
            activateForModal()
            SearchBarSheets.shared.request = .moveTo(sel)
        case .rename:
            activateForModal()
            SearchBarSheets.shared.request = .rename(sel)
        case .shelve:
            shelve(sel)
        case .sendSecurely:
            sendSecurely(sel)
        case .pasteToFrontmost:
            paste(sel, inTerminal: APP_MANAGER.frontmostAppIsTerminal)
        case .trash:
            confirmTrash(sel)
        case .togglePreview:
            Defaults[.searchBarShowPreview].toggle()
        case .dropToFocusedElement:
            RH.trackRun(sel)
            collapse()
            APP_MANAGER.dropToFocusedElement(paths: sel)
        case .dropToZone:
            RH.trackRun(sel)
            collapse()
            APP_MANAGER.dropToZone(paths: sel)
        case .openWithFrontmost:
            guard let appURL = APP_MANAGER.lastFrontmostApp?.bundleURL else { return }
            RH.trackRun(sel)
            NSWorkspace.shared.open(sel.map(\.url), withApplicationAt: appURL, configuration: .init(), completionHandler: { _, _ in })
            collapse()
        }
    }

    /// ⏎ and ⌘⇧⏎, which swap between opening and pasting depending on whether a terminal is in
    /// front, exactly as in the window.
    func performReturn(modifiers: NSEvent.ModifierFlags) -> Bool {
        guard !selection.isEmpty else { return false }
        let inTerminal = APP_MANAGER.frontmostAppIsTerminal
        let pastes = inTerminal && Defaults[.enterPastesToFrontmostTerminal]
        if modifiers.isEmpty {
            pastes ? paste(selection, inTerminal: true) : perform(.open)
            return true
        }
        if modifiers == [.command, .shift] {
            inTerminal ? perform(.open) : paste(selection, inTerminal: false)
            return true
        }
        return false
    }

    func performHint(_ id: SearchBarHint.ID) {
        switch id {
        case .open: perform(.open)
        case .paste: paste(selection, inTerminal: true)
        case .showInFinder: perform(.showInFinder)
        case .quickLook: toggleQuickLook()
        case .copy: perform(.copy)
        case .drill: drillIn()
        case .actions: showActionsMenu()
        case .window: switchToWindow()
        }
    }

    func removeFromResults(_ removed: Set<FilePath>) {
        guard !removed.isEmpty else { return }
        let ordered = results.items
        let next = ordered.lastIndex(where: { removed.contains($0) }).flatMap { last in
            ordered[(last + 1)...].first { !removed.contains($0) } ?? ordered[..<last].last { !removed.contains($0) }
        }
        STASH.remove(removed)
        FUZZY.results = FUZZY.results.filter { !removed.contains($0) }
        FUZZY.recents = FUZZY.recents.filter { !removed.contains($0) }
        FUZZY.sortedRecents = FUZZY.sortedRecents.filter { !removed.contains($0) }
        if let next, let row = results.items.firstIndex(of: next) {
            results.select(row: row)
        }
    }

    func applyRename(_ submission: RenameSubmission) {
        do {
            let renamed = try performRenameOperation(originalPaths: submission.originals, renamedPaths: submission.renamed)
            FUZZY.renamePaths(renamed)
            FUZZY.scoredResults = FUZZY.scoredResults.map { renamed[$0] ?? $0 }
            FUZZY.results = FUZZY.results.map { renamed[$0] ?? $0 }
        } catch {
            log.error("Error renaming files: \(error.localizedDescription)")
        }
        panel?.makeKey()
    }

    // MARK: Buttons

    @objc func toggleEverything(_: Any?) {
        EVERYTHING.toggle()
    }

    @objc func togglePreview(_: Any?) {
        Defaults[.searchBarShowPreview].toggle()
    }

    @objc func showFilterMenu(_ sender: Any?) {
        guard let root else { return }
        let button = root.filterButton
        filterMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
    }

    @objc func showSortMenu(_: Any?) {
        guard let root else { return }
        let button = root.sortButton
        sortMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
    }

    enum ActionsMenu { case all, openWith, scripts }

    /// ⌘K and the Actions hint, ⌘O for Open With and ⌘X for scripts. Pops up over the selected row when it's on
    /// screen, else at the hint.
    func showActionsMenu(_ kind: ActionsMenu = .all) {
        guard let root else { return }
        let menu: NSMenu
        switch kind {
        case .all: menu = actionsMenu()
        case .openWith: menu = openWithMenu()
        case .scripts:
            guard let scripts = scriptsMenu() else {
                NSSound.beep()
                return
            }
            menu = scripts
        }
        let table = results.tableView
        let row = table.selectedRowIndexes.first ?? -1
        if row >= 0, table.visibleRect.intersects(table.rect(ofRow: row)) {
            let rect = table.rect(ofRow: row)
            menu.popUp(positioning: nil, at: NSPoint(x: rect.minX + 56, y: rect.maxY), in: table)
        } else {
            menu.popUp(positioning: nil, at: NSPoint(x: 12, y: root.hintBar.bounds.minY), in: root.hintBar)
        }
    }

    // MARK: Menus

    /// The scripts that take the selection, Pro only as in the window; nil when there are none.
    func scriptsMenu() -> NSMenu? {
        let sel = selection
        guard proactive, !sel.isEmpty else { return nil }
        let scripts = SM.scriptURLs.filter { SM.isEligible($0, forPaths: sel) }
        guard !scripts.isEmpty else { return nil }
        let menu = NSMenu()
        for script in scripts {
            let scriptItem = item(script.deletingPathExtension().lastPathComponent, enabled: SM.process == nil) { controller in
                let paths = controller.selection
                RH.trackRun(paths)
                SM.run(script: script, args: paths.map(\.string))
            }
            if let key = SM.scriptShortcuts[script] {
                scriptItem.keyEquivalent = String(key)
                scriptItem.keyEquivalentModifierMask = [.command, .control]
            }
            menu.addItem(scriptItem)
        }
        return menu
    }

    func actionsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let sel = selection
        let hasSelection = !sel.isEmpty

        menu.addItem(item("Open", enabled: hasSelection, keyEquivalent: "\r", modifiers: []) { $0.perform(.open) })
        menu.addItem(item(action: .showInFinder, enabled: hasSelection))
        menu.addItem(item(action: .quickLook, enabled: hasSelection))
        menu.addItem(item("Get Info", enabled: hasSelection, keyEquivalent: "i", modifiers: .command) { controller in
            if let path = controller.selection.first {
                openFinderGetInfo(path)
            }
        })

        menu.addItem(.separator())
        let terminal = Defaults[.terminalApp]
        if HelperApp.isInstalled(terminal) {
            menu.addItem(item(action: .openInTerminal, title: "Open in \(terminal.filePath?.stem ?? "Terminal")", enabled: hasSelection))
        }
        let editor = Defaults[.editorApp]
        if HelperApp.isInstalled(editor) {
            menu.addItem(item(action: .openInEditor, title: "Edit in \(editor.filePath?.stem ?? "Editor")", enabled: hasSelection))
        }
        if let app = APP_MANAGER.lastFrontmostApp, app.bundleURL != nil {
            menu.addItem(item(action: .openWithFrontmost, title: "Open with \(app.name ?? "frontmost app")", enabled: hasSelection))
        }
        let openWith = NSMenuItem(title: "Open With…", action: nil, keyEquivalent: "")
        openWith.submenu = openWithMenu()
        openWith.isEnabled = hasSelection && !(openWith.submenu?.items.isEmpty ?? true)
        menu.addItem(openWith)
        menu.addItem(item("Paste to \(APP_MANAGER.lastFrontmostApp?.name ?? "frontmost app")", enabled: hasSelection) { controller in
            controller.paste(controller.selection, inTerminal: APP_MANAGER.frontmostAppIsTerminal)
        })

        if let submenu = scriptsMenu() {
            let scriptsItem = NSMenuItem(title: "Scripts", action: nil, keyEquivalent: "")
            scriptsItem.submenu = submenu
            menu.addItem(scriptsItem)
        }

        menu.addItem(.separator())
        menu.addItem(item(action: .rename, title: "Rename\(sel.count > 1 ? " (batch)..." : "...")", enabled: hasSelection))
        menu.addItem(item(action: .copy, enabled: hasSelection))
        menu.addItem(item(action: .copyPaths, enabled: hasSelection))
        menu.addItem(item("Copy Files To...", enabled: hasSelection) { controller in
            controller.activateForModal()
            SearchBarSheets.shared.request = .copyTo(controller.selection)
        })
        menu.addItem(item(action: .moveTo, title: "Move Files To...", enabled: hasSelection))

        menu.addItem(.separator())
        let allStashed = hasSelection && sel.allSatisfy { STASH.contains($0) }
        menu.addItem(item(allStashed ? "Remove from Stash" : "Add to Stash", enabled: hasSelection) { controller in
            STASH.toggle(controller.selection)
        })
        menu.addItem(item(action: .sendSecurely, enabled: hasSelection))

        menu.addItem(.separator())
        menu.addItem(item(action: .trash, title: "Move to Trash", enabled: hasSelection && !sel.contains(where: \.isOnReadOnlyVolume)))
        return menu
    }

    func openWithMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for app in FUZZY.commonOpenWithApps {
            let name = app.deletingPathExtension().lastPathComponent
            let entry = item(name, enabled: true) { controller in
                let paths = controller.selection
                RH.trackRun(paths)
                NSWorkspace.shared.open(paths.map(\.url), withApplicationAt: app, configuration: .init(), completionHandler: { _, _ in })
                controller.collapse()
            }
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            entry.image = icon
            if let key = FUZZY.openWithAppShortcuts[app] {
                entry.keyEquivalent = String(key)
                entry.keyEquivalentModifierMask = [.command, .option]
            }
            menu.addItem(entry)
        }
        return menu
    }

    func filterMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let folderFilters = Defaults[.folderFilters]
        let quickFilters = Defaults[.quickFilters]

        if !folderFilters.isEmpty {
            menu.addItem(.sectionHeader(title: "Folder filters"))
            for filter in folderFilters {
                let entry = item(filter.id, enabled: proactive) { _ in
                    FUZZY.folderFilter = FUZZY.folderFilter == filter ? nil : filter
                }
                entry.state = FUZZY.folderFilter == filter ? .on : .off
                entry.toolTip = "Searches in \(filter.folders.map(\.shellString).joined(separator: ", "))"
                if let key = filter.key {
                    entry.keyEquivalent = String(key)
                    entry.keyEquivalentModifierMask = .option
                }
                menu.addItem(entry)
            }
        }
        if !quickFilters.isEmpty {
            menu.addItem(.sectionHeader(title: "Quick filters"))
            for filter in quickFilters {
                let entry = item(filter.id, enabled: proactive) { _ in
                    FUZZY.quickFilter = FUZZY.quickFilter == filter ? nil : filter
                }
                entry.state = FUZZY.quickFilter == filter ? .on : .off
                entry.toolTip = filter.subtitle
                if let key = filter.key {
                    entry.keyEquivalent = String(key)
                    entry.keyEquivalentModifierMask = .option
                }
                menu.addItem(entry)
            }
        }
        let volumes = FUZZY.enabledVolumes
        if !volumes.isEmpty {
            menu.addItem(.sectionHeader(title: "Volumes"))
            for (i, volume) in ([FilePath.root] + volumes).enumerated() {
                let name = volume == .root ? (volume.url.volumeName ?? "Root") : volume.name.string
                let entry = item(name, enabled: !FUZZY.volumesIndexing.contains(volume)) { _ in
                    FUZZY.volumeFilter = FUZZY.volumeFilter == volume ? nil : volume
                }
                entry.state = FUZZY.volumeFilter == volume ? .on : .off
                if i <= 9 {
                    entry.keyEquivalent = String(i)
                    entry.keyEquivalentModifierMask = .option
                }
                menu.addItem(entry)
            }
        }

        menu.addItem(.separator())
        let clear = item("All files (clear filters)", enabled: true) { $0.clearFilters() }
        clear.keyEquivalent = "\u{1b}"
        clear.keyEquivalentModifierMask = .option
        menu.addItem(clear)
        if proactive {
            menu.addItem(item("Edit filters…", enabled: true) { controller in
                controller.activateForModal()
                SearchBarSheets.shared.request = .editFilters
            })
        }
        return menu
    }

    func sortMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for sort in ClingShortcuts.sortShortcuts {
            let entry = item(sort.title, enabled: true) { $0.applySort(sort.field) }
            entry.image = NSImage(systemSymbolName: sort.systemImage, accessibilityDescription: nil)
            entry.state = FUZZY.sortField == sort.field ? .on : .off
            if let shortcut = KeyboardShortcuts.getShortcut(for: sort.name), let key = shortcut.nsMenuItemKeyEquivalent {
                entry.keyEquivalent = key
                entry.keyEquivalentModifierMask = shortcut.modifiers
            }
            menu.addItem(entry)
        }
        return menu
    }

    /// A sort shortcut or menu pick: a new field takes its natural direction, the current one flips.
    func applySort(_ field: SortField) {
        let ascendingDefault = field == .name || field == .path
        let reverse = FUZZY.sortField == field ? !FUZZY.reverseSort : !ascendingDefault
        FUZZY.sortField = field
        FUZZY.reverseSort = reverse
    }

    func clearFilters() {
        FUZZY.folderFilter = nil
        FUZZY.quickFilter = nil
        FUZZY.volumeFilter = nil
    }

    /// ⌥ plus a filter's letter, or a digit for a volume, the same keys as in the window.
    func applyFilterKey(_ ch: Character) -> Bool {
        if proactive, let filter = Defaults[.quickFilters].first(where: { $0.key == ch }) {
            FUZZY.quickFilter = filter
            return true
        }
        if proactive, let filter = Defaults[.folderFilters].first(where: { $0.key == ch }) {
            FUZZY.folderFilter = filter
            return true
        }
        if let digit = ch.wholeNumberValue, !FUZZY.enabledVolumes.isEmpty {
            let volumes = [FilePath.root] + FUZZY.enabledVolumes
            if digit < volumes.count {
                FUZZY.volumeFilter = volumes[digit]
                return true
            }
        }
        return false
    }

    /// ⌘⌥ plus an app's letter opens the selection with it, as the window's Open With row does.
    func openWithShortcut(_ ch: Character) -> Bool {
        let sel = selection
        guard !sel.isEmpty else { return false }
        let group = FUZZY.openWithAppShortcuts.filter { $0.value == ch }.map(\.key)
        guard group.count == 1 else {
            if group.count > 1 {
                showActionsMenu(.openWith)
                return true
            }
            return false
        }
        RH.trackRun(sel)
        NSWorkspace.shared.open(sel.map(\.url), withApplicationAt: group[0], configuration: .init(), completionHandler: { _, _ in })
        collapse()
        return true
    }

    /// ⌃⌘ plus a script's letter, as in the window's Scripts row.
    func runScriptShortcut(_ ch: Character) -> Bool {
        let sel = selection
        guard proactive, SM.process == nil, !sel.isEmpty,
              let script = SM.scriptShortcuts.first(where: { $0.value == ch })?.key,
              SM.isEligible(script, forPaths: sel)
        else { return false }
        RH.trackRun(sel)
        SM.run(script: script, args: sel.map(\.string))
        return true
    }

    // MARK: Private helpers

    private func commitQuery() {
        if !FUZZY.query.isEmpty {
            SearchHistory.shared.commit(FUZZY.query)
        }
    }

    private func copyPaths(_ sel: [FilePath]) {
        let pathStr: (FilePath) -> String = Defaults[.copyPathsWithTilde] ? { $0.shellString } : { $0.string }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            APP_MANAGER.frontmostAppIsTerminal
                ? sel.map { pathStr($0).replacingOccurrences(of: " ", with: "\\ ") }.joined(separator: " ")
                : sel.map { pathStr($0) }.joined(separator: "\n"),
            forType: .string
        )
    }

    /// The bar holds the keyboard even though another app is active, so it has to go away before
    /// the paste keystroke is posted or the ⌘V would land back in the bar.
    private func paste(_ sel: [FilePath], inTerminal: Bool) {
        guard !sel.isEmpty else { return }
        RH.trackRun(sel)
        commitQuery()
        collapse()
        mainAsyncAfter(ms: 40) {
            if inTerminal {
                APP_MANAGER.pasteToFrontmostApp(paths: sel, separator: " ", quoted: true)
            } else {
                APP_MANAGER.pasteToFrontmostApp(paths: sel, separator: "\n", quoted: false)
            }
        }
    }

    private func shelve(_ sel: [FilePath]) {
        let shelfApp = Defaults[.shelfApp]
        if shelfApp == CLING_STASH_APP {
            STASH.toggle(results.items.filter { sel.contains($0) })
            return
        }
        guard let shelf = shelfApp.existingFilePath?.url else { return }
        RH.trackRun(sel)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.open(sel.map(\.url), withApplicationAt: shelf, configuration: config, completionHandler: { _, _ in })
    }

    private func sendSecurely(_ sel: [FilePath]) {
        let send = SendManager.shared
        let files = sel.map(\.url)
        let expiration = Defaults[.defaultLinkExpiration]
        let folders = send.folderCount(in: files)
        guard folders > 0, let panel else {
            send.requestSend(files: files, expiration: expiration)
            watchForLink()
            return
        }
        activateForModal()
        let alert = NSAlert()
        alert.messageText = "Archive folders before sending?"
        alert.informativeText = "\(folders) folder\(folders == 1 ? "" : "s") will be archived into a .zip before sending."
        alert.addButton(withTitle: "Create archive & send")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: panel) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                send.requestSend(files: files, expiration: expiration)
                send.confirmPendingSend()
                self?.watchForLink()
            }
        }
    }

    /// Flashes "Link copied" when the send hands back its link.
    private func watchForLink() {
        let tick = SendManager.shared.linkCopiedTick
        var remaining = 40
        func poll() {
            mainAsyncAfter(ms: 250) { [weak self] in
                guard let self, isExpanded else { return }
                if SendManager.shared.linkCopiedTick != tick {
                    root?.hintBar.flash("Link copied")
                } else if remaining > 0 {
                    remaining -= 1
                    poll()
                }
            }
        }
        poll()
    }

    private func confirmTrash(_ sel: [FilePath]) {
        guard !sel.contains(where: \.isOnReadOnlyVolume) else { return }
        guard !Defaults[.suppressTrashConfirm], let panel else {
            trash(sel)
            return
        }
        activateForModal()
        let alert = NSAlert()
        alert.messageText = "Are you sure?"
        alert.icon = NSImage(systemSymbolName: "trash.circle.fill", accessibilityDescription: nil)
        alert.addButton(withTitle: "Move to trash")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: panel) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                self?.trash(sel)
                self?.panel?.makeKey()
            }
        }
    }

    private func trash(_ sel: [FilePath]) {
        var removed = Set<FilePath>()
        for path in sel {
            log.info("Trashing \(path.shellString)")
            do {
                try FileManager.default.trashItem(at: path.url, resultingItemURL: nil)
                removed.insert(path)
            } catch {
                log.error("Error trashing \(path.shellString): \(error.localizedDescription)")
            }
        }
        removeFromResults(removed)
    }

    private func item(action id: ActionID, title: String? = nil, enabled: Bool) -> NSMenuItem {
        let action = ToolbarAction.byID[id]
        let entry = item(title ?? action?.title ?? id.rawValue, enabled: enabled) { $0.perform(id) }
        if let symbol = action?.systemImage {
            entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        if ToolbarAction.rebindable.contains(where: { $0.id == id }),
           let shortcut = KeyboardShortcuts.getShortcut(for: ClingShortcuts.name(for: id)),
           let key = shortcut.nsMenuItemKeyEquivalent
        {
            entry.keyEquivalent = key
            entry.keyEquivalentModifierMask = shortcut.modifiers
        }
        return entry
    }

    private func item(
        _ title: String,
        enabled: Bool,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = [],
        _ handler: @escaping @MainActor (SearchBarController) -> Void
    ) -> NSMenuItem {
        let entry = SearchBarMenuItem(title: title, action: #selector(SearchBarMenuItem.fire(_:)), keyEquivalent: keyEquivalent)
        entry.target = entry
        entry.keyEquivalentModifierMask = modifiers
        entry.isEnabled = enabled
        entry.handler = { [weak self] in
            guard let self else { return }
            handler(self)
        }
        return entry
    }
}

// MARK: - SearchBarMenuItem

/// A menu item that runs a closure, so the menus can be built inline without a selector per action.
final class SearchBarMenuItem: NSMenuItem {
    var handler: (@MainActor () -> Void)?

    @objc func fire(_: Any?) {
        MainActor.assumeIsolated { handler?() }
    }
}
