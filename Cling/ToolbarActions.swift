import Foundation
import Defaults

enum ActionID: String, CaseIterable, Codable, Defaults.Serializable {
    case open, showInFinder, quickLook, openWith, openInTerminal, openInEditor
    case copy, copyPaths, moveTo, rename, shelve
    case sendSecurely, pasteToFrontmost
    case trash
    case dropToFocusedElement, dropToZone, openWithFrontmost
}

enum ActionSegment: String, Codable, Defaults.Serializable, CaseIterable {
    case open, fileOps, share, destructive, alternate
}

struct ToolbarAction: Identifiable {
    let id: ActionID
    let segment: ActionSegment
    let title: String
    let systemImage: String
    let isDestructive: Bool
    let defaultVisible: Bool

    /// Registry: the single source of truth for every action's metadata.
    static let all: [ToolbarAction] = [
        .init(id: .open,            segment: .open,        title: "Open",               systemImage: "arrow.up.forward.app",                     isDestructive: false, defaultVisible: true),
        .init(id: .showInFinder,    segment: .open,        title: "Show in Finder",     systemImage: "folder",                                    isDestructive: false, defaultVisible: true),
        .init(id: .quickLook,       segment: .open,        title: "Quick Look",         systemImage: "eye",                                       isDestructive: false, defaultVisible: false),
        .init(id: .openWith,        segment: .open,        title: "Open With…",         systemImage: "square.and.arrow.up.on.square",             isDestructive: false, defaultVisible: false),
        .init(id: .openInTerminal,  segment: .open,        title: "Open in Terminal",   systemImage: "terminal",                                  isDestructive: false, defaultVisible: false),
        .init(id: .openInEditor,    segment: .open,        title: "Open in Editor",     systemImage: "chevron.left.forward.slash.chevron.right",  isDestructive: false, defaultVisible: false),
        .init(id: .copy,            segment: .fileOps,     title: "Copy",               systemImage: "doc.on.doc",                                isDestructive: false, defaultVisible: true),
        .init(id: .copyPaths,       segment: .fileOps,     title: "Copy paths",         systemImage: "text.alignleft",                            isDestructive: false, defaultVisible: false),
        .init(id: .moveTo,          segment: .fileOps,     title: "Move to…",           systemImage: "arrow.right.doc.on.clipboard",              isDestructive: false, defaultVisible: true),
        .init(id: .rename,          segment: .fileOps,     title: "Rename",             systemImage: "pencil",                                    isDestructive: false, defaultVisible: false),
        .init(id: .shelve,          segment: .fileOps,     title: "Shelve",             systemImage: "tray.and.arrow.down",                       isDestructive: false, defaultVisible: false),
        .init(id: .sendSecurely,    segment: .share,       title: "Send securely",      systemImage: "paperplane",                                isDestructive: false, defaultVisible: true),
        .init(id: .pasteToFrontmost,segment: .share,       title: "Paste to Frontmost", systemImage: "arrow.down.doc",                            isDestructive: false, defaultVisible: false),
        .init(id: .trash,           segment: .destructive, title: "Trash",              systemImage: "trash",                                     isDestructive: true,  defaultVisible: true),
        .init(id: .dropToFocusedElement, segment: .alternate, title: "Drop to Focused Element", systemImage: "arrow.down.to.line", isDestructive: false, defaultVisible: false),
        .init(id: .dropToZone,           segment: .alternate, title: "Drop to Zone",            systemImage: "rectangle.dashed",   isDestructive: false, defaultVisible: false),
        .init(id: .openWithFrontmost,    segment: .alternate, title: "Open with Frontmost App", systemImage: "app.badge",          isDestructive: false, defaultVisible: false),
    ]

    static let byID: [ActionID: ToolbarAction] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    /// Ordered curated default for the visible bar.
    static let defaultBar: [ActionID] = all.filter { $0.defaultVisible && $0.segment != .alternate }.map(\.id)

    /// Segment display order, left to right (alternate handled separately by the Option-held set).
    static let segmentOrder: [ActionSegment] = [.open, .fileOps, .share, .destructive]
}

extension ActionSegment {
    var title: String {
        switch self {
        case .open: "Open"
        case .fileOps: "File ops"
        case .share: "Share"
        case .destructive: "Destructive"
        case .alternate: "More actions"
        }
    }

    /// Segments shown in the overflow menu (alternate + destructive are not listed there).
    static let segmentSections: [ActionSegment] = [.open, .fileOps, .share]
}
