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
    guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }),
          let table = findTableView(in: window.contentView)
    else { return }
    if table.numberOfRows > 0 {
        table.scrollRowToVisible(0)
    }
}

private func findTableView(in view: NSView?) -> NSTableView? {
    guard let view else { return nil }
    if let table = view as? NSTableView { return table }
    for sub in view.subviews {
        if let found = findTableView(in: sub) { return found }
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
            log.error("\(error.localizedDescription, privacy: .public)")
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
