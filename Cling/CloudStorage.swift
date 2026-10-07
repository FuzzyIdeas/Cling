import AppKit
import Defaults
import Lowtech
import QuickLookThumbnailing
import SwiftUI
import System

// MARK: - CloudLocation

/// A folder a cloud service keeps in sync through macOS: iCloud Drive, or anything in `~/Library/CloudStorage`
/// (Dropbox, Google Drive, OneDrive, Box…). Files there can be online only: they are on disk with their names, sizes
/// and dates but no contents, and reading them in any way downloads them first.
struct CloudLocation: Hashable, Identifiable, Sendable {
    let root: FilePath
    /// The service, as its app calls itself.
    let name: String
    /// What tells two accounts of the same service apart (`alex@example.com`, `Personal`), from the folder's name.
    let account: String?
    /// The service's app, for its icon.
    let appPath: String?

    var id: String {
        root.string
    }

    /// The name and account, the way the CLI and the activity log show a location.
    var label: String {
        account.map { "\(name) \($0)" } ?? name
    }

    @MainActor var icon: NSImage {
        if let appPath {
            return NSWorkspace.shared.icon(forFile: appPath)
        }
        // iCloud Drive's own folder has the iCloud icon.
        return NSWorkspace.shared.icon(forFile: (root / "com~apple~CloudDocs").string)
    }
}

// MARK: - CloudStorage

enum CloudStorage {
    static let folder = HOME / "Library" / "CloudStorage"
    static let iCloudRoot = HOME / "Library" / "Mobile Documents"

    /// The cloud folder a path is in, as the cloud scope's root for it. A folder in CloudStorage that no service has
    /// registered any more is not one: it stays in Library.
    static func root(containing path: String) -> String? {
        if path == iCloudRoot.string || path.hasPrefix(iCloudRoot.string + "/") {
            return iCloudRoot.string
        }
        guard path.hasPrefix(folder.string + "/") else { return nil }
        let name = path.dropFirst(folder.string.count + 1).prefix { $0 != "/" }
        let root = folder.string + "/" + name
        return name.isEmpty || xattr(root, domainAttribute) == nil ? nil : root
    }

    /// The cloud folders on this Mac. One in CloudStorage counts only while its service still has it registered
    /// (macOS marks it with the File Provider domain it belongs to): a folder left behind by a removed account
    /// is just a folder.
    static func locations() -> [CloudLocation] {
        var found: [CloudLocation] = []
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.string)) ?? []
        for name in names.sorted() where !name.hasPrefix(".") {
            let root = folder / name
            guard root.isDir, let domain = xattr(root.string, domainAttribute) else { continue }
            let app = providerApp(domain)
            // `GoogleDrive-alex@example.com`, `OneDrive-Personal`, `Dropbox`: the service, then the account.
            let dash = name.firstIndex(of: "-")
            let folderService = dash.map { String(name[..<$0]) } ?? name
            let account = dash.map { String(name[name.index(after: $0)...]) }.flatMap { $0.isEmpty ? nil : $0 }
            let appName = app.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            found.append(CloudLocation(root: root, name: appName ?? folderService, account: account, appPath: app?.path))
        }
        if iCloudRoot.exists {
            found.insert(CloudLocation(root: iCloudRoot, name: "iCloud Drive", account: nil, appPath: nil), at: 0)
        }
        return found
    }

    /// The app behind a File Provider domain, from the domain's ID: `com.getdropbox.dropbox.fileprovider/<uuid>` is
    /// the extension's bundle ID, which starts with its app's (`com.getdropbox.dropbox`).
    static func providerApp(_ domainID: String) -> URL? {
        var parts = (domainID.split(separator: "/").first ?? "").split(separator: ".").map(String.init)
        while parts.count >= 2 {
            if var url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: parts.joined(separator: ".")) {
                // The extension itself can answer: its app is the bundle it sits in.
                while url.pathExtension != "app", url.pathComponents.count > 1 {
                    url.deleteLastPathComponent()
                }
                if url.pathExtension == "app" {
                    return url
                }
            }
            parts.removeLast()
        }
        return nil
    }

    private static let domainAttribute = "com.apple.file-provider-domain-id"

    private static func xattr(_ path: String, _ name: String) -> String? {
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard getxattr(path, name, &buffer, size, 0, 0) == size else { return nil }
        return String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .controlCharacters)
    }
}

extension FilePath {
    /// A file a cloud service keeps online only: anything that reads it, a preview included, downloads it first.
    /// A package counts as a file. Other folders never do: listing one only fetches the names inside it.
    var isOnlineOnly: Bool {
        isOnlineOnlyFile(string)
    }
}

/// Out here because inside a `FilePath` extension `stat` is FilePath's own.
private func isOnlineOnlyFile(_ path: String) -> Bool {
    var st = stat()
    guard stat(path, &st) == 0, st.st_flags & UInt32(SF_DATALESS) != 0 else { return false }
    return st.st_mode & S_IFMT != S_IFDIR || CloudDownloads.isOnlinePackage(path)
}

// MARK: - CloudDownload

/// Downloads one online-only file on request and follows its progress. Kept per path, so moving the selection away
/// and back shows a download that is still going.
@MainActor @Observable
final class CloudDownload {
    init(path: FilePath) {
        self.path = path
    }

    enum Phase: Equatable {
        case idle
        case downloading
        case failed(String)
    }

    let path: FilePath
    var phase: Phase = .idle
    var fraction: Double = 0
    /// Turns true once the file is on disk.
    var finished = false

    /// The download under way (or failed) for this file, or a new one that is kept once it starts.
    static func of(_ path: FilePath) -> CloudDownload {
        active[path.string] ?? CloudDownload(path: path)
    }

    func start() {
        guard phase != .downloading else { return }
        follow()
        let url = url
        Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.startDownloadingUbiquitousItem(at: url)
            } catch {
                await MainActor.run { self.fail(error.localizedDescription) }
            }
        }
    }

    /// Picks up a download started elsewhere (Finder, or this file's preview before the selection moved on).
    func followIfDownloading() {
        guard phase == .idle else { return }
        let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.ubiquitousItemIsDownloadingKey])
        if values?.ubiquitousItemIsDownloading == true {
            follow()
        }
    }

    private static var active: [String: CloudDownload] = [:]

    @ObservationIgnored private var subscriber: Any?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var poll: Task<Void, Never>?

    /// The file itself rather than a Home folder link to it: macOS publishes the download's progress under the
    /// real path.
    private var url: URL {
        path.url.resolvingSymlinksInPath()
    }

    private func follow() {
        Self.active[path.string] = self
        phase = .downloading
        fraction = 0
        if subscriber == nil {
            subscriber = Progress.addSubscriber(forFileURL: url) { [weak self] progress in
                let observation = progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in
                        guard let self else { return }
                        self.fraction = max(self.fraction, fraction)
                    }
                }
                Task { @MainActor in self?.observation = observation }
                return {
                    Task { @MainActor in self?.observation = nil }
                }
            }
        }
        // The progress reaches 1 a moment before the file is swapped in, so done is when it stops being online only.
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard let self else { return }
                if !path.isOnlineOnly {
                    finish()
                    return
                }
                let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.ubiquitousItemDownloadingErrorKey])
                if let error = values?.ubiquitousItemDownloadingError {
                    fail(error.localizedDescription)
                    return
                }
            }
        }
    }

    private func finish() {
        stopFollowing()
        fraction = 1
        phase = .idle
        finished = true
        Self.active[path.string] = nil
    }

    private func fail(_ message: String) {
        stopFollowing()
        phase = .failed(message)
    }

    private func stopFollowing() {
        poll?.cancel()
        poll = nil
        if let subscriber {
            Progress.removeSubscriber(subscriber)
        }
        subscriber = nil
        observation = nil
    }
}

// MARK: - CloudThumbnails

/// The thumbnail a cloud service keeps for an online-only file. Quick Look asks the service for it, so the file
/// itself is not downloaded.
@MainActor
enum CloudThumbnails {
    static func thumbnail(for path: FilePath) async -> NSImage? {
        if let hit = cache[path.string] {
            return hit
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: path.url.resolvingSymlinksInPath(), size: CGSize(width: 600, height: 600),
            scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: [.lowQualityThumbnail, .thumbnail]
        )
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        let image = representation.nsImage
        cache[path.string] = image
        order.append(path.string)
        if order.count > 32 {
            cache[order.removeFirst()] = nil
        }
        return image
    }

    private static var cache: [String: NSImage] = [:]
    private static var order: [String] = []
}

// MARK: - CloudFilePreview

/// What the preview shows for an online-only file: the service's thumbnail, or the file's icon, with a button that
/// downloads it. Nothing reads the file until the button is pressed, so selecting results never downloads them.
struct CloudFilePreview: View {
    let path: FilePath
    /// Called once the file is on disk, for the real preview to take over.
    var downloaded: () -> Void

    var body: some View {
        ZStack {
            picture
            VStack(spacing: 10) {
                button
                if case let .failed(message) = download.phase {
                    VStack(spacing: 2) {
                        Text("Couldn't download")
                            .font(.scaled(12, .secondary, weight: .medium))
                        Text(message)
                            .font(.scaled(10, .secondary))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassOrMaterial(cornerRadius: 10)
                    .frame(maxWidth: 260)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: path.string) {
            thumbnail = nil
            download = CloudDownload.of(path)
            download.followIfDownloading()
            thumbnail = await CloudThumbnails.thumbnail(for: path)
        }
        .onChange(of: download.finished) { _, finished in
            if finished {
                downloaded()
            }
        }
    }

    @State private var thumbnail: NSImage?
    @State private var download = CloudDownload(path: FilePath("/"))
    @State private var hovering = false

    @ViewBuilder
    private var picture: some View {
        if let thumbnail {
            // A service's thumbnail can be small; past twice its size it only gets blurrier.
            Image(nsImage: thumbnail)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: thumbnail.size.width * 2, maxHeight: thumbnail.size.height * 2)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                .padding(24)
        } else {
            Image(nsImage: path.memoz.icon)
                .resizable()
                .scaledToFit()
                .frame(width: 128, height: 128)
        }
    }

    private var button: some View {
        let downloading = download.phase == .downloading
        return Button {
            download.start()
        } label: {
            ZStack {
                if downloading {
                    Circle()
                        .stroke(.secondary.opacity(0.25), lineWidth: 3)
                        .padding(4)
                    Circle()
                        .trim(from: 0, to: max(download.fraction, 0.03))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(4)
                        .animation(.easeOut(duration: 0.25), value: download.fraction)
                }
                Image(systemName: downloading ? "arrow.down" : "icloud.and.arrow.down")
                    .font(.system(size: downloading ? 16 : 22, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .frame(width: 56, height: 56)
            .glassOrMaterial(cornerRadius: 28)
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
            .scaleEffect(hovering && !downloading ? 1.06 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(downloading)
        .onHover { hovering = $0 }
        .help("Download")
        .accessibilityLabel("Download")
    }
}

// MARK: - Listing cloud folders

extension FuzzyClient {
    /// Cloud folders turned off in Settings.
    var disabledCloudRoots: Set<String> {
        Set(Defaults[.disabledCloudLocations].map(\.string))
    }

    /// The cloud scope's roots: the cloud folders on this Mac that are turned on.
    var cloudRoots: [String] {
        let disabled = disabledCloudRoots
        return cloudLocations.map(\.root.string).filter { !disabled.contains($0) }
    }

    /// Looks for cloud folders again: an account added or removed since. `thenList` lists their online-only folders
    /// once the new list is in.
    func refreshCloudLocations(thenList: Bool = false) {
        Task.detached(priority: .utility) {
            let locations = CloudStorage.locations()
            await MainActor.run {
                if locations != self.cloudLocations {
                    // An account added since: Library may have its folder from before it was registered.
                    let known = Set(self.cloudLocations.map(\.root.string))
                    let added = locations.map(\.root.string).filter { !known.contains($0) }
                    if !added.isEmpty {
                        self.scopeEngines[.library]?.removeSubtrees(added)
                    }
                    self.cloudLocations = locations
                    self.applyCloudRoots()
                    self.refreshLiveRoutes()
                    EVERYTHING.cloudFoldersChanged()
                }
                if thenList {
                    self.listCloudFolders()
                }
            }
        }
    }

    /// Lists the online-only folders of every cloud folder that is turned on, so the files inside them are found
    /// before anyone opens those folders in Finder. Listing fetches names, never contents, but it goes over the
    /// network and a large account can take minutes, so it runs on its own after the Library walk, which leaves
    /// such folders empty rather than waiting on them (see `CloudDownloads`).
    func listCloudFolders(_ only: [CloudLocation]? = nil) {
        // A walk of the scope under way replaces the engine; it lists the cloud folders again when it is done.
        guard searchableScopes.contains(.cloud), !scopesIndexing.contains(.cloud) else { return }
        let disabled = disabledCloudRoots
        let locations = (only ?? cloudLocations).filter { !disabled.contains($0.root.string) && cloudListTasks[$0.root.string] == nil }
        for location in locations {
            let root = location.root.string
            guard let walk = pathWalk(for: root) else { continue }
            let engine = walk.engine
            cloudListing[root] = 0
            let opKey = "cloud:\(root)"
            cloudListTasks[root] = Task.detached(priority: .utility) { [self] in
                _ = engine.addPathIfMissing(root, isDir: true)
                let before = engine.count
                let walked = engine.walkDirectory(
                    root, ignoreFile: walk.ignoreFile, ignoreRoot: walk.ignoreRoot, skipDir: walk.skipDir,
                    applyBlocklist: walk.applyBlocklist, listOnlineFolders: true,
                    progress: { count, _ in
                        Task { @MainActor in
                            guard self.cloudListing[root] != nil else { return }
                            self.cloudListing[root] = count
                            self.logActivity("Listing \(location.label): \(count.formatted()) files", ongoing: true, operationKey: opKey, count: count)
                        }
                    },
                    cancelled: { Task.isCancelled }
                )
                let cancelled = Task.isCancelled
                // The walk adds only what is new, so the engine grows when the service listed folders it had not yet.
                let listedNew = engine.count > before
                await MainActor.run {
                    self.cloudListTasks[root] = nil
                    self.cloudListing[root] = nil
                    if listedNew {
                        EVERYTHING.cloudFolderListed(root)
                    }
                    guard !cancelled else { return }
                    self.logActivity("Listed \(location.label): \(walked.formatted()) files", operationKey: opKey)
                    self.updateIndexedCount()
                    self.invalidateSearch()
                    self.performSearch()
                    self.scheduleSaveIndexes()
                }
            }
        }
    }

    func cancelCloudListing(_ roots: Set<String>? = nil) {
        for (root, task) in cloudListTasks where roots?.contains(root) ?? true {
            task.cancel()
            cloudListTasks[root] = nil
            cloudListing[root] = nil
        }
    }

    /// Brings the cloud scope in line with its roots after a folder is turned on or off, or an account comes or goes.
    /// One that went leaves the index straight away; a new one is walked and listed. The first folder turned on loads
    /// or walks the scope and the last one turned off unloads it, the way a scope toggle does.
    func applyCloudRoots() {
        let now = Set(cloudRoots)
        let gone = appliedCloudRoots.subtracting(now)
        let new = now.subtracting(appliedCloudRoots)
        guard !gone.isEmpty || !new.isEmpty else { return }
        appliedCloudRoots = now

        cancelCloudListing(gone)
        if let engine = scopeEngines[.cloud], !now.isEmpty {
            if !gone.isEmpty {
                engine.removeSubtrees(Array(gone))
            }
            // The engine now matches the new roots, or will once the listing below has walked them.
            if liveBase[.cloud] != nil {
                liveRules[.cloud] = rulesFingerprint(.cloud)
            }
            listCloudFolders(cloudLocations.filter { new.contains($0.root.string) })
        }
        syncScopeEngines()
        refreshLiveRoutes()
        updateIndexedCount()
        invalidateSearch()
        performSearch()
        scheduleSaveIndexes()
    }
}
