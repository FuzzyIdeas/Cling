import KeyboardShortcuts
import SwiftUI

// MARK: - ShortcutsSettingsPane

struct ShortcutsSettingsPane: View {
    var body: some View {
        Form {
            ForEach(displaySegments, id: \.self) { segment in
                let items = ToolbarAction.rebindable.filter { $0.segment == segment }
                if !items.isEmpty {
                    Section(segment.title) {
                        ForEach(items) { action in
                            LabeledContent {
                                ShortcutRecorder(name: ClingShortcuts.name(for: action.id)) { _ in
                                    validate(action.id)
                                }
                            } label: {
                                Label(action.title, systemImage: action.systemImage)
                            }
                        }
                    }
                }
            }
            Section("Sorting") {
                ForEach(ClingShortcuts.sortShortcuts) { sort in
                    LabeledContent {
                        ShortcutRecorder(name: sort.name) { _ in
                            validate(name: sort.name, title: sort.title)
                        }
                    } label: {
                        Label(sort.title, systemImage: sort.systemImage)
                    }
                }
            }
            if let conflict {
                Section {
                    Text(conflict).foregroundStyle(.red).font(.callout)
                }
            }
            Section {
                Button("Reset all shortcuts to defaults") {
                    KeyboardShortcuts.reset(ClingShortcuts.allNames)
                    conflict = nil
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    @State private var conflict: String?

    private let displaySegments: [ActionSegment] = [.open, .fileOps, .share, .destructive, .alternate]

    private func validate(_ id: ActionID) {
        validate(name: ClingShortcuts.name(for: id), title: ToolbarAction.byID[id]?.title ?? id.rawValue)
    }

    /// Reject a just-recorded shortcut that duplicates another of ours (file action or sort):
    /// clear it and tell the user. Works for both the toolbar-action rows and the sorting rows.
    private func validate(name: KeyboardShortcuts.Name, title: String) {
        guard let new = KeyboardShortcuts.getShortcut(for: name),
              let other = ClingShortcuts.conflictingTitle(with: new, excluding: name)
        else {
            conflict = nil; return
        }
        KeyboardShortcuts.setShortcut(nil, for: name)
        conflict = "\(title) conflicts with \(other). Shortcut cleared."
    }
}
