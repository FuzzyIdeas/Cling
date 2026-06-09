import AppKit
import Defaults
import Foundation
import Ignore
import Lowtech
import OSLog
import SwiftUI
import System

private let log = Logger(subsystem: clingSubsystem, category: "MissingPathIndex")

// MARK: - IndexInclusionPlan

/// Concrete set of changes to force a path back into the index. Consumed by `FuzzyClient.includeInIndex`.
struct IndexInclusionPlan {
    var addBlockedPrefixes: [String] = []  // `!` exception lines for the prefix blocklist
    var addBlockedContains: [String] = []  // `!` exception lines for the contains blocklist
    var removeBlockedPrefixes: [String] = []
    var removeBlockedContains: [String] = []
    var addHomeFsignoreLines: [String] = []
    var volumeFsignoreLines: [FilePath: [String]] = [:]
    var reindexScopes: Set<SearchScope> = []
    var reindexVolumes: Set<FilePath> = []
    var fullReindex = false

    var isEmpty: Bool {
        addBlockedPrefixes.isEmpty && addBlockedContains.isEmpty &&
            removeBlockedPrefixes.isEmpty && removeBlockedContains.isEmpty &&
            addHomeFsignoreLines.isEmpty && volumeFsignoreLines.allSatisfy { $0.value.isEmpty }
    }
}

// MARK: - IgnoreSource

/// Where an exclusion rule lives. Blocklist rules are byte-matched and prune directories before fsignore
/// negation can act, so they're undone with a blocklist `!` exception (not an fsignore `!` rule).
enum IgnoreSource: Equatable, Hashable {
    case blocklistPrefix
    case blocklistContains
    case homeIgnore
    case volumeIgnore(root: String, name: String)

    var label: String {
        switch self {
        case .blocklistPrefix: "Global blocklist (prefix)"
        case .blocklistContains: "Global blocklist (contains)"
        case .homeIgnore: "Home ignore file (~/.fsignore)"
        case let .volumeIgnore(_, name): "Volume ignore file (\(name)/.fsignore)"
        }
    }

    var isBlocklist: Bool {
        switch self {
        case .blocklistPrefix, .blocklistContains: true
        case .homeIgnore, .volumeIgnore: false
        }
    }
}

// MARK: - IgnoreHit

struct IgnoreHit: Identifiable, Equatable {
    let id = UUID()
    let source: IgnoreSource
    let rule: String

    static func == (lhs: IgnoreHit, rhs: IgnoreHit) -> Bool {
        lhs.source == rhs.source && lhs.rule == rhs.rule
    }
}

// MARK: - RootContext

/// The fsignore root that governs a path (HOME for home/library scopes, or a volume root), plus the
/// path expressed relative to that root (what gitignore patterns are anchored against).
struct RootContext: Equatable {
    enum Kind: Equatable {
        case home
        case volume(FilePath)
    }

    let kind: Kind
    let rootPath: String
    let rel: String

    var isHome: Bool { if case .home = kind { return true }; return false }
}

// MARK: - PathStatus

enum PathStatus: Equatable {
    case notFound
    case excluded([IgnoreHit])
    case notInAnyScope
    case alreadyIndexable
}

// MARK: - InclusionOption

enum Breadth: Int, Comparable {
    case exact = 0
    case pattern = 1
    case folder = 2
    case broad = 3

    static func < (lhs: Breadth, rhs: Breadth) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Reindex scope after applying a plan, precomputed from the path during diagnosis.
enum ReindexTarget: Equatable {
    case scopes([SearchScope])
    case volume(FilePath)
    case full
}

/// One user-selectable way to re-include the path. May add blocklist `!` exceptions (preferred, keeps the
/// fast byte-matched rule in place), remove a blocklist rule outright (broad fallback), and/or add fsignore
/// `!` lines (for paths also excluded by an ignore file).
struct InclusionOption: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let summary: String
    let breadth: Breadth
    var addBlocklistPrefixes: [String] = []   // `!`-prefixed exception lines
    var addBlocklistContains: [String] = []   // `!`-prefixed exception lines
    var removeBlocklist: [IgnoreHit] = []
    var reExcludeFsignore: [String] = []
    var reIncludeFsignore: [String] = []
    var fsignoreRoot: FilePath? // nil = home, otherwise the volume root

    /// Lines, in apply order: re-exclusions first, then `!` re-inclusions (so negation wins as the last match).
    var fsignoreLines: [String] { reExcludeFsignore + reIncludeFsignore }

    static func == (lhs: InclusionOption, rhs: InclusionOption) -> Bool { lhs.id == rhs.id }

    /// Signature used to dedupe options that would produce identical changes.
    var signature: String {
        let add = (addBlocklistPrefixes + addBlocklistContains).sorted().joined(separator: ",")
        let rm = removeBlocklist.map(\.rule).sorted().joined(separator: ",")
        return "\(add)|\(rm)|\(fsignoreRoot?.string ?? "home")|\(fsignoreLines.joined(separator: ","))"
    }
}

// MARK: - PathDiagnosis

struct PathDiagnosis {
    let path: String
    let isDir: Bool
    let status: PathStatus
    let rootContext: RootContext?
    let reindex: ReindexTarget
    let options: [InclusionOption]

    var hits: [IgnoreHit] {
        if case let .excluded(hits) = status { return hits }
        return []
    }

    /// Turn a chosen option into a concrete plan plus the right reindex target.
    func plan(for option: InclusionOption) -> IndexInclusionPlan {
        var plan = IndexInclusionPlan()
        plan.addBlockedPrefixes = option.addBlocklistPrefixes
        plan.addBlockedContains = option.addBlocklistContains
        for hit in option.removeBlocklist {
            switch hit.source {
            case .blocklistPrefix: plan.removeBlockedPrefixes.append(hit.rule)
            case .blocklistContains: plan.removeBlockedContains.append(hit.rule)
            default: break
            }
        }
        if let root = option.fsignoreRoot {
            plan.volumeFsignoreLines[root, default: []].append(contentsOf: option.fsignoreLines)
        } else {
            plan.addHomeFsignoreLines.append(contentsOf: option.fsignoreLines)
        }

        switch reindex {
        case let .scopes(scopes): plan.reindexScopes = Set(scopes)
        case let .volume(v): plan.reindexVolumes = [v]
        case .full: plan.fullReindex = true
        }
        return plan
    }
}

// MARK: - IndexSnapshot

/// Immutable snapshot of the exclusion configuration, captured on the main actor so analysis can run off-main.
struct IndexSnapshot {
    let home: String
    let blockedPrefixes: [String]
    let blockedContains: [String]
    let homeFsignore: String?
    let volumes: [(root: String, name: String, fsignore: String?)]

    @MainActor
    static func capture() -> IndexSnapshot {
        let homeStr = HOME.string
        let prefixes = nonCommentLines(Defaults[.blockedPrefixes])
        let contains = nonCommentLines(Defaults[.blockedContains])
        let homeIgnore = try? String(contentsOf: fsignore.url, encoding: .utf8)
        let vols = FUZZY.enabledVolumes.map { vol -> (root: String, name: String, fsignore: String?) in
            let content = try? String(contentsOf: (vol / ".fsignore").url, encoding: .utf8)
            return (root: vol.string, name: vol.name.string, fsignore: content)
        }
        return IndexSnapshot(home: homeStr, blockedPrefixes: prefixes, blockedContains: contains, homeFsignore: homeIgnore, volumes: vols)
    }

    static func nonCommentLines(_ s: String) -> [String] {
        s.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}

// MARK: - IndexInclusionAnalyzer

enum IndexInclusionAnalyzer {
    /// Analyze whether `rawPath` is excluded from the index, by which rules, and how to force it back in.
    nonisolated static func diagnose(rawPath: String, snapshot: IndexSnapshot) -> PathDiagnosis {
        let path = normalize(rawPath)
        guard !path.isEmpty else {
            return PathDiagnosis(path: rawPath, isDir: false, status: .notFound, rootContext: nil, reindex: .full, options: [])
        }

        var isDirObjC: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirObjC)
        let isDir = isDirObjC.boolValue
        guard exists else {
            return PathDiagnosis(path: path, isDir: false, status: .notFound, rootContext: nil, reindex: .full, options: [])
        }

        let root = rootContext(for: path, snapshot: snapshot)
        let scopes = scopesForPath(path, home: snapshot.home)
        let onVolume: FilePath? = { if case let .volume(v) = root?.kind { return v }; return nil }()
        let reindex: ReindexTarget = onVolume.map { .volume($0) } ?? (scopes.isEmpty ? .full : .scopes(scopes))

        // 1. Blocklist hits (byte matching, no root needed). `!`-prefixed lines are exceptions: if one
        // matches, the path is allowed through despite any block rule, so report no blocklist hits.
        var blocklistHits: [IgnoreHit] = []
        let exception = { (line: String) in String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
        let allowPrefixes = snapshot.blockedPrefixes.filter { $0.hasPrefix("!") }.map(exception)
        let allowContains = snapshot.blockedContains.filter { $0.hasPrefix("!") }.map(exception)
        // Most-specific (longest) matching rule wins, so only report a block rule that out-specifies every
        // matching allow exception (mirrors isPathBlocked).
        let maxAllow = max(
            allowPrefixes.filter { path.hasPrefix($0) }.map(\.count).max() ?? 0,
            allowContains.filter { containsMatches(path: path, component: $0) }.map(\.count).max() ?? 0
        )
        for prefix in snapshot.blockedPrefixes where !prefix.hasPrefix("!") && prefix.count > maxAllow && prefixMatches(path: path, prefix: prefix) {
            blocklistHits.append(IgnoreHit(source: .blocklistPrefix, rule: prefix))
        }
        for comp in snapshot.blockedContains where !comp.hasPrefix("!") && comp.count > maxAllow && containsMatches(path: path, component: comp) {
            blocklistHits.append(IgnoreHit(source: .blocklistContains, rule: comp))
        }

        // 2. fsignore hits (gitignore semantics, anchored at root)
        var fsignoreHits: [IgnoreHit] = []
        if let root {
            bust_gitignore_cache()
            let content: String?
            let source: IgnoreSource
            switch root.kind {
            case .home:
                content = snapshot.homeFsignore
                source = .homeIgnore
            case let .volume(v):
                let entry = snapshot.volumes.first { $0.root == v.string }
                content = entry?.fsignore
                source = .volumeIgnore(root: v.string, name: v.name.string)
            }
            if let content, !content.isEmpty, isIgnoredAtRoot(rel: root.rel, content: content) {
                for line in fsignoreRuleLines(content) where isIgnoredAtRoot(rel: root.rel, content: line) {
                    fsignoreHits.append(IgnoreHit(source: source, rule: line))
                }
                // If the net result is ignored but no single positive rule matched alone, surface a generic hit.
                if fsignoreHits.isEmpty {
                    fsignoreHits.append(IgnoreHit(source: source, rule: "(combination of rules)"))
                }
            }
        }

        let allHits = blocklistHits + fsignoreHits
        guard !allHits.isEmpty else {
            // Not excluded by any rule. Either it's outside every indexed location, or it should already be indexed.
            let status: PathStatus = (scopes.isEmpty && onVolume == nil) ? .notInAnyScope : .alreadyIndexable
            return PathDiagnosis(path: path, isDir: isDir, status: status, rootContext: root, reindex: reindex, options: [])
        }

        let isBundle = isDir && ((try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false)
        let options = buildOptions(
            path: path, isDir: isDir, isBundle: isBundle, root: root,
            blocklistHits: blocklistHits, fsignoreHits: fsignoreHits
        )
        return PathDiagnosis(path: path, isDir: isDir, status: .excluded(allHits), rootContext: root, reindex: reindex, options: options)
    }

    /// Which enabled scope(s) would index `path` (used to scope the reindex after applying a plan).
    nonisolated static func scopesForPath(_ path: String, home: String) -> [SearchScope] {
        let lib = home + "/Library"
        if path == lib || path.hasPrefix(lib + "/") { return [.library] }
        if path == home || path.hasPrefix(home + "/") { return [.home] }
        if path == "/Applications" || path.hasPrefix("/Applications/")
            || path == "/System/Applications" || path.hasPrefix("/System/Applications/") { return [.applications] }
        if path == "/System" || (path.hasPrefix("/System/") && !path.hasPrefix("/System/Volumes/")) { return [.system] }
        for r in ["/usr", "/bin", "/sbin", "/opt", "/etc", "/Library", "/var", "/private"] {
            if path == r || path.hasPrefix(r + "/") { return [.root] }
        }
        return []
    }

    // MARK: Path helpers

    nonisolated static func normalize(_ raw: String) -> String {
        var p = raw.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return "" }
        p = (p as NSString).expandingTildeInPath
        // Clean ./.. without resolving symlinks (the index stores raw paths).
        p = URL(fileURLWithPath: p).standardizedFileURL.path
        if p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    nonisolated static func rootContext(for path: String, snapshot: IndexSnapshot) -> RootContext? {
        let home = snapshot.home
        if path == home || path.hasPrefix(home + "/") {
            return RootContext(kind: .home, rootPath: home, rel: relativize(path, to: home))
        }
        for vol in snapshot.volumes {
            if path == vol.root || path.hasPrefix(vol.root + "/") {
                return RootContext(kind: .volume(FilePath(vol.root)), rootPath: vol.root, rel: relativize(path, to: vol.root))
            }
        }
        return nil
    }

    nonisolated static func relativize(_ path: String, to root: String) -> String {
        guard path.hasPrefix(root) else { return path }
        var rel = String(path.dropFirst(root.count))
        while rel.hasPrefix("/") { rel.removeFirst() }
        return rel
    }

    // MARK: Blocklist matching (mirrors isPathBlocked)

    nonisolated static func prefixMatches(path: String, prefix: String) -> Bool {
        if path.hasPrefix(prefix) { return true }
        // Mirror the /private auto-expansion done by PathBlocklist.rebuild()
        for (a, b) in [("/tmp/", "/private/tmp/"), ("/var/", "/private/var/"), ("/etc/", "/private/etc/")] {
            if prefix.hasPrefix(a), path.hasPrefix("/private" + prefix) { return true }
            if prefix.hasPrefix(b), path.hasPrefix(String(prefix.dropFirst("/private".count))) { return true }
        }
        return false
    }

    nonisolated static func containsMatches(path: String, component: String) -> Bool {
        if path.contains(component) { return true }
        // fts paths omit the trailing slash, so "/build/" should also match a path ending in "/build"
        if component.hasSuffix("/"), component.count >= 2 {
            let trimmed = String(component.dropLast())
            if path.hasSuffix(trimmed) { return true }
        }
        return false
    }

    // MARK: fsignore probing (temp-root technique)

    /// Non-comment, non-empty, non-negation lines (candidate culprit rules).
    nonisolated static func fsignoreRuleLines(_ content: String) -> [String] {
        content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("!") }
    }

    /// Write `content` to a throwaway ignore file whose root is a temp dir, then check `rel` under it.
    /// The crate requires the path to live under the ignore file's root and anchors patterns to it, so we
    /// reconstruct `<tempRoot>/<rel>` to preserve gitignore semantics without touching HOME or the volume.
    nonisolated static func isIgnoredAtRoot(rel: String, content: String) -> Bool {
        let tmpRoot = NSTemporaryDirectory() + "cling-ignore-probe-" + UUID().uuidString
        let ignoreFile = tmpRoot + "/.fsignore"
        defer { try? FileManager.default.removeItem(atPath: tmpRoot) }
        do {
            try FileManager.default.createDirectory(atPath: tmpRoot, withIntermediateDirectories: true)
            try content.write(toFile: ignoreFile, atomically: true, encoding: .utf8)
        } catch {
            log.error("ignore probe write failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        let probePath = rel.isEmpty ? tmpRoot : tmpRoot + "/" + rel
        return probePath.isIgnored(in: ignoreFile)
    }

    // MARK: - Re-inclusion option generation

    nonisolated static func buildOptions(
        path: String, isDir: Bool, isBundle: Bool, root: RootContext?,
        blocklistHits: [IgnoreHit], fsignoreHits: [IgnoreHit]
    ) -> [InclusionOption] {
        let rel = root?.rel
        let volRoot: FilePath? = { if case let .volume(v) = root?.kind { return v }; return nil }()
        let hasFs = !fsignoreHits.isEmpty && rel != nil

        // When the path is also excluded by an ignore file, the same option must add an fsignore `!` for the
        // exact target (the blocklist exception alone won't clear the ignore-file match during the walk).
        let fsTarget: (reExclude: [String], reInclude: [String]) =
            (hasFs && rel != nil) ? targetLines(rel: rel!, isDir: isDir, isBundle: isBundle) : ([], [])
        func attachFs(_ option: inout InclusionOption) {
            guard hasFs else { return }
            option.reExcludeFsignore = fsTarget.reExclude
            option.reIncludeFsignore = fsTarget.reInclude
            option.fsignoreRoot = volRoot
        }

        var options: [InclusionOption] = []

        if !blocklistHits.isEmpty {
            // Preferred fix: add blocklist `!` exceptions. The fast byte-matched block rule stays in place;
            // only the excepted paths are let back in (and the walker descends into blocked dirs to reach them).

            // 1. Exact path: a prefix exception covering this path (and, for a directory, its subtree).
            var exact = InclusionOption(
                title: "Index this exact path (recommended)",
                summary: "Adds a blocklist exception so only this path is indexed.",
                breadth: .exact,
                addBlocklistPrefixes: ["!\(path)"]
            )
            attachFs(&exact)
            options.append(exact)

            // 2. Smart generalizations: re-include the component after a matched contains rule, everywhere it
            //    appears (e.g. block `.app/Contents/`, except `!.app/Contents/MacOS/` for all app binaries).
            //    Skipped when an ignore file also blocks the path, since the exact fsignore `!` would narrow it.
            if !hasFs {
                for hit in blocklistHits where hit.source == .blocklistContains {
                    guard let g = generalizedException(forContains: hit.rule, path: path) else { continue }
                    options.append(InclusionOption(
                        title: "Index all similar paths",
                        summary: "Adds the exception `!\(g.pattern)`, indexing `\(g.component)` wherever `\(hit.rule)` would block it. The rest stays out.",
                        breadth: .pattern,
                        addBlocklistContains: ["!\(g.pattern)"]
                    ))
                }
            }

            // 3. Broad fallback: delete the rule entirely.
            let ruleList = blocklistHits.map { "`\($0.rule)`" }.joined(separator: ", ")
            var remove = InclusionOption(
                title: "Remove the blocklist rule",
                summary: "Deletes \(ruleList) from the blocklist. Indexes everything it matched, not just this path. Can be large and slow.",
                breadth: .broad,
                removeBlocklist: blocklistHits
            )
            attachFs(&remove)
            options.append(remove)
        } else if let rel {
            // Pure ignore-file exclusion: add `!` re-includes (negation makes the walker descend).
            let target = targetLines(rel: rel, isDir: isDir, isBundle: isBundle)
            options.append(InclusionOption(
                title: "Index this exact path",
                summary: targetSummary(isDir: isDir, isBundle: isBundle),
                breadth: .exact,
                reExcludeFsignore: target.reExclude,
                reIncludeFsignore: target.reInclude,
                fsignoreRoot: volRoot
            ))
            if let parentRel = parentRelative(rel) {
                let parentName = (parentRel as NSString).lastPathComponent
                if let ext = fileExtension(of: (rel as NSString).lastPathComponent) {
                    let glob = extGlob(scope: parentRel, ext: ext)
                    options.append(InclusionOption(
                        title: "All .\(ext) \(bundleNoun(ext))s in this folder",
                        summary: "Indexes every `.\(ext)` under `\(parentName)`.",
                        breadth: .pattern,
                        reExcludeFsignore: glob.reExclude,
                        reIncludeFsignore: glob.reInclude,
                        fsignoreRoot: volRoot
                    ))
                }
                options.append(InclusionOption(
                    title: "This whole folder",
                    summary: "Indexes everything inside `\(parentName)`.",
                    breadth: .folder,
                    reIncludeFsignore: ["!\(parentRel)", "!\(parentRel)/**"],
                    fsignoreRoot: volRoot
                ))
            }
        }

        // Dedupe identical changes, keep stable order by breadth.
        var seen = Set<String>()
        return options
            .filter { seen.insert($0.signature).inserted }
            .sorted { $0.breadth < $1.breadth }
    }

    /// For a contains rule like `.app/Contents/` that matches `path`, return the component right after it and a
    /// `!` exception pattern re-including that component everywhere (e.g. `.app/Contents/MacOS/`).
    nonisolated static func generalizedException(forContains rule: String, path: String) -> (pattern: String, component: String)? {
        guard rule.hasSuffix("/"), let range = path.range(of: rule) else { return nil }
        let comp = path[range.upperBound...].prefix { $0 != "/" }
        guard !comp.isEmpty else { return nil }
        return (pattern: rule + comp + "/", component: String(comp))
    }

    // MARK: Pattern helpers

    nonisolated static func fileExtension(of leaf: String) -> String? {
        guard let dot = leaf.lastIndex(of: "."), dot != leaf.startIndex else { return nil }
        let ext = String(leaf[leaf.index(after: dot)...])
        guard !ext.isEmpty, ext.count <= 12, !ext.contains(" ") else { return nil }
        return ext.lowercased()
    }

    nonisolated static func parentRelative(_ rel: String) -> String? {
        guard let slash = rel.lastIndex(of: "/") else { return nil }
        let parent = String(rel[..<slash])
        return parent.isEmpty ? nil : parent
    }

    /// Directory extensions that macOS treats as opaque bundles; we index the bundle entry but not its guts.
    nonisolated static let bundleExtensions: Set<String> = [
        "app", "framework", "bundle", "appex", "xpc", "plugin", "kext", "qlgenerator",
        "mdimporter", "prefpane", "photoslibrary", "rtfd", "pkg", "component", "wdgt",
    ]

    /// fsignore lines to re-include a single target.
    /// - file: `!rel`
    /// - bundle dir: `!rel` plus `rel/**` re-exclusion (whitelisting a dir otherwise drags in every internal file)
    /// - plain dir: `!rel` and `!rel/**` (include the whole subtree)
    nonisolated static func targetLines(rel: String, isDir: Bool, isBundle: Bool) -> (reExclude: [String], reInclude: [String]) {
        if !isDir { return ([], ["!\(rel)"]) }
        if isBundle { return (["\(rel)/**"], ["!\(rel)"]) }
        return ([], ["!\(rel)", "!\(rel)/**"])
    }

    /// Re-include every `*.ext` under `scope`. Adds a `/**` re-exclusion so bundle internals stay out
    /// (harmless for plain-file extensions, which have no children).
    nonisolated static func extGlob(scope: String, ext: String) -> (reExclude: [String], reInclude: [String]) {
        let pattern = "\(scope)/**/*.\(ext)"
        if bundleExtensions.contains(ext.lowercased()) {
            return (["\(pattern)/**"], ["!\(pattern)"])
        }
        return ([], ["!\(pattern)"])
    }

    nonisolated static func bundleNoun(_ ext: String) -> String {
        bundleExtensions.contains(ext.lowercased()) ? "bundle" : "file"
    }

    nonisolated static func targetSummary(isDir: Bool, isBundle: Bool, lead: String = "Adds a `!` rule so only") -> String {
        if isBundle { return "\(lead) this bundle is indexed (its internal files stay out)." }
        if isDir { return "\(lead) this folder and its contents are indexed." }
        return "\(lead) this file is indexed."
    }
}

// MARK: - MissingPathResultsBar

/// Thin affordance under the search results: when a search doesn't surface what the user expected, this
/// lets them check whether the path is excluded and force it into the index. Opens the diagnostic sheet,
/// pre-filling the query when it looks like a path.
struct MissingPathResultsBar: View {
    let query: String

    @State private var showSheet = false
    @State private var hovering = false

    private var candidatePath: String {
        let q = query.trimmingCharacters(in: .whitespaces)
        return (q.contains("/") || q.hasPrefix("~")) ? q : ""
    }

    var body: some View {
        Button(action: { showSheet = true }) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.magnifyingglass")
                Text("Not seeing it? A file or folder may be excluded from the index.")
                Text("Add a path")
                    .foregroundStyle(hovering ? Color.accentColor : Color.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                Spacer()
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.06) : .clear)
            .opacity(hovering ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .sheet(isPresented: $showSheet) {
            MissingPathSheet(initialPath: candidatePath)
                .frame(width: 600, height: 560)
        }
    }
}

// MARK: - MissingPathSheet

struct MissingPathSheet: View {
    var initialPath: String = ""

    @Environment(\.dismiss) private var dismiss
    @State private var pathText = ""
    @State private var diagnosis: PathDiagnosis?
    @State private var selectedID: UUID?
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    inputSection
                    if let diagnosis {
                        resultSection(diagnosis)
                    } else {
                        dropZone
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .padding(2)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.12), value: dropTargeted)
        .onAppear {
            if pathText.isEmpty, !initialPath.isEmpty {
                pathText = initialPath
                analyze()
            }
        }
    }

    /// Faint drop affordance shown before a path has been checked. The icon brightens and swaps while a
    /// file is dragged over the sheet.
    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: dropTargeted ? "arrow.down.doc.fill" : "questionmark.folder")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.45))
                .scaleEffect(dropTargeted ? 1.12 : 1)
            Text(dropTargeted ? "Release to check this path" : "Drop a file or folder anywhere, or type a path above")
                .font(.system(size: 11))
                .foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 46)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(dropTargeted ? Color.accentColor.opacity(0.06) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    dropTargeted ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.2),
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                )
        )
        .padding(.top, 4)
    }

    private func handleDrop(_ urls: [URL]) -> Bool {
        guard let url = urls.first(where: \.isFileURL) else { return false }
        pathText = url.path
        analyze()
        return true
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Reindex excluded path").font(.system(size: 14, weight: .semibold))
                Text("Check whether a file or folder is excluded by an ignore rule or the blocklist, and add it back.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("/path/to/file/or/folder", text: $pathText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit(analyze)
                Button("Choose…", action: choose)
                    .controlSize(.regular)
                Button("Check", action: analyze)
                    .controlSize(.regular)
                    .keyboardShortcut(.defaultAction)
                    .disabled(pathText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Tip: paste a path, drop a file anywhere on this sheet, or use Choose. `~` is expanded.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func resultSection(_ d: PathDiagnosis) -> some View {
        switch d.status {
        case .notFound:
            statusCard(icon: "exclamationmark.triangle.fill", tint: .orange,
                       title: "Nothing exists at that path",
                       detail: "Double-check the path. The file or folder must exist on disk to be indexed.")
        case .notInAnyScope:
            statusCard(icon: "mappin.slash", tint: .orange,
                       title: "Not inside any indexed location",
                       detail: "This path isn't under an enabled search scope or an indexed volume, so Cling never walks it. Enable the matching scope (or volume) in Search settings first.")
        case .alreadyIndexable:
            VStack(alignment: .leading, spacing: 10) {
                statusCard(icon: "checkmark.seal.fill", tint: .green,
                           title: "Not excluded by any rule",
                           detail: "No ignore rule or blocklist entry matches this path. It should already be in the index. If it's missing, a reindex will pick it up.")
                Button("Reindex now") {
                    reindex(for: d)
                    dismiss()
                }
                .controlSize(.regular)
            }
        case let .excluded(hits):
            VStack(alignment: .leading, spacing: 16) {
                excludedByCard(hits)
                optionsCard(d)
            }
        }
    }

    private func excludedByCard(_ hits: [IgnoreHit]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Excluded by these rules", systemImage: "nosign")
                .font(.system(size: 12, weight: .semibold))
            ForEach(hits) { hit in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(hit.rule)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    Text(hit.source.label)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if hit.source.isBlocklist {
                        Text("byte match")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.secondary.opacity(0.18), in: Capsule())
                            .foregroundStyle(.secondary)
                            .help("Fast blocklist rule. Undone with a blocklist `!` exception (it prunes folders before ignore-file negation can apply).")
                    }
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func optionsCard(_ d: PathDiagnosis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Reindex rule", systemImage: "plus.circle")
                .font(.system(size: 12, weight: .semibold))

            ForEach(d.options) { option in
                optionRow(option, diagnosis: d)
            }

            if d.options.contains(where: { !$0.reIncludeFsignore.isEmpty || !$0.addBlocklistPrefixes.isEmpty || !$0.addBlocklistContains.isEmpty }) {
                Text("An exception makes Cling scan inside folders it would otherwise skip, so the next index may take longer.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }

            HStack {
                Spacer()
                Button("Apply & Reindex") {
                    apply(d)
                }
                .controlSize(.regular)
                .buttonStyle(.borderedProminent)
                .disabled(selectedID == nil || FUZZY.backgroundIndexing)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func optionRow(_ option: InclusionOption, diagnosis d: PathDiagnosis) -> some View {
        let selected = selectedID == option.id
        return Button(action: { selectedID = option.id }) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .font(.system(size: 13))
                VStack(alignment: .leading, spacing: 4) {
                    Text(option.title).font(.system(size: 12, weight: .medium))
                    Text(option.summary).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if selected {
                        changeList(option, diagnosis: d)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(8)
            .background(selected ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func changeList(_ option: InclusionOption, diagnosis d: PathDiagnosis) -> some View {
        let ignoreLabel = option.fsignoreRoot == nil ? "~/.fsignore" : "\(option.fsignoreRoot!.name.string)/.fsignore"
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(Array((option.addBlocklistPrefixes + option.addBlocklistContains).enumerated()), id: \.offset) { _, line in
                changeLine(sign: "+", color: .green, label: "Add to blocklist", value: line)
            }
            ForEach(option.removeBlocklist) { hit in
                changeLine(sign: "−", color: .red, label: "Remove from blocklist", value: hit.rule)
            }
            ForEach(Array(option.reExcludeFsignore.enumerated()), id: \.offset) { _, line in
                changeLine(sign: "+", color: .secondary, label: "Add to \(ignoreLabel)", value: line)
            }
            ForEach(Array(option.reIncludeFsignore.enumerated()), id: \.offset) { _, line in
                changeLine(sign: "+", color: .green, label: "Add to \(ignoreLabel)", value: line)
            }
        }
        .padding(.top, 4)
    }

    private func changeLine(sign: String, color: Color, label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(sign).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(color)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
            Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }

    private func statusCard(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).font(.system(size: 16))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Actions

    private func analyze() {
        let raw = pathText.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        let snapshot = IndexSnapshot.capture()
        let result = IndexInclusionAnalyzer.diagnose(rawPath: raw, snapshot: snapshot)
        diagnosis = result
        selectedID = result.options.first?.id
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = HOME.url
        if panel.runModal() == .OK, let url = panel.url {
            pathText = url.path
            analyze()
        }
    }

    private func apply(_ d: PathDiagnosis) {
        guard let id = selectedID, let option = d.options.first(where: { $0.id == id }) else { return }
        FUZZY.includeInIndex(d.plan(for: option))
        dismiss()
    }

    private func reindex(for d: PathDiagnosis) {
        switch d.rootContext?.kind {
        case .home: FUZZY.refresh(pauseSearch: false, scopes: [.home, .library])
        case let .volume(v): FUZZY.indexVolume(v)
        case nil: FUZZY.refresh(pauseSearch: false)
        }
    }
}
