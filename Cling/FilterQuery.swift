import Foundation

/// How a filter restricts results by entry kind. `folders` maps to the directories-only search
/// parameter (it has no query token); `both`/`files` are expressible as tokens.
enum FilterMatch: String, Codable, CaseIterable {
    case both, files, folders
}

/// Compile a Quick Filter's structured fields into a query string in the same operator language
/// the search bar uses. Used for the editor's "Runs as" preview and as the filter's query
/// contribution at search time. `match == .folders` contributes no token (it is a parameter).
func compileFilterQuery(extensions: String?, exclude: String?, match: FilterMatch, folders: [String], maxDepth: Int?) -> String {
    var tokens: [String] = []

    if let extensions, !extensions.trimmingCharacters(in: .whitespaces).isEmpty {
        for raw in extensions.replacingOccurrences(of: "|", with: " ").replacingOccurrences(of: ",", with: " ").split(separator: " ") {
            let bare = raw.drop(while: { $0 == "." })
            if !bare.isEmpty { tokens.append("." + bare) }
        }
    }
    if let exclude, !exclude.trimmingCharacters(in: .whitespaces).isEmpty {
        for raw in exclude.split(separator: " ") {
            tokens.append(raw.hasPrefix("!") ? String(raw) : "!" + raw)
        }
    }
    if match == .files { tokens.append("!/") }
    for folder in folders where !folder.isEmpty {
        tokens.append(folder.contains(" ") ? "in:\"\(folder)\"" : "in:\(folder)")
    }
    if let maxDepth, maxDepth >= 0 { tokens.append("depth:\(maxDepth)") }

    return tokens.joined(separator: " ")
}
