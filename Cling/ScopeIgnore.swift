import Foundation
import Lowtech
import System

/// Per-scope gitignore files for scopes whose real root is read-only / SIP-protected (Applications, System,
/// Root), where we can't drop a `.fsignore` at the root. The file lives in our cache dir; its patterns are
/// anchored to the real scope directory at match time via the rooted ignore API (`isIgnored(in:root:)`).
/// Home and Library keep using `~/.fsignore` directly.
enum ScopeIgnore {
    /// Scopes that use a separate, rooted ignore file (everything not already covered by `~/.fsignore`).
    static let rootedScopes: [SearchScope] = [.applications, .system, .root]

    static var dir: FilePath { indexFolder / "ignores" }

    static func file(for scope: SearchScope) -> FilePath { dir / "\(scope.rawValue).fsignore" }

    static func content(for scope: SearchScope) -> String {
        (try? String(contentsOf: file(for: scope).url, encoding: .utf8)) ?? ""
    }

    /// The ignore file path to apply while walking `scope`, or nil when it has no patterns.
    static func activeFile(for scope: SearchScope) -> String? {
        let f = file(for: scope)
        guard let content = try? String(contentsOfFile: f.string, encoding: .utf8),
              content.contains(where: { !$0.isWhitespace }) else { return nil }
        return f.string
    }

    static func ensureDir() {
        try? FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
    }

    static func write(_ content: String, for scope: SearchScope) {
        ensureDir()
        try? content.write(to: file(for: scope).url, atomically: true, encoding: .utf8)
    }

    /// The real root directories a rooted scope walks. Patterns in its ignore file are relative to these.
    static func roots(for scope: SearchScope) -> [String] {
        switch scope {
        case .applications: ["/Applications", "/System/Applications"]
        case .system: ["/System"]
        case .root: ["/usr", "/bin", "/sbin", "/opt", "/etc", "/Library", "/var", "/private"]
        case .home, .library: []
        }
    }

    /// Map an absolute path to its rooted scope and the specific root that contains it (nil if not in one).
    static func scopeAndRoot(forPath path: String) -> (scope: SearchScope, root: String)? {
        for scope in rootedScopes {
            for root in roots(for: scope) where path == root || path.hasPrefix(root + "/") {
                return (scope, root)
            }
        }
        return nil
    }
}
