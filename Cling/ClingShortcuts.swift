import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts

func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
    var carbon = 0
    if flags.contains(.command) { carbon |= cmdKey }
    if flags.contains(.option)  { carbon |= optionKey }
    if flags.contains(.control) { carbon |= controlKey }
    if flags.contains(.shift)   { carbon |= shiftKey }
    return carbon
}

private func sc(_ keyCode: Int, _ mods: NSEvent.ModifierFlags) -> KeyboardShortcuts.Shortcut {
    KeyboardShortcuts.Shortcut(carbonKeyCode: keyCode, carbonModifiers: carbonModifiers(from: mods))
}

extension KeyboardShortcuts.Name {
    // open: bare ⏎ in non-terminal context is not rebindable; ⌘⇧⏎ is the terminal-context variant.
    static let clOpen                 = Self("cl_open",                 initial: sc(kVK_Return, [.command, .shift]))
    static let clShowInFinder         = Self("cl_showInFinder",         initial: sc(kVK_Return, [.command]))
    // quickLook: Space is handled separately and not rebindable; ⌘Y is the rebindable variant.
    static let clQuickLook            = Self("cl_quickLook",            initial: sc(kVK_ANSI_Y, [.command]))
    static let clOpenWith             = Self("cl_openWith",             initial: sc(kVK_ANSI_O, [.command]))
    static let clOpenInTerminal       = Self("cl_openInTerminal",       initial: sc(kVK_ANSI_T, [.command]))
    static let clOpenInEditor         = Self("cl_openInEditor",         initial: sc(kVK_ANSI_E, [.command]))
    static let clCopy                 = Self("cl_copy",                 initial: sc(kVK_ANSI_C, [.command]))
    static let clCopyPaths            = Self("cl_copyPaths",            initial: sc(kVK_ANSI_C, [.command, .shift]))
    static let clMoveTo               = Self("cl_moveTo",               initial: sc(kVK_ANSI_M, [.command]))
    static let clRename               = Self("cl_rename",               initial: sc(kVK_ANSI_R, [.command]))
    static let clShelve               = Self("cl_shelve",               initial: sc(kVK_ANSI_S, [.command]))
    static let clSendSecurely         = Self("cl_sendSecurely",         initial: sc(kVK_ANSI_U, [.command]))
    // pasteToFrontmost: bare ⏎ in terminal context is not rebindable; ⌘⇧⏎ is the non-terminal variant.
    static let clPasteToFrontmost     = Self("cl_pasteToFrontmost",     initial: sc(kVK_Return, [.command, .shift]))
    static let clTrash                = Self("cl_trash",                initial: sc(kVK_Delete, [.command]))
    static let clDropToFocusedElement = Self("cl_dropToFocusedElement", initial: sc(kVK_Return, [.option]))
    static let clDropToZone           = Self("cl_dropToZone",           initial: sc(kVK_Return, [.option, .shift]))
    static let clOpenWithFrontmost    = Self("cl_openWithFrontmost",    initial: sc(kVK_Return, [.command, .option]))
}

enum ClingShortcuts {
    static let nameByAction: [ActionID: KeyboardShortcuts.Name] = [
        .open:                 .clOpen,
        .showInFinder:         .clShowInFinder,
        .quickLook:            .clQuickLook,
        .openWith:             .clOpenWith,
        .openInTerminal:       .clOpenInTerminal,
        .openInEditor:         .clOpenInEditor,
        .copy:                 .clCopy,
        .copyPaths:            .clCopyPaths,
        .moveTo:               .clMoveTo,
        .rename:               .clRename,
        .shelve:               .clShelve,
        .sendSecurely:         .clSendSecurely,
        .pasteToFrontmost:     .clPasteToFrontmost,
        .trash:                .clTrash,
        .dropToFocusedElement: .clDropToFocusedElement,
        .dropToZone:           .clDropToZone,
        .openWithFrontmost:    .clOpenWithFrontmost,
    ]

    static let allNames = Array(nameByAction.values)

    static func name(for id: ActionID) -> KeyboardShortcuts.Name {
        nameByAction[id]!
    }

    /// We dispatch locally (not via global hotkeys), so the package's own conflict alert
    /// does not catch duplicates among OUR names. This finds another action using the same combo.
    @MainActor
    static func duplicateOwner(of shortcut: KeyboardShortcuts.Shortcut, excluding id: ActionID) -> ActionID? {
        for (actionID, name) in nameByAction where actionID != id {
            if KeyboardShortcuts.getShortcut(for: name) == shortcut { return actionID }
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
