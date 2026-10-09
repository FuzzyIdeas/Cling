import AppKit
import Lowtech
import OSLog
import UniformTypeIdentifiers

private let log = Logger(subsystem: clingSubsystem, category: "Shared")

/// Reveal files in Finder. activateFileViewerSelecting alone doesn't reliably
/// bring up a Finder window when Finder has no windows visible — opening the
/// parent dirs first guarantees a window exists, then the selection sticks.
func revealInFinder(_ urls: [URL]) {
    guard !urls.isEmpty else { return }
    for parent in Set(urls.map { $0.deletingLastPathComponent() }) {
        NSWorkspace.shared.open(parent)
    }
    NSWorkspace.shared.activateFileViewerSelecting(urls)
}

/// SwiftUI Table on macOS doesn't auto-scroll on selection changes, so we
/// reach into the underlying NSTableView and explicitly scroll its first row
/// into view. Used after actions that prepend a new file to the results.
func scrollResultsTableToTop() {
    scrollResultsTable(toRow: 0)
}

func scrollResultsTable(toRow row: Int) {
    guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }),
          let table = findTableView(in: window.contentView)
    else { return }
    if row < table.numberOfRows {
        table.scrollRowToVisible(row)
    }
}

/// macOS 27's SwiftUI tables crash on a right-click below their last row: the context menu asks for the row view at
/// row -1 and AppKit throws. With no row under the pointer the menu has nothing of its own to act on, so the click is
/// dropped before it reaches the table.
@MainActor
func guardEmptyTableAreaRightClicks() {
    guard #available(macOS 27, *), emptyTableAreaMonitor == nil else { return }
    emptyTableAreaMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
        guard event.type == .rightMouseDown || event.modifierFlags.contains(.control),
              var view = event.window?.contentView?.hitTest(event.locationInWindow)
        else { return event }
        while !(view is NSTableView), let superview = view.superview {
            view = superview
        }
        guard let table = view as? NSTableView,
              table.row(at: table.convert(event.locationInWindow, from: nil)) == -1
        else { return event }
        return nil
    }
}

@MainActor private var emptyTableAreaMonitor: Any?

/// macOS 27's SwiftUI tables crash on a drag that starts in the header past the last column: AppKit asks whether
/// column -1 may move, and SwiftUI's table looks that column up without checking (CLING-AX). There is no column there
/// to move, so the answer is no without asking SwiftUI; every drag of a real column still reaches it unchanged.
@MainActor
func guardTableColumnReordering() {
    let selector = NSSelectorFromString("outlineView:shouldReorderColumn:toColumn:")
    guard #available(macOS 27, *), !tableColumnReorderingGuarded,
          let coordinator = NSClassFromString("_TtC7SwiftUI29AppKitOutlineTableCoordinator"),
          let method = class_getInstanceMethod(coordinator, selector)
    else { return }
    tableColumnReorderingGuarded = true

    typealias ShouldReorder = @convention(c) (AnyObject, Selector, NSOutlineView, Int, Int) -> Bool
    let original = unsafeBitCast(method_getImplementation(method), to: ShouldReorder.self)
    let guarded: @convention(block) (AnyObject, NSOutlineView, Int, Int) -> Bool = { coordinator, outlineView, column, target in
        guard (0 ..< outlineView.numberOfColumns).contains(column) else { return false }
        return original(coordinator, selector, outlineView, column, target)
    }
    method_setImplementation(method, imp_implementationWithBlock(guarded))
}

@MainActor private var tableColumnReorderingGuarded = false

private func findTableView(in view: NSView?) -> NSTableView? {
    guard let view else { return nil }
    if let table = view as? NSTableView {
        return table
    }
    for sub in view.subviews {
        if let found = findTableView(in: sub) {
            return found
        }
    }
    return nil
}

extension UTType {
    static let avif = UTType("public.avif")
    static let webm = UTType("org.webmproject.webm")
    static let mkv = UTType("org.matroska.mkv")
    static let mpeg = UTType("public.mpeg")
    static let wmv = UTType("com.microsoft.windows-media-wmv")
    static let flv = UTType("com.adobe.flash.video")
    static let m4v = UTType("com.apple.m4v-video")
}

let VIDEO_FORMATS: [UTType] = [.quickTimeMovie, .mpeg4Movie, .webm, .mkv, .mpeg2Video, .avi, .m4v, .mpeg].compactMap { $0 }
let IMAGE_FORMATS: [UTType] = [.webP, .avif, .heic, .bmp, .tiff, .png, .jpeg, .gif].compactMap { $0 }
let IMAGE_VIDEO_FORMATS = IMAGE_FORMATS + VIDEO_FORMATS
let ALL_FORMATS = IMAGE_FORMATS + VIDEO_FORMATS + [.pdf]

extension URL {
    func utType() -> UTType? {
        contentTypeResourceValue ?? fetchFileType()
    }

    func fetchFileType() -> UTType? {
        if let type = UTType(filenameExtension: pathExtension) {
            return type
        }

        guard let mimeType = shell("/usr/bin/file", args: ["-b", "--mime-type", path], timeout: 1.5).o else {
            return nil
        }

        return UTType(mimeType: mimeType)
    }

    var contentTypeResourceValue: UTType? {
        var type: AnyObject?

        do {
            try (self as NSURL).getResourceValue(&type, forKey: .contentTypeKey)
        } catch {
            log.error("\(error.localizedDescription)")
        }
        return type as? UTType
    }

    var canBeOptimisedByClop: Bool {
        if filePath?.isDir ?? false {
            return true
        }
        guard let type = utType() else { return false }
        return ALL_FORMATS.contains(type)
    }
}
