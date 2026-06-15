import Foundation
import Lowtech
import System

// MARK: - Structural exclude patterns

/// Recognizes well-known on-disk layouts (app/framework bundles, media libraries, build-artifact folders,
/// localizations) in a selection and proposes rules that generalize across siblings (every app, every
/// `node_modules`, ...) instead of the literal path prefix the generic analyzer would emit. Each candidate
/// is verified by construction: it is only attached to the selected paths whose structure it provably
/// matches (the `**` semantics were checked against `git check-ignore`), so the toy preview matcher in
/// `ExcludeAnalyzer.matches` never has to understand `**`.
enum StructuralPatterns {
    // MARK: Candidate

    struct Candidate {
        let rules: [ExcludeRule]
        let title: String
        let summary: String
        let breadth: Breadth
        var needsReindex = true
        /// 0 = broad / cross-container, 1 = container-local. Used only to order ties.
        let rank: Int

        var key: String {
            rules.map { "\(StructuralPatterns.mechKey($0.mechanism))\u{1}\($0.line)\u{1}\($0.blocklistPrefix)" }
                .joined(separator: "\u{2}")
        }
    }

    /// Build-artifact / VCS / dependency directories that are noise at any depth. These go to the global
    /// blocklist (fast prune, no globs needed) rather than a per-store ignore file.
    static let noiseDirs: Set<String> = [
        "node_modules", ".git", ".svn", ".hg", ".build", "DerivedData", "Pods", "Carthage",
        "target", "build", "Build", "dist", "out", "vendor", "__pycache__", ".venv", "venv",
        "site-packages", ".tox", ".mypy_cache", ".pytest_cache", ".gradle", ".m2", ".terraform",
        ".next", ".nuxt", ".svelte-kit", ".parcel-cache", ".cache", "coverage", ".nyc_output",
    ]

    /// Opaque library packages: searching their guts is rarely useful, so drop everything inside.
    static let mediaExts: [String] = [
        ".photoslibrary", ".fcpbundle", ".musiclibrary", ".imovielibrary", ".tvlibrary",
        ".aplibrary", ".logicx", ".band", ".xcarchive",
    ]

    /// Non-binary sections of an `*.app` bundle that can be dropped wholesale.
    static let appDropSections: Set<String> = [
        "Resources", "Frameworks", "PlugIns", "_CodeSignature", "SharedSupport", "Helpers",
        "Library", "XPCServices", "Frameworks", "CodeResources",
    ]

    static func mechKey(_ m: ExcludeMechanism) -> String {
        switch m {
        case .homeIgnore: "home"
        case let .volumeIgnore(v): "vol:" + v.string
        case let .scopeIgnore(scope): "scope:" + scope.rawValue
        case .blocklist: "blk"
        }
    }

    // MARK: Public entry

    /// Structural options for the whole selection. Candidates produced by different paths that resolve to the
    /// same rule are merged, so a single "all apps" rule can report that it covers every selected path.
    static func options(_ infos: [ExcludePathInfo]) -> [ExcludeOption] {
        var groups: [String: (cand: Candidate, covered: Int)] = [:]
        var order: [String] = []
        for info in infos {
            for cand in candidates(for: info) {
                let key = cand.key
                if groups[key] == nil {
                    groups[key] = (cand, 0)
                    order.append(key)
                }
                groups[key]!.covered += 1
            }
        }
        guard !groups.isEmpty else { return [] }

        let total = infos.count
        let ordered = order
            .map { (key: $0, group: groups[$0]!) }
            .sorted { a, b in
                a.group.covered != b.group.covered
                    ? a.group.covered > b.group.covered
                    : a.group.cand.rank < b.group.cand.rank
            }

        return ordered.prefix(6).map { entry in
            let cand = entry.group.cand
            let covered = entry.group.covered
            var summary = cand.summary
            if total > 1 {
                summary += covered == total ? " Covers all \(total) selected." : " Covers \(covered) of \(total) selected."
            }
            return ExcludeOption(
                title: cand.title,
                summary: summary,
                breadth: cand.breadth,
                rules: cand.rules,
                needsReindex: cand.needsReindex
            )
        }
    }

    // MARK: Per-path detection

    static func candidates(for info: ExcludePathInfo) -> [Candidate] {
        var out: [Candidate] = []
        let m = info.mechanism
        let onBlocklist = m == .blocklist
        // Components relative to the store root (fsignore), or the absolute path (blocklist).
        let comps = (onBlocklist ? info.abs : info.rel).split(separator: "/").map(String.init)
        guard !comps.isEmpty else { return [] }

        // C — build-artifact / VCS noise directories, routed to the global blocklist (fast, store-agnostic).
        if let i = comps.firstIndex(where: { noiseDirs.contains($0) }) {
            let name = comps[i]
            out.append(Candidate(
                rules: [ExcludeRule(mechanism: .blocklist, line: "/\(name)/", blocklistPrefix: false)],
                title: "All “\(name)” folders",
                summary: "Skips every `\(name)` directory anywhere. Fast global blocklist rule.",
                breadth: .broad,
                rank: 0
            ))
        }

        // C' — hidden (dot) directories: a hidden config/secrets/tooling folder is clutter the user usually
        // wants gone wherever it appears, even when the files inside it have nothing in common. Offer to drop
        // every directory with that name via the global blocklist, same as C. Pick the deepest dot-folder
        // ancestor (the hidden folder the selection sits directly inside); skip "." / ".." and names C already
        // covers so the two never emit a duplicate candidate.
        if let di = comps.lastIndex(where: { c in
            c.hasPrefix(".") && c != "." && c != ".." && !noiseDirs.contains(c)
        }), di < comps.count - 1 || info.isDir {
            let name = comps[di]
            out.append(Candidate(
                rules: [ExcludeRule(mechanism: .blocklist, line: "/\(name)/", blocklistPrefix: false)],
                title: "All “\(name)” folders",
                summary: "Skips every hidden `\(name)` directory anywhere. Fast global blocklist rule.",
                breadth: .broad,
                rank: 0
            ))
        }

        // Everything below needs glob support (an fsignore store).
        guard m.supportsGlobs else {
            mediaBlocklistFallback(comps, info: info, into: &out)
            return out
        }

        // A — app bundle: keep the executables in Contents/MacOS, drop the cruft.
        if let bi = comps.lastIndex(where: { $0.hasSuffix(".app") }), comps.count > bi + 2, comps[bi + 1] == "Contents" {
            let appName = comps[bi]
            let appRel = comps.prefix(bi + 1).joined(separator: "/")
            let section = comps[bi + 2]
            let afterMacOS = comps.count - (bi + 3)

            if section == "MacOS", afterMacOS >= 2 || (afterMacOS == 1 && info.isDir) {
                // The selection lives in a subfolder of MacOS; a directory-only trailing `**/` drops those
                // subfolders while leaving the binaries that sit directly in MacOS indexed.
                out.append(Candidate(
                    rules: [ExcludeRule(mechanism: m, line: "**/Contents/MacOS/**/")],
                    title: "All apps: clear out Contents/MacOS, keep binaries",
                    summary: "Drops the subfolders inside every app's MacOS folder (plugins, data) while keeping the executables searchable.",
                    breadth: .broad,
                    rank: 0
                ))
                out.append(Candidate(
                    rules: [ExcludeRule(mechanism: m, line: "/\(appRel)/Contents/MacOS/**/")],
                    title: "Just \(appName): clear out Contents/MacOS, keep binaries",
                    summary: "Same, limited to this one app.",
                    breadth: .folder,
                    rank: 1
                ))
            } else if section != "MacOS", appDropSections.contains(section) {
                out.append(Candidate(
                    rules: [ExcludeRule(mechanism: m, line: "**/Contents/\(section)/")],
                    title: "All apps: drop Contents/\(section)",
                    summary: "Removes every app's `\(section)` folder from the index.",
                    breadth: .broad,
                    rank: 0
                ))
                out.append(Candidate(
                    rules: [ExcludeRule(mechanism: m, line: "/\(appRel)/Contents/\(section)/")],
                    title: "Just \(appName): drop Contents/\(section)",
                    summary: "Removes this one app's `\(section)` folder.",
                    breadth: .folder,
                    rank: 1
                ))
            }
        }

        // A' — standalone framework Resources (also fires for embedded frameworks; the user can pick either).
        if let fi = comps.firstIndex(where: { $0.hasSuffix(".framework") }),
           comps.count > fi + 3, comps[fi + 1] == "Versions", comps[fi + 3] == "Resources"
        {
            out.append(Candidate(
                rules: [ExcludeRule(mechanism: m, line: "**/*.framework/Versions/*/Resources/")],
                title: "All frameworks: drop bundled Resources",
                summary: "Removes every framework's Resources folder while keeping the library itself.",
                breadth: .broad,
                rank: 0
            ))
        }

        // B — opaque media / archive libraries: drop everything inside.
        if let mi = comps.firstIndex(where: { c in mediaExts.contains(where: { c.hasSuffix($0) }) }) {
            let pkg = comps[mi]
            let ext = mediaExts.first { pkg.hasSuffix($0) } ?? ""
            let pkgRel = comps.prefix(mi + 1).joined(separator: "/")
            out.append(Candidate(
                rules: [ExcludeRule(mechanism: m, line: "*\(ext)/")],
                title: "All \(ext) libraries",
                summary: "Skips the contents of every `\(ext)` package.",
                breadth: .broad,
                rank: 0
            ))
            out.append(Candidate(
                rules: [ExcludeRule(mechanism: m, line: "/\(pkgRel)/")],
                title: "Just this \(ext) library",
                summary: "Skips the contents of `\(pkg)`.",
                breadth: .folder,
                rank: 1
            ))
        }

        // D — localizations: drop all, or all but the base/English ones.
        if let li = comps.firstIndex(where: { $0.hasSuffix(".lproj") }) {
            let lproj = comps[li]
            out.append(Candidate(
                rules: [ExcludeRule(mechanism: m, line: "*.lproj/")],
                title: "All localizations",
                summary: "Skips every `.lproj` language folder, anywhere.",
                breadth: .broad,
                rank: 0
            ))
            if lproj != "Base.lproj", lproj != "en.lproj" {
                out.append(Candidate(
                    rules: [
                        ExcludeRule(mechanism: m, line: "*.lproj/"),
                        ExcludeRule(mechanism: m, line: "!Base.lproj/"),
                        ExcludeRule(mechanism: m, line: "!en.lproj/"),
                    ],
                    title: "Localizations except Base and English",
                    summary: "Skips `.lproj` folders but keeps `Base.lproj` and `en.lproj`.",
                    breadth: .broad,
                    rank: 1
                ))
            }
        }

        return out
    }

    /// Media library that resolved to the blocklist (a path outside any ignore-file store): a prefix rule on
    /// the package path drops its contents without needing globs.
    private static func mediaBlocklistFallback(_ comps: [String], info: ExcludePathInfo, into out: inout [Candidate]) {
        guard let mi = comps.firstIndex(where: { c in mediaExts.contains(where: { c.hasSuffix($0) }) }) else { return }
        let pkg = comps[mi]
        // comps came from the absolute path; rebuild the package's absolute path.
        let pkgAbs = "/" + comps.prefix(mi + 1).joined(separator: "/")
        out.append(Candidate(
            rules: [ExcludeRule(mechanism: .blocklist, line: pkgAbs + "/", blocklistPrefix: true)],
            title: "Just this library",
            summary: "Skips the contents of `\(pkg)`.",
            breadth: .folder,
            rank: 1
        ))
    }
}
