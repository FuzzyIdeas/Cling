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

// MARK: - FolderSegment

/// One selectable folder level in the "parent folder" option's breadcrumb (root to deepest).
struct FolderSegment: Hashable {
    let name: String
    let rule: ExcludeRule
}

// MARK: - ExcludeOption

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

    let path: FilePath
    let abs: String
    let mechanism: ExcludeMechanism
    let root: String? // HOME or volume root; nil for blocklist paths
    let rel: String // path relative to root (fsignore); the absolute path for blocklist

    /// Lazily stat'd so huge selections (exact-only bulk mode) never touch the filesystem.
    var isDir: Bool { path.isDir }

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
            return ExcludeAnalysis(infos: infos, options: [option], note: "\(infos.count) paths selected. Smart suggestions are off for large selections, so each path is excluded exactly.")
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
            while i < common.count, i < p.count, common[i] == p[i] {
                i += 1
            }
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
        for info in remaining {
            rules.append(exactRule(info))
        }
        return rules.isEmpty ? nil : rules
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

}

// MARK: - ExcludeSheetRequest

/// Identifiable wrapper so the sheet is presented with `.sheet(item:)`, which passes the paths atomically
/// (avoids the stale-state race where `.sheet(isPresented:)` could open with an old/empty selection).
struct ExcludeSheetRequest: Identifiable {
    let id = UUID()
    let paths: [FilePath]
}

// MARK: - ExcludeFromIndexSheet

struct ExcludeFromIndexSheet: View {
    let paths: [FilePath]

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
            if let first = result.options.first { reseed(first) }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var analysis: ExcludeAnalysis?
    @State private var selectedID: UUID?
    @State private var folderSegmentIndex = 0
    @State private var edit: ExcludeEdit?
    @State private var rawMode = false
    @State private var selectionOK: Bool? = nil
    @State private var affectedCount: Int? = nil
    @State private var countCapped = false
    @State private var countTask: Task<Void, Never>? = nil

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
        return VStack(alignment: .leading, spacing: 6) {
            Button(action: {
                selectedID = option.id
                if let segments = option.folderSegments { folderSegmentIndex = segments.count - 1 }
                reseed(option)
            }) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                        .font(.system(size: 13))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(option.title).font(.system(size: 12, weight: .medium))
                        Text(option.summary).font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if selected {
                VStack(alignment: .leading, spacing: 6) {
                    if let segments = option.folderSegments {
                        folderBreadcrumb(segments)
                    }
                    if edit != nil {
                        editor(option)
                    } else {
                        changeList(rulesFor(option)) // read-only fallback for large sets
                    }
                }
                .padding(.leading, 21)
            }
        }
        .padding(8)
        .background(selected ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
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
                    Button(seg.name) { folderSegmentIndex = idx; if let o = analysis?.options.first(where: { $0.id == selectedID }) { reseed(o) } }
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

    private func rulesFor(_ option: ExcludeOption) -> [ExcludeRule] {
        if let segments = option.folderSegments, !segments.isEmpty {
            return [segments[min(folderSegmentIndex, segments.count - 1)].rule]
        }
        return option.rules
    }

    private func apply(_ analysis: ExcludeAnalysis) {
        guard let id = selectedID, let option = analysis.options.first(where: { $0.id == id }) else { return }
        let rules = effectiveRules(for: option)
        // Only large/bulk options have no editor (edit == nil); those are never "edited", so don't force a
        // reindex on them (an optional `!=` against a non-optional array would always read as edited).
        let edited = edit.map { $0.effectiveLines() != rulesFor(option).map(\.line) } ?? false
        FUZZY.excludeFromIndex(rules: rules, paths: Set(paths), reindex: option.needsReindex || edited)
        dismiss()
    }

    // MARK: Edit state

    /// Build editable state for an option, but only when it shows a small, hand-editable rule set. Large/bulk
    /// sets fall back to the read-only change list.
    private func makeEdit(for option: ExcludeOption) -> ExcludeEdit? {
        let rules = rulesFor(option)
        guard (1 ... 12).contains(rules.count) else { return nil }
        return ExcludeEdit(rules: rules.map { ($0.line, $0.mechanism.supportsGlobs) })
    }

    /// Rebuild concrete rules from the edited text, preserving each rule's original mechanism and prefix flag.
    private func effectiveRules(for option: ExcludeOption) -> [ExcludeRule] {
        let orig = rulesFor(option)
        guard let edit else { return orig }
        let lines = edit.effectiveLines()
        return orig.enumerated().map { i, r in
            ExcludeRule(mechanism: r.mechanism, line: i < lines.count ? lines[i] : r.line, blocklistPrefix: r.blocklistPrefix)
        }
    }

    private func reseed(_ option: ExcludeOption) {
        edit = makeEdit(for: option)
        rawMode = false
        recomputeSignals(option)
    }

    private func recomputeSignals(_ option: ExcludeOption) {
        guard let analysis else { selectionOK = nil; affectedCount = nil; return }
        let rules = effectiveRules(for: option)
        // Reliable selection check: every selected path still matched by some rule.
        if edit == nil {
            selectionOK = nil
        } else {
            selectionOK = analysis.infos.allSatisfy { info in rules.contains { ExcludeAnalyzer.matches($0, info) } }
        }
        recomputeCount(rules, infos: analysis.infos)
    }

    private func recomputeCount(_ rules: [ExcludeRule], infos: [ExcludePathInfo]) {
        countTask?.cancel()
        affectedCount = nil
        countCapped = false
        guard edit != nil else { return }
        let root = infos.first?.root
        let queries: [ExcludeCountQuery] = rules.compactMap {
            excludeCountQuery(line: $0.line, supportsGlobs: $0.mechanism.supportsGlobs, blocklistPrefix: $0.blocklistPrefix, root: root)
        }
        guard !queries.isEmpty else { return }
        countTask = Task {
            var total = 0, capped = false
            for q in queries {
                if Task.isCancelled { return }
                let c = await FUZZY.matchCount(query: q.query, dirsOnly: q.dirsOnly, folders: q.folders.map { FilePath($0) }, maxDepth: nil, cap: 5000)
                total += c
                if c >= 5000 { capped = true }
            }
            if Task.isCancelled { return }
            await MainActor.run { affectedCount = total; countCapped = capped }
        }
    }

    private func recomputeSignalsForSelected() {
        guard let analysis, let option = analysis.options.first(where: { $0.id == selectedID }) else { return }
        recomputeSignals(option)
    }

    // MARK: Editor

    @ViewBuilder
    private func editor(_ option: ExcludeOption) -> some View {
        if let edit {
            let rules = rulesFor(option)
            let cols = edit.togglableColumns()
            let single = edit.lines.count == 1
            VStack(alignment: .leading, spacing: 3) {
                if rawMode {
                    ForEach(Array(edit.lines.enumerated()), id: \.offset) { i, _ in
                        rawLineField(i, storeLabel: i < rules.count ? rules[i].storeLabel : "")
                    }
                } else {
                    ForEach(Array(edit.lines.enumerated()), id: \.offset) { i, line in
                        if single, line.chipEligible, !cols.isEmpty {
                            chipLine(i, line: line, columns: cols, storeLabel: rules[i].storeLabel)
                        } else {
                            staticRuleLine(text: edit.effectiveLines()[i], storeLabel: i < rules.count ? rules[i].storeLabel : "", literalNote: !line.chipEligible)
                        }
                    }
                }
                HStack(spacing: 10) {
                    Button(rawMode ? "Done editing text" : "Edit as text") {
                        if rawMode { self.edit?.commitRaw() }
                        rawMode.toggle()
                        recomputeSignals(option)
                    }
                    .controlSize(.small).buttonStyle(.link)
                    selectionBadge()
                    countBadge()
                    Spacer()
                }
                .padding(.top, 2)
            }
            .padding(.top, 4)
        }
    }

    private func chipLine(_ i: Int, line: ExcludeRuleLine, columns: Set<Int>, storeLabel: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("+").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(.red)
            HStack(spacing: 2) {
                if line.anchored { Text("/").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary) }
                ForEach(Array(line.tokens.enumerated()), id: \.offset) { c, token in
                    if c > 0 { Text("/").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary) }
                    if token.isLiteral, columns.contains(c) {
                        Button(action: { edit?.cycle(column: c); recomputeSignalsForSelected() }) {
                            tokenChip(token.display, tint: chipTint(token), interactive: true)
                        }
                        .buttonStyle(.plain).help(chipHelp(token))
                    } else {
                        tokenChip(token.display, tint: .secondary, interactive: false)
                    }
                }
                if line.dirSlash { Text("/").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary) }
            }
            Text("Add to \(storeLabel)").font(.system(size: 9)).foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
    }

    private func tokenChip(_ text: String, tint: Color, interactive: Bool) -> some View {
        Text(Self.middleTruncated(text))
            .lineLimit(1).truncationMode(.middle)
            .font(.system(size: 10, design: .monospaced))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(tint.opacity(interactive ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: 3))
            .overlay(interactive ? RoundedRectangle(cornerRadius: 3).strokeBorder(tint.opacity(0.4)) : nil)
            .foregroundStyle(interactive ? tint : Color.secondary)
    }

    private func chipTint(_ token: RuleToken) -> Color {
        switch token.state { case .literal: .primary; case .extWildcard: .accentColor; case .fullWildcard: .orange }
    }

    private func chipHelp(_ token: RuleToken) -> String {
        switch token.state {
        case .literal:
            if let ext = token.ext { return "\(token.original). Click to exclude any .\(ext) file here." }
            return "\(token.original). Click to exclude any name here."
        case .extWildcard: return "Excludes any .\(token.ext ?? "") file here. Click to exclude any name."
        case .fullWildcard: return "Excludes any name here. Click to use the literal name again."
        }
    }

    private func staticRuleLine(text: String, storeLabel: String, literalNote: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("+").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(.red)
            Text(Self.middleTruncated(text))
                .lineLimit(1).truncationMode(.middle)
                .font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                .help(text)
            Text("Add to \(storeLabel)").font(.system(size: 9)).foregroundStyle(.tertiary)
            if literalNote {
                Text("literal match, wildcards not supported here").font(.system(size: 9)).foregroundStyle(.tertiary).italic()
            }
            Spacer(minLength: 0)
        }
    }

    private func rawLineField(_ i: Int, storeLabel: String) -> some View {
        HStack(spacing: 6) {
            TextField("", text: Binding(
                get: { edit.map { i < $0.effectiveLines().count ? $0.effectiveLines()[i] : "" } ?? "" },
                set: { edit?.setRaw(i, $0); recomputeSignalsForSelected() }
            ))
            .textFieldStyle(.roundedBorder).font(.system(size: 10, design: .monospaced))
            Text("Add to \(storeLabel)").font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func selectionBadge() -> some View {
        switch selectionOK {
        case .some(true): Label("matches your selection", systemImage: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(.green)
        case .some(false): Label("no longer matches your selection", systemImage: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(.red)
        case .none: EmptyView()
        }
    }

    @ViewBuilder
    private func countBadge() -> some View {
        if let n = affectedCount {
            if n <= paths.count {
                Label("only your selection", systemImage: "info.circle").font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Label("would exclude ~\(countCapped ? "5000+" : String(n)) indexed items", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
        }
    }

    static func middleTruncated(_ s: String, max: Int = 28) -> String {
        guard s.count > max else { return s }
        let keep = max - 1
        return "\(s.prefix(keep - keep / 2))…\(s.suffix(keep / 2))"
    }

}
