import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts

func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
    var carbon = 0
    if flags.contains(.command) { carbon |= cmdKey }
    if flags.contains(.option) { carbon |= optionKey }
    if flags.contains(.control) { carbon |= controlKey }
    if flags.contains(.shift) { carbon |= shiftKey }
    return carbon
}

private func sc(_ keyCode: Int, _ mods: NSEvent.ModifierFlags) -> KeyboardShortcuts.Shortcut {
    KeyboardShortcuts.Shortcut(carbonKeyCode: keyCode, carbonModifiers: carbonModifiers(from: mods))
}

extension KeyboardShortcuts.Name {
    // open: bare ⏎ in non-terminal context is not rebindable; ⌘⇧⏎ is the terminal-context variant.
    static let clOpen = Self("cl_open", initial: sc(kVK_Return, [.command, .shift]))
    static let clShowInFinder = Self("cl_showInFinder", initial: sc(kVK_Return, [.command]))
    // quickLook: Space is handled separately and not rebindable; ⌘Y is the rebindable variant.
    static let clQuickLook = Self("cl_quickLook", initial: sc(kVK_ANSI_Y, [.command]))
    static let clOpenWith = Self("cl_openWith", initial: sc(kVK_ANSI_O, [.command]))
    static let clOpenInTerminal = Self("cl_openInTerminal", initial: sc(kVK_ANSI_T, [.command]))
    static let clOpenInEditor = Self("cl_openInEditor", initial: sc(kVK_ANSI_E, [.command]))
    static let clCopy = Self("cl_copy", initial: sc(kVK_ANSI_C, [.command]))
    static let clCopyPaths = Self("cl_copyPaths", initial: sc(kVK_ANSI_C, [.command, .shift]))
    static let clMoveTo = Self("cl_moveTo", initial: sc(kVK_ANSI_M, [.command]))
    static let clRename = Self("cl_rename", initial: sc(kVK_ANSI_R, [.command]))
    static let clShelve = Self("cl_shelve", initial: sc(kVK_ANSI_S, [.command]))
    static let clSendSecurely = Self("cl_sendSecurely", initial: sc(kVK_ANSI_U, [.command]))
    // pasteToFrontmost: bare ⏎ in terminal context is not rebindable; ⌘⇧⏎ is the non-terminal variant.
    static let clPasteToFrontmost = Self("cl_pasteToFrontmost", initial: sc(kVK_Return, [.command, .shift]))
    static let clTrash = Self("cl_trash", initial: sc(kVK_Delete, [.command]))
    static let clTogglePreview = Self("cl_togglePreview", initial: sc(kVK_ANSI_P, [.command, .shift]))
    static let clDropToFocusedElement = Self("cl_dropToFocusedElement", initial: sc(kVK_Return, [.option]))
    static let clDropToZone = Self("cl_dropToZone", initial: sc(kVK_Return, [.option, .shift]))
    static let clOpenWithFrontmost = Self("cl_openWithFrontmost", initial: sc(kVK_Return, [.command, .option]))

    // Sort shortcuts. Dispatched window-locally by ContentView's key monitor (never global
    // hotkeys, like the rest here). Defaults use Control+letter to stay clear of the saturated
    // ⌘-letter file-action space.
    static let clSortByScore = Self("cl_sortByScore", initial: sc(kVK_ANSI_0, [.control]))
    static let clSortByName = Self("cl_sortByName", initial: sc(kVK_ANSI_N, [.control]))
    static let clSortByPath = Self("cl_sortByPath", initial: sc(kVK_ANSI_P, [.control]))
    static let clSortBySize = Self("cl_sortBySize", initial: sc(kVK_ANSI_S, [.control]))
    static let clSortByDate = Self("cl_sortByDate", initial: sc(kVK_ANSI_D, [.control]))
}

// MARK: - ClingShortcuts

enum ClingShortcuts {
    // MARK: Sorting

    struct SortShortcut: Identifiable {
        let field: SortField
        let name: KeyboardShortcuts.Name
        let title: String
        let systemImage: String

        var id: String {
            field.rawValue
        }
    }

    static let nameByAction: [ActionID: KeyboardShortcuts.Name] = [
        .open: .clOpen,
        .showInFinder: .clShowInFinder,
        .quickLook: .clQuickLook,
        .openWith: .clOpenWith,
        .openInTerminal: .clOpenInTerminal,
        .openInEditor: .clOpenInEditor,
        .copy: .clCopy,
        .copyPaths: .clCopyPaths,
        .moveTo: .clMoveTo,
        .rename: .clRename,
        .shelve: .clShelve,
        .sendSecurely: .clSendSecurely,
        .pasteToFrontmost: .clPasteToFrontmost,
        .trash: .clTrash,
        .togglePreview: .clTogglePreview,
        .dropToFocusedElement: .clDropToFocusedElement,
        .dropToZone: .clDropToZone,
        .openWithFrontmost: .clOpenWithFrontmost,
    ]

    /// Rebindable sort shortcuts, shown in the Shortcuts settings pane and dispatched by
    /// ContentView's key monitor. Kept separate from `ToolbarAction` on purpose: sorting is not a
    /// per-file action and must never surface as a toolbar button or in the action overflow menu.
    static let sortShortcuts: [SortShortcut] = [
        .init(field: .score, name: .clSortByScore, title: "Sort by Relevance", systemImage: "sparkles"),
        .init(field: .name, name: .clSortByName, title: "Sort by Name", systemImage: "textformat"),
        .init(field: .path, name: .clSortByPath, title: "Sort by Path", systemImage: "folder"),
        .init(field: .size, name: .clSortBySize, title: "Sort by Size", systemImage: "arrow.up.arrow.down"),
        .init(field: .date, name: .clSortByDate, title: "Sort by Date", systemImage: "calendar"),
    ]

    static let sortNames = sortShortcuts.map(\.name)

    /// Every name we own, for "Reset all" and to keep them disabled at the package's global layer
    /// (all of ours are dispatched window-locally, so none may register a real global hotkey).
    static let allNames = Array(nameByAction.values) + sortNames

    static func name(for id: ActionID) -> KeyboardShortcuts.Name {
        nameByAction[id]!
    }

    /// The sort field bound to `shortcut`, if any — reverse lookup for the key monitor.
    @MainActor
    static func sortField(for shortcut: KeyboardShortcuts.Shortcut) -> SortField? {
        sortShortcuts.first { KeyboardShortcuts.getShortcut(for: $0.name) == shortcut }?.field
    }

    /// We dispatch locally (not via global hotkeys), so the package's own conflict alert does not
    /// catch duplicates among OUR names. This returns the display title of any OTHER of our
    /// shortcuts (file action or sort) already bound to `shortcut`, so the two sets can't silently
    /// share a combo.
    @MainActor
    static func conflictingTitle(with shortcut: KeyboardShortcuts.Shortcut, excluding name: KeyboardShortcuts.Name) -> String? {
        for (actionID, other) in nameByAction where other != name {
            if KeyboardShortcuts.getShortcut(for: other) == shortcut {
                return ToolbarAction.byID[actionID]?.title ?? actionID.rawValue
            }
        }
        for sort in sortShortcuts where sort.name != name {
            if KeyboardShortcuts.getShortcut(for: sort.name) == shortcut { return sort.title }
        }
        return nil
    }

    /// These names must NEVER register a global hotkey (they're dispatched window-locally),
    /// so keep them disabled at the package's global layer.
    @MainActor
    static func setup() {
        allNames.forEach { KeyboardShortcuts.disable($0) }
    }
}
