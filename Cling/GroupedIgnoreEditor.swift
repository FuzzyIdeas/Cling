import Lowtech
import SwiftUI

/// Toggle-first editor for a grouped ignore / blocklist file. Each `#:group` becomes a row with an
/// on/off switch; expanding a group reveals a checkbox per rule. The raw gitignore text stays one
/// disclosure away ("Edit as text") for authoring new rules, but day-to-day enabling and disabling
/// never requires touching the syntax.
///
/// The bound `rawText` is the single source of truth: toggles mutate a parsed copy and write the
/// serialized result straight back, and any outside change to `rawText` (raw edits, Reset, Reset All)
/// re-parses the toggle list. `IgnoreDocument.parse`/`serialize` round-trips byte-for-byte, so a file
/// is only rewritten once the user actually flips something.
struct GroupedIgnoreEditor: View {
    init(
        title: String,
        subtitle: String,
        rawText: Binding<String>,
        rawEditorHeight: CGFloat = 160,
        applyDisabled: Bool = false,
        showHelpButton: Bool = false,
        onApply: @escaping () -> Void,
        defaultText: @escaping () -> String,
        openExternal: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        _rawText = rawText
        self.rawEditorHeight = rawEditorHeight
        self.applyDisabled = applyDisabled
        self.showHelpButton = showHelpButton
        self.onApply = onApply
        self.defaultText = defaultText
        self.openExternal = openExternal
        _doc = State(initialValue: IgnoreDocument.parse(rawText.wrappedValue))
    }

    let title: String
    let subtitle: String
    @Binding var rawText: String
    let rawEditorHeight: CGFloat
    let applyDisabled: Bool
    let showHelpButton: Bool
    let onApply: () -> Void
    let defaultText: () -> String
    let openExternal: (() -> Void)?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                header
                groupsList
                rawDisclosure
                buttonRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .groupBoxStyle(SettingsCardGroupBoxStyle())
        .onChange(of: rawText) {
            // Re-sync only when the change came from outside the toggle list (raw edits / resets).
            let parsed = IgnoreDocument.parse(rawText)
            if parsed.serialize() != doc.serialize() { doc = parsed }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                if !title.isEmpty {
                    Text(title).font(.system(size: 12, weight: .semibold))
                }
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if showHelpButton {
                Button(action: { showHelpSheet.toggle() }) {
                    Image(systemName: "questionmark.circle").foregroundColor(.secondary)
                }
                .buttonStyle(.borderlessText)
                .sheet(isPresented: $showHelpSheet) { helpSheet }
            }
        }
    }

    private var groupsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            if doc.groups.isEmpty {
                Text("No rule groups yet. Use Edit as text below to add rules.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ForEach(doc.groups.indices, id: \.self) { gi in
                    groupView(gi)
                }
            }
        }
    }

    private func groupView(_ gi: Int) -> some View {
        let group = doc.groups[gi]
        let isExpanded = expanded.contains(group.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Toggle("", isOn: groupBinding(gi))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(group.ruleCount == 0)
                    .fixedSize()
                Button {
                    if group.ruleCount > 0 { toggleExpanded(group.id) }
                } label: {
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.name).font(.system(size: 11, weight: .medium)).foregroundStyle(.primary)
                            Text(statusCaption(group)).font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if group.ruleCount > 0 {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 12)
                        }
                    }
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(group.rules, id: \.index) { rule in
                        Button {
                            ruleBinding(gi, rule.index).wrappedValue.toggle()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: rule.enabled ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 11))
                                    .foregroundStyle(rule.enabled ? Color.accentColor : .secondary)
                                    .frame(width: 14)
                                Text(rule.pattern)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(rule.enabled ? .primary : .secondary)
                                    .strikethrough(!rule.enabled, color: .secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .frame(height: 18)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 22)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 7)
        .background(.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
    }

    private var rawDisclosure: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { showRaw.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: showRaw ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Text("Edit as text").font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 0)
                }
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Only instantiate the TextEditor while expanded; an always-present NSTextView is what made
            // the surrounding ScrollView lag.
            if showRaw {
                TextEditor(text: $rawText)
                    .font(.system(size: 11, design: .monospaced))
                    .contentMargins(6)
                    .frame(height: rawEditorHeight)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 0.5))
                if let openExternal {
                    HStack {
                        Spacer()
                        Button("Open in external editor", action: openExternal)
                            .controlSize(.small)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    private var buttonRow: some View {
        HStack {
            Button("Apply & Reindex", action: onApply)
                .controlSize(.small)
                .disabled(applyDisabled)
                .help("Save these rules and reindex")
            Button("Reset to Default") { rawText = defaultText() }
                .controlSize(.small)
                .help("Restore Cling's built-in rules for this list")
            Spacer()
        }
    }

    private var helpSheet: some View {
        VStack(spacing: 5) {
            HStack {
                Button(action: { showHelpSheet = false }) {
                    Image(systemName: "xmark")
                        .font(.heavy(7))
                        .foregroundColor(.bg.warm)
                }
                .buttonStyle(FlatButton(color: .fg.warm.opacity(0.6), circle: true, horizontalPadding: 5, verticalPadding: 5))
                .padding(.top, 8).padding(.leading, 8)
                Spacer()
            }
            IgnoreHelpText().padding()
        }
        .frame(width: 500)
    }

    // MARK: - Bindings & state

    @State private var doc: IgnoreDocument
    @State private var expanded: Set<String> = []
    @State private var showRaw = false
    @State private var showHelpSheet = false

    private func toggleExpanded(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func statusCaption(_ group: IgnoreDocument.Group) -> String {
        if group.ruleCount == 0 { return group.isCustom ? "add rules via Edit as text" : "no rules" }
        if group.allEnabled { return "\(group.ruleCount) rule\(group.ruleCount == 1 ? "" : "s") active" }
        if group.anyEnabled { return "\(group.enabledCount) of \(group.ruleCount) active" }
        return "off"
    }

    private func groupBinding(_ gi: Int) -> Binding<Bool> {
        Binding(
            get: { doc.groups.indices.contains(gi) ? doc.groups[gi].anyEnabled : false },
            set: { newVal in
                doc.setGroup(gi, enabled: newVal)
                rawText = doc.serialize()
            }
        )
    }

    private func ruleBinding(_ gi: Int, _ ii: Int) -> Binding<Bool> {
        Binding(
            get: {
                guard doc.groups.indices.contains(gi),
                      doc.groups[gi].items.indices.contains(ii),
                      case let .rule(_, enabled) = doc.groups[gi].items[ii] else { return false }
                return enabled
            },
            set: { newVal in
                doc.setRule(group: gi, item: ii, enabled: newVal)
                rawText = doc.serialize()
            }
        )
    }
}
