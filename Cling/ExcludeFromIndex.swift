import AppKit
import Defaults
import Foundation
import Lowtech
import OSLog
import SwiftUI
import System

private let log = Logger(subsystem: clingSubsystem, category: "ExcludeFromIndex")

// MARK: - ExcludeMechanism

/// Which exclusion store a rule goes into. Ignore files use gitignore globs; the blocklist is byte matching.
enum ExcludeMechanism: Equatable, Hashable {
    case homeIgnore
    case volumeIgnore(FilePath)
    case scopeIgnore(SearchScope)
    case blocklist

    var supportsGlobs: Bool { self != .blocklist }

    var fileLabel: String {
        switch self {
        case .homeIgnore: "~/.fsignore"
        case let .volumeIgnore(v): "\(v.name.string)/.fsignore"
        case let .scopeIgnore(scope): "\(scope.label) ignore"
        case .blocklist: "blocklist"
        }
    }
}

// MARK: - ExcludeRule

struct ExcludeRule: Hashable {
    let mechanism: ExcludeMechanism
    let line: String
    var blocklistPrefix = false // for .blocklist: prefix match vs contains match

    var storeLabel: String {
        if mechanism == .blocklist { return blocklistPrefix ? "blocklist (prefix)" : "blocklist (contains)" }
        return mechanism.fileLabel
    }
}

// MARK: - ExcludeOption

/// One selectable folder level in the "parent folder" option's breadcrumb (root to deepest).
struct FolderSegment: Hashable {
    let name: String
    let rule: ExcludeRule
}

struct ExcludeOption: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let summary: String
    let breadth: Breadth
    var rules: [ExcludeRule] = []
    /// Set on the "parent folder" option: ancestor folders (root first) the user clicks to choose how far up.
    var folderSegments: [FolderSegment]?
    /// Broad rules can match paths beyond the selection, so a reindex is needed to drop the rest. Exact
    /// rules only touch the selected paths, which are removed from the live index immediately.
    var needsReindex = false

    static func == (lhs: ExcludeOption, rhs: ExcludeOption) -> Bool { lhs.id == rhs.id }
}

// MARK: - ExcludePathInfo

struct ExcludePathInfo {
    let path: FilePath
    let abs: String
    let mechanism: ExcludeMechanism
    let root: String? // HOME or volume root; nil for blocklist paths
    let rel: String // path relative to root (fsignore); the absolute path for blocklist

    /// Lazily stat'd so huge selections (exact-only bulk mode) never touch the filesystem.
    var isDir: Bool { path.isDir }

    init(path: FilePath, home: String, volumes: [FilePath]) {
        self.path = path
        let p = path.string
        abs = p
        if p == home || p.hasPrefix(home + "/") {
            mechanism = .homeIgnore
            root = home
            rel = Self.relativize(p, home)
        } else if let v = volumes.first(where: { p == $0.string || p.hasPrefix($0.string + "/") }) {
            mechanism = .volumeIgnore(v)
            root = v.string
            rel = Self.relativize(p, v.string)
        } else if let (scope, scopeRoot) = ScopeIgnore.scopeAndRoot(forPath: p) {
            mechanism = .scopeIgnore(scope)
            root = scopeRoot
            rel = Self.relativize(p, scopeRoot)
        } else {
            mechanism = .blocklist
            root = nil
            rel = p
        }
    }

    var leaf: String { (abs as NSString).lastPathComponent }
    var ext: String? { IndexInclusionAnalyzer.fileExtension(of: leaf) }
    var rootKey: String {
        switch mechanism {
        case .homeIgnore: "home"
        case let .volumeIgnore(v): "vol:" + v.string
        case let .scopeIgnore(scope): "scope:" + scope.rawValue
        case .blocklist: "blk"
        }
    }

    /// The directory containing this path, as a rule pattern (rel for fsignore, abs for blocklist), no trailing slash.
    var parentPattern: String {
        let dir = (mechanism == .blocklist ? abs : rel) as NSString
        return dir.deletingLastPathComponent
    }

    static func relativize(_ p: String, _ r: String) -> String {
        guard p.hasPrefix(r) else { return p }
        var s = String(p.dropFirst(r.count))
        while s.hasPrefix("/") { s.removeFirst() }
        return s
    }
}

// MARK: - ExcludeAnalysis

struct ExcludeAnalysis {
    let infos: [ExcludePathInfo]
    let options: [ExcludeOption]
    var note: String?
}

// MARK: - ExcludeAnalyzer

enum ExcludeAnalyzer {
    /// Above this many selected paths we skip the smart detections (O(n²) grouping + per-path stats) and just
    /// offer an exact rule per path, so a "select all then exclude" of thousands of rows can't hang the sheet.
    static let smartLimit = 200

    @MainActor
    static func analyze(_ paths: [FilePath]) -> ExcludeAnalysis {
        let home = HOME.string
        let volumes = FUZZY.enabledVolumes
        let infos = paths.map { ExcludePathInfo(path: $0, home: home, volumes: volumes) }
        guard !infos.isEmpty else { return ExcludeAnalysis(infos: [], options: []) }

        // Bulk mode: too many paths to analyze sensibly. Exact only, no filesystem stats, no grouping.
        if infos.count > smartLimit {
            let rules = infos.map { exactRuleNoStat($0) }
            let option = ExcludeOption(
                title: "Exactly these \(infos.count) paths",
                summary: "Adds one rule per selection.",
                breadth: .exact,
                rules: rules,
                needsReindex: false
            )
            return ExcludeAnalysis(infos: infos, options: [option], note: "\(infos.count) paths selected — smart suggestions are off for large selections. Each path is excluded exactly.")
        }

        var options: [ExcludeOption] = [exactOption(infos)]

        // Structural options recognize well-known layouts (app/framework bundles, media libraries, build
        // folders, localizations) and generalize across siblings. They work across mixed stores because each
        // rule carries its own mechanism, so they're computed before the same-store smart options below.
        options.append(contentsOf: StructuralPatterns.options(infos))

        // Smart options only when every selection lives in the same store (same fsignore root, or all blocklist).
        let sameRoot = Set(infos.map(\.rootKey)).count == 1
        if sameRoot, let mech = infos.first?.mechanism {
            if mech.supportsGlobs, let ext = commonExtension(infos) {
                options.append(ExcludeOption(
                    title: "All .\(ext) files",
                    summary: "Excludes every `.\(ext)` file in \(mech.fileLabel).",
                    breadth: .pattern,
                    rules: [ExcludeRule(mechanism: mech, line: "*.\(ext)")],
                    needsReindex: true
                ))
            }
            if let name = commonLeaf(infos), let rule = nameRule(name: name, isDir: infos.allSatisfy(\.isDir), mechanism: mech) {
                options.append(ExcludeOption(
                    title: "All items named “\(name)”",
                    summary: "Excludes anything named `\(name)` at any depth.",
                    breadth: .pattern,
                    rules: [rule],
                    needsReindex: true
                ))
            }
            if let folder = folderOption(infos, mechanism: mech) {
                options.append(folder)
            }
            if infos.count > 2, let grouped = smartGrouping(infos, mechanism: mech), grouped.count < infos.count {
                options.append(ExcludeOption(
                    title: "Smart: \(grouped.count) rule\(grouped.count == 1 ? "" : "s") covering all \(infos.count)",
                    summary: "Groups similar selections so fewer rules cover everything you picked.",
                    breadth: .pattern,
                    rules: grouped,
                    needsReindex: true
                ))
            }
        }

        return ExcludeAnalysis(infos: infos, options: options)
    }

    // MARK: Option builders

    static func exactOption(_ infos: [ExcludePathInfo]) -> ExcludeOption {
        let rules = infos.map { exactRule($0) }
        let n = infos.count
        return ExcludeOption(
            title: n == 1 ? "Exactly this path (recommended)" : "Exactly these \(n) paths (recommended)",
            summary: n == 1 ? "Excludes only this path, nothing else." : "Adds one rule per selection. Excludes only what you picked.",
            breadth: .exact,
            rules: rules,
            needsReindex: false
        )
    }

    static func exactRule(_ info: ExcludePathInfo) -> ExcludeRule {
        if info.mechanism == .blocklist {
            return ExcludeRule(mechanism: .blocklist, line: info.abs, blocklistPrefix: true)
        }
        // Leading slash anchors the pattern to the ignore-file root, so it matches only this path.
        return ExcludeRule(mechanism: info.mechanism, line: "/\(info.rel)" + (info.isDir ? "/" : ""))
    }

    /// Exact rule without stat'ing the path (for bulk mode). Anchored; no trailing slash, which still
    /// excludes a directory and its contents in gitignore, just without the dir-only restriction.
    static func exactRuleNoStat(_ info: ExcludePathInfo) -> ExcludeRule {
        if info.mechanism == .blocklist {
            return ExcludeRule(mechanism: .blocklist, line: info.abs, blocklistPrefix: true)
        }
        return ExcludeRule(mechanism: info.mechanism, line: "/\(info.rel)")
    }

    static func nameRule(name: String, isDir: Bool, mechanism: ExcludeMechanism) -> ExcludeRule? {
        if mechanism == .blocklist {
            guard isDir else { return nil } // a bare filename substring would over-match; only offer for dirs
            return ExcludeRule(mechanism: .blocklist, line: "/\(name)/")
        }
        // No leading slash: unanchored, so it matches anything with this name at any depth.
        return ExcludeRule(mechanism: mechanism, line: isDir ? "\(name)/" : name)
    }

    static func folderRule(_ pattern: String, mechanism: ExcludeMechanism) -> ExcludeRule {
        if mechanism == .blocklist {
            return ExcludeRule(mechanism: .blocklist, line: "\(pattern)/", blocklistPrefix: true)
        }
        return ExcludeRule(mechanism: mechanism, line: "/\(pattern)/")
    }

    /// The "exclude a parent folder" option: the ancestor folders from the root down to the deepest folder
    /// containing every selection, as clickable breadcrumb segments. nil when there's no meaningful ancestor.
    static func folderOption(_ infos: [ExcludePathInfo], mechanism: ExcludeMechanism) -> ExcludeOption? {
        guard let common = commonParentPattern(infos) else { return nil }
        let components = common.split(separator: "/").map(String.init)
        // For the blocklist, the first component is a top-level dir like "Applications"; excluding it alone is
        // too broad, so start one level deeper. No option when the common ancestor isn't deep enough (e.g.
        // paths spanning different apps share only "/Applications").
        let startDepth = mechanism == .blocklist ? 2 : 1
        guard components.count >= startDepth else { return nil }
        var segments: [FolderSegment] = []
        for depth in startDepth ... components.count {
            let pattern = components.prefix(depth).joined(separator: "/")
            let line = mechanism == .blocklist ? "/" + pattern : pattern
            segments.append(FolderSegment(name: components[depth - 1], rule: folderRule(line, mechanism: mechanism)))
        }
        guard !segments.isEmpty else { return nil }
        return ExcludeOption(
            title: "Everything in a parent folder",
            summary: "Excludes a whole folder above the selection. Click a segment to choose how far up.",
            breadth: .folder,
            rules: [segments.last!.rule],
            folderSegments: segments,
            needsReindex: true
        )
    }

    // MARK: Commonality detection

    static func commonExtension(_ infos: [ExcludePathInfo]) -> String? {
        guard infos.allSatisfy({ !$0.isDir }) else { return nil }
        let exts = Set(infos.map(\.ext))
        if exts.count == 1, let e = exts.first ?? nil { return e }
        return nil
    }

    static func commonLeaf(_ infos: [ExcludePathInfo]) -> String? {
        let leaves = Set(infos.map(\.leaf))
        return leaves.count == 1 ? leaves.first : nil
    }

    /// Deepest directory pattern (rel for fsignore, abs for blocklist) that contains every selection.
    static func commonParentPattern(_ infos: [ExcludePathInfo]) -> String? {
        let parents = infos.map { $0.parentPattern.split(separator: "/").map(String.init) }
        guard let first = parents.first else { return nil }
        var common = first
        for p in parents.dropFirst() {
            var i = 0
            while i < common.count, i < p.count, common[i] == p[i] { i += 1 }
            common = Array(common.prefix(i))
        }
        return common.isEmpty ? nil : common.joined(separator: "/")
    }

    // MARK: Smart grouping (greedy set cover)

    static func smartGrouping(_ infos: [ExcludePathInfo], mechanism: ExcludeMechanism) -> [ExcludeRule]? {
        var remaining = infos
        var rules: [ExcludeRule] = []
        var guardCount = 0
        while !remaining.isEmpty, guardCount < 64 {
            guardCount += 1
            guard let best = bestCandidate(remaining, mechanism: mechanism), best.covered.count >= 2 else { break }
            rules.append(best.rule)
            remaining = remaining.filter { !matches(best.rule, $0) }
        }
        for info in remaining { rules.append(exactRule(info)) }
        return rules.isEmpty ? nil : rules
    }

    private static func bestCandidate(_ infos: [ExcludePathInfo], mechanism: ExcludeMechanism) -> (rule: ExcludeRule, covered: [ExcludePathInfo])? {
        var candidates: [ExcludeRule] = []
        if mechanism.supportsGlobs {
            for e in Set(infos.compactMap { $0.isDir ? nil : $0.ext }) {
                candidates.append(ExcludeRule(mechanism: mechanism, line: "*.\(e)"))
            }
        }
        for name in Set(infos.map(\.leaf)) {
            let dirs = infos.filter { $0.leaf == name }
            if let r = nameRule(name: name, isDir: dirs.allSatisfy(\.isDir), mechanism: mechanism) { candidates.append(r) }
        }
        for parent in Set(infos.map(\.parentPattern)) where !parent.isEmpty {
            candidates.append(folderRule(parent, mechanism: mechanism))
        }
        let scored = candidates.map { rule in (rule: rule, covered: infos.filter { matches(rule, $0) }) }
        return scored.max { $0.covered.count < $1.covered.count }
    }

    static func matches(_ rule: ExcludeRule, _ info: ExcludePathInfo) -> Bool {
        let line = rule.line
        if line.hasPrefix("*.") { // extension glob (fsignore only)
            return !info.isDir && info.ext == String(line.dropFirst(2))
        }
        if rule.mechanism == .blocklist {
            if rule.blocklistPrefix {
                let core = line.hasSuffix("/") ? String(line.dropLast()) : line
                return info.abs == core || info.abs.hasPrefix(core + "/")
            }
            // contains match, mirroring isPathBlocked (incl. trailing-slash-as-end)
            return info.abs.contains(line) || (line.hasSuffix("/") && info.abs.hasSuffix(String(line.dropLast())))
        }
        // fsignore pattern (rel-based)
        var core = line
        if core.hasSuffix("/") { core.removeLast() }
        let anchored = core.hasPrefix("/")
        let body = anchored ? String(core.dropFirst()) : core // pattern without the anchor slash
        if anchored || body.contains("/") {
            // Anchored or multi-component path pattern: exact dir/file or a prefix of it.
            return info.rel == body || info.rel.hasPrefix(body + "/")
        }
        // Bare name: matches that name as any path component, at any depth.
        return info.leaf == body || info.rel.split(separator: "/").contains(Substring(body))
    }
}

// MARK: - ExcludeFromIndexSheet

/// Identifiable wrapper so the sheet is presented with `.sheet(item:)`, which passes the paths atomically
/// (avoids the stale-state race where `.sheet(isPresented:)` could open with an old/empty selection).
struct ExcludeSheetRequest: Identifiable {
    let id = UUID()
    let paths: [FilePath]
}

struct ExcludeFromIndexSheet: View {
    let paths: [FilePath]

    @Environment(\.dismiss) private var dismiss
    @State private var analysis: ExcludeAnalysis?
    @State private var selectedID: UUID?
    @State private var folderSegmentIndex = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    selectionCard
                    if let analysis {
                        optionsCard(analysis)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            let result = ExcludeAnalyzer.analyze(paths)
            analysis = result
            selectedID = result.options.first?.id
            if let segments = result.options.compactMap(\.folderSegments).first {
                folderSegmentIndex = segments.count - 1 // default to the deepest folder
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Exclude from index").font(.system(size: 14, weight: .semibold))
                Text("Add an ignore rule or blocklist entry. Pick how broadly it applies.")
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

    private var selectionCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(paths.count == 1 ? "Selected path" : "\(paths.count) selected paths", systemImage: "doc.on.doc")
                .font(.system(size: 12, weight: .semibold))
            ForEach(paths.prefix(6), id: \.string) { path in
                Text(path.shellString)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if paths.count > 6 {
                Text("+ \(paths.count - 6) more").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func optionsCard(_ analysis: ExcludeAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Exclusion rule", systemImage: "minus.circle")
                .font(.system(size: 12, weight: .semibold))

            if let note = analysis.note {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(analysis.options) { option in
                optionRow(option)
            }

            HStack {
                Spacer()
                Button("Exclude & Apply") { apply(analysis) }
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

    private func optionRow(_ option: ExcludeOption) -> some View {
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
                        if let segments = option.folderSegments {
                            folderBreadcrumb(segments)
                        }
                        changeList(rulesFor(option))
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

    private func changeList(_ rules: [ExcludeRule]) -> some View {
        let limit = 10
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(rules.prefix(limit).enumerated()), id: \.offset) { _, rule in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("+").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(.red)
                    Text(rule.line)
                        .font(.system(size: 10, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Add to \(rule.storeLabel)").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            if rules.count > limit {
                Text("+ \(rules.count - limit) more rule\(rules.count - limit == 1 ? "" : "s")")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 4)
    }

    // MARK: Actions

    private func rulesFor(_ option: ExcludeOption) -> [ExcludeRule] {
        if let segments = option.folderSegments, !segments.isEmpty {
            return [segments[min(folderSegmentIndex, segments.count - 1)].rule]
        }
        return option.rules
    }

    private func apply(_ analysis: ExcludeAnalysis) {
        guard let id = selectedID, let option = analysis.options.first(where: { $0.id == id }) else { return }
        FUZZY.excludeFromIndex(rules: rulesFor(option), paths: Set(paths), reindex: option.needsReindex)
        dismiss()
    }

    /// Clickable breadcrumb of the ancestor folders, root to deepest. Clicking a segment excludes the folder
    /// up to and including it; deeper segments are shown dimmed since they fall inside the excluded folder.
    private func folderBreadcrumb(_ segments: [FolderSegment]) -> some View {
        let selected = min(folderSegmentIndex, segments.count - 1)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(Array(segments.enumerated()), id: \.offset) { idx, seg in
                    if idx > 0 {
                        Text("/").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                    Button(seg.name) { folderSegmentIndex = idx }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: idx == selected ? .semibold : .regular, design: .monospaced))
                        .foregroundStyle(idx > selected ? Color.secondary.opacity(0.4) : .primary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(idx == selected ? Color.accentColor.opacity(0.25) : .clear, in: Capsule())
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
