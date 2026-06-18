import SwiftUI

/// Reference card for the search query language, shown in a popover from the search bar.
/// Covers fuzzy matching, type/place filters, anchors, and exclusions.
struct QuerySyntaxCheatsheet: View {
    struct Item: Identifiable {
        let id = UUID()
        let syntax: String
        let desc: String
        var example: String? = nil
    }

    struct Group: Identifiable {
        let id = UUID()
        let title: String
        let icon: String
        let tint: Color
        let items: [Item]
    }

    static let groups: [Group] = [
        Group(title: "Match", icon: "magnifyingglass", tint: .blue, items: [
            Item(syntax: "text", desc: "Fuzzy match — letters in order, anywhere in the path", example: "lnr → Lunar"),
            Item(syntax: "a b", desc: "Every word must match (in order across the path)", example: "search engine"),
            Item(syntax: "'text", desc: "Exact text, not fuzzy", example: "'NTSC matches NTSC, not Nits"),
        ]),
        Group(title: "Type & place", icon: "folder", tint: .orange, items: [
            Item(syntax: ".ext", desc: "Filter by extension (also *.ext)", example: ".swift"),
            Item(syntax: ".a .b", desc: "Several extensions at once", example: ".png .jpg"),
            Item(syntax: "in:PATH", desc: "Search only inside a folder", example: "in:~/Downloads"),
            Item(syntax: "depth:N", desc: "Limit how deep below the root to look", example: "depth:1"),
            Item(syntax: "name/", desc: "A folder and everything inside it", example: "config/"),
        ]),
        Group(title: "Anchors", icon: "arrow.left.and.right.text.vertical", tint: .purple, items: [
            Item(syntax: "^text", desc: "A path segment that starts with text (/text works too)", example: "^release → …/Releases, not jq-release.key"),
            Item(syntax: "text$", desc: "Name ends with text (extension optional)", example: "icon$ or icon.png$ → crank-icon.png"),
        ]),
        Group(title: "Exclude", icon: "minus.circle", tint: .red, items: [
            Item(syntax: "!text", desc: "Hide paths containing text", example: "!invoice"),
            Item(syntax: "!.ext", desc: "Hide an extension", example: "!.pyc"),
            Item(syntax: "!name/", desc: "Hide a folder", example: "!node_modules/"),
            Item(syntax: "!/", desc: "Files only — hide folders", example: nil),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "command")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Search syntax")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Self.groups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 5) {
                                Image(systemName: group.icon)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(group.tint)
                                Text(group.title.uppercased())
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .tracking(0.5)
                            }
                            ForEach(group.items) { item in
                                row(item)
                            }
                        }
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: 420)

            Divider()

            HStack(spacing: 5) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Mix freely:")
                    .foregroundStyle(.secondary)
                chip(".py plot !/packages/")
            }
            .font(.system(size: 11))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 380)
    }

    private func row(_ item: Item) -> some View {
        HStack(alignment: .top, spacing: 10) {
            chip(item.syntax)
                .frame(width: 92, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.desc)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                if let example = item.example {
                    Text(example)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, design: .monospaced).weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

#Preview {
    QuerySyntaxCheatsheet()
}
