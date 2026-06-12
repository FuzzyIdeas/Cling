//
//  FilePreview.swift
//  Cling
//
//  Inline file preview panel shown to the right of the results table. Each file
//  type gets the most capable interactive renderer we can give it: native
//  AppKit views for media (so scroll / zoom / playback actually work, which an
//  embedded QLPreviewView does not in this borderless panel window), 7-Zip
//  listings for archives and disk images, and QuickLook only as a fallback.
//

import AppKit
import AVFoundation
import AVKit
import Defaults
import ImageIO
import Lowtech
import PDFKit
import QuickLookUI
import SwiftUI
import System
import UniformTypeIdentifiers

// MARK: - PreviewKind

enum PreviewKind {
    case folder
    case archive
    case image
    case pdf
    case video
    case audio
    case text
    case quicklook

    @MainActor
    init(for url: URL) {
        let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if vals?.isDirectory == true, vals?.isPackage != true {
            self = .folder
            return
        }

        let type = url.fileType
        if let type {
            if type.conforms(to: .image) {
                self = .image
                return
            }
            if type.conforms(to: .pdf) {
                self = .pdf
                return
            }
            if type.conforms(to: .audiovisualContent) || type.conforms(to: .movie) {
                // AVFoundation can't decode some containers (MKV, WebM, …); let
                // QuickLook handle those instead of a blank AVPlayerView.
                self = AVSupport.canPlay(type) ? .video : .quicklook
                return
            }
            if type.conforms(to: .audio) {
                self = AVSupport.canPlay(type) ? .audio : .quicklook
                return
            }
        }

        // Containers QuickLook has no real preview for (disk images, archives):
        // list their entries with 7-Zip instead of showing a bare icon.
        if SevenZip.canList(url), !QuickLookSupport.shared.canPreview(url) {
            self = .archive
            return
        }

        if let type, type.conforms(to: .text), !type.conforms(to: .rtf), !type.conforms(to: .html) {
            self = .text
            return
        }

        self = .quicklook
    }
}

extension URL {
    /// The file's UTType, by extension first (fast) then by content.
    var fileType: UTType? {
        if !pathExtension.isEmpty, let byExt = UTType(filenameExtension: pathExtension.lowercased()) {
            return byExt
        }
        return try? resourceValues(forKeys: [.contentTypeKey]).contentType
    }
}

// MARK: - FilePreviewPanel

struct FilePreviewPanel: View {
    let paths: [FilePath]

    var body: some View {
        VStack(spacing: 0) {
            if let path = current {
                header(for: path)
                Divider().opacity(0.5)
                content(for: path)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyState
            }
            Divider().opacity(0.4)
            hideHint
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: selectionKey) {
            // The selected files changed: jump back to the first one.
            index = 0
        }
        .onChange(of: paths.count) { _, newValue in pathCount = newValue }
        .onAppear {
            pathCount = paths.count
            installArrowMonitor()
        }
        .onDisappear { removeArrowMonitor() }
    }

    @State private var index = 0
    @State private var hintHovering = false
    // Mirror of paths.count, read by the arrow-key monitor (which captures a
    // frozen `self`, so it can only see live values through @State storage).
    @State private var pathCount = 0
    @State private var arrowMonitor: Any?

    /// Identity of the current selection, so navigation resets when it changes
    /// but stays put while paging through the same set.
    private var selectionKey: String {
        "\(paths.count)|\(paths.first?.string ?? "")|\(paths.last?.string ?? "")"
    }

    private var current: FilePath? {
        guard !paths.isEmpty else { return nil }
        return paths[safe: index] ?? paths.first
    }

    private var navControls: some View {
        HStack(spacing: 4) {
            Button { step(-1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(index <= 0)
            Text("\(index + 1) of \(paths.count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button { step(1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(index >= paths.count - 1)
        }
        .help("Step through selected files (← →)")
    }

    private var hideHint: some View {
        Button {
            Defaults[.showFilePreview] = false
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 9))
                Text("⌘⇧P to toggle")
                    .font(.system(size: 10, design: .rounded))
            }
            .foregroundStyle(.secondary)
            .opacity(hintHovering ? 0.95 : 0.3)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hintHovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hintHovering)
        .help("Hide the preview panel")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 32))
                .foregroundStyle(.quaternary)
            Text("No selection")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(for path: FilePath) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: path.memoz.icon)
                .resizable()
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(path.name.string)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(path.dir.shellString)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if paths.count > 1 {
                navControls
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private func content(for path: FilePath) -> some View {
        switch PreviewKind(for: path.url) {
        case .folder:
            FolderPreview(path: path)
        case .archive:
            ArchivePreview(path: path)
        case .image:
            ImageScrollPreview(url: path.url)
        case .pdf:
            PDFKitPreview(url: path.url)
        case .video, .audio:
            AVPreview(url: path.url)
        case .text:
            CodePreviewView(url: path.url)
        case .quicklook:
            QuickLookPreview(url: path.url)
        }
    }

    private func step(_ delta: Int) {
        index = min(max(index + delta, 0), max(pathCount - 1, 0))
    }

    /// Flip through the multi-file selection with ← / → while the pointer is over
    /// the preview. Left/right do nothing in the results table, so we take them
    /// whenever focus isn't in a text field (the search caret and word-by-word
    /// autocomplete still own the arrows there).
    private func installArrowMonitor() {
        guard arrowMonitor == nil else { return }
        arrowMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Arrow keys always carry .function/.numericPad, so only reject the
            // real modifiers here.
            guard pathCount > 1,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  event.window?.identifier?.rawValue == "main"
            else {
                return event
            }
            // Leave the search field's caret / autocomplete arrows alone.
            if NSApp.keyWindow?.firstResponder is NSText {
                return event
            }
            switch event.keyCode {
            case 123: step(-1); return nil // left arrow
            case 124: step(1); return nil // right arrow
            default: return event
            }
        }
    }

    private func removeArrowMonitor() {
        if let arrowMonitor {
            NSEvent.removeMonitor(arrowMonitor)
        }
        arrowMonitor = nil
    }
}

// MARK: - PDFKitPreview

struct PDFKitPreview: NSViewRepresentable {
    final class Coordinator {
        weak var view: PDFView?

        func load(_ url: URL) {
            guard loadedURL != url else { return }
            loadedURL = url
            // Parse off the main thread: a huge or malformed PDF can be slow.
            DispatchQueue.global(qos: .userInitiated).async {
                let document = PDFDocument(url: url)
                DispatchQueue.main.async {
                    guard self.loadedURL == url else { return }
                    self.view?.document = document
                }
            }
        }

        private var loadedURL: URL?

    }

    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .clear
        context.coordinator.view = view
        context.coordinator.load(url)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        context.coordinator.load(url)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

}

// MARK: - AVPreview

struct AVPreview: NSViewRepresentable {
    let url: URL

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        let currentURL = (nsView.player?.currentItem?.asset as? AVURLAsset)?.url
        guard currentURL != url else { return }
        nsView.player?.pause()
        nsView.player = AVPlayer(url: url)
    }

}

// MARK: - ImageScrollPreview

/// An image inside a scroll view with native trackpad pinch-to-zoom and scroll.
struct ImageScrollPreview: NSViewRepresentable {
    final class Coordinator {
        weak var scroll: ZoomableImageScrollView?
        weak var fallback: NSView?

        func load(_ url: URL) {
            guard loadedURL != url else { return }
            loadedURL = url
            guard let scroll, let imageView = scroll.documentView as? NSImageView else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let image = Self.loadBounded(url)
                DispatchQueue.main.async {
                    guard self.loadedURL == url else { return }
                    if let image {
                        imageView.image = image
                        scroll.isHidden = false
                        scroll.refit()
                    } else {
                        // NSImage can't decode it (RAW, exotic formats): hand off to QuickLook.
                        self.showQuickLookFallback(for: url)
                    }
                }
            }
        }

        private var loadedURL: URL?

        /// Decodes the image, downsampling anything enormous so a giant file
        /// (e.g. a 30000×30000 TIFF) can't allocate gigabytes and hang the UI.
        private static func loadBounded(_ url: URL) -> NSImage? {
            let maxPixel = 8192
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                return NSImage(contentsOf: url)
            }
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let width = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
            guard width > maxPixel || height > maxPixel else {
                return NSImage(contentsOf: url)
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }

        private func showQuickLookFallback(for url: URL) {
            guard let fallback, let scroll else { return }
            scroll.isHidden = true
            if fallback.subviews.contains(where: { $0 is QLPreviewView }) {
                (fallback.subviews.first { $0 is QLPreviewView } as? QLPreviewView)?.previewItem = url as NSURL
                return
            }
            guard let ql = QLPreviewView(frame: fallback.bounds, style: .normal) else { return }
            ql.autoresizingMask = [.width, .height]
            ql.previewItem = url as NSURL
            fallback.addSubview(ql)
        }
    }

    let url: URL

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerCurve = .continuous
        container.layer?.cornerRadius = 6
        container.layer?.masksToBounds = true

        let scroll = ZoomableImageScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 20
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let clip = CenteringClipView()
        clip.drawsBackground = false
        scroll.contentView = clip

        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageFrameStyle = .none
        imageView.animates = true
        scroll.documentView = imageView

        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        context.coordinator.scroll = scroll
        context.coordinator.fallback = container
        context.coordinator.load(url)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.load(url)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

}

// MARK: - ZoomableImageScrollView

/// Scroll view that fits its image to the viewport the first time it gets a real
/// size, and again whenever the image changes.
final class ZoomableImageScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard !fitted,
              let imageView = documentView as? NSImageView,
              let image = imageView.image,
              bounds.width > 1, bounds.height > 1
        else { return }

        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        imageView.frame = NSRect(origin: .zero, size: size)
        let fit = min(bounds.width / size.width, bounds.height / size.height)
        magnification = min(fit, 1) // show small images at 100%, shrink large ones to fit
        fitted = true
    }

    func refit() {
        fitted = false
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private var fitted = false

}

// MARK: - CenteringClipView

/// Keeps the image centered in the viewport when it's smaller than the panel,
/// instead of letting it sink to the bottom-left (AppKit's default origin).
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let docFrame = documentView.frame
        if docFrame.width < rect.width {
            rect.origin.x = (docFrame.width - rect.width) / 2
        }
        if docFrame.height < rect.height {
            rect.origin.y = (docFrame.height - rect.height) / 2
        }
        return rect
    }
}

// MARK: - QuickLookPreview

/// Embedded QuickLook preview backed by `QLPreviewView`. Used only as a fallback
/// for types we don't render natively; it renders but is not fully interactive
/// inside this panel window.
struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    static func dismantleNSView(_ nsView: QLPreviewView, coordinator: ()) {
        nsView.close()
    }

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView(frame: .zero)!
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        guard (nsView.previewItem as? URL) != url else { return }
        nsView.previewItem = url as NSURL
        nsView.refreshPreviewItem()
    }

}

// MARK: - DirEntry

private struct DirEntry: Identifiable {
    let path: FilePath
    let isDir: Bool

    var id: String { path.string }
}

// MARK: - FolderPreview

struct FolderPreview: View {
    let path: FilePath

    var body: some View {
        Group {
            if loading {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                Text("Empty folder")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(entries) { entry in
                            HStack(spacing: 6) {
                                Image(nsImage: entry.path.memoz.icon)
                                    .resizable()
                                    .frame(width: 15, height: 15)
                                Text(entry.path.name.string)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 4)
                                if entry.isDir {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.tertiary)
                                } else {
                                    Text(entry.path.memoz.humanizedFileSize)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .listRowSeparator(.hidden)
                        }
                    } header: {
                        Text("\(entries.count) item\(entries.count == 1 ? "" : "s")\(truncated ? "+" : "")")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .task(id: path.string) {
            await load()
        }
    }

    @State private var entries: [DirEntry] = []
    @State private var truncated = false
    @State private var loading = true

    private func load() async {
        loading = true
        let url = path.url
        let result: ([DirEntry], Bool) = await Task.detached(priority: .userInitiated) {
            let limit = 2000
            // Enumerate lazily and stop at the cap, so a directory with millions
            // of entries never loads the whole listing into memory.
            guard let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ) else {
                return ([], false)
            }
            var collected: [DirEntry] = []
            var truncated = false
            for case let childURL as URL in enumerator {
                if collected.count >= limit { truncated = true; break }
                let isDir = (try? childURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                collected.append(DirEntry(path: FilePath(childURL.path), isDir: isDir))
            }
            let entries = collected.sorted { a, b in
                if a.isDir != b.isDir { return a.isDir }
                return a.path.name.string.localizedCaseInsensitiveCompare(b.path.name.string) == .orderedAscending
            }
            return (entries, truncated)
        }.value

        entries = result.0
        truncated = result.1
        loading = false
    }
}

// MARK: - ArchivePreview

struct ArchivePreview: View {
    let path: FilePath

    var body: some View {
        Group {
            if loading {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let listing, !listing.entries.isEmpty {
                List {
                    Section {
                        ForEach(listing.entries) { entry in
                            HStack(spacing: 6) {
                                Image(systemName: entry.isDir ? "folder" : "doc")
                                    .font(.system(size: 10))
                                    .foregroundStyle(entry.isDir ? Color.accentColor : .secondary)
                                    .frame(width: 15)
                                Text(entry.name)
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .listRowSeparator(.hidden)
                        }
                    } header: {
                        Text("\(listing.entries.count)\(listing.truncated ? "+" : "") entr\(listing.entries.count == 1 ? "y" : "ies")\(listing.truncated ? " (truncated)" : "")")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            } else {
                // No usable listing: let QuickLook take its best shot.
                QuickLookPreview(url: path.url)
            }
        }
        .task(id: path.string) {
            await load()
        }
    }

    @State private var listing: SevenZip.Listing? = nil
    @State private var loading = true

    private func load() async {
        loading = true
        listing = await SevenZip.cachedList(path.url).value
        loading = false
    }
}

// MARK: - SevenZip

/// Lists archive and disk-image contents with the bundled 7-Zip, the same way
/// the "List contents" script does, without extracting or mounting anything.
enum SevenZip {
    struct Entry: Identifiable {
        let name: String
        let isDir: Bool

        var id: String { name }
    }

    struct Listing {
        let entries: [Entry]
        let truncated: Bool
        var totalUncompressedSize: Int64 = 0
    }

    /// Archive, disk-image, and filesystem-image extensions 7-Zip can list.
    /// Document containers (docx, xlsx, epub, …) and installer packages are left
    /// out so they stay on their proper QuickLook preview.
    static let listableExtensions: Set<String> = [
        "zip", "zipx", "jar", "xpi", "7z", "rar", "r00", "tar", "gz", "tgz", "taz",
        "bz2", "bzip2", "tbz", "tbz2", "xz", "txz", "zst", "tzst", "lz", "lzma",
        "lzh", "lha", "arj", "cab", "cpio", "ar", "deb", "rpm", "wim", "swm", "esd",
        "dmg", "iso", "img", "cdr", "toast", "vhd", "vhdx", "vmdk", "vdi", "qcow",
        "qcow2", "qcow2c", "squashfs", "udf", "xar", "lit", "chm", "z", "mbr",
        "nsis", "cramfs", "apfs", "apm", "hfs", "hfsx", "ntfs", "fat", "ext",
        "ext2", "ext3", "ext4", "msi",
    ]

    static func canList(_ url: URL) -> Bool {
        listableExtensions.contains(url.pathExtension.lowercased())
    }

    static func list(_ url: URL) async -> Listing? {
        let process = Process()
        process.executableURL = SEVEN_ZIP.url
        process.arguments = ["l", "-slt", "-bso0", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        // Discard stderr: an undrained stderr pipe could fill and deadlock the read.
        process.standardError = FileHandle.nullDevice

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Listing?, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(returning: nil)
                        return
                    }

                    // Kill the process if it runs too long, even while producing no output.
                    let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

                    let handle = pipe.fileHandleForReading
                    var data = Data()
                    var flooded = false
                    while true {
                        let chunk = handle.availableData
                        if chunk.isEmpty { break } // EOF or pipe closed by terminate()
                        data.append(chunk)
                        if data.count >= maxBytes {
                            flooded = true
                            if process.isRunning { process.terminate() }
                            break
                        }
                    }
                    watchdog.cancel()
                    process.waitUntilExit()

                    let (entries, capped, totalSize) = parse(String(decoding: data, as: UTF8.self))
                    // A clean run with no entries (unsupported/corrupt) → nil so we fall back to QuickLook.
                    if entries.isEmpty, !flooded, process.terminationStatus != 0 {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(returning: Listing(entries: entries, truncated: flooded || capped, totalUncompressedSize: totalSize))
                    }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// Memoized listings keyed by path+mtime so the archive preview and the
    /// info bar share a single 7z subprocess per archive. Tiny FIFO cache:
    /// listings of huge archives can hold thousands of entries.
    @MainActor private static var listTasks: [String: Task<Listing?, Never>] = [:]
    @MainActor private static var listTaskOrder: [String] = []

    @MainActor
    static func cachedList(_ url: URL) -> Task<Listing?, Never> {
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(mtime)"
        if let task = listTasks[key] { return task }
        let task = Task { await list(url) }
        listTasks[key] = task
        listTaskOrder.append(key)
        if listTaskOrder.count > 8 {
            listTasks.removeValue(forKey: listTaskOrder.removeFirst())
        }
        return task
    }

    // Bounds so a zip bomb or huge archive can never hang the UI or run forever.
    private static let timeout: TimeInterval = 6
    private static let maxBytes = 8 * 1024 * 1024
    private static let maxEntries = 5000

    /// Pairs each `Path =` with the following `Folder =`/`Mode =` marker, which
    /// drops the archive's own header line and tells files from directories.
    /// Stops at `maxEntries` so a bomb with millions of entries stays bounded.
    private static func parse(_ text: String) -> (entries: [Entry], capped: Bool, totalSize: Int64) {
        var seen = Set<String>()
        var entries: [Entry] = []
        var path: String?
        var capped = false
        var pastHeader = false
        var totalSize: Int64 = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if entries.count >= maxEntries { capped = true; break }
            let line = String(rawLine)
            if line.hasPrefix("Path = ") {
                path = String(line.dropFirst("Path = ".count))
            } else if line.hasPrefix("Folder = ") {
                if let p = path, !p.isEmpty, seen.insert(p).inserted {
                    entries.append(Entry(name: p, isDir: line.dropFirst("Folder = ".count).first == "+"))
                }
                path = nil
            } else if line.hasPrefix("Mode = ") {
                if let p = path, !p.isEmpty, seen.insert(p).inserted {
                    entries.append(Entry(name: p, isDir: line.dropFirst("Mode = ".count).first == "d"))
                }
                path = nil
            } else if line == "----------" {
                pastHeader = true
            } else if pastHeader, line.hasPrefix("Size = "), let size = Int64(line.dropFirst("Size = ".count)) {
                totalSize += size
            }
        }
        let sorted = entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return (sorted, capped, totalSize)
    }
}

// MARK: - AVSupport

/// Which audiovisual types AVFoundation can actually play. MKV/WebM and other
/// containers it can't decode are absent, so they fall through to QuickLook.
enum AVSupport {
    static func canPlay(_ type: UTType) -> Bool {
        playable.contains { type.conforms(to: $0) }
    }

    private static let playable: [UTType] = AVURLAsset.audiovisualTypes().compactMap { UTType($0.rawValue) }

}

// MARK: - QuickLookSupport

/// Detects which UTIs QuickLook actually has a generator for, by parsing
/// `qlmanage -m`. Used to decide when a custom preview (7-Zip listing for disk
/// images, etc.) beats QuickLook's bare icon.
@MainActor
final class QuickLookSupport {
    static let shared = QuickLookSupport()

    private(set) var supportedUTIs: Set<String> = []

    func warmUp() {
        guard !ready else { return }
        detect(attemptsLeft: 3)
    }

    /// Until detection finishes, assume QuickLook can handle a file so we don't
    /// wrongly fall back to a listing for something it previews well.
    func canPreview(_ url: URL) -> Bool {
        guard ready else { return true }
        guard let type = url.fileType else { return false }
        if supportedUTIs.contains(type.identifier) { return true }
        return type.supertypes.contains { supportedUTIs.contains($0.identifier) }
    }

    /// Modern QuickLook provider extensions don't show up in `qlmanage -m`; keep
    /// a small supplement so they aren't mistaken for unsupported.
    private static let supplement: Set<String> = ["org.idpf.epub-container"]

    private var ready = false

    private static func runQLManage() -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-m"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }

        // Lines under "plugins:" look like "  <uti> -> /path/to.qlgenerator (ver)".
        var set = Set<String>()
        var inPlugins = false
        for rawLine in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let line = String(rawLine)
            if line.hasPrefix("plugins:") { inPlugins = true; continue }
            guard inPlugins, let arrow = line.range(of: " -> ") else { continue }
            let uti = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
            if !uti.isEmpty { set.insert(uti) }
        }
        return set
    }

    private func detect(attemptsLeft: Int) {
        DispatchQueue.global(qos: .utility).async {
            let utis = Self.runQLManage()
            DispatchQueue.main.async {
                // qlmanage occasionally returns empty/errors; retry a couple times.
                if utis.isEmpty, attemptsLeft > 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self.detect(attemptsLeft: attemptsLeft - 1)
                    }
                    return
                }
                self.supportedUTIs = utis.union(Self.supplement)
                self.ready = true
            }
        }
    }

}
