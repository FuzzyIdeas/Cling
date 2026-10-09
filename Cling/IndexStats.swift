import Lowtech
import SwiftUI
import System

// MARK: - IndexWalks

/// When each index was last walked in full and how long the walk took. The index files can't tell: live changes save
/// them again every few minutes.
struct IndexWalks: Codable {
    enum Key {
        case scope(SearchScope)
        case volume(FilePath)
        case everything

        var string: String {
            switch self {
            case let .scope(scope): "scope:\(scope.rawValue)"
            case let .volume(volume): "volume:\(volume.string)"
            case .everything: "everything"
            }
        }
    }

    struct Walk: Codable {
        let finished: Date
        let seconds: Double
    }

    static let file = indexFolder / "index-walks.json"

    var walks: [String: Walk] = [:]

    static func read() -> Self {
        guard let data = try? Data(contentsOf: file.url), let state = try? JSONDecoder().decode(Self.self, from: data) else {
            return Self()
        }
        return state
    }

    /// On the main actor, so two walks that end together can't write over each other.
    @MainActor static func record(_ key: Key, started: Date) {
        var state = read()
        state.walks[key.string] = Walk(finished: Date(), seconds: Date().timeIntervalSince(started))
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: file.url, options: .atomic)
    }

    subscript(_ key: Key) -> Walk? {
        walks[key.string]
    }
}

// MARK: - IndexStats

/// Each index's files, size on disk, memory and last full walk, for the bottom of the index browser.
struct IndexStats {
    struct Item: Identifiable {
        let id: String
        let name: String
        /// Nil while the index isn't loaded.
        let files: Int?
        let diskBytes: Int
        /// Nil while the index isn't loaded.
        let memoryBytes: Int?
        let walk: IndexWalks.Walk?
    }

    var scopes: [Item] = []
    var drives: [Item] = []
    var everything: Item?
    /// The file extension table all the engines share, which none of them counts.
    var extensionTableBytes = 0

    var all: [Item] {
        scopes + drives + (everything.map { [$0] } ?? [])
    }

    var diskBytes: Int {
        Self.sum(all) { $0.diskBytes }
    }

    var memoryBytes: Int {
        Self.sum(all) { $0.memoryBytes } + extensionTableBytes
    }

    static func sum(_ items: [Item], _ value: (Item) -> Int?) -> Int {
        items.reduce(0) { $0 + (value($1) ?? 0) }
    }

    /// Always a decimal point, whatever the region uses, and numeric at zero ("0 KB", not "Zero kB"), which an index
    /// that only reads its file often is.
    static func size(_ bytes: Int, base: Double) -> String {
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(bytes) / base
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= base
            unit += 1
        }
        let decimals = [0, 1, 2, 2][unit]
        return String(format: "%.\(decimals)f %@", value, units[unit])
    }

    /// A size on disk, the way the index browser and Settings show it.
    static func diskSize(_ bytes: Int) -> String {
        size(bytes, base: 1000)
    }

    static func memorySize(_ bytes: Int) -> String {
        size(bytes, base: 1024)
    }

    /// Takes the engines on the main actor and measures them off it: checking their pages holds each engine's lock
    /// for a system call per column.
    @MainActor static func gather() async -> IndexStats {
        typealias Source = (id: String, name: String, file: FilePath, engine: SearchEngine?, key: IndexWalks.Key)
        let scopes: [Source] = SearchScope.allCases.compactMap { scope in
            let engine = FUZZY.scopeEngines[scope]
            let file = scopeIndexFile(scope)
            guard engine != nil || file.exists else { return nil }
            return ("scope:\(scope.rawValue)", scope.label, file, engine, .scope(scope))
        }
        let drives: [Source] = FUZZY.enabledVolumes.compactMap { volume in
            let engine = FUZZY.volumeEngines[volume]
            let file = volumeIndexFile(volume)
            guard engine != nil || file.exists else { return nil }
            return ("volume:\(volume.string)", volume.name.string, file, engine, .volume(volume))
        }
        let everythingFile = EverythingIndex.indexFile
        let everything: Source? = EVERYTHING.engine != nil || everythingFile.exists
            ? ("everything", "Everything", everythingFile, EVERYTHING.engine, .everything)
            : nil

        return await Task.detached(priority: .utility) {
            let walks = IndexWalks.read()
            let sizes = IndexSizes.measure()
            func item(_ source: Source) -> Item {
                Item(
                    id: source.id, name: source.name, files: source.engine?.count, diskBytes: sizes[source.file.string] ?? 0,
                    memoryBytes: source.engine?.footprintBytes, walk: walks[source.key]
                )
            }
            return IndexStats(
                scopes: scopes.map(item), drives: drives.map(item), everything: everything.map(item),
                extensionTableBytes: SearchEngine.extensionTableBytes
            )
        }.value
    }
}

// MARK: - IndexStatsView

/// The index browser's footer: scopes and drives with their subtotals, then Everything.
struct IndexStatsView: View {
    let stats: IndexStats?
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded, let stats {
                grid(stats)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
        }
    }

    /// Height of the grid below the header, for deciding whether the window has room for it.
    static func gridHeight(_ stats: IndexStats) -> CGFloat {
        let groups = (stats.scopes.isEmpty ? 0 : 1) + (stats.drives.isEmpty ? 0 : 1)
        let lines = 1 + groups + stats.all.count + (stats.extensionTableBytes > 0 ? 1 : 0)
        return CGFloat(lines) * (FontScale.length(15) + 3) + 8
    }

    private var header: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text("Index stats")
                    .font(.scaled(11, .chrome, weight: .medium))
                Spacer()
                if let stats {
                    Text("\(disk(stats.diskBytes)) on disk · \(memory(stats.memoryBytes)) in memory")
                        .font(.scaled(10, .chrome).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func grid(_ stats: IndexStats) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
            GridRow {
                Text("Index")
                Text("Files").gridColumnAlignment(.trailing)
                Text("On disk").gridColumnAlignment(.trailing)
                Text("In memory").gridColumnAlignment(.trailing)
                Text("Last full index")
            }
            .font(.scaled(10, .chrome, weight: .medium))
            .foregroundStyle(.secondary)

            if !stats.scopes.isEmpty {
                group("Scopes", stats.scopes)
            }
            if !stats.drives.isEmpty {
                group("Drives", stats.drives)
            }
            if let everything = stats.everything {
                row(everything, indented: false)
            }
            if stats.extensionTableBytes > 0 {
                GridRow {
                    Text("Extension table")
                        .help("File extensions all the indexes share, kept once for all of them")
                    Text("")
                    Text("")
                    Text(memory(stats.extensionTableBytes))
                    Text("")
                }
            }
        }
        .font(.scaled(11).monospacedDigit())
    }

    @ViewBuilder
    private func group(_ name: String, _ items: [IndexStats.Item]) -> some View {
        GridRow {
            Text(name)
            Text(IndexStats.sum(items) { $0.files }.spaced)
            Text(disk(IndexStats.sum(items) { $0.diskBytes }))
            Text(memory(IndexStats.sum(items) { $0.memoryBytes }))
            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
        }
        .fontWeight(.medium)
        ForEach(items) { row($0, indented: true) }
    }

    private func row(_ item: IndexStats.Item, indented: Bool) -> some View {
        GridRow {
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, indented ? 14 : 0)
            Text(item.files?.spaced ?? "")
            Text(disk(item.diskBytes))
            if let bytes = item.memoryBytes {
                Text(memory(bytes))
            } else {
                Text("not loaded").foregroundStyle(.secondary)
            }
            lastWalk(item.walk)
        }
    }

    @ViewBuilder
    private func lastWalk(_ walk: IndexWalks.Walk?) -> some View {
        if let walk {
            let took = Duration.seconds(walk.seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
            Text("\(walk.finished.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))) · \(took)")
                .help("\(walk.finished.formatted(date: .abbreviated, time: .shortened)), took \(took)")
        } else {
            Text("")
        }
    }

    private func disk(_ bytes: Int) -> String {
        IndexStats.diskSize(bytes)
    }

    private func memory(_ bytes: Int) -> String {
        IndexStats.memorySize(bytes)
    }

}

// MARK: - IndexSizes

/// What each saved index takes on disk, for the rows in Settings and the CLI's lists. Measured off the main thread, at
/// first use and again whenever a file in the index folder is written or removed: every save renames its finished file
/// into place, which the folder reports. Everything's own folder isn't watched, so it asks for a measure after it
/// saves or deletes.
@MainActor @Observable
final class IndexSizes {
    private init() {
        refresh()
    }

    static let shared = IndexSizes()

    /// Bytes by index file path, for the files that exist.
    private(set) var bytes: [String: Int] = [:]

    var everything: Int? {
        saved(EverythingIndex.indexFile)
    }

    /// Every `.idx` file in the index folder and in Everything's, by path. Reads the disk: never on the main thread.
    nonisolated static func measure() -> [String: Int] {
        var sizes: [String: Int] = [:]
        for folder in [indexFolder, EverythingIndex.indexFile.removingLastComponent()] {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.string)) ?? [] where name.hasSuffix(".idx") {
                let file = folder / name
                if let size = (try? FileManager.default.attributesOfItem(atPath: file.string))?[.size] as? Int {
                    sizes[file.string] = size
                }
            }
        }
        return sizes
    }

    func scope(_ scope: SearchScope) -> Int? {
        saved(scopeIndexFile(scope))
    }

    func volume(_ volume: FilePath) -> Int? {
        saved(volumeIndexFile(volume))
    }

    /// Measures again soon, once for a burst of asks: a save writes and renames, a walk of several scopes saves each.
    func refresh() {
        guard !measuring else {
            measureAgain = true
            return
        }
        measuring = true
        let watching = watcher != nil
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(300))
            let source = watching ? nil : Self.watchIndexFolder()
            let measured = Self.measure()
            await MainActor.run {
                if let source {
                    self.watcher = source
                }
                self.update(measured)
                self.measuring = false
                if self.measureAgain {
                    self.measureAgain = false
                    self.refresh()
                }
            }
        }
    }

    /// Takes sizes measured elsewhere off the main thread, as the CLI does before it answers.
    func update(_ measured: [String: Int]) {
        if measured != bytes {
            bytes = measured
        }
    }

    /// Takes a deleted index out at once, before the folder reports it.
    func forget(_ file: FilePath) {
        bytes[file.string] = nil
    }

    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var measuring = false
    @ObservationIgnored private var measureAgain = false

    /// nil while the index folder doesn't exist yet; the next measure tries again.
    private nonisolated static func watchIndexFolder() -> DispatchSourceFileSystemObject? {
        let fd = open(indexFolder.string, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: .global(qos: .utility))
        source.setEventHandler {
            Task { @MainActor in INDEX_SIZES.refresh() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    /// No size for an index with no file, or an empty one.
    private func saved(_ file: FilePath) -> Int? {
        bytes[file.string].flatMap { $0 > 0 ? $0 : nil }
    }
}

@MainActor let INDEX_SIZES = IndexSizes.shared

// MARK: - IndexSizeText

/// An index's size on disk, as a value at the end of its row. Nothing while it has no saved file.
struct IndexSizeText: View {
    let bytes: Int?

    var body: some View {
        if let bytes {
            Text(IndexStats.diskSize(bytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
