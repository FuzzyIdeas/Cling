import Foundation

//
// The writes that carry more than a key and a value. The CLI encodes one into `ClingRequest.payload`
// and the app decodes it, so both ends read the same field names. Every field is optional because
// an edit only names what it changes: a field left out keeps its current value.

// MARK: - ClingFilterSpec

public struct ClingFilterSpec: Codable {
    public init(kind: String, name: String) {
        self.kind = kind
        self.name = name
    }

    /// `quick` or `folder`.
    public var kind: String
    public var name: String
    /// The filter's current name, when this write renames it.
    public var rename: String?
    public var folders: [String]?
    /// Space separated, e.g. `.png .jpg`. Quick filters only.
    public var extensions: String?
    /// Words or extensions a result must not contain. Quick filters only.
    public var exclude: String?
    /// `both`, `files` or `folders`. Quick filters only.
    public var match: String?
    /// Text put before the typed query. Quick filters only.
    public var prepend: String?
    /// Text put after the typed query. Quick filters only.
    public var append: String?
    /// A whole query that replaces every structured field. Quick filters only.
    public var rawQuery: String?
    /// -1 clears it.
    public var maxDepth: Int?
    /// One letter or digit, pressed with ⌥ in the search window. `none` clears it.
    public var key: String?
    /// An SF Symbol name.
    public var icon: String?
    /// 0 to 1 around the colour wheel.
    public var hue: Double?
    /// How long Cling stays in the background before the filter turns off: a duration like `90s`, `10m` or `2h`,
    /// `off` to keep it on, or `default` to follow the setting.
    public var autoOff: String?
}

// MARK: - ClingScriptSpec

public struct ClingScriptSpec: Codable {
    public init(name: String) {
        self.name = name
    }

    /// The file name without its extension.
    public var name: String
    /// sh, zsh, fish, python3, ruby, perl, swift, osascript or node. Picks the shebang and extension.
    public var runner: String?
    /// The script body, without the shebang or the header comments Cling manages.
    public var code: String?
    public var description: String?
    /// One letter or digit for ⌘⌃ in the search window. `none` clears it.
    public var key: String?
    /// Space separated, without dots. `none` clears it.
    public var extensions: String?
    /// 0 clears it.
    public var minFiles: Int?
    /// 0 clears it.
    public var maxFiles: Int?
    public var filesOnly: Bool?
    public var dirsOnly: Bool?
    public var confirm: Bool?
    public var sequential: Bool?
    public var showOutput: Bool?
    /// Overwrite the code of an existing script with the same name.
    public var replace: Bool?
}
