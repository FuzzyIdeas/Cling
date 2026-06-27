import SwiftUI

/// Reference card for the search query language, shown in a popover from the search bar.
/// Covers fuzzy matching, type/place filters, anchors, and exclusions.
struct QuerySyntaxCheatsheet: View {
    struct Item: Identifiable {
        let id = UUID()
        let syntax: String
        let desc: String
        var example: String?
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
            Item(syntax: "text", desc: "Fuzzy match: the letters in order, anywhere in the path", example: "rprt finds report.pdf"),
            Item(syntax: "a b", desc: "Every word must appear", example: "vacation photos"),
            Item(syntax: "'text", desc: "Exact text, not fuzzy", example: "'cat finds vacation, not contact"),
        ]),
        Group(title: "Type & place", icon: "folder", tint: .orange, items: [
            Item(syntax: ".ext", desc: "Filter by file type (or *.ext)", example: ".pdf"),
            Item(syntax: ".a .b", desc: "Several file types at once", example: ".jpg .png"),
            Item(syntax: "in:PATH", desc: "Search only inside a folder", example: "in:~/Documents"),
            Item(syntax: "depth:N", desc: "Stay within N folders of the search root", example: "depth:1"),
            Item(syntax: "name/", desc: "A folder with this name, and everything inside it", example: "Photos/ finds the folder and its files"),
        ]),
        Group(title: "Anchors", icon: "arrow.left.and.right.text.vertical", tint: .purple, items: [
            Item(syntax: "^text", desc: "A folder or file name that starts with this", example: "^report finds Reports, not annual-report"),
            Item(syntax: "text$", desc: "A name that ends with this (file type optional)", example: "report$ finds annual-report.pdf"),
        ]),
        Group(title: "Exclude", icon: "minus.circle", tint: .red, items: [
            Item(syntax: "!text", desc: "Hide anything containing this", example: "!backup"),
            Item(syntax: "!.ext", desc: "Hide a file type", example: "!.zip"),
            Item(syntax: "!name/", desc: "Hide a folder", example: "!Backups/"),
            Item(syntax: "!/", desc: "Files only (hide folders)", example: nil),
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
                chip("report .pdf in:~/Documents !draft")
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
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                        .padding(.top, 1)
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
