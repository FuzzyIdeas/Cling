import Foundation

/// Parsed representation of a grouped ignore / blocklist file.
///
/// The on-disk format is plain gitignore (or blocklist) text annotated with `#:group id=… name=…`
/// headers and a trailing `#:custom name=…` group for rules the user adds. A disabled rule is stored
/// as a `#:off <pattern>` line: both the blocklist parser and the ignore crate treat it as a comment
/// and skip it, while this model can flip it back on without losing the pattern.
///
/// `parse()` followed by `serialize()` is an identity transform for already-grouped content (every
/// line is reproduced verbatim), so opening the toggle UI never rewrites a user's file until they
/// actually change something.
struct IgnoreDocument {
    enum Item: Equatable {
        case rule(pattern: String, enabled: Bool)
        case comment(String) // a plain "# …" annotation (not a disabled rule), kept verbatim
        case blank
    }

    struct Group: Identifiable {
        var id: String
        var name: String
        var isCustom: Bool
        var items: [Item]

        /// The rule items together with their position in `items` (so the UI can toggle them in place).
        var rules: [(index: Int, pattern: String, enabled: Bool)] {
            items.enumerated().compactMap { idx, item in
                if case let .rule(pattern, enabled) = item {
                    return (idx, pattern, enabled)
                }
                return nil
            }
        }

        var ruleCount: Int {
            rules.count
        }
        var enabledCount: Int {
            rules.lazy.filter(\.enabled).count
        }
        var allEnabled: Bool {
            ruleCount > 0 && enabledCount == ruleCount
        }
        var anyEnabled: Bool {
            enabledCount > 0
        }
        var isPartial: Bool {
            enabledCount > 0 && enabledCount < ruleCount
        }
    }

    /// Lines before the first group header (top-of-file comments), kept verbatim.
    var preamble: [String]
    var groups: [Group]

    // MARK: - Parsing

    static func parse(_ text: String) -> IgnoreDocument {
        var preamble: [String] = []
        var groups: [Group] = []
        var current: Group?

        func flush() {
            if let g = current {
                groups.append(g); current = nil
            }
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("#:group") {
                flush()
                let (id, name) = parseHeader(trimmed, keyword: "#:group")
                let gid = id ?? "group\(groups.count)"
                current = Group(id: gid, name: name ?? gid, isCustom: false, items: [])
                continue
            }
            if trimmed.hasPrefix("#:custom") {
                flush()
                let (_, name) = parseHeader(trimmed, keyword: "#:custom")
                current = Group(id: "custom", name: name ?? "Your rules", isCustom: true, items: [])
                continue
            }

            let item: Item
            if trimmed.isEmpty {
                item = .blank
            } else if trimmed.hasPrefix("#:off") {
                let pattern = String(trimmed.dropFirst("#:off".count)).trimmingCharacters(in: .whitespaces)
                item = .rule(pattern: pattern, enabled: false)
            } else if trimmed.hasPrefix("#") {
                item = .comment(line)
            } else {
                item = .rule(pattern: trimmed, enabled: true)
            }

            if current == nil {
                preamble.append(line)
            } else {
                current?.items.append(item)
            }
        }
        flush()

        return IgnoreDocument(preamble: preamble, groups: groups)
    }

    // MARK: - Serializing

    func serialize() -> String {
        var lines: [String] = preamble
        for group in groups {
            lines.append(
                group.isCustom
                    ? "#:custom name=\(group.name)"
                    : "#:group id=\(group.id) name=\(group.name)"
            )
            for item in group.items {
                switch item {
                case let .rule(pattern, enabled):
                    lines.append(enabled ? pattern : "#:off \(pattern)")
                case let .comment(text):
                    lines.append(text)
                case .blank:
                    lines.append("")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Mutation

    mutating func setGroup(_ groupIndex: Int, enabled: Bool) {
        guard groups.indices.contains(groupIndex) else { return }
        for i in groups[groupIndex].items.indices {
            if case let .rule(pattern, _) = groups[groupIndex].items[i] {
                groups[groupIndex].items[i] = .rule(pattern: pattern, enabled: enabled)
            }
        }
    }

    mutating func setRule(group groupIndex: Int, item itemIndex: Int, enabled: Bool) {
        guard groups.indices.contains(groupIndex),
              groups[groupIndex].items.indices.contains(itemIndex),
              case let .rule(pattern, _) = groups[groupIndex].items[itemIndex] else { return }
        groups[groupIndex].items[itemIndex] = .rule(pattern: pattern, enabled: enabled)
    }

    mutating func setAll(enabled: Bool) {
        for gi in groups.indices {
            setGroup(gi, enabled: enabled)
        }
    }

    /// Adds the rules of `additions` this document has nowhere yet, on or off, each to the end of the group with the
    /// same id, or to a new group. A new group goes where `reference` (the shipped defaults) has it: after the nearest
    /// group before it there that this document has too, otherwise ahead of the user's own rules. Shipping new default
    /// rules into a file the user may have edited this way leaves every line already there as it was.
    mutating func add(_ additions: IgnoreDocument, placedLike reference: IgnoreDocument? = nil) {
        var present = Set(groups.flatMap { $0.rules.map(\.pattern) })
        present.formUnion(preamble.map { $0.trimmingCharacters(in: .whitespaces) })

        for addition in additions.groups where !addition.isCustom {
            var missing: [Item] = []
            for pattern in addition.rules.map(\.pattern) where present.insert(pattern).inserted {
                missing.append(.rule(pattern: pattern, enabled: true))
            }
            guard !missing.isEmpty else { continue }

            if let gi = groups.firstIndex(where: { !$0.isCustom && $0.id == addition.id }) {
                // After the group's last line, ahead of the blank lines that part it from the next group.
                let end = (groups[gi].items.lastIndex { $0 != .blank } ?? -1) + 1
                groups[gi].items.insert(contentsOf: missing, at: end)
            } else {
                var at = groups.firstIndex(where: \.isCustom) ?? groups.count
                if let reference, let place = reference.groups.firstIndex(where: { $0.id == addition.id }) {
                    for prior in reference.groups[..<place].reversed() {
                        if let gi = groups.firstIndex(where: { !$0.isCustom && $0.id == prior.id }) {
                            at = gi + 1
                            break
                        }
                    }
                }
                groups.insert(Group(id: addition.id, name: addition.name, isCustom: false, items: missing + [.blank]), at: at)
            }
        }
    }

    /// Pull `id=` and `name=` out of a header line. `name=` captures the rest of the line so group
    /// names may contain spaces; `id=` is a single whitespace-delimited token.
    private static func parseHeader(_ line: String, keyword: String) -> (id: String?, name: String?) {
        let body = line.dropFirst(keyword.count)
        var id: String?
        var name: String?

        if let nameRange = body.range(of: "name=") {
            name = body[nameRange.upperBound...].trimmingCharacters(in: .whitespaces)
            let beforeName = body[..<nameRange.lowerBound]
            if let idRange = beforeName.range(of: "id=") {
                id = beforeName[idRange.upperBound...]
                    .trimmingCharacters(in: .whitespaces)
                    .prefix { !$0.isWhitespace }
                    .description
            }
        } else if let idRange = body.range(of: "id=") {
            id = body[idRange.upperBound...]
                .trimmingCharacters(in: .whitespaces)
                .prefix { !$0.isWhitespace }
                .description
        }
        return (id, name)
    }

}
